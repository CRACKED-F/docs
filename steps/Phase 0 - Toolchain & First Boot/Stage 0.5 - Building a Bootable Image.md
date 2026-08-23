# Stage 0.5 — Building a Bootable Image

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you work with:** `boot/limine.conf` (already scaffolded — you read it and understand every line), `scripts/mkimage.sh` (already scaffolded — you run it and understand every line)
**Deliverable:** **FIRST BOOT.** `build/os.iso` boots under legacy BIOS and `build/os.img` boots under UEFI; in both cases real firmware loads Limine, Limine loads your kernel, and your `hlt` loop is running — proven through the QEMU monitor, because there is no output yet.

---

> **This is the milestone stage of Phase 0.** Everything before it was compilation:
> object files, symbols, section headers. Nothing had run. At the end of this stage a
> processor somewhere has executed instructions that you wrote, on bare metal, under
> two different firmware standards.
>
> You will not see a single character of output. That is intentional and it is the
> whole design of §6 — read it before you start, not after it fails.

---

## Progress

- [ ] Read `boot/limine.conf` and be able to say what each of the four menu entries is for
- [ ] Note the `staging an empty placeholder` line in the `make iso` output — that is the stub initrd, and it is expected until [[Phase 7 - Overview|Phase 7]]
- [ ] `make iso` — `build/os.iso` exists and is a few megabytes
- [ ] Confirm `limine bios-install` actually ran (no error, no "skipped" note)
- [ ] `make img` — `build/os.img` exists, ~322 MiB
- [ ] Inspect the ISO with `xorriso -indev build/os.iso -toc` and the image with `parted build/os.img print`
- [ ] `make run` — the Limine menu appears, then the screen goes black
- [ ] `Ctrl-Alt-2`, `info registers` — `RIP` is in `0xFFFFFFFF80...`, `CPL=0`, `HLT=1`
- [ ] Run `info registers` a second time — `RIP` is unchanged
- [ ] `make run-uefi` — same check under UEFI
- [ ] Boot the ISO under UEFI too (`-cdrom` + `-bios`) — that is the third leg of the matrix
- [ ] Deliberately break `kernel_path` in `limine.conf`, confirm Limine complains, put it back
- [ ] Committed with a message like `feat(boot): hybrid ISO and GPT image build`

---

## 1. Why this stage exists

You have a `kernel.elf`. It has a `.limine_requests` section ([[Stage 0.2 - The Limine Request Section]]), a `kmain` that does not return ([[Stage 0.3 - Freestanding C++ and kmain]]), and a link map that puts `.text` at `0xFFFFFFFF80000000` ([[Stage 0.4 - The Linker Script and Higher-Half Layout]]). None of that is a bootable thing. An ELF file is a description of a program for a program loader, and at power-on there is no program loader — there is a chip that reads a fixed location off a fixed device and jumps to it.

The gap between "a correct ELF file" and "the firmware runs it" is filled by three separate pieces of machinery, none of which is your kernel: a **bootloader binary** in a format the firmware understands, a **filesystem layout** the bootloader can read, and a **container format** the firmware will boot from. This stage builds all three around your kernel and proves the resulting object boots.

Skip it and you have no way to run anything, ever. There is no `./kernel.elf`. But the sharper reason it is a separate stage is diagnostic. Firmware failures are the least informative failures in the whole project: the machine either reboots, or sits at a black screen, or drops you into a UEFI shell, and none of those tells you which of the five links in the chain broke. If you build the image *and* write the serial driver *and* fix the linker script in one sitting, a black screen means you have three suspects and no evidence. Building the image on its own, with a kernel whose entire behaviour is `hlt`, means a black screen has exactly one meaning and one way to check it.

That is also why this stage precedes [[Stage 0.6 - Serial Output]] rather than following it. The ordering is called out in [[Phase 0 - Overview]] and it is deliberate: **0.5 proves the boot chain with a kernel that only halts; 0.6 then adds the first output.** Each stage changes one thing. Do it the other way round and the first time you run QEMU you are simultaneously testing xorriso flags, ESP layout, firmware handoff, the linker script, and a UART driver — and when nothing appears you cannot tell whether the serial code is wrong or whether the kernel was never reached at all. That specific confusion is the single most common way people lose a weekend at this point.

---

## 2. The concept

### 2.1 What happens at power-on

Power reaches the CPU. It comes out of reset in a defined state with the instruction pointer aimed at the very top of the address space, where the motherboard has mapped a flash chip. That chip contains the **firmware**. Everything before your kernel runs is firmware, and there are two families of it in the x86 world.

The firmware's job, from your point of view, is exactly one thing: **find some code on a storage device, load it into RAM, and jump to it.** How it decides what to load is the entire difference between BIOS and UEFI.

### 2.2 Legacy BIOS: the boot sector

The IBM PC BIOS convention, essentially unchanged since 1981:

```
  power on
     │
     ▼
  POST, then walk the boot-device list in CMOS order
     │
     ▼
  read LBA 0 of the device — the first 512 bytes — into memory at 0x7C00
     │
     ▼
  is byte 510 == 0x55 and byte 511 == 0xAA ?
     │                  │
     no                 yes
     │                  │
  try next device       jump to 0x7C00, 16-bit real mode, DL = drive number
```

That 512-byte block is the **Master Boot Record**. Its last 66 bytes are the signature plus a four-entry partition table, so your code gets 446 bytes. 446 bytes is not enough to do anything except load more code, which is why every BIOS bootloader is a chain: a first stage in the MBR, a second stage somewhere else on the disk, and only then something that can read a filesystem.

**CD-ROMs do not work that way**, because a CD sector is 2048 bytes and there is no MBR. They use **El Torito**, a 1995 extension. The BIOS reads the ISO 9660 Boot Record Volume Descriptor at sector 17 of the disc, follows it to a **boot catalogue**, and the catalogue tells it what to load. A catalogue entry can request three emulation modes:

| Mode | What the BIOS pretends the disc is | Verdict |
|---|---|---|
| Floppy emulation | a 1.44 or 2.88 MB floppy | limits you to that size; INT 13h geometry lies |
| Hard-disk emulation | a disk with an MBR | same chaining problem, extra indirection |
| **No emulation** | nothing — just load N raw sectors and jump | what every modern loader uses |

We use no-emulation. The BIOS loads a fixed number of sectors from a fixed LBA to `0x7C00` and jumps. That loaded blob is `limine-bios-cd.bin`, and it knows how to read ISO 9660 well enough to find the rest of Limine.

### 2.3 UEFI: the firmware reads a filesystem

UEFI throws the whole boot-sector idea away. UEFI firmware contains a **FAT filesystem driver** and a **PE/COFF loader**. It does not load raw sectors and jump; it opens a *file* and executes it as a proper program, with the machine already in 64-bit mode and a rich API available.

```
  power on
     │
     ▼
  firmware initialises, enumerates block devices
     │
     ▼
  for each device: read the GPT, look for a partition whose type GUID is
  C12A7328-F81F-11D2-BA4B-00A0C93EC93B  — the EFI System Partition
     │
     ▼
  mount it as FAT
     │
     ├── boot entries in NVRAM (Boot0000, Boot0001…) ? load what they name
     │
     └── nothing registered, or removable media ?
            load  \EFI\BOOT\BOOTX64.EFI       ◄── the removable-media fallback path
     │
     ▼
  execute it as a PE32+ EFI application, 64-bit, identity-mapped, boot services live
```

Two consequences matter enormously here.

**The ESP must be FAT.** Not "should be" — the firmware's only filesystem driver is FAT. The UEFI specification requires implementations to support FAT12, FAT16 and FAT32 and nothing else. You may not put your bootloader on ext2, or on your own filesystem, because the firmware cannot read it and there is no way to teach it. This is the direct cause of the FAT32 half of [[ADR-0009 - Filesystem Strategy FAT32 then ext2]]: we implement FAT32 in the kernel not because it is a good filesystem but because it is the one we are *required* to be able to write.

**The fallback path is what makes removable media work.** A permanently installed OS registers a boot entry in the firmware's NVRAM naming its own loader. A USB stick cannot — it has never seen this machine before. So the spec defines a hardcoded path per architecture that firmware must try when it has nothing registered: `\EFI\BOOT\BOOTX64.EFI` on x86_64, `\EFI\BOOT\BOOTIA32.EFI` on 32-bit x86. That exact path, capitalised that way, is why `stage_common` copies Limine's `BOOTX64.EFI` to `$STAGE/EFI/BOOT/BOOTX64.EFI` and nowhere else. Put it one directory off and UEFI firmware finds no bootloader and drops you at a shell prompt.

This is also why running QEMU with `-bios OVMF_CODE_4M.fd` works at all: `-bios` gives OVMF no writable variable store, so it has no NVRAM boot entries, so it always takes the fallback path. Your development setup exercises exactly the path a USB stick takes on real hardware.

### 2.4 One file for both: the hybrid ISO

An El Torito boot catalogue may hold **more than one entry**, each tagged with a platform ID. Platform ID `0x00` means "80x86 BIOS". Platform ID `0xEF` means "UEFI". Firmware reads the catalogue and picks the entry it understands, ignoring the other.

The UEFI entry cannot point at raw sectors, because UEFI does not boot raw sectors — it boots a file out of a FAT filesystem. So the UEFI El Torito entry points at a **FAT disk image embedded inside the ISO as an ordinary file**. The firmware exposes that file as a virtual block device, mounts it as FAT, and finds `/EFI/BOOT/BOOTX64.EFI` inside it. That file is `limine-uefi-cd.bin`: a small pre-made FAT image with Limine's EFI binaries already in it.

```
os.iso
├── LBA 0        protective MBR + Limine's BIOS boot record   ◄─ BIOS-from-USB path
├── LBA 1-33     GPT header + partition entries               ◄─ UEFI-from-USB path
├── sector 17    ISO 9660 Boot Record Volume Descriptor  ──┐
│                                                          │
├── boot catalogue  ◄────────────────────────────────────── ┘
│     ├── entry, platform 0x00 (BIOS) ──► limine-bios-cd.bin, no-emulation
│     └── entry, platform 0xEF (UEFI) ──► limine-uefi-cd.bin   [a FAT image]
│                                              └── /EFI/BOOT/BOOTX64.EFI
│
└── ISO 9660 / Rock Ridge / Joliet filesystem
      limine.conf
      kernel.elf
      initrd.tar
      limine-bios.sys
      limine-bios-cd.bin
      limine-uefi-cd.bin
      EFI/BOOT/BOOTX64.EFI     (unused by the El Torito path; see §5)
```

There is a fourth path hiding in that diagram. If you `dd` the ISO onto a USB stick, the firmware sees a *disk*, not an optical drive, and El Torito never enters the picture — BIOS reads LBA 0 as an MBR, UEFI reads LBA 1 as a GPT. Making both of those work on an ISO is what "hybrid" means, and it is the job of `--protective-msdos-label`, `-efi-boot-part --efi-boot-image`, and the `limine bios-install` call afterwards.

### 2.5 And separately: the GPT disk image

`os.img` is not a disc. It is a byte-for-byte image of a real hard disk.

```
os.img  (322 MiB)
│
├── 0 MiB      LBA 0        protective MBR
│              LBA 1        GPT header
│              LBA 2-33     partition entry array (128 × 128 bytes)
│              LBA 34-2047  free — Limine's BIOS stage 2 is embedded here
│
├── 1 MiB      ┌─ Partition 1 — ESP, FAT32, 64 MiB, type GUID C12A7328-…
│              │    /EFI/BOOT/BOOTX64.EFI
│              │    /EFI/BOOT/BOOTIA32.EFI
│              │    /limine.conf
│              │    /kernel.elf
│              │    /initrd.tar
│              │    /limine-bios.sys
│              └─
├── 65 MiB     ┌─ Partition 2 — root, ext2, 256 MiB, label OSROOT
│              │    empty for now. WRITABLE.
│              └─
└── 321 MiB    backup GPT
```

The ISO is read-only by construction — ISO 9660 has no concept of writing. `os.img` has a second partition that the OS will eventually mount read-write, and that is the artefact that will one day prove persistence: write a file, reboot, the file is still there. That test is [[Phase 10 - Overview|Phase 10]], but the image has to have somewhere to write from Stage 0.5 onward or the layout has to change later, and layout changes late are the ones that break the release pipeline. See [[11 - Release and Deployment]] for where these artefacts end up.

---

## 3. Design decisions and tradeoffs

### Decision: one hybrid ISO, or separate BIOS and UEFI artefacts?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): one hybrid ISO** | Two El Torito entries in one boot catalogue, plus a protective MBR and GPT so a raw `dd` also boots | A genuinely intimidating `xorriso` command line; failures produce cryptic messages | ✅ |
| B: separate `os-bios.iso` and `os-uefi.iso` | Two simple `xorriso` calls, one per firmware | Two artefacts, two checksums, two download buttons, and a user who must know their own firmware type | ❌ |
| C: UEFI only | An ESP and nothing else | Fastest to build; abandons every pre-2012 machine and every VM configured for SeaBIOS | ❌ |

**Why A.** The complexity is paid once, in one shell function, by us. Option B pushes it onto every user and every CI matrix entry forever. And the question "which firmware does this machine use?" is one most people cannot answer about their own laptop — the second-hand test machine in [[11 - Release and Deployment]] is exactly the case where you find out by trying. One file that boots regardless is a product decision, and it is the main practical payoff of [[ADR-0003 - Limine as the Bootloader]]: Limine ships prebuilt BIOS stages *and* prebuilt EFI binaries, so both entries are a file copy rather than a build.

**Why not B.** It is not actually simpler where it counts. The hard part of UEFI booting is the ESP layout, and you still have to get that exactly right in option B — you have just also added artefact-management overhead, a second checksum line, and a support question. The `xorriso` incantation is copied once from Limine's README and then never touched.

**When B would be right.** If the two artefacts genuinely differ — a signed Secure Boot chain for UEFI and an unsigned one for BIOS, say — then forcing them into one file buys nothing and the shared command line becomes a liability. Post-1.0 Secure Boot support could flip this.

### Decision: ship an ISO, a GPT image, or both?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): both** | ISO for the dev loop and optical/Ventoy use; `.img` for USB, VMs and real hardware | Two build paths in `mkimage.sh`; the boot matrix doubles | ✅ |
| B: ISO only | One artefact, `-cdrom`, done | **Read-only root, forever.** Persistence can never be demonstrated | ❌ |
| C: `.img` only | One artefact, closest to how it ships | Slower dev loop; no Ventoy/optical path; `-cdrom` convenience lost | ❌ |

**Why A.** They are answers to different questions. The ISO answers "did my change boot?" in a couple of seconds with `-cdrom`. The `.img` answers "does the thing we ship work?" — it is the only artefact with a real partition table, a real ESP, and **a writable root partition**. The whole point of [[ADR-0009 - Filesystem Strategy FAT32 then ext2]] is that this OS persists data, and you cannot persist to ISO 9660.

**Why not B.** The failure is silent and late. Everything works for eight phases, then Phase 10 arrives, you implement ext2, and there is nowhere to mount it. Worse, you would have spent those eight phases building a boot path whose layout you now have to change, which means changing the release pipeline, the boot matrix, and every set of instructions you have written.

**Why not C.** Fidelity is not free. Building `os.img` runs `parted`, `mkfs.fat`, six `mcopy` calls, `mke2fs`, and two `dd`s over 322 MiB. Building the ISO runs one `xorriso`. When you are iterating on a kernel bug and rebuilding forty times an hour, that difference is the difference between staying in flow and not.

**When C would be right.** The moment the ISO and the image diverge behaviourally — a bug that reproduces on one and not the other — the ISO stops being a valid proxy and you should test what you ship. The boot matrix in `scripts/test.sh` exists precisely to catch that divergence, which is why CI runs `bios/iso`, `uefi/iso` and `uefi/img` rather than picking one.

### Decision: `mtools` + `parted`, or loop-mount the image?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): `mtools` + `parted` + `dd`** | Build each filesystem as a standalone file, populate it with `mmd`/`mcopy` which speak FAT directly, then `dd` it into the disk image at the right offset | Offsets must be computed by hand and kept consistent with `parted` | ✅ |
| B: `losetup` + `mount` | Attach the image to a loop device, mount the partitions, use `cp` | **Needs root and `--privileged`.** Does not work in an unprivileged container, and often not in CI at all | ❌ |
| C: `guestfish` / libguestfs | A whole VM-based appliance manipulates the image | Enormous dependency; slow start-up; needs KVM to be tolerable | ❌ |

**Why A.** This is the decisive constraint in the entire script, so it is worth stating flatly: **`mount` is a privileged operation.** `losetup` needs `CAP_SYS_ADMIN`, and so does mounting the resulting device. Inside the toolchain container that means `docker run --privileged`, which is a security posture nobody should accept for a build step and which many CI providers refuse outright. `mtools` implements FAT in userspace — `mcopy -i esp.img file ::/` opens `esp.img` as a regular file and writes FAT structures into it. No kernel involvement, no root, no capabilities. `mke2fs` and `mkfs.fat` do the same for their formats. The whole image build therefore runs as an ordinary user in an ordinary container, which is what makes [[10 - CI Pipeline]] possible at all.

**Why not B.** Beyond the privilege problem, it makes builds non-reproducible and machine-dependent: loop device numbers, whether `udev` has settled, whether a stale mount from a crashed earlier run is still attached. Half the "works on my machine" reports in image-building code come from loop mounts.

**When B would be right.** On a developer workstation, interactively, when you need to *inspect* an image rather than build one — `sudo mount -o loop,offset=$((1024*1024)) build/os.img /mnt` is a perfectly good way to look inside the ESP. Inspection is not the build, and only the build has to be unprivileged. (`mdir -i build/esp.img ::/` does the same thing without root, if the ESP image is still around.)

### Decision: which artefact does the day-to-day dev loop boot?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): ISO for `make run`, image for `make run-uefi`** | Fast BIOS loop by default; UEFI/image check on demand and in CI | You can drift: work all day on the ISO and only discover a UEFI break later | ✅ |
| B: image for everything | Every run is exactly what ships | ~10× the image build time on every iteration | ❌ |
| C: ISO for everything | Fastest possible loop | The GPT/ESP path is never exercised until release — the worst possible time to find out | ❌ |

**Why A.** Iteration speed and shipping fidelity are both real, and they are in tension only if you pretend one command must satisfy both. Two commands, each honest about what it is: `make run` is "did I break the kernel", `make run-uefi` is "did I break the boot path".

**Why not C.** The UEFI path has entirely different failure modes from the BIOS path — the fallback filename, the ESP type GUID, FAT32 cluster counts, the PE loader. None of them are exercised by `-cdrom` under SeaBIOS. Finding out on release day, on the one test laptop, is the definition of a bad time.

**The mitigation.** `make test-boot` runs the whole matrix — `bios/iso`, `uefi/iso`, `uefi/img`, and `uefi/img --smp 4` — and CI runs it on every push. The drift risk in option A is real but it is bounded by a machine that checks, not by your discipline.

### Decision: `-no-reboot -no-shutdown` on every QEMU invocation?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): always both** | A guest reset request stops the VM instead of performing it; QEMU stays alive and the monitor still works | You must remember to close QEMU yourself | ✅ |
| B: neither | Default QEMU behaviour: a triple fault resets the machine and it boots again | **Destroys the evidence.** The screen clears, the log restarts, and the symptom becomes an infinite loop | ❌ |
| C: `-no-reboot` only | QEMU exits on a reset instead of looping | Better than B, but the process is gone — you cannot open the monitor and look at the registers | ❌ |

**Why A.** An unhandled CPU exception in a kernel with no IDT ([[Phase 2 - Overview|Phase 2]] fixes that) becomes a double fault, and an unhandled double fault becomes a **triple fault**, which is not an exception at all — it is the CPU giving up and asserting reset. On real hardware the machine reboots. In QEMU, by default, the VM reboots. You see the firmware splash again, and the only observable symptom is that it keeps happening.

`-no-reboot` intercepts the reset and turns it into a shutdown request. `-no-shutdown` intercepts *that* and stops emulation without exiting the process. Together they freeze the machine at the moment it died with the monitor still attached, so `info registers` shows you the state and `-D` still holds the log. This turns "it reboots forever" into "it stopped, here is where."

**Why not B.** In CI it is worse than losing information — the run does not fail, it *hangs*, and ninety seconds later `timeout` kills it. Your entire diagnostic is the string `TIMEOUT after 90s`. That is why the flags are hardcoded in `scripts/test.sh`'s `qemu_args()` with a comment saying they are not optional, and in every `run*` target in the `Makefile`.

**When B would be right.** Only when a reboot is the thing under test — a warm-reset path, or `scripts/test.sh shutdown`, which deliberately omits `-no-shutdown` because a successful ACPI power-off *is* the assertion. Note that even that case keeps `-no-reboot`.

### Decision: verify the first boot through the QEMU monitor, or write serial output first?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): monitor now, serial in 0.6** | The kernel only halts; you inspect `RIP` from outside the guest | You must learn the monitor, and the "success" signal is a black screen | ✅ |
| B: serial driver first, then boot | The kernel prints on entry; "it printed" is the proof | If nothing prints, three unverified stages are suspects at once | ❌ |

**Why A.** The monitor is an **external** observer. It does not depend on any code you wrote being correct — not the UART init, not the DLAB sequence, not `\r\n` translation, not the QEMU `-serial` plumbing. It reads the emulated CPU's actual register file. When it says `RIP=ffffffff8000102a` and `HLT=1`, the only possible explanation is that Limine loaded your kernel at its link address and the processor executed your `hlt`. There is no way for that to be a false positive.

**Why not B.** Consider the failure. You add serial, build an image, run it, see nothing. Which is broken?

1. the image (kernel not staged, wrong path in `limine.conf`, `bios-install` skipped),
2. the linker script (wrong load address, `.limine_requests` dropped),
3. the UART code (DLAB left set, transmit-ready bit not polled),
4. the QEMU invocation (`-serial` missing, output going to a window you are not looking at).

Four suspects, one symptom, no evidence. Now consider the ordering we use: 0.5 fails → the image or the linker script, and the monitor tells you which within thirty seconds. 0.5 passed and 0.6 fails → it is the UART or the QEMU flags, and the kernel is definitively fine. **Each stage changes one thing, so each failure has one class of cause.** That is the entire argument, and it is written into [[Phase 0 - Overview]] as a note on ordering.

**When B would be right.** On the *second* OS you build, on hardware you have booted before, with an image build you have already validated. Then serial-first is faster because the boot chain is not actually in question. It is in question here.

---

## 4. Specification

### The two firmware handoffs

| | Legacy BIOS | UEFI |
|---|---|---|
| Where firmware looks | LBA 0 of the device (`0x55AA` at offset 510), or the El Torito catalogue on optical media | GPT partition with type GUID `C12A7328-F81F-11D2-BA4B-00A0C93EC93B` |
| Filesystem it can read | none — raw sectors only | FAT12 / FAT16 / FAT32 |
| What it loads | 512 bytes (MBR) or N × 512 bytes (El Torito no-emulation) | a PE32+ file, any size |
| Fixed path | none | `\EFI\BOOT\BOOTX64.EFI` (x86_64 removable fallback) |
| CPU mode at handoff | 16-bit real mode, `CS:IP` = `0000:7C00` | 64-bit long mode, identity-mapped, boot services live |
| Our file | `limine-bios-cd.bin` (ISO), boot record via `limine bios-install` (disk) | `BOOTX64.EFI` |

### El Torito, as used here

| Field | Value here | Meaning |
|---|---|---|
| BIOS entry platform ID | `0x00` | 80x86 |
| UEFI entry platform ID | `0xEF` | UEFI |
| Emulation | none (`-no-emul-boot`) | load raw sectors, no floppy/HDD pretence |
| Boot load size | `4` (`-boot-load-size 4`) | 4 × 512-byte *virtual* sectors = 2048 bytes = one CD sector |
| Boot info table | present (`-boot-info-table`) | 56 bytes patched into the boot image at byte offset 8: PVD LBA, boot-file LBA, boot-file length, checksum. The stage uses it to locate itself and the rest of the disc |
| UEFI boot image | `limine-uefi-cd.bin` | a FAT image; firmware mounts it and runs `/EFI/BOOT/BOOTX64.EFI` from inside it |

### `os.img` layout — exact offsets

Produced by `build_img()` with the defaults `ESP_MB=64`, `ROOT_MB=256`.

| Region | Byte offset | Size | Contents |
|---|---|---|---|
| Protective MBR | `0` | 512 B | one partition entry, type `0xEE`, covering the disk |
| GPT header | `512` | 512 B | LBA 1 |
| Partition entries | `1024` | 16 KiB | 128 entries × 128 B, LBA 2–33 |
| Gap | `~17 KiB` | ~1007 KiB | free; `limine bios-install` embeds stage 2 here |
| **Partition 1 — ESP** | `1 MiB` (`1048576`) | 64 MiB | FAT32, label `OSBOOT`, type GUID `C12A7328-…` |
| **Partition 2 — root** | `65 MiB` (`68157440`) | 256 MiB written into 257 MiB | ext2, 1024-byte blocks, label `OSROOT` |
| Backup GPT | last 33 sectors | ~17 KiB | mirror of the primary |
| **Total** | | **322 MiB** | `ESP_MB + ROOT_MB + 2` |

The `+ 2` is not padding for luck. One MiB goes at the front for GPT plus alignment, and roughly one MiB is left at the end so the backup GPT has somewhere to live. Remove it and `parted` cannot place the backup header.

### `xorriso -as mkisofs` flags, in the order they appear

| Flag | Effect | What breaks without it |
|---|---|---|
| `-R` | Rock Ridge extensions | filenames get mangled to 8.3 uppercase; `kernel.elf` becomes `KERNEL.ELF;1` and Limine cannot open `boot():/kernel.elf` |
| `-r` | Rock Ridge with rationalised ownership — uid/gid 0, sane modes | files carry the build user's uid; breaks reproducibility |
| `-J` | Joliet extensions | long filenames unreadable when the disc is mounted on Windows; cosmetic for boot, useful for inspection |
| `-b limine-bios-cd.bin` | names the El Torito **BIOS** boot image, path relative to the staging root | no BIOS entry in the catalogue; BIOS firmware sees a non-bootable disc |
| `-no-emul-boot` | no-emulation mode for that entry | BIOS tries floppy emulation and fails |
| `-boot-load-size 4` | load 2048 bytes | too few sectors loaded; the stage runs off the end of what was read |
| `-boot-info-table` | patch the 56-byte table at offset 8 | `limine-bios-cd.bin` cannot locate the disc's PVD; boot fails after the jump |
| `-hfsplus` | add an HFS+ filesystem alongside ISO 9660 | some Intel-Mac firmware will not boot the disc |
| `-apm-block-size 2048` | Apple Partition Map block size, matching the CD sector size | HFS+ present but unusable by Apple firmware |
| `--efi-boot limine-uefi-cd.bin` | adds a **second** catalogue entry, platform `0xEF`, pointing at the FAT image | no UEFI entry; UEFI firmware ignores the disc |
| `-efi-boot-part --efi-boot-image` | register the already-added EFI boot image as a real partition in the image's partition table | the ISO boots as a CD under UEFI but not when `dd`'d to a USB stick |
| `--protective-msdos-label` | write a protective MBR at LBA 0 | tools and firmware may treat the raw device as unpartitioned |
| `"$STAGE" -o "$BUILD_DIR/os.iso"` | source tree, output file | — |

You will see `-isohybrid-gpt-basdat` in older Limine instructions and on a lot of OSDev pages. It solves the same problem — making the embedded EFI image visible as a partition to firmware reading the raw device — by tagging it as a GPT partition of type "Basic Data". The `-efi-boot-part --efi-boot-image` pair used here is Limine's current recommendation and registers it as a proper EFI System Partition instead. Do not mix the two; consult `man xorriso` if you need to change either.

### QEMU flags used for verification

| Flag | Why |
|---|---|
| `-cdrom build/os.iso` | attach as an IDE optical device; triggers the El Torito path under SeaBIOS |
| `-drive format=raw,file=build/os.img` | attach as a hard disk; `format=raw` silences QEMU's format-probe warning |
| `-bios /usr/share/OVMF/OVMF_CODE_4M.fd` | replace SeaBIOS with UEFI firmware. **Ubuntu 24.04 path — not `OVMF_CODE.fd`** |
| `-m 512M` | RAM |
| `-smp 1` | one CPU. SMP is [[Phase 12 - Overview\|Phase 12]]; more cores now only adds noise |
| `-serial stdio` | UART to your terminal. Produces nothing until Stage 0.6 — Limine's own `serial: yes` output arrives here |
| `-no-reboot -no-shutdown` | freeze on fault instead of rebooting. See §3 |
| `-d int,cpu_reset -D build/qemu.log` | diagnostic only: log exceptions and dump CPU state at reset. This is how you confirm a triple fault |

### QEMU monitor commands you need

| Keys / command | Effect |
|---|---|
| `Ctrl-Alt-2` | switch the QEMU window to the monitor console |
| `Ctrl-Alt-1` | switch back to the guest display |
| `info registers` | full CPU state: `RIP`, `CPL`, `HLT`, `CR0`–`CR4`, segment descriptors |
| `info status` | `running` or `paused` — a paused VM after `-no-reboot -no-shutdown` means it faulted |
| `x /8i <address>` | disassemble 8 instructions at a **literal** address (paste the `RIP` value from `info registers`) |
| `info mem` | active page-table mappings — useful from [[Phase 4 - Overview\|Phase 4]] onward |
| `quit` | exit QEMU |

---

## 5. Writing the code

Both files already exist in the scaffold. Neither is code you write in this stage — they are code you must be able to read, because when the boot fails these are the two files you will be staring at.

### `boot/limine.conf`

The bootloader's configuration: which entries appear in the menu, and for each, what to load and how.

```ini
# Limine boot configuration. See ADR-0003.
#
# Paths are relative to the boot volume root: the ISO root, or the ESP on the
# GPT image. scripts/mkimage.sh stages them there.

timeout: 3
default_entry: 1

# Serial output from the bootloader itself. Invaluable when the kernel never
# gets far enough to initialise its own serial port.
serial: yes

interface_branding: CRACKED-F OS

/CRACKED-F OS
    protocol: limine
    kernel_path: boot():/kernel.elf
    module_path: boot():/initrd.tar
    # Ask for a specific mode; Limine falls back to the best available.
    # The framebuffer is the ONLY console path — there is no VGA text mode
    # anywhere in this OS. See ADR-0004.
    resolution: 1280x800x32

/CRACKED-F OS (verbose)
    protocol: limine
    kernel_path: boot():/kernel.elf
    module_path: boot():/initrd.tar
    resolution: 1280x800x32
    kernel_cmdline: loglevel=debug

/CRACKED-F OS (single core)
    protocol: limine
    kernel_path: boot():/kernel.elf
    module_path: boot():/initrd.tar
    resolution: 1280x800x32
    # Useful for deciding whether a bug is an SMP race (Phase 12) or not.
    kernel_cmdline: nosmp

/CRACKED-F OS (self-test)
    protocol: limine
    kernel_path: boot():/kernel-test.elf
    module_path: boot():/initrd.tar
    # Tier 2 build: runs in-kernel assertions and reports through the QEMU
    # isa-debug-exit device. ADR-0010.
    kernel_cmdline: selftest=all
```

#### Line by line

**Lines 6–7 — the menu's behaviour**
```ini
timeout: 3
default_entry: 1
```
`timeout` is seconds. The menu appears, counts down from 3, and boots `default_entry`. Set it to `0` and the menu never appears — the default entry boots immediately, which is right for CI and wrong while you are developing, because three seconds is how long you have to notice that Limine printed an error before the screen changes. Limine also supports disabling the automatic boot entirely so it waits for a keypress; check `CONFIG.md` in the Limine repository for the exact keyword, and do not guess at it.

`default_entry` is **1-based**. `1` selects the first entry, `/CRACKED-F OS`. This matters right now: entry 4 loads `kernel-test.elf`, which does not exist yet, and if the indexing were 0-based you would be booting entry 2 without realising it.

**Line 11 — bootloader serial**
```ini
serial: yes
```
Limine mirrors its own terminal output to the serial port. Read that again, because it is the single most useful line in the file during Phase 0: **this is output from the bootloader, produced entirely before your kernel runs.** If `kernel_path` is wrong, if the ELF is malformed, if a protocol revision is unsupported, Limine says so — and with `serial: yes` plus `-serial stdio` it says so *in your terminal*, where you can copy it, rather than on a screen that is about to be replaced by a black framebuffer.

This is why `make run` is worth using rather than a bare `qemu-system-x86_64` even before you have written a UART driver. Delete this line and a bad `kernel_path` becomes a black screen instead of a sentence.

**Line 13 — cosmetic**
```ini
interface_branding: CRACKED-F OS
```
The string Limine shows in its menu chrome. No functional effect. It is worth setting anyway: it is the first visual confirmation that the `limine.conf` being read is *yours*, and not a stale copy left over on the boot volume from an earlier build.

**Lines 15–22 — the default entry**
```ini
/CRACKED-F OS
    protocol: limine
    kernel_path: boot():/kernel.elf
    module_path: boot():/initrd.tar
    resolution: 1280x800x32
```
A single leading `/` starts a top-level menu entry; the text after it is the label. (Two slashes would nest an entry inside a submenu.) Indented `key: value` lines belong to the entry.

`protocol: limine` selects the Limine boot protocol — the request/response model from [[Stage 0.2 - The Limine Request Section]]. The alternatives Limine offers are `linux`, `multiboot1`, `multiboot2`, and chainloading. Set this to `multiboot2` by mistake and Limine will look for a Multiboot header your kernel does not have, and refuse to boot it.

`kernel_path: boot():/kernel.elf` is a Limine URI. `boot()` means "the volume Limine itself was loaded from" — resolved at runtime, so the *same* config string works on the ISO (where it is the ISO 9660 root) and on `os.img` (where it is the FAT32 ESP). That is not a small convenience: it is what lets one `limine.conf` be staged unmodified into two completely different filesystems. Limine also accepts `guid(...)`, `uuid(...)` and `fslabel(...)` forms for loading from a volume other than the boot one.

The `/kernel.elf` half is a path **on the boot volume**, not a path in your repo and not a path in `build/`. `mkimage.sh` copies `build/kernel.elf` to the root of the staging tree, so on the volume it is `/kernel.elf`. Confusing the staging path with the volume path is the most common single mistake in this stage — see §7.

`module_path: boot():/initrd.tar` hands Limine a file to load into memory and report through the module request. Your kernel does nothing with it until [[Phase 7 - Overview|Phase 7]], but the file must exist now or Limine errors during load. This is why the checklist has you create a stub `initrd.tar`.

`resolution: 1280x800x32` requests width × height × bits-per-pixel. It is a **request**: if the firmware cannot provide that mode Limine picks the best available and reports whatever it actually got in the framebuffer response. Never hardcode 1280×800 anywhere in the kernel — read the response. Under [[ADR-0004 - Framebuffer Console Not VGA Text]] the framebuffer is the only display path in the system, so this is the only place a display mode is ever chosen.

**Lines 24–29 — the verbose entry**
```ini
/CRACKED-F OS (verbose)
    ...
    kernel_cmdline: loglevel=debug
```
Identical to the default except for `kernel_cmdline`, a string handed to the kernel through the boot protocol. (Look up the exact request and field name in the pinned `limine.h` — the kernel-file/executable-file response carries it, and the naming changed across Limine versions.) Nothing parses it yet; the log-level machinery arrives with the ring buffer in [[Phase 1 - Overview|Phase 1]].

The entry exists now, empty, on purpose. Adding a debug boot option is a two-minute job today and a twenty-minute interruption on the day you actually need it, which will be a day you are already annoyed.

**Lines 31–37 — the single-core entry**
```ini
/CRACKED-F OS (single core)
    ...
    kernel_cmdline: nosmp
```
Limine starts the application processors for you and parks them in a callback ([[ADR-0003 - Limine as the Bootloader]]). From [[Phase 12 - Overview|Phase 12]] onward, `nosmp` is the fastest available triage step for a class of bug that is otherwise very expensive: boot single-core, and if the fault disappears it is a race, not a logic error. That halves the search space in one reboot.

**Lines 39–45 — the self-test entry**
```ini
/CRACKED-F OS (self-test)
    kernel_path: boot():/kernel-test.elf
    ...
    kernel_cmdline: selftest=all
```
A **different kernel binary**: the Tier 2 build described in [[09 - Testing Strategy]] and [[ADR-0010 - Testing Strategy and the QEMU Exit Device]], which runs in-kernel assertions and reports the result by writing to QEMU's `isa-debug-exit` device at port `0xF4`.

`kernel-test.elf` does not exist yet, and `mkimage.sh` does not stage it. **Selecting this entry today will fail** with a file-not-found from Limine. That is expected and harmless — do not "fix" it by deleting the entry.

---

### `scripts/mkimage.sh`

Turns `build/kernel.elf` plus `build/initrd.tar` plus `boot/limine.conf` into bootable artefacts. Runs inside the toolchain container, unprivileged.

#### Lines 11–27 — preamble

```bash
set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
STAGE="${BUILD_DIR}/stage"
LIMINE_DIR="${LIMINE_DIR:-/opt/limine}"

KERNEL="${BUILD_DIR}/kernel.elf"
INITRD="${BUILD_DIR}/initrd.tar"

ESP_MB="${ESP_MB:-64}"
ROOT_MB="${ROOT_MB:-256}"

die() { echo "error: $*" >&2; exit 1; }

require() {
  [[ -f "$1" ]] || die "missing $1 — run 'make' first"
}
```

`set -Eeuo pipefail` is not decoration in a script that writes disk images. `-e` aborts on the first failing command; without it a failed `mkfs.fat` is followed by six `mcopy` calls into an unformatted image, and you get an `os.img` that exists, is the right size, and does not boot. `-u` catches typo'd variable names, which in this script would expand to an empty path and `dd` to the wrong offset. `-o pipefail` makes a failure anywhere in a pipeline fail the pipeline. `-E` propagates traps into functions.

`LIMINE_DIR` defaults to `/opt/limine`, which is where the `toolchain/Dockerfile` clones the pinned `v8.6.0-binary` tag and runs `make` to produce the `limine` deploy tool. The `${VAR:-default}` form throughout means CI or a local experiment can override any of these without editing the script.

`require` exists so the failure message is `missing build/kernel.elf — run 'make' first` rather than forty lines of xorriso complaining about an empty directory.

#### Lines 35–56 — `stage_common`

```bash
stage_common() {
  require "$KERNEL"
  require "$INITRD"
  require "boot/limine.conf"

  rm -rf "$STAGE"
  mkdir -p "$STAGE/EFI/BOOT"

  cp "$KERNEL"            "$STAGE/kernel.elf"
  cp "$INITRD"            "$STAGE/initrd.tar"
  cp boot/limine.conf     "$STAGE/limine.conf"

  # UEFI: firmware looks for the removable-media fallback path.
  cp "$LIMINE_DIR/BOOTX64.EFI"  "$STAGE/EFI/BOOT/BOOTX64.EFI"
  [[ -f "$LIMINE_DIR/BOOTIA32.EFI" ]] && cp "$LIMINE_DIR/BOOTIA32.EFI" "$STAGE/EFI/BOOT/BOOTIA32.EFI"

  # BIOS stages.
  cp "$LIMINE_DIR/limine-bios.sys"     "$STAGE/" 2>/dev/null || true
  cp "$LIMINE_DIR/limine-bios-cd.bin"  "$STAGE/" 2>/dev/null || true
  cp "$LIMINE_DIR/limine-uefi-cd.bin"  "$STAGE/" 2>/dev/null || true
}
```

**`rm -rf "$STAGE"` first.** The staging tree is rebuilt from nothing every time, never updated in place. If it were incremental, a file you renamed or deleted in the repo would linger on the boot volume — and a stale `kernel.elf` that still boots is the worst possible debugging experience, because your changes appear to have no effect. Always rebuild the tree.

**Everything lands at the volume root.** `kernel.elf`, `initrd.tar` and `limine.conf` go to `$STAGE/`, which becomes `/` on the ISO and `::/` on the ESP. That is what makes `boot():/kernel.elf` in the config resolve. Limine searches a small set of locations on the boot volume for `limine.conf`; the root is one of them, and it is the simplest. If you decide to move things into a `/boot/` subdirectory, **every path in `limine.conf` must change with it** — they are two halves of the same contract.

**`$STAGE/EFI/BOOT/BOOTX64.EFI`.** Exactly the removable-media fallback path from §2.3. The capitalisation matters on FAT in principle and costs nothing to get right; copy it verbatim.

`BOOTIA32.EFI` is guarded with `[[ -f ... ]] &&` because 32-bit UEFI firmware is rare — some older Atom tablets and netbooks shipped it — but including the file costs a few hundred kilobytes and buys a class of machine you would otherwise be unable to boot.

**The three BIOS files.** `limine-bios-cd.bin` is the El Torito no-emulation stage. `limine-uefi-cd.bin` is the FAT image for the UEFI El Torito entry. `limine-bios.sys` is the BIOS second stage, loaded off the filesystem by whichever first stage ran — from the MBR boot record on a disk, or from the CD stage on optical media.

The `2>/dev/null || true` on those three lines is a deliberate trade and a small trap. It lets the script work with a Limine build that lacks BIOS support (a UEFI-only build). The cost is that a genuinely missing `limine-bios-cd.bin` is not reported here — it surfaces later as a confusing `xorriso` error about a boot image it cannot find. If `build_iso` fails oddly, check `ls $LIMINE_DIR` first.

**A note on the staged `EFI/BOOT/` in the ISO.** The ISO's UEFI El Torito entry does *not* read the ISO's own `/EFI/BOOT/` — it reads the FAT filesystem *inside* `limine-uefi-cd.bin`, which already contains its own copy of `BOOTX64.EFI`. The staged copy is there because `build_img` reuses the same tree, where it is essential. Harmless duplication, and worth understanding so you do not go looking for the wrong file when the ISO fails under UEFI.

#### Lines 65–84 — `build_iso`

```bash
build_iso() {
  stage_common
  echo ">> building ${BUILD_DIR}/os.iso"

  xorriso -as mkisofs \
      -R -r -J \
      -b limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
      -hfsplus \
      -apm-block-size 2048 \
      --efi-boot limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image \
        --protective-msdos-label \
      "$STAGE" -o "${BUILD_DIR}/os.iso"

  "$LIMINE_DIR/limine" bios-install "${BUILD_DIR}/os.iso"

  echo "   $(du -h "${BUILD_DIR}/os.iso" | cut -f1)"
}
```

`xorriso -as mkisofs` puts xorriso into `mkisofs` compatibility mode, so it accepts the classic flag vocabulary. Every flag is explained in the table in §4; the two things to internalise are that **`-b` and `--efi-boot` create the two boot catalogue entries** (BIOS and UEFI respectively), and that **their arguments are paths relative to `$STAGE`**, not to your working directory.

`-boot-load-size 4` deserves one more sentence because the units are a trap: El Torito counts in 512-byte *virtual* sectors even on media whose real sectors are 2048 bytes. Four of them is one physical CD sector. That is the standard value; `limine-bios-cd.bin` is larger than 2 KiB, and it uses the boot info table patched in by `-boot-info-table` to find and load the rest of itself.

**`limine bios-install` is not optional, and it is not what you think.** After xorriso finishes, the ISO boots under BIOS *as a CD* (El Torito) and under UEFI (El Torito EFI entry, or the GPT entry created by `-efi-boot-part`). What it does **not** yet do is boot under BIOS from a USB stick — because when the firmware sees a USB mass-storage device it reads LBA 0 as an MBR and never looks at the El Torito catalogue at all. `limine bios-install` writes Limine's BIOS boot record into that first sector and patches in the location of the second stage. This is the line that completes the fourth boot path in the diagram in §2.4.

Because it is a separate command after xorriso, it is also the easiest thing in the script to lose in a refactor. Its symptom is very specific and very confusing — see §7.

#### Lines 95–113 — `build_img`, partitioning

```bash
build_img() {
  stage_common
  local img="${BUILD_DIR}/os.img"
  local total=$(( ESP_MB + ROOT_MB + 2 ))

  echo ">> building ${img} (${total} MiB)"
  rm -f "$img"
  truncate -s "${total}M" "$img"

  parted -s "$img" \
      mklabel gpt \
      mkpart ESP  fat32 1MiB "$(( ESP_MB + 1 ))MiB" \
      set 1 esp on \
      mkpart root ext2  "$(( ESP_MB + 1 ))MiB" 100%

  local esp_off=$(( 1024 * 1024 ))
  local esp_size=$(( ESP_MB * 1024 * 1024 ))
  local root_off=$(( esp_off + esp_size ))
```

`truncate -s 322M` creates a **sparse** file: the directory entry says 322 MiB, but no blocks are allocated until something is written. Building the image therefore costs almost no disk I/O for the regions nothing touches. GNU `truncate` reads `M` as MiB (`MB` would be 10⁶), which matters because `parted` is being given `MiB` units and the two must agree.

`parted -s` is `--script` — no interactive confirmations, which is mandatory in a build script and in CI.

`mklabel gpt` writes the protective MBR, the primary GPT at LBA 1–33, and the backup GPT at the end of the file.

`mkpart ESP fat32 1MiB 65MiB` creates partition 1 spanning [1 MiB, 65 MiB) — 64 MiB, matching `ESP_MB`. **The `fat32` argument does not format anything.** It is a filesystem-type hint that influences the partition's type field; the actual FAT32 is created twenty lines later by `mkfs.fat`. People lose real time to this: `parted` said `fat32`, so surely there is a filesystem? There is not.

Starting at 1 MiB rather than immediately after the GPT is the universal modern convention. It leaves room for the GPT plus the embedded BIOS stage, and it aligns the partition to any plausible flash erase-block boundary, which matters for write endurance and performance on the USB stick this eventually lands on.

`set 1 esp on` sets partition 1's type GUID to `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`. This is the flag that makes UEFI firmware look inside it. Without it you have a FAT32 partition with the correct files that no firmware will ever open — and the symptom is a UEFI shell prompt, indistinguishable from having put `BOOTX64.EFI` in the wrong place.

`mkpart root ext2 65MiB 100%` takes everything to the end. With `total = 322`, that is 257 MiB of partition for a 256 MiB filesystem, leaving room for the backup GPT.

The three `local` offset variables restate the geometry in bytes, for `dd`. **They duplicate the numbers given to `parted`, and nothing checks that the two agree.** That is the sharpest edge in this script: change `1MiB` in the `parted` line without changing `esp_off`, and you will `dd` a perfectly good FAT32 filesystem somewhere that is not where the partition table says the partition is. Everything succeeds; nothing boots.

#### Lines 115–130 — the ESP

```bash
  local esp="${BUILD_DIR}/esp.img"
  rm -f "$esp"
  truncate -s "${ESP_MB}M" "$esp"
  mkfs.fat -F 32 -n "OSBOOT" "$esp" >/dev/null

  mmd   -i "$esp" ::/EFI ::/EFI/BOOT
  mcopy -i "$esp" "$STAGE/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
  [[ -f "$STAGE/EFI/BOOT/BOOTIA32.EFI" ]] && mcopy -i "$esp" "$STAGE/EFI/BOOT/BOOTIA32.EFI" ::/EFI/BOOT/
  mcopy -i "$esp" "$STAGE/kernel.elf"   ::/
  mcopy -i "$esp" "$STAGE/initrd.tar"   ::/
  mcopy -i "$esp" "$STAGE/limine.conf"  ::/
  [[ -f "$STAGE/limine-bios.sys" ]] && mcopy -i "$esp" "$STAGE/limine-bios.sys" ::/

  dd if="$esp" of="$img" bs=1M seek=1 conv=notrunc status=none
  rm -f "$esp"
```

The ESP is built **as a standalone 64 MiB file**, formatted, populated, and only then copied into the disk image at the right offset. That indirection is the whole unprivileged-build trick: `mkfs.fat` and `mtools` operate on a plain file, so no loop device and no `mount` is ever needed.

`mkfs.fat -F 32` forces FAT32 rather than letting `mkfs.fat` choose by size. Forcing it matters because **FAT32 has a floor**: the format requires more than 65 524 clusters, and at 512 bytes per cluster that is roughly 32 MiB. A 64 MiB ESP clears it comfortably. Shrink `ESP_MB` below about 33 and `mkfs.fat -F 32` will refuse or produce a filesystem that real firmware rejects. `-n "OSBOOT"` sets the volume label, which is how you identify the partition in `parted print` output and in a file manager when the stick is plugged into a normal machine.

`mmd -i "$esp" ::/EFI ::/EFI/BOOT` creates the two directories. The `::` prefix is mtools' notation for "the image named by `-i`", as opposed to a configured drive letter. `::/EFI/BOOT` is an absolute path inside that image.

The `mcopy` calls place, in order: the UEFI bootloader at the fallback path, the optional 32-bit one, and then `kernel.elf`, `initrd.tar` and `limine.conf` at the ESP root — which is what `boot():/kernel.elf` resolves to when Limine was loaded from this partition.

`limine-bios.sys` goes on the ESP too, guarded. That looks odd — a BIOS file on an EFI System Partition — and it is deliberate: when this image is booted on a legacy-BIOS machine, the boot record installed at the end of `build_img` needs to load the second stage from *some* filesystem it can read, and FAT32 is one Limine can read. Without it the BIOS path on `os.img` gets as far as the MBR and stops.

`dd if="$esp" of="$img" bs=1M seek=1 conv=notrunc` writes the finished filesystem 1 MiB into the disk image. **`conv=notrunc` is load-bearing.** By default `dd` truncates its output file at the end of what it wrote — which would leave you with a 65 MiB `os.img` containing an ESP, no root partition, and no backup GPT. The image would still look plausible. `status=none` just keeps the build log clean.

#### Lines 132–146 — the root filesystem and the boot record

```bash
  local root="${BUILD_DIR}/root.img"
  rm -f "$root"
  truncate -s "${ROOT_MB}M" "$root"
  # -F: it is a file, not a block device. -b 1024: matches our ext2 driver's
  # first supported block size (Phase 10).
  mke2fs -q -t ext2 -b 1024 -F -L "OSROOT" "$root"
  dd if="$root" of="$img" bs=1M seek=$(( root_off / 1024 / 1024 )) conv=notrunc status=none
  rm -f "$root"

  "$LIMINE_DIR/limine" bios-install "$img" 2>/dev/null || \
      echo "   (note: BIOS install skipped — image is UEFI-only)"
```

Same pattern: build the filesystem as a file, `dd` it into place. `seek=$(( root_off / 1024 / 1024 ))` evaluates to 65, matching the `parted` start of partition 2.

`-F` tells `mke2fs` to proceed on something that is not a block device — without it, it refuses to format a regular file.

**`-b 1024` is the interesting flag.** ext2's superblock always lives at byte offset 1024 from the start of the filesystem, regardless of block size. With 1024-byte blocks that means the superblock *is* block 1: block 0 is the boot block, block 1 is the superblock, block 2 begins the block group descriptor table. Every structure sits on a block boundary you can compute with a shift. With 4096-byte blocks the superblock is instead embedded at offset 1024 *inside* block 0, and the descriptor table moves to block 1, and every worked example you read has to specify which case it is describing. When you write the ext2 driver in [[Phase 10 - Overview|Phase 10]], reading a filesystem whose block size is 1024 removes an entire category of off-by-one. Block groups are 8 × block_size blocks each, so 1024-byte blocks give 8 MiB groups: 32 of them across this 256 MiB partition.

The partition is **empty**. That is fine. It exists so the layout is final now, and so there is something to mount the first time [[Phase 9 - Overview|Phase 9]] and [[Phase 10 - Overview|Phase 10]] have a block driver and a filesystem.

`limine bios-install "$img"` writes the BIOS boot record into LBA 0 and embeds the intermediate stage in the free space between the GPT and the 1 MiB partition start — which is exactly why the partition starts at 1 MiB rather than at LBA 34. The `2>/dev/null || echo "(note: ...)"` makes a failure here non-fatal, because a UEFI-only image is still a perfectly useful image. Read the build output: if you see that note and you *wanted* BIOS boot from this image, something is wrong, and swallowing stderr means you will have to re-run the command by hand without the redirect to find out what.

---

## 6. How to verify

This is the part of the stage that has no shortcuts. **Your kernel produces no output.** The only evidence available is the state of the emulated CPU, read from outside the guest. Follow the sequence exactly.

### Step 0 — the stub initrd (automatic)

`limine.conf` names `initrd.tar` as a module, so the file must exist or Limine
errors while loading the boot entry. Nothing builds one until
[[Phase 7 - Overview|Phase 7]], so `stage_common` creates an empty archive for you
and says so:

```
>> note: build/initrd.tar not built yet — staging an empty placeholder (Phase 7 replaces it)
```

Ten kilobytes of nulls is a valid tar archive. Limine loads it as a module and your
kernel ignores it until Phase 7 gives it a real one. Nothing for you to do here —
just recognise the line when it appears.

### Step 1 — build both artefacts

```sh
make iso
make img
```

Expected, roughly:

```
>> building build/os.iso
   4.2M
>> building build/os.img (322 MiB)
   322M
```

If the ISO build printed nothing between `>> building` and the size, `limine bios-install` succeeded silently — that is correct. If the image build printed `(note: BIOS install skipped — image is UEFI-only)`, note it and continue; the UEFI test below will still pass.

### Step 2 — inspect the artefacts before booting them

Thirty seconds here saves twenty minutes of guessing at a black screen.

```sh
xorriso -indev build/os.iso -toc
```

Look for two El Torito entries in the boot catalogue, one BIOS and one UEFI-platform.

```sh
parted build/os.img print
```

Expected:

```
Model:  (file)
Disk build/os.img: 338MB
Sector size (logical/physical): 512B/512B
Partition Table: gpt

Number  Start   End    Size   File system  Name  Flags
 1      1049kB  68.2MB 67.1MB fat32        ESP   boot, esp
 2      68.2MB  337MB  269MB  ext2         root
```

The `esp` flag on partition 1 is the thing to check. Missing, and UEFI will not look inside it.

```sh
mdir -i build/esp.img ::/ 2>/dev/null || true   # only if you kept the intermediate
file build/os.iso
```

`file build/os.iso` should report an ISO 9660 image with a boot sector, and mention DOS/MBR data — that MBR is what `limine bios-install` wrote.

### Step 3 — BIOS boot, from the ISO

```sh
make run
```

which runs:

```
qemu-system-x86_64 -cdrom build/os.iso -m 512M -smp 1 \
    -serial stdio -no-reboot -no-shutdown
```

**What you should see, in order:**

1. The SeaBIOS splash for a moment.
2. **Limine's boot menu**, branded `CRACKED-F OS`, with four entries and a countdown from 3.
3. The menu disappears and **the screen goes black.**

**The black screen is success.** Limine set the 1280×800 framebuffer, handed control to `kmain`, and `kmain` executed `hlt`. Nothing draws to that framebuffer because nothing in your kernel knows how yet — that is [[Phase 1 - Overview|Phase 1]]. There is no message, no cursor, no output of any kind. Do not "fix" it.

Reaching the menu already proves a great deal: firmware found the disc, El Torito loaded `limine-bios-cd.bin`, that loaded `limine-bios.sys`, and Limine found and parsed your `limine.conf`. Everything up to and including the config file is verified by the menu appearing. What the menu does *not* prove is that your kernel was loaded or ran. That is the next step.

### Step 4 — the proof: `info registers`

In the QEMU window press **`Ctrl-Alt-2`**. The display switches to the QEMU monitor, a `(qemu)` prompt. Type:

```
(qemu) info registers
```

You will get something close to this. Exact values differ; the fields that matter are called out below.

```
RAX=0000000000000000 RBX=0000000000000000 RCX=0000000000000000 RDX=0000000000000000
RSI=0000000000000000 RDI=0000000000000000 RBP=0000000000000000 RSP=ffffffff80010000
R8 =0000000000000000 R9 =0000000000000000 R10=0000000000000000 R11=0000000000000000
R12=0000000000000000 R13=0000000000000000 R14=0000000000000000 R15=0000000000000000
RIP=ffffffff8000102a RFL=00000002 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=1
ES =0030 0000000000000000 ffffffff 00c09300 DPL=0 DS   [-WA]
CS =0028 0000000000000000 ffffffff 00a09b00 DPL=0 CS64 [-RA]
...
CR0=80010011 CR2=0000000000000000 CR3=0000000000200000 CR4=00000020
```

Read four things, in this order:

| Field | Wanted | Meaning |
|---|---|---|
| `RIP=ffffffff8000102a` | **starts `ffffffff80`** | The instruction pointer is inside your kernel's higher-half image, at the base from [[Stage 0.4 - The Linker Script and Higher-Half Layout]]. Nothing else in the machine lives at that address |
| `HLT=1` | `1` | The CPU is in halt state. Your `hlt` executed |
| `CPL=0` | `0` | Ring 0. Still kernel mode; nothing has tried to drop privilege |
| `CS =… CS64` | `CS64` | The code segment is a 64-bit long-mode segment. Limine's promise, kept |

`CR0=80010011` has bit 31 set (`PG`, paging on) and bit 0 set (`PE`, protected mode), and `CR4=00000020` has bit 5 set (`PAE`) — the long-mode configuration Limine established before jumping to you.

### Step 5 — run it a second time

```
(qemu) info registers
```

**`RIP` must be the same value.** This is the step people skip and it is the one that makes the verification airtight. A single sample tells you the CPU was at a kernel address at one instant; it does not distinguish "parked in your halt loop" from "passing through your code on the way to a fault". Two identical samples, seconds apart, with `HLT=1`, mean the processor is going nowhere. It is parked in your `hlt` loop, in your code, and it will stay there until you close QEMU.

That is first boot. Your code ran on the machine.

If you want to be completely sure it is *your* loop, paste the address into the disassembler:

```
(qemu) x /6i 0xffffffff8000102a
```

and compare against `x86_64-elf-objdump -d build/kernel.elf | less` around `kmain`. You should see `hlt` and a jump back to it.

### Step 6 — interpreting a bad `info registers`

| What you see | What it means | Where to look |
|---|---|---|
| `RIP` in low memory (`0x7cxx`, `0xf000xxxx`, `0x10xxxx`) | The kernel was never reached. You are still in firmware or in Limine | `limine.conf` paths; did the menu even appear? |
| `RIP` in kernel range but changing between samples, `HLT=0` | Running, not halted. Either `kmain` returned into something, or the halt loop is not what you think | disassemble at `RIP`; check that `kmain` never returns |
| QEMU keeps restarting: firmware splash, menu, splash, menu | **Triple fault.** And you are missing `-no-reboot` | see below |
| The VM is frozen and `info status` says `paused` | A reset was requested and `-no-reboot -no-shutdown` caught it — the guest faulted | `RIP` still shows roughly where; use `-d int,cpu_reset` for detail |
| `info registers` errors or the monitor is unresponsive | You are on the wrong console | `Ctrl-Alt-2` for the monitor, `Ctrl-Alt-1` for the display |

To confirm a triple fault rather than infer it:

```sh
qemu-system-x86_64 -cdrom build/os.iso -m 512M -smp 1 \
    -serial stdio -no-reboot -no-shutdown \
    -d int,cpu_reset -D build/qemu.log
```

`-d int` logs every exception the CPU takes. A triple fault shows as a `check_exception` line where an exception arrives while another is being delivered, followed by the CPU-reset dump that `-d cpu_reset` produces. That dump contains the register state at the moment the machine gave up, which is the closest thing to a stack trace available before [[Phase 2 - Overview|Phase 2]] gives you an IDT and [[Stage 0.7 - Panic and KASSERT]] gives you a panic handler.

### Step 7 — UEFI boot, from the GPT image

```sh
make run-uefi
```

**The firmware path is auto-detected.** UEFI firmware lives somewhere different on
every platform, so the `Makefile` takes the first path that exists — Ubuntu 24.04's
`OVMF_CODE_4M.fd`, older Debian/Ubuntu's `OVMF_CODE.fd`, or Homebrew QEMU's
`edk2-x86_64-code.fd` on macOS. Check what it resolved to with:

```sh
make -n run-uefi | grep bios
```

If it resolved to nothing — `-bios \` with an empty path — you have no UEFI firmware
installed (`sudo apt install ovmf`, or `brew install qemu`), or yours is somewhere
unusual. Find it and override:

```sh
ls /usr/share/OVMF/ /usr/share/ovmf/ 2>/dev/null
make run-uefi OVMF_CODE=/path/to/firmware.fd
```

`scripts/test.sh` honours the same variable.

**What you should see:**

1. The TianoCore logo, and possibly a few seconds of device enumeration.
2. **Limine's menu**, identical to the BIOS run.
3. Black screen.

Then the same check: `Ctrl-Alt-2`, `info registers`, twice. `RIP` in `0xffffffff80...`, `HLT=1`, unchanged between samples.

Reaching the menu here proves a different chain from step 3: OVMF read the GPT, recognised partition 1 by its type GUID, mounted the FAT32, found `\EFI\BOOT\BOOTX64.EFI` at the fallback path, and executed it as a PE32+ application. Every one of those is a distinct thing that can be wrong, and none of them was exercised by the BIOS run.

### Step 8 — the third leg: the ISO under UEFI

The boot matrix has three legs, and `make` only gives you two of them. Run the third by hand:

```sh
qemu-system-x86_64 -cdrom build/os.iso \
    -bios /usr/share/OVMF/OVMF_CODE_4M.fd \
    -m 512M -smp 1 -serial stdio -no-reboot -no-shutdown
```

This exercises the El Torito **UEFI** entry — the embedded `limine-uefi-cd.bin` FAT image — which neither of the previous runs touched. If steps 3 and 7 pass and this one drops to a UEFI shell, your `--efi-boot` flags are wrong.

### Step 9 — make a failure happen on purpose

Verification that has only ever produced a pass is not verification. Break it deliberately, once:

```sh
sed -i 's|boot():/kernel.elf|boot():/kernel.elff|' boot/limine.conf
make run
```

Limine should reach its menu, then report that it cannot open the file — on screen, and in your terminal via `serial: yes` plus `-serial stdio`. That is what a real path error looks like, and knowing its shape is worth sixty seconds now. Put the file back:

```sh
git checkout boot/limine.conf
```

### What can only be checked later

| Claim | Verified in |
|---|---|
| The kernel can produce output | [[Stage 0.6 - Serial Output]] |
| A fault reports itself instead of triple-faulting | [[Stage 0.7 - Panic and KASSERT]] |
| The framebuffer response is usable | [[Phase 1 - Overview\|Phase 1]] |
| The memory map is correct and the initrd is intact | [[Phase 4 - Overview\|Phase 4]], [[Phase 7 - Overview\|Phase 7]] |
| The ext2 root partition mounts and holds files | [[Phase 10 - Overview\|Phase 10]] |
| The image boots on real hardware | the manual checklist in [[11 - Release and Deployment]] |

### Verification checklist

- [ ] `build/os.iso` exists; `xorriso -indev build/os.iso -toc` shows two El Torito entries
- [ ] `build/os.img` exists; `parted build/os.img print` shows partition 1 with the `esp` flag
- [ ] `make run` reaches Limine's menu with the `CRACKED-F OS` branding
- [ ] After the countdown, the screen is black — and you know that is correct
- [ ] `Ctrl-Alt-2` → `info registers` → `RIP` begins `ffffffff80`
- [ ] `HLT=1`, `CPL=0`, `CS` line shows `CS64`
- [ ] A second `info registers` gives an identical `RIP`
- [ ] `make run-uefi` reaches the menu and passes the same register check
- [ ] The ISO booted under OVMF passes the same check
- [ ] A deliberately broken `kernel_path` produces a visible Limine error, and you reverted it

---

## 7. Common traps

**"Limine's menu appears, then the screen goes black and QEMU reboots in a loop."**
The menu, the black screen, then the firmware splash again, forever. This is a **triple fault**, and you are seeing the loop because `-no-reboot` is missing from your QEMU command line. First add `-no-reboot -no-shutdown` — that alone converts an infinite loop into a frozen machine you can inspect with `info registers`. Then find the fault with `-d int,cpu_reset -D build/qemu.log`. At this stage the causes are few: `kmain` returned (there is nothing to return *to*, so the CPU executes whatever garbage follows), the stack pointer is invalid, or the linker script placed a section somewhere unmapped. Note that the black screen on its own is *not* the symptom — a black screen that stays black is success. The reboot is the symptom.

**"Limine says: no such file, or cannot open `kernel.elf`."**
The bootloader loaded, read its config, and could not find what the config named. Almost always a confusion between the **staging path** and the **boot-volume path**. `boot():/kernel.elf` means "`/kernel.elf` on the volume Limine booted from". `mkimage.sh` copies `build/kernel.elf` to `$STAGE/kernel.elf`, and `$STAGE` becomes that volume's root — so the two agree. They stop agreeing the moment you move a file into a subdirectory on one side without changing the other. Check the actual contents of the artefact rather than assuming:

```sh
xorriso -indev build/os.iso -find /            # what is really on the ISO
mdir -i build/esp.img ::/                       # what is really on the ESP
```

The second-most-common cause is Rock Ridge: if `-R -r` were dropped from the xorriso line, ISO 9660 would mangle the name to `KERNEL.ELF;1` and the lowercase path would not resolve.

**"It boots fine under BIOS, but UEFI drops me at a shell prompt."**
A `Shell>` or `UEFI Interactive Shell` prompt means the firmware started, found no bootable application, and gave up gracefully. Three causes, in order of likelihood:

1. `BOOTX64.EFI` is not at `/EFI/BOOT/BOOTX64.EFI`. The path is fixed by the UEFI specification and is not negotiable. Verify with `mdir -i build/esp.img ::/EFI/BOOT`.
2. The ESP type GUID is not set — `set 1 esp on` did not run, or partition 1 is not the one you think. `parted build/os.img print` must show `esp` in the Flags column.
3. The FAT is not valid FAT32. If you reduced `ESP_MB` below about 33, `mkfs.fat -F 32` cannot reach the 65 525-cluster minimum and firmware may reject the filesystem entirely.

From the shell you can diagnose directly: `fs0:`, then `ls`, then `ls EFI\BOOT`. If `fs0:` does not exist, the firmware did not recognise any partition as an ESP, which points at cause 2 or 3 rather than cause 1.

**"Works perfectly in QEMU, black screen on real hardware."**
QEMU is a forgiving, well-behaved, extremely simple machine. Real firmware is none of those things. Work through this order:

- **Secure Boot.** Our Limine is unsigned. Secure Boot silently refuses to execute it and you get no message at all. Disable it in firmware setup. This is the first thing to check, every time, and it is documented as a standing limitation in [[11 - Release and Deployment]].
- **Legacy/CSM mode.** Some firmware boots the USB stick via CSM instead of UEFI, or vice versa. Check which the boot menu selected; the two paths are completely different code in our image.
- **You wrote the ISO with a tool that "helped".** Some USB writers unpack the ISO onto a fresh FAT partition instead of writing bytes. That destroys the MBR, the GPT, and the El Torito catalogue. Use `dd` (or Rufus in DD-image mode), or use `os.img`, or use Ventoy which is built to boot ISOs as ISOs.
- **The resolution request.** `1280x800x32` may not exist on that panel. Limine falls back, so this rarely causes a hang, but if the screen is black and the machine is otherwise alive it is worth trying a common mode such as `1024x768x32`.
- **No serial port.** Most laptops made after 2010 have no UART, so the diagnostic you will lean on from [[Stage 0.6 - Serial Output]] onward is unavailable exactly where you need it most. A USB-to-serial adapter does not help — it needs a driver we do not have until much later. This is the strongest argument for keeping one older test machine with a real serial header, and it is why [[11 - Release and Deployment]] recommends a cheap second-hand laptop.

**"`limine bios-install` was skipped."**
Two different symptoms depending on which artefact.

On `os.img` the script prints `(note: BIOS install skipped — image is UEFI-only)` and carries on. UEFI boot is unaffected; legacy-BIOS boot from that image will not work. Re-run the command by hand without the `2>/dev/null` to see the real error:

```sh
/opt/limine/limine bios-install build/os.img
```

The usual causes are that there is not enough free space between the GPT and the first partition (do not move the partition start below 1 MiB), or that `limine-bios.sys` never made it onto the ESP so there is no second stage to point at.

On `os.iso` the failure is nastier because there is no note — the line has no `|| true` and `set -e` would abort the build, so if it silently did not run at all it is because someone removed the line. The ISO will still boot in QEMU with `-cdrom`, because that path is El Torito and does not involve the MBR. It will fail only when `dd`'d to a USB stick and booted on a BIOS machine — which is to say, it will fail on release day, on hardware, in front of someone. Keep the line.

**"`mtools` refuses with a message about sectors and tracks."**
`mcopy` sometimes objects that the total number of sectors is not a multiple of sectors per track. Our ESP is a flat file with no real geometry, so the check is meaningless here. Set `MTOOLS_SKIP_CHECK=1` in the environment, or add `mtools_skip_check=1` to `~/.mtoolsrc`.

**"`make iso` says `missing build/initrd.tar — run 'make' first`."**
You are on an older copy of `scripts/mkimage.sh`. Current `stage_common` creates an empty placeholder itself and prints `staging an empty placeholder`. If you see the hard error instead, either update the script or work around it once with `tar -cf build/initrd.tar --files-from /dev/null`. The real initrd arrives in [[Phase 7 - Overview|Phase 7]].

**"The `(self-test)` menu entry fails."**
Expected. It loads `kernel-test.elf`, which does not exist until the Tier 2 build in [[09 - Testing Strategy]]. `default_entry: 1` means you never select it by accident. Leave the entry in place.

**"I changed something and the behaviour did not change."**
Check you actually rebuilt the artefact you booted. `make run` depends on `iso`; `make run-uefi` depends on `img`. Editing `boot/limine.conf` and then running a stale `os.iso` is a genuinely convincing illusion. `ls -l build/os.iso build/os.img` and look at the timestamps. `stage_common`'s `rm -rf "$STAGE"` protects you from a stale *staging tree*, but nothing protects you from booting yesterday's image.

**"`dd` wrote the ESP but the image is now 65 MiB."**
`conv=notrunc` is missing. `dd` truncated `os.img` at the end of the ESP, taking the root partition and the backup GPT with it. Both `dd` calls in `build_img` need it.

---

## 8. What this unlocks

Everything. From here on, every stage in every phase is verified by running the OS, and running the OS means `make run` or `make run-uefi` — which means this stage's two artefacts. [[Stage 0.6 - Serial Output]] is the immediate beneficiary: it can only be tested by booting, and because 0.5 is already proven, a silent serial port in 0.6 has exactly one class of cause. `Stage 0.8 - The Build System` wires these targets into the standard verbs, and `Stage 0.9 - CI From Day One` runs the whole boot matrix from `scripts/test.sh` on every push. The `os.img` layout decided here — a 64 MiB FAT32 ESP and a writable ext2 root at 1024-byte blocks — is the layout [[Phase 9 - Overview|Phase 9]]'s block layer and [[Phase 10 - Overview|Phase 10]]'s filesystems will read, and the one [[11 - Release and Deployment]] ships. Get the ESP's fallback path or its type GUID wrong and nothing fails today, because QEMU with `-cdrom` never touches either; it fails the first time someone plugs a USB stick into a real machine, which is the most expensive possible moment to find out. That is why §6 makes you run the UEFI leg and the ISO-under-UEFI leg now rather than trusting the BIOS run.

---

## 9. Reading

- **Limine — `CONFIG.md`**, the authoritative reference for every key in `limine.conf`, including the exact spelling of values this note deliberately did not guess at:
  <https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md>
- **Limine — `README.md`**, which is where the `xorriso` command line in `mkimage.sh` comes from. Read it against the script; if they ever diverge, the README is right:
  <https://github.com/limine-bootloader/limine>
- **Limine — `PROTOCOL.md`**, for what the bootloader hands your kernel and in what state:
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- **UEFI Specification**, §13 (Protocols — Media Access) and the GPT chapter. Skim it for the ESP type GUID and the removable-media fallback path — the two facts this stage's UEFI half rests on:
  <https://uefi.org/specifications>
- **El Torito Bootable CD-ROM Format Specification 1.0** — twenty pages, and it explains the boot catalogue and the platform-ID field better than any secondary source:
  <https://pdos.csail.mit.edu/6.828/2018/readings/boot-cdrom.pdf>
- **OSDev — El Torito**, for the practical version with the xorriso flags:
  <https://wiki.osdev.org/El-Torito>
- **OSDev — UEFI**, particularly the sections on the ESP and boot order:
  <https://wiki.osdev.org/UEFI>
- **OSDev — Bootable Disk**, on MBR layout and the hybrid trick:
  <https://wiki.osdev.org/Bootable_Disk>
- **QEMU — invocation and the monitor.** The `-d` option list and the monitor command reference are worth bookmarking now; you will use both for the next two years:
  <https://www.qemu.org/docs/master/system/invocation.html> and
  <https://www.qemu.org/docs/master/system/monitor.html>
- **`man xorriso`** — specifically the `-as mkisofs` compatibility section. The only correct way to settle an argument about `-efi-boot-part` versus `-isohybrid-gpt-basdat`.
- **`man mtools`, `man mcopy`, `man mke2fs`, `man parted`** — the tools that build the image. `mke2fs`'s `-b` discussion is short and directly relevant to [[Phase 10 - Overview|Phase 10]].
- [[ADR-0003 - Limine as the Bootloader]] — why Limine, and what the escape hatch is
- [[ADR-0009 - Filesystem Strategy FAT32 then ext2]] — why the ESP is FAT32 and why we must eventually be able to write it
- [[11 - Release and Deployment]] — where `os.iso` and `os.img` end up, and the manual checklist that no CI can replace
- [[14 - Debugging Playbook]] — the general procedure this stage's §6 is a special case of
- [[06 - Architecture Overview]] — the boot chain diagram, now with every arrow in it verified

Next: **[[Stage 0.6 - Serial Output]]**

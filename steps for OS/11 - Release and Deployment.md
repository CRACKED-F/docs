# Release and Deployment

How the OS gets out of the repository and onto a machine — QEMU, a VM, a USB stick,
or real hardware.

This is the "launch" half of the pipeline. [[10 - CI Pipeline]] is the "is it
correct" half.

---

## Versioning

**Semantic versioning, adapted for an OS.**

```
v<major>.<minor>.<patch>        v0.4.1
```

| Bump | When |
|---|---|
| **major** | Syscall ABI breaks, or the on-disk format changes incompatibly |
| **minor** | New capability — a driver, a filesystem, a phase completed |
| **patch** | Bug fixes, no new capability, no ABI change |

Pre-1.0 the ABI is explicitly unstable. **v1.0 is the promise that the syscall ABI in
`kernel/include/abi/` will not break within the major version**, which is the point
at which anyone else can build software against the system.

Milestone → version mapping is in [[15 - Roadmap and Milestones]].

The version is set in exactly one place — the git tag. `CMakeLists.txt` derives it
via `git describe --tags --dirty`, so an untagged build is honestly labelled
`v0.4.1-17-gabc1234-dirty` and can never be mistaken for a release.

---

## Artefacts

Every release publishes all of these. Different users need different shapes.

| Artefact | Format | For |
|---|---|---|
| `os-v0.4.1.iso` | Hybrid ISO, BIOS + UEFI | QEMU, CD, `dd` to USB, VM optical |
| `os-v0.4.1.img.xz` | GPT disk image, ESP + root | USB, VM disk, cloud |
| `os-v0.4.1.ova` | OVF appliance | VirtualBox / VMware, one-click import |
| `os-v0.4.1.vhdx` | Hyper-V disk | Windows 11 Hyper-V |
| `kernel-v0.4.1.elf` | Unstripped kernel | debugging a release build |
| `kernel-v0.4.1.sym` | Symbol table | symbolising a panic from a user report |
| `SHA256SUMS` | Checksums | integrity |
| `SHA256SUMS.asc` | Signature | authenticity (post-1.0) |

### Why the hybrid ISO matters

One file that boots on **both** UEFI and legacy BIOS. It carries a BIOS boot record
*and* an El Torito EFI System Partition. This is what lets a single download work
regardless of the target's firmware, and it is the main practical reason for
[[ADR-0003 - Limine as the Bootloader]].

### Why the GPT image matters

The ISO is read-only. `os.img` is a real disk: a FAT32 **EFI System Partition**
holding `/EFI/BOOT/BOOTX64.EFI`, plus a root partition the OS can **write to**. This
is the artefact that proves persistence works, and the one you actually put on a USB
stick.

```
os.img
├── GPT header + protective MBR
├── Partition 1 — ESP, FAT32, 64 MiB
│     /EFI/BOOT/BOOTX64.EFI     (Limine)
│     /limine.conf
│     /kernel.elf
│     /initrd.tar
└── Partition 2 — root, ext2, rest of the disk
```

---

## `release.yml`

```
  git tag v0.4.1 && git push --tags
        │
        ▼
  ┌──────────────────────────────────────────┐
  │ 1. verify tag is on master, tree clean   │
  │ 2. run the FULL ci.yml suite             │  ◄── a tag does not skip tests
  │ 3. build all artefacts (release flags)   │
  │ 4. run the boot matrix against the       │
  │    RELEASE images, not test builds       │  ◄── test what you ship
  │ 5. generate SHA256SUMS                   │
  │ 6. generate changelog from commits       │
  │ 7. create draft GitHub Release           │
  │ 8. attach artefacts                      │
  └──────────────────────────────────────────┘
        │
        ▼
  Draft release — a human runs the manual
  checklist, then publishes.
```

**The release is created as a draft.** Publishing is a deliberate human act after the
manual checklist below, because CI cannot boot real hardware.

---

## The manual release checklist

CI proves it works in QEMU. Only a person can prove it works on metal. This runs
before publishing any minor or major release.

```
[ ] os.iso boots in QEMU  (BIOS)
[ ] os.iso boots in QEMU  (UEFI/OVMF)
[ ] os.img boots in QEMU  (UEFI/OVMF)
[ ] boots with -smp 4, all cores online
[ ] boots with 128 MiB and with 8 GiB
[ ] VirtualBox: import .ova, boots to shell
[ ] Hyper-V: attach .vhdx, boots to shell     (Windows member)
[ ] REAL HARDWARE: dd os.img to USB, boot the test laptop, reach shell
[ ] real hardware: keyboard works
[ ] real hardware: writes a file, reboots, file is still there
[ ] real hardware: ACPI shutdown actually powers off
[ ] CHANGELOG.md accurate
[ ] known-issues section updated
[ ] SHA256SUMS verifies against a fresh download
```

**The real-hardware rows are the ones that matter.** They are the difference between
"we built an OS" and "we built an OS that runs on a computer." Keep one dedicated
x86_64 UEFI test machine — a cheap second-hand laptop is ideal, because it will have
hardware QEMU never modelled.

---

## Writing to a USB stick

```sh
# macOS
diskutil list                                   # find the disk, be careful
diskutil unmountDisk /dev/diskN
sudo dd if=os.img of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN

# Linux / WSL2
sudo dd if=os.img of=/dev/sdX bs=4M status=progress conv=fsync

# Windows 11
#   Rufus, "DD image" mode, or:
#   Use os.iso with Ventoy — copy the ISO onto a Ventoy stick, no flashing
```

> `dd` to the wrong device destroys that device. Check twice. This is the single
> most dangerous command in the project.

On the target machine, disable **Secure Boot** — our Limine build is unsigned. Signed
Secure Boot support is post-1.0 (it requires either a Microsoft-signed shim or
enrolling our own key in firmware).

---

## Release cadence

| Type | Cadence | Gate |
|---|---|---|
| Nightly | automatic, 03:00 UTC | `nightly.yml` green |
| Milestone (`v0.N.0`) | when a milestone completes | full manual checklist |
| Patch (`v0.N.x`) | as needed | CI green + QEMU smoke |
| `v1.0.0` | at M8 | full checklist + a week of soak |

Nightlies are pre-releases and marked as such. They are for the team, not for users.

---

## Deployment targets, ranked by reality

| Target | Status | Notes |
|---|---|---|
| QEMU (BIOS + UEFI) | Primary | every CI run |
| VirtualBox / VMware | Supported | `.ova`, manual per release |
| Hyper-V | Supported | `.vhdx`, Windows member validates |
| Real x86_64 UEFI PC | **The goal** | manual, every minor release |
| Intel Mac | Supported | x86_64 UEFI, same path |
| Apple Silicon Mac | **Not a boot target** | [[ADR-0006 - Apple Silicon Is Not a Boot Target]] — dev host only, via QEMU |
| Cloud (AWS/GCP) | Post-1.0 | needs virtio-blk/net + a cloud-init equivalent |
| Raspberry Pi | Out of scope | aarch64; see ADR-0006 revisit conditions |

---

## Known-limitations policy

Every release ships a **Known Limitations** section, written honestly. Current
standing items:

- No Secure Boot support (unsigned bootloader)
- No USB stack — keyboard requires PS/2 or firmware PS/2 emulation. **Some modern
  laptops have neither**, and on those the OS boots but cannot be typed into
- No journalling; unclean shutdown may require `fsck`
- Single user, no permission enforcement before Phase 15
- No dynamic linking; all binaries static

Stating these plainly costs nothing and prevents every bug report that is really a
scope decision.

---

## Related

[[10 - CI Pipeline]] · [[15 - Roadmap and Milestones]] · [[ADR-0006 - Apple Silicon Is Not a Boot Target]]

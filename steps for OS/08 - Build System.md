# Build System

How source becomes a bootable image, and why the build runs in a container.

---

## The shape of it

```
   host (macOS / Windows 11 / CI)
        │
        │  make run
        ▼
   ┌────────────────────────────────────────┐
   │  docker: ghcr.io/cracked-f/os-toolchain│   ← pinned, identical everywhere
   │                                        │
   │   cmake + ninja                        │
   │     kernel.elf   (x86_64-elf-g++)      │
   │     libc.a                             │
   │     user programs                      │
   │   tools/mkinitrd  → initrd.tar         │
   │   xorriso         → os.iso   (BIOS+UEFI)│
   │   parted+mtools   → os.img   (GPT+ESP) │
   └────────────────┬───────────────────────┘
                    │  artefacts on a bind mount
                    ▼
   host: qemu-system-x86_64 os.iso
```

**Build inside the container. Run QEMU on the host.** GUI output and KVM/HVF
acceleration do not survive containerisation cleanly. In CI, QEMU runs *inside* the
container headless with `-display none`.

---

## Why CMake and not plain Make

v1 planned a hand-written Makefile. That is right for six files and wrong for a
thousand.

| | Hand-rolled Make | CMake + Ninja |
|---|---|---|
| Header dependencies | manual, always subtly wrong | automatic and correct |
| Incremental rebuild | rebuilds too much or too little | correct |
| Three toolchains (kernel / user / host tools) | three parallel rule sets | three toolchain files |
| Host-compiled unit tests | awkward | native |
| `compile_commands.json` for clangd/clang-tidy | no | free |

That last point matters more than it looks: without `compile_commands.json` your
editor cannot resolve kernel headers, so you lose autocomplete and go-to-definition
across the whole project — for years.

**Ninja over Make** for build speed, which matters on Apple Silicon where the
container runs emulated.

`Makefile` at the repo root stays, as a **thin wrapper** providing the verbs people
actually type. It contains no build logic.

---

## Three toolchains, one tree

A single build produces binaries for three different environments. Conflating them is
a classic and painful mistake.

| Target | Toolchain file | Compiler | Notes |
|---|---|---|---|
| Kernel | `cmake/x86_64-kernel.cmake` | `x86_64-elf-g++` | freestanding, `-mno-red-zone`, `-mcmodel=kernel` |
| Userspace | `cmake/x86_64-user.cmake` | `x86_64-elf-g++` | freestanding, links our libc + crt0 |
| Host tools & unit tests | native | host `g++`/`clang++` | `mkinitrd`, `mkfont`, doctest |

Host tools and unit tests are built via CMake's `ExternalProject`/superbuild so the
cross-toolchain never contaminates them.

---

## Kernel compile flags

Defined once in `cmake/KernelFlags.cmake`. **These are not stylistic. Each prevents a
specific, real failure.**

```cmake
-ffreestanding            # no hosted C++ runtime assumptions
-fno-exceptions -fno-rtti # no unwinder, no type tables      ADR-0007
-fno-stack-protector      # no __stack_chk_fail to link against
-fno-pic -fno-pie         # kernel is loaded at a fixed address
-mcmodel=kernel           # addressing valid in the top 2 GiB
-mno-red-zone             # ◄── CRITICAL: interrupts clobber the red zone
-mno-sse -mno-mmx -mno-80387 -mno-3dnow   # no FP state to save
-std=c++20
-Wall -Wextra -Werror
```

`-mno-red-zone` deserves its own note. The AMD64 ABI lets a leaf function use the
128 bytes below `rsp` without adjusting it. In user space nothing else touches that
memory. In kernel space, an **interrupt pushes its frame right there** — silently
destroying live data. The result is random, unreproducible corruption discovered
weeks later, in code that is not the code at fault.

CI greps the compile database for this flag and fails if any translation unit lacks
it.

`-Werror` is on from commit one. Turning it on later means fixing hundreds of
warnings at once, which nobody ever does.

---

## Kernel link flags

Separate from the compile flags, and just as load-bearing.

```cmake
-T kernel/arch/x86_64/boot/linker.ld   # our layout, not the default
-nostdlib                              # no crt0, no libc, no default libs
-static                                # no dynamic loader exists
-z max-page-size=0x1000                # ◄── 4 KiB, not the 2 MiB default
-Wl,--build-id=none                    # reproducibility
```

`-z max-page-size=0x1000` deserves the same attention as `-mno-red-zone`. The
x86-64 linker defaults to a **2 MiB** maximum page size and aligns segments
accordingly. That silently defeats the 4 KiB section alignment the linker script
asks for, pads the image by megabytes, and leaves sections whose boundaries do not
land on the page granularity the VMM will use to apply per-section permissions in
Phase 15. Set it once, here.

---

## The linker script

`kernel/arch/x86_64/boot/linker.ld` places the kernel at `0xFFFFFFFF80000000`
([[06 - Architecture Overview]]) and must:

- keep the Limine request sections (`.limine_requests`, plus the
  `.limine_requests_start` / `.limine_requests_end` marker sections) findable by the
  bootloader — `KEEP()` them, or `--gc-sections` discards them and Limine silently
  finds no requests. See [[Stage 0.4 - The Linker Script and Higher-Half Layout]].
- 4 KiB-align `.text`, `.rodata`, `.data`, `.bss` so page permissions can differ per
  section — this is what makes W^X in Phase 15 possible without relayout
- export `__kernel_start`, `__kernel_end`, `__text_start/end`, `__rodata_start/end`,
  `__data_start/end` so the PMM can reserve the kernel image and the VMM can set
  per-section permissions
- keep `.init_array` so global constructors can be run explicitly

---

## Build outputs

| Artefact | What it is | Used for |
|---|---|---|
| `build/kernel.elf` | Kernel with symbols | GDB, backtrace symbolisation |
| `build/kernel.sym` | Stripped symbol table | shipped for panic symbolisation |
| `build/initrd.tar` | init, sh, coreutils | boot module |
| `build/os.iso` | Hybrid ISO, BIOS + UEFI | QEMU, CD, USB (`dd`) |
| `build/os.img` | GPT disk, ESP + root partition | USB, VM disk, cloud |
| `build/os-vbox.ova` | VirtualBox appliance | VM users |
| `build/compile_commands.json` | Compile database | clangd, clang-tidy |

The **hybrid ISO** carries both a BIOS boot record and an EFI System Partition, so
one file boots either firmware. The **GPT image** is the real-hardware and VM path,
with a FAT32 ESP holding `/EFI/BOOT/BOOTX64.EFI` plus a second partition for the root
filesystem.

---

## The verbs

```
make shell        # interactive shell inside the toolchain container
make              # build kernel + libc + user + initrd
make iso          # + os.iso
make img          # + os.img (GPT/ESP)
make run          # build iso, boot in QEMU (BIOS), serial to stdout
make run-uefi     # boot in QEMU with OVMF firmware
make run-smp      # boot with -smp 4
make debug        # QEMU with -s -S, waits for GDB on :1234
make gdb          # attach GDB with symbols and our .gdbinit preloaded
make test         # all three test tiers
make test-unit    # tier 1 only — seconds
make test-kernel  # tier 2 — in-kernel self-tests
make test-boot    # tier 3 — integration
make fmt          # clang-format in place
make lint         # clang-format --dry-run + clang-tidy
make clean
make toolchain    # rebuild the container image locally
```

**Every verb runs identically in CI.** CI calls these same targets — it does not have
its own build recipe. When CI breaks, you reproduce it with one command locally.
That property is worth protecting.

---

## Reproducibility

Two builds of the same commit must produce identical bytes. This is what makes "it
works on my machine" a falsifiable claim.

- Toolchain pinned by image digest, not tag
  ([[ADR-0005 - Containerised Pinned Toolchain]])
- Limine pinned to a git tag in `boot/limine.mk`
- `SOURCE_DATE_EPOCH` set from the commit timestamp
- No `__DATE__` / `__TIME__` anywhere — CI greps for them
- Build path normalised with `-ffile-prefix-map`
- `ccache` inside the container for incremental speed, keyed on content

`make verify-repro` builds twice into separate directories and diffs the artefacts.

---

## Related

[[ADR-0005 - Containerised Pinned Toolchain]] · [[07 - Repository Layout]] · [[10 - CI Pipeline]]

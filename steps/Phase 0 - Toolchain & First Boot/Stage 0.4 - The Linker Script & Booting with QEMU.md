# Stage 0.4 — The Linker Script & Booting with QEMU

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

The linker takes your object files and decides **where each part lives in memory**.
For a normal program the OS handles this. For a kernel there is no OS, so you write a
**linker script** that says: put the Multiboot header first, load the kernel at a
known physical address, and lay out code, read-only data, and zeroed data in order.

Two facts drive the script:

- GRUB loads a Multiboot kernel at physical `0x00100000` (1 MiB). Below that lies
  real-mode and BIOS memory you must not overwrite.
- The Multiboot header must come **first** so it lands in the first 8 KiB.

Once linked, QEMU can boot the raw kernel directly with its built-in Multiboot
loader (`-kernel`), which is faster than building an ISO. You build the ISO in
Stage 0.5; use `-kernel` now to close the loop quickly.

---

## Specification

- Load address: `. = 0x00100000;` (1 MiB).
- Section order: `.multiboot` (the header), then `.text`, then `.rodata`, then
  `.data`, then `.bss`.
- The output is a single ELF binary, for example `mykernel.bin`.
- Link with the **cross-compiler**, not bare `ld`, so it finds `libgcc`:
  `i686-elf-gcc -T linker.ld -ffreestanding -nostdlib -o mykernel.bin boot.o kernel.o -lgcc`.
- Boot with: `qemu-system-i386 -kernel mykernel.bin`.

---

## Your task

1. Write `linker.ld`:
   - Set the entry symbol to `_start`.
   - Start the location counter at `0x00100000`.
   - Place `.multiboot` first, then `.text`, `.rodata`, `.data`, `.bss`.
2. Link `boot.o` and `kernel.o` into `mykernel.bin` using the cross-compiler command
   above.
3. Run `grub-file --is-x86-multiboot mykernel.bin` and confirm it exits 0.
4. Boot it: `qemu-system-i386 -kernel mykernel.bin`.
5. Confirm the white `A` from Stage 0.3 appears in the top-left corner.

---

## How to verify

- `grub-file --is-x86-multiboot mykernel.bin` exits 0 (no output, exit code 0). This
  proves the header is valid and correctly placed.
- QEMU boots and shows a single white `A` at the top-left. That is proof your C++
  `kernel_main` ran on bare metal.
- No reboot loop. If QEMU keeps resetting, the machine is triple-faulting — most
  often a missing stack (Stage 0.3) or a bad linker layout.

---

## Common traps

- **Header not in the first 8 KiB.** If `.multiboot` is not first in the script,
  GRUB will not find it. Order matters.
- **Linking with bare `ld`.** You then miss `libgcc`, and some C++ built-ins (like
  64-bit divides) fail to link. Link through `i686-elf-gcc`.
- **Wrong load address.** Anything other than 1 MiB for a plain Multiboot kernel
  collides with reserved low memory.
- **`grub-file` missing on macOS.** Use the container from Stage 0.5, or trust the
  QEMU `-kernel` boot as your check for now.

---

## Reading

- OSDev — *Bare Bones* (the `linker.ld` section): <https://wiki.osdev.org/Bare_Bones>
- OSDev — *Linker Scripts*: <https://wiki.osdev.org/Linker_Scripts>
- GNU `ld` manual (linker script command language):
  <https://sourceware.org/binutils/docs/ld/Scripts.html>

Next: **[[Stage 0.5 - Building a Bootable ISO with GRUB]]**.

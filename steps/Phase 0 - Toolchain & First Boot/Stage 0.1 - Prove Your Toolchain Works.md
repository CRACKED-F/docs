# Stage 0.1 — Prove Your Toolchain Works

**Difficulty:** Very Easy · ~5 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

Before you write a kernel, prove the machine that builds it works. Two things must
be true: the **cross-compiler** produces an `i686-elf` object, and **QEMU** starts.
This stage is a smoke test. It fails fast and clearly if setup is wrong, instead of
hiding a broken tool inside a blank-screen boot three stages later.

---

## Specification

- The cross-compiler is `i686-elf-gcc` / `i686-elf-g++`. It must exist on your PATH.
- A freestanding object does not need a `main` or a C library. You can compile a
  single function to an object file with `-ffreestanding -c`.
- QEMU for this target is `qemu-system-i386`.

---

## Your task

1. Create a project folder (inside WSL on Windows, anywhere on macOS).
2. Write a one-line C++ file with a single empty function, for example
   `void _probe() {}`.
3. Compile it to an object with the cross-compiler using
   `-ffreestanding -nostdlib -c`. Confirm it produces a `.o` file with no errors.
4. Run `file` on the `.o` (or `i686-elf-readelf -h`) and confirm the format is
   **ELF 32-bit i386**, not your host's format (not x86-64, not Mach-O).
5. Start QEMU with `qemu-system-i386` and no disk. Confirm a window opens and shows
   "No bootable device". Close it.

---

## How to verify

- The compile prints nothing and exits 0.
- `readelf -h probe.o` shows `Class: ELF32` and `Machine: Intel 80386`.
- QEMU opens a window (or a text screen with `-nographic`) and complains it has
  nothing to boot. That "error" is success — QEMU runs.

If the object is Mach-O or x86-64, you compiled with your **host** compiler by
mistake. Re-check the tool name.

---

## Common traps

- Typing `gcc` out of habit instead of `i686-elf-gcc`. The host compiler will
  happily build the object and mislead you.
- On macOS, `file` reporting `Mach-O` means the wrong compiler ran.
- Forgetting `-ffreestanding`: the host compiler may demand a `main` or a library.

---

## Reading

- OSDev — *GCC Cross-Compiler* and *Why do I need a Cross Compiler?*
  <https://wiki.osdev.org/GCC_Cross-Compiler>
- See **[[02 - Toolchain Setup (Mac & Windows)]]** if any tool is missing.

Next: **[[Stage 0.2 - The Multiboot Header]]**.

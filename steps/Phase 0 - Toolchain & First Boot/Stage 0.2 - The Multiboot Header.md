# Stage 0.2 — The Multiboot Header

**Difficulty:** Easy · ~15 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

Firmware loads GRUB. GRUB then needs to recognize *your* kernel as something it can
load. The **Multiboot specification** is the contract: if your kernel starts with a
small, specially formatted header in the first 8 KiB of the file, GRUB will load it,
put the CPU in 32-bit protected mode, and jump to your entry point.

This means you skip writing a real-mode bootloader entirely. The price is one small
header of "magic numbers". This stage writes that header in assembly.

---

## Specification

The Multiboot 1 header is three (or more) 32-bit fields, aligned to 4 bytes:

| Field | Value | Meaning |
|---|---|---|
| `magic` | `0x1BADB002` | Marks the header so GRUB can find it. |
| `flags` | e.g. `0x00000003` | Bit 0: align modules to pages. Bit 1: ask GRUB for a memory map. |
| `checksum` | `-(magic + flags)` | The three values must sum to zero (mod 2³²). |

- The header must lie within the first 8192 bytes of the kernel file and be 4-byte
  aligned. You guarantee this with the linker script in
  **[[Stage 0.4 - The Linker Script & Booting with QEMU]]** by placing it first.
- Write it in a NASM (or GAS) assembly file, in its own section (commonly
  `.multiboot`).

---

## Your task

1. Create `boot.asm` (NASM syntax) with a `.multiboot` section.
2. Define the three constants: `MAGIC = 0x1BADB002`, `FLAGS = 0x3`,
   `CHECKSUM = -(MAGIC + FLAGS)`.
3. Emit them as three `dd` (define-dword) values, 4-byte aligned.
4. Assemble it with `nasm -f elf32 boot.asm -o boot.o`.
5. Keep this file; **[[Stage 0.3 - Freestanding C++ & the Kernel Entry Point]]** adds
   the entry code below the header in the same file.

---

## How to verify

- `nasm -f elf32` assembles with no errors and produces `boot.o`.
- After Stage 0.4 links the kernel, `grub-file --is-x86-multiboot mykernel.bin`
  exits 0. That command is the definitive check that GRUB will accept your kernel.
  You cannot run it yet, but write it down as the Phase 0 acceptance test.

---

## Common traps

- The checksum is wrong or the three values do not sum to zero. GRUB then ignores
  the kernel and you get "no multiboot header found".
- The header is not in the first 8 KiB because the linker placed something else
  first. Fix this in the linker script (Stage 0.4), not here.
- Mixing Multiboot 1 (`0x1BADB002`) with Multiboot 2 (`0xE85250D6`). This guide uses
  Multiboot 1 for simplicity. Do not mix the two.

---

## Reading

- Multiboot Specification, section "Header layout":
  <https://www.gnu.org/software/grub/manual/multiboot/multiboot.html>
- OSDev — *Multiboot*: <https://wiki.osdev.org/Multiboot>
- OSDev — *Bare Bones* (the `boot.s` section): <https://wiki.osdev.org/Bare_Bones>

Next: **[[Stage 0.3 - Freestanding C++ & the Kernel Entry Point]]**.

# Stage 4.1 — Reading the Memory Map

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 4 - Overview|Phase 4 — Memory Management]]

---

## Concept

Before you hand out memory you must know which memory exists and which is safe to
touch. You do not probe RAM yourself; GRUB already did and left you a **memory map** —
a list of regions, each marked usable or reserved. GRUB passes a pointer to this
information in a register when it jumps to your kernel. You just have to find it and
read it.

---

## Specification

- When GRUB enters your kernel, register `ebx` holds a pointer to the **Multiboot
  info structure**, and `eax` holds the magic value `0x2BADB002`. Capture `ebx` in
  your assembly entry and pass it to `kernel_main`.
- The info structure has a `flags` field. If bit 6 is set, the `mmap_length` and
  `mmap_addr` fields point at the memory map.
- The memory map is an array of entries. Each entry has: a `size` field, a 64-bit
  `base_addr`, a 64-bit `length`, and a `type` (type 1 = usable RAM). Entries can vary
  in size, so advance by `size + 4` bytes each step, not by a fixed struct size.
- Also note the kernel's own start and end addresses (export symbols from the linker
  script) so you never mark the kernel's memory as free.

---

## Your task

1. In the assembly entry, push the Multiboot info pointer (`ebx`) as an argument to
   `kernel_main`, and change `kernel_main`'s signature to accept it.
2. Define the Multiboot info and memory-map entry structs.
3. Check the magic value and the flags bit for the memory map.
4. Walk the memory map, printing each region's base, length, and type.
5. Sum the usable (type 1) memory and print the total.

---

## How to verify

- The printed regions match what you told QEMU (`-m 128M` gives roughly 128 MiB of
  usable RAM across the regions).
- The magic value read at entry is `0x2BADB002`. If it is not, GRUB did not pass
  control the way you assume, and the pointer is garbage.
- The total usable memory is a believable number, not zero and not absurd.

---

## Common traps

- **Advancing by the wrong step.** Entries are variable length; step by `size + 4`.
- Losing `ebx` before you save it — the first thing your entry code touches may
  clobber it. Save it immediately.
- Ignoring the 64-bit fields' high halves; on a 32-bit kernel you mostly use the low
  half, but read the struct correctly.
- Assuming region order or contiguity. Treat the map as an unordered list of ranges.

---

## Reading

- OSDev — *Detecting Memory (x86)* (Multiboot map section):
  <https://wiki.osdev.org/Detecting_Memory_(x86)>
- Multiboot Specification — "Boot information format":
  <https://www.gnu.org/software/grub/manual/multiboot/multiboot.html>

Next: **[[Stage 4.2 - The Physical Frame Allocator]]**.

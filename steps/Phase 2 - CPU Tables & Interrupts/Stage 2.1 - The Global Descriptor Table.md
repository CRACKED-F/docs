# Stage 2.1 — The Global Descriptor Table

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]

---

## Concept

In protected mode the CPU views memory through **segments**, and it reads their
definitions from the **Global Descriptor Table (GDT)**. GRUB set up a temporary GDT
to get you here, but you should own it — later stages (the TSS for user mode in
**[[Phase 6 - Overview|Phase 6]]**) add entries to it.

For a modern kernel the segments are deliberately boring: this is the **flat model**.
You make code and data segments that each span the whole 4 GiB address space, so
segmentation effectively "gets out of the way" and real memory protection comes later
from **paging** (**[[Phase 4 - Overview|Phase 4]]**). You still must define these flat
segments, because the CPU requires them.

---

## Specification

- A GDT is an array of 8-byte **descriptors**. Entry 0 must be the **null
  descriptor** (all zeroes).
- You need at least: null, kernel code, kernel data. (User code, user data, and the
  TSS come in Phase 6.)
- Flat segment values: base `0x00000000`, limit `0xFFFFF` with 4 KiB granularity, so
  each segment covers all 4 GiB.
- Access byte and flags encode: present, ring (0 for kernel), executable (code vs
  data), direction, and read/write. The exact bit meanings are on the OSDev *GDT*
  page.
- You load it with the `lgdt` instruction, then reload the segment registers.
  Reloading `cs` requires a **far jump**; `ds/es/fs/gs/ss` are reloaded by `mov`.

---

## Your task

1. Define a packed `gdt_entry` struct (8 bytes) and a `gdt_ptr` struct (a 16-bit
   limit plus a 32-bit base).
2. Fill three entries: null, kernel code (ring 0, executable), kernel data (ring 0,
   writable).
3. Write a small assembly routine `gdt_flush` that runs `lgdt`, reloads the data
   segment registers with the data selector, and far-jumps to reload `cs` with the
   code selector.
4. Call your GDT setup early in `kernel_main`, before you enable interrupts.
5. `kprintf` a confirmation line after `gdt_flush` returns.

---

## How to verify

- The kernel keeps running past `gdt_flush` and prints your confirmation line. A bad
  GDT triple-faults immediately (QEMU reboot loop), so simply *surviving* the reload
  is the main check.
- In the Bochs debugger (optional) you can dump the GDT and see your three entries.

---

## Common traps

- **Not far-jumping to reload `cs`.** A plain `mov` cannot change `cs`; you must far
  jump. Skipping this leaves `cs` pointing at GRUB's old descriptor.
- Wrong struct packing. The descriptor must be exactly 8 bytes; use a packed
  attribute so the compiler adds no padding.
- Loading the segment *selector* (byte offset into the GDT: `0x08`, `0x10`) versus
  the *index* (1, 2). Registers take the selector (offset).

---

## Reading

- OSDev — *Global Descriptor Table* and *GDT Tutorial*:
  <https://wiki.osdev.org/Global_Descriptor_Table> · <https://wiki.osdev.org/GDT_Tutorial>
- The Little OS Book, "Segmentation": <https://littleosbook.github.io>

Next: **[[Stage 2.2 - The Interrupt Descriptor Table]]**.

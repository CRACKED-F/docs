# Stage 4.2 — The Physical Frame Allocator

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 4 - Overview|Phase 4 — Memory Management]]

---

## Concept

Physical RAM is handed out in fixed **4 KiB frames**. The **frame allocator** is the
bookkeeper: it knows which frames are free and which are in use, and it answers
`alloc_frame()` with a free physical address and `free_frame(addr)` to give one back.
Paging (next stage) and every process will ask this allocator for their physical
memory.

The simplest reliable design is a **bitmap**: one bit per frame, 1 = used, 0 = free.
For 128 MiB of RAM that is 32768 frames, so 4 KiB of bitmap. Cheap and easy to reason
about.

---

## Specification

- Frame size: `4096` bytes. Frame number `n` covers physical `n * 4096`.
- Bitmap: one bit per frame. Helpers `set_bit(n)`, `clear_bit(n)`, `test_bit(n)`.
- Initialize from the memory map (Stage 4.1): mark everything used, then clear the
  usable (type 1) regions to free.
- Then mark **reserved** areas used again so they are never handed out: low memory
  below 1 MiB, the kernel's own range (from the linker symbols), and the bitmap
  itself.
- `alloc_frame()`: find the first free bit, set it, return its physical address.
  Return an error/zero when memory is exhausted.
- `free_frame(addr)`: clear the bit for that address.

---

## Your task

1. Reserve storage for the bitmap (a static array is fine early on).
2. Write `set_bit`, `clear_bit`, `test_bit`.
3. Initialize the bitmap from the memory map: all used, then free the usable regions.
4. Re-mark reserved regions used: below 1 MiB, the kernel image, and the bitmap.
5. Write `alloc_frame()` and `free_frame(addr)`.
6. Test: allocate several frames, print their addresses, free them, allocate again,
   and confirm reuse.

---

## How to verify

- `alloc_frame` returns distinct, 4 KiB-aligned physical addresses inside usable RAM.
- Freeing a frame and allocating again returns the same frame (the bitmap tracks it).
- The kernel's own address range is never returned by `alloc_frame`.
- Allocating until exhaustion returns the error value rather than wandering into
  reserved memory.

---

## Common traps

- Forgetting to reserve the kernel image or the bitmap, so the allocator hands out
  memory it is standing on.
- Confusing frame *number* with frame *address* (`address = number * 4096`).
- Not aligning the initial free/used marking to frame boundaries.
- A slow linear scan is fine for now; do not optimize prematurely.

---

## Reading

- OSDev — *Page Frame Allocation*: <https://wiki.osdev.org/Page_Frame_Allocation>
- The Little OS Book, "A Short Introduction to Virtual Memory" / memory chapters:
  <https://littleosbook.github.io>

Next: **[[Stage 4.3 - Enabling Paging]]**.

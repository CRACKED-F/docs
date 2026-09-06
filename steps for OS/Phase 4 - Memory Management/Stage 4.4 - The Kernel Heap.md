# Stage 4.4 — The Kernel Heap

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 4 - Overview|Phase 4 — Memory Management]]

---

## Concept

The frame allocator hands out whole 4 KiB frames. But most kernel data — a filename, a
list node, a process record — is much smaller. A **heap** sits on top of paging and
serves **variable-sized** requests: this is `kmalloc(size)` and `free(ptr)`. With it,
C++ `new`/`delete` can work too, and the rest of the kernel stops using fixed global
arrays.

A simple, correct first heap is a **linked list of blocks**, each with a header saying
its size and whether it is free. `kmalloc` walks the list for a big-enough free block,
splits it, and returns the data area. `free` marks a block free and merges neighbors.

---

## Specification

- Reserve a virtual address range for the heap and back it with frames through
  `map_page` (from Stage 4.3), growing it as needed.
- Block header: size, a free flag, and a link to the next block (a bump/`sbrk`-style
  allocator is an acceptable even-simpler first version, without `free`).
- `kmalloc(size)`: find or grow a free block of at least `size`, split off the
  remainder, mark it used, return the pointer after the header. Keep the returned
  pointer suitably aligned.
- `free(ptr)`: find the block header behind `ptr`, mark it free, and coalesce with
  adjacent free blocks to fight fragmentation.
- Once `kmalloc`/`free` work, implement `operator new`/`operator delete` on top so C++
  allocation works.

---

## Your task

1. Reserve and map an initial heap region using paging + the frame allocator.
2. Implement `kmalloc(size)` with first-fit search, block splitting, and alignment.
3. Implement `free(ptr)` with coalescing of adjacent free blocks.
4. Add a way to grow the heap (map more pages) when no block is large enough.
5. Implement `operator new`/`operator delete` calling `kmalloc`/`free`.
6. Stress-test: many allocations and frees of mixed sizes, checking values survive.

---

## How to verify

- `kmalloc` returns distinct, aligned, writable pointers, and data written to them
  reads back correctly.
- `free` then `kmalloc` reuses space (the heap does not grow without bound under a
  malloc/free loop).
- A C++ `new`/`delete` of a small object works.
- A torture loop of random alloc/free sizes runs for thousands of iterations without
  corruption or running out prematurely.

---

## Common traps

- Returning the pointer *at* the header instead of just after it, so callers overwrite
  bookkeeping.
- No coalescing, so repeated alloc/free fragments the heap until it fails.
- Alignment bugs: some structures need 4- or 8-byte alignment; round `size` up.
- Growing the heap into unmapped pages without calling `map_page`, causing a page
  fault inside `kmalloc`.

---

## Reading

- OSDev — *Writing a memory manager* / *Heap*:
  <https://wiki.osdev.org/Heap>
- JamesM's tutorial, "The Heap" chapter (mind the errata):
  <http://www.jamesmolloy.co.uk/tutorial_html/> ·
  <https://wiki.osdev.org/James_Molloy's_Tutorial_Known_Bugs>
- OSTEP — "Free-Space Management":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

---

## Phase 4 is complete

Your kernel manages memory: it knows its RAM, allocates physical frames, translates
through paging, and serves `kmalloc`/`free`. Commit. This unlocks processes,
filesystems, and program loading.

Next phase: **[[Phase 5 - Overview]]**.

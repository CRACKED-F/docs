# Stage 4.3 — Enabling Paging

**Difficulty:** Hard · ~1.5 hours
**Phase:** [[Phase 4 - Overview|Phase 4 — Memory Management]]

---

## Concept

**Paging** makes the CPU translate every **virtual** address to a **physical** one
through tables you control, one 4 KiB **page** at a time. This gives two huge wins:
each process can have its own address space (isolation), and memory need not be
contiguous. It is also the point where a wrong table entry causes a **page fault** —
which you already handle, so faults are readable, not silent reboots.

On 32-bit x86 the translation uses two levels: a **page directory** with 1024 entries,
each pointing at a **page table** with 1024 entries, each mapping one 4 KiB page.
1024 × 1024 × 4 KiB = the full 4 GiB space.

---

## Specification

- Page size `4096`. A virtual address splits into: directory index (top 10 bits),
  table index (next 10 bits), offset (low 12 bits).
- Page directory and each page table are 4 KiB and **4 KiB-aligned**. Get them from
  your frame allocator.
- Each entry holds a physical frame address plus flags: **present** (bit 0),
  **writable** (bit 1), **user** (bit 2). Kernel pages leave user clear.
- **Identity-map** the kernel's memory first: virtual address = physical address for
  the low region that holds your kernel, so nothing moves under you when paging turns
  on. (A higher-half layout is an optional later refinement; identity mapping is the
  safe first step.)
- Enable paging: load the page directory's physical address into `cr3`, then set the
  paging bit (bit 31) in `cr0`.
- Install a **page-fault handler** (vector 14) that reads the faulting address from
  `cr2` and prints it with the error code.

---

## Your task

1. Define page-directory and page-table entry types and the index-extraction macros.
2. Allocate a page directory and identity-map at least the kernel's physical range
   (and the VGA buffer at `0xB8000`).
3. Write `map_page(virt, phys, flags)` that walks/creates the directory and table
   entries.
4. Load `cr3` and set the paging bit in `cr0`.
5. Add a page-fault handler that reads `cr2` and prints the faulting address, the
   error code, and whether it was a read/write and user/kernel access.
6. Test: access a mapped address (works) and an unmapped one (clean page fault
   message).

---

## How to verify

- The kernel keeps running after paging is enabled and still prints to screen (the
  VGA buffer is mapped).
- Reading a mapped address returns the expected value.
- Touching an unmapped address prints a page fault with the correct `cr2` address —
  not a reboot. This proves both paging and your fault handler.

---

## Common traps

- **Not identity-mapping the code that enables paging.** The instruction right after
  you set `cr0` must still be reachable, so its page must be mapped. Forgetting this
  triple-faults instantly.
- **Forgetting the VGA buffer**, so the screen goes dead the moment paging turns on
  even though the kernel runs (check serial output to confirm it is alive).
- Unaligned page directory or tables. They must be 4 KiB-aligned.
- Setting the writable/user bits wrong, causing faults on legitimate access.
- Not flushing the TLB after changing a mapping (reload `cr3`, or use `invlpg`).

---

## Reading

- OSDev — *Paging* and *Setting Up Paging*:
  <https://wiki.osdev.org/Paging> · <https://wiki.osdev.org/Setting_Up_Paging>
- Philipp Oppermann — "Introduction to Paging" (clearest diagrams):
  <https://os.phil-opp.com/paging-introduction/>
- OSTEP — "Paging: Introduction" and "Translation":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 4.4 - The Kernel Heap]]**.

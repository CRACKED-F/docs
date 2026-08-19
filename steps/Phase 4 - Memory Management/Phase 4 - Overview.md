# Phase 4 — Memory Management

**Goal:** take control of RAM. You will find out how much memory exists, hand out
physical **frames** on request, turn on **paging** so virtual addresses map to
physical ones, and build a **heap** so `kmalloc`/`free` work. After this phase your
kernel can allocate memory dynamically and give each future process its own protected
address space.

This is the phase that makes everything after it possible: processes, the heap-backed
data structures a filesystem needs, and user/kernel isolation.

> Prerequisite: **[[Phase 3 - Overview|Phase 3]]** complete. Page faults will use the
> exception handler from **[[Stage 2.3 - CPU Exception Handlers]]**.

---

## Why this phase exists

So far you allocate nothing — every buffer is a fixed global. Real OS work needs
dynamic memory: variable-length structures, per-process page tables, loaded programs.
That needs three layers, built bottom-up:

1. **Know your RAM** — read the memory map GRUB gives you.
2. **Physical allocation** — a frame allocator that owns 4 KiB blocks.
3. **Virtual memory** — paging, then a heap on top.

Read the OSTEP virtual-memory chapters before starting. This phase is much easier with
the mental model first.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 4.1 | [[Stage 4.1 - Reading the Memory Map]] | Medium | The list of usable RAM regions. |
| 4.2 | [[Stage 4.2 - The Physical Frame Allocator]] | Medium | `alloc_frame` / `free_frame`. |
| 4.3 | [[Stage 4.3 - Enabling Paging]] | Hard | Virtual memory turned on. |
| 4.4 | [[Stage 4.4 - The Kernel Heap]] | Hard | Working `kmalloc` / `free`. |

---

## Deliverable

`kmalloc(size)` returns usable memory backed by real frames through paging, `free`
returns it, and a deliberate access to an unmapped address triggers a **page fault**
that your handler reports cleanly. You have dynamic memory and memory protection.

---

## Read before you start

- OSTEP — "Address Spaces", "Paging", "Translation" chapters:
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *Detecting Memory (x86)*, *Paging*, *Setting Up Paging*:
  <https://wiki.osdev.org/Detecting_Memory_(x86)> · <https://wiki.osdev.org/Paging> ·
  <https://wiki.osdev.org/Setting_Up_Paging>

Previous: **[[Phase 3 - Overview]]** · Next: **[[Phase 5 - Overview]]**.

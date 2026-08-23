# Progress Tracker

One page, every stage, a checkbox each. Tick a stage when it is **verified**, not
when the code is written — the stage note's *How to verify* section defines done.

> Obsidian renders `- [ ]` as a clickable box. Click it and the line strikes
> through. Read [[01 - How To Use These Docs]] for how a stage is structured.

**Rule:** commit after every green stage. When the screen goes blank three stages
later, `git diff` against the last known-good commit is the fastest debugging tool
you own.

---

## Phase 0 — Toolchain & First Boot

Detailed notes: [[Phase 0 - Overview]]

- [ ] 0.1 [[Stage 0.1 - Prove Your Toolchain Works]]
- [ ] 0.2 [[Stage 0.2 - The Limine Request Section]]
- [ ] 0.3 [[Stage 0.3 - Freestanding C++ and kmain]]
- [ ] 0.4 [[Stage 0.4 - The Linker Script and Higher-Half Layout]]
- [ ] 0.5 [[Stage 0.5 - Building a Bootable Image]] — **FIRST BOOT**
- [ ] 0.6 [[Stage 0.6 - Serial Output]] — **FIRST OUTPUT**
- [ ] 0.7 [[Stage 0.7 - Panic and KASSERT]]
- [ ] 0.8 [[Stage 0.8 - The Build System]]
- [ ] 0.9 [[Stage 0.9 - CI From Day One]]

---

## Phase 1 — Text Output

Detailed notes: [[Phase 1 - Overview]]

> Rewritten for the linear framebuffer. Notes 1.3, 1.6 and 1.7 are still
> outstanding — see the markers below.

- [ ] 1.1 [[Stage 1.1 - The Linear Framebuffer]]
- [ ] 1.2 [[Stage 1.2 - Rasterising a Bitmap Font]]
- [ ] 1.3 [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] — ⚠️ note is an incomplete draft
- [ ] 1.4 [[Stage 1.4 - Double Buffering]]
- [ ] 1.5 [[Stage 1.5 - The Log Ring Buffer and Levels]]
- [ ] 1.6 [[Stage 1.6 - kprintf]]
- [ ] 1.7 [[Stage 1.7 - Symbolised Backtraces]] — ⚠️ note not written yet

---

## Phase 2 — CPU Tables & Interrupts

Detailed notes: [[Phase 2 - Overview]]

- [ ] 2.1 [[Stage 2.1 - The Global Descriptor Table]]
- [ ] 2.2 [[Stage 2.2 - The TSS and Interrupt Stacks]] — survivable double faults
- [ ] 2.3 [[Stage 2.3 - The Interrupt Descriptor Table]] — ⚠️ shallow, not yet rewritten
- [ ] 2.4 [[Stage 2.4 - Interrupt Stubs and the Saved Frame]] — ⚠️ note not written yet
- [ ] 2.5 [[Stage 2.5 - CPU Exception Handlers]] — ⚠️ shallow, not yet rewritten
- [ ] 2.6 [[Stage 2.6 - The 8259 PIC - Remap and Mask]] — ⚠️ shallow, not yet rewritten
- [ ] 2.7 [[Stage 2.7 - Hardware Interrupts]] — ⚠️ shallow, not yet rewritten

---

## Phase 3 — Drivers: Timer & Keyboard

Detailed notes: [[Phase 3 - Overview]]

- [ ] 3.1 [[Stage 3.1 - The Programmable Interval Timer]]
- [ ] 3.2 [[Stage 3.2 - The Keyboard Driver]]
- [ ] 3.3 [[Stage 3.3 - An Input Line Buffer]]

---

## Phase 4 — Memory Management

Detailed notes: [[Phase 4 - Overview]]

- [ ] 4.1 [[Stage 4.1 - Reading the Memory Map]]
- [ ] 4.2 [[Stage 4.2 - The Physical Frame Allocator]]
- [ ] 4.3 [[Stage 4.3 - Enabling Paging]]
- [ ] 4.4 [[Stage 4.4 - The Kernel Heap]]

---

## Phase 5 — Multitasking

Detailed notes: [[Phase 5 - Overview]]

- [ ] 5.1 [[Stage 5.1 - Tasks, Context, and the Stack]]
- [ ] 5.2 [[Stage 5.2 - Cooperative Task Switching]]
- [ ] 5.3 [[Stage 5.3 - Preemptive Scheduling]]
- [ ] 5.4 [[Stage 5.4 - Sleep and Blocking]]

---

## Phase 6 — User Mode & System Calls

Detailed notes: [[Phase 6 - Overview]]

- [ ] 6.1 [[Stage 6.1 - The Task State Segment]]
- [ ] 6.2 [[Stage 6.2 - Entering Ring 3]]
- [ ] 6.3 [[Stage 6.3 - The System Call Interface]]
- [ ] 6.4 [[Stage 6.4 - A Minimal User C Library]]

---

## Phase 7 — Filesystem & Program Loading

Detailed notes: [[Phase 7 - Overview]]

- [ ] 7.1 [[Stage 7.1 - The Initial Ramdisk]]
- [ ] 7.2 [[Stage 7.2 - A Read-Only Filesystem]]
- [ ] 7.3 [[Stage 7.3 - The Virtual Filesystem Layer]]
- [ ] 7.4 [[Stage 7.4 - Loading and Running an ELF Program]]

---

## Phase 8 — The Shell

Detailed notes: [[Phase 8 - Overview]]

- [ ] 8.1 [[Stage 8.1 - The Shell Read-Eval Loop]]
- [ ] 8.2 [[Stage 8.2 - Built-in Commands]]
- [ ] 8.3 [[Stage 8.3 - Launching Programs]]
- [ ] 8.4 [[Stage 8.4 - init - Wiring It Together]]

**🎉 Milestone: a self-hosted interactive system.** Everything past here is
"product", not "it works".

---

## Phases 9–15 — Product

Stage notes not yet written; only phase overviews exist. Write the stages for a
phase before starting it.

- [ ] 9 [[Phase 9 - Overview|Storage]] — block devices, AHCI/NVMe, the block cache
- [ ] 10 [[Phase 10 - Overview|Real Filesystems]] — FAT32 then ext2 ([[ADR-0009 - Filesystem Strategy FAT32 then ext2]])
- [ ] 11 [[Phase 11 - Overview|Modern Platform]] — ACPI, APIC, PCI, HPET/TSC
- [ ] 12 [[Phase 12 - Overview|SMP]] — start the application processors
- [ ] 13 [[Phase 13 - Overview|Unix Process Model]] — fork/exec, signals, pipes
- [ ] 14 [[Phase 14 - Overview|Networking]] — ARP, IPv4, UDP, TCP, sockets
- [ ] 15 [[Phase 15 - Overview|Hardening and Real Hardware]] — W^X, SMEP/SMAP, boot on metal

- [ ] [[Capstone - You Built an OS]]

---

## Cross-cutting, do once

- [ ] Replace `@member-a` / `@member-b` in `.github/CODEOWNERS` with real usernames
- [ ] Publish the toolchain image, then **pin it by digest** in `Makefile` and every
      workflow — see [[ADR-0005 - Containerised Pinned Toolchain]]
- [ ] Record the first ADR of your own (something you decided that is not in
      [[decisions/ADR-0001 - Record Architecture Decisions|ADR-0001]]'s list)
- [ ] Write `kernel/sched/locks.md` before the second lock exists
      ([[06 - Architecture Overview]])

---

## Related

[[Phase 0 - Overview]] · [[15 - Roadmap and Milestones]] · [[01 - How To Use These Docs]]

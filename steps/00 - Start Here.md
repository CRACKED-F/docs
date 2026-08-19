# Build Your Own OS — Start Here

This vault is a step-by-step guide to build a small but real operating system from
scratch in **C++**. It targets **x86 (32-bit i386)**, boots through **GRUB /
Multiboot**, and runs in the **QEMU** emulator. The end goal is a genuinely working
OS: it boots, drives the screen and keyboard, manages memory, runs many tasks at
once, loads programs from a filesystem, and gives you an interactive shell.

The docs assume **no low-level experience**. Every stage explains the idea first,
then tells you exactly what to build, then tells you how to check it works. Every
stage also links to reading material, because the concepts are new and worth
learning from more than one source.

> New here? Read **[[01 - How To Use These Docs]]** first, then set up your machine
> with **[[02 - Toolchain Setup (Mac & Windows)]]**.

---

## The model these docs follow (CodeCrafters-inspired)

This guide copies the structure of CodeCrafters challenges:

- Work splits into small **stages**. Stages group into **phases**.
- Each stage is small on purpose. The first stages take minutes, not hours.
- Every stage ends with **working, runnable code**. You are never far from a
  program that boots.
- Each stage has the same four parts: **Concept → Specification → Task checklist →
  How to verify**. A **Reading** section links out for depth.
- Later stages depend on earlier ones. You build one dependency chain, in order.

See **[[01 - How To Use These Docs]]** for the full anatomy of a stage.

---

## The roadmap

Work through the phases in order. Each phase note lists its stages and the
deliverable you will have at the end.

### [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
Get the tools, cross-compile a tiny kernel, and let GRUB boot it in QEMU.
**Deliverable:** GRUB boots your kernel and it halts cleanly.

### [[Phase 1 - Overview|Phase 1 — Text Output]]
Write to the screen, add colors and scrolling, log over a serial port, and build a
`printf`-style formatter.
**Deliverable:** formatted text on screen and in a serial log.

### [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]
Load the GDT and IDT, handle CPU exceptions, remap the PIC, and take hardware
interrupts.
**Deliverable:** the CPU handles faults and fires interrupt handlers.

### [[Phase 3 - Overview|Phase 3 — Drivers: Timer & Keyboard]]
Drive the timer for a steady tick and read the keyboard into an input buffer.
**Deliverable:** you can type on screen and the clock ticks.

### [[Phase 4 - Overview|Phase 4 — Memory Management]]
Read the memory map, allocate physical frames, turn on paging, and build a kernel
heap.
**Deliverable:** working `kmalloc`/`free` with virtual memory on.

### [[Phase 5 - Overview|Phase 5 — Multitasking]]
Save and restore CPU context, switch between tasks, and let the timer preempt them.
**Deliverable:** two kernel tasks run at the same time.

### [[Phase 6 - Overview|Phase 6 — User Mode & System Calls]]
Set up the TSS, drop to ring 3, and add a system-call interface.
**Deliverable:** a user-mode program asks the kernel for a service.

### [[Phase 7 - Overview|Phase 7 — Filesystem & Program Loading]]
Load a ramdisk, read files through a virtual filesystem, and run an ELF program.
**Deliverable:** the kernel loads and runs a program from a filesystem.

### [[Phase 8 - Overview|Phase 8 — The Shell]]
Build a userspace shell that reads a line, runs built-ins, and launches programs.
**Deliverable:** an interactive shell — your working OS.

---

## Support notes

- **[[01 - How To Use These Docs]]** — how a stage is built and how to work.
- **[[02 - Toolchain Setup (Mac & Windows)]]** — install everything, once.
- **[[03 - Resources & Reading]]** — the master list of books, wikis, and tutorials.
- **[[04 - Glossary]]** — every acronym and term, in plain words.

---

## A word on honesty and pace

OS development is slow the first time. A stage that reads as three lines can cost an
evening, because the machine gives you a blank screen instead of an error message.
This is normal. The docs point you to a **debugging habit** in each phase and to the
**[[03 - Resources & Reading#Debugging|debugging resources]]** so a blank screen
becomes a clue, not a wall.

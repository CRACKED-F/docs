# Phase 6 — User Mode & System Calls

**Goal:** create the wall between the kernel and programs. You will set up the **TSS**
so the CPU can find the kernel stack, drop a program into **ring 3** (user mode, where
it cannot touch hardware or kernel memory), and build a **system call** doorway so a
user program can still ask the kernel for services like "print this" or "exit".

This is what separates a hobby kernel from an operating system: code that runs with
*less* privilege than the kernel and must ask permission to do anything real.

> Prerequisite: **[[Phase 5 - Overview|Phase 5]]** and paging from
> **[[Stage 4.3 - Enabling Paging]]** (user pages need the user bit set).

---

## Why this phase exists

Until now every line of code runs in ring 0 with full power. One bad pointer can wipe
the kernel. User mode fixes that: user programs run isolated, and the **only** way
into the kernel is through system calls you define and check. This is the foundation
for running untrusted programs, and for the shell launching them in
**[[Phase 8 - Overview|Phase 8]]**.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 6.1 | [[Stage 6.1 - The Task State Segment]] | Medium | A TSS the CPU uses on ring switches. |
| 6.2 | [[Stage 6.2 - Entering Ring 3]] | Hard | Code running in user mode. |
| 6.3 | [[Stage 6.3 - The System Call Interface]] | Hard | `int 0x80` calls into the kernel. |
| 6.4 | [[Stage 6.4 - A Minimal User C Library]] | Medium | `write`/`exit` wrappers for programs. |

---

## Deliverable

A program runs in ring 3, cannot directly touch kernel memory or I/O, and calls a
system call (for example `write`) that the kernel handles and returns from. A user
program that tries something illegal is stopped by a fault, not by luck.

---

## Read before you start

- OSDev — *Getting to Ring 3*, *Task State Segment*, *System Calls*:
  <https://wiki.osdev.org/Getting_to_Ring_3> · <https://wiki.osdev.org/Task_State_Segment> ·
  <https://wiki.osdev.org/System_Calls>
- OSTEP — "Limited Direct Execution" (the trap/return model):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Previous: **[[Phase 5 - Overview]]** · Next: **[[Phase 7 - Overview]]**.

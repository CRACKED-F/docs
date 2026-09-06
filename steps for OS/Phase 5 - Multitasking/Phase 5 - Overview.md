# Phase 5 — Multitasking

**Goal:** run more than one thing at once. You will define a **task** (its own stack
and saved registers), switch the CPU from one task to another, let the **timer**
preempt a running task so none can hog the CPU, and add **sleep/blocking** so tasks
can wait without spinning.

This is the heart of what makes an OS an OS. When two counters print at the same time
from two separate tasks, you have built a scheduler.

> Prerequisite: **[[Phase 4 - Overview|Phase 4]]** (you need `kmalloc` for task
> stacks) and the timer from **[[Stage 3.1 - The Programmable Interval Timer]]**.

---

## Why this phase exists

A single-threaded kernel cannot run a shell *and* a background job, or handle a slow
device without freezing. Multitasking is the mechanism for concurrency. Build it in
two steps: first a **cooperative** switch you trigger by hand (easier to get right),
then **preemptive** switching driven by the timer (the real thing).

Read the OSTEP process and scheduling chapters first. The idea of "saving and
restoring a context" is much clearer on paper than in a register dump.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 5.1 | [[Stage 5.1 - Tasks, Context, and the Stack]] | Medium | A task struct and stacks. |
| 5.2 | [[Stage 5.2 - Cooperative Task Switching]] | Hard | `yield()` switches tasks. |
| 5.3 | [[Stage 5.3 - Preemptive Scheduling]] | Hard | The timer forces switches. |
| 5.4 | [[Stage 5.4 - Sleep and Blocking]] | Medium | Tasks wait without spinning. |

---

## Deliverable

Two (or more) kernel tasks run "at the same time": each prints its own output, the
timer switches between them without either calling `yield`, and a sleeping task uses
no CPU until its time is up. You have a working preemptive scheduler.

---

## Read before you start

- OSTEP — "Processes", "Process API", "Scheduling: Introduction":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *Kernel Multitasking* / *Brendan's Multi-tasking Tutorial*:
  <https://wiki.osdev.org/Multitasking_Systems>

Previous: **[[Phase 4 - Overview]]** · Next: **[[Phase 6 - Overview]]**.

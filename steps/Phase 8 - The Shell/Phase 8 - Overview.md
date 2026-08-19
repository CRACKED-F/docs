# Phase 8 — The Shell

**Goal:** put a human in control. You will write a **shell** — a user program that
prints a prompt, reads a line, and runs it. First it handles **built-in commands**
(`help`, `echo`, `ls`), then it **launches other programs** from the filesystem, and
finally it becomes the **init** program the kernel starts at boot. When you type a
command and a program runs and prints its output, you have a working OS.

Everything in this phase is a **user program**. It uses only the syscalls and library
from Phase 6 and the file loading from Phase 7. The kernel does not change much here;
you are finally building *on top of* it.

> Prerequisite: **[[Phase 7 - Overview|Phase 7]]** (load programs) and the user
> library from **[[Stage 6.4 - A Minimal User C Library]]**.

---

## Why this phase exists

An OS with no way to run commands is a library, not a system. The shell is the face of
the OS: it ties input, processes, and the filesystem into one loop a person can use.
It is also the proof that all the earlier phases actually work together.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 8.1 | [[Stage 8.1 - The Shell Read-Eval Loop]] | Medium | A prompt that reads lines. |
| 8.2 | [[Stage 8.2 - Built-in Commands]] | Medium | `help`, `echo`, `ls` built in. |
| 8.3 | [[Stage 8.3 - Launching Programs]] | Hard | Type a program name, it runs. |
| 8.4 | [[Stage 8.4 - init - Wiring It Together]] | Medium | The shell starts at boot. |

---

## Deliverable

The machine boots straight into your shell. You type `ls` and see the files, `echo
hello` and it prints, and the name of a program and it runs and returns you to the
prompt. **This is a working operating system built from nothing.**

---

## Read before you start

- OSTEP — "Process API" (`fork`, `exec`, `wait` — how a shell runs programs):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- xv6 shell (`sh.c`) — a tiny, complete shell to read and learn from:
  <https://github.com/mit-pdos/xv6-public/blob/master/sh.c>

Previous: **[[Phase 7 - Overview]]** · Next: **[[Capstone - You Built an OS]]**.

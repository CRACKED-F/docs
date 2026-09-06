# Stage 8.1 — The Shell Read-Eval Loop

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 8 - Overview|Phase 8 — The Shell]]

---

## Concept

A shell is a simple loop: **print a prompt, read a line, act on it, repeat**. This
stage builds the loop and the input side. It is a **user program** — it reads input
through a `read` syscall and prints through `write`, not by touching the keyboard
driver directly. That is the point: the shell proves the user/kernel boundary works
for real input and output.

You need a working `read` syscall that returns typed lines. If you built the blocking
line buffer in **[[Stage 5.4 - Sleep and Blocking]]**, wire `sys_read` to it now.

---

## Specification

- Ensure a `read(fd, buf, len)` syscall exists that returns a line from the keyboard
  (blocking until Enter), building on the line buffer from
  **[[Stage 3.3 - An Input Line Buffer]]** and the blocking wait from Stage 5.4.
- The shell program loop:
  1. `write` a prompt (for example `"$ "`).
  2. `read` a line into a buffer.
  3. Trim the trailing newline.
  4. (Next stage) parse and act. For now, just echo the line back.
  5. Repeat forever.
- The shell is built as a user ELF program (like "hello" in Phase 6/7), linked against
  the user library.

---

## Your task

1. Make sure `read` returns a full line from the keyboard through the syscall path.
2. Write the shell program: a loop that prints a prompt, reads a line, and echoes it.
3. Build it as a user ELF and place it in the ramdisk.
4. Load and run it with the ELF loader from **[[Stage 7.4 - Loading and Running an ELF Program]]**.
5. Confirm the prompt appears and typed lines echo back.

---

## How to verify

- Booting and running the shell shows a prompt, and each line you type echoes after
  you press Enter.
- The shell runs in ring 3 (it is a user program) and only uses syscalls for I/O.
- Backspace editing from the line buffer still works at the prompt.

---

## Common traps

- The shell trying to read the keyboard port directly — it cannot, it is ring 3. It
  must use `read`.
- `read` not blocking, so the loop spins and reads empty lines.
- Not trimming the newline, so command matching in the next stage fails on an
  invisible character.
- A too-small line buffer that truncates input.

---

## Reading

- xv6 shell `sh.c` (the main loop): <https://github.com/mit-pdos/xv6-public/blob/master/sh.c>
- OSTEP — "Process API" (the read-run loop idea):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 8.2 - Built-in Commands]]**.

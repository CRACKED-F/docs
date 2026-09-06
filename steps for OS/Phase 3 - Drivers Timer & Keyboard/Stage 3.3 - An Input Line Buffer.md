# Stage 3.3 — An Input Line Buffer

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 3 - Overview|Phase 3 — Drivers: Timer & Keyboard]]

---

## Concept

Characters arrive one at a time from an interrupt, but programs want a whole **line**:
"give me what the user typed, up to Enter". This stage adds a buffer between the
interrupt-driven keyboard and the rest of the kernel. The keyboard handler appends
characters; a `readline` function returns the buffer when Enter is pressed. Backspace
erases the last character. This is the exact interface the shell will use.

It also introduces a real concurrency question: the interrupt writes the buffer while
your main code reads it. You will handle that simply for now, and properly once you
have multitasking.

---

## Specification

- Keep a fixed-size line buffer and a length.
- On a printable character: append it and echo it to the screen.
- On **Backspace**: remove the last character and erase it on screen (print
  backspace, space, backspace), if the line is not empty.
- On **Enter**: mark the line "ready", echo a newline.
- `readline(buffer, max)`: block (spin with `hlt` in a loop) until a line is ready,
  then copy it out and reset the buffer.
- Because an interrupt updates the buffer, disable interrupts briefly (`cli`/`sti`)
  around the moment you read and reset it, so a key press mid-copy cannot corrupt it.

---

## Your task

1. Add a line buffer, a length, and a "line ready" flag.
2. In the keyboard path, handle printable characters, Backspace, and Enter as above,
   with on-screen echo.
3. Write `readline(buf, max)` that waits (using `hlt`) for the ready flag, then copies
   and resets the buffer under a short `cli`/`sti`.
4. Test with a loop: `readline` a line, then `kprintf` "you typed: %s".

---

## How to verify

- Typing a line and pressing Enter makes `readline` return exactly that line.
- Backspace erases the last character on screen and in the returned string.
- The echo-and-return loop keeps working over many lines without corruption.

---

## Common traps

- **Race with the interrupt.** Reading and resetting the buffer without briefly
  disabling interrupts can drop or duplicate a character. A short critical section
  fixes it.
- Busy-waiting with a tight `while` (100% CPU) instead of `hlt` in the wait loop.
- Off-by-one on the buffer bound, allowing a write past the end on a long line.
- Not null-terminating the returned string before using it with `%s`.

---

## Reading

- OSDev — *PS/2 Keyboard* (buffering input):
  <https://wiki.osdev.org/PS/2_Keyboard>
- OSTEP — the concurrency intro, for the race idea (skim now, return in Phase 5):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

---

## Phase 3 is complete

Your kernel has a clock and can read typed lines. Commit. These two drivers are the
inputs the scheduler and the shell will build on.

Next phase: **[[Phase 4 - Overview]]**.

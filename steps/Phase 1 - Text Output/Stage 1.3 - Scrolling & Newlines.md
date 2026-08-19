# Stage 1.3 — Scrolling & Newlines

**Difficulty:** Medium · ~25 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Text Output]]

---

## Concept

A real console does two things your driver still cannot: it treats `\n` as "go to the
start of the next line", and when text reaches the bottom row it **scrolls** — every
line moves up one, the top line falls off, and a blank line opens at the bottom.
Without scrolling your kernel's messages vanish off the bottom the moment there are
more than 25 lines.

---

## Specification

- Handle special characters in `print_char`:
  - `\n`: set column to 0, advance the row.
  - `\t` (optional): advance the column to the next multiple of, say, 8.
  - `\r` (optional): set column to 0.
- **Scroll** when the row would pass the last row (24):
  1. Copy each row's memory up by one row (row `n` ← row `n+1`).
  2. Clear the last row to spaces with the current color.
  3. Keep the cursor on the last row.
- The copy is a straightforward `memmove` over the VGA buffer. You may need to write
  your own `memmove`/`memset` since there is no C library; keep them in a `string.cpp`.

---

## Your task

1. Extend `print_char` to handle `\n` (and optionally `\t`, `\r`).
2. Write a `scroll()` function that shifts all rows up by one and clears the bottom
   row.
3. Call `scroll()` whenever advancing the row would move past the last row, and pin
   the cursor to the last row.
4. Write freestanding `memset` and `memmove` if you do not have them yet.
5. Print more than 25 lines and confirm the screen scrolls smoothly.

---

## How to verify

- Printing 30+ lines scrolls the screen; the newest line is always visible at the
  bottom.
- `\n` moves to the start of the next line, not just down one column.
- No garbage row appears at the bottom after a scroll (the new line is cleared).

---

## Common traps

- Copying rows **downward** instead of upward, which duplicates the top line.
- Forgetting to clear the freshly opened bottom row, leaving stale characters.
- Advancing the row past 24 without scrolling, so text writes off the visible area
  (or past the buffer).

---

## Reading

- OSDev — *Printing to Screen* (scrolling section):
  <https://wiki.osdev.org/Printing_to_Screen>
- The Little OS Book, "Output" chapter: <https://littleosbook.github.io>

Next: **[[Stage 1.4 - Serial Port Logging]]**.

# Phase 1 — Text Output

**Goal:** make the kernel talk. You will write text to the screen with color and a
moving cursor, scroll when the screen fills, send the same text out a serial port for
capture, and build a `kprintf` so you can print numbers and strings the way you print
with `printf` on a normal system.

Output is the tool you debug every later phase with. Build it well now.

> Prerequisite: **[[Phase 0 - Overview|Phase 0]]** complete (`make run` boots).

---

## Why this phase exists

Right now your only feedback is one white `A`. That is not enough to debug
interrupts or paging. You need to print messages and values. You also need
**serial** output, because when the kernel crashes the screen freezes but a serial
log is already saved to a file — often the last line tells you what went wrong.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 1.1 | [[Stage 1.1 - The VGA Text Buffer]] | Easy | A character at any screen cell. |
| 1.2 | [[Stage 1.2 - A Terminal Driver]] | Medium | `print`, colors, a tracked cursor. |
| 1.3 | [[Stage 1.3 - Scrolling & Newlines]] | Medium | The screen scrolls when full. |
| 1.4 | [[Stage 1.4 - Serial Port Logging]] | Medium | Logs captured to a file via COM1. |
| 1.5 | [[Stage 1.5 - kprintf, a Formatted Printer]] | Medium | `kprintf("%d %x %s", ...)`. |

---

## Deliverable

`kprintf` prints formatted text to the screen and the serial log, the screen scrolls
correctly, and colors work. You can now narrate what your kernel is doing.

---

## Read before you start

- OSDev — *Printing to Screen* and *VGA Hardware*:
  <https://wiki.osdev.org/Printing_to_Screen> · <https://wiki.osdev.org/VGA_Hardware>
- OSDev — *Serial Ports*: <https://wiki.osdev.org/Serial_Ports>
- The Little OS Book, "Output" chapter: <https://littleosbook.github.io>

Previous: **[[Phase 0 - Overview]]** · Next: **[[Phase 2 - Overview]]**.

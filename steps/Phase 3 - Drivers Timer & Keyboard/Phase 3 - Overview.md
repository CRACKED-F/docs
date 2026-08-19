# Phase 3 — Drivers: Timer & Keyboard

**Goal:** turn the raw IRQ machinery from Phase 2 into two real drivers. The
**timer** (PIT) gives you a steady, counted tick — the heartbeat that will later
drive preemptive multitasking. The **keyboard** turns key presses into characters and
feeds a line buffer, so your kernel can finally read input.

This is the first phase that feels interactive. You type, and the screen answers.

> Prerequisite: **[[Phase 2 - Overview|Phase 2]]** complete (IRQs are delivered).

---

## Why this phase exists

Interrupts alone do nothing useful; they need drivers behind them. The timer is the
clock every scheduler needs (**[[Phase 5 - Overview|Phase 5]]**). The keyboard is how
a human drives the shell (**[[Phase 8 - Overview|Phase 8]]**). Both are small, and
both give immediate, visible feedback, which makes this a satisfying phase after the
heavy theory of Phase 2.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 3.1 | [[Stage 3.1 - The Programmable Interval Timer]] | Medium | A counted tick at a known rate. |
| 3.2 | [[Stage 3.2 - The Keyboard Driver]] | Medium | Key presses turned into characters. |
| 3.3 | [[Stage 3.3 - An Input Line Buffer]] | Medium | A `readline` that returns a typed line. |

---

## Deliverable

The kernel keeps a tick count that rises at a rate you set, and you can type a line of
text that echoes to the screen and is returned to your code when you press Enter. This
line buffer is what the shell will read from later.

---

## Read before you start

- OSDev — *Programmable Interval Timer* and *PS/2 Keyboard*:
  <https://wiki.osdev.org/Programmable_Interval_Timer> · <https://wiki.osdev.org/PS/2_Keyboard>
- The Little OS Book, "Interrupts and Input" (keyboard section):
  <https://littleosbook.github.io>

Previous: **[[Phase 2 - Overview]]** · Next: **[[Phase 4 - Overview]]**.

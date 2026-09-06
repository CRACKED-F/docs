# Stage 3.1 — The Programmable Interval Timer

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 3 - Overview|Phase 3 — Drivers: Timer & Keyboard]]

---

## Concept

The **PIT (Programmable Interval Timer)** is a chip that fires **IRQ 0** at a rate you
choose. It is your kernel's clock. You program it once with a **frequency**, then
count the interrupts it raises. That count is "how long since boot", and later the
tick is what forces a task switch so no program can run forever
(**[[Phase 5 - Overview|Phase 5]]**).

Under the hood the PIT counts down from a **divisor** of a fixed base frequency
(about 1.19318 MHz). You do not pick the frequency directly; you pick the divisor,
and frequency = base ÷ divisor.

---

## Specification

- PIT ports: channel 0 data `0x40`, command `0x43`.
- Base frequency: `1193182` Hz. For a target of `f` Hz, `divisor = 1193182 / f`. A
  common choice is `f = 100` (a 10 ms tick).
- To program channel 0 in "rate generator / lobyte-hibyte" mode: send command `0x36`
  to port `0x43`, then send the divisor low byte, then the high byte, to port `0x40`.
- Register a handler on **IRQ 0** (via `register_irq_handler` from Stage 2.5) that
  increments a global `uint64_t tick`.

---

## Your task

1. Write `pit_init(uint32_t frequency)` that computes the divisor and programs
   channel 0 (`0x36`, then low byte, then high byte).
2. Add a global tick counter and an IRQ 0 handler that increments it.
3. Register that handler and unmask IRQ 0.
4. Optionally, add `sleep(ms)` that busy-waits until the tick count advances by the
   right amount.
5. Print the tick count periodically to watch it rise.

---

## How to verify

- The tick counter rises steadily. At 100 Hz it increases by about 100 each second.
- Printing the tick in a loop shows monotonic growth; it never resets or jumps
  backward.
- A `sleep(1000)` pauses for roughly one second (rough is fine; the PIT is not
  precise).

---

## Common traps

- Sending the divisor bytes in the wrong order (low byte first, then high).
- Integer overflow or truncation when computing the divisor; it must fit in 16 bits,
  so very low frequencies are invalid.
- Forgetting to unmask IRQ 0 at the PIC, so the handler never runs.
- Doing heavy work in the tick handler. Keep it to an increment.

---

## Reading

- OSDev — *Programmable Interval Timer*:
  <https://wiki.osdev.org/Programmable_Interval_Timer>
- OSDev — *Timer Interrupt*: <https://wiki.osdev.org/Timer_Interrupt>

Next: **[[Stage 3.2 - The Keyboard Driver]]**.

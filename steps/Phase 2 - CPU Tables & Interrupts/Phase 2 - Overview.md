# Phase 2 — CPU Tables & Interrupts

**Goal:** teach the CPU how to react to events. You will load two tables the x86
requires — the **GDT** (memory segments and privilege) and the **IDT** (which handler
runs for which interrupt) — then handle CPU **exceptions** (like divide-by-zero), fix
the **PIC** so hardware interrupt numbers do not collide with exceptions, and finally
take real **hardware interrupts**.

This is the hardest conceptual jump in the guide. Read the theory first. When it
works, your kernel stops being a straight-line program and starts *responding*.

> Prerequisite: **[[Phase 1 - Overview|Phase 1]]** complete (you can `kprintf`).

---

## Why this phase exists

Everything interactive depends on interrupts. The keyboard, the timer that drives
multitasking, the system calls user programs make — all of them arrive as interrupts.
The CPU will not deliver a single one until the IDT is loaded and the PIC is
configured. This phase lays that foundation. It produces little visible output, but
nothing after it works without it.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 2.1 | [[Stage 2.1 - The Global Descriptor Table]] | Medium | A GDT you loaded yourself. |
| 2.2 | [[Stage 2.2 - The Interrupt Descriptor Table]] | Medium | An IDT the CPU reads. |
| 2.3 | [[Stage 2.3 - CPU Exception Handlers]] | Hard | Faults print instead of rebooting. |
| 2.4 | [[Stage 2.4 - Remapping the PIC]] | Medium | IRQs moved off the exception range. |
| 2.5 | [[Stage 2.5 - Hardware Interrupts (IRQs)]] | Hard | The CPU delivers hardware interrupts. |

---

## Deliverable

A deliberate divide-by-zero prints a clean "Exception 0" message instead of rebooting
the machine, and a hardware IRQ (you will confirm with the timer in
**[[Phase 3 - Overview|Phase 3]]**) reaches your handler. Interrupts are enabled and
the machine is stable.

---

## Read before you start

- The Little OS Book — "Segmentation" and "Interrupts and Input" chapters:
  <https://littleosbook.github.io>
- OSDev — *GDT Tutorial*, *Interrupt Descriptor Table*, *8259 PIC*:
  <https://wiki.osdev.org/GDT_Tutorial> · <https://wiki.osdev.org/Interrupt_Descriptor_Table> ·
  <https://wiki.osdev.org/8259_PIC>
- Philipp Oppermann — CPU exceptions and interrupts articles (Rust, but the clearest
  explanations): <https://os.phil-opp.com>

Previous: **[[Phase 1 - Overview]]** · Next: **[[Phase 3 - Overview]]**.

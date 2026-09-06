# Stage 2.5 — Hardware Interrupts (IRQs)

**Difficulty:** Hard · ~45 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]

---

> [!warning] SHALLOW NOTE — NOT YET REWRITTEN
> This is the original short spec, kept so nothing is lost. It has **not** been
> rewritten to the depth of [[Stage 2.2 - The TSS and Interrupt Stacks]] yet:
> no tradeoff analysis, no line-by-line code walkthrough, and some of it still
> carries 32-bit assumptions that do not hold in long mode. Treat it as an
> outline, not instructions.

## Concept

With the PIC remapped, hardware interrupts now land on vectors 32–47. This stage adds
handler stubs for those vectors (the **IRQs**), a way to register a C++ callback per
IRQ, and finally **enables interrupts** with the `sti` instruction. After this, the
CPU can be interrupted by hardware at any moment — which is exactly what makes the
timer and keyboard possible in the next phase.

The IRQ stubs look like the exception stubs from Stage 2.3, with one addition: each
must send an **EOI** to the PIC when done.

---

## Specification

- Write 16 assembly stubs for vectors 32–47 (IRQ 0–15). Like the ISR stubs, they push
  the vector number and jump to a common saver, but the common IRQ path calls
  `irq_handler` and sends the EOI.
- Provide `register_irq_handler(irq, callback)` so later drivers attach a function to
  an IRQ without touching assembly.
- `irq_handler(registers_t* r)`: work out the IRQ number from `r->int_no` (vector −
  32), call the registered callback if present, then `pic_send_eoi`.
- Enable interrupts with `sti` only **after** the IDT, PIC remap, and IRQ stubs are
  all in place.

---

## Your task

1. Write the 16 IRQ stubs (again, a NASM macro keeps it short).
2. Write the common IRQ assembly path that saves state, calls `irq_handler`, restores,
   and `iret`s.
3. Implement `register_irq_handler` with a 16-slot callback table.
4. Implement `irq_handler`, remembering to send the EOI even when no callback is
   registered.
5. Run `sti` at the end of setup.
6. Temporarily register a handler on IRQ 0 that prints a dot, to prove IRQs arrive
   (you will replace it with the real timer in **[[Phase 3 - Overview|Phase 3]]**).

---

## How to verify

- After `sti`, the kernel keeps running (does not fault) and, with a temporary IRQ 0
  handler, prints periodic dots — proof hardware interrupts are being delivered and
  acknowledged.
- Removing the EOI makes the dots stop after exactly one, which confirms the EOI is
  doing its job.

---

## Common traps

- **Enabling interrupts too early**, before the IDT/PIC are ready, causing an
  immediate fault.
- **Forgetting the EOI**, so each IRQ line fires exactly once and then goes silent.
- A callback that does slow work or re-enables interrupts carelessly, causing
  re-entry. Keep IRQ handlers short.
- Not masking unused IRQ lines, so spurious interrupts arrive with no handler.

---

## Reading

- OSDev — *IRQ* and *8259 PIC*: <https://wiki.osdev.org/IRQ> · <https://wiki.osdev.org/8259_PIC>
- Philipp Oppermann — "Hardware Interrupts" (clear model, Rust code):
  <https://os.phil-opp.com/hardware-interrupts/>

---

## Phase 2 is complete

The CPU now reacts to faults and hardware. Exceptions print instead of rebooting, and
hardware interrupts reach your handlers. Commit. Next you turn IRQs into real drivers.

Next phase: **[[Phase 3 - Overview]]**.

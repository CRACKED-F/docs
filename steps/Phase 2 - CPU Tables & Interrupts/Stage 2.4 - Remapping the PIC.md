# Stage 2.4 — Remapping the PIC

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]

---

## Concept

Hardware interrupts (keyboard, timer, disk) arrive through the **8259 PIC**. By
default the PIC delivers them on vectors 0–15 — which **collide** with the CPU
exceptions you just handled. A timer tick would look like a divide-by-zero. You must
**remap** the PIC so its interrupts land on vectors 32–47, clear of the exception
range.

There are two PICs, a master and a slave, chained together. Remapping is a fixed
sequence of writes to their command and data ports. It is boilerplate, but the
kernel is unusable until it is done.

---

## Specification

- Master PIC ports: command `0x20`, data `0x21`. Slave PIC ports: command `0xA0`,
  data `0xA1`.
- Remap so the master serves vectors **32–39** (offset `0x20`) and the slave serves
  **40–47** (offset `0x28`).
- The init sequence sends four **ICW** (initialization command word) bytes to each
  PIC: start init (`0x11`), the vector offset, the master/slave wiring (IRQ2 links
  them), and the mode (`0x01` for 8086 mode). Then optionally set the interrupt mask.
- After remapping you also need the **EOI** convention: at the end of every hardware
  interrupt handler, write `0x20` to the PIC command port (both PICs if the IRQ came
  from the slave) so the next interrupt can be delivered.

---

## Your task

1. Write `pic_remap()` that sends the ICW sequence to move the master to `0x20` and
   the slave to `0x28`.
2. Write `pic_send_eoi(irq)` that writes `0x20` to the master, and also to the slave
   when `irq >= 8`.
3. Optionally, write helpers to mask/unmask individual IRQ lines via the data ports.
4. Call `pic_remap()` during setup, after the IDT and before enabling interrupts.
5. Mask all IRQs for now except the ones you will enable in Stage 2.5.

---

## How to verify

- After remapping, enabling interrupts (Stage 2.5) does not instantly fault. If the
  PIC were still on 0–15, the first timer tick would fire your exception handlers.
- When you add the timer in **[[Phase 3 - Overview|Phase 3]]**, ticks arrive on vector
  32, not vector 0 — direct proof the remap worked.

---

## Common traps

- **Sending EOI to only the master for a slave IRQ.** IRQs 8–15 need an EOI to *both*
  PICs, or those lines stop delivering after the first interrupt.
- Wrong offsets, so IRQs still overlap exceptions.
- Enabling interrupts before remapping. A pending tick then hits an exception vector
  and the machine faults.

---

## Reading

- OSDev — *8259 PIC* (has the exact remap sequence):
  <https://wiki.osdev.org/8259_PIC>
- The Little OS Book, "Interrupts and Input": <https://littleosbook.github.io>

Next: **[[Stage 2.5 - Hardware Interrupts (IRQs)]]**.

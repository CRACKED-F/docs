# Stage 5.3 — Preemptive Scheduling

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 5 - Overview|Phase 5 — Multitasking]]

---

## Concept

Cooperative switching trusts every task to call `yield()`. A real OS cannot. **Preemptive**
scheduling uses the **timer interrupt** (IRQ 0) to force a switch: on each tick the
kernel decides whether the current task's turn is up, and if so switches to the next
one. Now a task that never yields is still interrupted, and the CPU is shared fairly.

The subtlety is that the switch now happens **inside an interrupt handler**, on top of
the state the CPU and your IRQ stub already pushed. You must make the timer's switch
consistent with that layout.

---

## Specification

- In the IRQ 0 (timer) handler, increment the tick and, on a time-slice boundary (for
  example every N ticks), call the scheduler to pick the next task and switch to it.
- The switch from interrupt context must save/restore the same context your IRQ stub
  established, so returning to a task later resumes cleanly through `iret`.
- Keep a **time slice** (quantum): switch every few ticks, not every single tick, so
  tasks make progress and switching overhead stays low.
- Guard shared scheduler data. Interrupts are already off inside the handler (you used
  an interrupt gate), which gives you a natural critical section for the task list.
- Idle case: if no task is ready, run a halt loop (`hlt`) rather than busy-spinning.

---

## Your task

1. Extend the timer handler to call the scheduler on a quantum boundary.
2. Make the scheduler pick the next ready task (round-robin) and perform the switch in
   a way consistent with the IRQ stub's saved state.
3. Add an idle task (or an idle path) that `hlt`s when nothing else is ready.
4. Create two tasks that loop **without** calling `yield`, each printing its id.
5. Confirm both still make progress — the timer switches between them on its own.

---

## How to verify

- Two tasks that never call `yield` both keep printing; the timer alone interleaves
  them. This is the proof preemption works.
- Adjusting the quantum changes how coarsely output interleaves.
- With no ready task, CPU usage drops (QEMU host CPU falls) because the idle path
  halts instead of spinning.

---

## Common traps

- **Inconsistent context between the IRQ stub and the switch.** The saved layout must
  line up so the eventual `iret` returns correctly. This is the hardest part; step
  through it in GDB.
- Re-enabling interrupts inside the scheduler at the wrong moment, allowing a nested
  timer interrupt mid-switch.
- Forgetting the EOI to the PIC, so the timer stops after one tick and switching
  freezes.
- Switching every single tick, so the tasks spend all their time context-switching.

---

## Reading

- OSDev — *Kernel Multitasking* (preemption via the timer):
  <https://wiki.osdev.org/Kernel_Multitasking>
- OSTEP — "Scheduling: Introduction" and "Multi-Level Feedback":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 5.4 - Sleep and Blocking]]**.

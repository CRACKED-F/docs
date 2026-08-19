# Stage 5.2 — Cooperative Task Switching

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 5 - Overview|Phase 5 — Multitasking]]

---

## Concept

A **context switch** saves the current task's registers onto its stack, saves its
stack pointer into its task struct, loads the next task's stack pointer, restores its
registers, and returns — now running the other task. In **cooperative** switching, a
task triggers this itself by calling `yield()`. Nothing forces it, so a task that
never yields runs forever. That limitation is fine for this stage; you fix it with the
timer in Stage 5.3.

Cooperative first is the right order: the switch mechanism is identical, but you
control exactly when it happens, so bugs are far easier to find.

---

## Specification

- Write the switch in assembly: `switch_context(old_esp_ptr, new_esp)`.
  1. Push the callee-saved registers (and flags) of the current task.
  2. Save the current `esp` into `*old_esp_ptr`.
  3. Load `esp` from `new_esp`.
  4. Pop the registers in the reverse order.
  5. `ret` — which now returns into the *new* task.
- `yield()` (C++): pick the next ready task (round-robin over the list), then call
  `switch_context(&current->esp, next->esp)` and set `current = next`.
- The pre-filled stack from Stage 5.1 must match this push/pop layout exactly, so a
  brand-new task's first `yield`-in lands at its entry function.

---

## Your task

1. Write the `switch_context` assembly routine with a matched push/pop of
   callee-saved registers and flags.
2. Write `yield()` that selects the next ready task and calls the switch.
3. Reconcile the Stage 5.1 stack pre-fill with this exact register layout.
4. Create two tasks that each loop: print a character, then call `yield()`.
5. Confirm output alternates between the two tasks.

---

## How to verify

- Two tasks that print `A`/`B` and `yield` produce interleaved output (`ABABAB...`),
  proving control passes back and forth.
- A newly created task's first run begins at its entry function (the pre-fill is
  correct).
- Returning to a task resumes exactly where it left off, with its local variables
  intact (they lived on its stack).

---

## Common traps

- **Layout mismatch** between the pre-filled stack and the switch's pop sequence — the
  single most common multitasking bug. Keep them in one mental model.
- Saving `esp` to the wrong task's struct, so a task resumes on another's stack.
- Not saving flags, so interrupt-enable state leaks between tasks (matters more in
  Stage 5.3).
- Clobbering caller-saved registers and assuming they survive the switch.

---

## Reading

- OSDev — *Kernel Multitasking* (the switch routine):
  <https://wiki.osdev.org/Kernel_Multitasking>
- xv6 `swtch.S` (a tiny, clean reference switch — read it):
  <https://github.com/mit-pdos/xv6-public/blob/master/swtch.S>

Next: **[[Stage 5.3 - Preemptive Scheduling]]**.

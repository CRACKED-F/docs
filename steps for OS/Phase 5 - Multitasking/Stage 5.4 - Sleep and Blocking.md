# Stage 5.4 — Sleep and Blocking

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 5 - Overview|Phase 5 — Multitasking]]

---

## Concept

A task that waits — for a second to pass, or for a key press — should not burn the CPU
spinning. **Blocking** removes a task from the ready list so the scheduler skips it,
and **unblocking** puts it back when its condition is met. `sleep(ms)` is the first
example: the task blocks, and the timer wakes it when enough ticks have passed. This
turns the busy-wait `readline` from Stage 3.3 into a proper blocking wait later.

---

## Specification

- Add task states: **ready**, **running**, **blocked/sleeping**. The scheduler only
  picks ready tasks.
- `sleep(ms)`: compute a wake tick (`current_tick + ms * ticks_per_ms`), set the
  task's state to sleeping, record the wake tick, and yield to the scheduler.
- In the timer handler, before scheduling, scan sleeping tasks and mark any whose wake
  tick has passed as ready again.
- Generalize to a **block/unblock** pair: a task blocks on some condition; the code
  that satisfies the condition (for example the keyboard handler) unblocks it.
- If every task is blocked, run the idle path.

---

## Your task

1. Add the sleeping state and a wake-tick field to the task struct.
2. Implement `sleep(ms)` that blocks the current task and yields.
3. In the timer handler, wake any sleeping task whose time has come.
4. Add generic `block(task)` and `unblock(task)` helpers.
5. Convert the keyboard line buffer (**[[Stage 3.3 - An Input Line Buffer]]**) so
   `readline` blocks the calling task and the keyboard IRQ unblocks it on Enter.
6. Test: a task that sleeps one second wakes on time while another task runs.

---

## How to verify

- A task calling `sleep(1000)` pauses for about a second and then resumes, while other
  tasks keep running during the wait.
- A sleeping task consumes no CPU (the scheduler skips it; the idle path halts).
- `readline` now blocks its task instead of busy-waiting, and typing wakes it.

---

## Common traps

- Waking a task by tick comparison with a wraparound bug; use a wide enough tick type
  (64-bit) so it does not overflow.
- Unblocking from an interrupt without care, racing the scheduler's view of the task
  list.
- Leaving a task blocked forever because the unblock path is never reached (a lost
  wake-up). Check every block has a matching unblock.
- Forgetting the idle path, so an all-blocked system spins or hangs.

---

## Reading

- OSTEP — "Condition Variables" and "Semaphores" (the block/unblock idea):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *Kernel Multitasking* (blocking states):
  <https://wiki.osdev.org/Kernel_Multitasking>

---

## Phase 5 is complete

Your kernel runs many tasks, the timer shares the CPU fairly, and waiting tasks sleep
instead of spinning. Commit. Next you separate user programs from the kernel.

Next phase: **[[Phase 6 - Overview]]**.

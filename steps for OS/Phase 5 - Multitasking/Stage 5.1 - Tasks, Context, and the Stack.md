# Stage 5.1 — Tasks, Context, and the Stack

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 5 - Overview|Phase 5 — Multitasking]]

---

## Concept

A **task** is "a CPU in progress": the registers it is using and the stack it is
running on. To run two tasks, you keep two of these and swap between them. This stage
does no switching yet — it defines the task, gives each its own stack, and builds a
list of tasks. Getting the data model right makes the switch in Stage 5.2 much easier.

The key idea: a task that is **not** running is fully described by its **saved stack
pointer**. Everything else it needs is sitting on its own stack. So a task struct can
be as small as "a stack pointer plus some bookkeeping".

---

## Specification

- A `task` struct with at least: a saved kernel stack pointer (`esp`), a unique id, a
  state (running / ready / sleeping), and a link to the next task (a circular list is
  convenient for round-robin).
- Each task gets its own stack, allocated with `kmalloc` (for example 16 KiB), used
  top-down.
- To make a **new** task start at a function, you **pre-fill** its stack so that the
  first context switch "returns" into that function. Lay the stack out to look exactly
  as if the task had already been switched away from: pushed registers, then the entry
  address where a `ret` will jump.
- Keep a pointer to the **current** task and a list of ready tasks.

---

## Your task

1. Define the `task` struct and a global "current task" pointer and task list.
2. Write `create_task(entry_function)`: allocate a stack, pre-fill it so the first
   switch enters `entry_function`, and add the task to the list.
3. Turn the code already running into "task 0" so the current pointer is always valid.
4. Print the task list (ids and states) to confirm creation works.
5. Do **not** switch yet — that is Stage 5.2.

---

## How to verify

- Creating several tasks builds a list with distinct ids and separate stack regions
  (print the stack addresses; they must not overlap).
- The current-task pointer is valid from the moment the kernel's own execution is
  registered as task 0.
- Stack pre-fill layout matches exactly what your Stage 5.2 switch code will pop — you
  will confirm this fully when the first switch lands in the entry function.

---

## Common traps

- Stack pre-fill order not matching the switch's pop order, so the first switch jumps
  to a garbage address. Design both together.
- Overlapping stacks from a `kmalloc` size mistake, so one task corrupts another.
- Forgetting to register the initial execution as a task, so the first switch has
  nowhere to save the outgoing context.
- Stacks too small; deep calls or interrupts overflow them. 16 KiB is a safe start.

---

## Reading

- OSDev — *Kernel Multitasking* (task/context model):
  <https://wiki.osdev.org/Kernel_Multitasking>
- OSTEP — "Processes" and "Limited Direct Execution":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 5.2 - Cooperative Task Switching]]**.

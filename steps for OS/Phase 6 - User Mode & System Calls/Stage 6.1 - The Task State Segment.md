# Stage 6.1 — The Task State Segment

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 6 - Overview|Phase 6 — User Mode & System Calls]]

---

## Concept

When a user program (ring 3) is interrupted or makes a system call, the CPU must
switch to a **kernel** stack — it cannot keep using the user's stack, which may be
invalid or malicious. Where does the CPU find that kernel stack? In the **Task State
Segment (TSS)**. You fill the TSS with the kernel stack pointer and segment, add a
descriptor for it to the GDT, and load it. From then on, every ring 3 → ring 0
transition uses the stack you named.

This stage builds the TSS now, so ring 3 in the next stage has a safe landing.

---

## Specification

- The TSS is a structure the CPU reads on a privilege change. For this guide the only
  fields that matter are `ss0` (kernel stack segment) and `esp0` (kernel stack
  pointer). The rest can be zero.
- Add a **TSS descriptor** to the GDT (extending **[[Stage 2.1 - The Global Descriptor Table]]**).
  Add user code and user data segment descriptors too (ring 3 versions of your code
  and data segments) — you need them in Stage 6.2.
- Load the TSS with the `ltr` instruction, using the TSS descriptor's selector.
- Update `esp0` whenever you switch tasks, so a trap always lands on the current
  task's kernel stack.

---

## Your task

1. Extend the GDT with: user code, user data, and a TSS descriptor.
2. Define the TSS struct and a single global instance.
3. Set `ss0` to the kernel data selector and `esp0` to a kernel stack top.
4. Load the TSS with `ltr` after loading the GDT.
5. Hook task switching (**[[Phase 5 - Overview|Phase 5]]**) to update `esp0` to the
   incoming task's kernel stack.

---

## How to verify

- The kernel still boots and runs after `ltr` (a bad TSS descriptor faults, so simply
  surviving is the first check).
- The GDT now has six entries (null, kernel code/data, user code/data, TSS); dumping
  it in Bochs shows them.
- Full confirmation comes in Stage 6.2: a system call from ring 3 correctly lands on
  the `esp0` stack you set here.

---

## Common traps

- Wrong TSS descriptor type or limit, which triple-faults on `ltr`.
- Setting `esp0` to a stack that is too small or shared, so nested traps corrupt it.
- Forgetting to update `esp0` on task switch, so a trap in one task lands on another's
  kernel stack.
- Loading the wrong selector into `ltr` (it must be the TSS descriptor's selector).

---

## Reading

- OSDev — *Task State Segment*: <https://wiki.osdev.org/Task_State_Segment>
- OSDev — *Getting to Ring 3* (TSS section):
  <https://wiki.osdev.org/Getting_to_Ring_3>

Next: **[[Stage 6.2 - Entering Ring 3]]**.

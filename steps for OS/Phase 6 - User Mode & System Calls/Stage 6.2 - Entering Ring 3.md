# Stage 6.2 — Entering Ring 3

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 6 - Overview|Phase 6 — User Mode & System Calls]]

---

## Concept

**Ring 3** is user privilege: no port I/O, no privileged instructions, and (with
paging) no access to kernel-only pages. The CPU does not have a "go to ring 3"
instruction. Instead you **fake an interrupt return**: you build a stack that looks
exactly like the CPU just interrupted a ring 3 program, then run `iret`. The CPU
"returns" into user mode. This is the standard trick, and it reuses the `iret` you
already know from interrupt handlers.

---

## Specification

- Map the user program's code and stack pages with the **user bit** set (bit 2) in
  their page-table entries (**[[Stage 4.3 - Enabling Paging]]**), or user mode cannot
  even fetch its own instructions.
- To enter ring 3, push onto the current (kernel) stack, in this order, then `iret`:
  1. the **user data selector** (with ring-3 bits) for `ss`,
  2. the user stack pointer `esp`,
  3. the `eflags` value (with the interrupt flag set so interrupts stay on),
  4. the **user code selector** (with ring-3 bits) for `cs`,
  5. the user entry `eip`.
- Load the user **data** segment selectors into `ds/es/fs/gs` before the `iret`.
- The ring bits (the low two bits of a selector, the **RPL**) must be `3` for user
  selectors.

---

## Your task

1. Confirm your user code/data GDT selectors from Stage 6.1 and OR in the ring-3 bits.
2. Map a small user code page (containing a test function) and a user stack page with
   the user bit set.
3. Write an assembly routine that loads the user data selectors, pushes the five
   values above, and runs `iret`.
4. Point the user entry at a tiny routine that loops (do not call kernel functions —
   it cannot).
5. Confirm the program runs in ring 3.

---

## How to verify

- The test routine runs (you can prove it by having it make the system call you add in
  Stage 6.3; until then, use a debugger).
- In GDB or Bochs, `cs` shows ring 3 (its low two bits are `3`) while the test routine
  runs.
- A deliberate privileged action in the user routine (for example an `out`
  instruction, or touching a kernel-only page) causes a **general protection fault** or
  **page fault** — proof the privilege wall is real.

---

## Common traps

- **Kernel-only pages.** If the user code or stack pages lack the user bit, the CPU
  page-faults immediately on entry. This is the most common ring-3 bug.
- Forgetting the RPL (ring bits) on the selectors, so the `iret` does not actually
  drop privilege.
- Not loading the user data selectors before `iret`.
- Clearing the interrupt flag in the pushed `eflags`, so the timer stops and the
  system appears to hang in user mode.

---

## Reading

- OSDev — *Getting to Ring 3* (the `iret` trampoline):
  <https://wiki.osdev.org/Getting_to_Ring_3>
- Intel SDM Vol. 3, "Protection" and "Interrupt/Exception handling" (reference):
  <https://www.intel.com/sdm>

Next: **[[Stage 6.3 - The System Call Interface]]**.

# Stage 2.3 — CPU Exception Handlers

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]

---

> [!warning] SHALLOW NOTE — NOT YET REWRITTEN
> This is the original short spec, kept so nothing is lost. It has **not** been
> rewritten to the depth of [[Stage 2.2 - The TSS and Interrupt Stacks]] yet:
> no tradeoff analysis, no line-by-line code walkthrough, and some of it still
> carries 32-bit assumptions that do not hold in long mode. Treat it as an
> outline, not instructions.

## Concept

Vectors 0–31 are reserved by the CPU for **exceptions**: divide-by-zero (0),
invalid opcode (6), general protection fault (13), page fault (14), and more. Right
now any of these triple-faults and reboots the machine. This stage makes them call a
handler that prints what happened. That single change turns silent reboots into
readable error messages — the biggest debugging upgrade in the whole guide.

The tricky part is the **calling convention**. The CPU does not enter a C++ function
cleanly; it pushes some state and expects you to save the rest. So each vector points
at a tiny **assembly stub** that saves registers, calls one common C++ handler, then
restores and returns with `iret`.

---

## Specification

- Write 32 assembly stubs, one per vector 0–31. Each:
  1. (For vectors that do **not** push an error code) push a dummy 0 so every stub
     has the same stack layout.
  2. Push the interrupt number.
  3. Jump to a common stub that saves all general registers (`pusha`), saves the data
     segment, loads the kernel data segment, and calls the C++ handler with a pointer
     to the saved state.
  4. On return, restore everything and `iret`.
- **Error codes:** vectors 8, 10–14, and 17 push an error code automatically; the
  others do not. Match your dummy-push logic to this list so the stack layout is
  identical for all.
- Define a `registers_t` struct that mirrors exactly what the stub pushed, in order.
  The C++ handler reads fault details from it.
- The common C++ handler `isr_handler(registers_t* r)` looks up `r->int_no` and
  `kprintf`s a message. For now, halt after an unhandled exception.

---

## Your task

1. Write the 32 assembly stubs (a NASM macro makes this short: one macro for
   "pushes error code", one for "does not").
2. Write the common assembly stub that saves state, calls `isr_handler`, restores,
   and `iret`s.
3. Define `registers_t` matching the push order exactly.
4. Register all 32 stubs in the IDT with `idt_set_gate`.
5. Write `isr_handler` that prints the vector number (and a name, if you like).
6. Test: run a divide-by-zero and a breakpoint `int3`; confirm each prints its
   vector.

---

## How to verify

- A deliberate `int $3` prints "Exception 3" (or your breakpoint message) and the
  kernel continues or halts cleanly — no reboot.
- A divide-by-zero prints "Exception 0".
- The printed values (like the faulting instruction pointer in `registers_t`) look
  sane, which confirms the struct matches the stub's push order.

---

## Common traps

- **Struct/stub mismatch.** If `registers_t` field order does not match the push
  order, every value is shifted and nonsense. Get this exactly right.
- **Error-code inconsistency.** Forgetting the dummy push on no-error-code vectors
  shifts the stack for half your handlers.
- Not reloading the kernel data segment inside the stub, which matters once user mode
  exists.
- Returning with `ret` instead of `iret`. Interrupt returns must use `iret`.

---

## Reading

- OSDev — *Interrupt Service Routines* and *Exceptions*:
  <https://wiki.osdev.org/Interrupt_Service_Routines> · <https://wiki.osdev.org/Exceptions>
- JamesM's tutorial, "The GDT and IDT" and "IRQs and the PIT" (check the errata):
  <http://www.jamesmolloy.co.uk/tutorial_html/> ·
  <https://wiki.osdev.org/James_Molloy's_Tutorial_Known_Bugs>

Next: **[[Stage 2.4 - Remapping the PIC]]**.

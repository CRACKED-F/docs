# Stage 6.3 — The System Call Interface

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 6 - Overview|Phase 6 — User Mode & System Calls]]

---

## Concept

A ring 3 program cannot do I/O itself, so it must **ask** the kernel. A **system
call** is the controlled doorway: the program puts a call number and arguments in
registers, runs a software interrupt (`int 0x80`), and the CPU traps into a kernel
handler that runs the request at ring 0 and returns a result. This is the only way in,
and the kernel checks every request — which is the whole point of the privilege wall.

---

## Specification

- Add an IDT entry for vector `0x80` as an interrupt gate whose **DPL is 3**, so ring 3
  is allowed to invoke it. (Other gates keep DPL 0.)
- Calling convention (a common simple choice): `eax` = syscall number, `ebx`, `ecx`,
  `edx` = arguments. The handler returns the result in `eax`.
- The `int 0x80` stub saves state (like other interrupts), calls a C++
  `syscall_handler(registers_t*)`, and returns through `iret`. The handler reads the
  number from the saved `eax` and dispatches.
- Start with two calls: `sys_write(fd, buf, len)` (print to screen/serial) and
  `sys_exit(code)` (end the current task). Grow the table later.
- **Validate arguments.** A user pointer must be checked before the kernel reads it, or
  a program can trick the kernel into reading kernel memory. At minimum, reject
  pointers into the kernel's address range.

---

## Your task

1. Register vector `0x80` with a DPL-3 interrupt gate.
2. Write the `int 0x80` assembly stub that saves state and calls `syscall_handler`.
3. Write `syscall_handler` that dispatches on the saved `eax` through a small table.
4. Implement `sys_write` and `sys_exit`, validating any user pointers first.
5. From the ring-3 test routine (Stage 6.2), set the registers and run `int 0x80` to
   print a string.
6. Confirm the string prints and the program can exit cleanly.

---

## How to verify

- The ring-3 test program calls `write` and its text appears on screen and serial —
  proof a user program reached the kernel and back.
- `exit` ends the task and the scheduler moves on.
- A `write` with a pointer into kernel memory is **rejected**, not served — proof the
  validation works.
- The return value arrives in `eax` in the user program.

---

## Common traps

- **DPL of the `0x80` gate left at 0**, so `int 0x80` from ring 3 itself faults with a
  general protection fault. It must be 3.
- Trusting user pointers. Always validate before dereferencing; this is a real
  security boundary even in a hobby OS.
- Clobbering the saved registers so the return value or the resumed user state is
  wrong.
- Forgetting that the kernel now runs on the `esp0` stack from the TSS — keep that
  stack valid.

---

## Reading

- OSDev — *System Calls*: <https://wiki.osdev.org/System_Calls>
- OSTEP — "Limited Direct Execution" (traps and the syscall boundary):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 6.4 - A Minimal User C Library]]**.

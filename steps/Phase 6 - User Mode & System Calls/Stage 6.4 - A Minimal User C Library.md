# Stage 6.4 — A Minimal User C Library

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 6 - Overview|Phase 6 — User Mode & System Calls]]

---

## Concept

Writing `int 0x80` by hand in every program is painful. A tiny **user library** wraps
each system call in a normal C++ function: `write(...)`, `exit(...)`, later `read`,
`open`, `exec`. User programs link against this library and call plain functions,
while the library hides the register setup and the software interrupt. This is the
seed of a real libc, and it is what the shell and its programs will call in
**[[Phase 8 - Overview|Phase 8]]**.

---

## Specification

- A `syscall` wrapper in assembly or inline assembly that loads `eax` (number) and the
  argument registers, runs `int 0x80`, and returns `eax`.
- C++ wrappers: `int write(int fd, const void* buf, size_t len);`,
  `void exit(int code);`, and stubs for the calls you will add (`read`, `open`,
  `exec`).
- A **crt0** entry: a small startup that the linker makes the program's real entry
  point. It calls `main`, then calls `exit(main_return_value)` so a program that just
  returns still exits cleanly.
- Build user programs as **separate ELF binaries** linked at a user virtual address,
  against this library and `crt0`. They are not part of the kernel binary.

---

## Your task

1. Write the low-level `syscall` wrapper.
2. Write `write` and `exit` C++ wrappers over it (and stubs for future calls).
3. Write `crt0` that calls `main` and then `exit`.
4. Set up a small build for user programs: compile, link against `crt0` + the library
   at a fixed user load address, output an ELF.
5. Build a "hello" user program that calls `write` and returns.
6. For now, load it the crude way (embed or place it at a known address) and enter it
   with the ring-3 path from Stage 6.2 to confirm the library works. Real loading from
   a filesystem comes in **[[Phase 7 - Overview|Phase 7]]**.

---

## How to verify

- The "hello" program, written with plain `write("...")` and a normal `main`, prints
  its text through the syscall path.
- Returning from `main` exits cleanly via `crt0` → `exit`.
- The program is a standalone ELF file, separate from the kernel binary.

---

## Common traps

- Linking the user program at a kernel address instead of a user virtual address.
- Forgetting `crt0`, so a program that returns from `main` falls off into garbage
  instead of calling `exit`.
- Inline-assembly clobber lists that do not list the registers the syscall uses,
  letting the compiler assume they survived.
- Depending on kernel headers or kernel functions from user code — the two must not
  share code that touches ring-0 state.

---

## Reading

- OSDev — *System Calls* and *Creating a C Library*:
  <https://wiki.osdev.org/System_Calls> · <https://wiki.osdev.org/Creating_a_C_Library>
- xv6 user library (`user/`) as a compact reference:
  <https://github.com/mit-pdos/xv6-public>

---

## Phase 6 is complete

You have a real privilege boundary: user programs run isolated in ring 3 and reach the
kernel only through validated system calls, wrapped in a small library. Commit. Next
you give programs a filesystem to live in.

Next phase: **[[Phase 7 - Overview]]**.

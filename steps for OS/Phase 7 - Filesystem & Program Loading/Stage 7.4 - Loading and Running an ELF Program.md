# Stage 7.4 — Loading and Running an ELF Program

**Difficulty:** Hard · ~1.5 hours
**Phase:** [[Phase 7 - Overview|Phase 7 — Filesystem & Program Loading]]

---

## Concept

Your user programs are **ELF** files (the same format as the kernel). To run one from
the filesystem, the kernel must act as a **loader**: read the ELF headers, copy each
part of the file to the virtual address it wants, set up a fresh user stack, and jump
to the program's entry point in ring 3. This is exactly what `exec` does on a real OS,
and it is the final mechanism before the shell can launch programs by name.

---

## Specification

- An ELF file starts with an **ELF header**: a magic number (`0x7F 'E' 'L' 'F'`), the
  entry-point address, and the offset and count of **program headers**.
- Each **program header** of type `PT_LOAD` describes a segment: a file offset, a
  virtual address to load it at, a size in the file, and a (possibly larger) size in
  memory. For each: map user pages at its virtual address, copy the file bytes, and
  zero the remainder (for `.bss`).
- Build a **new address space** (a fresh page directory) for the program so it is
  isolated, mapping the kernel into it as well (needed for syscalls to work). Load the
  segments there.
- Allocate and map a **user stack**. Set the task's entry to the ELF entry-point and
  enter ring 3 with the Phase 6 trampoline.
- Add a `sys_exec(path)` (and later `fork`) so programs and the shell can start
  programs.

---

## Your task

1. Define the ELF header and program-header structs; check the magic number.
2. Create a new page directory for the program and map the kernel into it.
3. For each `PT_LOAD` header: map user pages, copy file data, zero the rest.
4. Allocate and map a user stack.
5. Set up a task whose entry is the ELF entry-point and run it in ring 3.
6. Wire `sys_exec(path)`: open the file through the VFS, load it, and start it.
7. Test: load the "hello" ELF from the ramdisk and run it.

---

## How to verify

- The "hello" program, read from the ramdisk as an ELF file (not baked into the
  kernel), loads and prints through its syscalls.
- The program runs in ring 3 with its own address space; a fault in it does not take
  down the kernel.
- Loading a second, different program works without residue from the first.

---

## Common traps

- Copying by **file offset** into the wrong **virtual address**, or ignoring the
  difference between file size and memory size (missing the zeroed `.bss`).
- Not mapping the kernel into the new address space, so the first syscall (which runs
  kernel code) page-faults.
- Forgetting the user bit on the program's pages (see **[[Stage 6.2 - Entering Ring 3]]**).
- Reusing one page directory for every program, so they overwrite each other.
- An unaligned or too-small user stack.

---

## Reading

- OSDev — *ELF* and *ELF Tutorial*:
  <https://wiki.osdev.org/ELF> · <https://wiki.osdev.org/ELF_Tutorial>
- OSTEP — "Process API" (`fork`/`exec` model):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

---

## Phase 7 is complete

Your OS has files and can load and run programs from them, each isolated in its own
address space. Commit. Only one piece is left: a program that lets a human drive all
of this — the shell.

Next phase: **[[Phase 8 - Overview]]**.

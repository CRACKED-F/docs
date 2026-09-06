# Stage 8.3 — Launching Programs

**Difficulty:** Hard · ~1 hour
**Phase:** [[Phase 8 - Overview|Phase 8 — The Shell]]

---

## Concept

The real power of a shell is running **other programs**. When you type a name that is
not a built-in, the shell finds a matching file, starts it as a new process, waits for
it to finish, and returns to the prompt. On a real OS this is `fork` + `exec` + `wait`.
You can start with a simpler `spawn(path)` that loads and runs a program and waits for
it, then add `fork`/`exec` separately if you want the classic model.

This stage connects every earlier phase: the filesystem finds the program, the ELF
loader (**[[Stage 7.4 - Loading and Running an ELF Program]]**) loads it, the scheduler
runs it, and the syscall boundary keeps it contained.

---

## Specification

- Add process-control syscalls. The simplest workable set:
  - `spawn(path, argv)` — load the ELF at `path`, create a process, return a handle;
    **or** the classic pair `fork()` (duplicate the current process) and
    `exec(path, argv)` (replace the current image).
  - `wait(handle)` — block the shell until the child exits, returning its exit code.
- `exec` reuses the ELF loader: build a new address space, load the segments, set up
  the user stack (with `argv` on it), and enter ring 3.
- Pass `argv` to the new program by copying the arguments onto its user stack in the
  layout its `crt0`/`main` expects.
- On child exit (`sys_exit`), record the exit code and unblock any waiting parent.

---

## Your task

1. Implement `spawn(path, argv)` (or `fork` + `exec`) in the kernel, reusing the ELF
   loader and the ring-3 entry.
2. Copy `argv` onto the new program's user stack.
3. Implement `wait` so the shell blocks until the child exits and gets its exit code.
4. In the shell, when a command is not a built-in, try to `spawn` a file of that name
   and `wait` for it.
5. Build a couple of test user programs (for example a `cat` that prints a file) and
   place them in the ramdisk.
6. Test: type a program name, watch it run, and return to the prompt.

---

## How to verify

- Typing the name of a program in the ramdisk runs it; its output appears and the
  prompt returns.
- The shell **waits** — the prompt comes back only after the program exits, and the
  exit code is available.
- A program that crashes (faults) is stopped by the kernel and control returns to the
  shell; the shell survives.
- Passing arguments works: `cat somefile` prints that file.

---

## Common traps

- The parent not blocking in `wait`, so the prompt returns before the child runs.
- `argv` copied to the wrong place on the user stack, so the program sees garbage
  arguments.
- Not freeing the child's frames/address space on exit, leaking memory each run.
- A crashed child taking down the shell because faults are not isolated per process —
  make sure a user fault kills only that process.

---

## Reading

- OSTEP — "Process API" (`fork`, `exec`, `wait` explained with diagrams):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- xv6 `exec.c` and `sh.c` (a complete, small `exec` and the shell that calls it):
  <https://github.com/mit-pdos/xv6-public/blob/master/exec.c>

Next: **[[Stage 8.4 - init - Wiring It Together]]**.

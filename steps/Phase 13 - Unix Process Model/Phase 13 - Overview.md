# Phase 13 — The Unix Process Model

**Goal:** become a Unix. You will implement **`fork` with copy-on-write**, **pipes**,
**signals**, a **TTY layer** with line discipline and job control, a real **`malloc`**
for userspace, and enough **libc** that ordinary C programs compile and run.

At the end of this phase `ls | grep foo | wc -l` works, `Ctrl-C` kills the foreground
job, and `Ctrl-Z` suspends it.

> Prerequisite: [[Phase 8 - Overview|Phase 8]] (shell and syscalls),
> [[Phase 4 - Overview|Phase 4]] (paging — COW is a page-fault trick),
> [[Phase 10 - Overview|Phase 10]] (a real filesystem to exec from).

---

## Why this phase exists

The v1 vault's process model was a single `spawn(path)` that loaded a program and
waited for it. That is enough to say "the shell runs programs" and not enough to be
a Unix.

Everything a shell actually does — pipelines, background jobs, `Ctrl-C`, redirection,
`$?` — rests on four primitives v1 did not have: **`fork`**, **file descriptors as
first-class inheritable objects**, **pipes**, and **signals**. See
[[05 - Gap Analysis (v1 to Product)]], gaps C11–C16.

This is also the phase where userspace stops being a demonstration and becomes a
place you can write software. Without `malloc` and a real libc, every user program is
a special case.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 13.1 | Stage 13.1 - The File Descriptor Table | Medium | Per-process fds, `dup`, `dup2`, close-on-exec |
| 13.2 | Stage 13.2 - fork | Hard | A child process that is a copy of its parent |
| 13.3 | Stage 13.3 - Copy-on-Write | **Hard** | `fork` that does not copy memory until written |
| 13.4 | Stage 13.4 - exec and Argument Passing | Hard | `execve` with `argv` and `envp` |
| 13.5 | Stage 13.5 - wait, exit codes, and Zombies | Medium | `waitpid`, exit status, orphan reparenting |
| 13.6 | Stage 13.6 - Pipes | Hard | `pipe()`, blocking reads, EOF, SIGPIPE |
| 13.7 | Stage 13.7 - Signals | **Hard** | Delivery, handlers, masks, the signal trampoline |
| 13.8 | Stage 13.8 - The TTY Layer and Line Discipline | Hard | Canonical mode, echo, editing, `Ctrl-C`/`Ctrl-D`/`Ctrl-Z` |
| 13.9 | Stage 13.9 - Process Groups and Job Control | Hard | Foreground/background, `SIGTTIN`/`SIGTTOU`, `jobs`/`fg`/`bg` |
| 13.10 | Stage 13.10 - Userspace malloc | Medium | `brk`/`mmap` and a real allocator |
| 13.11 | Stage 13.11 - Filling Out libc | Medium | `stdio`, `string`, `stdlib`, `time` — enough to port programs |
| 13.12 | Stage 13.12 - A Real Shell | Hard | Pipelines, redirection, job control, `$?`, quoting |

---

## Deliverable

```
$ ls | grep .txt | wc -l
3
$ cat bigfile > copy.txt
$ sleep 100 &
[1] 42
$ jobs
[1]+ Running    sleep 100
$ fg
sleep 100
^C
$ echo $?
130
```

Every line of that requires a different piece of this phase. It is the most
satisfying deliverable in the project.

---

## The hard parts, named in advance

**`fork` is genuinely strange the first time.** One call returns twice, in two
different address spaces, with different return values. Implementing it means
constructing a second process whose saved register state is identical to the caller's
except `rax`, and whose address space is a copy.

**Copy-on-write is a page-fault trick.** Rather than copying every page, mark both
parent's and child's pages **read-only** and share the frames, with a per-frame
reference count. On a write, the fault handler sees a write to a read-only-but-COW
page, allocates a fresh frame, copies, and remaps it writable.

The traps here are specific and each costs a day:
- Forgetting that the **reference count must be atomic** on SMP.
- Forgetting to handle a COW fault where refcount is already 1 — just remap writable,
  do not copy.
- Forgetting that the **kernel** writing to a user COW page (via `copy_to_user`) must
  also trigger the copy.

**Signals are the subtlest thing in this phase.** Delivering a signal means
manipulating the *user* stack from the kernel so that on return to user mode the
handler runs, and when the handler returns, execution resumes where it was
interrupted. That is done by pushing a fake frame plus a **trampoline** that calls
`sigreturn`. Interactions to get right: signals during a blocking syscall (restart or
`EINTR`?), signals with a mask, nested signals, and a signal arriving on a different
core than the target is running on.

**The TTY layer is where line editing actually belongs.** v1 put a line buffer in the
keyboard driver. That is the wrong layer: line discipline (echo, backspace, `Ctrl-C`
generating `SIGINT`, `Ctrl-D` generating EOF) is a property of the terminal, not the
keyboard, and it must sit between the keyboard and the process's `stdin` so it can
also serve serial consoles. This is a refactor of Phase 3 work, and it is expected.

**Zombies are not a bug.** A process that exits must keep its exit status until its
parent calls `wait`. Reaping too early loses the status; never reaping leaks the
process table. Orphans get reparented to `init`, which is why `init` must loop on
`wait` forever.

---

## Why COW and not a simple copying fork

A copying `fork` is much simpler and is a legitimate intermediate step — Stage 13.2
builds exactly that, and Stage 13.3 upgrades it.

But a copying `fork` makes the standard Unix idiom `fork(); exec()` absurd: you copy
the entire address space and then immediately discard it. For a shell running a
pipeline, that is several copies of everything per command. COW is not an
optimisation here, it is what makes the process model usable.

---

## Testing

| Tier | What |
|---|---|
| 1 | fd table allocation and `dup2` semantics; signal mask arithmetic; the allocator's free-list logic; `argv`/`envp` stack layout construction |
| 2 | `fork` produces a child with a distinct address space; a COW write triggers exactly one copy and refcounts return to 1; a signal handler runs and returns correctly |
| 3 | The full deliverable above, driven over serial. Plus: a fork bomb is contained; a pipeline with a slow reader blocks the writer correctly; `Ctrl-C` kills only the foreground group |

---

## Read before you start

- OSTEP — "Process API", "Interlude: Process API", and the "Concurrency" chapters:
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- xv6 — `proc.c`, `exec.c`, `pipe.c`, `sh.c`. The clearest small implementation of
  all of this in existence: <https://github.com/mit-pdos/xv6-public>
- Stevens & Rago, *Advanced Programming in the UNIX Environment* — chapters on
  process control, signals, and terminal I/O. The definitive description of the
  semantics you are implementing.
- OSDev — *Signals*, *Terminals*: <https://wiki.osdev.org/Signals>
- POSIX.1-2024 — the specification for `fork`, `execve`, `waitpid`, `sigaction`,
  `termios`. Read the RATIONALE sections; they explain the edge cases.

Previous: [[Phase 12 - Overview]] · Next: [[Phase 14 - Overview]]

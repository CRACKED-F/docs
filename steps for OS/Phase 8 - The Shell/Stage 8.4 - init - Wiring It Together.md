# Stage 8.4 — init: Wiring It Together

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 8 - Overview|Phase 8 — The Shell]]

---

## Concept

A real OS does not run the shell from hard-coded kernel calls. It starts one first
user program — **init** — and init starts the shell. This is the clean boot story:
the kernel finishes setup, drops to ring 3 running init, and from that moment
everything is a user program. On this small OS, init can simply be the shell itself,
or a tiny program that launches the shell and restarts it if it exits.

This stage turns your pile of working parts into a system that **boots to a usable
prompt** on its own.

---

## Specification

- At the end of kernel setup, instead of running test code, load and start the **init**
  program from the ramdisk in ring 3, then let the scheduler take over.
- init responsibilities (keep them minimal):
  1. Start the shell (`spawn`/`exec` from Stage 8.3).
  2. `wait` for it. If it exits, restart it, so the machine always has a prompt.
- Remove or gate behind a debug flag any earlier temporary test code in `kernel_main`,
  so a normal boot goes straight to the shell.
- Make sure the ramdisk contains init, the shell, and any built-in test programs.

---

## Your task

1. Write an `init` user program that starts the shell and re-launches it if it exits.
2. Change kernel startup to load and enter `init` in ring 3 as the last step, then
   idle/schedule.
3. Stage `init`, the shell, and test programs into the ramdisk archive.
4. Remove leftover test code from `kernel_main` (or hide it behind a flag).
5. Boot the ISO and confirm you reach the shell prompt with no manual steps.

---

## How to verify

- Booting the ISO in QEMU lands you at the shell prompt automatically — no test output,
  no manual triggering.
- Running commands and programs works exactly as in Stage 8.3, now from a clean boot.
- If the shell exits, init restarts it and the prompt returns.
- The whole path — GRUB → kernel → init → shell → your command — runs end to end.

---

## Common traps

- Leaving test code that runs before init and clutters or breaks the boot.
- init exiting itself (with no shell running), leaving the system with nothing to do.
- Forgetting to stage init or the shell in the ramdisk, so the loader cannot find
  them at boot.
- The kernel returning from its setup path instead of scheduling, so the machine halts
  after starting init.

---

## Reading

- OSTEP — "Process API" (init as the first process):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- xv6 `init.c` (a real, tiny init that spawns and restarts the shell):
  <https://github.com/mit-pdos/xv6-public/blob/master/init.c>

---

## Phase 8 is complete — and so is your OS

The machine boots to a shell you built, running your programs, on a kernel you wrote
from an empty folder. Commit, and celebrate — this is a genuine milestone.

See **[[Capstone - You Built an OS]]** for what you have, and where to go next.

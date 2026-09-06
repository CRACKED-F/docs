# How To Use These Docs

Read this once. It explains how a stage is built, how to move through the phases,
and the habits that keep you unstuck.

---

## The shape of a stage

Every stage note has the same parts, in the same order. This is the
CodeCrafters-inspired anatomy.

1. **Difficulty & time** — a rough size, from *Very Easy* (under 5 minutes for an
   experienced dev) to *Hard* (over an hour). With no low-level experience, expect
   your times to run longer. That is expected, not a failure.
2. **Concept** — the idea behind the stage, in plain words. Read this before you
   write code. It answers *why*.
3. **Specification** — the exact facts you need: register names, memory addresses,
   table layouts, byte formats. It answers *what*, with no guessing.
4. **Your task** — a numbered checklist of what to implement. 5 to 8 items.
5. **How to verify** — how to run it and what a pass looks like. If you cannot
   check it, you are not done.
6. **Reading** — links out to the wiki, book, or tutorial for depth. Read at least
   one before a hard stage.
7. **Common traps** — the specific mistakes that cost people hours on this stage.

---

## How to work through a phase

- **Go in order.** Each stage depends on the ones before it. Do not skip.
- **Finish a stage completely before the next.** "Working code at every step" is
  the whole point. A half-finished stage hides which change broke the boot.
- **Commit after every green stage.** Use Git. When the screen goes blank, `git
  diff` against the last working commit is your fastest debugging tool.
- **Read the concept before you code, not after.** The specification will not make
  sense without it.

---

## The build-and-run loop

From Phase 0 onward you repeat one loop:

1. Edit code.
2. Build the kernel and (from Phase 0.5) wrap it in an ISO.
3. Boot the ISO in QEMU.
4. Read the screen, the serial log, or the QEMU monitor.
5. Fix and repeat.

You will run this loop hundreds of times. **Automate it early.** A `Makefile` and a
one-line `make run` save you from typos that look like OS bugs. Phase 0 sets this
up.

---

## Debugging habits (start these on day one)

- **Log over the serial port, not just the screen.** Screen output disappears when
  the kernel crashes; serial output is captured to a file. You add serial logging
  in **[[Phase 1 - Overview|Phase 1]]** for exactly this reason.
- **Use the QEMU monitor.** `Ctrl-Alt-2` in QEMU opens a monitor where you can dump
  registers (`info registers`) and memory. See
  **[[03 - Resources and Reading#Debugging]]**.
- **Attach GDB to QEMU.** QEMU can pause and wait for a debugger with `-s -S`. This
  turns "blank screen" into a single-stepped instruction trace. This is the single
  most valuable skill in this whole guide.
- **Change one thing at a time.** Two changes plus a blank screen equals no
  information.

---

## Conventions in these notes

- Code is written for **freestanding C++** — no standard library, no OS underneath.
  What that means is explained in **[[Stage 0.3 - Freestanding C++ & the Kernel Entry Point]]**.
- Addresses are hexadecimal, written like `0xB8000`.
- "Ring 0" means kernel (full privilege). "Ring 3" means user (limited). Rings are
  explained in **[[04 - Glossary]]** and used from **[[Phase 6 - Overview|Phase 6]]**.
- Double-bracket links (written `[[Note Name]]`) jump to other notes. Follow them.

---

## When you are stuck for more than an hour

1. Re-read the stage **Concept** and **Common traps**.
2. Read the linked wiki page in full, not just the snippet.
3. Compare your code against a reference implementation (see
   **[[03 - Resources and Reading#Reference implementations]]**). Reading working
   code is not cheating; it is how everyone learns this.
4. Ask with a specific question and your serial log. "It does not boot" gets no
   help; "GRUB prints X then resets, here is my multiboot header" gets an answer.

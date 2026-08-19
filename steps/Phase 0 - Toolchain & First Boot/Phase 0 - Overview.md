# Phase 0 — Toolchain & First Boot

**Goal:** go from an empty folder to a kernel that GRUB boots inside QEMU. You will
not write an OS feature yet. You will prove that every tool in the chain works and
that your own code runs on bare metal.

This phase feels like plumbing because it is. Do it carefully once, and every later
phase reuses the same build-and-run loop.

> Prerequisite: finish **[[02 - Toolchain Setup (Mac & Windows)]]** first.

---

## Why this phase exists

Between "I wrote `kernel_main`" and "it runs" sit five things that must all be
correct: the cross-compiler, the Multiboot header, freestanding C++, the linker
script, and GRUB. If any one is wrong you get a blank screen with no error. This
phase turns each on separately so that when something breaks, you know which one.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 0.1 | [[Stage 0.1 - Prove Your Toolchain Works]] | Very Easy | Confidence the compiler and QEMU run. |
| 0.2 | [[Stage 0.2 - The Multiboot Header]] | Easy | A header GRUB recognizes. |
| 0.3 | [[Stage 0.3 - Freestanding C++ & the Kernel Entry Point]] | Medium | `kernel_main` in C++, called from assembly. |
| 0.4 | [[Stage 0.4 - The Linker Script & Booting with QEMU]] | Medium | A kernel binary QEMU boots with `-kernel`. |
| 0.5 | [[Stage 0.5 - Building a Bootable ISO with GRUB]] | Medium | A real bootable `os.iso`. |
| 0.6 | [[Stage 0.6 - The Makefile & Build-Run Loop]] | Easy | `make run` builds and boots in one command. |

---

## Deliverable

At the end of Phase 0, `make run` builds your kernel, wraps it in an ISO, boots it
in QEMU, and the machine reaches your `kernel_main` and halts cleanly (no reboot
loop, no triple fault). You will not see text on screen yet — that is
**[[Phase 1 - Overview|Phase 1]]**. You *will* confirm you reached `kernel_main` by
writing a single byte to video memory or a serial character.

---

## Read before you start

- OSDev — *Bare Bones* (this phase is a careful expansion of it):
  <https://wiki.osdev.org/Bare_Bones>
- OSDev — *Beginner Mistakes*: <https://wiki.osdev.org/Beginner_Mistakes>
- The Little OS Book, chapters 1–3: <https://littleosbook.github.io>
- See **[[03 - Resources & Reading]]** for the full list.

Next phase: **[[Phase 1 - Overview]]**.

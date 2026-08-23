# Phase 0 — Toolchain & First Boot

**Goal:** go from an empty repository to a kernel that **Limine boots under both UEFI
and legacy BIOS**, prints over the serial port, and reports a fault cleanly instead of
silently rebooting.

You will not write an OS feature yet. You will prove that every link in the chain
works — and build the two things you will lean on for the next two years: a
reproducible build, and a way for the kernel to tell you what went wrong.

> Prerequisite: [[02 - Toolchain Setup]] complete (`make shell` works).

---

## Phase progress

Tick these off as you go. Each links to a stage note with its own detailed
checklist, line-by-line code walkthrough, and tradeoff analysis.

- [ ] **0.1** [[Stage 0.1 - Prove Your Toolchain Works]] — container, cross-compiler, and QEMU all answer
- [ ] **0.2** [[Stage 0.2 - The Limine Request Section]] — a kernel Limine recognises
- [ ] **0.3** [[Stage 0.3 - Freestanding C++ and kmain]] — `kmain`, and our own `BootInfo`
- [ ] **0.4** [[Stage 0.4 - The Linker Script and Higher-Half Layout]] — linked at `0xFFFFFFFF80000000`
- [ ] **0.5** [[Stage 0.5 - Building a Bootable Image]] — 🎉 **FIRST BOOT**
- [ ] **0.6** [[Stage 0.6 - Serial Output]] — 🎉 **FIRST OUTPUT**
- [ ] **0.7** [[Stage 0.7 - Panic and KASSERT]] — faults halt with a register dump
- [ ] **0.8** [[Stage 0.8 - The Build System]] — `make run` does everything
- [ ] **0.9** [[Stage 0.9 - CI From Day One]] — every push is built and boot-tested

**Phase complete when:**

- [ ] `make run` boots under BIOS and greets you over serial
- [ ] `make run-uefi` does the same under OVMF
- [ ] A deliberate null dereference panics with a register dump — no reboot loop
- [ ] `git push` runs the whole thing in CI and comes back green

---

## Why this phase exists

Between "I wrote `kmain`" and "it runs" sit five things that must all be correct: the
cross-compiler, the Limine request section, the linker script, the boot image layout,
and the firmware handoff. If any one is wrong you get a blank screen with no error.
This phase turns each on separately, so when something breaks you know which one.

It also front-loads two things the original plan left until far too late:

- **Serial output early** ([[Stage 0.6 - Serial Output|Stage 0.6]]). It survives a
  crash, it is captured to a file, and it works before the framebuffer exists. It is
  the reason every later failure is diagnosable.
- **Panic and `KASSERT`** ([[Stage 0.7 - Panic and KASSERT|Stage 0.7]]). Every Tier-2
  test in [[09 - Testing Strategy]] is built on `KASSERT`, so it cannot be an
  afterthought.

---

## What changed from the classic tutorial path

If you have read Bare Bones or The Little OS Book, three things here will look
different. Each is a deliberate decision, recorded as an ADR.

| Classic | Here | Why |
|---|---|---|
| i686 32-bit | **x86_64 long mode** | [[ADR-0002 - Target x86_64 Not i686]] |
| GRUB + Multiboot 1 | **Limine protocol** | [[ADR-0003 - Limine as the Bootloader]] |
| White `A` at `0xB8000` | **A character over serial** | [[ADR-0004 - Framebuffer Console Not VGA Text]] |
| Hand-written Makefile | **CMake in a pinned container** | [[ADR-0005 - Containerised Pinned Toolchain]] |

The biggest practical consequence: **Limine hands you a CPU already in 64-bit long
mode with paging enabled.** You do not write a long-mode trampoline. That is what
makes targeting 64-bit tractable — and you still build your own page tables in
[[Phase 4 - Overview|Phase 4]], where the concept gets the attention it deserves.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 0.1 | [[Stage 0.1 - Prove Your Toolchain Works]] | Very Easy | Confidence the container, compiler, and QEMU run |
| 0.2 | [[Stage 0.2 - The Limine Request Section]] | Easy | A kernel Limine recognises and will load |
| 0.3 | [[Stage 0.3 - Freestanding C++ and kmain]] | Medium | `kmain` in C++, and our own `BootInfo` |
| 0.4 | [[Stage 0.4 - The Linker Script and Higher-Half Layout]] | Hard | A linked kernel at `0xFFFFFFFF80000000` |
| 0.5 | [[Stage 0.5 - Building a Bootable Image]] | Medium | **FIRST BOOT** — hybrid ISO, kernel reached and halted |
| 0.6 | [[Stage 0.6 - Serial Output]] | Medium | **FIRST OUTPUT** — a line of text out of COM1 |
| 0.7 | [[Stage 0.7 - Panic and KASSERT]] | Medium | Faults halt with a register dump, not a reboot loop |
| 0.8 | [[Stage 0.8 - The Build System]] | Medium | `make run` builds and boots in one command |
| 0.9 | [[Stage 0.9 - CI From Day One]] | Medium | Every push builds and boot-tests automatically |

> **Note on ordering.** Boot comes *before* serial (0.5 before 0.6), deliberately.
> Each stage should change one thing: 0.5 proves the boot chain works with a kernel
> that only halts — verified through the QEMU monitor — and 0.6 then adds output. If
> you write serial code first and it does not appear, you have three unverified
> stages to debug at once instead of one.

> **Note on the build system.** Stages 0.1–0.7 compile with hand-typed
> `x86_64-elf-g++` commands. That is deliberate: you see exactly which flags matter
> and why before a build system hides them. [[Stage 0.8 - The Build System|Stage 0.8]]
> then replaces the hand-typing with CMake.

**Stage 0.9 is not optional and it is not premature.** Turning CI on before there is
much to test is the point: it is trivial now and painful later, and from this moment
onward every regression is caught by the commit that caused it. See
[[10 - CI Pipeline]].

---

## Deliverable

`make run` builds the kernel, wraps it in a hybrid ISO, boots it in QEMU, and prints
a greeting over the serial port. `make run-uefi` does the same under OVMF firmware.
A deliberate null dereference produces a panic with a register dump, not a reboot
loop. `git push` runs the whole thing in CI.

You will not see text on the screen yet — that is [[Phase 1 - Overview|Phase 1]]. You
*will* have proof your C++ ran on bare metal, under both firmware types.

---

## The proof-of-life milestone

The classic milestone is a white `A` in the corner of the screen. Ours is a line of
text over the serial port, and it is strictly better:

- It works before any display code exists.
- It is captured to a file, so it survives the crash that follows.
- It works identically on real hardware, where there may be no text mode at all.
- CI can read it.

Chasing a pixel before you have serial output is how people spend a weekend
debugging a display when the kernel was never reached.

---

## Read before you start

- **Limine protocol specification** — the request/response model, and what each
  request gives you: <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- OSDev — *Limine Bare Bones* (the 64-bit, Limine-based equivalent of Bare Bones):
  <https://wiki.osdev.org/Limine_Bare_Bones>
- OSDev — *Beginner Mistakes*. Read it now and again after Phase 2:
  <https://wiki.osdev.org/Beginner_Mistakes>
- OSDev — *Serial Ports*: <https://wiki.osdev.org/Serial_Ports>
- OSDev — *Higher Half Kernel*: <https://wiki.osdev.org/Higher_Half_Kernel>
- [[06 - Architecture Overview]] — the boot chain and memory layout you are building
  toward
- [[03 - Resources and Reading]] for the full list

Next phase: [[Phase 1 - Overview]]

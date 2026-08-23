# Build an Operating System — Start Here

This vault is the complete plan for building a **real, deployable operating system**
in C++ — from an empty repository to an ISO that boots on an actual computer.

It targets **x86_64**, boots through **UEFI or legacy BIOS**, runs on real hardware
as well as in QEMU, and ends as a system with a shell, a persistent filesystem,
multiple cores, a Unix process model, and a TCP/IP stack.

It assumes **no low-level experience**. Every stage explains the idea first, tells you
exactly what to build, then tells you how to check it works.

> **New here?** Read [[01 - How To Use These Docs]], then [[06 - Architecture Overview]],
> then set up your machine with [[02 - Toolchain Setup]].
>
> **Ready to build?** [[Progress Tracker]] is the one page with every stage and a
> checkbox each. Start at [[Stage 0.1 - Prove Your Toolchain Works]].
>
> **Wondering why this looks different from a typical OS tutorial?** Read
> [[05 - Gap Analysis (v1 to Product)]].

---

## Product, not project

The distinction drives every decision in this vault:

| | Project | Product — what we are building |
|---|---|---|
| Success is | it worked once, on my machine | it works every time, on anyone's machine |
| Verified by | looking at the screen | automated tests in CI |
| Runs on | QEMU | real hardware, reproducibly |
| Built by | whatever compiler I have | a pinned, identical toolchain |
| Ships | never | on a tag, with artefacts and checksums |

That is why this vault contains a CI pipeline, a release process, and a test strategy
alongside the kernel material. An OS nobody can install is not an OS.

---

## The three decisions that shape everything

Recorded in full under [[ADR-0001 - Record Architecture Decisions|steps/decisions]].

1. **x86_64, not 32-bit.** Modern firmware boots 64-bit executables. 32-bit is a
   dead end for anything meant to run on a real machine.
   → [[ADR-0002 - Target x86_64 Not i686]]
2. **Limine, not GRUB.** One image that boots UEFI *and* BIOS, and it hands us a
   kernel already in long mode with a framebuffer and a memory map.
   → [[ADR-0003 - Limine as the Bootloader]]
3. **Framebuffer, not VGA text mode.** UEFI makes no guarantee of a text mode. The
   classic `0xB8000` trick produces a black screen on real modern hardware.
   → [[ADR-0004 - Framebuffer Console Not VGA Text]]

---

## The roadmap

Work through the phases in order. Milestones and estimates are in
[[15 - Roadmap and Milestones]].

### Foundations

| Phase | Deliverable |
|---|---|
| [[Phase 0 - Overview\|0 — Toolchain & First Boot]] | Boots under UEFI and BIOS; serial output; panics report cleanly |
| [[Phase 1 - Overview\|1 — Console & Logging]] | Framebuffer text, `kprintf`, a log ring buffer, symbolised backtraces |
| [[Phase 2 - Overview\|2 — CPU Tables & Interrupts]] | 64-bit GDT/IDT/TSS; exceptions and hardware interrupts handled |
| [[Phase 3 - Overview\|3 — Drivers: Timer & Keyboard]] | A steady tick and typed input |

### The kernel proper

| Phase | Deliverable |
|---|---|
| [[Phase 4 - Overview\|4 — Memory Management]] | Our own 4-level page tables, a frame allocator, `kmalloc` |
| [[Phase 5 - Overview\|5 — Multitasking]] | Locking discipline, then preemptive scheduling |
| [[Phase 6 - Overview\|6 — User Mode & Syscalls]] | Ring 3, `syscall`/`sysret`, a validated boundary |
| [[Phase 7 - Overview\|7 — VFS & Program Loading]] | A writable VFS and an ELF loader |
| [[Phase 8 - Overview\|8 — The Shell]] | Boots to an interactive prompt |

### A real system

| Phase | Deliverable |
|---|---|
| [[Phase 9 - Overview\|9 — Storage]] | Block layer, buffer cache, AHCI and NVMe drivers |
| [[Phase 10 - Overview\|10 — Real Filesystems]] | FAT32 and ext2 — **data survives a reboot** |
| [[Phase 11 - Overview\|11 — Modern Platform]] | ACPI, APIC, PCI, HPET, RTC — **and it can power itself off** |
| [[Phase 12 - Overview\|12 — SMP]] | Every core running, every shared structure safe |
| [[Phase 13 - Overview\|13 — Unix Process Model]] | `fork`, pipes, signals, job control, a real libc |
| [[Phase 14 - Overview\|14 — Networking]] | ARP, IP, UDP, TCP, sockets — it answers a ping |
| [[Phase 15 - Overview\|15 — Hardening & Real Hardware]] | NX/SMEP/SMAP/W^X, users, **boots from a USB stick on a real PC** |

Then [[Capstone - You Built an OS]].

---

## Engineering handbook

These are not optional reading. They are the difference between a project that ships
and one that stalls at month nine.

| Note | What it covers |
|---|---|
| [[05 - Gap Analysis (v1 to Product)]] | What was missing from the original plan, and why |
| [[06 - Architecture Overview]] | Boot chain, init order, memory layout, subsystem map |
| [[07 - Repository Layout]] | Where every file goes, and the four boundary rules |
| [[08 - Build System]] | CMake, three toolchains, the flags that prevent real bugs |
| [[09 - Testing Strategy]] | The three test tiers and the definition of done |
| [[10 - CI Pipeline]] | What runs automatically and what it protects |
| [[11 - Release and Deployment]] | Artefacts, the boot matrix, the manual checklist |
| [[12 - Team Workflow]] | The two-person split and the interface-first rule |
| [[13 - Coding Standards]] | Ten rules, each preventing a specific kernel bug |
| [[14 - Debugging Playbook]] | Symptom → cause, for the failures that actually happen |
| [[15 - Roadmap and Milestones]] | Estimates, parallelism, and pre-agreed cut lines |

Reference: [[03 - Resources and Reading]] · [[04 - Glossary]] ·
[[ADR-0001 - Record Architecture Decisions|Decision records]]

The ready-to-use project skeleton — CI workflows, toolchain container, image build
scripts — is in `scaffold/` in this repository.

---

## A word on honesty and pace

OS development is slow the first time. A stage that reads as three lines can cost an
evening, because the machine gives you a blank screen instead of an error message.
This is normal.

[[15 - Roadmap and Milestones]] estimates **18–26 months part-time for two people**.
That number is honest, and every hobby OS that shipped took roughly this long. If it
is uncomfortable, the right response is to cut scope deliberately — the cut lines are
pre-agreed in that note — rather than to compress the estimate and discover the truth
later.

The mitigation for the real risk, which is losing momentum rather than hitting a
technical wall, is structural: **every milestone produces something you can show
someone in two minutes.**

Two habits from day one: [[14 - Debugging Playbook|log over serial]], and commit after
every green stage.

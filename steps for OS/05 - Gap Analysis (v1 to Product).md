# Gap Analysis — from teaching vault to shippable product

This note is the honest audit of the v1 vault against the goal of **a deployable,
end-to-end operating system built by two people**. It records what was missing, how
bad each gap was, and where it is now addressed.

Read it once to understand *why* the vault changed. It is a snapshot of 2026-08-20,
not living documentation — the roadmap in [[15 - Roadmap and Milestones]] is what you
work from.

---

## Verdict on v1

The v1 vault was a **good teaching ladder and not a product plan.** 9 phases, 40
stages, consistent structure, honest about difficulty, well sourced. As a learning
path it beat most paid courses.

But it terminated at *"boots to a shell in QEMU"* and made three Phase-0 choices that
made real-hardware deployment impossible. It also contained **zero engineering
infrastructure** — no repo layout, no build system beyond a hand-rolled Makefile, no
tests, no CI, no release process, no team workflow.

The distinction that matters:

| | Project | Product |
|---|---|---|
| Success is | it worked once, on my machine | it works every time, on anyone's machine |
| Verified by | looking at the screen | automated tests in CI |
| Runs on | QEMU | real hardware, reproducibly |
| Built by | whatever compiler I have | a pinned, identical toolchain |
| Breaks | silently, discovered weeks later | loudly, at the commit that caused it |
| Ships | never | on a tag, with artefacts and checksums |

---

## Tier 1 — Blockers (make deployment impossible)

These invalidate the goal outright. All are Phase-0/1 decisions, which is why they
were fixed first and why fixing them **now** cost only prose. Fixing them after code
existed would have cost months.

### B1. 32-bit i686 target

Modern UEFI firmware hands control to a 64-bit executable. A 32-bit kernel needs a
thunk most firmware does not support. 4 GiB physical RAM ceiling.
**Fixed:** [[ADR-0002 - Target x86_64 Not i686]].

### B2. VGA text mode at `0xB8000`

**The most serious single gap in v1.** UEFI and VGA are mutually exclusive in
practice — UEFI makes no guarantee of a VGA-compatible mode, and on modern machines
there is none. The entire v1 Phase 1 output layer produces *nothing* on a real
UEFI-booted laptop. No error, no output, black screen — and the code is correct, so
there is no debugging path to the answer.
**Fixed:** [[ADR-0004 - Framebuffer Console Not VGA Text]].

### B3. Multiboot 1 + legacy-BIOS GRUB

Multiboot 1 is 32-bit by definition. Obtaining a working GRUB `BOOTX64.EFI`
cross-platform is painful — v1 conceded this by telling macOS users to run GRUB in
Docker.
**Fixed:** [[ADR-0003 - Limine as the Bootloader]].

### B4. No persistent storage

Read-only tar ramdisk only. Nothing survives reboot. An OS that cannot write to a
disk is a demo.
**Fixed:** Phase 9 (block layer, AHCI, NVMe) + Phase 10 (FAT32, ext2),
[[ADR-0009 - Filesystem Strategy FAT32 then ext2]].

### B5. Cannot power off

No ACPI. The OS has no way to shut down or reboot the machine — on real hardware you
hold the power button. Also blocks SMP discovery, since the MADT is an ACPI table.
**Fixed:** Phase 11.

---

## Tier 2 — Structural (product is not credible without these)

### S1. No tests, at any level

v1's every "How to verify" was "boot it and look at the screen." That cannot run in
CI, so CI could only prove the code compiles — nearly worthless for a kernel, since
a kernel that compiles and triple-faults is no better than one that does not compile.
**Fixed:** [[ADR-0010 - Testing Strategy and the QEMU Exit Device]], [[09 - Testing Strategy]].

### S2. No CI/CD

Nothing built, tested, or released automatically. With two people merging in
parallel, silent breakage is guaranteed.
**Fixed:** [[10 - CI Pipeline]] + committed workflows in `scaffold/.github/workflows/`.

### S3. Unpinned, per-developer toolchain

v1 had each developer install a cross-compiler by hand — Homebrew on macOS, "build
from source, budget an hour" on Windows. Three environments, three compilers, three
sets of inlining decisions. A race that never fires on one machine fires reliably on
the other, and bug reports become unreproducible.
**Fixed:** [[ADR-0005 - Containerised Pinned Toolchain]] + `scaffold/toolchain/Dockerfile`.

### S4. No source layout

v1 never said where code goes. Two people cannot work in parallel on a tree whose
shape is undefined — you get merge conflicts in files that should never have been
touched by both.
**Fixed:** [[ADR-0008 - Monorepo Layout]], [[07 - Repository Layout]].

### S5. No panic, assert, or stack traces

When a v1 kernel faults you get a register dump at best. No symbolisation, no
backtrace, no "which line". Every fault becomes a manual GDB session.
**Fixed:** Stage 0.5 (panic + `KASSERT`), Stage 1.6 (symbolised backtrace),
[[14 - Debugging Playbook]].

### S6. No kernel log buffer

Output goes straight to screen and is lost. No `dmesg`, no log levels, no way to see
what happened before the fault scrolled past.
**Fixed:** Stage 1.5 (ring buffer + levels + `dmesg` syscall).

### S7. No synchronisation primitives — a correctness landmine

**v1 built a preemptive scheduler in Phase 5 with no discussion of locking at all.**
The moment the timer can interrupt a task mid-update of a shared structure, the
kernel has data races. On a single core, disabling interrupts is sufficient — but v1
never said so, and never introduced the discipline. Adding SMP later would then
multiply the problem across cores.
**Fixed:** Stage 5.0 introduces atomics, spinlocks, IRQ-save discipline, and RAII lock
guards **before** the first preemptive switch. Phase 12 extends to multicore.

### S8. No team workflow

Two people, no branch protection, no review rule, no ownership split, no definition
of done.
**Fixed:** [[12 - Team Workflow]].

### S9. No release process

No versioning, no artefacts, no changelog, no way for anyone to obtain and run the
OS.
**Fixed:** [[11 - Release and Deployment]] + `scaffold/.github/workflows/release.yml`.

---

## Tier 3 — Missing OS capability (needed for "server-grade")

Ranked by dependency order, which is the order the new phases build them.

| # | Gap | Why it matters | Where |
|---|---|---|---|
| C1 | No block device layer or buffer cache | Every real filesystem needs one | Phase 9 |
| C2 | No disk driver (AHCI/NVMe) | Cannot reach a disk at all | Phase 9 |
| C3 | No writable filesystem | Nothing persists | Phase 10 |
| C4 | No ACPI | No shutdown, no reboot, no SMP discovery | Phase 11 |
| C5 | No APIC | 8259 PIC is legacy and cannot route to multiple cores | Phase 11 |
| C6 | No PCI enumeration | Cannot find any modern device | Phase 11 |
| C7 | No RTC / wall clock | No file timestamps, no `date` | Phase 11 |
| C8 | No HPET/TSC | PIT is coarse and legacy | Phase 11 |
| C9 | No SMP | Single core on multicore hardware | Phase 12 |
| C10 | No per-CPU data | Prerequisite for SMP | Phase 12 |
| C11 | No `fork` / COW | Only a crude `spawn`; no Unix process model | Phase 13 |
| C12 | No pipes | Shell cannot do `a \| b` | Phase 13 |
| C13 | No signals | No `Ctrl-C`, no way to kill a process | Phase 13 |
| C14 | No TTY layer / job control | No line discipline, no foreground process group | Phase 13 |
| C15 | No userspace `malloc` | User programs cannot allocate | Phase 13 |
| C16 | No real libc | v1 had `write`/`exit` stubs only | Phase 13 |
| C17 | No networking | Required for "server-grade" | Phase 14 |
| C18 | No NX / SMEP / SMAP / W^X | Zero exploit mitigation | Phase 15 |
| C19 | No users or permissions | Everything runs as root-equivalent | Phase 15 |
| C20 | Never booted on real hardware | The actual deployment goal | Phase 15 |

---

## Tier 4 — Deliberately out of scope for v1

Recorded so they are visible decisions rather than oversights.

| Item | Why deferred |
|---|---|
| GUI / window server | Doubles project scale; server-grade scope chosen |
| Dynamic linking | Static binaries are sufficient; adds a linker and PLT/GOT handling |
| aarch64 port | [[ADR-0006 - Apple Silicon Is Not a Boot Target]] |
| Journalling filesystem | ext2 + `fsck` is tractable; ext4 is not |
| USB stack | Large; PS/2 emulation and virtio cover input in QEMU. **Note: this means real-hardware keyboard support is limited to machines with PS/2 emulation** — a genuine v1 limitation |
| Audio | No dependency needs it |
| Preemptible kernel | Non-preemptible kernel is simpler and correct |
| Our own bootloader | [[ADR-0003 - Limine as the Bootloader]] escape hatch keeps it possible |

---

## Scale check

An honest estimate for two people, part-time, given the scope above:

| Milestone | Phases | Estimate |
|---|---|---|
| M1 — Boots, prints, faults cleanly | 0–2 | 6–10 weeks |
| M2 — Interactive kernel with memory | 3–5 | 10–14 weeks |
| M3 — Userspace and a shell | 6–8 | 12–16 weeks |
| M4 — Persistence | 9–10 | 10–14 weeks |
| M5 — Modern platform + SMP | 11–12 | 10–14 weeks |
| M6 — Unix process model | 13 | 8–12 weeks |
| M7 — Networking | 14 | 10–14 weeks |
| M8 — Hardening + real hardware, v1.0 | 15 | 6–10 weeks |

**Total: roughly 18–26 months part-time.** If that number is uncomfortable, the
correct response is to cut scope deliberately — drop Phase 14 and ship at M6 — not to
compress estimates. See [[15 - Roadmap and Milestones]] for the cut lines.

---

## What did not change

The parts of v1 that were good, and were kept:

- **The stage anatomy.** Concept → Specification → Your task → How to verify →
  Common traps → Reading. It is genuinely well designed and every new stage uses it.
- **Honesty about difficulty.** The "a stage that reads as three lines can cost an
  evening" note in [[00 - Start Here]] is correct and stays.
- **The debugging-habits section.** Serial first, change one thing at a time, GDB
  early. All correct.
- **The phase dependency ordering** for Phases 3–8. Timer before scheduler, paging
  before user mode, VFS before ELF loading. Sound.
- **The reading list.** OSTEP, xv6, OSDev, Little OS Book remain the right sources —
  extended in [[03 - Resources and Reading]] for 64-bit, UEFI, and Limine.

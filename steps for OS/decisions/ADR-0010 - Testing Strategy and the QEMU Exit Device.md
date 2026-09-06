# ADR-0010 — Testing strategy and the QEMU exit device

**Status:** Accepted · **Date:** 2026-08-20

---

## Context

The v1 vault had **no automated tests of any kind**. Every stage's "How to verify"
was a manual instruction: boot it, look at the screen, decide whether it is right.

That does not survive contact with a real project:

- A regression in Phase 4's page-table code shows up as a mysterious fault in Phase
  12, weeks later, and nobody knows which commit caused it.
- Two people merging in parallel break each other's work silently.
- "Boot it and look" cannot run in CI, so CI can only prove the code *compiles* —
  which for a kernel is nearly worthless. A kernel that compiles and triple-faults
  is not meaningfully better than one that does not compile.

The core difficulty is that kernel code cannot simply be linked into a normal test
binary: it assumes it owns the machine.

## Decision

**Three test tiers**, each with a different mechanism and a different cost.

### Tier 1 — Host unit tests (`tests/unit/`)

Pure logic compiled for the **host**, not the target, and run natively. Fast
(milliseconds), debuggable with ordinary tools.

Covers anything with no hardware dependency: the buddy/bitmap allocator's bit
arithmetic, `printf` formatting, string functions, FAT cluster-chain walking, ELF
header parsing, tar parsing, the scheduler's run-queue selection, ring buffers, path
canonicalisation.

Achieved by keeping this logic in **architecture-neutral files that take their
dependencies as parameters** rather than reaching for globals. This is a design
constraint that improves the kernel independently of testing — it is the main reason
`kernel/mm/` and `kernel/arch/x86_64/mm/` are separate directories in
[[ADR-0008 - Monorepo Layout]].

Framework: **doctest** (single header, no dependencies).

### Tier 2 — In-kernel self-tests (`tests/kernel/`)

A test build of the kernel that boots under QEMU, runs assertions **in kernel
context on the real hardware model**, and reports the result.

Covers what Tier 1 cannot: does paging actually map, does the context switch resume
correctly, does the page-fault handler fire on the right address, does `kmalloc`
survive a torture loop, does an IRQ arrive.

**Reporting mechanism: QEMU's `isa-debug-exit` device.**

```
qemu-system-x86_64 -device isa-debug-exit,iobase=0xf4,iosize=0x04 ...
```

Writing value `N` to the port makes QEMU exit with status `(N << 1) | 1`. So a
kernel that finishes its tests writes `0` for success (QEMU exits `1`) and `1` for
failure (QEMU exits `3`). The runner script maps these back to pass/fail. This is the
same mechanism `kvm-unit-tests` uses.

Serial output is captured to a log file for the failure report.

**Every test run has a hard timeout.** A kernel that hangs must fail the build, not
hang CI forever. `timeout 60 qemu-system-x86_64 ...`.

### Tier 3 — Integration / boot tests (`tests/integration/`)

Boot the **real release image** and drive it as a user would: send keystrokes over
serial, assert on the output.

Covers the things that only break when everything is assembled: does it reach the
shell prompt, does `ls` list the files, does `cat` print a file, does a crashing
program leave the shell alive, does ACPI shutdown actually power off.

Mechanism: `pexpect` scripts against QEMU's serial port, with per-step timeouts.

Runs against **all four boot configurations**: BIOS ISO, UEFI ISO (OVMF), UEFI disk
image, and single-core versus SMP.

## Consequences

- Kernel code must be written to be testable: dependency-injected rather than
  global-reaching, and split along the arch boundary. This is a real design
  constraint and the largest cost of this decision. It is also, independently, better
  architecture.
- The kernel needs a **panic handler and assertion infrastructure from Phase 0**, not
  as an afterthought — `KASSERT` is the primitive every Tier 2 test is built on.
  This is why panic/assert moved into Stage 0.5 rather than appearing late.
- CI wall-clock grows. Mitigated by tiering: Tier 1 on every push (seconds), Tiers 2
  and 3 on every PR (minutes), the full matrix nightly.
- The test kernel build and the release kernel build must not diverge. Same sources,
  same flags, one extra `-DKERNEL_TESTS=1`.

## Definition of done

**A stage is not complete until it has a test at the appropriate tier.** This is
enforced in the PR template and is the single most important process rule in
[[12 - Team Workflow]].

## Related

[[09 - Testing Strategy]] · [[10 - CI Pipeline]] · [[14 - Debugging Playbook]]

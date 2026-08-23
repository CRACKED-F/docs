# ADR-0002 — Target x86_64, not i686

**Status:** Accepted · **Date:** 2026-08-20
**Supersedes:** the i686 target assumed throughout the v1 vault

---

## Context

The original guide targeted **i686** (32-bit x86). That is the standard choice in
teaching material because 32-bit protected mode is simpler: two-level paging, a
small register set, and nearly every classic tutorial (JamesM, Bran, The Little OS
Book) uses it.

But this project's goal changed from "learn OS development" to "**build a
deployable operating system**". Under that goal, 32-bit is a dead end:

- Every x86 machine sold in roughly the last eighteen years is 64-bit.
- 64-bit UEFI firmware — what actually ships on modern hardware — hands control to a
  **64-bit** executable. A 32-bit kernel needs a thunk that most modern firmware
  does not support well or at all.
- 32-bit caps addressable physical RAM at 4 GiB and forces PAE/highmem workarounds
  that no new system should carry.
- The System V AMD64 ABI is what every real toolchain, debugger, and reference OS
  targets. Staying 32-bit means fighting the tools forever.

The counter-argument is real and should be stated honestly: 64-bit is harder to
bootstrap. Long mode requires paging to be enabled *before* the CPU can execute a
single 64-bit instruction — so the very first thing a from-scratch kernel must do is
the thing beginners find hardest.

## Decision

Target **x86_64 (AMD64) long mode** from Stage 0.1.

We sidestep the bootstrap difficulty by choosing a bootloader that enters the kernel
*already in 64-bit long mode with paging enabled* — see
[[ADR-0003 - Limine as the Bootloader]]. The hard part is delegated to code that is
already correct. We still learn paging properly in Phase 4, when we take over
address-space management ourselves and build our own page tables.

## Consequences

**Gained**

- Boots on real 2026 hardware.
- 4-level paging, a 48-bit canonical address space, 16 general-purpose registers.
- The higher-half layout at `0xFFFFFFFF80000000` is standard and well documented.
- Reference material (Linux, Limine examples, the OSDev x86-64 pages, the AMD64 ABI
  document) applies directly rather than by analogy.

**Paid**

- Most beginner tutorials are 32-bit. Their *concepts* transfer; their *code* does
  not. Every stage note must state the 64-bit specifics explicitly rather than
  linking to a 32-bit page and hoping the reader translates correctly.
- The SysV AMD64 calling convention passes integer arguments in `rdi`, `rsi`, `rdx`,
  `rcx`, `r8`, `r9`. A 32-bit habit of reading arguments off the stack silently reads
  garbage.
- **The red zone.** The 128 bytes below `rsp` that leaf functions may use without
  adjusting the stack pointer. Kernel code **must** be compiled with
  `-mno-red-zone`, or an interrupt arriving mid-function will overwrite live data.
  This is the single most common x86_64 kernel bug and it presents as random,
  unreproducible corruption weeks after the mistake was made. It is enforced in our
  `CMakeLists.txt` and checked in CI.
- SSE registers are part of the ABI. The kernel builds with `-mno-sse -mno-mmx
  -mno-80387 -mno-red-zone` and must not use floating point in kernel context, or it
  must save and restore that state on every context switch. v1 forbids kernel FP.
- `-mcmodel=kernel` is required so the compiler generates addressing valid for the
  top 2 GiB of the address space.

## Alternatives rejected

- **i686 now, port later.** Rejected. A port is not a phase, it is a rewrite: every
  assembly stub, page-table walk, interrupt frame, and calling convention changes.
  Doing it twice costs more than doing it right once, and no code exists yet to
  protect.
- **aarch64 (ARM64).** Attractive long-term — it is where hardware is going — but the
  x86 ecosystem's documentation, emulation tooling, and reference material is an
  order of magnitude deeper, and QEMU's x86_64 emulation is the better-trodden path.
  Revisit after v1.0.
- **RISC-V.** Cleanest architecture of the three and the best-documented teaching
  target (xv6-riscv), but no consumer hardware our team owns. Fails the
  "deployable" requirement.

## Related

[[ADR-0003 - Limine as the Bootloader]] · [[ADR-0006 - Apple Silicon Is Not a Boot Target]] · [[ADR-0007 - Freestanding C++20 as the Kernel Language]]

# ADR-0008 — Monorepo layout

**Status:** Accepted · **Date:** 2026-08-20

---

## Context

The OS consists of a kernel, a C library, userspace programs, build tooling, tests,
and documentation. These could live in one repository or several. The v1 vault never
said — it never described a source layout at all, which is a real gap: two people
cannot work in parallel on a tree whose shape is undefined.

A specific coupling drives this decision: **the kernel and the libc are versioned
together.** Adding a syscall touches the kernel dispatch table, the libc wrapper, and
the syscall number header simultaneously. Split across repositories, that is a
three-repo atomic change — which is to say, not atomic, and a source of constant
version-skew bugs.

## Decision

**One repository for all code**, at `CRACKED-F/os`.

**Documentation stays separate**, at `CRACKED-F/docs` (this vault), because it is an
Obsidian vault with a different audience, a different review cadence, and no build
coupling to the code.

```
os/
├── boot/              Limine config, pinned bootloader, image staging
├── kernel/
│   ├── arch/x86_64/   The ONLY architecture-specific code
│   │   ├── boot/      Limine entry, boot_info_t  (see ADR-0003 escape hatch)
│   │   ├── cpu/       GDT, IDT, TSS, exceptions, APIC
│   │   ├── mm/        Page tables, TLB
│   │   └── asm/       Interrupt stubs, context switch
│   ├── mm/            Architecture-neutral: PMM, VMM, heap, slab
│   ├── sched/         Tasks, scheduler, sync primitives
│   ├── fs/            VFS, tmpfs, FAT32, ext2
│   ├── drivers/       Serial, framebuffer, keyboard, PCI, AHCI, NVMe, net
│   ├── net/           ARP, IP, UDP, TCP, sockets
│   ├── syscall/       Dispatch table and handlers
│   ├── lib/           kstd:: containers, string, printf
│   └── include/       Kernel-internal headers
├── libc/              Userspace C library (our libc)
├── user/              Userspace programs: init, sh, coreutils
├── tests/
│   ├── unit/          Host-compiled tests of pure logic
│   ├── kernel/        In-kernel self-tests (run under QEMU)
│   └── integration/   Boot + expect-script tests
├── tools/             Host tools: mkinitrd, mkfont, symbolise
├── scripts/           build.sh, run.sh, test.sh, mkimage.sh, debug.sh
├── toolchain/         Dockerfile, pinned versions
├── cmake/             Toolchain files, KernelFlags.cmake
└── .github/workflows/ CI, release, nightly
```

## Rules

1. **`kernel/arch/x86_64/` is the only place architecture-specific code may live.**
   CI greps for `__asm__`, `asm(`, and x86 register names outside it and fails.
   This keeps [[ADR-0006 - Apple Silicon Is Not a Boot Target]]'s revisit condition
   achievable.
2. **`limine.h` may only be included under `kernel/arch/x86_64/boot/`.** Enforced by
   CI grep — the escape hatch in [[ADR-0003 - Limine as the Bootloader]] is worthless
   if it leaks.
3. **`kernel/` must never include from `libc/` or `user/`.** Different privilege
   domain, different memory rules. Enforced by CI grep.
4. **Shared kernel/user definitions** (syscall numbers, `errno` values, struct
   layouts crossing the boundary) live in exactly one place:
   `kernel/include/abi/`. `libc/` includes from there. This directory is the ABI
   contract and every change to it requires both reviewers.
5. Each top-level directory owns its `CMakeLists.txt`.

## Consequences

- One clone, one build, one CI run, one version number. A syscall addition is one
  atomic commit and one reviewable diff.
- The repo will grow large. Acceptable; it is source, not binaries. Build artefacts
  are gitignored and released as GitHub Release assets
  ([[11 - Release and Deployment]]).
- Docs and code can drift out of sync since they are separate repos. Mitigated by a
  CI check in the docs repo that verifies every referenced file path still exists in
  the code repo, and by the definition-of-done in [[12 - Team Workflow]] requiring a
  docs update in the same PR cycle.

## Alternatives rejected

- **Split repos** (`kernel`, `libc`, `user`, `tools`). Rejected: the kernel/libc ABI
  coupling makes atomic change impossible and version skew inevitable. This is the
  main reason real OS projects (Linux, SerenityOS, ToaruOS) are monorepos.
- **Docs inside the code repo.** Tempting for atomicity. Rejected because the vault
  is an Obsidian workspace with its own `.obsidian/` config, and because prose review
  and code review have different rhythms — mixing them means doc typos block code
  merges.

## Related

[[07 - Repository Layout]] · [[08 - Build System]] · [[12 - Team Workflow]]

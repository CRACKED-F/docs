# ADR-0006 — Apple Silicon is not a boot target

**Status:** Accepted · **Date:** 2026-08-20

---

## Context

The team requirement was stated as "it should run on both Mac and Windows 11 and the
latest version of macOS." That sentence has two readings and they lead to very
different projects, so this ADR fixes the interpretation.

**Reading A — development environment.** Both team members must be able to build,
run, and debug the OS on their own machine (one macOS, one Windows 11). This is the
intended reading and is satisfied by [[ADR-0005 - Containerised Pinned Toolchain]].

**Reading B — boot target.** The OS must boot natively on Apple Silicon Mac hardware.
This is rejected here.

## Decision

**Apple Silicon (M-series) Macs are a supported *development* platform and are not a
*boot* target.** The OS runs on them under QEMU emulation. It does not, and will not
in v1, boot natively on them.

## Rationale

Booting natively on Apple Silicon is not a hard version of x86 bring-up — it is a
different project:

- **Different instruction set.** M-series is aarch64. Every line of assembly, the
  entire interrupt model (GIC, not APIC), the MMU model (different page-table
  format), and the exception model differ. See
  [[ADR-0002 - Target x86_64 Not i686]] — this is the same rewrite cost, again.
- **No UEFI.** Apple Silicon uses Apple's proprietary **iBoot** chain. There is no
  UEFI, no ACPI, and no standard firmware interface to target.
- **Undocumented hardware.** Apple publishes no hardware documentation for these
  SoCs. Display, storage (NVMe with Apple-specific queues), USB, and interrupt
  controllers are all custom and must be reverse-engineered.
- **The precedent is discouraging.** Asahi Linux — a funded, full-time team of
  experienced kernel engineers — spent years reaching usable support, and hardware
  support is still incomplete. A two-person team building its first OS cannot
  reasonably scope this.

Boot Camp does not exist on Apple Silicon, so there is no vendor-supported path for
booting a non-macOS operating system on the bare metal at all.

## What we support instead

| Machine | Status |
|---|---|
| Apple Silicon Mac | **Dev only** — build + run under QEMU (`linux/amd64` emulation) |
| Intel Mac (2010+) | **Boot target** — x86_64 UEFI, boots from USB |
| Windows 11 PC | **Boot target** — x86_64 UEFI, boots from USB |
| Any x86_64 UEFI machine | **Boot target** |
| QEMU / OVMF | **Primary CI and dev target** |
| VirtualBox / VMware / Hyper-V | **Boot target** — released as VM images |

This satisfies the underlying intent: **both developers can work on their own
machine, and the resulting OS boots on real, current hardware.**

## Revisit conditions

Reconsider aarch64 as a *second* architecture — not as an Apple Silicon port — if:

1. v1.0 ships on x86_64, **and**
2. the `kernel/arch/` boundary has proven clean enough that a second architecture is
   additive rather than invasive, **and**
3. the team wants a target such as a Raspberry Pi 5 or an aarch64 QEMU virt machine,
   both of which are **documented** and use standard firmware.

Apple Silicon bare metal remains out of scope indefinitely.

## Related

[[ADR-0002 - Target x86_64 Not i686]] · [[ADR-0005 - Containerised Pinned Toolchain]] · [[11 - Release and Deployment]]

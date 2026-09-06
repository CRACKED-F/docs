# ADR-0001 — Record architecture decisions

**Status:** Accepted · **Date:** 2026-08-20 · **Deciders:** both members

---

## Context

This project spans years and two people. Decisions made in week 3 will be
questioned in month 14, usually by the person who did not make them. Without a
record, the team re-litigates settled questions and cannot tell a deliberate
choice from an accident.

## Decision

Record every significant technical decision as a numbered ADR in
`steps/decisions/`. One decision per file. Never edit a decided ADR — supersede it
with a new one that links back.

An ADR is warranted when a choice is **expensive to reverse**, **constrains later
work**, or **someone will ask "why did we do it this way?"**. Choosing a variable
name is not an ADR. Choosing a bootloader is.

## Consequences

- Onboarding and self-review get much faster.
- Cost: one short file per significant decision.
- ADRs are append-only history, not current documentation. When an ADR is
  superseded, the reader must follow the chain.

---

## Index

| ADR | Decision | Status |
|---|---|---|
| [[ADR-0001 - Record Architecture Decisions\|0001]] | Record architecture decisions | Accepted |
| [[ADR-0002 - Target x86_64 Not i686\|0002]] | Target x86_64, not i686 | Accepted |
| [[ADR-0003 - Limine as the Bootloader\|0003]] | Limine as the bootloader | Accepted |
| [[ADR-0004 - Framebuffer Console Not VGA Text\|0004]] | Framebuffer console, not VGA text mode | Accepted |
| [[ADR-0005 - Containerised Pinned Toolchain\|0005]] | Containerised, pinned toolchain | Accepted |
| [[ADR-0006 - Apple Silicon Is Not a Boot Target\|0006]] | Apple Silicon is not a boot target | Accepted |
| [[ADR-0007 - Freestanding C++20 as the Kernel Language\|0007]] | Freestanding C++20 as the kernel language | Accepted |
| [[ADR-0008 - Monorepo Layout\|0008]] | Monorepo layout | Accepted |
| [[ADR-0009 - Filesystem Strategy FAT32 then ext2\|0009]] | Filesystem strategy: FAT32 then ext2 | Accepted |
| [[ADR-0010 - Testing Strategy and the QEMU Exit Device\|0010]] | Testing strategy and the QEMU exit device | Accepted |

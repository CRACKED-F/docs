# ADR-0009 — Filesystem strategy: tmpfs, then FAT32, then ext2

**Status:** Accepted · **Date:** 2026-08-20

---

## Context

The v1 plan ended at a **read-only USTAR (tar) ramdisk**. That is fine for a
teaching milestone and useless for a product: nothing persists. Reboot and every
change is gone. A "deployable OS" must be able to write to a disk and find its data
again.

Three questions had to be answered together: what do we boot from, what do we write
to, and in what order do we build them.

## Decision

Three filesystems, introduced in this order.

### 1. `tmpfs` (Phase 7) — replaces the tar ramdisk

An in-memory, **writable** filesystem behind the VFS. Backed by the heap.

Chosen over v1's read-only tar parser because a writable filesystem from the start
means the VFS interface is designed for writes on day one. Retrofitting write support
into an interface designed read-only is a rewrite of every caller. The initrd is
still a tar archive on disk, but it is **unpacked into tmpfs** at boot rather than
being read in place.

### 2. `FAT32` (Phase 10) — the first real, persistent filesystem

- **Required regardless.** UEFI mandates a FAT-formatted EFI System Partition. We
  must be able to read and write FAT32 to build and update our own boot media
  ([[ADR-0003 - Limine as the Bootloader]]).
- Simple enough to implement correctly in a few weeks: FAT table, cluster chains,
  directory entries, long-filename entries.
- **Interoperable.** A FAT32 partition written by our OS can be mounted on macOS,
  Windows, and Linux. This is enormously valuable for debugging — when the OS writes
  a corrupt file, you can inspect it with tools that already work.
- Well documented, with the Microsoft specification publicly available.

Its weaknesses are real and accepted: no permissions, no hard links, no journalling,
4 GiB file limit, poor behaviour on unclean shutdown.

### 3. `ext2` (Phase 10, later stages) — the native filesystem

- Real Unix semantics: inodes, permissions, ownership, hard and symbolic links,
  timestamps. Needed for a credible process/user model in Phase 13.
- Well documented and stable — the on-disk format has not changed in decades.
- Readable and writable from Linux for inspection, and from macOS/Windows with
  third-party tools.
- No journal, which keeps the implementation tractable. Crash consistency is
  addressed by `fsck` at mount, not by journalling. This is an explicit v1
  limitation.

## Consequences

- **Three filesystem implementations behind one VFS.** This is the point: the VFS in
  Phase 7 is validated by three genuinely different backends, which is the only way
  to know the abstraction is real. A VFS with one implementation is not an
  abstraction, it is indirection.
- A block-device layer and buffer cache must exist before FAT32. That is Phase 9,
  sequenced before Phase 10.
- We must write a `mkfs`-equivalent, or format on the host with existing tools. v1
  formats on the host (`mkfs.fat`, `mke2fs` in the toolchain container) and only
  implements mount/read/write in the kernel. Writing our own `mkfs` is post-v1.
- No journalling means unclean shutdown can corrupt the filesystem. Accepted for v1
  and documented as a known limitation. Phase 11's ACPI shutdown path exists partly
  to make clean shutdown the normal case.

## Rejected

- **Keep read-only tar only.** Fails the product requirement outright.
- **ext4.** Journalling, extents, and delayed allocation make it several times the
  work of ext2 for benefits we cannot yet use.
- **Write our own filesystem first.** Tempting, and educational. Rejected for v1
  because a novel format cannot be inspected by any existing tool — you lose the
  ability to check your work from outside the system you are debugging. Worth doing
  *after* ext2, when you have a working reference to compare against.

## Related

[[Phase 9 - Overview]] · [[Phase 10 - Overview]] · [[ADR-0008 - Monorepo Layout]]

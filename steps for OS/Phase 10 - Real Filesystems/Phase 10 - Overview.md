# Phase 10 — Real Filesystems

**Goal:** make data survive a reboot. You will implement **FAT32** (because UEFI
requires it and every other OS can read it) and **ext2** (because it has real Unix
semantics), mount them through the VFS you built in
[[Phase 7 - Overview|Phase 7]], and make the root filesystem come from a disk instead
of a ramdisk.

At the end of this phase your OS writes a file, powers off, boots again, and the file
is still there. That is the moment it stops being a demo.

> Prerequisite: [[Phase 9 - Overview|Phase 9]] (block layer and a working disk
> driver), [[Phase 7 - Overview|Phase 7]] (the VFS).

---

## Why this phase exists

Persistence is the difference between a program and a system. It is also the phase
that validates two earlier abstractions:

- **The VFS is proven by its third implementation.** tmpfs, FAT32, and ext2 are
  genuinely different — in-memory versus on-disk, no permissions versus full Unix
  permissions, cluster chains versus inodes and block groups. A VFS with one backend
  is indirection; a VFS with three is an abstraction. If the interface needs changing
  when ext2 arrives, that is information, and it is better learned now than at Phase
  14.
- **The block layer is proven by real access patterns.** Filesystems read the same
  metadata blocks constantly. If the buffer cache from Stage 9.3 is wrong, FAT32 will
  find out.

See [[ADR-0009 - Filesystem Strategy FAT32 then ext2]] for why these two formats.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 10.1 | Stage 10.1 - Mounting and the Mount Table | Medium | `mount` / `umount`, path resolution across mounts |
| 10.2 | Stage 10.2 - FAT32 Read | Hard | List directories and read files from a real FAT32 partition |
| 10.3 | Stage 10.3 - FAT32 Write | Hard | Create, write, extend, delete; the FAT chain stays consistent |
| 10.4 | Stage 10.4 - Long Filenames (VFAT) | Medium | Names longer than 8.3 |
| 10.5 | Stage 10.5 - ext2 Read | Hard | Inodes, block groups, indirect blocks, directories |
| 10.6 | Stage 10.6 - ext2 Write | Hard | Allocate inodes and blocks, update bitmaps, link and unlink |
| 10.7 | Stage 10.7 - Permissions, Links, and Timestamps | Medium | Real Unix file metadata |
| 10.8 | Stage 10.8 - Booting From Disk | Hard | Root filesystem on disk; the ramdisk becomes optional |
| 10.9 | Stage 10.9 - fsck and Crash Consistency | Hard | Detect and repair after an unclean shutdown |

---

## Deliverable

The OS mounts a FAT32 partition and an ext2 partition from a real disk, reads and
writes files on both, resolves paths across mount points, and boots with its **root
filesystem on disk**. Files created in one boot are present in the next, with
correct sizes, permissions, and timestamps.

`fsck` runs at mount, detects an inconsistent filesystem, and repairs the common
cases.

---

## The hard parts, named in advance

**Cluster chains versus inodes.** FAT32 stores "where is the next block of this file"
in a single global table; ext2 stores it in the file's own inode with up to triple
indirection. These are opposite designs, and implementing both is where the VFS
interface earns its shape.

**Write ordering matters, and there is no journal.** When you extend a file you must
update the FAT (or the block bitmap), the directory entry (or the inode), and the
data. If power fails between them, the filesystem is inconsistent. Without
journalling — a deliberate scope decision in
[[ADR-0009 - Filesystem Strategy FAT32 then ext2]] — the mitigation is **ordering**:
write data first, metadata last, so a crash loses the write rather than corrupting
the structure. Stage 10.9 handles the rest with `fsck`.

**Directory entry allocation and reuse.** Both formats reuse deleted entries. Both
have edge cases around crossing a block boundary mid-directory. This is where the
Tier-1 tests from [[09 - Testing Strategy]] save you: cluster-chain and inode
arithmetic is pure logic and can be tested on the host in milliseconds instead of
in QEMU in seconds.

**Endianness and packing.** On-disk structures are little-endian and tightly packed.
A missing `__attribute__((packed))` shifts every field and produces garbage that
looks almost right.

---

## Why FAT32 is not optional

Even if you preferred ext2 everywhere, UEFI **mandates** a FAT-formatted EFI System
Partition. To build, update, or repair your own boot media from within your own OS —
which is what "self-hosting" starts to mean — you must be able to write FAT32.

It has a second, underrated benefit: **you can mount it on your Mac or Windows
machine.** When your OS writes a corrupt file, you can inspect it with tools that
already work. Debugging a filesystem you cannot read from outside is significantly
harder.

---

## Testing

| Tier | What |
|---|---|
| 1 | FAT cluster-chain walking, LFN checksum and reassembly, 8.3 generation, ext2 inode/block-group arithmetic, indirect-block index maths, path resolution across mounts |
| 2 | Format a RAM disk, mount, create 1000 files, read them back, delete half, verify free-space accounting |
| 3 | **Write a file, reboot the VM, read it back.** Then: pull the plug mid-write (QEMU kill), reboot, `fsck` repairs it |

That Tier-3 crash test is the one that matters. Everything else can pass while the
filesystem quietly corrupts itself on power loss.

---

## Read before you start

- Microsoft FAT32 File System Specification (the authoritative source)
- OSDev — *FAT*: <https://wiki.osdev.org/FAT>
- OSDev — *Ext2*: <https://wiki.osdev.org/Ext2>
- *The Second Extended File System* (Dave Poirier) — the best ext2 reference:
  <https://www.nongnu.org/ext2-doc/ext2.html>
- OSTEP — "File System Implementation", "Crash Consistency: FSCK and Journaling":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Previous: [[Phase 9 - Overview]] · Next: [[Phase 11 - Overview]]

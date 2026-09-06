# Stage 7.3 — The Virtual Filesystem Layer

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 7 - Overview|Phase 7 — Filesystem & Program Loading]]

---

## Concept

Right now the rest of the kernel calls `fs_read` on your tar parser directly. If you
later add a real disk filesystem, every caller would need to change. A **Virtual File
System (VFS)** prevents that: it defines one interface — `open`, `read`, `write`,
`close`, `readdir` — and each real filesystem plugs in behind it. Callers use the VFS
and never care which filesystem answers. This is also what turns your syscalls
(`sys_open`, `sys_read`) into general file access.

---

## Specification

- Define a `vfs_node` (or `file`) with function pointers (or virtual methods) for
  `read`, `write`, `open`, `close`, `readdir`, `finddir`, plus fields for name, size,
  type (file or directory), and a per-filesystem "inode" handle.
- Implement these operations for the tar filesystem from Stage 7.2 by filling in the
  function pointers.
- Provide a root node and a `vfs_open(path)` that walks the path from the root using
  `finddir`.
- Add kernel-facing `read`/`write`/`open`/`close` that dispatch through the node's
  function pointers, and wire the Phase 6 syscalls (`sys_open`, `sys_read`) to them.

---

## Your task

1. Define the `vfs_node` interface (fields + operation pointers).
2. Implement the tar filesystem behind that interface (its `read`, `finddir`,
   `readdir`).
3. Mount the tar filesystem as the VFS root.
4. Implement `vfs_open(path)`, `vfs_read`, `vfs_close`.
5. Connect `sys_open`/`sys_read`/`sys_close` (from **[[Stage 6.3 - The System Call Interface]]**)
   to the VFS.
6. Test: open a file by path, read it, and close it, all through the VFS — and from a
   user program through the syscalls.

---

## How to verify

- Opening and reading a file through `vfs_open`/`vfs_read` returns the same bytes as
  the direct `fs_read` did in Stage 7.2.
- A user program can `open`/`read`/`close` a file through the syscalls and print its
  contents.
- `readdir` on the root lists the files.

---

## Common traps

- Function-pointer fields left null, so a call through the VFS jumps to address zero
  (a page fault). Default them to safe stubs.
- Mixing up per-node state (which file) with per-open state (read position). Track the
  read offset per open handle, not per node.
- Path walking that does not handle the root or a leading slash.
- Returning internal pointers into the ramdisk to user space without copying, which
  breaks the isolation from Phase 6.

---

## Reading

- OSDev — *VFS*: <https://wiki.osdev.org/VFS>
- OSTEP — "File System Implementation" (the interface idea):
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Next: **[[Stage 7.4 - Loading and Running an ELF Program]]**.

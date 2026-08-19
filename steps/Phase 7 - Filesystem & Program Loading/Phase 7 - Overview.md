# Phase 7 — Filesystem & Program Loading

**Goal:** give your OS files and the ability to run programs from them. You will load
a **ramdisk** GRUB hands you at boot, read files from it through a simple **filesystem
format**, put a **virtual filesystem (VFS)** layer over it so the rest of the kernel
uses one `open`/`read` interface, and finally **load and run an ELF program** from a
file.

At the end of this phase the kernel can take a file named "hello", parse it, place it
in memory, and run it as a user program. That is the last piece before a shell.

> Prerequisite: **[[Phase 6 - Overview|Phase 6]]** (you run user ELF programs) and the
> heap from **[[Stage 4.4 - The Kernel Heap]]**.

---

## Why this phase exists

A shell is worthless if there is nothing to run and no files to act on. Programs must
live somewhere and be loaded on demand. A ramdisk is the simplest "somewhere": GRUB
loads a file image into memory for you as a **module**, so you skip writing a disk
driver and a real on-disk filesystem for now, and focus on files and program loading.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 7.1 | [[Stage 7.1 - The Initial Ramdisk]] | Medium | A file image loaded by GRUB. |
| 7.2 | [[Stage 7.2 - A Read-Only Filesystem]] | Medium | List and read files by name. |
| 7.3 | [[Stage 7.3 - The Virtual Filesystem Layer]] | Medium | One `open`/`read`/`close` API. |
| 7.4 | [[Stage 7.4 - Loading and Running an ELF Program]] | Hard | Run a program from a file. |

---

## Deliverable

The kernel lists the files in the ramdisk, reads a named file's contents, and loads an
ELF program from a file into a fresh address space and runs it in ring 3 through the
Phase 6 machinery. Files and programs now come from "disk", not from being baked into
the kernel.

---

## Read before you start

- OSDev — *USTAR*, *VFS*, *ELF*, *ELF Tutorial*:
  <https://wiki.osdev.org/USTAR> · <https://wiki.osdev.org/VFS> ·
  <https://wiki.osdev.org/ELF> · <https://wiki.osdev.org/ELF_Tutorial>
- OSTEP — "File System Implementation", "Files and Directories":
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Previous: **[[Phase 6 - Overview]]** · Next: **[[Phase 8 - Overview]]**.

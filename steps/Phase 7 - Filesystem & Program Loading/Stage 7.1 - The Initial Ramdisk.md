# Stage 7.1 — The Initial Ramdisk

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 7 - Overview|Phase 7 — Filesystem & Program Loading]]

---

## Concept

A **ramdisk** (initrd) is a file image loaded into RAM at boot and treated as a
read-only disk. You do not need a disk driver to have files: GRUB can load an extra
file — a **Multiboot module** — alongside your kernel and tell you where it is in
memory. You build that module on your host (an archive of your files), list it in
`grub.cfg`, and read its address from the Multiboot info. This is your OS's first
storage.

---

## Specification

- In `grub.cfg`, add a `module` line after the `multiboot` line, naming your archive
  file. GRUB loads it and records it in the Multiboot info.
- Set bit 3 in the Multiboot header flags (module alignment) if you want modules page
  aligned. The Multiboot info's `mods_count` and `mods_addr` describe loaded modules;
  each module entry has a start address, an end address, and a name string.
- Read the module's start/end from the Multiboot info (extend
  **[[Stage 4.1 - Reading the Memory Map]]**), and **reserve** that physical range in
  the frame allocator so it is not handed out.
- Build the archive on your host and place it in `isodir/boot/` next to the kernel.

---

## Your task

1. Build a small archive (a few text files) on your host — the format is chosen in
   Stage 7.2; a `tar` archive is the plan.
2. Add a `module /boot/initrd.tar` line to `grub.cfg` and stage the file in `isodir`.
3. Parse `mods_count` / `mods_addr` from the Multiboot info and read the module's
   start and end addresses.
4. Reserve the module's physical range in the frame allocator.
5. Print the module's address range and size to confirm GRUB loaded it.

---

## How to verify

- The printed module size matches the archive file's size on your host.
- The first bytes at the module address match the archive's first bytes (for a tar,
  the first file's name is near the start).
- The frame allocator never hands out the module's range (allocate many frames and
  confirm none overlap it).

---

## Common traps

- Forgetting to reserve the module memory, so the allocator later overwrites your
  files.
- A `grub.cfg` path that does not match where the archive sits in `isodir`.
- Reading `mods_addr` as the module data instead of as a pointer to the module
  *descriptor* (which then points at the data).
- Building the ISO without the module staged, so `mods_count` is zero.

---

## Reading

- OSDev — *Multiboot* (modules section):
  <https://wiki.osdev.org/Multiboot>
- JamesM's tutorial, "The VFS and the initrd" (mind the errata):
  <http://www.jamesmolloy.co.uk/tutorial_html/> ·
  <https://wiki.osdev.org/James_Molloy's_Tutorial_Known_Bugs>

Next: **[[Stage 7.2 - A Read-Only Filesystem]]**.

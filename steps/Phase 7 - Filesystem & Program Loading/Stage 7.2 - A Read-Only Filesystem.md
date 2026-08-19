# Stage 7.2 — A Read-Only Filesystem

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 7 - Overview|Phase 7 — Filesystem & Program Loading]]

---

## Concept

The ramdisk is a blob of bytes. A **filesystem format** gives it structure: named
files with sizes and contents. The easiest choice is **USTAR**, the standard `tar`
format. You already have `tar` on your host to build the archive, and its layout is
simple: a 512-byte header per file (name, size, type), then the file data padded to a
512-byte boundary, repeated. Parsing it is a short loop. Read-only is enough for now.

---

## Specification

- A USTAR entry is a **512-byte header** followed by the file data, padded up to the
  next 512-byte boundary.
- Header fields you need: the file **name** (offset 0, up to 100 bytes), the **size**
  (offset 124, an **octal** ASCII string), and the **type flag** (offset 156; `'0'` or
  `\0` is a regular file). The size is octal text — convert it to a number.
- Walk the archive: read a header, note the name and size, record where the data
  begins, then advance past the data (rounded up to 512) to the next header. Stop at
  the end-of-archive marker (a zero-filled block).
- Provide `fs_list()` (names), `fs_find(name)` (locate an entry), and
  `fs_read(entry, buf, len)` (copy bytes out).

---

## Your task

1. Define the USTAR header layout (offsets above) as a struct or with explicit field
   reads.
2. Write a parser that walks the archive from the module start, building a list of
   `{name, data_pointer, size}`.
3. Convert the octal size field to an integer.
4. Implement `fs_list`, `fs_find(name)`, and `fs_read`.
5. Test: list the files, then read one text file and print its contents.

---

## How to verify

- `fs_list` prints exactly the files you put in the archive, with correct sizes.
- Reading a known text file prints its exact contents.
- `fs_find` returns the right entry for a valid name and nothing for a missing name.

---

## Common traps

- **Reading the size as decimal.** The tar size field is octal ASCII; parse it as base
  8.
- Not rounding the data length up to a 512-byte boundary when advancing to the next
  header, so parsing desynchronizes after the first file.
- Assuming a fixed number of files instead of stopping at the zero-block end marker.
- Off-by-one on the 100-byte name field; names can use the full width without a
  terminator.

---

## Reading

- OSDev — *USTAR* (exact header field offsets):
  <https://wiki.osdev.org/USTAR>
- The `tar` format description (GNU): <https://www.gnu.org/software/tar/manual/html_node/Standard.html>

Next: **[[Stage 7.3 - The Virtual Filesystem Layer]]**.

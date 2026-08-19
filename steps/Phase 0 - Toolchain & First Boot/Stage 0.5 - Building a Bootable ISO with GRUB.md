# Stage 0.5 — Building a Bootable ISO with GRUB

**Difficulty:** Medium · ~25 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

QEMU's `-kernel` flag is a shortcut: QEMU itself acts as the bootloader. A real PC
does not. To boot the way real hardware does — and to load extra files later, like
the ramdisk in **[[Phase 7 - Overview|Phase 7]]** — you package GRUB and your kernel
into a bootable **ISO**. `grub-mkrescue` does this: you give it a directory laid out
like a boot disk, it produces `os.iso`, and QEMU boots that ISO with no special
flags.

---

## Specification

The directory layout `grub-mkrescue` expects:

```
isodir/
└── boot/
    ├── mykernel.bin
    └── grub/
        └── grub.cfg
```

A minimal `grub.cfg`:

```
menuentry "MyOS" {
    multiboot /boot/mykernel.bin
}
```

Build and boot:

```sh
grub-mkrescue -o os.iso isodir      # needs xorriso installed
qemu-system-i386 -cdrom os.iso
```

> **macOS note:** `grub-mkrescue` is not available natively. Run this step in a small
> Linux container (Docker/OrbStack) mounting your project folder, or keep using
> `-kernel` from Stage 0.4 and build the ISO on a Linux/WSL machine when you need
> modules. A container recipe:
> ```sh
> docker run --rm -v "$PWD":/os -w /os ubuntu:24.04 \
>   sh -c "apt-get update && apt-get install -y grub-pc-bin grub-common xorriso && \
>          grub-mkrescue -o os.iso isodir"
> ```

---

## Your task

1. Create the `isodir/boot/grub/` directory tree.
2. Copy `mykernel.bin` into `isodir/boot/`.
3. Write `grub.cfg` with a single `menuentry` that uses `multiboot
   /boot/mykernel.bin`.
4. Run `grub-mkrescue -o os.iso isodir` (natively on WSL/Linux, or via the container
   on macOS).
5. Boot it: `qemu-system-i386 -cdrom os.iso`.

---

## How to verify

- `grub-mkrescue` produces `os.iso` with no errors.
- `qemu-system-i386 -cdrom os.iso` shows the GRUB menu (or boots straight through)
  and then your white `A` appears. You now boot exactly as real hardware would.

---

## Common traps

- **`xorriso` not installed.** `grub-mkrescue` calls it to build the ISO and fails
  without it.
- **Wrong GRUB command in `grub.cfg`.** Use `multiboot` (Multiboot 1). `multiboot2`
  will not load a Multiboot-1 kernel.
- **Path mismatch.** The path in `grub.cfg` (`/boot/mykernel.bin`) must match where
  the file sits inside `isodir`.
- On some distros the tool is `grub2-mkrescue`. Check both names.

---

## Reading

- OSDev — *Bare Bones* (the "Building an ISO" section): <https://wiki.osdev.org/Bare_Bones>
- OSDev — *GRUB*: <https://wiki.osdev.org/GRUB>
- GRUB manual — `grub-mkrescue`:
  <https://www.gnu.org/software/grub/manual/grub/grub.html>

Next: **[[Stage 0.6 - The Makefile & Build-Run Loop]]**.

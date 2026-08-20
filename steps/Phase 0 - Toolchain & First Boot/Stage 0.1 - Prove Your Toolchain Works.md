# Stage 0.1 — Prove Your Toolchain Works

**Difficulty:** Very Easy · ~10 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

Before writing a kernel, prove the machine that builds it works. Three things must be
true: the **container** runs, the **cross-compiler** produces an `x86_64-elf` object,
and **QEMU** starts.

This stage is a smoke test. It fails fast and clearly if the setup is wrong, instead
of hiding a broken tool inside a blank-screen boot three stages later — which is the
single most demoralising way to lose a weekend.

---

## Specification

- All builds happen **inside the toolchain container**
  ([[ADR-0005 - Containerised Pinned Toolchain]]). `make shell` puts you there.
- The cross-compiler is `x86_64-elf-gcc` / `x86_64-elf-g++`. Not `gcc`. Not
  `x86_64-linux-gnu-gcc`.
- A freestanding object needs no `main` and no C library:
  `-ffreestanding -nostdlib -c` is enough to compile one.
- QEMU runs on the **host**, not in the container. The binary is
  `qemu-system-x86_64`.

---

## Your task

1. Clone the repository and run `make shell`. Confirm you get a prompt inside the
   container.
2. Inside the container, check every tool answers:
   ```sh
   x86_64-elf-gcc --version      # expect 14.2.0
   x86_64-elf-g++ --version
   x86_64-elf-ld --version       # expect binutils 2.43
   nasm --version
   cmake --version
   ls "$LIMINE_DIR/BOOTX64.EFI"  # the UEFI bootloader must be present
   ```
3. Write a one-line C++ file with a single empty function, e.g. `void probe() {}`.
4. Compile it with the kernel flag set:
   ```sh
   x86_64-elf-g++ -ffreestanding -fno-exceptions -fno-rtti \
       -mno-red-zone -mno-sse -mno-mmx -mno-80387 -mcmodel=kernel \
       -std=c++20 -c probe.cpp -o probe.o
   ```
5. Confirm the output is the right kind of object:
   ```sh
   file probe.o                  # ELF 64-bit LSB relocatable, x86-64
   x86_64-elf-readelf -h probe.o # Class: ELF64, Machine: Advanced Micro Devices X86-64
   ```
6. On the **host**, start QEMU with no disk and confirm it complains it has nothing
   to boot:
   ```sh
   qemu-system-x86_64 -m 512M
   ```
7. Confirm UEFI firmware is available on the host — you will need it from Stage 0.7:
   ```sh
   ls /usr/share/OVMF/OVMF_CODE.fd    # or wherever your platform puts it
   ```

---

## How to verify

- Every tool prints a version, not "command not found".
- The compile prints nothing and exits 0.
- `file probe.o` says **`ELF 64-bit LSB relocatable, x86-64`**. Not Mach-O, not
  32-bit, not `x86-64 ... GNU/Linux`.
- QEMU opens a window (or a text screen) and says it has no bootable device. That
  "error" is success — it means QEMU runs.

---

## Common traps

- **Typing `gcc` out of habit.** The host compiler will happily build the object and
  mislead you for hours. If `file` reports `Mach-O` you are on macOS running the host
  compiler; if it reports `ELF 64-bit ... GNU/Linux` you ran the Linux system
  compiler, not the cross-compiler.
- **Building on the host instead of in the container.** The whole point of
  [[ADR-0005 - Containerised Pinned Toolchain]] is that your machine, your teammate's
  machine, and CI produce identical bytes. Get into the habit now.
- **Forgetting `-mno-red-zone`.** It costs nothing today and prevents a category of
  random corruption later that is genuinely hard to diagnose. See
  [[ADR-0002 - Target x86_64 Not i686]]. CI enforces it from Stage 0.9.
- **Docker permission denied on Linux.** You are not in the `docker` group, or have
  not logged out since being added.
- **On Apple Silicon, the container feels slow.** Expected — it runs under
  `linux/amd64` emulation so that its output matches CI exactly. `ccache` inside the
  image keeps incremental builds quick.

---

## Reading

- [[02 - Toolchain Setup]] if any tool is missing
- [[ADR-0005 - Containerised Pinned Toolchain]] for why it works this way
- OSDev — *Why do I need a Cross Compiler?*
  <https://wiki.osdev.org/Why_do_I_need_a_Cross_Compiler%3F>

Next: **Stage 0.2 - The Limine Request Section**

# Toolchain Setup (Mac & Windows)

You do this once. It gives you the tools to compile a kernel that runs on **no
operating system** and to boot it in an emulator. Detailed, per-stage use of these
tools starts in **[[Phase 0 - Overview|Phase 0]]**.

> **Why a special toolchain?** Your Mac or Windows compiler builds programs *for
> your Mac or Windows*. It assumes an OS is present. A kernel has no OS under it, so
> you need a **cross-compiler** that targets a bare `i686-elf` machine. This is not
> optional. Using the host compiler is the top beginner mistake and it fails in
> confusing ways. See OSDev's *Why do I need a Cross Compiler?* in
> **[[03 - Resources & Reading]]**.

---

## What you will install

| Tool | Job |
|---|---|
| `i686-elf-gcc` / `i686-elf-g++` | The cross-compiler that builds the kernel. |
| `i686-elf-binutils` | Assembler and linker for the target (`ld`, `as`). |
| `nasm` | Assembler for the small hand-written assembly parts. |
| `qemu` (`qemu-system-i386`) | The emulator that runs your OS. |
| `grub` + `xorriso` | Build a bootable ISO image with GRUB. |
| `make` | Runs the build-and-run loop. |
| `gdb` | Debugger that attaches to QEMU. |

---

## macOS (Apple Silicon and Intel)

Use [Homebrew](https://brew.sh). QEMU emulates x86 on Apple Silicon with no extra
work — the target is x86 even though your CPU is ARM.

1. Install Homebrew if you do not have it (see the link above).
2. Install the emulator, assembler, and helpers:
   ```sh
   brew install qemu nasm xorriso make gdb
   ```
3. Install a prebuilt cross-compiler. The community tap is the fast path:
   ```sh
   brew install i686-elf-gcc i686-elf-binutils
   ```
4. GRUB does not run natively on macOS. Two clean options:
   - **Easiest:** build the ISO inside a small Linux container (Docker or OrbStack).
     A ready recipe is in **[[Stage 0.5 - Building a Bootable ISO with GRUB]]**.
   - **Alternative:** boot the raw kernel with QEMU's built-in Multiboot loader
     (`qemu-system-i386 -kernel mykernel.bin`) and postpone the ISO. Phase 0 shows
     both.

> If `brew install i686-elf-gcc` fails, build the cross-compiler from source with
> the OSDev *GCC Cross-Compiler* guide (linked in **[[03 - Resources & Reading]]**).
> Budget an hour. It is a one-time cost.

---

## Windows

Do **not** build the toolchain in raw Windows. Use **WSL2** (Windows Subsystem for
Linux). It gives you a real Linux where every OSDev instruction works verbatim, and
GRUB runs natively.

1. Open PowerShell as Administrator and install WSL with Ubuntu:
   ```powershell
   wsl --install -d Ubuntu
   ```
   Reboot if it asks. Open **Ubuntu** from the Start menu and create your user.
2. Inside Ubuntu, install the tools:
   ```sh
   sudo apt update
   sudo apt install -y build-essential nasm qemu-system-x86 grub-pc-bin grub-common xorriso gdb
   ```
3. Install the cross-compiler. Prebuilt packages drift, so building from source is
   the reliable path here. Follow the OSDev *GCC Cross-Compiler* guide (in
   **[[03 - Resources & Reading]]**), targeting `i686-elf`. Budget an hour, once.
4. QEMU shows a window through WSLg on Windows 11. On Windows 10, install QEMU for
   Windows separately and run the built ISO with it, or use `-display none` plus
   serial output.

> Keep your code **inside** the WSL filesystem (for example `~/os`), not on the
> Windows `C:` drive path (`/mnt/c/...`). Builds there are much slower.

---

## Verify the setup

Run these. Each should print a version, not "command not found".

```sh
i686-elf-gcc --version
i686-elf-g++ --version
nasm --version
qemu-system-i386 --version
grub-mkrescue --version    # or grub2-mkrescue on some systems
xorriso --version
gdb --version
```

When all seven answer, you are ready for **[[Phase 0 - Overview|Phase 0]]**.

---

## Common traps

- **Wrong target triple.** It must be `i686-elf`, not `i686-linux-gnu` and not your
  host's default. A linux target links against a C library you do not have.
- **Using `gcc` instead of `i686-elf-gcc` by habit.** The build will look like it
  works and then behave strangely at boot. Always call the prefixed tool.
- **macOS + GRUB frustration.** Do not fight it. Use the container recipe or QEMU's
  `-kernel` loader while you learn. Switch to a real ISO later.
- **`grub-mkrescue` reports "xorriso not found".** Install `xorriso`; GRUB shells
  out to it to build the ISO.

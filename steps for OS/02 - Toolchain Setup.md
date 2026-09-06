# Toolchain Setup

You do this once, on each machine. It takes about fifteen minutes, most of which is
Docker downloading things.

> **This supersedes the old per-OS manual install.** See
> [[ADR-0005 - Containerised Pinned Toolchain]] for why.

---

## Why a container instead of installing a compiler

Your Mac or Windows compiler builds programs *for your Mac or Windows*. It assumes an
operating system is present. A kernel has none, so you need a **cross-compiler**
targeting a bare `x86_64-elf` machine.

The old plan was for each of you to build one by hand — Homebrew on macOS, "build
from source, budget an hour" on Windows. That produces **three different compilers**
across two developers and CI. In kernel work that matters more than anywhere else:

- Different GCC versions make different inlining and stack-layout decisions. A race
  that never fires on one machine fires reliably on the other.
- Your teammate reports a boot crash you cannot reproduce, and you lose a day
  discovering the difference was `gcc 14.2` versus `gcc 15.1`.
- CI is green while local is red. An untrusted CI gets bypassed, and then it is worse
  than no CI.

So: **one pinned Docker image, used by both developers and by CI.** Identical bytes
everywhere.

---

## What you install on the host

Only two things.

| Tool | Why on the host |
|---|---|
| **Docker** | Runs the toolchain image — the compiler, linker, Limine, image tools |
| **QEMU** | Runs the OS. GUI output and hardware acceleration do not survive containerisation cleanly |

Everything else — `x86_64-elf-gcc`, binutils, nasm, xorriso, mtools, OVMF, GDB,
clang-format, Limine — lives inside the image.

---

## macOS (Apple Silicon and Intel)

```sh
# Docker. OrbStack is lighter and faster than Docker Desktop; either works.
brew install --cask orbstack        # or: brew install --cask docker

# QEMU on the host
brew install qemu
```

> **Apple Silicon note.** The container runs under `linux/amd64` emulation, which is
> slower than native. This is deliberate: a native arm64 image would produce
> different output from CI, which defeats the whole point. `ccache` inside the image
> keeps incremental builds fast — a full kernel rebuild is still under a minute.
>
> Your Mac is a **development machine, not a boot target**. The OS will not boot
> natively on Apple Silicon — see [[ADR-0006 - Apple Silicon Is Not a Boot Target]].
> It runs under QEMU, and it boots natively on any x86_64 UEFI machine.

---

## Windows 11

Use **WSL2**. Docker Desktop integrates with it, and the whole toolchain behaves
exactly as it does on Linux and in CI.

```powershell
# 1. WSL2 with Ubuntu
wsl --install -d Ubuntu
#    Reboot if prompted, then open Ubuntu and create your user.

# 2. Docker Desktop, with the WSL2 backend enabled
winget install Docker.DockerDesktop
#    Settings -> Resources -> WSL Integration -> enable for Ubuntu
```

Then inside Ubuntu:

```sh
sudo apt update && sudo apt install -y qemu-system-x86 ovmf
```

> **Keep the repository inside the WSL filesystem** (`~/os`), not on the Windows
> drive (`/mnt/c/...`). Builds on `/mnt/c` are several times slower because every
> file access crosses a translation layer.
>
> QEMU displays through WSLg on Windows 11 with no extra setup.

---

## Linux

```sh
sudo apt install -y docker.io qemu-system-x86 ovmf
sudo usermod -aG docker "$USER"     # log out and back in
```

---

## Get the toolchain image

```sh
git clone https://github.com/CRACKED-F/os.git
cd os

# Pull the published image (fast), or build it locally (~25 min, once)
docker pull ghcr.io/cracked-f/os-toolchain:latest
# or
make toolchain
```

---

## Verify

```sh
make shell
```

That drops you into the toolchain container. Inside it:

```sh
x86_64-elf-gcc --version      # 14.2.0
x86_64-elf-g++ --version
x86_64-elf-ld --version       # binutils 2.43
nasm --version
ls $LIMINE_DIR/BOOTX64.EFI    # the UEFI bootloader
cmake --version
```

Back on the host:

```sh
qemu-system-x86_64 --version
```

When all of those answer, you are ready for [[Phase 0 - Overview|Phase 0]].

---

## The verbs you will actually use

```
make shell        # shell inside the toolchain container
make              # build kernel, libc, user programs, initrd
make run          # build the ISO and boot it (BIOS), serial to your terminal
make run-uefi     # boot the disk image under UEFI firmware
make debug        # QEMU frozen, waiting for GDB on :1234
make test         # all three test tiers
make fmt          # format the code
make help         # everything
```

**Build in the container, run QEMU on the host.** `make` handles the handoff — you do
not need to think about it.

---

## Common traps

- **Running `gcc` out of habit.** Inside the container the cross-compiler is
  `x86_64-elf-gcc`. The host compiler will happily build an object and mislead you
  for hours. If `file kernel.o` says anything other than `ELF 64-bit LSB relocatable,
  x86-64`, the wrong compiler ran.
- **Editing on Windows, building in WSL, with the repo on `/mnt/c`.** Slow, and line
  endings will fight you. Keep it in the WSL filesystem; `.gitattributes` handles the
  rest.
- **`docker: permission denied` on Linux.** You are not in the `docker` group yet, or
  you have not logged out since being added.
- **Pinning to `:latest`.** Fine while getting started. Before you rely on
  reproducibility, pin the image **digest** in the `Makefile` and the workflows —
  `toolchain.yml` prints the digest to use after every build.
- **OVMF not found.** `make run-uefi` needs UEFI firmware on the host. On Ubuntu/WSL
  it is `/usr/share/OVMF/OVMF_CODE.fd`; on macOS, `brew install qemu` includes it at
  a different path — set `OVMF_CODE` if `make` cannot find it.

---

## Related

[[ADR-0005 - Containerised Pinned Toolchain]] · [[08 - Build System]] · [[Phase 0 - Overview]]

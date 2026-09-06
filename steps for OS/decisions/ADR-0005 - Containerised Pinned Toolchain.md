# ADR-0005 — Containerised, pinned toolchain

**Status:** Accepted · **Date:** 2026-08-20
**Supersedes:** the per-OS manual install in v1 `02 - Toolchain Setup`

---

## Context

The team is two people on **different operating systems**: one on macOS (Apple
Silicon), one on Windows 11. CI is a third environment (Ubuntu on GitHub Actions).

The v1 plan told each developer to install a cross-compiler by hand — Homebrew on
macOS, "build from source, budget an hour" on Windows/WSL. That produces three
different compilers with three different versions, and in kernel development that
matters enormously:

- Different GCC versions make different inlining and stack-layout decisions. A race
  that never fires on one machine fires reliably on the other.
- "Works on my machine" is unfalsifiable when the machines genuinely differ.
- A bug report from your teammate is unreproducible, and you burn a day discovering
  the difference was `gcc 14.2` versus `gcc 15.1`.
- CI green while local is red (or the reverse) destroys trust in CI, and a CI nobody
  trusts is worse than no CI.

For a two-person team, an afternoon lost to toolchain drift is a meaningful fraction
of a week's output.

## Decision

**All builds happen inside a pinned Docker image.** The image is defined in
`toolchain/Dockerfile`, tagged by content hash, and published to GHCR as
`ghcr.io/cracked-f/os-toolchain`.

Every environment uses the same image:

| Environment | How |
|---|---|
| macOS (Apple Silicon) | Docker Desktop / OrbStack, `linux/amd64` platform |
| Windows 11 | Docker Desktop with WSL2 backend |
| CI | `container:` key in the GitHub Actions job |

`make` on the host is a thin wrapper that runs the real build in the container.
`make shell` drops you into it. Nothing is installed on the host except Docker and
QEMU.

Pinned inside the image, by exact version:

- `x86_64-elf-gcc` / `g++` and `binutils` (built from source, versions pinned)
- `nasm`
- `clang-format`, `clang-tidy` (for lint parity with CI)
- `xorriso`, `mtools`, `dosfstools`, `parted` (image building)
- `limine` at a pinned tag ([[ADR-0003 - Limine as the Bootloader]])
- `gdb` with x86_64 target support
- `cmake`, `ninja`

## Consequences

- **Reproducible builds.** Identical bytes on both machines and in CI. When your
  teammate says "it crashes on boot", you can reproduce it.
- Docker becomes a hard prerequisite. Acceptable — it is one install on each
  platform, versus an hour of compiler-from-source per developer plus ongoing drift.
- **QEMU runs on the host, not in the container.** GUI/framebuffer output and KVM
  acceleration do not survive containerisation cleanly. The container builds the
  ISO; the host runs it. `make run` handles the handoff. Headless CI runs QEMU
  inside the container with `-display none`.
- On Apple Silicon, the container runs under `linux/amd64` emulation, which is
  slower. Mitigated by keeping the build incremental and by `ccache` inside the
  image. A full kernel rebuild is still under a minute.
- Updating the toolchain becomes an explicit, reviewed commit that changes the
  Dockerfile and the pinned tag — visible in `git log`, not a silent `brew upgrade`.

## Consequences for onboarding

New machine setup drops from "budget an hour, maybe a day if the cross-compiler
build fails" to:

```
git clone && make shell
```

## Alternatives rejected

- **Nix.** Genuinely better at reproducibility and would work. Rejected on team
  familiarity: neither member knows Nix, and the learning curve competes directly
  with the actual project. Revisit if Docker proves painful.
- **Devcontainers only.** A devcontainer is a thin layer over this same Dockerfile;
  we ship one (`.devcontainer/`) *pointing at* the pinned image, but the image
  remains the source of truth so CI and CLI use exactly the same thing.
- **Per-OS install scripts.** The v1 approach. Rejected — it is the problem.

## Related

[[ADR-0006 - Apple Silicon Is Not a Boot Target]] · [[02 - Toolchain Setup]] · [[10 - CI Pipeline]]

# CI Pipeline

What runs automatically, when, and what it protects.

Working workflows are committed at `scaffold/.github/workflows/`. Copy them into
`CRACKED-F/os` when you create it.

---

## Principle

**CI runs the same commands you run locally.** It has no private build recipe. Every
job is `make <target>` inside the same pinned container
([[ADR-0005 - Containerised Pinned Toolchain]]).

When CI fails, you reproduce it with one command. A CI that can only be debugged by
pushing commits is a CI nobody trusts, and an untrusted CI gets bypassed.

---

## The four workflows

| Workflow | Trigger | Wall clock | Purpose |
|---|---|---|---|
| `ci.yml` | every push + PR | ~6 min | the merge gate |
| `nightly.yml` | 03:00 UTC daily | ~40 min | full matrix + stress |
| `release.yml` | tag `v*` | ~15 min | build and publish artefacts |
| `toolchain.yml` | `toolchain/**` changes | ~25 min | rebuild + push the image |

---

## `ci.yml` — the merge gate

Staged so cheap checks fail fast. No point booting a kernel that does not lint.

```
 push / pull_request
        │
        ├── lint          (~30s)  clang-format, clang-tidy, boundary greps
        │
        ├── build         (~2m)   kernel, libc, user, initrd, iso, img
        │      │
        │      ├── test-unit      (~20s)  Tier 1, host-native
        │      ├── test-kernel    (~2m)   Tier 2, in-kernel self-tests
        │      └── test-boot      (~3m)   Tier 3, boot matrix
        │
        └── artifacts     upload os.iso + os.img + kernel.elf (14-day retention)
```

### The `lint` job — boundary enforcement

This is where the architectural rules in [[07 - Repository Layout]] stop being
aspirations. Each grep protects a specific decision:

```sh
# 1. -mno-red-zone on EVERY kernel translation unit.
#    Missing it = random corruption, discovered weeks later. ADR-0002.
jq -r '.[].command' build/compile_commands.json \
  | grep -v -- '-mno-red-zone' && { echo "TU missing -mno-red-zone"; exit 1; }

# 2. Limine must not leak out of arch/x86_64/boot/. ADR-0003 escape hatch.
grep -rl 'limine\.h' kernel/ --include='*.?pp' \
  | grep -v '^kernel/arch/x86_64/boot/' && { echo "limine.h leaked"; exit 1; }

# 3. No inline asm outside arch/. Keeps a second arch additive.
grep -rnE '\b(asm|__asm__)\s*(volatile)?\s*\(' kernel/ --include='*.?pp' \
  | grep -v '^kernel/arch/' && { echo "asm outside arch/"; exit 1; }

# 4. Kernel must not include userspace headers.
grep -rnE '#include\s*[<"](libc|user)/' kernel/ && exit 1

# 5. No __DATE__/__TIME__ — breaks reproducible builds.
grep -rn '__DATE__\|__TIME__' kernel/ libc/ user/ && exit 1

# 6. No TODO without an issue number. Prevents silent debt.
grep -rnE 'TODO(?!\(#[0-9]+\))' kernel/ libc/ user/ -P && exit 1
```

Also: `clang-format --dry-run --Werror` and `clang-tidy` on the compile database.

### Caching

- Container image from GHCR (pulled by digest, not tag)
- `ccache` volume keyed on `${{ hashFiles('**/*.cpp','**/*.hpp') }}`
- Limine checkout keyed on the pinned tag

Cold cache ~12 min; warm ~6 min.

### Required status checks

Branch protection on `master` requires **all** of: `lint`, `build`, `test-unit`,
`test-kernel`, `test-boot`. See [[12 - Team Workflow]].

---

## `nightly.yml` — the things too slow to gate on

Runs at 03:00 UTC. Opens an issue on failure (and does not spam — it updates the
existing issue if one is open).

- **Full boot matrix**: BIOS/UEFI × ISO/IMG × 1/2/4/8 cores × 128M/512M/4G RAM
- **Memory stress**: 1 000 000-iteration heap torture; assert no leak and no
  fragmentation collapse
- **Fork bomb / scheduler stress**: hundreds of tasks, assert fairness and no
  deadlock
- **Filesystem torture**: random write/read/delete against FAT32 and ext2, then
  unmount, remount, `fsck` — assert clean
- **Long-run soak**: boot and idle for 30 minutes; assert no tick drift, no memory
  growth, still responsive
- **Reproducibility**: `make verify-repro` — build twice, diff artefacts
- **Sanitiser build**: Tier 1 tests under ASan and UBSan

Stress tests belong here rather than in `ci.yml` specifically because they are slow
and occasionally flaky. A flaky merge gate is worse than no gate — it trains people
to hit re-run without reading.

---

## `release.yml` — see [[11 - Release and Deployment]]

Triggered by a `v*` tag. Builds every artefact, generates checksums, writes the
changelog, and publishes a GitHub Release.

---

## `toolchain.yml` — the container image

Triggers on changes under `toolchain/`. Builds the image, runs a smoke test (build
the kernel with it), and pushes to `ghcr.io/cracked-f/os-toolchain` tagged with both
the commit SHA and `latest`.

**The repo pins the digest, not `latest`.** Updating the toolchain is therefore an
explicit PR that changes the pinned digest — visible in `git log`, reviewable, and
revertable. A toolchain that updates itself is a toolchain that breaks your build on
a morning you had other plans.

---

## Reading a CI failure

Every failing job uploads:

| Artefact | Why |
|---|---|
| `serial.log` | the kernel's own account of what happened — **read this first** |
| `qemu-stderr.log` | QEMU's complaints (bad instruction, unassigned memory access) |
| `kernel.elf` | for local `addr2line` / GDB against the exact failing build |
| `screenshot.ppm` | QEMU `-display none` still supports `screendump` via the monitor |

Reproduce locally:

```sh
gh run download <run-id>
make debug                       # same image, GDB waiting on :1234
make gdb
```

---

## Deliberately not in CI

| Not doing | Why |
|---|---|
| Real-hardware runners | No hardware runner; manual release checklist instead |
| Performance benchmarks | Benchmarking emulated hardware measures QEMU |
| Fuzzing | Post-1.0. Syscall-boundary fuzzing is the obvious first target |
| Coverage gate | Tier-1-only coverage; a gate would produce theatre |

---

## Related

[[09 - Testing Strategy]] · [[11 - Release and Deployment]] · [[12 - Team Workflow]] · [[08 - Build System]]

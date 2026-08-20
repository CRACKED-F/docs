# Scaffold — the OS repository skeleton

**This directory is not part of the docs.** It is a ready-to-use project skeleton
for the code repository, `CRACKED-F/os`, kept here so the specs in
[`../steps/`](../steps/) and the files that implement them stay in one place until
the code repo exists.

## How to use it

```sh
# 1. Create the code repo
gh repo create CRACKED-F/os --private --clone
cd os

# 2. Copy the scaffold in
cp -r ../docs/scaffold/. .

# 3. Fill in the placeholders
#    - .github/CODEOWNERS      -> real GitHub usernames
#    - Makefile TOOLCHAIN      -> pinned image digest once published
#    - .github/workflows/*.yml -> pinned image digest

# 4. Build the toolchain image once
make toolchain

# 5. First commit
git add -A && git commit -m "chore: project scaffold" && git push -u origin master
```

Then start [`Phase 0`](../steps/Phase%200%20-%20Toolchain%20%26%20First%20Boot/).

---

## What is here

| Path | What | Spec |
|---|---|---|
| `toolchain/Dockerfile` | Pinned cross-toolchain: `x86_64-elf-gcc` 14.2, binutils 2.43, Limine, QEMU, OVMF, image tools | [ADR-0005](../steps/decisions/) |
| `Makefile` | Thin host wrapper — every verb the team types. No build logic | [08 - Build System](../steps/) |
| `.github/workflows/ci.yml` | Merge gate: lint, build, three test tiers, boot matrix | [10 - CI Pipeline](../steps/) |
| `.github/workflows/release.yml` | Tag → all artefacts → draft GitHub Release | [11 - Release and Deployment](../steps/) |
| `.github/workflows/nightly.yml` | Full matrix, stress, soak, reproducibility, sanitisers | [10 - CI Pipeline](../steps/) |
| `.github/workflows/toolchain.yml` | Rebuild + publish the container image | [ADR-0005](../steps/decisions/) |
| `.github/CODEOWNERS` | The two-person ownership split | [12 - Team Workflow](../steps/) |
| `.github/pull_request_template.md` | Enforces the definition of done | [12 - Team Workflow](../steps/) |
| `.github/ISSUE_TEMPLATE/` | Bug report (demands a serial log) and stage tracker | [12 - Team Workflow](../steps/) |
| `scripts/test.sh` | All three test tiers, incl. the `isa-debug-exit` protocol | [09 - Testing Strategy](../steps/) |
| `scripts/mkimage.sh` | Hybrid BIOS+UEFI ISO, GPT disk image, VM appliances | [11 - Release and Deployment](../steps/) |
| `scripts/lint.sh` | The architectural boundary rules — same script CI runs | [07 - Repository Layout](../steps/) |
| `scripts/verify-repro.sh` | Build twice, diff artefacts | [08 - Build System](../steps/) |
| `boot/limine.conf` | Boot menu incl. verbose, single-core, and self-test entries | [ADR-0003](../steps/decisions/) |
| `.clang-format` / `.clang-tidy` | Style and static analysis | [13 - Coding Standards](../steps/) |

---

## What is deliberately not here

**The kernel source.** That is Phase 0 onward — writing it is the project.

**`CMakeLists.txt` and the toolchain files.** They are Stage 0.6's deliverable. The
`Makefile` calls them; writing them is a stage, not scaffolding.

**`tests/integration/run.py`.** Referenced by `scripts/test.sh`; written when there
is a shell to drive (Phase 8).

The scaffold gives you the pipeline. The stages give you the OS.

---

## Placeholders to replace

Search for these before relying on any of it:

```
@member-a, @member-b              .github/CODEOWNERS
ghcr.io/cracked-f/os-toolchain:latest    -> pin to @sha256:<digest>
CRACKED-F/1                       .github/ISSUE_TEMPLATE/stage.yml (project id)
```

The image digest is the important one. Pinning to `:latest` means a toolchain
rebuild can silently change your build output, which defeats the entire purpose of
[ADR-0005](../steps/decisions/). `toolchain.yml` prints the digest to pin after
every successful build.

# Stage 0.9 — CI From Day One

**Difficulty:** Medium · ~45 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `.github/workflows/ci.yml` (adapted from the scaffold), and the
placeholders inside it — the GHCR image reference, the registry credentials, the
`CONTAINER=1` environment, and the OVMF path
**Deliverable:** every push and pull request builds, lints, and boot-tests the kernel
automatically, and a regression produces a red X on GitHub within minutes, attached
to the commit that caused it.

---

## Progress

- [ ] Read `.github/workflows/ci.yml` end to end before changing anything
- [ ] Replace `cracked-f` with your GitHub org/user in every `container:` line
- [ ] Run `toolchain.yml` **first** and wait for it to publish the image
- [ ] Make the GHCR package public, or add `credentials:` to every `container:` block
- [ ] Add `CONTAINER: 1` to the workflow environment so `make` does not try to nest Docker
- [ ] Point `OVMF_CODE` at the path that actually exists in the image
- [ ] Narrow the file lists and the matrix to what exists in Phase 0
- [ ] Push a branch, open a draft PR, watch the run go green
- [ ] Break formatting deliberately; confirm `lint` fails in about 30 seconds
- [ ] Add `#include "limine.h"` to `kernel/main.cpp`; confirm the boundary rule catches it
- [ ] Force a kernel test failure; download `serial.log` from the run's artifacts
- [ ] Turn on branch protection with all five checks required
- [ ] Pin the image by digest once `toolchain.yml` has printed one
- [ ] Committed with a message like `ci: enable the merge gate`

---

## 1. Why this stage exists

You are about to object, and the objection is reasonable: **there is almost nothing
to test yet.** The kernel prints one line over serial and halts. There are no unit
tests worth the name. Wiring up a five-job pipeline to guard three hundred lines of
code looks like ceremony.

Turn it on anyway. Three arguments, in order of how much they will cost you if you
ignore them.

**It is trivial now and painful later.** Right now `ci.yml` has to be true about a
repo with one build target, one image, and one boot path. Every job is a `make`
verb that already works on your laptop. In four phases it has to be true about a
kernel, a libc, a userspace, an initrd, three toolchain files, and a test harness —
and you will be introducing CI *while* debugging whichever of those is broken.
Nobody does that. They say "after this phase", and the phase never ends.

**From this moment, every regression is attributed to the commit that caused it.**
This is the argument that actually matters, and it is specific to kernels. In
application code a bug usually fails near its cause. Here, as
[[ADR-0010 - Testing Strategy and the QEMU Exit Device]] puts it, a heap bug in
Phase 4 surfaces as a scheduler fault in Phase 12 and the bisect window is hundreds
of commits. CI is the thing that shrinks that window to one. Every green run is a
recorded, machine-checked claim: *at this commit, the kernel built, linted, and
booted under four firmware/media combinations.* You cannot manufacture those claims
retroactively. Either the run happened at the time or the information is gone.

**A CI added after 5,000 lines starts red, and a CI that starts red gets ignored
forever.** This is the failure mode you must avoid at all costs. Add the
`-mno-red-zone` check to a tree that has forty translation units and two of them are
missing the flag, and now the merge gate is red for a reason unrelated to the change
in front of you. The rational response is to disable the check "temporarily". The
check never comes back. The same is true of `clang-format` (run it over a formatted
repo and it passes; run it over an unformatted one and it reports every file),
`-Werror`, and every boundary grep in [[07 - Repository Layout]]. Turn each rule on
at the moment it is trivially satisfiable — which is now, when the repo has one
`.cpp` file.

[[Phase 0 - Overview]] states this without hedging:

> **Stage 0.9 is not optional and it is not premature.** Turning CI on before there
> is much to test is the point: it is trivial now and painful later, and from this
> moment onward every regression is caught by the commit that caused it.

The one thing that would make this stage genuinely premature is if it were slow or
flaky. It is neither: a warm run is about six minutes, and everything in it is
deterministic. The slow and flaky things go in `nightly.yml`, which is §3's fourth
decision.

---

## 2. The concept

GitHub Actions runs a **workflow** — a YAML file under `.github/workflows/` — when
an **event** happens in the repo. A workflow contains **jobs**; each job gets a
fresh virtual machine (`runs-on: ubuntu-latest`) and runs a list of **steps**.
Steps are either shell commands (`run:`) or reusable actions (`uses:`).

Two features do the real work here.

**`container:`** tells the runner to execute every step of that job *inside a Docker
image* instead of on the bare VM. This is the hinge of the whole design. The image
is `ghcr.io/<org>/os-toolchain`, the same image `make shell` drops you into on your
laptop ([[ADR-0005 - Containerised Pinned Toolchain]]). CI therefore has no private
build recipe, no apt-get list, no "install the cross-compiler" step that drifts from
your machine's. It has the same `x86_64-elf-g++ 14.2.0`, the same binutils 2.43, the
same pinned Limine, the same QEMU.

**`needs:`** declares a dependency between jobs, which turns a flat list into a
graph. Jobs with no `needs:` all start at once; a job with `needs: build` waits.
Combined with `strategy.matrix`, which fans one job definition out into N parallel
jobs with different parameters, you get this shape:

```
        push / pull_request
                 │
     ┌───────────┼────────────┬──────────────┐
     ▼           ▼            ▼              │
   lint       build       test-unit          │   (all start together)
   ~30s        ~2m          ~20s             │
                 │                           │
        uploads "images" artifact            │
       (os.iso, os.img, kernel.elf)          │
                 │                           │
        ┌────────┴──────────┐                │
        ▼                   ▼                │
   test-kernel          test-boot ──────────┘
     ~2m                   ~3m
   Tier 2, QEMU        Tier 3, 4-way matrix
   isa-debug-exit      ┌──────────────────────┐
                       │ bios-iso   1 core    │
                       │ uefi-iso   1 core    │
                       │ uefi-img   1 core    │
                       │ uefi-smp   4 cores   │
                       └──────────────────────┘
                        fail-fast: false
```

The three test jobs map exactly onto the three tiers in
[[09 - Testing Strategy]]. Tier 1 is host-native and needs nothing but the source.
Tiers 2 and 3 need a bootable image, so they wait on `build`.

The remaining concept is **how a kernel reports a test result to a shell script.**
A normal test binary returns an exit code. A kernel has no parent process to return
to — it owns the machine. The bridge is a QEMU device: `isa-debug-exit` watches an
I/O port, and when the guest writes to it, *QEMU itself* exits with a status derived
from the value written. The kernel writes 0 for pass; QEMU exits 1; `scripts/test.sh`
sees exit 1 and prints PASS. The exact arithmetic and why it is arithmetic at all is
in §4.

Everything else in this stage is plumbing around those three ideas.

---

## 3. Design decisions and tradeoffs

### Decision: turn CI on now, or after there is something to test

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): now, at ~300 lines** | Enable all five jobs and every boundary rule while the repo trivially satisfies them | 45 minutes today; ~6 min of wall clock per push forever after | ✅ |
| B: after Phase 2 | Wait until there are interrupts and real tests to run | Every rule starts red; you introduce CI while debugging the IDT | ❌ |
| C: after v1.0 | "We'll add tests when it's stable" | Never happens; by then a bisect spans a year | ❌ |

**Why A.** The cost of turning CI on scales with the size of the tree it must be true
about. Today `clang-format --dry-run` is satisfied by one file, `jq` over
`compile_commands.json` sees a handful of translation units all built by the same
CMake rule, and the boot matrix has one thing to assert: the kernel is reached. Every
one of those gets monotonically harder.

**Why not B.** By the end of Phase 2 you have an IDT, 256 ISR stubs in NASM, exception
handlers, and a first `KASSERT` firing in anger. Introducing CI there makes the first
red X ambiguous — is the pipeline wrong, or the kernel? You spend a day untangling
that, competing directly with the actual bug. Worse, Phase 2 is where the first
*architectural* violations appear: the first temptation to put `outb` outside
`kernel/arch/`. The boundary greps must exist before the temptation does, or they
arrive as an accusation instead of a guardrail.

**When B would be right.** For a spike you expect to throw away, CI is overhead. The
tell is whether you intend to `git bisect` this repo in six months. This one has a
fifteen-phase roadmap ([[15 - Roadmap and Milestones]]); it will be bisected.

---

### Decision: run CI in the same container as local development, or give CI its own setup

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): `container:` the pinned GHCR image** | Every job runs inside `ghcr.io/<org>/os-toolchain`; jobs invoke `make` verbs | Image must be published before CI can run; ~20s pull per job | ✅ |
| B: `apt-get install` the tools in a setup step | A `run:` block installs gcc, nasm, qemu on the bare runner | Ubuntu's `gcc` is not `x86_64-elf-gcc`; versions float; drifts from local | ❌ |
| C: `setup-*` actions plus a prebuilt cross-compiler download | Marketplace actions fetch toolchains | Two build recipes, maintained separately, that must be kept in sync by hand | ❌ |

**Why A.** The decisive property is **one-command reproduction of a CI failure.** When
`test-kernel` goes red you run `make test-kernel` locally and get the same result,
because it is not a *similar* environment — it is byte-for-byte the same image, pulled
by the same reference. No class of bug exists only in CI. [[10 - CI Pipeline]] states
it as the founding principle:

> **CI runs the same commands you run locally.** It has no private build recipe.

**Why not B.** B produces the specific failure mode that destroys CI as an
institution. The environments differ — GCC minor version, QEMU version, `ld` defaults
— so eventually a test is **green in CI and red locally**, or the reverse. Now every
failure has two candidate explanations, and distinguishing them means pushing commits
and waiting six minutes per iteration. People stop reading CI output; then they merge
past it; then someone disables the required check "just for this PR".
[[ADR-0005 - Containerised Pinned Toolchain]] records exactly this: *CI green while
local is red (or the reverse) destroys trust in CI, and a CI nobody trusts is worse
than no CI* — worse, because it costs runner time and gives false assurance.

The `-mno-red-zone` rule is the sharpest illustration: two GCC versions make different
inlining and stack-layout decisions, so a red-zone corruption that never fires under
14.2 can fire reliably under 15.1. If CI runs a different compiler from yours, a green
CI is not evidence about your binary.

**When B would be right.** For a toolchain the distro actually ships correctly — a Go
project where `setup-go@v5` gives you the exact declared version — the container buys
much less. The moment you need a *cross* compiler built from source, it wins outright.

---

### Decision: pin the image by tag or by digest

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen, eventually): digest** | `container: ghcr.io/org/os-toolchain@sha256:abc…` | Updating the toolchain is an explicit PR; the SHA is unreadable | ✅ |
| B: `:latest` | `container: ghcr.io/org/os-toolchain:latest` | A toolchain rebuild silently changes what CI compiles with | ⚠️ acceptable for the first week only |
| C: `:<commit-sha>` tag | `container: …os-toolchain:9f3a1c…` | Better than `latest`; still a mutable pointer in principle | ➖ |

**Why A.** A digest is the content hash of the image manifest. It cannot be moved.
Pinning by digest makes "which compiler built this binary" a fact recorded in
`git log`, and makes a toolchain upgrade a reviewable, revertable diff — which is the
entire consequence [[ADR-0005 - Containerised Pinned Toolchain]] was written to
obtain.

**Why not B, concretely.** `toolchain.yml` pushes `:latest` on every merge that
touches `toolchain/`. Suppose your teammate bumps `GCC_VERSION` from 14.2.0 to 15.1.0
in a PR that looks like a one-line Dockerfile change and merges it at 23:00. You pull
nothing, change nothing, and push a docs-only commit the next morning. Your CI run
compiles the kernel with a compiler you have never used, on a morning you had other
plans. If it goes red you will look at your own diff first, because that is what
changed *as far as git is concerned*. The information that the compiler moved is not
in the repo at all. This is the failure that "a toolchain that updates itself breaks
your build on a morning you had other plans" is describing.

**Where to get the digest.** `toolchain.yml` prints it for you. Its last step is:

```yaml
      - name: Report the digest to pin
        if: github.event_name != 'pull_request'
        run: |
          echo "::notice::New toolchain digest: ${{ steps.build.outputs.digest }}"
          echo "::notice::Update the container: lines in ci.yml, release.yml and nightly.yml to pin it."
```

The `::notice::` shows as an annotation at the top of the run summary. You can also
ask the registry directly:

```sh
docker buildx imagetools inspect ghcr.io/<org>/os-toolchain:latest \
  | grep -i '^Digest:'
```

**The chicken-and-egg you will actually hit.** `ci.yml` as scaffolded references
`ghcr.io/cracked-f/os-toolchain:latest`, and on a brand-new repo **that image does
not exist**. The first push therefore behaves differently from every later push:
every job dies in seconds, before a single step runs, with `manifest unknown` or
`denied`. The sequence that works:

1. Push `toolchain/` and `.github/workflows/toolchain.yml` **on their own**, or run
   `toolchain.yml` from the Actions tab via its `workflow_dispatch` trigger.
2. Wait ~25 minutes. It is building GCC from source.
3. Make the resulting GHCR package public (Packages → the package → Package settings
   → Change visibility), *or* keep it private and add `credentials:` to every
   `container:` block — see §5.
4. Only now push `ci.yml`.

**When B is right.** For the first few days, while you are still changing the
Dockerfile every hour, `:latest` is the correct choice and chasing digests is
friction. Pin the digest the moment you start relying on a green CI run as evidence —
in practice, when you turn on branch protection.

---

### Decision: what gates a merge, and what runs nightly

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): fast + deterministic gates; slow + flaky runs nightly** | `ci.yml` = lint, build, 3 tiers, 4-way matrix, ~6 min. `nightly.yml` = 48-cell matrix, stress, 30-min soak, repro, sanitisers | A regression only nightly catches is found up to 24h late | ✅ |
| B: everything gates the merge | One workflow; the full matrix and the soak run on every push | ~40 min per push, and any flake blocks the merge | ❌ |
| C: nothing gates the merge; all reporting is nightly | CI is advisory | `master` breaks and nobody notices until tomorrow | ❌ |

**Why A.** The governing principle, stated in `nightly.yml`'s own header comment:

> A flaky merge gate is worse than no gate — it trains people to hit re-run without
> reading.

That is a claim about human behaviour, not software. The first time a job fails for a
reason unrelated to your diff, you read the log. The third time, you hit re-run. By
the tenth, re-run is a reflex — and the eleventh failure, which was real, gets re-run
too. A gate that is 98% reliable is not 98% as good as a perfect gate; it is worth
close to nothing, because it has taught everyone to route around it.

So the gate contains only things that fail *iff* something is wrong: compilation,
formatting, greps over the tree, a boot that either reaches its marker or does not.
Anything with a timing dependency, a randomness source, or a 30-minute runtime goes to
`nightly.yml`, which opens (and updates, rather than spams) an issue on failure.

**Why not B.** The runner minutes matter less than the feedback loop: a 40-minute gate
means you context-switch away and come back, so broken `master` states live longer,
not shorter. And the soak test *will* flake — it asserts no tick drift over 30 minutes
on emulated hardware shared with other GitHub tenants.

**When B would be right.** If merges were rare — a release branch taking one merge a
week — running everything is cheap and the flakiness cost is bounded. It is also right
for `release.yml`, which does run the fuller matrix, because a release is worth 40
minutes and there is no re-run reflex to protect.

**The split, concretely:**

| Check | Where | Why there |
|---|---|---|
| clang-format, boundary greps | `ci.yml` | 30s, purely textual, cannot flake |
| build kernel + iso + img | `ci.yml` | Deterministic; the most common breakage |
| Tier 1 unit tests | `ci.yml` | Host-native, milliseconds |
| Tier 2 kernel self-tests | `ci.yml` | Deterministic under QEMU; hard timeout makes a hang a failure |
| Tier 3, 4 configurations | `ci.yml` | The four you actually ship |
| Tier 3, 48 configurations | `nightly.yml` | Same code paths, 10× the runtime |
| Heap/scheduler/fs stress | `nightly.yml` | Minutes each, and randomised |
| 30-minute soak | `nightly.yml` | Obviously |
| `make verify-repro` | `nightly.yml` | Builds twice; too slow to gate |
| ASan/UBSan Tier 1 | `nightly.yml` | Slower build, and sanitiser output needs reading |

---

### Decision: job ordering — cheap checks first

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): lint ∥ build ∥ test-unit, then tests `needs: build`** | Cheap jobs start immediately; expensive matrix waits for an artifact that must exist | A broken build still costs the lint job's 30s of runner time | ✅ |
| B: strict chain — `build needs: lint`, etc. | Nothing starts until lint passes | +30s wall clock on every green run, which is every run you actually wait for | ➖ |
| C: no `needs:` anywhere | Everything fans out at once | `test-boot` downloads an artifact that does not exist and fails confusingly | ❌ |

**Why A.** Two different things are being optimised; separate them.

`needs: build` is not about speed. `test-boot` *cannot* run without `build` — its
second step is `actions/download-artifact@v4` for the `images` artifact `build`
uploads. `test-kernel`'s `needs: build` is a **policy** choice: it rebuilds the ISO
itself (`make test-kernel` depends on the `iso` target), so mechanically the
dependency buys nothing. What it buys is not spending two minutes booting a kernel
when you already know compilation is broken.

Wall-clock ordering comes from somewhere else entirely: `concurrency` with
`cancel-in-progress`. Only one run per group may be in flight, and a new one cancels
the old. Because the key is `github.ref` the queue is per-branch — on a
`pull_request` event `github.ref` is `refs/pull/N/merge`, effectively per-PR; on a
push to master, `refs/heads/master`. Push three commits in ninety seconds and you get
one run, for the tip, instead of three competing for runners while two are obsolete.

**Why not B.** Chaining `build` behind `lint` adds lint's full duration to every
*green* run — and green runs are the ones you sit and wait for. It saves build's two
minutes only when lint fails, which should be rare and which you learn about in 30
seconds regardless, because lint reports independently. On a public repo the runner
minutes are free; the wall clock is not.

**When B would be right.** On a self-hosted runner, or a private repo eating a minutes
quota, serialising to avoid wasted compute is the correct trade. Also right when lint
is very fast and build is very slow, where the ratio flips.

**The cost of A.** `cancel-in-progress` means intermediate commits on a branch never
get their own verdict, so `git bisect` over a branch's CI status is meaningless. Fine
here, because the workflow squash-merges one stage per branch
([[12 - Team Workflow]]): the unit that must be green is the squashed commit on
`master`, and that one always gets a full run.

---

### Decision: enforce architecture rules by grep in CI, or by code review

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen): greps in `lint`, one step per rule** | Six `run:` steps, each failing with a `::error::` annotation | Crude; textual; will false-positive on comments and strings | ✅ |
| B: code review only | The reviewer checks the four rules in [[07 - Repository Layout]] | Humans forget, and someone must be the one who says it | ❌ |
| C: a real static analyser / custom clang-tidy checks | AST-aware, no false positives on comments | Days of work; a `clang-tidy` plugin to enforce a directory convention is not a weekend project | ❌ |

**Why A.** Be honest about what a grep is: a substring match with no idea what a
comment is, and it will occasionally be wrong. It has exactly two virtues, and they
are enough.

It is **tireless.** It checks all six rules on all files on every push, including the
one you made at 01:00 to fix one thing, forever. A reviewer checks the rules they
remember, on the files in the diff, when they are not tired.

It is **impersonal**, and this is the underrated one. On a two-person team nobody
wants to be the person who writes "you put `limine.h` in the wrong directory again"
for the third time. So they stop writing it, and the boundary erodes — not because
anyone decided to abandon it, but because enforcing it socially is unpleasant. A grep
has no feelings, requires no diplomacy, and is never accused of nitpicking. The rule
stops being a relationship between two people and becomes a property of the repo.

The false-positive cost is real and paid in a specific currency: occasionally a
legitimate line trips a rule and you restructure or reword it. Fair price. Each rule
in §5 documents what its false positives look like.

**Why not B.** [[07 - Repository Layout]] opens its boundary section with *"These are
enforced by CI, not by good intentions."* The rules are load-bearing: arch-code
confinement is the only thing keeping a second architecture from being a rewrite and
is what makes `kernel/mm/` host-testable at Tier 1; Limine confinement is what makes
the bootloader replaceable at all. A rule enforced only when someone notices decays
exactly as fast as the codebase grows.

**When C would be right.** If the rules were about code *semantics* rather than file
*locations* — "no allocation in interrupt context", "no blocking call while holding a
spinlock" — grep cannot express that and a real analyser earns its cost. Directory
conventions are genuinely a grep-shaped problem.

**The rules and what each protects:**

| # | Rule | Protects | ADR |
|---|---|---|---|
| 1 | every kernel TU carries `-mno-red-zone` | Interrupts clobbering the 128-byte red zone | [[ADR-0002 - Target x86_64 Not i686]] |
| 2 | `limine.h` only under `kernel/arch/x86_64/boot/` | The bootloader escape hatch | [[ADR-0003 - Limine as the Bootloader]] |
| 3 | no inline asm outside `kernel/arch/` | Second arch stays additive; `kernel/mm/` stays host-testable | [[ADR-0008 - Monorepo Layout]] |
| 4 | `kernel/` never includes `libc/` or `user/` | Privilege/allocator/memory-rule separation | [[ADR-0008 - Monorepo Layout]] |
| 5 | no `__DATE__` / `__TIME__` | Reproducible builds | [[ADR-0005 - Containerised Pinned Toolchain]] |
| 6 | no `TODO` without an issue number | Silent debt | [[12 - Team Workflow]] |

---

## 4. Specification

### Workflow triggers

| Workflow | Event | Notes |
|---|---|---|
| `ci.yml` | `push` to `master`, any `pull_request`, `workflow_dispatch` | As scaffolded, a push to a **feature branch with no open PR runs nothing** |
| `toolchain.yml` | push to `master` touching `toolchain/**`, PR touching `toolchain/**`, `workflow_dispatch` | PRs build but do not push |
| `nightly.yml` | `schedule: '0 3 * * *'`, `workflow_dispatch` | 03:00 UTC |
| `release.yml` | push of a tag matching `v*`, `workflow_dispatch` | Publishes a **draft** release |

### `ci.yml` job graph

| Job | `needs:` | Container | Wall clock | Uploads |
|---|---|---|---|---|
| `lint` | — | toolchain | ~30s | — |
| `build` | — | toolchain | ~2m | `images` (14-day retention) |
| `test-unit` | — | toolchain | ~20s | — |
| `test-kernel` | `build` | toolchain | ~2m | `test-kernel-logs` on failure |
| `test-boot` | `build` | toolchain | ~3m × 4 in parallel | `boot-logs-<name>` on failure |

Cold cache ~12 min; warm ~6 min.

### The boot matrix

| `name` | `firmware` | `media` | `smp` | QEMU consequence |
|---|---|---|---|---|
| `bios-iso` | `bios` | `iso` | 1 | SeaBIOS, `-cdrom build/os.iso`, no `-bios` flag |
| `uefi-iso` | `uefi` | `iso` | 1 | `-bios $OVMF_CODE -cdrom build/os.iso` |
| `uefi-img` | `uefi` | `img` | 1 | `-bios $OVMF_CODE -drive format=raw,file=build/os.img` |
| `uefi-smp` | `uefi` | `img` | 4 | as above plus `-smp 4` |

`fail-fast: false` — all four run to completion even after one fails.

### QEMU invocation assembled by `scripts/test.sh`

| Flag | Value | Why |
|---|---|---|
| `-m` | `$MEM` (default `512M`) | |
| `-smp` | `$SMP` (default `1`) | |
| `-display none` | — | No graphical backend exists in a container |
| `-no-reboot -no-shutdown` | — | A triple fault must halt, not reboot into a loop |
| `-serial` | `file:build/serial.log` | The kernel's own account, captured |
| `-d` | `guest_errors` | Log guest faults QEMU notices |
| `-D` | `build/qemu-stderr.log` | Where `-d` output goes |
| `-device` | `isa-debug-exit,iobase=0xf4,iosize=0x04` | Tier 2 only |

### The `isa-debug-exit` contract

| Item | Value |
|---|---|
| Device | `isa-debug-exit` |
| I/O port base | `0xf4` |
| Port window size | `0x04` bytes |
| Guest writes | `N` (via `outl`) |
| QEMU process exit status | `(N << 1) \| 1` |

| Guest writes | QEMU exits | `scripts/test.sh` reports |
|---|---|---|
| `0` | `1` | **PASS**, and prints `serial.log` |
| `1` | `3` | **FAIL**, prints last 60 lines of `serial.log` + QEMU stderr |
| (nothing; kernel hung) | `124` from `timeout(1)` | **TIMEOUT after Ns — the kernel hung** |
| (nothing; QEMU exited on its own) | `0` | **QEMU exited 0 without writing to the exit device** |
| — | anything else | **crash or bad invocation** |

The doubling is the point. QEMU computes the status as `(N << 1) | 1`, so the low bit
is always set and **the guest can never cause an exit status of 0**. That reserves 0
to mean one specific, otherwise-indistinguishable thing: *the test kernel never
reached `test_exit()`*. Without the transform, a kernel that wrote 0 and a kernel
that never ran the tests would both look like exit 0, and a test suite that silently
executed nothing would report PASS forever. `scripts/test.sh` has an explicit arm for
it:

```sh
      0)   red   "QEMU exited 0 without writing to the exit device."
           red   "The test kernel probably never reached test_exit()."
```

The kernel side, from [[ADR-0010 - Testing Strategy and the QEMU Exit Device]]:

```cpp
[[noreturn]] void test_exit(bool ok) {
    outl(0xf4, ok ? 0 : 1);      // -> QEMU exit 1 (pass) or 3 (fail)
    __builtin_unreachable();
}
```

This is the mechanism `kvm-unit-tests` uses. It is not a hack invented here.

### Required status checks on `master`

`lint`, `build`, `test-unit`, `test-kernel`, `test-boot` — all five
([[12 - Team Workflow]]). Note that with a matrix, GitHub reports each leg
separately (`test-boot (bios-iso)` and so on), so select all four legs when
configuring branch protection, or the gate has a hole.

---

## 5. Writing the code

This stage's "code" is YAML and shell. There is one file, and it already exists at
`scaffold/.github/workflows/ci.yml` — open it now and keep it beside this section,
because the walk below quotes every block of it in full.

### `.github/workflows/ci.yml`

The merge gate: five jobs, all inside the pinned toolchain container, all invoking
verbs that also work on your laptop. The shape, before the detail:

```
name: CI

on:            push to master, any PR, manual button
concurrency:   one run per branch; supersede the old one

jobs:
  lint          container: toolchain. checkout → clang-format → compile db
                  → 6 boundary rules, one step each → clang-tidy
  build         container: toolchain. checkout → restore ccache
                  → make iso img → upload "images" artifact (14 days)
  test-unit     container: toolchain. checkout → make test-unit
  test-kernel   needs: build. make test-kernel → upload serial.log if: failure()
  test-boot     needs: build. 4-way matrix, fail-fast: false
                  download "images" → scripts/test.sh boot → logs if: failure()
```

#### Line by line

**`on:` — the triggers**

```yaml
on:
  push:
    branches: [master]
  pull_request:
  workflow_dispatch:
```

Three events, and the first is narrower than it looks. `push: branches: [master]`
fires only for pushes to `master` — pushing `feat/phase1-console` with no PR open runs
**nothing**. That is deliberate (it avoids running twice per commit, once for `push`
and once for `pull_request`), but it means "every push runs CI" is true only once you
open a PR. With the vault's one-stage-per-branch workflow that is the right shape:
open a **draft PR** first thing on a branch. If you want unconditional coverage, widen
to `branches: ['**']` and accept the duplicates.

`pull_request:` with no filter fires for PRs against any base. It checks out the
**merge commit** — your branch merged into the base — not your branch tip, so CI can
go red because of something on `master` you have not rebased onto. That is what
"require branches to be up to date" formalises.

`workflow_dispatch:` puts a **Run workflow** button on the Actions tab. You need it
this stage: after `toolchain.yml` publishes the image you want to re-run `ci.yml`
without inventing a commit.

**`concurrency` — one run per branch**

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

`group` names a queue; runs in the same group serialise. `cancel-in-progress: true`
turns "serialise" into "supersede" — a new run cancels the running one. The `ci-`
prefix keeps this queue distinct from other workflows keyed on `github.ref`. You gain:
a fix-up commit thirty seconds later kills the obsolete run immediately. You give up:
per-commit CI history on a branch. See §3.

**`container:` — the whole design in one line**

```yaml
    runs-on: ubuntu-latest
    container: ghcr.io/cracked-f/os-toolchain:latest
```

`runs-on` picks the VM; `container` says every step of the job runs *inside that
image*. `x86_64-elf-g++`, `nasm`, `xorriso`, `mtools`, `qemu-system-x86_64`, `jq`,
`clang-format`, `python3-pexpect` and the pinned Limine tree at `$LIMINE_DIR` are all
there because `toolchain/Dockerfile` put them there — the identical image `make shell`
gives you.

**Four things to change on this line.**

1. **The org.** `cracked-f` is a placeholder. Replace it in all five jobs, plus
   `nightly.yml`, `release.yml`, and `TOOLCHAIN` at the top of the `Makefile`.

2. **The digest, eventually** — in all five copies. The comment above `jobs:` explains
   why there are five rather than one variable:

   ```
   # The `env` context is NOT available in `jobs.<id>.container.image`
   ```

   That is a real Actions limitation, not laziness: `${{ env.FOO }}` does not resolve
   in a `container.image` field. Reusable workflows can deduplicate it; five copies of
   one line is not worth the indirection.

3. **Credentials, if the package is private.** GHCR packages pushed by `GITHUB_TOKEN`
   default to private, and a private image needs authentication even from its own
   repository:

   ```yaml
       container:
         image: ghcr.io/<org>/os-toolchain:latest
         credentials:
           username: ${{ github.actor }}
           password: ${{ secrets.GITHUB_TOKEN }}
   ```

   plus `permissions: packages: read` on the job. Simpler alternative: make the
   package public once in its package settings.

4. **`CONTAINER: 1`.** The root `Makefile` reads `ifeq ($(CONTAINER),1)` to decide
   whether to wrap commands in `docker run`. Inside the CI container you *are* the
   execution context, so it must be `1` — otherwise every `make` step tries to launch
   Docker inside a container that has no Docker. Neither the scaffolded `Dockerfile`
   nor `ci.yml` sets it. Fix it once, at workflow level:

   ```yaml
   env:
     CONTAINER: 1
     OVMF_CODE: /usr/share/OVMF/OVMF_CODE_4M.fd
   ```

   (Workflow-level `env:` *is* visible to steps; only `container.image` cannot see
   it.) `ENV CONTAINER=1` in `toolchain/Dockerfile` also works and is arguably better,
   since it fixes `nightly.yml` and `release.yml` too.

`OVMF_CODE` is there for a related reason: `scripts/test.sh` defaults to
`/usr/share/OVMF/OVMF_CODE.fd`, and Ubuntu 24.04 — the image's base — ships
`OVMF_CODE_4M.fd`. The Dockerfile's own verification step warns about exactly this
(`WARN: OVMF path differs on this base image`). Without the override, three of the
four boot legs die instantly with `OVMF firmware not found`. Confirm with `make shell`
then `ls /usr/share/OVMF/`.

---

#### The `lint` job

**Step 1 — clang-format**

```yaml
      - name: clang-format
        run: |
          find kernel libc user tools tests \
               \( -name '*.cpp' -o -name '*.hpp' -o -name '*.c' -o -name '*.h' \) -print0 \
            | xargs -0 clang-format --dry-run --Werror
```

`--dry-run` makes clang-format report what it *would* change instead of changing it;
`--Werror` turns those reports into a non-zero exit. Together they are "check
formatting" — there is no `--check` flag. `-print0`/`-0` pair up so paths containing
spaces survive the pipe.

The fix on the developer's side is always the same: `make fmt`, which runs
`scripts/fmt.sh` — the same `find`, with `clang-format -i`.

**Adapt for Phase 0:** `libc`, `user`, and `tools` do not exist yet. `find` prints an
error and returns non-zero for each missing directory. Trim the list to what exists
(`kernel tests`) and add them back as they appear, or copy `scripts/lint.sh`'s
defensive form, which is `... -print0 2>/dev/null | xargs -0 -r ...`. The `-r` matters
independently: without it, `xargs` runs `clang-format` with zero file arguments on an
empty tree, which makes it read stdin instead of failing usefully.

**Step 2 — the compile database**

```yaml
      - name: Generate compile database
        run: make compile-commands
```

`make compile-commands` runs `cmake ... -DCMAKE_EXPORT_COMPILE_COMMANDS=ON` and then
asserts `build/compile_commands.json` exists. That file is a JSON array with one
object per translation unit, each recording the directory, the source file, and the
exact command line. It exists for clangd and clang-tidy
([[08 - Build System]]), and the next rule mines it.

**Step 3 — boundary rule 1: `-mno-red-zone` on every kernel TU**

```yaml
      - name: 'Boundary: every kernel TU has -mno-red-zone'
        run: |
          bad=$(jq -r '.[]
                       | select(.file | test("/kernel/"))
                       | select((.command // (.arguments | join(" "))) | contains("-mno-red-zone") | not)
                       | .file' build/compile_commands.json)
          if [ -n "$bad" ]; then
            echo "::error::Kernel translation units missing -mno-red-zone:"
            echo "$bad"
            exit 1
          fi
```

The `jq` program, filter by filter:

- `.[]` — the file is a JSON **array**; this streams each element as a separate value
  through the rest of the pipeline.
- `select(.file | test("/kernel/"))` — `test` is jq's regex match. Keep only entries
  whose source path contains `/kernel/`. CMake writes absolute paths, so a kernel
  source appears as `/os/kernel/mm/pmm.cpp` and matches. This is the filter that
  excludes host-tool and Tier-1 targets, which **must not** carry `-mno-red-zone`.
- `(.command // (.arguments | join(" ")))` — a compile database entry has *either* a
  `command` string or an `arguments` array, depending on the generator. `//` is jq's
  alternative operator: take `.command` unless it is null or false, in which case
  join the `arguments` array into a string. Writing it this way makes the rule
  survive a switch from Ninja to another generator.
- `contains("-mno-red-zone") | not` — keep the entries where the flag is **absent**.
  These are the offenders.
- `.file` — emit the path. `-r` strips JSON quoting so the output is plain paths.

`bad` is empty on success, so `[ -n "$bad" ]` is the failure test. `::error::` is a
GitHub *workflow command*: the runner parses it out of stdout and renders a red
annotation at the top of the run summary and on the PR, so the reason is visible
without opening the log. Every rule below uses the same shape.

*Why mechanise this one.* The AMD64 ABI lets a leaf function use the 128 bytes below
`rsp` without adjusting `rsp` — the red zone. In user space nothing else touches that
memory. **In kernel space an interrupt pushes its frame right there**, silently
destroying live data. The result is random, unreproducible corruption found weeks
later in code that is not at fault: no compiler warning, no crash at the point of the
mistake, no way to spot it by reading a diff. One missing flag in one `cmake/` file
produces it. A 200 ms grep is a very good trade against a week of that.

*False positive.* If your checkout path itself contains a `kernel` directory — cloning
into `~/kernel/os/` — `test("/kernel/")` matches every entry including host tools, and
the rule fails on files that must not have the flag. Anchor harder if that bites:
`test("/os/kernel/")`.

*False negative.* A TU compiled through a response file (`@flags.rsp`) does not carry
the flag in `command`, so `contains` will not see it. Not a concern with the current
CMake setup, but it is why this rule proves *presence on the command line*, not
*presence in the compilation*.

**Step 4 — boundary rule 2: `limine.h` confinement**

```yaml
      - name: 'Boundary: limine.h confined to arch/x86_64/boot'
        run: |
          leak=$(grep -rl 'limine\.h' kernel/ --include='*.?pp' --include='*.h' 2>/dev/null \
                 | grep -v '^kernel/arch/x86_64/boot/' || true)
          if [ -n "$leak" ]; then
            echo "::error::limine.h included outside arch/x86_64/boot/:"
            echo "$leak"
            exit 1
          fi
```

`grep -r` recurses; `-l` prints file names only, deduplicated. `limine\.h` escapes the
dot to make it literal. `--include='*.?pp'` matches `.cpp` and `.hpp` (`?` is a
single-character glob); the second `--include` adds `.h`.

The second `grep -v` drops the one directory where the include is legal. **The `^`
anchor is load-bearing and fragile**: `grep -r … kernel/` prints paths beginning
`kernel/`, so `^kernel/arch/x86_64/boot/` matches. Write `grep -r … ./kernel/` and
every path gains a `./`, the anchor never matches, and every legal file is reported as
a leak. If this rule fires on `boot/entry.cpp` itself, that is what happened.

`|| true` is not cosmetic. **`grep` exits 1 when it finds nothing** — the success case
here. GitHub runs `run:` blocks under `bash -e`, and a command substitution in an
assignment propagates its exit status, so without `|| true` the step aborts on the
*good* outcome. Every rule in this job carries it for that reason.

*What it protects.* [[ADR-0003 - Limine as the Bootloader]] accepts a dependency on one
bootloader on the explicit condition that it stays behind a wall: Limine's responses
are copied into our own `BootInfo` inside `kernel/arch/x86_64/boot/`
([[Stage 0.3 - Freestanding C++ and kmain]]) and nothing else ever sees a Limine type.
The moment `kernel/mm/pmm.cpp` includes the header to peek at the memory map, the
escape hatch is gone and switching bootloaders becomes a whole-tree refactor.

*False positive.* A comment or documentation string naming the header in a file outside
`boot/` — including a header comment explaining this very rule — trips it. grep does
not parse C++. Reword the prose or move the note.

**Step 5 — boundary rule 3: no inline asm outside `arch/`**

```yaml
      - name: 'Boundary: no inline asm outside arch/'
        run: |
          leak=$(grep -rnE '\b(asm|__asm__)[[:space:]]*(volatile)?[[:space:]]*\(' kernel/ \
                   --include='*.cpp' --include='*.hpp' 2>/dev/null \
                 | grep -v '^kernel/arch/' || true)
```

`-E` selects extended regular expressions; `-n` adds line numbers so the annotation
points at the offending line. `\b` is a GNU word boundary, so `wasm(` and `basm(` do
not match. `(volatile)?` makes the qualifier optional, and `[[:space:]]*` allows any
spacing before it and before the parenthesis.

*What it protects.* [[ADR-0008 - Monorepo Layout]] and rule 1 of
[[07 - Repository Layout]]: architecture-specific code confined to `kernel/arch/`. Two
things depend on it. A second architecture stays **additive** — you add
`kernel/arch/aarch64/` rather than rewriting the tree. And `kernel/mm/` stays
**host-testable at Tier 1**, the single largest reason the allocator's arithmetic can
be unit-tested at all ([[09 - Testing Strategy]]).

*False positives:* `// asm("hlt") is not allowed here` in a comment, or a string
literal containing `asm(`. Comments are the realistic case.

*False negatives:* `__asm__ __volatile__ (` does not match, because `__volatile__` is
not `volatile`; nor does `asm goto (`. Both are legal GCC. The rule is a net, not a
proof — widen the pattern rather than trusting it, and widen `scripts/lint.sh` too,
which carries the same one.

**Step 6 — boundary rule 4: kernel does not include userspace**

```yaml
      - name: 'Boundary: kernel does not include userspace'
        run: |
          leak=$(grep -rnE '#include[[:space:]]*[<"](libc|user)/' kernel/ 2>/dev/null || true)
```

`[<"]` is a character class matching either include form. `(libc|user)/` requires the
trailing slash, so `libcxx/` does not match — the slash is doing real work.

*What it protects.* Rule 3 of [[07 - Repository Layout]]: different privilege domain,
different memory rules, different allocator. A kernel that accidentally links a
userspace `malloc` is, in that document's phrasing, a very confusing afternoon. The
correct channel for anything crossing the boundary is `kernel/include/abi/`, which
`libc/` includes *from* — never the reverse. Note this grep has no `--include` filter,
so it scans every file under `kernel/` including `.md`, `.ld` and `.asm` — slightly
stricter than intended, and harmless.

**Step 7 — reproducibility: no `__DATE__` / `__TIME__`**

```yaml
      - name: 'Repro: no __DATE__ / __TIME__'
        run: |
          leak=$(grep -rn '__DATE__\|__TIME__' kernel/ libc/ user/ 2>/dev/null || true)
```

Basic regular expressions here, so alternation is `\|` rather than `|`.

*What it protects.* Two builds of the same commit must produce identical bytes — what
makes "works on my machine" falsifiable, and what `make verify-repro` checks nightly.
These macros expand to the wall-clock moment of compilation, so one use makes every
build unique and every reproducibility check fail forever. The boot banner is the
classic offender; use `SOURCE_DATE_EPOCH` (set from the commit timestamp by
`release.yml`) or the git SHA instead.

*False positive:* a comment saying "never use the date macro" — spelled out literally,
it fires. *False negative:* `__TIMESTAMP__` is not in the pattern and is just as
poisonous. Add it when you remember.

**Step 8 — debt: no bare `TODO`**

```yaml
      - name: 'Debt: no TODO without an issue number'
        run: |
          leak=$(grep -rnP 'TODO(?!\(#\d+\))' kernel/ libc/ user/ 2>/dev/null || true)
```

`-P` selects PCRE, which is required because `(?!...)` is a **negative lookahead** —
not available in POSIX BRE or ERE. The pattern reads: the literal `TODO` *not*
immediately followed by `(#` digits `)`. So `TODO(#42): reclaim bootloader memory`
passes and `TODO: fix this` fails.

*What it protects.* A `TODO` with no issue is a note to nobody; `TODO(#42)` is a
tracked item with an owner, a discussion, and a place in the backlog. The rule converts
an intention into a commitment at the moment that is cheapest.

*False positives:* `TODOS`, a `TODO` in prose, and — annoyingly — `TODO (#42)` with a
space, which the pattern rejects. `FIXME`, `XXX` and `HACK` are not covered; add them
if the team uses them.

*Portability:* `-P` needs a grep built with PCRE. Ubuntu's GNU grep has it; BusyBox
grep (Alpine) does not and fails with `support for -P is not compiled`. Another reason
the container is pinned.

**Step 9 — clang-tidy**

```yaml
      - name: clang-tidy
        run: make lint-tidy
```

This runs `run-clang-tidy -p build -quiet 'kernel/|libc/|user/'` over the compile
database. Two practical warnings first.

Check that `run-clang-tidy` is on `PATH` in the image — on Ubuntu it is sometimes
installed only under a versioned name (`run-clang-tidy-18`). `make shell` then `which
run-clang-tidy` settles it; if absent, symlink it in the Dockerfile or call the
versioned binary.

And clang-tidy analyses with **clang**, while the compile database records
**`x86_64-elf-g++`** invocations. Clang does not automatically know the cross
compiler's system include paths or accept all its flags, so a first run can produce a
wall of `'cstdint' file not found`. Expect to add `--extra-arg` entries or a
`.clang-tidy` config. **It is entirely legitimate to leave `lint-tidy` off the gate
until it is clean** — comment the step out with a `TODO(#N)` and enable it later. What
you must not do is leave it in, red, and learn to ignore red.

**A drift to fix while you are here.** `scripts/lint.sh` implements **eight** rules;
`ci.yml` inlines **six**. The one only in the script is `no volatile on non-pointer
shared state`, protecting rule 3 of [[13 - Coding Standards]] — `volatile` provides
neither atomicity nor ordering, and using it as a concurrency primitive is a bug that
appears under SMP in Phase 12 and nowhere before. Two copies of a rule set drift; that
is what just happened. Two fixes, and they trade off:

| Option | Gain | Loss |
|---|---|---|
| Replace the six inline steps with one `run: make lint` | Exactly one source of truth; local and CI cannot diverge | One step, one red X — you lose the per-rule `::error::` annotation and have to read the log |
| Keep inline steps, and add the missing rule | Per-rule annotations in the PR UI | Must remember to update two files |

Pick one deliberately. The vault's stated principle — CI has no private recipe —
argues for `make lint`. If you keep the inline form, add a line to `scripts/lint.sh`'s
header saying `ci.yml` mirrors it.

---

#### The `build` job

```yaml
      - name: Restore ccache
        uses: actions/cache@v4
        with:
          path: /ccache
          key: ccache-${{ runner.os }}-${{ hashFiles('**/*.cpp', '**/*.hpp', '**/*.asm') }}
          restore-keys: ccache-${{ runner.os }}-
```

`path: /ccache` matches `CCACHE_DIR=/ccache` from `toolchain/Dockerfile` — the same
path the local `Makefile` mounts as the `os-ccache` Docker volume. The action restores
at step time and saves at job end.

`hashFiles(...)` hashes the listed files' contents, so the key changes whenever any
source changes and a fresh push is always a *miss* on the exact key. That is
intentional: `actions/cache` writes a new entry only when the primary key missed, so
the cache refreshes on every source change. `restore-keys` supplies the fallback — the
most recent entry whose key starts with `ccache-Linux-`, i.e. last commit's cache — so
you compile only what changed.

Two limits: a repository's total Actions cache is capped (10 GB at the time of
writing) with LRU eviction, and entries untouched for 7 days are removed. A branch idle
for a fortnight gets a cold build — the difference between the ~6 min warm and ~12 min
cold figures in [[10 - CI Pipeline]].

```yaml
      - run: make iso img
```

Same verbs from [[08 - Build System]] you type locally. `iso` produces the hybrid
BIOS+UEFI ISO via `xorriso`; `img` the GPT disk image with a FAT32 ESP via `parted` +
`mtools`. Both depend on `all`, so kernel, libc, user programs and initrd are built
first.

```yaml
      - uses: actions/upload-artifact@v4
        with:
          name: images
          path: |
            build/os.iso
            build/os.img
            build/kernel.elf
            build/kernel.sym
          retention-days: 14
```

`name: images` is what `test-boot` downloads. The four paths are what anything
downstream needs: two bootable images, the ELF **with symbols** for `addr2line` and
GDB, and the stripped symbol table.

`retention-days: 14` is a judgement — long enough to fetch the exact binary behind a
regression you noticed a week later (you cannot symbolise a panic backtrace against a
rebuild that inlined differently, which is why [[14 - Debugging Playbook]] cares),
short enough not to eat the storage quota. The default is 90; 14 is deliberate.

Note there is no `if: failure()` here: images upload on **success**, because their
purpose is to be downloaded and booted by a human. That is separate from the
failure-only log uploads below.

---

#### `test-unit` — Tier 1

```yaml
  test-unit:
    runs-on: ubuntu-latest
    container: ghcr.io/cracked-f/os-toolchain:latest
    steps:
      - uses: actions/checkout@v4
      - run: make test-unit
```

No `needs:`, because Tier 1 compiles for the **host** and does not need the ISO. It
starts at t=0 alongside `lint` and `build` and usually reports first. `scripts/test.sh
unit` configures a separate `build-host` directory with `-DBUILD_HOST_TESTS=ON`, builds
it natively, and runs `ctest --output-on-failure`.

In Phase 0 this suite is nearly empty. Leave the job in anyway: it costs 20 seconds,
and it means the day you write your first `TEST_CASE` it runs — rather than being
written and not wired up for three phases.

---

#### `test-kernel` — Tier 2, and the serial log

```yaml
  test-kernel:
    needs: build
    steps:
      - uses: actions/checkout@v4
      - run: make test-kernel
      - name: Upload serial log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-kernel-logs
          path: |
            build/serial.log
            build/qemu-stderr.log
            build/kernel.elf
```

`needs: build` here is policy, not mechanism. This job does not download the `images`
artifact; `make test-kernel` depends on the `iso` target, so it rebuilds. The
dependency exists so that a broken compile does not also spend two minutes booting
QEMU to discover the same thing.

**That rebuild is worth optimising.** The job has no `ccache` restore step, so it
pays a full cold build every run. Two ways out, in increasing order of correctness:
add the same `actions/cache@v4` block as `build`; or download the `images` artifact
and call `./scripts/test.sh kernel` directly, skipping the build entirely. The second
is better — it tests the artifact you actually built rather than a second build of
the same source.

**`if: failure()`.** Every step has an implicit `if: success()`, meaning it is skipped
once anything in the job has failed. `if: failure()` inverts that: run **only**
because something failed. Without it, the upload would be skipped in exactly the case
you need it.

**Why `serial.log` is the single most valuable failure artifact.** When Tier 2 fails
you have a process exit code and nothing else. Exit 3 tells you *a* test failed; it
does not tell you which, or what the expected and actual values were. The serial log
is the kernel's own account of what happened, written line by line as it happened:

```
[TEST] mm/paging: map_page makes address readable ......... PASS
[TEST] mm/paging: unmapped access faults with correct CR2 . PASS
[TEST] mm/heap:  torture 100000 random alloc/free ......... PASS
[TEST] sched:    context switch preserves callee-saved .... FAIL
       expected rbx=0xDEADBEEF got 0x00000000
       at kernel/sched/task.cpp:214
```

Four properties make it uniquely good, and they are exactly why
[[Phase 0 - Overview]] puts serial before everything else:

- It **survives the crash** — written to a host file as each byte leaves the guest, so
  the last line before a triple fault is on disk even though the guest is gone.
- It works **before** any display code exists, and is the only channel at all during
  early boot.
- It carries the *reason*, not just the fact: a hang leaves a log whose last line names
  the subsystem that was initialising when it stopped.
- On a timeout — QEMU killed at 90 s, exit 124 — it is the **only** evidence there is.

[[10 - CI Pipeline]]'s triage table puts it first for that reason: *the kernel's own
account of what happened — **read this first***. `qemu-stderr.log` (from `-d
guest_errors -D …`) is second, carrying QEMU's complaints about bad instructions and
unassigned memory accesses. `kernel.elf` is third, uploaded because you cannot
symbolise the backtrace without the exact binary — a local rebuild is not guaranteed
to place symbols identically. `scripts/test.sh` also prints the last 60 lines inline
via `report_failure()`, so the common case needs no download at all.

---

#### `test-boot` — Tier 3 and the matrix

```yaml
    strategy:
      fail-fast: false
      matrix:
        include:
          - { name: bios-iso,  firmware: bios, media: iso, smp: 1 }
          - { name: uefi-iso,  firmware: uefi, media: iso, smp: 1 }
          - { name: uefi-img,  firmware: uefi, media: img, smp: 1 }
          - { name: uefi-smp,  firmware: uefi, media: img, smp: 4 }
```

`strategy.matrix` fans one job definition into four parallel jobs. Explicit `include:`
rows rather than a cross product of `firmware × media × smp` give exactly the four
shipped combinations — no `bios` + `img` cell, which this project does not support.
`name` exists so the job label and artifact name are readable.

**`fail-fast: false` is the important line.** The default (`true`) cancels every
remaining leg the moment one fails, destroying the information you actually want —
which is not *whether* it failed but *the shape of the failure*:

| Pattern | Diagnosis |
|---|---|
| all four red | something universal — the kernel, the linker script, the build |
| `bios-iso` green, all three UEFI red | the ESP, `BOOTX64.EFI`, or an assumption about firmware state |
| `uefi-iso` green, `uefi-img` red | the GPT/ESP image layout, not the kernel |
| only `uefi-smp` red | an SMP assumption — breaks only with more than one core |

That table comes free from four parallel jobs, and not at all from one failure plus
three cancellations.

**Why UEFI deserves its own legs.** [[09 - Testing Strategy]] states it plainly: *a bug
that only appears under UEFI is exactly the bug that ruins a release.* The reason is
structural. Almost all your development runs on the fastest path — `make run`, which is
BIOS + ISO — while almost every machine anyone will actually boot this on is UEFI. The
configuration you test constantly is the one nobody uses.

They genuinely differ. Under BIOS, Limine's own stages set the machine up. Under UEFI,
OVMF has been running for a second already: its own memory map, its own page tables,
its own services resident at kernel entry, a different machine state. A kernel that
assumes anything about what it inherits — memory map entry types, framebuffer
configuration, which regions are safe to reclaim — works under one and not the other.
You find out when someone `dd`s the image to a USB stick and it hangs on a real
laptop, which is the worst possible moment.

`release.yml` sets `fail-fast: true` on its own matrix. Not a contradiction: a release
is blocked by any single failure anyway, so there is nothing to learn from burning the
remaining legs.

```yaml
      - uses: actions/download-artifact@v4
        with:
          name: images
          path: build/
```

This is why `needs: build` is mechanical here. The artifact lands in `build/`, exactly
where `scripts/test.sh` expects `os.iso` and `os.img`. Note the consequence: **this
job tests the exact bytes `build` produced**, not a rebuild. That is the right
property for an integration test — you are asserting something about the artifact, and
a rebuild is a different artifact.

```yaml
      - name: Boot test (${{ matrix.name }})
        run: |
          ./scripts/test.sh boot \
            --firmware ${{ matrix.firmware }} \
            --media    ${{ matrix.media }} \
            --smp      ${{ matrix.smp }} \
            --timeout  90
```

Calling the script directly rather than `make test-boot`, because the Makefile target
runs all four configurations serially — the matrix already parallelises them. The
90-second timeout is enforced inside `run.py`; a kernel that hangs fails rather than
holding a runner for six hours.

**Adapt for Phase 0.** `scripts/test.sh boot` shells out to
`python3 tests/integration/run.py`, which does not exist yet — the real pexpect
harness arrives with the shell in Phase 8. You have two honest options:

1. **Narrow the job now.** Replace the `test.sh boot` call with a direct QEMU
   invocation plus a `grep` on `serial.log` for the greeting string from
   [[Stage 0.6 - Serial Output]]. That asserts precisely what Phase 0 can assert:
   the kernel was reached and produced output, under all four configurations.
2. **Write the smallest possible `run.py`** that accepts `--qemu`, `--timeout`, `--`
   and the QEMU argument list, runs it under a timeout, and greps `serial.log` for
   the marker. Roughly thirty lines, and it gets replaced wholesale in Phase 8.

Do not leave the job calling a script that does not exist. That is the "starts red"
failure this whole stage exists to avoid.

---

#### Consolidated adaptation checklist

| What | Where | Change |
|---|---|---|
| Org name | 5 × `container:` in `ci.yml`, plus `nightly.yml`, `release.yml`, `Makefile` | `cracked-f` → your org |
| Image existence | — | Run `toolchain.yml` first; wait for it |
| Package visibility | GHCR package settings, or `credentials:` in each `container:` | Public, or authenticate |
| `CONTAINER=1` | workflow-level `env:`, or `ENV CONTAINER=1` in the Dockerfile | Stops `make` nesting Docker |
| `OVMF_CODE` | workflow-level `env:` | `/usr/share/OVMF/OVMF_CODE_4M.fd` on Ubuntu 24.04 — verify |
| clang-format file list | `lint` step 1 | Drop `libc user tools` until they exist; add `-r` to `xargs` |
| `clang-tidy` | `lint` last step | Comment out with a `TODO(#N)` if it is not yet clean |
| Tier 3 harness | `test-boot` | Narrow to a serial-marker grep, or write a minimal `run.py` |
| Rule drift | `ci.yml` vs `scripts/lint.sh` | Add the `volatile` rule, or replace the inline steps with `make lint` |
| Trigger scope | `on: push:` | Open a draft PR per branch, or widen to `branches: ['**']` |

---

## 6. How to verify

Five experiments, each under ten minutes. Do all of them — **a CI you have never seen
fail is a CI you have no evidence works.**

### 6.1 The image exists before CI needs it

```sh
docker pull ghcr.io/<org>/os-toolchain:latest
docker run --rm ghcr.io/<org>/os-toolchain:latest x86_64-elf-g++ --version | head -1
```

```
x86_64-elf-g++ (GCC) 14.2.0
```

If `docker pull` says `manifest unknown` or `denied`, stop here and run `toolchain.yml`
from the Actions tab. Everything downstream fails until this works.

### 6.2 A green run end to end

```sh
git checkout -b ci/enable-merge-gate
git add .github/workflows/ci.yml
git commit -m "ci: enable the merge gate"
git push -u origin ci/enable-merge-gate
gh pr create --draft --title "ci: enable the merge gate" --body "Turns on ci.yml."
gh run watch
```

Expected: five job names appear, `lint` and `test-unit` report first, `test-boot`
expands into four legs, all green in roughly six minutes (twelve on the first,
cold-cache run). The draft PR is what triggers the run — with `on: push: branches:
[master]` the bare push does not. If nothing starts, that is why, not a broken
workflow.

### 6.3 Break formatting; confirm `lint` fails in ~30 seconds

```sh
printf '\n\nvoid   badly_formatted_fn(  int x ,int y ) {  }\n' >> kernel/main.cpp
git commit -am "test: deliberately break formatting"
git push
```

Expected: `lint` red within about 30 seconds, with an annotation naming the file, and
the log showing clang-format's intended diff. `build` may still be running or even
pass — the jobs are independent. Now prove the parity claim locally:

```sh
make lint
```

```
clang-format                                        FAIL
   run 'make fmt'
```

Then `make fmt && git commit -am "test: revert formatting break" && git push`.

### 6.4 Violate a boundary; confirm the grep catches it

```sh
sed -i '1i #include "limine.h"' kernel/main.cpp
git commit -am "test: deliberately leak limine.h"
git push
```

Expected — a red annotation at the top of the run:

```
Error: limine.h included outside arch/x86_64/boot/:
kernel/main.cpp
```

This is the check [[Stage 0.3 - Freestanding C++ and kmain]] told you existed; now you
have watched it fire. Revert it, then do one more — a bare `TODO` is the fastest:

```sh
printf '// TODO: something\n' >> kernel/main.cpp
```

Expected: `Error: TODO without an issue reference — use TODO(#123)`.

### 6.5 Force a kernel-test failure; download `serial.log`

Make Tier 2 report failure — the minimal version is a test entry point that calls
`test_exit(false)` unconditionally, writing `1` to port `0xf4` so QEMU exits 3. Push
it. Expected in the job log:

```
FAIL  (isa-debug-exit 1)
--- serial.log (last 60 lines) ---
```

The run summary's **Artifacts** section now lists `test-kernel-logs`:

```sh
gh run download <run-id> -n test-kernel-logs
cat serial.log
x86_64-elf-addr2line -e kernel.elf 0xFFFFFFFF80101A2C
```

The archive must contain `serial.log`, `qemu-stderr.log`, and `kernel.elf`. If
Artifacts is empty, the `if: failure()` step did not run — check that the failing step
comes *before* the upload step. Revert the deliberate failure.

### 6.6 Lock the gate

Settings → Branches → protect `master`, per [[12 - Team Workflow]]:

```
[x] Require a pull request before merging
[x] Require 1 approval
[x] Require status checks: lint, build, test-unit, test-kernel, test-boot
[x] Require branches to be up to date before merging
[x] Require linear history
[ ] Include administrators          ← deliberately off
```

The status check names only appear in the picker **after** they have run at least
once, which is why 6.2 comes first. Select all four `test-boot (…)` legs, not just the
parent — otherwise the matrix is not actually required.

---

- [ ] `docker pull` of the toolchain image succeeds from your machine
- [ ] A draft PR produces five jobs, all green, in about six minutes
- [ ] Deliberate formatting breakage makes `lint` red in ~30 s, and `make lint` reproduces it locally
- [ ] `#include "limine.h"` in `kernel/main.cpp` produces the `limine.h leaked` annotation
- [ ] A bare `TODO` produces the debt annotation
- [ ] A failing Tier 2 test uploads `test-kernel-logs`, and `serial.log` inside it explains the failure
- [ ] `gh run download` retrieves the artifact and `addr2line` resolves against the uploaded `kernel.elf`
- [ ] Branch protection lists all five checks, with all four `test-boot` legs selected
- [ ] The toolchain image is pinned by digest in all five `container:` lines

**What cannot be checked yet.** Tier 1 has almost no tests until Phase 4 gives the
allocators something to assert about. Tier 2 has nothing meaningful until Phase 2
brings interrupts. `make verify-repro` (nightly) is not trustworthy until
`SOURCE_DATE_EPOCH` and `-ffile-prefix-map` are both wired up in
[[08 - Build System]]. The value of turning them on now is that the *harness* is
proven, so the day you write the test, running it is free.

---

## 7. Common traps

**Every job fails within seconds: `manifest unknown`, `denied`, or `unauthorized`.**
The job never starts a step — the failure is in the "Initialize containers" phase.
Three causes, in order of likelihood. (1) The toolchain image has never been
published: `toolchain.yml` has not run, or ran only on a PR (it deliberately does not
push on PRs: `push: ${{ github.event_name != 'pull_request' }}`). Run it manually from
the Actions tab and wait ~25 minutes. (2) The image is published but **private** —
GHCR packages default to private. Either make the package public in its package
settings, or add `credentials:` with `${{ github.actor }}` / `${{ secrets.GITHUB_TOKEN }}`
to every `container:` block and give the job `permissions: packages: read`. (3) The
org name is still `cracked-f`. This is the one everybody hits on the first push, and
it is why the very first push behaves differently from every later one.

**Every `make` step fails with `docker: command not found` or `Cannot connect to the
Docker daemon`.** The root `Makefile` wraps commands in `docker run` unless
`CONTAINER=1`. Inside a CI container there is no Docker daemon, so it tries to nest
and dies. Set `CONTAINER: 1` in the workflow's `env:` block, or `ENV CONTAINER=1` in
`toolchain/Dockerfile` — the second is better because it also fixes `nightly.yml` and
`release.yml`. Symptom variant: the step hangs instead of failing, because `docker run
-it` is waiting on a TTY that does not exist; the `Makefile`'s `RUNQ` variant strips
`-it` for exactly this reason.

**CI passes but the same command fails locally (or the reverse).** By construction
this should be impossible, so it means one of the invariants broke. Check, in order:
are you actually running through the container (`make lint`, not a bare `clang-format`
you happen to have on `$PATH`)? Is the `container:` line still `:latest` while your
`Makefile`'s `TOOLCHAIN` says something else — or vice versa? Has `:latest` moved
since you last pulled (`docker pull ghcr.io/<org>/os-toolchain:latest` and see whether
it downloads layers)? This is the failure mode digest pinning eliminates, and the
moment you hit it once is the moment to pin. Also verify with
`docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/<org>/os-toolchain:latest`
that the digest you have matches the one in `ci.yml`.

**`lint` fails on a file you did not touch.** Almost always clang-format on a repo
where formatting was never applied wholesale. `clang-format --dry-run --Werror` has no
concept of "changed files" — it checks everything, every time. The fix is a single
repo-wide pass, committed on its own so it never pollutes a review:

```sh
make fmt
git commit -am "style: apply clang-format repo-wide"
```

Do this **before** enabling the check, not after. The same logic applies to every rule
in this stage and is the entire "a CI that starts red gets ignored forever" argument
from §1. If it is a boundary rule rather than formatting, check whether the grep is
matching a comment — see the per-rule false-positive notes in §5.

**A boot test times out at 90 seconds with an empty or missing `serial.log`.** Three
distinct causes that look identical.

- `-display none` missing. QEMU tries to open a graphical backend; in a container
  with no X or Wayland socket it aborts with a display initialisation error, and on a
  developer machine it opens a window that nobody closes, so the run sits there until
  the timeout. `scripts/test.sh`'s `qemu_args()` always includes it; if you hand-rolled
  a QEMU line for the Phase 0 adaptation, you probably left it out.
- `-no-reboot -no-shutdown` missing. A triple fault resets the machine, which reboots
  into the same fault, forever. You get a timeout instead of the fault message —
  losing the one piece of information that explained everything. `scripts/test.sh`'s
  own comment calls this out as *not optional*, and
  [[Stage 0.7 - Panic and KASSERT]] makes the same point from the kernel side.
- The kernel genuinely hung before serial was initialised, so there is nothing to
  log. Check `qemu-stderr.log` — `-d guest_errors` records faults QEMU noticed even
  when the guest said nothing. If that is empty too, `make debug` locally and attach
  GDB.

A fourth variant, specific to CI: **all three UEFI legs fail immediately with `OVMF
firmware not found at /usr/share/OVMF/OVMF_CODE.fd`** while `bios-iso` passes. That is
the Ubuntu 24.04 filename change — the file is `OVMF_CODE_4M.fd`. Set `OVMF_CODE` in
the workflow `env:`, and confirm the path with `make shell` then `ls /usr/share/OVMF/`.

**The matrix takes twenty minutes.** Look at where the time goes before optimising.
The usual culprit is a missing or ineffective ccache restore. Check: (1) does the
`build` job actually restore — the step log says either `Cache restored from key: …`
or `Cache not found for input keys: …`; (2) is `path:` really `/ccache`, matching
`CCACHE_DIR` in the image; (3) does `test-kernel` rebuild without any cache at all? It
does, as scaffolded — that is a free two minutes, recoverable either by adding the
cache block or by downloading the `images` artifact instead of rebuilding. Confirm
ccache is being used at all by adding `ccache -s` as a step and reading the hit rate;
a rate near zero usually means the compiler is being invoked by absolute path,
bypassing the `/usr/lib/ccache` shims on `$PATH`. Also check that `test-boot`'s four
legs really are running in parallel and not queuing behind a concurrency limit.

**A push to a feature branch runs nothing at all.** Not a failure — the `on:` block
says `push: branches: [master]`. Open a PR (a draft counts) and every subsequent push
to that branch runs the full gate. If you want unconditional coverage, widen to
`branches: ['**']` and accept that a branch with an open PR then runs twice per push.

**`find: 'libc': No such file or directory` in the `lint` job.** The scaffolded file
list assumes the full tree from [[07 - Repository Layout]], most of which arrives in
later phases. Trim the list to the directories that exist and grow it as you go, or
copy the `2>/dev/null` / `xargs -r` form from `scripts/lint.sh`. The same applies to
the `__DATE__` and `TODO` rules, which scan `kernel/ libc/ user/`.

**A boundary rule reports every legal file as a violation.** Almost certainly the
`^` anchor in the second grep. `grep -r pattern kernel/` prints `kernel/foo.cpp`;
`grep -r pattern ./kernel/` prints `./kernel/foo.cpp`, and `^kernel/arch/...` then
matches nothing, so the exclusion never applies. Keep the paths exactly as scaffolded.

**A rule that should fire does not.** Remember `grep` exits 1 on no match and the
steps end with `|| true` so that success does not abort the step. If you edit a rule
and get the polarity wrong, it will silently pass forever. Test every rule change by
deliberately violating it, as in §6.4 — a boundary rule you have never seen fail is a
boundary rule you have no evidence about.

---

## 8. What this unlocks

Every later stage's "How to verify" becomes something a machine does on your behalf,
and the definition of done in [[12 - Team Workflow]] — *test at the appropriate tier,
passing in CI* — becomes checkable rather than aspirational. Concretely: Phase 2's
IDT work is the first time a boundary rule earns its keep (the first `outb` outside
`kernel/arch/`); Phase 4's allocators are the first substantial Tier 1 suite; Phase 12's
SMP work is where `uefi-smp` stops being a formality and starts being the leg that
catches things. `release.yml` reuses this machinery wholesale, so a release that
cannot boot cannot be tagged.

What silently breaks if this stage is done wrong is worse than a red pipeline. A CI
pinned to `:latest` means your green runs are evidence about an unknown compiler. A
matrix with `fail-fast: true` means you learn *that* it broke without learning *where*.
A boundary rule with an inverted grep is a rule that has never once fired and never
will. And a `test-boot` job that silently skips because its harness does not exist is
the worst of all — a green check mark that asserts nothing, which is exactly what
CI exists to prevent.

Next up in [[Phase 1 - Overview|Phase 1]], every stage lands behind this gate.

---

## 9. Reading

- **GitHub Actions — workflow syntax reference.** The authoritative list of every key
  used here: `on`, `concurrency`, `container`, `needs`, `strategy.matrix`, `if`.
  <https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions>
- **GitHub Actions — running jobs in a container.** What `container:` does to step
  execution, and the `credentials:` block a private GHCR image needs.
  <https://docs.github.com/en/actions/using-jobs/running-jobs-in-a-container>
- **GitHub Actions — workflow commands.** Where `::error::` comes from and what else
  you can emit (`::warning::`, `::notice::`, `::group::`).
  <https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions>
- **Working with the Container registry (GHCR).** Package visibility and how a repo's
  `GITHUB_TOKEN` relates to a package — the source of the `denied` trap.
  <https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry>
- **`actions/cache`.** The README documents `key`, `restore-keys`, the save-on-miss
  behaviour, and the size and eviction limits behind the cold/warm figures.
  <https://github.com/actions/cache>
- **jq manual.** For the compile-database query: `select`, `test`, the `//`
  alternative operator, `contains`.
  <https://jqlang.github.io/jq/manual/>
- **QEMU — invocation and debug options.** `-device isa-debug-exit`, `-d`, `-D`,
  `-no-reboot`, `-no-shutdown`, `-display`.
  <https://www.qemu.org/docs/master/system/invocation.html>
- **`kvm-unit-tests`.** The project that established the `isa-debug-exit` convention.
  Worth ten minutes to see how a serious suite drives a kernel under QEMU.
  <https://gitlab.com/kvm-unit-tests/kvm-unit-tests>
- **OSDev — Kernel Debugging.** The manual counterpart to everything CI automates.
  <https://wiki.osdev.org/Kernel_Debugging>
- [[10 - CI Pipeline]] — the reference document this stage implements; the failure
  triage table in it is the one to keep open when a job goes red
- [[09 - Testing Strategy]] — what belongs in each tier, and why the boot matrix has
  those four rows
- [[ADR-0010 - Testing Strategy and the QEMU Exit Device]] — the decision, including
  the design constraint it imposes on kernel code
- [[ADR-0005 - Containerised Pinned Toolchain]] — why CI and your laptop must run the
  same image, and what happens when they do not
- [[07 - Repository Layout]] — the four boundary rules in prose, before they became greps
- [[12 - Team Workflow]] — branch protection settings and the definition of done
- [[14 - Debugging Playbook]] — what to do with `serial.log` once you have downloaded it

Next: **[[Phase 1 - Overview|Phase 1 — Text Output]]**

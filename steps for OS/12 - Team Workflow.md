# Team Workflow — Two People

How two people build an OS in parallel without breaking each other's work.

---

## The core problem

An OS is a dependency chain. Phase 5 needs Phase 4's heap; Phase 8 needs everything.
Two people working strictly in sequence means one person is always idle. Two people
working in parallel on the same layer means constant conflicts.

The answer is **split by subsystem, not by phase**, with an agreed interface between
them written *before* either side is built.

---

## Ownership split

Not rigid ownership — either person may touch anything — but a **default owner** who
reviews changes and holds the mental model. The split follows the natural seam in the
system: the parts that touch hardware versus the parts that touch the user.

| | **Member A — "Down"** | **Member B — "Up"** |
|---|---|---|
| Theme | Hardware and memory | Processes, files, userspace |
| Owns | `arch/`, `mm/`, `drivers/`, ACPI, APIC, PCI, SMP | `fs/`, `syscall/`, `sched/`, `libc/`, `user/`, `net/` |
| Phases | 0, 2, 3, 4, 9, 11, 12 | 5, 6, 7, 8, 10, 13, 14 |
| Also owns | toolchain container, build system | CI workflows, test harness, release |

Phase 1 (console + logging) and Phase 15 (hardening) are shared.

**Both own** `kernel/include/abi/` — every change there needs both reviewers, because
it is the contract that binds their halves ([[ADR-0008 - Monorepo Layout]]).

### Why this split works

The dependency chain runs *downward*: A's work unblocks B's, rarely the reverse. So
A generally runs one phase ahead. When B is blocked waiting on A, B works on
tests, tooling, or documentation — never on A's files.

### Interface-first rule

When a phase spans both halves, **write the header first, merge it, then implement
both sides in parallel.**

Example — Phase 9/10, the block layer and FAT32:
1. Both agree on `blockdev.hpp`: `read_blocks`, `write_blocks`, `block_size`.
2. That header merges on its own, with a stub implementation.
3. A implements AHCI behind it. B implements FAT32 on top of it, against a
   RAM-backed stub.
4. They meet at the interface and it works, because it was agreed in advance.

This is the single highest-leverage habit for a two-person team. Without it you
serialise; with it you genuinely parallelise.

---

## Branching

```
master          protected, always green, always bootable
  │
  ├── feat/phase4-heap
  ├── fix/pagefault-cr2-wrong
  ├── docs/phase9-notes
  └── chore/bump-limine
```

- **`master` is always bootable.** If `master` cannot boot, that is a stop-everything
  event — fix or revert before anything else.
- Branch names: `<type>/<short-description>`. Types: `feat`, `fix`, `docs`, `chore`,
  `refactor`, `test`, `perf`.
- **One stage per branch.** Stages are sized to be a day or three of work, which is
  exactly the right PR size.
- Rebase on `master` before opening a PR. Merge commits from `master` into a feature
  branch make the history unreadable.

### Branch protection on `master`

```
[x] Require a pull request before merging
[x] Require 1 approval
[x] Dismiss stale approvals on new commits
[x] Require status checks: lint, build, test-unit, test-kernel, test-boot
[x] Require branches to be up to date before merging
[x] Require conversation resolution
[x] Require linear history          (squash merge only)
[ ] Include administrators          ← deliberately OFF, see below
```

**"Include administrators" is off** because with two people, one of you will
occasionally be unavailable for days. A hard block would mean the project stops. The
rule is social instead: **self-merging is allowed only for a documented emergency or
when the other member is genuinely unreachable, and it must be noted in the PR.** If
this starts happening weekly, the rule is not working and needs revisiting rather
than quietly ignoring.

---

## Commits

```
<type>: <imperative summary, <=72 chars>

Why this change exists. Not what the diff shows — the diff shows that.
What problem it solves, what alternative was rejected, what to watch out for.

Refs #42
```

Good:
```
fix: reserve Limine module memory before PMM init

The PMM was handing out frames that still held the initrd, so the first
kmalloc after boot silently corrupted the tar archive. Symptom was a
"file not found" for init, three phases later.

Refs #61
```

Bad: `fix bug`, `wip`, `changes`.

**Commit after every green stage.** That is what makes `git bisect` usable, and
`git bisect` is the most valuable debugging tool in a project where bugs surface far
from their cause.

---

## Pull requests

Every PR must state:

1. **What** it does
2. **Why** — link the stage note or issue
3. **How it was tested** — which tier, and paste the output
4. **What could break** — what to watch on `master` after merge

The template in `scaffold/.github/pull_request_template.md` asks these directly.

### Review, with two people

Review is not a formality when there are two of you — **it is the only mechanism that
puts a second brain on kernel code**, and kernel bugs are exactly the kind that one
brain misses.

A reviewer must:

- Actually check out the branch and run `make test` at least once per phase
- Read the assembly changes line by line — the compiler will not catch a wrong
  register
- Verify the lock ordering against `kernel/sched/locks.md`
- Verify user-pointer validation on any syscall change — **this is a security
  boundary and the most consequential code in the tree**
- Confirm the definition of done: is there a test?

**Turnaround target: same day.** With two people, a stalled review blocks half the
project's capacity.

---

## Definition of done

A stage is done when **all** of these are true:

```
[ ] Code merged to master
[ ] Test at the appropriate tier, passing in CI      ← ADR-0010
[ ] The stage's "How to verify" actually verified
[ ] No new compiler warnings (-Werror means this is automatic)
[ ] Docs updated if behaviour changed
[ ] An ADR written if a significant decision was made
[ ] master still boots
```

---

## Cadence

| When | What | Length |
|---|---|---|
| Daily | Async standup in a GitHub Discussion: doing / blocked | 5 min |
| Weekly | Sync call: review the board, unblock, agree next interfaces | 45 min |
| Per milestone | Retro + the manual release checklist | 2 hours |

The weekly call's most valuable output is **agreeing the next interfaces**, which is
what enables the following week's parallel work.

---

## Issue tracking

GitHub Projects board, one item per stage.

```
Backlog → Ready → In progress → In review → Done
```

- **Ready** means unblocked: dependencies merged, interface agreed.
- WIP limit of **2 per person**. More than that means something is stuck and should
  be surfaced, not accumulated.
- Bugs get a `bug` label and jump the queue if `master` is affected.

---

## Handling being stuck

Written down because two-person teams lose the most time here.

1. **One hour alone.** Re-read the stage concept and common traps.
2. **Then write it down** — post the serial log and what you have ruled out in the
   Discussion. Writing it out solves it surprisingly often.
3. **Then ask.** A synchronous debugging session with two people on one screen is
   worth more than two people stuck separately.
4. **Time-box to a day.** After that, either simplify the approach or park it with a
   documented workaround and an issue. Grinding on one bug for a week is how
   two-person projects die.

---

## Related

[[09 - Testing Strategy]] · [[10 - CI Pipeline]] · [[15 - Roadmap and Milestones]]

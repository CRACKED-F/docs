## What

<!-- One or two sentences. What does this change do? -->

## Why

<!-- Link the stage note or issue. Closes #NN -->

Stage:
Closes #

## How this was tested

<!-- Which tier, and paste the output. "It boots" is not a test.
     See steps/09 - Testing Strategy. -->

- [ ] Tier 1 — host unit test (`make test-unit`)
- [ ] Tier 2 — in-kernel self-test (`make test-kernel`)
- [ ] Tier 3 — integration/boot test (`make test-boot`)
- [ ] Manually verified the stage's "How to verify" section

```
paste test output here
```

## What could break

<!-- What should we watch on master after this merges? Which subsystems does
     this touch that are not obviously related? -->

---

## Checklist

- [ ] `master` still boots after this change
- [ ] No new compiler warnings (`-Werror` makes this automatic)
- [ ] Docs updated if behaviour changed
- [ ] An ADR added if a significant decision was made
- [ ] Lock ordering respected and `kernel/sched/locks.md` updated if a lock was added
- [ ] **If this touches `kernel/include/abi/`** — both reviewers required, and the
      libc side is updated in the same PR
- [ ] **If this touches a syscall** — every user pointer is validated
      (canonical, bounded, mapped, correct permission, copied once)

<!-- Self-merging is allowed only for a documented emergency or when the other
     member is genuinely unreachable. If so, say which, here. -->

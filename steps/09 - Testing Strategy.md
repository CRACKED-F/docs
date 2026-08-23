# Testing Strategy

How you know the kernel works without booting it and squinting at the screen.

Decided in [[ADR-0010 - Testing Strategy and the QEMU Exit Device]].

---

## Why this is hard, and why it matters more here than elsewhere

Kernel code cannot be linked into a normal test binary — it assumes it owns the
machine. There is no process to crash, no debugger attached by default, and a bug
does not throw an exception, it corrupts memory and manifests somewhere else three
weeks later.

That last property is the whole argument. In application code, a bug usually fails
near its cause. In kernel code, a heap bug in Phase 4 surfaces as a scheduler fault
in Phase 12, and the bisect window is *hundreds of commits*. Tests are not a quality
nicety here; they are how you keep the project debuggable at all.

---

## Three tiers

| Tier | Runs where | Speed | Catches |
|---|---|---|---|
| 1 — Unit | Host, native | milliseconds | logic errors |
| 2 — Kernel self-test | QEMU, kernel context | seconds | hardware-interaction errors |
| 3 — Integration | QEMU, full image | tens of seconds | assembly/wiring errors |

---

## Tier 1 — Host unit tests

Pure logic compiled **for the host** and run natively. Ordinary debugging, ordinary
tools, ordinary speed. Framework: **doctest** (single header, vendored).

**What belongs here:**

- Bitmap / buddy allocator bit arithmetic
- `printf` formatting (every specifier, width, precision, edge case)
- `string.h` implementations
- FAT32 cluster-chain walking, LFN reassembly, 8.3 name generation
- ext2 inode/block-group arithmetic
- ELF header and program-header parsing, including malformed input
- tar parsing (octal size fields, the 512-byte padding rule)
- Scheduler run-queue selection given a synthetic task list
- Path canonicalisation (`.`, `..`, `//`, trailing slash)
- Ring buffer wraparound
- TCP sequence-number arithmetic and window calculations

**The design constraint this imposes:** this logic must take its dependencies as
parameters rather than reaching for globals or hardware. That is exactly why
`kernel/mm/` and `kernel/arch/x86_64/mm/` are separate directories
([[ADR-0008 - Monorepo Layout]]) — the allocator's *arithmetic* is testable on the
host; only the page-table *writes* need real hardware.

This constraint improves the kernel independently of testing. It is not a tax paid
for tests; it is a better design that tests happen to require.

```cpp
// tests/unit/test_pmm.cpp
TEST_CASE("bitmap allocator reuses freed frames") {
    uint8_t storage[4096] = {};
    Bitmap bm(storage, sizeof(storage) * 8);
    bm.mark_free(0, 100);

    auto a = bm.alloc();
    auto b = bm.alloc();
    CHECK(a != b);
    bm.free(a);
    CHECK(bm.alloc() == a);          // freed frame comes back
}
```

**Target: every pure-logic function has a Tier-1 test before it is used by the
kernel.** These are cheap. Write them first.

---

## Tier 2 — In-kernel self-tests

A test build of the kernel boots under QEMU, runs assertions **in kernel context on
the real hardware model**, and reports a pass/fail exit code.

**What belongs here** — anything that cannot be faked on the host:

- Does `map_page` actually make the address readable?
- Does unmapping actually fault, with the right address in `CR2`?
- Does the context switch resume a task with its registers intact?
- Does `kmalloc` survive a 100 000-iteration random alloc/free torture loop?
- Does an IRQ actually arrive, and does the EOI let the next one through?
- Does a `#GP` from ring 3 land in the right handler with the right error code?
- Are atomics actually atomic across cores? (Phase 12)

### The reporting mechanism

QEMU's `isa-debug-exit` device makes QEMU exit when the kernel writes to a port:

```
qemu-system-x86_64 -device isa-debug-exit,iobase=0xf4,iosize=0x04 ...
```

Writing `N` to port `0xf4` exits QEMU with status `(N << 1) | 1`.

```cpp
[[noreturn]] void test_exit(bool ok) {
    outl(0xf4, ok ? 0 : 1);      // -> QEMU exit 1 (pass) or 3 (fail)
    __builtin_unreachable();
}
```

`scripts/test.sh` maps exit `1` → pass, `3` → fail, anything else → crash. This is
the same mechanism `kvm-unit-tests` uses.

### Two rules that are not optional

**1. Hard timeout on every run.** A kernel that hangs must *fail*, not hang CI
forever.

```sh
timeout 60 qemu-system-x86_64 ... ; rc=$?
[ $rc -eq 124 ] && { echo "TIMEOUT — kernel hung"; exit 1; }
```

**2. Always `-no-reboot -no-shutdown`.** Otherwise a triple fault silently reboots
into an infinite loop and you get a timeout instead of the fault message, losing the
one piece of information you needed.

Serial output is always captured to a log and printed on failure.

```
[TEST] mm/paging: map_page makes address readable ......... PASS
[TEST] mm/paging: unmapped access faults with correct CR2 . PASS
[TEST] mm/heap:  torture 100000 random alloc/free ......... PASS
[TEST] sched:    context switch preserves callee-saved .... FAIL
       expected rbx=0xDEADBEEF got 0x00000000
       at kernel/sched/task.cpp:214
```

---

## Tier 3 — Integration / boot tests

Boot the **real release image** and drive it as a user would: send keystrokes over
serial, assert on output. Mechanism: `pexpect` with per-step timeouts.

```python
# tests/integration/test_shell.py
def test_shell_runs_programs(qemu):
    qemu.expect(r"\$ ", timeout=30)          # reached the prompt
    qemu.sendline("echo hello")
    qemu.expect("hello")
    qemu.sendline("ls")
    qemu.expect("init")
    qemu.sendline("crashme")                  # deliberately faults
    qemu.expect(r"\$ ")                       # shell survived the child dying
```

**What belongs here:**

- Boots to a shell prompt within N seconds
- Built-ins work; programs launch and return
- A crashing child does not take down the shell
- Writing a file, rebooting, and reading it back (Phase 10 — the real persistence
  proof)
- ACPI shutdown actually powers off (QEMU exits cleanly)
- Networking: ping, a TCP echo round-trip (Phase 14)

### The boot matrix

Every integration test runs against **all** of these. They fail differently, and a
bug that only appears under UEFI is exactly the bug that ruins a release.

| Config | Firmware | Media | Cores |
|---|---|---|---|
| BIOS ISO | SeaBIOS | `os.iso` | 1 |
| UEFI ISO | OVMF | `os.iso` | 1 |
| UEFI disk | OVMF | `os.img` | 1 |
| UEFI SMP | OVMF | `os.img` | 4 |

---

## Definition of done

> **A stage is not complete until it has a test at the appropriate tier.**

This is the single most important process rule in the project. It is in the PR
template and it is a reviewer's job to enforce it.

Which tier:

| The thing you built | Tier |
|---|---|
| A function with no hardware dependency | 1 |
| Something touching CPU state, MMU, or a device | 2 |
| A user-visible behaviour | 3 |

---

## Coverage, and what it is worth

`gcov`/`lcov` on **Tier 1 only** — coverage of kernel-context code is not meaningfully
measurable in our setup and pretending otherwise invites gaming the number.

Target: 80% line coverage on `kernel/lib/`, `kernel/mm/` (neutral parts), and
`kernel/fs/` parsing code. **No target elsewhere**, because a coverage target on code
that cannot be host-tested produces theatre, not quality.

---

## What we deliberately do not test

Recorded so these are decisions, not oversights.

- **Timing precision.** QEMU's timing is not real timing. We assert that a sleep
  returns *after* its deadline, never that it returns *near* it.
- **Real hardware in CI.** No hardware runner. Real-hardware validation is a manual
  release-checklist step ([[11 - Release and Deployment]]).
- **Performance.** No benchmarks in v1. Correctness first; a benchmark on emulated
  hardware measures QEMU.

---

## Related

[[ADR-0010 - Testing Strategy and the QEMU Exit Device]] · [[10 - CI Pipeline]] · [[14 - Debugging Playbook]]

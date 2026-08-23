# Stage 0.7 — Panic and `KASSERT`

**Difficulty:** Medium · ~75 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `kernel/lib/panic.cpp`, `kernel/include/kernel/panic.hpp`, `kernel/include/kernel/assert.hpp`
**Deliverable:** a fault prints a message, a register dump and a backtrace, then halts — instead of silently rebooting.

---

## Progress

- [ ] Write `kernel/include/kernel/panic.hpp` — `panic()`, the sink hooks, `panic_write()`
- [ ] Write `kernel/include/kernel/assert.hpp` — `KASSERT` and `KASSERT_ALWAYS`
- [ ] Write `kernel/lib/panic.cpp`: output plumbing and the tiny formatter
- [ ] Add register capture and the register dump
- [ ] Add the frame-pointer backtrace — **bounded, and validated before every dereference**
- [ ] Add the re-entrancy guard so a panic inside a panic cannot triple-fault
- [ ] Add `-fno-omit-frame-pointer` in `cmake/KernelFlags.cmake`
- [ ] Call `panic("test panic: %d", 42)` at the end of `kernel_init` and boot it
- [ ] Confirm QEMU halts instead of rebooting, and host CPU stays near zero
- [ ] Resolve a backtrace address with `x86_64-elf-addr2line`
- [ ] Add a temporary `KASSERT(1 == 2)` and confirm the file and line are right
- [ ] Remove the test panic; keep the machinery
- [ ] Committed with a message like `feat(lib): panic handler, KASSERT, frame-pointer backtrace`

---

## 1. Why this stage exists

Your kernel currently has exactly one failure mode: **the machine reboots and tells you
nothing.**

There is no IDT yet — that is [[Phase 2 - Overview|Phase 2]] — so the CPU has nowhere to
send an exception. A stray write to address `0` raises a page fault, the CPU looks for a
handler, fails, escalates to a double fault, fails again, and triple-faults. The processor
signals shutdown and the platform resets it. Firmware runs, Limine runs, your kernel runs,
your bug happens again.

That costs three things at once. **No message** — you do not know what went wrong. **No
state** — the reset clears the registers, so you do not know where either. **No signal in
CI** — the loop never ends, so the hard timeout in [[09 - Testing Strategy]] fires and the
job reports `TIMEOUT — kernel hung`, which is also what you get for a deadlock, an infinite
loop, and forty other causes. A specific fault has become a generic non-answer.

This stage builds the machinery that turns that into a paragraph of text: `panic()`, which
prints everything the kernel knows and then parks the core, and `KASSERT`, which states an
invariant and calls `panic()` when it does not hold.

**Hold one caveat in your head for the next two phases.** Stage 0.7 does not catch CPU
faults — catching a fault requires an IDT. It catches *detected* errors: an explicit
`panic()` call and a failed `KASSERT`. CPU faults start arriving in **Stage 2.3**, where
the exception handlers' job is to call this `panic()` with a real exception frame. That is
what the initialisation order in [[06 - Architecture Overview]] records: panic is step 5,
dependencies "serial, IDT", phase "0/2". You build the reporting half now because Phase 2
is far easier to debug when the reporting already works, and because every Tier-2 test in
[[09 - Testing Strategy]] is written in terms of `KASSERT` and cannot exist before it does.

---

## 2. The concept

### What the CPU does with an exception when you have no IDT

Every x86 exception has a **vector number** — `#DE` divide error is 0, `#GP` general
protection is 13, `#PF` page fault is 14. When one fires the CPU indexes the **Interrupt
Descriptor Table**, a table of 16-byte gate descriptors whose base and limit live in the
`IDTR` register, reads entry `[vector]`, and jumps to the address in that gate.

Limine hands you a CPU in long mode with paging on and interrupts disabled. It does **not**
hand you a usable IDT; treat `IDTR` as containing nothing you may rely on. So the lookup
fails — either the limit is too small for that vector or the gate is marked not-present —
and failing to deliver an exception is itself an exception.

```
  your bug:  *(volatile uint64_t*)0 = 1;     ← write to an unmapped page
       │
       ▼
  #PF (vector 14) raised
       │
       ├── CPU reads IDT[14] .............. no table / gate not present
       ▼
  #DF (vector 8) raised           "double fault": a fault while delivering a fault
       │
       ├── CPU reads IDT[8] ............... no table / gate not present
       ▼
  TRIPLE FAULT
       │
       ├── processor enters shutdown; the platform asserts RESET
       ▼
  firmware → Limine → your kernel → same bug → same reset
       │
       └────────────────────────► silent reboot loop.  No output. CI timeout.
```

Two details worth having right. Not every fault-during-fault is a double fault: Intel's
rules classify exceptions as benign or contributory and only certain combinations escalate —
a missing IDT gate raises a contributory fault during delivery of a contributory fault or a
page fault, so this path does. And the third failure is not "a vector 18 exception"; there
is no triple-fault handler to miss. The processor gives up and signals shutdown, and what
happens next is the platform's business. On a PC, and in QEMU, that is a reset.

The reset is what makes the failure silent: it clears the framebuffer, clears the registers,
and restarts the chain. Anything already pushed **out of the machine** survives — the whole
argument for [[Stage 0.6 - Serial Output]] preceding this stage. Serial bytes live in your
terminal or `build/serial.log`, where a reset cannot reach them.

### What panic does instead

`panic()` is not error handling. It is the deliberate refusal to handle an error, on the
grounds that the kernel has already proved it does not understand its own state. Its job is
**evidence preservation**.

```
  kernel detects something impossible
       │
       ▼  cli                      nothing may interrupt the report
       ▼  serial: banner           the log says "we panicked" whatever happens next
       ▼  serial: message          why
       ▼  serial: registers        where — pure register reads, cannot fault
       ▼  serial: backtrace        how we got here — first step that touches memory
       ▼  serial: recent log       context — only if the ring buffer exists (Stage 1.5)
       ▼  screen: the same text    only if a console exists (Phase 1)
       ▼  cli; hlt forever         the core parks; nothing else is corrupted
```

Read that as a reliability gradient: each step is more likely to fail than the one above
it, so each is placed after everything it could destroy. §4 states it as a table.

### Invariants versus conditions

Most kernel bugs are not "the disk was unplugged"; they are "this pointer was supposed to
be page-aligned and is not". The first is a *condition* — the world did something legal
that you must handle. The second is an *invariant* — something your own code guarantees by
construction, so if it is false the code is wrong and every line afterwards runs on a false
premise. Those get opposite treatment, and telling them apart is the most important
judgement in this stage.

---

## 3. Design decisions and tradeoffs

### Decision: what does the kernel do when an invariant breaks?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — panic and halt (chosen)** | Print everything, `cli; hlt` forever | The machine is dead until you reboot it | ✅ |
| B — log and attempt to continue | Warn, carry on with a fixed-up value | Corruption spreads; the crash lands somewhere unrelated | ❌ |
| C — reboot | Reset, optionally after a crash dump | Evidence destroyed unless the dump path already works | ❌ |

**Why A.** A broken invariant means the kernel's model of itself is wrong. Every subsequent
instruction executes on a false premise, and in kernel context there is no containment: no
process to kill, no exception to throw, no supervisor to notice. Halting freezes the
machine in the state closest to the cause — exactly the state you want to inspect — and
keeps the message on screen with the core out of the way while you read it.

**Why not B.** "Continue" means continuing to write to memory you have proved you do not
understand. The failure does not go away, it *moves*: the allocator with the corrupt free
list panics three seconds later inside the scheduler, and now the backtrace points at the
scheduler. [[09 - Testing Strategy]] makes the same point about bisect windows — a bug that
surfaces far from its cause turns ten minutes of debugging into several days. Continuing is
a machine for manufacturing that distance.

**Why not C.** Rebooting deletes the evidence. It is the failure mode this stage exists to
remove, chosen on purpose, and it produces the CI timeout from §1.

**When B and C would be right.** Both are correct in production, and real kernels do them.
Linux's `WARN_ON` is option B — stack trace and keep going, because on a user's laptop an
imperfect kernel that stays up beats a correct one that stops. Windows' bugcheck is option
C — write a crash dump, then reboot, because availability is the product and the dump keeps
the evidence anyway. Note the precondition: C is acceptable *because* the dump is written
first, and a dump needs a working disk stack, a dump partition, and code that survives
whatever just broke. You have none of that. You are debugging, not serving users. Revisit C
when this OS has users and a tested dump path — not before.

---

### Decision: does `KASSERT` compile out in release builds?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — two macros (chosen)** | `KASSERT` compiles out under `NDEBUG`; `KASSERT_ALWAYS` never does | One judgement call per assert | ✅ |
| B — always on | Every assert runs in every build | A branch on every hot path, forever | ❌ |
| C — always off in release | No `KASSERT_ALWAYS` | Cheap, critical checks get dropped with the rest | ❌ |

**Why A.** The two costs traded here are different in kind and one macro cannot express
both. Asserting `is_aligned(addr, PAGE_SIZE)` inside a page-table walk that runs on every
fault is a test-and-branch on a hot path, and there will be hundreds of such asserts by
Phase 12 — a real cost you would like to stop paying once the code is trusted. Asserting
that a free-list node's magic number is intact costs one compare and stops you linking a
corrupt block into the allocator; proceeding there costs the whole heap. Two costs, two
macros.

**The rule for choosing.** Use `KASSERT_ALWAYS` when *both* hold:

1. The check is cheap relative to the work around it — a compare, a mask, a bounds test.
2. Proceeding on a false condition **corrupts state**, rather than merely producing a wrong
   answer.

Otherwise use `KASSERT`. Free-list magic numbers, page-table entry sanity before a write,
lock-rank ordering ([[13 - Coding Standards]] rule 4), and "this index is inside this array
before I write through it" are `KASSERT_ALWAYS`. Arithmetic preconditions, consistency
checks in settled code, and anything inside a tight loop are `KASSERT`.

**Why not B.** It forces the tradeoff the wrong way where it is least visible: when every
assert is unconditional, the expensive ones become an argument for deleting asserts, and
the cheap-but-critical ones get deleted alongside them.

**Why not C.** A release kernel with no checks is one whose first symptom of corruption is a
triple fault on a user's machine. `KASSERT_ALWAYS` keeps the handful worth their cost.

**Two consequences that bite.** A `KASSERT` condition must have **no side effects** —
`KASSERT(list_remove(node) == 0)` works until the release build, where the node is never
removed and you have shipped a leak that does not reproduce in debug. And the release
expansion must still *parse* the condition, or asserts rot: a variable gets renamed and the
debug build breaks weeks later when someone finally compiles it. §5 shows the `sizeof` form
that gives both properties.

---

### Decision: assert an invariant, or return an error?

The most consequential judgement in the stage. [[13 - Coding Standards]] rule 7:

```cpp
KASSERT(is_aligned(addr, PAGE_SIZE));    // a bug if false — panic
if (!page_exists(addr)) return -EFAULT;  // can legitimately happen — return
```

| The condition | Who can make it false | Treatment |
|---|---|---|
| `addr` is aligned when the caller promised alignment | only your own code | `KASSERT` |
| The free-list head is non-null after a successful alloc | only your own code | `KASSERT` |
| The lock is held on entry to this internal function | only your own code | `KASSERT` |
| A syscall's `fd` is in range | **any user program** | `return -EBADF` |
| A user pointer is mapped and writable | **any user program** | `return -EFAULT` |
| A block number read from a disk image is in range | **any disk, including a hostile one** | return an error |
| A packet's declared length matches its actual length | **anyone on the network** | drop the packet |

**The test.** *Can anything outside this kernel's own source make this false?* If yes it is
a condition and you return an error. If the only way is for kernel code to have a bug, it is
an invariant and you assert it.

**Backwards, direction one: asserting on input the outside world controls.**
`KASSERT(fd < MAX_FD)` in a syscall handler means a three-line user program calling
`close(999999)` halts the machine. That is a denial of service on day one, and once
processes exist and one is untrusted it is a security bug: an unprivileged program has a
reliable one-instruction way to take the system down. These are easy to write because the
assert *reads* as defensive. It is the opposite — it converts a rejectable input into a
fatal one. This is why [[13 - Coding Standards]] rule 5 mandates `validate_user_ptr`
returning `-EFAULT` and not an assert.

**Backwards, direction two: returning an error for a broken invariant.**

```cpp
if (!is_aligned(addr, PAGE_SIZE))
    return -EINVAL;      // wrong: nothing outside this kernel can cause this
```

Worse than it looks. You have taken a proof that your own code is broken and turned it into
a return value the caller almost certainly ignores or — worse — *handles*, by retrying,
falling back, or logging at debug level. The bug survives. The misaligned address came from
somewhere, that somewhere is still wrong, and the next symptom is a corrupt page-table
entry discovered in Phase 12 as a scheduler fault. You spent the one moment where the bug
was cheap to find and bought nothing.

**When the answer flips.** At a trust boundary. The same check is an assert on the
kernel-internal side and an error return on the outward-facing side: `sys_read` validates
its `fd` and returns `-EBADF`, and the internal `file_read(File*, ...)` it then calls may
`KASSERT(f != nullptr)`, because by that point the value was validated by kernel code and a
null is a bug in that validation. The boundary is where the check changes kind, and it
should be a named, visible place — `kernel/syscall/validate.cpp`, filesystem parsers,
packet parsers — not scattered.

---

### Decision: frame-pointer walking or DWARF unwinding for the backtrace?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — frame pointers (chosen)** | `rbp` chains frame to frame; return address at `rbp+8` | One GPR; `-fno-omit-frame-pointer`; blind to hand-written asm frames | ✅ |
| B — DWARF `.eh_frame` unwinding | Interpret CFI programs to reconstruct the CFA at any PC | A real unwinder running inside the panic path | ❌ |
| C — heuristic stack scan | Scan the stack for values that look like return addresses | No flags needed; produces plausible-looking lies | ❌ |

**Why A.** The loop in §5 is about twenty lines and dereferences memory twice per frame. No
tables, no allocation, no parsing state, no runtime support. That matters more here than
anywhere else in the kernel, because this code runs *after* the kernel has admitted it is
broken — every line in the panic path is a line that might fault while reporting a fault,
and a fault inside `panic` costs you the original message. Twenty auditable lines is a
defensible amount of risk. The price is one register and a compiler flag.

**Why not B.** DWARF is genuinely the better unwinder: accurate for optimised
frame-pointer-less code, correct through hand-written assembly if the `.cfi` directives are
right, and free of any register cost. But the implementation is a bytecode interpreter for
the CFI opcodes, a binary search over `.eh_frame_hdr`, and a register-rule state machine —
several thousand lines of pointer-chasing parser, added to the one function that must never
fault, run at the moment kernel state is least trustworthy. One bad pointer in that parser
and you lose the message it existed to enrich. You also have `-fno-exceptions`
([[ADR-0007 - Freestanding C++20 as the Kernel Language]]), so there is no unwinder in the
toolchain to borrow; you would write it yourself.

**Why not C.** A stack scan finds every stale return address left over from earlier calls
mixed in with the live ones, in no distinguishable order. A backtrace that is sometimes
right and never marked is worse than none, because you will act on it.

**When B would be right.** When you can no longer afford `-fno-omit-frame-pointer` in the
build you ship and the register genuinely matters. That is why Linux moved to its ORC
unwinder — and note the shape of that answer: the project with the strongest case for B did
not choose B, it invented a simpler pre-digested format. If you get there, do the same. Not
in Phase 0.

---

### Decision: where does panic write, and in what order?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — serial first and unconditionally, console last and only if present (chosen)** | Text goes to COM1 immediately; a copy is buffered and replayed to the console at the end | 4 KiB of `.bss` | ✅ |
| B — console first | Draw to the framebuffer, then serial | Panic is useless before Phase 1, and faults with no console | ❌ |
| C — mirror live to both | Every chunk goes to both channels as produced | A console fault at line 1 loses lines 2..n **from serial too** | ❌ |

**Why A.** Look at the initialisation order in [[06 - Architecture Overview]]: serial is
step 1, panic step 5, the framebuffer console step 6, the log ring buffer step 7. Panic must
be fully functional one step *before* a console exists, because steps 2–5 are exactly where
early boot fails — a null Limine response, a bad `boot_info` copy, a wrong GDT descriptor.
A panic that needs a console is useless for the failures it was built for. Serial is also
the channel most likely to work at all — no framebuffer, no font, no pitch arithmetic, no
MMIO mapping, just four `outb`s and a status bit
([[ADR-0004 - Framebuffer Console Not VGA Text]]) — and it is the only channel CI can read.

**Why not B.** It inverts the dependency, and it faults on a machine with no framebuffer.
"The panic handler crashed" is a uniquely unhelpful place to be.

**Why not C.** The subtle one, and why §5 buffers rather than mirrors. Live mirroring makes
a console failure fatal to the *serial* output: `put()` writes a chunk to serial, then to
the console, the console faults on chunk one, and nothing after it reaches either channel.
Buffering as you write to serial and replaying the whole buffer to the console as the last
act before halting gives the property you want — the console may fail as badly as it likes
and serial already has the complete report.

**When B or C would be right.** On a machine with no serial port, which is most laptops
built after about 2010. That is a real case for [[Phase 15 - Overview|Phase 15]], and the
answer there is to *add* channels — a framebuffer panic screen, a dump to disk — never to
reorder them. Serial stays first because it works earliest.

---

### Decision: does panic reuse `kprintf`?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — panic has its own tiny formatter (chosen)** | ~60 lines local to `panic.cpp` | Logic duplicated with `kprintf` later | ✅ |
| B — call `kprintf` | One formatter for the whole kernel | It does not exist until Stage 1.5 — and it may be the broken thing | ❌ |

**Why A.** `kprintf` arrives five stages after you need panic, which settles it on schedule
alone — but the reason outlives the schedule. When `kprintf` exists it will route to the
console and the log ring, take whatever lock protects them, and use the general output path;
every one of those might be the reason you are panicking. Sixty duplicated lines buy
independence. It is also why the register dump in §5 bypasses the format string entirely:
fewer moving parts is the whole design goal of this file.

---

## 4. Specification

### `panic`

```cpp
[[noreturn]] void panic(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
```

| Guarantee | Why |
|---|---|
| Never returns | Callers and the optimiser rely on it; `[[noreturn]]` makes it a contract |
| Never allocates | There is no heap until [[Phase 4 - Overview|Phase 4]] |
| Never takes a lock | The lock may be the broken thing |
| Never dereferences an unvalidated pointer | A fault here loses the message |
| Re-entrant-safe | A second entry halts immediately instead of recursing |

### The eight steps, in order

Each step is more likely to fail than the one above it. That is the ordering rule.

| # | Step | Why here | What breaks if it moves later |
|---|---|---|---|
| 1 | `cli` | One instruction, cannot fail; until Phase 2 any interrupt is a triple fault | An interrupt lands mid-report: scrambled output, or a fatal re-entry |
| 2 | Serial banner, unconditionally | Everything below can fail; this guarantees the log says *something* | A failure in step 3+ produces a completely empty log |
| 3 | The message | The most valuable line; formatting touches only the format string | If registers or the backtrace fault first, you lose *why* |
| 4 | Register dump | Pure register reads — cannot fault | After the backtrace, a bad frame pointer costs you the registers too |
| 5 | Backtrace | **First step that dereferences memory**, so first that can fault | Nothing — but moving it *earlier* risks everything above it |
| 6 | Log ring dump (Stage 1.5) | Reads a structure that may itself be the corruption | A corrupt ring buffer eats the backtrace |
| 7 | Console, if registered | Most code, most MMIO, most arithmetic — most likely to fault | A console fault costs the entire serial report (§3, option C) |
| 8 | `for (;;) { cli; hlt; }` | Nothing after it matters | Falling out of a `[[noreturn]]` function is undefined behaviour |

Register *capture* happens before step 2 even though the *printing* is step 4 — the values
must be read before the printing code perturbs them.

### `KASSERT`

```cpp
#define KASSERT(cond) \
    do { if (!(cond)) panic("assertion failed: %s\n  at %s:%d", #cond, __FILE__, __LINE__); } while (0)
```

| Macro | Debug | Release (`NDEBUG` defined) | Use for |
|---|---|---|---|
| `KASSERT(c)` | evaluates `c`, panics if false | parsed and type-checked, never evaluated | invariants generally |
| `KASSERT_ALWAYS(c)` | evaluates `c`, panics if false | **identical** — never compiles out | cheap checks whose violation corrupts state |

CMake defines `NDEBUG` automatically for `Release` and `RelWithDebInfo`, so no extra
plumbing is needed; `BUILD_TYPE=Debug` leaves it undefined.

### Register capture: what is real and what is approximate

| Field | Source | Trustworthy at the panic site? |
|---|---|---|
| `rbx`, `rbp`, `r12`–`r15` | read directly | **Yes** — callee-saved, so they still hold the caller's values |
| `rsp` | read directly | Yes, offset by panic's own frame |
| `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`–`r11` | read directly | **No** — caller-saved; the call to `panic` already overwrote them |
| `rflags` | `pushfq; popq` | Yes |
| `rip` | `__builtin_return_address(0)` | Yes — the call site of `panic` |
| `cr2` | `mov %cr2` | Only meaningful after a page fault |
| `cr3` | `mov %cr3` | Yes — physical address of the active PML4 |

This is as good as it gets before an IDT exists, and this table is what you tell yourself
when a value looks wrong. In [[Phase 2 - Overview|Phase 2]] the exception stubs push a full
register frame at the instant of the fault, `panic` takes that frame as an argument, and
every field becomes exact — including the faulting `rip` and the error code.

### Stack frame layout (x86-64 SysV, with frame pointers)

Prologue: `push %rbp` then `mov %rsp, %rbp`.

```
   higher addresses
   ├──────────────────────────┤
   │ return address           │  ← rbp + 8   (into the caller)
   ├──────────────────────────┤
   │ caller's saved rbp       │  ← rbp + 0   (the next frame up)
   ├──────────────────────────┤
   │ this function's locals   │  ← rsp
   lower addresses
```

So a frame is exactly `struct { StackFrame* next; uintptr_t ret; }`.

### Frame validation — every predicate, checked *before* dereference

| Predicate | Value | Rejects |
|---|---|---|
| `addr >= 0xFFFF800000000000` | kernel-space floor | null, user addresses, **and every non-canonical value** |
| `addr <= UINTPTR_MAX - sizeof(StackFrame)` | no wraparound | a read straddling the top of the address space |
| `(addr & 7) == 0` | 8-byte aligned | garbage that happens to be in range |
| `next > current` | stacks grow down | loops and self-referential garbage |
| frame count `< 32` | bound | an unbounded walk through mapped junk |
| `__text_start <= ret < __text_end` | return address in kernel `.text` | data mistaken for a return address; also ends the walk cleanly at `kmain` |

The floor check does double duty. A canonical 64-bit address has bits 63:48 all equal to
bit 47; `0xFFFF800000000000` is the lowest address with all of them set, so anything at or
above it is canonical by construction — one comparison instead of a sign-extension test.

`__text_start` / `__text_end` are exported by the linker script from Stage 0.4 (see
[[08 - Build System]]). Check your `linker.ld` for the exact spelling before relying on
these names.

**What you cannot check yet:** whether the address is actually *mapped*. You do not own the
page tables ([[Phase 4 - Overview|Phase 4]]) and have no page-fault handler
([[Phase 2 - Overview|Phase 2]]), so a plausible pointer into an unmapped page still
triple-faults. The predicates remove the common failures; the re-entrancy guard is the
backstop for the rest.

### Build flags

| Flag | Where | Why |
|---|---|---|
| `-fno-omit-frame-pointer` | `cmake/KernelFlags.cmake` | `-O1`+ enables `-fomit-frame-pointer` by default; without this `rbp` is a general-purpose register and the walk reads garbage |
| `-mno-red-zone` | already set ([[08 - Build System]]) | makes `pushfq; popq` inside inline asm safe |
| `-Wall` | already set | enables `-Wformat`, which `format(printf,1,2)` activates for `panic` |

---

## 5. Writing the code

**One boundary note first.** `kernel/lib/panic.cpp` contains x86 inline assembly, and
[[07 - Repository Layout]] rule 1 confines inline assembly to `kernel/arch/`. That conflict
is resolved deliberately, not ignored: the *policy* in this file — ordering, formatting,
assert semantics — is architecture-neutral and belongs in `lib/`, while the register reads
are the only architecture-specific part. This file is an explicit, documented exemption to
the CI boundary grep. If a second architecture ever appears, the capture and the halt loop
move behind `arch_capture_regs()` / `arch_halt()` and nothing else here changes. Record the
exemption in `.github/workflows/ci.yml` so it is a decision rather than a hole.

### `kernel/include/kernel/panic.hpp`

The cross-subsystem interface: how anything reports a fatal error, and how later subsystems
attach themselves to the panic path.

```cpp
#pragma once

#include <stddef.h>

// A sink panic can push already-formatted text at. Registered by subsystems
// that do not exist yet the first time panic is used.
using PanicSink = void (*)(const char* text, size_t len);

// A hook panic calls to append extra context. It writes via panic_write().
using PanicHook = void (*)();

// Registered by the framebuffer console in Phase 1. Null until then.
void panic_set_console_sink(PanicSink sink);

// Registered by the log ring buffer in Stage 1.5. Null until then.
void panic_set_log_dump(PanicHook hook);

// Write raw text to the live panic channels. For panic hooks only.
void panic_write(const char* text, size_t len);

// Report a fatal, unrecoverable condition and halt. Never returns.
[[noreturn]] void panic(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
```

#### Line by line

**The two function-pointer types**
```cpp
using PanicSink = void (*)(const char* text, size_t len);
using PanicHook = void (*)();
```
Registration hooks rather than direct calls, and the reason is layering. In the subsystem
map in [[06 - Architecture Overview]], `drivers/` sits *above* `lib/`, so `panic.cpp`
calling the framebuffer console directly would be an upward call — the one thing the
dependency rule forbids. Inverting it costs one function pointer: the console registers
itself when it initialises and `panic.cpp` never learns a framebuffer exists. It also gives
you the null check step 7 needs for free. Nothing calls the setters in Phase 0; they exist
now so Phase 1 is a one-line change rather than a redesign, and so the guarded paths are
written while you are thinking about them.

**`panic_write`**
```cpp
void panic_write(const char* text, size_t len);
```
Public only so a registered hook can emit into the same stream — Stage 1.5's log dump calls
it once per stored line. Not a general print function: no locking, and it writes into the
panic capture buffer.

**The declaration of `panic`**
```cpp
[[noreturn]] void panic(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
```
`[[noreturn]]` is load-bearing three ways. It lets the compiler treat everything after a
failed `KASSERT` as unreachable, which is what stops `-Wmaybe-uninitialized` firing on a
variable that only an assert-checked path leaves unset — under `-Werror` that is the
difference between a clean build and a false failure. It lets the optimiser drop the return
path, so no epilogue and no register restoration is generated. And it is a contract: a
`[[noreturn]]` function that returns is undefined behaviour, which is why step 8 is an
infinite loop and not a `return`.

`format(printf, 1, 2)` says argument 1 is the format string and the variadic arguments
start at 2, turning on `-Wformat` at every call site. `panic("bad id %s", id)` with an `int`
`id` becomes a compile error instead of a wild pointer dereference *inside the panic
handler* — the worst place in the kernel for one. The caveat: GCC checks against real
`printf` while the formatter below implements a subset, so `%f` compiles cleanly and prints
as literal text. That is why the formatter's `default:` case echoes unknown specifiers
instead of guessing.

---

### `kernel/include/kernel/assert.hpp`

The two assertion macros — the header you will include most often in the whole project.

```cpp
#pragma once

#include <kernel/panic.hpp>

// Present in EVERY build, including release. Use where the check is cheap and
// the consequence of proceeding is corruption.
#define KASSERT_ALWAYS(cond)                                                   \
    do {                                                                       \
        if (!(cond)) [[unlikely]] {                                            \
            panic("assertion failed: %s\n  at %s:%d", #cond, __FILE__,         \
                  __LINE__);                                                   \
        }                                                                      \
    } while (0)

#ifdef NDEBUG
// Release: sizeof does not evaluate its operand, so the condition costs
// nothing at run time — but it is still parsed and type-checked, and every
// variable named inside it still counts as used.
#  define KASSERT(cond)                                                        \
      do {                                                                     \
          (void)sizeof((cond));                                                \
      } while (0)
#else
#  define KASSERT(cond) KASSERT_ALWAYS(cond)
#endif
```

#### Line by line

**The `do { ... } while (0)` wrapper**

Not decoration. The macro must behave as **one statement**, usable anywhere a statement is
legal, and only `do { } while (0)` achieves that while still requiring a terminating
semicolon.

Try bare braces — `#define BAD(cond) { if (!(cond)) panic("x"); }` — and then:

```cpp
if (x) BAD(x > 1); else panic("y");
```

That expands to `if (x) { ... }; else panic("y");`. The semicolon after the block ends the
`if`, so the `else` has nothing to attach to, and GCC says exactly this:

```
error: 'else' without a previous 'if'
```

The failure appears at the call site, in someone else's file, weeks later, with an error
message pointing nowhere near the macro. A bare `if` with no braces at all is worse: it
compiles, silently swallows the caller's `else`, and changes the meaning of their code.
`do { } while (0)` is a compound statement that *needs* its semicolon, so `if (x)
KASSERT(y); else z();` parses as written. The `while (0)` costs nothing — every compiler
folds it away at every optimisation level.

**`if (!(cond)) [[unlikely]]`**
```cpp
        if (!(cond)) [[unlikely]] {
```
The inner parentheses around `cond` are mandatory: `KASSERT(a || b)` without them expands to
`!a || b`, a different expression that will happily pass while the invariant is broken.
`[[unlikely]]` is the C++20 branch hint — it lays the panic call out off the hot path, so
the common case is a compare and a not-taken branch with no cache pressure from the call
sequence. It is what makes leaving `KASSERT_ALWAYS` in release genuinely cheap.

**The panic call**
```cpp
            panic("assertion failed: %s\n  at %s:%d", #cond, __FILE__,
                  __LINE__);
```
`#cond` is the **stringification operator**: the preprocessor replaces it with a string
literal of the argument's source text, *before* that argument is macro-expanded.
`KASSERT(is_aligned(addr, PAGE_SIZE))` prints `assertion failed: is_aligned(addr,
PAGE_SIZE)` — the expression you wrote, not `((addr) & (0x1000 - 1)) == 0`. That is what
makes a failure self-explanatory without opening the file.

`__FILE__` expands to the source path as the compiler saw it, `__LINE__` to an `int` (hence
`%d`). Both are substituted at the point of expansion, which is the *call site* rather than
this header, because macro arguments and predefined macros expand where the macro is used.
That is the whole mechanism by which a macro defined in one file reports a line number in
another. One build-system interaction: `__FILE__` would embed the container's
`/os/kernel/...` path, and `-ffile-prefix-map` (already set for reproducibility,
[[08 - Build System]]) normalises it, so panic output is identical on your machine, your
teammate's macOS box, and CI.

**The release expansion**
```cpp
#  define KASSERT(cond)                                                        \
      do {                                                                     \
          (void)sizeof((cond));                                                \
      } while (0)
```
Three requirements are met at once. *The condition must not be evaluated:* `sizeof` is an
unevaluated operand — the compiler types the expression and discards it, generating no
code, and a function call inside it is never emitted. (This is also the mechanical reason
side effects in an assert are a bug: they simply disappear.) *The condition must still be
compiled:* it is parsed and fully type-checked, so a renamed variable breaks the release
build immediately instead of lying in wait. *It must not warn:* the obvious alternative,
`#define KASSERT(cond) ((void)0)`, discards the condition text entirely, and a variable that
only the assert reads then becomes unused. Under `-Wall -Werror`:

```
warning: unused variable 'only_used_by_assert' [-Wunused-variable]
```

and the release build fails. With the `sizeof` form the variable is still named and still
counts as used. The `(void)` cast discards the `size_t` result and keeps `-Wunused-value`
quiet. The one restriction is that the condition must have a type `sizeof` accepts, so not
`void` — and since an assert condition must be contextually convertible to `bool` anyway,
this never comes up.

**The `NDEBUG` switch.** `NDEBUG` is the standard C and C++ release macro, and CMake adds
`-DNDEBUG` to `CMAKE_CXX_FLAGS_RELEASE` and `..._RELWITHDEBINFO` by itself. Keying off it
means behaviour follows `BUILD_TYPE` with no extra plumbing and no project-specific macro
for a newcomer to get wrong. Defining `KASSERT` *as* `KASSERT_ALWAYS` in debug — one
definition, not two copies — means the two can never drift.

---

### `kernel/lib/panic.cpp`

The implementation: output plumbing, a minimal formatter, register capture, the frame walk,
and the eight-step sequence.

```cpp
// kernel/lib/panic.cpp — the kernel's last words.
//
// Rules that apply to every line in this file:
//   * never allocate            (there is no heap until Phase 4)
//   * never take a lock         (the lock may be the broken thing)
//   * never lean on the stack   (the stack may be the broken thing)
//   * never dereference a pointer that has not been range-checked
//   * never return

#include <kernel/panic.hpp>

#include <kernel/serial.hpp>   // serial_putc() — from Stage 0.6

#include <cstdarg>
#include <stddef.h>
#include <stdint.h>

// Exported by the linker script (Stage 0.4); used to sanity-check return
// addresses. Check linker.ld for the exact symbol names.
extern "C" const char __text_start[];
extern "C" const char __text_end[];

namespace {

constexpr uintptr_t KERNEL_SPACE_MIN = 0xFFFF800000000000ULL;
constexpr unsigned  MAX_FRAMES       = 32;
constexpr size_t    CAPTURE_BYTES    = 4096;

constexpr char HEX_DIGITS[] = "0123456789ABCDEF";
constexpr char BANNER[] = "\n================= KERNEL PANIC =================\n";
constexpr char FOOTER[] = "================================================\n";

struct Regs {
    uint64_t rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
    uint64_t rflags, cr2, cr3, rip;
};

// Static, not a local: (a) the stack may be the corrupted thing, and (b) a
// static has a link-time address, so each capture below is a plain store that
// needs no scratch register. See the notes.
Regs g_regs;

char      g_capture[CAPTURE_BYTES];   // replayed to the console at step 7
size_t    g_capture_len;
PanicSink g_console;                  // null until Phase 1 registers one
PanicHook g_log_dump;                 // null until Stage 1.5 registers one
bool      g_in_panic;                 // re-entrancy guard

// ---------------------------------------------------------------- output ---

void put(const char* s, size_t n) {
    for (size_t i = 0; i < n; ++i)
        serial_putc(s[i]);
    for (size_t i = 0; i < n && g_capture_len < CAPTURE_BYTES; ++i)
        g_capture[g_capture_len++] = s[i];
}

void put(const char* s) {
    size_t n = 0;
    while (s[n] != '\0')
        ++n;
    put(s, n);
}

void put_hex(uint64_t v, unsigned digits) {
    char buf[16];
    for (unsigned i = 0; i < digits; ++i)
        buf[digits - 1 - i] = HEX_DIGITS[(v >> (4 * i)) & 0xF];
    put(buf, digits);
}

void put_hex_min(uint64_t v) {
    unsigned digits = 1;
    for (uint64_t t = v; t >= 16; t >>= 4)
        ++digits;
    put_hex(v, digits);
}

void put_dec(uint64_t v) {
    char rev[20];                       // 20 digits is the widest uint64_t
    unsigned n = 0;
    do {
        rev[n++] = static_cast<char>('0' + (v % 10));
        v /= 10;
    } while (v != 0);

    char out[20];
    for (unsigned i = 0; i < n; ++i)
        out[i] = rev[n - 1 - i];
    put(out, n);
}

// -------------------------------------------------------------- formatter --

void vformat(const char* fmt, va_list ap) {
    for (const char* p = fmt; *p != '\0'; ++p) {
        if (*p != '%') {
            put(p, 1);
            continue;
        }

        ++p;
        bool wide = false;
        while (*p == 'l' || *p == 'z') {   // %ld, %llx, %zu — all 64-bit here
            wide = true;
            ++p;
        }

        switch (*p) {
        case '\0':                          // trailing '%': do not run off the end
            put("%", 1);
            return;
        case 's': {
            const char* s = va_arg(ap, const char*);
            put(s != nullptr ? s : "(null)");
            break;
        }
        case 'c': {
            const char c = static_cast<char>(va_arg(ap, int));
            put(&c, 1);
            break;
        }
        case 'd':
        case 'i': {
            const int64_t v = wide ? va_arg(ap, long)
                                   : static_cast<int64_t>(va_arg(ap, int));
            if (v < 0) {
                put("-", 1);
                put_dec(static_cast<uint64_t>(-(v + 1)) + 1);   // safe at INT64_MIN
            } else {
                put_dec(static_cast<uint64_t>(v));
            }
            break;
        }
        case 'u':
            put_dec(wide ? va_arg(ap, unsigned long) : va_arg(ap, unsigned));
            break;
        case 'x':
            put_hex_min(wide ? va_arg(ap, unsigned long) : va_arg(ap, unsigned));
            break;
        case 'p':
            put("0x");
            put_hex(reinterpret_cast<uint64_t>(va_arg(ap, void*)), 16);
            break;
        case '%':
            put("%", 1);
            break;
        default:                            // unknown specifier: echo it back
            put("%", 1);
            put(p, 1);
            break;
        }
    }
}

// --------------------------------------------------------------- registers -

__attribute__((always_inline)) inline void capture_regs() {
    // GPRs first: the three reads below need a scratch register, and clobbering
    // a GPR we have not stored yet would corrupt the dump.
    __asm__ volatile("movq %%rax, %0" : "=m"(g_regs.rax) :: "memory");
    __asm__ volatile("movq %%rbx, %0" : "=m"(g_regs.rbx) :: "memory");
    __asm__ volatile("movq %%rcx, %0" : "=m"(g_regs.rcx) :: "memory");
    __asm__ volatile("movq %%rdx, %0" : "=m"(g_regs.rdx) :: "memory");
    __asm__ volatile("movq %%rsi, %0" : "=m"(g_regs.rsi) :: "memory");
    __asm__ volatile("movq %%rdi, %0" : "=m"(g_regs.rdi) :: "memory");
    __asm__ volatile("movq %%rbp, %0" : "=m"(g_regs.rbp) :: "memory");
    __asm__ volatile("movq %%rsp, %0" : "=m"(g_regs.rsp) :: "memory");
    __asm__ volatile("movq %%r8,  %0" : "=m"(g_regs.r8)  :: "memory");
    __asm__ volatile("movq %%r9,  %0" : "=m"(g_regs.r9)  :: "memory");
    __asm__ volatile("movq %%r10, %0" : "=m"(g_regs.r10) :: "memory");
    __asm__ volatile("movq %%r11, %0" : "=m"(g_regs.r11) :: "memory");
    __asm__ volatile("movq %%r12, %0" : "=m"(g_regs.r12) :: "memory");
    __asm__ volatile("movq %%r13, %0" : "=m"(g_regs.r13) :: "memory");
    __asm__ volatile("movq %%r14, %0" : "=m"(g_regs.r14) :: "memory");
    __asm__ volatile("movq %%r15, %0" : "=m"(g_regs.r15) :: "memory");

    uint64_t tmp;
    // Safe only because -mno-red-zone is set: there is nothing below rsp to
    // destroy. See 08 - Build System.
    __asm__ volatile("pushfq\n\tpopq %0" : "=r"(tmp) :: "memory");
    g_regs.rflags = tmp;
    __asm__ volatile("movq %%cr2, %0" : "=r"(tmp));
    g_regs.cr2 = tmp;
    __asm__ volatile("movq %%cr3, %0" : "=r"(tmp));
    g_regs.cr3 = tmp;
}

void put_reg(const char* name, uint64_t v, unsigned digits = 16) {
    put(name);
    put("=", 1);
    put_hex(v, digits);
}

void dump_regs() {
    put("\n");
    put_reg("RAX", g_regs.rax); put("  "); put_reg("RBX", g_regs.rbx);
    put("  "); put_reg("RCX", g_regs.rcx); put("\n");
    put_reg("RDX", g_regs.rdx); put("  "); put_reg("RSI", g_regs.rsi);
    put("  "); put_reg("RDI", g_regs.rdi); put("\n");
    put_reg("RSP", g_regs.rsp); put("  "); put_reg("RBP", g_regs.rbp);
    put("  "); put_reg("RFLAGS", g_regs.rflags, 8); put("\n");
    put_reg("R8 ", g_regs.r8);  put("  "); put_reg("R9 ", g_regs.r9);
    put("  "); put_reg("R10", g_regs.r10); put("\n");
    put_reg("R11", g_regs.r11); put("  "); put_reg("R12", g_regs.r12);
    put("  "); put_reg("R13", g_regs.r13); put("\n");
    put_reg("R14", g_regs.r14); put("  "); put_reg("R15", g_regs.r15); put("\n");
    put_reg("CR2", g_regs.cr2); put("  "); put_reg("CR3", g_regs.cr3); put("\n");
    put_reg("RIP", g_regs.rip); put("  <- call site of panic\n");
}

// --------------------------------------------------------------- backtrace -

struct StackFrame {
    const StackFrame* next;   // the caller's saved rbp
    uintptr_t         ret;    // the return address into the caller
};

bool frame_is_plausible(const StackFrame* f) {
    const uintptr_t a = reinterpret_cast<uintptr_t>(f);
    if (a < KERNEL_SPACE_MIN)                 return false;  // null/user/non-canonical
    if (a > UINTPTR_MAX - sizeof(StackFrame)) return false;  // would wrap
    if ((a & 0x7) != 0)                       return false;  // misaligned
    return true;
}

bool text_is_plausible(uintptr_t ret) {
    const uintptr_t lo = reinterpret_cast<uintptr_t>(__text_start);
    const uintptr_t hi = reinterpret_cast<uintptr_t>(__text_end);
    return ret >= lo && ret < hi;
}

void print_backtrace(const StackFrame* frame) {
    put("\nBacktrace:\n");

    for (unsigned i = 0; i < MAX_FRAMES; ++i) {
        if (!frame_is_plausible(frame))
            break;                              // validate BEFORE dereferencing

        const uintptr_t   ret  = frame->ret;
        const StackFrame* next = frame->next;

        if (!text_is_plausible(ret))
            break;

        put("  #"); put_dec(i); put("  0x"); put_hex(ret, 16); put("\n");

        if (reinterpret_cast<uintptr_t>(next) <= reinterpret_cast<uintptr_t>(frame))
            break;                              // stacks grow down: must ascend
        frame = next;
    }
}

[[noreturn]] void halt_forever() {
    for (;;)
        __asm__ volatile("cli\n\thlt" ::: "memory");
}

}  // namespace

// ------------------------------------------------------------ public API ---

void panic_set_console_sink(PanicSink sink)    { g_console = sink; }
void panic_set_log_dump(PanicHook hook)        { g_log_dump = hook; }
void panic_write(const char* text, size_t len) { put(text, len); }

[[noreturn]] void panic(const char* fmt, ...) {
    // 1. Nothing may interrupt what follows.
    __asm__ volatile("cli" ::: "memory");

    // A panic inside a panic adds nothing and risks a triple fault.
    if (g_in_panic)
        halt_forever();
    g_in_panic = true;

    // Capture now; print at step 4.
    capture_regs();
    g_regs.rip = reinterpret_cast<uint64_t>(__builtin_return_address(0));

    // 2. Serial, unconditionally, before anything that can fail.
    put(BANNER, sizeof(BANNER) - 1);

    // 3. The message.
    va_list ap;
    va_start(ap, fmt);
    vformat(fmt, ap);
    va_end(ap);
    put("\n", 1);

    // 4. Registers — pure register reads, cannot fault.
    dump_regs();

    // 5. Backtrace — the first step that dereferences memory.
    print_backtrace(static_cast<const StackFrame*>(__builtin_frame_address(0)));

    // 6. Recent log lines — only once Stage 1.5 registers a dump hook.
    if (g_log_dump != nullptr) {
        put("\nRecent log:\n");
        g_log_dump();
    }

    put(FOOTER, sizeof(FOOTER) - 1);

    // 7. The screen, if there is one. Last, because it is the most code.
    if (g_console != nullptr)
        g_console(g_capture, g_capture_len);

    // 8. Park the core.
    halt_forever();
}
```

#### Line by line

**The header comment.** Not decoration — it is the review checklist for this file. Every
future change gets checked against it, because the constraints are invisible from the code
and each one is a way to turn "the kernel panicked" into "the kernel hung".

**Includes and linker symbols**
```cpp
#include <kernel/serial.hpp>   // serial_putc() — from Stage 0.6

extern "C" const char __text_start[];
extern "C" const char __text_end[];
```
`serial_putc` is the only thing this file needs from outside. Stage 0.6 defines it in
`kernel/drivers/char/serial.cpp`; put the declaration in `kernel/include/kernel/serial.hpp`
so it is a declared cross-subsystem interface ([[07 - Repository Layout]]) rather than an
`extern` smuggled into a `.cpp`. If you put it elsewhere, include that instead.

The linker symbols are declared as **arrays**, not pointers. `extern const char
__text_start[]` means "the symbol's address is the value I want". Writing `extern const
char* __text_start` instead reads eight bytes *from* that address and uses them as a
pointer — a completely different and wrong number. It is a classic mistake and the symptom
is a backtrace that mysteriously never prints any frames.

`<cstdarg>` supplies `va_list`; it is a freestanding header provided by the compiler, not a
C library, so it is legal here ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]).

**Constants**
```cpp
constexpr uintptr_t KERNEL_SPACE_MIN = 0xFFFF800000000000ULL;
constexpr unsigned  MAX_FRAMES       = 32;
constexpr size_t    CAPTURE_BYTES    = 4096;
```
`KERNEL_SPACE_MIN` is the HHDM base from [[06 - Architecture Overview]] and also the lowest
canonical higher-half address — the double duty from §4. `MAX_FRAMES` bounds the walk.
`CAPTURE_BYTES` is 4 KiB of `.bss`; a full report is roughly 700 bytes, so it holds the
report plus a log dump, and anything longer truncates on the console while serial still has
all of it.

**Why `g_regs` is static**
```cpp
Regs g_regs;
```
Two reasons, and the second is not obvious. A local would live on the stack, and the stack
may be the broken thing — stack overflow is exactly the kind of bug that gets you here. And
because `g_regs` has a link-time address, `movq %rax, g_regs+0` needs **no scratch
register**. If the destination were `regs.rax` reached through a reference, GCC would first
load the object's address into some register — quite possibly `rax` — and `movq %rax,
0(%rax)` would then store the *address* instead of the register you were capturing. Making
it static removes the whole class of problem. [[13 - Coding Standards]] rule 9 is satisfied
because `Regs` is trivially default-initialisable: no constructor runs, so nothing depends
on `.init_array`.

**`put` — the output primitive**
```cpp
void put(const char* s, size_t n) {
    for (size_t i = 0; i < n; ++i)
        serial_putc(s[i]);
    for (size_t i = 0; i < n && g_capture_len < CAPTURE_BYTES; ++i)
        g_capture[g_capture_len++] = s[i];
}
```
Serial first, always, in the same order as §4's step list. The second loop copies into the
replay buffer for step 7 — a copy, not a mirror, which is exactly why option A beats option
C in §3: if the console explodes at step 7, serial already received every byte. The bound in
the loop condition truncates an overlong report rather than writing past the buffer; this
function must not be the thing that corrupts memory. Note what `put` does *not* do: no
`\r\n` translation. Stage 0.6 put that inside `serial_putc` where it belongs, so the capture
buffer holds plain `\n` and the console does its own line handling.

**`put_hex` and `put_dec`**
```cpp
    for (unsigned i = 0; i < digits; ++i)
        buf[digits - 1 - i] = HEX_DIGITS[(v >> (4 * i)) & 0xF];
```
Fills from the least significant nibble backwards, so no reversal pass. `digits` must be
1–16 and every caller passes a literal. Fixed-width zero-padded output is deliberate:
aligned columns are scannable, and a value short by a digit is instantly visible as a
wrong-looking address. `put_dec` uses `do/while` rather than `while` so `v == 0` prints `0`
rather than nothing, and `rev[20]` because the widest `uint64_t`, 18446744073709551615, is
20 digits. Its 64-bit `/` and `%` compile to a single `div` instruction; on a 32-bit target
they would become calls to libgcc's `__udivdi3`, which you do not link — one of the quieter
dividends of [[ADR-0002 - Target x86_64 Not i686]].

**The formatter's `%` handling**
```cpp
        while (*p == 'l' || *p == 'z') { wide = true; ++p; }
        switch (*p) {
        case '\0':
            put("%", 1);
            return;
```
Length modifiers collapse to one flag because on LP64 `long`, `long long`, `size_t` and
`uintptr_t` are all 64 bits — `%lx`, `%llx` and `%zx` mean the same thing here; the loop
consumes `ll` as well as `l`. The `'\0'` case closes a real trap: `panic("done 100%")`.
Without it the `switch` falls into `default`, prints, and the loop's `++p` steps *past* the
terminating NUL to print whatever follows in `.rodata`. A format-string bug inside the panic
handler is exactly the thing that turns a diagnosable failure into a mystery.

```cpp
        default:
            put("%", 1);
            put(p, 1);
```
Unknown specifiers are echoed, not guessed — the safety valve for the `format` attribute
mismatch noted earlier. GCC accepts `%f` because it checks against real `printf`, and this
formatter has no floating point (nor may it — FP is banned in kernel context). Printing
`%f` is a legible bug report; guessing would consume the wrong number of variadic arguments
and garble everything after it.

```cpp
                put_dec(static_cast<uint64_t>(-(v + 1)) + 1);
```
`-INT64_MIN` is not representable as an `int64_t`, so the obvious `-v` is undefined
behaviour on exactly one input. Negating `v + 1` and adding one back after the unsigned
conversion stays in range for every value.

**`capture_regs` — GPR order is a correctness requirement**
```cpp
    __asm__ volatile("movq %%rax, %0" : "=m"(g_regs.rax) :: "memory");
    ...
    __asm__ volatile("pushfq\n\tpopq %0" : "=r"(tmp) :: "memory");
```
One statement per register, `"=m"` so the asm stores straight to memory. Two things are
relied on: `-mcmodel=kernel` with `-fno-pic` makes a static's address a plain displacement,
so this becomes `movq %rax, g_regs(%rip)` with no scratch register; and `"memory"` is on
every one of them per [[13 - Coding Standards]] rule 2 — an omitted clobber lets the
compiler reorder the stores, and it is the kind of bug that appears six months later when
an unrelated change alters inlining.

**All sixteen GPRs are captured before the `pushfq`, and that is not tidiness.** Those last
three reads use `"=r"`, so GCC allocates some general-purpose register as the destination
and clobbers it. If `cr2` were read before `r12` were stored and GCC picked `r12`, the dump
would show a control register's address where a callee-saved value belongs. Store first,
scratch afterwards.

`pushfq; popq` is the only way to read `rflags` — there is no `mov` form. Pushing inside
inline asm is safe **only** because `-mno-red-zone` is set: with the red zone enabled the
compiler may have live data in the 128 bytes below `rsp` and the push would silently destroy
it. That is the same flag [[14 - Debugging Playbook]] names as the first suspect for "random
corruption with no pattern", appearing here as a precondition rather than a bug. `cr2` holds
the faulting linear address of the most recent page fault and `cr3` the physical address of
the active PML4; both read with a plain `mov` in ring 0. `cr2` is stale at this stage —
nothing has faulted — but it costs one instruction and becomes the most important field in
the dump from Stage 2.3 onward.

**`always_inline`, and why the values are approximate**
```cpp
__attribute__((always_inline)) inline void capture_regs() {
```
A real call would perturb `rsp` and could shuffle values between registers before the first
store; forcing it inline puts the stores as close to `panic`'s entry as the compiler can
manage. It does not make the caller-saved registers meaningful. By the time any code inside
`panic` runs, `rdi` and `rsi` hold `fmt` and the first variadic argument and `rax` holds the
variadic register count the ABI requires — those are `panic`'s own values. The callee-saved
registers `rbx`, `rbp`, `r12`–`r15` still hold the *caller's* values, because that is what
callee-saved means: `panic` will save them if it uses them, but it has not yet. `rsp` is one
frame below the caller's.

`rip` is the one register with no `mov` form — you cannot read the instruction pointer
directly. Two ways to get one anyway. The general trick is a **local label**, taking the
address of a point in the current function:

```cpp
uint64_t here;
__asm__ volatile("leaq 0(%%rip), %0" : "=r"(here));   // address of the next instruction
```

The zero displacement is required; `lea (%rip), %rax` is not valid AT&T syntax. That gives
you a point inside `panic`, which is almost useless — you already know you are in `panic`.
What you want is the *caller's* address, so the code uses `__builtin_return_address(0)`
instead: the address `panic` will return to, which is the instruction after the call, and
therefore the value you feed `addr2line`. It is also why the printed `RIP` and backtrace
frame `#0` are the same number. Level `0` is the only safe argument; higher levels are what
the frame walk is for. Keep the label trick in mind for Phase 2, where a stub needs to
record where it is. All of this becomes exact there anyway, when the exception stub hands
`panic` a real register frame captured at the instant of the fault.

**The frame struct and the walk**
```cpp
struct StackFrame {
    const StackFrame* next;
    uintptr_t         ret;
};
```
A literal transcription of the §4 diagram: at `rbp+0` the caller's saved `rbp`, at `rbp+8`
the return address. The member order is fixed by the hardware convention, not by preference
— swapping them prints return addresses as frame pointers and vice versa.

```cpp
        if (!frame_is_plausible(frame))
            break;                              // validate BEFORE dereferencing

        const uintptr_t   ret  = frame->ret;
        const StackFrame* next = frame->next;
```
**This is the most important detail in the stage.** The check happens before the two loads,
not after, and everything the loop needs is read once into locals. Validate after reading —
or read `frame->ret` inside the `if` — and you have already touched the memory you were
about to reject; if it is unmapped the CPU raises a page fault, there is no handler, and the
machine triple-faults. You lose the panic message *and* the original bug becomes invisible,
because the only remaining symptom is the reboot loop this stage exists to eliminate.

```cpp
        if (reinterpret_cast<uintptr_t>(next) <= reinterpret_cast<uintptr_t>(frame))
            break;
```
Stacks grow downward, so each caller's frame sits at a *higher* address than its callee's.
Requiring strict ascent terminates a frame that points at itself or backwards — the shape a
corrupt `rbp` produces — in one iteration instead of thirty-two. Cast to `uintptr_t` first:
comparing pointers into unrelated objects is not something the language defines, and integer
comparison is what you actually mean.

The `MAX_FRAMES` bound is the second half of the safety story. The predicates catch
nonsense, but garbage that happens to be aligned, higher-half, ascending and pointing at
plausible `.text` can chain for a long time; thirty-two is far more than this kernel will
ever have, and *finite* is the property that matters. `text_is_plausible` is also how the
walk ends correctly: `kmain` was called by Limine, whose code is not in your `.text`, so the
first frame outside the kernel image stops it.

**`halt_forever`**
```cpp
[[noreturn]] void halt_forever() {
    for (;;)
        __asm__ volatile("cli\n\thlt" ::: "memory");
}
```
`hlt` stops the core until an interrupt, NMI, SMI or reset. With `IF` clear a maskable
interrupt cannot resume it, so the core genuinely parks: no instructions retired, and QEMU's
vCPU thread idles instead of burning a host core. `cli` sits inside the loop as well as at
step 1 so the loop is correct on its own terms — if anything ever resumes the core with
interrupts somehow enabled, the next iteration disables them again. The `for (;;)` satisfies
`[[noreturn]]`; no `__builtin_unreachable()` is needed because the compiler can already see
the loop never exits.

**Step 1 and the re-entrancy guard**
```cpp
    __asm__ volatile("cli" ::: "memory");

    if (g_in_panic)
        halt_forever();
    g_in_panic = true;
```
`cli` is one instruction with no memory access and cannot fail, which is exactly why it goes
first. Until Phase 2 *any* interrupt during the report is a triple fault; after Phase 2, an
interrupt handler that logs would interleave into the middle of the register dump and one
that panics would re-enter. Moving this even one line later leaves a window.

The guard is the backstop for everything frame validation cannot prove. If any part of the
report faults — and once Phase 2 routes faults into `panic`, it will call back in here — the
second entry does nothing and parks the core, so you keep whatever the first panic already
pushed out of the serial port, which is the part you needed. Without it the second panic
tries to print, faults in the same place, and recurses until the stack is gone or the
machine triple-faults.

A plain `bool`, not `volatile`: this is not concurrency, and [[13 - Coding Standards]] rule
3 is clear that `volatile` is for MMIO. On SMP (Phase 12) it becomes an atomic test-and-set,
and `panic` additionally has to IPI the other cores into a halt — otherwise one core writes
a careful report while three others keep corrupting the state it describes. The guard runs
before `capture_regs`, so its load and store use one scratch register first; that register is
caller-saved and was already destroyed by the call to `panic` — §4's table already marks it
untrustworthy — and keeping the *first* panic's registers is worth far more.

**Steps 2 and 3**
```cpp
    put(BANNER, sizeof(BANNER) - 1);
    va_list ap;
    va_start(ap, fmt);
    vformat(fmt, ap);
    va_end(ap);
```
`sizeof(BANNER) - 1` is the length without the NUL, computed at compile time — no `strlen`
walk and no dependency on a string function that does not exist yet. The leading `\n` inside
`BANNER` guarantees the banner starts on a fresh line even if the panic interrupted a
half-written log line. `va_start`/`va_end` must bracket the traversal, and `vformat` takes
the `va_list` rather than being variadic itself — the standard split, because a `va_list` can
only be walked once.

**Steps 6 and 7 — the guards**
```cpp
    if (g_log_dump != nullptr) { ... }
    if (g_console != nullptr)
        g_console(g_capture, g_capture_len);
```
Both are null throughout Phase 0, so both steps are skipped and panic works with nothing but
a serial port. This is the concrete form of "panic must work at step 5 of the initialisation
order, when only serial is up". The console replay is the last thing before halting and it
sends the whole buffer at once, so a fault in the framebuffer code costs nothing that has
not already left the machine.

---

### The build flag

```cmake
# cmake/KernelFlags.cmake — alongside the existing kernel flags.
# rbp must be a frame pointer, or the backtrace in panic.cpp is fiction.
-fno-omit-frame-pointer
```

Check the file for the exact variable the other flags are appended to.

At `-O1` and above GCC enables `-fomit-frame-pointer` by default: it frees `rbp` as a
general-purpose register and drops the two-instruction prologue. Everything still works —
except that `rbp` now holds an array index, or half a hash, and the walk treats it as a
pointer. Best case the predicates reject it and you print zero frames. Worst case it passes
all of them and you print a column of confident, wrong addresses that `addr2line` resolves
to real functions that were never on the stack. **That is the failure to fear,** because you
will believe it.

Debug builds must have this flag; this project sets it in Release too. The cost is one of
fifteen general-purpose registers — low single-digit percent, and effectively nothing on
code that is not register-starved. A backtrace you cannot trust in the build you actually
ship is not worth the register you saved.

---

## 6. How to verify

### Now, without booting

```sh
make                                    # clean under -Wall -Wextra -Werror
x86_64-elf-nm build/kernel.elf | grep -i ' panic'
```

Expected — `panic` present and `T`, a symbol in `.text`:

```
ffffffff80102b40 T panic
```

Confirm the frame-pointer flag reached every translation unit:

```sh
jq -r '.[].command' build/compile_commands.json | grep -c -- '-fno-omit-frame-pointer'
jq -r '.[].command' build/compile_commands.json | wc -l
```

The two numbers must match. Same check [[14 - Debugging Playbook]] prescribes for
`-mno-red-zone`, for the same reason: a flag set on *most* files produces a bug that only
appears in some backtraces. Then prove the prologue is really there:

```sh
x86_64-elf-objdump -d build/kernel.elf | grep -A2 '<kernel_init>:'
```

```
ffffffff80101a00 <kernel_init>:
ffffffff80101a00:  55                    push   %rbp
ffffffff80101a01:  48 89 e5              mov    %rsp,%rbp
```

If those two instructions are missing, the flag did not apply and nothing below will work.

### Booting it

Add `panic("test panic: %d", 42);` at the end of `kernel_init`, then `make run-serial`.
Expected — exactly this shape; the values will differ:

```
================= KERNEL PANIC =================
test panic: 42

RAX=0000000000000000  RBX=FFFFFFFF80210000  RCX=0000000000001000
RDX=0000000000000008  RSI=0000000000000000  RDI=FFFF8000DEADBEEF
RSP=FFFFFFFF801FFE40  RBP=FFFFFFFF801FFE80  RFLAGS=00000046
R8 =0000000000000000  R9 =0000000000000000  R10=0000000000000000
R11=0000000000000000  R12=0000000000000000  R13=0000000000000000
R14=0000000000000000  R15=0000000000000000
CR2=0000000000000000  CR3=000000000100A000
RIP=FFFFFFFF80101A2C  <- call site of panic

Backtrace:
  #0  0xFFFFFFFF80101A2C
  #1  0xFFFFFFFF801002F1
================================================
```

**Check 1 — QEMU does not reboot.** The banner appears once and stays. No second boot
message, no loop. `make run-serial` already passes `-no-reboot -no-shutdown`, so a reset
would make QEMU exit rather than loop — you should see neither. Wait a minute and confirm
nothing else is printed.

**Check 2 — the host CPU is idle.** In another terminal:

```sh
ps -o %cpu=,comm= -C qemu-system-x86_64
```
```
 0.3 qemu-system-x86_64
```

Under a percent or two. Pinned near 100 on one core means `hlt` is not executing or
interrupts are enabled in the halt loop, and you have a spin loop wearing a `hlt` costume.
(On Windows, the QEMU process's CPU column in Task Manager shows the same thing.)

**Check 3 — at least two plausible kernel-range addresses.** Every backtrace line must start
`0xFFFFFFFF8`, inside the kernel image ([[06 - Architecture Overview]]). One frame means the
walk stopped immediately — suspect the frame-pointer flag or the member order in
`StackFrame`. Zero frames means `frame_is_plausible` rejected the very first frame.

**Check 4 — the addresses resolve.**

```sh
x86_64-elf-addr2line -f -C -i -e build/kernel.elf 0xFFFFFFFF80101A2C
```
```
kernel_init
kernel/main.cpp:143
```

That must be the line that called `panic`. `-f` prints the function, `-C` demangles, `-i`
expands inlined frames. Backtrace entries are *return* addresses — the instruction after the
call — so when a call is the last instruction of a line the address can resolve to the
following line; pass `<addr> - 1` when you want the call site exactly. Stage 1.7 automates
all of this in-kernel.

**Check 5 — `KASSERT` reports the right place.** Temporarily add `KASSERT(1 == 2);` in a
known function:

```
================= KERNEL PANIC =================
assertion failed: 1 == 2
  at kernel/main.cpp:139
```

The expression text comes from `#cond`, the location from `__FILE__`/`__LINE__` at the call
site. If the file says `assert.hpp`, something is wrong with how you expanded the macro.

**Check 6 (optional, 30 seconds, worth doing once) — see what you replaced.** Comment out the
`panic()` call, put `*(volatile uint64_t*)0 = 1;` in its place, and add `-d int,cpu_reset
2> trace.log` to the QEMU command line. `trace.log` shows the fault chain from §2 — a `#PF`
(`v=0e`), then `#DF` (`v=08`), then the CPU reset with its register state. Without
`-no-reboot` the same run loops forever and prints nothing. Read the *first* exception;
everything after is cascade. Then put the panic back.

### Only checkable later

- **A CPU fault producing this output** — Stage 2.3, once exception handlers call `panic`
  with a real frame. Until then only explicit `panic()` and `KASSERT` reach it.
- **Function names instead of raw addresses** — Stage 1.7, which embeds the symbol table.
- **The `Recent log:` section** — Stage 1.5, when the ring buffer registers a dump hook.
- **The panic on screen** — Phase 1, when the console registers a sink.
- **Correct behaviour under `-smp 4`** — Phase 12: an atomic guard, and an IPI to stop the
  other cores.

- [ ] Builds clean with `-Wall -Wextra -Werror`
- [ ] `-fno-omit-frame-pointer` count equals the translation-unit count
- [ ] `push %rbp; mov %rsp,%rbp` present in a disassembled function
- [ ] Test panic prints banner, message, registers and backtrace over serial
- [ ] QEMU halts and does not reboot
- [ ] Host CPU usage under ~2%
- [ ] At least two backtrace addresses, all in `0xFFFFFFFF8...`
- [ ] `addr2line` resolves frame `#0` to the calling line
- [ ] `KASSERT(1 == 2)` prints the expression, file and line
- [ ] Test panic removed; the machinery stays

---

## 7. Common traps

**"The machine reboots and I see nothing — the exact behaviour panic was supposed to fix."**
You panicked inside the panic handler, almost always in the backtrace: a frame pointer
dereferenced before it was validated, or validated by a predicate that let an unmapped
address through. The resulting page fault has no handler, so the CPU escalates to a double
fault and then a triple fault and resets — throwing away the banner and message that were
already written. Fix in three parts: check every pointer *before* the load, never after;
bound the walk at 32 frames; and add the `g_in_panic` guard so a second entry parks the core
immediately. Diagnose by commenting out `print_backtrace` — if the message and registers
appear, the walk is your problem.

**"Panic output is interleaved or scrambled, with fragments of other lines inside the
register dump."** Missing or late `cli`. An interrupt arrived mid-report and its handler
printed. Once interrupt handlers exist this is the ordinary case, not a rare one. `cli` must
be the first statement in `panic` — before the guard, before the capture, before anything.
Seeing this *before* Phase 2 means a different problem: you should not be receiving
interrupts at all yet.

**"QEMU pegs a host core at 100% after the panic."** `hlt` without `cli` in the halt loop.
`hlt` resumes on the next interrupt, so with `IF` set the CPU wakes on every timer tick and
immediately halts again — a very expensive spin loop. `cli; hlt` parks the core properly.
The same symptom appears if you wrote `for (;;) {}` with no `hlt`, or if a `[[noreturn]]`
function fell off the end and the compiler emitted a jump back into it. Confirm with `ps -o
%cpu= -C qemu-system-x86_64`, not by feel.

**"The backtrace prints nonsense addresses — or worse, plausible ones that are wrong."**
`-fno-omit-frame-pointer` is missing, so at `-O1` and above `rbp` is an ordinary
general-purpose register and you are walking whatever integer it held. Zero frames is the
lucky outcome; the dangerous one is a full column of addresses that `addr2line` resolves to
real functions that were never on the stack, and an afternoon spent investigating the wrong
subsystem. Verify with the `compile_commands.json` grep in §6, not by reading the CMake
file. The same symptom appears in Phase 2 for a different reason: hand-written assembly
stubs do not build frames, so a backtrace through an interrupt entry point stops at the
boundary. That one is expected, and the fix is to have the stubs push a synthetic frame.

**"Panic works for me and faults on a build without a console."** An unguarded console path
— calling the framebuffer sink without the `g_console != nullptr` check, or dereferencing a
`BootInfo` framebuffer field before `boot_info` has been collected. Panic must be fully
functional at step 5 of the initialisation order in [[06 - Architecture Overview]], one step
before the console exists. Every optional output channel is a null-checked function pointer,
and the check is not optional. Test it the easy way: panic works in Phase 0 today with no
console registered at all. If you ever have to add a console to make panic work, you have
inverted the dependency.

**"A user program can crash the kernel."** You asserted something the outside world
controls: `KASSERT(fd < MAX_FD)` on a syscall argument, `KASSERT(len < MAX_LEN)` on a
user-supplied length, `KASSERT` on a field read out of a filesystem image or a network
packet. Each is a one-line denial of service any unprivileged program can trigger, and later
a security bug rather than merely an availability one. Return `-EBADF`, `-EINVAL`,
`-EFAULT`; drop the packet; reject the image. Assert only what your own code guarantees. In
review the question is always §3's: *can anything outside this kernel's source make this
false?*

**"Panic prints nothing at all and the machine hangs — no banner, no reboot."** Two
candidates. Either the panic happened before `serial_init()` ran, so the UART's divisor is
unset and the bytes go nowhere — that is why serial is step 1 of the initialisation order and
why [[Stage 0.3 - Freestanding C++ and kmain]] uses a register pattern and `hlt` for earlier
failures. Or `serial_putc` polls the line-status register in an unbounded loop on a machine
with no UART; Stage 0.6 specifies recording the loopback self-test result and not hanging,
and `panic` is the function where skipping that bites. A panic that hangs is
indistinguishable from the deadlock you were trying to diagnose.

**"The release build fails with unused-variable errors after I added asserts."** The release
`KASSERT` discarded the condition text. `#define KASSERT(cond) ((void)0)` produces `warning:
unused variable 'x' [-Wunused-variable]`, which `-Werror` turns into a build failure, for any
variable only an assert reads. Use the `(void)sizeof((cond))` form.

**"A `KASSERT` was doing real work and the release build broke."** Side effects in an assert
condition. `KASSERT(refcount_dec(obj) == 0)` decrements in debug and does nothing in
release, so the bug does not reproduce in the build you develop in. Conditions must be pure
reads; if a check matters enough to run in release, that is what `KASSERT_ALWAYS` is for.

---

## 8. What this unlocks

Everything you will debug for the next fifteen phases. Stage 2.3's exception handlers are
thin wrappers that decode the fault and call this `panic` — that is where the deliverable
becomes complete and a genuine CPU fault produces this output instead of a reset. Every
Tier-2 self-test in [[09 - Testing Strategy]] is a `KASSERT` in kernel context, so the whole
middle tier of the test pyramid rests on this file. Stage 1.5 hooks the log ring buffer into
step 6, Stage 1.7 replaces raw addresses with function names and line numbers, and
[[Phase 1 - Overview|Phase 1]]'s console registers itself as the step-7 sink — all additive
changes to code written here.

Done wrong, the failures are quiet. An unbounded or unvalidated frame walk turns every
future fault back into the silent reboot loop from §1, and you will blame the subsystem you
were working on rather than the panic handler. A missing `-fno-omit-frame-pointer` gives
backtraces that are confidently wrong. And asserting on user input builds a denial of service
into the syscall layer that nobody notices until [[Phase 6 - Overview|Phase 6]] runs the
first untrusted program.

---

## 9. Reading

- OSDev — *Stack Trace*: <https://wiki.osdev.org/Stack_Trace>
  The frame-pointer walk, with the same struct and the same warning about validating
  pointers before dereferencing them.
- OSDev — *Double Fault*: <https://wiki.osdev.org/Double_Fault> — the escalation rules from
  §2, including which exception pairs actually escalate.
- OSDev — *Triple Fault*: <https://wiki.osdev.org/Triple_Fault> — short, and it explains why
  there is no handler to miss.
- OSDev — *Kernel Debugging*: <https://wiki.osdev.org/Kernel_Debugging> — broad survey; the
  part about what survives a reset is what matters here.
- Intel SDM Vol. 3A, Chapter 6, *Interrupt and Exception Handling*:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
  Table 6-5 is the definitive statement of which fault combinations produce a double fault.
- GCC — *Extended Asm*: <https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html>
  Constraints and clobbers, including why `"memory"` is not optional.
- GCC — *Return Address* built-ins:
  <https://gcc.gnu.org/onlinedocs/gcc/Return-Address.html> — `__builtin_return_address`,
  `__builtin_frame_address`, and their caveats above level 0.
- System V AMD64 ABI: <https://gitlab.com/x86-psABIs/x86-64-ABI> — the stack frame and
  register-saving conventions the walk relies on.
- [[13 - Coding Standards]] — rule 7 is §3's assert-versus-return decision in canonical
  form; rule 2 for the `"memory"` clobber; rule 3 for why the guard is not `volatile`.
- [[14 - Debugging Playbook]] — where the target panic format is specified, and the symptom
  table this stage makes usable.
- [[09 - Testing Strategy]] — why `KASSERT` has to exist before the tests do.
- [[06 - Architecture Overview]] — the initialisation order that dictates panic's output
  ordering.

Next: **[[Stage 0.8 - The Build System]]**

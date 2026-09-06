# Stage 1.5 — The Log Ring Buffer and Levels

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `kernel/include/kernel/log.hpp`, `kernel/lib/log.cpp`
**Deliverable:** a `dmesg`-style history with severity levels — the last 256 lines survive a scroll, are replayed to the console when it initialises late, and are dumped by `panic()`.

---

## Progress

- [ ] Write `kernel/include/kernel/log.hpp` — `LogLevel`, the ring geometry, the sink type, the API
- [ ] Write `kernel/lib/log.cpp` — the slot struct, the `.bss` state, `log_write_n`
- [ ] Add `log_replay` and `log_register_sink`, with the replay-on-registration behaviour
- [ ] Add `log_dump_last` and register it as the panic hook from `log_init`
- [ ] Add `log_set_level`, `log_set_level_by_name`, and `log_parse_cmdline`
- [ ] Add `cmdline[]` to `BootInfo` and copy it in `boot_info.cpp`
- [ ] Add `serial_log_sink` in `kernel/drivers/char/serial.cpp` and register it in `kernel_init`
- [ ] Call `log_init()` immediately after `serial_init()`, before anything else
- [ ] Register the console sink at the end of `console_init()` and watch history appear on screen
- [ ] Write `tests/unit/test_log.cpp` — the Tier-1 wraparound test from [[09 - Testing Strategy]]
- [ ] Verify the ring is in `.bss` and `kernel.elf` did not grow by 64 KiB
- [ ] Boot the `(verbose)` menu entry and confirm `loglevel=debug` changes what is printed
- [ ] Trigger a panic and confirm the `Recent log:` section is populated
- [ ] Committed with a message like `feat(lib): log ring buffer with severity levels`

---

## 1. Why this stage exists

You now have a console that scrolls ([[Phase 1 - Overview|Stage 1.3]]) and a back buffer that makes scrolling fast ([[Phase 1 - Overview|Stage 1.4]]). Both of those *destroy output*. Scrolling means the top line is discarded, and with a back buffer it is discarded from normal RAM rather than from the framebuffer — the same loss, faster. Twenty-five lines into a boot, the message that explained what the physical memory manager decided is gone, and there is no way to get it back.

That is survivable while the only thing you print is a banner. It stops being survivable in [[Phase 4 - Overview|Phase 4]], when the interesting output is forty lines of memory-map parsing followed by a fault. The fault message is on screen; the forty lines that would explain it are not.

There is a second, worse loss, and it is the one the phase overview names: **the console does not exist yet when the most fragile code runs.** Look at the initialisation order in [[06 - Architecture Overview]]. Serial is step 1, the `BootInfo` copy is step 2, the GDT and IDT are steps 3 and 4, and the framebuffer console is step 6. Steps 2 through 5 are exactly where early boot fails — a null Limine response, a bad descriptor, a wrong offset — and none of them can print to a screen, because there is no screen. Today those messages go to serial and nowhere else. On a machine with no serial port, which is most laptops built after 2010, they go nowhere at all.

Finally, [[Stage 0.7 - Panic and KASSERT]] built a panic handler whose step 6 is "dump the recent log", guarded by `if (g_log_dump != nullptr)`. Nothing has ever registered that hook, so the most valuable section of a panic report — *what the kernel was doing in the seconds before it died* — has been empty since Phase 0. This stage fills it.

The fix for all four is the same object: a fixed block of memory that every log call writes to **first**, and output devices read from **second**.

---

## 2. The concept

### A ring buffer

A ring buffer is a fixed-size array plus a counter, used as if it were an infinite list. You write to `array[counter % CAPACITY]` and increment the counter. When the counter passes `CAPACITY` the modulo wraps back to slot 0 and you overwrite the oldest entry. Nothing moves, nothing is allocated, nothing is freed.

```
  CAPACITY = 8, head = 5 (five lines written, none dropped yet)

  slot:     0      1      2      3      4      5      6      7
         ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
         │ ln 0 │ ln 1 │ ln 2 │ ln 3 │ ln 4 │      │      │      │
         └──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
           ^oldest                            ^ head % 8 = next write

  ...three more lines...  head = 11

  slot:     0      1      2      3      4      5      6      7
         ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
         │ ln 8 │ ln 9 │ ln10 │ ln 3 │ ln 4 │ ln 5 │ ln 6 │ ln 7 │
         └──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
                          ^ head % 8 = 3       lines 0-2 are gone
                            (also the oldest live line)

  live range = [head - CAPACITY, head) = [3, 11)
  lines lost = head - CAPACITY          = 3
```

Two properties of that picture do all the work later. First, **`head` is a count, not an index** — it is the number of lines ever written, and it never resets. Second, once you have `head`, everything else is arithmetic with no special cases: the oldest live line is `head - CAPACITY` (or `0` if that would be negative), the newest is `head - 1`, "the last twenty lines" is `[head - 20, head)`, and the number of lines you have lost is `head - CAPACITY`. No `full` flag, no `tail` pointer, no ambiguity about whether `head == tail` means empty or full.

### Why a kernel logs to memory first and to devices second

A `printf` in a userspace program writes into a buffer that the C library eventually flushes to a file descriptor. That indirection exists for speed. In a kernel it exists for three harder reasons.

**A memory write cannot fail.** `slot.text[i] = msg[i]` is a `mov`. It has no error path, no return code, no device that might be absent. Compare a UART write, which polls a status register in a loop and hangs forever on a machine whose UART is wedged ([[Stage 0.6 - Serial Output]] §7), or a framebuffer write, which needs a valid mapping, a correct pitch, and a rasterised font.

**A memory write cannot block.** Serial at 115200 baud moves about 11,000 characters per second — roughly 87 µs per character, which [[Stage 0.6 - Serial Output]] measures out to a wall-clock cost you can see. Writing 252 bytes to RAM is nanoseconds. That difference is what makes it safe to put a log call anywhere: inside a fault handler, inside the scheduler, inside a spinlock critical section. If logging meant "wait for the UART", most of the interesting places in the kernel could not log at all.

**A memory write works before any device is initialised.** The ring is a static array. It is valid the instant the kernel image is loaded — before `serial_init()`, before the console, before the memory manager. That is what makes "log before console" possible, and it is the property the phase overview is naming.

So the design is a fan-out with the memory write as the trunk:

```
   log_write(Info, "pmm: 512 MiB usable")
            │
            ▼
   ┌──────────────────────┐
   │ filter: level >= threshold?          │  ← one compare
   └──────────────────────┘
            │ yes
            ▼
   ┌──────────────────────────────────────┐
   │ RING  (always, unconditionally)      │  ← cannot fail, cannot block
   │ g_lines[head % 256], then head++     │     works at init step 0
   └──────────────────────────────────────┘
            │
            ▼  fan out to whatever exists right now
   ┌────────┴──────────┬────────────────┬───────────────┐
   │                   │                │               │
 serial sink      console sink      (Phase 9:       (Phase 14:
 (from step 1)    (from step 6)      disk log)       net log)
                       ▲
                       └── registered LATE, and gets the whole
                           history replayed at registration
```

The replay arrow is the whole trick. A sink registered at step 6 immediately receives every line written since step 0, in order, as if it had been present the whole time. Nothing was lost; it was merely deferred.

### Severity levels

A level is a small integer attached to each line that answers "how much does this matter". It buys three things:

1. **Filtering.** A threshold discards anything below it *before* it costs anything, so `Trace` logging can be left permanently in the source and cost one compare per call in a normal boot.
2. **Marking.** `[ERROR] ahci: port 0 reset timeout` is scannable in a 3,000-line serial log in a way that unlabelled text is not.
3. **Routing, later.** A `Panic`-level line can force a synchronous flush; an `Error` can be the thing a Tier-3 test greps for.

The order matters, and we number ours *upwards* with severity — `Trace = 0` through `Panic = 5` — so the filter reads `level >= threshold`. Syslog and Linux number them the other way (`LOG_EMERG = 0`, `LOG_DEBUG = 7`), which makes every filter comparison read backwards from the way you think about it. Ours is chosen so that the highest severity can never be filtered out by any threshold, and so that the all-zero `.bss` state means "record everything" — which is exactly what you want in the window before anything has configured the log.

### What is *not* safe here yet, and the seam that makes it fixable

Today `log_write` is atomic by construction: one core, interrupts disabled until [[Phase 2 - Overview|Phase 2]], no preemption until [[Phase 5 - Overview|Phase 5]]. Nothing can interleave with it, so no lock is needed and none is written.

That stops being true in three steps, and it is worth knowing now which step breaks what:

| From | Hazard | Symptom |
|---|---|---|
| Phase 3 — interrupt handlers | An IRQ handler logs while `log_write` is halfway through a slot | One slot holds half of two messages |
| Phase 5 — preemption | The same, from the scheduler | The same |
| Phase 12 — SMP | Two cores claim the same slot from the same `head` | One line silently lost, one torn |

There is no `std::atomic` available — there is no libstdc++ in the toolchain ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]) — and [[13 - Coding Standards]] rule 3 forbids papering over it with `volatile`. **Do not attempt to solve this now.** Real locking is [[Phase 5 - Overview|Phase 5]]; SMP safety is [[Phase 12 - Overview|Phase 12]].

What you *must* do now is leave the seam in the right place, because the shape of the data structure decides whether the later fix is four lines or a rewrite. Four properties of the design below exist for that reason:

- **`++g_head` is the single publish point.** Everything a reader needs is stored in the slot *before* the increment. In Phase 12 that increment becomes a release-ordered atomic and the payload stores become the thing it publishes. (GCC's `__atomic_*` builtins are compiler intrinsics, not a library, and for a naturally-aligned 64-bit value on x86_64 they compile to inline `lock`-prefixed instructions — so the eventual fix needs no libatomic and no libstdc++.)
- **`g_head` is one 64-bit variable that only ever increases.** A reader can snapshot it and know exactly what it is allowed to read. A `head`/`tail`/`full` triple could not be snapshotted atomically.
- **The critical section is bounded and does no I/O.** The longest thing `log_write` does is copy at most 252 bytes. That makes a plain IRQ-save spinlock a legitimate answer in Phase 5 — no risk of sleeping under a lock ([[13 - Coding Standards]] rule 4).
- **Sinks are called after the publish, outside the slot write.** So the lock, when it arrives, does not need to cover the sink callbacks — which is essential, because a sink talks to a device.

---

## 3. Design decisions and tradeoffs

### Decision: does a log call write to memory first, or straight to the device?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — ring first, then fan out to registered sinks (chosen)** | `log_write` stores the line, then calls whatever sinks exist | 64 KiB of `.bss`; one indirection per sink | ✅ |
| B — write straight to serial and console | `log_write` calls `serial_write` and `console_write` directly | No history; nothing works before the devices do; the call blocks | ❌ |
| C — write to the device, and keep a copy for `dmesg` | Device first, ring second | Same blocking cost, and the ring is now the *second* thing to fail | ❌ |

**Why A.** Three properties, and each one is decisive on its own. The ring works at initialisation step 0 when no device exists, so early boot is loggable at all. The ring cannot block, so a log call is cheap enough to sit inside an interrupt handler or a lock. And the ring **survives** — the line is in memory when the console scrolls it away, when the screen is cleared, and when the kernel panics thirty lines later. B has none of these. The indirection is the entire feature, not a cost of it.

**Why not B.** It inverts the dependency. `log_write` would have to know about `serial.cpp` and `fbcon.cpp`, which are `drivers/` — a layer *above* `lib/` in the subsystem map in [[06 - Architecture Overview]], and calling upward is the one thing the dependency rule forbids. More concretely: a message logged at step 2 of the init order is written to a console that does not exist for another four steps, so it is simply lost, and there is no mechanism by which it could ever be recovered. That is the bug this stage exists to remove.

**Why not C.** Ordering matters more than it looks. If the device write comes first and it hangs — a wedged UART polling a line-status register that never changes — the ring write never happens, and you have lost the line *and* the machine. The order in A means the evidence is banked before anything risky is attempted. This is the same reliability-gradient argument as [[Stage 0.7 - Panic and KASSERT]] §4: put each step after everything it could destroy.

**When B would be right.** In a bootloader, or in a pre-`main` stub, where there is no memory you can rely on and the entire program is fifty lines. Also for a genuine last-resort channel: `panic()` deliberately writes to serial synchronously and does *not* go through this ring, because at that moment the ring is one of the things that might be corrupt. A system can have both, and this one does.

---

### Decision: fixed-size static ring, or a growable buffer?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — fixed static array in `.bss` (chosen)** | `LogLine g_lines[256];` at namespace scope | 64 KiB reserved forever; old lines are lost | ✅ |
| B — grow on demand | `kmalloc` a bigger buffer when full | **Does not exist** — no heap until Phase 4 | ❌ |
| C — a small static ring that a Phase 4 hook replaces with a heap one | Static now, `kmalloc` later | Two code paths, a migration, and a pointer that changes under readers | ❌ |

**Why A.** It is forced, and it is also correct. Forced: the heap is step 10 of the initialisation order and the log is needed at step 0, so a heap-backed log could not exist during the entire window it is most needed. Correct independently of that: an unbounded log is a kernel that runs out of memory because it was talking about running out of memory, and the failure mode of a growable buffer under a fault storm — a page fault handler that logs, faulting again — is a machine that dies of logging.

**Sizing.** The two numbers multiply, so pick them deliberately:

| Knob | Value | Reasoning |
|---|---|---|
| Lines | 256 | Deep enough to cover a whole boot; a power of two so `% 256` is an `and` |
| Text bytes per line | 252 | Plus 4 bytes of metadata makes a 256-byte slot exactly |
| Total | 64 KiB | `.bss`, so **zero bytes in `kernel.elf`** |

Two hundred and fifty-six lines is chosen against a real workload: a Phase 4 boot with `loglevel=debug` prints roughly 120 lines, so the whole boot fits and a panic dump can still reach back to the beginning. 252 characters is chosen so that truncation is rare rather than routine — a page-fault report with an address, an error code and a symbol name runs 80 to 120 characters, and 252 leaves headroom without doubling the buffer. If you want it smaller, change `LOG_LINES`; it is one constant and a `static_assert` will tell you if you break the power-of-two requirement.

**Why not B.** It cannot be written. There is no allocator.

**Why not C.** Tempting in Phase 4 and still wrong. The migration has to copy a live ring while `head` is advancing, every future reader has to load a pointer that can change, and you have bought exactly one thing: more history. You can have more history today by changing `256` to `1024` and spending 256 KiB of `.bss`, with no code at all.

**When B or C would be right.** When log volume is a product feature rather than a debugging aid — a server whose operators expect a week of retention. That kernel writes the ring to *disk* on a timer rather than growing it in RAM, which is [[Phase 9 - Overview|Phase 9]] at the earliest and is an additional sink, not a different ring.

---

### Decision: what happens when the ring is full?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — overwrite the oldest (chosen)** | `head % CAPACITY` lands back on slot 0 and keeps going | The oldest lines are lost | ✅ |
| B — stop when full | Once `head == CAPACITY`, drop new lines | The *newest* lines are lost | ❌ |
| C — drop by level | Overwrite the lowest-severity line rather than the oldest | A scan per write; timeline holes; still lossy | ❌ |

**Why A.** The question is not "which lines do I lose" but "which lines do I *keep*", and the answer is dictated by why you are reading the log. You read it after something went wrong, to find out what happened just before. The most recent lines are the ones adjacent to the failure. Overwrite-oldest guarantees that the ring always contains the most recent `CAPACITY` lines, whatever else has happened — which is precisely the invariant `panic()` needs.

**Why not B.** It is exactly backwards, and it fails in the specific case the log exists for. Stop-when-full means the ring fills up with boot messages — the ones you have already read, on screen, and already have on serial — and then refuses every line after that. The fault forty minutes into a stress test writes nothing, and the panic dump prints early boot chatter with the crash nowhere in it. Worse, the failure is silent and looks like success: there *is* a log, it *is* full, and it is uniformly useless. This is the single most common way a first ring buffer is written wrong, because "the buffer is full, so stop writing" is what the phrase sounds like it should mean.

**Why not C.** It sounds clever and it costs a linear scan of 256 slots on every log call to find a victim. It also destroys the one thing that makes a log readable — the fact that consecutive lines happened consecutively. A dump with the `Debug` lines punched out of the middle reads like a transcript with words missing, and you will draw the wrong conclusion from the gap.

**When B would be right.** When the *first* occurrence is what matters and later ones are noise — a one-shot capture of the first fault after boot, or an audit trail where the beginning is the evidence. Note the shape: those are not really logs, they are single-event captures, and the honest implementation is a one-slot buffer with a "captured" flag, not a full ring you refuse to advance.

---

### Decision: line-oriented slots, or a byte-oriented ring?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — fixed-width line slots (chosen)** | `LogLine g_lines[256]`, one line per slot | Wasted bytes in short lines; hard cap on line length | ✅ |
| B — byte ring | One `char[65536]`, lines separated by `\n` | Cannot cheaply find "the last 20 lines"; a wrap tears a line in half | ❌ |
| C — byte ring plus a descriptor array | Bytes in one ring, `{offset, len, level}` records in another | Both of A's costs *and* B's tearing, plus two wrap conditions to keep consistent | ❌ |

**Why A.** Everything this stage must deliver is retrieval, and retrieval is what fixed-width slots make trivial. "The last 20 lines" is `for (i = head - 20; i < head; ++i)` over `g_lines[i % 256]` — five lines of code, no parsing, no scanning, `O(20)`. Each slot carries its own length and level, so nothing needs to be re-derived. And a slot is either fully written or holds the previous line: there is no state in which a *partial* line is readable, which means the panic dump can never print garbage.

**Why not B.** Two concrete failures. Retrieval: to find the last twenty lines in a byte ring you must scan **backwards** from the head looking for the twentieth `\n`, wrapping the index by hand as you go, and handle the case where fewer than twenty newlines exist. That is a fiddly loop, and it is a fiddly loop you are asking to run inside the panic handler. Tearing: when the write pointer wraps mid-message, the bytes at the wrap point are the tail of the new message immediately followed by the surviving tail of the *old* one. A reader sees `pmm: 512 MiB usaghi: port 0 reset timeout` — one line assembled from two messages, with no marker to say it happened. Both were reasonable-looking log lines a moment ago; now they are a single plausible-looking lie, and you will read it and believe it.

**Why not C.** This is what Linux actually does (`printk_ringbuffer` keeps a data ring plus a descriptor ring) and for Linux it is right — variable-length records at Linux's log volume make fixed-width slots genuinely wasteful. The cost is that the two rings wrap independently and must be kept mutually consistent, lock-free, across cores, in code that runs from NMI context. That is several hundred lines of carefully-ordered atomics. You do not have atomics, you do not have SMP, and you do not have the log volume. Read theirs; do not write theirs.

**The cost you are accepting.** A 20-character line occupies a 256-byte slot, so a typical boot wastes maybe 70% of the buffer. That is 45 KiB of `.bss` bought to make the panic path five lines long and untearable. On a machine with gigabytes of RAM this is not a tradeoff, it is a rounding error with a large usability payoff.

**When B would be right.** When lines vary by orders of magnitude in length and memory is genuinely tight — an embedded target with 64 KiB of RAM *total*, where a fixed 256-byte slot is a quarter of the machine.

---

### Decision: compile-time or runtime log levels?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — runtime threshold, settable from the kernel cmdline (chosen)** | `g_threshold` compared on every call; `loglevel=debug` sets it | One load-and-compare per call site | ✅ |
| B — compile-time only | `#if LOG_LEVEL <= DEBUG` around each call | Changing verbosity means a rebuild and a reflash | ❌ |
| C — both, always | Runtime check inside a compile-time guard | The best answer, but only once profiling says the check matters | ⚠️ later |

**Why A.** The mechanism already exists and is already wired: `boot/limine.conf` has shipped a `/CRACKED-F OS (verbose)` menu entry with `kernel_cmdline: loglevel=debug` since [[Stage 0.5 - Building a Bootable Image]], and that note explicitly defers the parsing to this phase. Runtime filtering is therefore not a new capability, it is the capability that entry was created for. The value is the workflow: you hit a bug, you reboot into the verbose entry, and you get the detail *for the boot that failed*, on the same binary, with no rebuild. With B the sequence is edit, rebuild, re-image, reboot — and any bug whose reproduction depends on timing may not survive the change.

**The cost, honestly.** Every log call becomes a load of `g_threshold`, a compare, and a not-taken branch — a handful of cycles, from a cache line that is hot because every log call touches it. That is irrelevant almost everywhere, and it is not irrelevant in exactly one place: a `Trace` call inside a per-page loop in the physical memory manager, or inside the page-fault path, executed millions of times. There the check is real cost, and worse, the *arguments* are usually evaluated before the call even when the line is discarded.

**Which is why C is the eventual answer, not now.** When you have a hot path with `Trace` logging in it, wrap those specific call sites:

```cpp
#ifndef NDEBUG
    if (log_enabled(LogLevel::Trace))
        log_write(LogLevel::Trace, "...");
#endif
```

`NDEBUG` is already defined by CMake for `Release` and `RelWithDebInfo` ([[Stage 0.7 - Panic and KASSERT]] §4), so the guard costs no new build plumbing. Do this **per call site, when a profile says so** — not as a project-wide policy, because a global `#if` deletes the messages you will want on the day the release build is the one that misbehaves.

**Why not B alone.** A release kernel whose verbosity cannot be raised is a kernel that must be rebuilt to be debugged, and the machine you cannot rebuild for is the user's. The `(verbose)` boot entry is worth more than the cycles it costs.

---

### Decision: is the line formatted in the log call, or at the sink?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — the ring stores fully-formatted text; sinks add only their own decoration (chosen)** | `log_write` takes a finished string; sinks prepend `[INFO ] ` and append a newline | The message is rendered once, even if it is later filtered by no one | ✅ |
| B — store the format string and the arguments; format at each sink | `log_write(level, fmt, args...)` stores a `va_list` snapshot | `%s` arguments are *pointers*; by replay time they may be freed, unmapped, or overwritten | ❌ |
| C — format at each sink from the original string | Sinks re-run the formatter per sink | Same pointer-lifetime bug, times the number of sinks | ❌ |

**Why A.** B and C share one fatal flaw. `log_write(Info, "opening %s", name)` stores a pointer to `name`. The console registers four steps later and replays that line — and `name` was a stack buffer in a function that returned long ago. You print whatever is at that address now. This is not a rare race; it is the *normal* case for a replayed log, because replay happens by definition after the call site is gone. Rendering to text at the call site converts every argument into bytes the ring owns, which is the only way a stored line can be safely re-read later.

It also keeps the ring's cost honest: one render, at a known bounded size, in the caller's context — rather than an unbounded amount of formatting work happening inside a device sink.

**Be honest about the ordering.** `kprintf` is the *next* stage, [[Stage 1.6 - kprintf]]. So this stage's `log_write` takes an already-formatted `const char*`, which today means a string literal or something you assembled by hand. That is deliberate, and it is the right order:

- This stage defines the **interface** and the storage. Stage 1.6 writes the formatter that feeds it.
- The seam is `log_write_n(level, buf, len)`. Stage 1.6's `klog(level, fmt, ...)` renders into a stack buffer and makes exactly one call to it. Nothing in this file changes.
- The reason the length-taking variant exists at all is this handshake: a formatter already knows how many bytes it produced, so re-scanning for a NUL would be waste, and requiring NUL-termination would force the formatter to reserve a byte for it.

Doing it the other way — writing `kprintf` first and bolting a ring behind it — is how you end up with a formatter that owns the output policy, which is exactly the coupling [[Stage 0.7 - Panic and KASSERT]] §3 refused when it gave `panic` its own private formatter.

---

## 4. Specification

### Severity levels

| `LogLevel` | Value | Sink prefix | Means | Example |
|---|---|---|---|---|
| `Trace` | 0 | `[TRACE]` | Per-iteration detail; off in a normal boot | `pte[3] = 0x...` |
| `Debug` | 1 | `[DEBUG]` | Development detail; on with `loglevel=debug` | `pmm: region 4 usable, 128 MiB` |
| `Info` | 2 | `[INFO ]` | Normal milestones; the default floor | `console: 1280x800x32` |
| `Warn` | 3 | `[WARN ]` | Anomaly, recovered | `acpi: no HPET, falling back to PIT` |
| `Error` | 4 | `[ERROR]` | An operation failed | `ahci: port 0 reset timeout` |
| `Panic` | 5 | `[PANIC]` | Fatal; can never be filtered out | The last line before `panic()` |

**Filter rule:** a line is recorded when `level >= threshold`. `Panic` is the maximum, so no threshold can suppress it. Prefixes are padded to five characters so the message column lines up in a serial log.

### Ring geometry

| Constant | Value | Why |
|---|---|---|
| `LOG_LINES` | 256 | A whole verbose boot; power of two so `% LOG_LINES` is `and $0xff` |
| `LOG_LINE_CHARS` | 252 | Text bytes per slot |
| `sizeof(LogLine)` | 256 B | 252 text + `uint16_t len` + `uint8_t level` + `uint8_t flags` |
| Ring total | 64 KiB | `.bss` — **zero bytes in `kernel.elf`** |
| `LOG_MAX_SINKS` | 4 | serial, console, and two spare (Phase 9 disk, Phase 14 net) |
| `PANIC_DUMP_LINES` | 20 | Fits alongside the register dump in `panic`'s 4 KiB capture buffer |

`static_assert((LOG_LINES & (LOG_LINES - 1)) == 0)` enforces the power of two, and `static_assert(sizeof(LogLine) == 256)` catches an accidental padding change.

### `head` arithmetic

`g_head` is a `uint64_t` **count of lines ever written**, never an index, never reset.

| Quantity | Expression | Note |
|---|---|---|
| Slot for the next write | `g_head % LOG_LINES` | Also the oldest live slot, once wrapped |
| Oldest live line number | `g_head > LOG_LINES ? g_head - LOG_LINES : 0` | No special case for "not yet wrapped" |
| Newest line number | `g_head - 1` | Valid only when `g_head > 0` |
| The last `n` lines | `[max(first, g_head - n), g_head)` | Clamped to the live range |
| Lines lost to overwrite | `g_head > LOG_LINES ? g_head - LOG_LINES : 0` | Derived — no counter needed |

Overflow is not a concern: at one million lines per second a `uint64_t` takes about 584,000 years to wrap. Even then, `% 256` stays contiguous across the wrap because 256 divides 2⁶⁴ exactly.

### Public API

| Function | Callable when | Guarantees |
|---|---|---|
| `log_init()` | Any time; **not** required before `log_write` | Idempotent. Does **not** clear the ring. Registers the panic hook |
| `log_write(level, msg)` | Always, including before `log_init` | Never allocates, never blocks, has no failure path |
| `log_write_n(level, msg, len)` | Always | As above; the seam Stage 1.6 calls |
| `log_set_level(level)` | Any time | Affects subsequent writes only |
| `log_set_level_by_name("debug")` | Any time | `false` if the name is unknown |
| `log_parse_cmdline(s)` | After `BootInfo` is copied | Honours `loglevel=<name>`; ignores every other token |
| `log_register_sink(sink)` | After the sink's own device is up | Replays all history to it; `false` if the table is full |
| `log_replay(sink)` | Any time | Oldest to newest; bounded by a snapshot of `head` |
| `log_dump_last(n)` | Panic context | Writes via `panic_write`; **bypasses the sink list**; ≤ `LOG_LINES` iterations |
| `log_lost_count()` | Any time | Lines overwritten before anyone read them |

### The sink contract

A sink is `void (*)(LogLevel, const char* text, size_t len)`. It must:

| Rule | Why |
|---|---|
| Not call `log_write` | Infinite recursion. A guard limits the damage but the line is not delivered |
| Not allocate | There is no heap until Phase 4, and later there still must not be one here |
| Not block indefinitely | A log call is allowed anywhere; a blocking sink revokes that |
| Add its own line ending | `text` has **no** trailing newline — the ring stripped it |
| Not assume NUL-termination | `text` is *not* NUL-terminated. Use `len` |
| Tolerate `len == 0` | An empty log line is legal |

### Initialisation order — an amendment to [[06 - Architecture Overview]]

The table there lists the log ring as step 7, depending on "console, serial". **That records where the log is fully wired, not where it becomes usable.** The ring itself has no dependencies at all, and this stage makes that explicit:

| Step | Action | Note |
|---|---|---|
| 0 | *(nothing)* — the ring is already valid | `.bss` is zeroed by the loader, and zero is a valid empty ring |
| 1 | `serial_init()` | Unchanged |
| 1b | `log_init()` | **New.** Sets the default threshold; registers the panic hook |
| 1c | `log_register_sink(&serial_log_sink)` | Replays anything logged before now |
| 2 | `BootInfo` copy, then `log_parse_cmdline(info->cmdline)` | The cmdline is not available before this |
| 6 | `console_init()`, ending in `log_register_sink(&console_log_sink)` | **Replays the entire history to the screen** |

### `BootInfo` needs a `cmdline`

The `BootInfo` in [[Stage 0.3 - Freestanding C++ and kmain]] has no cmdline field. Add one:

```cpp
inline constexpr size_t MAX_CMDLINE = 256;
// ... inside struct BootInfo:
    char cmdline[MAX_CMDLINE];   // copied, NUL-terminated, may truncate
```

and copy it in `boot_info.cpp` with the same bounded copy used for `Module::path`. The string Limine hands you lives in **bootloader-reclaimable memory** and must be copied out, exactly like every other Limine pointer — the trap named at the top of [[06 - Architecture Overview]]. The cmdline is carried on the kernel-file / executable-file response; **check the pinned `limine.h` for the exact request and field name**, because it was renamed across Limine versions and [[Stage 0.5 - Building a Bootable Image]] flags the same caveat.

---

## 5. Writing the code

### `kernel/include/kernel/log.hpp`

The cross-subsystem interface: how anything in the kernel records a line, and how an output device attaches itself.

```cpp
#pragma once

#include <stddef.h>
#include <stdint.h>

// ------------------------------------------------------------------ levels --
//
// Ordered least- to most-severe, so the filter reads `level >= threshold` and
// Panic can never be suppressed. This is the OPPOSITE of syslog/RFC 5424
// numbering, deliberately. Trace == 0 also means the all-zero .bss state is
// "record everything", which is the right default before anything is configured.

enum class LogLevel : uint8_t {
    Trace = 0,
    Debug = 1,
    Info  = 2,
    Warn  = 3,
    Error = 4,
    Panic = 5,
};

// ------------------------------------------------------------------- shape --

inline constexpr size_t LOG_LINES      = 256;   // slots; MUST be a power of two
inline constexpr size_t LOG_LINE_CHARS = 252;   // text bytes per slot
inline constexpr size_t LOG_MAX_SINKS  = 4;     // serial, console, +2 spare

static_assert((LOG_LINES & (LOG_LINES - 1)) == 0,
              "LOG_LINES must be a power of two: the slot index is head % LOG_LINES");

// A sink receives one complete line. `text` is NOT NUL-terminated and has no
// trailing newline. A sink must not allocate, must not block, and must never
// call log_write().
using LogSink = void (*)(LogLevel level, const char* text, size_t len);

// --------------------------------------------------------------------- api --

// Sets the default threshold and hooks the ring into panic(). Idempotent, and
// it does NOT clear the ring: log_write() is legal before this is called.
void log_init();

void log_write(LogLevel level, const char* msg);              // NUL-terminated
void log_write_n(LogLevel level, const char* msg, size_t len);// explicit length

void     log_set_level(LogLevel level);
LogLevel log_get_level();
inline bool log_enabled(LogLevel level) { return level >= log_get_level(); }

[[nodiscard]] bool log_set_level_by_name(const char* name);   // "debug", "warn"
void               log_parse_cmdline(const char* cmdline);    // loglevel=<name>

// Registers `sink` and immediately replays the whole ring to it, so a device
// that initialises late still sees everything that happened before it existed.
[[nodiscard]] bool log_register_sink(LogSink sink);

void log_replay(LogSink sink);   // oldest -> newest, does not register
void log_dump_last(size_t n);    // panic path only: writes via panic_write()

uint64_t log_line_count();       // lines ever written
uint64_t log_lost_count();       // lines overwritten before anyone read them

const char* log_level_name(LogLevel level);   // always exactly 5 characters
```

#### Line by line

**The enum's underlying type and ordering**
```cpp
enum class LogLevel : uint8_t {
    Trace = 0,
    ...
```
`enum class` gives a distinct type, so `log_write(2, "x")` is a compile error rather than a silent level. `: uint8_t` fixes the size at one byte, which is what lets the slot struct be exactly 256 bytes — the default underlying type is `int`, and a four-byte level would push `sizeof(LogLine)` to 260 and break the `static_assert`.

The values are written out explicitly rather than left implicit. They are not just an internal detail: they will be an ABI once `dmesg` becomes a syscall ([[05 - Gap Analysis (v1 to Product)]] names it), and a number that userspace can see should be a decision rather than a consequence of the declaration order.

**Why `Trace = 0` specifically.** Global state in `.bss` starts at zero. `g_threshold` is a `LogLevel`, so its pre-`log_init` value is `Trace`, so the filter passes everything. That is the correct behaviour for the window before anything has configured the log: record it all, decide later. Number the enum the other way round and the zero state means "suppress everything", and your earliest messages — the ones from the code most likely to be broken — vanish, with no line of code anywhere that says so.

**The `static_assert` on `LOG_LINES`**
```cpp
static_assert((LOG_LINES & (LOG_LINES - 1)) == 0, "...");
```
`x & (x - 1)` clears the lowest set bit, so it is zero only when `x` had exactly one bit set. The requirement is not correctness — `head % 300` is perfectly correct arithmetic — it is cost. With a power-of-two constant GCC compiles `% 256` to `and $0xff`, one instruction with no latency worth measuring; with 300 it emits a multiply-and-shift reciprocal sequence, in a function you want to be able to call from anywhere. Someone will eventually "just make it 300 lines", and this line is how they find out in the build rather than in a profile.

**The sink type**
```cpp
using LogSink = void (*)(LogLevel level, const char* text, size_t len);
```
A plain function pointer, for the same reason `PanicSink` is one in [[Stage 0.7 - Panic and KASSERT]]: `drivers/` sits *above* `lib/` in the subsystem map, so `log.cpp` calling the console directly would be an upward call. Inverting it means the console registers itself and `log.cpp` never learns that a framebuffer exists. It also keeps `log.cpp` free of every device dependency, which is what makes it compile on the host for a Tier-1 test.

Three parameters, no more. `len` is separate because `text` is a slice of a fixed-width slot and is not NUL-terminated. The truncation flag is deliberately *not* a fourth parameter — the ring marks a cut line inside the text itself (see `log_write_n`), so every sink shows it with no signature change.

**`log_enabled` is `inline` in the header**
```cpp
inline bool log_enabled(LogLevel level) { return level >= log_get_level(); }
```
So a guarded hot-path call site — the pattern from §3 — costs a load and a compare with no function call. Comparing two `enum class` values with `>=` is legal C++ and compares the underlying values, which is exactly why §2 insisted the numbering run upward with severity.

**`[[nodiscard]]` on the two fallible functions.** [[13 - Coding Standards]] rule 6: anything that can fail is marked, and `-Werror` turns an ignored result into a build failure. Both really can fail — a fifth sink, or a typo in `loglevel=dbeug` — and both fail in ways that are otherwise silent. `log_write` is deliberately *not* fallible: it has no error path at all, which is the property §3 was buying.

---

### `kernel/lib/log.cpp`

The ring, the filter, the fan-out, the replay, and the panic dump.

```cpp
// kernel/lib/log.cpp — the kernel's memory of what it has been doing.
//
// Rules that apply to every line in this file:
//   * never allocate            (there is no heap until Phase 4)
//   * never block               (a log call must be cheap enough to sit anywhere)
//   * never fail                (log_write has no error path, by design)
//   * the ring write happens FIRST; sinks are a consequence, not the point
//   * nothing here has a constructor or a non-zero initialiser, so the whole
//     64 KiB lives in .bss and costs zero bytes in kernel.elf

#include <kernel/log.hpp>

#include <kernel/panic.hpp>   // panic_write(), panic_set_log_dump()

#include <stddef.h>
#include <stdint.h>

namespace {

// One slot. Exactly 256 bytes, so &g_lines[i] is a shift rather than a multiply.
struct LogLine {
    uint16_t len;                   // bytes used in text[]
    uint8_t  level;                 // a LogLevel, stored narrow
    uint8_t  flags;                 // LINE_TRUNCATED
    char     text[LOG_LINE_CHARS];  // NOT NUL-terminated; len is the length
};
static_assert(sizeof(LogLine) == 256, "LogLine stride changed — check LOG_LINE_CHARS");

inline constexpr uint8_t LINE_TRUNCATED       = 1u << 0;
inline constexpr size_t  TRUNCATION_MARK_LEN  = 3;    // "..."
inline constexpr size_t  PANIC_DUMP_LINES     = 20;

// --- state. Every one of these is zero, and zero is a valid EMPTY log. ------

LogLine  g_lines[LOG_LINES];
uint64_t g_head;          // total lines ever written. NOT an index.
LogLevel g_threshold;     // zero == LogLevel::Trace == record everything
LogSink  g_sinks[LOG_MAX_SINKS];
size_t   g_sink_count;
bool     g_in_sink;       // true while any sink callback is on the stack
bool     g_initialised;

// --- helpers ---------------------------------------------------------------

size_t bounded_strlen(const char* s, size_t limit) {
    size_t n = 0;
    while (n < limit && s[n] != '\0')
        ++n;
    return n;
}

bool str_eq(const char* a, const char* b) {
    while (*a != '\0' && *a == *b) { ++a; ++b; }
    return *a == *b;
}

void panic_puts(const char* s) {
    panic_write(s, bounded_strlen(s, 128));
}

void panic_put_udec(uint64_t v) {
    char rev[20];                       // 20 digits is the widest uint64_t
    size_t n = 0;
    do {
        rev[n++] = static_cast<char>('0' + (v % 10));
        v /= 10;
    } while (v != 0);

    char out[20];
    for (size_t i = 0; i < n; ++i)
        out[i] = rev[n - 1 - i];
    panic_write(out, n);
}

// The hook panic() calls at its step 6. Registered by log_init().
void panic_log_hook() {
    log_dump_last(PANIC_DUMP_LINES);
}

}  // namespace

// ---------------------------------------------------------------- writing ---

void log_write_n(LogLevel level, const char* msg, size_t len) {
    if (level < g_threshold)
        return;                         // filtered: costs one compare

    if (msg == nullptr) {
        msg = "(null)";
        len = 6;
    }

    // The ring is line-oriented: one slot IS one line, so a trailing newline
    // from a caller migrating off serial_puts() is dropped rather than stored.
    while (len > 0 && (msg[len - 1] == '\n' || msg[len - 1] == '\r'))
        --len;

    LogLine& slot = g_lines[g_head % LOG_LINES];

    uint8_t flags  = 0;
    size_t  copy   = len;
    size_t  stored = len;
    if (copy > LOG_LINE_CHARS) {
        copy   = LOG_LINE_CHARS - TRUNCATION_MARK_LEN;
        stored = LOG_LINE_CHARS;
        flags  = LINE_TRUNCATED;
    }

    for (size_t i = 0; i < copy; ++i)
        slot.text[i] = msg[i];

    if (flags & LINE_TRUNCATED) {
        for (size_t i = 0; i < TRUNCATION_MARK_LEN; ++i)
            slot.text[copy + i] = '.';  // fills [249,252) — the last three bytes
    }

    slot.len   = static_cast<uint16_t>(stored);
    slot.level = static_cast<uint8_t>(level);
    slot.flags = flags;

    // PUBLISH. Everything a reader needs is already in the slot. This single
    // increment is the seam that becomes a release-ordered atomic in Phase 12.
    ++g_head;

    // Fan out. The line is safe in memory whether or not any of this works.
    if (!g_in_sink) {
        g_in_sink = true;
        for (size_t i = 0; i < g_sink_count; ++i)
            g_sinks[i](level, slot.text, stored);
        g_in_sink = false;
    }
}

void log_write(LogLevel level, const char* msg) {
    if (msg == nullptr) {
        log_write_n(level, nullptr, 0);
        return;
    }
    // Bounded: a caller with a missing NUL must not walk us off a page. Scanning
    // one byte past the slot width is what lets log_write_n see it was too long.
    log_write_n(level, msg, bounded_strlen(msg, LOG_LINE_CHARS + 1));
}

// ----------------------------------------------------------------- levels ---

void     log_set_level(LogLevel level) { g_threshold = level; }
LogLevel log_get_level()               { return g_threshold; }

const char* log_level_name(LogLevel level) {
    switch (level) {
    case LogLevel::Trace: return "TRACE";
    case LogLevel::Debug: return "DEBUG";
    case LogLevel::Info:  return "INFO ";
    case LogLevel::Warn:  return "WARN ";
    case LogLevel::Error: return "ERROR";
    case LogLevel::Panic: return "PANIC";
    }
    return "?????";                     // a value cast in from outside the enum
}

bool log_set_level_by_name(const char* name) {
    if (name == nullptr)
        return false;

    struct Named { const char* name; LogLevel level; };
    static constexpr Named TABLE[] = {
        {"trace", LogLevel::Trace}, {"debug", LogLevel::Debug},
        {"info",  LogLevel::Info},  {"warn",  LogLevel::Warn},
        {"error", LogLevel::Error}, {"panic", LogLevel::Panic},
    };

    for (const Named& n : TABLE) {
        if (str_eq(name, n.name)) {
            g_threshold = n.level;
            return true;
        }
    }
    return false;
}

void log_parse_cmdline(const char* cmdline) {
    if (cmdline == nullptr)
        return;

    static constexpr char KEY[]   = "loglevel=";
    constexpr size_t      KEY_LEN = sizeof(KEY) - 1;

    for (const char* p = cmdline; *p != '\0'; ) {
        while (*p == ' ' || *p == '\t')          // skip separators
            ++p;
        if (*p == '\0')
            break;

        const char* tok = p;                     // token is [tok, p) after this
        while (*p != '\0' && *p != ' ' && *p != '\t')
            ++p;

        size_t i = 0;
        while (i < KEY_LEN && tok + i < p && tok[i] == KEY[i])
            ++i;
        if (i != KEY_LEN)
            continue;                            // not our token; p has advanced

        char   value[16];                        // longest name is 5 characters
        size_t n = 0;
        for (const char* v = tok + KEY_LEN; v < p && n + 1 < sizeof(value); ++v)
            value[n++] = *v;
        value[n] = '\0';

        if (!log_set_level_by_name(value))
            log_write(LogLevel::Warn, "log: unrecognised loglevel= on cmdline");
        return;                                  // first occurrence wins
    }
}

// ------------------------------------------------------------------ sinks ---

bool log_register_sink(LogSink sink) {
    if (sink == nullptr)
        return false;
    if (g_sink_count >= LOG_MAX_SINKS)
        return false;

    // Register FIRST, then replay. A line written during the replay is then
    // delivered live and is outside the replay's snapshot, so it arrives
    // exactly once. Replaying first would deliver it twice.
    g_sinks[g_sink_count++] = sink;
    log_replay(sink);
    return true;
}

void log_replay(LogSink sink) {
    if (sink == nullptr)
        return;

    const uint64_t end   = g_head;                            // snapshot
    const uint64_t first = (end > LOG_LINES) ? (end - LOG_LINES) : 0;

    const bool saved = g_in_sink;
    g_in_sink = true;
    for (uint64_t i = first; i < end; ++i) {
        const LogLine& l = g_lines[i % LOG_LINES];
        size_t len = l.len;
        if (len > LOG_LINE_CHARS)
            len = LOG_LINE_CHARS;
        sink(static_cast<LogLevel>(l.level), l.text, len);
    }
    g_in_sink = saved;
}

// ------------------------------------------------------------ panic dump ---

void log_dump_last(size_t n) {
    if (n == 0)
        return;
    if (n > LOG_LINES)
        n = LOG_LINES;                  // the ring cannot hold more than this

    const uint64_t end = g_head;
    if (end == 0) {
        panic_puts("  (log is empty)\n");
        return;
    }

    uint64_t first = (end > n) ? (end - n) : 0;
    if (end - first > LOG_LINES)        // never read past the oldest live slot
        first = end - LOG_LINES;

    const uint64_t lost = (end > LOG_LINES) ? (end - LOG_LINES) : 0;
    if (lost > 0) {
        panic_puts("  (");
        panic_put_udec(lost);
        panic_puts(" earlier lines already overwritten)\n");
    }

    for (uint64_t i = first; i < end; ++i) {
        const LogLine& l = g_lines[i % LOG_LINES];

        size_t len = l.len;
        if (len > LOG_LINE_CHARS)
            len = LOG_LINE_CHARS;       // defensive: this runs in the panic path

        panic_puts("  [");
        panic_puts(log_level_name(static_cast<LogLevel>(l.level & 0x7)));
        panic_puts("] ");
        panic_write(l.text, len);       // the one thing that is not NUL-terminated
        panic_puts("\n");
    }
}

// ------------------------------------------------------------------- init ---

void log_init() {
    if (g_initialised)
        return;

    // Deliberately does NOT clear the ring. Anything logged before this point
    // is real history and not losing it is the entire point of the stage.
    g_threshold   = LogLevel::Info;
    g_initialised = true;

    panic_set_log_dump(&panic_log_hook);   // panic step 6 now has something to call
}

uint64_t log_line_count() { return g_head; }
uint64_t log_lost_count() { return (g_head > LOG_LINES) ? (g_head - LOG_LINES) : 0; }
```

#### Line by line

**The slot struct and its `static_assert`**
```cpp
struct LogLine {
    uint16_t len;
    uint8_t  level;
    uint8_t  flags;
    char     text[LOG_LINE_CHARS];
};
static_assert(sizeof(LogLine) == 256, "...");
```
Metadata first, then the payload — that ordering is not arbitrary. `uint16_t` needs two-byte alignment; putting `text[252]` first would leave `len` at offset 252, which happens to be fine, but the moment `LOG_LINE_CHARS` changes to an odd number the compiler inserts padding and `sizeof` silently becomes 258. Fixed-size fields first means the layout is determined by the fields you wrote, not by an alignment rule you did not think about.

2 + 1 + 1 + 252 = 256 with no padding at all. The `static_assert` is the guard: change `LOG_LINE_CHARS` to 250 and the build fails immediately, rather than the ring quietly becoming 254 bytes per slot, the multiply-by-stride becoming a real multiply, and 512 bytes of `.bss` going missing.

`text` is explicitly *not* NUL-terminated. Storing a terminator would cost a byte per slot and buy nothing, because `len` is already stored, and it would create a second source of truth about where the line ends — the classic setup for one path reading the length and another reading to the NUL and the two disagreeing after a truncation.

**The state block, and why every declaration is bare**
```cpp
LogLine  g_lines[LOG_LINES];
uint64_t g_head;
LogLevel g_threshold;
```
No initialisers. That is a deliberate, load-bearing choice, not laziness.

A namespace-scope object with no initialiser is zero-initialised by the language, and GCC places it in `.bss` — `SHT_NOBITS`, which occupies **no bytes in the ELF file**. [[Stage 0.4 - The Linker Script and Higher-Half Layout]] establishes both halves of why that works: the ELF rule that a `PT_LOAD` segment with `p_memsz > p_filesz` has its excess treated as zero, and the linker script's placement of `.bss` last in the data segment so that the excess really is the tail. Limine implements those semantics, so `g_lines` is 64 KiB of zeroes before `kmain` runs, at a cost of zero bytes on disk and zero instructions at boot.

Give any of these a non-zero initialiser — a default member initialiser like `uint8_t level = 2;`, a constructor, or filling `text` with spaces — and the array must be materialised in the file. `kernel.elf` grows by 64 KiB, every boot pays to read it, and a constructor additionally violates [[13 - Coding Standards]] rule 9 and depends on `.init_array`, which does not run until step 11 of the init order — five steps *after* the console. A log that only starts working after the heap does is not a log.

The all-zero state is also a *valid, empty* ring: `g_head == 0` means nothing written, `g_sink_count == 0` means no sinks, `g_threshold == LogLevel::Trace` means record everything. That is why `log_write` is legal before `log_init`.

**The filter, and why it is the first statement**
```cpp
    if (level < g_threshold)
        return;
```
One load, one compare, one branch — before the NUL check, before the newline strip, before touching the ring. A discarded line costs essentially nothing, which is the property that makes it reasonable to leave `Trace` calls in the source permanently. Comparing `LogLevel` values directly works because the enum's underlying type is `uint8_t` and the ordering runs upward with severity.

**The `nullptr` and newline handling**
```cpp
    if (msg == nullptr) { msg = "(null)"; len = 6; }

    while (len > 0 && (msg[len - 1] == '\n' || msg[len - 1] == '\r'))
        --len;
```
`"(null)"` rather than a crash, for the same reason `panic`'s formatter does it: the log is a diagnostic tool and a diagnostic tool that faults on bad input is worse than useless at exactly the moment it matters.

The newline strip enforces the structural invariant **one slot is one line**. Callers arrive here from `serial_puts("...\n")` habits, and a stored trailing newline would make every sink emit a blank line between entries — the console would scroll at twice the rate, and the panic dump would double in height for no content. The loop form handles `"\r\n"` and a doubled `"\n\n"`; `len > 0` first means an all-newline message becomes an empty line rather than an underflowed `size_t` and a 16-exabyte read.

Embedded newlines in the *middle* of a message are stored verbatim. That is the caller's problem, and [[Stage 1.6 - kprintf]] is where a formatter splits on them.

**The wraparound: `g_head % LOG_LINES`**
```cpp
    LogLine& slot = g_lines[g_head % LOG_LINES];
```
This is the line the whole structure turns on, so it is worth stating exactly why it is written this way and not the way it is usually written first.

`g_head` is a **count**, not a position. It is the number of lines ever written, it starts at zero, and it is never assigned — only incremented. The position is *derived*, every time, by `% LOG_LINES`.

The naive alternative keeps `head` as an index and wraps it in place:

```cpp
    // DO NOT DO THIS
    LogLine& slot = g_lines[g_head];
    ++g_head;
    if (g_head == LOG_LINES)
        g_head = 0;
```

Four things break.

*You lose the count.* `g_head` now tells you where the next write goes and nothing else. "How many lines have there been" needs a second variable; "has the buffer wrapped" needs a `bool`; "how many lines were lost" needs a third. Every one of them is another thing that has to be updated in lockstep on every path that touches the ring, and every one is a place a later change can forget.

*Empty and full become indistinguishable.* With a wrapped index and a `tail`, `head == tail` means both "nothing stored" and "exactly `CAPACITY` stored", and every classic ring-buffer bug lives in that ambiguity. With a monotonic count there is no ambiguity: `g_head == 0` is empty, and full is `g_head >= LOG_LINES`, and neither can be confused with the other.

*The reset is `== `, and `==` is fragile.* Written as `if (g_head == LOG_LINES)` it is correct only if the increment is exactly one and the check runs after *every* increment. Add a path that advances `head` by two — a future "log dropped N lines" marker, say — and the check is skipped, `g_head` sails past `LOG_LINES`, and the next write indexes out of bounds into whatever `.bss` object the linker placed after the ring. That is silent memory corruption in a diagnostic subsystem, which is the worst possible place for it, because you will not believe the log when it starts lying. `%` cannot be skipped: it is applied at the point of use, so there is no path that can bypass it.

*The retrieval arithmetic gets special cases.* `log_dump_last`, `log_replay` and `log_lost_count` are each two or three lines here because "line number `i` lives in slot `i % LOG_LINES`" holds unconditionally. With a wrapped index every one of them needs a "have we wrapped yet" branch and a two-part loop.

The usual objection to `%` is cost, and it does not apply: `LOG_LINES` is a power-of-two compile-time constant, so GCC emits `and $0xff` — one instruction, no division unit involved. That is what the `static_assert` in the header protects.

**Truncation — bounded, marked, and never overflowing**
```cpp
    uint8_t flags  = 0;
    size_t  copy   = len;
    size_t  stored = len;
    if (copy > LOG_LINE_CHARS) {
        copy   = LOG_LINE_CHARS - TRUNCATION_MARK_LEN;
        stored = LOG_LINE_CHARS;
        flags  = LINE_TRUNCATED;
    }

    for (size_t i = 0; i < copy; ++i)
        slot.text[i] = msg[i];

    if (flags & LINE_TRUNCATED) {
        for (size_t i = 0; i < TRUNCATION_MARK_LEN; ++i)
            slot.text[copy + i] = '.';
    }
```
Three separate requirements, met in order.

*Never overflow.* `copy` is clamped to `LOG_LINE_CHARS - 3 = 249`, so the copy loop writes indices 0–248. The mark loop writes 249, 250, 251. `text` has 252 elements, indices 0–251. The last written index is exactly the last valid index — check that by hand once and then trust it, because this is the only place in the file that writes through an index derived from caller-supplied data.

*Never lie.* A silently-cut line is a trap: you read `pmm: mapping region at 0xFFFF8000` and conclude the address is wrong, when in fact the rest of the line said `...0000 length 512 MiB`. The three dots are visible in every sink and in the panic dump with no signature change anywhere, because they are part of the stored text.

*Keep it machine-readable too.* `LINE_TRUNCATED` in `flags` is what a future `dmesg` reports as a count. It is one byte that was going to be padding regardless.

Note that a message of exactly 252 characters is stored whole — the comparison is `>`, not `>=`. Off by one in the other direction and every full-width line gets three dots it did not earn.

**Publish, then fan out**
```cpp
    slot.len   = static_cast<uint16_t>(stored);
    slot.level = static_cast<uint8_t>(level);
    slot.flags = flags;

    ++g_head;

    if (!g_in_sink) {
        g_in_sink = true;
        for (size_t i = 0; i < g_sink_count; ++i)
            g_sinks[i](level, slot.text, stored);
        g_in_sink = false;
    }
```
The order is the design. Text, then metadata, then — and only then — `++g_head`. Until that increment, line number `g_head` does not exist as far as any reader is concerned; the slot still logically holds its previous contents. After it, the slot is complete. **One store publishes the whole record.**

That is single-threaded reasoning today and it is genuinely sufficient today: one core, interrupts disabled until Phase 2, no preemption until Phase 5. Nothing can observe the intermediate state. The value of writing it in this order now is that Phase 12's fix is to make the increment a release store and the reader's load an acquire — and nothing else moves. Get the order wrong now (increment first, fill after) and that fix is impossible without restructuring, because there would be no single point at which the record becomes valid.

The sinks are called **after** the publish, with the ring already consistent — so a sink that reads the ring (a `dmesg` command doing it the lazy way) sees a sane structure, and so the lock that eventually protects the slot write does not have to be held across a device write.

`g_in_sink` is a re-entrancy guard, not a lock. A sink that calls `log_write` — a console sink logging its own error is the realistic case — would otherwise recurse until the stack runs out, and a stack overflow inside the logging subsystem produces a fault whose backtrace points at logging, which is exactly the kind of misdirection that costs a day. With the guard, the re-entrant line is still **written to the ring** (the memory write is unconditional; it is only the fan-out that is suppressed) and appears in the panic dump. Losing a delivery beats losing the machine.

**`log_write`'s bounded `strlen`**
```cpp
    log_write_n(level, msg, bounded_strlen(msg, LOG_LINE_CHARS + 1));
```
Two jobs in one expression. The bound means a caller who passes an unterminated buffer cannot walk this function off the end of a mapped page and into a fault — an ordinary `strlen` here turns a caller's bug into a kernel fault inside the logger. And the bound is `LOG_LINE_CHARS + 1`, not `LOG_LINE_CHARS`: scanning one byte past the slot width is what lets `log_write_n` see `len == 253 > 252` and mark the line truncated. Bound it at 252 exactly and every over-long message is silently cut with no dots.

**`log_level_name` returns fixed-width strings**
```cpp
    case LogLevel::Info:  return "INFO ";
    ...
    return "?????";
```
Every name is exactly five characters, `INFO` and `WARN` padded. Aligned columns are the difference between skimming a 3,000-line serial log and reading it. The trailing `return "?????"` is not dead code: `static_cast<LogLevel>(l.level & 0x7)` in the dump can produce 6 or 7 from a corrupt slot, and `"?????"` is also five characters, so the panic dump's fixed-width write stays in bounds no matter what is in memory. With every enumerator covered, `-Wswitch` is satisfied and the fallthrough return costs nothing.

**The cmdline parser**
```cpp
    for (const char* p = cmdline; *p != '\0'; ) {
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == '\0') break;
        const char* tok = p;
        while (*p != '\0' && *p != ' ' && *p != '\t') ++p;
```
Tokenised rather than substring-searched, and that matters: a cmdline is `loglevel=debug nosmp selftest=all`, and a naive search for `"loglevel="` would also match `xloglevel=trace` or a value that happens to contain the text. Matching whole whitespace-delimited tokens is the same rule every real bootloader cmdline uses.

The `for` has an empty increment expression and `p` is advanced inside the body — so `continue` after a non-matching token is safe, because `p` has already moved past it. Write the token scan *after* the `continue` by mistake and you have an infinite loop at boot, before any output exists to tell you so.

```cpp
        char   value[16];
        size_t n = 0;
        for (const char* v = tok + KEY_LEN; v < p && n + 1 < sizeof(value); ++v)
            value[n++] = *v;
        value[n] = '\0';
```
The value is copied out because it is a slice of a longer string with no terminator of its own, and `log_set_level_by_name` compares NUL-terminated strings. `n + 1 < sizeof(value)` reserves the terminator's byte, so `value[n] = '\0'` can never write index 16. Sixteen bytes for a five-character name is deliberate slack: `loglevel=` with a long garbage value must truncate rather than overflow, and truncating simply makes the lookup fail and log a warning — which is the behaviour you want.

`return` after the first `loglevel=` token means first occurrence wins. Either rule is defensible; what matters is that it is a rule and not an accident.

**Registration order, and the snapshot that makes it exact**
```cpp
    g_sinks[g_sink_count++] = sink;
    log_replay(sink);
```
```cpp
    const uint64_t end   = g_head;
    const uint64_t first = (end > LOG_LINES) ? (end - LOG_LINES) : 0;
```
Register first, then replay, and replay only up to a **snapshot** of `g_head` taken at entry. Work through the case that decides it. Suppose something writes a log line while the replay is running — a sink misbehaving, or in Phase 3 an interrupt handler. Because the sink is already in `g_sinks`, that new line is delivered to it *live* by `log_write`'s fan-out. Because the replay loop stops at `end`, which was captured before, the replay does not deliver it again. The sink sees it exactly once, in order.

Reverse the two statements and the same line is delivered zero times: the replay finished before the registration, and the fan-out had not yet learned about the sink. A silently-dropped line in the mechanism whose entire job is not to drop lines.

The snapshot also bounds the loop unconditionally. Without it, a sink that logs on every call would keep `g_head` ahead of `i` forever and the replay would never terminate — a hang at `console_init()`, on a machine that has just started drawing pixels, with no obvious cause.

`first` is the oldest line still in the ring: `end - LOG_LINES` once wrapped, `0` before. The ternary is the only place the "has it wrapped" question is asked, and it is asked in one expression with no branch in the loop body.

`g_in_sink` is saved and restored rather than set and cleared, so the invariant is one sentence — *`g_in_sink` is true whenever any sink callback is on the stack* — and holds even when `log_replay` is reached from inside `log_register_sink` from inside something else.

**`log_dump_last` — the panic path**
```cpp
    if (n > LOG_LINES) n = LOG_LINES;
    const uint64_t end = g_head;
    if (end == 0) { panic_puts("  (log is empty)\n"); return; }

    uint64_t first = (end > n) ? (end - n) : 0;
    if (end - first > LOG_LINES)
        first = end - LOG_LINES;
```
This function runs after the kernel has admitted it does not understand its own state, so every line is written on the assumption that the ring might be corrupt.

`first = end - n` **counts backwards from the head**. That is the whole function, and getting the direction wrong is the trap in §7: `g_head % LOG_LINES` is the *next slot to write*, which once wrapped holds the **oldest** live line. Starting there and walking forward gives you the oldest `n` lines — and before the ring has wrapped it gives you `n` slots that were never written, so the panic dump prints twenty blank lines and looks broken rather than wrong.

The two clamps make the loop bounded regardless of what `g_head` contains. `n` is capped at `LOG_LINES`, and `first` is pushed forward if the requested window reaches past the oldest live slot. Whatever garbage `g_head` holds, this loop runs at most 256 times. In the panic path, "bounded no matter what" is worth more than elegance.

```cpp
        size_t len = l.len;
        if (len > LOG_LINE_CHARS)
            len = LOG_LINE_CHARS;
```
Defensive for the same reason. `l.len` is written by this file and should never exceed 252, but a memory-corruption bug is a leading reason to be in a panic at all, and an unclamped `len` here means `panic_write` reads past the slot — a fault inside the panic handler, which costs you the register dump and the backtrace that were already printed. Cheap insurance, in the one function where insurance is worth buying.

```cpp
        panic_write(l.text, len);
```
Note what this function does **not** do: it never touches `g_sinks`. The panic dump deliberately bypasses the sink list, because a corrupt function pointer in that array is a jump to nowhere from inside the panic handler. It reads only the ring and calls exactly one known function, `panic_write`, which [[Stage 0.7 - Panic and KASSERT]] already guarantees writes to serial and buffers a copy for the console. That is also why `log_dump_last` takes no sink parameter: it has exactly one caller and one legitimate output path.

**`log_init` does not clear the ring**
```cpp
    g_threshold   = LogLevel::Info;
    g_initialised = true;
    panic_set_log_dump(&panic_log_hook);
```
Three statements, and the interesting one is the statement that is absent. Clearing `g_lines` here would erase everything logged before `log_init` ran — which is precisely the early-boot history this stage exists to preserve. The `.bss` zero state is already a valid empty ring, so there is nothing to initialise.

What `log_init` actually does is raise the threshold from the `.bss` default of `Trace` to `Info`, and hand `panic` the hook it has been null-checking since Phase 0. Note the ordering consequence: lines written before `log_init` are recorded at any level, and lines written after are filtered at `Info` until `log_parse_cmdline` runs a few statements later. In practice the code in that window logs at `Info` or above anyway, so the window is invisible; the reason it is set up this way round is that a mistake here should cost you an extra line of output, never a missing one.

`g_initialised` makes the function idempotent, so a second call from a test harness or a future re-init path cannot reset the threshold underneath a `loglevel=` that has already been parsed.

---

### Wiring it up

**In `kernel_init()`** — the additions, in this order. The signature is `void kernel_init(BootInfo* info)` from [[Stage 0.3 - Freestanding C++ and kmain]]:

```cpp
#include <kernel/log.hpp>

void kernel_init(BootInfo* info) {
    serial_init();                                  // step 1, unchanged

    log_init();                                     // step 1b — panic can now dump
    if (!log_register_sink(&serial_log_sink))       // step 1c — replays history
        serial_puts("log: sink table full\n");

    log_parse_cmdline(info->cmdline);               // step 2 — needs BootInfo

    log_write(LogLevel::Info, KERNEL_NAME " " KERNEL_VERSION);
    // ...
}
```

**In `kernel/drivers/char/serial.cpp`**, a sink that the log knows nothing about:

```cpp
void serial_log_sink(LogLevel level, const char* text, size_t len) {
    serial_putc('[');
    serial_puts(log_level_name(level));
    serial_puts("] ");
    serial_write(text, len);      // NOT NUL-terminated: length form
    serial_putc('\n');            // the ring stripped it; the sink adds it back
}
```

The sink lives in `drivers/`, not in `lib/log.cpp`, and that placement is the point. `drivers/` sits above `lib/` in the subsystem map, so `log.cpp` may not call serial directly; instead the driver *provides* a sink and `kernel_init` wires the two together. The payoff is immediate and concrete: `log.cpp` has no device dependencies at all, which is what makes the Tier-1 host test in §6 possible.

**At the end of `console_init()`** (from Stage 1.3 — check that note for the exact console function names):

```cpp
    if (!log_register_sink(&console_log_sink))
        log_write(LogLevel::Warn, "console: log sink table full");
    panic_set_console_sink(&console_panic_sink);   // Stage 0.7's step-7 hook
```

That first call is the "log before console" promise being kept. Registration replays the ring, so every line written since step 0 — the serial banner, the memory map summary, any warning from the `BootInfo` copy — is drawn to the framebuffer the moment the framebuffer starts working, in order, as if the console had been there all along.

---

## 6. How to verify

### Checkable now

**1. It builds, and the ring is in `.bss`.**

```sh
make
x86_64-elf-nm build/kernel.elf | grep -i g_lines
```
```
ffffffff80106000 b _ZN12_GLOBAL__N_17g_linesE
```

A lowercase `b` (or `B`) is `.bss` — correct. A `d` or `D` means `.data`, and the ring is being stored in the file. Confirm the file did not grow:

```sh
x86_64-elf-size -A build/kernel.elf | grep -E '\.data|\.bss'
```
```
.data     512   ...
.bss    98304   ...
```

`.bss` up by ~64 KiB, `.data` unchanged. If `.data` grew by 65536, see §7.

**2. Wraparound: the oldest are dropped, the newest survive.** Temporarily, at the end of `kernel_init`:

```cpp
    for (int i = 0; i < 300; ++i) {
        char buf[32] = "line ";
        // crude: two digits plus hundreds, until kprintf exists in Stage 1.6
        buf[5] = static_cast<char>('0' + (i / 100) % 10);
        buf[6] = static_cast<char>('0' + (i / 10) % 10);
        buf[7] = static_cast<char>('0' + i % 10);
        buf[8] = '\0';
        log_write(LogLevel::Info, buf);
    }
    panic("ring test");
```

```sh
make run-serial
```

In the `Recent log:` section of the panic output, the last twenty lines must be `line 280` … `line 299`, and the header must read:

```
Recent log:
  (44 earlier lines already overwritten)
  [INFO ] line 280
  ...
  [INFO ] line 299
```

44 is exact: 300 written − 256 capacity. `line 000` through `line 043` are gone and `line 299` is present. **If it is the other way round — early lines present, recent ones missing — you have written stop-when-full.**

**3. The Tier-1 unit test.** [[09 - Testing Strategy]] names "ring buffer wraparound" as a Tier-1 case, and `log.cpp` is host-compilable because it depends on no device. Create `tests/unit/test_log.cpp`:

```cpp
#include <doctest/doctest.h>
#include <kernel/log.hpp>

namespace {
size_t g_seen;
char   g_last[LOG_LINE_CHARS + 1];

void capture(LogLevel, const char* text, size_t len) {
    ++g_seen;
    for (size_t i = 0; i < len; ++i) g_last[i] = text[i];
    g_last[len] = '\0';
}
}  // namespace

TEST_CASE("ring keeps the newest LOG_LINES lines and drops the oldest") {
    log_set_level(LogLevel::Trace);
    const uint64_t before = log_line_count();

    for (int i = 0; i < 300; ++i)
        log_write(LogLevel::Info, "x");

    CHECK(log_line_count() - before == 300);
    CHECK(log_lost_count() >= 300 - LOG_LINES);

    g_seen = 0;
    log_replay(&capture);
    CHECK(g_seen == LOG_LINES);            // never more than capacity
}

TEST_CASE("an over-long line is truncated, marked, and never overflows") {
    char big[LOG_LINE_CHARS * 2];
    for (char& c : big) c = 'A';
    big[sizeof(big) - 1] = '\0';

    log_write(LogLevel::Info, big);
    g_seen = 0;
    log_replay(&capture);

    CHECK(g_seen > 0);
    const size_t n = __builtin_strlen(g_last);
    CHECK(n == LOG_LINE_CHARS);
    CHECK(g_last[n - 1] == '.');
    CHECK(g_last[n - 3] == '.');
}

TEST_CASE("a sink registered late receives the whole history") {
    log_write(LogLevel::Info, "before the sink existed");
    g_seen = 0;
    REQUIRE(log_register_sink(&capture));
    CHECK(g_seen > 0);
}

TEST_CASE("filtering discards below the threshold") {
    log_set_level(LogLevel::Warn);
    const uint64_t before = log_line_count();
    log_write(LogLevel::Debug, "should not be recorded");
    CHECK(log_line_count() == before);
    log_write(LogLevel::Error, "should be recorded");
    CHECK(log_line_count() == before + 1);
    log_set_level(LogLevel::Trace);
}
```

The test links `kernel/lib/log.cpp` plus a six-line `tests/unit/stubs_panic.cpp` supplying `panic_write` and `panic_set_log_dump`. **Two stubs is the whole host-side cost, and that is the sink indirection paying for itself** — had `log.cpp` called `serial_putc` directly, the test would need a UART.

```sh
make test-unit
```
```
[doctest] assertions: 11 | 11 passed | 0 failed
```

**4. Pre-console messages appear on screen.** Remove the 300-line loop. Confirm `log_init()` and the serial sink registration are *before* `console_init()`, boot, and look at the framebuffer: the banner and the memory-map summary logged at step 1 must be on the screen, above whatever the console logs itself. Those lines were written before a single pixel existed. If the screen starts at `console: 1280x800x32` and everything earlier is only on serial, the replay is not happening — check that `console_init` actually calls `log_register_sink`.

**5. Panic dumps the log.** With the test loop removed, a plain `panic("test")` must now produce a populated `Recent log:` section — the same section that has been empty since Phase 0:

```
Backtrace:
  #0  0xFFFFFFFF80101A2C
  #1  0xFFFFFFFF801002F1

Recent log:
  [INFO ] CRACKED-F OS 0.0.1-dev
  [INFO ] framebuffer: 1280x800x32 pitch=5120
  [INFO ] console: 100 cols x 50 rows
================================================
```

**6. `loglevel=debug` changes what is printed.** Add a `log_write(LogLevel::Debug, "debug filtering works")` to `kernel_init`. Boot the default entry: it must **not** appear. Boot `/CRACKED-F OS (verbose)` from the Limine menu, which passes `kernel_cmdline: loglevel=debug`:

```sh
make run-serial      # pick the (verbose) entry within the 3-second timeout
```
```
[DEBUG] debug filtering works
```

If it never appears on either entry, `info->cmdline` is empty — the `BootInfo` field is not being populated. Print it once to check:

```cpp
    serial_puts("cmdline: "); serial_puts(info->cmdline); serial_putc('\n');
```

Empty means `boot_info.cpp` is not copying it, or is reading the wrong Limine response field. Check the pinned `limine.h`.

### Only checkable later

- **Correct behaviour when an interrupt handler logs** — [[Phase 3 - Overview|Phase 3]]. Until an IRQ can fire, nothing can interleave with `log_write`.
- **Correct behaviour under preemption** — [[Phase 5 - Overview|Phase 5]], where the ring gets a real IRQ-save lock.
- **Correct behaviour under `-smp 4`** — [[Phase 12 - Overview|Phase 12]]: an atomic `head` and per-core ordering.
- **`dmesg` from userspace** — the syscall that exposes this ring, once there is a userspace to call it ([[05 - Gap Analysis (v1 to Product)]]).
- **Timestamps on each line** — there is no time source until the PIT in [[Phase 3 - Overview|Phase 3]] and no good one until TSC calibration in [[Phase 11 - Overview|Phase 11]]. When one exists, add a `uint64_t` to `LogLine` and drop `LOG_LINE_CHARS` to 244 to keep the 256-byte stride.

- [ ] Builds clean with `-Wall -Wextra -Werror`
- [ ] `nm` shows `g_lines` in `.bss`; `.data` did not grow by 64 KiB
- [ ] 300 logged lines leave the newest 256; `log_lost_count()` is exactly 44
- [ ] `make test-unit` passes, including the wraparound and truncation cases
- [ ] Messages logged before `console_init()` appear on the framebuffer after it attaches
- [ ] `panic()` prints a populated `Recent log:` section
- [ ] The `(verbose)` boot entry shows `[DEBUG]` lines; the default entry does not
- [ ] A 400-character message is stored as 252 characters ending in `...`
- [ ] The test loop is removed; the machinery stays

---

## 7. Common traps

**"The oldest messages survive and the newest are lost — the log is full of boot chatter and the crash is nowhere in it."** You implemented stop-when-full: a `if (g_head >= LOG_LINES) return;` guard, or a `full` flag that suppresses writes. It is the natural reading of "the buffer is full", and it is exactly backwards for a log. A ring must always overwrite the oldest, because the value of a log line is inversely proportional to its age at the moment you read it — and the moment you read it is always after something went wrong. The fix is to delete the guard: `g_head % LOG_LINES` already does the right thing on its own, which is one of the reasons to derive the slot rather than manage an index. Confirm with the 300-line test in §6: the last line must be `line 299`.

**"A line in the dump is half one message and half another — `pmm: 512 MiB usaghi: port 0 reset timeout`."** Two causes, and they need different fixes. If you built a byte-oriented ring, this is inherent: the write pointer wrapped mid-message and the surviving tail of the old contents follows the head of the new one. The fix is structural — fixed-width slots, as in §3, so a slot is either fully overwritten or untouched. If you have fixed-width slots and still see it, your slot arithmetic is wrong: check that `copy` is clamped **before** the copy loop rather than after, that the copy loop bound is `copy` and not `len`, and that `slot.len` is assigned `stored` rather than the original `len` — a `len` of 400 stored in a 252-byte slot makes every reader run 148 bytes into the next slot.

**"Early boot messages never appear anywhere — not on screen, not in the panic dump."** Three candidates, in the order they are worth checking. *The console never replays:* `console_init()` does not call `log_register_sink`, so the console only ever sees lines written after it started; everything earlier is in the ring and on serial but never drawn. *`log_init` clears the ring:* if you added a loop zeroing `g_lines` — which looks like the responsible thing to do — it deletes exactly the history that was written before it ran. `log_init` must not clear. *Registration happens before the ring has anything in it,* which is fine, or *the sink was registered but `log_replay` walks the wrong range:* check that `first` is `end - LOG_LINES` and not `end`. Isolate it by calling `log_replay(&serial_log_sink)` manually right after `console_init` — if the lines appear on serial twice, the ring is fine and the console registration is the problem.

**"Panic prints `Recent log:` and then nothing — or twenty blank lines."** The dump is reading forward from the head instead of backward from it. `g_head % LOG_LINES` is the *next slot to be written*; once the ring has wrapped it holds the **oldest** live line, and before it has wrapped it holds a slot that was never written at all — `len == 0`, which prints as an empty line. Starting the loop at `g_head` and running forward therefore gives you either the oldest lines or nothing. The dump must start at `g_head - n`:

```cpp
    uint64_t first = (end > n) ? (end - n) : 0;   // count BACK from the head
    for (uint64_t i = first; i < end; ++i)        // then walk forward to it
```

The blank-lines variant is the more confusing one because it looks like the ring is empty when it is full. Check `log_line_count()` before concluding anything.

**"`kernel.elf` grew by 64 KiB and boots noticeably slower."** The ring landed in `.data` instead of `.bss`, so 65,536 bytes of zeroes are stored in the file and read off the disc at every boot. The cause is always an initialiser: a default member initialiser in `LogLine` (`uint8_t level = 2;`), a constructor, or an explicit fill like `char text[LOG_LINE_CHARS] = " ";`. Any of them means the object is no longer zero-initialised, so it cannot be `SHT_NOBITS`. Diagnose with `nm` — a `d`/`D` rather than `b`/`B` — and fix by removing every initialiser; the language already guarantees zero for namespace-scope objects, and [[Stage 0.4 - The Linker Script and Higher-Half Layout]] establishes that Limine honours the ELF rule that zeroes the region. A constructor is doubly wrong: it violates [[13 - Coding Standards]] rule 9 and would not run until `.init_array` at step 11 of the init order, long after the log must work. There is a second, rarer cause with the same symptom: if `.bss` is not the last allocated section in its `PT_LOAD` segment, the linker must materialise it as real bytes — [[Stage 0.4 - The Linker Script and Higher-Half Layout]] covers the placement rule.

**"The kernel hangs at `console_init()` with the screen half-drawn."** A sink that logs, plus a replay with no bound. The console sink logs something, `log_write` appends it and advances `g_head`, and a replay loop written as `i < g_head` chases a head that keeps moving. The snapshot (`const uint64_t end = g_head;` at entry) makes the loop terminate regardless, and `g_in_sink` stops the recursion. If you removed either, put it back — and note that this bug does not exist until a sink misbehaves, so it appears the day you add error logging to a driver, not the day you write the ring.

**"Every log line is followed by a blank line, and the screen scrolls twice as fast."** The trailing newline was stored in the slot *and* added by the sink. The ring is line-oriented, so a slot must never contain a line terminator: the strip loop in `log_write_n` removes it on the way in, and each sink adds whatever terminator its device wants on the way out. Deleting the strip loop because "the caller already added it" reintroduces this, and it also breaks the panic dump's alignment.

**"Nothing is logged at all after I added `log_init()`."** The threshold comparison is inverted — `if (level > g_threshold) return;` instead of `<`. With `g_threshold == LogLevel::Info` that discards `Info`, `Warn`, `Error` and `Panic` and keeps only `Trace` and `Debug`, which nothing emits by default, so the log is silent while looking configured. It is easy to write because syslog numbering runs the other way and half the reference material you will read uses it. The rule for ours: severity increases with the number, so *keep* when `level >= threshold`.

**"A `%s` in a logged message prints garbage after the console attaches."** You stored a format string and its arguments instead of formatted text. By replay time the pointer arguments are stale — the stack frame is gone, or the buffer has been reused. This is §3's last decision as a bug report. Format at the call site; the ring stores bytes it owns. Until [[Stage 1.6 - kprintf]] exists there is no formatter to get this wrong with, which is a good reason to write the two stages in this order.

---

## 8. What this unlocks

[[Stage 1.6 - kprintf]] slots straight into `log_write_n` — it renders into a stack buffer and makes one call, and nothing in `log.cpp` changes. [[Stage 1.7 - Symbolised Backtraces]] and every panic from now on gets the `Recent log:` section that [[Stage 0.7 - Panic and KASSERT]] reserved but could not fill, which turns a panic from "where did it die" into "what was it doing". From [[Phase 4 - Overview|Phase 4]] onward this ring is the primary debugging surface for every subsystem you cannot single-step: the memory manager, the scheduler, interrupt handlers. [[Phase 5 - Overview|Phase 5]] gives it a real lock, [[Phase 12 - Overview|Phase 12]] makes `g_head` atomic, and userspace eventually reads it through a `dmesg` syscall ([[05 - Gap Analysis (v1 to Product)]]).

Done wrong, the failures are quiet and expensive. A stop-when-full ring looks completely healthy — it is full of plausible lines — and it is guaranteed to be useless in every situation you built it for, and you will not discover that until you are already debugging something else. A ring that lands in `.data` costs 64 KiB on every boot for years without anyone noticing. And a `head` managed as a wrapped index rather than a monotonic count works perfectly until the day someone adds a second path that advances it, at which point the log starts writing past the end of its own array — silent memory corruption in the one subsystem whose output you have been trusting.

---

## 9. Reading

- Linux — *printk basics*: <https://www.kernel.org/doc/html/latest/core-api/printk-basics.html>
  The canonical severity list and how a runtime loglevel is applied. Read it for the level semantics; note their numbering is inverted relative to ours and why that makes their filters read backwards.
- Linux — `kernel/printk/printk_ringbuffer.c`: <https://elixir.bootlin.com/linux/latest/source/kernel/printk/printk_ringbuffer.c>
  Option C from §3, done properly: a data ring plus a descriptor ring, lock-free, NMI-safe. Read the header comment — it is a very good explanation of exactly what fixed-width slots buy you by *not* doing this.
- RFC 5424, §6.2.1 (*Syslog Protocol* — severity table): <https://www.rfc-editor.org/rfc/rfc5424>
  Where the conventional level names come from, and the numbering everyone else uses.
- `syslog(2)` — the kernel ring buffer interface: <https://man7.org/linux/man-pages/man2/syslog.2.html>
  What `dmesg` actually calls. Worth skimming now because it is the shape of the syscall this ring will eventually expose.
- Wikipedia — *Circular buffer*: <https://en.wikipedia.org/wiki/Circular_buffer>
  Short, and it lays out the empty-versus-full ambiguity that the monotonic-`head` design in §5 sidesteps entirely.
- OSDev — *Serial Ports*: <https://wiki.osdev.org/Serial_Ports>
  For the sink side, and for why a device write is the thing you want *behind* a memory write.
- doctest: <https://github.com/doctest/doctest>
  The Tier-1 framework. The `TEST_CASE`/`CHECK` subset in §6 is all you need.
- [[Stage 0.7 - Panic and KASSERT]] — step 6 of the panic sequence and the `panic_set_log_dump` hook this stage finally registers.
- [[06 - Architecture Overview]] — the initialisation order §4 amends, and the layering rule that puts the sinks in `drivers/` rather than in `lib/`.
- [[09 - Testing Strategy]] — ring-buffer wraparound as a named Tier-1 case, and why a subsystem with no device dependency is worth arranging.
- [[13 - Coding Standards]] — rule 3 (why the concurrency answer is not `volatile`), rule 6 (`[[nodiscard]]`), rule 9 (no global constructors, which is why the ring has no initialiser).

Next: **[[Stage 1.6 - kprintf]]**

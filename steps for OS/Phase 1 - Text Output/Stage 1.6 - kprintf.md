# Stage 1.6 — kprintf

**Difficulty:** Medium · ~90 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `kernel/include/kernel/printf.hpp`, `kernel/lib/printf.cpp`, `tests/unit/test_printf.cpp`
**Deliverable:** `kprintf("%d %x %s %p %llu", ...)` prints correctly to the framebuffer console, the serial log **and** the log ring, with a host-compiled Tier-1 unit test covering every specifier and every edge case.

---

## Progress

- [ ] Write `kernel/include/kernel/printf.hpp` — `KPutc`, the limits, the four API families, the `format` attributes
- [ ] Write the `Out` counted sink wrapper and `utoa_rev` in `kernel/lib/printf.cpp`
- [ ] Write `emit_int` — sign, prefix, precision zeros, width padding, emitted in that order
- [ ] Write `emit_str` — precision, null-pointer safety, the bounded scan
- [ ] Write `format_core` — the flags/width/precision/length/conversion state machine
- [ ] Handle `INT64_MIN` through `magnitude()`; never write `-v` anywhere in this file
- [ ] Add `kvfprintf`/`kfprintf` (streaming) and `kvsnprintf`/`ksnprintf` (buffer)
- [ ] Add `kvlog`/`klog`/`kvprintf`/`kprintf` on top of `log_write_n` from [[Stage 1.5 - The Log Ring Buffer and Levels]]
- [ ] Write `tests/unit/test_printf.cpp` and add it to the Tier-1 target
- [ ] Add the differential oracle: same vectors through the host `snprintf`
- [ ] Boot, print the deliverable line, confirm it reaches screen, serial and the panic dump
- [ ] Retrofit `panic()` to format through `kfprintf` with a `panic_write` sink
- [ ] Deliberately write `kprintf("%s", 42)` once, watch `-Werror` reject it, then delete it
- [ ] Committed with a message like `feat(lib): kprintf, ksnprintf and the streaming formatter`

---

## 1. Why this stage exists

[[Stage 1.5 - The Log Ring Buffer and Levels]] built somewhere to put a line. It did not build any way to *make* one. `log_write(LogLevel::Info, msg)` takes a finished `const char*`, and today the only finished strings you have are string literals. Look at what that forced in that stage's own verification section: a loop that prints line numbers by writing `buf[5] = '0' + (i / 100) % 10` three times by hand. That is what "no formatter" actually costs, and it is the reason the log ring's §3 ends with a promise that this stage keeps.

Every value you will need to see from here on is a number. A page fault handler must report `CR2`, the error code, and the faulting `RIP`. The physical memory manager must report a base, a length, and a type per region — twenty times, at boot. The scheduler must report a task ID and a stack pointer. None of those are expressible as literals, and all of them are the *only* evidence you will have, because from [[Phase 2 - Overview|Phase 2]] onward the interesting failures happen inside interrupt handlers where you cannot single-step and there is nothing to attach a debugger to.

[[Phase 1 - Overview]] states the case for building it properly rather than quickly:

> `kprintf` is the ideal Tier-1 candidate: pure logic, enormous edge-case surface, and a bug in it will mislead you about *every other* subsystem for years.

Read that second clause literally. A formatter bug does not announce itself. It produces a plausible number. If `%p` drops the top 32 bits you will read `0x80104A2C` for an address that is really `0xFFFFFFFF80104A2C`, conclude your higher-half mapping is broken, and spend a day in [[Phase 4 - Overview|Phase 4]] rewriting a page-table walker that was correct. If `%d` mishandles the most negative integer you will see a garbage value exactly once, in the one log line that mattered. The formatter is the instrument you measure everything else with, and an instrument that is wrong is worse than no instrument, because you believe it.

And there is no C library ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]). There is no `printf` to call, no `snprintf`, no `strlen`, no `abs`. Roughly 250 lines of this file are lines nobody else has written for you, which is precisely why it is worth writing them with a test suite instead of hope.

---

## 2. The concept

### What a variadic function actually is

`void kprintf(const char* fmt, ...)` compiles to a normal function with **one** declared parameter. The `...` is not a parameter; it is a promise to the compiler that the caller may push more arguments and that the callee will find them by some out-of-band means. Nothing at runtime records how many there were or what types they had. That information exists in exactly one place: the format string, at the call site, as text.

That is the entire reason `printf` is dangerous and the entire reason `__attribute__((format(printf, ...)))` matters.

Before the arguments are placed, C's **default argument promotions** apply to everything passed through `...`:

| Passed | Arrives as | Consequence |
|---|---|---|
| `char`, `signed char`, `unsigned char` | `int` | `%c` must `va_arg(ap, int)` |
| `short`, `unsigned short` | `int` | `%hd` must `va_arg(ap, int)`, then narrow |
| `bool` | `int` | |
| `float` | `double` | irrelevant here — we have no FP |
| everything else | unchanged | `int`, `long`, `long long`, `size_t`, pointers |

So there is no way to pass a `char` to a variadic function. `va_arg(ap, char)` is always wrong.

### Where the arguments physically are (SysV AMD64)

On the x86_64 System V ABI the first six integer-or-pointer arguments travel in registers — `RDI`, `RSI`, `RDX`, `RCX`, `R8`, `R9` — and the seventh onward go on the stack. `AL` carries the number of vector registers used for variadic arguments; for us it is **always zero**, because the kernel builds with `-mno-sse -mno-mmx -mno-80387` and there is nothing that could go in an XMM register.

`va_start` cannot leave the variadic arguments in registers, because the function is about to use those registers for its own work. So the prologue of a variadic function **spills them into a register save area** in its own frame, and `va_list` becomes a cursor over two regions:

```
   kprintf("%d %s", 42, "ok")
   ─────────────────────────────────────────────────────────────
   RDI = fmt         ← the one NAMED parameter
   RSI = 42          ← variadic
   RDX = "ok"        ← variadic
   AL  = 0           ← "no vector registers used" (always 0: -mno-sse)

        higher addresses
        ┌────────────────────────────────┐
        │ 7th and later arguments        │ ← overflow_arg_area starts here
        ├────────────────────────────────┤
        │ return address                 │
        ├────────────────────────────────┤
        │ saved RBP                      │
        ├────────────────────────────────┤
        │ reg_save_area:                 │   (GCC picks the exact placement;
        │   +0   RDI = fmt               │    what matters is that it exists
        │   +8   RSI = 42                │    and va_list points into it)
        │   +16  RDX = "ok"              │
        │   +24  RCX                     │
        │   +32  R8                      │
        │   +40  R9                      │
        │   +48..+175  XMM0-7            │  ← NOT emitted: -mno-sse
        └────────────────────────────────┘
        lower addresses

   va_list ap = { gp_offset, fp_offset, overflow_arg_area, reg_save_area }

   va_arg(ap, T):
       gp_offset < 48  →  read *(reg_save_area + gp_offset); gp_offset += 8
       otherwise       →  read *overflow_arg_area;  overflow_arg_area += 8
```

`gp_offset` starts at `8 × (number of named integer parameters)` — `8` here, because `fmt` occupied `RDI`. Note the second bullet of the ABI's consequence: **every integer or pointer argument occupies exactly one 8-byte slot**, whether it is an `int`, a `long`, or a `char*`.

Four things follow, and all four show up later in this note:

1. `va_arg` performs **no checking whatsoever**. It reads 8 bytes at the cursor, reinterprets them as the type you named, and advances. If you ask for `const char*` where the caller passed `7`, you get the pointer `0x7` and the next dereference faults.
2. Because slots are uniformly 8 bytes on this ABI, asking for the wrong *width* truncates the value but does **not** shift the cursor. Asking for the wrong *number of arguments* does shift it, and every specifier after that point is garbage. §7 separates these two.
3. `fp_offset` exists in the struct but nothing in this kernel will ever advance it.
4. `va_list` is a compiler construct, not a library one. `<stdarg.h>` ships with GCC as a **freestanding** header, so it is available to us. Contrast `<inttypes.h>`, which is hosted and does not exist in this toolchain — which is why there is no `PRIu64` here.

### Parsing: left to right, exactly one argument per specifier

The format string is walked once, forward, character by character. Plain characters are emitted. A `%` starts a specifier, which is consumed in a fixed order:

```
   %[flags][width][.precision][length]conversion
    │  │      │        │         │       │
    │  │      │        │         │       └─ d i u x X o b c s p %
    │  │      │        │         └───────── (none) hh h l ll z
    │  │      │        └─────────────────── digits, or '*' (reads an int arg)
    │  │      └──────────────────────────── digits, or '*' (reads an int arg)
    │  └─────────────────────────────────── - 0 + space #   (any order, any number)
    └────────────────────────────────────── the '%'
```

Only when the conversion character is reached is an argument pulled — and exactly one, except that `*` pulls an extra `int` first. The pairing between "the Nth specifier" and "the Nth argument" is positional and implicit. There is no key, no tag, no length prefix. If the format string says four specifiers and the caller passed three arguments, the fourth `va_arg` reads whatever is in `R9` or on the stack: a saved register, a return address, a stack canary, nothing. It is **undefined behaviour**, it does not fault, and it prints a plausible-looking number.

That is why the compile-time check in §3 is not a nicety.

### Integer to text in an arbitrary base

Converting a non-negative integer to base *b* is one loop:

```
    v = 3735928559, b = 16
    3735928559 % 16 = 15 → 'f'      3735928559 / 16 = 233495534
     233495534 % 16 = 14 → 'e'       233495534 / 16 = 14593470
      14593470 % 16 = 14 → 'e'        14593470 / 16 = 912091
        912091 % 16 = 11 → 'b'          912091 / 16 = 57005
         57005 % 16 = 13 → 'd'           57005 / 16 = 3563
          3563 % 16 =  b → 'b'            3563 / 16 = 222
           222 % 16 = 14 → 'e'             222 / 16 = 13
            13 % 16 = 13 → 'd'              13 / 16 = 0   stop

    produced:  f e e b d b e d
    wanted:    d e a d b e e f
```

The digits come out **least-significant first**, which is backwards. There are three ways to fix that, and §3 picks one: fill a small buffer from its *end* towards its front, then hand back a pointer to the first digit written and a length. No reversal pass, no recursion, no allocation.

Two details that are easy to get wrong. The loop must be a `do…while`, not a `while` — otherwise the value `0` produces no digits at all. And the loop is written over an **unsigned** value; the sign is handled entirely outside it, which is what makes `INT64_MIN` survivable (§5).

On x86_64 the division is a single `divq`; the base is a runtime `unsigned`, so GCC cannot turn it into a reciprocal multiply, and that is fine. (On a 32-bit target the same code would emit calls to libgcc's `__udivdi3`/`__umoddi3` — worth knowing, not a problem here.)

### Where the output goes

One formatter, several destinations, chosen by the caller:

```
   klog(level, fmt, ...)  /  kprintf(fmt, ...)
        │
        │  render once into a 256-byte stack buffer  (kvsnprintf)
        ▼
   log_write_n(level, line, len)          ← Stage 1.5's seam, unchanged
        │
        ├─► ring slot (always, cannot fail)
        └─► fan out ──► serial sink ──► UART
                   └──► console sink ─► framebuffer

   kfprintf(sink, ctx, fmt, ...)          ← streaming; bypasses the ring
        │
        └─► one char at a time ──► panic_write / serial_putc / a test buffer
```

`kprintf` deliberately does **not** call the console or the serial port. It hands a finished line to the ring, and the ring already knows how to reach both, including replaying to a console that does not exist yet. The streaming path exists for the one caller that must not touch the ring: `panic`.

---

## 3. Design decisions and tradeoffs

### Decision: write your own printf, or port a public-domain one?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — write it (chosen)** | ~250 lines of your own | A day of edge cases; you *will* get `INT64_MIN` wrong once | ✅ |
| B — port `eyalroz/printf` (the maintained fork of `mpaland/printf`) | Drop in two files, define the float-disable macro | Genuinely freestanding, MIT; but ~1400 lines you did not write and cannot enumerate | ❌ here |
| C — port `nanoprintf` | Single header, feature macros | Same shape as B, smaller | ❌ here |
| D — port newlib's or musl's `vfprintf` | Take a real libc's implementation | Pulls `malloc`, `_dtoa_r`, reentrancy structs, locale, wide chars | ❌ |

**Why A.** Two payoffs, both concrete. First, this is the project's flagship Tier-1 test target — [[09 - Testing Strategy]] names "`printf` formatting (every specifier, width, precision, edge case)" explicitly — and a test suite is only as valuable as your ability to reason about what it is covering. Enumerating the branches of a formatter you wrote takes ten minutes; enumerating the branches of a 1400-line one you imported takes an afternoon and you will not do it. Second, the edge cases *are* the lesson. `INT64_MIN`, the C99 return-value convention, `%.0d` of zero, precision-bounded `%s` on a buffer with no terminator — these are the same class of off-by-one and signed-overflow reasoning that will decide whether your allocator and your ELF loader are correct. Learning them here costs a day and no data.

**Why not B or C — and be fair about it.** They are legitimate and they are fast, and `eyalroz/printf` and `nanoprintf` really are dependency-free: `<stdarg.h>`, `<stddef.h>`, `<stdint.h>` and nothing else. If you were writing a driver rather than an OS, porting one would be the correct engineering call. The specific risk to name is not "ported code is bad", it is **what a ported printf can quietly drag in**:

- **libc.** Many implementations call `memcpy`, `strlen`, `strnlen` or `abort`. You have none of those yet. The link error is the *good* outcome; the bad one is that a later stage adds a `memcpy` and the dependency becomes invisible.
- **Locale.** musl's `vfprintf` reaches for locale state for `%'d` grouping and for wide characters. There is no locale in this kernel and there never will be.
- **Floating point.** This is the sharp one. Every general-purpose printf has `%f`/`%e`/`%g`, and the float path is often compiled unless you remember a specific macro (`PRINTF_SUPPORT_DECIMAL_SPECIFIERS`, `NANOPRINTF_USE_FLOAT_FORMAT_SPECIFIERS`, and friends). Under `-mno-sse -mno-80387` a `double` argument is not slow, it is a **compile error**, and a `long double` path may reach for x87 instructions that will `#UD` at runtime if the FPU was never enabled. You have to audit for that, which is most of the work of writing it yourself.

**When B would be right.** When printf is not on your learning path, when a schedule is real, or when you genuinely need full C99 including floating point (a userspace libc in [[Phase 13 - Overview|Phase 13]] will). Note the middle path §6 actually uses: write your own, then run the *same* test vectors through the host's `snprintf` as a differential oracle. You get the confidence of a mature implementation and the code is still yours.

---

### Decision: which specifiers does the kernel support?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — a deliberate subset (chosen)** | `%d %i %u %x %X %o %b %s %c %p %%`, flags, width, precision, `l`/`ll`/`z` (and `h`/`hh` tolerated) | ~250 lines; some C99 code will not port in unchanged | ✅ |
| B — full C99 | Everything, including `%f %e %g %a`, `%n`, wide chars | Impossible under `-mno-sse`; `%n` is an exploit primitive | ❌ |
| C — the bare minimum (`%d %x %s %c %%`) | Half the code | No `%p`, no `%zu`, no width — so every address print is hand-padded | ❌ |

**Why A.** The subset is chosen by what kernel code actually prints: integers in three bases, addresses, strings, characters, and `size_t`. `%b` earns its place because a kernel spends its life looking at bitfields — page-table entry flags, PCI command registers, an interrupt error code — and reading `0x2F` as `101111` in your head is a step you should not be doing manually at 2 a.m. Width and precision earn their place because aligned columns are the difference between reading a twenty-region memory map and squinting at one.

**Why floating point is excluded, and what it would actually cost.** The kernel compiles with `-mno-sse -mno-mmx -mno-80387`. That is not a stylistic preference; it is a decision about interrupt cost. The x86_64 FPU/SSE register file is 512 bytes with `FXSAVE` and larger with `XSAVE`. If *any* kernel code used floating point, then **every** interrupt entry and every context switch would have to save and restore that state, because an interrupt can land between any two instructions and the handler must not clobber the interrupted context's registers. That is hundreds of bytes of memory traffic on the hottest path in the system, added permanently, to print a number that could have been printed as a fixed-point integer. It also means `CR0.TS`/lazy-FPU games, which are a known source of subtle bugs and, historically, of security holes.

So: `%f`, `%F`, `%e`, `%E`, `%g`, `%G`, `%a`, `%A` **must not exist**. The compiler enforces half of this for you — passing a `double` through `...` under `-mno-sse` is rejected at compile time with an error naming SSE as disabled. Do not "fix" that by re-enabling SSE for one file. If you ever need a fraction, print `1234` and a `%d.%02d` pair, or print micro-units.

`%n` is excluded for a different reason: it *writes* through a caller-supplied pointer chosen by the format string. It is the primitive behind the entire format-string vulnerability class. Nothing in this kernel needs it.

**What breaks if someone adds `%f` anyway.** Best case, the build fails and they revert. Worst case they add `-msse` to one translation unit, it links, it works in QEMU, and then six months later an interrupt fires in the middle of that code and silently corrupts an XMM register belonging to something else. That bug is not findable from the symptom.

**Why not C.** No `%p` means every address is printed with `%x` and loses its top half (see §7) or is hand-assembled. No `%zu` means every `size_t` print is a cast. No width means `panic`'s backtrace does not line up. The extra hundred lines buy the entire usability of the tool.

**When B would be right.** When you build the userspace C library. Then you need C99 conformance including floats — and it lives in userspace, where FP state is saved by the context switch anyway, because user tasks are allowed to use it.

---

### Decision: fixed output buffer, or stream through a callback?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — streaming core + a buffer sink built on it (chosen)** | `format_core` emits through `void (*)(void*, char)`; `kvsnprintf` is that callback writing into memory | One indirect call per character | ✅ |
| B — buffer only | Format into `char[N]`, then write the buffer | Truncation or overflow; needs a buffer before the heap exists; every caller pays 256 bytes of stack | ❌ |
| C — streaming only | No `snprintf` at all | The log ring needs a *finished string*; you would build one by hand at every call site | ❌ |

**Why A.** The streaming shape is what makes one formatter serve every destination. The formatter never learns whether a character is going to a UART, a framebuffer, a memory buffer, or a doctest capture — it calls `out(ctx, c)`. That is the same inversion Stage 1.5 used for sinks, applied one level down, and it buys the same thing: `printf.cpp` has **zero device dependencies**, which is exactly what makes it compile on the host for a Tier-1 test.

**But both shapes are needed, and the reason is a real conflict between two consumers.** The log ring wants a *finished string*: [[Stage 1.5 - The Log Ring Buffer and Levels]] §3 decided that the ring stores rendered text rather than a format string plus arguments, because a `%s` pointer stored for later replay is a dangling pointer by the time replay happens. So `klog` must render fully before it calls `log_write_n`, and rendering fully means a buffer. Meanwhile `panic` wants a *stream*: it deliberately bypasses the ring (the ring is one of the things that might be corrupt) and writes synchronously through `panic_write`, and it must not require a 256-byte stack buffer in a handler that may already be near the end of its stack.

Hence the layering: streaming is the primitive, and `kvsnprintf` is a fifteen-line sink over it. Build it the other way round — buffer as the primitive — and the panic path is forced through a buffer it did not want, and every streaming caller inherits a truncation limit it did not need.

**Why not B.** Two failure modes. Truncation is silent unless you implement the C99 return convention (§4), and a "fixed buffer" implementation that returns `void` or returns the bytes *stored* gives the caller no way to know. Overflow is worse: the classic hand-rolled kernel `sprintf` with no size argument, given a `%s` of a long string, writes past the end of a stack array in a function that has no stack protector (`-fno-stack-protector`) and no guard page. That corrupts the return address of the function doing the logging. You will see a fault at an address that is a fragment of your own log text.

**Why not C.** The ring needs a string. So does `ksnprintf` into a `BootInfo` field, so does building a filename in [[Phase 10 - Overview|Phase 10]]. Streaming-only means every one of those callers writes its own accumulating sink, which is the buffer sink, written badly, N times.

---

### Decision: recursion or a reversed buffer for digit conversion?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — fill a small buffer backwards (chosen)** | Write `buf[63]`, `buf[62]`, … ; return a pointer + length | 64 bytes of stack; no reversal pass | ✅ |
| B — recursion | `if (v >= base) rec(v / base); emit(digit);` | One stack frame per digit; unbounded if `base` is ever 0 or 1 | ❌ |
| C — forward with a divisor table | `for (d = largest_power_of_base; d; d /= base)` | A table per base, leading-zero suppression, more code, no gain | ❌ |

**Why A.** The digits emerge least-significant-first, so *something* has to reverse them. Writing backwards into a buffer makes the reversal free: the buffer is filled from `end` toward `begin`, and the answer is the range `[first, end)`. It is the same number of lines as the recursive version, it has one stack frame instead of up to 64, and it produces a `(pointer, length)` pair — which is exactly what `emit_int` needs so it can insert the sign, the `0x`, and the precision zeros *in front of* the digits without copying them.

**Sizing it.** The worst case is base 2 of a 64-bit value: **64 digits**. Nothing can be wider, because every larger base produces fewer digits. So the buffer is exactly 64 bytes — and it is 64 rather than the folklore "64 + sign + NUL = 66" for a stated reason: **the sign and the terminator never go in this buffer.** The sign is emitted separately by `emit_int`, and the buffer is not a C string; we return a pointer and a length. If you ever change that — store the `-` in the buffer, or NUL-terminate it — you must add the bytes back. Precision zeros never go in it either: `%.200d` is legal C, and an implementation that pre-filled the conversion buffer with precision zeros would write 200 bytes into a 64-byte array. Ours pads them at emit time, so precision is bounded only by the field clamp.

**Why not B.** In application code recursion here is fine, and bounded at 64 frames. In a kernel it is wrong for three compounding reasons. The stack is a fixed allocation shared with interrupt handlers, there is no guard page under it yet, and `-fno-stack-protector` is on — so an overflow is not a clean fault, it is silent corruption of whatever the linker placed below. `base` is derived from the **format string**, which is data: a parser bug that lets `base` reach `1` turns `v / base == v` into infinite recursion, and `base == 0` is a `#DE` divide error. And the subsystem that dies is the one you would use to debug the death. A stack overflow inside the printer produces a fault whose backtrace points at the printer, which is exactly the misdirection that costs a day.

**When B would be right.** In a host-side tool, or in the Tier-1 test harness itself, where a stack overflow is a clean crash with a real debugger attached and the recursion depth is provably bounded by the type width.

---

### Decision: `__attribute__((format(printf, N, M)))` — on or off?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — on every printf-like declaration (chosen)** | GCC type-checks the format string against the arguments at every call site | Zero runtime; the checker only knows *standard* specifiers, so `%b` may warn | ✅ |
| B — no attribute | Nothing is checked | Every format bug is a runtime bug, found by reading wrong output | ❌ |
| C — a checked macro wrapper | `#define KPRINTF(...) do { if (0) printf(__VA_ARGS__); kprintf(__VA_ARGS__); } while (0)` | Works, but needs a `printf` declaration you do not have | ❌ |

**Why A.** It is the cheapest bug-class elimination available anywhere in this project. `-Wformat` is already enabled by `-Wall`, and `-Werror` is already on, so adding one attribute per declaration converts an entire family of silent runtime corruption into build failures:

| You wrote | GCC says | Would have happened |
|---|---|---|
| `kprintf("%s", 42)` | expects `char*`, argument has type `int` | dereference of `0x2A` → page fault |
| `kprintf("%d %d", 1)` | too few arguments for format | second `va_arg` reads a saved register |
| `kprintf("%p", addr)` where `addr` is `uintptr_t` | expects `void*` | works today; breaks on any ILP32 target |
| `kprintf("%u", some_long)` | expects `unsigned int` | reads the low 32 bits, silently |
| `kprintf("%d")` | too few arguments | garbage integer |

Zero runtime cost, zero code size, five characters of typing. Turning it down is not a defensible engineering position.

**The costs, stated honestly.** Three of them.

1. **The checker only knows ISO C.** `%b` is our extension. GCC 12 and later know `%b` as C23's binary conversion, but whether that acceptance applies in `-std=c++20` mode is version-dependent. Test it once on the pinned GCC 14.2.0: write `kprintf("%b\n", 5u)` and build. If `-Werror` rejects it, your options are (a) drop `%b`, (b) wrap the handful of call sites that use it in `#pragma GCC diagnostic ignored "-Wformat"`, or (c) drop the attribute — which is by far the worst trade, because you would give up the whole table above to keep one specifier.
2. **The argument indices are 1-based over the *declared* parameter list, and for a non-static C++ member function the implicit `this` is argument 1.** So a free function `f(const char* fmt, ...)` is `format(printf, 1, 2)` but a member function with the same signature is `format(printf, 2, 3)`. Getting this wrong does not error; it silently checks the wrong parameter or checks nothing.
3. **`va_list` forwarders need the `0` form.** `kvfprintf(KPutc, void*, const char*, va_list)` is declared `format(printf, 3, 0)` — "check the format string itself, there is no argument list to check". That is what lets `kfprintf` pass a non-literal `fmt` through to it without tripping `-Wformat-nonliteral` (not in `-Wall`; enable it with `-Wformat=2` if you want it).

**Why not B.** Because the bug class it catches is invisible at runtime by construction. A `%d` given a pointer prints a number. You will read that number.

**When C would be right.** On a compiler with no `format` attribute at all. Not applicable: [[ADR-0005 - Containerised Pinned Toolchain]] pins GCC.

---

### Decision: does `kprintf` write to the log ring, or to the devices?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — render, then one `log_write_n` (chosen)** | The ring fans out to serial and console | One render, one call | ✅ |
| B — render, then call serial and console directly | Bypasses the ring | `kprintf` output is missing from `dmesg` and from the panic dump | ❌ |
| C — both | Ring *and* direct device writes | Every line printed twice | ❌ |

**Why A.** [[Stage 1.5 - The Log Ring Buffer and Levels]] already solved fan-out, replay-to-a-late-console, and level filtering. Reusing it means `kprintf` output is automatically in the panic dump, automatically on a console that had not initialised when the line was written, and automatically suppressible with `loglevel=`. It also keeps the layering clean: `printf.cpp` and `log.cpp` are both `lib/`, so this is a sideways call, not the upward call into `drivers/` that [[06 - Architecture Overview]] forbids.

**Why not B.** It reintroduces exactly the loss the previous stage removed. `kprintf` is the call every subsystem will use, so B means the *majority* of kernel output never enters the ring and the `Recent log:` section of a panic contains only the handful of hand-written `log_write` literals.

**Why not C.** Doubled output, and worse, doubled at different times: the ring's console sink draws the line, and then the direct call draws it again. You will chase a phantom loop.

**When B would be right.** In the panic path, and only there. `panic` cannot depend on the ring's sink table being intact, so it formats through `kfprintf` with a `panic_write` sink and reaches serial directly. That is not an exception to the rule; it is the reason the streaming API exists.

---

## 4. Specification

### Grammar

```
%[flags][width][.precision][length]conversion
```

Everything except `%` and the conversion character is optional. Order is fixed.

### Flags

| Flag | Applies to | Effect |
|---|---|---|
| `-` | all | Left-justify inside `width`. Overrides `0`. |
| `0` | `d i u x X o b p` | Pad with `0` **after** the sign and prefix. Ignored when `-` is present or a precision is given. |
| `+` | `d i` | Always emit a sign. Overrides the space flag. |
| ` ` | `d i` | Emit a space where `+` would emit nothing. |
| `#` | `x X o b` | Emit `0x` / `0X` / `0` / `0b`, **only when the value is non-zero**. |

### Width and precision

| Form | Meaning |
|---|---|
| `%8d` | Minimum field width 8; pad with spaces (or `0` with the `0` flag). |
| `%*d` | Width taken from an `int` argument read **before** the value. A negative width means `-` with `|w|`. |
| `%.5d` | Integers: minimum digit count, zero-filled on the left. |
| `%.3s` | Strings: **maximum** bytes read. The array need not be NUL-terminated. |
| `%.d` | Precision 0. For an integer value of 0 this produces **no characters**. |
| `%.*d` | Precision from an `int` argument. Negative means "no precision". |

Both are clamped to `KPRINTF_FIELD_MAX` (1024). A format string is data; `%2000000000d` must not become a two-billion-iteration pad loop.

### Length modifiers

| Modifier | `d`/`i` reads | `u x X o b` reads | Bits on x86_64 |
|---|---|---|---|
| *(none)* | `int` | `unsigned int` | 32 |
| `hh` | `int`, narrowed to `signed char` | `unsigned int` → `unsigned char` | 8 |
| `h` | `int`, narrowed to `short` | `unsigned int` → `unsigned short` | 16 |
| `l` | `long` | `unsigned long` | 64 |
| `ll` | `long long` | `unsigned long long` | 64 |
| `z` | `ptrdiff_t` | `size_t` | 64 |

`hh` and `h` are accepted rather than argued for: the value has already been promoted to `int`, so the modifier only controls the narrowing. Supporting them costs six lines and keeps `-Wformat` happy for code that prints a byte.

**On this target `uint64_t` is `unsigned long`, not `unsigned long long`.** So `%lu` is the specifier `-Wformat` will accept for a `uint64_t`; `%llu` is correct only for a value actually declared `unsigned long long`. Both read the same 8 bytes and both *work* — but the entire value of the format attribute is that it is right, so match it. There is no `PRIu64`: `<inttypes.h>` is a hosted header and does not exist here.

### Conversions

| Conv | Argument | Base | Notes |
|---|---|---|---|
| `d` `i` | signed | 10 | Sign handled outside the conversion loop. |
| `u` | unsigned | 10 | |
| `x` | unsigned | 16 | lowercase |
| `X` | unsigned | 16 | uppercase |
| `o` | unsigned | 8 | |
| `b` | unsigned | 2 | Our extension. Not ISO C. |
| `c` | `int` (promoted `char`) | — | Width applies; precision does not. |
| `s` | `const char*` | — | `nullptr` prints `(null)`. Precision bounds the read. Unbounded reads are capped at `KPRINTF_STR_MAX`. |
| `p` | `void*` | 16 | **Always** `0x` + exactly 16 uppercase digits. |
| `%` | none | — | Consumes no argument. |

### Deliberately excluded

| Excluded | Why |
|---|---|
| `%f %F %e %E %g %G %a %A` | No floating point. `-mno-sse -mno-mmx -mno-80387`; supporting FP would mean saving 512+ bytes of FPU state on every interrupt entry and every context switch. |
| `%n` | Writes through a caller pointer selected by the format string. The format-string exploit primitive. |
| `%ls %lc` and wide chars | No `wchar_t` story, no locale, no libc. |
| `'` (grouping), `$` (positional) | Locale and POSIX extensions with no kernel use. |

### Return values

| Function | Returns |
|---|---|
| `kvfprintf` / `kfprintf` | Characters produced. |
| `kvsnprintf` / `ksnprintf` | **Characters that WOULD have been written**, excluding the NUL — C99 7.21.6.5. So `ret >= size` means the output was truncated. `-1` only if the count exceeds `INT_MAX`. |
| `kprintf` / `klog` | `void`. |

`ksnprintf` writes at most `size` bytes **including** the terminator, always NUL-terminates when `size > 0`, and touches nothing at all when `size == 0` (so `ksnprintf(nullptr, 0, fmt, ...)` is the legal way to measure a string).

### Limits and stack

| Object | Size | Lives in |
|---|---|---|
| Conversion buffer | 64 B | `emit_int`'s frame |
| `klog` line buffer | `KPRINTF_LINE_MAX` = 256 B | `kvlog`'s frame |
| Width/precision clamp | `KPRINTF_FIELD_MAX` = 1024 | — |
| Unbounded `%s` scan cap | `KPRINTF_STR_MAX` = 1024 | — |
| Maximum call depth | 4 frames, no recursion | — |

256 is chosen against the log slot: `LOG_LINE_CHARS` is 252, so a render longer than 252 arrives at `log_write_n` with `len > 252` and is truncated *and marked* with `...` by the ring. A 256-byte buffer therefore never hides a truncation.

---

## 5. Writing the code

### `kernel/include/kernel/printf.hpp`

The formatting interface: the character-sink type, the limits, and four families of entry point.

```cpp
#pragma once

// <stdarg.h> is a FREESTANDING header — GCC ships it itself, it is not part of
// libc, and it is available to us. Contrast <inttypes.h>, which is hosted and
// does not exist in this toolchain: there is no PRIu64 here.
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include <kernel/log.hpp>   // LogLevel; klog() routes through the ring

// ------------------------------------------------------------------ shape --

// The one output primitive the formatter knows about. `ctx` is opaque to the
// formatter and handed back untouched, which is what lets a single formatter
// drive the serial port, the framebuffer console, a memory buffer and the
// panic path without knowing that any of them exist.
using KPutc = void (*)(void* ctx, char c);

inline constexpr size_t KPRINTF_LINE_MAX  = 256;   // klog's stack buffer
inline constexpr size_t KPRINTF_FIELD_MAX = 1024;  // clamp on width/precision
inline constexpr size_t KPRINTF_STR_MAX   = 1024;  // clamp on an unterminated %s

// -------------------------------------------------------------- streaming --
//
// Emits every byte through `out`. Never allocates, never blocks, bounded
// stack, no recursion — safe from an interrupt handler and from panic().

int kvfprintf(KPutc out, void* ctx, const char* fmt, va_list ap)
    __attribute__((format(printf, 3, 0)));

int kfprintf(KPutc out, void* ctx, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

// ----------------------------------------------------------------- buffer --
//
// C99 semantics: writes at most `size` bytes INCLUDING the NUL, always
// NUL-terminates when size > 0, writes nothing when size == 0, and returns the
// number of characters that WOULD have been written. ret >= size == truncated.

int kvsnprintf(char* buf, size_t size, const char* fmt, va_list ap)
    __attribute__((format(printf, 3, 0)));

int ksnprintf(char* buf, size_t size, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

// -------------------------------------------------------------------- log --
//
// The everyday calls. Render into a stack buffer, split on embedded newlines,
// and hand finished lines to the ring — which fans out to serial and console
// and keeps the history for panic(). kprintf() is klog() at LogLevel::Info.

void kprintf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void kvprintf(const char* fmt, va_list ap) __attribute__((format(printf, 1, 0)));

void klog(LogLevel level, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void kvlog(LogLevel level, const char* fmt, va_list ap)
    __attribute__((format(printf, 2, 0)));
```

#### Line by line

**The `KPutc` signature — `ctx` first, `char` second**
```cpp
using KPutc = void (*)(void* ctx, char c);
```
A plain function pointer, for the same reason `LogSink` is one in Stage 1.5: `lib/` must not call into `drivers/`. The `void* ctx` is the difference between this and a bare `void (*)(char)`. Without it, a buffer sink would need a file-scope "current buffer" global, which is not re-entrant and would break the moment `panic` formats while `klog` is halfway through. With it, `kvsnprintf` passes `&sink` and the formatter stays stateless.

`ctx` first matches the convention that context leads; more usefully, it means an unused `ctx` in a device sink is the *first* parameter and can be written `void*` with no name, which silences `-Wunused-parameter` under `-Wextra`.

**The three limits are `inline constexpr` in the header.** They are compile-time constants, so `-Wall` sees the pad loops as bounded; `inline` avoids one copy per translation unit. The values are argued in §4 — the important relationship is `KPRINTF_LINE_MAX (256) > LOG_LINE_CHARS (252)`, which guarantees that a render long enough to be cut by the buffer is *also* long enough for the ring to mark it with `...`.

**The `format` attribute indices.** Count the declared parameters, 1-based. `kfprintf(KPutc, void*, const char*, ...)` → `fmt` is 3, the first variadic is 4 → `format(printf, 3, 4)`. `kprintf(const char*, ...)` → `(printf, 1, 2)`. `klog(LogLevel, const char*, ...)` → `(printf, 2, 3)`. For the `va_list` variants the second index is **0**, meaning "there is no argument list; check the format string itself". That zero is what lets `kfprintf` forward its non-literal `fmt` into `kvfprintf` without `-Wformat-nonliteral` complaining, and it is the reason these declarations are worth writing out rather than leaving the `v` forms unattributed.

**`kvprintf` exists so other variadic functions can forward.** A driver writing `void ahci_log(const char* fmt, ...)` does `va_start` / `kvprintf(fmt, ap)` / `va_end` — the same shape as `vprintf` in a hosted C library, for the same reason.

---

### `kernel/lib/printf.cpp`

The state machine, the two emitters, and the four public families.

```cpp
// kernel/lib/printf.cpp — the kernel's formatted output.
//
// Rules that apply to every line in this file:
//   * no libc, no libstdc++     (ADR-0007: freestanding C++20)
//   * NO FLOATING POINT, EVER   (-mno-sse -mno-mmx -mno-80387)
//   * no allocation             (there is no heap until Phase 4)
//   * no recursion              (the stack is finite and shared with IRQs)
//   * bounded stack             (one 64-byte conversion buffer, and that is all)
//   * the format string is DATA — every loop derived from it is clamped

#include <kernel/printf.hpp>

#include <kernel/log.hpp>

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

namespace {

// -------------------------------------------------------------- the sink ---

// A counted wrapper around the caller's sink. `count` is the C99 return value:
// the number of characters the format PRODUCED, which is deliberately not the
// number a buffer sink managed to store.
struct Out {
    KPutc  fn;
    void*  ctx;
    size_t count;

    void put(char c) { fn(ctx, c); ++count; }

    void write(const char* s, size_t n) {
        for (size_t i = 0; i < n; ++i)
            put(s[i]);
    }

    void pad(char c, size_t n) {
        for (size_t i = 0; i < n; ++i)
            put(c);
    }
};

// ------------------------------------------------------------ the parsed % ---

enum class Len : uint8_t { None, Char, Short, Long, LongLong, Size };

struct Spec {
    bool     left      = false;   // '-'
    bool     zero      = false;   // '0'
    bool     plus      = false;   // '+'
    bool     space     = false;   // ' '
    bool     alt       = false;   // '#'
    bool     upper     = false;   // 'X' / '%p' -> uppercase digits
    bool     is_signed = false;   // '+' and ' ' apply only here
    unsigned base      = 10;
    int      width     = 0;
    int      prec      = -1;      // -1 == "no precision given"
};

// The widest thing utoa_rev can produce: base 2 of a 64-bit value = 64 digits.
// The sign, the "0x" prefix and any precision zeros are emitted SEPARATELY and
// need no room here. Put any of them in this buffer and you must add the bytes.
inline constexpr size_t DIGITS_MAX = 64;

// ------------------------------------------------------- integer -> text ---

// Fills end[-1], end[-2], ... backwards; returns a pointer to the first digit.
// Writing backwards is how least-significant-first digits end up in the right
// order with no reversal pass and no recursion.
char* utoa_rev(char* end, uint64_t v, unsigned base, bool upper) {
    const char* const digits = upper ? "0123456789ABCDEF"
                                     : "0123456789abcdef";
    char* p = end;
    do {                                  // do-while, so 0 produces "0"
        *--p = digits[v % base];
        v /= base;
    } while (v != 0);
    return p;
}

// THE classic bug. `-v` is undefined behaviour when v == INT64_MIN, because
// +9223372036854775808 is not representable in int64_t. Convert to unsigned
// FIRST: the conversion is modular and defined, and ~u + 1 is exactly
// two's-complement negation performed in a type that cannot overflow.
uint64_t magnitude(int64_t v) {
    const uint64_t u = static_cast<uint64_t>(v);
    return (v < 0) ? (~u + 1u) : u;
}

// ---------------------------------------------------------------- emitters ---

void emit_int(Out& o, const Spec& s, uint64_t mag, bool negative,
              const char* prefix, size_t prefix_len) {
    char        buf[DIGITS_MAX];
    char* const end     = buf + DIGITS_MAX;
    char*       first   = end;
    size_t      ndigits = 0;

    // C99 7.21.6.1p8: for d,i,o,u,x,X a precision of 0 with a value of 0
    // produces NO characters. Every other case produces at least one digit.
    if (!(s.prec == 0 && mag == 0)) {
        first   = utoa_rev(end, mag, s.base, s.upper);
        ndigits = static_cast<size_t>(end - first);
    }

    char sign = 0;
    if (s.is_signed) {
        if (negative)     sign = '-';
        else if (s.plus)  sign = '+';     // '+' beats ' '
        else if (s.space) sign = ' ';
    }

    size_t zeros = 0;
    if (s.prec > 0 && ndigits < static_cast<size_t>(s.prec))
        zeros = static_cast<size_t>(s.prec) - ndigits;

    const size_t body = (sign != 0 ? 1u : 0u) + prefix_len + zeros + ndigits;
    size_t spaces = (s.width > 0 && static_cast<size_t>(s.width) > body)
                  ? static_cast<size_t>(s.width) - body
                  : 0;

    // The '0' flag turns width padding into zero padding — but it is ignored
    // when '-' is present or a precision was given.
    if (s.zero && !s.left && s.prec < 0) {
        zeros += spaces;
        spaces = 0;
    }

    if (!s.left)
        o.pad(' ', spaces);
    if (sign != 0)
        o.put(sign);                      // sign BEFORE the zeros: -0000042
    if (prefix != nullptr)
        o.write(prefix, prefix_len);
    o.pad('0', zeros);
    o.write(first, ndigits);
    if (s.left)
        o.pad(' ', spaces);
}

void emit_str(Out& o, const Spec& s, const char* str) {
    if (str == nullptr)
        str = "(null)";                   // never dereference; never fault

    size_t slen = 0;
    if (s.prec >= 0) {
        // With a precision the array need NOT be NUL-terminated: read at most
        // `prec` bytes, stopping early if a terminator turns up.
        while (slen < static_cast<size_t>(s.prec) && str[slen] != '\0')
            ++slen;
    } else {
        // Without one, bound the scan anyway. A caller with a missing NUL must
        // not walk the logger off a mapped page.
        while (slen < KPRINTF_STR_MAX && str[slen] != '\0')
            ++slen;
    }

    const size_t spaces = (s.width > 0 && static_cast<size_t>(s.width) > slen)
                        ? static_cast<size_t>(s.width) - slen
                        : 0;

    if (!s.left)
        o.pad(' ', spaces);
    o.write(str, slen);
    if (s.left)
        o.pad(' ', spaces);
}

// ------------------------------------------------------- argument fetch ---
//
// `ap` is taken BY REFERENCE: va_arg mutates the walker and the caller must
// see that mutation. See the walkthrough — by value is a real bug on some ABIs.

uint64_t fetch_unsigned(va_list& ap, Len len) {
    switch (len) {
    case Len::Char:     return static_cast<unsigned char >(va_arg(ap, unsigned int));
    case Len::Short:    return static_cast<unsigned short>(va_arg(ap, unsigned int));
    case Len::Long:     return va_arg(ap, unsigned long);
    case Len::LongLong: return va_arg(ap, unsigned long long);
    case Len::Size:     return va_arg(ap, size_t);
    case Len::None:     break;
    }
    return va_arg(ap, unsigned int);      // default promotion: never `char`
}

int64_t fetch_signed(va_list& ap, Len len) {
    switch (len) {
    case Len::Char:     return static_cast<signed char>(va_arg(ap, int));
    case Len::Short:    return static_cast<short      >(va_arg(ap, int));
    case Len::Long:     return va_arg(ap, long);
    case Len::LongLong: return va_arg(ap, long long);
    case Len::Size:     return va_arg(ap, ptrdiff_t);
    case Len::None:     break;
    }
    return va_arg(ap, int);
}

// ------------------------------------------------------ the state machine ---

int format_core(KPutc out, void* ctx, const char* fmt, va_list& ap) {
    Out o{out, ctx, 0};

    if (fmt == nullptr) {                 // a diagnostic tool must not fault
        o.write("(null fmt)", 10);
        return static_cast<int>(o.count);
    }

    for (const char* p = fmt; *p != '\0'; ++p) {
        if (*p != '%') {                  // literal run
            o.put(*p);
            continue;
        }

        ++p;                              // step past the '%'
        if (*p == '%') { o.put('%'); continue; }
        if (*p == '\0') { o.put('%'); break; }   // trailing lone '%'

        Spec s;

        // ---- flags: any order, any number -----------------------------
        for (bool scanning = true; scanning; ) {
            switch (*p) {
            case '-': s.left  = true; ++p; break;
            case '0': s.zero  = true; ++p; break;
            case '+': s.plus  = true; ++p; break;
            case ' ': s.space = true; ++p; break;
            case '#': s.alt   = true; ++p; break;
            default:  scanning = false;   break;
            }
        }

        // ---- width ------------------------------------------------------
        if (*p == '*') {
            ++p;
            int w = va_arg(ap, int);       // consumed BEFORE the value
            if (w < 0) { s.left = true; w = -w; }   // C99: negative == '-' flag
            s.width = w;
        } else {
            while (*p >= '0' && *p <= '9') {
                if (s.width < static_cast<int>(KPRINTF_FIELD_MAX))
                    s.width = s.width * 10 + (*p - '0');
                ++p;                       // always advance, even when clamped
            }
        }
        if (s.width > static_cast<int>(KPRINTF_FIELD_MAX))
            s.width = static_cast<int>(KPRINTF_FIELD_MAX);

        // ---- precision --------------------------------------------------
        if (*p == '.') {
            ++p;
            if (*p == '*') {
                ++p;
                const int pr = va_arg(ap, int);
                s.prec = (pr < 0) ? -1 : pr;       // C99: negative == absent
            } else {
                s.prec = 0;                        // "%.d" means precision 0
                while (*p >= '0' && *p <= '9') {
                    if (s.prec < static_cast<int>(KPRINTF_FIELD_MAX))
                        s.prec = s.prec * 10 + (*p - '0');
                    ++p;
                }
            }
            if (s.prec > static_cast<int>(KPRINTF_FIELD_MAX))
                s.prec = static_cast<int>(KPRINTF_FIELD_MAX);
        }

        // ---- length modifier ---------------------------------------------
        Len len = Len::None;
        switch (*p) {
        case 'h':
            ++p;
            if (*p == 'h') { ++p; len = Len::Char;  } else { len = Len::Short; }
            break;
        case 'l':
            ++p;
            if (*p == 'l') { ++p; len = Len::LongLong; } else { len = Len::Long; }
            break;
        case 'z':
            ++p;
            len = Len::Size;
            break;
        default:
            break;
        }

        // A truncated format string such as "%-8l" lands here with *p == '\0'.
        // Falling into the conversion switch would emit the NUL and then the
        // outer for-loop's ++p would step PAST the end of the string.
        if (*p == '\0') { o.put('%'); break; }

        // ---- conversion ---------------------------------------------------
        switch (*p) {
        case 'd':
        case 'i': {
            const int64_t v = fetch_signed(ap, len);
            s.base      = 10;
            s.is_signed = true;
            emit_int(o, s, magnitude(v), v < 0, nullptr, 0);
            break;
        }

        case 'u':
        case 'x':
        case 'X':
        case 'o':
        case 'b': {
            s.base  = (*p == 'u') ? 10u
                    : (*p == 'o') ?  8u
                    : (*p == 'b') ?  2u
                                  : 16u;
            s.upper = (*p == 'X');

            const uint64_t v = fetch_unsigned(ap, len);

            const char* pfx  = nullptr;
            size_t      pfxn = 0;
            if (s.alt && v != 0) {          // '#' on zero adds nothing (C99)
                if (s.base == 16)     { pfx = s.upper ? "0X" : "0x"; pfxn = 2; }
                else if (s.base == 2) { pfx = "0b";                  pfxn = 2; }
                else if (s.base == 8) { pfx = "0";                   pfxn = 1; }
            }
            emit_int(o, s, v, false, pfx, pfxn);
            break;
        }

        case 'p': {
            // Pointers are 64 bits on this target, so a pointer is ALWAYS
            // "0x" plus sixteen uppercase hex digits. Fixed width means kernel
            // addresses line up in a column, which is what makes a backtrace
            // scannable, and uppercase matches 0xFFFFFFFF80000000 as it is
            // written everywhere else in this project.
            const uintptr_t v = reinterpret_cast<uintptr_t>(va_arg(ap, void*));
            s.base      = 16;
            s.upper     = true;
            s.is_signed = false;
            s.prec      = 16;               // exactly 16 digits, zero-filled
            s.zero      = false;            // the precision already did that
            emit_int(o, s, static_cast<uint64_t>(v), false, "0x", 2);
            break;
        }

        case 'c': {
            // Default argument promotion: a char through `...` arrives as int.
            const char c = static_cast<char>(va_arg(ap, int));
            const size_t spaces = (s.width > 1)
                                ? static_cast<size_t>(s.width) - 1u : 0u;
            if (!s.left) o.pad(' ', spaces);
            o.put(c);
            if (s.left)  o.pad(' ', spaces);
            break;
        }

        case 's':
            emit_str(o, s, va_arg(ap, const char*));
            break;

        default:
            // Unknown conversion: print it literally so a typo is VISIBLE.
            // Deliberately consumes no argument — we do not know what it would
            // be, and guessing would desynchronise every specifier after it.
            o.put('%');
            o.put(*p);
            break;
        }
    }

    return static_cast<int>(o.count);
}

// ------------------------------------------------------------ buffer sink ---

struct BufSink {
    char*  buf;
    size_t cap;    // total bytes available, INCLUDING the terminator
    size_t len;    // characters produced, which may exceed cap
};

void buf_put(void* ctx, char c) {
    BufSink* s = static_cast<BufSink*>(ctx);
    // Store only while there is room for this byte AND the terminator.
    if (s->cap != 0 && s->len + 1 < s->cap)
        s->buf[s->len] = c;
    ++s->len;                             // counted either way: the return value
}

}  // namespace

// ---------------------------------------------------------------- streaming ---

int kvfprintf(KPutc out, void* ctx, const char* fmt, va_list ap) {
    if (out == nullptr)
        return 0;

    // va_copy, for two independent reasons — see the walkthrough.
    va_list args;
    va_copy(args, ap);
    const int n = format_core(out, ctx, fmt, args);
    va_end(args);
    return n;
}

int kfprintf(KPutc out, void* ctx, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int n = kvfprintf(out, ctx, fmt, ap);
    va_end(ap);
    return n;
}

// ------------------------------------------------------------------ buffer ---

int kvsnprintf(char* buf, size_t size, const char* fmt, va_list ap) {
    BufSink sink{buf, (buf == nullptr) ? size_t{0} : size, 0};

    va_list args;
    va_copy(args, ap);
    format_core(&buf_put, &sink, fmt, args);
    va_end(args);

    if (sink.cap != 0) {                  // size == 0: touch NOTHING (C99)
        const size_t term = (sink.len < sink.cap - 1) ? sink.len : sink.cap - 1;
        buf[term] = '\0';
    }

    if (sink.len > 0x7FFFFFFFu)
        return -1;                        // not representable in an int
    return static_cast<int>(sink.len);
}

int ksnprintf(char* buf, size_t size, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    const int n = kvsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}

// --------------------------------------------------------------------- log ---

void kvlog(LogLevel level, const char* fmt, va_list ap) {
    // Filter BEFORE formatting. A discarded Trace line must not pay to render
    // itself — this is the cheap half of Stage 1.5 §3's runtime threshold.
    if (!log_enabled(level))
        return;

    char line[KPRINTF_LINE_MAX];

    va_list args;
    va_copy(args, ap);
    const int produced = kvsnprintf(line, sizeof(line), fmt, args);
    va_end(args);

    if (produced <= 0)
        return;                           // nothing to say

    size_t len = static_cast<size_t>(produced);
    if (len > sizeof(line) - 1)
        len = sizeof(line) - 1;           // the render was cut; log what we got

    // The ring is line-oriented: one slot is one line. Strip the caller's
    // terminator, then split whatever is left on embedded newlines.
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
        --len;

    size_t start = 0;
    for (size_t i = 0; i <= len; ++i) {
        if (i == len || line[i] == '\n') {
            size_t n = i - start;
            if (n > 0 && line[start + n - 1] == '\r')
                --n;                      // a "\r\n" pair inside the message
            log_write_n(level, line + start, n);
            start = i + 1;
        }
    }
}

void klog(LogLevel level, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    kvlog(level, fmt, ap);
    va_end(ap);
}

void kvprintf(const char* fmt, va_list ap) { kvlog(LogLevel::Info, fmt, ap); }

void kprintf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    kvlog(LogLevel::Info, fmt, ap);
    va_end(ap);
}
```

#### Line by line

**The `Out` wrapper, and why `count` is separate from what was stored**
```cpp
struct Out {
    KPutc fn; void* ctx; size_t count;
    void put(char c) { fn(ctx, c); ++count; }
```
Every character produced goes through `put`, and `put` increments unconditionally. That single decision *is* the C99 return-value convention: `count` is the number of characters the format produced, which for a buffer sink is not the number that fitted. Increment it only when the sink stored something and `ksnprintf` loses the ability to report truncation, which is the whole reason `snprintf` returns what it returns.

`write` and `pad` are loops over `put` rather than `memcpy`/`memset` calls — there is no `memcpy` here, and the sink is a function pointer, so there is nothing to bulk-copy into anyway.

**`Spec` has default member initialisers, and that is allowed here**
```cpp
struct Spec { bool left = false; /* ... */ int prec = -1; };
```
[[Stage 1.5 - The Log Ring Buffer and Levels]] §5 forbids initialisers on the ring's state, because a namespace-scope object with an initialiser leaves `.bss` and starts costing bytes in `kernel.elf`. That rule applies to **objects with static storage duration**. `Spec` is only ever a stack local, one per specifier, so its initialisers compile to a few stores in a register-allocated frame and cost nothing in the image. `prec = -1` is the load-bearing one: `-1` means "no precision was given", which is a genuinely different state from `0` ("precision zero"), and conflating them breaks `%.0d`.

**`utoa_rev` — backwards, unsigned, `do…while`**
```cpp
char* p = end;
do {
    *--p = digits[v % base];
    v /= base;
} while (v != 0);
return p;
```
`*--p` pre-decrements, so the first write is `end[-1]` — the last byte of the buffer — and the digits accumulate towards the front in the correct order. The function returns `p`, the *first* digit; the caller derives the length as `end - p`. No reversal pass, no second buffer, no recursion.

Three things must be exactly as written. The loop is `do…while`, so `v == 0` still produces one `'0'`; a `while` loop emits nothing for zero, and `kprintf("%d", 0)` printing an empty string is a bug you will not notice for weeks because zero is boring. `v` is `uint64_t`, so `%` and `/` are unsigned — signed division of a negative value is not what you want and rounds towards zero, which produces the wrong digits. And `digits` is selected by `upper` rather than by adding `0x20`, because case conversion by arithmetic is one more place to be off by one.

**`magnitude()` — the `INT64_MIN` bug, and why it is the one to get right**
```cpp
uint64_t magnitude(int64_t v) {
    const uint64_t u = static_cast<uint64_t>(v);
    return (v < 0) ? (~u + 1u) : u;
}
```
This function exists so that the word `-v` never appears in this file.

The range of `int64_t` is asymmetric: `-9223372036854775808` to `+9223372036854775807`. There are more negative values than positive ones, so the magnitude of the most negative value **is not representable in the type**. `-INT64_MIN` is signed integer overflow, which is *undefined behaviour* — and undefined behaviour in modern GCC is not "you get a weird number". The compiler is entitled to assume it cannot happen and optimise on that basis. In practice you get one of three outcomes, and which one you get depends on optimisation level:

- The value stays `INT64_MIN` (the hardware `neg` of the sign bit is itself), and the unsigned conversion then prints `9223372036854775808` with a spurious `-`, or the digit loop runs on a negative value and prints nonsense.
- GCC deletes your `if (v < 0)` branch entirely because it "proved" that the negated value is positive.
- With `-ftrapv` or a UBSan build, it traps.

The fix is to leave the signed domain **before** negating. `static_cast<uint64_t>(v)` on a negative value is a well-defined modular conversion (and since C++20 the standard mandates two's complement, so it is exactly the bit pattern). `~u + 1` is two's-complement negation performed in an unsigned type, where overflow is defined to wrap. For `INT64_MIN`: `u = 0x8000000000000000`, `~u = 0x7FFFFFFFFFFFFFFF`, `+1 = 0x8000000000000000` = 9223372036854775808 — the correct magnitude, which does not fit in `int64_t` and does fit perfectly in `uint64_t`.

`0u - u` is the same thing written more briefly; `~u + 1` is written out because it shows the mechanism.

The sign is carried separately, as `v < 0`, evaluated on the original value before any conversion. That is why `emit_int` takes `mag` and `negative` as two parameters instead of one signed number: **the digit loop never sees a sign at all**, so there is no code path in which it could get one wrong.

**`emit_int` — the emission order is the specification**
```cpp
if (!s.left) o.pad(' ', spaces);
if (sign != 0) o.put(sign);
if (prefix != nullptr) o.write(prefix, prefix_len);
o.pad('0', zeros);
o.write(first, ndigits);
if (s.left) o.pad(' ', spaces);
```
Six statements, in an order that encodes every flag interaction. Space padding is outside everything; the sign and the `0x` prefix come next; precision zeros go *inside* the prefix; digits last. That is why `%08d` of `-42` produces `-0000042` and not `0000-042`, and why `%#010x` of `0xBEEF` produces `0x0000beef` and not `000000xbeef`. Get the order wrong and every individual case still looks nearly right, which is what makes it hard to spot by eye and easy to catch with the §6 table.

```cpp
if (s.zero && !s.left && s.prec < 0) { zeros += spaces; spaces = 0; }
```
The `0` flag does not add padding; it **converts** width padding from spaces into zeros. Writing it as a transfer rather than as a second pad makes the two mutually exclusive by construction, so a value can never be padded twice. The two guards are C99 rules, not taste: `-` beats `0`, and an explicit precision beats `0`. Drop the `s.prec < 0` guard and `%08.3d` of `5` prints `00000005` instead of the correct `     005`.

```cpp
if (!(s.prec == 0 && mag == 0)) { first = utoa_rev(...); ... }
```
The one case that produces *no digits at all*. `%.0d` of `0` is the empty string in C99, and it is not a curiosity — it is how you print an optional field. Note the guard is `s.prec == 0`, which is only reachable because `prec` defaults to `-1`; with a default of `0` this branch would swallow every zero in the kernel.

**`emit_str` — null safety and the two scan bounds**
```cpp
if (str == nullptr) str = "(null)";
```
A logger that faults on bad input is worse than no logger, because it fails at exactly the moment you need it. And a null `%s` is not hypothetical: it is what you get from an uninitialised struct field, a failed lookup that returned `nullptr`, or a `BootInfo` string the bootloader did not supply — precisely the situations you are printing *about*. Without this line the dereference is a page fault; in early boot, before [[Phase 2 - Overview|Phase 2]] gives you an IDT, a page fault with no handler is a double fault with no handler, which is a **triple fault**, which is an instant reset with no output. You lose the machine and the message.

```cpp
if (s.prec >= 0) {
    while (slen < static_cast<size_t>(s.prec) && str[slen] != '\0') ++slen;
} else {
    while (slen < KPRINTF_STR_MAX && str[slen] != '\0') ++slen;
}
```
Two different rules, both required. With a precision, C guarantees the array is read for **at most** `prec` bytes and does not require a terminator at all — so `kprintf("%.4s", not_terminated)` is legal and must not scan past four bytes. The condition order matters: `slen < prec` is checked *before* `str[slen]`, so the last iteration never reads the byte after the limit.

Without a precision, a real `printf` scans to the NUL however far that is. We clamp at `KPRINTF_STR_MAX` instead, for the same reason `log_write` uses a bounded `strlen`: a caller's missing terminator must not turn into a fault inside the diagnostic path. The honest cost is that a legitimately longer string is cut at 1024 bytes with no marker. Given that `klog`'s buffer is 256 and the ring's slot is 252, nothing routed through the log can notice; only a `kfprintf` streaming directly to serial could, and if you need that, raise the constant.

**`fetch_unsigned` / `fetch_signed` — and why `ap` is a reference**
```cpp
uint64_t fetch_unsigned(va_list& ap, Len len) { ... }
```
`va_arg` mutates the walker. If these helpers took `va_list` **by value**, whether the caller sees the advance depends entirely on how the ABI defines `va_list`:

| ABI | `va_list` is | By value would |
|---|---|---|
| x86_64 SysV (our target, and the WSL host) | `__va_list_tag[1]` — an array | work, because array parameters decay to pointers |
| AArch64 Linux | a struct | **silently break**: the callee gets a copy |
| AArch64 macOS (the teammate's laptop) | `char*` | **silently break** |

A by-value bug here does not fail loudly. The cursor never advances, so *every* specifier prints the first argument, over and over. Taking a reference makes it correct on all three, and it is the reason the Tier-1 test is worth running on a macOS host as well as under WSL.

```cpp
case Len::Char: return static_cast<unsigned char>(va_arg(ap, unsigned int));
```
Note the pattern: `va_arg` asks for `unsigned int` and the *cast* does the narrowing. That is not a shortcut, it is the ABI. Default argument promotion already widened the caller's `unsigned char` to `unsigned int` before it was placed, so asking `va_arg` for `unsigned char` would be reading a type that was never passed.

```cpp
case Len::None: break;   // then: return va_arg(ap, unsigned int);
```
The `None` case falls out of the switch to a return at the bottom rather than returning inside it. With every enumerator listed, `-Wswitch` is satisfied; with the default outside, there is no `default:` label to hide a future enumerator you forgot to handle.

**`format_core` — the outer loop and the two `%` special cases**
```cpp
for (const char* p = fmt; *p != '\0'; ++p) {
    if (*p != '%') { o.put(*p); continue; }
    ++p;
    if (*p == '%') { o.put('%'); continue; }
    if (*p == '\0') { o.put('%'); break; }
```
One forward pass, one pointer, no lookahead beyond a single character. The subtlety is the interaction between the manual `++p` inside the body and the `++p` in the loop header: the body always leaves `p` pointing at the **last character consumed**, never one past it, so the header's increment lands on the next unconsumed character. Every `++p` in the parser below obeys that contract. Break it in one branch and you either skip a character or reparse one.

`%%` is handled immediately, before flags, because `%` is not a flag and a `%-%` should not be interpreted. The second line is the truncated-format guard: `"abc%"` must print `abc%` and stop, not read `p[1]` — which is the byte after the string literal's terminator.

**The flags loop**
```cpp
for (bool scanning = true; scanning; ) {
    switch (*p) {
    case '-': s.left = true; ++p; break;
    ...
    default: scanning = false; break;
    }
}
```
Flags may appear in any order and any number of times (`%-0+8d` and `%0-+8d` are the same thing), so this is a loop rather than a fixed sequence of `if`s. Each recognised flag advances `p`; the `default` advances nothing and stops. Because `'\0'` is not a flag, a format ending mid-flags exits here and is caught by the guard further down.

Order matters against the digit parser that follows: `'0'` is a **flag** when it appears before any other digit and part of the **width** afterwards. Running the flag loop first is what makes `%08d` mean "zero-pad to 8" and `%80d` mean "pad to 80". Swap the two and both formats break.

**Width and precision — clamped inside the accumulator**
```cpp
while (*p >= '0' && *p <= '9') {
    if (s.width < static_cast<int>(KPRINTF_FIELD_MAX))
        s.width = s.width * 10 + (*p - '0');
    ++p;
}
```
The clamp is inside the loop, guarding the multiply, and the `++p` is outside the guard. Both details are deliberate. Guarding the multiply means `s.width` can never exceed `1023 * 10 + 9 = 10239`, so the accumulator cannot overflow `int` no matter how many digits the format string contains — signed overflow is undefined behaviour, and a format string is data that can come from a cmdline. Advancing `p` unconditionally means the digits are still *consumed* after the clamp engages, so `%99999999999d` parses as a clamped width followed by `d`, not as a clamped width followed by a stream of literal `9`s.

The clamp itself exists because `pad()` is a loop. `%2000000000d` on an unclamped implementation is a two-billion-iteration loop writing to a UART at 11,000 characters per second. That is not a hang you diagnose; it is a hang you power-cycle.

```cpp
s.prec = (pr < 0) ? -1 : pr;
```
C99 says a negative precision from `.*` means the precision was **omitted**, not zero. Mapping it back to the `-1` sentinel is one character and gets `%.*s` with a computed `-1` right.

**The `*` cases consume an argument before the value**
```cpp
if (*p == '*') { ++p; int w = va_arg(ap, int); ... }
```
`%*d` reads **two** arguments: the width, then the value, in that order. This is the one place where a specifier is not one-argument, and it is the one place where a parser bug produces the desynchronisation described in §7 — every specifier after it reads the wrong slot. If you would rather not carry the risk, delete the two `*` branches; nothing in this kernel needs a runtime width. They are included because they are ten lines and `-Wformat` checks them for you.

**The truncated-format guard, before the conversion switch**
```cpp
if (*p == '\0') { o.put('%'); break; }
```
This is a memory-safety line, not a formatting one. A format string like `"%-8l"` runs the flag loop, the width parser, and the length parser, and arrives here with `p` on the terminator. Without the guard, the conversion switch hits `default:` and emits `'%'` followed by `'\0'` — a NUL byte in your output — and then the outer loop's `++p` steps *past* the end of the string and keeps parsing whatever the linker put next in `.rodata`. It will print garbage until it finds a zero byte, and it may run off the section.

**`%d` / `%i` — three lines, and every one is load-bearing**
```cpp
const int64_t v = fetch_signed(ap, len);
s.base = 10; s.is_signed = true;
emit_int(o, s, magnitude(v), v < 0, nullptr, 0);
```
Everything is widened to `int64_t` first, so there is exactly one signed path in the file regardless of length modifier. `is_signed` is what gates `+` and space in `emit_int` — without it, `%+u` would emit a sign on an unsigned value, which C says it must not. `magnitude(v)` and `v < 0` are evaluated from the same original value; note that they are two separate arguments rather than one signed one, which is what keeps `emit_int` sign-free.

**The unsigned group and the `#` prefix**
```cpp
if (s.alt && v != 0) {
    if (s.base == 16)     { pfx = s.upper ? "0X" : "0x"; pfxn = 2; }
    else if (s.base == 2) { pfx = "0b";                  pfxn = 2; }
    else if (s.base == 8) { pfx = "0";                   pfxn = 1; }
}
```
`v != 0` is the C99 rule: `%#x` of `0` prints `0`, not `0x0`. The reason is that `0x0` is longer than the value and carries no information, and — more practically — `%#o` of `0` would otherwise print `00`. Octal's prefix is a single `0` for the same reason: `0777` *is* the C octal literal.

Five conversions share one block because they differ only in `base` and `upper`. Writing them as five separate cases is five copies of the prefix logic and five places to forget `v != 0`.

**`%p` — sixteen digits, always**
```cpp
s.prec  = 16;
s.zero  = false;
emit_int(o, s, static_cast<uint64_t>(v), false, "0x", 2);
```
Fixed width, implemented as a **precision** rather than a width, and that distinction is the whole trick. A width of 18 with the `0` flag would be defeated by a caller writing `%-20p`; a precision of 16 is applied to the digits themselves and survives any flag combination, so a pointer is *always* eighteen characters and columns always line up. `s.zero = false` because the precision has already done the zero filling and leaving both on would double-pad.

The prefix is passed explicitly as `"0x"` rather than going through the `alt` path, for two reasons: a pointer always gets its prefix even when the value is zero (so `nullptr` prints `0x0000000000000000` and is instantly recognisable), and the prefix stays lowercase `0x` while the digits are uppercase — matching `0xFFFFFFFF80000000` as it is written in the linker script, in [[06 - Architecture Overview]], and in every backtrace in this vault.

`va_arg(ap, void*)` is the only correct read. `-Wformat` will make callers cast: `kprintf("%p", reinterpret_cast<void*>(addr))` for a `uintptr_t`. That cast is noise at every call site and it is worth it, because it is the same check that stops someone passing a 32-bit value.

**`%c` reads an `int`**
```cpp
const char c = static_cast<char>(va_arg(ap, int));
```
Default argument promotion again. `va_arg(ap, char)` is undefined and on GCC produces a diagnostic; even where it compiles, it reads the wrong type from a slot that holds a promoted `int`.

**The `default` case does not consume an argument**
```cpp
default: o.put('%'); o.put(*p); break;
```
Printing the unknown specifier literally makes a typo visible — `kprintf("%q\n", x)` shows `%q` in the log rather than silently vanishing. Not consuming an argument is the safer of two bad options: the caller passed one, so *something* is now misaligned, but consuming a value of a type we guessed could produce a pointer we then dereference. The real answer is that `-Wformat` rejects `%q` at compile time, so this branch is reachable only from a non-literal format string.

**`buf_put` — the bounds arithmetic, stated exactly**
```cpp
if (s->cap != 0 && s->len + 1 < s->cap)
    s->buf[s->len] = c;
++s->len;
```
`cap` is the total buffer size **including** the terminator. The condition `len + 1 < cap` stores at index `len` only while `len <= cap - 2`, which reserves index `cap - 1` for the NUL, permanently and unconditionally. Written as `len < cap` instead, the last character overwrites the byte the terminator needs and you get an unterminated string; written as `len <= cap` you write one past the end.

`++s->len` is outside the guard. That is the C99 return value being accumulated even after the buffer is full, and it is the only reason a caller can detect truncation.

```cpp
if (sink.cap != 0) {
    const size_t term = (sink.len < sink.cap - 1) ? sink.len : sink.cap - 1;
    buf[term] = '\0';
}
```
Terminate at the end of what was stored, or at `cap - 1` if the output was cut. `sink.cap - 1` is safe from underflow because it is guarded by `cap != 0`. And `cap == 0` means the function writes **nothing at all** — no terminator either — which is what makes `ksnprintf(nullptr, 0, fmt, ...)` a legal way to measure a string before allocating for it.

**`va_copy` — two independent reasons**
```cpp
va_list args;
va_copy(args, ap);
const int n = format_core(out, ctx, fmt, args);
va_end(args);
```
First, the standard one: C99 7.15p3 says that after a `va_list` is passed to a function that calls `va_arg` on it, the caller's copy is **indeterminate**. `kvfprintf` receives `ap` from a caller that will still call `va_end(ap)`; copying means we never touch the caller's object.

Second, the mechanical one, and this is the one that will actually bite you: `ap` is a **parameter**. On x86_64 SysV `va_list` is an array type, so a parameter declared `va_list ap` has already decayed to `__va_list_tag*` — and a `va_list&` (a reference to an array) cannot bind to a pointer. `args` is a real local array, so it can. Try to pass the parameter straight through to `format_core` and you get a compile error whose message is about reference binding and tells you nothing about varargs.

Every entry point that hands a `va_list` onward does the copy: `kvfprintf`, `kvsnprintf`, `kvlog`. Each one pairs its `va_copy` with a `va_end` on the same line of reasoning as a `new`/`delete` pair.

**`kvlog` — filter, render, strip, split**
```cpp
if (!log_enabled(level)) return;
```
First statement, before the 256-byte buffer is even touched. Stage 1.5's runtime threshold only pays for itself if the *formatting* is skipped too; a `Trace` call inside a per-page loop that renders its message and then throws it away is exactly the cost that stage's §3 warned about.

```cpp
if (produced <= 0) return;
size_t len = static_cast<size_t>(produced);
if (len > sizeof(line) - 1) len = sizeof(line) - 1;
```
`produced` is the C99 count, which can exceed the buffer. Clamping to `sizeof(line) - 1` converts it into "how many bytes are actually in `line`". Skip this clamp and `log_write_n` is handed a length longer than the data, and it copies uninitialised stack into the ring — a slot full of whatever the last function to use that stack region left there, printed to your screen. `produced <= 0` covers the empty format and the `-1` overflow return in one comparison.

```cpp
while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) --len;
```
The ring's structural invariant is one slot, one line, and Stage 1.5's `log_write_n` strips a trailing newline itself. Stripping here as well means the *split* below sees a clean end and does not emit a phantom empty line for the terminator. `len > 0` first, so an all-newline message becomes an empty line rather than an underflowed `size_t`.

```cpp
for (size_t i = 0; i <= len; ++i) {
    if (i == len || line[i] == '\n') {
        ...
        log_write_n(level, line + start, n);
        start = i + 1;
    }
}
```
`i <= len` rather than `i < len`, so the final segment — the one with no newline after it — is flushed by the `i == len` arm. This is what turns a single multi-line `kprintf` into several ring slots, which is what [[Stage 1.5 - The Log Ring Buffer and Levels]] §5 promised when it said embedded newlines were "the caller's problem, and Stage 1.6 is where a formatter splits on them". Without it, a two-line message occupies one slot and the console prints a line ending in the middle of a row.

---

### Wiring it up

**`panic` gets a real formatter.** In `kernel/lib/panic.cpp`, replace the hand-rolled digit printing with a sink over `panic_write` — check [[Stage 0.7 - Panic and KASSERT]] for the exact names it exports:

```cpp
namespace { void panic_putc(void* /*ctx*/, char c) { panic_write(&c, 1); } }

// ... inside panic(), for the register dump:
kfprintf(&panic_putc, nullptr, "  RIP = %p  RSP = %p\n",
         reinterpret_cast<void*>(rip), reinterpret_cast<void*>(rsp));
```

This is the streaming path earning its keep: no 256-byte buffer in a handler that may be short of stack, and no dependency on the ring's sink table, which may be the thing that is corrupt.

**A serial sink for the pre-log window**, in `kernel/drivers/char/serial.cpp` — one line, and it lets you `kfprintf` before `log_init()` has run:

```cpp
void serial_putc_sink(void* /*ctx*/, char c) { serial_putc(c); }
```

**Everything else just calls `kprintf` or `klog`.** No initialisation, no `printf_init()`. The formatter has no state.

---

## 6. How to verify

### The Tier-1 host unit test is the centrepiece

[[09 - Testing Strategy]] lists "`printf` formatting (every specifier, width, precision, edge case)" as a Tier-1 case, and `printf.cpp` qualifies because it touches no hardware — the sink indirection from §3 is what buys that. **These tests compile with the HOST compiler, not `x86_64-elf-g++`.** They run natively in milliseconds, under a real debugger, with no QEMU. The host is x86_64 Linux under WSL2, which is the same LP64 data model and the same SysV `va_list` as the target, so `%lu`, `%zu` and pointer width behave identically — that equivalence is exactly why the test is meaningful. Run it on the macOS teammate's machine too: a different `va_list` representation there is a *feature*, because it catches the by-value bug from §5.

The cases that must be in the table:

| # | Call | Expected output | Return | What it catches |
|---|---|---|---|---|
| 1 | `"%d", 0` | `0` | 1 | a `while` loop instead of `do…while` |
| 2 | `"%lld", INT64_MIN` | `-9223372036854775808` | 20 | **the negation-overflow bug** |
| 3 | `"%lld", INT64_MAX` | `9223372036854775807` | 19 | the other end of the range |
| 4 | `"%d", -1` | `-1` | 2 | basic sign |
| 5 | `"%x", -1` | `ffffffff` | 8 | reads 32 bits, not 64 |
| 6 | `"%lx", -1L` | `ffffffffffffffff` | 16 | the length modifier is honoured |
| 7 | `"%p", (void*)0xFFFFFFFF80000000` | `0xFFFFFFFF80000000` | 18 | 16 digits, uppercase, `0x` |
| 8 | `"%p", nullptr` | `0x0000000000000000` | 18 | prefix present even on zero |
| 9 | `"%08d", 42` | `00000042` | 8 | zero padding |
| 10 | `"%08d", -42` | `-0000042` | 8 | **sign before the zeros** |
| 11 | `"%8d", -42` | `␣␣␣␣␣-42` | 8 | sign counts toward the width |
| 12 | `"%-8d|", 42` | `42␣␣␣␣␣␣|` | 9 | left justification |
| 13 | `"%+d", 42` / `"% d", 42` | `+42` / `␣42` | 3 | the two sign flags |
| 14 | `"%#x", 0xBEEF` | `0xbeef` | 6 | alt form |
| 15 | `"%#x", 0` | `0` | 1 | alt form suppressed on zero |
| 16 | `"%#o", 8` | `010` | 3 | octal prefix is one character |
| 17 | `"%b", 5u` / `"%#b", 5u` | `101` / `0b101` | 3 / 5 | base 2 |
| 18 | `"%.0d", 0` | *(empty)* | 0 | the no-digits case |
| 19 | `"%.5d", 42` | `00042` | 5 | precision on an integer |
| 20 | `"%8.5d", 42` | `␣␣␣00042` | 8 | width and precision together |
| 21 | `"%.3s", "abcdef"` | `abc` | 3 | precision on a string |
| 22 | `"%-6.3s|", "abcdef"` | `abc␣␣␣|` | 7 | both, left-justified |
| 23 | `"%s", (const char*)nullptr` | `(null)` | 6 | **must not fault** |
| 24 | `"%.2s"` on a 2-byte array with no NUL | `ab` | 2 | precision bounds the read |
| 25 | `"%%"` / `"abc%"` | `%` / `abc%` | 1 / 4 | literal and truncated `%` |
| 26 | `"%c", 'A'` / `"%5c", 'A'` | `A` / `␣␣␣␣A` | 1 / 5 | promotion and width |
| 27 | `"%zu", sizeof(void*)` | `8` | 1 | `size_t` length modifier |
| 28 | `"%llu", 18446744073709551615ULL` | `18446744073709551615` | 20 | the unsigned top end |
| 29 | `"%*d", 6, 42` | `␣␣␣␣42` | 6 | `*` consumes two arguments |
| 30 | `"%q"` | `%q` | 2 | unknown specifier is visible |
| 31 | `ksnprintf(b, 5, "%s", "abcdefgh")` | `abcd` + NUL | **8** | **truncation reports the full length** |
| 32 | `ksnprintf(nullptr, 0, "%d", 12345)` | *(nothing written)* | 5 | measuring without a buffer |
| 33 | `"%d %x %s %p %llu", -7, 0xDEAD, "ok", p, 42ULL` | the deliverable line | — | everything at once |

`tests/unit/test_printf.cpp`:

```cpp
#include <doctest/doctest.h>

#include <kernel/printf.hpp>

#include <stdarg.h>
#include <stdint.h>
#include <string.h>       // the TEST is hosted and may use libc; the KERNEL may not
#include <stdio.h>        // for the differential oracle only

namespace {

struct Rendered { char buf[512]; int ret; };

Rendered render(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

Rendered render(const char* fmt, ...) {
    Rendered r;
    for (char& c : r.buf) c = '\xAA';          // poison: catches a missing NUL
    va_list ap;
    va_start(ap, fmt);
    r.ret = kvsnprintf(r.buf, sizeof(r.buf), fmt, ap);
    va_end(ap);
    return r;
}

}  // namespace

#define CHECK_FMT(expect, ...)                                    \
    do {                                                          \
        Rendered r_ = render(__VA_ARGS__);                        \
        CHECK(strcmp(r_.buf, expect) == 0);                       \
        CHECK(r_.ret == static_cast<int>(strlen(expect)));        \
    } while (0)

TEST_CASE("signed integers, including the value that cannot be negated") {
    CHECK_FMT("0", "%d", 0);
    CHECK_FMT("-1", "%d", -1);
    CHECK_FMT("2147483647", "%d", 2147483647);
    CHECK_FMT("-9223372036854775808", "%lld", INT64_MIN);   // the whole point
    CHECK_FMT("9223372036854775807", "%lld", INT64_MAX);
    CHECK_FMT("-2147483648", "%d", -2147483647 - 1);
}

TEST_CASE("bases and widths are read at the right size") {
    CHECK_FMT("ffffffff", "%x", -1);                    // 32-bit read
    CHECK_FMT("ffffffffffffffff", "%lx", -1L);          // 64-bit read
    CHECK_FMT("DEAD", "%X", 0xDEADu);
    CHECK_FMT("777", "%o", 0777u);
    CHECK_FMT("101", "%b", 5u);
    CHECK_FMT("0b101", "%#b", 5u);
    CHECK_FMT("0xbeef", "%#x", 0xBEEFu);
    CHECK_FMT("0", "%#x", 0u);                          // no prefix on zero
    CHECK_FMT("010", "%#o", 8u);
    CHECK_FMT("18446744073709551615", "%llu", 18446744073709551615ULL);
    CHECK_FMT("8", "%zu", sizeof(void*));
}

TEST_CASE("pointers are always sixteen digits") {
    CHECK_FMT("0xFFFFFFFF80000000", "%p",
              reinterpret_cast<void*>(UINT64_C(0xFFFFFFFF80000000)));
    CHECK_FMT("0x0000000000000000", "%p", static_cast<void*>(nullptr));
    CHECK_FMT("0x00000000000000FF", "%p", reinterpret_cast<void*>(0xFFu));
}

TEST_CASE("flags, width and precision compose in the right order") {
    CHECK_FMT("00000042", "%08d", 42);
    CHECK_FMT("-0000042", "%08d", -42);       // sign, THEN the zeros
    CHECK_FMT("     -42", "%8d", -42);
    CHECK_FMT("42      |", "%-8d|", 42);
    CHECK_FMT("+42", "%+d", 42);
    CHECK_FMT(" 42", "% d", 42);
    CHECK_FMT("", "%.0d", 0);                 // no characters at all
    CHECK_FMT("0", "%.0d", 1);
    CHECK_FMT("00042", "%.5d", 42);
    CHECK_FMT("   00042", "%8.5d", 42);
    CHECK_FMT("     005", "%08.3d", 5);       // precision defeats the '0' flag
    CHECK_FMT("    42", "%*d", 6, 42);
    CHECK_FMT("42    |", "%*d|", -6, 42);     // negative width == left justify
}

TEST_CASE("strings: precision, null safety, no terminator required") {
    CHECK_FMT("abc", "%.3s", "abcdef");
    CHECK_FMT("abc   |", "%-6.3s|", "abcdef");
    CHECK_FMT("   abc", "%6.3s", "abcdef");
    CHECK_FMT("(null)", "%s", static_cast<const char*>(nullptr));

    const char raw[2] = {'a', 'b'};           // deliberately not terminated
    CHECK_FMT("ab", "%.2s", raw);
}

TEST_CASE("literals, escapes and unknown specifiers") {
    CHECK_FMT("%", "%%");
    CHECK_FMT("100%", "100%%");
    CHECK_FMT("abc%", "abc%");                // truncated format
    CHECK_FMT("%q", "%q");
    CHECK_FMT("A", "%c", 'A');
    CHECK_FMT("    A", "%5c", 'A');
}

TEST_CASE("truncation reports what WOULD have been written") {
    char b[5];
    memset(b, '\xAA', sizeof(b));
    const int n = ksnprintf(b, sizeof(b), "%s", "abcdefgh");
    CHECK(n == 8);                            // the C99 convention
    CHECK(strcmp(b, "abcd") == 0);            // stored, and NUL-terminated
    CHECK(b[4] == '\0');

    CHECK(ksnprintf(nullptr, 0, "%d", 12345) == 5);   // measure with no buffer

    char untouched[4] = {'z', 'z', 'z', 'z'};
    CHECK(ksnprintf(untouched, 0, "hello") == 5);
    CHECK(untouched[0] == 'z');               // size == 0 writes NOTHING
}

TEST_CASE("the deliverable line") {
    CHECK_FMT("-7 dead ok 0xFFFFFFFF80000000 42",
              "%d %x %s %p %llu", -7, 0xDEADu, "ok",
              reinterpret_cast<void*>(UINT64_C(0xFFFFFFFF80000000)), 42ULL);
}

// ---- differential oracle: our formatter against the host's ---------------
// Only for specifiers the host shares. %p and %b are excluded: glibc's %p
// formatting is its own, and %b is our extension.
TEST_CASE("matches the host snprintf on shared specifiers") {
    static const char* const fmts[] = {
        "%d", "%5d", "%-5d|", "%05d", "%+d", "% d", "%.3d", "%8.3d",
    };
    static const int vals[] = { 0, 1, -1, 42, -42, 2147483647, -2147483647 - 1 };

    for (const char* f : fmts) {
        for (int v : vals) {
            char mine[64], theirs[64];
            const int a = ksnprintf(mine, sizeof(mine), f, v);
            const int b = snprintf(theirs, sizeof(theirs), f, v);
            INFO("format=", f, " value=", v);
            CHECK(a == b);
            CHECK(strcmp(mine, theirs) == 0);
        }
    }
}
```

The test links `kernel/lib/printf.cpp`, `kernel/lib/log.cpp`, and the `tests/unit/stubs_panic.cpp` that [[Stage 1.5 - The Log Ring Buffer and Levels]] §6 already added. Check `tests/unit/CMakeLists.txt` for the exact Tier-1 target name established in [[08 - Build System]].

```sh
make test-unit
```
```
[doctest] assertions: 120 | 120 passed | 0 failed
```

If `-Werror` rejects `"%b"` in this file, that is decision 5's stated cost arriving; see §7.

### Tier 2 — print from the kernel and read it

Add to `kernel_init`, after `console_init()`:

```cpp
    kprintf("kprintf: %d %x %s %p %llu", -7, 0xDEADu, "ok",
            reinterpret_cast<void*>(UINT64_C(0xFFFFFFFF80000000)), 42ULL);
    klog(LogLevel::Warn, "align: |%8d|%-8d|%08d|", 42, 42, -42);
```

```sh
make run-serial
```
```
[INFO ] kprintf: -7 dead ok 0xFFFFFFFF80000000 42
[WARN ] align: |      42|42      |-0000042|
```

Both lines must appear **on the framebuffer as well as on serial** — that is the ring's fan-out working, and it is how you confirm `kprintf` went through `log_write_n` rather than round the side.

Then trigger a `panic("formatter test")` and confirm the same two lines are in the `Recent log:` section. If they are on screen but not in the dump, `kprintf` is bypassing the ring (decision 6, option B).

### Checkable now

- [ ] Builds clean under `-Wall -Wextra -Werror`
- [ ] `make test-unit` passes every case in the table above, including `INT64_MIN`
- [ ] The differential oracle agrees with the host `snprintf` on all shared specifiers
- [ ] `kprintf` output appears on the framebuffer, on serial, **and** in the panic dump
- [ ] `ksnprintf(nullptr, 0, ...)` returns the right length and writes nothing
- [ ] A deliberate `kprintf("%s", 42)` is rejected by `-Werror` — then delete it
- [ ] A deliberate `kprintf("%f", 1.0)` is rejected by the compiler — then delete it
- [ ] `nm build/kernel.elf | grep printf` shows no `__udivdi3` or other libgcc helper

### Only checkable later

- **Re-entrancy from an interrupt handler** — [[Phase 3 - Overview|Phase 3]]. `kvlog`'s 256-byte buffer is a stack local, so it is already per-invocation safe; the shared state is the ring, which is Stage 1.5's problem and gets its lock in [[Phase 5 - Overview|Phase 5]].
- **`%p` on a userspace pointer** — [[Phase 13 - Overview|Phase 13]]. Printing a pointer is safe; dereferencing a user `%s` from the kernel is not, and will need a copy-from-user path.
- **Symbol names next to addresses** — [[Stage 1.7 - Symbolised Backtraces]] adds a `%pS`-style lookup on top of `%p`.

---

## 7. Common traps

**"Printing `INT64_MIN` prints garbage, prints a positive number with a minus sign, or hangs."** You wrote `-v` somewhere. `-INT64_MIN` is signed integer overflow and therefore undefined behaviour: the magnitude `+9223372036854775808` does not exist in `int64_t`. What you observe depends on the optimisation level, which is the tell — a bug that changes between `Debug` and `Release` is almost always UB. At `-O0` the hardware negation of `0x8000000000000000` is itself, so the value stays negative and either prints nonsense or, if your digit loop uses signed `%` and `/`, produces negative remainders and never terminates. At `-O2` GCC may delete the `if (v < 0)` branch entirely, having "proved" the negated value is positive. The fix is `magnitude()`: convert to `uint64_t` **first**, then negate with `~u + 1`, where the arithmetic is modular and defined. Test case 2 in §6 exists for exactly this and is the single most valuable line in the suite.

**"`%p` prints only eight digits — `0x80104A2C` instead of `0xFFFFFFFF80104A2C`."** You treated the pointer as 32 bits. Three variants, all with the same symptom. `va_arg(ap, unsigned int)` for `%p` reads the low half of the slot. Assigning the pointer through an `unsigned` or `uint32_t` local truncates it. Or `%p` is routed through the same path as `%x` with no length modifier, so `fetch_unsigned` takes the `Len::None` branch and reads an `unsigned int`. The read must be `va_arg(ap, void*)` and the value must be carried in `uintptr_t`/`uint64_t` throughout. This one is expensive out of proportion to its size, because the truncated address is *plausible*: `0x80104A2C` looks like a legitimate address, so you will believe it and go looking for a mapping bug in code that is correct. Test case 7 pins it.

**"`%s` with a null pointer triple-faults — instant reboot, no output at all."** `emit_str` dereferenced `nullptr`. In early boot this is not a segfault, it is a page fault; before [[Phase 2 - Overview|Phase 2]] there is no IDT, so the fault has no handler, which is a double fault, which also has no handler, which is a **triple fault** — the CPU resets. You lose the machine and every byte of output that had not already been flushed to serial. The two-word fix is the `if (str == nullptr) str = "(null)";` at the top of `emit_str`. The general rule it stands for: a diagnostic tool must not fault on bad input, because bad input is what you built it to tell you about. Related, and worth the same care: `format_core` checks `fmt == nullptr`, and `kvfprintf` checks `out == nullptr`.

**"Output is correct up to a point, and then everything after one call is shifted — later specifiers print earlier arguments."** The `va_arg` cursor and the format string have desynchronised. On x86_64 SysV, be precise about the cause, because the folklore answer is only half right here: every integer or pointer argument occupies exactly one 8-byte slot, so asking for `int` where a `long` was passed **truncates the value but does not move the cursor**. What genuinely shifts on this ABI is consuming the wrong *number* of arguments:

- `%*d` reads two arguments (width, then value). A parser that reads the `*` width but then falls into a path that also reads a width, or one that forgets to read it at all, is off by one for the rest of the string.
- The `default:` unknown-specifier branch consuming an argument the caller did not supply, or failing to consume one the caller did.
- A conversion that returns early without pulling its argument.

The width-mismatch version is a real shift on any ABI where slots are not uniformly 8 bytes — i686, and a 32-bit host if anyone builds the Tier-1 test there — which is why the textbook wording is "`%d` given a `long`". Either way the compile-time fix is the same: the `format` attribute rejects the call site. The runtime fix is to audit every path through the conversion switch and confirm each one pulls exactly one argument, plus one more for each `*`.

**"The compiler never catches my format typos — `kprintf("%d %d", 1)` builds clean."** The `format` attribute is missing, or attached wrongly. Check three things. It must be on the **declaration in the header** that call sites include, not only on the definition. The indices must count the declared parameters 1-based: `kprintf(const char*, ...)` is `(printf, 1, 2)`, `klog(LogLevel, const char*, ...)` is `(printf, 2, 3)`, `kfprintf(KPutc, void*, const char*, ...)` is `(printf, 3, 4)`. And for a non-static C++ **member** function the implicit `this` is argument 1, so every index shifts by one — a mistake that does not error, it just silently checks the wrong parameter. Verify positively rather than assuming: add `kprintf("%s", 42);` somewhere, build, and confirm `-Werror` stops you. If it builds, the attribute is not doing anything. Then delete the line.

**"Stack corruption after a long format — the kernel faults at an address that looks like fragments of my own log text."** The conversion buffer was too small, or something that was supposed to be emitted separately was written into it. The worst case is base 2 of a 64-bit value: **64 digits**. A buffer sized for decimal (20) or hex (16) overflows the moment someone writes `%b` or `%lb`. And note what the buffer does *not* have to hold: the sign, the `0x` prefix, and the precision zeros are all emitted by `emit_int` directly to the sink, never stored. If you moved any of them into the buffer, you must add the bytes back — and precision especially, because `%.200d` is legal C and 200 zeros will not fit in any conversion buffer you would sensibly size. There is no stack protector (`-fno-stack-protector`) and no guard page under the kernel stack yet, so the overflow does not fault cleanly; it overwrites the saved return address of whichever function called into the printer, and the fault address is a fragment of your format string. If you see a fault at something like `0x0000202D646165` you are looking at ASCII in a register that should hold a code address.

**"`-Werror` rejects `%b` with a warning about an unknown conversion type character."** Decision 5's stated cost. GCC's `-Wformat` checker only knows ISO C specifiers; `%b` is our extension, and whether GCC 14 accepts it in `-std=c++20` mode is version-dependent. Three ways out, in order of preference: drop `%b` and use `%x` (you lose a convenience, nothing else); wrap the handful of call sites that need it in `#pragma GCC diagnostic push` / `ignored "-Wformat"` / `pop`; or remove the `format` attribute, which is by far the worst trade because it gives up the entire table in §3 to keep one specifier. Note that this is a *build* failure, which means it is the good kind: you find out immediately, at the call site, with a file and a line.

**"`-Werror` rejects `%llu` on a `uint64_t`."** On this target `uint64_t` is `unsigned long`, so the checked-correct specifier is `%lu`; `%llu` is for a value actually declared `unsigned long long`. Both read the same eight bytes and both produce the same output, so the code "works" — but the whole value of the attribute is that it is right, so match it. There is no `PRIu64` to reach for: `<inttypes.h>` is a hosted header and does not exist in a freestanding toolchain. If the casts become tiresome, define your own four macros in `printf.hpp`; do not define them wrong, and do not suppress the warning.

**"Digits come out backwards — `%x` of `0xDEADBEEF` prints `feebdaed`."** You emitted directly from the modulo loop instead of filling a buffer backwards. The remainders arrive least-significant first; that is arithmetic, not a bug. Either write into the buffer from its end with `*--p` and return a pointer to the first digit, or add a reversal pass. §3 explains why the first is preferred.

**"`kprintf("%d", 0)` prints an empty string."** The digit loop is a `while` rather than a `do…while`, so a value of zero never enters the body. It is easy to miss because zero is the least interesting value you will print, and you will not notice until a counter that should read `0` reads nothing at all.

**"Every `kprintf` line appears twice on the console."** Decision 6, option C. `kprintf` is calling `log_write_n` **and** writing to the console or serial directly. Delete the direct writes: the ring already fans out to both sinks. The variant where lines appear twice only *after* `console_init()` is different and is Stage 1.5's replay working correctly — the console receives the history on registration and then receives new lines live; that is one delivery each, and if you see genuine duplicates there, check that `log_register_sink` registers before it replays.

**"A multi-line `kprintf` shows as one squashed line, or the panic dump has blank rows between entries."** The newline handling in `kvlog`. The ring's invariant is one slot per line: a message containing `\n` must be split into several `log_write_n` calls, and the trailing terminator must be stripped rather than stored. Squashed lines mean you are not splitting; blank rows mean you are splitting *and* leaving the trailing newline, so the final `i == len` segment emits an empty line after every message.

---

## 8. What this unlocks

Everything from here is debugged by reading `kprintf` output. [[Stage 1.7 - Symbolised Backtraces]] builds directly on `%p` and `%s` to print `heap_expand+0x8C (kernel/mm/heap.cpp:214)` instead of a bare address, and `panic`'s register dump becomes readable the moment it formats through `kfprintf`. [[Phase 2 - Overview|Phase 2]]'s IDT work is impossible to debug without printing an interrupt vector, an error code and a faulting address; [[Phase 4 - Overview|Phase 4]] prints a twenty-region memory map that is unreadable without `%p` and width; every later `KASSERT` gains the ability to say what the value actually *was*.

Done wrong, the failures are the quiet kind and they compound. A truncated `%p` sends you hunting for a mapping bug that does not exist. A mishandled `INT64_MIN` corrupts exactly one log line, in the one run that mattered, and you will read it as evidence about the subsystem being logged. A missing `format` attribute means the whole class of argument-mismatch bugs stays runtime-only, and each one costs an afternoon of reading output that looks almost right. That is what [[Phase 1 - Overview]] means by "a bug in it will mislead you about every other subsystem for years": the printer is your instrument, and the cost of a wrong instrument is paid in every measurement you take with it. Which is why the Tier-1 suite in §6 is not optional, and why it is worth more here than anywhere else in the project.

---

## 9. Reading

- **C11 draft N1570, §7.21.6.1 — `fprintf`**: <https://port70.net/~nsz/c/c11/n1570.html#7.21.6.1>
  The normative definition of flags, width, precision, length modifiers and every conversion. §7.21.6.5 is `snprintf` and the return-value convention. Read the paragraphs on `#`, on precision zero, and on the `0` flag being ignored — those three are where hand-written formatters get it wrong.
- **System V AMD64 ABI, §3.5.7 — variable argument lists**: <https://gitlab.com/x86-psABIs/x86-64-ABI>
  The actual definition of `__va_list_tag`, `gp_offset`, `fp_offset`, `reg_save_area` and `overflow_arg_area`. Confirms the 8-byte slot rule and the `AL` vector-register count that is always zero for us.
- **cppreference — variadic functions**: <https://en.cppreference.com/w/c/variadic>
  The default argument promotions, `va_copy`, and why a `va_list` passed onward is indeterminate afterwards. Short and directly applicable.
- **GCC — common function attributes (`format`)**: <https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html>
  The exact index rules, including the `this`-shifts-by-one note for C++ member functions and the `M = 0` form for `va_list` forwarders.
- **`snprintf(3)`**: <https://man7.org/linux/man-pages/man3/snprintf.3.html>
  The return-value convention in one paragraph, plus the `size == 0` rule the buffer sink implements.
- **Linux — `lib/vsprintf.c`**: <https://elixir.bootlin.com/linux/latest/source/lib/vsprintf.c>
  A production kernel formatter. Read `format_decode` and `number()` and compare them to §5 — the structure is the same. Their `%p` extension table (`%pS`, `%pI4`, …) is what [[Stage 1.7 - Symbolised Backtraces]] will imitate.
- **`eyalroz/printf`** (maintained fork of `mpaland/printf`): <https://github.com/eyalroz/printf>
  Decision 1's option B. Genuinely freestanding, MIT. Worth reading even if you write your own, and worth checking your output against.
- **`nanoprintf`**: <https://github.com/charlesnicholson/nanoprintf>
  Single header, aggressively configurable. The smallest credible alternative.
- **OSDev — *Meaty Skeleton***: <https://wiki.osdev.org/Meaty_Skeleton>
  Shows a minimal kernel `printf` in context. Useful for the shape; note it is 32-bit and its `%p` handling is not what you want.
- **doctest**: <https://github.com/doctest/doctest>
  The Tier-1 framework. `TEST_CASE`, `CHECK`, `INFO` is the whole surface used here.
- [[Stage 1.5 - The Log Ring Buffer and Levels]] — the `log_write_n` seam this stage feeds, and §3's argument for why the ring stores rendered text rather than a format string plus arguments.
- [[Stage 0.7 - Panic and KASSERT]] — `panic_write`, the sink this stage's streaming path targets, and the reason `panic` must not go through the ring.
- [[09 - Testing Strategy]] — `printf` formatting as the named Tier-1 case, and why a subsystem with no device dependency is worth arranging.
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]] — no libc, no libstdc++, no floating point, and the flags that enforce it.
- [[13 - Coding Standards]] — the rules on `[[nodiscard]]`, on global constructors, and on bounded loops.

Next: **[[Stage 1.7 - Symbolised Backtraces]]**

# Stage 0.5 — Panic and `KASSERT`

**Difficulty:** Medium · ~45 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

Something will go wrong roughly a thousand times over this project. What the kernel
does at that moment determines whether you spend ten minutes or four hours on it.

The default behaviour of a bare kernel is to **silently reboot**. That is the worst
possible outcome: no message, no state, and QEMU spinning in a loop that tells you
nothing. This stage replaces it with a **panic**: print everything we know, then halt
with interrupts off so the message stays put.

`KASSERT` is the companion. It states an invariant that must hold by construction; if
it does not, that is a bug, and the kernel says so immediately rather than continuing
to corrupt itself.

**This is not premature.** Every Tier-2 test in [[09 - Testing Strategy]] is built on
`KASSERT`, so it must exist before the tests do. And every stage from here to Phase 15
is debugged by reading panic output.

---

## Specification

### `panic`

```cpp
[[noreturn]] void panic(const char* fmt, ...);
```

Behaviour, in this exact order — the order matters, because each step can itself
fail:

1. **Disable interrupts** (`cli`). A panic must not be interrupted.
2. **Write to serial unconditionally**, before anything else. Serial is the channel
   most likely to still work ([[ADR-0004 - Framebuffer Console Not VGA Text]]).
3. Print the message.
4. Print the register state.
5. Print a backtrace — addresses now, symbolised in Stage 1.7.
6. Print the last N lines of the log ring buffer — added in Stage 1.5.
7. If a console exists, draw the same thing on screen.
8. **Halt forever**: `for (;;) { asm("cli; hlt"); }`

### `KASSERT`

```cpp
#define KASSERT(cond) \
    do { if (!(cond)) panic("assertion failed: %s\n  at %s:%d", #cond, __FILE__, __LINE__); } while (0)
```

- `KASSERT` compiles out in release builds.
- `KASSERT_ALWAYS` never compiles out — use it where the check is cheap and the
  consequence of proceeding is corruption.
- Assert **invariants**, not conditions the outside world can cause. Asserting on user
  input turns a user bug into a kernel panic. See [[13 - Coding Standards]] rule 7.

### Why not reboot

QEMU must always run with `-no-reboot -no-shutdown`, and the kernel must never
reset on a fault. A triple fault that reboots destroys the evidence, and you get a
CI timeout instead of the message that explained everything.

---

## Your task

1. Write `kernel/lib/panic.cpp` with `panic()` following the order above.
2. Write `kernel/include/kernel/assert.hpp` with `KASSERT` and `KASSERT_ALWAYS`.
3. Capture registers. At this stage, before the IDT exists
   ([[Phase 2 - Overview|Phase 2]]), read them directly with inline assembly —
   `rsp`, `rbp`, `rip` via a label, and the general-purpose registers.
4. Walk the frame pointers for a rough backtrace: `rbp` points at the saved `rbp`,
   and the return address is just above it. Bound the walk (say 32 frames) and stop
   on a non-canonical or unmapped-looking value, or the panic handler itself will
   fault.
5. Add `-fno-omit-frame-pointer` to the debug build flags, or `rbp` is not a frame
   pointer and the walk produces nonsense.
6. Print a visually distinctive banner so a panic is unmistakable in a log.
7. Test it: call `panic("test panic: %d", 42)` at the end of `kernel_init`.

---

## How to verify

From Stage 0.7 onward, `make run-serial` with a deliberate panic should produce
something like:

```
================= KERNEL PANIC =================
test panic: 42

RAX=0000000000000000  RBX=FFFFFFFF80210000  RCX=0000000000001000
RDX=0000000000000008  RSI=0000000000000000  RDI=FFFF8000DEADBEEF
RSP=FFFFFFFF801FFE40  RBP=FFFFFFFF801FFE80  RFLAGS=00000046

Backtrace:
  #0  0xFFFFFFFF80101A2C
  #1  0xFFFFFFFF801002F1
================================================
```

Checks:

- QEMU **does not reboot**. It sits there halted with the message on screen.
- Host CPU usage is low — `hlt` is executing, not a spin loop.
- The backtrace shows at least two plausible addresses in kernel range.
- `x86_64-elf-addr2line -e build/kernel.elf 0xFFFFFFFF80101A2C` resolves to the line
  that called `panic`. Stage 1.7 automates this.

---

## Common traps

- **Panicking inside the panic handler.** Dereferencing a bad frame pointer during
  the backtrace walk causes a fault inside `panic`, which panics again, and the
  machine triple-faults — losing the original message. **Bound the walk and sanity-
  check every pointer before dereferencing it.**
- **Forgetting `cli`.** An interrupt during a panic can re-enter and scramble the
  output.
- **`hlt` without `cli` in the loop.** `hlt` wakes on the next interrupt, so the loop
  spins at full CPU. `cli; hlt` actually parks the core.
- **Omitting `-fno-omit-frame-pointer`.** At `-O2` GCC uses `rbp` as a general
  register and your backtrace is fiction. Debug builds must set this flag.
- **Trying to print to a console that does not exist yet.** Panic must work at step 5
  of the init order in [[06 - Architecture Overview]], when only serial is up. Guard
  the console path on a flag.
- **Asserting things the user can cause.** `KASSERT(fd < MAX_FD)` on a syscall
  argument means any program can panic the kernel. Return `-EBADF` instead.

---

## Reading

- OSDev — *Stack Trace*: <https://wiki.osdev.org/Stack_Trace>
- OSDev — *Kernel Debugging*: <https://wiki.osdev.org/Kernel_Debugging>
- [[14 - Debugging Playbook]] — the panic format is specified there
- [[13 - Coding Standards]] rule 7 — assert versus return

Next: **Stage 0.6 - The Linker Script and Higher-Half Layout**

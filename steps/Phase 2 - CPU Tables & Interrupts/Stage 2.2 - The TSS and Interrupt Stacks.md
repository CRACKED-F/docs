# Stage 2.2 — The TSS and Interrupt Stacks

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]
**Files you create:** `kernel/arch/x86_64/cpu/tss.hpp`, `kernel/arch/x86_64/cpu/tss.cpp`
**Files you change:** `kernel/arch/x86_64/cpu/gdt.hpp`, `kernel/arch/x86_64/cpu/gdt.cpp`, `kernel/kernel_init.cpp`
**Deliverable:** `rsp0` is set and the IST slots are populated, so that from [[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] onward a kernel stack overflow produces a readable double-fault panic with a register dump instead of a silent triple fault and reboot.

---

## Progress

- [ ] Grow the GDT array from 5 entries to 7 — the TSS descriptor takes **two** slots
- [ ] Fix `GdtPointer` to a **64-bit** base if Stage 2.1 gave it a 32-bit one
- [ ] Add the selector constants to `gdt.hpp`, including `GDT_SELECTOR_TSS`
- [ ] Write `gdt_install_tss()` in `gdt.cpp` — the 16-byte system-segment descriptor
- [ ] Write `kernel/arch/x86_64/cpu/tss.hpp` — the packed `Tss` struct and the `static_assert`s
- [ ] Write `kernel/arch/x86_64/cpu/tss.cpp` — the guarded stacks, `tss_init`, `tss_set_rsp0`
- [ ] Point every IST pointer at the **top** of its array, not the start
- [ ] Set `iopb_offset = sizeof(Tss)` so ring 3 gets no port access
- [ ] Call `tss_init()` from `kernel_init` immediately after `gdt_init()`, before the IDT
- [ ] Boot and survive `ltr` — a bad descriptor triple-faults on the spot
- [ ] Check `info registers` in the QEMU monitor shows `TR` loaded with `TSS64-busy`
- [ ] Add the Tier-1 descriptor-encoding test with the golden bytes from §6
- [ ] Confirm `.bss` grew by ~100 KiB and `kernel.elf` on disk did not
- [ ] *(deferred to Stage 2.4)* Run the stack-overflow test and get a `#DF` panic, not a reset
- [ ] Committed with a message like `feat(arch): 64-bit TSS with IST interrupt stacks`

---

## 1. Why this stage exists

Right now your kernel runs on a stack that Limine handed you, and it has exactly one
stack. Every function call, every local variable, and — from Stage 2.3 — every
interrupt frame the CPU pushes goes on that one stack. That works right up until the
stack is the thing that is broken.

Here is the failure, in order, and it is worth reading slowly because the entire stage
exists to break this chain:

1. Something recurses too deeply. A parser on malformed input, a page-fault handler
   that faults, a `kprintf` that formats a struct that formats itself. `rsp` walks
   down past the bottom of the stack.
2. It reaches a page that is not mapped. The CPU raises **#PF**, page fault — which is
   correct and useful, and is exactly what you want to happen.
3. To deliver #PF, the CPU must push a five-qword interrupt frame. It pushes it at the
   current `rsp` — which is the address that just faulted.
4. That push faults. A fault while delivering a fault is **#DF**, double fault, vector 8.
5. To deliver #DF, the CPU must push another frame. Same `rsp`. Same unmapped page.
6. A fault while delivering a double fault is a **triple fault**. There is no vector 9
   for this. The CPU asserts its shutdown cycle and the machine resets.

You get nothing. No message, no register dump, no line number. QEMU reboots to the
Limine menu and you are left staring at a working boot screen wondering what changed.
[[14 - Debugging Playbook]] calls this the worst class of bug in the project, and it is
worst precisely because the diagnostic machinery is the thing that died.

The fix is architectural, not clever. The CPU can be told: *when vector 8 fires, do not
use the current stack — switch to this other stack, unconditionally, no matter what
state `rsp` is in.* That mechanism is the **Interrupt Stack Table**, and it lives in the
**Task State Segment**. With one IST entry for the double-fault vector, step 5 above
loads a known-good `rsp` and the handler runs. You get:

```
*** DOUBLE FAULT (vector 8) ***
  rip = 0xffffffff8010a3c1   rsp = 0xffffffff801fefe0
  cr2 = 0xffffffff801fefe0   error = 0
```

That is a bug report. The other version is a reboot.

[[Phase 2 - Overview|The phase overview]] states it flatly: *"Set this up in Stage 2.2,
not later."* The temptation is to do the IDT first because the IDT is the visible,
satisfying part. Resist it. Every stack-overflow bug you write between now and whenever
you get around to the IST is a bug you cannot debug — and Phase 4's page-table code and
Phase 5's scheduler are the two places in this project most likely to produce one.

The TSS carries a second thing you need. When a ring-3 process is interrupted, the CPU
must not keep using the user stack — that pointer is under the process's control, and
trusting it is a full kernel compromise. The CPU switches to a kernel stack it reads
from `rsp0` in the TSS. **[[Phase 6 - Overview|Phase 6]] does not work at all without
it.** You are building it now because it lives in the same 104-byte structure.

---

## 2. The concept

### 2.1 What the TSS is not

If you read 32-bit material, the TSS is described as the CPU's built-in task-switching
mechanism: a hardware structure holding every register of a task, with `ljmp` to a TSS
selector performing a complete context switch in one instruction. There is a busy bit,
a back-link field, task gates in the IDT, the whole apparatus.

**All of that is gone in long mode.** AMD removed hardware task switching from x86-64.
`ltr` still exists, the TSS still exists, but the CPU will never save or restore a
register set into it. Task gates do not exist in the 64-bit IDT. Your Phase 5 scheduler
will switch contexts in software, by pushing registers and swapping `rsp`, like every
modern kernel.

What survives is a small structure the CPU reads — never writes — to answer exactly
three questions:

| Question | Field | Used by |
|---|---|---|
| "I am entering ring 0 from ring 3. Which stack?" | `rsp0` | [[Phase 6 - Overview\|Phase 6]] user mode |
| "This gate names IST slot *n*. Which stack?" | `ist1`..`ist7` | Stage 2.3 onward |
| "Ring 3 executed `in`/`out`. Is that port allowed?" | `iopb_offset` | Security, from Phase 6 |

That is the entire useful content. `rsp1` and `rsp2` exist for rings 1 and 2, which no
one has used since OS/2, and you will set them to zero.

### 2.2 Privilege-level stack switching

A CPU running ring-3 code has `rsp` pointing into the user process's stack. An
interrupt arrives — a timer tick, say. The CPU is about to run kernel code at ring 0.
Where does it push the interrupt frame?

It cannot push it on the user stack. Three reasons, any one of them fatal:

- The user stack pointer might point at unmapped memory, or at a read-only page, or at
  a kernel address the process wants to trick you into writing. The process chose it.
- The kernel would be writing its saved `rip` and `cs` to memory the process can read
  and modify while the handler runs.
- After a `fork`, the process might not have a valid stack at all.

So on any interrupt that raises the privilege level, the CPU performs a **stack
switch**: it reads `rsp0` out of the TSS, loads it into `rsp`, loads `ss` with the null
selector, and *then* pushes the frame. The old `ss:rsp` are part of what gets pushed, so
`iretq` can restore them on the way out.

```
        BEFORE (ring 3 running)              AFTER (ring 0, frame pushed)

  rsp ──► ┌───────────────┐            rsp ──► ┌───────────────┐
          │  user stack   │                    │ ss   (user)   │
          │  (untrusted)  │                    │ rsp  (user)   │  ◄── saved
          └───────────────┘                    │ rflags        │
                                               │ cs   (user)   │
          TSS.rsp0 ─────────────────────►      │ rip           │
                                               ├───────────────┤
                                               │ kernel stack  │
                                               └───────────────┘
```

Two things follow that surprise people:

**In long mode, `ss` and `rsp` are pushed on *every* interrupt**, not just on a
privilege change. In 32-bit mode the frame is three dwords for a same-ring interrupt and
five for a cross-ring one, and getting that wrong is a classic bug. x86-64 removed the
inconsistency: the frame is always five qwords (plus an error code for some vectors).

**`syscall` does not use `rsp0`.** The `syscall` instruction — which
[[06 - Architecture Overview]] commits this kernel to — performs no stack switch at all.
It loads `rip` and `rflags` and leaves `rsp` pointing at the user stack; the kernel must
switch stacks itself, in the first few instructions of the entry stub, using `swapgs` and
a per-CPU pointer. That is Phase 6's problem. `rsp0` covers *interrupts and exceptions*
arriving while user code runs, which is the timer, the keyboard, and every page fault a
process takes. Both paths matter; only one of them is this structure's job.

### 2.3 The Interrupt Stack Table

`rsp0` only helps on a privilege change. If the kernel is already in ring 0 and its own
stack is broken, `rsp0` is never consulted — the CPU keeps using the stack it has. That
is the hole the IST fills.

The IST is seven 64-bit stack pointers in the TSS. Each 16-byte IDT gate has a 3-bit
field naming one of them. When a gate with a non-zero IST index fires:

> The CPU loads `rsp` from `TSS.ist<n>`, **unconditionally**, aligns it down to a
> 16-byte boundary, and pushes the frame there — regardless of the current privilege
> level and regardless of whether the current `rsp` was valid.

"Regardless" is the whole feature. The current stack could be zero, non-canonical, or
pointing at a device MMIO region; it does not matter, because the CPU never touches it.

```
   Gate for vector 8, ist=1              TSS
  ┌────────────────────────┐        ┌──────────────┐
  │ offset  cs  ist=1  P.. │───────►│ ist1 ────────┼──► ┌──────────────┐ ◄── top
  └────────────────────────┘        │ ist2         │    │              │
                                    │ ...          │    │  16 KiB      │
   rsp is garbage — irrelevant      └──────────────┘    │  #DF stack   │
                                                        └──────────────┘
                                                        ▲ guard region
```

Two properties you must internalise now, because both become traps:

**The index is 1-based.** `0` in a gate means "do not switch stacks" — the legacy
behaviour. `1` means `ist1`. There is no slot zero. Writing `0` intending "the first
one" silently disables the feature; you will find out during a stack overflow, which is
the worst possible time.

**IST stacks are not re-entrant.** If a vector using `ist1` fires while a handler is
already running on `ist1`, the CPU loads the same top-of-stack address again and pushes
the new frame directly over the first handler's live locals. The hardware provides a
stack, not a stack *allocator*. This is why the "one shared IST stack" idea in §3.3 is a
bug, and it is why real kernels take pains to make IST handlers short and
non-faulting.

### 2.4 The whole failure, with and without

```
  WITHOUT an IST entry for #DF          WITH ist1 pointing at a good stack

  deep recursion                        deep recursion
     │                                     │
     ▼  rsp runs off the bottom            ▼  rsp runs off the bottom
  touch unmapped page                   touch unmapped page
     │                                     │
     ▼  CPU pushes #PF frame at rsp        ▼  CPU pushes #PF frame at rsp
  PUSH FAULTS                           PUSH FAULTS
     │                                     │
     ▼                                     ▼
   #DF (vector 8)                        #DF (vector 8)
     │                                     │
     ▼  CPU pushes #DF frame at rsp        ▼  gate says ist=1
  PUSH FAULTS                           rsp := TSS.ist1   ◄── known good
     │                                     │
     ▼                                     ▼
  TRIPLE FAULT ──► machine resets       handler runs ──► panic() prints
  no output whatsoever                  the frame, the registers, and a
                                        backtrace. You fix the bug.
```

The right-hand column costs 104 bytes of structure, 16 KiB of `.bss`, and about sixty
minutes. That is the trade this stage makes.

---

## 3. Design decisions and tradeoffs

### 3.1 Decision: set up the IST now, or after exceptions work?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — TSS and IST before the IDT** | Stage 2.2 populates the TSS; Stage 2.3 builds gates that already name IST slots | One stage (~60 min) before anything visible happens | ✅ |
| B — IDT first, IST retrofitted in Stage 2.5 | Gates start with `ist = 0`; the IST is added once handlers print things | Every stack-overflow bug in between is an undiagnosable reset | ❌ |
| C — Never; rely on big stacks | Make the kernel stack 1 MiB and hope | Moves the cliff, does not remove it; wastes memory per task from Phase 5 | ❌ |

**Why A.** The order in [[06 - Architecture Overview]] is not arbitrary: step 3 is
"GDT + TSS", step 4 is "IDT + exception handlers". The IDT depends on the TSS, not the
other way round — a gate's IST field is meaningless if the TSS behind it is empty. Doing
the TSS first means Stage 2.3 writes gates that are correct on the first attempt, rather
than gates that are quietly wrong and get fixed three stages later.

**Why not B.** The argument for B is real: you cannot *observe* the payoff until an IDT
exists, so B feels like it sequences the visible progress better. The problem is what
happens in the gap. Stage 2.3 and Stage 2.4 are the two hardest stages in this phase —
256 generated stubs, error-code normalisation, a saved-frame layout that Phase 5 depends
on. They are exactly the stages where you will write code that faults inside a fault
handler. Under B, every one of those shows up as a reboot loop, and you debug it by
bisecting with `-d int` traces. Under A, the same bug prints its own name. You pay the
sixty minutes either way; the question is whether you pay them before or after they
would have saved you.

**When B would be right.** If you were bringing up on real hardware with a working
JTAG/hardware debugger, or under a hypervisor that reports triple faults with full CPU
state, a triple fault is no longer opaque and the urgency drops. Also if your bring-up
order forced the IDT first for an unrelated reason — an SoC that requires a fault
handler before you can probe memory, say. Neither applies here: you are on QEMU with
`-d int`, which tells you *that* a triple fault happened but very little about *why*.

---

### 3.2 Decision: which vectors get an IST entry?

| Option | Vectors on an IST | Cost | Verdict |
|---|---|---|---|
| **A (chosen)** | #DF (8), NMI (2), #MC (18), #DB (1) | 4 × 20 KiB = 80 KiB of `.bss` | ✅ |
| B — minimal | #DF only | 20 KiB; NMI during a stack switch still kills you | ⚠️ acceptable |
| C — A plus #PF (14) | adds vector 14 | 20 KiB more, and breaks nested page faults | ❌ |
| D — every exception | all 32 on ISTs | 640 KiB, and nothing is re-entrant any more | ❌ |

**#DF (8) — always. This is not negotiable.** Double fault is the *only* vector where
the alternative to an IST stack is a triple fault. Every other exception, if it fires
with a broken stack, escalates into #DF; #DF is the last catch. Give it `ist1` and give
it nothing else to do but print.

**NMI (2) — yes.** A non-maskable interrupt can arrive at literally any instruction
boundary, including the handful of instructions in the middle of a `swapgs`/stack-switch
sequence in Phase 6 where `rsp` is briefly a user-controlled value, and including while
another handler is midway through pushing its own frame. `cli` does not stop it. If NMI
shares the interrupted stack it inherits whatever is wrong with it. It gets `ist2`.

**#MC (18) — yes.** Machine check is asynchronous hardware error reporting; like NMI it
arrives without regard to what you were doing. It fires approximately never in QEMU, so
this costs 20 KiB to be correct on real hardware in [[Phase 15 - Overview|Phase 15]].
`ist3`.

**#DB (1) — yes, but it is the one you can drop.** Debug exceptions fire on hardware
breakpoints and single-step. The reason to isolate them is that you will eventually want
to breakpoint code inside another exception handler, and a #DB that lands on the handler's
own stack makes that awkward. Linux gives #DB a dedicated exception stack for exactly
this. `ist4`. If you are short of ideas for the 20 KiB, this is the entry to cut.

**#PF (14) — no, and this is the one worth arguing about.** The case *for* is
appealing: page faults are how you detect stack overflow in the first place, so putting
#PF on a known-good stack means the overflow is caught one exception earlier, and you
get "page fault at the guard page" instead of "double fault". Cleaner message, same
information.

The case against is decisive for this kernel: **page faults nest legitimately, and IST
stacks are not re-entrant.** From [[Phase 4 - Overview|Phase 4]] onward the page-fault
handler is a real subsystem — demand paging, copy-on-write, lazy stack growth — and it
runs code that can itself take a page fault (touching a not-yet-mapped page-table page,
say). With #PF on `ist5`, the nested fault reloads the same `rsp` and overwrites the
outer handler's frame; the outer handler then returns through a corrupted stack. You
have traded a rare, loud failure for a rare, silent one. Some designs *rely* on
recursive page faults — a recursive page-table mapping scheme deliberately faults its way
into mapping the table it needs — and an IST entry makes those designs simply not work.

Leave #PF on the interrupted stack. A stack overflow then escalates #PF → #DF and lands
on `ist1`, which is diagnosable, which was the goal.

**Why not D.** Beyond the memory, putting every vector on an IST removes re-entrancy
everywhere and makes nested exceptions — which are normal, not exceptional — silently
corrupting. The IST is a tool for vectors that must survive a broken stack, not a
general-purpose stack allocator.

**When C would be right.** If you were writing a microkernel or a unikernel where the
page-fault handler is provably non-faulting — a fixed set of pre-mapped regions, no
demand paging, no CoW — then #PF cannot nest, the re-entrancy objection evaporates, and
the earlier, clearer diagnostic is worth having. Revisit this if the Phase 4 fault
handler ever becomes provably flat.

---

### 3.3 Decision: one shared IST stack, or one per vector?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — one stack per IST slot** | `ist1..ist4` point at four separate arrays | 4 × 20 KiB = 80 KiB `.bss` | ✅ |
| B — one shared stack | `ist1 = ist2 = ist3 = ist4 = same top` | 20 KiB; corrupts on any overlap | ❌ |
| C — shared, but only for the "rare" vectors | NMI and #MC share; #DF is separate | 40 KiB; the overlap you cannot rule out is exactly NMI-during-#DF | ❌ |

**Why A.** Because §2.3's non-re-entrancy is not a theoretical concern, it is the
specific bug this stage exists to avoid. Walk the shared case concretely:

1. Stack overflow escalates to #DF. The CPU loads the shared stack top and pushes.
2. The #DF handler starts building a panic message. `panic()` formats into a buffer;
   that buffer is a local, so it is at the top of the shared stack. It walks the frame
   pointer chain for a backtrace. It is doing real work, with real locals.
3. An NMI arrives. Its gate also names the shared slot. The CPU loads **the same top of
   stack** and pushes a five-qword frame right over the panic buffer and the saved
   registers.
4. The NMI handler returns with `iretq`. The #DF handler resumes with its locals
   replaced by an interrupt frame.
5. Best case: the panic prints garbage. Worst case: the handler faults on a corrupted
   pointer, which is a fault inside the double-fault handler, which is a triple fault —
   the exact outcome the IST was installed to prevent.

**Why not B.** The saving is 60 KiB. [[06 - Architecture Overview]] targets machines
with megabytes of usable RAM, the stacks live in `.bss` so they cost nothing on disk,
and they are allocated once for the life of the kernel rather than per task. 60 KiB is
0.1% of a 64 MiB machine. You are trading a tenth of a percent of memory for a class of
corruption that reproduces once a week and never under a debugger. That is a bad trade
at any price.

**When B would be right.** On a genuinely memory-constrained target — an embedded system
with 128 KiB of SRAM total, where 80 KiB of stacks is most of your RAM — sharing becomes
a real engineering decision rather than laziness. Even then, keep #DF separate and share
only among vectors you can *prove* are mutually exclusive. On this project no such proof
exists, because NMI is by definition not excludable.

---

### 3.4 Decision: how big are the stacks, and what about guard pages?

| Option | Size per stack | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — 16 KiB + 4 KiB reserved guard** | 4 pages usable, 1 page guard | 20 KiB per stack | ✅ |
| B — 4 KiB (one page) | Minimal | A `char buf[512]` in `panic()` plus a backtrace walk gets uncomfortably close | ❌ |
| C — 64 KiB | Generous | 4× the memory to solve a problem 16 KiB already solves | ❌ |
| D — 16 KiB, no guard region at all | Just the stack | Overflow silently scribbles the neighbouring `.bss` variable | ❌ |

**Why 16 KiB.** Work out what actually sits on an exception stack:

| Consumer | Bytes |
|---|---|
| Hardware interrupt frame (5 qwords + error code) | 48 |
| Saved GPRs pushed by the Stage 2.4 stub | ~120 |
| `registers_t` passed by pointer, plus alignment | ~176 |
| `panic()`'s format buffer and locals | 256–512 |
| `kprintf` / `vsnprintf` call chain, several frames | ~500 |
| Backtrace walk, symbol lookup | ~500 |
| Log-ring dump from [[Stage 1.5 - The Log Ring Buffer and Levels]] | ~300 |

That is roughly 2 KiB of genuinely-used stack for one panic, with no nesting. 4 KiB
leaves a factor of two, which is not enough margin for a structure whose entire job is
to be reliable when everything else is broken. 16 KiB leaves a factor of eight and is
the same number Linux uses for its per-task kernel stack on x86-64 (`THREAD_SIZE_ORDER
= 2`, four pages). Powers of two and page multiples matter because Phase 4 will
eventually allocate these from the page allocator, and 16 KiB is four clean pages.

**Why a guard region below each stack.** Without one, running off the bottom of a stack
writes into whatever the linker happened to place before it in `.bss` — another stack,
the log ring, a driver's buffer. The corruption is silent and shows up later somewhere
unrelated. With an *unmapped* page below the stack, the first write past the bottom
faults immediately, at the instruction that did it, with `cr2` pointing at the guard
page. That converts a memory-corruption bug into a page fault, which is the single most
valuable transformation in kernel debugging.

**The honest part.** You cannot make the guard genuinely unmapped in this stage.
Unmapping a page means editing page tables, and this kernel does not own its page tables
until [[Phase 4 - Overview|Phase 4]] — Limine built the current ones and you have no
VMM. So what Stage 2.2 does is *reserve and align*: each stack is preceded by a 4 KiB
region, and the whole object is `alignas(4096)` so that region is exactly one page on a
page boundary. Today it is ordinary writable `.bss` and an overflow will scribble it
without complaint. In Phase 4 you walk the list of these regions and unmap them, and the
protection turns on with no change to this file. Reserving now is what makes that a
five-line change later instead of a re-layout.

**When C would be right.** If a handler on an IST stack ever does something genuinely
deep — decompressing a crash dump, walking a filesystem to write a core file — 16 KiB
stops being enough and you size for the real workload. That is a Phase 15 concern.
Handlers on IST stacks should stay shallow by policy, and 16 KiB is the number that
enforces the policy without ever getting in the way.

---

### 3.5 Decision: one TSS now, or per-CPU from the start?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — one TSS, but no per-CPU state baked into the API** | A single `g_tss`; all access through functions, never a global | Phase 12 changes one file | ✅ |
| B — build per-CPU arrays now | `Tss g_tss[MAX_CPUS]` from day one | Untestable until Phase 12; invents a `MAX_CPUS` and a CPU-id source that do not exist yet | ❌ |
| C — one TSS forever | Ship it | Breaks the instant a second core boots, in a way that looks like random memory corruption | ❌ |

**Why A.** `rsp0` is inherently per-CPU: two cores can be inside the kernel at once, and
they must not be using the same kernel stack. So can the IST stacks be, for the same
reason — two cores can double-fault independently. Under SMP each core therefore needs
its own TSS, and because `ltr` takes a *selector*, each core also needs its own TSS
descriptor, which in practice means each core gets its own GDT with the descriptor at a
fixed index. That is a [[Phase 12 - Overview|Phase 12]] change and it is genuinely
involved.

What you can do now, for free, is make that change **additive** rather than a rewrite.
Three rules:

1. **`Tss` is a pure hardware-layout POD.** No statics, no methods, no CPU id inside it.
   It describes 104 bytes of memory and nothing else. Phase 12 puts it in an array or in
   a per-CPU area; the struct does not change.
2. **No caller ever touches a TSS object.** The scheduler will call
   `tss_set_rsp0(top)`, not `g_tss.rsp0 = top`. When Phase 12 makes that
   "the current CPU's TSS", every call site is already correct and only the function
   body changes. This is the rule that pays for itself.
3. **`tss_init()` fills the TSS, installs the descriptor, and runs `ltr` in one place.**
   Phase 12's AP bring-up calls the same function with a CPU index added; the sequence
   does not have to be rediscovered.

**Why not B.** Speculative generality that cannot be exercised. You would be picking
`MAX_CPUS`, inventing a "which CPU am I" accessor before the LAPIC exists to answer it
(step 13 in [[06 - Architecture Overview]]'s init order — nine steps after this one),
and writing per-CPU indexing that stays untested for ten phases. Code that has never
been executed with more than one CPU is not per-CPU code, it is per-CPU-shaped code.

**Why not C.** Named explicitly in §7 as a trap, because the symptom is so misleading:
everything works on one core, and under `make run-smp` you get corruption that looks
like a scheduler bug.

**When B would be right.** If SMP were the next phase rather than the tenth, or if
per-CPU storage already existed as a subsystem, building on it immediately would be
correct — you never want a per-CPU abstraction introduced *after* twenty call sites have
assumed a global.

---

## 4. Specification

### 4.1 The 64-bit TSS — exact layout, 104 bytes

Intel SDM Vol. 3A, "64-Bit TSS Format". Note that the 8-byte fields are **not**
naturally aligned — `rsp0` sits at offset 4. This is why the struct must be packed.

| Offset | Size | Field | Value you write |
|---|---|---|---|
| `0x00` | 4 | reserved | `0` |
| `0x04` | 8 | `rsp0` — ring 0 stack | top of a kernel stack |
| `0x0C` | 8 | `rsp1` — ring 1 stack | `0` (unused) |
| `0x14` | 8 | `rsp2` — ring 2 stack | `0` (unused) |
| `0x1C` | 8 | reserved | `0` |
| `0x24` | 8 | `ist1` | top of the #DF stack |
| `0x2C` | 8 | `ist2` | top of the NMI stack |
| `0x34` | 8 | `ist3` | top of the #MC stack |
| `0x3C` | 8 | `ist4` | top of the #DB stack |
| `0x44` | 8 | `ist5` | `0` |
| `0x4C` | 8 | `ist6` | `0` |
| `0x54` | 8 | `ist7` | `0` |
| `0x5C` | 8 | reserved | `0` |
| `0x64` | 2 | reserved | `0` |
| `0x66` | 2 | `iopb_offset` | `104` (`sizeof(Tss)`) |
| | | **total** | **`0x68` = 104 bytes** |

**`iopb_offset` semantics.** It is the offset, from the TSS base, at which the I/O
permission bitmap begins. The rule (SDM Vol. 1, "I/O Permission Bit Map"): *if the
bitmap's base offset is greater than or equal to the TSS segment limit, there is no
bitmap, and every I/O instruction from CPL > IOPL faults with #GP.* With the segment
limit set to 103 and `iopb_offset` set to 104, `104 >= 103` holds and all ports are
denied. That is what you want.

### 4.2 The TSS descriptor in the GDT — 16 bytes

A **system-segment** descriptor in long mode is 16 bytes, occupying two consecutive
8-byte GDT slots. Code and data descriptors remain 8 bytes; only system descriptors
(TSS, LDT, call gates) are doubled, because they need a full 64-bit base.

**Low 8 bytes** — identical in shape to an ordinary 8-byte descriptor:

| Bits | Field | Value here |
|---|---|---|
| 0–15 | limit[15:0] | `0x0067` (103) |
| 16–31 | base[15:0] | from `&g_tss` |
| 32–39 | base[23:16] | from `&g_tss` |
| 40–43 | **type** | `0x9` = available 64-bit TSS (`0xB` = busy) |
| 44 | S — descriptor class | **`0`** = system segment |
| 45–46 | DPL | `0` |
| 47 | P — present | `1` |
| 48–51 | limit[19:16] | `0x0` |
| 52 | AVL | `0` |
| 53 | reserved (L in a code descriptor) | **must be `0`** |
| 54 | reserved (D/B in a code descriptor) | **must be `0`** |
| 55 | G — granularity | `0` = byte units |
| 56–63 | base[31:24] | from `&g_tss` |

Bits 40–47 together are the **access byte**: `P=1 DPL=00 S=0 type=1001` = `0x89`.

**High 8 bytes:**

| Bits | Field | Value |
|---|---|---|
| 0–31 | **base[63:32]** | the top half of `&g_tss` |
| 32–63 | reserved | **`0`** |

**Where the base splits.** This is the part people get wrong. A higher-half kernel puts
the TSS somewhere around `0xFFFFFFFF80105000`. That base is scattered across **five**
non-contiguous fields:

```
  base = 0xFFFFFFFF 80 10 5000
           │        │  │  └──── bits 15:0   → low  qword, bits 16–31
           │        │  └─────── bits 23:16  → low  qword, bits 32–39
           │        └────────── bits 31:24  → low  qword, bits 56–63
           └─────────────────── bits 63:32  → high qword, bits 0–31
```

Miss the last one and the CPU reads your TSS from `0x0000000080105000`, which is user
address space and is not mapped. `ltr` faults, and with no IDT the machine triple-faults
instantly.

**Golden bytes.** For `base = 0xFFFFFFFF80105000`, `limit = 103`, the 16 bytes are:

```
  67 00 00 50 10 89 00 80   FF FF FF FF 00 00 00 00
  └─┬─┘ └─┬─┘ ┌┘  ┌┘  ┌┘ └┐  └────┬────┘ └────┬────┘
   limit  b15:0 b23:16 │   b31:24  base 63:32  reserved
                    access  gran
```
As two little-endian qwords: `0x8000891050000067`, `0x00000000FFFFFFFF`.
§6 uses these as a unit-test vector.

### 4.3 GDT layout after this stage

| Index | Selector | Entry | Size |
|---|---|---|---|
| 0 | `0x00` | null | 8 |
| 1 | `0x08` | kernel code, ring 0 | 8 |
| 2 | `0x10` | kernel data, ring 0 | 8 |
| 3 | `0x18` | user data, ring 3 | 8 |
| 4 | `0x20` | user code, ring 3 | 8 |
| 5 | `0x28` | **TSS descriptor, low half** | 16 total |
| 6 | *(consumed)* | **TSS descriptor, high half** | |

Seven slots, so the `lgdt` limit is `7 * 8 - 1 = 55` (`0x37`).

> **Match your own Stage 2.1 ordering.** The selector for the TSS is just
> `index * 8`, and the only hard requirement is that the two halves are consecutive and
> the last GDT entry. This table puts **user data before user code** because `sysret`
> requires it: returning to 64-bit ring 3 loads `cs` from `STAR[63:48] + 16` and `ss`
> from `STAR[63:48] + 8`, so the data descriptor must sit 8 bytes below the code
> descriptor. [[Stage 2.1 - The Global Descriptor Table]] left the user entries for
> later; fix the order now, while nothing depends on it.

### 4.4 The `lgdt` operand in long mode

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | limit = `sizeof(gdt) - 1` |
| `0x02` | **8** | base — **64-bit**, not 32 |

Ten bytes, packed. If Stage 2.1 gave you a 32-bit base field, change it now: a kernel
GDT at `0xFFFFFFFF801...` truncates to `0x801...` and `lgdt` points the CPU at nothing.

### 4.5 `ltr`

```
ltr r/m16
```

- Operand is a **16-bit selector** — the byte offset into the GDT (`0x28` here), RPL `0`.
- Requires CPL 0. Not valid in real mode or virtual-8086 mode.
- The referenced descriptor must be a system segment (`S = 0`) with type
  `0x9` (available 64-bit TSS). Anything else — including type `0xB`, *busy* — gives
  `#GP`.
- **`ltr` sets the busy bit**, rewriting the in-memory descriptor's type from `0x9` to
  `0xB`. A second `ltr` on the same descriptor therefore faults. Load it once.
- The CPU caches base, limit, and flags in the hidden part of `TR`. Editing the
  descriptor in memory afterwards has no effect until the next `ltr`.

### 4.6 The IST field in an IDT gate (forward reference)

Stage 2.3 builds 16-byte gates. The relevant byte is offset 4:

| Bits | Field |
|---|---|
| 0–2 | **IST index, 1-based.** `0` = do not switch stacks; `1`–`7` = `ist1`–`ist7` |
| 3–7 | reserved, must be `0` |

Constants for this field are declared in `tss.hpp` below so that Stage 2.3 does not
invent its own.

---

## 5. Writing the code

### `kernel/arch/x86_64/cpu/tss.hpp`

The hardware layout of the TSS, the IST slot assignments, and the three-function API.
This header is arch-private — it sits next to its `.cpp` under `kernel/arch/x86_64/`
rather than in `kernel/include/`, because nothing outside the arch layer should know
what a TSS is.

```cpp
// kernel/arch/x86_64/cpu/tss.hpp
//
// The 64-bit Task State Segment. Long mode does NOT use this for task
// switching -- that mechanism was removed with the rest of 32-bit task
// management. The CPU reads exactly three things out of it: rsp0 (the stack
// used on a ring 3 -> ring 0 transition), the seven IST pointers, and the
// I/O permission bitmap offset. See Stage 2.2.

#pragma once

#include <stddef.h>
#include <stdint.h>

namespace arch {

// ---------------------------------------------------------------------------
// Hardware layout. Intel SDM Vol. 3A, "64-Bit TSS Format".
// Do not reorder. Do not add fields. Do not remove `packed` -- rsp0 lives at
// offset 4, so none of the 8-byte fields is naturally aligned and the
// compiler would otherwise insert padding.
// ---------------------------------------------------------------------------
struct Tss {
    uint32_t reserved0;    // 0x00  must be zero
    uint64_t rsp0;         // 0x04  ring 0 stack, used on a ring 3 -> 0 entry
    uint64_t rsp1;         // 0x0C  ring 1 -- unused, must be zero
    uint64_t rsp2;         // 0x14  ring 2 -- unused, must be zero
    uint64_t reserved1;    // 0x1C  must be zero
    uint64_t ist1;         // 0x24
    uint64_t ist2;         // 0x2C
    uint64_t ist3;         // 0x34
    uint64_t ist4;         // 0x3C
    uint64_t ist5;         // 0x44
    uint64_t ist6;         // 0x4C
    uint64_t ist7;         // 0x54
    uint64_t reserved2;    // 0x5C  must be zero
    uint16_t reserved3;    // 0x64  must be zero
    uint16_t iopb_offset;  // 0x66  >= segment limit means "no bitmap, deny all"
} __attribute__((packed));

static_assert(sizeof(Tss) == 104, "the 64-bit TSS is exactly 104 bytes");
static_assert(offsetof(Tss, rsp0) == 0x04, "rsp0 must be at offset 0x04");
static_assert(offsetof(Tss, ist1) == 0x24, "ist1 must be at offset 0x24");
static_assert(offsetof(Tss, ist7) == 0x54, "ist7 must be at offset 0x54");
static_assert(offsetof(Tss, iopb_offset) == 0x66, "iopb must be at offset 0x66");

// ---------------------------------------------------------------------------
// IST slot numbers, as written into the 3-bit field of an IDT gate.
// ONE-BASED: 0 in a gate means "do not switch stacks". There is no slot 0.
// Stage 2.3 uses these names rather than bare numbers.
// ---------------------------------------------------------------------------
inline constexpr uint8_t IST_NONE          = 0;  // ordinary gate, no switch
inline constexpr uint8_t IST_DOUBLE_FAULT  = 1;  // vector 8   -- mandatory
inline constexpr uint8_t IST_NMI           = 2;  // vector 2
inline constexpr uint8_t IST_MACHINE_CHECK = 3;  // vector 18
inline constexpr uint8_t IST_DEBUG         = 4;  // vector 1
inline constexpr uint8_t IST_HIGHEST_USED  = 4;  // slots 5-7 are left at zero

// Every stack this module owns is this size, preceded by a reserved region
// that Phase 4 will unmap into a real guard page.
inline constexpr size_t KERNEL_STACK_SIZE = 16 * 1024;
inline constexpr size_t STACK_GUARD_SIZE  = 4096;

// Fill the TSS, install its 16-byte descriptor in the GDT, and run `ltr`.
// Call once, after gdt_init() and before idt_init().
void tss_init();

// Set the stack the CPU switches to on a ring 3 -> ring 0 interrupt. The
// Phase 5 scheduler calls this on every context switch with the incoming
// task's kernel stack top. Never assign to a TSS object directly: when
// Phase 12 makes this per-CPU, only this function's body changes.
void tss_set_rsp0(uint64_t stack_top);

// Top-of-stack address of IST slot 1..7, or 0 if that slot is unused.
// Stage 2.3 asserts with this that no gate names an empty slot.
uint64_t tss_ist(uint8_t slot);

}  // namespace arch
```

#### Line by line

**The includes**

```cpp
#include <stddef.h>
#include <stdint.h>
```

`<stdint.h>` and `<stddef.h>`, never `<cstdint>` and `<cstddef>`. The C++ headers are
part of libstdc++, which this kernel does not link and which `-nostdinc++` removes from
the include path entirely. The C headers are supplied by GCC itself as part of the
freestanding environment ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]).
`<stddef.h>` is here for `size_t` and for `offsetof`, which the `static_assert`s use.

**The `Tss` struct and `__attribute__((packed))`**

```cpp
struct Tss {
    uint32_t reserved0;    // 0x00
    uint64_t rsp0;         // 0x04
    ...
} __attribute__((packed));
```

This is the single most important line in the file. `reserved0` is 4 bytes, so `rsp0`
starts at offset 4 — an 8-byte field on a 4-byte boundary. Without `packed`, the
compiler inserts 4 bytes of padding to align it, `rsp0` lands at offset 8, every field
after it shifts, and `sizeof(Tss)` comes out at 112 instead of 104.

The consequences are not a compile error; they are worse than that. The CPU reads this
memory with hardwired offsets. It would read your `reserved1` as `ist1`, find zero,
switch to stack address 0 on a double fault, fault on the push, and triple-fault — the
exact failure you installed the IST to prevent, now caused by the fix. The
`static_assert` below catches it at compile time, which is why it is there.

`__attribute__((packed))` after the closing brace is the form that works everywhere;
`[[gnu::packed]]` on the class head is equivalent under GCC if your
[[13 - Coding Standards]] prefer C++ attribute syntax.

The struct stays **standard-layout** despite packing — all members public, no virtuals,
no base classes — which is what makes `offsetof` legal on it.

**The `static_assert` block**

```cpp
static_assert(sizeof(Tss) == 104, "the 64-bit TSS is exactly 104 bytes");
static_assert(offsetof(Tss, rsp0) == 0x04, "rsp0 must be at offset 0x04");
static_assert(offsetof(Tss, ist1) == 0x24, "ist1 must be at offset 0x24");
static_assert(offsetof(Tss, ist7) == 0x54, "ist7 must be at offset 0x54");
static_assert(offsetof(Tss, iopb_offset) == 0x66, "iopb must be at offset 0x66");
```

Five assertions against the table in §4.1. `sizeof` alone is not enough: two fields
swapped, or one `uint32_t` where a `uint64_t` belongs plus a compensating change, keeps
the total at 104 while every offset moves. Checking the size *and* the three offsets
that hardware actually reads — `rsp0`, the ends of the IST block, and the I/O bitmap —
pins the layout down.

These cost nothing at runtime and they are the only mechanism that will ever tell you the
struct is wrong. The alternative is a triple fault with no output.

**The IST constants**

```cpp
inline constexpr uint8_t IST_NONE          = 0;
inline constexpr uint8_t IST_DOUBLE_FAULT  = 1;
inline constexpr uint8_t IST_NMI           = 2;
inline constexpr uint8_t IST_MACHINE_CHECK = 3;
inline constexpr uint8_t IST_DEBUG         = 4;
inline constexpr uint8_t IST_HIGHEST_USED  = 4;
```

`inline constexpr` at namespace scope (C++17) gives one shared object across every
translation unit with no definition in a `.cpp`, and `constexpr` makes them usable in
`static_assert` and as array bounds. Not macros — a macro has no type and ignores
namespaces.

They are named rather than numeric because of the 1-based trap in §2.3. `IST_NONE = 0`
exists specifically so that Stage 2.3 writes `IST_NONE` for an ordinary gate and cannot
mistake it for "slot zero". `IST_HIGHEST_USED` lets `tss_init` assert that every slot it
was asked to fill actually got a stack.

**The API**

```cpp
void tss_init();
void tss_set_rsp0(uint64_t stack_top);
uint64_t tss_ist(uint8_t slot);
```

Three functions, no exported variables. This is decision 3.5 rule 2 made concrete: there
is no `extern Tss g_tss;` here, so no caller can ever write `g_tss.rsp0 = x` and hardcode
the assumption that there is exactly one TSS. When Phase 12 makes these operate on the
calling CPU's TSS, every call site is already correct.

`tss_set_rsp0` takes a `uint64_t` rather than a pointer because it is a stack *top* —
a one-past-the-end address that will be decremented before it is ever dereferenced.
Typing it as `uint8_t*` would invite someone to dereference it.

---

### `kernel/arch/x86_64/cpu/tss.cpp`

Owns the TSS instance and the static stacks, and performs the one-time load.

```cpp
// kernel/arch/x86_64/cpu/tss.cpp
//
// Stage 2.2. Fills the 64-bit TSS, installs its 16-byte descriptor in the
// GDT, and loads TR. After this runs, an IDT gate may name an IST slot and
// the CPU will find a valid stack there.

#include "tss.hpp"

#include "gdt.hpp"

#include <stddef.h>
#include <stdint.h>

#include <kernel/log.hpp>
#include <kernel/panic.hpp>

namespace arch {
namespace {

// One stack, plus the address range reserved immediately below it.
//
// TODAY the guard is ordinary writable .bss and protects nothing; it only
// reserves the address range and forces the layout. In Phase 4, once the
// kernel owns its page tables, the VMM unmaps every `guard` page and the
// protection turns on with no change to this file. See Stage 2.2 section 3.4.
struct alignas(4096) GuardedStack {
    uint8_t guard[STACK_GUARD_SIZE];
    uint8_t stack[KERNEL_STACK_SIZE];

    // Stacks grow DOWNWARD. The CPU wants the address one past the last
    // usable byte, not the address of the first one.
    uint64_t top() const {
        return reinterpret_cast<uint64_t>(&stack[KERNEL_STACK_SIZE]);
    }
};

static_assert(sizeof(GuardedStack) == STACK_GUARD_SIZE + KERNEL_STACK_SIZE,
              "GuardedStack must have no padding -- the guard must sit "
              "immediately below the stack");
static_assert(alignof(GuardedStack) == 4096,
              "the guard region must be exactly one page, page-aligned, so "
              "Phase 4 can unmap it");

// Zero-initialised, so these live in .bss and cost nothing in kernel.elf on
// disk. No heap exists until Phase 4; these are the only stacks there are.
GuardedStack g_stack_rsp0;   // ring 3 -> ring 0 entries (idle until Phase 6)
GuardedStack g_stack_df;     // IST1  #DF  vector 8
GuardedStack g_stack_nmi;    // IST2  NMI  vector 2
GuardedStack g_stack_mce;    // IST3  #MC  vector 18
GuardedStack g_stack_db;     // IST4  #DB  vector 1

// The one TSS. Phase 12 turns this into one per CPU; nothing outside this
// file names it, so that change stays inside these braces.
Tss g_tss;

}  // namespace

void tss_set_rsp0(uint64_t stack_top) {
    g_tss.rsp0 = stack_top;
}

uint64_t tss_ist(uint8_t slot) {
    switch (slot) {
        case 1: return g_tss.ist1;
        case 2: return g_tss.ist2;
        case 3: return g_tss.ist3;
        case 4: return g_tss.ist4;
        case 5: return g_tss.ist5;
        case 6: return g_tss.ist6;
        case 7: return g_tss.ist7;
        default: return 0;
    }
}

void tss_init() {
    // 1. Every byte zero. Reserved fields must read as zero, and this is the
    //    only statement that guarantees it independently of the linker.
    __builtin_memset(&g_tss, 0, sizeof(g_tss));

    // 2. The ring 0 stack. Unused until Phase 6, because nothing runs in
    //    ring 3 yet -- but leaving it at 0 means the very first user-mode
    //    interrupt would push to address 0.
    g_tss.rsp0 = g_stack_rsp0.top();

    // 3. The interrupt stacks. TOP of each array. See section 3.3 for why
    //    these are four separate objects and not one shared one.
    g_tss.ist1 = g_stack_df.top();    // IST_DOUBLE_FAULT
    g_tss.ist2 = g_stack_nmi.top();   // IST_NMI
    g_tss.ist3 = g_stack_mce.top();   // IST_MACHINE_CHECK
    g_tss.ist4 = g_stack_db.top();    // IST_DEBUG
    // ist5..ist7 stay zero. Stage 2.3 must not name them.

    // 4. Deny ring 3 every I/O port. sizeof(Tss) == 104 is one past the
    //    segment limit of 103, which the CPU reads as "no bitmap at all".
    g_tss.iopb_offset = sizeof(Tss);

    // 5. Cheap invariants, checked before the CPU is told to trust any of it.
    KASSERT(g_tss.rsp0 != 0);
    KASSERT(g_tss.ist1 > reinterpret_cast<uint64_t>(&g_stack_df));
    KASSERT(g_tss.ist1 - reinterpret_cast<uint64_t>(g_stack_df.stack) ==
            KERNEL_STACK_SIZE);
    KASSERT((g_tss.ist1 & 0xF) == 0);

    // 6. Write the 16-byte system-segment descriptor into GDT slots 5 and 6.
    //    Segment limit is sizeof(Tss) - 1 == 103, byte granularity.
    gdt_install_tss(reinterpret_cast<uint64_t>(&g_tss), sizeof(Tss) - 1);

    // 7. Load the task register. Legal only under `kernel/arch/`, which this
    //    file is. `ltr` takes r/m16, so the operand must be 16 bits wide.
    const uint16_t selector = GDT_SELECTOR_TSS;
    asm volatile("ltr %0" : : "rm"(selector) : "memory");

    LOG_INFO("tss: TR=0x%04x rsp0=%p ist1(#DF)=%p ist2(NMI)=%p",
             selector,
             reinterpret_cast<void*>(g_tss.rsp0),
             reinterpret_cast<void*>(g_tss.ist1),
             reinterpret_cast<void*>(g_tss.ist2));
}

}  // namespace arch
```

#### Line by line

**Includes**

```cpp
#include "tss.hpp"
#include "gdt.hpp"
```

Its own header first, so that the header is proven self-contained — if `tss.hpp` forgot
an include, this is where it fails. `gdt.hpp` supplies `gdt_install_tss()` and
`GDT_SELECTOR_TSS`; both files are in the same directory, so quoted includes are right.
`<kernel/panic.hpp>` and `<kernel/log.hpp>` come from `kernel/include/` and use angle
brackets.

**`struct alignas(4096) GuardedStack`**

```cpp
struct alignas(4096) GuardedStack {
    uint8_t guard[STACK_GUARD_SIZE];
    uint8_t stack[KERNEL_STACK_SIZE];
```

The guard array is declared **first**, so it occupies the 4 KiB immediately below the
usable stack. Since stacks grow down, "below the stack" is where an overflow goes, which
is where the guard has to be. Reversing these two lines produces an object that compiles,
links, boots, and provides no protection whatsoever.

`alignas(4096)` does two jobs. It puts `guard` on an exact page boundary, so Phase 4 can
unmap precisely that one page without touching the stack above it. And because the
object's total size is a multiple of 4096, the *next* `GuardedStack` in `.bss` also
starts page-aligned — the five objects tile cleanly, and the guard of one sits directly
below the stack of the previous one.

`STACK_GUARD_SIZE` and `KERNEL_STACK_SIZE` come from the header rather than being literal
numbers here, so that Phase 4's unmapping code and this layout cannot drift apart.

**`top()`**

```cpp
    uint64_t top() const {
        return reinterpret_cast<uint64_t>(&stack[KERNEL_STACK_SIZE]);
    }
```

**This is the line that people get wrong, and it is worth dwelling on.** x86 stacks grow
toward lower addresses. `push` decrements `rsp` and *then* writes. So the value the CPU
wants is the address one past the last usable byte: the first `push` decrements to the
last byte of the array and writes there.

`&stack[KERNEL_STACK_SIZE]` is a one-past-the-end address, which C++ explicitly permits
you to form (you may not dereference it, and nothing here does). It equals
`&stack[0] + 16384`.

Write `&stack[0]` instead — the array's own address, the thing you would naturally pass
anywhere else — and the first push writes to `stack[-8]`, which is the last 8 bytes of
`guard`, and the frame walks straight down through the guard into whatever `.bss` object
the linker placed before this one. The double-fault handler then runs while corrupting
memory, and the panic it prints is either garbage or a second fault. §7 lists the
symptom.

Because the object is 4096-aligned and both sizes are multiples of 16, `top()` is
16-byte aligned. Long mode aligns `rsp` down to 16 before pushing an interrupt frame
anyway, so this is not strictly required — but a misaligned base would silently waste up
to 15 bytes and would break the SysV ABI expectations of the C++ handler that Stage 2.4
calls.

**The `static_assert`s on `GuardedStack`**

```cpp
static_assert(sizeof(GuardedStack) == STACK_GUARD_SIZE + KERNEL_STACK_SIZE, ...);
static_assert(alignof(GuardedStack) == 4096, ...);
```

The size check proves the compiler inserted no padding between `guard` and `stack` —
if it had, the guard would no longer be adjacent to the region it guards and Phase 4's
unmap would protect the wrong page. The alignment check proves `alignas` survived; a
typo turning it into `alignas(4)` compiles fine and quietly makes the guard un-unmappable.

**The five stack objects**

```cpp
GuardedStack g_stack_rsp0;
GuardedStack g_stack_df;
GuardedStack g_stack_nmi;
GuardedStack g_stack_mce;
GuardedStack g_stack_db;
```

Five objects at 20 KiB each = 100 KiB. They have no initialiser, so they are
zero-initialised and land in `.bss` — reserved by the linker script, zeroed at load time,
**costing nothing in `kernel.elf` on disk**. §6 verifies both halves of that claim.

They are in an anonymous `namespace`, giving internal linkage: no other translation unit
can name them, and the linker will not merge them with a same-named symbol elsewhere.
[[13 - Coding Standards]] uses the anonymous namespace rather than `static` on each
declaration because it states the intent once for the whole block.

There is no heap ([[Phase 4 - Overview|Phase 4]] is where `kmalloc` arrives), so static
arrays are not a shortcut here — they are the only option. That constraint happens to be
correct for interrupt stacks anyway: a stack the double-fault handler depends on should
not come from an allocator that might itself be the thing that is broken.

**`tss_set_rsp0`**

```cpp
void tss_set_rsp0(uint64_t stack_top) {
    g_tss.rsp0 = stack_top;
}
```

Two lines today, and it will stay two lines until Phase 12 makes it
`current_cpu()->tss.rsp0 = stack_top`. Its whole value is that Phase 5's scheduler calls
it instead of touching a global, so that change is local.

Note what it does *not* do: no `ltr`, no cache invalidation. The CPU reads `rsp0` out of
memory on every ring-3 → ring-0 transition; only the descriptor's base, limit, and flags
are cached in `TR`'s hidden registers. Updating `rsp0` on every context switch is
therefore just a store, which is why this design is cheap enough for the scheduler's
hot path.

**`tss_ist`**

```cpp
uint64_t tss_ist(uint8_t slot) {
    switch (slot) {
        case 1: return g_tss.ist1;
        ...
        default: return 0;
    }
}
```

A `switch` rather than pointer arithmetic over the struct, because the IST fields are not
a real array — they are seven separately-named members of a packed struct, and indexing
into them by casting a pointer would be undefined behaviour and would break under
`-Werror` with `-Waddress-of-packed-member`.

`default: return 0` covers slot 0 and slots above 7. Stage 2.3 uses it as
`KASSERT(tss_ist(gate_ist) != 0)` before installing any gate with a non-zero IST index —
which catches the "gate names `ist5`, which was never filled" bug at boot rather than
during a double fault.

**`tss_init` step 1 — zero everything**

```cpp
    __builtin_memset(&g_tss, 0, sizeof(g_tss));
```

`g_tss` is in `.bss` and is therefore already zero at this point, so this looks
redundant. It is not, for three reasons:

- **Reserved means reserved.** §4.1 marks four fields reserved. Intel's rule for reserved
  fields is that software must write zero and that behaviour is undefined otherwise —
  a future CPU may check them, and hypervisors already perform consistency checks on
  guest state. Setting them explicitly is the difference between "happens to be zero" and
  "is zero because we said so".
- **It survives a second call.** Phase 12 calls `tss_init` once per CPU. Phase 15 may
  call it after a soft reset. Neither can assume `.bss` state.
- **It documents the invariant** at the one place a reader looks. The alternative,
  `g_tss = Tss{};`, is equivalent and arguably more idiomatic C++; use whichever your
  [[13 - Coding Standards]] prefer.

`__builtin_memset` rather than `<string.h>`'s `memset` because this is a freestanding
build. GCC will inline a 104-byte memset as stores, but for larger objects it can emit a
call to `memset`, which your Phase 0 `kstd` string routines must therefore provide — if
you get an undefined reference to `memset` at link time, that is the cause, not a bug
here.

**Step 2 — `rsp0`**

```cpp
    g_tss.rsp0 = g_stack_rsp0.top();
```

Nothing runs in ring 3 until Phase 6, so this value is genuinely never read today. Set it
anyway. The failure mode of leaving it at zero is that the first user-mode interrupt —
which will arrive during Phase 6 bring-up, when twenty other things are also new —
switches to stack address 0, faults on the push, and triple-faults. That bug would be
attributed to whatever Phase 6 code was under test at the time. Setting it now costs one
line and 20 KiB.

From Phase 5, the scheduler overwrites this on every context switch with the incoming
task's kernel stack. `g_stack_rsp0` is the value that applies to the boot/idle path.

**Step 3 — the IST pointers**

```cpp
    g_tss.ist1 = g_stack_df.top();
    g_tss.ist2 = g_stack_nmi.top();
    g_tss.ist3 = g_stack_mce.top();
    g_tss.ist4 = g_stack_db.top();
```

Four distinct objects, per decision 3.3. The comment naming each vector matters more than
it looks: the mapping from slot number to purpose exists **only** by convention, split
across this file and Stage 2.3's gate table. `IST_DOUBLE_FAULT = 1` in the header and
`ist1 = g_stack_df.top()` here are the two halves of one decision, and if they disagree
the double-fault handler runs on the NMI stack, which works fine right up until an NMI
arrives.

`ist5`, `ist6`, and `ist7` are deliberately left at zero from step 1. A gate naming an
unfilled slot loads `rsp = 0`, which is strictly worse than no IST at all — it converts
a *possibly* survivable fault into a guaranteed triple fault. `tss_ist()` plus a
`KASSERT` in Stage 2.3 is what stops that.

**Step 4 — the I/O permission bitmap offset**

```cpp
    g_tss.iopb_offset = sizeof(Tss);
```

`sizeof(Tss)` is 104. The segment limit installed in step 6 is 103. Per §4.1, an offset
greater than or equal to the limit means *there is no bitmap* and every `in`, `out`,
`ins`, and `outs` from CPL > IOPL raises `#GP`. That is the policy you want: ring 3 gets
no direct hardware access, ever.

**What goes wrong if you leave it at 0** — and it will be 0, because step 1 zeroed it, so
this is a sin of omission rather than commission. Offset 0 is *less* than the limit of
103, so the CPU concludes a bitmap does exist and that it begins at the TSS base. It then
indexes into the first 104 bytes of the TSS to find the permission bit for a port, where
a **clear bit means the port is allowed**. Those 104 bytes are your reserved zeros, your
`rsp1`/`rsp2` zeros, the zeroed `ist5`–`ist7`, and the zero bytes inside otherwise-valid
pointers. Vast stretches of it are zero. A ring-3 process would be granted access to
hundreds of I/O ports — the PIC, the PIT, the ATA registers, the CMOS — chosen
essentially at random by the bit pattern of your stack addresses. It could reprogram the
interrupt controller or write to a disk directly. The whole security boundary this kernel
is built to enforce would leak through a two-byte field.

Write it explicitly, and understand that `104 >= 103` is the entire mechanism.

**Step 5 — the assertions**

```cpp
    KASSERT(g_tss.rsp0 != 0);
    KASSERT(g_tss.ist1 > reinterpret_cast<uint64_t>(&g_stack_df));
    KASSERT(g_tss.ist1 - reinterpret_cast<uint64_t>(g_stack_df.stack) ==
            KERNEL_STACK_SIZE);
    KASSERT((g_tss.ist1 & 0xF) == 0);
```

Four checks, placed **before** the descriptor is installed and `ltr` runs, so that a
mistake here panics with a message instead of faulting in the CPU's microcode.

The third one is the important one: it asserts that `ist1` is exactly
`KERNEL_STACK_SIZE` bytes above the *start of the stack array*, which is true only if
`top()` returned the end. If someone "fixes" `top()` to return `&stack[0]`, this
assertion fires at boot with a file and line number, rather than presenting as a
corrupted panic message six weeks later. It is a two-line guard against the single most
common bug in this stage.

`KASSERT` compiles out in release builds per [[Stage 0.7 - Panic and KASSERT]], which is
fine — these are checks on constants, so if they hold once they hold always.

**Step 6 — install the descriptor**

```cpp
    gdt_install_tss(reinterpret_cast<uint64_t>(&g_tss), sizeof(Tss) - 1);
```

`reinterpret_cast<uint64_t>` on the address, because the descriptor is a bit field and
wants an integer, and because `&g_tss` is a higher-half address around
`0xFFFFFFFF801xxxxx` whose top 32 bits must survive into the descriptor's second qword.

`sizeof(Tss) - 1 = 103` is the limit. Segment limits are inclusive — the last valid byte
offset, not the size. Passing 104 makes the limit 104, `iopb_offset` of 104 is then no
longer `>= limit`, and you have re-opened the I/O bitmap hole from step 4. Passing
`sizeof(Tss)` here is a genuinely subtle two-bug interaction; the two constants are
deliberately written as `sizeof(Tss)` and `sizeof(Tss) - 1` so the relationship is
visible on the page.

**Step 7 — `ltr`**

```cpp
    const uint16_t selector = GDT_SELECTOR_TSS;
    asm volatile("ltr %0" : : "rm"(selector) : "memory");
```

`ltr` takes an `r/m16`. Declaring `selector` as `uint16_t` is what makes GCC pick a
16-bit register or a 16-bit memory operand for `%0`; an `int` here would yield `ltr %eax`,
which does not assemble. The `"rm"` constraint lets GCC choose either form.

`volatile` stops GCC from deleting the statement — it has no outputs, so without
`volatile` it is dead code by inspection. The `"memory"` clobber tells GCC that memory
may have changed, which prevents it from caching a read of the GDT across this
instruction; `ltr` reads the descriptor and writes the busy bit back into it.

This is inline assembly, which [[13 - Coding Standards]] permits **only** under
`kernel/arch/`. This file is `kernel/arch/x86_64/cpu/tss.cpp`, so it is allowed;
`scripts/lint.sh` enforces the rule.

Three things about this one instruction:

- It must run **after** `lgdt`, because the CPU reads the descriptor from the GDT the
  `GDTR` currently points at.
- The GDT limit must already cover index 6. Growing the array without growing the limit
  gives `#GP` here — §7.
- It sets the busy bit, rewriting the descriptor's type from `0x9` to `0xB`. Calling
  `tss_init()` twice therefore faults on the second `ltr`. It is a one-shot.

Nothing observable happens if it succeeds. That is the point: from here on, `TR` is
loaded and the CPU knows where to find `rsp0` and the IST.

**The log line**

```cpp
    LOG_INFO("tss: TR=0x%04x rsp0=%p ist1(#DF)=%p ist2(NMI)=%p", ...);
```

Print the pointers. When the payoff test in §6 produces a double fault, the `rsp` in the
fault dump should be *just below* the `ist1` value on this line, and comparing the two is
the fastest way to confirm the stack switch actually happened. Casting through `void*`
for `%p` avoids the `-Wformat` error that `-Werror` would otherwise turn into a build
failure.

---

### `kernel/arch/x86_64/cpu/gdt.hpp` — additions

Selector constants and the new entry point. Add to the existing header from Stage 2.1.

```cpp
// --- add to kernel/arch/x86_64/cpu/gdt.hpp ---

// Selectors are byte offsets into the GDT: index * 8. User data sits BELOW
// user code because `sysret` requires it (see Stage 2.2 section 4.3).
inline constexpr uint16_t GDT_SELECTOR_NULL        = 0x00;  // index 0
inline constexpr uint16_t GDT_SELECTOR_KERNEL_CODE = 0x08;  // index 1
inline constexpr uint16_t GDT_SELECTOR_KERNEL_DATA = 0x10;  // index 2
inline constexpr uint16_t GDT_SELECTOR_USER_DATA   = 0x18;  // index 3
inline constexpr uint16_t GDT_SELECTOR_USER_CODE   = 0x20;  // index 4
inline constexpr uint16_t GDT_SELECTOR_TSS         = 0x28;  // index 5 AND 6

// 5 segment descriptors + 2 slots for the one 16-byte TSS descriptor.
inline constexpr size_t GDT_ENTRY_COUNT = 7;

// Write the 16-byte system-segment descriptor for a TSS into slots 5 and 6.
// `limit` is inclusive: pass sizeof(Tss) - 1.
void gdt_install_tss(uint64_t base, uint32_t limit);
```

---

### `kernel/arch/x86_64/cpu/gdt.cpp` — changes

Three edits to the file Stage 2.1 produced.

```cpp
// --- 1. grow the table -------------------------------------------------
// Was: GdtEntry g_gdt[5];
alignas(16) GdtEntry g_gdt[GDT_ENTRY_COUNT];

// --- 2. the lgdt operand: the base is 64-bit in long mode ---------------
struct GdtPointer {
    uint16_t limit;   // sizeof(g_gdt) - 1, inclusive
    uint64_t base;    // 64-bit. NOT uint32_t.
} __attribute__((packed));

static_assert(sizeof(GdtPointer) == 10,
              "lgdt reads a 10-byte operand in long mode: 2 + 8");

// --- 3. the 16-byte system-segment descriptor --------------------------
struct TssDescriptor {
    uint16_t limit_low;    // limit[15:0]
    uint16_t base_low;     // base[15:0]
    uint8_t  base_mid;     // base[23:16]
    uint8_t  access;       // P | DPL | S=0 | type
    uint8_t  granularity;  // G | 0 | 0 | AVL | limit[19:16]
    uint8_t  base_high;    // base[31:24]
    uint32_t base_upper;   // base[63:32]   <-- the half everyone forgets
    uint32_t reserved;     // must be zero
} __attribute__((packed));

static_assert(sizeof(TssDescriptor) == 16,
              "a 64-bit system-segment descriptor is 16 bytes, not 8");
static_assert((GDT_SELECTOR_TSS / 8) + 2 <= GDT_ENTRY_COUNT,
              "the TSS descriptor needs two consecutive free GDT slots");

void gdt_install_tss(uint64_t base, uint32_t limit) {
    TssDescriptor d{};

    d.limit_low   = static_cast<uint16_t>(limit & 0xFFFFu);
    d.base_low    = static_cast<uint16_t>(base & 0xFFFFu);
    d.base_mid    = static_cast<uint8_t>((base >> 16) & 0xFFu);
    d.access      = 0x89;  // P=1 DPL=0 S=0 type=0x9 (available 64-bit TSS)
    d.granularity = static_cast<uint8_t>((limit >> 16) & 0x0Fu);  // G=0, L=0
    d.base_high   = static_cast<uint8_t>((base >> 24) & 0xFFu);
    d.base_upper  = static_cast<uint32_t>(base >> 32);
    d.reserved    = 0;

    // Copy over two consecutive 8-byte slots. memcpy rather than a cast so
    // there is no aliasing between GdtEntry and TssDescriptor.
    __builtin_memcpy(&g_gdt[GDT_SELECTOR_TSS / 8], &d, sizeof(d));
}
```

#### Line by line

**`alignas(16) GdtEntry g_gdt[GDT_ENTRY_COUNT];`**

Two entries longer than Stage 2.1's table, because one TSS descriptor consumes two
8-byte slots. If you grow the array but the `GdtPointer.limit` is a hardcoded number
rather than `sizeof(g_gdt) - 1`, the limit still says 39 and slots 5 and 6 lie outside
the table — `ltr` then raises `#GP` because the selector exceeds the GDT limit. Compute
the limit from `sizeof`, never by hand.

`alignas(16)` is not required by the architecture (8 is the recommended minimum for the
GDT base), but it is free and it keeps the 16-byte TSS descriptor naturally aligned,
which means the `__builtin_memcpy` below compiles to two aligned 8-byte stores.

**`GdtPointer` with a 64-bit base**

In long mode `lgdt` reads a 10-byte operand: a 16-bit limit followed by a **64-bit**
base. Every 32-bit tutorial shows a 32-bit base, and it is the kind of error that
survives review because the code looks familiar. With a higher-half kernel at
`0xFFFFFFFF80000000` ([[06 - Architecture Overview]], `-mcmodel=kernel`), a truncated
base points at low user space and the very next segment-register load triple-faults. The
`static_assert(sizeof(GdtPointer) == 10)` is what makes the mistake a build error.

**`TssDescriptor`, field by field**

```cpp
    uint16_t limit_low;    // limit[15:0]
    uint16_t base_low;     // base[15:0]
    uint8_t  base_mid;     // base[23:16]
    uint8_t  access;       // P | DPL | S=0 | type
    uint8_t  granularity;  // G | 0 | 0 | AVL | limit[19:16]
    uint8_t  base_high;    // base[31:24]
    uint32_t base_upper;   // base[63:32]
    uint32_t reserved;     // must be zero
```

The first six fields are byte-for-byte the layout of an ordinary 8-byte descriptor —
that is deliberate on Intel's part, so a 64-bit system descriptor is "the 32-bit one plus
eight bytes". The last two are the extension. Cross-check each field against the tables
in §4.2 as you type; that section exists so this struct can be written from it directly.

`__attribute__((packed))` for the same reason as the TSS: `base_upper` is a `uint32_t`
at offset 8, which happens to be aligned, but `access` and `granularity` are single
bytes between 16-bit fields and the compiler must not tidy them.

**`d.access = 0x89`**

The single most consequential constant in this file. In binary, `1000 1001`:

| Bit | Value | Meaning |
|---|---|---|
| 7 | `1` | **P** — present. `0` gives `#GP` on `ltr` |
| 6–5 | `00` | **DPL** = 0. The TSS is ring-0 state |
| 4 | `0` | **S** — system segment. `1` would make it a code/data descriptor and `ltr` would `#GP` |
| 3–0 | `1001` | **type 0x9** — available 64-bit TSS |

Type `0xB` is *busy* 64-bit TSS, and `ltr` refuses to load a busy descriptor — that is
the mechanism, inherited from 32-bit task switching, that prevented recursive task
entry. Write `0x8B` here by transposing a digit and `ltr` faults immediately. The CPU
will set the busy bit itself; your job is to hand it an available one.

**`d.granularity = (limit >> 16) & 0x0F`**

With `limit = 103` this evaluates to `0x00`, and the masking matters more for what it
*excludes* than what it includes:

- **G (bit 7) = 0** — byte granularity. Setting G would multiply the limit by 4096, and
  the segment would extend 400 KiB past the TSS. The `iopb_offset >= limit` test in §4.1
  would then fail, silently re-opening ring-3 port access.
- **Bits 6 and 5 = 0** — in a *code* descriptor these are D/B and L; in a system
  descriptor they are reserved and must be zero. Copy-pasting the kernel code
  descriptor's flags byte (which has L set for 64-bit code) into this field is a
  well-trodden path to a `#GP` on `ltr`.

**`d.base_upper = static_cast<uint32_t>(base >> 32)`**

The whole reason this descriptor is 16 bytes. Omit this line and the descriptor still
compiles, still installs, and encodes a base with its top 32 bits zero — for a
higher-half TSS at `0xFFFFFFFF80105000` that is `0x0000000080105000`, an unmapped user
address. The `ltr` then either `#GP`s or `#PF`s while reading the TSS, and with no IDT
installed the result is a triple fault. §7 lists this first because it is the most
common way this stage fails.

**`__builtin_memcpy(&g_gdt[GDT_SELECTOR_TSS / 8], &d, sizeof(d));`**

`GDT_SELECTOR_TSS / 8` is `0x28 / 8` = 5. Copying 16 bytes from index 5 fills indices 5
and 6, which is exactly the two-slot layout from §4.3.

`memcpy` rather than `*reinterpret_cast<TssDescriptor*>(&g_gdt[5]) = d`, because the
latter writes through a pointer of a different type than the object actually stored there
and is a strict-aliasing violation — legal-looking code that GCC at `-O2` is entitled to
reorder or elide. `__builtin_memcpy` is the standard way to say "these bytes, exactly,
now", and for 16 bytes GCC emits two `mov`s with no function call.

---

### `kernel/kernel_init.cpp` — the call

```cpp
    gdt_init();          // Stage 2.1 -- lgdt, reload cs/ds/ss
    arch::tss_init();    // Stage 2.2 -- fill the TSS, install descriptor, ltr
    idt_init();          // Stage 2.3
```

The order is fixed by [[06 - Architecture Overview]]'s init table — step 3 is "GDT +
TSS", step 4 is "IDT + exception handlers" — and by two hard dependencies:

- `tss_init` **after** `gdt_init`, because `ltr` reads a descriptor out of the GDT the
  `GDTR` currently points at, and because `gdt_install_tss` writes into the array
  `gdt_init` set up.
- `tss_init` **before** `idt_init`, because Stage 2.3's gates name IST slots and assert
  via `tss_ist()` that those slots are populated. Reverse the two and the assertion fires
  at boot — which is the good outcome; without the assertion you would get a gate
  pointing at `rsp = 0`.

Both run before interrupts are enabled, so there is no window in which a fault could
arrive against a half-built table.

---

## 6. How to verify

### 6.1 What you can check right now — build time

```bash
make                    # inside the container, per [[08 - Build System]]
```

A clean build is a real result here: five `static_assert`s in `tss.hpp` and four more in
`gdt.cpp` all passed, which means the 104-byte layout, the 16-byte descriptor, the
10-byte `lgdt` operand, and the page-aligned guard are each confirmed by the compiler.

Then confirm the stacks are where you think:

```bash
nm -C build/kernel.elf | grep -iE 'g_stack|g_tss'
```

Expected — five stacks and the TSS, all lower-case `b` (local `.bss` symbols, because
they are in an anonymous namespace):

```
ffffffff8011a000 b arch::(anonymous namespace)::g_stack_db
ffffffff8011f000 b arch::(anonymous namespace)::g_stack_df
ffffffff80124000 b arch::(anonymous namespace)::g_stack_mce
ffffffff80129000 b arch::(anonymous namespace)::g_stack_nmi
ffffffff8012e000 b arch::(anonymous namespace)::g_stack_rsp0
ffffffff80133000 b arch::(anonymous namespace)::g_tss
```

Two things to read off this: every stack address ends in `000` (page-aligned, so
`alignas(4096)` worked), and consecutive stacks differ by `0x5000` = 20480 bytes
(16 KiB + 4 KiB, so there is no padding between them).

Confirm they cost nothing on disk:

```bash
size build/kernel.elf
```

`.bss` should be about **102400 bytes** larger than before this stage, while `text` and
`data` are unchanged and the file size on disk has not grown. That is the whole argument
for `.bss` in one command.

### 6.2 What you can check at boot — `ltr` survived

```bash
make run
```

Expected on serial:

```
[  0.000] info  gdt: loaded, 7 entries, limit 55
[  0.000] info  tss: TR=0x0028 rsp0=0xffffffff80132000 ist1(#DF)=0xffffffff80123000 ist2(NMI)=0xffffffff8012d000
[  0.000] info  idt: ...
```

**Surviving `ltr` is the test.** There is no IDT yet, so a bad descriptor produces `#GP`,
which has no handler, which triple-faults, which reboots. If you see the line after
`tss_init` at all, the descriptor was well-formed and `TR` is loaded. This is the same
"survival is the check" logic [[Stage 2.1 - The Global Descriptor Table]] uses for
`gdt_flush`.

Sanity-check the printed values against `nm`: each IST pointer must equal its stack's
symbol address + `0x5000` (4 KiB guard + 16 KiB stack). If a pointer equals the symbol
address exactly, you returned `&stack[0]` from `top()`.

### 6.3 What you can check in the monitor — `TR` is loaded

Boot with the monitor on stdio:

```bash
qemu-system-x86_64 -cdrom build/os.iso -m 512M \
    -serial file:serial.log -monitor stdio \
    -no-reboot -no-shutdown
```

At the `(qemu)` prompt:

```
(qemu) info registers
```

Look for the `TR` line among the segment registers:

```
TR =0028 ffffffff80133000 00000067 00008b00 DPL=0 TSS64-busy
     │           │            │        │             │
     │           │            │        │             └─ decoded type
     │           │            │        └─ raw flags (varies with base[31:24])
     │           │            └─ limit = 0x67 = 103
     │           └─ base = &g_tss, must match `nm`
     └─ selector 0x28
```

Four things to check, in order of how much they tell you:

- [ ] **Selector is `0028`, not `0000`.** `0000` means `ltr` never ran.
- [ ] **`TSS64-busy`.** QEMU decodes the type nibble. `busy` proves `ltr` executed and
      set the bit itself. `TSS64-avl` would mean the register was loaded some other way.
- [ ] **Limit is `00000067`.** 103. If it reads `00067000` you set the G bit.
- [ ] **Base matches `g_tss` from `nm`.** If the top eight hex digits are `00000000`
      you forgot `base_upper`.

You can also dump the raw descriptor. Take the address of `g_gdt` from `nm` and read two
qwords:

```
(qemu) x/2gx 0xffffffff80115000
ffffffff80115000: 0x8000891050000067 0x00000000ffffffff
```

Compare against the golden bytes in §4.2 — same shape, with your base substituted.

### 6.4 Tier-1 unit test — descriptor encoding

[[Phase 2 - Overview]] names descriptor encoding as an ideal Tier-1 target: pure bit
manipulation with a published correct answer. Add to `tests/unit/test_gdt.cpp`, per
[[09 - Testing Strategy]]:

```cpp
TEST(TssDescriptor, EncodesHigherHalfBase) {
    // The golden vector from Stage 2.2 section 4.2.
    uint64_t words[2] = {0, 0};
    encode_tss_descriptor(words, 0xFFFFFFFF80105000ull, 103);

    EXPECT_EQ(words[0], 0x8000891050000067ull);
    EXPECT_EQ(words[1], 0x00000000FFFFFFFFull);
}

TEST(TssDescriptor, IsSixteenBytes) {
    EXPECT_EQ(sizeof(TssDescriptor), 16u);
}

TEST(Tss, LayoutMatchesIntelSpec) {
    EXPECT_EQ(sizeof(arch::Tss), 104u);
    EXPECT_EQ(offsetof(arch::Tss, rsp0), 0x04u);
    EXPECT_EQ(offsetof(arch::Tss, ist1), 0x24u);
    EXPECT_EQ(offsetof(arch::Tss, iopb_offset), 0x66u);
}
```

To make the first test possible, factor the field arithmetic in `gdt_install_tss` into a
free function that writes into a caller-supplied buffer instead of into `g_gdt` — a
three-line refactor that makes the whole encoding testable on the host, with no QEMU in
the loop. This test catches the missing `base_upper` in under a second, versus a
triple-fault bisect.

### 6.5 The payoff test — a double fault instead of a reboot

**This is why the stage exists, and it needs the IDT.** Populating the TSS does nothing
observable on its own: the IST is only consulted when a *gate* names a slot, and gates
arrive in [[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] with handlers in
Stage 2.4. Come back and run this at the end of Stage 2.4, then tick the box in
§Progress. Write the test now so it is waiting.

Add to `kernel_init.cpp`, temporarily:

```cpp
// TEMPORARY -- Stage 2.2 payoff test. Delete after it passes.
[[gnu::noinline]] static uint64_t blow_the_stack(uint64_t depth) {
    volatile uint8_t pad[512];
    pad[0] = static_cast<uint8_t>(depth);
    // The `+ pad[0]` is load-bearing: it makes this NOT a tail call, so GCC
    // cannot turn the recursion into a loop that never grows the stack.
    return blow_the_stack(depth + 1) + pad[0];
}
```

and call it:

```cpp
    volatile uint64_t sink = blow_the_stack(0);
    (void)sink;
```

Three details, each of which the optimiser would otherwise defeat:

- `[[gnu::noinline]]` — otherwise GCC inlines the recursion into a loop.
- `+ pad[0]` after the call — makes it a non-tail call, so a real frame is pushed.
  Without it, `-O2` performs tail-call elimination and the stack never grows; you sit in
  an infinite loop and nothing faults.
- `volatile uint8_t pad[512]` — `volatile` stops the array being optimised away, and 512
  bytes per frame means roughly eight frames per 4 KiB page. The stack pointer therefore
  cannot step *over* an unmapped page without touching it.

**Before the IST** (comment out `g_tss.ist1 = ...`, or set the #DF gate's IST to
`IST_NONE`), run:

```bash
qemu-system-x86_64 -cdrom build/os.iso -m 512M -serial stdio \
    -d int,cpu_reset -no-reboot -no-shutdown 2> trace.log
```

`trace.log` ends like this — three `check_exception` lines and then the machine is gone:

```
check_exception old: 0xffffffff new 0xe
    47: v=0e e=0002 i=0 cpl=0 IP=0008:ffffffff8010a3c1 SP=0010:ffffffff801fefe0 CR2=ffffffff801fefe0
check_exception old: 0xe new 0xe
    48: v=08 e=0000 i=0 cpl=0 IP=0008:ffffffff8010a3c1 SP=0010:ffffffff801fefe0 CR2=ffffffff801fefe0
check_exception old: 0x8 new 0xe
```

Read it: a page fault (`v=0e`), then a page fault while delivering it, which the CPU
promotes to `v=08` — double fault. Then a third fault while delivering *that*, with
`old: 0x8`, and QEMU resets. **Note `SP` on the `v=08` line: still the overflowed
stack.** There was nowhere else to go. Serial output stops mid-line and, without
`-no-reboot`, you would be looking at the Limine menu with no idea why.

**With the IST**, the same command produces:

```
check_exception old: 0xffffffff new 0xe
    47: v=0e e=0002 i=0 cpl=0 IP=0008:ffffffff8010a3c1 SP=0010:ffffffff801fefe0 CR2=ffffffff801fefe0
check_exception old: 0xe new 0xe
    48: v=08 e=0000 i=0 cpl=0 IP=0008:ffffffff8010a3c1 SP=0010:ffffffff80123000 CR2=ffffffff801fefe0
```

Two differences, and both are the whole stage:

1. **There is no third `check_exception` line.** The `#DF` was delivered successfully.
2. **`SP` on the `v=08` line changed** from `ffffffff801fefe0` (the dying stack) to
   `ffffffff80123000` — which is exactly the `ist1(#DF)=` value `tss_init` logged at
   boot. The CPU switched stacks.

And on serial you get the thing you have been building toward:

```
*** PANIC: DOUBLE FAULT (vector 8) ***
  error code 0
  rip 0xffffffff8010a3c1  rsp 0xffffffff801fefe0  rflags 0x00010006
  cs  0x0008  ss 0x0010  cr2 0xffffffff801fefe0
  rax 0x0000000000000c41  rbx ...
  ...
  Backtrace:
    ffffffff8010a3c1  blow_the_stack+0x21
    ffffffff8010a3d6  blow_the_stack+0x36
    ...
```

A reboot loop became a bug report. Addresses and line numbers will differ; the two
structural facts — no third exception, and `SP` equal to your `ist1` — are what you are
verifying.

### 6.6 Checklist

- [ ] `make` succeeds — all nine `static_assert`s pass
- [ ] `nm -C build/kernel.elf | grep g_stack` shows five page-aligned symbols `0x5000` apart
- [ ] `size build/kernel.elf` shows `.bss` up by ~102400 bytes, `text`/`data` unchanged
- [ ] The kernel survives `ltr` and prints the `tss:` line
- [ ] Each logged IST pointer equals its `nm` symbol address + `0x5000`
- [ ] `info registers` shows `TR =0028 ... 00000067 ... TSS64-busy`
- [ ] `x/2gx &g_gdt[5]` matches the §4.2 shape, with a non-zero second qword
- [ ] Tier-1 test `TssDescriptor.EncodesHigherHalfBase` passes on the host
- [ ] *(after Stage 2.4)* `blow_the_stack` produces a `#DF` panic with a backtrace
- [ ] *(after Stage 2.4)* `-d int` shows no third `check_exception`, and `SP` on the
      `v=08` line equals `ist1`

---

## 7. Common traps

**Symptom: the machine triple-faults the moment you add `tss_init()` — a reboot loop,
and the `tss:` log line never prints.**
`ltr` faulted. With no IDT that is instantly fatal, so there is no diagnostic; you have
to find it by inspection. In descending order of likelihood:

- **`base_upper` never written.** The base is truncated to 32 bits, so the CPU reads the
  TSS from an unmapped low address. Check `x/2gx` on the descriptor: the second qword must
  be `0x00000000ffffffff` for a higher-half kernel, not `0`.
- **The descriptor was written as 8 bytes.** If you reused Stage 2.1's 8-byte
  `GdtEntry` for the TSS, GDT index 6 holds whatever was there before and the CPU reads
  it as base bits 63:32 plus reserved bits. `static_assert(sizeof(TssDescriptor) == 16)`
  is the fix.
- **Wrong type nibble.** `access` must be `0x89`. `0x8B` is a *busy* TSS — `#GP`.
  `0x99` sets S=1, making it a data descriptor — `#GP`. `0x09` clears the present bit —
  `#GP`.
- **L or D/B set in the granularity byte.** Copy-pasted from the kernel code descriptor.
  Bits 5 and 6 of that byte must be zero in a system descriptor.
- **The GDT limit was not grown.** You enlarged `g_gdt[]` but `GdtPointer.limit` is a
  literal from Stage 2.1. Selector `0x28` then exceeds the limit — `#GP`. Always compute
  `sizeof(g_gdt) - 1`.
- **`tss_init()` called twice.** The first `ltr` set the busy bit; the second sees type
  `0xB` and refuses. Call it once.

Isolate it with `-d int,cpu_reset -no-reboot -no-shutdown` and read the *first*
exception in the log — everything after it is noise ([[14 - Debugging Playbook]]).

---

**Symptom: the stack-overflow test still resets the machine, even though `info
registers` shows `TR` loaded correctly.**
The TSS is fine; the *gate* is not using it. The IST index in the IDT gate is `0`, which
means "do not switch stacks" — the legacy behaviour — so the CPU ignores the IST
entirely.

**The field is 1-based.** There is no slot 0. `IST_DOUBLE_FAULT` is `1` and it selects
`ist1`. Writing `0` because "it's the first one" is the classic off-by-one here, and it
fails silently: everything boots, every test passes, and the one situation the feature
exists for behaves exactly as if you had never built it.

The mirror-image bug is just as bad: a gate naming slot `5`, `6`, or `7`, which
`tss_init` deliberately left at zero. The CPU loads `rsp = 0` and pushes to address 0 —
a guaranteed fault, so an IST that is *worse* than none. Guard both directions in
Stage 2.3:

```cpp
    if (ist != IST_NONE) {
        KASSERT(ist <= IST_HIGHEST_USED);
        KASSERT(tss_ist(ist) != 0);
    }
```

---

**Symptom: the double-fault handler itself faults, or the panic prints garbage — random
characters, impossible register values, a backtrace into nowhere.**
The IST pointer is the *start* of the stack array instead of its end. Stacks grow down,
so the CPU's first push writes 8 bytes *below* the address you gave it — into the guard
region, and then straight on down through whatever `.bss` object the linker placed
before it. The handler runs while destroying memory it does not own, including possibly
its own arguments.

Diagnose it in one line: compare the logged `ist1` against `nm`. If `ist1` equals the
`g_stack_df` symbol address exactly, that is the bug; it should be `0x5000` higher.

```cpp
    // wrong -- the LOWEST address in the array
    g_tss.ist1 = reinterpret_cast<uint64_t>(&g_stack_df.stack[0]);

    // right -- one past the END
    g_tss.ist1 = reinterpret_cast<uint64_t>(&g_stack_df.stack[KERNEL_STACK_SIZE]);
```

The `KASSERT` in `tss_init` step 5 exists solely to turn this into a named boot-time
panic. Keep it.

---

**Symptom: from Phase 6, a ring-3 process can execute `out` and reprogram hardware — the
PIC gets remapped, or the timer changes rate, and no kernel code did it.**
`iopb_offset` is `0`. The CPU compares it against the segment limit of 103, concludes a
bitmap exists at TSS base + 0, and reads permission bits out of the first 104 bytes of
the TSS itself. A **clear bit means allowed**, and most of the TSS is zeros — reserved
fields, `rsp1`, `rsp2`, the unused IST slots, and the zero bytes inside your pointers. A
large, effectively random set of ports is granted to ring 3.

The fix is one line, and it depends on an inequality:

```cpp
    g_tss.iopb_offset = sizeof(Tss);            // 104
    gdt_install_tss(base, sizeof(Tss) - 1);     // limit 103
```

`104 >= 103` is what makes the CPU say "no bitmap, deny everything". Break the
relationship in either direction — set the limit to `sizeof(Tss)`, or set the G bit so
the limit becomes 400 KiB — and the hole reopens with no other visible symptom. Test it
in Phase 6 by having a user program execute `out`; it must take `#GP`.

---

**Symptom: it works perfectly on one core; under `make run-smp` you get random
corruption, tasks resuming on the wrong stack, or a double fault whose register dump
makes no sense.**
One TSS, several CPUs. `rsp0` is inherently per-CPU: two cores in the kernel at once are
using two different kernel stacks, and a single `rsp0` field can only name one of them.
Whichever core wrote it last wins, and the other core's next user-mode interrupt lands
on a stack that is already in use. The IST stacks have the identical problem — two cores
can double-fault independently and would share one 16 KiB stack.

This cannot bite before [[Phase 12 - Overview|Phase 12]], which is why one TSS is the
right answer today. What decision 3.5 buys you is that the fix stays additive: `Tss` is
a plain layout struct that can be placed in a per-CPU area unchanged, every caller
already goes through `tss_set_rsp0()` rather than touching a global, and `tss_init()` is
the single place the sequence lives. Phase 12 gives each CPU its own GDT (because the TSS
selector must differ per core), its own TSS, and its own set of IST stacks, and calls the
same `tss_init` from AP bring-up.

**Do not "fix" it early by adding `MAX_CPUS` arrays now.** Per-CPU code that has never
run on more than one CPU is not per-CPU code.

---

## 8. What this unlocks

[[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] can now build gates whose IST
field names a real stack, and Stage 2.4's stubs and Stage 2.5's handlers inherit a
double-fault path that survives a destroyed stack — which is what makes the rest of Phase
2 debuggable rather than a bisect against reboots. [[Phase 4 - Overview|Phase 4]] turns
the reserved guard regions into genuinely unmapped pages, at which point stack overflow
becomes a precise page fault rather than silent `.bss` corruption; the layout here is
what makes that a small change. [[Phase 5 - Overview|Phase 5]]'s scheduler calls
`tss_set_rsp0()` on every context switch. [[Phase 6 - Overview|Phase 6]] depends on
`rsp0` completely — without it, the first interrupt taken in ring 3 pushes a frame onto a
user-controlled stack pointer, which is a kernel compromise if it works and a triple
fault if it does not — and on `iopb_offset` to keep ring 3 away from the hardware.
[[Phase 12 - Overview|Phase 12]] replicates all of this per CPU.

The failures from getting this stage wrong are unusually quiet: a mis-set `iopb_offset`
produces no symptom until a user process pokes a port four phases from now, and an IST
pointer off by 16 KiB produces no symptom until the day you actually double-fault. That
is what §6's assertions and unit tests are for.

---

## 9. Reading

- **OSDev — Task State Segment**, the 64-bit section and the IST paragraph:
  <https://wiki.osdev.org/Task_State_Segment> — the shortest correct statement of the
  104-byte layout. Ignore everything it says about 32-bit hardware task switching.
- **OSDev — Global Descriptor Table**, "System Segment Descriptor":
  <https://wiki.osdev.org/Global_Descriptor_Table> — the bit tables §4.2 is drawn from,
  including where the 64-bit base splits.
- **OSDev — Double Fault**: <https://wiki.osdev.org/Double_Fault> — the table of which
  exception pairs promote to #DF and which promote straight to triple fault. Worth
  reading before Stage 2.5.
- **OSDev — Exceptions**: <https://wiki.osdev.org/Exceptions> — vector numbers and which
  push an error code; you need vector 8, 2, 18, and 1 from it for the gate table.
- **Philipp Oppermann, "Double Faults"**:
  <https://os.phil-opp.com/double-fault-exceptions/> — the single best written
  explanation of the stack-overflow → #PF → #DF → triple-fault cascade and why the IST
  fixes it. It is Rust, but the hardware reasoning is language-independent and the
  diagrams are excellent.
- **Intel SDM Vol. 3A** — <https://software.intel.com/en-us/articles/intel-sdm> — the
  ground truth. §7.7 "Task Management in 64-bit Mode" for the TSS layout and the
  statement that hardware task switching is not supported; §6.14.5 "Interrupt Stack
  Table" for the IST; §6.14.2 for the 16-byte alignment of the interrupt frame.
  Vol. 1's "I/O Permission Bit Map" section for the `iopb_offset >= limit` rule.
- **AMD64 Architecture Programmer's Manual Vol. 2**, ch. 12 "Task Management":
  <https://www.amd.com/system/files/TechDocs/24593.pdf> — AMD designed long mode, and
  their prose on why hardware task switching was dropped is clearer than Intel's.
- **Linux `arch/x86/include/asm/cpu_entry_area.h`**:
  <https://github.com/torvalds/linux/blob/master/arch/x86/include/asm/cpu_entry_area.h> —
  a production kernel's exception-stack set (DF, NMI, DB, MCE, and the SEV-ES ones) and
  its guard pages. Confirms the §3.2 verdict, including that #PF is *not* on an IST.
- Vault: [[Phase 2 - Overview]] · [[Stage 2.1 - The Global Descriptor Table]] ·
  [[06 - Architecture Overview]] (init order, memory layout) ·
  [[14 - Debugging Playbook]] (the triple-fault section, `-d int,cpu_reset`) ·
  [[09 - Testing Strategy]] (the Tier-1 encoding test) ·
  [[Stage 0.7 - Panic and KASSERT]] (what `KASSERT` compiles to in release builds)

Next: **[[Stage 2.3 - The Interrupt Descriptor Table]]**

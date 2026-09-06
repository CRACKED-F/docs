# Stage 2.1 — The Global Descriptor Table

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]
**Files you create:** `kernel/arch/x86_64/cpu/gdt.hpp`, `kernel/arch/x86_64/cpu/gdt.cpp`
**Files you change:** `kernel/kernel_init.cpp`
**Deliverable:** the kernel runs on its own 64-bit GDT — `CS` and `SS` hold selectors you wrote, ring-3 descriptors exist in the order `sysret` mandates, and two consecutive slots are reserved for the 16-byte TSS descriptor [[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] installs.

> **This note replaces a 32-bit-era version.** If you are reading a cached copy that
> mentions **GRUB**, a **32-bit `lgdt` base pointer**, or **user code before user data**,
> all three are wrong. There is no GRUB in this project ([[ADR-0003 - Limine as the Bootloader]]);
> `lgdt` reads a 64-bit base in long mode (§4.7); and the user descriptors must be ordered
> data-then-code or `sysret` cannot work (§3.2). The corrections are called out where they
> occur.

---

## Progress

- [ ] Re-read the 32-bit vs 64-bit table in [[Phase 2 - Overview]] — every row is a way a 32-bit tutorial breaks here
- [ ] Create `kernel/arch/x86_64/cpu/gdt.hpp` — packed `GdtEntry`, `GdtPointer` with a **64-bit** base, the `constexpr` encoder
- [ ] Add the selector constants, with **user data at `0x18` and user code at `0x20`** — the order `sysret` requires
- [ ] Size the table at **7** entries: 5 segment descriptors plus 2 slots reserved for Stage 2.2's 16-byte TSS descriptor
- [ ] Write the `static_assert`s, including the one that turns the `sysret` ordering into a build error
- [ ] Create `kernel/arch/x86_64/cpu/gdt.cpp` — the `constexpr` table, the GDTR, `gdt_init()`
- [ ] Write the reload sequence: `lgdt`, `mov` for the data segments, **`lretq`** for `CS`
- [ ] Call `arch::gdt_init()` from `kernel_init` as the first thing in Phase 2, before `tss_init()`
- [ ] Boot and survive the far return — a bad GDT triple-faults on the spot
- [ ] Check `objdump` shows the five golden qwords from §4.5
- [ ] Check `info registers` shows `CS =0008`, `SS =0010`, and `GDT= <base> 00000037`
- [ ] Run with `-d int` and confirm there is no `check_exception` line
- [ ] Add the Tier-1 encoding test with the golden bytes from §4.5
- [ ] Committed with a message like `feat(arch): our own 64-bit GDT with sysret-ordered descriptors`

---

## 1. Why this stage exists

Limine hands your kernel a CPU that is already in long mode, with paging on, interrupts
off, and a working stack. It also hands you a **GDT that is not yours**. It had to load
one — you cannot be in long mode without a code descriptor whose L bit is set — so it
built a small table, loaded it, jumped into your `kmain`, and moved on. That table is a
means to an end, and the end has been reached.

Three things go wrong if you keep it.

**It is in memory you are about to take back.** Limine's own structures live in memory the
boot protocol marks as *bootloader-reclaimable*. [[Phase 3 - Overview|Phase 3]]'s physical
memory manager will fold exactly that memory into the free-page pool, because that is what
"reclaimable" means and because you will want those pages. The first allocation that lands
on Limine's GDT rewrites your descriptors with heap metadata, and the next thing that
loads a segment register faults. The bug appears in Phase 3, weeks after the cause, and
looks like an allocator bug.

**It does not contain the descriptors you need.** A bootloader runs entirely in ring 0. It
has no reason to define a DPL-3 code segment, a DPL-3 data segment, or a TSS descriptor.
[[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] needs a TSS slot to run `ltr` into.
[[Phase 6 - Overview|Phase 6]] needs the ring-3 pair to enter user mode at all. You cannot
append them to a table you do not own the storage for and whose limit you did not set.

**Its descriptor order is not yours to choose.** This is the one that costs the most and
shows up the latest. `syscall` and `sysret` do not take selector operands; they *compute*
selectors by adding fixed offsets to a value in an MSR. That arithmetic only produces
correct selectors if your descriptors sit in one specific order. Limine has no obligation
to use that order — and neither did the previous version of this note, which listed the
user descriptors backwards. Getting it right costs nothing today. Getting it wrong costs a
renumbering of every selector constant, every IDT gate, and every `iretq` frame in Phase 6.

There is a fourth reason, and it is the honest one: from here to the end of the project,
every table the CPU reads is a table you built. The GDT is the smallest of them and the
one with the clearest specification. Build it now, with `static_assert`s that pin the
layout, and the IDT in [[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] is the same
exercise with more entries.

What you get at the end of this stage is invisible: `CS` holds `0x08` instead of whatever
Limine used, and the machine keeps running. That is the entire observable result, and §6
explains why *surviving* is a real test rather than a weak one.

---

## 2. The concept

### 2.1 What segmentation was actually for

Segmentation is the oldest memory-management mechanism on this architecture, and
understanding what it *was* is what makes it obvious why it is nearly gone.

**8086, 1978.** Registers are 16 bits, so a pointer reaches 64 KiB. Intel wanted 1 MiB of
address space. The fix was to add a second 16-bit register — a *segment* register — and
compute the physical address as `segment * 16 + offset`. Four segment registers named the
regions currently in use: `CS` for code, `DS` for data, `SS` for the stack, `ES` for
everything else. This is why they are called what they are called, and why there are
exactly those four plus `FS`/`GS`, which arrived on the 386.

**80286 and 80386, protected mode.** Segments stopped being a multiply-by-16 trick and
became a protection mechanism. A segment register no longer holds an address; it holds a
**selector**, which is an index into a table of **descriptors**. Each descriptor carries:

- a **base** — where the segment starts in linear address space,
- a **limit** — how long it is, checked by hardware on *every* access,
- a **DPL** — the privilege level required to use it,
- a **type** — code or data, readable, writable, executes-downward, conforming.

That is a real protection system. A program could be given a data segment 64 KiB long, and
any access past the end raised a fault, from hardware, with no software cost. Code and data
could be separated so that a buffer overflow could not reach into executable memory. It
predates paging on this architecture and it does a genuinely different job.

**And then nobody used it.** Two reasons. First, the 386 also introduced paging, which
does the same protection job at 4 KiB granularity, per process, with a mechanism that also
supports swapping and copy-on-write and memory-mapped files — none of which segmentation
can do. Second, C. The C memory model wants one flat address space where a pointer is a
number; segmented pointers are `far`/`near` and they poison every API. So every serious
32-bit operating system converged on the same trick: define segments with **base 0 and the
maximum limit**, so that "the segment" is the entire address space, and let paging do the
real work. The **flat model**. Segmentation was still there, still enforced, still costing
transistors, but every descriptor said "everything".

AMD noticed. When they designed x86-64, they deleted the part nobody used.

### 2.2 The crucial 64-bit fact: segmentation is essentially disabled

**In 64-bit mode, the CPU ignores the base and the limit in `CS`, `DS`, `ES` and `SS`.**
Not "conventionally set to zero" — *ignored*. The base is treated as 0 and the limit check
is not performed, whatever bytes are in the descriptor. You can put `base = 0xDEADBEEF,
limit = 0x00001` in your data descriptor and nothing changes.

`FS` and `GS` are the two exceptions, and only partially: they keep a usable base, but in
long mode the full 64-bit base comes from the MSRs `IA32_FS_BASE`, `IA32_GS_BASE` and
`IA32_KERNEL_GS_BASE`, not from the descriptor. Loading a selector into `FS` or `GS`
resets that base from the descriptor's 32-bit field, so a kernel that uses `GS` for
per-CPU data must write the MSR *after* the selector load, never before. That is
[[Phase 6 - Overview|Phase 6]]'s and [[Phase 12 - Overview|Phase 12]]'s problem; Stage 2.1
only needs you to know the ordering exists.

So what does a descriptor still carry?

```
      An 8-byte descriptor in long mode:

      ┌──────────────────────────────────────────────┐
      │  base[31:0]     ── IGNORED for CS/DS/ES/SS    │
      │  limit[19:0]    ── IGNORED for CS/DS/ES/SS    │
      ├──────────────────────────────────────────────┤
      │  P     present            ── READ             │
      │  DPL   privilege level    ── READ  ★          │
      │  S     system vs code/data── READ             │
      │  type  code/data, R/W, DC ── READ             │
      │  L     64-bit code        ── READ  ★          │
      │  D/B   32-bit default     ── READ             │
      └──────────────────────────────────────────────┘
```

Roughly forty of the sixty-four bits are dead. What survives is *privilege* and *mode*.

### 2.3 So why is there still a GDT?

Five reasons, and each one of them is load-bearing for a later stage in this phase.

**1. The CPU requires valid selectors.** `CS` and `SS` must contain something the CPU can
resolve. There is no "segmentation off" bit. If `CS` names a descriptor that is not
present, is not a code segment, or has L and D both set, the load faults. The table is
mandatory even though most of its content is ignored.

**2. Privilege level lives in `CS`.** The current privilege level — CPL, the thing that
decides whether `cli`, `lgdt`, `in`, `out` and a write to `CR3` are legal — is *literally
the low two bits of `CS`*. There is no separate CPL register. Ring 3 exists because the
CPU is running with a `CS` whose bottom two bits are `11` and whose descriptor has
`DPL = 3`. Without a DPL-3 code descriptor in your GDT there is no way to enter user mode,
because there is no selector value that would mean it.

**3. `syscall` and `sysret` demand a specific descriptor order.** Neither instruction takes
an operand. Both derive `CS` and `SS` by adding fixed offsets to a 16-bit field in
`IA32_STAR`. That is §3.2 and §4.8, and it is the reason this stage cares about ordering
at all.

**4. The TSS descriptor has to live somewhere.** `ltr` takes a GDT selector. The Task State
Segment — which holds `rsp0` and the seven IST stacks that make a stack overflow
survivable — is reachable only through a **16-byte system-segment descriptor occupying two
consecutive GDT slots**. Stage 2.2 writes it; this stage reserves the slots and sizes the
limit to cover them.

**5. IDT gates name a code selector.** Every one of the 256 gates in
[[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] contains a 16-bit selector field
that must point at a ring-0 64-bit code descriptor in *your* GDT. Every interrupt loads
`CS` from that field. If the GDT under it is Limine's reclaimed memory, every interrupt is
a fault.

### 2.4 Selectors, the GDTR, and the hidden cache

A **selector** is 16 bits:

```
   15                                3    2   1  0
  ┌──────────────────────────────────┬────┬───────┐
  │            index                 │ TI │  RPL  │
  └──────────────────────────────────┴────┴───────┘
       descriptor number             0=GDT  requested
                                     1=LDT  privilege
```

Because the index is bits 15:3, the selector value is the **byte offset** of the
descriptor: index 1 is selector `0x08`, index 2 is `0x10`, index 3 is `0x18`. This is why
segment registers take `0x08`, not `1` — a trap the old version of this note correctly
flagged and which is still worth flagging.

The `GDTR` is a special register holding a 16-bit **limit** and a 64-bit **base**. `lgdt`
loads it from a 10-byte operand in memory; `sgdt` reads it back. The limit is the offset of
the *last valid byte*, so it is `size - 1`.

The critical mechanical detail, and the one that explains half of §7:

> When you load a segment register, the CPU reads the descriptor **once**, and caches its
> base, limit and flags in a *hidden* part of the register. Everything afterwards uses the
> cache. Changing the GDT in memory, or `lgdt`-ing an entirely different GDT, does **not**
> re-read anything.

```
   mov $0x10, %ax        ┌──────────────────────────┐
   mov %ax, %ds  ────►   │ GDT[2]  read ONCE        │
                         └────────────┬─────────────┘
                                      ▼
                    DS = 0x10  │ hidden: base, limit, flags │
                               └──────────────────────────┘
                        every later access uses the hidden part
```

So after `lgdt` your new table is *installed* but no segment register is *using* it — they
are all still running on cached descriptors from Limine's table, which no longer exists as
far as the GDTR is concerned. That is why `lgdt` is only half the job.

### 2.5 The reload, and why `CS` is different

Reloading `DS`, `ES`, `FS`, `GS` and `SS` is a `mov`. Reloading `CS` is not, because
**`mov cs, ax` is not a valid instruction.** The `MOV Sreg, r/m16` encoding excludes `CS`
as a destination; the assembler will reject it. Reading `CS` (`mov %cs, %ax`) is fine, and
that asymmetry catches people.

The reason is that changing `CS` changes the privilege level and the instruction mode, so
it must happen atomically with a change of `RIP`. The instructions that do that are the
**far transfers**: far jump, far call, far return, and `iretq`. In 64-bit mode the
*direct* far jump with an immediate `ptr16:32` operand (opcode `EA`) **is not encodable** —
this is the second correction to the old note, which said "far jump". What is available is
the indirect far jump through memory, and the far return.

The far return is the clean one. `lretq` pops a 64-bit `RIP` and then a 64-bit `CS` off
the stack. So you *fabricate a far return*: push the selector you want, push the address
you want to land on, and execute `lretq`. The CPU validates the descriptor, loads `CS`,
sets `RIP`, and you continue on the next line. Four instructions, no linker games, no
separate `.S` file.

```
  push  $0x08          rsp ─►┌──────────┐
  lea   1f(%rip), %rax        │  CS=0x08 │  ◄── [rsp+8]
  push  %rax                  │  RIP=1b  │  ◄── [rsp]
  lretq  ───────────────────► └──────────┘
1:                            pops RIP, then CS. CPL, mode
                              and RIP all change together.
```

Note it is `lretq`, not `lret`. The default operand size for a far return in 64-bit mode is
**32 bits**; without the REX.W prefix the CPU pops a 4-byte `EIP` and a 4-byte `CS` from
the wrong offsets and you triple-fault. `lretq` is the GAS mnemonic that emits REX.W.

---

## 3. Design decisions and tradeoffs

### 3.1 Decision: replace Limine's GDT, or keep using it?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — build and load our own** | A 7-entry table in the kernel image; `lgdt`; reload every segment register | ~60 min, 56 bytes of `.data` | ✅ |
| B — keep Limine's | Do nothing. Segment registers already contain working selectors | Free today. No ring-3 descriptors, no TSS slot, unknown ordering, and the storage is reclaimed in Phase 3 | ❌ |
| C — keep Limine's and append to it | `sgdt` to find it, write past the last entry, raise the limit | Free-ish | ❌ |

**Why A.** The Limine boot protocol guarantees a **state** at handover — long mode, paging
enabled, interrupts disabled, a valid stack, and a GDT good enough to be executing — not a
**table you may keep**. It is explicit that the kernel should load its own GDT as soon as
it is able to. Everything Limine leaves behind lives in memory that the memory map marks
bootloader-reclaimable, and [[Phase 3 - Overview|Phase 3]]'s PMM exists specifically to
reclaim it. Depending on a structure you have promised to overwrite is not a shortcut, it
is a delayed fault.

Building your own also buys the three things this phase needs and Limine cannot provide:
a DPL-3 code/data pair, two consecutive slots for the 16-byte TSS descriptor, and a
descriptor **order** you control (§3.2).

**Why not B.** Concretely, in the order you would hit them:

- Stage 2.2 calls `ltr` with a selector. There is no TSS descriptor in Limine's table and
  no slot you own to put one in. The stage cannot be completed.
- Phase 6 needs a `CS` with `DPL = 3`. There is none. `iretq` into ring 3 with a ring-0
  `CS` raises `#GP`, and there is no selector value that would work instead.
- Phase 3 reclaims the pages. Then the first `iretq`, the first interrupt, or the first
  `mov %ax, %ds` reads a descriptor out of freshly-allocated heap. The failure is a
  `#GP` or a triple fault whose cause is three phases upstream.

**When B would be right.** If the firmware or bootloader documented its table as permanent
and provided the layout you need. Some paravirtual entry environments do promise a stable
descriptor set. A UEFI *application* — as opposed to an OS — reasonably runs on the
firmware's GDT forever, because it never leaves ring 0 and never loads a TSS. And on
AArch64 or RISC-V there is no GDT at all: this entire stage is x86 archaeology that those
targets skip. It is worth knowing that the work here is a property of the architecture,
not of operating systems.

---

### 3.2 Decision: descriptor order — arbitrary, or what `sysret` mandates?

**This is the decision in this stage that bites, and it bites in Phase 6.**

| Option | Order | Cost | Verdict |
|---|---|---|---|
| **A (chosen)** | null, kernel code, kernel data, **user data, user code**, TSS(×2) | Zero. It is a matter of typing the lines in this order | ✅ |
| B — "natural" order | null, kernel code, kernel data, **user code, user data**, TSS(×2) | Zero today. In Phase 6 it is a renumbering of every selector constant, IDT gate and `iretq` frame — or a permanently duplicated pair of user descriptors | ❌ |
| C — Linux's order | null, kernel code, kernel data, **user 32-bit code, user data, user code**, TSS(×2) | One extra descriptor. Correct, and necessary if you ever run 32-bit user programs | ⚠️ later |

**Why A.** `syscall` and `sysret` take no operands. Both read `IA32_STAR` (MSR
`0xC0000081`) and construct selectors by **fixed offset arithmetic**:

| Instruction | Loads | From |
|---|---|---|
| `syscall` | `CS` | `STAR[47:32]` |
| `syscall` | `SS` | `STAR[47:32] + 8` |
| `sysretq` (64-bit return) | `CS` | `STAR[63:48] + 16` |
| `sysretq` (64-bit return) | `SS` | `STAR[63:48] + 8` |
| `sysret` (compat return) | `CS` | `STAR[63:48]` |

Read the `sysretq` rows again. `SS` comes from **base + 8** and `CS` comes from
**base + 16**. Since a selector is a byte offset and every descriptor is 8 bytes, that says
exactly one thing:

> **The user *data* descriptor must sit 8 bytes below the user *code* descriptor.**

With our layout — user data at index 3 (`0x18`), user code at index 4 (`0x20`) — the
required `STAR[63:48]` is `0x10`, conventionally written `0x13` with RPL 3 in the low bits.
Check it: `0x13 + 16 = 0x23` = index 4, RPL 3 = user code ✓. `0x13 + 8 = 0x1B` = index 3,
RPL 3 = user data ✓. The kernel half is `STAR[47:32] = 0x08`, giving `CS = 0x08` and
`SS = 0x08 + 8 = 0x10` — which is why kernel code must immediately precede kernel data,
and why the natural order works there. Phase 6 will write
`IA32_STAR = 0x0013000800000000` and nothing else.

Now try to make option B work. You would need a base `b` such that `b + 16` names user code
at `0x18` and `b + 8` names user data at `0x20`. The first gives `b = 0x08`; the second
gives `b = 0x18`. There is no `b`. **The order is not a preference, it is an equation with
no solution when reversed.**

> **The previous version of this note had this backwards.** It said *"User code, user data,
> and the TSS come in Phase 6."* Both halves are wrong: the order is reversed, and the
> descriptors belong here rather than in Phase 6 precisely because fixing the order later is
> the expensive part. [[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]]'s §4.3 already
> assumes the corrected order; this note is what makes the two agree.

**Why not B.** Not because it fails today — it does not. Every test in §6 passes under B.
The kernel boots, the GDT loads, `info registers` looks right. It fails on the day in Phase
6 that you first execute `sysret`, and by then the wrong selector values are compiled into:

- every `GDT_SELECTOR_*` constant and every use of them,
- the selector field of all 256 IDT gates from Stage 2.3,
- the `cs` and `ss` values in the `iretq` frames Stage 2.4's stubs build,
- the TSS selector passed to `ltr`, if you shift the TSS to make room,
- any hand-written assembly with a literal `0x18` or `0x20` in it.

There is a cheaper escape, and you should know it exists so you can weigh it honestly:
append a *second* user data/code pair at the correct relative offsets and leave the
original pair unused. That works, costs 16 bytes, and leaves you with two sets of
"user" descriptors forever, one of which is a trap for anyone reading the table. It is a
permanent wart traded against a one-time renumbering.

**Right now the order is free. Wrong, it costs a Phase 6 rewrite.** That asymmetry is the
whole argument.

**When C would be right.** The moment you want to run 32-bit user programs. Compatibility
mode needs its own user code descriptor with `L = 0, D = 1`, and the non-REX.W `sysret`
loads `CS` from `STAR[63:48]` itself — offset zero. So the three descriptors must be
`STAR[63:48]` → 32-bit user code, `+8` → user data, `+16` → 64-bit user code, which is
exactly Linux's `USER32_CS, USER_DS, USER_CS` triple. If you ever add compat mode, insert
the 32-bit code descriptor *before* user data and everything else keeps working, because
the +8/+16 relationship between the two you already have is preserved. Building the
5-entry version now does not paint you into a corner; building B does.

---

### 3.3 Decision: a `constexpr` compile-time table, or one built at runtime?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — `constexpr` encoder, constant initialiser** | `gdt_encode()` is `constexpr`; the array's initialiser is a constant expression, so GCC emits the bytes | None | ✅ |
| B — build it in `gdt_init()` | A `set_entry(i, base, limit, access, flags)` helper called five times at boot | ~30 lines of shift-and-mask running at the least debuggable moment in boot, producing bytes no static tool can check | ❌ |
| C — a global object with a constructor | `struct Gdt { Gdt() { ... } }; Gdt g_gdt;` | **Never runs.** [[ADR-0007 - Freestanding C++20 as the Kernel Language\|ADR-0007]] bans global constructors and the kernel has no `.init_array` runner | ❌ |

**Why A.** Three things follow from the initialiser being a constant expression.

*The bytes exist in `kernel.elf`.* §6 dumps them with `objdump` and compares against the
golden values in §4.5 **before ever booting**. A wrong access byte is a diff, not a triple
fault.

*There is no initialisation order to reason about.* The table is correct from the instant
the image is loaded. `gdt_init()` contains no table construction at all — it computes the
GDTR and executes the reload, and that is all it can get wrong.

*Nothing needs to run before `main`.* This is the ADR-0007 point and it is not stylistic.
This kernel does not link a C++ runtime and does not walk `.init_array`; there is no code
anywhere that calls global constructors. A global with a **dynamic** initialiser therefore
compiles, links, and silently stays zero — and `lgdt` on a table of zeros means every
segment register load faults on a not-present descriptor. Option C is not "slower", it is
"does not work, with no diagnostic". A `constexpr` initialiser is a **static** initialiser:
GCC emits the finished bytes into the section and emits nothing into `.init_array`. There
is nothing to run, so nothing can fail to run.

**One honesty note about `.rodata`.** A fully `const` table would land in `.rodata`, which
would be the ideal hardening: a stray kernel write could not corrupt your descriptors.
This table cannot be `const`, because Stage 2.2 writes the TSS descriptor into slots 5 and
6 and `&g_tss` is not a constant expression — you cannot `reinterpret_cast` a pointer to an
integer in a constant expression, so the base cannot be split across bit-fields at compile
time. So the array is non-`const` and lands in **`.data`**. What you keep is the part that
matters: constant *initialisation*, therefore no global constructor. If you want the
hardening later, [[Phase 4 - Overview|Phase 4]] can map the page read-only after `ltr` has
run — at which point you must pre-set the **accessed** bit (bit 0) in every access byte,
because the CPU writes that bit when a selector is loaded and would otherwise take a page
fault inside a segment load. §4.2 says where it is.

**Why not B.** The arithmetic is identical; the difference is *where it runs*. A runtime
builder executes at the one point in boot where you have the fewest tools: no IDT, so any
mistake is a reset with no output; and the classic tutorial shape is a five-argument
`set_gdt_entry(index, base, limit, access, gran)` whose arguments are all integers and can
be transposed without a warning. Under A the same expression is evaluated by the compiler,
the result is in the object file, and `objdump` checks it in one second.

**When B would be right.** When the contents are genuinely not known at compile time.
Stage 2.2's `gdt_install_tss()` is exactly that case, and it is written as a runtime
function for exactly that reason. [[Phase 12 - Overview|Phase 12]] goes further: each core
gets its own GDT whose TSS descriptor holds *that core's* TSS address, which is a runtime
value by construction. The rule is: `constexpr` everything the compiler can know, and write
a runtime installer only for the fields that depend on addresses.

---

### 3.4 Decision: flat 4 GiB limits, or zeros?

| Option | Encoding | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — base 0, limit `0xFFFFF`, G = 1** | The conventional flat descriptor: `0x00AF9A00'0000FFFF` and friends | None | ✅ |
| B — base 0, limit 0, G = 0 | Honest about what the CPU reads in 64-bit mode | None at runtime — but every tool decodes your table as one-byte segments, and any non-64-bit descriptor added later is broken | ❌ |
| C — limit `0xFFFFF`, G = 0 (1 MiB) | A half-measure | Same as B, plus it looks deliberate, so nobody questions it | ❌ |

**Why A.** In 64-bit mode the base and the limit are ignored for `CS`, `DS`, `ES` and `SS`,
so all three options are byte-for-byte equivalent *to the CPU*. Everything else disagrees.

*Tooling reads the fields.* QEMU's `info registers` prints the limit for every segment
register; gdb and `objdump` decode descriptors; the §6 checks compare against known values.
Under B every one of those reads `00000000`, and you lose a free cross-check on whether
your encoder put the bits in the right places at all. Under A, seeing `ffffffff` in
`info registers` proves that `limit_low`, the low nibble of the granularity byte, and the
G bit all encoded correctly — three fields verified by one glance.

*Every reference shows these values.* `0x00AF9A000000FFFF` for 64-bit ring-0 code and
`0x00CF92000000FFFF` for ring-0 data are the numbers on the OSDev page, in the AMD manual's
examples, and in every other kernel's `gdt.c`. A reader comparing your table against a
reference sees a match rather than a puzzle, and so do you at 2 a.m.

*The limit comes back the moment a descriptor is not 64-bit.* Two concrete cases in this
project's future. A **compatibility-mode** user code descriptor (`L = 0, D = 1`) for
32-bit programs — §3.2 option C — enforces its limit normally; a zero limit makes it a
one-byte segment. And [[Phase 12 - Overview|Phase 12]]'s AP bring-up starts each
application processor in **real mode** and walks it up through protected mode to long mode,
which needs 16-bit and 32-bit descriptors whose limits are real. A table where half the
descriptors mean their limits and half do not is worse than one that is uniformly
conventional.

**The L bit and the D bit are mutually exclusive.** This is the flags detail that bites
here. In a *code* descriptor:

- **L** (descriptor bit 53, bit 5 of the granularity byte) = "this is 64-bit code".
- **D/B** (bit 54, bit 6) = "default operand and address size is 32-bit".

If `L = 1`, then `D` **must** be 0. Setting both makes the descriptor **invalid**, and
loading it into `CS` raises `#GP` — which, with no IDT, is a triple fault on your `lretq`.
This is why the kernel code descriptor's granularity byte is `0xAF` (`G=1, D=0, L=1,
AVL=0`) and not the `0xCF` you would copy from a 32-bit tutorial. Data descriptors use
`0xCF` (`G=1, D/B=1, L=0`) because `L` has no meaning in a data descriptor and `D/B` is
conventionally set. **Do not copy the code descriptor's flags byte to the data descriptor
or vice versa**; they differ in exactly the two bits that matter.

**When B would be right.** If you were writing a table that will only ever hold 64-bit
descriptors, and you valued "the source says precisely what the hardware does" over
convention and tooling, zeros are defensible and a few minimal kernels do it. That
condition fails here at Phase 12 at the latest. And having half the table lie about its
limits while the other half means them is the genuinely bad outcome, so pick one and be
consistent — which, for the reasons above, means A.

---

## 4. Specification

### 4.1 The 8-byte segment descriptor

Little-endian. Bit numbers are within the 64-bit descriptor.

| Bits | Width | Field | Struct member |
|---|---|---|---|
| 0–15 | 16 | `limit[15:0]` | `limit_low` |
| 16–31 | 16 | `base[15:0]` | `base_low` |
| 32–39 | 8 | `base[23:16]` | `base_mid` |
| 40–47 | 8 | **access byte** — see §4.2 | `access` |
| 48–51 | 4 | `limit[19:16]` | low nibble of `granularity` |
| 52–55 | 4 | **flags** — see §4.3 | high nibble of `granularity` |
| 56–63 | 8 | `base[31:24]` | `base_high` |

The base and limit are split into three and two pieces respectively, in a non-obvious
order, because the 386 descriptor had to remain binary-compatible with the 286's. There is
no logic to recover; encode from the table.

The struct member names match [[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]]'s
`TssDescriptor` field-for-field for the first six fields, which is deliberate: a 64-bit
system descriptor is exactly this layout plus eight more bytes.

### 4.2 The access byte, bit by bit

| Bit | Name | Meaning | Kernel code | Kernel data | User data | User code |
|---|---|---|---|---|---|---|
| 7 | **P** | Present. `0` ⇒ `#NP` on load | `1` | `1` | `1` | `1` |
| 6–5 | **DPL** | Descriptor privilege level | `00` | `00` | `11` | `11` |
| 4 | **S** | `1` = code/data, `0` = system (TSS, LDT, gates) | `1` | `1` | `1` | `1` |
| 3 | **E** | Executable. `1` = code segment | `1` | `0` | `0` | `1` |
| 2 | **DC** | Code: *conforming*. Data: *expand-down* | `0` | `0` | `0` | `0` |
| 1 | **RW** | Code: readable. Data: writable | `1` | `1` | `1` | `1` |
| 0 | **A** | Accessed. **The CPU sets this** on selector load | `0` | `0` | `0` | `0` |
| | | **byte** | **`0x9A`** | **`0x92`** | **`0xF2`** | **`0xFA`** |

Notes that matter:

- **S = 0 makes it a system descriptor.** Stage 2.2's TSS descriptor has `S = 0` and
  access byte `0x89`. A code/data descriptor with `S = 0` is not loadable into `CS`.
- **DC = 1 on a code segment means *conforming*** — code that keeps the caller's CPL rather
  than the descriptor's. Ring-3 code could then call into it and stay at ring 3 while
  executing kernel addresses. Leave it `0`.
- **RW = 0 on a code segment makes it execute-only**, so you cannot read your own constants
  through `CS`. Irrelevant in 64-bit mode but set it anyway.
- **A is written by the CPU.** If you ever map the GDT read-only (§3.3), pre-set it: the
  access bytes become `0x9B`, `0x93`, `0xF3`, `0xFB`. Do not be surprised when
  `info registers` shows `9b` where you wrote `9a` — that is the CPU, not a bug.

### 4.3 The flags nibble and the limit nibble

The byte at descriptor bits 48–55 is `flags[3:0] : limit[19:16]`.

| Bit in byte | Descriptor bit | Name | Meaning |
|---|---|---|---|
| 7 | 55 | **G** | Granularity. `0` = limit in bytes, `1` = limit in 4 KiB units |
| 6 | 54 | **D/B** | Default operand size. `1` = 32-bit. **Must be 0 if L = 1** |
| 5 | 53 | **L** | Long mode. `1` = 64-bit code segment. Code descriptors only |
| 4 | 52 | **AVL** | Available for software. The CPU ignores it entirely |
| 3–0 | 51–48 | | `limit[19:16]` |

| Descriptor | G | D/B | L | AVL | limit[19:16] | byte |
|---|---|---|---|---|---|---|
| 64-bit code | 1 | 0 | 1 | 0 | `0xF` | **`0xAF`** |
| data | 1 | 1 | 0 | 0 | `0xF` | **`0xCF`** |

`G = 1` with `limit = 0xFFFFF` gives `(0xFFFFF + 1) * 4096 = 4 GiB`.

### 4.4 What long mode ignores

| Field | `CS` | `DS` `ES` `SS` | `FS` `GS` |
|---|---|---|---|
| base | ignored (0) | ignored (0) | overridden by `IA32_FS_BASE` / `IA32_GS_BASE` |
| limit | not checked | not checked | not checked |
| P, DPL, S, type | **read and enforced** | **read and enforced** | read |
| L, D/B | **read and enforced** | ignored | ignored |

### 4.5 The table for this stage — golden bytes

| Idx | Selector | Entry | base | limit | access | gran | Descriptor qword |
|---|---|---|---|---|---|---|---|
| 0 | `0x00` | null | — | — | `0x00` | `0x00` | `0x0000000000000000` |
| 1 | `0x08` | kernel code, ring 0 | 0 | `0xFFFFF` | `0x9A` | `0xAF` | `0x00AF9A000000FFFF` |
| 2 | `0x10` | kernel data, ring 0 | 0 | `0xFFFFF` | `0x92` | `0xCF` | `0x00CF92000000FFFF` |
| 3 | `0x18` | **user data**, ring 3 | 0 | `0xFFFFF` | `0xF2` | `0xCF` | `0x00CFF2000000FFFF` |
| 4 | `0x20` | **user code**, ring 3 | 0 | `0xFFFFF` | `0xFA` | `0xAF` | `0x00AFFA000000FFFF` |
| 5 | `0x28` | TSS descriptor, low half | — | — | — | — | `0` until Stage 2.2 |
| 6 | *(consumed)* | TSS descriptor, high half | — | — | — | — | `0` until Stage 2.2 |

Seven slots ⇒ `sizeof(g_gdt) = 56` ⇒ **`lgdt` limit = 55 = `0x37`**.

This is the same table as [[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] §4.3, with
the same selector numbers. Stage 2.2's Progress list opens with *"grow the GDT array from 5
entries to 7"* and *"fix `GdtPointer` to a 64-bit base"*; build it at 7 with a 64-bit base
now and both boxes are already ticked when you get there.

The entry 0 rule: **the null descriptor must be all zeros and must be first.** Selector `0`
means "no segment"; loading it into `DS`/`ES`/`FS`/`GS` is legal and marks the register
unusable, and the CPU pushes `SS = 0` on some interrupt paths. It is not decoration — it is
the encoding of "nothing".

### 4.6 Selector values as used

| Purpose | Value | Index | RPL |
|---|---|---|---|
| Null | `0x00` | 0 | 0 |
| Kernel `CS` | `0x08` | 1 | 0 |
| Kernel `DS`/`ES`/`FS`/`GS`/`SS` | `0x10` | 2 | 0 |
| User `SS` (Phase 6) | `0x1B` | 3 | **3** |
| User `CS` (Phase 6) | `0x23` | 4 | **3** |
| TSS, for `ltr` (Stage 2.2) | `0x28` | 5+6 | 0 |

The `GDT_SELECTOR_USER_*` constants hold the RPL-0 forms (`0x18`, `0x20`) because that is
what the *offset* arithmetic in `IA32_STAR` operates on; Phase 6 ORs in the RPL where it
builds a frame. Stage 2.2 uses the same constants with the same values.

### 4.7 The `lgdt` operand — 64-bit base

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | limit = `sizeof(gdt) - 1`, inclusive |
| `0x02` | **8** | base — **64-bit** |

```cpp
struct GdtPointer {
    uint16_t limit;
    uint64_t base;    // 64-bit. NOT uint32_t.
} __attribute__((packed));
static_assert(sizeof(GdtPointer) == 10, "lgdt reads a 10-byte operand in long mode: 2 + 8");
```

**A 32-bit base here is a 32-bit-tutorial bug**, and it is the third correction to the old
version of this note. In protected mode `lgdt` reads six bytes: a 16-bit limit and a 32-bit
base. In long mode it reads **ten**. With a higher-half kernel at `0xFFFFFFFF80000000`
([[06 - Architecture Overview]], `-mcmodel=kernel`), a 32-bit base truncates
`0xFFFFFFFF80115000` to `0x80115000` — an unmapped low address — and the next segment load
faults reading a descriptor from nothing. The code *looks* right because it looks familiar,
which is why the `static_assert` is the actual defence.

The `packed` attribute is what makes this struct 10 bytes. Unpacked, `uint16_t` then
`uint64_t` gives 6 bytes of padding and `sizeof` 16; `lgdt` would then read the correct
limit and a base assembled from padding bytes.

### 4.8 The `IA32_STAR` selector rule (forward reference, Phase 6)

MSR `0xC0000081`.

| Bits | Field | Value for this layout |
|---|---|---|
| 31:0 | `SYSCALL` target `EIP` (32-bit mode only) | 0 |
| 47:32 | kernel selector base | `0x08` |
| 63:48 | user selector base | `0x13` (`0x10 \| RPL 3`) |

⇒ `IA32_STAR = 0x0013000800000000`.

| Instruction | Register | Computed selector | Must be |
|---|---|---|---|
| `syscall` | `CS` | `0x08` | kernel code, index 1 |
| `syscall` | `SS` | `0x08 + 8 = 0x10` | kernel data, index 2 |
| `sysretq` | `SS` | `0x13 + 8 = 0x1B` | user data, index 3, RPL 3 |
| `sysretq` | `CS` | `0x13 + 16 = 0x23` | user code, index 4, RPL 3 |

`sysret` synthesises the hidden descriptor state rather than reading the GDT, but the
selector *values* it produces are indices into your GDT, and the very next interrupt or
`iretq` does read them. So the descriptors must exist, be DPL 3, and be the right types.

### 4.9 The reload

| Register | Instruction | Note |
|---|---|---|
| `DS` `ES` `FS` `GS` `SS` | `mov` | Load the kernel data selector, or `0` |
| `CS` | **far transfer only** | `mov cs, ax` is not encodable. Direct far `jmp ptr16:32` is not encodable in 64-bit mode. Use `lretq` |

---

## 5. Writing the code

### `kernel/arch/x86_64/cpu/gdt.hpp`

The hardware layouts, the selector constants, the `constexpr` encoder, and the two-function
API. Arch-private: it lives next to its `.cpp` under `kernel/arch/x86_64/`, not in
`kernel/include/`, because nothing outside the arch layer should know what a descriptor is.
The types are in the header rather than the `.cpp` so the host-side Tier-1 test in §6.4 can
reach the encoder.

```cpp
// kernel/arch/x86_64/cpu/gdt.hpp
//
// The 64-bit Global Descriptor Table. In long mode segmentation is
// essentially disabled -- base and limit are ignored for CS/DS/ES/SS -- so a
// descriptor here carries privilege, type and a few mode flags and nothing
// else. The table still exists because the CPU requires valid selectors, CPL
// lives in CS, syscall/sysret derive selectors by fixed offsets from
// IA32_STAR, and the TSS descriptor has to live somewhere. See Stage 2.1.

#pragma once

#include <stddef.h>
#include <stdint.h>

namespace arch {

// ---------------------------------------------------------------------------
// Hardware layout: one 8-byte segment descriptor.
// Intel SDM Vol. 3A, "Segment Descriptors". Field names match the first six
// fields of Stage 2.2's TssDescriptor, which is this layout plus 8 bytes.
// ---------------------------------------------------------------------------
struct GdtEntry {
    uint16_t limit_low;    // limit[15:0]
    uint16_t base_low;     // base[15:0]
    uint8_t  base_mid;     // base[23:16]
    uint8_t  access;       // P | DPL | S | E | DC | RW | A
    uint8_t  granularity;  // G | D/B | L | AVL | limit[19:16]
    uint8_t  base_high;    // base[31:24]
} __attribute__((packed));

static_assert(sizeof(GdtEntry) == 8, "a segment descriptor is exactly 8 bytes");

// ---------------------------------------------------------------------------
// The operand lgdt reads. TEN bytes in long mode: a 16-bit limit and a
// 64-BIT base. A 32-bit base is a 32-bit-tutorial bug -- it truncates a
// higher-half GDT address and the next segment load faults.
// ---------------------------------------------------------------------------
struct GdtPointer {
    uint16_t limit;   // sizeof(g_gdt) - 1, inclusive
    uint64_t base;    // 64-bit. NOT uint32_t.
} __attribute__((packed));

static_assert(sizeof(GdtPointer) == 10,
              "lgdt reads a 10-byte operand in long mode: 2 + 8");

// ---------------------------------------------------------------------------
// Access-byte and flags constants. Stage 2.1 section 4.2 and 4.3.
// ---------------------------------------------------------------------------
inline constexpr uint8_t GDT_ACCESS_KERNEL_CODE = 0x9A;  // P DPL=0 S E   RW
inline constexpr uint8_t GDT_ACCESS_KERNEL_DATA = 0x92;  // P DPL=0 S     RW
inline constexpr uint8_t GDT_ACCESS_USER_DATA   = 0xF2;  // P DPL=3 S     RW
inline constexpr uint8_t GDT_ACCESS_USER_CODE   = 0xFA;  // P DPL=3 S E   RW

// G=1, D/B=0, L=1, AVL=0. L and D/B are MUTUALLY EXCLUSIVE: both set is an
// invalid descriptor and #GPs when loaded into CS.
inline constexpr uint8_t GDT_FLAGS_LONG_CODE = 0xA0;
// G=1, D/B=1, L=0, AVL=0. L is meaningless in a data descriptor.
inline constexpr uint8_t GDT_FLAGS_DATA      = 0xC0;

// base 0, limit 0xFFFFF with G=1 == 4 GiB. Ignored in 64-bit mode; written
// conventionally so tools decode the table and so 32-bit descriptors added
// later are not the odd ones out. Stage 2.1 section 3.4.
inline constexpr uint32_t GDT_FLAT_LIMIT = 0xFFFFFu;

// ---------------------------------------------------------------------------
// Selectors: byte offsets into the table, index * 8.
//
// USER DATA SITS BELOW USER CODE. `sysretq` loads SS from STAR[63:48] + 8 and
// CS from STAR[63:48] + 16, so the data descriptor must be 8 bytes below the
// code descriptor. There is no value of STAR that makes the reverse order
// work. Stage 2.1 section 3.2 and 4.8.
// ---------------------------------------------------------------------------
inline constexpr uint16_t GDT_SELECTOR_NULL        = 0x00;  // index 0
inline constexpr uint16_t GDT_SELECTOR_KERNEL_CODE = 0x08;  // index 1
inline constexpr uint16_t GDT_SELECTOR_KERNEL_DATA = 0x10;  // index 2
inline constexpr uint16_t GDT_SELECTOR_USER_DATA   = 0x18;  // index 3
inline constexpr uint16_t GDT_SELECTOR_USER_CODE   = 0x20;  // index 4
inline constexpr uint16_t GDT_SELECTOR_TSS         = 0x28;  // index 5 AND 6

// 5 segment descriptors + 2 slots for the one 16-byte TSS descriptor that
// Stage 2.2 installs. Sized now so the lgdt limit already covers it.
inline constexpr size_t GDT_ENTRY_COUNT = 7;

// These are what the ordering decision is really made of. Getting them wrong
// is free today and a Phase 6 rewrite later, so make it a build error.
static_assert(GDT_SELECTOR_KERNEL_DATA == GDT_SELECTOR_KERNEL_CODE + 8,
              "syscall loads SS from STAR[47:32] + 8: kernel data must sit "
              "8 bytes above kernel code");
static_assert(GDT_SELECTOR_USER_CODE == GDT_SELECTOR_USER_DATA + 8,
              "sysretq loads SS from STAR[63:48] + 8 and CS from +16: user "
              "data must sit 8 bytes BELOW user code");
static_assert(GDT_SELECTOR_TSS / 8 + 2 <= GDT_ENTRY_COUNT,
              "the TSS descriptor needs two consecutive free GDT slots");

// ---------------------------------------------------------------------------
// Encode one descriptor. constexpr so the whole table is a constant
// initialiser -- no global constructor (ADR-0007 bans them and nothing would
// run one), and the finished bytes are in kernel.elf for objdump to check.
// ---------------------------------------------------------------------------
constexpr GdtEntry gdt_encode(uint32_t base, uint32_t limit,
                              uint8_t access, uint8_t flags) {
    return GdtEntry{
        .limit_low   = static_cast<uint16_t>(limit & 0xFFFFu),
        .base_low    = static_cast<uint16_t>(base & 0xFFFFu),
        .base_mid    = static_cast<uint8_t>((base >> 16) & 0xFFu),
        .access      = access,
        .granularity = static_cast<uint8_t>((flags & 0xF0u) |
                                            ((limit >> 16) & 0x0Fu)),
        .base_high   = static_cast<uint8_t>((base >> 24) & 0xFFu),
    };
}

// Load our GDT and reload every segment register onto it. Call once, first
// thing in Phase 2, before tss_init(). Stage 2.2 adds gdt_install_tss() here.
void gdt_init();

}  // namespace arch
```

#### Line by line

**The includes**

```cpp
#include <stddef.h>
#include <stdint.h>
```

`<stdint.h>` and `<stddef.h>`, never `<cstdint>` and `<cstddef>`. The C++ headers are part
of libstdc++, which this kernel does not link and which `-nostdinc++` removes from the
include path entirely. The C headers come from GCC itself as part of the freestanding
environment ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]). `<stddef.h>`
supplies `size_t` for `GDT_ENTRY_COUNT`.

**`struct GdtEntry`**

```cpp
struct GdtEntry {
    uint16_t limit_low;
    uint16_t base_low;
    uint8_t  base_mid;
    uint8_t  access;
    uint8_t  granularity;
    uint8_t  base_high;
} __attribute__((packed));
```

Six fields in the order §4.1 gives them. Transcribe from the table; there is no pattern to
reconstruct from memory.

Two honest words about `packed` here. With *this* field order — 2, 2, 1, 1, 1, 1 — every
member is already naturally aligned and `sizeof` is already 8, so `packed` changes nothing
today. Keep it anyway, and keep the `static_assert` next to it, because both exist to catch
a *future* edit: widen `granularity` to `uint16_t` for "clarity", or reorder two fields, and
without them you get a silently 10- or 12-byte descriptor. The CPU indexes the table by
multiplying the selector index by 8; a 12-byte entry means index 2 reads bytes 24–31, which
straddle two descriptors and decode as garbage. Where `packed` genuinely does work in this
file is `GdtPointer`, below.

`__attribute__((packed))` after the closing brace is the form that works everywhere;
`[[gnu::packed]]` on the class head is equivalent under GCC if your
[[13 - Coding Standards]] prefer C++ attribute syntax. Stage 2.2 uses the same form for
`Tss` and `TssDescriptor`.

**`struct GdtPointer` and its assert**

```cpp
struct GdtPointer {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

static_assert(sizeof(GdtPointer) == 10, "lgdt reads a 10-byte operand in long mode: 2 + 8");
```

Here `packed` is doing real work. `uint16_t` followed by `uint64_t` naturally aligns to
offset 8, giving 6 bytes of padding and `sizeof` 16. `lgdt` reads exactly ten bytes from the
address you give it: limit from offset 0 (which would still be correct) and base from
offsets 2–9, which under padding is six zero bytes followed by the low two bytes of the real
base. The GDTR ends up pointing at an address like `0x0000000000005000`. Nothing faults at
`lgdt` itself; the next `mov %ax, %ds` reads a descriptor from unmapped memory and the
machine resets.

The `static_assert` is the whole defence, and it is also the defence against declaring
`base` as `uint32_t` — the 32-bit-tutorial bug from §4.7 — because that yields `sizeof` 6.
Two different mistakes, one build error.

**The access and flags constants**

```cpp
inline constexpr uint8_t GDT_ACCESS_KERNEL_CODE = 0x9A;
inline constexpr uint8_t GDT_ACCESS_KERNEL_DATA = 0x92;
inline constexpr uint8_t GDT_ACCESS_USER_DATA   = 0xF2;
inline constexpr uint8_t GDT_ACCESS_USER_CODE   = 0xFA;
inline constexpr uint8_t GDT_FLAGS_LONG_CODE = 0xA0;
inline constexpr uint8_t GDT_FLAGS_DATA      = 0xC0;
```

`inline constexpr` at namespace scope (C++17) gives one shared object across every
translation unit with no definition in a `.cpp`, and `constexpr` makes them usable inside
`gdt_encode()` in a constant expression. Not macros — a macro has no type, ignores
namespaces, and would not appear in a debugger.

The two flags constants differ in exactly the two bits §3.4 warns about: `0xA0` is
`G=1 D=0 L=1`, `0xC0` is `G=1 D=1 L=0`. Copying one into the other's descriptor is the
"invalid descriptor" trap in §7. Naming them rather than writing `0xA0` inline is what makes
that mistake visible at the call site: `GDT_FLAGS_DATA` next to `GDT_ACCESS_USER_CODE` reads
as obviously wrong.

Only the low nibble of the *access* byte is left to the encoder — the `A` bit is 0 in all
four constants, and the CPU will set it. If Phase 4 ever maps the GDT read-only, change
these to `0x9B`, `0x93`, `0xF3`, `0xFB` and nothing else changes.

**The selector constants**

```cpp
inline constexpr uint16_t GDT_SELECTOR_KERNEL_CODE = 0x08;  // index 1
inline constexpr uint16_t GDT_SELECTOR_KERNEL_DATA = 0x10;  // index 2
inline constexpr uint16_t GDT_SELECTOR_USER_DATA   = 0x18;  // index 3
inline constexpr uint16_t GDT_SELECTOR_USER_CODE   = 0x20;  // index 4
inline constexpr uint16_t GDT_SELECTOR_TSS         = 0x28;  // index 5 AND 6
```

Byte offsets, not indices — the trap the old note flagged and which is still the most common
five-minute confusion here. These are exactly the values
[[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] declares, so the two files agree by
construction rather than by luck.

`GDT_SELECTOR_TSS` is declared here, in Stage 2.1, even though nothing uses it until Stage
2.2. It is what fixes `GDT_ENTRY_COUNT` at 7 and therefore the `lgdt` limit at 55, and doing
it now means Stage 2.2 does not have to change the limit — which is one of the ways `ltr`
fails with `#GP` (Stage 2.2 §7).

**The three `static_assert`s on ordering**

```cpp
static_assert(GDT_SELECTOR_KERNEL_DATA == GDT_SELECTOR_KERNEL_CODE + 8, ...);
static_assert(GDT_SELECTOR_USER_CODE == GDT_SELECTOR_USER_DATA + 8, ...);
static_assert(GDT_SELECTOR_TSS / 8 + 2 <= GDT_ENTRY_COUNT, ...);
```

**The second one is the most valuable line in this stage.** §3.2 explains why the ordering
matters and why the failure lands in Phase 6; this converts that from a comment nobody reads
into a build error nobody can ignore. Swap the two user selectors and the kernel does not
compile, with a message that says exactly what is wrong. The alternative is discovering it
the day `sysret` first executes.

The first pins the kernel side of the same rule (`syscall` takes `SS` from `+8`). The third
is copied from Stage 2.2 and guarantees the table is big enough for a 16-byte descriptor at
index 5.

All three are checks on compile-time constants, so they cost nothing and can never be
"temporarily disabled" without the compiler noticing.

**`gdt_encode()`**

```cpp
constexpr GdtEntry gdt_encode(uint32_t base, uint32_t limit,
                              uint8_t access, uint8_t flags) {
```

`constexpr`, which is decision 3.3 made concrete: called with constant arguments it is
evaluated by the compiler and the array below gets a constant initialiser. It is also a
plain function, so the host-side Tier-1 test in §6.4 can call it with the golden values.

```cpp
        .limit_low   = static_cast<uint16_t>(limit & 0xFFFFu),
        .base_low    = static_cast<uint16_t>(base & 0xFFFFu),
        .base_mid    = static_cast<uint8_t>((base >> 16) & 0xFFu),
```

Straight transcription of §4.1. Every `static_cast` is required, not cosmetic: `limit &
0xFFFFu` has type `unsigned int`, and narrowing conversions in a braced initialiser are
**ill-formed**, so without the casts this does not compile. That is the compiler doing you a
favour — it forces you to state, per field, how many bits you meant.

```cpp
        .granularity = static_cast<uint8_t>((flags & 0xF0u) |
                                            ((limit >> 16) & 0x0Fu)),
```

The one composite field. `flags & 0xF0` keeps only the high nibble — so passing a flags
constant that accidentally has bits set in the low nibble cannot corrupt the limit — and
`(limit >> 16) & 0x0F` supplies `limit[19:16]`. With `flags = 0xA0` and `limit = 0xFFFFF`
this is `0xA0 | 0x0F = 0xAF`, which is the golden value in §4.5. Drop the `& 0xF0` and a
sloppy flags constant silently changes the segment length; drop the `& 0x0F` and a limit
above 20 bits spills into the L and D/B bits, producing the invalid-descriptor `#GP` from
§7.

```cpp
        .base_high   = static_cast<uint8_t>((base >> 24) & 0xFFu),
```

`base` is a `uint32_t`, so a 64-bit base cannot be passed here at all. That is deliberate:
an 8-byte descriptor has no room for one, and the 16-byte system descriptor that does is
Stage 2.2's `gdt_install_tss`. Typing the parameter as `uint32_t` means the mistake is a
compile error rather than a silent truncation.

Designated initialisers (`.field = value`) are C++20 and must appear in declaration order,
which they do. They also mean every field is named at the point it is set, so a
transposition between `access` and `granularity` — two adjacent `uint8_t`s, the classic
positional-initialiser bug — is impossible.

**The API**

```cpp
void gdt_init();
```

One function. No exported table, no exported GDTR: `g_gdt` and `g_gdtr` stay in an anonymous
namespace in the `.cpp` so no caller can reach in and edit a descriptor. Stage 2.2 adds
`gdt_install_tss()` alongside it, and because that function also lives in `gdt.cpp` it can
still see `g_gdt`.

---

### `kernel/arch/x86_64/cpu/gdt.cpp`

Owns the table and the GDTR, and performs the one-time load and reload.

```cpp
// kernel/arch/x86_64/cpu/gdt.cpp
//
// Stage 2.1. Builds the 64-bit GDT at compile time, loads it with lgdt, and
// reloads every segment register so the CPU stops using the descriptors
// Limine cached. After this runs, CS/SS name our descriptors and slots 5-6
// are reserved for Stage 2.2's TSS descriptor.

#include "gdt.hpp"

#include <stddef.h>
#include <stdint.h>

#include <kernel/log.hpp>
#include <kernel/panic.hpp>

namespace arch {
namespace {

// ---------------------------------------------------------------------------
// The table. The initialiser is a constant expression, so GCC emits finished
// bytes and nothing into .init_array -- which matters because this kernel has
// no global-constructor runner (ADR-0007). Not `const`, because Stage 2.2
// writes the TSS descriptor into slots 5 and 6.
//
// Base and limit are ignored in 64-bit mode. They are written conventionally
// anyway: see Stage 2.1 section 3.4.
// ---------------------------------------------------------------------------
alignas(16) GdtEntry g_gdt[GDT_ENTRY_COUNT] = {
    // idx 0, sel 0x00 -- null. Must be all zeros and must be first.
    gdt_encode(0, 0, 0, 0),
    // idx 1, sel 0x08 -- kernel code, ring 0, 64-bit (L=1, D=0)
    gdt_encode(0, GDT_FLAT_LIMIT, GDT_ACCESS_KERNEL_CODE, GDT_FLAGS_LONG_CODE),
    // idx 2, sel 0x10 -- kernel data, ring 0
    gdt_encode(0, GDT_FLAT_LIMIT, GDT_ACCESS_KERNEL_DATA, GDT_FLAGS_DATA),
    // idx 3, sel 0x18 -- USER DATA. Must precede user code: sysretq takes
    //                    SS from STAR[63:48]+8 and CS from +16.
    gdt_encode(0, GDT_FLAT_LIMIT, GDT_ACCESS_USER_DATA, GDT_FLAGS_DATA),
    // idx 4, sel 0x20 -- user code, ring 3, 64-bit
    gdt_encode(0, GDT_FLAT_LIMIT, GDT_ACCESS_USER_CODE, GDT_FLAGS_LONG_CODE),
    // idx 5-6, sel 0x28 -- reserved for Stage 2.2's 16-byte TSS descriptor.
    GdtEntry{},
    GdtEntry{},
};

static_assert(sizeof(g_gdt) == GDT_ENTRY_COUNT * sizeof(GdtEntry),
              "no padding between descriptors -- the CPU indexes by index * 8");
static_assert(sizeof(g_gdt) - 1 == 55, "7 entries: the lgdt limit is 55 (0x37)");

// The lgdt operand. Filled at runtime because &g_gdt is not a constant
// expression -- reinterpret_cast is not allowed in one.
GdtPointer g_gdtr;

}  // namespace

void gdt_init() {
    // 1. Build the GDTR. The limit is INCLUSIVE: size - 1.
    g_gdtr.limit = static_cast<uint16_t>(sizeof(g_gdt) - 1);
    g_gdtr.base  = reinterpret_cast<uint64_t>(&g_gdt[0]);

    // 2. Cheap checks before the CPU is told to trust any of it. The GDT is a
    //    kernel-image object, so its address is in the top 2 GiB; a base whose
    //    upper half is zero means it was truncated somewhere.
    KASSERT(g_gdtr.base != 0);
    KASSERT((g_gdtr.base >> 32) == 0xFFFFFFFFull);
    KASSERT((g_gdtr.base & 0x7) == 0);

    // 3. Load the table, then move every segment register onto it.
    //    lgdt alone changes nothing the CPU is using: each segment register
    //    still runs on the descriptor Limine cached in its hidden half.
    asm volatile(
        "lgdt %[gdtr]                \n\t"
        // Data segments take a plain mov.
        "movw %[data], %%ax          \n\t"
        "movw %%ax, %%ds             \n\t"
        "movw %%ax, %%es             \n\t"
        "movw %%ax, %%fs             \n\t"
        "movw %%ax, %%gs             \n\t"
        "movw %%ax, %%ss             \n\t"
        // CS cannot: `mov cs, ax` is not an instruction, and a direct far
        // jump with an immediate is not encodable in 64-bit mode. Fabricate
        // a far return instead: push CS, push the return address, lretq.
        "pushq %[code]               \n\t"
        "leaq  1f(%%rip), %%rax      \n\t"
        "pushq %%rax                 \n\t"
        "lretq                       \n"   // NOT `lret` -- that is 32-bit
        "1:                          \n\t"
        :
        : [gdtr] "m"(g_gdtr),
          [data] "i"(GDT_SELECTOR_KERNEL_DATA),
          [code] "i"(GDT_SELECTOR_KERNEL_CODE)
        : "rax", "memory");

    LOG_INFO("gdt: loaded, %u entries, limit %u",
             static_cast<unsigned>(GDT_ENTRY_COUNT),
             static_cast<unsigned>(g_gdtr.limit));

    // 4. Read the CPU's own state back and print it. This is the cheapest
    //    proof that the reload did what you think: sgdt returns what lgdt
    //    stored, and CS/SS are the registers that would have faulted.
    GdtPointer readback{};
    uint16_t cs = 0;
    uint16_t ss = 0;
    asm volatile("sgdt %0" : "=m"(readback));
    asm volatile("movw %%cs, %0" : "=rm"(cs));
    asm volatile("movw %%ss, %0" : "=rm"(ss));

    KASSERT(readback.base == g_gdtr.base);
    KASSERT(readback.limit == g_gdtr.limit);
    KASSERT(cs == GDT_SELECTOR_KERNEL_CODE);
    KASSERT(ss == GDT_SELECTOR_KERNEL_DATA);

    LOG_INFO("gdt: GDTR base=%p limit=%u  cs=0x%04x ss=0x%04x",
             reinterpret_cast<void*>(readback.base),
             static_cast<unsigned>(readback.limit),
             cs, ss);
}

}  // namespace arch
```

#### Line by line

**Includes**

```cpp
#include "gdt.hpp"

#include <stddef.h>
#include <stdint.h>

#include <kernel/log.hpp>
#include <kernel/panic.hpp>
```

Its own header first, so the header is proven self-contained — if `gdt.hpp` forgot an
include, this is where it fails. `<kernel/log.hpp>` supplies `LOG_INFO`
([[Stage 1.5 - The Log Ring Buffer and Levels]]) and `<kernel/panic.hpp>` supplies `KASSERT`
([[Stage 0.7 - Panic and KASSERT]]); both live in `kernel/include/` so they use angle
brackets, exactly as Stage 2.2 does.

**The table**

```cpp
alignas(16) GdtEntry g_gdt[GDT_ENTRY_COUNT] = {
    gdt_encode(0, 0, 0, 0),
    gdt_encode(0, GDT_FLAT_LIMIT, GDT_ACCESS_KERNEL_CODE, GDT_FLAGS_LONG_CODE),
    ...
```

Every initialiser is a call to a `constexpr` function with constant arguments, so the whole
thing is a **constant initialiser**. GCC evaluates `gdt_encode` at compile time, writes the
56 finished bytes into the object file, and emits **nothing** into `.init_array`. §6.1 reads
those bytes back with `objdump` and compares them against §4.5 — a check that runs in a
second and needs no emulator.

This is the ADR-0007 payoff. Had the table been built by a constructor, the constructor
would never run — there is no code in this kernel that walks `.init_array` — and `lgdt`
would install 56 zero bytes. Every descriptor would have `P = 0`, and the first segment load
would raise `#NP`, and with no IDT that is a triple fault with no output.

The array is **not** `const`, so it lands in `.data` rather than `.rodata`. That is forced
by Stage 2.2: `gdt_install_tss()` writes 16 bytes into slots 5 and 6, and the TSS base is not
a constant expression. §3.3 covers what you give up and how Phase 4 can get it back.

`alignas(16)` is not architecturally required — Intel recommends the GDT base be 8-byte
aligned — but it is free, it keeps Stage 2.2's 16-byte TSS descriptor naturally aligned so
its `__builtin_memcpy` compiles to two aligned stores, and it makes the `objdump` output in
§6.1 start on a round address.

**Slots 5 and 6**

```cpp
    GdtEntry{},
    GdtEntry{},
```

Value-initialised, so all zeros: `P = 0`, not present. That is the right placeholder. If
some code loaded selector `0x28` before Stage 2.2 fills it, it would fault cleanly rather
than using a stale descriptor. Reserving them **now** is what fixes `GDT_ENTRY_COUNT` at 7
and the `lgdt` limit at 55, so Stage 2.2 never has to touch the limit — and "the GDT limit
was not grown" is on Stage 2.2's own trap list.

**The `static_assert`s on the table**

```cpp
static_assert(sizeof(g_gdt) == GDT_ENTRY_COUNT * sizeof(GdtEntry), ...);
static_assert(sizeof(g_gdt) - 1 == 55, "7 entries: the lgdt limit is 55 (0x37)");
```

The first proves the array is contiguous 8-byte entries with no padding, which is what makes
"selector = index × 8" true. The second pins the number that appears in `info registers`
and in Stage 2.2's expected log line, so if someone changes `GDT_ENTRY_COUNT` the
documentation and the code cannot drift apart silently — the build stops and you update
both.

**`GdtPointer g_gdtr;`**

At namespace scope rather than as a local in `gdt_init()`. A local would work — `lgdt` reads
the operand immediately and the CPU keeps a copy — but a static object can be found with
`nm` and inspected in the monitor, which is worth more than a stack slot. It has no
initialiser, so it lands in `.bss`.

It cannot be `constexpr` for the reason in the comment: `reinterpret_cast` is not permitted
in a constant expression, so the base has to be taken at runtime. This is the one part of
the table that genuinely must be built at boot, and it is three assignments.

**Step 1 — building the GDTR**

```cpp
    g_gdtr.limit = static_cast<uint16_t>(sizeof(g_gdt) - 1);
    g_gdtr.base  = reinterpret_cast<uint64_t>(&g_gdt[0]);
```

`sizeof(g_gdt) - 1`, never a literal. Segment and table limits on x86 are **inclusive** —
the offset of the last valid byte, not the size. Writing `sizeof(g_gdt)` makes the limit 56,
which means the CPU believes there is a partial eighth descriptor; and writing a literal
`39` left over from a 5-entry table means selector `0x28` exceeds the limit and Stage 2.2's
`ltr` raises `#GP`. Computing it from `sizeof` makes both impossible.

`reinterpret_cast<uint64_t>` because the GDTR field is an integer and the value is a
higher-half address around `0xFFFFFFFF801xxxxx` whose top 32 bits must survive. They do,
because §4.7's field is `uint64_t`.

**Step 2 — the assertions**

```cpp
    KASSERT(g_gdtr.base != 0);
    KASSERT((g_gdtr.base >> 32) == 0xFFFFFFFFull);
    KASSERT((g_gdtr.base & 0x7) == 0);
```

Three checks, placed **before** `lgdt`, so a mistake panics with a file and line number
instead of resetting the machine.

The middle one is the interesting one. The kernel is linked at `0xFFFFFFFF80000000`
([[06 - Architecture Overview]], `-mcmodel=kernel`), so every address in the image has
`0xFFFFFFFF` in its upper half. If that half is zero, the base was truncated somewhere — the
32-bit-base bug from §4.7, or a cast through `uint32_t`. `static_assert(sizeof(GdtPointer)
== 10)` already catches the declared-type version at compile time; this catches the version
where someone truncates the *value*. Belt and braces, for one comparison.

The third checks 8-byte alignment, which Intel recommends for the GDT base and which
`alignas(16)` guarantees — it fires only if someone removes the `alignas`.

`KASSERT` compiles out in release builds, which is fine: these are checks on values derived
from constants, so if they hold once they hold always.

**Step 3 — `lgdt` and the reload, instruction by instruction**

This is the part worth reading slowly. It is one `asm volatile` block because the
instructions must be contiguous — GCC must not be allowed to schedule anything between
loading `SS` and the far return.

```asm
lgdt %[gdtr]
```

Loads the 10-byte operand at `g_gdtr` into the GDTR: the CPU now knows where your table is
and how long it is. It does **not** re-read any segment register. `DS`, `SS` and `CS` are
still running on the descriptors Limine cached in their hidden halves (§2.4), which is why
this instruction alone is not enough and why it also does not fault when the table is wrong.
The fault comes at the next line.

```asm
movw %[data], %%ax
movw %%ax, %%ds
movw %%ax, %%es
movw %%ax, %%fs
movw %%ax, %%gs
movw %%ax, %%ss
```

`%[data]` is `GDT_SELECTOR_KERNEL_DATA` under an `"i"` constraint, so GCC emits the literal
`movw $16, %ax`. Then five stores, each of which makes the CPU read `g_gdt[2]`, validate it
(present, correct type, DPL ≥ CPL), and refill that register's hidden half. **This is where
a broken table actually faults**, and it is the fault the reader will observe as "the
machine dies at `lgdt`".

Five registers, not four: `SS` is included. In 64-bit mode `SS` carries almost no meaning —
its base is 0 and no limit is checked — but it must hold something loadable, and interrupt
delivery pushes it. Loading it here, before the pushes below, means the whole sequence runs
under your own descriptors.

`FS` and `GS` get the kernel data selector too. Loading a selector into `GS` resets `GS.base`
from the descriptor (§2.2), which is harmless now because nothing has set a `GS` base yet;
Phase 6 will write `IA32_GS_BASE` **after** any selector load, never before. Linux instead
loads null (`0`) into `DS` and `ES` in 64-bit kernel mode, since they are unused; either is
correct, and the data selector is easier to recognise in `info registers`.

```asm
pushq %[code]
```

`GDT_SELECTOR_KERNEL_CODE` under `"i"`, so `pushq $8`. In 64-bit mode `push imm` pushes a
full 8 bytes (the immediate is sign-extended), which is exactly the slot width `lretq` will
pop `CS` from.

```asm
leaq 1f(%%rip), %%rax
pushq %%rax
```

`1f` is a **numeric local label**: "the next label `1:` going forward". The address is taken
RIP-relative, so it is correct regardless of where the linker places this code. Then it is
pushed, landing directly below the selector, so the stack now holds `[rsp] = RIP`,
`[rsp+8] = CS` — the layout `lretq` expects.

Two details. **Use a numeric label, not a named one.** If GCC inlines `gdt_init()` into two
places, or clones it, the asm string is emitted twice and a named label becomes a duplicate
symbol at assembly time. Numeric labels may repeat; `1f` binds to the nearest one forward.
**Use `lea`, not `mov`.** `movq $1f, %rax` would also work here because `-mcmodel=kernel`
guarantees the kernel lives in the top 2 GiB where a sign-extended 32-bit immediate reaches
— but it silently breaks under any other code model, while the RIP-relative `lea` is correct
under all of them.

```asm
lretq
1:
```

Far return. It pops `RIP` from `[rsp]`, pops `CS` from `[rsp+8]`, validates the descriptor at
index 1 — present, `S = 1`, executable, `L = 1` with `D = 0`, `DPL` compatible with the
current CPL — and transfers. `RIP`, `CS`, CPL and the instruction mode all change in one
atomic step, which is the entire reason a far transfer is required and why
**`mov cs, ax` is not a valid instruction**: there is no way to express "and also change
`RIP`" in a `mov`.

It must be `lretq`, not `lret`. The default operand size for a far return in 64-bit mode is
32 bits; `lret` would pop a 4-byte `EIP` and a 4-byte `CS` from the wrong offsets and jump
somewhere arbitrary. `lretq` is the GAS mnemonic that emits the REX.W prefix. Under Intel
syntax the equivalent is `retfq`.

The sequence is stack-balanced: two pushes, and `lretq` pops both. `rsp` on the far side of
the block equals `rsp` before it, so GCC's frame is intact. `-mno-red-zone` means there is
nothing live below `rsp` for the pushes to overwrite either, which is one of the reasons
that flag is non-negotiable in kernel code.

```cpp
        : [gdtr] "m"(g_gdtr),
          [data] "i"(GDT_SELECTOR_KERNEL_DATA),
          [code] "i"(GDT_SELECTOR_KERNEL_CODE)
        : "rax", "memory");
```

No outputs. `"m"(g_gdtr)` makes GCC emit a memory reference — in practice
`lgdt g_gdtr(%rip)` — rather than requiring you to hand-write the addressing. `"i"` for the
two selectors gives literal immediates, which is what `movw $imm, %ax` and `pushq $imm`
need; a `"r"` constraint would burn two more registers for no reason.

The clobber list has to be right or GCC will miscompile around this block:

- **`"rax"`** — the block writes `%ax`, so `%rax`. Omit it and GCC may have a live variable
  in `rax` across the asm and get a corrupted value back, which presents as unrelated
  nonsense hundreds of lines later.
- **`"memory"`** — a full compiler barrier. It stops GCC caching or reordering memory
  accesses across the block, which matters because `lgdt` reads `g_gdtr` from memory and
  because the segment state the rest of the kernel depends on changes here.
- **`volatile`** — the block has no outputs, so without it GCC is entitled to delete the
  whole thing as dead code.
- **`"cc"`** is not listed because GCC assumes an implicit condition-code clobber for
  every `asm` on x86; adding it is harmless but redundant.

This is inline assembly, which [[13 - Coding Standards]] permits **only** under
`kernel/arch/`. This file is `kernel/arch/x86_64/cpu/gdt.cpp`, so it is allowed;
`scripts/lint.sh` enforces the rule. That constraint is also why the reload lives here
rather than in a shared header.

**The log line**

```cpp
    LOG_INFO("gdt: loaded, %u entries, limit %u", ...);
```

The format is fixed by [[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] §6.2, which
expects `gdt: loaded, 7 entries, limit 55` immediately before its own `tss:` line. Values are
cast to `unsigned` rather than printed with `%zu`, because the kernel's `kprintf` is a
small implementation and `%zu` support is not something to assume.

That this line prints at all is the primary test — see §6.2.

**Step 4 — reading the CPU back**

```cpp
    GdtPointer readback{};
    uint16_t cs = 0;
    uint16_t ss = 0;
    asm volatile("sgdt %0" : "=m"(readback));
    asm volatile("movw %%cs, %0" : "=rm"(cs));
    asm volatile("movw %%ss, %0" : "=rm"(ss));
```

`sgdt` stores the GDTR into a 10-byte memory operand — the exact inverse of `lgdt`, and the
same struct works for both. Reading `CS` and `SS` is a plain `mov` in the *readable*
direction; `mov %cs, %ax` is legal even though `mov %ax, %cs` is not.

Declaring `cs` and `ss` as `uint16_t` is what makes GCC choose a 16-bit operand for `%0`;
an `int` would give `movw %cs, %eax`, which does not assemble in that form. Each is a
separate `asm volatile` because they are independent and there is nothing to keep contiguous.

```cpp
    KASSERT(readback.base == g_gdtr.base);
    KASSERT(readback.limit == g_gdtr.limit);
    KASSERT(cs == GDT_SELECTOR_KERNEL_CODE);
    KASSERT(ss == GDT_SELECTOR_KERNEL_DATA);
```

Four assertions that turn "it probably worked" into "it demonstrably worked". The `CS` check
is the valuable one: it is the only way, short of the monitor, to prove the far return
actually happened rather than being optimised, mis-assembled, or skipped. If `CS` still holds
Limine's selector, this panics at boot with a message — instead of failing three stages later
on the first `iretq`, which is what §7 describes.

```cpp
    LOG_INFO("gdt: GDTR base=%p limit=%u  cs=0x%04x ss=0x%04x", ...);
```

Print them. §6.1 gets `g_gdt`'s address from `nm`; this line is what you compare it against,
and it is how you satisfy the "print GDTR base/limit and compare against your table" check.
Casting through `void*` for `%p` avoids the `-Wformat` diagnostic that `-Werror` would turn
into a build failure.

---

### `kernel/kernel_init.cpp` — the call

```cpp
    arch::gdt_init();    // Stage 2.1 -- lgdt, reload ds/es/fs/gs/ss and cs
    arch::tss_init();    // Stage 2.2 -- fill the TSS, install descriptor, ltr
    idt_init();          // Stage 2.3
```

First in Phase 2, and the order is fixed by [[06 - Architecture Overview]]'s init table —
step 3 is "GDT + TSS", step 4 is "IDT + exception handlers" — and by two hard dependencies:

- `tss_init()` **after** `gdt_init()`, because `ltr` reads its descriptor out of the GDT the
  GDTR currently points at, and because `gdt_install_tss()` writes into the array
  `gdt_init()` set up.
- `idt_init()` **after** both, because Stage 2.3's gates name a `CS` selector that must
  resolve in *your* table, and assert via `tss_ist()` that the IST slots they name are
  populated.

All three run with interrupts still disabled, exactly as Limine left them, so there is no
window in which a fault could arrive against a half-built table.

(Stage 2.2's snippet writes `gdt_init()` unqualified. Everything in this module is in
`namespace arch`, matching `tss.hpp`, so qualify it — or add a `using` — and be consistent.)

---

## 6. How to verify

### 6.1 What you can check right now — build time

```bash
make                    # inside the container, per [[08 - Build System]]
```

A clean build is a real result. Six `static_assert`s passed: the 8-byte descriptor, the
10-byte `lgdt` operand, the contiguous table, the limit of 55, the two-slot TSS reservation,
and — the one that matters most — **the `sysret` ordering**. That last one is the only
mechanism that will ever tell you the user descriptors are the wrong way round before Phase
6 does.

Confirm the table is where you think and, more importantly, that it is in `.data` and not
`.bss`:

```bash
nm -C build/kernel.elf | grep -i 'g_gdt'
```

Expected — lower-case letters because both are in an anonymous namespace, `d` for the table
(initialised data) and `b` for the GDTR (zero, so `.bss`):

```
ffffffff80115000 d arch::(anonymous namespace)::g_gdt
ffffffff8011a2c0 b arch::(anonymous namespace)::g_gdtr
```

**If `g_gdt` shows as `b`, the initialiser was not constant** and the table is all zeros in
the image. That is decision 3.3's failure mode, and this one letter is how you detect it.

Now read the actual bytes back and compare against §4.5, before ever booting:

```bash
objdump -s -j .data \
    --start-address=0xffffffff80115000 \
    --stop-address=0xffffffff80115038 \
    build/kernel.elf
```

Expected:

```
Contents of section .data:
 ...115000 00000000 00000000 ffff0000 009aaf00  ................
 ...115010 ffff0000 0092cf00 ffff0000 00f2cf00  ................
 ...115020 ffff0000 00faaf00 00000000 00000000  ................
 ...115030 00000000 00000000                    ........
```

Read it against §4.5, one entry per eight bytes:

| Bytes | Entry | Check |
|---|---|---|
| `00000000 00000000` | null | all zeros |
| `ffff0000 009aaf00` | kernel code | access `9a`, gran `af` |
| `ffff0000 0092cf00` | kernel data | access `92`, gran `cf` |
| `ffff0000 00f2cf00` | **user data** | access `f2` — DPL 3, not executable |
| `ffff0000 00faaf00` | **user code** | access `fa`, gran `af` |
| `00000000` ×4 | TSS slots | zero until Stage 2.2 |

The two `f`-prefixed access bytes must appear in that order: `f2` (data) **before** `fa`
(code). If you see `fa` first, that is §3.2's bug and the ordering `static_assert` should
have caught it — check you did not weaken it.

### 6.2 What you can check at boot — the machine survives

```bash
make run
```

Expected on serial:

```
[  0.000] info  gdt: loaded, 7 entries, limit 55
[  0.000] info  gdt: GDTR base=0xffffffff80115000 limit=55  cs=0x0008 ss=0x0010
[  0.000] info  tss: TR=0x0028 ...
```

**Surviving the reload is the test, and it is a stronger test than it looks.** There is no
IDT yet, so any fault raised while loading a segment register has no handler, which is a
double fault, which also has no handler, which is a triple fault and a reset. There is no
partial credit and no misleading middle ground: a malformed descriptor, a truncated base, a
bad limit, or `L` and `D` both set each produce a reboot loop rather than degraded operation.
If the two lines print, all four are ruled out.

Two things to cross-check by eye:

- `base=` must match the `g_gdt` address from `nm` **including the leading `ffffffff`**. If
  the top eight hex digits are `00000000`, the base was truncated.
- `cs=0x0008` proves the far return executed. Limine's `CS` will not be `0x0008` by
  coincidence; if it reads anything else, the `lretq` did not happen or landed on the wrong
  descriptor. (The `KASSERT` in step 4 should have panicked first.)

### 6.3 What you can check in the monitor

```bash
qemu-system-x86_64 -cdrom build/os.iso -m 512M \
    -serial file:serial.log -monitor stdio \
    -no-reboot -no-shutdown
```

At the `(qemu)` prompt:

```
(qemu) info registers
```

The interesting lines (exact decoration text varies with QEMU version; the values do not):

```
CS =0008 0000000000000000 ffffffff 00af9b00 DPL=0 CS64 [-RA]
SS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
DS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
GDT=     ffffffff80115000 00000037
```

Five things to check, in order of how much they tell you:

- [ ] **`CS =0008`** — your kernel code selector. The far return worked.
- [ ] **`SS =0010`** — your kernel data selector.
- [ ] **`GDT= <base> 00000037`** — `0x37` is 55, which is `7 * 8 - 1`. If it reads
      `00000027` (39) the table is still five entries and Stage 2.2's `ltr` will `#GP`.
      The base must match `nm`, upper half included.
- [ ] **`CS64`** — QEMU decoded `L = 1`. If it says `CS32`, the L bit is clear and you are
      executing 64-bit code through a compatibility-mode descriptor.
- [ ] **The flags read `00af9b00`, not `00af9a00`.** That is not a typo — the CPU set the
      **accessed** bit (§4.2) when you loaded the selector. Seeing `9b` where you wrote `9a`
      is proof the descriptor was actually read, not evidence of corruption.

Dump the raw table too. Take the address from `nm`:

```
(qemu) x/7gx 0xffffffff80115000
ffffffff80115000: 0x0000000000000000 0x00af9b000000ffff
ffffffff80115010: 0x00cf93000000ffff 0x00cff2000000ffff
ffffffff80115020: 0x00affa000000ffff 0x0000000000000000
ffffffff80115030: 0x0000000000000000
```

Seven qwords, matching §4.5 with the accessed bit set on the two descriptors you actually
loaded (indices 1 and 2). The user descriptors keep `f2` and `fa` because nothing has loaded
them yet — they will pick up their accessed bits in Phase 6.

### 6.4 No faults happened

```bash
qemu-system-x86_64 -cdrom build/os.iso -m 512M -serial stdio \
    -d int,cpu_reset -no-reboot -no-shutdown 2> trace.log
```

`trace.log` should contain **no `check_exception` line at all**. Any exception at this point
in boot is fatal — there is no IDT — so a single `check_exception` means you are looking at
the triple-fault cascade and the first line names the vector that started it. `-no-reboot`
keeps the machine dead so the log is the last thing that happened rather than the first
thing of the next boot. [[14 - Debugging Playbook]] covers reading these.

### 6.5 Tier-1 unit test — descriptor encoding

[[Phase 2 - Overview]] names descriptor encoding as an ideal Tier-1 target: pure bit
manipulation with a published correct answer, easy to get subtly wrong. Because
`gdt_encode()` is a `constexpr` free function in the header, the whole encoder is testable on
the host with no QEMU in the loop. Add to `tests/unit/test_gdt.cpp`, per
[[09 - Testing Strategy]]:

```cpp
static uint64_t as_qword(const arch::GdtEntry& e) {
    uint64_t v = 0;
    __builtin_memcpy(&v, &e, sizeof(e));
    return v;
}

TEST(GdtEncode, KernelCodeMatchesGoldenBytes) {
    // Stage 2.1 section 4.5.
    auto e = arch::gdt_encode(0, arch::GDT_FLAT_LIMIT,
                              arch::GDT_ACCESS_KERNEL_CODE,
                              arch::GDT_FLAGS_LONG_CODE);
    EXPECT_EQ(as_qword(e), 0x00AF9A000000FFFFull);
}

TEST(GdtEncode, UserDataMatchesGoldenBytes) {
    auto e = arch::gdt_encode(0, arch::GDT_FLAT_LIMIT,
                              arch::GDT_ACCESS_USER_DATA,
                              arch::GDT_FLAGS_DATA);
    EXPECT_EQ(as_qword(e), 0x00CFF2000000FFFFull);
}

TEST(GdtEncode, SplitsBaseAcrossThreeFields) {
    // Base 0 everywhere in our table, so exercise the split explicitly.
    auto e = arch::gdt_encode(0x12345678, 0xFFFFFu, 0x9A, 0xA0);
    EXPECT_EQ(e.base_low,  0x5678u);
    EXPECT_EQ(e.base_mid,  0x34u);
    EXPECT_EQ(e.base_high, 0x12u);
}

TEST(GdtLayout, SelectorOrderSatisfiesSysret) {
    EXPECT_EQ(arch::GDT_SELECTOR_USER_CODE, arch::GDT_SELECTOR_USER_DATA + 8);
    EXPECT_EQ(arch::GDT_SELECTOR_KERNEL_DATA, arch::GDT_SELECTOR_KERNEL_CODE + 8);
    EXPECT_EQ(sizeof(arch::GdtEntry), 8u);
    EXPECT_EQ(sizeof(arch::GdtPointer), 10u);
}
```

The `memcpy` into a `uint64_t` rather than a cast is deliberate: `GdtEntry` is packed, and
reading it through a `uint64_t*` is a strict-aliasing violation that GCC at `-O2` is entitled
to reorder. Stage 2.2 uses the same pattern for the same reason.

The third test is the one that earns its place. Every descriptor in this stage has base 0, so
a bug in the base splitting is invisible in the table and invisible at boot — right up until
Stage 2.2 encodes a real base into a real descriptor. Testing it here, where the answer is
trivially checkable, is a second of work against a triple-fault bisect.

### 6.6 What can only be checked later

| Check | Stage |
|---|---|
| The TSS descriptor loads (`ltr` survives, `TR =0028`) | [[Stage 2.2 - The TSS and Interrupt Stacks\|Stage 2.2]] |
| IDT gates resolve their `CS` selector against your table | [[Stage 2.3 - The Interrupt Descriptor Table\|Stage 2.3]] |
| `iretq` returns cleanly through your `CS`/`SS` | Stage 2.4 |
| **The `sysret` ordering is actually right** | [[Phase 6 - Overview\|Phase 6]] |

The last one is the point of §3.2 and the reason the ordering is pinned by a
`static_assert` rather than by a comment: it is the only decision in this stage whose
correctness cannot be observed for another four phases.

### 6.7 Checklist

- [ ] `make` succeeds — all six `static_assert`s pass
- [ ] `nm -C build/kernel.elf | grep g_gdt` shows `g_gdt` as **`d`**, not `b`
- [ ] `objdump -s -j .data` shows the five golden qwords from §4.5, with `f2` before `fa`
- [ ] The kernel survives the reload and prints both `gdt:` lines
- [ ] The logged GDTR base matches `nm`, upper half `ffffffff` included
- [ ] `info registers` shows `CS =0008`, `SS =0010`, `CS64`
- [ ] `GDT=` shows your base and limit `00000037`
- [ ] `x/7gx` matches §4.5, with the accessed bit set on indices 1 and 2
- [ ] `-d int` produces no `check_exception` line
- [ ] Tier-1 tests `GdtEncode.*` and `GdtLayout.SelectorOrderSatisfiesSysret` pass on the host

---

## 7. Common traps

**Symptom: the machine triple-faults the instant `lgdt` executes — a reboot loop, and the
`gdt: loaded` line never prints.**

Strictly, `lgdt` itself almost never faults; it just stores ten bytes into a register. What
faults is the very next instruction that loads a segment register against a table the CPU
cannot read, which is the `movw %ax, %ds` three lines later — close enough that you will
observe it as "it dies at `lgdt`". Under `-d int` you will see a single exception with `IP`
inside `gdt_init`. Causes, in descending order of likelihood:

- **The limit is `sizeof(g_gdt)` instead of `sizeof(g_gdt) - 1`.** Table limits are
  *inclusive*. Compute it, never write a literal — a literal `39` left from a 5-entry table
  is the same bug with a later blast radius (Stage 2.2's `ltr` gets `#GP`).
- **`GdtPointer` lacks `packed`.** `uint16_t` then `uint64_t` becomes 16 bytes with six
  padding bytes in the middle; `lgdt` reads the correct limit and a base assembled from
  padding. `static_assert(sizeof(GdtPointer) == 10)` is the fix.
- **`GdtPointer::base` is a `uint32_t`** — the 32-bit-tutorial bug. `0xFFFFFFFF80115000`
  truncates to `0x80115000`, which is unmapped user space. The same `static_assert` catches
  it, because `sizeof` becomes 6.
- **The table was built by a global constructor** and therefore never ran, so every
  descriptor is zero and `P = 0`. Check for `d` versus `b` in `nm` output (§6.1).

**Symptom: the reload asm runs and the machine dies exactly on the far return.**

`lretq` validates the descriptor at index 1 before transferring, and it is the first
instruction to do so. Causes:

- **`lret` instead of `lretq`.** The default operand size for a far return in 64-bit mode is
  32 bits. Without REX.W the CPU pops four bytes of `EIP` and four bytes of `CS` from the
  wrong offsets and jumps into hyperspace.
- **The pushes are in the wrong order.** `lretq` takes `RIP` from `[rsp]` and `CS` from
  `[rsp+8]`, so the **selector is pushed first** and the address second.
- **The pushed selector is an index, not an offset.** `pushq $1` instead of `pushq $8` —
  the old note's third trap, still the most common five-minute confusion.
- **`L` and `D/B` both set in the code descriptor's granularity byte.** See the dedicated
  trap below.

**Symptom: `gdt_init()` returns and prints happily, everything works, and then the first
interrupt in Stage 2.3 faults — or Phase 6's first `iretq` does.**

You skipped the `CS` reload. You will read in 32-bit tutorials that omitting the far jump
faults immediately. **It does not, and that is what makes it dangerous.** `CS`'s hidden
descriptor cache still holds Limine's code descriptor, and the CPU keeps using the cache; it
does not re-read anything until something *reloads* `CS`. So execution continues normally,
your log line prints, and the stale selector value sits in `CS` until the first `iretq`,
`sysret`, or interrupt return validates it — against *your* table, where that index may be
your TSS slot, a not-present entry, or past the limit. The failure lands one to four stages
downstream and gets attributed to the IDT.

The `KASSERT(cs == GDT_SELECTOR_KERNEL_CODE)` in step 4 exists solely to convert this into a
named boot-time panic. Keep it.

**Symptom: everything works, every test in §6 passes, and then Phase 6 cannot enter ring 3 —
`sysret` returns to a `#GP`, or user code executes with kernel privileges.**

The descriptor order is wrong for `sysret`. `sysretq` takes `SS` from `STAR[63:48] + 8` and
`CS` from `STAR[63:48] + 16`, so **user data must sit 8 bytes below user code**. Reverse
them and there is no value of `STAR` that makes both selectors land on the right
descriptors — the two constraints give `b = 0x08` and `b = 0x18` simultaneously (§3.2).

There is no symptom before Phase 6. Nothing you can run in Phase 2 detects it. That is
precisely why it is pinned by a build-time assertion:

```cpp
static_assert(GDT_SELECTOR_USER_CODE == GDT_SELECTOR_USER_DATA + 8,
              "sysretq loads SS from STAR[63:48] + 8 and CS from +16: user "
              "data must sit 8 bytes BELOW user code");
```

**The previous version of this note had the order backwards** — it listed "user code, user
data" and deferred both to Phase 6. If you built from that version, fix it now while the only
cost is retyping two lines. Fixing it in Phase 6 means renumbering every selector constant,
all 256 IDT gates' selector fields, every `iretq` frame in Stage 2.4's stubs, and any
assembly with a literal `0x18` or `0x20` in it.

**Symptom: random corruption — the GDT looks right in the source but `x/7gx` shows garbage
in the middle entries, or `info registers` decodes nonsense.**

A descriptor struct is not the size the CPU assumes. The CPU finds descriptor *n* at
`base + n * 8`, full stop; if your `GdtEntry` is 10 or 12 bytes because the compiler inserted
padding, index 2 reads bytes 24–31, which straddle two of your entries. Index 0 always looks
fine, which makes it worse.

With the field order in §4.1 the compiler happens to need no padding, so `packed` is a no-op
*today* — do not let that talk you out of it. It plus `static_assert(sizeof(GdtEntry) == 8)`
is what makes a future edit — widening a field, reordering two members — a build error rather
than a boot-time mystery. The same pair on `GdtPointer` catches the case where packing
genuinely matters, and Stage 2.2's `TssDescriptor` relies on exactly the same discipline for
16 bytes.

**Symptom: `#GP` on the far return, or QEMU logs `v=0d` with an error code naming your code
selector, and `info registers` shows the descriptor as invalid.**

`L` and `D/B` are both set in the code descriptor. In a code descriptor `L` (bit 5 of the
granularity byte) means "64-bit" and `D/B` (bit 6) means "32-bit default operand size", and
**they are mutually exclusive**: `L = 1` requires `D = 0`. Both set is an architecturally
invalid descriptor, and loading it into `CS` raises `#GP`.

It happens one way, reliably: copying the data descriptor's `0xCF` into the code descriptor,
or starting from a 32-bit tutorial where `0xCF` is correct for both. The right values are
**`0xAF` for 64-bit code** (`G=1 D=0 L=1`) and **`0xCF` for data** (`G=1 D=1 L=0`). Naming
them `GDT_FLAGS_LONG_CODE` and `GDT_FLAGS_DATA` rather than writing hex at the call site is
what makes the mistake visible when you read the table.

The mirror image bites in Stage 2.2: a *system* descriptor must have bits 5 and 6 **both**
zero, so copying `0xAF` into the TSS descriptor's granularity byte is a `#GP` on `ltr`.

**Symptom: the kernel boots fine now, and starts triple-faulting after you finish Phase 3's
physical memory manager.**

You are still on Limine's GDT, or your GDTR points into bootloader memory. Limine's
structures live in memory the map marks bootloader-reclaimable, and the PMM's whole job is to
reclaim it. The first allocation that lands on those pages rewrites your descriptors. This is
§3.1's failure mode, and the fix is this stage — the table must live in `.data` inside
`kernel.elf`, which is memory nothing will ever reclaim.

---

## 8. What this unlocks

[[Stage 2.2 - The TSS and Interrupt Stacks|Stage 2.2]] writes its 16-byte TSS descriptor into
the two slots reserved here and runs `ltr` on selector `0x28` — which works only because the
limit already covers index 6 and because `GdtPointer` already has a 64-bit base, both of which
Stage 2.2's Progress list otherwise asks you to retrofit.
[[Stage 2.3 - The Interrupt Descriptor Table|Stage 2.3]] puts `GDT_SELECTOR_KERNEL_CODE` into
the selector field of all 256 gates, so every interrupt in the rest of the project enters
through descriptor index 1 of this table; Stage 2.4's stubs build `iretq` frames out of the
same selectors. [[Phase 4 - Overview|Phase 4]] can map the table read-only once `ltr` has run,
if you pre-set the accessed bits. [[Phase 6 - Overview|Phase 6]] programs
`IA32_STAR = 0x0013000800000000` and enters ring 3 through the user descriptors — the single
place where the ordering decision in §3.2 finally pays or bills.
[[Phase 12 - Overview|Phase 12]] gives each core its own copy of this table, because each
core's TSS descriptor must hold that core's TSS address.

The failures from getting this stage wrong split cleanly in two, and both are covered by
§6's checks for a reason. The *loud* ones — a bad limit, a truncated base, `L` and `D` both
set — triple-fault on the spot, which is unpleasant but honest. The *quiet* one is the
descriptor order: it produces no symptom whatsoever until Phase 6, at which point twenty other
things are also new and the GDT is the last place anyone looks. That is what the ordering
`static_assert` is for, and it is why the user descriptors are written now rather than
"in Phase 6" as the earlier version of this note suggested.

---

## 9. Reading

- **OSDev — Global Descriptor Table**: <https://wiki.osdev.org/Global_Descriptor_Table> —
  the bit tables §4.1–§4.3 are drawn from. Read the x86-64 sections and the "System Segment
  Descriptor" part, which Stage 2.2 needs. Its 8-byte descriptor diagram is the one to trust.
- **OSDev — GDT Tutorial**: <https://wiki.osdev.org/GDT_Tutorial> — useful for the reload
  sequence, but **it is largely 32-bit**: it shows a far *jump* and a 32-bit `lgdt` base.
  Read it for the shape, not the values, and cross-check everything against §4.
- **AMD64 Architecture Programmer's Manual Vol. 2**, ch. 4 "Segmented Virtual Memory" and
  §6.1 "SYSCALL and SYSRET": <https://www.amd.com/system/files/TechDocs/24593.pdf> — AMD
  designed long mode and `syscall`/`sysret`. §6.1 is the authoritative statement of the
  `STAR[63:48] + 8` / `+ 16` rule that dictates the descriptor order. If you read one
  primary source for this stage, read that section.
- **Intel SDM Vol. 3A**, §3.4.5 "Segment Descriptors" and §5.2 "Fields and Flags Used for
  Segment-Level and Page-Level Protection", plus §5.8 for the far-transfer rules:
  <https://software.intel.com/en-us/articles/intel-sdm> — ground truth for every bit in §4.2
  and §4.3, and for the statement that base and limit are ignored in 64-bit mode.
- **OSDev — Setting Up Long Mode**: <https://wiki.osdev.org/Setting_Up_Long_Mode> — worth
  skimming for what Limine already did on your behalf, and for why the L bit exists.
- **OSDev — SYSENTER** (which also covers `syscall`): <https://wiki.osdev.org/SYSENTER> —
  the practical view of `IA32_STAR` layout, ahead of Phase 6.
- **Linux `arch/x86/kernel/cpu/common.c`**, the `gdt_page` definition:
  <https://github.com/torvalds/linux/blob/master/arch/x86/kernel/cpu/common.c> — a production
  64-bit GDT, statically initialised exactly as §3.3 argues for. Note the `USER32_CS,
  USER_DS, USER_CS` triple in `arch/x86/include/asm/segment.h` — that is §3.2 option C, and
  seeing it in a real kernel is the fastest way to convince yourself the offset rule is real.
- **The Little OS Book, "Segmentation"**: <https://littleosbook.github.io> — good, short
  prose on *why* segments exist. It is entirely 32-bit: base and limit are enforced there,
  the `lgdt` pointer is 6 bytes, and it reloads `CS` with a far jump. Read it for §2.1's
  history, then discard the mechanics.
- Vault: [[Phase 2 - Overview]] (the 32-bit vs 64-bit difference table — every row is a trap
  in this phase) · [[Stage 2.2 - The TSS and Interrupt Stacks]] (the 16-byte system
  descriptor that goes in slots 5 and 6) · [[06 - Architecture Overview]] (init order, the
  higher-half memory layout, the commitment to `syscall`) ·
  [[ADR-0003 - Limine as the Bootloader]] (what Limine does and does not guarantee) ·
  [[ADR-0007 - Freestanding C++20 as the Kernel Language]] (why there is no global-constructor
  runner) · [[13 - Coding Standards]] (inline asm only under `kernel/arch/`) ·
  [[14 - Debugging Playbook]] (the triple-fault section, `-d int,cpu_reset`) ·
  [[09 - Testing Strategy]] (Tier-1 encoding tests)

Next: **[[Stage 2.2 - The TSS and Interrupt Stacks]]**

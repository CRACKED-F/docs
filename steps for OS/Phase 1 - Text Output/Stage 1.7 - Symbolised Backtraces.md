# Stage 1.7 — Symbolised Backtraces

**Difficulty:** Hard · ~90 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `tools/symbolise/symbolise.cpp`, `kernel/lib/ksyms_stub.cpp`, `kernel/include/kernel/symbols.hpp`, `kernel/lib/symbols.cpp`, `scripts/symbolise.sh`, plus changes to `tools/CMakeLists.txt`, `CMakeLists.txt`, `kernel/CMakeLists.txt`, `cmake/KernelFlags.cmake`, `kernel/arch/x86_64/boot/linker.ld` and `kernel/lib/panic.cpp`
**Deliverable:** a panic prints `heap_expand+0x8C` beside every backtrace address instead of `0xFFFFFFFF80104A2C` alone, and `./scripts/symbolise.sh` turns the same log into `heap_expand+0x8C   kernel/mm/heap.cpp:214`.

---

## Progress

- [ ] `tools/symbolise/symbolise.cpp` — the host generator: run `nm`, sort, demangle, emit
- [ ] Add `symbolise` to `tools/CMakeLists.txt` and to `BUILD_BYPRODUCTS` in the top-level `CMakeLists.txt`
- [ ] Add `.ksyms` to `linker.ld`: a fifth `PHDRS` entry, `KEEP()`, placed **after `.bss`**
- [ ] `kernel/lib/ksyms_stub.cpp` — the pass-one stand-in that defines an empty table
- [ ] `kernel/include/kernel/symbols.hpp` — `SymbolInfo` and `symbol_lookup`
- [ ] `kernel/lib/symbols.cpp` — the bounds-checked binary search
- [ ] Restructure `kernel/CMakeLists.txt`: one `kernel_objs` object library, two links
- [ ] Add `-g` to `KERNEL_CXX_FLAGS` so the offline half works in every build type
- [ ] Update `print_backtrace` in `kernel/lib/panic.cpp` — name every frame, and use it as a sanity check
- [ ] `scripts/symbolise.sh` — the offline `file:line` pass
- [ ] `make` runs both links; `build/kernel/generated/ksyms.cpp` exists and is readable
- [ ] `.text` symbol addresses are **identical** in `kernel.stage1.elf` and `kernel.elf`
- [ ] A test panic names every frame with a plausible offset
- [ ] Add a new function, rebuild, confirm the addresses are still right
- [ ] Committed with a message like `feat(lib): symbolised backtraces`

---

## 1. Why this stage exists

[[Stage 0.7 - Panic and KASSERT]] gave you a backtrace. It looks like this:

```
Backtrace:
  #0  0xFFFFFFFF80104A2C
  #1  0xFFFFFFFF80103118
  #2  0xFFFFFFFF801002F1
```

Every one of those numbers is correct and none of them is *information*. To turn one into a
fact you switch to a terminal, find the `kernel.elf` that produced that exact boot, and run
`x86_64-elf-addr2line`. Three frames, three invocations, and the whole loop only works if
you still have the matching binary. Do that four times an hour for the next fourteen phases
and the arithmetic is brutal.

It gets worse in the three places you most need it. **On real hardware** ([[Phase 15 - Overview|Phase 15]])
the evidence is a photograph of a screen, and there is no host attached to run `addr2line`
against. **In CI** ([[Stage 0.9 - CI From Day One]]) the artefact is a log file in a job that
finished twenty minutes ago; a reviewer reading a failed run sees a column of hex and moves
on. And **when someone else is looking** — your teammate, or you in six months — a raw
address is a request for work rather than a description of a bug.

The fix is to put the answer in the kernel. A symbol table is a sorted array of
`(address, name)` pairs; finding the function that contains an address is a binary search
over it. That is roughly thirty lines of kernel code and it is safe to run in the panic
path, because the table is a statically embedded read-only array: no allocation, no parsing,
no file, no lock, no chance of touching a page that is not mapped.

There is a hard limit to what those thirty lines can do, and being precise about it is most
of this stage. A symbol table can tell you **which function** an address is in. It cannot
tell you **which line**. That needs DWARF line-number information, which is a bytecode
program you have to interpret — a different and much larger job (§2.4). So the design here
is a split: names in the kernel, `file:line` from a one-line host command that reads the
same log. §3 argues that split is not a compromise; it is the right answer.

---

## 2. The concept

### 2.1 What a symbol table is

When the compiler emits an object file it records, for every function and every global
object it defined, a fixed-size record in a section called `.symtab`. The linker merges all
of them into one table in the final ELF. Each record is an `Elf64_Sym`:

| Field | Size | Meaning |
|---|---|---|
| `st_name` | 4 | Byte offset into `.strtab` where the name begins |
| `st_value` | 8 | The symbol's address (after linking, the final virtual address) |
| `st_size` | 8 | Size in bytes — for a function, its length |
| `st_info` | 1 | Type (`FUNC`, `OBJECT`, `NOTYPE`, …) and binding (`GLOBAL`, `LOCAL`, `WEAK`) |
| `st_other` | 1 | Visibility |
| `st_shndx` | 2 | Index of the section it lives in |

That is all a symbol table is: a flat array of records plus a blob of NUL-separated names.
It is part of the **linking view** of the ELF ([[Stage 0.4 - The Linker Script and Higher-Half Layout]] §2),
which means it is *not* in any `PT_LOAD` segment. Limine does not load it. The running
kernel cannot see its own `.symtab` — the bytes are on the ISO, in the file, and nowhere in
memory. This is the whole reason this stage exists: to copy the part of `.symtab` you care
about into a section that *is* loaded.

### 2.2 What `x86_64-elf-nm` gives you

`nm` prints the symbol table as text, one symbol per line, in `value type name` order:

```sh
$ x86_64-elf-nm --defined-only build/kernel.elf | head -6
ffffffff80000000 T kmain
ffffffff80000180 t serial_wait_tx
ffffffff801001c0 T panic
ffffffff80100640 T symbol_lookup
ffffffff80101a00 T kernel_init
ffffffff80210000 B g_capture
```

The middle column is the **type letter**, and it is how you decide what belongs in the
table:

| Letter | Meaning | In the table? |
|---|---|---|
| `T` | Defined in `.text`, global | **yes** |
| `t` | Defined in `.text`, local (a `static` function, or one in an anonymous namespace) | **yes** |
| `W` | Weak, defined, not tagged as a data symbol — in practice a weak function | **yes** |
| `w` | Weak, undefined | no (excluded by `--defined-only`) |
| `D` / `d` | Initialised data (`.data`) | no |
| `B` / `b` | Zero-initialised data (`.bss`) | no |
| `R` / `r` | Read-only data (`.rodata`) | no |
| `A` | Absolute — a value, not an address. Linker-script symbols defined outside a section land here | no |
| `U` | Undefined | no (excluded by `--defined-only`) |

**Only code symbols go in.** Two reasons, both load-bearing. A backtrace contains return
addresses, and a return address is always in `.text`, so data symbols can never be the right
answer. And keeping them out means a bogus address cannot "resolve" to a plausible-looking
global variable and mislead you — the lookup either lands inside a real function or reports
nothing, which is exactly the property §5's frame sanity check depends on.

Note `t`. Static functions are invisible to other translation units but perfectly visible to
`nm`, so they symbolise like anything else. That matters more than it sounds: a lot of kernel
code is `static`, and a backtrace that silently skipped it would be full of holes.

### 2.3 From an address to `name + offset`

The table gives you the *start* of each function. A backtrace gives you an address somewhere
in the middle of one. Bridging the two is one rule:

> **The function containing address `A` is the one with the greatest start address that is
> less than or equal to `A`.**

```
   addresses  ──────────────────────────────────────────────────────────►

   ...80100640        ...801006D0            ...80101A00
        │                  │                      │
        ▼                  ▼                      ▼
   ┌──────────────┐   ┌─────────────────────┐   ┌──────────────┐
   │ symbol_lookup│   │ heap_expand         │   │ kernel_init  │
   └──────────────┘   └─────────────────────┘   └──────────────┘
                              ▲
                              │ A = ...8010075C
                              └── greatest start <= A is heap_expand (...801006D0)
                                  offset = A - 0x801006D0 = 0x8C
                                  answer: heap_expand+0x8C
```

Two things follow immediately, and they are the two things people get wrong.

**The table must be sorted by address.** "Greatest start ≤ A" is only cheap if the array is
ordered; on an unordered array it is a linear scan. Sorting is free — the host tool does it
once at build time — so the kernel gets a **binary search**: about twelve loads for four
thousand symbols, no matter how big the kernel gets. §5 spends most of its length on getting
that search's predicate right, because the classic bug here is an off-by-one that returns
the *previous* function near a boundary, and a backtrace that names the wrong function is
worse than one that names none.

**"Contains" is not proved, only bounded.** The rule finds the last function that *started*
before `A`. If `A` is past the end of that function — in inter-function padding, or off the
end of `.text` entirely — the rule still returns it, with a big offset. So the answer needs
bounding: an address must be inside `.text` at all, and the offset must be small enough to
be a real function. §5 does both.

### 2.4 The precise difference between a name and a `file:line`

This is the distinction that drives every decision in §3, so be exact about it.

**A name comes from the symbol table.** One `Elf64_Sym` record per function, `st_value` is
the address, `st_name` points at a string. Finding the function containing an address is a
binary search over an array you can sort at build time. There is nothing to interpret.

**A `file:line` comes from DWARF line-number information**, in the `.debug_line` section, and
it is a completely different kind of artefact. `.debug_line` is not a table. It is a
**bytecode program** for a state machine whose registers are `(address, file, line, column,
is_stmt, …)`. Opcodes like `DW_LNS_advance_pc` and `DW_LNS_advance_line` step those
registers, and most of the stream is "special opcodes", single bytes that encode both an
address advance and a line advance at once. To answer "what line is address `A` on" you must:

1. Parse `.debug_abbrev` and `.debug_info` far enough to find the compilation unit that
   covers `A`, and read its `DW_AT_stmt_list` — the offset of its line program.
2. Parse the line program header, including the directory and file-name tables, whose format
   **changed incompatibly between DWARF 4 and DWARF 5**.
3. Run the state machine from the start of that program, emitting a row per instruction
   boundary, until you step past `A`.

There is no index to binary-search. The work is proportional to the size of the compilation
unit, and you must implement an opcode interpreter to do any of it. Then there is inlining:
one address can legitimately correspond to *several* source locations at once, because the
compiler inlined three calls into that instruction. DWARF expresses that with
`DW_TAG_inlined_subroutine` entries in `.debug_info` — which is what `addr2line -i` prints —
and a symbol table cannot express it at all.

The size difference is the other half of the story:

| Artefact | Section | Roughly, for a Phase 1 kernel | Loaded at run time? |
|---|---|---|---|
| Names (this stage) | `.ksyms` (ours) | tens of KB | **yes** — that is the point |
| ELF symbol table | `.symtab` + `.strtab` | tens of KB | no — not `SHF_ALLOC` |
| DWARF line numbers | `.debug_line` | hundreds of KB | no |
| Full DWARF | `.debug_*` | megabytes | no |

So: names are a sorted array and a binary search. Lines are a bytecode interpreter over
megabytes of tables. That is not a difference of degree, and it is why the answer in §3 is
"names in the kernel, lines on the host".

### 2.5 The build-time pipeline

Nothing is parsed at run time. A host program reads a linked kernel and writes a `.cpp`;
that `.cpp` is compiled and linked like any other kernel source. Exactly the shape
[[Stage 1.2 - Rasterising a Bitmap Font]] established for the font.

```
   kernel/*.cpp  ────►  kernel_objs        one compile of every TU
                            │
          ┌─────────────────┴──────────────────────┐
          │                                        │
          ▼                                        │
   + kernel/lib/ksyms_stub.cpp                     │
          │                                        │
          ▼                                        │
   build/kernel.stage1.elf                         │
          │   every function address is now FINAL  │
          ▼                                        │
   x86_64-elf-nm --defined-only                    │
          │                                        │
          ▼                                        │
   tools/symbolise      HOST binary, native g++,   │
          │             real libstdc++             │
          │   filter · sort · dedupe · demangle    │
          │   · intern · emit                      │
          ▼                                        │
   build/kernel/generated/ksyms.cpp                │
          │                                        │
          └──────────────────► + ──────────────────┘
                               │
                               ▼
                        build/kernel.elf     ← the only image that ever boots
```

Two links of the **same object files**. That is not an optimisation; it is the correctness
argument. If the two passes recompiled independently they could in principle differ, and the
whole scheme rests on the object code being byte-identical between them.

### 2.6 The chicken and the egg

Here is the problem that makes this stage Hard rather than Medium.

```
   link  ──►  final addresses  ──►  symbol table  ──►  a bigger binary
     ▲                                                        │
     └────────────────  different addresses  ◄────────────────┘
```

You cannot know the addresses until you link. You cannot build the table until you know the
addresses. Adding the table to the binary changes the binary, which changes the addresses,
which invalidates the table you just built.

The failure this produces is the nastiest kind. It does not crash and it does not print
garbage. Every symbol comes out **shifted by the same small constant**, so a lookup lands in
the function *before* the real one — a real function, with a plausible offset, printed with
total confidence. You will read `heap_expand+0x8C` and go and read `heap_expand`, and the bug
is in `heap_free`, two hundred bytes earlier. §3 makes this a decision with a verdict, and
§6 gives you the one command that proves the fix works.

---

## 3. Design decisions and tradeoffs

### Decision: embed a symbol table in the kernel, or symbolise offline with `addr2line`?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — embed names in the kernel, get `file:line` offline (chosen)** | A generated `.ksyms` section holds sorted `(addr, name)`; a host script adds `file:line` from DWARF | Tens of KB of image now, low hundreds later; the build-ordering problem in §2.6 | ✅ |
| B — offline only: print raw addresses, run `addr2line` | Nothing in the kernel changes | Useless without the matching `kernel.elf` and a host to run it on | ❌ |
| C — embed names *and* DWARF line info | A line-program interpreter in the kernel | Hundreds of KB of tables plus a bytecode interpreter, in the panic path | ❌ |

**Why A.** Three properties you get only by putting the names in the image.

*The panic explains itself where it happens.* On real hardware in [[Phase 15 - Overview|Phase 15]]
your evidence is a screen. Nobody is attaching a debugger to it. A named backtrace is
readable off a photograph; a column of hex is not.

*CI logs become reviewable.* [[Stage 0.9 - CI From Day One]] archives serial output from
failed runs. A reviewer opening that log sees `kheap_alloc+0x40` and knows which subsystem
failed. With raw addresses they would need the exact `kernel.elf` from that job — which they
would have to download, if it was archived at all.

*You stop needing the matching binary.* Symbolisation with `addr2line` is only valid against
the *exact* build that produced the address. One rebuild between the crash and the
investigation and every answer is silently wrong. An embedded table cannot get out of sync,
because it ships inside the thing that crashed.

The cost is honest and worth stating in bytes. §4 has the arithmetic; for a Phase 1 kernel
it is around 25–30 KB, and by [[Phase 12 - Overview|Phase 12]] with a few thousand symbols
and long C++ names it will be in the low hundreds of KB. That is a real number. It buys the
single most-used debugging artefact in the project.

**Why not B.** Be fair to it first: B is genuinely free, it gives you full `file:line` with
inline frames, and it is what you have been doing since Stage 0.7. It fails on the three
cases above, and it fails *silently* on the fourth — using a rebuilt binary — which is the
kind of failure that costs a day. Keep it as the second half of A, not as the whole answer.

**Why not C.** The panic path is the one place in the kernel where every added line is a line
that might fault while reporting a fault. A DWARF line-program interpreter is a header
parser, a variable-length-integer decoder, an opcode dispatch loop, and a file-table walk,
run against data structures at the moment kernel state is least trustworthy. Get one bound
wrong in that and you lose the message it existed to enrich — the exact failure
[[Stage 0.7 - Panic and KASSERT]] §7 names as the worst outcome. It also costs hundreds of KB
of image for a section that is not currently loaded at all.

The strongest evidence is what Linux does. `kallsyms` embeds names — and only names — and
Linux does not put line numbers in the panic path either. A project with every resource to
build option C chose option A.

**When B would be right.** When image size is genuinely constrained: a bootloader stage, or
a target with 256 KiB of flash. Also when the kernel is only ever run under a debugger you
control, in which case the table is redundant. **When C would be right.** When you ship an
appliance with no serial port and no screen, must self-describe a fault to a field engineer,
and have already paid for a DWARF parser for some other reason. Nothing here matches either.

---

### Decision: how do you break the chicken-and-egg cycle?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — table in its own section, placed last (chosen)** | Link once with a stub; generate; link again with the real table. `.ksyms` is the final section, so filling it moves nothing before it | A linker-script change, a fifth `PHDRS` entry, and a second link | ✅ |
| B — padded placeholder sized on pass one | Reserve N zero bytes on pass one; pass two writes into the reservation, so nothing moves at all | You must guess N; too small fails the build, too big wastes image; the guess needs re-tuning as the kernel grows | ➖ |
| C — link twice and accept that the table's own symbols may move | Just relink. Data addresses shift; code addresses happen not to | Rests on an accident of layout, and fails silently the day the layout changes | ❌ |

**Why A.** It converts the problem from "manage the drift" into "make drift structurally
impossible". The linker assigns addresses in the order the `SECTIONS` block lists them. If
`.ksyms` is last, then by construction every byte placed before it has already been assigned
its final address before the linker reaches the table, and the table's size cannot influence
any of them. Pass one and pass two produce identical `.text`, `.rodata`, `.data` and `.bss`
addresses, and the only symbols that move are `.ksyms`'s own — which are data symbols that
never appear in a backtrace.

Strictly, the table only has to come after `.text`, because only code addresses appear in a
backtrace. Placing it at the very end is the strongest form of the same guarantee, and it
costs nothing extra. It also keeps `.bss` last inside the `:data` segment, which
[[Stage 0.4 - The Linker Script and Higher-Half Layout]] requires so that `p_memsz > p_filesz`
and the loader zero-fills the tail instead of the linker writing it into the file. That is
why `.ksyms` gets its own `PT_LOAD` rather than being appended to `:data` — appending it
there would put a `PROGBITS` section after `.bss` in the same segment and put megabytes of
zeros back into your ELF.

**Why not B.** It is the classic answer and it does work — it is essentially what Linux's
`scripts/link-vmlinux.sh` does, linking with `kallsyms` two or three times and checking that
the result converged. The cost is a constant you cannot compute from anything: the padding
must be at least as large as a table you have not built yet, whose size depends on names you
have not demangled yet. Guess low and the build fails with an obscure "region overflowed"
message; guess high and you carry the waste in every image. Then someone adds forty functions
in Phase 9 and the guess needs revisiting, at which point the failure is a build error in
somebody else's pull request.

**When B would be right.** When you cannot control the layout — building against a
vendor-supplied linker script, or emitting a firmware image whose section order is fixed by a
loader you did not write. Then last-placement is not available and reservation is the only
lever you have.

**Why not C.** This is the trap, because *it works today*. In our script `.rodata` comes after
`.text`, so a plain `const` array from the generated file lands after every function and no
code address moves. It looks correct. It is correct by accident, and the accident has no
guard: add `-ffunction-sections`, reorder a section, let the generated file emit one function
by mistake, or let `used` pull in something that lands in `.text`, and every symbol shifts by
a constant with no warning anywhere. What you get is §2.6's failure — confident, plausible,
wrong. A is the same two links plus a written-down contract, and §6 adds the check that
enforces it mechanically.

**Getting it wrong looks like this.** Not a crash. Not garbage. Every frame names a real
function that really exists at a real address, off by one function. You debug the wrong code
for an afternoon and conclude the backtrace is unreliable, which is the worst possible
outcome, because from then on you do not trust the one tool that was going to save you time.

---

### Decision: frame-pointer walking or DWARF CFI unwinding — does the answer change now?

[[Stage 0.7 - Panic and KASSERT]] chose frame pointers: twenty auditable lines, two
dereferences per frame, no tables, no parser, no allocation, in the one function that must
never fault. DWARF `.eh_frame` unwinding is the better unwinder — accurate through optimised
frameless code and through hand-written assembly — but it is a CFI bytecode interpreter plus
a register-rule state machine, and `-fno-exceptions` means the toolchain has no unwinder to
borrow ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]). That argument is unchanged.

**What changes now is the failure mode of the frame walk, not the choice.** Until this stage
the walk's only defence was structural: is the frame pointer canonical, aligned, ascending,
and does the return address land between `__text_start` and `__text_end`? Those reject
nonsense but accept any well-formed garbage that happens to point into the text range.

With a symbol table you gain a semantic check for free: **does this return address land
inside a function I know about?** The lookup already computes it. If the answer is no, the
address is in inter-function padding, in a region no symbol covers, or simply not a return
address at all — and the chain has left the rails. One extra `if`, no extra work, and it
turns "print thirty-two plausible lies" into "print what we have and stop". §5 wires it in.

This does not make the walk correct through assembly stubs — Phase 2's interrupt entry points
build no frames, and a backtrace still stops at that boundary until they push a synthetic one.
It makes the walk *honest* about where it stopped being right, which is the property you
actually need.

---

### Decision: table format — inline names, or a packed array plus a string pool?

| Option | How it works | Bytes per symbol | Verdict |
|---|---|---|---|
| **A — two parallel arrays + one string pool (chosen)** | `uint64_t addr[N]`, `uint32_t name_off[N]`, one NUL-separated `char` blob | 12 + name | ✅ |
| B — one struct array + string pool | `struct { uint64_t addr; uint32_t off; }` — padded to 16 by `alignof(uint64_t)` | 16 + name | ➖ |
| C — inline fixed-width names | `struct { uint64_t addr; char name[64]; }` | 72, and names truncate at 63 | ❌ |

Work it out for N = 800 symbols with an average stripped name of 22 characters:

| Option | Table | Pool | Total |
|---|---|---|---|
| A | 800 × 12 = 9.6 KB | 800 × 23 = 18.4 KB | **28.0 KB** |
| B | 800 × 16 = 12.8 KB | 18.4 KB | 31.2 KB |
| C | 800 × 72 = 57.6 KB | — | 57.6 KB |

At Phase 12 scale — say 4000 symbols averaging 28 characters — A is 48 + 116 = 164 KB and C
is 288 KB. C also silently truncates every name longer than 63 characters, which in C++ is
most template instantiations and a fair number of ordinary member functions.

**Why A.** Splitting the struct into two arrays is not stylistic. `alignof(uint64_t)` is 8, so
`{uint64_t; uint32_t;}` is 12 bytes of content in a 16-byte object — 25% of the table is
padding you cannot use. Two arrays have no padding at all, and the binary search touches only
`ksyms_addr[]`, so each probe pulls in eight neighbouring addresses per 64-byte cache line
instead of four.

Be honest about that last point: a panic is not a hot path, so the cache argument is worth
almost nothing here in wall-clock terms. The size argument is the real one, and the third
argument is better than both — separating the arrays means the *search* never reads a name,
so a corrupt string pool cannot affect which symbol you find. It can only affect what is
printed, which is the failure you would rather have.

**Why not C.** It is simpler to generate and it needs no offsets — a genuine advantage if you
are debugging the generator. It costs twice the space at the low end and rises with the
longest name rather than the average one, and truncation makes the two overloads you actually
needed to tell apart print identically.

**When C would be right.** If you had no string pool because the names were fixed-length by
construction — a table of interrupt vector names, say. For symbol names, never.

---

### Decision: what do you do about C++ name mangling?

`nm` prints what is in the ELF, and what is in the ELF for a C++ function is
`_Z11heap_expandm`. The `_Z` prefix, the `11` length, the name, then `m` for the
`unsigned long` parameter — the Itanium C++ ABI encoding. It is unreadable in a panic and it
is unsearchable in your editor.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — demangle in the HOST tool, embed the readable form (chosen)** | `abi::__cxa_demangle` from libstdc++, at build time | One include and ten lines, in a program that already links the standard library | ✅ |
| B — demangle in the kernel | Parse the mangled form at panic time | A real Itanium-ABI demangler: substitution tables, nested-name grammar, and it *allocates* | ❌ |
| C — live with it | Print `_Z11heap_expandm` | Every panic needs a manual `c++filt` step, forever | ❌ |

**Why A.** The tool is a host binary built by the native compiler with the real standard
library ([[Stage 0.8 - The Build System]], "three toolchains, one tree"), so
`abi::__cxa_demangle` is one `#include <cxxabi.h>` away and is the same implementation
`c++filt` and `addr2line -C` use. Doing it at build time also means it is done **once**,
before the strings are interned, so identical names share pool space; and it lets the tool
post-process the result, which §5 uses to strip the parameter list.

**Why not B.** GCC's demangler is `libiberty/cp-demangle.c` — several thousand lines with a
substitution table, a recursive-descent parser over a grammar with dozens of productions, and
`malloc` at its core. Every one of those properties is disqualifying in the panic path: there
is no heap at [[Phase 4 - Overview|Phase 4]] and the heap may be the corrupt thing after it.
You would be running a recursive parser over attacker-shaped input at the moment the kernel
has already admitted it does not understand its own state.

**Why not C.** It is not that `_Z11heap_expandm` is unreadable — with practice you can read
it. It is that you cannot *grep* for it, cannot paste it into a bug report, and the extra
`c++filt` step is exactly the manual round-trip this whole stage exists to remove.

**`extern "C"` symbols are unaffected.** `kmain`, `panic`, `memcpy`, and every linker-script
symbol have no `_Z` prefix, are already readable, and pass through untouched. The tool checks
for the prefix and only calls the demangler when it is present, so a symbol that is not C++
costs nothing and cannot be corrupted by a demangler bug.

**One sub-decision the tool makes.** `_Z11heap_expandm` demangles to `heap_expand(unsigned
long)`, and the parameter list is a third of the string pool. The tool strips it, so the panic
prints `heap_expand+0x8C`. The price is that two overloads now display the same name — which
costs you almost nothing, because the offset differs and one `addr2line` disambiguates them
exactly. If you prefer full signatures, delete one call in §5 and pay the pool.

---

## 4. Specification

### The five embedded symbols

Every one lives in `.ksyms` and is `const`. Nothing in the kernel writes any of them.

| Symbol | Type | Meaning |
|---|---|---|
| `ksyms_count` | `const uint32_t` | Number of entries. **0** in a stage-one link |
| `ksyms_strings_size` | `const uint32_t` | `sizeof(ksyms_strings)` — the bound every name offset is checked against |
| `ksyms_addr[]` | `const uint64_t[]` | Function start addresses, **strictly ascending** |
| `ksyms_name_off[]` | `const uint32_t[]` | Parallel to `ksyms_addr`: byte offset of this symbol's name in the pool |
| `ksyms_strings[]` | `const char[]` | NUL-separated names. The last byte is `'\0'` |

All five are declared inside `extern "C" { … }`. Two reasons: the names must be unmangled so
the kernel's `extern` declarations match, and a declaration directly contained in a
linkage-specification is treated as if it carried `extern`, which is what stops a
namespace-scope `const` from getting internal linkage and vanishing from the link.

### Invariants the kernel relies on, and who guarantees them

| Invariant | Guaranteed by | What the kernel does if it is false |
|---|---|---|
| `ksyms_addr` is sorted ascending | `tools/symbolise` (`std::sort`) | Binary search returns a wrong symbol — undetectable, so the tool must be right |
| No duplicate addresses | `tools/symbolise` (`std::unique`) | Harmless; the search returns one of them |
| Every `ksyms_name_off[i] < ksyms_strings_size` | `tools/symbolise` | **Checked** in `symbol_lookup` — returns "not found" |
| `ksyms_strings` ends in `'\0'` | the string literal's implicit terminator | A name walk could run off the array |
| Every address ≥ `0xFFFFFFFF80000000` | `tools/symbolise` (`--base` filter) | Harmless; those entries are unreachable |

The first is the one you cannot check cheaply at run time, which is why the tool sorts rather
than trusting `nm -n`, and why §6 has a check for it.

### Size arithmetic

```
bytes = 12 * N  +  sum over unique names of (len + 1)  +  8
                                                          ^ the two uint32 scalars
```

| Kernel | N | avg name | Table | Pool | Total |
|---|---|---|---|---|---|
| Phase 1 (this stage) | ~800 | 22 | 9.6 KB | 18.4 KB | ~28 KB |
| Phase 4 | ~1600 | 24 | 19.2 KB | 40 KB | ~59 KB |
| Phase 12 | ~4000 | 28 | 48 KB | 116 KB | ~164 KB |

Names are interned, so the pool holds one copy of each distinct name however many symbols
share it.

### Linker script additions

| Change | Value | Why |
|---|---|---|
| New `PHDRS` entry | `ksyms PT_LOAD FLAGS(4);` | Read-only. `PF_R = 4`, the same encoding the `rodata` segment uses |
| New output section | `.ksyms`, after `__bss_end` | Nothing placed before it can move when it grows (§3) |
| `KEEP(*(.ksyms))` | — | Nothing in the kernel reaches the table through a relocation, so `--gc-sections` would discard it. Same argument as `.limine_requests` in [[Stage 0.4 - The Linker Script and Higher-Half Layout]] |
| `__kernel_end` moves | past `.ksyms` | The table is part of the image and the [[Phase 4 - Overview\|Phase 4]] frame allocator must reserve it |
| `__bss_end` does **not** move | — | `.bss` stays last inside `:data`, preserving `p_memsz > p_filesz` |

After this the image has **five** `PT_LOAD` segments, not four.

### `symbol_lookup` contract

```cpp
struct SymbolInfo {
    const char* name;    // nullptr when nothing resolves
    uintptr_t   base;    // start address of the containing function
    uintptr_t   offset;  // query - base
};

SymbolInfo symbol_lookup(uintptr_t addr);
```

| Guarantee | Why it matters |
|---|---|
| Never allocates | Called from `panic`, where there may be no heap and the heap may be corrupt |
| Never takes a lock | The lock may be the broken thing |
| Never writes memory | Nothing it can corrupt |
| Reads only `.ksyms` and two linker symbols | All statically mapped, read-only, present in every image |
| Bounded: ⌈log₂ N⌉ + 1 iterations | 12 loads at N = 4000. Cannot loop |
| Returns `{nullptr, 0, 0}` rather than guessing | The caller can tell "no answer" from "an answer" |

**Rejection rules**, in the order they are applied:

| Condition | Result |
|---|---|
| `ksyms_count == 0` | not found — a stage-one image, or the table was garbage-collected |
| `addr < __text_start` or `addr >= __text_end` | not found — not kernel code at all |
| `addr < ksyms_addr[0]` | not found — before the first symbol |
| `offset > 0x10000` | not found — 64 KiB past a function start is padding or a gap, not a function |
| `ksyms_name_off[idx] >= ksyms_strings_size` | not found — the table is corrupt; refuse rather than read out of bounds |

### The `-1` rule for return addresses

A backtrace entry is a **return address**: the address of the instruction *after* the `call`.
When the `call` is the last instruction of a function — a tail call, or a call to a
`[[noreturn]]` function like `panic` — the return address is the first byte of the *next*
function, and a naive lookup reports `next_function+0x0`.

So the lookup is done on `ret - 1`, which is guaranteed to land inside the calling
instruction, while the *printed* offset is measured to `ret` itself so it matches what you
paste into `addr2line`. `ret` is always ≥ `__text_start` by the time this runs, so `ret - 1`
cannot underflow. This is the same caveat [[Stage 0.7 - Panic and KASSERT]] §6 raised about
`addr2line`; here it is handled for you.

### Build flags

| Flag | Where | Why |
|---|---|---|
| `-g` | `cmake/KernelFlags.cmake` | Puts DWARF in `kernel.elf` so the offline `file:line` pass works in **every** build type, not only `Debug`. `.debug_*` are not `SHF_ALLOC`, so Limine never loads them and the run-time cost is exactly zero |
| `-fno-omit-frame-pointer` | already set | Without it there is no frame chain to name |

---

## 5. Writing the code

### `tools/symbolise/symbolise.cpp`

The host generator: run `nm`, filter to code symbols, demangle, sort, dedupe, intern the
names into one pool, and emit a C++ source file.

```cpp
// tools/symbolise/symbolise.cpp
//
// Turn the symbol table of a linked kernel ELF into a C++ source file holding a
// sorted, packed, statically initialised address -> name table.
//
// This is a HOST tool. It is built by the NATIVE compiler and links the real
// standard library, so <string>, <vector> and <algorithm> are all fair game.
// Nothing in this file runs on the target.
//
//   usage: symbolise <kernel.elf> <out.cpp> [--nm PROG] [--base HEX]
//
// The output is a pure function of the input ELF: no timestamps, no paths, no
// environment, no locale. Two runs on the same input produce identical bytes.

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>

#include <cxxabi.h>   // abi::__cxa_demangle - libstdc++, host only

namespace {

// Anything below this is not kernel code. See Stage 0.4.
constexpr std::uint64_t DEFAULT_BASE = 0xFFFFFFFF80000000ULL;

// A link that yields fewer than this many code symbols was almost certainly
// stripped. Refuse loudly rather than emit a table that silently does nothing.
constexpr std::size_t MIN_SYMBOLS = 16;

// C++ template names are unbounded; a panic line is 80 columns.
constexpr std::size_t MAX_NAME = 96;

struct Sym {
    std::uint64_t addr;
    bool          global;   // 'T'/'W' rather than 't'/'w'
    std::string   name;     // demangled, parameters stripped, sanitised, clamped
};

[[noreturn]] void die(const std::string& msg) {
    std::fprintf(stderr, "symbolise: %s\n", msg.c_str());
    std::exit(1);
}

// "foo(int)"        -> "foo"
// "Heap::grow(u64)" -> "Heap::grow"
// "operator()(int)" -> "operator()"
// "vtable for Foo"  -> unchanged (not a function signature)
std::string strip_params(const std::string& s) {
    if (s.empty() || s.back() != ')')
        return s;
    int depth = 0;
    for (std::size_t i = s.size(); i-- > 0; ) {
        if (s[i] == ')') {
            ++depth;
        } else if (s[i] == '(') {
            if (--depth == 0)
                return s.substr(0, i);
        }
    }
    return s;                       // unbalanced: leave it alone
}

std::string demangle(const std::string& mangled) {
    if (mangled.rfind("_Z", 0) != 0)
        return mangled;             // extern "C", or an assembler label

    int   status = 0;
    char* raw    = abi::__cxa_demangle(mangled.c_str(), nullptr, nullptr, &status);
    if (raw == nullptr || status != 0) {
        std::free(raw);
        return mangled;             // unparsable: keep the mangled form
    }
    std::string out = strip_params(raw);
    std::free(raw);
    return out;
}

// Force every stored byte to printable ASCII, then clamp the length. Both run
// at INGEST, so the pool bytes and the recorded offsets always agree.
std::string sanitise(std::string s) {
    for (char& c : s) {
        const unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x20 || u > 0x7E)
            c = '?';
    }
    if (s.size() > MAX_NAME)
        s = s.substr(0, MAX_NAME - 3) + "...";
    return s;
}

// The C++ SOURCE spelling of a name. Emit-time only: escaping changes the
// source text, never the byte count, so it must not touch pool offsets.
std::string escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (const char c : s) {
        if (c == '"' || c == '\\')
            out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

std::vector<Sym> read_symbols(const std::string& nm, const std::string& elf,
                              std::uint64_t base) {
    const std::string cmd = nm + " --defined-only \"" + elf + "\"";

    std::FILE* pipe = ::popen(cmd.c_str(), "r");
    if (pipe == nullptr)
        die("cannot start: " + cmd);

    std::vector<Sym> syms;
    char             line[4096];

    while (std::fgets(line, sizeof line, pipe) != nullptr) {
        // "ffffffff801006d0 T heap_expand"
        char* end = nullptr;
        errno     = 0;
        const std::uint64_t addr = std::strtoull(line, &end, 16);
        if (end == line || errno != 0)
            continue;                                   // no address field

        while (*end == ' ' || *end == '\t') ++end;
        const char type = *end;
        if (type != 'T' && type != 't' && type != 'W' && type != 'w')
            continue;                                   // not code

        ++end;
        while (*end == ' ' || *end == '\t') ++end;

        std::string name(end);
        while (!name.empty() && (name.back() == '\n' || name.back() == '\r'))
            name.pop_back();
        if (name.empty() || addr < base)
            continue;

        syms.push_back(Sym{addr, type == 'T' || type == 'W',
                           sanitise(demangle(name))});
    }

    if (::pclose(pipe) != 0)
        die("`" + cmd + "` failed - is " + nm + " on PATH?");

    return syms;
}

}  // namespace

int main(int argc, char** argv) {
    std::string   elf;
    std::string   out;
    std::string   nm   = "x86_64-elf-nm";
    std::uint64_t base = DEFAULT_BASE;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--nm" && i + 1 < argc)         nm   = argv[++i];
        else if (a == "--base" && i + 1 < argc)  base = std::strtoull(argv[++i], nullptr, 0);
        else if (elf.empty())                    elf  = a;
        else if (out.empty())                    out  = a;
        else                                     die("unexpected argument: " + a);
    }
    if (elf.empty() || out.empty())
        die("usage: symbolise <kernel.elf> <out.cpp> [--nm PROG] [--base HEX]");

    std::vector<Sym> syms = read_symbols(nm, elf, base);
    if (syms.size() < MIN_SYMBOLS)
        die("only " + std::to_string(syms.size()) + " code symbols in " + elf +
            " - is it stripped?");

    // Ascending address. Ties: prefer the global alias, then the lexically
    // smaller name, so the result never depends on nm's output order.
    std::sort(syms.begin(), syms.end(), [](const Sym& a, const Sym& b) {
        if (a.addr   != b.addr)   return a.addr < b.addr;
        if (a.global != b.global) return a.global;
        return a.name < b.name;
    });
    syms.erase(std::unique(syms.begin(), syms.end(),
                           [](const Sym& a, const Sym& b) { return a.addr == b.addr; }),
               syms.end());

    // One string pool, one copy of each distinct name.
    std::string                                    pool;
    std::vector<std::uint32_t>                     offs;
    std::unordered_map<std::string, std::uint32_t> interned;
    offs.reserve(syms.size());

    for (const Sym& s : syms) {
        const auto it = interned.find(s.name);
        if (it != interned.end()) {
            offs.push_back(it->second);
            continue;
        }
        const std::uint32_t off = static_cast<std::uint32_t>(pool.size());
        interned.emplace(s.name, off);
        pool += s.name;
        pool.push_back('\0');
        offs.push_back(off);
    }

    std::FILE* f = std::fopen(out.c_str(), "w");
    if (f == nullptr)
        die("cannot write " + out);

    std::fprintf(f,
        "// GENERATED by tools/symbolise. DO NOT EDIT.\n"
        "//\n"
        "// Everything here lives in .ksyms, which linker.ld places after every\n"
        "// other section. Nothing in this file may emit code, or land in\n"
        "// .text/.rodata/.data/.bss - see Stage 1.7 section 3.\n"
        "\n"
        "#include <stdint.h>\n"
        "\n"
        "#define KSYMS __attribute__((used, section(\".ksyms\"), aligned(8)))\n"
        "\n"
        "extern \"C\" {\n\n");

    std::fprintf(f, "KSYMS const uint32_t ksyms_count        = %zuu;\n", syms.size());
    std::fprintf(f, "KSYMS const uint32_t ksyms_strings_size = %zuu;\n\n", pool.size() + 1);

    std::fprintf(f, "KSYMS const uint64_t ksyms_addr[%zu] = {\n", syms.size());
    for (const Sym& s : syms)
        std::fprintf(f, "    0x%016llXULL,  // %s\n",
                     static_cast<unsigned long long>(s.addr), s.name.c_str());
    std::fprintf(f, "};\n\n");

    std::fprintf(f, "KSYMS const uint32_t ksyms_name_off[%zu] = {", offs.size());
    for (std::size_t i = 0; i < offs.size(); ++i)
        std::fprintf(f, "%s%uu,", (i % 8 == 0 ? "\n    " : " "), offs[i]);
    std::fprintf(f, "\n};\n\n");

    // One string literal per name. Adjacent literals concatenate, and the
    // compiler appends the final NUL - hence strings_size == pool.size() + 1.
    std::fprintf(f, "KSYMS const char ksyms_strings[] =\n");
    for (std::size_t i = 0; i < pool.size(); ) {
        const std::size_t n = pool.find('\0', i);
        std::fprintf(f, "    \"%s\\0\"\n", escape(pool.substr(i, n - i)).c_str());
        i = n + 1;
    }
    std::fprintf(f, "    \"\";\n\n");

    std::fprintf(f, "}  // extern \"C\"\n");

    if (std::fclose(f) != 0)
        die("write failed: " + out);

    std::fprintf(stderr, "symbolise: %zu symbols, %zu name bytes, %zu total\n",
                 syms.size(), pool.size(), syms.size() * 12 + pool.size() + 8);
    return 0;
}
```

#### Line by line

**The header comment and the includes**
```cpp
#include <algorithm>
#include <string>
#include <unordered_map>
#include <vector>
#include <cxxabi.h>
```
This is one of the few files in the tree where those includes are legal, and the comment says
so because the next person to read it will have spent a week being told they are not. The
three-toolchain rule from [[Stage 0.8 - The Build System]] is what makes it true: `tools/` is
a separate CMake project configured by a separate CMake process with the native compiler and
the real standard library. Add `include(cmake/KernelFlags.cmake)` to `tools/CMakeLists.txt`
"for consistency" and this file stops compiling in four ways at once.

`<cxxabi.h>` is libstdc++'s exposure of the Itanium ABI runtime. `abi::__cxa_demangle` is the
same implementation behind `c++filt` and `addr2line -C`.

**Reproducibility is a design constraint, not a nicety**
```cpp
// The output is a pure function of the input ELF: no timestamps, no paths, ...
```
`make verify-repro` in [[08 - Build System]] compares two clean builds byte for byte. A
generated file that embeds `__DATE__`, the input path, or a hash-map iteration order breaks
that check, and the failure looks like a build-system bug rather than a generator bug. Three
places in this program could have leaked non-determinism and each is closed deliberately: the
banner names no input file, the sort has a total order with an explicit tie-break, and the
pool is built by iterating the **sorted vector** rather than the `unordered_map`.

**`MIN_SYMBOLS`**
```cpp
constexpr std::size_t MIN_SYMBOLS = 16;
```
The only defence against the worst silent failure in the stage. If someone adds `-s` to the
link flags, or strips `kernel.stage1.elf`, `nm` prints nothing, the tool emits a table with
zero entries, the kernel links, boots, panics, and prints exactly what it printed before this
stage — and the only clue is an absence. Dying here converts that into a build failure with
the word "stripped" in it. Sixteen is deliberately far below any real kernel and far above
zero.

**`MAX_NAME`**
```cpp
constexpr std::size_t MAX_NAME = 96;
```
Bounds the pool and bounds the panic line. It also bounds the kernel's `put(sym.name)` walk:
no stored name is longer than 96 bytes, so even if an offset were valid but wrong, the print
terminates. A cheap second guarantee on top of the pool's terminating NUL.

**`strip_params`, and why it scans backwards**
```cpp
    if (s.empty() || s.back() != ')')
        return s;
    int depth = 0;
    for (std::size_t i = s.size(); i-- > 0; ) {
        if (s[i] == ')')      ++depth;
        else if (s[i] == '(') { if (--depth == 0) return s.substr(0, i); }
    }
```
The obvious implementation — cut at the first `(` — is wrong on exactly the cases that
matter. `operator()(int)` would become `operator`. Scanning backwards from a trailing `)` with
a depth counter finds the `(` that opens the outermost, final parameter list, which is the one
you want in every case:

| Input | What the depth walk finds | Result |
|---|---|---|
| `heap_expand(unsigned long)` | the `(` at index 11 | `heap_expand` |
| `operator()(int)` | the `(` at index 10 | `operator()` |
| `install(void (*)(int))` | the `(` at index 7 | `install` |
| `Slab<64>::alloc()` | the `(` before the empty list | `Slab<64>::alloc` |
| `vtable for Console` | no trailing `)` — early return | unchanged |

The early return on "does not end in `)`" protects the non-function symbols `nm` reports:
`vtable for X`, `typeinfo for X`, `guard variable for X`. Those are data and the type filter
has already dropped them; the guard costs one comparison and makes the function correct on its
own terms rather than correct by luck.

**`demangle`**
```cpp
    if (mangled.rfind("_Z", 0) != 0)
        return mangled;
```
`rfind(s, 0) == 0` is the idiomatic "starts with", and it is safe on strings shorter than the
prefix. Skipping the demangler for non-`_Z` names is not an optimisation — it is what
guarantees `extern "C"` symbols pass through byte for byte. `kmain` would very likely be
unaffected by `__cxa_demangle` anyway, but relying on that is relying on a behaviour of
somebody else's parser.

```cpp
    if (raw == nullptr || status != 0) { std::free(raw); return mangled; }
```
`__cxa_demangle` returns a `malloc`'d buffer and sets `status`: `0` success, `-1` allocation
failure, `-2` "not a valid mangled name", `-3` invalid argument. On any failure the mangled
form is better than nothing — it still identifies the function uniquely and `c++filt` decodes
it by hand. `free(nullptr)` is defined and does nothing, so the call is unconditional.

**`sanitise` and `escape` are two functions on purpose**
```cpp
std::string sanitise(std::string s);       // at ingest: changes the BYTES
std::string escape(const std::string& s);  // at emit:   changes the SOURCE TEXT
```
This split is the subtle bug in the whole tool. A name containing a backslash occupies **one**
byte in the pool and **two** characters in the C++ source (`\\`). Compute the pool offsets from
the escaped text and every offset after the first such name is wrong — which prints names as
fragments of their neighbours. So escaping happens only when writing, and offsets come from
`pool.size()`, which counts real bytes.

`sanitise` runs at ingest because it *does* change bytes: replacing a non-printable with `?`
keeps the length identical, and truncating to `MAX_NAME` changes the length before any offset
is assigned. Both are recorded in the pool, so the kernel's view and the source's view agree.

**`read_symbols`: running `nm`**
```cpp
    const std::string cmd = nm + " --defined-only \"" + elf + "\"";
    std::FILE* pipe = ::popen(cmd.c_str(), "r");
```
`--defined-only` drops `U` (undefined) and `w` (undefined weak) rows, which is what guarantees
every remaining line begins with an address — the parse below depends on it. The path is
quoted because a build directory can contain spaces.

`popen`/`pclose` are POSIX, not ISO C++. They are visible here because libstdc++ on glibc
defines `_GNU_SOURCE` in `bits/os_defines.h`, which every libstdc++ header pulls in, so the
declarations are exposed even under `-std=c++20`. If you ever port this tool to a libc where
that is not true, add `-D_POSIX_C_SOURCE=200809L` to the target's compile definitions.

We deliberately do **not** pass `nm -C`. Two reasons: the demangled name needs post-processing
(strip parameters, sanitise, clamp), which is easier in-process; and `nm -C` puts spaces and
parentheses into the name field, so any parse that treated the line as whitespace-delimited
fields would silently break. We do not pass `-n` either, because the tool must sort anyway to
dedupe and tie-break — depending on an `nm` flag for an invariant the kernel's binary search
relies on is a flag somebody will one day forget.

**The parse**
```cpp
        char* end = nullptr;
        errno     = 0;
        const std::uint64_t addr = std::strtoull(line, &end, 16);
        if (end == line || errno != 0)
            continue;
```
`strtoull` with base 16 consumes the address and leaves `end` at the first character it did
not use. `end == line` means it consumed nothing — a blank line, or a header — and is the
cheapest possible "is this a symbol row" test. `errno` catches an overflowing value, which
cannot happen with a 16-digit address but costs one store.

```cpp
        const char type = *end;
        if (type != 'T' && type != 't' && type != 'W' && type != 'w')
            continue;
```
The filter from §2.2, and the single most consequential line in the tool. Widen it to include
`D`/`B`/`R` and the table doubles in size while acquiring the ability to answer a *code*
address query with a variable's name — which would break the frame sanity check in
`panic.cpp`, because garbage addresses would suddenly start resolving.

```cpp
        std::string name(end);
        while (!name.empty() && (name.back() == '\n' || name.back() == '\r'))
            name.pop_back();
```
The rest of the line is the name, taken whole rather than tokenised. Stripping `\r` as well as
`\n` costs nothing and means output captured on a Windows host does not produce names with an
invisible trailing character — which would defeat interning and print as a stray glyph.

```cpp
        if (name.empty() || addr < base)
            continue;
```
The `base` filter drops anything outside the kernel's virtual range. Nothing of type `T`/`t`
should be below `0xFFFFFFFF80000000` in this image, so this is insurance rather than a working
filter — but it is the insurance that keeps `ksyms_addr[0]` meaningful, which
`symbol_lookup`'s first bound check depends on.

```cpp
    if (::pclose(pipe) != 0)
        die("`" + cmd + "` failed - is " + nm + " on PATH?");
```
`pclose` returns the child's wait status. If `nm` is missing the shell exits 127 and this
fires. Without the check a missing `nm` produces zero lines, `MIN_SYMBOLS` fires instead, and
the error blames the ELF for being stripped when the real problem is `PATH`.

**Argument parsing, and why `--nm` exists**
```cpp
        if (a == "--nm" && i + 1 < argc)  nm = argv[++i];
```
The tool is a host binary but the ELF it reads is a cross-target object, so the `nm` that
understands it is `x86_64-elf-nm`, not the host's. The default is correct inside the container;
the flag exists so CMake can pass the name explicitly, and so a second architecture would not
need a code change. `--base` is the same idea for `KERNEL_VMA`.

**The sort and the dedupe**
```cpp
    std::sort(syms.begin(), syms.end(), [](const Sym& a, const Sym& b) {
        if (a.addr   != b.addr)   return a.addr < b.addr;
        if (a.global != b.global) return a.global;
        return a.name < b.name;
    });
```
The primary key is the address, because that is what the kernel binary-searches. The two
tie-breaks exist because several symbols can share one address — an alias, a folded-back
`.cold` part, a label and the function that starts at it. Preferring the global (`a.global`
sorts `true` first) means `kmain` wins over a local alias at the same address, which is almost
always the name you wanted. The final `a.name < b.name` makes the order **total**, so the
output does not depend on `std::sort`'s internal choices or on `nm`'s ordering. That is what
makes the generated file reproducible.

```cpp
    syms.erase(std::unique(syms.begin(), syms.end(),
                           [](const Sym& a, const Sym& b) { return a.addr == b.addr; }),
               syms.end());
```
`std::unique` collapses *adjacent* equal elements — which after the sort means all of them —
and keeps the **first**, the one the tie-break just promoted. Duplicates would not break the
binary search, but they waste an entry each and make `ksyms_addr` non-strictly ascending,
which is a weaker invariant to reason about. Remove them.

**Interning**
```cpp
        const auto it = interned.find(s.name);
        if (it != interned.end()) { offs.push_back(it->second); continue; }
```
Identical names appear more often than you would guess: the same `static` helper compiled into
several translation units, or two long template names truncated to the same 96 characters.
Interning stores one copy and points every user at it. The map is only ever *queried* in
sorted-vector order and never iterated, which is what keeps it out of the reproducibility
argument.

**Emitting the section attribute**
```cpp
        "#define KSYMS __attribute__((used, section(\".ksyms\"), aligned(8)))\n"
```
Three attributes, three jobs. `section(".ksyms")` is what puts these objects after everything
else in the image — the entire chicken-and-egg fix from §3 rests on this attribute and the
matching linker-script entry. `used` tells the compiler the object is referenced even though
nothing in this translation unit reads it; it is the same belt-and-braces pairing with `KEEP()`
that [[Stage 0.4 - The Linker Script and Higher-Half Layout]] argues for on `.limine_requests`,
and the reasoning is identical — `used` stops the compiler deleting it, `KEEP()` stops
`--gc-sections` deleting it, and neither substitutes for the other. `aligned(8)` guarantees the
`uint64_t` array is 8-byte aligned wherever the linker places the fragment; x86-64 tolerates
unaligned loads, so this is about not shipping a latent bug rather than about speed.

Everything emitted is `const`. Mixing a non-`const` object into `.ksyms` makes GCC want the
section writable and produces `error: .ksyms causes a section type conflict` — a confusing
message for a real mistake, because a writable symbol table is one a wild pointer can rewrite.

**The `extern "C"` block**
```cpp
        "extern \"C\" {\n\n"
```
Two jobs. The names must be unmangled or `symbols.cpp`'s `extern` declarations would not match.
And a declaration *directly contained* in a linkage-specification is treated as though it
carried `extern`, which defeats the C++ rule giving a namespace-scope `const` internal linkage.
Drop the `extern "C"` and all five objects become internal to the generated translation unit,
the kernel fails to link with five undefined references, and the cause is invisible unless you
happen to know that rule.

**The address array**
```cpp
        std::fprintf(f, "    0x%016llXULL,  // %s\n",
                     static_cast<unsigned long long>(s.addr), s.name.c_str());
```
`%016llX` gives a fixed-width uppercase address matching the panic output, so you can compare
by eye. The `ULL` suffix is explicit rather than necessary — the compiler would pick a type
that works — and removes a class of question. The trailing comment is the reason a reviewer
can read this file at all, the same argument [[Stage 1.2 - Rasterising a Bitmap Font]] makes
for annotating the font array, and the reason the tool is worth eighty lines more than an
`objcopy` one-liner. The comment holds the raw name, not the escaped one: a comment needs no
escaping.

**The offset array**
```cpp
    for (std::size_t i = 0; i < offs.size(); ++i)
        std::fprintf(f, "%s%uu,", (i % 8 == 0 ? "\n    " : " "), offs[i]);
```
Eight per line, purely so the file diffs readably. The `u` suffix keeps the initialisers
unsigned.

**The string pool**
```cpp
    for (std::size_t i = 0; i < pool.size(); ) {
        const std::size_t n = pool.find('\0', i);
        std::fprintf(f, "    \"%s\\0\"\n", escape(pool.substr(i, n - i)).c_str());
        i = n + 1;
    }
    std::fprintf(f, "    \"\";\n\n");
```
**One literal per name, and this is not cosmetic.** Emitting the pool as one long literal would
produce text like `"kmain\0123abc"`, where `\012` parses as an **octal escape** — a completely
different byte, silently. Splitting at every NUL means each `\0` ends its own literal and can
never absorb the digits that follow. Adjacent string literals concatenate at translation phase
6, so the array's contents are exactly the pool.

The trailing `""` closes the initialiser and contributes nothing. The compiler appends the
final NUL, which is why `ksyms_strings_size` is `pool.size() + 1` and why *every* offset less
than that size names a NUL-terminated string. That is the invariant the kernel's bounds check
is written against.

**The summary line**
```cpp
    std::fprintf(stderr, "symbolise: %zu symbols, %zu name bytes, %zu total\n", ...);
```
To stderr, so it appears in the build log next to Ninja's `COMMENT` and never contaminates the
generated file. It is how you notice the day the table doubles.

---

### `tools/CMakeLists.txt`

One target added to the host-tools project from [[Stage 1.2 - Rasterising a Bitmap Font]].

```cmake
# ... the existing mkfont target ...

add_executable(symbolise symbolise/symbolise.cpp)
target_compile_options(symbolise PRIVATE -Wall -Wextra -Werror)
```

That is the whole change. `KernelFlags.cmake` is still not included here, and the comment at
the top of that file still explains why. `-Werror` on a host tool matters more than on the
kernel: a generator that quietly does the wrong thing produces a kernel that lies to you.

---

### Top-level `CMakeLists.txt`

```cmake
set(HOST_TOOL_DIR ${CMAKE_BINARY_DIR}/host-tools/bin)
set(MKFONT        ${HOST_TOOL_DIR}/mkfont)
set(SYMBOLISE     ${HOST_TOOL_DIR}/symbolise)      # <-- new

ExternalProject_Add(host_tools
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/tools
    BINARY_DIR ${CMAKE_BINARY_DIR}/host-tools
    CMAKE_ARGS
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_CXX_COMPILER=c++
        -DCMAKE_RUNTIME_OUTPUT_DIRECTORY=${HOST_TOOL_DIR}
    BUILD_ALWAYS     TRUE
    INSTALL_COMMAND  ""
    BUILD_BYPRODUCTS ${MKFONT} ${SYMBOLISE}        # <-- symbolise added
)

add_subdirectory(kernel)
```

`BUILD_BYPRODUCTS` is the line to get right. Ninja refuses to generate a graph containing a
file no rule produces, so omitting `${SYMBOLISE}` makes the next section's `DEPENDS
${SYMBOLISE}` fail at *generate* time with `'build/host-tools/bin/symbolise', needed by ...,
missing and no known rule to make it` — an error naming a file that plainly does get built.
Same rule, same message, same fix as `mkfont`.

---

### `kernel/arch/x86_64/boot/linker.ld` — the `.ksyms` section

Two edits to the script from [[Stage 0.4 - The Linker Script and Higher-Half Layout]]. This is
the file that makes the chicken-and-egg fix real; everything else is plumbing.

```ld
PHDRS
{
    requests PT_LOAD FLAGS(6);   /* RW  — the bootloader writes here */
    text     PT_LOAD FLAGS(5);   /* R E */
    rodata   PT_LOAD FLAGS(4);   /* R   */
    data     PT_LOAD FLAGS(6);   /* RW  */
    ksyms    PT_LOAD FLAGS(4);   /* R   — the embedded symbol table  <-- new */
}
```

and, in `SECTIONS`, immediately after the existing `__bss_end`:

```ld
    . = ALIGN(PAGE_SIZE);
    __bss_end = .;

    /* ------------------------------------------- the embedded symbol table
       LAST, and in its own segment, on purpose.

       tools/symbolise generates this section's contents from a link of this
       very image. Placing it after every other output section makes it
       IMPOSSIBLE for its size to move anything that came before it, so the
       addresses the first link assigned are still correct in the second.
       Read-only: nothing in the kernel ever writes it.  See Stage 1.7 §3. */
    .ksyms : {
        __ksyms_start = .;
        KEEP(*(.ksyms))
        __ksyms_end = .;
    } :ksyms

    . = ALIGN(PAGE_SIZE);
    __kernel_end = .;
```

**Why after `.bss` and not before `.data`.** Only `.text` addresses appear in a backtrace, so
strictly the table only has to come after `.text`. Putting it at the very end is the strongest
form of the same guarantee at no extra cost, and it preserves something Stage 0.4 cares about:
`.bss` must remain the **last** section inside the `:data` segment so that `p_memsz > p_filesz`
and the loader zero-fills the tail. Append `.ksyms` to `:data` after `.bss` instead of giving
it its own `PHDRS` entry and you put a `PROGBITS` section after a `NOBITS` one in the same
segment — which forces the linker to materialise every zero byte of `.bss` into the file, and
your ELF grows by the size of the kernel stack plus every static buffer in the kernel.

**`KEEP(*(.ksyms))`.** Nothing in the kernel reaches the table through a relocation:
`symbols.cpp` refers to `ksyms_addr` by name, which is a symbol reference, but the *section*
has no incoming references from the reachability graph `--gc-sections` walks. The moment
someone enables `--gc-sections` to shrink the image, an unprotected `.ksyms` is collected and
every panic silently loses its names. This is exactly the `.limine_requests` argument from
Stage 0.4, and the same belt-and-braces answer: `used` in the source, `KEEP()` in the script,
because neither substitutes for the other.

**`__kernel_end` moves; `__bss_end` does not.** The table is part of the loaded image, so the
Phase 4 frame allocator must reserve it — that is why `__kernel_end` goes after `.ksyms`
rather than staying where it was. `__bss_end` stays put, because every consumer of it means
"the end of the writable region", and `.ksyms` is not writable.

**One consequence worth predicting:** `__kernel_end` and `__stack_top` therefore differ between
`kernel.stage1.elf` and `kernel.elf`. That is fine — nothing ever boots the stage-one image —
but it is why §6's verification compares `.text` symbols specifically rather than diffing whole
symbol tables.

---

### `kernel/lib/ksyms_stub.cpp`

The pass-one stand-in. It exists so `kernel.stage1.elf` links at all.

```cpp
// kernel/lib/ksyms_stub.cpp — the stand-in table for the FIRST link.
//
// kernel.stage1.elf links this file. kernel.elf links the generated
// build/kernel/generated/ksyms.cpp instead. Exactly one of the two is in any
// given link, and they define the same five symbols in the same section.
//
// This file must define NOTHING else, and must emit no code: anything it put
// into .text would appear in the stage-one link and not the final one, which
// is precisely the drift Stage 1.7 §3 exists to prevent.

#include <stdint.h>

#define KSYMS __attribute__((used, section(".ksyms"), aligned(8)))

extern "C" {

KSYMS const uint32_t ksyms_count        = 0;
KSYMS const uint32_t ksyms_strings_size = 1;
KSYMS const uint64_t ksyms_addr[1]      = { 0 };
KSYMS const uint32_t ksyms_name_off[1]  = { 0 };
KSYMS const char     ksyms_strings[1]   = { '\0' };

}  // extern "C"
```

`ksyms_count = 0` is the whole behaviour: `symbol_lookup` checks it first and returns "not
found", so a stage-one image degrades exactly to Stage 0.7 — raw addresses, no names, no
crash. That matters more than it sounds, because if you ever *do* boot the stage-one image by
accident (see §7) you get a working kernel with an unhelpful backtrace rather than a mystery.

The one-element arrays are not zero-length on purpose: `const uint64_t x[] = {};` is not valid
C++, and a zero-length array extension would be a GNU extension in a tree that sets
`CMAKE_CXX_EXTENSIONS OFF`. One element costs sixteen bytes in an image nobody boots.

---

### `kernel/CMakeLists.txt` — one compile, two links

This is the restructure. The file from [[Stage 0.8 - The Build System]] built one executable
directly from sources; it now builds an **object library** and links it twice.

```cmake
# --- the embedded font (Stage 1.2) -----------------------------------------
set(FONT_BLOB ${CMAKE_SOURCE_DIR}/tools/mkfont/vga8x16.fnt)
set(FONT_GEN  ${CMAKE_CURRENT_BINARY_DIR}/generated/font8x16.cpp)

add_custom_command(
    OUTPUT  ${FONT_GEN}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_BINARY_DIR}/generated
    COMMAND ${MKFONT} ${FONT_BLOB} ${FONT_GEN} font8x16
    DEPENDS ${FONT_BLOB} ${MKFONT} host_tools
    COMMENT "mkfont: vga8x16.fnt -> font8x16.cpp"
    VERBATIM
)

# --- every kernel translation unit, compiled ONCE --------------------------
#
# An object library, not two executables built from the same source list.
# This is not only a build-time saving: it is what makes "the same objects,
# linked twice" literally true, which is what the address-stability argument
# in Stage 1.7 §3 rests on.

add_library(kernel_objs OBJECT
    arch/x86_64/boot/entry.cpp
    arch/x86_64/boot/boot_info.cpp
    drivers/char/serial.cpp
    drivers/char/fbcon.cpp
    lib/log.cpp
    lib/panic.cpp
    lib/symbols.cpp
    main.cpp
    ${FONT_GEN}
)

# PUBLIC, not PRIVATE: both executables below have one source of their own
# (the stub / the generated table) and those must be compiled with exactly
# the same flags. PUBLIC propagates them through target_link_libraries.
target_compile_options(kernel_objs PUBLIC ${KERNEL_CXX_FLAGS})
target_include_directories(kernel_objs PUBLIC ${CMAKE_SOURCE_DIR}/kernel/include)

set(LD_SCRIPT ${CMAKE_SOURCE_DIR}/kernel/arch/x86_64/boot/linker.ld)
set(KSYMS_GEN ${CMAKE_CURRENT_BINARY_DIR}/generated/ksyms.cpp)

# --- pass 1: the same kernel, with an EMPTY symbol table -------------------
add_executable(kernel.stage1.elf lib/ksyms_stub.cpp)
target_link_libraries(kernel.stage1.elf PRIVATE kernel_objs)

# --- generate: read pass 1's addresses, write pass 2's table ---------------
add_custom_command(
    OUTPUT  ${KSYMS_GEN}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_CURRENT_BINARY_DIR}/generated
    COMMAND ${SYMBOLISE} $<TARGET_FILE:kernel.stage1.elf> ${KSYMS_GEN}
            --nm x86_64-elf-nm
    DEPENDS kernel.stage1.elf $<TARGET_FILE:kernel.stage1.elf>
            ${SYMBOLISE} host_tools
    COMMENT "symbolise: kernel.stage1.elf -> ksyms.cpp"
    VERBATIM
)

# --- pass 2: the image that actually boots ---------------------------------
add_executable(kernel.elf ${KSYMS_GEN})
target_link_libraries(kernel.elf PRIVATE kernel_objs)

# --- identical link treatment for both -------------------------------------
foreach(image kernel.stage1.elf kernel.elf)
    target_link_options(${image} PRIVATE ${KERNEL_LINK_FLAGS} -T ${LD_SCRIPT})
    set_target_properties(${image} PROPERTIES
        LINK_DEPENDS             ${LD_SCRIPT}
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    )
endforeach()

# A separate symbol file: GDB loads it, and scripts/symbolise.sh can use it if
# kernel.elf is ever stripped. Keep kernel.elf unstripped as well.
add_custom_command(TARGET kernel.elf POST_BUILD
    COMMAND x86_64-elf-objcopy --only-keep-debug
            $<TARGET_FILE:kernel.elf> ${CMAKE_BINARY_DIR}/kernel.sym
    COMMENT "Generating kernel.sym"
)
```

#### Line by line

**`add_library(kernel_objs OBJECT ...)`**
An `OBJECT` library is a target that compiles sources and stops — no archive, no link. Both
executables then consume the resulting `.o` files. Two things this buys, and the second is the
important one. Compile time halves compared with listing the sources in both executables. And
the two links are guaranteed to see **byte-identical objects**, which is the premise of the
whole scheme: if the passes recompiled separately, a difference in flags, in `__FILE__`
normalisation, or in anything else would move code between them and the table would be built
against addresses the final image does not have.

**`target_compile_options(kernel_objs PUBLIC ...)`**
[[Stage 0.8 - The Build System]] used `PRIVATE` here, correctly, because there was one target
and nothing consumed it. Now two executables link this library and each carries one source of
its own — `ksyms_stub.cpp` and the generated `ksyms.cpp`. Those must be compiled with
`-mcmodel=kernel -mno-red-zone -nostdinc++` like everything else, and `PUBLIC` is what
propagates the flags across `target_link_libraries`. Leave it `PRIVATE` and the two extra
sources compile with default host-ish flags: the most likely first symptom is
`fatal error: stdint.h: No such file or directory`, and the least likely is a link that
succeeds and is quietly wrong.

**`target_link_libraries(kernel.stage1.elf PRIVATE kernel_objs)`**
Since CMake 3.12 you may link an object library this way; the object files are added to the
consuming target and the usage requirements propagate. This also creates the target-level
dependency, so the objects are built before either link runs. The older
`$<TARGET_OBJECTS:kernel_objs>` in the source list works too but does not propagate the
compile options, which is exactly what we want here.

**The custom command's `DEPENDS` line**

| Entry | Kind | What it buys |
|---|---|---|
| `kernel.stage1.elf` | target | Ordering: the first link must finish before the tool runs |
| `$<TARGET_FILE:kernel.stage1.elf>` | file | Re-run the generator whenever the stage-one image changes — i.e. whenever *any* kernel source changes |
| `${SYMBOLISE}` | file | Edit `symbolise.cpp`, the tool relinks, its timestamp moves, the table regenerates |
| `host_tools` | target | Ordering: build the tool before invoking it |

The file entry is the one that makes the pipeline correct. Omit it and the table is generated
once and never again: you add a function, the kernel rebuilds, the addresses shift, and the
table still describes yesterday's binary — §2.6's failure, arriving by a different road.
`${SYMBOLISE}` is accepted as a file dependency only because of `BUILD_BYPRODUCTS` in the
top-level file; the two go together.

**`--nm x86_64-elf-nm` passed explicitly**
The tool's default is already this, but naming it in the build means the build does not depend
on a default compiled into a binary somebody may change. It is also the line you edit on the
day there is a second target architecture.

**Why the custom command must live in this file**
`add_custom_command(OUTPUT ...)` attaches to the directory it appears in, and only a target in
*that same directory* picks it up. Move this block to the top-level `CMakeLists.txt` and
`kernel.elf` never sees the rule; Ninja reports "no known rule to make ksyms.cpp" and the fix
is not obvious from the message. Same rule as `mkfont` in Stage 1.2.

**The `foreach`**
Both images must be linked with the same flags and the same script, and both must land at the
build root. Writing it once means they cannot drift — and drift here would be subtle, because
a stage-one image linked with a *different* `max-page-size` would lay out `.text` differently
and the table would be built against the wrong addresses. That is the failure this loop
prevents from ever being possible.

**`RUNTIME_OUTPUT_DIRECTORY` on the stage-one image too.** `scripts/mkimage.sh` only looks for
`build/kernel.elf`, so the stage-one image does not need to be at the build root for the build
to work. It is put there anyway so §6's verification command has a stable path.

### `cmake/KernelFlags.cmake`

One flag added:

```cmake
set(KERNEL_CXX_FLAGS
    ...
    -fno-omit-frame-pointer             # so panic() can walk the stack
    -g                                  # DWARF, for the offline file:line pass
    -Wall -Wextra -Werror)
```

CMake already adds `-g` for `Debug` and `RelWithDebInfo`. Adding it here makes it
unconditional, and the reason is that half of this stage's deliverable lives on the host:
`scripts/symbolise.sh` needs `.debug_line` in `kernel.elf`, and a plain `Release` build
without this flag makes every `addr2line` answer `??:0`. The run-time cost is **zero** —
`.debug_*` sections are not `SHF_ALLOC`, so they are in no `PT_LOAD` segment and Limine never
reads them. The only cost is `kernel.elf` on the ISO getting a few megabytes larger, which
matters to nobody at this stage and is recoverable later by stripping the *image* copy while
keeping `build/kernel.sym`.

---

### `kernel/include/kernel/symbols.hpp`

The cross-subsystem interface. One struct, two functions.

```cpp
#pragma once

#include <stdint.h>

// The result of resolving an address against the embedded symbol table.
//
//   name == nullptr  ->  the address resolved to nothing. Callers must check.
//
struct SymbolInfo {
    const char* name;    // into .ksyms; NUL-terminated; never freed
    uintptr_t   base;    // start address of the containing function
    uintptr_t   offset;  // addr - base
};

// Resolve a kernel code address to "function + offset".
//
// Safe to call from panic(): never allocates, never locks, never writes, and
// dereferences nothing it has not first bounds-checked. Runs in
// ceil(log2(N)) + 1 iterations and cannot loop.
SymbolInfo symbol_lookup(uintptr_t addr);

// How many symbols this image embeds. 0 means no table (a stage-one link, or
// one where --gc-sections ate .ksyms).
uint32_t symbol_count();
```

`<stdint.h>`, not `<cstdint>` — there is no libstdc++ in this toolchain and `-nostdinc++`
makes that a hard error rather than a surprise ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]).

`SymbolInfo` is returned by value and is 24 bytes, so the SysV ABI returns it via a hidden
pointer to caller-provided storage. That storage is the caller's stack frame, which is the
only allocation involved anywhere in this stage — and it is the same kind of "allocation" as
declaring a local `int`.

`symbol_count()` exists so the panic handler can print one honest line when the table is
missing, rather than silently producing a Stage 0.7 backtrace and leaving you to wonder
whether the stage is broken or the image is old.

---

### `kernel/lib/symbols.cpp`

The lookup. Thirty lines, and this is the section to read twice.

```cpp
// kernel/lib/symbols.cpp — address -> "function+offset".
//
// Every rule from panic.cpp applies to this file, because panic.cpp is its
// only caller and it runs after the kernel has admitted it is broken:
//
//   * never allocate            (there may be no heap; the heap may be corrupt)
//   * never take a lock         (the lock may be the broken thing)
//   * never parse               (the table is sorted at build time)
//   * never write memory        (nothing here can corrupt anything)
//   * never dereference an index that has not been bounds-checked
//   * terminate, always, in a bounded number of steps

#include <kernel/symbols.hpp>

#include <stddef.h>
#include <stdint.h>

// Exported by the linker script (Stage 0.4). Declared as ARRAYS: the symbol's
// ADDRESS is the value we want.
extern "C" const char __text_start[];
extern "C" const char __text_end[];

// Emitted by tools/symbolise into .ksyms, or by lib/ksyms_stub.cpp when the
// table is empty. See Stage 1.7 section 4 for the layout.
extern "C" {
extern const uint32_t ksyms_count;
extern const uint32_t ksyms_strings_size;
extern const uint64_t ksyms_addr[];
extern const uint32_t ksyms_name_off[];
extern const char     ksyms_strings[];
}

namespace {

// No kernel function is this long. An address further than this past a symbol
// start is inter-function padding or an unlisted region, not that function.
constexpr uintptr_t MAX_SYMBOL_SPAN = 0x10000;   // 64 KiB

static_assert(sizeof(uintptr_t) == sizeof(uint64_t),
              "the table stores addresses as uint64_t");

}  // namespace

uint32_t symbol_count() {
    return ksyms_count;
}

SymbolInfo symbol_lookup(uintptr_t addr) {
    const SymbolInfo none{nullptr, 0, 0};

    // 1. No table at all: a stage-one image, or .ksyms was garbage-collected.
    const size_t n = ksyms_count;
    if (n == 0)
        return none;

    // 2. Not kernel code. Rejects null, user addresses, non-canonical values,
    //    data addresses, and anything in .ksyms itself.
    const uintptr_t text_lo = reinterpret_cast<uintptr_t>(__text_start);
    const uintptr_t text_hi = reinterpret_cast<uintptr_t>(__text_end);
    if (addr < text_lo || addr >= text_hi)
        return none;

    // 3. Below the first symbol: there is no "greatest entry <= addr".
    if (addr < ksyms_addr[0])
        return none;

    // 4. Binary search for the GREATEST index whose address is <= addr.
    //    Invariant: every entry in [0, lo) is <= addr, every entry in
    //    [hi, n) is > addr. The loop shrinks [lo, hi) by half each step, so
    //    it runs at most ceil(log2(n)) + 1 times and cannot fail to end.
    size_t lo = 0;
    size_t hi = n;
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;   // no overflow, ever
        if (ksyms_addr[mid] <= addr)
            lo = mid + 1;                        // mid qualifies; look right
        else
            hi = mid;                            // mid is too big; look left
    }
    // lo is now the COUNT of entries <= addr. Step 3 proved it is not zero.
    const size_t idx = lo - 1;

    const uintptr_t base   = static_cast<uintptr_t>(ksyms_addr[idx]);
    const uintptr_t offset = addr - base;

    // 5. The last symbol has no successor to bound it, and .text is padded to
    //    a page. Refuse an implausible offset rather than print a name with a
    //    five-digit offset that looks like an answer.
    if (offset > MAX_SYMBOL_SPAN)
        return none;

    // 6. The table itself could be wrong. Bounds-check before indexing.
    const uint32_t off = ksyms_name_off[idx];
    if (off >= ksyms_strings_size)
        return none;

    return SymbolInfo{&ksyms_strings[off], base, offset};
}
```

#### Line by line

**The header comment**

Not decoration. It is the review checklist for the file, and every rule in it is a rule whose
violation converts "the kernel panicked and told me why" into "the kernel hung". Anyone adding
a cache, a lock, a lazily-built index, or a `kprintf` call to this file must argue against the
list first.

**The linker symbols**
```cpp
extern "C" const char __text_start[];
extern "C" const char __text_end[];
```
Declared as **arrays**, not pointers. `extern const char __text_start[]` means "the symbol's
address is the value I want". Writing `extern const char* __text_start` reads eight bytes
*from* that address and treats them as a pointer — a different and wrong number, and the
symptom is that every lookup fails and every frame prints `<no symbol>`. Same declaration and
same trap as [[Stage 0.7 - Panic and KASSERT]].

**The table declarations**
```cpp
extern "C" {
extern const uint32_t ksyms_count;
extern const uint64_t ksyms_addr[];
...
}
```
`extern "C"` so the names match the unmangled definitions in the generated file, and the
explicit `extern` keyword so these are declarations rather than tentative definitions with
internal linkage. The arrays are declared with **no size**: this translation unit does not know
how many entries there are and must not pretend to, because `ksyms_count` is the only truth.
An incomplete array type is legal to declare and index; only `sizeof` is forbidden, which is
exactly the operation that would be wrong here.

**`MAX_SYMBOL_SPAN`**
```cpp
constexpr uintptr_t MAX_SYMBOL_SPAN = 0x10000;   // 64 KiB
```
The bound for step 5. Sixty-four kilobytes is roughly a hundred times the largest function this
kernel will ever have and roughly sixteen times the page padding at the end of `.text`, so it
rejects the case it exists for and accepts everything real. A tighter bound would eventually
reject a genuinely large function; a looser one stops catching anything.

**`static_assert`**
```cpp
static_assert(sizeof(uintptr_t) == sizeof(uint64_t), ...);
```
The table stores addresses as `uint64_t` and the lookup compares them against `uintptr_t`. On
this target both are `unsigned long` so the comparison is exact and warning-free. On a 32-bit
port it would silently truncate. One line, checked at compile time, and it turns a future
silent bug into a build failure with a sentence explaining it.

**Step 1 — the empty table**
```cpp
    const size_t n = ksyms_count;
    if (n == 0)
        return none;
```
First, because every step below indexes the array. Reading `ksyms_count` into a local also
means the search compares against a value that cannot change under it — irrelevant today,
relevant the moment [[Phase 12 - Overview|Phase 12]] has other cores running while this one
panics.

**Step 2 — the text-range gate**
```cpp
    if (addr < text_lo || addr >= text_hi)
        return none;
```
This is doing four jobs at once and it is worth naming them. It rejects **null and user
addresses**, because `__text_start` is `0xFFFFFFFF80000000`. It rejects every **non-canonical**
address for free, since anything at or above the higher-half floor is canonical by
construction. It rejects **data addresses**, including pointers into `.ksyms` itself. And it
converts the last symbol's unbounded upper edge into a bounded one, which is what makes step 5
a sanity check rather than the only defence.

It is also the check that makes the *caller's* frame sanity test meaningful. `panic.cpp` asks
"did this return address resolve?", and that question is only useful because a non-answer here
means something specific: the address is not kernel code, or it is in a region no function
covers.

**Step 3 — below the first symbol**
```cpp
    if (addr < ksyms_addr[0])
        return none;
```
The search below computes "how many entries are ≤ `addr`". If that count is zero there is no
"greatest entry ≤ `addr`" and `lo - 1` would underflow to `SIZE_MAX`, and the next line would
index the array at `SIZE_MAX`. Checking here rather than after the loop means the invalid case
never reaches the arithmetic at all.

Could this fire in practice? Only if `.text` begins with something `nm` did not report — a
linker-inserted thunk, or a `.text` fragment from an object with no symbol. Rare, real, and
cheap to handle.

**Step 4 — the binary search, which is the whole file**

This is the classic "greatest element ≤ target" search, and it is the classic place to get an
off-by-one. Take it one line at a time.

```cpp
    size_t lo = 0;
    size_t hi = n;
```
The search window is the **half-open** interval `[lo, hi)`: `lo` is included, `hi` is not.
Half-open is what makes the arithmetic below work without any `+1`/`-1` corrections, and it is
why `hi` starts at `n` rather than `n - 1`.

The invariant, which is the thing to hold in your head:

> every entry in `[0, lo)` is **≤ addr**, and every entry in `[hi, n)` is **> addr**.

It is trivially true at the start, because both ranges are empty.

```cpp
        const size_t mid = lo + (hi - lo) / 2;
```
Not `(lo + hi) / 2`. That form overflows when `lo + hi` exceeds the range of the type — the bug
that sat in `java.util.Arrays.binarySearch` for nine years. Our `n` is a few thousand, so it
cannot happen here, and writing it the safe way anyway costs nothing and means the habit is
there when the array is not small. `mid` is always in `[lo, hi)` because `hi > lo` in the loop.

```cpp
        if (ksyms_addr[mid] <= addr)
            lo = mid + 1;
        else
            hi = mid;
```
**The predicate is `<=`, not `<`, and this is the off-by-one.** Think about what each branch
asserts.

If `ksyms_addr[mid] <= addr`, then entry `mid` *qualifies* — it is a candidate answer — and so
does everything before it. So the invariant "everything in `[0, lo)` is ≤ addr" stays true if
we set `lo = mid + 1`, moving `mid` into the qualified region. The answer is `mid` or something
to its right.

If `ksyms_addr[mid] > addr`, entry `mid` is disqualified and so is everything after it, so
`hi = mid` keeps "everything in `[hi, n)` is > addr" true.

Now change `<=` to `<` and follow it through. An address that is *exactly* a function's start —
which is common: it is what `__builtin_return_address` gives you when a call is the first
instruction of a function, and what every `+0x0` frame is — now takes the `else` branch, that
entry lands in the disqualified region, and the search returns the *previous* function. The
panic names `heap_free` when the frame is at the first byte of `heap_expand`. It is a real
function, at a real address, with a plausible offset, and it is wrong.

Note also `lo = mid + 1` versus `hi = mid`, which look asymmetric and are not: with a half-open
window, excluding `mid` from the right-hand side means setting `hi` **to** `mid`, while
excluding it from the left means setting `lo` **past** it. Write `hi = mid - 1` and the loop
skips a candidate; write `lo = mid` and the window stops shrinking when `hi - lo == 1` and the
loop never terminates — a hang inside `panic`, which is the one failure worse than a wrong
answer.

```cpp
    const size_t idx = lo - 1;
```
When the loop ends, `lo == hi`, and by the invariant everything below `lo` qualifies while
everything at or above it does not. So `lo` is exactly the **count** of entries ≤ `addr`, and
the greatest qualifying entry is at `lo - 1`. Step 3 already proved `lo >= 1`, so this cannot
underflow.

**Why this terminates.** Each iteration strictly shrinks `hi - lo`: in the first branch `lo`
increases to at least `mid + 1 > lo`; in the second `hi` drops to `mid < hi`. A strictly
decreasing non-negative integer reaches zero, and `lo < hi` then fails. At most
`⌈log₂ n⌉ + 1` iterations — twelve for four thousand symbols — with two array reads each.
Termination is a property you can prove by reading eight lines, which is exactly the standard
this file is held to.

**Step 5 — bounding the offset**
```cpp
    if (offset > MAX_SYMBOL_SPAN)
        return none;
```
For every entry except the last, the search has already bounded the offset: `addr` is less than
`ksyms_addr[idx + 1]`, so the offset is at most the distance to the next function, which for a
real function is its size. The last entry has no successor, and `.text` is padded to a page
boundary after it, so an address in that padding would otherwise print as
`last_function+0x3F40`.

The number is a judgement, not a fact, and it is the right kind of judgement: it can only
produce false *negatives* (a missing name for an enormous function), never a false positive.
Given the choice, a panic that says `<no symbol>` is strictly better than one that says
something wrong.

A stricter alternative is to have the generator emit a sentinel entry at `__text_end` with an
empty name, which gives every real symbol a successor and makes the bound exact. It is a good
refinement and it costs the tool one special case; the constant is enough for now.

**Step 6 — the bounds check before indexing the pool**
```cpp
    const uint32_t off = ksyms_name_off[idx];
    if (off >= ksyms_strings_size)
        return none;

    return SymbolInfo{&ksyms_strings[off], base, offset};
```
The tool guarantees this can never fire. Check it anyway, and the reason is the same reason
`panic` validates a frame pointer it has every reason to trust: **this code runs when the
kernel is known to be broken.** Until [[Phase 4 - Overview|Phase 4]] maps `.ksyms` read-only,
any wild write in the kernel can land in it. A corrupt offset without this check is a read at
an arbitrary distance past the pool, followed by a walk to the next zero byte, in a function
whose entire job is to not fault.

This check is also what makes the returned pointer safe to hand to `put()`. `off <
ksyms_strings_size` plus "the last byte of `ksyms_strings` is `'\0'`" together prove that a
NUL exists at or before the end of the array, so walking to it stays in bounds. That pair of
facts is why `panic.cpp` may call `put(sym.name)` — the one place in the panic path that
dereferences a pointer it did not itself range-check, and it is safe because this function
range-checked it here.

**What this function does not do, and why that is the point.** No `malloc`, no static mutable
state, no lock, no recursion, no loop whose bound depends on data, no write to memory, no read
outside two arrays and two linker symbols. Every one of those absences is deliberate, because
the caller is `panic`, and a fault inside `panic` costs you the original message and returns
you to the silent reboot loop [[Stage 0.7 - Panic and KASSERT]] was written to eliminate.

---

### `kernel/lib/panic.cpp` — the updated backtrace

Three changes: one include, one new helper, and a rewritten loop. Everything else in the file
from [[Stage 0.7 - Panic and KASSERT]] is untouched, including the eight-step ordering — the
backtrace is still step 5, still the first step that dereferences memory, and still placed
after the register dump for exactly the reason §4 of that stage gives.

```cpp
#include <kernel/symbols.hpp>   // <-- add, next to <kernel/serial.hpp>
```

```cpp
// --------------------------------------------------------------- backtrace -

void print_frame(unsigned i, uintptr_t ret, const SymbolInfo& sym) {
    put("  #");
    if (i < 10)
        put(" ", 1);                  // right-align #0..#9 with #10..#31
    put_dec(i);
    put("  0x");
    put_hex(ret, 16);

    if (sym.name != nullptr) {
        put("  ");
        put(sym.name);                // in bounds and NUL-terminated: see
        put("+0x");                   // symbols.cpp step 6
        put_hex_min(ret - sym.base);
    } else {
        put("  <no symbol>");
    }
    put("\n", 1);
}

void print_backtrace(const StackFrame* frame) {
    put("\nBacktrace:\n");

    if (symbol_count() == 0)
        put("  (no symbol table in this image)\n");

    for (unsigned i = 0; i < MAX_FRAMES; ++i) {
        if (!frame_is_plausible(frame))
            break;                              // validate BEFORE dereferencing

        const uintptr_t   ret  = frame->ret;
        const StackFrame* next = frame->next;

        if (!text_is_plausible(ret))
            break;

        // ret is a RETURN address: the instruction AFTER the call. Resolve
        // ret - 1 so a call in the last instruction of a function is
        // attributed to that function and not to the next one. ret >=
        // __text_start by the check above, so this cannot underflow.
        const SymbolInfo sym = symbol_lookup(ret - 1);

        print_frame(i, ret, sym);

        // A return address inside no known function means the chain has left
        // the rails. Print what we have and stop, rather than continuing to
        // walk memory that has already proved untrustworthy.
        if (sym.name == nullptr)
            break;

        if (reinterpret_cast<uintptr_t>(next) <= reinterpret_cast<uintptr_t>(frame))
            break;                              // stacks grow down: must ascend
        frame = next;
    }
}
```

#### Line by line

**`if (symbol_count() == 0)`**
One line that saves an hour. Without it, a build where `--gc-sections` ate `.ksyms`, or where
you accidentally booted `kernel.stage1.elf`, produces a backtrace that looks exactly like the
one Stage 0.7 produced — and you go looking for a bug in the binary search when the table is
simply not there. This turns an absence into a statement.

**`put_hex(ret, 16)` before the name**
The raw address stays. Two reasons. `scripts/symbolise.sh` needs it to run `addr2line`, so
dropping it would break the other half of the deliverable. And when the name is wrong — which
is what §7's traps are about — the address is how you find out.

**`put_hex_min(ret - sym.base)`**
Minimum-width hex, so you get `+0x8C` and not `+0x000000000000008C`. Note the offset is
computed from `ret`, while the *lookup* used `ret - 1`. That is deliberate and it is the only
subtle line in the function: the name answers "which function was executing", and the offset
answers "which byte do I paste into `addr2line`". Compute the offset from `ret - 1` instead
and every number is one less than the address printed beside it, which is exactly the kind of
inconsistency that costs twenty minutes at 2am.

**`const SymbolInfo sym = symbol_lookup(ret - 1);` before `print_frame`**
The lookup happens once, and its result is used for both printing and the sanity check. Calling
it twice would be harmless — the function is pure — but doing the work once and holding the
answer in a local is the same discipline as reading `frame->ret` and `frame->next` into locals:
the panic path does each dangerous thing exactly once, in a place you can point at.

**The frame sanity check**
```cpp
        if (sym.name == nullptr)
            break;
```
This is what §3 promised, and it is one comparison on a value you already have. Before this
stage the walk's only defences were structural — canonical, aligned, ascending, inside
`.text`. Those accept any well-formed garbage that happens to point into the text range, and
because the text range is a megabyte wide, garbage often does.

The symbol table adds a semantic test: this address is not merely *in* the code region, it is
inside a function the linker actually emitted. An address in inter-function padding, in a
`.text` fragment that carries no symbol, or in a region past the last function fails it. Those
are precisely the shapes a corrupted frame chain produces.

Stopping rather than continuing is the right response, and the reasoning is the same as the
ascending-address check next to it. A backtrace's value is that the frames are causally linked;
once one link is unverifiable, the frames after it are not "slightly less reliable", they are
unrelated. Printing them makes the output longer and less true. Printing the failing frame
first, then stopping, keeps the address on screen so you can investigate it by hand — which is
what you will want, because the most common cause is a hand-written assembly stub that built no
frame, and the address tells you which one.

**What has not changed, and why**
The validate-before-dereference ordering, the `MAX_FRAMES` bound, the ascending-address check,
and the placement of the whole walk after the register dump are all exactly as
[[Stage 0.7 - Panic and KASSERT]] left them. Symbolisation is strictly additive: it reads a
statically linked read-only array using an address the loop has already validated. It cannot
make the walk less safe, and that property is the reason it can be added to the panic path at
all.

---

### `scripts/symbolise.sh`

The offline half: names come from the kernel, source lines come from here.

```sh
#!/usr/bin/env bash
# scripts/symbolise.sh — add source locations to a panic log.
#
#   make run-serial | ./scripts/symbolise.sh
#   ./scripts/symbolise.sh < build/serial.log
#
# Reads a log on stdin and, for every kernel address on a line, appends the
# file:line that addr2line reports. Needs an UNSTRIPPED kernel.elf built with
# -g — see cmake/KernelFlags.cmake.
set -euo pipefail

ELF="${KERNEL_ELF:-build/kernel.elf}"
A2L="${ADDR2LINE:-x86_64-elf-addr2line}"

[ -f "$ELF" ] || { echo "symbolise: no $ELF — run make first" >&2; exit 1; }

while IFS= read -r line; do
    addr=$(printf '%s\n' "$line" | grep -oiE '0xffffffff8[0-9a-f]{7}' | head -n1 || true)
    if [ -n "$addr" ]; then
        # Backtrace entries are RETURN addresses; -1 lands inside the call.
        prev=$(printf '0x%x' "$(( addr - 1 ))")
        loc=$("$A2L" -e "$ELF" "$prev" 2>/dev/null | head -n1 || true)
        case "$loc" in
            ''|'??:0'|'??:?') printf '%s\n'      "$line" ;;
            *)                printf '%s   %s\n' "$line" "$loc" ;;
        esac
    else
        printf '%s\n' "$line"
    fi
done
```

**The address pattern.** `0x` plus `ffffffff` plus `8` plus seven more hex digits is sixteen
hex digits — the exact shape `put_hex(ret, 16)` emits, and it will not match a random hex
number elsewhere in the log. `-i` because the kernel prints uppercase digits after a lowercase
`0x`.

**`$(( addr - 1 ))` and the sign.** `0xFFFFFFFF80104A2C` exceeds `INT64_MAX`, so bash's
arithmetic wraps it to a negative value. That is harmless: `printf '%x'` reprints the same
64-bit pattern, so `prev` comes out as `0xffffffff80104a2b` and `addr2line` gets the right
number. The `-1` is the same rule §4 states, applied on the host.

**The `case` on the result.** `addr2line` prints `??:0` when it has no line information for an
address — a stub with no DWARF, or a build with no `-g`. Passing that through would add noise
to every line; suppressing it means the script is safe to pipe every log through
unconditionally.

**If `kernel.elf` is ever stripped**, run it as `KERNEL_ELF=build/kernel.sym ./scripts/symbolise.sh`.
`objcopy --only-keep-debug` keeps `.symtab` and every `.debug_*` section, which is everything
`addr2line` needs.

The obvious speed-up is to collect all the addresses and pass them to a single `addr2line`
invocation, which accepts many. A panic has at most thirty-two frames, so the loop finishes
instantly and the simple version is the one that stays readable.

---

## 6. How to verify

### Now, without booting

```sh
make
```

Two links and one generation step must appear in the log:

```
[41/44] Linking CXX executable kernel.stage1.elf
[42/44] symbolise: kernel.stage1.elf -> ksyms.cpp
symbolise: 812 symbols, 18104 name bytes, 27856 total
[43/44] Building CXX object kernel/CMakeFiles/kernel.elf.dir/generated/ksyms.cpp.obj
[44/44] Linking CXX executable kernel.elf
```

If step 42 is missing, the custom command's `DEPENDS` is wrong and you are linking a stale
table. If the summary line says a suspiciously round number of symbols, read it — the count is
your first sanity check on the type filter.

**Read the generated file.** It is meant to be readable; that was a design goal.

```sh
sed -n '1,24p' build/kernel/generated/ksyms.cpp
```

```cpp
// GENERATED by tools/symbolise. DO NOT EDIT.
...
extern "C" {

KSYMS const uint32_t ksyms_count        = 812u;
KSYMS const uint32_t ksyms_strings_size = 18105u;

KSYMS const uint64_t ksyms_addr[812] = {
    0xFFFFFFFF80000000ULL,  // kmain
    0xFFFFFFFF80000040ULL,  // serial_wait_tx
    ...
```

**Confirm the section exists and is where it should be.**

```sh
x86_64-elf-readelf -S build/kernel.elf | grep -E 'Name|\.bss|\.ksyms'
```

`.ksyms` must be `PROGBITS`, flagged `A` (alloc) and **not** `W` (write), at a higher address
than `.bss`:

```
  [ 8] .bss    NOBITS    ffffffff80210000  ...  WA
  [ 9] .ksyms  PROGBITS  ffffffff80222000  ...   A
```

```sh
x86_64-elf-readelf -l build/kernel.elf | grep -c LOAD
```
```
5
```

Four before this stage, five now. Four means the `PHDRS` entry is missing and `.ksyms` was
folded into an existing segment — which will still work today and will break the day
[[Phase 15 - Overview|Phase 15]] applies per-section permissions.

**The chicken-and-egg check. This is the important one.**

```sh
for f in kernel.stage1.elf kernel.elf; do
  x86_64-elf-nm --defined-only "build/$f" \
    | awk '$2 ~ /^[TtWw]$/ { print $1, $3 }' | sort > "/tmp/$f.syms"
done
diff /tmp/kernel.stage1.elf.syms /tmp/kernel.elf.syms \
  && echo "OK: every code address is identical across both links"
```

`diff` must print nothing. **Any** line of output means the table describes addresses the final
image does not have, and every backtrace from now on is off by a constant. Put this check in
`scripts/lint.sh` and run it in CI ([[Stage 0.9 - CI From Day One]]) — it is mechanical, it
takes a second, and it is the only thing standing between you and §7's first trap.

Note the check deliberately compares only `T`/`t`/`W`/`w`. `__kernel_end`, `__stack_top` and
the `ksyms_*` symbols themselves *do* differ between the two links, and that is expected and
harmless (§5, linker script).

**Confirm a `static` function made it in.**

```sh
x86_64-elf-nm --defined-only build/kernel.elf | awk '$2 == "t" { print; exit }'
grep -c '// ' build/kernel/generated/ksyms.cpp     # one comment per symbol
```

Take the name from the first command and find it in `ksyms.cpp`. If local symbols are missing,
the type filter in `read_symbols` is rejecting `t`.

**Confirm the table is sorted** — the one invariant the kernel cannot check:

```sh
grep -oE '0x[0-9A-F]{16}ULL' build/kernel/generated/ksyms.cpp > /tmp/a
sort -C /tmp/a && echo "sorted"
```

### Booting it

Put `panic("test panic: %d", 42);` back at the end of `kernel_init` and run `make run-serial`.
Expected shape — addresses will differ:

```
================= KERNEL PANIC =================
test panic: 42

RAX=0000000000000000  RBX=FFFFFFFF80210000  RCX=0000000000001000
...
RIP=FFFFFFFF80101A2C  <- call site of panic

Backtrace:
  # 0  0xFFFFFFFF80101A2C  kernel_init+0x2C
  # 1  0xFFFFFFFF801002F1  kmain+0x31
================================================
```

**Check 1 — every frame has a name.** A `<no symbol>` on frame `#0` means the lookup is
failing, not the walk; go to §7. A `<no symbol>` on the *last* frame is normal once you are
walking through code Limine called.

**Check 2 — the offsets are plausible.** Small hex numbers, a few hundred bytes at most. A
five-digit offset means `MAX_SYMBOL_SPAN` let something through and the name is probably the
last symbol in `.text`.

**Check 3 — cross-check one frame against `addr2line`.**

```sh
x86_64-elf-addr2line -f -C -e build/kernel.elf 0xFFFFFFFF80101A2B
```
```
kernel_init
kernel/main.cpp:143
```

The function name must be **the same one the kernel printed**. Note the address is the printed
one minus 1, for the reason in §4. If the kernel says `kernel_init` and `addr2line` says
`serial_init`, the table is shifted — run the `diff` check above.

**Check 4 — the offline pass.**

```sh
./scripts/symbolise.sh < build/serial.log | grep -A3 Backtrace
```
```
Backtrace:
  # 0  0xFFFFFFFF80101A2C  kernel_init+0x2C   kernel/main.cpp:143
  # 1  0xFFFFFFFF801002F1  kmain+0x31         kernel/main.cpp:61
```

That is the deliverable. If the locations come out `??:0`, `-g` did not reach the build — check
`compile_commands.json`, not the CMake file.

**Check 5 — add a function and rebuild. This is the proof that the chicken-and-egg fix works.**

Insert a new function *early* in a source file, so everything after it shifts:

```cpp
// kernel/main.cpp, above kernel_init
__attribute__((noinline)) void canary_function() {
    __asm__ volatile("nop" ::: "memory");
}
```

Call it once from `kernel_init` so it is not collected, then:

```sh
make
grep -c canary_function build/kernel/generated/ksyms.cpp     # -> 1
```

Re-run the `diff` check from above — still empty — and re-run the boot test. The addresses will
all have moved; the names must all still be right, and `addr2line` must still agree. Then
delete the function and rebuild. **If you only do one verification in this stage, do this one:**
it is the only test that exercises the failure the whole design exists to prevent.

**Check 6 — the walk terminates cleanly.** Count the backtrace lines: there must be at least two
and fewer than `MAX_FRAMES`. A backtrace that stops at exactly 32 frames is not terminating —
it is being cut off by the bound, which means the frame chain is garbage and the sanity check
did not catch it. Confirm the last line is either a real frame in `kmain` or a single
`<no symbol>`; either is a clean end.

**Check 7 — reproducibility.**

```sh
sha256sum build/kernel/generated/ksyms.cpp
make clean && make
sha256sum build/kernel/generated/ksyms.cpp
```

Identical. A difference means non-determinism leaked into the generator — the usual culprit is
iterating the `unordered_map` instead of the sorted vector.

### Only checkable later

- **A real CPU fault producing a named backtrace** — Stage 2.3, once exception handlers call
  `panic` with a real frame.
- **Frames through interrupt entry stubs** — [[Phase 2 - Overview|Phase 2]]. Assembly stubs
  build no frame, so the walk stops at that boundary until they push a synthetic one. The
  `<no symbol>` marker is how you will recognise it.
- **`.ksyms` mapped read-only by the page tables** — [[Phase 4 - Overview|Phase 4]]. Until then
  the section is read-only by convention only.
- **Symbolised lock-acquisition sites** — [[Phase 12 - Overview|Phase 12]]'s lock-rank checking
  wants a name for the acquiring function, and it gets it from here.

- [ ] `make` shows two links and one `symbolise:` line
- [ ] `build/kernel/generated/ksyms.cpp` is readable and its addresses are sorted
- [ ] `.ksyms` is `PROGBITS`, alloc, **not** writable, after `.bss`
- [ ] `readelf -l` shows five `LOAD` segments
- [ ] The stage-one/final `.text` symbol `diff` is empty
- [ ] A `static` function appears in the table
- [ ] A test panic names every frame with a small, plausible offset
- [ ] `addr2line` on `printed_address - 1` reports the same function the kernel printed
- [ ] `scripts/symbolise.sh` appends `file:line` to every frame
- [ ] Adding a function, rebuilding, and re-running all of the above still passes
- [ ] Two clean builds produce an identical `ksyms.cpp`
- [ ] Test panic removed; the machinery stays

---

## 7. Common traps

**"Every symbol is off by a constant — the names are real functions, just the wrong ones."**
The chicken-and-egg bug, and the reason this stage is Hard. The table was generated from a link
whose addresses the final image does not have. Three causes, in order of likelihood. `.ksyms`
is not the last section — check the `SECTIONS` block, and check that the generated file's
objects really carry `section(".ksyms")` rather than falling into `.rodata` because someone
edited the `KSYMS` macro. The generated file emitted something into `.text` — anything at all,
even one inline function — which shifts every function after it. Or the two links do not use the
same objects and the same flags: verify the `foreach` in `kernel/CMakeLists.txt` applies
identical `target_link_options` to both, and that `target_compile_options` on `kernel_objs` is
`PUBLIC`. The diagnosis is one command, the `nm`/`diff` check in §6, and it should be in CI so
this is never diagnosed by hand twice.

Why it is dangerous rather than merely wrong: it produces *plausible* output. A shifted lookup
names the function immediately before the real one — a real symbol, a real address, a sensible
offset. You will read it, believe it, and debug the wrong code. There is no symptom other than
"the bug is not where the backtrace says".

**"The backtrace faults inside panic and the machine reboots — I am back to the silent loop."**
The worst outcome in the project, because it destroys the message that was already on its way
out. It is almost never the frame walk itself, which Stage 0.7 already hardened; it is the new
code. Three candidates. `symbol_lookup` was called on an address the loop had not yet validated
— it must come after `text_is_plausible(ret)`, never before. The bounds check on
`ksyms_name_off[idx]` was dropped as "impossible", and a corrupt table then sent `put()`
walking through unmapped memory looking for a NUL. Or `lo = mid` was written instead of
`lo = mid + 1`, so the search never terminates and the kernel hangs rather than faulting —
which looks identical from outside. Diagnose by commenting out the `symbol_lookup` call and
printing raw addresses: if the panic completes, the problem is in `symbols.cpp`, and the
binary search is where to look first.

**"Names print as `_Z11heap_expandm`."** The demangler did not run. Either `strip_params`/
`demangle` is not being called in the ingest path, or `__cxa_demangle` returned non-zero
`status` and the fallback correctly kept the mangled form. Check by hand:

```sh
echo '_Z11heap_expandm' | c++filt
```

If `c++filt` demangles it and your tool does not, the `rfind("_Z", 0) != 0` guard is rejecting
it — usually because the name still has a leading space from a sloppy parse, so it does not
start with `_Z` at index 0. Print the name before demangling to confirm. If `c++filt` also
fails, the symbol genuinely is not Itanium-mangled and the mangled form is the correct output.
`extern "C"` symbols such as `kmain` and `panic` never had a prefix and are unaffected either
way — if *those* look right and only C++ ones look wrong, this is your trap.

**"The lookup returns the wrong function, but only for addresses right at a function's start."**
The binary-search off-by-one. The predicate is `<` instead of `<=`, so an address exactly equal
to a symbol's start disqualifies that symbol and the search returns the previous one. It is
invisible in ordinary use — most frame addresses are somewhere in the middle of a function —
and it shows up on `+0x0` frames, which are exactly the ones produced by a call as the first
instruction of a function and by the synthetic frames Phase 2 will add. The related mistakes
have different signatures: `hi = mid - 1` skips a candidate and gives a wrong answer at
arbitrary offsets; `lo = mid` hangs forever inside `panic`. Test it deliberately — take an
address straight from the `ksyms_addr` array and confirm it resolves to that entry with offset
`0`.

**"Symbols work in Debug and vanish in Release."** Three separate causes with one symptom, so
check them in order. **`--gc-sections`** was added to shrink the release image and collected
`.ksyms`, because nothing reaches it through a relocation — the fix is `KEEP()` in the linker
script plus `used` on the objects, both of which §5 specifies and neither of which is optional;
confirm with `readelf -S | grep ksyms`. **The link was stripped** (`-s`, or a `strip` step in a
release script), so `nm` on the stage-one image finds nothing — the tool's `MIN_SYMBOLS` check
turns this into a build failure with the word "stripped" in it, which is why that check exists;
if you removed it, the symptom is a table with zero entries and a panic that prints
`(no symbol table in this image)`. **`-g` is missing**, in which case the *names* still work
perfectly — they come from `.symtab`, not from DWARF — but `scripts/symbolise.sh` reports
`??:0` for everything. That third one is the common case, and it is why `-g` is in
`KERNEL_CXX_FLAGS` unconditionally rather than only in the Debug configuration.

**"`undefined reference to 'ksyms_count'` and four friends."** The generated file's definitions
have internal linkage. Either the `extern "C"` block was dropped from the emitter, or someone
"cleaned up" the generated file by removing it. A namespace-scope `const` in C++ has internal
linkage unless it is declared `extern` or is directly contained in a linkage-specification —
`extern "C"` supplies the second. It is not decoration and it is not about the compiler being
C++ rather than C.

**"The build hangs, or Ninja says `'build/host-tools/bin/symbolise' ... missing and no known
rule to make it`."** `BUILD_BYPRODUCTS` in `ExternalProject_Add` does not list `${SYMBOLISE}`.
Ninja will not generate a graph containing a file nothing declares as an output, even when that
file demonstrably gets built. Add it next to `${MKFONT}`.

**"I added a source file and the table did not update."** The custom command's `DEPENDS` is
missing `$<TARGET_FILE:kernel.stage1.elf>`, so the generator only re-runs when the *tool*
changes, not when the kernel does. This is the same class of bug as the font not regenerating
in [[Stage 1.2 - Rasterising a Bitmap Font]], and it produces the off-by-a-constant failure at
the top of this list.

**"QEMU boots something that has no symbol table at all."** You pointed `mkimage.sh` at
`kernel.stage1.elf`, or copied it by hand while debugging. The stage-one image is scaffolding:
its table is empty by construction and its `__kernel_end` under-reports the image, which will
make the Phase 4 frame allocator hand out pages the kernel is running from. Only `kernel.elf`
is ever bootable. The `(no symbol table in this image)` line in the panic output exists mostly
to tell you this has happened.

**"`error: .ksyms causes a section type conflict`."** Something non-`const` was put in
`.ksyms`, so GCC wants the section writable while the rest of it is read-only. Fix the
declaration rather than the section flags: a writable symbol table is one that a wild pointer
can rewrite, and the whole value of this table is that it is trustworthy when nothing else is.

**"The linker warns about orphan sections after adding `-g`."** If you enabled
`--orphan-handling=warn`, the `.debug_*` sections are now orphans because the script does not
name them. They are non-`SHF_ALLOC` and land outside every segment, so this is noise rather
than a bug — either add an explicit `.debug_*` block to the script or leave the warning. Do
**not** add them to `/DISCARD/`; that throws away the DWARF the offline pass needs.

---

## 8. What this unlocks

This is the last piece of the debugging surface, and everything after it is built on top.
[[Phase 2 - Overview|Phase 2]]'s exception handlers call `panic` with a real register frame,
and this stage is what makes their output legible — a `#PF` at an address that names
`vmm_map_page+0x1C` is a bug report; the same fault as raw hex is a research project. The
`<no symbol>` marker is how you will discover, on your first interrupt, that assembly stubs
build no stack frame. [[Phase 4 - Overview|Phase 4]] is where it pays for itself: allocator
bugs surface far from their cause, and a named backtrace is the only cheap way to see the call
chain that reached a corrupt free list. [[Phase 12 - Overview|Phase 12]]'s lock-rank checking
reports "lock A acquired after lock B" and needs a function name for each acquisition site,
which it takes from `symbol_lookup`. And [[Stage 0.9 - CI From Day One]] gains logs that a
reviewer can act on without downloading a binary.

Done wrong, the failures are quiet in the way that costs the most. A table built against the
wrong link names real functions confidently and wrongly, and the only symptom is that your bugs
are never where the backtrace says — a state you can stay in for weeks, because the natural
conclusion is "backtraces are unreliable" rather than "the table is shifted". A missing bounds
check turns the panic handler into the thing that faults, which returns you to the silent
reboot loop [[Stage 0.7 - Panic and KASSERT]] existed to remove, with an extra layer of
misdirection on top. And a `.ksyms` section that `--gc-sections` can eat will work perfectly
until the day somebody optimises the image for size, at which point every panic in the project
quietly loses its names.

---

## 9. Reading

- Linux — `kernel/kallsyms.c`: <https://elixir.bootlin.com/linux/latest/source/kernel/kallsyms.c>
  The production version of `symbol_lookup`. Read `kallsyms_lookup_address` — it is the same
  "greatest address ≤ target" search, over a table compressed far harder than ours.
- Linux — `scripts/kallsyms.c`: <https://elixir.bootlin.com/linux/latest/source/scripts/kallsyms.c>
  The production version of `tools/symbolise`, including the token-based compression that gets
  a 5 MB name table down to under 1 MB. Read it after this stage, not before.
- Linux — `scripts/link-vmlinux.sh`: <https://elixir.bootlin.com/linux/latest/source/scripts/link-vmlinux.sh>
  Option B from §3 in production: link, generate, link again, and *check that the result
  converged*. Worth reading to see what the padded-placeholder approach costs in practice.
- binutils — `nm`: <https://sourceware.org/binutils/docs/binutils/nm.html>
  The authoritative list of type letters. §2.2's table is a subset; read the full one before
  widening the filter.
- binutils — `addr2line`: <https://sourceware.org/binutils/docs/binutils/addr2line.html>
  Short. The `-i` flag and what it means for inlined frames is the part that matters.
- binutils — the `ld` manual, *SECTIONS* and *Input Section Keep*:
  <https://sourceware.org/binutils/docs/ld/>
  What `KEEP()` actually does to the `--gc-sections` reachability graph.
- Itanium C++ ABI, §5.1 *External Names* (the mangling grammar):
  <https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling>
  Read enough to decode `_Z11heap_expandm` by hand once. It makes the decision to demangle on
  the host obvious.
- libstdc++ — *Demangling*: <https://gcc.gnu.org/onlinedocs/libstdc++/manual/ext_demangling.html>
  The `abi::__cxa_demangle` contract, including every `status` value.
- DWARF 5 standard: <https://dwarfstd.org/doc/DWARF5.pdf>
  Section 6.2, *Line Number Information*. Skim the state machine and the special-opcode
  encoding — that is §2.4's argument in its original form, and ten minutes there is worth more
  than any summary.
- ELF specification, *Symbol Table*: <https://refspecs.linuxfoundation.org/elf/elf.pdf>
  Figure 1-16 onward: `Elf64_Sym`, the type/binding encoding, and the section-index rules.
- OSDev — *Stack Trace*: <https://wiki.osdev.org/Stack_Trace>
  The frame walk this stage decorates, and a short section on symbol lookup.
- [[Stage 0.7 - Panic and KASSERT]] — the eight-step panic ordering, the frame validation
  predicates, and the frame-pointer-versus-DWARF argument this stage extends.
- [[Stage 0.8 - The Build System]] — the three-toolchain rule that makes a host tool possible,
  and where `kernel.sym` comes from.
- [[Stage 0.4 - The Linker Script and Higher-Half Layout]] — `KEEP()`, `PHDRS`, and the section
  ordering the chicken-and-egg fix depends on.
- [[Stage 1.2 - Rasterising a Bitmap Font]] — the host-tool-plus-generated-source pattern this
  stage reuses wholesale.
- [[14 - Debugging Playbook]] — the panic format this stage completes, and the symptom table it
  finally makes usable.

Previous: **[[Stage 1.6 - kprintf]]** · Next: **[[Phase 2 - Overview]]**

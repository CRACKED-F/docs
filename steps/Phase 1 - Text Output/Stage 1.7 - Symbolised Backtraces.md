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

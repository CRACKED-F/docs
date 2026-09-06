# Stage 0.4 — The Linker Script and Higher-Half Layout

**Difficulty:** Hard · ~90 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `kernel/arch/x86_64/boot/linker.ld`
**Deliverable:** `kernel.elf` links at `0xFFFFFFFF80000000` with four page-aligned, separately-permissioned `PT_LOAD` segments, a surviving `.limine_requests` section, and boundary symbols the PMM and VMM will consume in [[Phase 4 - Overview|Phase 4]].

---

## Progress

- [ ] Re-read the memory-layout diagram in [[06 - Architecture Overview]] and the linker-script requirements in [[08 - Build System]]
- [ ] Create `kernel/arch/x86_64/boot/linker.ld` with `OUTPUT_FORMAT`, `OUTPUT_ARCH`, and `ENTRY(kmain)`
- [ ] Declare four `PHDRS` with explicit `FLAGS()` — requests RW, text R E, rodata R, data RW
- [ ] Set the location counter to `0xFFFFFFFF80000000`
- [ ] Place `.limine_requests` first, with `KEEP()` on all three marker sections
- [ ] Page-align and place `.text`, `.rodata`, `.init_array`, `.fini_array`, `.data`, `.bss` — in that order
- [ ] Reserve the kernel boot stack and its guard page at the end of `.bss`
- [ ] Export `__kernel_start/end`, `__text_start/end`, `__rodata_start/end`, `__data_start/end`, `__bss_start/end`, `__stack_bottom/top`
- [ ] Discard `.eh_frame`, `.note.*`, `.comment`
- [ ] Link with `-z max-page-size=0x1000 --build-id=none --orphan-handling=warn`
- [ ] `readelf -l` shows four `LOAD` segments at `0xffffffff80...`, alignment `0x1000`, flags `RW` / `R E` / `R` / `RW`
- [ ] `readelf -h` entry point equals the `kmain` address reported by `nm`
- [ ] `readelf -S` shows `.limine_requests` present and non-empty, and `.bss` typed `NOBITS`
- [ ] Committed with a message like `feat(boot): higher-half linker script at 0xFFFFFFFF80000000`

---

## 1. Why this stage exists

You have object files. `entry.o` contains `kmain` and the Limine requests; `boot_info.o` and `main.o` contain the rest. Every one of them is a *relocatable* object: the code inside refers to functions and globals by name, with a placeholder where the address should go, and a list of "patch this offset with the address of that symbol" instructions. Nothing in an `.o` file knows where it will live. That is the linker's job, and until you tell the linker where the kernel goes, there is no kernel — only parts.

For a hosted program you never think about this, because the toolchain ships a default linker script that puts your program somewhere sensible for the OS you are targeting. There is no OS here. There is no default that is correct. The kernel has to land at exactly `0xFFFFFFFF80000000`, because that is what `-mcmodel=kernel` — which you have been compiling with since [[Stage 0.1 - Prove Your Toolchain Works|Stage 0.1]] — assumes, and because it is what the Limine x86-64 protocol requires. Link anywhere else and the link itself fails with a wall of `relocation truncated to fit` errors, or worse, succeeds and produces a kernel that triple-faults on its first memory access.

Placement is only half of it. The other half is *permissions*. The kernel's code must be executable and not writable. Its string literals and constants must be readable and neither writable nor executable. Its globals must be writable and not executable. The CPU can enforce all three in hardware through page-table bits, and [[Phase 15 - Overview|Phase 15]] will make it do so — but only if every one of those regions starts and ends on a 4 KiB page boundary. Page permissions have page granularity. If `.text` and `.rodata` share a page, you cannot mark one executable and the other not; you have to pick, and you will pick "both writable and executable", which is the permission set every exploit wants.

The cost of getting this wrong is not a compile error two years from now. It is a *relayout*: changing the section order and alignment of a kernel that already has a PMM reserving `[__kernel_start, __kernel_end)`, a VMM mapping per-section ranges, a backtrace symboliser resolving addresses, and a linker-script-defined per-CPU area. Every one of those has to be re-verified. Ten minutes of alignment now buys a week later. That is the whole argument for doing this properly at stage four rather than patching it in at phase fifteen.

---

## 2. The concept

### What a linker actually does

Three jobs, in order.

**1. Symbol resolution.** Each object file carries a symbol table: symbols it *defines* (`kmain`, `g_boot_info`) and symbols it *references but does not define* (`kernel_init`, `collect_boot_info`). The linker builds one global table, matches every undefined reference to exactly one definition, and errors if a symbol is missing (`undefined reference to ...`) or defined twice (`multiple definition of ...`).

**2. Section placement.** Every object file is a bag of *sections*: `.text` (machine code), `.rodata` (constants), `.data` (initialised globals), `.bss` (zero-initialised globals, which occupy no bytes in the file), plus whatever else the compiler emitted. The linker gathers all the input sections with the same role, concatenates them into *output sections*, and assigns each output section a final virtual address. **This is the part the linker script controls.** Without a script the linker uses a built-in default; with one, you decide.

**3. Relocation.** Once addresses are final, the linker walks the relocation list in each object and patches the placeholders. `call kernel_init` had a zero where the target offset goes; now it gets the real one. This is where a wrong link address turns into a hard error, because most x86-64 relocations cannot encode an arbitrary 64-bit address — see §3.

```
  entry.o        main.o        boot_info.o
  ┌────────┐    ┌────────┐    ┌────────┐
  │ .text  │    │ .text  │    │ .text  │       1. resolve symbols
  │ .rodata│    │ .rodata│    │ .data  │       2. concatenate + place
  │ .limine│    │ .bss   │    │ .bss   │       3. patch relocations
  └───┬────┘    └───┬────┘    └───┬────┘
      └─────────────┼─────────────┘
                    ▼   linker.ld says where
            ┌───────────────────┐
            │    kernel.elf     │
            └───────────────────┘
```

### Sections versus segments — and why the loader only cares about one of them

An ELF file has **two independent views of the same bytes**, described by two different tables.

The **section header table** is the *linking* view. It is fine-grained — `.text`, `.rodata`, `.data`, `.bss`, `.symtab`, `.debug_info`, `.comment` — and it is what the linker, `objdump`, `nm`, and GDB read. It is not needed at run time. You can strip it entirely and the program still runs.

The **program header table** is the *execution* view. Each entry is a **segment** (`PT_LOAD`, `PT_NOTE`, …), and each `PT_LOAD` segment says: *take `p_filesz` bytes starting at file offset `p_offset`, place them at virtual address `p_vaddr`, make the region `p_memsz` bytes long (zero-filling any excess), and map it with permissions `p_flags`.* A bootloader or program loader reads **only** the program headers. It does not know or care that `.text` and `.rodata` are different things; it knows that segment 1 is `R E` and segment 2 is `R`.

```
 sections (linking view)          segments (execution view)
 ────────────────────────         ───────────────────────────
 .limine_requests   ──────────►   PT_LOAD  RW   ← Limine writes here
 .text              ──────────►   PT_LOAD  R E
 .rodata            ──────────►   PT_LOAD  R
 .init_array  ──┐
 .fini_array  ──┼─────────────►   PT_LOAD  RW   (p_memsz > p_filesz)
 .data        ──┤
 .bss         ──┘
 .symtab  .strtab  .shstrtab      (not in any segment — not loaded)
```

**Everything in this stage follows from that picture.** A page cannot have two permission sets, and a segment is what carries permissions, so *sections that need different permissions must go in different segments*, and *segments must not share a page*. That is why the alignment matters, and it is why the `PHDRS` block exists in the script at all: without it, GNU `ld` invents segments for you by merging sections with compatible flags, and you get an `RWX` blob.

### Higher half, in one picture

x86-64 in 4-level paging mode has 48 significant address bits, sign-extended to 64. Addresses must be *canonical*: bits 63–48 must all equal bit 47. That splits the address space into two usable halves with a vast non-canonical hole between them, and the hardware faults on any address in the hole.

```
0xFFFFFFFFFFFFFFFF ┌───────────────────────────────┐ ─┐
                   │                               │  │ top 2 GiB
0xFFFFFFFF80000000 │ KERNEL IMAGE  ← this stage    │ ─┘ -mcmodel=kernel
                   ├───────────────────────────────┤
0xFFFF800000000000 │ HHDM — direct map of all RAM  │
                   ├───────────────────────────────┤
                   │ ##### non-canonical hole #### │ faults on touch
                   ├───────────────────────────────┤
0x0000800000000000 │ USER SPACE                    │
0x0000000000000000 └───────────────────────────────┘
```

Full layout in [[06 - Architecture Overview]]. Two properties matter here:

- **The kernel is mapped into every address space.** A syscall or interrupt from a user process runs kernel code without switching page tables — only the lower half changes on a context switch. If the kernel lived in the lower half it would either collide with user programs or force a full address-space switch on every trap.
- **The whole lower half belongs to user space.** 128 TiB, no carve-outs, no "kernel starts at 0xC0000000 so your program stops there" limit.

### The thing that makes this stage x86-64-specific

Almost every x86-64 instruction that names a memory address encodes it as a **32-bit field**. `mov eax, [g_counter]` has four bytes for the address, not eight. The CPU sign-extends those four bytes to 64 bits. Sign extension of a 32-bit value reaches exactly two ranges:

```
  0x00000000  .. 0x7FFFFFFF   →  0x0000000000000000 .. 0x000000007FFFFFFF   (low 2 GiB)
  0x80000000  .. 0xFFFFFFFF   →  0xFFFFFFFF80000000 .. 0xFFFFFFFFFFFFFFFF   (top 2 GiB)
```

That is where `0xFFFFFFFF80000000` comes from. It is not a convention or a tradition. It is the lowest address from which a sign-extended 32-bit immediate can reach every byte of the kernel. `-mcmodel=kernel` tells GCC "you may assume all code and data live in the top 2 GiB", and GCC then emits the short, fast, absolute forms. Link the kernel one byte below that boundary and the assumption is false, and the linker says so.

---

## 3. Design decisions and tradeoffs

### Decision: where does the kernel link?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. Higher half at `0xFFFFFFFF80000000` (chosen)** | Top 2 GiB; kernel mapped in every address space | Must understand canonical addressing; no low-memory identity map by default | ✅ |
| B. Identity-mapped low kernel (e.g. `0x100000`) | Kernel at 1 MiB, virtual == physical | Steals the low address space from every user process; needs a per-trap page-table switch or a shared low mapping | ❌ |
| C. Higher half elsewhere (e.g. `0xFFFF800000000000`) | Still upper half, but not the top 2 GiB | Incompatible with `-mcmodel=kernel`; collides with our HHDM | ❌ |

**Why A.** Three independent reasons converge on it.

*Addressing.* It is the base `-mcmodel=kernel` assumes. Every global access becomes a 32-bit displacement instead of a 10-byte `movabs`. Smaller code, fewer instruction-cache misses, no per-reference register pressure.

*Address-space economy.* The kernel occupies the upper half of every process's page tables. User space gets the entire lower half — 128 TiB — with no ceiling to explain and no `TASK_SIZE` constant to get wrong. When a syscall arrives, kernel code and kernel data are already mapped; the CPU switches privilege level and nothing else.

*The bootloader requires it.* Limine's x86-64 protocol specifies the kernel be linked in the topmost 2 GiB. Check `PROTOCOL.md` for the pinned `v8.6.0-binary` release if you want the exact wording — but it matches what `-mcmodel=kernel` needs anyway, so there is no tension.

**Why not B.** An identity-mapped kernel at `0x100000` means every user process either has the kernel sitting inside its own low address space (so a bug in user code can name kernel addresses, and `mmap` has a hole in the middle of the range programs expect to be free), or the kernel gets its own address space and every syscall and interrupt pays a `CR3` write plus a TLB flush. On modern parts that is hundreds of cycles per trap, on the hottest path in the system. It is also *not* what `-mcmodel=kernel` compiles for, so you would drop to `-mcmodel=small`, and then the kernel could never address anything above 2 GiB directly.

**Why not C.** `0xFFFF800000000000` is a perfectly good canonical upper-half address, and it is where our HHDM lives — which is the point: the direct map needs a large contiguous region, and putting the kernel image inside it is asking for a collision. More decisively, a 32-bit sign-extended field cannot reach `0xFFFF8000...`, so `-mcmodel=kernel` code linked there produces exactly the failure in §7.

**When B would be right.** A bootstrap loader, a UEFI application, a hypervisor payload that must run before paging is under your control — anything that runs identity-mapped by construction and never coexists with user address spaces. Some microkernels also identity-map because their kernel is a few tens of kilobytes and never needs the upper half. Neither describes this project.

---

### Decision: which code model — `kernel`, `large`, or PIE?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. `-mcmodel=kernel` (chosen)** | Assumes all code and data in the top 2 GiB; 32-bit sign-extended displacements (`R_X86_64_32S`) | Link address is fixed at `0xFFFFFFFF80000000`; libgcc is built for a different model | ✅ |
| B. `-mcmodel=large` | No assumptions; every symbol address materialised with a 64-bit `movabs`, calls become indirect | Every global reference costs 10 bytes and a register; no direct `call rel32` | ❌ |
| C. PIE / `-fpic` | Position-independent; addresses reached through a GOT, fixed up at load | You must implement the relocation processing yourself, at boot, before you have any memory management | ❌ |

**Why A.** It is the fastest and smallest option, and the constraint it imposes — "link in the top 2 GiB" — is a constraint we wanted anyway. The generated code for `g_counter++` is one instruction with a four-byte displacement. There is no indirection, no GOT, no load-time work, and nothing to initialise before C++ can run. It is what Linux uses, which also means every piece of reference material and every compiler bug report applies directly.

**Why not B.** `-mcmodel=large` works at *any* link address, which sounds like freedom until you look at the code. Every access to a global becomes `movabs rax, <64-bit address>` followed by a dereference: ten bytes instead of six or seven, plus a scratch register burned per reference. Function calls within the kernel stop being `call rel32` and become load-then-`call rax`, which defeats the branch predictor's static hints. On the interrupt path — which runs millions of times a second and is the code you least want to slow down — this is a measurable, permanent tax for flexibility you will never use, because the kernel's link address is not going to change.

**Why not C.** Position-independent code moves the address problem to run time. A PIE kernel has a `.dynamic` section, a GOT, and a list of `R_X86_64_RELATIVE` relocations that *something* must walk and apply before the first global access works. That something would be a hand-written assembly routine running before `kmain`, with no stack discipline, no output, and no way to assert. When it is wrong, the symptom is a fault at an address that appears nowhere in your source. You would be writing and debugging a dynamic loader as stage four of phase zero, in exchange for a relocatability nobody asked for.

**When C would be right.** KASLR. If you want to randomise the kernel base at boot to make an attacker guess where the kernel is (listed as a hardening option in [[Phase 15 - Overview|Phase 15]]), you need either a PIE kernel or a relocation table you apply yourself. That is a real reason, and it is a Phase 15 conversation — after there is something worth protecting, and after the boot path is boring enough to extend safely.

> **The libgcc caveat.** Our toolchain image builds `all-target-libgcc`, and the kernel links against it for helpers like 128-bit division. That `libgcc.a` is compiled with the *default* code model and *with* the red zone — not `-mcmodel=kernel -mno-red-zone`. In practice hobby kernels link it and it works, because the helpers are small, leaf-ish, and mostly self-referential. But if you ever see a `relocation truncated to fit` error whose symbol lives in `libgcc.a`, this is why. The fix is to build a second libgcc with kernel flags; OSDev documents it under *Libgcc without red zone*.

---

### Decision: 4 KiB-align every section, or pack them tight?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. Page-align `.text`, `.rodata`, `.data`, `.bss` (chosen)** | `. = ALIGN(4K)` between regions; each gets its own `PT_LOAD` | Up to ~4 KiB padding per boundary — about 12 KiB total | ✅ |
| B. Pack, align only as the compiler asks | Sections abut at 16- or 32-byte boundaries | One `RWX` segment; W^X becomes impossible without a relayout | ❌ |
| C. Align to 2 MiB (`CONSTANT(MAXPAGESIZE)` default) | Every region on a huge-page boundary | Up to 8 MiB of padding; enables huge-page kernel mappings | ❌ for now |

**Why A.** Permissions have page granularity, full stop. The CPU's page-table entries carry one writable bit and one no-execute bit per 4 KiB page. If the last byte of `.text` and the first byte of `.rodata` share a page, that page must be both executable and part of your read-only data — so you either mark rodata executable or mark text non-executable, and neither is acceptable. Aligning to 4 KiB is what makes the sentence "text is `R E`, rodata is `R`, data is `RW NX`" *expressible*.

The cost is padding: on average half a page per boundary, four boundaries, so a few kilobytes of zeros in a kernel image measured in hundreds of kilobytes. That is not a cost, it is a rounding error.

**Why not B.** Because "we will align it later" is not a small change. By the time W^X matters you have: a PMM reserving `[__kernel_start, __kernel_end)` and asserting the range is page-aligned; a VMM mapping `[__text_start, __text_end)` with specific flags; a backtrace symboliser that classifies an address by which range it falls in; a `.init_array` walker; and, by Phase 12, per-CPU regions carved from the same script. Changing the layout shifts every symbol, which means every one of those consumers must be re-verified, and the failure mode of getting one wrong is a fault in an unrelated subsystem months later. Compare that to typing `. = ALIGN(PAGE_SIZE);` four times today. [[Phase 15 - Overview|Phase 15]] says the same thing from the other end.

**Why not C.** 2 MiB alignment is what GNU `ld` does by *default* on x86-64 — `CONSTANT(MAXPAGESIZE)` is `0x200000` unless you say otherwise — and it is genuinely useful later, because a 2 MiB-aligned `.text` can be mapped with a single huge page instead of 512 small ones, saving TLB entries. But right now it would waste up to 8 MiB of physical memory on a kernel that is a few hundred kilobytes, for a benefit that only appears once the VMM in [[Phase 4 - Overview|Phase 4]] is sophisticated enough to choose page sizes. We take 4 KiB now by passing `-z max-page-size=0x1000`, and revisit if TLB pressure ever shows up in a profile.

**When C would be right.** A kernel with a multi-megabyte text section, or one where you have measured iTLB misses and found them to matter. Linux maps its kernel text with huge pages for exactly this reason.

---

### Decision: `KEEP()` on `.limine_requests` and `.init_array` — belt *and* braces?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. `__attribute__((used))` in C++ **and** `KEEP()` in the script (chosen)** | Compiler is told not to delete the object; linker is told not to garbage-collect the section | Two places to remember | ✅ |
| B. `used` only | Compiler keeps it; linker may still collect it under `--gc-sections` | Breaks silently the day someone adds `--gc-sections` for size | ❌ |
| C. `KEEP()` only | Linker keeps whatever arrives; compiler may never emit it | Breaks now — the object never reaches the linker | ❌ |
| D. `__attribute__((retain))` | Sets `SHF_GNU_RETAIN`; the linker keeps it without a `KEEP()` | Needs GCC ≥ 11 and binutils ≥ 2.36 (we have both); the guarantee is spread across source files instead of stated once | ➖ viable |

**Why A.** These are two different tools defending against two different deletions, and neither substitutes for the other.

`--gc-sections` makes the linker treat sections as nodes in a graph. It starts from a set of *roots* — the `ENTRY()` symbol, anything named by `-u`, and every section wrapped in `KEEP()` — follows relocations to find reachable sections, and discards the rest. It is a real win with `-ffunction-sections -fdata-sections`, and someone on this project will eventually turn it on to shrink the image.

The Limine request structs are the pathological case: **nothing in the kernel ever reads them by name.** The bootloader finds them by scanning the image for their 128-bit magic IDs. To the compiler they are globals with initialisers that nobody references; to the linker they are a section with no incoming relocations. Both are entitled to delete them, and the resulting kernel is one Limine cannot serve — every response pointer null, or the kernel not recognised at all. `used` stops the compiler. `KEEP()` stops the linker. Remove either and the failure is silent, distant, and hard to attribute.

`.init_array` is the same shape. It is a table of function pointers to global constructors; the *entries* are referenced by nothing until step 11 of the init order in [[06 - Architecture Overview]] walks them. Left unprotected, the section can disappear and your constructors quietly never run.

**Why not B or C.** Each covers one of the two deletions. `KEEP()` cannot resurrect an object the compiler never emitted; `used` cannot stop `--gc-sections` from dropping the section afterwards. Note also that `used` on a `static` object is what makes the compiler emit it at all — see [[Stage 0.2 - The Limine Request Section]], where it is already applied.

**When D would be right.** If you dislike having the guarantee split between the source and the script, `__attribute__((retain))` puts it entirely in the source: the object is marked `SHF_GNU_RETAIN` and the linker honours it without a `KEEP()`. It is a legitimate modern choice. We use `KEEP()` because the linker script is the one file where the whole layout contract is written down, and "these sections must survive" belongs in the contract.

---

### Decision: which boundary symbols to export, and does `.bss` need zeroing?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. Export start/end for the image and every region (chosen)** | Linker defines `__kernel_start/end`, `__text_start/end`, … | Ten-ish symbols to keep in sync with the section list | ✅ |
| B. Export only `__kernel_start` / `__kernel_end` | Enough for the PMM to reserve the image | VMM cannot set per-section permissions; W^X impossible | ❌ |
| C. Hardcode addresses in C++ | `constexpr uintptr_t KERNEL_START = 0xFFFFFFFF80000000;` | Wrong the moment anything moves; end address unknowable | ❌ |

**Why A.** Each symbol has a named consumer, and the list is short enough to be worth writing out:

| Symbol pair | Consumed by | For what |
|---|---|---|
| `__kernel_start` / `__kernel_end` | PMM, [[Phase 4 - Overview\|Phase 4]] | Reserve the kernel image so the frame allocator never hands out a page the kernel is running from |
| `__text_start` / `__text_end` | VMM (Phase 4), W^X (Phase 15), backtrace symboliser (Phase 1) | Map `R X`, no write; decide whether a return address is kernel code |
| `__rodata_start` / `__rodata_end` | VMM | Map `R`, no write, no execute |
| `__data_start` / `__data_end` | VMM | Map `RW`, no execute |
| `__bss_start` / `__bss_end` | VMM; optional boot-time zeroing | Map `RW`, no execute; the range to `memset` if you choose to |
| `__init_array_start` / `__init_array_end` | Global-constructor walker, step 11 of the init order | Iterate the function-pointer table |
| `__stack_bottom` / `__stack_top` | Boot stack switch; guard-page mapping in Phase 4 | `rsp` starts at `__stack_top`; the page below `__stack_bottom` stays unmapped |

Option C fails on the end addresses alone: the size of the kernel image is not knowable until link time, and the PMM absolutely must reserve the real extent. Under-reserve and the allocator eventually hands out a page containing live kernel code; the symptom is corruption in a subsystem chosen effectively at random.

**On zeroing `.bss` — be careful here.** The rule in the ELF gABI is that for a `PT_LOAD` segment where `p_memsz > p_filesz`, the loader must treat the excess bytes as zero. `.bss` is exactly that excess: it is `SHT_NOBITS`, occupies no file bytes, and exists only as the difference between the last segment's file size and memory size. Limine loads standard ELF64 and implements these semantics, so on a correct layout your globals *are* zero when `kmain` starts.

Two honest qualifications:

1. **The guarantee is per-segment and positional.** It covers the tail of a `PT_LOAD` whose `p_memsz` exceeds its `p_filesz`. If `.bss` is not the last allocated section in its segment, the linker must materialise it as real zero bytes in the file — the ELF grows by the size of your `.bss`, which is why `.bss` is placed last in `:data` below. If `.bss` somehow ended up outside a `PT_LOAD` entirely, nothing zeroes it and nothing maps it.
2. **Verify it, do not assume it.** Add a `static volatile uint64_t g_bss_probe;` and check it reads zero once you have serial output in [[Stage 0.6 - Serial Output]]. That is a two-line test against a whole class of ghost bugs.

If you want a belt-and-braces `memset(__bss_start, 0, __bss_end - __bss_start)` at the very top of `kmain`, it is harmless and cheap — **provided you understand one thing**: Limine has already written response pointers into the request structs by the time your code runs. Those structs live in `.limine_requests`, not `.bss`, because they have non-zero initialisers (the magic IDs), so zeroing `.bss` cannot clobber them. If you ever move a bootloader-written object into `.bss`, that stops being true and the zeroing destroys it. This is precisely the kind of thing to reason about rather than to copy.

---

### Decision: where does the kernel stack live, and is a guard page worth it?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A. Reserve it in `.bss` from the linker script, with a guard page below (chosen)** | `. = . + PAGE_SIZE` for the guard, then `. = . + 64K` for the stack; symbols exported | 68 KiB of `p_memsz`, zero file bytes; the guard is only *reserved* until Phase 4 | ✅ |
| B. A C++ array: `alignas(4096) static uint8_t stack[65536];` | Same memory, declared in source | No natural place for the guard page; alignment and the "which end is the top" question move into C++ | ➖ |
| C. Keep using the stack Limine gave you | Zero work now | It lives in bootloader-reclaimable memory, which Phase 4 will reclaim | ❌ |

**Why A.** The stack is a layout fact, and layout facts belong in the layout file. Putting it there gets you three things for free: it is page-aligned by construction, `__stack_top` and `__stack_bottom` are exported symbols alongside every other boundary, and there is an obvious, syntactically natural place to reserve the guard page — right before the stack, in address order.

Sizing: 64 KiB. For reference, Linux uses 16 KiB per kernel stack on x86-64, and xv6 uses 4 KiB. 64 KiB is generous because it is free — the stack is `NOBITS`, so it costs zero bytes in the ELF and only reserved address space plus the physical pages behind it. When [[Phase 12 - Overview|Phase 12]] brings up secondary CPUs, each gets its own stack and this one becomes the BSP's boot stack.

**Direction, because it is the classic confusion:** the x86 stack grows *downwards*. `__stack_top` is the **highest** address and is the value you load into `rsp`. `__stack_bottom` is the **lowest** address and is the limit you overflow past. The guard page sits **below** `__stack_bottom`. Because `__stack_top` is page-aligned it is also 16-byte aligned, which is what the SysV AMD64 ABI wants at a call boundary — so `mov rsp, __stack_top` followed by a `call` is correctly aligned.

**Why the guard page is worth a page of address space.** Kernel stack overflow is one of the nastiest bugs in the business. Without a guard, the stack simply keeps growing down into whatever is beneath it — your `.bss`, another CPU's stack, a page table — and *silently corrupts it*. The fault appears later, somewhere else, in code that is innocent. With a guard page, the first push past the end touches an unmapped page and raises a page fault immediately, with `rip` pointing at the function that overflowed and `cr2` pointing at the guard. You get a diagnosis instead of a mystery. One page of address space — of 128 TiB — for that trade is not a decision, it is arithmetic.

**Be honest about the sequencing.** In Stage 0.4 the guard page is *reserved, not protected*. Limine maps every `PT_LOAD` segment, so the guard page is currently mapped read-write like the rest of `.bss`, and an overflow will land in it harmlessly rather than faulting. Making it genuinely unmapped requires control of the page tables, and that arrives in [[Phase 4 - Overview|Phase 4]] Stage 4.3. What you get now is the *layout* — a known-address, page-aligned hole with a symbol on each end — so that Phase 4 only has to clear one present bit. In the meantime it still absorbs the first 4 KiB of any overflow into dead space, and you can seed it with a poison pattern and check it later if you want an early warning.

**Why not C.** Limine hands `kmain` a valid stack, which is why [[Stage 0.3 - Freestanding C++ and kmain]] did not need to set one up. But that stack lives in *bootloader-reclaimable* memory — the same category as the response structures — and Phase 4's PMM will reclaim it. Running on a stack whose pages have been added to the free list is a bug with no floor to it. You must switch to your own stack before that happens; reserving it now means the switch is a one-line assembly stub later, not a layout change.

---

## 4. Specification

### Address constants

| Name | Value | Meaning |
|---|---|---|
| `KERNEL_VMA` | `0xFFFFFFFF80000000` | Kernel link base; bottom of the top 2 GiB |
| top of address space | `0xFFFFFFFFFFFFFFFF` | |
| size of the window | `0x0000000080000000` (2 GiB) | Reachable by a sign-extended 32-bit displacement |
| `PAGE_SIZE` | `0x1000` (4 KiB) | Granularity of page permissions |
| `KERNEL_STACK_SIZE` | `0x10000` (64 KiB) | BSP boot stack |
| HHDM base | `0xFFFF800000000000` | Not this stage — [[Phase 4 - Overview\|Phase 4]] |

### ELF segment flags (`p_flags`)

| Bit | Name | Value |
|---|---|---|
| 0 | `PF_X` — execute | 1 |
| 1 | `PF_W` — write | 2 |
| 2 | `PF_R` — read | 4 |

Combinations used: `FLAGS(4)` = `R`, `FLAGS(5)` = `R E`, `FLAGS(6)` = `RW`. `FLAGS(7)` = `RWX` is what you get by accident and must never appear.

### The segments this script produces

| PHDR | Sections | `FLAGS` | `readelf -l` shows | Why |
|---|---|---|---|---|
| `requests` | `.limine_requests` | 6 | `RW` | Limine writes response pointers into these structs |
| `text` | `.text` | 5 | `R E` | Code: executable, never writable |
| `rodata` | `.rodata` | 4 | `R` | Constants and string literals: no write, no execute |
| `data` | `.init_array`, `.fini_array`, `.data`, `.bss` | 6 | `RW` | Mutable state: no execute |

### Exported symbols

| Symbol | Alignment | Notes |
|---|---|---|
| `__kernel_start` | 4 KiB | `== KERNEL_VMA` |
| `__kernel_end` | 4 KiB | Exclusive upper bound of the whole image |
| `__text_start` / `__text_end` | 4 KiB | `__text_end == __rodata_start` |
| `__rodata_start` / `__rodata_end` | 4 KiB | `__rodata_end == __data_start` |
| `__data_start` / `__data_end` | 4 KiB | Covers `.init_array`, `.fini_array`, `.data` |
| `__bss_start` / `__bss_end` | 4 KiB | `__bss_end == __kernel_end` |
| `__init_array_start` / `__init_array_end` | 8 B | May be equal if there are no constructors — that is fine |
| `__stack_guard_bottom` / `__stack_guard_top` | 4 KiB | One page; unmapped in Phase 4 |
| `__stack_bottom` / `__stack_top` | 4 KiB | `rsp` starts at `__stack_top` (the high address) |

The regions are contiguous and non-overlapping: every `_end` is the next region's `_start`. The VMM can walk them without gap-handling.

### Code models

| `-mcmodel=` | Assumes | Relocation for a global | Cost |
|---|---|---|---|
| `small` (default) | Everything in the low 2 GiB | `R_X86_64_32` | Fastest — wrong address range for us |
| **`kernel`** | Everything in the top 2 GiB | `R_X86_64_32S` | Fastest, correct range ✅ |
| `medium` | Small code, large data | mixed | Unnecessary |
| `large` | No assumptions | `R_X86_64_64` via `movabs` | 10-byte references, indirect calls |

### Relocations you will meet

| Value | Name | Encodes | Fails when |
|---|---|---|---|
| 1 | `R_X86_64_64` | Full 64-bit address | ~never |
| 2 | `R_X86_64_PC32` | 32-bit PC-relative | Target > ±2 GiB from the reference |
| 4 | `R_X86_64_PLT32` | Call via PLT slot (no PLT here → same as PC32) | as above |
| 10 | `R_X86_64_32` | Zero-extended 32-bit | Address ≥ 2 GiB — the `-mcmodel=small` failure |
| 11 | `R_X86_64_32S` | Sign-extended 32-bit | Address outside the low 2 GiB *and* outside the top 2 GiB |

### Linker-script directives used

| Directive | Meaning |
|---|---|
| `OUTPUT_FORMAT(elf64-x86-64)` | BFD target of the output file |
| `OUTPUT_ARCH(i386:x86-64)` | Architecture recorded in the ELF header |
| `ENTRY(sym)` | Sets `e_entry`; also a root for `--gc-sections` |
| `SECTIONS { … }` | The placement program |
| `.` | The location counter — the current output address |
| `. = ADDR;` | Move the location counter. **Forward only.** |
| `ALIGN(n)` | Round the location counter up to a multiple of `n` |
| `CONSTANT(MAXPAGESIZE)` | The linker's max page size — `0x200000` by default on x86-64, `0x1000` with `-z max-page-size=0x1000` |
| `*(.text .text.*)` | Match those input sections from all input files, in link order |
| `KEEP(...)` | Exempt from `--gc-sections` |
| `SORT_BY_INIT_PRIORITY(...)` | Order `.init_array.NNNNN` by `init_priority` |
| `PHDRS { name PT_LOAD FLAGS(n); }` | Declare segments explicitly |
| `} :name` | Assign an output section to a declared segment |
| `/DISCARD/ : { … }` | Drop matching input sections entirely |
| `sym = expr;` | Define a symbol. Inside a section → section-relative; outside → absolute |

### Required link flags

| Flag | Why | Symptom if missing |
|---|---|---|
| `-T .../linker.ld` | Use our script | Default layout, wrong address |
| `-z max-page-size=0x1000` | Makes `CONSTANT(MAXPAGESIZE)` 4 KiB | 2 MiB alignment and megabytes of waste |
| `-static` | No dynamic linking | A `.dynamic` section nothing will process |
| `--build-id=none` | Suppress `.note.gnu.build-id` | An orphan note section |
| `--orphan-handling=warn` | Warn about input sections the script does not place | Sections silently land somewhere arbitrary |
| `-nostdlib` (driver only) | Don't link crt/libc | Undefined `_start`, `__libc_csu_init`, … |

> `-nostdlib` is a **compiler-driver** flag. GNU `ld` also has a `-nostdlib`, but it means something else entirely ("only search `-L` directories"). If you invoke `ld` directly you do not need it.

---

## 5. Writing the code

### `kernel/arch/x86_64/boot/linker.ld`

The single file that decides where every byte of the kernel lives and what permissions it will be able to carry.

```ld
/* kernel/arch/x86_64/boot/linker.ld
 *
 * Higher-half kernel layout for x86_64 + Limine.
 * See: steps/06 - Architecture Overview  (memory layout)
 *      steps/08 - Build System           (what this script must provide)
 *
 * MUST be linked with  -z max-page-size=0x1000
 * or CONSTANT(MAXPAGESIZE) is 0x200000 and every region gets 2 MiB alignment.
 */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(kmain)

/* ---------------------------------------------------------------- constants */

/* Bottom of the topmost 2 GiB. Required by -mcmodel=kernel and by the
   Limine x86-64 protocol. Changing this means changing both. */
KERNEL_VMA        = 0xFFFFFFFF80000000;

PAGE_SIZE         = CONSTANT(MAXPAGESIZE);   /* 0x1000, given the -z flag */
KERNEL_STACK_SIZE = 64K;

/* ------------------------------------------------------ segments (PT_LOAD) */
/* FLAGS() is the ELF p_flags bitfield:  PF_X = 1, PF_W = 2, PF_R = 4. */

PHDRS
{
    requests PT_LOAD FLAGS(6);   /* RW  — the bootloader writes here */
    text     PT_LOAD FLAGS(5);   /* R E */
    rodata   PT_LOAD FLAGS(4);   /* R   */
    data     PT_LOAD FLAGS(6);   /* RW  */
}

/* ------------------------------------------------------------------ layout */

SECTIONS
{
    . = KERNEL_VMA;
    __kernel_start = .;

    /* Limine finds these by scanning for their magic IDs. Nothing in the
       kernel references them, so KEEP() is what stops --gc-sections. */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :requests

    /* ------------------------------------ executable, never writable */
    . = ALIGN(PAGE_SIZE);
    .text : {
        __text_start = .;
        *(.text .text.*)
    } :text

    . = ALIGN(PAGE_SIZE);
    __text_end = .;

    /* ------------------------- read-only, not writable, not executable */
    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(PAGE_SIZE);
    __rodata_end = .;

    /* ------------------------------------ writable, never executable */
    __data_start = .;

    .init_array : {
        __init_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    } :data

    .fini_array : {
        __fini_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
        KEEP(*(.fini_array))
        __fini_array_end = .;
    } :data

    .data : {
        *(.data .data.*)
    } :data

    . = ALIGN(PAGE_SIZE);
    __data_end = .;

    /* .bss MUST be the last allocated section in :data, so that the
       segment's p_memsz > p_filesz and the loader zero-fills the tail
       instead of the linker writing megabytes of zeros into the file. */
    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)

        /* BSP boot stack. NOBITS: costs zero bytes in kernel.elf.
           Grows DOWN from __stack_top. Guard page sits below it. */
        . = ALIGN(PAGE_SIZE);
        __stack_guard_bottom = .;
        . = . + PAGE_SIZE;              /* left unmapped in Phase 4 */
        __stack_guard_top = .;

        __stack_bottom = .;
        . = . + KERNEL_STACK_SIZE;
        __stack_top = .;                /* <-- initial rsp */
    } :data

    . = ALIGN(PAGE_SIZE);
    __bss_end   = .;
    __kernel_end = .;

    /* Not needed, and actively troublesome if left in. */
    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
        *(.comment)
    }
}
```

#### Line by line

**`OUTPUT_FORMAT(elf64-x86-64)` / `OUTPUT_ARCH(i386:x86-64)`**
```ld
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
```
`OUTPUT_FORMAT` names the BFD target: 64-bit little-endian ELF for x86-64. `OUTPUT_ARCH` sets `e_machine` to `EM_X86_64` (62). With `x86_64-elf-ld` these are what you would get anyway, so they are documentation and insurance — insurance against someone linking with the host `ld` and getting a subtly different default. `i386:x86-64` looks like a typo and is not; it is BFD's name for the 64-bit member of the i386 architecture family.

**`ENTRY(kmain)`**
```ld
ENTRY(kmain)
```
Sets `e_entry` in the ELF header to the address of `kmain`. Limine reads that field and jumps there. It also makes `kmain` a **root for `--gc-sections`**, which is the reason the entire reachable kernel survives garbage collection without any further annotation.

`kmain` must be `extern "C"`. C++ name mangling turns `void kmain()` into `_Z5kmainv`, and `ENTRY(kmain)` then finds nothing — you get `ld: warning: cannot find entry symbol kmain; defaulting to <some address>` and an entry point pointing at the start of the image rather than at your function. [[Stage 0.3 - Freestanding C++ and kmain]] already flags this; here is where it bites.

**`KERNEL_VMA`**
```ld
KERNEL_VMA = 0xFFFFFFFF80000000;
```
A plain symbol assignment outside `SECTIONS`. This is the number the whole stage is about: the lowest address reachable by a sign-extended 32-bit displacement (§2), the base `-mcmodel=kernel` assumes, and what the Limine protocol requires. Any address in `[0xFFFFFFFF80000000, 2^64)` would work; this is the bottom of the window, so the kernel gets the whole 2 GiB to grow into.

**`PAGE_SIZE` and `KERNEL_STACK_SIZE`**
```ld
PAGE_SIZE         = CONSTANT(MAXPAGESIZE);
KERNEL_STACK_SIZE = 64K;
```
`CONSTANT(MAXPAGESIZE)` is a linker builtin returning the target's maximum page size — **`0x200000` (2 MiB) by default on x86-64**, and `0x1000` when you pass `-z max-page-size=0x1000`. Using it rather than a literal `4K` matters because the linker uses the same value to lay out segments: it keeps `p_offset ≡ p_vaddr (mod p_align)`. Hardcode `4K` here while the linker still thinks the page size is 2 MiB and it will pad the *file* to restore that congruence, producing a multi-megabyte `kernel.elf` full of zeros. Tie them together and a forgotten flag degrades to "2 MiB alignment, wasteful but working" instead of "8 MB of zeros".

`64K` uses `ld`'s size suffixes (`K`, `M`). Sizing rationale in §3.

**`PHDRS`**
```ld
PHDRS
{
    requests PT_LOAD FLAGS(6);   /* RW  */
    text     PT_LOAD FLAGS(5);   /* R E */
    rodata   PT_LOAD FLAGS(4);   /* R   */
    data     PT_LOAD FLAGS(6);   /* RW  */
}
```
Four segments, declared explicitly. `PT_LOAD` means "the loader must map this". `FLAGS(n)` writes `p_flags` directly: 4 = `PF_R`, 5 = `PF_R|PF_X`, 6 = `PF_R|PF_W`.

Three consequences worth understanding.

*Declaring `PHDRS` at all turns off the automatic behaviour.* Without it, `ld` invents segments by merging adjacent output sections with compatible flags, and text plus rodata plus data commonly collapses into one `RWX` `PT_LOAD` — which binutils 2.43 will even warn about (`has a LOAD segment with RWX permissions`). With it, you get exactly the segments you named and nothing else: no `PT_GNU_STACK`, no `PT_GNU_RELRO`, no `PT_PHDR`. For a bare-metal kernel that is what you want.

*The requests segment is `RW`, not `R`.* Limine writes a response pointer into each request struct. Marking that region read-only is a micro-optimisation that buys nothing and invites a fault the day something else writes there.

*`.text` is `R E`, never `RW`.* If `.text` ended up in a non-executable segment, Limine would map it `NX` and the CPU would fault on the *first instruction fetch at the entry point* — a triple fault, before any of your code runs, with nothing to show for it.

**`. = KERNEL_VMA;` and `__kernel_start`**
```ld
. = KERNEL_VMA;
__kernel_start = .;
```
`.` is the location counter: the virtual address at which the next thing will be placed. It starts at zero, and this is where you plant the kernel. `__kernel_start` records it as a symbol. Because the assignment is outside any output section, the symbol is **absolute** — `nm` shows it as `A` rather than `T`/`D`/`B`. That is expected and harmless; you only ever take its address.

The PMM in [[Phase 4 - Overview|Phase 4]] uses `[__kernel_start, __kernel_end)` to reserve the kernel image. Get the pair wrong and the frame allocator will eventually hand out a page containing running kernel code.

**`.limine_requests`**
```ld
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :requests
```
The output section named `.limine_requests` collects three input sections: the start marker, the requests themselves, and the end marker. Limine scans the loaded image for the 128-bit magic IDs; the markers let it bound that scan.

`KEEP()` exempts each from `--gc-sections`. Nothing in the kernel references these objects by name, so without `KEEP()` they are unreachable in the section graph and eligible for deletion. Combined with the `__attribute__((used))` already on them from [[Stage 0.2 - The Limine Request Section]], this is the belt-and-braces pair argued for in §3: `used` stops the compiler, `KEEP` stops the linker.

`:requests` assigns this output section to the `requests` segment. **You must write `:phdr` on every allocatable output section once you use `PHDRS`**, because `ld`'s rule is that a section without an explicit assignment inherits the segments of the *previous* section. Omit `:text` on `.text` and it silently joins the `requests` segment — `RW`, non-executable, instant triple fault.

> Section names come from the `limine.h` you vendored. The v8.x header uses `.limine_requests`, `.limine_requests_start`, and `.limine_requests_end`; older templates used `.requests` and friends (which is what [[08 - Build System]] still says). **Check the header** and make the script match — the failure mode is an empty section and a bootloader that finds no requests.

This section is placed first, at `KERNEL_VMA` itself, which is conventional and keeps the requests trivially findable. It is not strictly required.

**`.text`**
```ld
    . = ALIGN(PAGE_SIZE);
    .text : {
        __text_start = .;
        *(.text .text.*)
    } :text

    . = ALIGN(PAGE_SIZE);
    __text_end = .;
```
`ALIGN(PAGE_SIZE)` rounds `.` up to the next 4 KiB boundary — this is the alignment that makes W^X possible, and it is why the requests section cannot bleed into a page shared with code.

`*(.text .text.*)` matches `.text` from every input file, plus the per-function sections `.text.<name>` that `-ffunction-sections` produces and the variants GCC emits on its own (`.text.hot`, `.text.unlikely`, `.text.startup`). Miss the `.text.*` and those become orphans — the linker places them somewhere of its own choosing, with a warning if you passed `--orphan-handling=warn` and in silence if you did not.

`__text_start` is defined **inside** the braces, making it relative to the output section. `__text_end` is defined **outside**, after the trailing `ALIGN`, so it lands on a page boundary. That asymmetry is deliberate and it is what the Linux kernel's own script does: the start symbol wants to be the first byte of the section, the end symbol wants to be the page-aligned exclusive bound the VMM will map up to. It also means `__text_end == __rodata_start` exactly, so the regions tile with no gaps.

**`.rodata`**
```ld
    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(PAGE_SIZE);
    __rodata_end = .;
```
No `ALIGN` before it, because `__text_end` already left `.` page-aligned. `.rodata.*` catches the mangled per-object names — `.rodata.str1.1` (string literal pools), `.rodata.cst8` (constant pools), and the `-fdata-sections` per-object variants. String literals live here; so does anything `constexpr` that got emitted.

Its own segment with `FLAGS(4)`: readable, not writable, not executable. That combination is worth stating plainly, because it is the one people skip. A writable rodata section means a bug can rewrite your string table; an executable one means an attacker with a write primitive has a place to put code.

**`__data_start`, `.init_array`, `.fini_array`**
```ld
    __data_start = .;

    .init_array : {
        __init_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    } :data

    .fini_array : {
        __fini_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
        KEEP(*(.fini_array))
        __fini_array_end = .;
    } :data
```
`__data_start` marks the beginning of the writable region — note it covers `.init_array` and `.fini_array` too, not just `.data`. That is what the VMM wants: one contiguous `RW NX` range.

`.init_array` is an array of function pointers to global constructors. GCC emits one entry per global object with a non-trivial constructor, into `.init_array` for default priority and `.init_array.NNNNN` for `__attribute__((init_priority(N)))`. `SORT_BY_INIT_PRIORITY` orders the numbered ones correctly; the plain `.init_array` inputs follow. `KEEP()` because — again — nothing references the entries by name.

[[ADR-0007 - Freestanding C++20 as the Kernel Language]] bans globals with non-trivial constructors, so this section may well be **empty**, and `__init_array_start == __init_array_end`. That is correct: the walker in step 11 of the init order ([[06 - Architecture Overview]]) runs zero iterations. The section is here so the plumbing exists when [[Phase 4 - Overview|Phase 4]] has a heap and the ban relaxes. After your first link, check with `nm` that both symbols exist; if the linker dropped the empty output section along with them, move the two assignments outside the braces.

`.fini_array` is the destructor equivalent. We never run it — a kernel does not exit — but collecting it costs nothing and keeps it from becoming an orphan.

If you are ever on a toolchain old enough to emit `.ctors`/`.dtors` instead, add `KEEP(*(.ctors))` and `KEEP(*(.dtors))`. GCC 14.2 configured normally uses `.init_array`; confirm with `x86_64-elf-readelf -S entry.o`.

**`.data` and `__data_end`**
```ld
    .data : {
        *(.data .data.*)
    } :data

    . = ALIGN(PAGE_SIZE);
    __data_end = .;
```
Globals with a non-zero initialiser. These are real bytes in the file. `.data.*` catches `-fdata-sections` output.

Nothing PIC-related appears here (`.data.rel.ro`, `.got`, `.got.plt`) because we compile `-fno-pic -fno-pie` and link `-static`. If any of those ever show up in `readelf -S`, something in the flags has drifted.

**`.bss`, the stack, and the guard page**
```ld
    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)

        . = ALIGN(PAGE_SIZE);
        __stack_guard_bottom = .;
        . = . + PAGE_SIZE;
        __stack_guard_top = .;

        __stack_bottom = .;
        . = . + KERNEL_STACK_SIZE;
        __stack_top = .;
    } :data
```
`.bss` holds zero-initialised globals. It is `SHT_NOBITS`: the section has a size but no file content, and it exists in the ELF only as the amount by which the `data` segment's `p_memsz` exceeds its `p_filesz`. The loader zero-fills that excess (§3).

`*(COMMON)` catches tentative definitions — C-style `int x;` at file scope with no initialiser, which older C compilers place in the COMMON pseudo-section. C++ does not generate these and `-fno-common` is GCC's default since version 10, so this line will almost certainly match nothing. It costs nothing and it prevents an orphan if a `.c` file or an assembly `.comm` ever sneaks in.

**`.bss` must be the last allocated section in the `data` segment.** If a section with file content followed it, the linker would have to give that section a file offset past the `.bss`, which means writing `.bss` out as literal zeros. Your `kernel.elf` grows by the size of your `.bss` — which, with a 64 KiB stack in there, is immediately noticeable, and with a large static buffer becomes absurd.

The stack is carved out with location-counter arithmetic. `. = . + PAGE_SIZE` advances 4 KiB without emitting anything, so the section stays `NOBITS`. Address order, low to high:

```
   __bss_start ──┐
                 │  .bss from all objects
   (page align)  │
   __stack_guard_bottom ─┐
                         │  4 KiB — unmapped in Phase 4
   __stack_guard_top ────┘
   __stack_bottom ───────┐
                         │  64 KiB — the stack
                         │  grows DOWNWARD, this way ▲
   __stack_top ──────────┘   <-- initial rsp
```

`__stack_top` is the **high** address and the value you load into `rsp`. `__stack_bottom` is the **low** address; overflow goes past it, into the guard. Because `__stack_top` inherits page alignment it is 16-byte aligned, satisfying the SysV AMD64 requirement at call boundaries.

You do not switch to this stack in Stage 0.4 — Limine gave you a working one and there is nothing yet to switch with. The switch is a two-instruction assembly prologue, and it must happen before [[Phase 4 - Overview|Phase 4]] reclaims bootloader memory (§3, option C).

**`__bss_end` and `__kernel_end`**
```ld
    . = ALIGN(PAGE_SIZE);
    __bss_end   = .;
    __kernel_end = .;
```
Both page-aligned, both absolute, and equal — `.bss` is the last thing in the image. `__kernel_end` is the exclusive upper bound the PMM reserves. Rounding up is important: reserve to the byte and the PMM may hand out the page that contains the last few bytes of your `.bss`.

**`/DISCARD/`**
```ld
    /DISCARD/ : {
        *(.eh_frame .eh_frame.*)
        *(.note .note.*)
        *(.comment)
    }
```
Anything matched here is dropped rather than placed.

`.eh_frame` is DWARF unwind data. GCC on x86-64 emits it even with `-fno-exceptions`, because the psABI wants asynchronous unwind tables. We have no unwinder and never will (exceptions are banned by [[ADR-0007 - Freestanding C++20 as the Kernel Language]]), and our backtraces will walk frame pointers instead. Left in, it is dead weight and an orphan-placement nuisance. *If you later decide to build a DWARF-based backtracer, this is the line you delete.*

`.note.*` covers `.note.gnu.build-id` and `.note.gnu.property` (the CET/IBT markers GCC 14 may emit). Neither means anything to a bare-metal kernel, and a stray `PT_NOTE`-shaped orphan in a script with explicit `PHDRS` is just confusing. Passing `--build-id=none` prevents build-id generation at the source; this catches the rest.

`.comment` is the compiler version string. Non-allocatable, so it never affects the segments — dropping it just shrinks the file and helps the reproducible-build check in [[08 - Build System]].

**What is deliberately *not* discarded:** `.symtab`, `.strtab`, `.shstrtab`, and the `.debug_*` sections. They are non-allocatable, so they end up in no segment and cost nothing at run time, and they are what GDB and the panic symboliser need. Never discard them from `kernel.elf`; strip a *copy* if you want a small one.

---

### The link command

Stage 0.8 moves this into CMake. For now, invoke it by hand so you can see every flag:

```sh
x86_64-elf-ld \
    -T kernel/arch/x86_64/boot/linker.ld \
    -m elf_x86_64 \
    -static \
    -z max-page-size=0x1000 \
    --build-id=none \
    --orphan-handling=warn \
    -o build/kernel.elf \
    build/entry.o build/boot_info.o build/main.o
```

Or through the compiler driver, which is what CMake will do:

```sh
x86_64-elf-g++ \
    -T kernel/arch/x86_64/boot/linker.ld \
    -nostdlib -static -no-pie \
    -Wl,-z,max-page-size=0x1000 \
    -Wl,--build-id=none \
    -Wl,--orphan-handling=warn \
    -o build/kernel.elf \
    build/entry.o build/boot_info.o build/main.o -lgcc
```

`-z max-page-size=0x1000` is the one people forget. See §7.

---

### Consuming the symbols from C++

You do not need this until [[Phase 4 - Overview|Phase 4]], but get the declaration form right now, because the wrong one compiles cleanly and reads garbage.

```cpp
// Linker-defined boundary symbols. Declare them as arrays: what you want is
// the ADDRESS of the symbol, and an array name decays to its address.
extern "C" {
    extern char __kernel_start[];
    extern char __kernel_end[];
    extern char __text_start[];
    extern char __text_end[];
    extern char __rodata_start[];
    extern char __rodata_end[];
    extern char __data_start[];
    extern char __data_end[];
    extern char __bss_start[];
    extern char __bss_end[];
    extern char __stack_bottom[];
    extern char __stack_top[];
}

inline uintptr_t kernel_start() { return reinterpret_cast<uintptr_t>(__kernel_start); }
inline size_t    kernel_size()  { return static_cast<size_t>(__kernel_end - __kernel_start); }
```

**The trap.** Writing `extern "C" uintptr_t __kernel_end;` and then using `__kernel_end` compiles, and reads *the eight bytes stored at that address* — which is whatever happens to be at the end of your kernel image. You wanted the address; you got the contents. Declaring the symbols as arrays makes the mistake unrepresentable, because an array cannot be read as a scalar.

`extern "C"` is required: these symbols come from the linker with no C++ mangling.

The leading double underscore is reserved for the implementation in C++ — which, in a kernel, is exactly what we are. It also keeps the names clear of the traditional `_end` / `etext` / `edata` that some toolchain pieces still expect.

---

## 6. How to verify

**This stage does not boot.** Booting is [[Stage 0.5 - Building a Bootable Image]] — it needs an ISO, a `limine.conf`, and the Limine deploy step. Everything below is a static check on `kernel.elf`, and every one of them is worth doing, because a static check that fails here saves you from debugging a black screen there.

Run all of these inside `make shell`.

### The link itself succeeds

```sh
$ x86_64-elf-ld -T kernel/arch/x86_64/boot/linker.ld -m elf_x86_64 -static \
      -z max-page-size=0x1000 --build-id=none --orphan-handling=warn \
      -o build/kernel.elf build/*.o
$ echo $?
0
```

No output at all is the pass condition. Specifically, **no** `relocation truncated to fit`, **no** `cannot find entry symbol`, **no** `orphan section ... being placed in`, **no** `LOAD segment with RWX permissions`.

### Segments: addresses, flags, alignment

```sh
$ x86_64-elf-readelf -l build/kernel.elf
```

```
Elf file type is EXEC (Executable file)
Entry point 0xffffffff80001000
There are 4 program headers, starting at offset 64

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  LOAD           0x0000000000001000 0xffffffff80000000 0xffffffff80000000
                 0x0000000000000110 0x0000000000000110  RW     0x1000
  LOAD           0x0000000000002000 0xffffffff80001000 0xffffffff80001000
                 0x00000000000004a0 0x00000000000004a0  R E    0x1000
  LOAD           0x0000000000003000 0xffffffff80002000 0xffffffff80002000
                 0x0000000000000080 0x0000000000000080  R      0x1000
  LOAD           0x0000000000004000 0xffffffff80003000 0xffffffff80003000
                 0x0000000000000018 0x0000000000012018  RW     0x1000

 Section to Segment mapping:
  Segment Sections...
   00     .limine_requests
   01     .text
   02     .rodata
   03     .init_array .data .bss
```

Your sizes will differ. What must match:

| Check | Expected |
|---|---|
| Number of `LOAD` segments | 4 |
| Every `VirtAddr` | starts `0xffffffff80` |
| Flags, in order | `RW`, `R E`, `R`, `RW` |
| Any segment with `RWX` | none |
| `Align` on every segment | `0x1000` — if it says `0x200000` you forgot `-z max-page-size=0x1000` |
| Last segment | `MemSiz` ≫ `FileSiz` (the `.bss` + stack gap) |
| Section-to-segment mapping | `.bss` is the **last** section listed in its segment |

### The entry point is `kmain`, and `kmain` is in kernel range

```sh
$ x86_64-elf-nm build/kernel.elf | grep -w kmain
ffffffff80001000 T kmain

$ x86_64-elf-readelf -h build/kernel.elf | grep 'Entry point'
  Entry point address:               0xffffffff80001000
```

The two addresses must be **identical**. `T` means a global symbol in text. If you see `_Z5kmainv` instead, `extern "C"` is missing. If the entry point is `0x0` or equals `__kernel_start` while `kmain` is elsewhere, `ENTRY()` did not resolve.

One-liner for CI:

```sh
$ test "$(x86_64-elf-readelf -h build/kernel.elf | awk '/Entry point/{print $NF}')" \
     = "0x$(x86_64-elf-nm build/kernel.elf | awk '/ T kmain$/{print $1}')" \
  && echo "entry ok"
entry ok
```

### `.limine_requests` exists and is not empty

```sh
$ x86_64-elf-readelf -S build/kernel.elf | grep -A1 limine
  [ 1] .limine_requests  PROGBITS         ffffffff80000000  00001000
       0000000000000110  0000000000000000  WA       0     0     8
```

The size field (`0000000000000110` here) **must not be zero**. Zero means the requests were dropped — the `used` attribute, the section name, or the `KEEP()` is wrong. See §7.

Confirm the magic is really in there:

```sh
$ x86_64-elf-readelf -x .limine_requests build/kernel.elf | head -4
```

You should see the common request-ID prefix repeated (the first two 64-bit words of every Limine ID are shared; compare against the `LIMINE_COMMON_MAGIC` definition in your vendored `limine.h`).

### Sections, types, and boundary symbols

```sh
$ x86_64-elf-readelf -S build/kernel.elf | grep -E '\.(text|rodata|data|bss|init_array)'
```

Check: `.text` has flags `AX`, `.rodata` has `A`, `.data` has `WA`, `.bss` has **type `NOBITS`** and flags `WA`. If `.bss` is `PROGBITS`, it is being written into the file — something is placed after it in the segment.

```sh
$ x86_64-elf-nm build/kernel.elf | grep -E '__(kernel|text|rodata|data|bss|stack|init_array)_' | sort
ffffffff80000000 A __kernel_start
ffffffff80001000 T __text_start
ffffffff80002000 A __text_end
ffffffff80002000 D __rodata_start
...
```

All of them present. `A` (absolute) for the ones defined outside sections, `T`/`D`/`B` for those defined inside — both are correct, and §5 explains which is which. Every `_end` should equal the following `_start`.

### Nothing dynamic, nothing position-independent

```sh
$ x86_64-elf-readelf -d build/kernel.elf
There is no dynamic section in this file.

$ x86_64-elf-readelf -S build/kernel.elf | grep -E '\.(got|plt|rela|dynamic|interp)'
(no output)
```

Any hit here means `-fno-pic -fno-pie` or `-static` went missing.

### The file is not absurdly large

```sh
$ x86_64-elf-size build/kernel.elf
   text	   data	    bss	    dec	    hex	filename
   1184	    296	  73752	  75232	  125e0	build/kernel.elf

$ ls -l build/kernel.elf
```

`bss` should include your 68 KiB of stack + guard. The **file** should be tens of kilobytes, not megabytes. A multi-megabyte `kernel.elf` means either the page-size flag is missing or something is placed after `.bss`.

### Checklist

- [ ] `x86_64-elf-ld` completes with exit status 0 and no warnings
- [ ] No `relocation truncated to fit` / `R_X86_64_32S` errors
- [ ] `readelf -l` shows exactly 4 `LOAD` segments, all at `0xffffffff80...`
- [ ] Flags are `RW`, `R E`, `R`, `RW` — and no segment is `RWX`
- [ ] Every segment's `Align` is `0x1000`
- [ ] The last segment's `MemSiz` exceeds its `FileSiz`
- [ ] `.bss` is the last section in the last segment, and its type is `NOBITS`
- [ ] `readelf -h` entry point equals `nm`'s address for `kmain`
- [ ] `.limine_requests` is present with non-zero size
- [ ] All boundary symbols resolve, and each `_end` equals the next `_start`
- [ ] `readelf -d` reports no dynamic section
- [ ] `kernel.elf` is tens of KiB, not MiB

### What can only be checked later

| Check | Stage |
|---|---|
| Limine actually loads the image and reaches `kmain` | [[Stage 0.5 - Building a Bootable Image]] |
| `.bss` really arrives zeroed at run time | [[Stage 0.6 - Serial Output]] — probe a global and print it |
| Boundary symbols cover the true image extent | Stage 4.1, when the PMM reserves the range |
| Per-section permissions actually enforced | [[Phase 4 - Overview\|Phase 4]] Stage 4.3, and Phase 15 for W^X |
| The guard page faults on overflow | Phase 4, once you own the page tables |

---

## 7. Common traps

**Symptom: the link fails with a wall of `relocation truncated to fit: R_X86_64_32S against symbol 'g_whatever'`.**
(LLD phrases the same thing as `relocation R_X86_64_32S out of range`.)
You compiled with `-mcmodel=kernel` — which promises every address is in the top 2 GiB — and linked somewhere else. The 32-bit signed field cannot encode the address, and the linker refuses to truncate it.
*Fix:* check that `. = KERNEL_VMA;` really is `0xFFFFFFFF80000000` and that the `-T` flag is actually pointing at your script (a typo'd path is silently ignored by some build setups, and you get the default layout at `0x400000`). If the failing symbol lives in `libgcc.a`, see the libgcc caveat in §3.

**Symptom: same error, but the offending relocation is `R_X86_64_32` rather than `R_X86_64_32S`.**
That is the *small* code model — zero-extended, so it can only reach the low 2 GiB. A translation unit is missing `-mcmodel=kernel`.
*Fix:* grep the compile database. [[08 - Build System]] already has CI grep for `-mno-red-zone`; add one for `-mcmodel=kernel` while you are there.

**Symptom: Limine says it cannot find the kernel, or boots to a black screen with every response pointer null.**
`.limine_requests` was garbage-collected, misnamed, or never emitted. Confirm with `readelf -S build/kernel.elf | grep limine` — if the section is missing or size zero, that is your answer.
*Fix, in the order to check them:* (1) the section name in `linker.ld` matches the one your vendored `limine.h` uses — v8.x uses `.limine_requests`, older templates used `.requests`; (2) `KEEP()` wraps all three input sections; (3) the request globals still carry `__attribute__((used))` from [[Stage 0.2 - The Limine Request Section]]; (4) you did not accidentally list `.limine_requests` in `/DISCARD/`.

**Symptom: `ld: warning: cannot find entry symbol kmain; defaulting to 0000000000000000` — or `readelf -h` reports an entry point of `0x0` or of `__kernel_start` rather than of `kmain`.**
`ENTRY()` names a symbol that does not exist under that name. Almost always C++ mangling: `void kmain()` without `extern "C"` links as `_Z5kmainv`.
*Fix:* `extern "C" void kmain(void)` in `entry.cpp`. Verify with `x86_64-elf-nm build/kernel.elf | grep kmain` — you want `T kmain`, not `T _Z5kmainv`. Note that this is only a *warning*, not an error: the link succeeds and produces a kernel that jumps into the middle of nothing.

**Symptom: the kernel boots but globals contain garbage; a counter you never incremented starts at a huge number.**
`.bss` was not zeroed. Three causes, all visible in `readelf -l`:
- The `data` segment's `MemSiz` equals its `FileSiz` — the zero-fill gap does not exist, so `.bss` ended up outside the segment or in one of its own with no `p_memsz` slack.
- `.bss` is not the last section in its segment, so the linker materialised it as file bytes (which actually still works, but bloats the ELF — check the file size).
- You zeroed it yourself and clobbered something. If you added a `memset` over `[__bss_start, __bss_end)`, make sure nothing the bootloader wrote lives in that range.
*Fix:* keep `.bss` last in `:data`, confirm `MemSiz > FileSiz`, and add the `g_bss_probe` check from §3 once serial works.

**Symptom: `kernel.elf` is several megabytes for a kernel with a few hundred lines of code.**
You are aligning to 4 KiB while the linker still thinks the maximum page size is 2 MiB, so it pads the *file* to keep `p_offset` congruent to `p_vaddr`. Or something with file content is placed after `.bss`, forcing the `.bss` to be written out as literal zeros.
*Fix:* pass `-z max-page-size=0x1000`, and check the section-to-segment mapping puts `.bss` last.

**Symptom: `ld: warning: kernel.elf has a LOAD segment with RWX permissions`.**
Two output sections with incompatible intent landed in the same segment — usually because an output section is missing its `:phdr` assignment and inherited the previous one.
*Fix:* every allocatable output section needs an explicit `:requests` / `:text` / `:rodata` / `:data`. This is the rule that catches people: `ld` does *not* default to "no segment", it defaults to "the previous section's segments".

**Symptom: `ld: warning: orphan section '.text.startup' being placed in section '.text'` — or a section you never listed shows up in `readelf -S` at a surprising address.**
An input section pattern in the script does not cover something the compiler emitted. Common culprits: `.text.*` variants, `.rodata.str1.1`, `.note.gnu.property`, `.tbss`/`.tdata` if anyone uses TLS.
*Fix:* keep `--orphan-handling=warn` on permanently so you find out immediately, and extend the pattern. Never `--orphan-handling=discard` — that turns a warning into silent deletion of code.

**Symptom: triple fault at the entry point, before a single instruction of yours executes. QEMU's `-d int` shows nothing useful.**
`.text` was mapped non-executable. Its segment has the wrong `FLAGS()`, or `.text` is missing its `:text` assignment and joined an `RW` segment. Limine honours `p_flags`, and an instruction fetch from an `NX` page faults immediately.
*Fix:* `readelf -l` must show `R E` for the segment containing `.text`.

**Symptom: `ld: address 0xffffffff7ffff000 of build/kernel.elf section '.text' is not within region ...`, or `cannot move location counter backwards`.**
A `. = <value>` assignment tried to go backwards, usually because a constant was mistyped (one `F` short in `0xFFFFFFFF80000000`) or an `ALIGN` was applied to the wrong expression.
*Fix:* count the hex digits. `0xFFFFFFFF80000000` is sixteen of them.

**Symptom: `ld: section .rodata VMA [...] overlaps section .text VMA [...]`.**
Two output sections were given overlapping addresses — typically from an explicit address on an output section combined with location-counter arithmetic. In this script no output section has an explicit address, so if you see this you have added one.
*Fix:* let `.` drive placement; use `ALIGN`, not absolute addresses, between sections.

**Symptom: a global object's constructor never runs.**
Expected, in Phase 0 — nothing calls the `.init_array` entries yet; that is step 11 of the init order and it arrives in [[Phase 4 - Overview|Phase 4]]. [[ADR-0007 - Freestanding C++20 as the Kernel Language]] bans such globals for exactly this reason.
*Fix:* explicit `init()` functions in the documented order. If you have reached Phase 4 and the walker still runs zero iterations, check that `__init_array_start` and `__init_array_end` both exist in `nm` output — an empty output section can take its symbols with it, and the fix is to move the two assignments outside the braces.

**Symptom: `ld: warning: <file>.o: missing .note.GNU-stack section implies executable stack`.**
binutils ≥ 2.39 complains about objects with no stack-permission note. It shows up once you add NASM `.asm` files in [[Phase 2 - Overview|Phase 2]].
*Fix:* pass `-z noexecstack`, or add `section .note.GNU-stack noalloc noexec nowrite progbits` at the end of each assembly file. Harmless either way for a bare-metal kernel, but noise in the build log is noise you will learn to ignore, and then you will ignore a real warning.

**Symptom: everything above passes, and QEMU still shows nothing.**
That is not this stage. You have no ISO, no `limine.conf` deployment, and no output code. Go to [[Stage 0.5 - Building a Bootable Image]] and then [[Stage 0.6 - Serial Output]]. Resist the urge to start changing the linker script — you have just proven statically that it is correct.

---

## 8. What this unlocks

Everything downstream reads this file's output. [[Stage 0.5 - Building a Bootable Image]] can now produce a `kernel.elf` that Limine will actually load and jump into — the first boot. Stage 4.1 and Stage 4.2 use `__kernel_start` and `__kernel_end` to reserve the kernel image so the frame allocator never hands out a page the kernel is running from; Stage 4.3 uses the per-section pairs to build page tables with genuinely different permissions per region; [[Phase 15 - Overview|Phase 15]] turns those into W^X, which is only possible because every boundary here is page-aligned. The `.init_array` collection is what makes step 11 of the initialisation order in [[06 - Architecture Overview]] implementable at all, and the reserved stack plus guard page is what [[Phase 12 - Overview|Phase 12]] generalises into per-CPU stacks.

The silent failures are the ones to fear. Under-reserving the kernel range corrupts a random subsystem weeks later. Packing sections tight makes W^X a full relayout rather than a flag. Losing `.limine_requests` produces a kernel that boots to nothing with no diagnostic. None of these announce themselves; all of them are prevented by the checks in §6, which is why you run all of them now rather than after the first black screen.

---

## 9. Reading

- **GNU `ld` — Linker Scripts.** The reference. Read *Script Format*, *Simple Assignments*, *SECTIONS*, and *Output Section Attributes* end to end once; skim the rest.
  <https://sourceware.org/binutils/docs/ld/Scripts.html>
- **GNU `ld` — PHDRS.** Short, and it is the section that explains the "sections without `:phdr` inherit the previous section's segments" rule that causes the `RWX` trap.
  <https://sourceware.org/binutils/docs/ld/PHDRS.html>
- **GNU `ld` — Builtin Functions.** `ALIGN`, `CONSTANT`, `SIZEOF`, `ADDR`. Where `MAXPAGESIZE` is defined.
  <https://sourceware.org/binutils/docs/ld/Builtin-Functions.html>
- **ELF gABI — Program Header.** The authority on `p_filesz` vs `p_memsz` and the zero-fill rule that `.bss` depends on. Two pages.
  <https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html>
- **System V ABI, AMD64 supplement.** Relocation types (`R_X86_64_32S` and friends), the code models, and the 16-byte stack alignment rule.
  <https://gitlab.com/x86-psABIs/x86-64-ABI>
- **GCC — x86 Options.** The `-mcmodel=` documentation, in the compiler's own words.
  <https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html>
- **Limine — `PROTOCOL.md`.** Confirm the top-2-GiB requirement and the entry-state guarantees for the pinned `v8.6.0-binary` release rather than trusting a summary.
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- **OSDev — Linker Scripts.** A gentler introduction than the binutils manual; read it first if the manual is heavy going.
  <https://wiki.osdev.org/Linker_Scripts>
- **OSDev — Higher Half Kernel.** Covers the GRUB/`AT()` approach as well, which is useful contrast: with Limine you do not need load-address arithmetic, because the bootloader maps segments at their virtual addresses for you.
  <https://wiki.osdev.org/Higher_Half_Kernel>
- **OSDev — Limine Bare Bones.** The minimal working example; its linker script is the ancestor of ours.
  <https://wiki.osdev.org/Limine_Bare_Bones>
- **OSDev — Libgcc without red zone.** Read it the first time a relocation error points into `libgcc.a`.
  <https://wiki.osdev.org/Libgcc_without_red_zone>
- **Linux — `arch/x86/kernel/vmlinux.lds.S`.** A production higher-half x86-64 linker script. Dense, but it settles arguments about what is conventional — including the start-symbol-inside / end-symbol-outside pattern used here.
  <https://github.com/torvalds/linux/blob/master/arch/x86/kernel/vmlinux.lds.S>
- [[06 - Architecture Overview]] — the memory layout this stage realises.
- [[08 - Build System]] — the requirements list this script satisfies, and where the link flags will live from Stage 0.8.
- [[ADR-0002 - Target x86_64 Not i686]] — why `-mcmodel=kernel` is in the flag set at all.
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]] — why `.eh_frame` is discarded and `.init_array` is expected to be empty for now.

Next: **[[Stage 0.5 - Building a Bootable Image]]**

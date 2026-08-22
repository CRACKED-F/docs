# Stage 0.3 — Freestanding C++ and `kmain`

**Difficulty:** Medium · ~75 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `kernel/include/kernel/boot_info.hpp`, `kernel/arch/x86_64/boot/boot_info.cpp`, `kernel/main.cpp` — plus edits to `kernel/arch/x86_64/boot/entry.cpp`
**Deliverable:** every Limine response the kernel will ever need is copied into our own `BootInfo` struct, and nothing outside `kernel/arch/x86_64/boot/` knows Limine exists.

---

## Progress

- [ ] Create `kernel/include/kernel/boot_info.hpp` with `MemoryType`, `MemoryRegion`, `Module`, `BootInfo`
- [ ] Choose `MAX_REGIONS`, `MAX_MODULES`, `MAX_MODULE_PATH` and add the `static_assert`s that pin the layout
- [ ] Add the boot-halt code table and the `boot_halt()` declaration
- [ ] Create `kernel/arch/x86_64/boot/boot_info.cpp` and declare the six requests `extern`
- [ ] Implement `boot_halt()` — `cli`, code pinned in `RDI`, `hlt` forever
- [ ] Implement `map_memory_type()` and `copy_string()` (there is no libc)
- [ ] Implement `collect_boot_info()`, null-checking **every** response before touching it
- [ ] Bound the memmap copy against `MAX_REGIONS` and halt on overflow — never truncate
- [ ] Copy module descriptors **and** the path strings they point at
- [ ] Edit `entry.cpp`: drop `static` from the requests, check `LIMINE_BASE_REVISION_SUPPORTED`, call `collect_boot_info()` then `kernel_init()`
- [ ] Make `kmain` `[[noreturn]]` and park the CPU after `kernel_init` returns
- [ ] Create `kernel/main.cpp` with `kernel_init(BootInfo*)` — no `limine.h`, no inline asm
- [ ] Compile all three translation units with the kernel flag set, `-Werror` clean
- [ ] Run the `limine` boundary grep locally and confirm it returns nothing
- [ ] Committed with a message like `feat(boot): copy Limine responses into BootInfo`

---

## 1. Why this stage exists

Limine has finished. The CPU is in 64-bit long mode with paging on and interrupts off, and somewhere in RAM sits a scattering of small structures describing the machine: how much memory there is and where the holes are, where the framebuffer lives, what offset the direct map sits at, where your own image was placed, what files were loaded beside you. Every one of those structures is reachable only through a pointer that Limine wrote into a request you declared in [[Stage 0.2 - The Limine Request Section]].

Those structures are on borrowed land. Limine marks its own working memory — including every response it wrote — as `LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE`. That is not a warning, it is an invitation: the memory is yours to take back, and in [[Phase 4 - Overview|Phase 4]] your physical memory manager will do exactly that, because on a small machine reclaiming a few hundred kilobytes matters and because leaving it permanently reserved for no reason is sloppy. The moment the PMM adds those pages to its free list, every Limine pointer you kept becomes a pointer into someone else's allocation.

That failure is genuinely nasty, and it is the reason this stage is 75 minutes and not 20. It does not fail at the moment of the mistake. It fails in Phase 4 or later, in whichever subsystem happens to read `boot_info->fb_addr` first after the heap got busy — and the diff that "caused" it will be an innocent change to the allocator. You will read the framebuffer code, then the console code, then the paging code, and none of them will be wrong. The bug was written today.

The second reason is smaller but compounds for years. If `limine.h` types leak into the kernel proper, then `kernel/mm/pmm.cpp` takes a `limine_memmap_response*`, `kernel/drivers/char/fbcon.cpp` takes a `limine_framebuffer*`, and the "we could swap the bootloader" claim in [[ADR-0003 - Limine as the Bootloader]] quietly becomes false. Nobody decides to couple to a bootloader. It happens one convenient `#include` at a time. This stage puts the wall up while the tree is three files big, and [[10 - CI Pipeline]] keeps it up.

---

## 2. The concept

### What "freestanding" actually means

A **hosted** C++ implementation assumes an operating system is underneath it. `main` is called by startup code that ran first; `new` reaches a heap that someone else built; `std::vector` can throw, and something catches or terminates; `printf` becomes a `write` syscall. None of that exists here. You *are* the operating system.

`-ffreestanding` tells the compiler to stop assuming. Concretely it means: no `main` special-casing, no library-function-semantics assumptions in the optimiser (mostly — see the `memset` trap in §7), and only the *freestanding subset* of the standard library is guaranteed.

**In this project that subset is narrower than the standard allows.** The C++ standard's freestanding subset includes header-only pieces like `<type_traits>` and `<bit>` — but those ship in **libstdc++**, and our toolchain image does not build it (`toolchain/Dockerfile` stops at `all-gcc all-target-libgcc`). `#include <cstdint>` fails outright:

```
fatal error: cstdint: No such file or directory
```

What *does* work is GCC's own freestanding C headers, which are compiled into the compiler rather than into a library: `<stdint.h>`, `<stddef.h>`, `<stdarg.h>`, `<stdbool.h>`, `<limits.h>`, `<float.h>`. Everything else the kernel needs — type traits, bit utilities, atomics — you write yourself in `kernel/lib/kstd/`. See [[ADR-0007 - Freestanding C++20 as the Kernel Language]] for why that trade is deliberate.

What it does **not** do is stop you writing `#include <vector>`. The cross-compiler ships libstdc++ headers and they are on the include path. The header will compile. The *link* is what fails, with a page of undefined references. This is worth internalising early: in freestanding C++ the ban on most of the language's runtime features is enforced by the **linker**, not the compiler. §3 lists exactly which error you get for each violation, because recognising the error is how you diagnose it in ten seconds instead of an hour.

### The request/response model, one level deeper

Stage 0.2 established the shape: you declare a request, Limine writes a response pointer into it. What Stage 0.2 did not say is where the response lives and how deeply it nests.

```
   YOUR KERNEL IMAGE (.limine_requests, in .data)      BOOTLOADER-RECLAIMABLE RAM
  ┌──────────────────────────────────────┐          ┌────────────────────────────────┐
  │ memmap_request                       │          │ limine_memmap_response         │
  │   id[4]      = <128-bit magic>       │          │   revision   = 0               │
  │   revision   = 0                     │          │   entry_count = 9              │
  │   response ──┼──────────────────────────────►   │   entries ──┐                  │
  └──────────────────────────────────────┘          │             ▼                  │
                                                    │   [0] ──► {base,length,type}   │
   Limine writes ONLY the `response` field.         │   [1] ──► {base,length,type}   │
   Everything to the right of the arrow is          │   [2] ──► {base,length,type}   │
   memory Limine allocated for itself.              │   ...                          │
                                                    └────────────────────────────────┘
                                                       ▲
                                                       │ Phase 4's PMM sees type 5
                                                       │ (BOOTLOADER_RECLAIMABLE) and
                                                       │ adds every page of it to the
                                                       │ free list. Then kmalloc hands
                                                       │ it out. Then it is a task
                                                       │ struct, or a page table.
```

Two things to notice.

**The nesting is three levels deep.** `memmap_request.response` is a pointer to a response; `response->entries` is a pointer to an *array of pointers*; `entries[i]` is a pointer to one entry. Copying `response` alone copies nothing useful. Copying `entries` alone copies a pointer into reclaimed memory. Only walking to the leaves and copying the `base`/`length`/`type` scalars gets you data that outlives the bootloader.

**Strings are leaves too.** A module's descriptor has a `path` field that is a `char*`. The pointer is in reclaimable memory and so is the text it points at. Copying the descriptor without copying the string is the same bug wearing a different hat.

### The barrier

So the design is a barrier, drawn once, at the earliest possible moment:

```
   ┌─────────────────────────── kernel/arch/x86_64/boot/ ───────────────────────────┐
   │                                                                               │
   │   entry.cpp        the requests, the markers, kmain()                         │
   │   boot_info.cpp    collect_boot_info():  Limine types ──► our types           │
   │   limine.h         vendored, and legal ONLY in this directory                 │
   │                                                                               │
   └──────────────────────────────────┬────────────────────────────────────────────┘
                                      │  BootInfo*  (plain scalars, fixed arrays)
                                      ▼
   ┌───────────────────────────────────────────────────────────────────────────────┐
   │  the entire rest of the kernel — mm/, drivers/, fs/, sched/, main.cpp          │
   │  has never heard of a bootloader                                              │
   └───────────────────────────────────────────────────────────────────────────────┘
```

`collect_boot_info()` runs once, before anything else, and after it returns the bootloader is irrelevant. That single function is the entire coupling surface to Limine. Swapping to a different bootloader means rewriting one file — which is the claim [[ADR-0003 - Limine as the Bootloader]] makes, and this is where it is either made true or quietly abandoned.

### Why `BootInfo` lives in `.bss`

There is no heap. There will not be one until Phase 4. There are exactly three places a `BootInfo` can live:

- **The stack.** Limine gave us a stack, but `collect_boot_info()` returns and its frame dies with it. Returning a pointer to a dead frame is a dangling pointer that *usually works* until the next function call reuses the memory, which is the worst failure mode available.
- **The heap.** Does not exist. `new` is a link error by design.
- **Static storage.** A file-scope `static BootInfo g_boot_info;`. It is trivially constructible, so nothing needs to run to create it. It sits in `.bss`, inside the kernel image, at a fixed address that is mapped for as long as the kernel is. It is zero on arrival because the ELF specification requires a loader to zero-fill the part of a `PT_LOAD` segment beyond the file size, and Limine does.

Static storage is the only option that survives, and it is free.

---

## 3. Design decisions and tradeoffs

### Decision: freestanding C++, C, Rust, or assembly?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Freestanding C++20 (chosen)** | Full language minus exceptions, RTTI, stdlib, FP. `-ffreestanding` plus a flag set that removes the runtime-dependent features | You must police a language subset by hand; several features compile fine and fail at link, one fails only at runtime | ✅ |
| C11 | The same minus templates, `constexpr`, `enum class`, RAII | No compile-time table generation, no RAII lock guards, no type-safe `PhysAddr`/`VirtAddr`, macros where templates belong | ❌ |
| Rust (`no_std`) | Borrow checker and lifetimes encode the invariants kernels get wrong | Neither of us knows it; the reference corpus we will actually read is C and C++ | ❌ |
| Pure assembly | No runtime assumptions at all, total control | Unmaintainable past a few thousand lines; no type checking of any kind | ❌ |

**Why C++.** Three things pay for themselves inside this project's lifetime, and they are not stylistic.

*Type-safe address distinctions.* [[13 - Coding Standards]] rule 1 mandates `struct PhysAddr { uint64_t value; };` and `struct VirtAddr { uint64_t value; };`. In C these are two `typedef`s of `uint64_t` and the compiler will happily let you pass one where the other belongs. In C++ they are distinct types, the mistake is a compile error, and the wrapper costs zero bytes and zero instructions. Mixing physical and virtual addresses is among the most common and most confusing kernel bugs there is; making it unrepresentable is worth the whole decision on its own.

*RAII.* From [[Phase 5 - Overview|Phase 5]] onward every lock is taken through a guard object whose destructor releases it. That is not tidiness. It means a lock cannot be leaked by an early `return` added six months later by someone who did not notice there was a lock held. In C the same discipline is `goto out;` and a hand-maintained unlock path, and it fails eventually, and the failure is a deadlock under load.

*`constexpr` and templates.* The GDT, the IDT, and the page-flag tables are all data that can be computed at compile time from readable expressions instead of written out as hex by hand. Wrong hex in a descriptor table is a triple fault with no diagnostic; a `constexpr` function that builds the descriptor from named fields is checkable by reading it. `enum class` with an explicit underlying type gives fixed-width enums that cannot implicitly convert to `int`.

**What C++ costs.** Honesty first: it costs you a policing job. C has essentially no features that silently require a runtime. C++ has several, and two of them (globals with constructors, and implicit `memset`) fail in ways that are not obviously about C++ at all. The next decision is entirely about neutralising that cost.

**Why not Rust.** This is the strongest rejected option and it deserves a straight answer rather than a dismissal. `no_std` Rust is a genuinely excellent kernel language. The borrow checker encodes exactly the invariants that dominate kernel debugging — who owns this page, is this reference still valid after the address space switched, can two CPUs reach this at once — and it encodes them in a form the compiler checks rather than a form you remember. Rust for Linux exists; Redox exists; the approach is proven.

It is rejected for two reasons that are about this team rather than the language. Neither member has written Rust, and the learning curve would compete directly with the OS material — you would be debugging the borrow checker at the same time as debugging paging, and you would not know which one was lying to you. And the reference corpus for this project is C and C++: OSDev, xv6, the Intel SDM's examples, and every tutorial you will fall back on at 1 a.m. Translating a page-table walk from C into Rust while you are still unsure whether the walk itself is right doubles the number of things that can be wrong.

**When Rust would be right.** If either of you already knew it. If the project were a product rather than a vehicle for learning x86_64. Or later: [[ADR-0007 - Freestanding C++20 as the Kernel Language]] explicitly flags this as worth revisiting if C++ memory bugs become the dominant time sink, and that is a real trigger, not a face-saving hedge. A rewrite of a subsystem in Rust after Phase 8 is a defensible move.

**Why not pure assembly.** You will write assembly — the ISR stubs, the context switch, the AP trampoline — because those genuinely cannot be expressed in C++. Everything else in assembly means no type checking, no structure layout the compiler maintains for you, and a memory-map copy loop that is forty instructions of manual pointer arithmetic instead of six lines. The parts that must be assembly are confined to `kernel/arch/x86_64/asm/` and inline blocks under `kernel/arch/`, which `scripts/lint.sh` enforces.

---

### Decision: which C++ features are banned, and what does each violation look like?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Ban at the flag level (chosen)** | `-fno-exceptions -fno-rtti -mno-sse -mno-mmx -mno-80387 -fno-stack-protector`, plus conventions CI greps for | A few things still slip through to link time or runtime | ✅ |
| Provide the runtime | Write an unwinder, type tables, FPU save/restore, an early allocator | Thousands of lines of infrastructure before the first line of OS | ❌ |
| Allow and hope | Ship the flags off and stay disciplined | The failures are link errors at best and triple faults at worst | ❌ |

**Why ban at the flag level.** A flag turns a class of mistake into a build failure at the exact line that made it. A convention turns the same mistake into a debugging session. Every ban below buys you a diagnostic you would otherwise not get, and the whole point is that **you should be able to recognise each error on sight**.

#### Exceptions — `-fno-exceptions`

An exception is not a language feature so much as a runtime service. `throw` calls `__cxa_allocate_exception` (which allocates — there is no allocator), then `__cxa_throw`, which hands control to an unwinder. The unwinder walks the stack using the `.eh_frame` tables the compiler emitted, and at each frame it calls a **personality routine** (`__gxx_personality_v0`) to ask whether that frame has a handler and what destructors to run. All of that is code that lives in `libgcc_eh` and `libstdc++`, neither of which we link. And there is nowhere sensible to throw *to*: an exception escaping an interrupt handler has no frame to unwind into.

*Violation with the flag on:*
```
error: exception handling disabled, use '-fexceptions' to enable
```
*Violation with the flag off* (someone drops it from one translation unit):
```
undefined reference to `__cxa_allocate_exception'
undefined reference to `__cxa_throw'
undefined reference to `__gxx_personality_v0'
undefined reference to `_Unwind_Resume'
```
You will also see `.eh_frame` sections appear in `objdump -h` output that were not there before — a useful early tell that one file lost the flag.

#### RTTI — `-fno-rtti`

`dynamic_cast` and `typeid` need a `std::type_info` object per polymorphic class, a runtime routine that walks the inheritance graph, and vtable slots pointing at it. `-fno-rtti` removes the tables, which also shrinks the image.

*Violation with the flag on:*
```
error: 'dynamic_cast' not permitted with '-fno-rtti'
error: cannot use 'typeid' with '-fno-rtti'
```
*Violation with the flag off:*
```
undefined reference to `__dynamic_cast'
undefined reference to `vtable for __cxxabiv1::__class_type_info'
```

Virtual functions themselves are **fine** and stay allowed — a vtable is a table of pointers in `.rodata` and an indirect call, no runtime required. RTTI is the separate, heavier thing.

#### The standard library

`<vector>`, `<string>`, `<iostream>`, `<memory>` assume a hosted environment: an allocator, a way to report errors by throwing, and eventually syscalls.

In this project the practical rule is simpler than the standard's: **the only headers available are GCC's freestanding C headers** — `<stdint.h>`, `<stddef.h>`, `<stdarg.h>`, `<stdbool.h>`, `<limits.h>`, `<float.h>`. There is no libstdc++ in the toolchain image, so `<type_traits>`, `<bit>`, `<atomic>` and every `<c...>` header are simply absent, and kernel builds pass `-nostdinc++` so that this fails immediately and legibly instead of depending on what happens to be installed. Anything beyond the C headers you write in `kstd::`.

*This one has no compiler diagnostic at all.* `#include <vector>` compiles. Using it produces:
```
undefined reference to `operator new(unsigned long)'
undefined reference to `operator delete(void*, unsigned long)'
undefined reference to `std::__throw_length_error(char const*)'
undefined reference to `__cxa_pure_virtual'
```
`operator new` is **deliberately not stubbed**. Providing a stub would turn a build failure into a null pointer at runtime. Phase 4 supplies the real one; until then the link error *is* the design.

#### Floating point and SSE — `-mno-sse -mno-mmx -mno-80387`

This is the ban people question, because "I was never going to use a `float` anyway". That misses the point twice.

First, the compiler will use SSE registers on its own. On x86-64 the SysV ABI passes and returns floating-point values in `xmm0`–`xmm7`, and at `-O2` GCC will happily use 16-byte SSE moves to copy structures even when no floating-point value is involved. Without `-mno-sse`, XMM registers appear in code you never suspected.

Second, and this is the real argument: **the CPU does not save FP state across an interrupt for you.** If a kernel interrupt handler touches an XMM register, it has silently clobbered whatever the interrupted context had in it — which, once there is userspace, means user data. The fix is to `fxsave`/`fxrstor` (or `xsave`/`xrstor`) on every entry and exit, which is roughly 512 bytes of copying per interrupt and a pile of code you have to get exactly right. The kernel does not use floating point, so it never has to write that code. The state save is confined to task switching in Phase 5, and only for user tasks.

*Violation:*
```
error: SSE register return with SSE disabled
error: SSE register argument with SSE disabled
error: SSE disabled
```
*Violation with the flags dropped:* an SSE instruction executes with `CR4.OSFXSR` clear (Limine makes no promise about that bit) and raises `#UD`, or with `CR0.EM`/`CR0.TS` set and raises `#NM`. Before [[Phase 2 - Overview|Phase 2]] there is no IDT, so the fault becomes a double fault, then a triple fault, then a QEMU reboot loop with nothing on the screen. This is one of the hardest "blank screen" causes to find, and it is why the flags are non-negotiable in `cmake/KernelFlags.cmake` and grepped by CI.

#### The red zone — `-mno-red-zone`

The SysV ABI lets a leaf function use 128 bytes below `RSP` without adjusting it. Hardware interrupts push their frame below `RSP` and clobber exactly that area. Covered by [[ADR-0002 - Target x86_64 Not i686]]; the symptom is random corruption of locals in small functions, appearing only when an interrupt lands at the wrong instruction — which means it appears at Phase 2 and is blamed on the IDT.

#### The stack protector — `-fno-stack-protector`

*Violation:* `undefined reference to '__stack_chk_fail'` and `undefined reference to '__stack_chk_guard'`. Harmless to diagnose, but there is no thread-local canary and no handler, so it must go.

#### Globals with non-trivial constructors — convention

This is the one with no compiler diagnostic and no link error in the common case, so it is the one that bites.

`Console g_console;` at file scope, where `Console` has a constructor, makes GCC emit an initialisation function and put a pointer to it in `.init_array`. On a hosted system the C runtime walks `.init_array` before `main`. **Nothing walks it here.** We do run global constructors eventually — step 11 of the initialisation order in [[06 - Architecture Overview]], after the heap exists — but that is Phase 4, and anything that depended on a constructor having run before then read an all-zero object out of `.bss`. If the class is polymorphic the vtable pointer is zero, and the first virtual call jumps to address 0.

*Violation, some of the time:* a non-trivial **destructor** makes GCC register it with `__cxa_atexit`, giving you
```
undefined reference to `__cxa_atexit'
undefined reference to `__dso_handle'
```
and a function-local `static` with a non-trivial constructor emits a thread-safe initialisation guard:
```
undefined reference to `__cxa_guard_acquire'
undefined reference to `__cxa_guard_release'
```
Those two are your friends — they catch the mistake at build time. The dangerous case is a global with a constructor and a trivial destructor, which links cleanly and is simply never initialised.

`BootInfo` is designed around this. It has no constructors, no destructors, no virtual functions, no members with any of those. It is an aggregate of scalars and arrays of scalars, so `static BootInfo g_boot_info;` requires nothing to run.

**When a runtime would be worth building.** If you were writing a kernel where subsystems genuinely benefit from unwinding — some research kernels do — or targeting a platform where the FPU is the only fast path for something the kernel must do. Neither applies. And Phase 4 does eventually run `.init_array`, so the ban on constructors is really a ban on *depending on them before step 11*.

---

### Decision: copy the Limine responses, or hold pointers into them?

This is the decision this stage exists for.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Copy everything into `BootInfo` (chosen)** | Walk every response to its leaves at boot; store scalars in our own struct in `.bss` | ~3.8 KiB of `.bss`; fixed capacity limits you must choose and enforce | ✅ |
| Hold Limine pointers | Store `limine_memmap_response*` and friends; read through them on demand | Dangles the moment Phase 4 reclaims the memory; leaks Limine types tree-wide | ❌ |
| Copy lazily, on first use | Same as copying, but deferred | The deadline is "before the PMM runs", which is not a point any single subsystem knows about | ❌ |
| Never reclaim bootloader memory | Mark type 5 permanently reserved so the pointers stay valid | Wastes memory forever, and still leaks Limine types into every consumer | ❌ |

**Why copy.** The lifetime question has a clean answer and a messy one, and copying picks the clean one. After `collect_boot_info()` returns, *the bootloader's memory is dead to us*. There is no ordering constraint to remember, no subsystem that has to be initialised before the PMM to grab its data first, and no invariant that a future contributor can violate without noticing. A pointer-holding design has all three.

**Why not hold pointers — the exact shape of the failure.** Suppose `BootInfo` stores `limine_memmap_response* memmap` and the PMM reads it at init. Phase 0 through Phase 3: works perfectly, because nothing has allocated anything. Phase 4, first run: also works, because the PMM reads the map to *build* its free list, and only afterwards adds the reclaimable pages to it. Phase 4, second week, after the heap lands and `kmalloc` starts serving requests: the pages that held the response are now a slab, or a page table, or a task struct. Now `boot_info->memmap->entry_count` is whatever integer happens to sit at that offset. If it is huge, the loop runs off the end and faults. If it is small, you silently lose most of your RAM. If it is zero, the PMM reports no memory at all.

The commit that "broke" it will be an allocator change. You will bisect to it, read it, and find nothing wrong, because there is nothing wrong with it. The bug is in a file you wrote months earlier that has not been touched since. That is the specific experience this stage is buying insurance against, and the premium is one afternoon and 3.8 KiB.

**Why not lazy copying.** It sounds cheaper and is strictly worse. The deadline is a global property — "before any allocation from reclaimable memory" — and no individual subsystem is in a position to know whether it has been crossed. You would end up writing an assertion that the copy already happened, which is the eager design with extra steps.

**Why not simply never reclaim.** It preserves the pointers, so it superficially works. But bootloader-reclaimable memory on a UEFI machine can run to hundreds of kilobytes, some of it low memory that Phase 12's AP trampoline actually needs (the trampoline must live below 1 MiB). More importantly it does nothing about the *coupling* problem: `kernel/mm/pmm.cpp` would still be including `limine.h`, and ADR-0003's escape hatch would still be fiction.

**The cost, stated plainly.** Copying means fixed-size arrays, because there is no heap. Fixed-size arrays mean a capacity you must choose, and a capacity means an overflow case you must handle. That is the next decision, and it is not a footnote — getting it wrong reintroduces silent data loss by a different route.

**When holding pointers would be right.** If the data were both large and read-once — a full ACPI table, say, or the contents of a module. We do exactly that for module *contents*: an initrd can be megabytes, and copying it would need a heap we do not have. What makes that safe is that module bytes are not in reclaimable memory; Limine places them in `LIMINE_MEMMAP_KERNEL_AND_MODULES` (type 6), which the PMM must never treat as usable. The rule is not "never keep a pointer", it is **never keep a pointer into memory you are going to reclaim** — and the memory map is what tells you which is which.

---

### Decision: fixed-size arrays or dynamic allocation for `regions[]` and `modules[]`?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Fixed-size arrays in `.bss` (chosen)** | `MemoryRegion regions[MAX_REGIONS];` sized at compile time | A cap you must pick, and a hard failure when it is exceeded | ✅ |
| `kmalloc` an exact-sized array | Allocate `entry_count` regions once the size is known | The heap is Phase 4. This code runs in Phase 0 | ❌ |
| A bump allocator carved out of `.bss` | Reserve a static arena, hand out slices | Same fixed cap, plus an allocator to write and debug, for no gain | ❌ |
| Walk Limine's map on demand instead of storing it | No array at all | That is "hold pointers", already rejected | ❌ |

**Why fixed-size.** The forcing constraint is not aesthetic: **`collect_boot_info()` runs before a heap can possibly exist**, because the heap is built on the PMM and the PMM is built on the memory map that this function produces. The dependency is circular and the only way out is storage that needs no allocator. Look at the initialisation order in [[06 - Architecture Overview]]: `boot_info` is step 2, the PMM is step 8, the heap is step 10. Nothing before step 10 can allocate.

**Choosing `MAX_REGIONS`.** The number has to cover the worst real map, not the QEMU map you will develop against.

| Environment | Typical entry count |
|---|---|
| QEMU, BIOS boot, `-m 512M` | 8–12 |
| QEMU, UEFI (OVMF) | 15–25 |
| Real UEFI laptop, after Limine merges the EFI map | commonly 30–70 |

**128 is the choice here.** It is comfortably above the worst case anyone reports, and the cost is `128 × 24 = 3072` bytes of `.bss` — about 0.0006% of a 512 MiB machine. The asymmetry is total: over-provisioning costs nothing you will ever notice, under-provisioning costs a boot failure on the one machine that matters (someone's actual laptop, in [[Phase 15 - Overview|Phase 15]]). When a limit is this cheap, pick a number nothing plausible reaches and stop thinking about it.

`MAX_MODULES = 8` is different in character: it is bounded by `boot/limine.conf`, which we write. Eight is generous for a config that lists one initrd, and exceeding it means someone edited the config, which is exactly when a loud failure is helpful.

`MAX_MODULE_PATH = 64` bytes bounds the copied path string. Paths here look like `/boot/initrd.tar`; 64 is roomy, and truncation is survivable because the path is diagnostic, not load-bearing.

**What to do on overflow — and why truncation is wrong.** Silently keeping the first `MAX_REGIONS` entries is the tempting one-liner and it is a correctness disaster in both directions:

- If the dropped entries are `USABLE`, the PMM never learns about that RAM. A 16 GiB machine boots with 4 GiB. Nothing reports an error; you just have less memory than you paid for, and the number is plausible enough that you will not question it for months.
- If the dropped entries are `RESERVED` or MMIO, it is worse. The PMM does not know that range is off limits — the map is not contiguous, so "not mentioned" does not mean "not there" — and eventually hands a device's MMIO aperture out as ordinary RAM. Writing to it does whatever that device does. The resulting bug is not even in software.

So: **halt, loudly, with a distinct code.** `boot_halt(BOOT_FAIL_TOO_MANY_REGIONS)` is correct today. From [[Stage 0.7 - Panic and KASSERT]] it becomes `panic("memory map has %llu entries, MAX_REGIONS is %zu", ...)`, which tells you the number to raise it to. Refusing to boot on a machine you cannot describe correctly is the right behaviour; booting with a wrong description is not.

**When dynamic allocation would be right.** From Phase 4 onward, for anything else. `kstd::vector` exists once the heap does, and by Phase 9 the block layer and VFS use it freely. This is a Phase 0 constraint, not a house style — and the discipline of a hard cap with a hard failure is still the right shape for anything that must work before the allocator.

---

### Decision: static `BootInfo`, or build it on the stack and copy it up?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **`static BootInfo g_boot_info;` in `boot_info.cpp` (chosen)** | One instance in `.bss`, zeroed by the ELF loader, address fixed at link time | ~3.8 KiB permanently resident; one global | ✅ |
| Local `BootInfo` in `collect_boot_info()` | Fill a stack temporary, return a pointer to it | Returns a dangling pointer; also a ~3.8 KiB stack frame | ❌ |
| Local, returned **by value** | Fill on the stack, copy out to the caller's storage | The copy is a ~3.8 KiB struct assignment — GCC emits a call to `memcpy`, which does not exist | ❌ |
| `static BootInfo` with a constructor | Encapsulate the filling in a constructor | Exactly the banned case: nothing has run `.init_array` | ❌ |

**Why static.** It survives (`.bss` is part of the kernel image and mapped forever), it needs no allocator, it needs no code to come into existence, and its address is a link-time constant so there is nothing to get wrong. It costs one global, which [[13 - Coding Standards]] permits with the `g_` prefix and which is honest: there *is* exactly one machine.

**Why not the stack.** Returning `&local` from `collect_boot_info()` is a dangling pointer, and here it is the treacherous kind: the frame is not immediately overwritten, so the first few reads in `kernel_init()` return correct data. It breaks when the call depth grows, which is to say when you add the next subsystem. There is a second problem — Limine's default stack is not large, and a 3.8 KiB frame is a meaningful bite out of it with no guard page until Stage 0.4.

**Why not return by value.** This is the subtle one and it is worth understanding, because the same mechanism causes the `memset` trap in §7. Returning a 3808-byte aggregate makes the caller pass a hidden pointer to its own storage, and GCC implements the copy as a **call to `memcpy`**. `-ffreestanding` does not stop it: GCC still assumes the four block functions `memcpy`, `memmove`, `memset` and `memcmp` are available, because the C standard requires a freestanding implementation to provide them. We have not written them yet. The result is
```
undefined reference to `memcpy'
```
from a line of code that contains no function call at all.

**Why a static with a constructor is exactly the banned case.** It is tempting to write:

```cpp
static BootInfo g_boot_info{collect_from_limine()};   // NO
```

That gives `g_boot_info` a non-trivial initialiser, so GCC emits an initialisation function, puts it in `.init_array`, and **nothing calls it**. `g_boot_info` stays all-zero. `kmain` then hands `kernel_init` a struct claiming zero memory regions, no framebuffer, and an HHDM offset of zero — a perfectly well-formed description of a machine that does not exist. There is no compiler warning, no link error, and no fault until something divides by `region_count`.

The right shape is the boring one: a trivially constructible aggregate, plus an explicit `collect_boot_info()` that fills it and is called from a place you control. That is the same pattern as [[13 - Coding Standards]] rule 9 and the same reason.

**When a stack-local would be right.** If `BootInfo` were small — a few dozen bytes — and `kmain` kept it alive in its own frame for the lifetime of the kernel, since `kmain` never returns. That is a real technique and some kernels use it. It stops being reasonable at kilobyte scale with an unmeasured stack, and it makes the struct's lifetime depend on a fact about `kmain` that is not visible from anywhere else.

---

## 4. Specification

### Limine response structures — real field names

From the vendored `kernel/arch/x86_64/boot/limine.h`. `LIMINE_API_REVISION` is **not** defined by us, so it defaults to `0`, which decides several names below. `LIMINE_PTR(T)` expands to plain `T` unless `LIMINE_NO_POINTERS` is defined (it exists so a 32-bit loader can see pointer fields as `uint64_t`); we do not define it, so every `LIMINE_PTR(void *)` is just `void *`.

| Request type | Response type | Response fields |
|---|---|---|
| `limine_memmap_request` | `limine_memmap_response` | `revision`, `entry_count` (`uint64_t`), `entries` (`struct limine_memmap_entry **`) |
| `limine_hhdm_request` | `limine_hhdm_response` | `revision`, `offset` (`uint64_t`) |
| `limine_kernel_address_request` | `limine_kernel_address_response` | `revision`, `physical_base`, `virtual_base` (both `uint64_t`) |
| `limine_framebuffer_request` | `limine_framebuffer_response` | `revision`, `framebuffer_count` (`uint64_t`), `framebuffers` (`struct limine_framebuffer **`) |
| `limine_module_request` | `limine_module_response` | `revision`, `module_count` (`uint64_t`), `modules` (`struct limine_file **`) |
| `limine_rsdp_request` | `limine_rsdp_response` | `revision`, `address` |

Every request struct has the same first three members: `uint64_t id[4]`, `uint64_t revision`, and a `response` pointer. `limine_module_request` adds `internal_module_count` and `internal_modules` at request revision 1.

**Two names that change with the API revision.** At `LIMINE_API_REVISION >= 2` the kernel-address request is renamed `limine_executable_address_request` / `..._response`, and `LIMINE_MEMMAP_KERNEL_AND_MODULES` becomes `LIMINE_MEMMAP_EXECUTABLE_AND_MODULES`. At `LIMINE_API_REVISION >= 1`, `limine_rsdp_response::address` changes from `void *` to `uint64_t`, and its meaning changes from a direct-map virtual address to a physical one. We are at revision 0. If you ever define that macro, `boot_info.cpp` is the only file that has to change — which is the whole point of the barrier. Check the vendored header rather than trusting this table if the pinned Limine version moves.

`limine_memmap_entry`:

| Field | Type | Meaning |
|---|---|---|
| `base` | `uint64_t` | Physical base address, byte-granular |
| `length` | `uint64_t` | Length in bytes |
| `type` | `uint64_t` | One of the constants below |

`limine_framebuffer` — note the field order, which is **not** the same as `limine_video_mode`:

| Field | Type | Notes |
|---|---|---|
| `address` | `void *` | **Virtual** address, inside the direct map Limine set up |
| `width`, `height`, `pitch` | `uint64_t` | `pitch` is bytes per scanline, and is **not** `width * bpp / 8` |
| `bpp` | `uint16_t` | Bits per pixel |
| `memory_model` | `uint8_t` | `LIMINE_FRAMEBUFFER_RGB` is `1` |
| `red_mask_size`, `red_mask_shift` | `uint8_t` | And the green and blue equivalents |
| `edid_size`, `edid` | `uint64_t`, `void *` | Ignored in Phase 0 |
| `mode_count`, `modes` | response revision 1 | Ignored in Phase 0 |

`limine_file` — the module descriptor:

| Field | Type | Notes |
|---|---|---|
| `revision` | `uint64_t` | |
| `address` | `void *` | **Virtual**, in the direct map; the module's bytes |
| `size` | `uint64_t` | Bytes |
| `path`, `cmdline` | `char *` | **Into reclaimable memory — must be copied** |
| `media_type`, `partition_index`, `mbr_disk_id`, the three `limine_uuid`s | | Provenance; unused here |

### Memory-map type constants and our mapping

| Limine constant | Value | Our `MemoryType` | What Phase 4 does with it |
|---|---|---|---|
| `LIMINE_MEMMAP_USABLE` | 0 | `USABLE` | Free list |
| `LIMINE_MEMMAP_RESERVED` | 1 | `RESERVED` | Never touch |
| `LIMINE_MEMMAP_ACPI_RECLAIMABLE` | 2 | `ACPI_RECLAIMABLE` | Free after Phase 11 parses the tables |
| `LIMINE_MEMMAP_ACPI_NVS` | 3 | `ACPI_NVS` | Never touch |
| `LIMINE_MEMMAP_BAD_MEMORY` | 4 | `BAD_MEMORY` | Never touch |
| `LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE` | 5 | `BOOTLOADER_RECLAIMABLE` | **Free list — this is the memory this stage exists to escape** |
| `LIMINE_MEMMAP_KERNEL_AND_MODULES` | 6 | `KERNEL_AND_MODULES` | Never free: our image and the initrd |
| `LIMINE_MEMMAP_FRAMEBUFFER` | 7 | `FRAMEBUFFER` | Never free; mapped write-combining in Phase 4 |
| anything else | — | `RESERVED` | Conservative default |

### Properties of the memory map you may and may not rely on

- It is **not contiguous.** Ranges are separated by holes that are simply not described — most obviously the PCI hole below 4 GiB. "Not mentioned" does not mean "usable"; it means "unknown", and unknown means do not touch.
- **Do not depend on the order.** Limine's `PROTOCOL.md` states the entries are sorted by base address; check the document for the tag you pinned before relying on it, because the raw E820 and UEFI maps underneath are not sorted and no other bootloader promises it. Nothing in `collect_boot_info()` needs the property, and nothing later should either. Treat it as an unordered list of ranges: if Phase 4 wants it sorted, Phase 4 sorts it.
- Usable regions are page-aligned in base and length and do not overlap other entries. Non-usable regions carry weaker guarantees and may overlap each other. Confirm the exact wording in `PROTOCOL.md` before Phase 4 leans on it.
- `entry_count` can legitimately be large on real UEFI hardware. It cannot legitimately be zero.

### `.limine_requests` sizes, for verifying the object file

| Object | Bytes |
|---|---|
| `limine_base_revision[3]` | 24 |
| `limine_framebuffer_request` | 48 |
| `limine_memmap_request` | 48 |
| `limine_hhdm_request` | 48 |
| `limine_kernel_address_request` | 48 |
| `limine_module_request` (request revision 1) | 64 |
| `limine_rsdp_request` | 48 |
| **`.limine_requests` total** | **328 (0x148)** |
| `.limine_requests_start` (`limine_requests_start_marker[4]`) | 32 |
| `.limine_requests_end` (`limine_requests_end_marker[2]`) | 16 |

### `BootInfo` layout and `.bss` cost

| Member | Type | Bytes | Source |
|---|---|---|---|
| `fb_present` (+7 pad) | `bool` | 8 | `framebuffer_count > 0` |
| `fb_addr` | `uintptr_t` | 8 | `framebuffers[0]->address` |
| `fb_width`, `fb_height`, `fb_pitch` | `uint64_t` | 24 | same |
| `fb_bpp` + six mask bytes | `uint16_t`, `uint8_t[6]` | 8 | same |
| `regions` | `MemoryRegion[128]` | 3072 | memmap entries |
| `region_count` | `size_t` | 8 | `entry_count` |
| `hhdm_offset` | `uintptr_t` | 8 | `hhdm->offset` |
| `kernel_phys_base`, `kernel_virt_base` | `uintptr_t` | 16 | kernel-address response |
| `modules` | `Module[8]` | 640 | module descriptors + copied paths |
| `module_count` | `size_t` | 8 | `module_count` |
| `rsdp_addr` | `uintptr_t` | 8 | `rsdp->address` |
| **Total** | | **3808** | |

`sizeof(MemoryRegion) == 24`, `sizeof(Module) == 16 + MAX_MODULE_PATH == 80`. Both are pinned by `static_assert`.

### Boot-halt codes

There is no serial port until [[Stage 0.6 - Serial Output]] and no `panic()` until [[Stage 0.7 - Panic and KASSERT]]. Until then a fatal boot error parks the CPU with a recognisable 64-bit value in `RDI`, read back in the QEMU monitor with `info registers`. The high half spells the category; the low half says which check fired.

| Constant | Value | Fires when |
|---|---|---|
| `BOOT_HALT_OK` | `0xB007C0DE00000000` | `kernel_init` returned — the expected end of Stage 0.3 |
| `BOOT_FAIL_BASE_REVISION` | `0xB007FA1100000001` | Limine does not support our base revision |
| `BOOT_FAIL_NO_MEMMAP` | `0xB007FA1100000002` | memmap response is null |
| `BOOT_FAIL_EMPTY_MEMMAP` | `0xB007FA1100000003` | `entry_count == 0` |
| `BOOT_FAIL_TOO_MANY_REGIONS` | `0xB007FA1100000004` | `entry_count > MAX_REGIONS` |
| `BOOT_FAIL_NO_HHDM` | `0xB007FA1100000005` | HHDM response is null |
| `BOOT_FAIL_NO_KERNEL_ADDRESS` | `0xB007FA1100000006` | kernel-address response is null |
| `BOOT_FAIL_TOO_MANY_MODULES` | `0xB007FA1100000007` | `module_count > MAX_MODULES` |

`0xB007FA11` reads as `BOOTFAIL` and `0xB007C0DE` as `BOOTCODE`, which is the entire justification: you will recognise them in a register dump without looking anything up.

### Required versus optional responses

| Response | Required? | If missing |
|---|---|---|
| memmap | **yes** | `boot_halt` — nothing works without a memory map |
| HHDM | **yes** | `boot_halt` — Phase 4 cannot address physical memory without it |
| kernel address | **yes** | `boot_halt` — needed for backtraces and for Phase 4's self-reservation |
| framebuffer | no | `fb_present = false`; a headless machine must still boot |
| modules | no | `module_count = 0`; there is no initrd until Phase 7 |
| RSDP | no | `rsdp_addr = 0`; Phase 11 decides what to do about it |

---

## 5. Writing the code

Four files, in this order: the header first, because everything else refers to it; then the translation step; then the boundary; then the entry point that ties them together.

### `kernel/include/kernel/boot_info.hpp`

The kernel's own description of the machine. Nothing in this header knows what a bootloader is, and that is the requirement it exists to satisfy.

```cpp
// kernel/include/kernel/boot_info.hpp
//
// The kernel's own description of the machine, copied out of the bootloader's
// responses at boot. Nothing here knows what a bootloader is.
//
// See ADR-0003 (Limine is confined to kernel/arch/x86_64/boot/) and
// 06 - Architecture Overview (initialisation order).

#pragma once

#include <stddef.h>
#include <stdint.h>

// --- Capacity limits -------------------------------------------------------
//
// There is no heap until Phase 4, so every array here is fixed size. These
// numbers are policy, not hardware limits. Overflow is fatal, never silent.

inline constexpr size_t MAX_REGIONS     = 128;  // memory map entries
inline constexpr size_t MAX_MODULES     = 8;    // files loaded beside us
inline constexpr size_t MAX_MODULE_PATH = 64;   // bytes, including the NUL

// --- Memory map ------------------------------------------------------------
//
// Our own type, deliberately not the bootloader's. The numeric values happen
// to match Limine's today; boot_info.cpp translates explicitly anyway, so a
// bootloader change is one switch statement rather than a tree-wide audit.

enum class MemoryType : uint32_t {
    USABLE                 = 0,  // free RAM, ours to allocate
    RESERVED               = 1,  // firmware or MMIO; never touch
    ACPI_RECLAIMABLE       = 2,  // ACPI tables; free after Phase 11 parses them
    ACPI_NVS               = 3,  // ACPI non-volatile storage; never touch
    BAD_MEMORY             = 4,  // firmware reports this RAM as faulty
    BOOTLOADER_RECLAIMABLE = 5,  // the bootloader's memory, incl. its responses
    KERNEL_AND_MODULES     = 6,  // our image and the initrd
    FRAMEBUFFER            = 7,  // the linear framebuffer
};

struct MemoryRegion {
    uint64_t   base;      // physical, byte-granular
    uint64_t   length;    // bytes
    MemoryType type;
    uint32_t   reserved;  // explicit padding: sizeof is a fact, not folklore
};
static_assert(sizeof(MemoryRegion) == 24, "MemoryRegion layout changed");

// --- Modules ---------------------------------------------------------------

struct Module {
    uintptr_t addr;                   // virtual address of the module's bytes
    uint64_t  size;                   // bytes
    char      path[MAX_MODULE_PATH];  // copied, NUL-terminated, may truncate
};
static_assert(sizeof(Module) == 16 + MAX_MODULE_PATH, "unexpected padding");

// --- Everything the kernel knows about the machine at boot -----------------

struct BootInfo {
    // Framebuffer. fb_present is false if the firmware gave us no display.
    bool      fb_present;
    uintptr_t fb_addr;  // virtual, inside the bootloader's direct map
    uint64_t  fb_width, fb_height, fb_pitch;
    uint16_t  fb_bpp;
    uint8_t   fb_red_shift, fb_green_shift, fb_blue_shift;
    uint8_t   fb_red_size,  fb_green_size,  fb_blue_size;

    // Memory. Treat as an unordered list of ranges; it is NOT contiguous.
    MemoryRegion regions[MAX_REGIONS];
    size_t       region_count;
    uintptr_t    hhdm_offset;

    // Kernel placement — needed to symbolise a backtrace in Stage 1.7.
    uintptr_t kernel_phys_base, kernel_virt_base;

    // Modules — the initrd, from Phase 7 onward.
    Module modules[MAX_MODULES];
    size_t module_count;

    // ACPI. Zero means the bootloader did not find an RSDP.
    uintptr_t rsdp_addr;
};

// --- Boot-time failure reporting -------------------------------------------
//
// No serial until Stage 0.6, no panic() until Stage 0.7. Until then a fatal
// boot error parks the CPU with a recognisable value in RDI, which you read
// in the QEMU monitor with `info registers`. Stage 0.7 replaces every call
// site with panic().

inline constexpr uint64_t BOOT_HALT_OK                = 0xB007C0DE00000000ULL;
inline constexpr uint64_t BOOT_FAIL_BASE_REVISION     = 0xB007FA1100000001ULL;
inline constexpr uint64_t BOOT_FAIL_NO_MEMMAP         = 0xB007FA1100000002ULL;
inline constexpr uint64_t BOOT_FAIL_EMPTY_MEMMAP      = 0xB007FA1100000003ULL;
inline constexpr uint64_t BOOT_FAIL_TOO_MANY_REGIONS  = 0xB007FA1100000004ULL;
inline constexpr uint64_t BOOT_FAIL_NO_HHDM           = 0xB007FA1100000005ULL;
inline constexpr uint64_t BOOT_FAIL_NO_KERNEL_ADDRESS = 0xB007FA1100000006ULL;
inline constexpr uint64_t BOOT_FAIL_TOO_MANY_MODULES  = 0xB007FA1100000007ULL;

[[noreturn]] void boot_halt(uint64_t code);

// --- The two functions that join the boot layer to the kernel --------------

[[nodiscard]] BootInfo* collect_boot_info();  // arch/x86_64/boot/boot_info.cpp
void kernel_init(BootInfo* info);             // kernel/main.cpp
```

#### Line by line

**Lines 9–12 — the preamble**
```cpp
#pragma once

#include <stddef.h>
#include <stdint.h>
```
`#pragma once` per [[13 - Coding Standards]]. Both includes are freestanding-safe — `<stddef.h>` for `size_t`, `<stdint.h>` for the fixed-width types — and neither pulls in a runtime. List both rather than relying on one dragging in the other, which is not guaranteed across libstdc++ versions.

**Lines 19–21 — the capacity limits**
```cpp
inline constexpr size_t MAX_REGIONS     = 128;
inline constexpr size_t MAX_MODULES     = 8;
inline constexpr size_t MAX_MODULE_PATH = 64;
```
`inline constexpr` at namespace scope (C++17) gives one shared object across all translation units with no `.cpp` definition, and `constexpr` makes them usable as array bounds. Not macros: a macro has no type and does not respect scope. The numbers are argued in §3; what matters here is that they are *named*, so the overflow check in `boot_info.cpp` and the array bound cannot drift apart.

**Lines 29–38 — `MemoryType`**
```cpp
enum class MemoryType : uint32_t {
    USABLE                 = 0,
    RESERVED               = 1,
    // ...
    FRAMEBUFFER            = 7,
};
```
Three deliberate choices.

*`enum class`, not a plain `enum`.* A plain enum leaks its enumerators into the enclosing scope — `USABLE` would become a global name — and converts implicitly to `int`, so `if (region.type == 5)` would compile. With `enum class` you must write `MemoryType::USABLE`, and comparing against a bare integer is an error.

*`: uint32_t`, an explicit underlying type.* Without it the enum's size is implementation-defined. With it, `MemoryType` is exactly four bytes, which is what makes `sizeof(MemoryRegion) == 24` a fact rather than an accident. Any type appearing in a struct whose layout you care about needs a fixed width.

*Values written out explicitly*, so that reordering the list cannot silently renumber them.

The values match Limine's today, and `map_memory_type()` still translates explicitly rather than casting. A cast would work and would be wrong: it makes the coincidence load-bearing, and the day Limine adds type 8 you get an out-of-range enum value with no diagnostic.

**Lines 40–46 — `MemoryRegion`**
```cpp
struct MemoryRegion {
    uint64_t   base;
    uint64_t   length;
    MemoryType type;
    uint32_t   reserved;
};
static_assert(sizeof(MemoryRegion) == 24, "MemoryRegion layout changed");
```
`base` and `length` are `uint64_t`, not `uintptr_t`, on purpose. These are **physical** addresses. `uintptr_t` means "an integer that can hold a pointer", which is a claim about the virtual address space; a physical address is not a pointer and must never be dereferenced. Phase 4 replaces this with the real `PhysAddr` wrapper from [[13 - Coding Standards]] rule 1.

`reserved` is explicit padding. The compiler would insert four anonymous bytes anyway to align the struct to eight; writing them down makes `sizeof` predictable, the `static_assert` meaningful, and leaves no uninitialised gap. Cost: nothing.

The `static_assert` fires if anyone adds a field or changes a type. It is the cheapest possible regression test — a table from §4 that the compiler checks.

**Lines 50–55 — `Module`**
```cpp
struct Module {
    uintptr_t addr;
    uint64_t  size;
    char      path[MAX_MODULE_PATH];
};
static_assert(sizeof(Module) == 16 + MAX_MODULE_PATH, "unexpected padding");
```
`addr` **is** `uintptr_t` here, unlike `MemoryRegion::base`, because Limine gives module addresses as virtual addresses inside its direct map — you can dereference this one. The inconsistency is real information, and the header comment says so.

`path` is an inline array, not a `const char*`. That is the whole point: a pointer would point into bootloader-reclaimable memory and dangle. 512 bytes of `.bss` buys paths that outlive the bootloader.

The `static_assert` is written `16 + MAX_MODULE_PATH` rather than `80` so retuning the limit does not break it, while still catching unexpected padding.

**Lines 59–67 — the framebuffer block**
```cpp
    bool      fb_present;
    uintptr_t fb_addr;
    uint64_t  fb_width, fb_height, fb_pitch;
    uint16_t  fb_bpp;
    uint8_t   fb_red_shift, fb_green_shift, fb_blue_shift;
    uint8_t   fb_red_size,  fb_green_size,  fb_blue_size;
```
`fb_present` exists because a machine can legitimately have no display, and a kernel that refuses to boot on one is not deployable — the same reasoning as the serial self-test in [[Stage 0.6 - Serial Output]]. Without the flag, Phase 1 must infer "no framebuffer" from `fb_addr == 0`, conflating "absent" with "the bootloader handed us address zero".

`fb_pitch` is bytes per scanline and is **not** derivable from width and bpp — hardware rounds scanlines up to an alignment boundary. Phase 1's `putpixel` is `fb_addr + y * fb_pitch + x * (fb_bpp / 8)`; using `width * 4` instead of `pitch` gives a picture that shears diagonally, a distinctive and very common first-framebuffer bug.

The mask **sizes** are stored alongside the shifts. The earlier sketch of this struct carried only the shifts, and shifts alone are not enough: `(red & ((1 << red_size) - 1)) << red_shift` needs both halves. Storing only the shift works by accident on the 8/8/8 modes QEMU gives you and breaks on 5/6/5.

**Lines 69–71 — the memory block**
```cpp
    MemoryRegion regions[MAX_REGIONS];
    size_t       region_count;
    uintptr_t    hhdm_offset;
```
The array is by value, inline in the struct. That is what makes `BootInfo` self-contained: not one pointer in it points outside the kernel image.

`region_count` is separate from the array because 128 entries are allocated and only `region_count` of them are valid. Reading past it gives zeroes, which look like a zero-length region at address zero — plausible enough to confuse you. **Every loop over `regions` is bounded by `region_count`, never by `MAX_REGIONS`.**

`hhdm_offset` is the direct-map base: physical address `p` is readable at virtual `p + hhdm_offset`. Stored rather than hardcoded even though [[06 - Architecture Overview]] documents it as `0xFFFF800000000000`, because that is the 4-level-paging value and it differs under 5-level.

**Lines 73–81 — kernel placement, modules, ACPI**
```cpp
    uintptr_t kernel_phys_base, kernel_virt_base;
    Module modules[MAX_MODULES];
    size_t module_count;
    uintptr_t rsdp_addr;
```
`kernel_phys_base` and `kernel_virt_base` let you convert an address in a backtrace back into a file offset in `kernel.elf`, which is what Stage 1.7's symboliser does. They are also what Phase 4 uses to reserve the kernel's own pages — you know where the image is in virtual terms from the linker script, but the PMM works in physical addresses, and this pair is the bridge.

`rsdp_addr` is zero when absent, which is a usable sentinel because zero is never a valid RSDP address.

**Lines 91–100 — the boot-halt interface**
```cpp
inline constexpr uint64_t BOOT_HALT_OK = 0xB007C0DE00000000ULL;
// ...
[[noreturn]] void boot_halt(uint64_t code);
```
`ULL` on every literal. Without a suffix, `0xB007C0DE00000000` exceeds `int` and the compiler picks a type for you; being explicit costs three characters and removes the question.

`[[noreturn]]` is doing real work here, not documentation. It tells the compiler that control does not come back, so code after a `boot_halt()` call is unreachable. Without it, `collect_boot_info()` produces "may be used uninitialised" warnings on the paths that halt, and `-Werror` turns those into build failures.

The declaration lives in this header rather than an arch-private one so that both `entry.cpp` and `boot_info.cpp` see the same codes and there is one table. It is a declaration only — no inline assembly appears in `kernel/include/`, so the "no asm outside `kernel/arch/`" rule in `scripts/lint.sh` is satisfied. Stage 0.7 deletes this block and replaces the call sites with `panic()`.

**Lines 104–105 — the two boundary functions**
```cpp
[[nodiscard]] BootInfo* collect_boot_info();
void kernel_init(BootInfo* info);
```
These two declarations *are* the barrier, expressed in code. Above them is arch-specific, bootloader-aware; below them is the kernel. Both signatures mention only our own types.

`[[nodiscard]]` per [[13 - Coding Standards]] rule 6: calling `collect_boot_info()` and throwing the result away is meaningless, and `-Werror` makes it a build failure.

`kernel_init` is declared here rather than in a header of its own only because there is exactly one such function today. When Stage 0.8 brings the real CMake build and a second entry point, move it to `kernel/include/kernel/init.hpp`.

---

### `kernel/arch/x86_64/boot/boot_info.cpp`

Translates every Limine response into `BootInfo`. Together with `entry.cpp`, the only file in the tree that may include `limine.h`.

```cpp
// kernel/arch/x86_64/boot/boot_info.cpp
//
// Translates Limine's responses into our own BootInfo. Together with
// entry.cpp this is the only code in the tree that includes limine.h.
//
// Everything here runs exactly once, before anything else exists: no serial,
// no IDT, no heap, no locks, no other CPU.

#include <kernel/boot_info.hpp>

#include <stddef.h>
#include <stdint.h>

#include "limine.h"

// ---------------------------------------------------------------------------
// The requests are DEFINED in entry.cpp. Limine requires every request to sit
// between the start and end markers in memory, and the cheap way to guarantee
// that is to keep them all in one translation unit, in declaration order.
// These declarations must match those definitions exactly, volatile included.
// ---------------------------------------------------------------------------

extern volatile limine_memmap_request         memmap_request;
extern volatile limine_hhdm_request           hhdm_request;
extern volatile limine_kernel_address_request kernel_address_request;
extern volatile limine_framebuffer_request    framebuffer_request;
extern volatile limine_module_request         module_request;
extern volatile limine_rsdp_request           rsdp_request;

// ---------------------------------------------------------------------------
// Storage. Static, so it lives in .bss inside the kernel image and outlives
// everything. Trivially constructible, so nothing has to run to create it.
// ---------------------------------------------------------------------------

static BootInfo g_boot_info;

// ---------------------------------------------------------------------------
// Park the CPU with `code` in RDI. Read it back in the QEMU monitor with
// `info registers`. Replaced by panic() in Stage 0.7.
// ---------------------------------------------------------------------------

[[noreturn]] void boot_halt(uint64_t code) {
    __asm__ volatile("cli" ::: "memory");
    for (;;) {
        // "D" pins `code` in RDI. The operand is inside the loop so the
        // compiler cannot decide the value is dead and reuse the register.
        __asm__ volatile("hlt" :: "D"(code) : "memory");
    }
}

// ---------------------------------------------------------------------------
// Limine's memory-map type -> ours. Explicit, exhaustive, conservative:
// anything we do not recognise becomes RESERVED, never USABLE.
// ---------------------------------------------------------------------------

static MemoryType map_memory_type(uint64_t limine_type) {
    switch (limine_type) {
    case LIMINE_MEMMAP_USABLE:                 return MemoryType::USABLE;
    case LIMINE_MEMMAP_RESERVED:               return MemoryType::RESERVED;
    case LIMINE_MEMMAP_ACPI_RECLAIMABLE:       return MemoryType::ACPI_RECLAIMABLE;
    case LIMINE_MEMMAP_ACPI_NVS:               return MemoryType::ACPI_NVS;
    case LIMINE_MEMMAP_BAD_MEMORY:             return MemoryType::BAD_MEMORY;
    case LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE: return MemoryType::BOOTLOADER_RECLAIMABLE;
    case LIMINE_MEMMAP_KERNEL_AND_MODULES:     return MemoryType::KERNEL_AND_MODULES;
    case LIMINE_MEMMAP_FRAMEBUFFER:            return MemoryType::FRAMEBUFFER;
    default:                                   return MemoryType::RESERVED;
    }
}

// ---------------------------------------------------------------------------
// strncpy does not exist: there is no libc. Always NUL-terminates, truncates
// rather than overruns, tolerates a null source.
// ---------------------------------------------------------------------------

static void copy_string(char* dst, size_t dst_size, const char* src) {
    if (dst_size == 0) {
        return;
    }
    if (src == nullptr) {
        dst[0] = '\0';
        return;
    }
    size_t i = 0;
    while (i + 1 < dst_size && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

// ---------------------------------------------------------------------------
// The one job of this file.
// ---------------------------------------------------------------------------

BootInfo* collect_boot_info() {
    BootInfo& bi = g_boot_info;  // already all-zero: it is in .bss

    // --- Memory map. Required. ---------------------------------------------
    limine_memmap_response* memmap = memmap_request.response;
    if (memmap == nullptr) {
        boot_halt(BOOT_FAIL_NO_MEMMAP);
    }
    if (memmap->entry_count == 0) {
        boot_halt(BOOT_FAIL_EMPTY_MEMMAP);
    }
    if (memmap->entry_count > MAX_REGIONS) {
        // Truncating would hide RAM from the Phase 4 allocator, or hide an
        // MMIO hole and let it hand out device memory. Stop instead.
        boot_halt(BOOT_FAIL_TOO_MANY_REGIONS);
    }
    for (uint64_t i = 0; i < memmap->entry_count; ++i) {
        // `entries` is an array of POINTERS to entries, not an array of
        // entries. Getting this wrong reads garbage that looks plausible.
        const limine_memmap_entry* e = memmap->entries[i];
        bi.regions[i].base     = e->base;
        bi.regions[i].length   = e->length;
        bi.regions[i].type     = map_memory_type(e->type);
        bi.regions[i].reserved = 0;
    }
    bi.region_count = static_cast<size_t>(memmap->entry_count);

    // --- HHDM offset. Required. --------------------------------------------
    limine_hhdm_response* hhdm = hhdm_request.response;
    if (hhdm == nullptr) {
        boot_halt(BOOT_FAIL_NO_HHDM);
    }
    bi.hhdm_offset = static_cast<uintptr_t>(hhdm->offset);

    // --- Where our own image landed. Required. -----------------------------
    limine_kernel_address_response* ka = kernel_address_request.response;
    if (ka == nullptr) {
        boot_halt(BOOT_FAIL_NO_KERNEL_ADDRESS);
    }
    bi.kernel_phys_base = static_cast<uintptr_t>(ka->physical_base);
    bi.kernel_virt_base = static_cast<uintptr_t>(ka->virtual_base);

    // --- Framebuffer. Optional: a machine may genuinely have no display. ---
    limine_framebuffer_response* fbr = framebuffer_request.response;
    if (fbr != nullptr && fbr->framebuffer_count > 0) {
        const limine_framebuffer* fb = fbr->framebuffers[0];
        bi.fb_present     = true;
        bi.fb_addr        = reinterpret_cast<uintptr_t>(fb->address);
        bi.fb_width       = fb->width;
        bi.fb_height      = fb->height;
        bi.fb_pitch       = fb->pitch;
        bi.fb_bpp         = fb->bpp;
        bi.fb_red_shift   = fb->red_mask_shift;
        bi.fb_green_shift = fb->green_mask_shift;
        bi.fb_blue_shift  = fb->blue_mask_shift;
        bi.fb_red_size    = fb->red_mask_size;
        bi.fb_green_size  = fb->green_mask_size;
        bi.fb_blue_size   = fb->blue_mask_size;
    } else {
        bi.fb_present = false;  // Stage 0.6 will say so over serial.
    }

    // --- Modules. Optional now, load-bearing from Phase 7. -----------------
    limine_module_response* mods = module_request.response;
    if (mods != nullptr) {
        if (mods->module_count > MAX_MODULES) {
            boot_halt(BOOT_FAIL_TOO_MANY_MODULES);
        }
        for (uint64_t i = 0; i < mods->module_count; ++i) {
            const limine_file* f = mods->modules[i];
            bi.modules[i].addr = reinterpret_cast<uintptr_t>(f->address);
            bi.modules[i].size = f->size;
            // The path string lives in reclaimable memory too. Copy it.
            copy_string(bi.modules[i].path, MAX_MODULE_PATH, f->path);
        }
        bi.module_count = static_cast<size_t>(mods->module_count);
    } else {
        bi.module_count = 0;
    }

    // --- ACPI RSDP. Optional: Phase 11 decides what to do without it. ------
    limine_rsdp_response* rsdp = rsdp_request.response;
    if (rsdp != nullptr) {
        // API revision 0: `address` is a void* into the direct map. At
        // LIMINE_API_REVISION >= 1 it becomes a uint64_t PHYSICAL address.
        bi.rsdp_addr = reinterpret_cast<uintptr_t>(rsdp->address);
    } else {
        bi.rsdp_addr = 0;
    }

    return &bi;
}
```

#### Line by line

**Lines 8–15 — includes, in the mandated order**
```cpp
#include <kernel/boot_info.hpp>

#include <stddef.h>
#include <stdint.h>

#include "limine.h"
```
[[13 - Coding Standards]] orders includes: own header, then kernel headers, then freestanding `<...>`. `limine.h` is vendored third-party code and goes last, in quotes because it sits in this directory and is found by the compiler's local search. `<stddef.h>` and `<stdint.h>` are listed even though `boot_info.hpp` already pulls them in — include what you use.

This is the line CI greps for. If it appears in a file outside `kernel/arch/x86_64/boot/`, `scripts/lint.sh` fails the build.

**Lines 22–27 — the `extern` request declarations**
```cpp
extern volatile limine_memmap_request         memmap_request;
extern volatile limine_hhdm_request           hhdm_request;
extern volatile limine_kernel_address_request kernel_address_request;
extern volatile limine_framebuffer_request    framebuffer_request;
extern volatile limine_module_request         module_request;
extern volatile limine_rsdp_request           rsdp_request;
```
The requests are defined in `entry.cpp` and read here. Why the split, when it would be simpler to define them in the file that uses them?

Because Limine's start and end markers must bracket every request **in memory**. Requests declared in one translation unit are laid out by the compiler in declaration order within their section, so keeping the markers and all six requests in `entry.cpp` makes the bracketing a property of the source you can see. Split them across two objects and the ordering becomes a property of link order, which is decided by CMake, changes when someone renames a file, and fails silently — Limine simply does not find the requests, every response comes back null, and you halt on `BOOT_FAIL_NO_MEMMAP` with no clue why.

Three things must match the definitions exactly:

- **The `volatile` qualifier.** `volatile limine_memmap_request` and `limine_memmap_request` are different types, but global variables at namespace scope are not name-mangled in C++ — the symbol is `memmap_request` either way, so this ODR violation *links cleanly*. What you get is a compiler that believes it may cache or elide reads of a variable the bootloader wrote behind its back.
- **The names.** If you named them differently in [[Stage 0.2 - The Limine Request Section]], keep your names and change these.
- **Not `static`.** A `static` definition has internal linkage and these externs will not resolve: `undefined reference to 'memmap_request'`. Limine's own template marks them `static` because it keeps everything in one file; we do not, so we cannot.

When this list outgrows six entries, promote it to `kernel/arch/x86_64/boot/limine_requests.hpp` — a private header beside the source, which [[07 - Repository Layout]] allows.

**Line 34 — the storage**
```cpp
static BootInfo g_boot_info;
```
`static` gives it internal linkage: nothing outside this file can name it, and the only way to reach it is the pointer `collect_boot_info()` returns. That is deliberate — it means there is exactly one `BootInfo` and exactly one function that fills it.

No initialiser, and that is the point. `BootInfo` is an aggregate of scalars, so this is zero-initialisation with no code: the variable is placed in `.bss`, and the loader zero-fills `.bss` because the ELF specification requires the bytes of a `PT_LOAD` segment beyond `p_filesz` to read as zero. Limine does this. **Do not** "make sure" by writing `static BootInfo g_boot_info = {};` and **do not** add a zeroing loop: a 3808-byte zero-initialisation is exactly the pattern GCC turns into a call to `memset`, which does not exist yet. See §7.

The `g_` prefix is the convention for globals in [[13 - Coding Standards]].

**Lines 41–48 — `boot_halt`**
```cpp
[[noreturn]] void boot_halt(uint64_t code) {
    __asm__ volatile("cli" ::: "memory");
    for (;;) {
        __asm__ volatile("hlt" :: "D"(code) : "memory");
    }
}
```
This is the whole failure-reporting mechanism for Stage 0.3 through Stage 0.5. Understand it rather than copying it — you will use the technique again whenever something breaks before the console works.

`cli` clears the interrupt flag, and it goes first: a `hlt` with interrupts *enabled* wakes on the next interrupt and falls out of the halt. With them disabled, `hlt` parks the core until an NMI or SMI, which in QEMU means forever. There is no IDT until [[Phase 2 - Overview|Phase 2]] anyway, so an interrupt arriving here would triple-fault and destroy the evidence.

`"D"(code)` is the x86 machine constraint for `RDI`. GCC has letters for only a handful of registers — `a` RAX, `b` RBX, `c` RCX, `d` RDX, `S` RSI, `D` RDI — and none for R15, which is why RDI rather than something more exotic. RDI is also the first SysV argument register, so the value is usually already there and the constraint costs nothing.

The operand is **inside** the loop, not before it. Put it outside and the compiler may observe that `code` is dead after the setup and reuse RDI; the register you read in `info registers` would then hold whatever the optimiser last put there. Attached to the `hlt` itself, the value must be in RDI at every iteration.

`"memory"` on both blocks, per [[13 - Coding Standards]] rule 2 — it doubles as a compiler barrier, and the rule exists so nobody relitigates it per site. `for (;;)` after a `hlt` is not redundant: an NMI or SMI resumes at the instruction after `hlt`, and the loop puts it straight back. `[[noreturn]]` must be repeated on the definition to match the header.

Reading it back is §6, in one line: run QEMU with `-monitor stdio`, type `info registers`, look at `RDI`.

**Lines 55–67 — `map_memory_type`**
```cpp
static MemoryType map_memory_type(uint64_t limine_type) {
    switch (limine_type) {
    case LIMINE_MEMMAP_USABLE: return MemoryType::USABLE;
    // ...
    default:                   return MemoryType::RESERVED;
    }
}
```
An explicit switch, not `static_cast<MemoryType>(limine_type)`. The cast would compile, produce identical code today, and be wrong for two reasons: it makes the numeric coincidence between the two enumerations load-bearing, and it lets an unknown value — a type `8` from a future Limine — become a `MemoryType` that matches no enumerator, so every `switch` downstream falls through its cases with no diagnostic.

The `default` returns `RESERVED`, never `USABLE`. This is the conservative direction and it matters: mistaking reserved memory for usable means the allocator eventually hands out firmware structures or device apertures. Mistaking usable memory for reserved means you have slightly less RAM. One of those is a corrupted machine and one is a rounding error.

`LIMINE_MEMMAP_KERNEL_AND_MODULES` is the correct spelling at `LIMINE_API_REVISION 0`. At revision 2 it is `LIMINE_MEMMAP_EXECUTABLE_AND_MODULES` and this file will not compile until you change it — which is the barrier working as intended.

`static`, so it has internal linkage and GCC inlines it freely.

**Lines 74–88 — `copy_string`**
```cpp
static void copy_string(char* dst, size_t dst_size, const char* src) {
    if (dst_size == 0) { return; }
    if (src == nullptr) { dst[0] = '\0'; return; }
    size_t i = 0;
    while (i + 1 < dst_size && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}
```
There is no `strncpy` because there is no libc, and fifteen lines is cheaper than providing a string library before you have a serial port.

Three deliberate properties. It **always NUL-terminates** — the loop stops at `i + 1 < dst_size`, leaving room for the terminator the last line always writes (`strncpy` famously does *not* guarantee this, which is why it is not the model). It **truncates rather than overruns**, because the bound is on the destination: a corrupt 4 KiB path cannot walk off a 64-byte array into the next field of `BootInfo`. And it **tolerates a null source**, because `limine_file::path` can be null and dereferencing it here would fault before there is any way to report the fault.

`i + 1 < dst_size` and not `i < dst_size - 1`: with `dst_size` zero the latter underflows to `SIZE_MAX` and the loop runs until it faults. The early return already covers that, but a condition that is correct on its own makes the early return a second line of defence rather than the only one.

**Lines 94–95 — the function opening**
```cpp
BootInfo* collect_boot_info() {
    BootInfo& bi = g_boot_info;  // already all-zero: it is in .bss
```
The reference is purely for readability — `bi.fb_width` instead of `g_boot_info.fb_width` forty times — and compiles to nothing.

No `[[nodiscard]]` on the definition; the attribute belongs on the declaration in the header and repeating it is not required.

**Lines 97–109 — the memory map guards**
```cpp
    limine_memmap_response* memmap = memmap_request.response;
    if (memmap == nullptr) {
        boot_halt(BOOT_FAIL_NO_MEMMAP);
    }
    if (memmap->entry_count == 0) {
        boot_halt(BOOT_FAIL_EMPTY_MEMMAP);
    }
    if (memmap->entry_count > MAX_REGIONS) {
        boot_halt(BOOT_FAIL_TOO_MANY_REGIONS);
    }
```
The load on the first line is where `volatile` earns its place: the compiler must actually read the field rather than assuming it still holds the `nullptr` the initialiser put there. Once loaded, the value goes into an ordinary non-volatile pointer, and that is correct — Limine writes the request's `response` field, but the response structure itself is written before your kernel starts and never touched again.

**The null check is not optional and not paranoia.** A response is null whenever Limine did not honour the request: a protocol revision mismatch, a bootloader too old for a feature, a request the linker dropped for want of `__attribute__((used))`, or markers that failed to bracket the requests. All four are things you will actually hit. Dereferencing null before Phase 2 gives a page fault with no IDT to catch it — double fault, triple fault, silent QEMU reboot loop, no message, no register dump. This check is the difference between "`RDI = 0xB007FA1100000002`, the memmap request was not honoured" and an evening.

`entry_count == 0` is a separate case with a separate code: a null response means the request failed; an empty map means it succeeded and the machine claims to have no memory. Different causes, different fixes.

The overflow check is argued in §3. It must come *before* the loop, and it must halt rather than clamp. It compares against `MAX_REGIONS`, the same constant that sizes the array, so check and bound cannot drift.

**Lines 110–119 — the copy loop**
```cpp
    for (uint64_t i = 0; i < memmap->entry_count; ++i) {
        const limine_memmap_entry* e = memmap->entries[i];
        bi.regions[i].base     = e->base;
        bi.regions[i].length   = e->length;
        bi.regions[i].type     = map_memory_type(e->type);
        bi.regions[i].reserved = 0;
    }
    bi.region_count = static_cast<size_t>(memmap->entry_count);
```
`memmap->entries` is `struct limine_memmap_entry **` — an array of *pointers*, each pointing at a separate three-field structure. It is **not** an array of entries. Treat it as one and the data is wrong in a maximally confusing way: `base` reads back as a pointer value, so it looks like a large plausible address; `length` reads as the next pointer; and the map describes a machine with several exabytes of RAM in bizarre places. Check the double star in `limine.h` if you are unsure.

The four fields are assigned individually rather than as an aggregate. `bi.regions[i] = {...}` would be tidier and is a 24-byte struct copy, which GCC may lower to a `memcpy` call at higher optimisation levels; field-at-a-time is unambiguously scalar stores. Setting `reserved = 0` costs one store and gives the padding a defined value.

`region_count` is assigned **after** the loop, so a fault halfway leaves it zero and no later code reads a half-populated array. The index is `uint64_t` to match `entry_count`, avoiding a signed/unsigned comparison that `-Wextra -Werror` would reject.

**Lines 121–134 — HHDM and kernel address**
```cpp
    limine_hhdm_response* hhdm = hhdm_request.response;
    if (hhdm == nullptr) { boot_halt(BOOT_FAIL_NO_HHDM); }
    bi.hhdm_offset = static_cast<uintptr_t>(hhdm->offset);

    limine_kernel_address_response* ka = kernel_address_request.response;
    if (ka == nullptr) { boot_halt(BOOT_FAIL_NO_KERNEL_ADDRESS); }
    bi.kernel_phys_base = static_cast<uintptr_t>(ka->physical_base);
    bi.kernel_virt_base = static_cast<uintptr_t>(ka->virtual_base);
```
Same shape: read, null-check, copy. Both are required, because Phase 4 cannot function without either — the HHDM is how you touch physical memory once you have your own page tables, and the kernel address pair is how you reserve your own image.

The `static_cast<uintptr_t>` conversions are no-ops on x86_64, where `uintptr_t` and `uint64_t` are the same width. They are written anyway to make the type change deliberate rather than implicit, so that a future port to a 32-bit target produces a visible narrowing rather than a silent one.

`hhdm->offset` is read, never assumed. The value is `0xFFFF800000000000` on x86_64 with 4-level paging, which is what [[06 - Architecture Overview]] documents, and it is different under 5-level paging.

**Lines 136–154 — the framebuffer, optional**
```cpp
    limine_framebuffer_response* fbr = framebuffer_request.response;
    if (fbr != nullptr && fbr->framebuffer_count > 0) {
        const limine_framebuffer* fb = fbr->framebuffers[0];
        bi.fb_present = true;
        bi.fb_addr    = reinterpret_cast<uintptr_t>(fb->address);
        // ... width, height, pitch, bpp, shifts, sizes ...
    } else {
        bi.fb_present = false;
    }
```
Two conditions, and both are needed. `fbr != nullptr` means the request was honoured; `framebuffer_count > 0` means it was honoured *and there is a display*. The `&&` short-circuits, so the second dereference only happens if the first check passed — which is the only reason writing them in this order is safe.

`framebuffers` is again an array of pointers, same double indirection as `entries`. We take `[0]` and ignore the rest: multi-head is not a Phase 1 problem and `BootInfo` deliberately describes one framebuffer.

`fb->address` is a **virtual** address, in the direct map Limine set up, which is why `reinterpret_cast<uintptr_t>` on a `void*` is meaningful rather than a category error. Phase 1 can dereference it as-is. Phase 4 must keep the HHDM at the same offset in its own page tables for it to stay valid, which it does deliberately; if you ever move the HHDM, the physical address is `fb_addr - hhdm_offset`.

The failure branch sets `fb_present = false` and carries on. This is the same judgement as the serial self-test in [[Stage 0.6 - Serial Output]]: a machine with no display is a real machine, and a kernel that will not boot on it is not deployable. Phase 1 checks the flag and skips console initialisation; serial still works.

`fb_bpp` is `uint16_t` on both sides and the mask fields are `uint8_t` on both sides, so none of these assignments narrows.

**Lines 156–172 — modules, optional**
```cpp
    limine_module_response* mods = module_request.response;
    if (mods != nullptr) {
        if (mods->module_count > MAX_MODULES) {
            boot_halt(BOOT_FAIL_TOO_MANY_MODULES);
        }
        for (uint64_t i = 0; i < mods->module_count; ++i) {
            const limine_file* f = mods->modules[i];
            bi.modules[i].addr = reinterpret_cast<uintptr_t>(f->address);
            bi.modules[i].size = f->size;
            copy_string(bi.modules[i].path, MAX_MODULE_PATH, f->path);
        }
        bi.module_count = static_cast<size_t>(mods->module_count);
    } else {
        bi.module_count = 0;
    }
```
`boot/limine.conf` lists no modules yet, so `module_count` is zero today and this loop does nothing. Write it now anyway: [[Phase 7 - Overview|Phase 7]] adds the initrd, and the alternative is discovering in Phase 7 that you need to revisit boot code you have not read in a year.

The overflow check has the same reasoning as `MAX_REGIONS` but a different flavour of cause: exceeding it means someone added modules to `limine.conf`, so failing loudly at boot is precisely the feedback wanted.

**Copying `path` is the subtle line.** `f->path` is a `char*` into bootloader-reclaimable memory, exactly like the response structures. Copying `addr` and `size` and keeping the pointer reproduces the whole bug this stage exists to prevent, in a field you will not think about until Phase 7 prints a module list and gets binary noise. `f->cmdline` has the same property and is not copied here only because nothing needs it; if you ever use it, copy it the same way.

The module *bytes* at `f->address` are **not** copied — an initrd can be megabytes and there is no heap. That is safe because Limine places module contents in memory typed `LIMINE_MEMMAP_KERNEL_AND_MODULES`, which the Phase 4 PMM must never add to the free list. This is the rule from §3 in action: never keep a pointer into memory you are going to reclaim. Checking that the PMM honours type 6 is a Phase 4 task, and it is on the Phase 4 checklist for this reason.

**Lines 174–185 — RSDP and return**
```cpp
    limine_rsdp_response* rsdp = rsdp_request.response;
    if (rsdp != nullptr) {
        bi.rsdp_addr = reinterpret_cast<uintptr_t>(rsdp->address);
    } else {
        bi.rsdp_addr = 0;
    }

    return &bi;
}
```
Optional, because a machine without ACPI is unusual but not impossible, and because Phase 11 is the code that actually cares. Zero is a safe sentinel: it is never a valid RSDP address.

The `reinterpret_cast` is correct **at `LIMINE_API_REVISION 0`**, where the field is `void*` holding a direct-map virtual address. At revision 1 and above it is a `uint64_t` holding a *physical* address, and this line will not compile — which is the right outcome, because the semantics changed and silently keeping the old code would give Phase 11 a physical address it treats as virtual. If you bump the API revision, this is one of two lines that need attention; the other is the `KERNEL_AND_MODULES` constant name.

`return &bi;` returns the address of the file-scope static, so the pointer is valid for the life of the kernel. This is the whole payoff of the storage decision in §3: there is no lifetime question to answer at the call site.

---

### `kernel/main.cpp`

The kernel proper begins here. Empty for now — its value in this stage is entirely in what it does *not* contain.

```cpp
// kernel/main.cpp
//
// Architecture-neutral kernel entry. By the time we get here, kmain() has
// already turned the bootloader's responses into a BootInfo.
//
// This file must never include limine.h, must never mention a Limine type,
// and must never contain inline assembly. scripts/lint.sh checks all three
// on every commit; see 07 - Repository Layout, boundary rules 1 and 2.

#include <kernel/boot_info.hpp>

void kernel_init([[maybe_unused]] BootInfo* info) {
    // Stage 0.6 adds serial_init() and the first line of output.
    // Stage 0.7 adds panic() and KASSERT.
    // Phase 1  adds the framebuffer console, from info->fb_*.
    // Phase 2  adds the GDT and IDT.
    // Phase 4  adds the physical memory manager, from info->regions.
    //
    // Returning is correct for now: kmain() parks the CPU. From Stage 0.8
    // this function is [[noreturn]] and never comes back.
}
```

#### Line by line

**Lines 1–8 — the comment block**

Worth writing, and worth writing here rather than in a wiki page. This file will be edited by both of you a hundred times over the next year, and the three prohibitions are not guessable from its contents. The comment is the first thing anyone sees before adding an include.

**Line 10 — the only include**
```cpp
#include <kernel/boot_info.hpp>
```
Angle brackets, because `kernel/include/` is on the include path via `-Ikernel/include` and this is a cross-subsystem interface header, not a file sitting next to this one.

This one line is the deliverable of the whole stage. `main.cpp` gets a complete description of the machine and has no idea a bootloader was involved. Nothing here would change if you swapped Limine for something else tomorrow.

**Lines 12–22 — `kernel_init`**
```cpp
void kernel_init([[maybe_unused]] BootInfo* info) {
}
```
`[[maybe_unused]]` is required, not decorative. `-Wextra` enables `-Wunused-parameter`, `-Werror` makes it fatal, and `info` is genuinely unused today. The alternatives are worse: omitting the parameter name loses the documentation of what the argument is, and `(void)info;` is the C idiom for a problem C++ has an attribute for. [[ADR-0007 - Freestanding C++20 as the Kernel Language]] lists `[[maybe_unused]]` among the encouraged attributes for exactly this.

**The body is empty and the function returns.** That is a considered choice, not laziness. The obvious alternative — halting here — would need `hlt`, which is inline assembly, which is banned outside `kernel/arch/` by boundary rule 1 and grepped by `scripts/lint.sh`. Spinning on an empty `for (;;) {}` instead would avoid the asm but burn a core at 100% and, more importantly, put the kernel's terminal state in a portable file where it does not belong. Stopping the machine is an architecture operation. So `kernel_init` returns, and `kmain` — which is arch code and may use `hlt` — parks the CPU.

That inverts once there is something to do: from Stage 0.8, `kernel_init` ends by starting the idle task and is marked `[[noreturn]]`.

Do not be tempted to add `serial_init()` here yet. Stage 0.6 adds it as the very first statement, and doing one thing per stage is what makes a failure attributable to one stage.

---

### `kernel/arch/x86_64/boot/entry.cpp` (edited)

The requests, the markers, and the entry point. Stage 0.2 created this file; this stage removes the placeholder halt loop and wires in the two calls.

```cpp
// kernel/arch/x86_64/boot/entry.cpp
//
// The kernel entry point and the whole Limine request block. Everything
// Limine-shaped lives here or in boot_info.cpp, and nowhere else.

#include <kernel/boot_info.hpp>

#include <stdint.h>

#include "limine.h"

// --- Protocol version negotiation ------------------------------------------
// Limine writes 0 into element [2] if it supports this base revision.
// The macro already ends in a semicolon; do not add another.

__attribute__((used, section(".limine_requests")))
volatile LIMINE_BASE_REVISION(2)

// --- Start marker ----------------------------------------------------------

__attribute__((used, section(".limine_requests_start")))
volatile LIMINE_REQUESTS_START_MARKER

// --- The requests ----------------------------------------------------------
// NOT static: boot_info.cpp declares these extern and reads the responses.

__attribute__((used, section(".limine_requests")))
volatile limine_framebuffer_request framebuffer_request = {
    .id = LIMINE_FRAMEBUFFER_REQUEST, .revision = 0, .response = nullptr
};

__attribute__((used, section(".limine_requests")))
volatile limine_memmap_request memmap_request = {
    .id = LIMINE_MEMMAP_REQUEST, .revision = 0, .response = nullptr
};

__attribute__((used, section(".limine_requests")))
volatile limine_hhdm_request hhdm_request = {
    .id = LIMINE_HHDM_REQUEST, .revision = 0, .response = nullptr
};

__attribute__((used, section(".limine_requests")))
volatile limine_kernel_address_request kernel_address_request = {
    .id = LIMINE_KERNEL_ADDRESS_REQUEST, .revision = 0, .response = nullptr
};

__attribute__((used, section(".limine_requests")))
volatile limine_module_request module_request = {
    .id = LIMINE_MODULE_REQUEST, .revision = 0, .response = nullptr,
    .internal_module_count = 0, .internal_modules = nullptr
};

__attribute__((used, section(".limine_requests")))
volatile limine_rsdp_request rsdp_request = {
    .id = LIMINE_RSDP_REQUEST, .revision = 0, .response = nullptr
};

// --- End marker ------------------------------------------------------------

__attribute__((used, section(".limine_requests_end")))
volatile LIMINE_REQUESTS_END_MARKER

// --- Entry point -----------------------------------------------------------

extern "C" [[noreturn]] void kmain(void) {
    if (!LIMINE_BASE_REVISION_SUPPORTED) {
        boot_halt(BOOT_FAIL_BASE_REVISION);
    }

    BootInfo* info = collect_boot_info();
    kernel_init(info);

    // kernel_init has nothing to do yet, so it returns. Park the CPU with a
    // recognisable value in RDI so Stage 0.5 can prove we got this far.
    boot_halt(BOOT_HALT_OK);
}
```

#### Line by line

**Lines 6–10 — includes**
```cpp
#include <kernel/boot_info.hpp>

#include <stdint.h>

#include "limine.h"
```
`boot_info.hpp` is new in this stage and brings in `BootInfo`, `collect_boot_info()`, `kernel_init()`, and the boot-halt codes. Everything else was already here from Stage 0.2.

**Lines 15–16 — the base revision**
```cpp
__attribute__((used, section(".limine_requests")))
volatile LIMINE_BASE_REVISION(2)
```
`LIMINE_BASE_REVISION(N)` expands to `uint64_t limine_base_revision[3] = { 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, (N) };` — two magic words Limine scans for and the revision you are asking for. **The macro ends in a semicolon.** Adding another gives a stray empty declaration; harmless at namespace scope but confusing, and it will look like a typo to the next reader.

The number is whatever you pinned in Stage 0.2 — do not change it here. `PROTOCOL.md` for your pinned Limine tag lists which base revisions that release supports, and the runtime check three lines into `kmain` catches a mismatch regardless, which is the real safety net.

`__attribute__((used))` stops the optimiser deleting a global that nothing in the program reads. Without it the whole request block can vanish, Limine finds nothing, and every response is null. `section(".limine_requests")` puts it where Stage 0.4's linker script will `KEEP` it.

**Lines 20–21 and 59–60 — the markers**
```cpp
__attribute__((used, section(".limine_requests_start")))
volatile LIMINE_REQUESTS_START_MARKER
// ... requests ...
__attribute__((used, section(".limine_requests_end")))
volatile LIMINE_REQUESTS_END_MARKER
```
The markers bound Limine's scan. Placing them in their own sections and letting the linker script order `.limine_requests_start`, `.limine_requests`, `.limine_requests_end` is what Limine's own template does and what [[Stage 0.4 - The Linker Script and Higher-Half Layout]] will expect.

If you followed Stage 0.2 literally and put the markers in `.limine_requests` alongside the requests, that also works — as long as everything stays in this one translation unit, where the compiler emits objects in declaration order within a section. Prefer the three-section form: it survives someone moving a request to another file, which the single-section form does not.

**Lines 27–56 — the six requests**
```cpp
__attribute__((used, section(".limine_requests")))
volatile limine_framebuffer_request framebuffer_request = {
    .id = LIMINE_FRAMEBUFFER_REQUEST, .revision = 0, .response = nullptr
};
```
Four things per request.

*Not `static`* — this is the edit Stage 0.3 makes. `boot_info.cpp` declares these `extern`, so they need external linkage; a `static` here gives `undefined reference to 'framebuffer_request'` at link time.

*`volatile`.* Limine writes `response` while your kernel is not executing, so the value changes with no cause the compiler can see. Without it, GCC may observe that `response` is initialised to `nullptr` and never assigned, constant-fold every read to `nullptr`, and either delete the null checks in `boot_info.cpp` or make them always fire. This is the MMIO-shaped exception to [[13 - Coding Standards]] rule 3 — a value changing behind the compiler's back, which is what `volatile` is for, and not concurrency, which is what it is not for.

*Designated initialisers, all fields.* `.id = LIMINE_FRAMEBUFFER_REQUEST` expands to a four-element braced list: the common magic plus this request's two ID words. Every field is initialised explicitly, so `-Wextra`'s `-Wmissing-field-initializers` has nothing to say. C++20 requires designators in declaration order, which is the order in `limine.h`.

*`.revision = 0`* is the **request** revision — not the base revision and not the response revision. Zero asks for each request's baseline feature set. `limine_module_request`'s two revision-1 fields still need initialising; zero and null means "no internal modules".

These six are Stage 0.2's seven table entries minus the base revision, which is not a request. Names must match the `extern` declarations in `boot_info.cpp`.

**Line 64 — the signature**
```cpp
extern "C" [[noreturn]] void kmain(void) {
```
`extern "C"` suppresses C++ name mangling so the symbol is `kmain` and not `_Z5kmainv`. The linker script's `ENTRY(kmain)` looks up a literal string; without `extern "C"` it finds nothing, and the ELF entry point ends up at address zero or wherever the linker defaults. Verify with `nm` (§6) rather than trusting it.

`[[noreturn]]` documents the contract and lets the compiler skip the epilogue. The function ends in a call to `boot_halt`, which is also `[[noreturn]]`, so there is no "control reaches end of non-void function" warning to suppress.

`void kmain(void)` takes no arguments. Limine's protocol passes nothing in registers; everything arrives through the responses. If you came from Multiboot expecting a magic value in `EAX` and a pointer in `EBX`, that model does not exist here.

**Lines 65–67 — the base revision check**
```cpp
    if (!LIMINE_BASE_REVISION_SUPPORTED) {
        boot_halt(BOOT_FAIL_BASE_REVISION);
    }
```
`LIMINE_BASE_REVISION_SUPPORTED` expands to `(limine_base_revision[2] == 0)`. You wrote your requested revision into that slot; Limine overwrites it with zero if it can honour the request and leaves it alone if it cannot. This is the very first thing to check, before touching any response, because a bootloader that does not support your base revision may not have filled in anything at all — the responses would all be null and you would halt on `BOOT_FAIL_NO_MEMMAP`, which is a true statement that points at the wrong problem.

The read goes through the `volatile` array, so it is a real load rather than a compile-time constant fold of the initialiser. This is the same `volatile` argument as the requests, and it is why the base revision array must not lose the qualifier either.

**Lines 69–70 — the two calls**
```cpp
    BootInfo* info = collect_boot_info();
    kernel_init(info);
```
Two lines, and they are the architecture of the entire kernel's startup. Everything Limine-shaped happens inside the first call and is finished when it returns. Everything after the second call is portable C++ that has never heard of a bootloader.

`collect_boot_info()` is `[[nodiscard]]`, so assigning the result is required; ignoring it would be a build failure.

**Lines 72–75 — the terminal state**
```cpp
    boot_halt(BOOT_HALT_OK);
}
```
`kernel_init` returns because it is empty, so `kmain` has to decide what to do next, and the answer is: stop, visibly. `BOOT_HALT_OK` is not a failure code — it is the *success* marker for this stage, and it is the thing you will look for in Stage 0.5 when the image boots for the first time. `RDI = 0xB007C0DE00000000` in `info registers` proves the kernel was entered, the base revision was accepted, every required response was present, the whole memory map was copied, and control reached the end of `kmain`. That is a remarkable amount of information from one register, and it is available before there is any way to print a character.

From Stage 0.6 this becomes a serial line. From Stage 0.8, `kernel_init` never returns and this call is unreachable — keep it anyway, as the thing that catches a `kernel_init` that returns by mistake.

---

## 6. How to verify

There is no linker script until [[Stage 0.4 - The Linker Script and Higher-Half Layout]] and no bootable image until Stage 0.5, so nothing here runs yet. Everything below is a check on the object files, and every one of them is worth doing — a mistake caught by `nm` today is a mistake you are not debugging through a blank screen in three stages' time.

### Now: compile all three translation units

Inside the container (`make shell` from the repo root), from `/os`:

```sh
KFLAGS="-std=c++20 -ffreestanding -fno-exceptions -fno-rtti \
        -fno-stack-protector -fno-pic -fno-pie -mcmodel=kernel -mno-red-zone \
        -mno-sse -mno-mmx -mno-80387 -Wall -Wextra -Werror -Ikernel/include"

mkdir -p /tmp/o
x86_64-elf-g++ $KFLAGS -c kernel/main.cpp                       -o /tmp/o/main.o
x86_64-elf-g++ $KFLAGS -c kernel/arch/x86_64/boot/entry.cpp     -o /tmp/o/entry.o
x86_64-elf-g++ $KFLAGS -c kernel/arch/x86_64/boot/boot_info.cpp -o /tmp/o/boot_info.o
```

Expected: three commands, no output at all, exit status 0. With `-Werror` any warning is a failure, so silence is the whole result. If you see anything, fix it now — `-Werror` is only useful if the build is clean enough that a new warning is visible.

### Now: `kernel_init` is defined and Limine-free

```sh
x86_64-elf-nm /tmp/o/main.o
```
```
0000000000000000 T _Z11kernel_initP8BootInfo
```

`T` means a defined symbol in `.text`. The name is mangled because `kernel_init` is ordinary C++ — `_Z11kernel_init` is "function named `kernel_init`", `P8BootInfo` is "takes a pointer to `BootInfo`". Demangle to check the signature:

```sh
x86_64-elf-nm -C /tmp/o/main.o
```
```
0000000000000000 T kernel_init(BootInfo*)
```

If you see `U` instead of `T`, you declared it but did not define it. If the parameter type is anything other than `BootInfo*`, the declaration in the header and the definition have drifted and the link in Stage 0.4 will fail.

Now the boundary check on the same object:

```sh
x86_64-elf-nm /tmp/o/main.o | grep -i limine || echo "clean"
```
```
clean
```

Any output here means a Limine type reached `main.cpp` — most likely through a header that should not have been included.

### Now: the source-level boundary rule

This is the CI rule from [[10 - CI Pipeline]], run locally:

```sh
grep -rn "limine" kernel/ --include='*.cpp' | grep -v arch/x86_64/boot/
echo "exit: $?"
```
```
exit: 1
```

No output, and exit status 1 from the trailing `grep` because it matched nothing. That is success. If a path prints, that file must lose its Limine dependency before the commit.

The repository's own script runs the same rule plus the others:

```sh
./scripts/lint.sh
```

Expect `limine.h confined to arch/x86_64/boot/` and `no inline asm outside kernel/arch/` to pass. The `-mno-red-zone` rule needs `build/compile_commands.json`, which does not exist until the CMake build lands in Stage 0.8; it will report a failure until then and that is expected.

### Now: the request block survived, and is the right size

```sh
x86_64-elf-objdump -h /tmp/o/entry.o | grep limine
```
```
  N .limine_requests_start 00000020  ...
  N .limine_requests       00000148  ...
  N .limine_requests_end   00000010  ...
```

`0x148` is 328 bytes: the 24-byte base revision array plus the six requests from the table in §4. `0x20` is the 32-byte start marker, `0x10` the 16-byte end marker. If `.limine_requests` is missing entirely, `__attribute__((used))` is absent or the section name is misspelled, and Limine will silently ignore every request. If it is `0x130` (304), the base revision array is not in the section.

### Now: `kmain` is unmangled, and `BootInfo` is the size you think

```sh
x86_64-elf-nm /tmp/o/entry.o | grep -w kmain
```
```
0000000000000000 T kmain
```

Exactly `kmain`. If it reads `_Z5kmainv`, the `extern "C"` is missing and Stage 0.4's `ENTRY(kmain)` will not find it.

```sh
x86_64-elf-size -A /tmp/o/boot_info.o | grep -E '^\.bss'
```
```
.bss           3808     0
```

3808 bytes is `g_boot_info`, and it matches the arithmetic in §4. A different number means you changed a limit or added a field — recheck the table rather than shrugging, because this is also how you would notice an accidental pointer member.

### Now: the banned features really are banned

Worth doing once, so you recognise the errors later. Add each line to `main.cpp` temporarily, compile, read the message, delete it. `throw 1;` and `double x = 1.0;` fail at compile time; `auto* p = new BootInfo;` **compiles** and fails only at link with `undefined reference to 'operator new(unsigned long)'`. That third case is the lesson: in freestanding C++, much of the ban is enforced by the linker.

### Later: proof it actually ran

Only from Stage 0.5, when there is a bootable image. On the host:

```sh
qemu-system-x86_64 -cdrom build/os.iso -m 512M -display none \
    -monitor stdio -no-reboot -no-shutdown
```

At the `(qemu)` prompt:

```
(qemu) info registers
```

Look for:

```
RAX=... RBX=... RCX=... RDX=...
RSI=... RDI=b007c0de00000000 RBP=... RSP=...
RIP=ffffffff8010....  RFL=00000002 ...
```

`RDI = b007c0de00000000` is `BOOT_HALT_OK`: the kernel was entered, the base revision was accepted, every required response was present and copied, and `kmain` reached its end. `RIP` in the higher half confirms you are executing from the kernel mapping. If `RDI` holds a `b007fa11...` value instead, look it up in the table in §4 — that tells you which check failed without any output device existing.

If you prefer the graphical window, `Ctrl+Alt+2` switches QEMU to the monitor console and `Ctrl+Alt+1` switches back.

Also worth running once with `-m 128M`: the memory map changes, `region_count` changes with it, and from Stage 0.6 you can print the number and prove you are reading the real map rather than a constant.

### Checklist

- [ ] All three translation units compile with the full kernel flag set, silently, `-Werror` clean
- [ ] `nm -C /tmp/o/main.o` shows `kernel_init(BootInfo*)` as a defined `T` symbol
- [ ] `nm /tmp/o/main.o | grep -i limine` finds nothing
- [ ] `grep -rn "limine" kernel/ --include='*.cpp' | grep -v arch/x86_64/boot/` prints nothing
- [ ] `./scripts/lint.sh` passes the two boundary rules that do not need `compile_commands.json`
- [ ] `objdump -h entry.o` shows all three `.limine_requests*` sections, `.limine_requests` at `0x148`
- [ ] `nm entry.o` shows `kmain`, not `_Z5kmainv`
- [ ] `size -A boot_info.o` shows `.bss` of 3808 bytes
- [ ] You have seen, once, what a `throw`, a `double`, and a `new` actually produce
- [ ] *(Stage 0.5)* `info registers` shows `RDI=b007c0de00000000`

---

## 7. Common traps

**The kernel works for weeks, then a routine allocator change makes `BootInfo` return garbage.** You stored a Limine pointer instead of copying the data. Phase 4 reclaimed the memory and something else is living there now. There is nothing wrong with the commit you bisected to. Fix: copy every field to a leaf; the only pointers left in `BootInfo` should be `fb_addr` and `Module::addr`, both of which point at memory Limine does not mark reclaimable. Grep your own code for `limine_` appearing anywhere other than a local variable inside `collect_boot_info()`.

**`undefined reference to 'memset'` — from a line with no function call in it.** GCC assumes a freestanding implementation provides `memcpy`, `memmove`, `memset` and `memcmp`, and emits calls to them for large struct copies, aggregate zero-initialisation, and — at `-O2`, via `-ftree-loop-distribute-patterns` — for hand-written loops it recognises. Classic triggers: `BootInfo info = {};`, returning `BootInfo` by value, a `bi.regions[i] = {...}` aggregate assignment. **The build is `Debug` today, so you may not see this until the first `-O2` build, which makes it a nasty surprise.** Fix: write the four functions in `kernel/lib/string.cpp` — you need them anyway from Phase 1 — or, as a stopgap, add `-fno-builtin -fno-tree-loop-distribute-patterns`. Providing the functions is the right answer.

**`undefined reference to '__cxa_guard_acquire'` / `'__cxa_guard_release'`.** A function-local `static` with a non-trivial constructor. GCC emits a thread-safe initialisation guard that calls into libstdc++. Fix: make the object trivially constructible and initialise it explicitly, or hoist it to a file-scope aggregate. This error is a gift — it catches the mistake at build time.

**`undefined reference to '__cxa_atexit'` and `'__dso_handle'`.** A global or static object with a non-trivial destructor; GCC registers it for teardown at exit, and there is no exit. Fix: remove the destructor, or the object.

**The dangerous version of the same mistake, which produces no error at all.** A global with a non-trivial constructor and a trivial destructor links cleanly, is never initialised, and reads as all zeroes from `.bss`. If it has virtual functions its vtable pointer is null, and the first virtual call jumps to address 0 — a page fault, with no IDT, so a triple fault and a silent QEMU reboot. Fix: [[13 - Coding Standards]] rule 9, always. Explicit `init()` in the order from [[06 - Architecture Overview]].

**QEMU reboots in a loop the instant it enters the kernel; `-d int,cpu_reset` shows a triple fault at the first instruction of `collect_boot_info`.** You dereferenced a null response. Before Phase 2 there is no IDT, so a page fault escalates to double then triple fault with no diagnostic whatsoever. Fix: null-check **every** response before touching it, without exception. This is the single reason the checks in §5 are so repetitive.

**The memory map looks like a machine with exabytes of RAM in impossible places.** You treated `response->entries` as an array of `limine_memmap_entry` rather than an array of *pointers* to them. What you read as `base` is a pointer value, which is large and plausible. Fix: `const limine_memmap_entry* e = memmap->entries[i];` — check the double star in `limine.h`.

**The kernel reports less RAM than the machine has, or eventually hands out MMIO as usable memory.** You truncated the memmap copy at `MAX_REGIONS` instead of failing. Silent truncation loses `USABLE` entries (less RAM, quietly) or loses `RESERVED` entries, and since the map is not contiguous, "not mentioned" reads as "unknown", not "safe". Fix: halt on overflow, then raise the constant. Never clamp.

**`info registers` shows `RDI = 0` even though you called `boot_halt` with a code.** The asm block has no input operand pinning the value, or the operand is outside the loop and the compiler reused the register. Fix: `__asm__ volatile("hlt" :: "D"(code) : "memory");` with the operand attached to the `hlt` *inside* the `for (;;)`.

**`undefined reference to 'memmap_request'` when linking `boot_info.o`.** The definition in `entry.cpp` is `static`, so it has internal linkage. Limine's single-file template marks them `static`; we cannot, because a second translation unit reads them. Fix: drop the `static`.

**The link succeeds but every response reads as null, or the null checks get optimised away.** The `volatile` qualifier differs between the definition in `entry.cpp` and the `extern` declaration in `boot_info.cpp`. Global variables at namespace scope are not name-mangled in C++, so the symbol matches and the linker says nothing. Fix: make the two declarations character-for-character identical apart from the `extern` and the initialiser.

**Every response is null and the base revision check passed.** Limine did not find the request block. Usual causes, in order of likelihood: a missing `__attribute__((used))`; a misspelled section name; requests that ended up outside the start/end markers because they were defined in a different translation unit. Fix: `objdump -h` the object and confirm the three sections exist with the sizes from §4.

**`error: SSE register return with SSE disabled`.** A `float` or `double` appeared — often from a helper someone copied in, or an average computed for a log message. Fix: use integer arithmetic. If you genuinely need a fraction, use fixed point. The kernel does not do floating point, so it never has to save FP state across interrupts.

**Phase 4 maps the framebuffer and gets a fault, or writes to the wrong physical page.** You treated `fb_addr` as a physical address. Limine's `limine_framebuffer::address` is a **virtual** address inside its direct map. Fix: the physical address is `fb_addr - hhdm_offset`, and only once you are confident your own page tables keep the HHDM at the same offset.

**Everything works in QEMU and the kernel refuses to boot on a real machine.** Two usual causes. `MAX_REGIONS` too small — a real UEFI map can be several times larger than QEMU's. Or you made the framebuffer required; some machines genuinely have no display. Fix: raise the cap, and keep optional responses optional.

**You hardcoded `0xFFFF800000000000` for the HHDM offset because [[06 - Architecture Overview]] says that is the value.** It is the value for 4-level paging on x86_64 and it is different under 5-level. Fix: read `hhdm->offset` and store it. The documented constant is what to *expect*, not what to assume.

---

## 8. What this unlocks

Everything from here reads `BootInfo` and nothing reads Limine. [[Stage 0.6 - Serial Output]] prints the framebuffer geometry and the region count as its first line of proof-of-life; [[Phase 1 - Overview|Phase 1]] builds the framebuffer console entirely out of `fb_addr`, `fb_pitch`, `fb_bpp` and the mask fields; Stage 1.7's backtrace symboliser needs `kernel_phys_base` and `kernel_virt_base`; [[Phase 4 - Overview|Phase 4]] builds the physical memory manager from `regions` and `region_count` and the entire address-translation layer from `hhdm_offset`; [[Phase 7 - Overview|Phase 7]] unpacks the initrd from `modules[0]`; [[Phase 11 - Overview|Phase 11]] starts ACPI parsing at `rsdp_addr`.

Done wrong, none of that fails now. Hold a pointer instead of copying and the kernel works until Phase 4's allocator gets busy, then breaks in whichever subsystem reads `BootInfo` first, with a bisect that lands on an innocent commit. Truncate the memory map instead of failing and the PMM either loses RAM silently or hands out device memory. Let a Limine type past the barrier and [[ADR-0003 - Limine as the Bootloader]]'s escape hatch quietly stops being true, which you discover the day you want to test under a different bootloader. All three are cheap today and expensive at every later point.

---

## 9. Reading

- **Limine protocol specification** — the authority for what every response means and which fields are guaranteed. Read the Memory Map, Framebuffer, HHDM, Kernel Address, Module and RSDP sections, and re-read Memory Map before Phase 4: <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- **The vendored `kernel/arch/x86_64/boot/limine.h`** — the only source of truth for field names and the `LIMINE_API_REVISION` conditionals. Prefer it over any tutorial, including this note.
- OSDev — *C++*: which language features need a runtime and which do not, with the link errors each produces: <https://wiki.osdev.org/C%2B%2B>
- OSDev — *Calling Global Constructors*: what `.init_array` is and what has to run it, which is why globals with constructors are banned until Phase 4: <https://wiki.osdev.org/Calling_Global_Constructors>
- OSDev — *Detecting Memory (x86)*: what E820 and the UEFI memory map look like underneath, and why maps are ragged: <https://wiki.osdev.org/Detecting_Memory_(x86)>
- OSDev — *Beginner Mistakes*: the null-response and reclaimed-memory classes of error, among many others: <https://wiki.osdev.org/Beginner_Mistakes>
- GCC manual — *Extended Asm*, for the constraint letters used by `boot_halt` and by every `asm` block from Stage 0.6 onward: <https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html>
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]] — the language subset, in normative form
- [[ADR-0003 - Limine as the Bootloader]] — the escape hatch this stage makes real
- [[13 - Coding Standards]] — rules 1, 2, 3 and 9 all appear in this stage's code
- [[06 - Architecture Overview]] — the initialisation order `BootInfo` sits at step 2 of
- [[07 - Repository Layout]] — boundary rules 1 and 2, and why they are greps rather than good intentions

Next: **[[Stage 0.4 - The Linker Script and Higher-Half Layout]]**





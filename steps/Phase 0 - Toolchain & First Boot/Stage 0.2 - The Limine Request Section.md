# Stage 0.2 — The Limine Request Section

**Difficulty:** Easy · ~45 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `kernel/arch/x86_64/boot/entry.cpp`, `kernel/arch/x86_64/boot/limine.h` (vendored, not written)
**Deliverable:** an object file with a global `kmain` symbol and a non-empty `.limine_requests` section — everything Limine needs to recognise this kernel, ready for the linker script in Stage 0.4.

---

## Progress

- [ ] `make shell`, then `mkdir -p kernel/arch/x86_64/boot`
- [ ] `cp "$LIMINE_DIR/limine.h" kernel/arch/x86_64/boot/` and **commit it** — it is source, not a build artefact
- [ ] Create `entry.cpp`; include `<stdint.h>` and `"limine.h"`
- [ ] Declare the base revision marker
- [ ] Declare the six request structs, each `volatile` and in `.limine_requests`
- [ ] Declare the start and end delimiters in their own sections
- [ ] Write `halt_forever()`
- [ ] Write `extern "C" [[noreturn]] void kmain()`
- [ ] Compile with the Stage 0.1 flag set — `-Werror` clean, zero warnings
- [ ] `x86_64-elf-nm` shows `T kmain`, not `T _Z5kmainv`
- [ ] `x86_64-elf-objdump -h` shows `.limine_requests` with a non-zero size
- [ ] `make lint` passes the `limine.h` confinement rule
- [ ] Committed with a message like `feat(boot): limine requests and kmain entry point`

---

## 1. Why this stage exists

Limine is a program. It runs before your kernel, reads `limine.conf`, loads `kernel.elf`
into memory, and jumps somewhere. Two questions have to be answered before that jump is
useful: **what does the kernel want from the bootloader**, and **where does the bootloader
put the answers**.

Without this stage you have a valid ELF that Limine will happily load and jump into, and a
kernel that knows nothing. It cannot find RAM, because the memory map lives in a structure
Limine only fills in if you asked. It cannot draw a pixel, because there is no way to
discover the framebuffer's address. It cannot find the ACPI tables, because on a UEFI
machine the RSDP is not at a fixed address and the only component that still knows where
it is, is the bootloader — which is about to exit. Each of those facts is available for
exactly one moment, and this stage is how you claim them.

The skip-it failure is specific and nasty. Write `kmain` without the request section and
everything still builds, links, and boots. Then in [[Phase 1 - Overview|Phase 1]] you read
`framebuffer_request.response->framebuffers[0]->address` and take a page fault
dereferencing null — before the IDT exists ([[Phase 2 - Overview|Phase 2]]), so there is no
handler, so it escalates to a triple fault and the machine resets. The observable symptom
is the QEMU window flickering back to the Limine menu. Nothing mentions requests, sections,
or `entry.cpp`.

This stage is also where the one architectural boundary that matters for the whole project
gets drawn: **`limine.h` is included by exactly one directory, forever.** Cheap now;
expensive once twenty files have a `limine_framebuffer*` in a signature.

---

## 2. The concept

Two programs run on this machine, one after the other. Limine runs in firmware context, can
call BIOS interrupts or UEFI boot services, and knows things your kernel will never be able
to find out on its own. By the time your kernel starts, that program is finished.

So Limine has to leave the information somewhere in memory, and your kernel has to know
where to look. The protocol's answer inverts the direction you would expect:

> **The kernel allocates the mailboxes; the bootloader fills them in.**

You put structures into your own binary. Each begins with a magic number identifying which
question it asks. Limine loads your binary, walks its bytes looking for those magic
numbers, and every time it finds one it recognises it writes a pointer into that structure
pointing at the answer. Then it jumps to your entry point. There is no argument in a
register and no info-block pointer — the answers are already sitting inside your own data,
because you shipped the envelopes.

```
   BUILD TIME                BOOT TIME                    kmain SEES
 ──────────────────    ────────────────────────    ────────────────────────
 ┌────────────────┐    ┌──────────────────────┐    ┌──────────────────────┐
 │ START MARKER   │    │ START MARKER ◄── scan│    │ START MARKER         │
 │ base rev  = 2  │    │ base rev[2] := 0     │    │ base rev[2] == 0     │
 │ framebuffer .id│    │ .response   := 0x7fe0│    │ .response = 0x7fe0 ──┼─┐
 │  .rev=0 .resp=0│    │ .response   := 0x7ff8│    │ .response = 0x7ff8   │ │
 │ memmap / hhdm  │    │ ...                  │    │ ...                  │ │
 │ kernel_addr    │    │                      │    │                      │ │
 │ module / rsdp  │    │                      │    │                      │ │
 │ END MARKER     │    │ END MARKER   ◄── stop│    │ END MARKER           │ │
 └────────────────┘    └──────────────────────┘    └──────────────────────┘ │
                                                                            │
   bootloader-reclaimable memory  ┌──────────────────────┐  ◄───────────────┘
   (Phase 4 WILL reclaim this)    │ framebuffer_response │
                                  │ memmap_response      │
                                  │ memmap entries[]     │
                                  └──────────────────────┘
```

The section holds three kinds of object, and keeping them distinct matters: the **base
revision marker** (not a request — a version negotiation in three words), the **requests**
themselves, and the two **delimiters** that bound the region Limine scans.

### Why scanning, and why that is not as silly as it sounds

Limine does not look up a symbol called `g_framebuffer_request`. Symbol tables get
stripped, and requiring specific names would force every kernel in the world to agree on
identifiers. Instead Limine reads the bytes of the loaded image and searches for a fixed
128-bit value — `LIMINE_COMMON_MAGIC` — which begins every request.

The consequence: **the section name means nothing to Limine.** It means everything to
*you*. Putting every request in one named section is how you guarantee they end up
contiguous, inside the delimiters, and inside a loadable segment. `.limine_requests` is a
convention. What the protocol requires is that the bytes reach memory Limine loads and that
they survive both the compiler and the linker — which is what `__attribute__((used))` and
the linker script's `KEEP` are for. Two tools, two mechanisms, both required.

---

## 3. Design decisions and tradeoffs

### Decision: which bootloader, and do we write our own?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — Limine** | Prebuilt `BOOTX64.EFI` + BIOS stages. Enters the kernel in 64-bit long mode, paging on, HHDM established, stack valid | A third-party dependency, pinned at `v8.6.0-binary`; a protocol nobody else uses | ✅ |
| B — GRUB2 + Multiboot 2 | Widely known. Hands you a tag stream | Enters in **32-bit protected mode** — you write the long-mode trampoline; staging GRUB EFI binaries cross-platform is painful; no SMP help | ❌ |
| C — GRUB + Multiboot 1 | The classic tutorial path | 32-bit only, legacy BIOS only, frozen info struct. Wrong target ([[ADR-0002 - Target x86_64 Not i686]]) | ❌ |
| D — write your own | MBR/real mode → A20 → protected → long mode; or a hand-written UEFI application | ~1 month before the first `hlt`; two implementations if you want both BIOS and UEFI | ❌ |

**Why A.** Limine hands you a CPU already in the state you would otherwise spend weeks
reaching: long mode, paging enabled, interrupts disabled, a valid stack, the kernel mapped
at its link address, a higher-half direct map established. It supplies the memory map,
framebuffer, RSDP, module locations, and — from [[Phase 12 - Overview|Phase 12]] — started
application processors parked in a callback. Each is something you would otherwise have
written yourself, badly, before writing any operating system.
[[ADR-0003 - Limine as the Bootloader]].

**Why not B.** Multiboot 2 leaves the CPU in 32-bit protected mode, so the kernel's first
job becomes: build a temporary GDT, hand-build four levels of initial page tables in
assembly, set `CR4.PAE`, load `CR3`, set `EFER.LME`, set `CR0.PG`, far-jump to a 64-bit code
segment. That trampoline is 32-bit code inside a 64-bit kernel, is not debuggable with any
tooling you have, and every mistake in it produces the same symptom: instant reset. It
teaches you the format of a page table entry — which [[Phase 4 - Overview|Phase 4]] teaches
properly, in C++, with a debugger attached.

**Why not D — and what you give up.** Being honest about the cost matters. **You will not
learn real-mode programming, the A20 gate, the 512-byte boot sector budget, BIOS `INT 13h`
disk reads, the protected-mode far jump, or the UEFI boot-services/`ExitBootServices`
handshake.** Those are real gaps — and they are gaps in *firmware* knowledge, not
*operating system* knowledge. You still build page tables (Phase 4), a GDT and IDT (Phase
2), and you still parse the memory map yourself. The OS concepts are not skipped, only the
firmware trivia. For a two-person team on a two-year roadmap, a month on boot sectors is a
month not spent on a scheduler.

**When D would be right.** If boot and firmware *are* the project; if you must support a
platform no existing loader handles; if certification forbids third-party code in the boot
path. None applies here, and the confinement rule below keeps the door open.

---

### Decision: request/response, or one fixed info struct?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — request/response** | You declare typed structs; the bootloader writes a typed pointer into each | Requests are found by scanning, so a build mistake silently yields zero requests; every response needs a null check | ✅ |
| B — Multiboot 2 tag stream | Bootloader builds a variable-length tag list; you walk it and cast each tag by its type field | Every access is a cast; alignment and bounds are your problem; the compiler checks nothing | ❌ |
| C — Multiboot 1 fixed struct | One struct at a known address plus a `flags` word where bit *N* means "field *M* is valid" | Frozen forever — no room to add anything; forget a flag check and you read a field nobody filled in | ❌ |

**Why A.** Three properties, in order of importance.

- **Typed.** `response->framebuffers[0]->pitch` is a field name the compiler checks. The
  alternative is `*(uint32_t*)(tag + 24)` and a comment you have to trust.
- **You ask only for what you need.** More usefully: a request that *changes behaviour* is
  opt-in. `LIMINE_SMP_REQUEST` actually starts the application processors;
  `LIMINE_STACK_SIZE_REQUEST` changes the stack you are handed. Not asking means not paying.
- **Forward compatible both ways.** A bootloader that does not know your request ignores it
  and leaves `response` null — it does not refuse to boot. A protocol that grows new fields
  puts them behind a higher `revision` you opt into. Nothing you write today breaks when
  Limine 9 ships.

**Why not C.** The flags word is the whole problem. `if (mbi->flags & (1 << 6))` before
touching `mmap_addr` is easy to skip, produces no diagnostic when skipped, and is *usually
fine in QEMU* because QEMU's firmware fills in more fields than real hardware does. That is
the exact shape of a bug that ships. A null pointer faults immediately, in the right place.

**Why not B.** Better than C, but it moves all type information to runtime: you cast an
integer offset into a struct pointer, hundreds of times, in the earliest and least
debuggable code in the system.

**When C would be right.** If Multiboot were the only option — some emulators and embedded
firmware speak nothing else — the discipline is: one function, one place, that validates
every flag bit and copies everything out. That is exactly the shape of Stage 0.3's
`collect_boot_info()`. The pattern transfers; only the source changes.

---

### Decision: does `limine.h` stay in one directory?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — confined** | `limine.h` only under `kernel/arch/x86_64/boot/`; responses copied into our own `BootInfo` | One extra struct, one extra copy, one extra translation unit | ✅ |
| B — include it anywhere | `fbcon.cpp` takes a `limine_framebuffer*`. Fewer lines today | The protocol becomes the kernel's internal interface; `kernel/mm/` stops being host-compilable; swapping bootloader means auditing the tree | ❌ |
| C — re-export wrapper | `kernel/include/kernel/boot.hpp` does `#include "limine.h"`; everyone includes that | All of B's coupling, and it passes the CI grep — the rule is defeated while looking green | ❌ |

**Why A.** [[ADR-0003 - Limine as the Bootloader]] says "swapping bootloaders means
rewriting one translation unit". That sentence is either true or it is decoration, and what
makes it true is that no Limine type appears in a signature outside `boot/`. Second payoff:
`kernel/mm/` and `kernel/fs/` compile on the *host* for Tier-1 tests
([[09 - Testing Strategy]]), and a `limine_memmap_entry` in a PMM header makes the PMM
untestable off-target — which costs far more than the translation layer.

**Why not B.** Concretely: the console takes `limine_framebuffer*`, the PMM takes
`limine_memmap_entry*`, ACPI takes the RSDP response. Now Limine renames `kernel_address`
to `executable_address` — which is exactly what `LIMINE_API_REVISION >= 2` already does in
the header sitting in your tree — and the rename lands in eleven files across five
subsystems you have not read for a year. Not hypothetical: the header's own `#if` blocks
are telling you the names are not stable.

**Why not C.** The CI rule greps for the string `limine.h` outside `boot/`
([[07 - Repository Layout]], boundary rule 2). A re-export header satisfies the grep and
changes nothing about the coupling. **The grep is a proxy for the constraint, not the
constraint.** If you find yourself engineering around it, you have found the rule working
correctly and are about to break it.

**The cost, stated plainly.** A is not free: it costs the `BootInfo` struct, the copying
code in `boot_info.cpp`, and the fact that adding a new piece of boot data means touching
three places instead of one. That work is
[[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]] — and it is also the fix for the
reclaimed-memory trap at the end of §5, so you were going to write the copy anyway. The
boundary is nearly free once you accept that copying is mandatory.

**When B would be right.** A single-target throwaway kernel with no tests and no second
architecture on the horizon. Or if the protocol were a stable standard you did not control
— but it is a pinned tag of a third-party project, which is the opposite.

---

### Decision: `volatile` on the request globals

This is the one place in the kernel where [[13 - Coding Standards]] rule 3 — *"`volatile` is
for MMIO, never for concurrency"* — needs a careful reading, because what happens here is
neither MMIO nor concurrency.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — `volatile` on the object** | Every read of `.response` is a real load from memory, guaranteed | Slightly worse codegen on a struct read a handful of times at boot | ✅ |
| B — plain globals + `used` | Relies on the optimiser not folding `.response` to its initialiser | Legal for the compiler to fold it; under LTO, likely | ❌ |
| C — `std::atomic` | Expresses "written by someone else" in the type system | Does not usefully compile: a 48-byte struct is not lock-free, so it needs `libatomic`, which does not exist in a freestanding kernel; also perturbs the layout the protocol dictates | ❌ |
| D — cast to `volatile` at each use | Same guarantee, applied at the read | The requirement moves to another file, repeated at every use, one miss from a silent miscompile | ❌ |

**Why A.** State the mechanism precisely, because "the bootloader might change it" is too
vague to reason about:

> `g_framebuffer_request.response` is initialised to `nullptr` at build time. **No code in
> this program ever assigns to it.** It is written by a *different program*, which has
> already exited by the time the first instruction of `kmain` runs.

From the compiler's point of view that is a global whose value is known at compile time and
never modified. Folding `request.response` to the constant `nullptr` is a completely correct
optimisation of the program as written. The optimiser is not being hostile; it is being
right about a program you lied to it about.

`volatile` is the C++ construct meaning "an agent outside this program's control flow can
change this object; issue a real load every time". That is exactly and only what is true
here. It is the same shape as an MMIO register — a memory location a non-program agent
writes — which is why rule 3 permits it. What rule 3 forbids is using `volatile` between
*two threads of this program*, where it gives neither atomicity nor ordering and you need
both. Here there is one thread and no ordering question at all: every write happened
strictly before `kmain` was entered.

`scripts/lint.sh`'s "no volatile on non-pointer shared state" rule exempts `kernel/arch/`
and only matches scalar declarations. These are `volatile` struct objects under
`kernel/arch/x86_64/boot/`, so they are outside the rule twice over. The exemption exists
for exactly this file.

**Why not B.** The failure is a null check the compiler evaluates at compile time.
`if (g_framebuffer_request.response == nullptr) halt();` folds to `if (true) halt();` and
you halt on a healthy boot; or the compiler proves the opposite in another inlining context
and you dereference a value it invented. Today, at `-O2` without LTO, GCC will probably
reload it because the object has external linkage. "Probably" is not a contract, and the day
it changes is the day someone adds `-flto` to speed up the build.

**Why not D.** It works, and it means `boot_info.cpp` — written next stage by whoever picks
it up — must remember the cast at all six use sites. Put the guarantee on the object, where
it cannot be forgotten and the reason can be commented once.

**When C would be right.** The moment two CPUs in *your* kernel touch the same variable —
[[Phase 12 - Overview|Phase 12]]. Then rule 3 applies at full force, `volatile` is wrong,
and `std::atomic` with an explicit memory order is the only correct answer.

---

### Decision: declare all six requests now, or one per phase?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — all six now** | Every request Phase 0–11 needs is declared today | ~304 bytes of data; six things whose purpose is not yet obvious | ✅ |
| B — add per phase | Add memmap in Phase 4, RSDP in Phase 11 | Every addition edits the file the entire boot depends on; a missing request surfaces five phases from the change | ❌ |

**Why A.** A declared request costs 48 bytes and zero instructions. A *missing* request costs
a debugging session in Phase 11 where ACPI gets a null RSDP and nothing in recent history
mentions boot. Declaring them all now also means Stage 0.3's `BootInfo` and its copy loop
get written exactly once.

**When B would be right.** For requests that **change the bootloader's behaviour** rather
than report facts. Three in the header do: `LIMINE_STACK_SIZE_REQUEST` changes the stack you
are handed, `LIMINE_PAGING_MODE_REQUEST` changes how many levels of page table Limine
builds, `LIMINE_SMP_REQUEST` actually starts the application processors. Those alter the
machine you wake up on, so each goes in during the phase ready to cope with it.

---

## 4. Specification

Everything below is read out of the vendored `limine.h`. When this note and the header
disagree, **the header wins** — check it.

### 4.1 The objects you declare

| # | Object | Type | Section | Bytes |
|---|---|---|---|---|
| 1 | `limine_requests_start_marker` | `uint64_t[4]`, from `LIMINE_REQUESTS_START_MARKER` | `.limine_requests_start` | 32 |
| 2 | `limine_base_revision` | `uint64_t[3]`, from `LIMINE_BASE_REVISION(N)` | `.limine_requests` | 24 |
| 3 | `g_framebuffer_request` | `limine_framebuffer_request` | `.limine_requests` | 48 |
| 4 | `g_memmap_request` | `limine_memmap_request` | `.limine_requests` | 48 |
| 5 | `g_hhdm_request` | `limine_hhdm_request` | `.limine_requests` | 48 |
| 6 | `g_kernel_address_request` | `limine_kernel_address_request` | `.limine_requests` | 48 |
| 7 | `g_module_request` | `limine_module_request` | `.limine_requests` | 64 |
| 8 | `g_rsdp_request` | `limine_rsdp_request` | `.limine_requests` | 48 |
| 9 | `limine_requests_end_marker` | `uint64_t[2]`, from `LIMINE_REQUESTS_END_MARKER` | `.limine_requests_end` | 16 |

Names 1, 2 and 9 are fixed by the macros and cannot be changed. It does not matter — Limine
finds all of these by magic bytes, never by symbol name. Seven are "requests" in the
protocol's sense: the base revision marker plus six questions. `.limine_requests` therefore
totals **24 + 48×5 + 64 = 328 bytes (0x148)**, possibly rounded up by alignment padding.

### 4.2 What each request buys you

| Request macro | Response type | Fields you will use | Needed by |
|---|---|---|---|
| `LIMINE_BASE_REVISION(N)` | *(none — writes into the marker)* | protocol version negotiation | always |
| `LIMINE_FRAMEBUFFER_REQUEST` | `limine_framebuffer_response` | `framebuffer_count`, `framebuffers[]` → `address`, `width`, `height`, `pitch`, `bpp`, `red_mask_shift`, … | [[Phase 1 - Overview\|Phase 1]] |
| `LIMINE_MEMMAP_REQUEST` | `limine_memmap_response` | `entry_count`, `entries[]` → `base`, `length`, `type` | [[Phase 4 - Overview\|Phase 4]] |
| `LIMINE_HHDM_REQUEST` | `limine_hhdm_response` | `offset` | [[Phase 4 - Overview\|Phase 4]] |
| `LIMINE_KERNEL_ADDRESS_REQUEST` | `limine_kernel_address_response` | `physical_base`, `virtual_base` | Stage 1.7 (backtraces) |
| `LIMINE_MODULE_REQUEST` | `limine_module_response` | `module_count`, `modules[]` → `limine_file` (`address`, `size`, `path`, `cmdline`) | [[Phase 7 - Overview\|Phase 7]] (initrd) |
| `LIMINE_RSDP_REQUEST` | `limine_rsdp_response` | `address` | [[Phase 11 - Overview\|Phase 11]] (ACPI) |

### 4.3 Request struct layout and the `id` field

Five of the six requests share one shape; `limine_module_request` adds two fields that only
exist at request revision 1.

| Offset | Size | Field | Written by |
|---|---|---|---|
| 0 | 32 | `uint64_t id[4]` | you, at build time |
| 32 | 8 | `uint64_t revision` | you, at build time |
| 40 | 8 | `response` pointer | **the bootloader** |
| 48 | 8 | `uint64_t internal_module_count` *(module only, req. rev. 1)* | you |
| 56 | 8 | `limine_internal_module** internal_modules` *(module only, req. rev. 1)* | you |

`id` is four 64-bit words, not one. `id[0]`/`id[1]` are `LIMINE_COMMON_MAGIC` —
`0xc7b1dd30df4c8b88`, `0x0a82e883a194f07b` — identical in **every** request; that 128-bit
value is what Limine scans memory for. `id[2]`/`id[3]` say which request it is:

| Request | `id[2]` | `id[3]` |
|---|---|---|
| framebuffer | `0x9d5827dcd881dd75` | `0xa3148604f6fab11b` |
| memmap | `0x67cf3d9d378a806f` | `0xe304acdfc50c3c62` |
| hhdm | `0x48dcf1cb8ad2b852` | `0x63984e959a98244b` |
| kernel address | `0x71ba76863cc55f63` | `0xb2644a48c516a487` |
| module | `0x3e7e279702be32af` | `0xca1c4f3bd1280cee` |
| rsdp | `0xc5e77b6b397e7b43` | `0x27637845accdcf3c` |

You never type these; you write `LIMINE_FRAMEBUFFER_REQUEST` and the macro expands to
`{ LIMINE_COMMON_MAGIC, 0x9d58…, 0xa314… }`. They are listed so you can recognise them in a
hex dump — see §6.

**Two `revision` fields, pointing opposite ways.** The *request* revision means "which of my
optional trailing fields have I filled in?" — set it to 0 and Limine reads nothing past
`response`. The *response* revision means "which of my trailing fields did the bootloader
fill in?" — `limine_framebuffer` marks `mode_count` and `modes` as "Response revision 1", so
reading them when the response revision is 0 reads uninitialised bytes. **Never touch a
field the header marks with a revision comment without checking `response->revision >= N`.**

### 4.4 The base revision marker

```c
#define LIMINE_BASE_REVISION(N) \
    uint64_t limine_base_revision[3] = { 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, (N) };
```

| Word | Initial value | After Limine has run |
|---|---|---|
| `[0]` | `0xf9562b2d5c95a6c8` | unchanged — this is what Limine searches for |
| `[1]` | `0x6a7b384944536bdc` | **overwritten** with the base revision actually loaded |
| `[2]` | `N` — the revision you want | **zeroed** if Limine can honour revision `N` |

| Macro | Expands to | Means |
|---|---|---|
| `LIMINE_BASE_REVISION_SUPPORTED` | `limine_base_revision[2] == 0` | the bootloader honoured revision `N`. **Check this first in `kmain`.** |
| `LIMINE_LOADED_BASE_REV_VALID` | `limine_base_revision[1] != 0x6a7b384944536bdc` | word `[1]` was overwritten, so the number in it means something |
| `LIMINE_LOADED_BASE_REVISION` | `limine_base_revision[1]` | the revision you actually got |

"Revision negotiation" is nothing more elaborate: you write a number in, the bootloader
writes a zero back if it agrees. The number is a knob — raising it opts into newer protocol
semantics and is guarded at runtime by `LIMINE_BASE_REVISION_SUPPORTED`, so a bump your
pinned Limine cannot honour fails loudly at boot rather than subtly later. Read
`PROTOCOL.md` for the highest revision your tag supports, and what each one changes, before
raising it.

### 4.5 Delimiter magic

| Marker | Words |
|---|---|
| `LIMINE_REQUESTS_START_MARKER` | `0xf6b8f4b39de7d1ae`, `0xfab91a6940fcb9cf`, `0x785c6ed015d3e316`, `0x181e920a7852b9d9` |
| `LIMINE_REQUESTS_END_MARKER` | `0xadc0e0531bb10d03`, `0x9572709f31764c62` |

`LIMINE_REQUESTS_DELIMITER` is defined in the header as an alias for the *end* marker.

Without delimiters Limine has to scan the entire loaded image for the common magic. That is
slower, and it is a correctness risk: if your kernel ever embeds a data blob — a font, a
compressed initrd, a test fixture — containing those sixteen bytes, Limine will try to
interpret it as a request. With delimiters the scan is bounded.

### 4.6 Machine state when `kmain` is entered

| Property | State | Consequence |
|---|---|---|
| CPU mode | 64-bit long mode | no trampoline to write |
| Paging | enabled, kernel mapped at its link address | you write your own tables in [[Phase 4 - Overview\|Phase 4]] |
| Interrupts | disabled (`IF = 0`) | `hlt` halts permanently — which is what you want today |
| Stack | valid, `RSP` set by Limine | you can call C++ immediately; your own stack with a guard page comes in Stage 0.4 |
| HHDM | established; offset in `limine_hhdm_response.offset` | it will be `0xFFFF800000000000`, but **read it, never hardcode it** |
| Arguments | none — `kmain` takes no parameters | everything arrives through response pointers |
| Application processors | **not started** unless you made `LIMINE_SMP_REQUEST` | Phase 12 |
| GDT | Limine's own | replaced in [[Phase 2 - Overview\|Phase 2]]; do not build on it |
| IDT | none you can use | any fault before Phase 2 is a triple fault |

Anything not in this table is unspecified. Check `PROTOCOL.md` before relying on it.

### 4.7 Do not define `LIMINE_API_REVISION`

The header defaults it to 0, and every name in this note assumes that default. Defining it
renames identifiers underneath you: `limine_kernel_address_request` becomes
`limine_executable_address_request`, `LIMINE_MEMMAP_KERNEL_AND_MODULES` becomes
`LIMINE_MEMMAP_EXECUTABLE_AND_MODULES`, `LIMINE_SMP_REQUEST` becomes `LIMINE_MP_REQUEST`,
and `limine_rsdp_response.address` changes from `void*` to `uint64_t`. Leave it alone.
Raising it is a deliberate, reviewed change to exactly one directory — which is the point of
confining the header there.

### 4.8 Memory map types

Full table is Phase 4's business; one value matters here.
`LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE` is **5**, and it is where every Limine response
lives. The others, for reference: `USABLE` 0, `RESERVED` 1, `ACPI_RECLAIMABLE` 2,
`ACPI_NVS` 3, `BAD_MEMORY` 4, `KERNEL_AND_MODULES` 6, `FRAMEBUFFER` 7.

---

## 5. Writing the code

### Vendoring `limine.h`

Not written — copied, and committed.

```sh
mkdir -p kernel/arch/x86_64/boot
cp "$LIMINE_DIR/limine.h" kernel/arch/x86_64/boot/limine.h
git add kernel/arch/x86_64/boot/limine.h
```

`$LIMINE_DIR` is `/opt/limine` inside the toolchain container, where the Dockerfile cloned
the pinned `v8.6.0-binary` tag ([[ADR-0005 - Containerised Pinned Toolchain]]).

**Commit it; do not fetch it during the build.** The header must not be able to drift out of
step with the pinned bootloader binary, and an offline build must still work. It is 711
lines and changes about twice a year. Only this directory may include it — `scripts/lint.sh`
fails the build otherwise ([[07 - Repository Layout]], boundary rule 2).

---

### `kernel/arch/x86_64/boot/entry.cpp`

The kernel's entry point, and the only file in the tree that knows the Limine protocol
exists.

```cpp
// kernel/arch/x86_64/boot/entry.cpp
//
// The kernel entry point, and the only place in the tree that knows Limine
// exists. ADR-0003.
//
// Limine loads this executable, scans it for the request structures below,
// writes a pointer into every .response it can honour, and then jumps to
// kmain with the CPU already in 64-bit long mode: paging on, interrupts off,
// a valid stack in RSP. There is no trampoline and no info-block argument.

#include <stdint.h>

#include "limine.h"  // vendored beside this file; see 07 - Repository Layout

// ---------------------------------------------------------------------------
// Base revision.
//
// Three 64-bit words. [0] and [1] are the magic Limine searches for; [2] is
// the protocol base revision this file is written against. Limine zeroes [2]
// if it can honour that revision, and overwrites [1] with the revision it
// actually loaded.
// ---------------------------------------------------------------------------
__attribute__((used, section(".limine_requests")))
static volatile LIMINE_BASE_REVISION(2);

// ---------------------------------------------------------------------------
// Requests.
//
// Each is located by the four 64-bit words in .id, never by symbol name or
// position, so the order below is free. `.response` is written by the
// bootloader — a different program, already finished when kmain starts — so
// every one of these is `volatile`. That is the MMIO-shaped exception in
// 13 - Coding Standards rule 3, and it is the only one in the kernel.
//
// These are NOT static: Stage 0.3's boot_info.cpp reads the responses from a
// sibling translation unit.
// ---------------------------------------------------------------------------

__attribute__((used, section(".limine_requests")))
volatile limine_framebuffer_request g_framebuffer_request = {
    .id       = LIMINE_FRAMEBUFFER_REQUEST,
    .revision = 0,
    .response = nullptr,
};

__attribute__((used, section(".limine_requests")))
volatile limine_memmap_request g_memmap_request = {
    .id       = LIMINE_MEMMAP_REQUEST,
    .revision = 0,
    .response = nullptr,
};

__attribute__((used, section(".limine_requests")))
volatile limine_hhdm_request g_hhdm_request = {
    .id       = LIMINE_HHDM_REQUEST,
    .revision = 0,
    .response = nullptr,
};

__attribute__((used, section(".limine_requests")))
volatile limine_kernel_address_request g_kernel_address_request = {
    .id       = LIMINE_KERNEL_ADDRESS_REQUEST,
    .revision = 0,
    .response = nullptr,
};

// Request revision 0, so Limine does not read internal_module_count /
// internal_modules. They are initialised anyway because -Wextra -Werror
// requires every field of a designated initialiser to be named.
__attribute__((used, section(".limine_requests")))
volatile limine_module_request g_module_request = {
    .id                    = LIMINE_MODULE_REQUEST,
    .revision              = 0,
    .response              = nullptr,
    .internal_module_count = 0,
    .internal_modules      = nullptr,
};

__attribute__((used, section(".limine_requests")))
volatile limine_rsdp_request g_rsdp_request = {
    .id       = LIMINE_RSDP_REQUEST,
    .revision = 0,
    .response = nullptr,
};

// ---------------------------------------------------------------------------
// Delimiters.
//
// Separate sections so the linker script (Stage 0.4) can emit them in the
// order start / requests / end. They bound the region Limine scans.
// ---------------------------------------------------------------------------
__attribute__((used, section(".limine_requests_start")))
static volatile LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests_end")))
static volatile LIMINE_REQUESTS_END_MARKER;

// ---------------------------------------------------------------------------
// Halting.
// ---------------------------------------------------------------------------
namespace {

// Parked in r15 before halting so `info registers` in the QEMU monitor says
// which path we took. Stage 0.6 replaces this with a serial message.
constexpr uint64_t HALT_UNSUPPORTED_BASE_REVISION = 0x0002'0001;
constexpr uint64_t HALT_END_OF_KMAIN              = 0x0002'0000;

[[noreturn]] void halt_forever(uint64_t code) {
    __asm__ volatile("cli");
    __asm__ volatile("mov %0, %%r15" : : "r"(code) : "r15");
    for (;;) {
        __asm__ volatile("hlt");
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Entry point.
//
// extern "C" so the symbol is `kmain`, not `_Z5kmainv`. The linker script's
// ENTRY(kmain) in Stage 0.4 resolves the unmangled name.
// ---------------------------------------------------------------------------
extern "C" [[noreturn]] void kmain() {
    if (!LIMINE_BASE_REVISION_SUPPORTED) {
        halt_forever(HALT_UNSUPPORTED_BASE_REVISION);
    }

    // Stage 0.3 replaces this with:
    //     BootInfo* info = collect_boot_info();
    //     kernel_init(info);
    halt_forever(HALT_END_OF_KMAIN);
}
```

---

#### Line by line

**The includes**

```cpp
#include <stdint.h>

#include "limine.h"
```

`<stdint.h>` is one of the few standard headers legal in a freestanding build
([[ADR-0007 - Freestanding C++20 as the Kernel Language]]) — it defines types, not
functions, so there is no library to link. You need it for `uint64_t` in `halt_forever`.
Quotes, not angle brackets: the header sits in this directory and the include path does not
contain it. If you find yourself adding `-I kernel/arch/x86_64/boot` so `<limine.h>` works
from elsewhere, stop — you are about to break the boundary.

---

**The base revision marker**

```cpp
__attribute__((used, section(".limine_requests")))
static volatile LIMINE_BASE_REVISION(2);
```

Four separate ideas in one line.

`LIMINE_BASE_REVISION(2)` expands to
`uint64_t limine_base_revision[3] = { 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, (2) };` —
**including the trailing semicolon**. The `;` you type is a second, empty declaration.
That is legal at namespace scope in C++11 and later and produces no warning under `-Wall
-Wextra`. It is written this way because the upstream Limine template does, and because a
declaration with no visible semicolon reads like a mistake.

`static` because nothing outside this file reads it: the three macros that interpret it
expand to direct array subscripts, so they only work in the translation unit that declared
the array.

`volatile` because word `[2]` is zeroed by the bootloader, from outside this program.
Without it, `LIMINE_BASE_REVISION_SUPPORTED` — literally `limine_base_revision[2] == 0` —
is a comparison of two compile-time constants (`2 == 0`), which the optimiser folds to
`false`. The kernel would then halt on every successful boot, with the "unsupported base
revision" code in `r15`, on a machine where the revision was supported perfectly.

The `2` is the protocol base revision (§4.4). The runtime check below means a wrong guess
fails loudly rather than subtly.

---

**`__attribute__((used, section(...)))` — the two attributes that make this work**

```cpp
__attribute__((used, section(".limine_requests")))
```

The most important line in the file, and the one people get wrong.

**`section(".limine_requests")`** tells GCC to emit this object into a section with that
name instead of `.data`. Normally initialised globals go in `.data`, interleaved with
everything else in link order. Unacceptable here for two reasons. First, the delimiters have
to *bound* the requests, which you can only guarantee if the requests are collected into one
contiguous region the linker script can place between them. Second, Stage 0.4's linker
script needs a name to write `KEEP(*(.limine_requests))` against, so the region survives
`--gc-sections`.

A typo here is silent. `.limine_request` (missing `s`) compiles, links, and produces a
section. Limine scans loaded memory rather than sections, so it *could* still find those
requests — but only if the section lands in a `PT_LOAD` segment and inside the delimiters,
and neither is true for a name the linker script does not mention. Default `ld` rules will
place `.limine_request` somewhere after the delimiters, or drop it. Result: zero recognised
requests, no diagnostic.

**`used`** tells GCC: *do not delete this, even though nothing reads it.* Without it:

1. `g_framebuffer_request` is a global no function reads or writes.
2. GCC at `-O2` concludes it is dead and removes it — outright for a `static` object, and
   for an external-linkage object under LTO or `-fdata-sections` + `--gc-sections`.
3. `.limine_requests` is emitted with size **0**.
4. Limine scans between the delimiters, finds no magic, honours nothing.
5. Every `response` pointer is `nullptr`.
6. Phase 1 dereferences one, with no IDT, so the page fault escalates to a double fault,
   which has no handler either, so it escalates to a triple fault and the machine resets.

**You see a reboot loop and a blank screen.** Nothing in that chain names `used`,
`entry.cpp`, or `.limine_requests`. §6's `objdump -h` check exists specifically to catch it
at build time, three stages before it can hurt you.

`used` and `KEEP` are not the same and you need both. `used` stops the **compiler** deleting
the object. `KEEP` stops the **linker** garbage-collecting the section. Either alone leaves
a hole.

---

**The anatomy of one request**

```cpp
__attribute__((used, section(".limine_requests")))
volatile limine_framebuffer_request g_framebuffer_request = {
    .id       = LIMINE_FRAMEBUFFER_REQUEST,
    .revision = 0,
    .response = nullptr,
};
```

**`.id`** is `uint64_t id[4]` — 32 bytes. The macro expands to
`{ LIMINE_COMMON_MAGIC, 0x9d5827dcd881dd75, 0xa3148604f6fab11b }`, and `LIMINE_COMMON_MAGIC`
is itself two words. So the first 128 bits are the magic every request shares — the pattern
Limine actually searches memory for — and the second 128 bits say which request this is.
Getting the ID wrong is impossible if you use the macro, which is exactly why you use it.

**`.revision = 0`** is the *request* revision: which of the struct's optional trailing fields
you filled in. `limine_framebuffer_request` has none, so 0 is the only sensible value. Not
the same `revision` as the one in the response — §4.3.

**`.response = nullptr`** is the field the bootloader writes and **you never touch again**.
Read it in `kmain`; never assign to it. The explicit `nullptr` is initialisation, not use:
the upstream template omits it, but with `-Wextra -Werror` GCC reports

```
warning: missing initializer for member 'limine_framebuffer_request::response'
         [-Wmissing-field-initializers]
```

and the build fails. Writing it costs nothing and is correct on every compiler.

**`volatile`** is on the whole object. Reading `g_framebuffer_request.response` through a
volatile-qualified object gives a genuine load from memory. The resulting pointer value is a
plain `limine_framebuffer_response*` — `volatile` qualifies the pointer *member*, not what
it points at — so Stage 0.3 can assign it to an ordinary pointer with no cast. Which is
right: the *response* is written once, before you run, and needs no special treatment. Only
the mailbox does.

**Not `static`.** The upstream template marks these `static`. We do not, because Stage 0.3's
`boot_info.cpp` is a separate translation unit that has to read the responses; it will
declare them `extern` in a small internal header beside these files. If you ever collapse
`boot_info.cpp` into `entry.cpp`, make them `static` — narrower linkage is free.

---

**The remaining five requests**

Identical shape, different `id`. Note the type name `limine_kernel_address_request` — that
spelling depends on `LIMINE_API_REVISION` being left at its default of 0 (§4.7). The module
request is the odd one out:

```cpp
volatile limine_module_request g_module_request = {
    .id                    = LIMINE_MODULE_REQUEST,
    .revision              = 0,
    .response              = nullptr,
    .internal_module_count = 0,
    .internal_modules      = nullptr,
};
```

Those last two are marked `/* Request revision 1 */` in the header: they let a kernel demand
modules the boot config did not list. We are at request revision 0, so Limine will not read
them — but `-Wmissing-field-initializers` does not know that, so they get initialised
anyway. Modules are how the initrd arrives ([[Phase 7 - Overview|Phase 7]]);
`boot/limine.conf` already lists `module_path: boot():/initrd.tar`.

C++20 designated initialisers must appear in **declaration order**. Putting `.revision`
before `.id` is a compile error, which is a small mercy.

---

**The delimiters**

```cpp
__attribute__((used, section(".limine_requests_start")))
static volatile LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests_end")))
static volatile LIMINE_REQUESTS_END_MARKER;
```

Three separate section names because the linker script has to emit them in order:

```
.limine_requests : {
    KEEP(*(.limine_requests_start))
    KEEP(*(.limine_requests))
    KEEP(*(.limine_requests_end))
}
```

That is Stage 0.4's job; it is quoted here so you can see why the section names are what
they are. If all three went into one section you would have no way to force the markers to
the ends — ordering within a section is at the linker's discretion.

The markers are found by their own magic (§4.5), not by section name. If the start marker
ends up *after* a request — which is what happens when the linker script omits the ordering
— Limine bounds its scan to a region that excludes that request, and that request alone
comes back null. Five requests honoured, one not, is a genuinely confusing failure.

`static` for the same reason as the base revision marker: nothing outside this file has any
use for them.

---

**The halt path**

```cpp
constexpr uint64_t HALT_UNSUPPORTED_BASE_REVISION = 0x0002'0001;
constexpr uint64_t HALT_END_OF_KMAIN              = 0x0002'0000;

[[noreturn]] void halt_forever(uint64_t code) {
    __asm__ volatile("cli");
    __asm__ volatile("mov %0, %%r15" : : "r"(code) : "r15");
    for (;;) {
        __asm__ volatile("hlt");
    }
}
```

Named constants rather than bare numbers, per [[13 - Coding Standards]] rule 8. The `0002`
is the stage number; it makes an unexpected halt greppable.

`cli` clears the interrupt flag. Limine already entered with interrupts disabled, so this is
belt and braces — but it makes the function correct to call from anywhere later, and after
Phase 2 that matters.

The `mov` into `r15` is a debugging affordance you use in Stage 0.5: when the kernel halts,
break into the QEMU monitor and type `info registers`. `r15` is chosen because it is
callee-saved and nothing here uses it. The clobber list names `r15` because the asm writes
it — an omitted clobber is undefined behaviour the optimiser eventually exploits
([[13 - Coding Standards]] rule 2). No `"memory"` clobber: the rule of thumb is "asm that
touches hardware needs `memory`", and a register-to-register `mov` touches none.

**`hlt` rather than an empty loop, and this is not a style preference.** A `for (;;) {}` with
no side effects is undefined behaviour in C++ — the forward-progress guarantee
([intro.progress]) lets the compiler assume every loop terminates, and GCC and Clang both
act on that by deleting the loop and letting control fall through into whatever bytes
follow. Your "halt" becomes a jump into the next function. An `__asm__ volatile` statement
is an observable side effect, so the loop must be kept.

`hlt` also stops the CPU until the next interrupt, which with `IF = 0` is never. The
practical difference: your fan stays quiet and QEMU stops burning a host core. A spin loop
looks identical from outside and pins a CPU at 100%.

`[[noreturn]]` lets GCC drop the epilogue and, more usefully, makes it a
`-Winvalid-noreturn` warning if anyone later adds a path that falls off the end.

---

**`extern "C"` and `kmain`**

```cpp
extern "C" [[noreturn]] void kmain() {
```

`extern "C"` suppresses C++ name mangling. Without it the Itanium C++ ABI encodes the
parameter types into the symbol so overloads can coexist, and `void kmain()` becomes:

```
_Z5kmainv
 │ │└──┬─┘│
 │ │   │  └─ parameter list: v = void
 │ │   └──── the name, length-prefixed: 5 characters, "kmain"
 │ └──────── name length follows
 └────────── _Z: this is a mangled C++ name
```

Stage 0.4's linker script says `ENTRY(kmain)`. `ld` looks for a symbol spelled exactly
`kmain`, does not find one, and — this is the important part — **does not error**:

```
ld: warning: cannot find entry symbol kmain; defaulting to 00000000ffffffff80000000
```

A *warning*, which scrolls past in a build log. `ld` then sets the ELF header's `e_entry` to
the start of the output section instead. `-Werror` does not help: that is a compiler flag and
this is the linker. Limine reads `e_entry` and jumps there. You land in whatever the linker
happened to put first — quite possibly `.limine_requests`, executing request magic as
instructions — and the machine triple-faults.

The fix is one keyword. The way you catch it is `nm`, in §6.

`kmain` takes **no parameters**, and that is the protocol, not a simplification: Limine
passes nothing in registers. Everything arrives through the response pointers.
`void kmain(void)` is the same declaration in C++ if you prefer the explicit spelling.

---

**The body**

```cpp
    if (!LIMINE_BASE_REVISION_SUPPORTED) {
        halt_forever(HALT_UNSUPPORTED_BASE_REVISION);
    }

    halt_forever(HALT_END_OF_KMAIN);
}
```

The base revision check is the first thing `kmain` does, before anything reads a response,
because if the bootloader could not honour the revision then nothing below is trustworthy.
It is also the only line in this stage whose behaviour depends on input, and the reason the
`volatile` on the marker is load-bearing rather than decorative.

Then it halts. **`kmain` must never return.** Limine *jumps* to the entry point; the protocol
does not promise a return address on the stack. A `ret` pops whatever eight bytes sit at
`RSP` into `RIP` — often zero, so you jump to address 0, which is unmapped, so you page
fault, and with no IDT that becomes a triple fault and a reset. You would see the Limine menu
reappear and conclude your kernel never ran. `[[noreturn]]` plus a `halt_forever` on every
path makes that structurally impossible. Stage 0.3 replaces the final `halt_forever` with
`collect_boot_info()` and `kernel_init()` — and keeps a `halt_forever` after them, for
exactly this reason.

---

### The trap that bites later: bootloader-reclaimable memory

Everything above is about getting the *pointers*. This is about how long they stay valid,
and it is the single most consequential fact in Phase 0.

**Limine's response structures do not live in your kernel image.** Your image holds the
request structs — the mailboxes. The replies are allocated by Limine, in memory it marks
`LIMINE_MEMMAP_BOOTLOADER_RECLAIMABLE` (type 5, §4.8). That name is a promise *to you*: once
you no longer need what the bootloader left behind, that memory is yours.

In [[Phase 4 - Overview|Phase 4]] you write the physical memory manager, and it does exactly
what the name invites — folds every type-5 region into the free pool and starts handing
those pages to `kmalloc`. At that moment every pointer into a Limine response becomes a
pointer into the heap.

The failure mode is what earns this its own section:

- **It does not fault.** The memory is mapped, readable, writable. Nothing traps.
- **It does not fail immediately.** The pages are free but unused, so the old contents
  survive for a while and the kernel keeps working.
- **It fails later, under load,** once the heap has churned enough to reuse those pages.
  `boot_info->fb_addr` becomes a fragment of a filesystem cache entry and the console starts
  drawing into random memory.
- **Nothing in the diff explains it.** The commit that broke it is the PMM commit, in Phase
  4. The bug is in `boot_info.cpp`, written in Phase 0, unmodified since.

The fix is mechanical and it is [[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]]: **copy
everything out of the responses into your own `BootInfo` before anything else runs.** Scalars
get copied. Memory map entries get copied into a fixed array. Module descriptors get copied —
the module *contents* stay where they are, because they can be large, but their ranges are
marked reserved in Phase 4 so the allocator never hands them out.

The rule, phrased so it is easy to review against:

> **After `collect_boot_info()` returns, no pointer derived from a Limine response is stored
> anywhere in the kernel.**

That rule is also what makes the boundary in [[07 - Repository Layout]] rule 2 hold: if no
Limine pointer escapes `boot/`, no Limine type needs to either.

---

## 6. How to verify

You cannot boot yet — no linker script (Stage 0.4), no image (Stage 0.5). Four things are
checkable **now**, and they catch every mistake that would otherwise surface as a blank
screen.

### Now: it compiles clean

```sh
x86_64-elf-g++ -ffreestanding -fno-exceptions -fno-rtti -fno-stack-protector \
    -fno-pic -fno-pie -mcmodel=kernel -mno-red-zone -mno-sse -mno-mmx -mno-80387 \
    -std=c++20 -Wall -Wextra -Werror \
    -c kernel/arch/x86_64/boot/entry.cpp -o /tmp/entry.o
```

Expected output: **nothing**, exit status 0. Any warning is an error here; that is the point
of `-Werror`.

### Now: `kmain` is an unmangled global text symbol

```sh
x86_64-elf-nm /tmp/entry.o | grep -i kmain
```

Expected — one line, exactly:

```
0000000000000000 T kmain
```

`T` means a defined symbol in the text section; uppercase means global. The address is 0 in a
relocatable object and means nothing. **The failure you are checking for:**

```
0000000000000000 T _Z5kmainv        ← extern "C" is missing
```

If you see that, Stage 0.4's `ENTRY(kmain)` produces a linker *warning*, not an error, and
the kernel boots into garbage. Catch it here.

The full table is worth one look. `x86_64-elf-nm /tmp/entry.o` should list all six
`g_*_request` symbols plus the three macro-generated ones:

```
0000000000000000 D g_framebuffer_request
0000000000000030 D g_hhdm_request
...
0000000000000000 T kmain
0000000000000130 d limine_base_revision
0000000000000000 d limine_requests_end_marker
0000000000000000 d limine_requests_start_marker
```

`nm` sorts by name, not address, and `halt_forever` may be inlined out of existence at `-O2`.
Two things matter: **uppercase `D`** for the six requests (global, initialised data) versus
**lowercase `d`** for the three macro-generated objects (they are `static`); and that all ten
exist at all. A missing request means `used` did not do its job.

### Now: `.limine_requests` is not empty

This is the check that catches the `used` bug. Run it every time you touch this file.

```sh
x86_64-elf-objdump -h /tmp/entry.o
```

```
Sections:
Idx Name                     Size      VMA               LMA               File off  Algn
  0 .text                    0000000f  0000000000000000  0000000000000000  00000040  2**0
                  CONTENTS, ALLOC, LOAD, READONLY, CODE
  3 .limine_requests         00000148  0000000000000000  0000000000000000  00000050  2**3
                  CONTENTS, ALLOC, LOAD, DATA
  4 .limine_requests_start   00000020  0000000000000000  0000000000000000  00000198  2**3
                  CONTENTS, ALLOC, LOAD, DATA
  5 .limine_requests_end     00000010  0000000000000000  0000000000000000  000001b8  2**3
                  CONTENTS, ALLOC, LOAD, DATA
```

Indices, file offsets, alignment, and the size of `.text` vary with optimisation level. What
must be true:

| Section | Expected size | Arithmetic |
|---|---|---|
| `.limine_requests` | `0x148` (328), give or take alignment padding | 24 (base revision) + 48 × 5 + 64 (module) |
| `.limine_requests_start` | `0x20` (32) | `uint64_t[4]` |
| `.limine_requests_end` | `0x10` (16) | `uint64_t[2]` |

**How to read a zero-sized `.limine_requests`.** If you see `00000000` as the size, or the
section is absent entirely, the objects were emitted and deleted, or never emitted. In order
of likelihood:

1. **`used` is missing or misspelled.** `__attribute__((section(".limine_requests")))`
   without `used` is the classic: GCC saw a global nobody reads and removed it. By far the
   most common cause, and why the attribute is written `used, section(...)` in that order —
   a truncated copy-paste then loses `section`, which fails loudly, rather than `used`, which
   fails silently.
2. **The section name is misspelled** — `.limine_request`, `.limine-requests`, a trailing
   space. Look at the names `objdump` printed; the typo is sitting there in plain sight.
3. **The attribute is attached to the wrong thing** — after the declarator, on a `typedef`,
   or separated by a stray semicolon. GCC usually warns `attribute ignored`, which with
   `-Werror` you would have seen. Another reason to keep `-Werror` on.

Do not proceed past this check. A zero-sized request section is the direct cause of the
blank-screen reboot loop in §5, and every stage between here and Stage 0.5 will look
completely healthy.

### Now: the magic is really in there, and the boundary holds

```sh
x86_64-elf-objdump -s -j .limine_requests /tmp/entry.o
```

```
Contents of section .limine_requests:
 0000 888b4cdf 30ddb1c7 7bf094a1 83e8820a  ..L.0...{.......
 0010 75dd81d8 dc27589d 1bb1faf6 048614a3  u....'X.........
 0020 00000000 00000000 00000000 00000000  ................
```

`888b4cdf 30ddb1c7` is `0xc7b1dd30df4c8b88` little-endian — the first word of
`LIMINE_COMMON_MAGIC`. It appears **six times**, once per request. The base revision marker's
own magic `0xf9562b2d5c95a6c8` shows up as `c8a6955c 2d2b56f9`, and the first eight bytes of
`-j .limine_requests_start` are `aed1e79d b3f4b8f6`. The runs of zeroes are the `.response`
pointers, waiting.

```sh
grep -rl 'limine\.h' kernel/ --include='*.cpp' --include='*.hpp' --include='*.h' \
  | grep -v '^kernel/arch/x86_64/boot/'
```

Expected output: **nothing**. That is the exact grep from `scripts/lint.sh`, so `make lint`
will agree.

### Later: what cannot be checked yet

That it links and `e_entry` points at `kmain`, and that `.limine_requests` lands inside a
`PT_LOAD` segment in start/requests/end order (`readelf -l`), are **Stage 0.4**. That Limine
actually recognises the requests and reaches the kernel is **Stage 0.5**. That every response
is non-null on a real boot is [[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]]'s logic,
first observable in [[Stage 0.6 - Serial Output|Stage 0.6]].

- [ ] Compiles with the full kernel flag set, `-Werror`, zero warnings
- [ ] `nm` shows `T kmain` — uppercase `T`, and not `_Z5kmainv`
- [ ] `objdump -h` shows `.limine_requests` at roughly `0x148` bytes, not `0`
- [ ] `.limine_requests_start` is 32 bytes; `.limine_requests_end` is 16 bytes
- [ ] All six `g_*_request` symbols appear in `nm` output
- [ ] `objdump -s -j .limine_requests` shows `888b4cdf 30ddb1c7` six times
- [ ] The `limine.h` confinement grep returns nothing
- [ ] `limine.h` is committed, not fetched at build time

---

## 7. Common traps

**Symptom: blank screen, QEMU resets in a loop, back to the Limine menu.** `used` is missing,
so GCC deleted the request globals and `.limine_requests` is zero bytes. Limine honoured
nothing, every `response` is null, and the first dereference triple-faults with no IDT to
report it. Fix: add `used`; verify with `objdump -h` before building any image.

**Symptom: `ld: warning: cannot find entry symbol kmain; defaulting to …`, and the kernel
appears not to run.** `extern "C"` is missing, so the symbol is `_Z5kmainv`. It is a
*warning*, so the build succeeds and produces an ELF whose entry point is wherever the linker
guessed. Fix: `extern "C"`. Verify with `nm | grep kmain`.

**Symptom: five requests honoured, one comes back null, consistently.** That request landed
outside the region bounded by the markers — almost always because the linker script does not
emit `.limine_requests_start`, `.limine_requests`, `.limine_requests_end` in that order, or
omits one. Fix: Stage 0.4's ordering; confirm with `readelf -l` that the whole run is inside
one `PT_LOAD`.

**Symptom: the kernel halts immediately with `r15 = 0x20001`.**
`LIMINE_BASE_REVISION_SUPPORTED` was false. Either the requested revision is higher than your
pinned Limine supports — check `PROTOCOL.md` for your tag — or the marker was optimised away
and the check folded to a constant. Distinguish with `objdump -s`: if the marker's magic is
in the section, the bootloader really did decline.

**Symptom: build fails with `missing initializer for member '…::response'`.** You copied the
upstream template, which omits `.response`, and this project builds with `-Wextra -Werror`.
Fix: write `.response = nullptr,`. It changes nothing at runtime.

**Symptom: works at `-O0`, breaks at `-O2`.** A missing `volatile`. At `-O0` GCC reloads
everything from memory so a plain global behaves; at `-O2` it folds `.response` to its
initialiser and your null checks become compile-time constants. Fix: `volatile` on the
request objects. §3 is the whole argument.

**Symptom: `kmain` halts but QEMU is pinned at 100% CPU.** `for (;;) {}` instead of a loop
containing `hlt`. If the loop survived optimisation at all — it need not, since an empty loop
with no side effects is undefined behaviour — it is a spin. Fix: `__asm__ volatile("hlt")`
inside the loop.

**Symptom: `error: 'limine_kernel_address_request' was not declared in this scope`.**
Something defined `LIMINE_API_REVISION` to 1 or 2 before the include, renaming it to
`limine_executable_address_request`. Fix: do not define it (§4.7).

**Symptom: CI fails the "limine.h confined" rule after a refactor.** A Limine type escaped
`kernel/arch/x86_64/boot/`. It usually starts as "just this one function takes a
`limine_framebuffer*`". Fix: put the field in `BootInfo`. Adding a wrapper header that
re-exports `limine.h` passes the grep and defeats the rule — do not.

**Symptom: everything works for five phases, then the framebuffer draws garbage after heavy
filesystem activity.** A retained pointer into a Limine response, and Phase 4's PMM has
reused that memory. See the end of §5. Fix: copy everything out in Stage 0.3.

**Symptom: `clang-tidy` complains that `limine_base_revision` lacks the `g_` prefix.**
`readability-identifier-naming` versus a macro-generated name you cannot change. Warning only
— `WarningsAsErrors` covers `bugprone-*`, `cert-*`, `clang-analyzer-*`, not `readability-*` —
so the build is fine. Ignore it, or suppress it on the line with a comment saying why.

**Symptom: you go looking for `mbi`, `mods_addr`, or magic `0x2BADB002`.** A Multiboot
tutorial. None of that exists in this protocol: Limine passes nothing in registers and there
is no info structure. See [[ADR-0003 - Limine as the Bootloader]].

---

## 8. What this unlocks

Every remaining stage in Phase 0 depends on this file. Stage 0.4's linker script exists to
place `.limine_requests` correctly and to resolve `ENTRY(kmain)`; Stage 0.5's image only
boots because Limine finds the requests; [[Stage 0.3 - Freestanding C++ and kmain]] copies
the responses into `BootInfo`, which is what [[Phase 1 - Overview|Phase 1]]'s console,
[[Phase 4 - Overview|Phase 4]]'s memory manager, [[Phase 7 - Overview|Phase 7]]'s initrd and
[[Phase 11 - Overview|Phase 11]]'s ACPI all read. Done wrong, this stage fails silently and
blames a stage written months later: a missing `used` looks like a broken linker script, a
missing request looks like broken ACPI, and a retained response pointer looks like a broken
heap.

---

## 9. Reading

- **Limine protocol specification** — the whole document, once. It is short, and it is the
  authority for everything in §4 the header does not state outright (what each base revision
  changes, the CPU-state guarantees, what "bootloader reclaimable" promises):
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
  Read the version matching your pinned tag, not trunk, before relying on a detail.
- **The vendored `limine.h` itself** — 711 lines, and the ground truth for every name in this
  note. When a tutorial and the header disagree, the header wins.
- **OSDev — Limine Bare Bones.** The smallest complete Limine kernel; useful for
  cross-checking the shape of the request declarations:
  <https://wiki.osdev.org/Limine_Bare_Bones>
- **GCC — Common Variable Attributes.** The normative text for `used` and `section`,
  including what `used` does and does not promise:
  <https://gcc.gnu.org/onlinedocs/gcc/Common-Variable-Attributes.html>
- **Itanium C++ ABI — Mangling.** Why `kmain` becomes `_Z5kmainv`, and how to decode any
  other mangled symbol in a linker error:
  <https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangling>
- **GNU `ld` manual.** Read the `KEEP` section now — it is the other half of the `used` story
  and Stage 0.4's central idea: <https://sourceware.org/binutils/docs/ld/>
- **OSDev — Beginner Mistakes.** The "my kernel triple faults" section maps almost
  one-for-one onto §7: <https://wiki.osdev.org/Beginner_Mistakes>
- [[ADR-0003 - Limine as the Bootloader]] — why Limine, and the escape hatch this stage makes
  real
- [[07 - Repository Layout]] — boundary rule 2 and the CI grep that enforces it
- [[13 - Coding Standards]] — rule 2 (clobber lists), rule 3 (`volatile`), rule 8 (named
  constants); all three appear in this file
- [[06 - Architecture Overview]] — the boot chain diagram this stage implements

Next: **[[Stage 0.3 - Freestanding C++ and kmain]]**

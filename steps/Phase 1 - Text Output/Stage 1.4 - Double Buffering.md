# Stage 1.4 — Double Buffering

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you change:** `kernel/drivers/char/fbcon.cpp`, `kernel/drivers/char/console.cpp`, `kernel/include/kernel/fbcon.hpp`
**Deliverable:** flicker-free, fast redraws — scrolling a full screen is imperceptible, and the panic screen still appears.

---

## Progress

- [ ] Add the static back buffer to `fbcon.cpp` — **no initialiser, so it lands in `.bss`**
- [ ] Confirm with `size` that `.bss` grew and the ELF file size did not
- [ ] Teach `fb_init` to decide whether the mode fits, and log which path it took
- [ ] Point `fb_putpixel` and `fb_fill_rect` at the back buffer when there is one
- [ ] Add `fb_mark_dirty`, and call it from every drawing primitive
- [ ] Write `flush_rows()` — **stores only, `dst += pitch`, `src += stride`**
- [ ] Add `fb_flush()` and `fb_flush_all()`
- [ ] Add `fb_scroll_up()` — the scroll now happens in RAM
- [ ] Split `console_putc` into `putc_noflush` + one flush per public call
- [ ] Make `console_write` flush **once**, not once per character
- [ ] Add `fb_flush_all()` to the panic sink — **panic halts, so it must flush itself**
- [ ] Measure: 1000 lines with `rdtsc` before and after the change
- [ ] Boot at a resolution where `pitch != width * 4` and check for shear
- [ ] Committed with a message like `perf(fbcon): draw into a RAM back buffer and flush`

---

## 1. Why this stage exists

Your console works. Stages [[Stage 1.1 - The Linear Framebuffer|1.1]] through
[[Stage 1.3 - A Console - Cursor, Colour, Scrolling|1.3]] built a framebuffer driver, a
font rasteriser, and a console with a cursor and a scroll. Every one of those writes pixels
straight into framebuffer memory, and one of them also *reads* them.

That read is the problem. Framebuffer memory is not RAM. It is a device aperture reached
across the system bus, mapped **write-combining**, and reading from it costs ten to a
hundred times what a read from RAM costs. Stage 1.3's scroll is a `memmove` on that memory:
to shift the screen up by one text line at 1280x800 it reads **3.83 MiB** out of the device
and writes it straight back. At a plausible 0.2–1 µs per read that is **0.1 to 0.5 seconds
of CPU, per scrolled line.** You will not notice while the screen fills for the first time.
You will notice the moment anything prints in a loop — a memory-map dump, a page-table
walk, a `kprintf` in an interrupt handler — and what you will see is a console that crawls
one line at a time like a teletype. The kernel is not slow. The kernel is spending all its
time reading pixels back out of a graphics card.

The second symptom is visual. Scan-out hardware reads the framebuffer about sixty times a
second and does not care that you are halfway through a scroll. For the tenth of a second
the scroll takes, the display shows a screen that is partly moved and partly not, with a
blank strip at the bottom because you cleared the last line before drawing into it. That is
the flicker.

Both have one fix: **do the work somewhere else.** Draw into ordinary cached RAM where
reads are cheap, and when the frame is finished push it to the device as one straight run
of writes. That turns a 0.5-second scroll into a 2-millisecond one. The catch, and the
reason this stage needs a design section rather than twenty minutes of typing, is that
**there is no heap yet.** `kmalloc` does not exist until
[[Stage 4.4 - The Kernel Heap|Stage 4.4]], three phases away. You cannot allocate 4 MiB.
§3 is about what you do instead.

---

## 2. The concept

### Where the framebuffer actually is

`BootInfo::fb_addr` is a virtual address, but the physical pages behind it are not system
RAM. They are a **PCI Base Address Register aperture** — a window the graphics device
claims in the physical address space, which the host bridge routes to the device instead of
to the memory controller. A store becomes a bus transaction. A load becomes a bus
transaction *and a round trip*.

### Memory types, and what write-combining is

x86 tags every mapping with a **memory type** telling the cache hierarchy how to treat it.
**WB (write-back)** is ordinary RAM: cached both ways. **UC (uncacheable)** gives every
access its own bus transaction in strict program order — right for a device control
register, where reading twice must mean two real reads. **WC (write-combining)** is the
middle ground, built for framebuffers.

WC writes do not enter the cache. They go into a small set of dedicated **write-combining
buffers**, each one cache line wide — 64 bytes on every x86-64 part you will meet.
Consecutive stores accumulate in a buffer, and when it fills, the whole thing is pushed out
as a **single 64-byte burst**. Sixteen 4-byte pixel stores become one bus transaction.

```
   WRITE-COMBINING, WRITES

   store fb[0]  store fb[1]  store fb[2] ...        store fb[15]
        │            │            │                      │
        ▼            ▼            ▼                      ▼
   ┌────┬────┬────┬────┬────┬────┬────┬ ... ┬────┐   64 bytes
   │ px │ px │ px │ px │ px │ px │ px │     │ px │   ← WC buffer
   └────┴────┴────┴────┴────┴────┴────┴ ... ┴────┘
                                                  FULL
                                                   │
                                                   ▼
                              ONE burst transaction on the bus
```

That is why sequential writes to a framebuffer are fast, and why **the order you write in
matters**. A buffer forced out half full goes to the bus as several small transactions
instead of one big one. A linear left-to-right, top-to-bottom sweep fills every buffer
completely; a glyph-shaped pattern — eight pixels, jump a scanline, eight more — does not.

### The read

```
   WRITE-COMBINING, ONE READ

   load fb[k]
       │
       ├─► partial WC buffers are forced out first
       │
       └─► request packet ──────► host bridge ──────► device
                                                        │
           CPU stalls  ....................            (decode, respond)
                                                        │
           ◄────────────────────── completion packet ◄───┘
```

A read of WC memory is **not cached and not combined**. There is no line fill, so reading
four bytes fetches four bytes — the next read pays the full latency again, and there is
nothing to prefetch into. Worse, the read must be ordered against writes still sitting in
the WC buffers, so it forces them out first, destroying the batching you were relying on.

| Access | Typical latency |
|---|---|
| L1 cache hit | ~1 ns |
| Miss all the way to DRAM | ~60–100 ns |
| **Read from a device aperture across the bus** | **~0.5–2 µs** |

That is the "one to two orders of magnitude" the [[Phase 1 - Overview|phase overview]]
warns about, and why its rule is absolute: **never read from framebuffer memory.**

### Why the naive scroll is pathological

```cpp
memmove(fb, fb + line_bytes, (height - GLYPH_H) * pitch);   // the bug
```

A copy reads. At 1280x800x32 this reads `1280 x 784 x 4 = 4,014,080` bytes — 3.83 MiB —
out of the graphics device, four or eight bytes at a time, each a separate round trip.
Roughly **500,000 bus round trips**, and no amount of clever coding fixes it, because the
reads *are* the algorithm. Nothing softens it either: you build with `-mno-sse`
([[ADR-0007 - Freestanding C++20 as the Kernel Language]]) so there are no wide vector
loads, and `rep movsb` optimises the *store* side while the load side still pays device
latency. The only fix is to stop reading.

### What double buffering is, and why the flicker goes

Keep a second copy of the screen in ordinary write-back RAM — the **back buffer** — and
make it the thing your drawing code touches. Every read your renderer does now hits cache.
Then, once the frame is complete, copy it to the framebuffer in one linear pass of stores.

```
   BEFORE (stages 1.1-1.3)                AFTER (this stage)

   ┌──────────────┐                       ┌──────────────┐
   │ console.cpp  │                       │ console.cpp  │
   └──────┬───────┘                       └──────┬───────┘
          │ putpixel / memmove                   │ putpixel / scroll
          ▼                                      ▼
   ┌──────────────┐                       ┌──────────────┐  cached WB RAM
   │  FRAMEBUFFER │  ◄── reads! ──┐       │ BACK BUFFER  │  reads ~1 ns
   │  (WC, bus)   │  ─── writes ──┘       └──────┬───────┘
   └──────────────┘                              │ fb_flush(): writes ONLY
                                                 ▼
                                          ┌──────────────┐
                                          │  FRAMEBUFFER │  one linear sweep,
                                          │  (WC, bus)   │  perfect for WC
                                          └──────────────┘
```

The flush is the ideal write-combining workload: strictly increasing addresses, no reads,
no gaps. Every WC buffer fills to 64 bytes and leaves as one burst. Copying the whole
3.91 MiB screen costs a couple of milliseconds, against the tenth of a second the old
scroll spent on reads alone.

The flicker goes for a related reason. With direct drawing the framebuffer is *incoherent*
for the entire duration of a redraw — a tenth of a second, six whole refresh cycles — and
during that time the screen genuinely shows a half-scrolled image with a blank strip. That
is not an artefact; it is the actual content of memory, faithfully displayed. With a back
buffer all the partial states happen in RAM where nothing is watching, and the framebuffer
only ever receives complete frames.

**Be precise about what this does not give you.** The blit is still not synchronised with
scan-out, so a refresh landing mid-flush can show the top of the new frame above the bottom
of the old one — classic tearing. The difference is that the window is 2 ms instead of
100 ms, and both halves are *valid* frames rather than one being visibly broken.
Eliminating it entirely needs vertical-blank synchronisation or a page flip, which needs a
real display driver — [[Phase 11 - Overview|Phase 11]], not this stage.

---

## 3. Design decisions and tradeoffs

### Decision: back buffer in RAM, or keep drawing straight to the framebuffer?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — back buffer in RAM, blit on flush** | All drawing hits cached WB RAM; a flush copies to the device | One screen of RAM (3.91 MiB at 1280x800) plus a copy per flush | ✅ |
| B — draw direct, keep the framebuffer `memmove` | What stages 1.1–1.3 do | ~0.1–0.5 s per scrolled line; visible flicker | ❌ |
| C — draw direct, scroll by re-rasterising the character grid | Shift the grid, redraw every glyph | No framebuffer reads, but a full-screen glyph raster per scroll | ⚠️ |

**Why A.** It removes reads from the framebuffer entirely — the actual problem — and does
so for *every* future renderer rather than only for scrolling. Once a back buffer exists,
"read the pixel under the cursor", "save this region and restore it" and "draw a box around
that" become free instead of catastrophic.

**Be honest about the memory.** This is not a rounding error at this point in the project.

| Mode | Bytes | MiB |
|---|---|---|
| 1024x768x32 | 3,145,728 | 3.00 |
| **1280x800x32** | **4,096,000** | **3.91** |
| 1280x1024x32 | 5,242,880 | 5.00 |
| 1920x1080x32 | 8,294,400 | 7.91 |
| 3840x2160x32 | 33,177,600 | 31.64 |

Nearly 4 MiB, permanently resident, on a kernel whose entire image is under 1 MiB and which
has no allocator. On a 128 MiB QEMU machine that is 3% of RAM spent on a console. It is
worth it — but it is a real cost, and the next decision is where it bites.

**Why not B.** §2 has the arithmetic. Half a second per scrolled line makes the console
unusable as a debugging tool, which is the whole justification for
[[Phase 1 - Overview|Phase 1]].

**Why not C.** C is genuinely reasonable — hence ⚠️ rather than ❌ — and it is the fallback
in the next decision. It never reads the framebuffer, so it fixes the pathological part,
and it costs no memory beyond the character grid you already keep. What it does not fix: a
full re-raster is 4,000 glyphs at 128 pixel-writes each, every write going to the device in
a scattered pattern that half-fills WC buffers. Perhaps five to ten times better than B,
perhaps five times worse than A, does not generalise beyond text, and still shows partial
frames.

**When B would be right.** When the framebuffer is *not* a device aperture. Some ARM SoCs
and some virtual machines back it with plain cacheable system RAM, where the read penalty
does not exist. **This includes QEMU** — see §6, because it means your measurement will
understate the win.

---

### Decision: where does 4 MiB come from when there is no heap?

The central constraint of this stage. `kmalloc` does not exist until
[[Stage 4.4 - The Kernel Heap|Stage 4.4]]; the frame allocator does not exist until
[[Stage 4.2 - The Physical Frame Allocator|Stage 4.2]]. There is nothing to allocate from.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — static array sized for a maximum mode, with a fallback** | `alignas(64) uint32_t g_back[MAX_W * MAX_H];` in `.bss`; if the real mode is bigger, run unbuffered | 3.91 MiB of `.bss` always, even at 640x480; a hard cap on resolution | ✅ |
| B — defer to Phase 4 | Ship option C above now; add the pixel back buffer once `kmalloc` works | No memory cost now; three phases of a slow console and a second implementation to write and then delete | ❌ |
| C — restrict the resolution so the buffer is small | Pin `limine.conf` to 800x600 (1.83 MiB) or 640x480 (1.17 MiB) | Half as many characters on screen, for the whole project | ❌ |

**Why A.** Three properties make it work, and they are the general technique for pre-heap
kernel memory.

*It is free in the image.* A zero-initialised static array goes in `.bss`, a `NOBITS`
section: the ELF records its size and address and stores **no bytes**. `kernel.elf` does
not grow. Limine allocates and zero-fills it at load time, exactly as
[[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]] relies on for `BootInfo`. Get this
wrong and the image grows by 3.91 MiB — trap 6 in §7.

*The cap is enforceable.* `fb_init` compares `width x height` against the array's capacity.
If the mode is larger it sets the back-buffer pointer to null and every drawing primitive
falls through to writing the framebuffer directly. The console still works — slower, and it
says so over serial. **A kernel that refuses to boot because it dislikes the display mode
is not a kernel**, the same argument as the serial self-test in
[[Stage 0.6 - Serial Output]] and `fb_present` in Stage 0.3.

*The exit is obvious.* [[Stage 4.4 - The Kernel Heap|Stage 4.4]] revisits this: allocate
`height * pitch` for the exact mode, copy the static buffer's contents across, repoint
`g_backbuf`, delete the array. Twenty lines, because everything already goes through one
pointer.

**Choosing the maximum.** Pin it to the mode you request in `boot/limine.conf`. 1280x800 is
a good default — 160x50 characters with an 8x16 font, enough to read a page-table dump
without scrolling. Do not size for 1920x1080 "just in case"; that is 7.91 MiB of `.bss` you
will never use, and the fallback exists precisely so the unusual machine degrades instead
of failing.

**Why not B.** The reasoning sounds disciplined — do not reserve statically when an
allocator is three phases away — and it is wrong for one specific reason: **you debug
Phases 2, 3 and 4 with this console.** Those are the hardest phases, they are where you
print most, and they are all *before* the heap exists. Deferring means the console is slow
for exactly the stretch where you need it most, and it means writing the character-grid
redraw, living with it, and then throwing it away. Two implementations for one feature.

**Why not C.** It trades a permanent, visible product limitation for a temporary internal
one: half the characters on screen for the life of the project, to avoid 2 MiB of `.bss` on
a machine with 128 MiB, in a kernel that will happily reserve more than that for page
tables in Phase 4.

**When B would be right.** On a memory-constrained target where 4 MiB is a real fraction of
RAM — an embedded board with 16 MiB. The answer there is not "defer" but "make it dynamic
earlier": move the frame allocator ahead of the console in the boot order, which is viable
in a kernel that does not need the console to debug the frame allocator. You are not in
that position.

**When C would be right.** When the display is genuinely small — a 320x240 embedded panel,
where the whole buffer is 300 KiB and the decision evaporates.

---

### Decision: flush the whole screen, or track dirty regions?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — dirty *line* range, one `[y0, y1)` pair** | Every draw widens a half-open pixel-row range; the flush copies only those rows | Two `uint32_t`s and two compares per draw | ✅ |
| B — full-screen flush always | Copy every row every time | 3.91 MiB per flush regardless of what changed | ⚠️ |
| C — dirty rectangles (x and y) | Track a bounding box, or a list of boxes | Partial-row copies, harder bookkeeping, more ways to be wrong | ❌ |

**Why A.** A console changes by **lines**. Printing one character dirties one 16-pixel band;
printing a line dirties the same band; a newline at the bottom of a full screen dirties
everything. That maps onto a single row range with no cleverness, and the win is large: at
1280x800 with an 8x16 font, one text line is 16 rows out of 800 — a **50x** reduction in
bytes flushed for the common case.

It is also the *safe* form of dirty tracking. Because the range is rows only, every flush
copies whole scanlines, keeping the linear write pattern WC wants. A rectangle narrower
than the screen turns the flush into many short runs with gaps, and a run under 64 bytes
cannot fill a WC buffer.

**Why not B.** B is not wrong, and you should build A on top of a working B — get
`flush_rows(0, height)` correct first, then add the range. Ship B and every keystroke echo
copies 3.91 MiB.

**Why not C.** The extra dimension buys little and costs a whole bug class. Bold the
symptom now so you recognise it: **stale text in a region that should have changed.** The
tracking said a region was clean when it was not, so the back buffer is right, the screen
is wrong, and nothing you print makes it update. It is invisible in review, reproduces only
for particular draw sequences, and will make you distrust the font renderer. Rows-only
tracking has exactly one rule — *every* function writing the back buffer calls
`fb_mark_dirty` — and that rule is auditable by grep.

**The honest limitation.** Dirty tracking wins nothing on scroll. When the screen scrolls,
every row shows different content, so the whole screen is legitimately dirty and the flush
is full-size. Avoiding that needs **hardware panning** — telling the display controller to
start scanning at a different offset, so a scroll costs one register write and no copying —
which requires mode-setting, which requires a real GPU driver
([[Phase 11 - Overview|Phase 11]]). Until then a scroll costs a full flush, and a full flush
is ~2 ms, and 2 ms is fine.

---

### Decision: when does the flush happen?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — once per public console call** | `console_putc` / `console_write` / `console_puts` mark dirty as they go and flush once before returning | One flush per `kprintf`, not per character | ✅ |
| B — per character | `fb_flush()` inside the character loop | A 60-character line becomes 60 flushes, ~50 wasted screen copies | ❌ |
| C — explicit only | The caller must call `console_flush()` | Correct and fastest — until someone forgets, and output silently never appears | ❌ |

**Why A.** It is the coarsest granularity that is still *unconditionally correct*: when any
public console function returns, what it printed is on screen. No caller can forget, no
output is stranded, and the natural unit of kernel output — one formatted line from
[[Stage 1.6 - kprintf|kprintf]] — coalesces into one flush. Export `console_flush()`
anyway, because the panic path and future batching callers need it.

**Why not B.** B is what you write first, because it obviously works. It is also 50x more
copying than necessary, and it will make you conclude the back buffer did not help. If your
console is still slow after this stage, check this before anything else — trap 4.

**Why not C.** Some path will forget: an error return, an early exit, a helper added later.
The failure mode is the worst in this stage — **output correctly generated and never
displayed** — and it looks identical to the code not having run.

**The panic interaction, which is where this actually bites.**
[[Stage 0.7 - Panic and KASSERT]] specifies the panic sequence: step 7 writes the captured
report to the console sink if one is registered, and step 8 is `cli; hlt` forever. With a
back buffer, the sink writing characters puts pixels **in RAM**. Then panic halts.

```
  panic()  ─► serial ─► registers ─► backtrace ─► console sink ─► cli; hlt
                                                        │              │
                                                writes the back        └─ nothing
                                                buffer ...                runs again,
                                                                          EVER
```

If the sink does not flush, the message you built the entire panic handler to deliver never
reaches the display. Serial still has it — which is exactly why this bug survives: you look
at your terminal, see a perfect panic report, and never notice the screen is showing the
last thing that happened before the fault. Then one day you are on real hardware with no
serial cable, and the screen is blank.

**The panic sink must end with `fb_flush_all()`, not `fb_flush()`.** A panic can land
anywhere, including halfway through a drawing routine or between a draw and its
`fb_mark_dirty`, so the dirty range may not describe what the sink just wrote. Panic is the
one place where "copy everything, unconditionally" is obviously right: it costs 2 ms and
the machine is about to stop forever.

**When C would be right.** Once [[Stage 3.1 - The Programmable Interval Timer|the timer]]
exists, the correct policy is a coalescing one: mark dirty on every write and flush at most
every 16 ms from a deferred context, so a burst of a thousand lines produces sixty flushes
instead of a thousand. That is the standard console design and the natural Phase 3
follow-up. It cannot be built now — there is no timer and no deferred context to run it in.

---

### Decision: is the back buffer tightly packed, or does it match the framebuffer's pitch?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — tightly packed, `width` pixels per row** | Back-buffer stride is `width`; the flush copies row by row | The flush must advance two different strides | ✅ |
| B — match `fb_pitch` | Back-buffer rows are `pitch` bytes, like the framebuffer | The whole flush is one `memcpy` — but the size is unknown until run time | ❌ |

**Why A.** B is tempting because it makes the flush a single linear copy of
`height * pitch` bytes with no per-row loop. It is impossible here for a decisive reason:
**a static array must be sized at compile time, and `pitch` is only known at run time.** You
would have to reserve `MAX_H * MAX_PITCH` for some invented maximum pitch. Tight packing
needs only `MAX_W * MAX_H`, a number you can justify. It also makes back-buffer addressing
trivial — `g_back[y * width + x]`, no byte arithmetic, no `reinterpret_cast`, no
strict-aliasing question — and keeps the hardware's padding a fact only one function knows.

**Why not B.** Beyond the sizing problem, it spreads `pitch` through the code. Every drawing
primitive would need it, and `pitch` is a property of the *display*, not of your renderer.

**The consequence, which §5 spends real time on.** The flush copies between two layouts with
different strides: `src` advances by `width` pixels, `dst` by `pitch` bytes. Writing
`dst += width * 4` compiles, runs, and is correct on every machine where
`pitch == width * 4` — most of them, including your QEMU setup — and shears the image
diagonally on the machines where it is not. Trap 3.

---

## 4. Specification

### Memory types (Intel SDM Vol. 3A, memory-cache-control chapter)

| Type | Cached? | Writes | Reads | Speculative reads |
|---|---|---|---|---|
| **WB** write-back | yes | into cache; written back on eviction | from cache | yes |
| **WC** write-combining | no | accumulate in 64-byte WC buffers, burst out | **uncached — a bus round trip each** | yes |
| **UC** uncacheable | no | one bus transaction each, strictly ordered | one bus transaction each | no |

Limine maps the framebuffer for you; check its `PROTOCOL.md` for the exact wording in
`v8.6.0`. Assume write-combining. If it turns out to be plain UC on your setup, every
argument here gets **stronger**, because UC loses the write batching as well.

### What forces a write-combining buffer out

The precise list is implementation-specific — the SDM is the authority. The ones that
matter:

| Trigger | Consequence |
|---|---|
| The buffer fills (64 bytes) | The good case: one full burst |
| A write to a different line needing the buffer | Partial flush; smaller transaction |
| **A read from WC memory** | Partial flush **plus** a full device round trip |
| `SFENCE`/`MFENCE`, a `LOCK`ed or serialising instruction | Partial flush |
| An access to UC memory | Partial flush |

The third row is this stage in one line.

### Cost of one text-line scroll at 1280x800x32, 8x16 font

| Operation | Bytes moved | Where | Rough cost |
|---|---|---|---|
| Stage 1.3 `memmove` on the framebuffer | 3.83 MiB read **+** 3.83 MiB written | device | **0.1–0.5 s** |
| Back-buffer scroll (this stage) | 3.83 MiB read + written | cached RAM | ~0.4 ms |
| Flush after a scroll | 3.91 MiB written | device, linear | ~2 ms |
| Flush after one line, no scroll | 16 rows = 80 KiB | device, linear | ~40 µs |

Device figures assume a real graphics card. Read §6 before believing QEMU numbers.

### Back-buffer geometry

| Quantity | Value | Unit |
|---|---|---|
| `BACK_MAX_WIDTH` | 1280 | pixels |
| `BACK_MAX_HEIGHT` | 800 | pixels |
| `BACK_MAX_PIXELS` | 1,024,000 | pixels |
| `sizeof(g_back)` | 4,096,000 | bytes (3.91 MiB) |
| `g_back_stride` | `g_width` | **pixels** per back-buffer row |
| `g_pitch` | `BootInfo::fb_pitch` | **bytes** per framebuffer scanline |

The unit mismatch on the last two rows is deliberate and commented in the code. Conflating
them is the shear bug.

```
   BACK BUFFER (tightly packed)            FRAMEBUFFER (pitch >= width*4)

   ┌───────────────────────┐               ┌───────────────────────┬─────┐
   │ row 0                 │               │ row 0                 │ pad │
   ├───────────────────────┤               ├───────────────────────┼─────┤
   │ row 1                 │               │ row 1                 │ pad │
   ├───────────────────────┤               ├───────────────────────┼─────┤
   │ row 2                 │               │ row 2                 │ pad │
   └───────────────────────┘               └───────────────────────┴─────┘
    ◄──── width pixels ────►                ◄──── width pixels ────►
                                            ◄─────── pitch bytes ────────►

    src += g_back_stride  (pixels)          dst += g_pitch  (BYTES)
```

### Dirty range

| Field | Meaning |
|---|---|
| `g_dirty_y0` | first dirty pixel row |
| `g_dirty_y1` | one past the last dirty pixel row (half-open) |
| empty | `g_dirty_y0 >= g_dirty_y1`; represented as `UINT32_MAX` / `0` |

`fb_mark_dirty(y, h)` widens the range to include `[y, y + h)`. `fb_flush()` copies the
range and resets it. `fb_flush_all()` copies every row and resets it.

### Section placement of a static array

| Declaration | Section | In the ELF file? |
|---|---|---|
| `uint32_t g_back[N];` | `.bss` (`NOBITS`) | **no — 0 bytes** |
| `uint32_t g_back[N] = {};` | `.bss` | no |
| `uint32_t g_back[N] = {1};` | `.data` (`PROGBITS`) | **yes — all 4 MiB** |
| `const uint32_t g_back[N] = {};` | `.rodata` (`PROGBITS`) | **yes — all 4 MiB** |

---

## 5. Writing the code

Nothing here adds a subsystem: `fbcon.cpp` grows a back buffer and a flush, `console.cpp`
learns when to call it.

> **Names.** `fb_putpixel`, `fb_fill_rect`, `fb_draw_glyph`, `g_fb`, `g_pitch` are the names
> *you* chose in stages 1.1–1.3. Open your files and use what is actually there.

### `kernel/include/kernel/fbcon.hpp`

```cpp
#pragma once

#include <stddef.h>
#include <stdint.h>

struct BootInfo;

// ---- from Stage 1.1 / 1.2 -------------------------------------------------
void     fb_init(const BootInfo* info);
bool     fb_present();
uint32_t fb_width();
uint32_t fb_height();
uint32_t fb_pack(uint8_t r, uint8_t g, uint8_t b);
void     fb_putpixel(uint32_t x, uint32_t y, uint32_t colour);
void     fb_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t colour);
void     fb_draw_glyph(char c, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg);

// ---- new in Stage 1.4 -----------------------------------------------------

// True when drawing goes to the RAM back buffer. False means the mode did not
// fit the static buffer and every draw writes straight to the framebuffer:
// correct, but slow. Logged at boot.
[[nodiscard]] bool fb_buffered();

// Record that back-buffer pixel rows [y, y + h) no longer match the screen.
// EVERY function that writes to the back buffer must call this.
void fb_mark_dirty(uint32_t y, uint32_t h);

// Copy the dirty rows to the framebuffer and mark everything clean.
void fb_flush();

// Copy every row, ignoring the dirty range. For the panic path, where the
// dirty range may describe an operation that never finished.
void fb_flush_all();

// Move the screen up by `rows` pixels inside the back buffer and fill the
// exposed band with `colour`. Does NOT flush; the caller decides when.
void fb_scroll_up(uint32_t rows, uint32_t colour);
```

#### Line by line

**`fb_buffered()` is `[[nodiscard]]`, the rest are not.** Discarding the answer to "is this
console fast?" is always a bug — the only reason to ask is to branch on it. `fb_flush()`
returns nothing to discard. [[13 - Coding Standards]] rule 6.

**`fb_mark_dirty` takes a height, not a second row.** `(y, h)` matches every drawing
primitive's own parameters — a glyph is at `(x, y)` and is `GLYPH_H` tall — so call sites
never do arithmetic. The half-open `[y0, y1)` form appears only inside the driver, where it
makes the "empty" test a single comparison.

**`fb_scroll_up` does not flush.** Scrolling and displaying are separate concerns:
`console.cpp` may scroll several times while processing one string and should pay for one
flush, not several. The function that knows when a frame is complete owns the write loop.

**Why a scroll primitive lives in `fbcon.cpp` at all.** It is the only file that knows
whether a back buffer exists and how rows are laid out. If `console.cpp` scrolled, it would
need `g_back`, `g_back_stride`, `g_pitch` and the buffered/unbuffered branch — the whole
abstraction, leaked. `console.cpp` deals in characters; `fbcon.cpp` deals in pixels and
memory ([[07 - Repository Layout]]).

---

### `kernel/drivers/char/fbcon.cpp`

Everything below is new or modified; the pixel packing and font lookup from stages 1.1–1.2
are unchanged and omitted.

```cpp
#include "kernel/fbcon.hpp"

#include "kernel/assert.hpp"
#include "kernel/boot_info.hpp"
#include "kernel/serial.hpp"

#include <stddef.h>
#include <stdint.h>

namespace {

// The largest mode the static back buffer can hold. Raising these raises the
// kernel's .bss by MAX_W * MAX_H * 4 bytes and changes nothing else.
constexpr uint32_t BACK_MAX_WIDTH  = 1280;
constexpr uint32_t BACK_MAX_HEIGHT = 800;
constexpr size_t   BACK_MAX_PIXELS =
    static_cast<size_t>(BACK_MAX_WIDTH) * BACK_MAX_HEIGHT;   // 1,024,000 px

// NO INITIALISER. That is what keeps this in .bss (NOBITS): 4,096,000 bytes of
// RAM at run time, ZERO bytes in kernel.elf. Any non-zero initialiser moves it
// to .data and the image grows by 3.91 MiB. See section 7, trap 6.
//
// Limine zero-fills it, because the ELF spec requires a loader to zero the part
// of a PT_LOAD segment beyond its file size (Stage 0.3), so the screen starts
// black with no code run.
//
// alignas(64) matches the CPU's write-combining buffer size, so the flush
// starts each burst on a buffer boundary instead of straddling two.
alignas(64) uint32_t g_back[BACK_MAX_PIXELS];

// Set by fb_init() from BootInfo. Mostly from Stage 1.1.
volatile uint8_t* g_fb     = nullptr;   // MMIO. Byte pointer: pitch is in bytes.
uint32_t          g_width  = 0;         // pixels
uint32_t          g_height = 0;         // pixels
uint32_t          g_pitch  = 0;         // BYTES per framebuffer scanline

// Null when the mode did not fit g_back. Every draw checks this one pointer.
uint32_t* g_backbuf     = nullptr;
uint32_t  g_back_stride = 0;            // PIXELS per back-buffer row == g_width

// Dirty pixel rows, half-open [y0, y1). Empty when y0 >= y1.
uint32_t g_dirty_y0 = UINT32_MAX;
uint32_t g_dirty_y1 = 0;

// Copy back-buffer rows [y0, y1) to the framebuffer.
//
// THE ONLY FUNCTION IN THE KERNEL THAT TOUCHES THE FRAMEBUFFER IN BULK.
// It contains no loads from g_fb, and it must never grow one.
void flush_rows(uint32_t y0, uint32_t y1) {
    if (g_backbuf == nullptr || g_fb == nullptr)
        return;
    if (y1 > g_height)
        y1 = g_height;
    if (y0 >= y1)
        return;                         // nothing dirty; also the empty range

    const uint32_t*   src = g_backbuf + static_cast<size_t>(y0) * g_back_stride;
    volatile uint8_t* dst = g_fb      + static_cast<size_t>(y0) * g_pitch;

    for (uint32_t y = y0; y < y1; ++y) {
        volatile uint32_t* d = reinterpret_cast<volatile uint32_t*>(dst);

        // Strictly increasing addresses, stores only, no gaps: exactly the
        // access pattern write-combining is built for.
        for (uint32_t x = 0; x < g_width; ++x)
            d[x] = src[x];              // d is WRITTEN. d is never read.

        src += g_back_stride;           // pixels
        dst += g_pitch;                 // BYTES, and not width * 4
    }
}

}  // namespace

// ---------------------------------------------------------------- init -----

void fb_init(const BootInfo* info) {
    if (!info->fb_present)
        return;

    // A pitch above 4 GiB is not a thing; assert rather than silently truncate.
    KASSERT(info->fb_pitch <= UINT32_MAX);
    KASSERT(info->fb_width <= UINT32_MAX && info->fb_height <= UINT32_MAX);

    g_fb     = reinterpret_cast<volatile uint8_t*>(info->fb_addr);
    g_width  = static_cast<uint32_t>(info->fb_width);
    g_height = static_cast<uint32_t>(info->fb_height);
    g_pitch  = static_cast<uint32_t>(info->fb_pitch);

    // ... Stage 1.1's colour-mask setup, unchanged ...

    // Does this mode fit the static back buffer?
    const size_t pixels = static_cast<size_t>(g_width) * g_height;
    if (info->fb_bpp == 32 && pixels <= BACK_MAX_PIXELS) {
        g_backbuf     = g_back;
        g_back_stride = g_width;
        serial_puts("fbcon: buffered\n");
    } else {
        g_backbuf     = nullptr;        // correct, just slow
        g_back_stride = 0;
        serial_puts("fbcon: UNBUFFERED - mode too large or not 32bpp; "
                    "raise BACK_MAX_* or expect a slow console\n");
    }

    // The zeroed back buffer and whatever the firmware left on screen disagree.
    fb_mark_dirty(0, g_height);
}

bool fb_buffered() { return g_backbuf != nullptr; }

// ---------------------------------------------------------------- draw -----

void fb_putpixel(uint32_t x, uint32_t y, uint32_t colour) {
    if (x >= g_width || y >= g_height)
        return;

    if (g_backbuf != nullptr) {
        g_backbuf[static_cast<size_t>(y) * g_back_stride + x] = colour;
        fb_mark_dirty(y, 1);
        return;
    }

    *reinterpret_cast<volatile uint32_t*>(
        g_fb + static_cast<size_t>(y) * g_pitch + static_cast<size_t>(x) * 4) = colour;
}

void fb_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t colour) {
    if (x >= g_width || y >= g_height)
        return;
    if (w > g_width - x)                // written this way: x + w can overflow
        w = g_width - x;
    if (h > g_height - y)
        h = g_height - y;

    if (g_backbuf != nullptr) {
        for (uint32_t row = 0; row < h; ++row) {
            uint32_t* p =
                g_backbuf + static_cast<size_t>(y + row) * g_back_stride + x;
            for (uint32_t col = 0; col < w; ++col)
                p[col] = colour;
        }
        fb_mark_dirty(y, h);
        return;
    }

    for (uint32_t row = 0; row < h; ++row) {
        volatile uint32_t* p = reinterpret_cast<volatile uint32_t*>(
            g_fb + static_cast<size_t>(y + row) * g_pitch) + x;
        for (uint32_t col = 0; col < w; ++col)
            p[col] = colour;
    }
}

// fb_draw_glyph is unchanged EXCEPT that it must end with
//     fb_mark_dirty(y, GLYPH_HEIGHT);
// It draws through fb_putpixel, which already marks each row, so this is
// belt-and-braces -- but write it explicitly, because the day someone optimises
// the glyph loop to write the back buffer directly is the day the per-pixel
// marking disappears.

// -------------------------------------------------------------- scroll -----

void fb_scroll_up(uint32_t rows, uint32_t colour) {
    if (rows == 0 || g_height == 0)
        return;
    if (rows >= g_height) {
        fb_fill_rect(0, 0, g_width, g_height, colour);
        return;
    }

    if (g_backbuf != nullptr) {
        // Ordinary cached RAM. NOT volatile: the compiler is welcome to turn
        // this into rep movsb or a memcpy call, and it should.
        const size_t words = static_cast<size_t>(g_height - rows) * g_back_stride;
        uint32_t*       d  = g_backbuf;
        const uint32_t* s  = g_backbuf + static_cast<size_t>(rows) * g_back_stride;

        for (size_t i = 0; i < words; ++i)   // forward: d < s, so no overlap bug
            d[i] = s[i];

        fb_fill_rect(0, g_height - rows, g_width, rows, colour);
        fb_mark_dirty(0, g_height);          // every row now shows new content
        return;
    }

    // Unbuffered fallback. This is the pathological path from section 2 -- it
    // READS the framebuffer -- and exists only so a machine with an oversized
    // mode still scrolls. Nothing else in this file reads g_fb.
    for (uint32_t y = 0; y + rows < g_height; ++y) {
        volatile uint32_t* d = reinterpret_cast<volatile uint32_t*>(
            g_fb + static_cast<size_t>(y) * g_pitch);
        const volatile uint32_t* s = reinterpret_cast<const volatile uint32_t*>(
            g_fb + static_cast<size_t>(y + rows) * g_pitch);
        for (uint32_t x = 0; x < g_width; ++x)
            d[x] = s[x];
    }
    fb_fill_rect(0, g_height - rows, g_width, rows, colour);
}

// --------------------------------------------------------------- flush -----

void fb_mark_dirty(uint32_t y, uint32_t h) {
    if (g_backbuf == nullptr || h == 0 || y >= g_height)
        return;
    if (h > g_height - y)
        h = g_height - y;

    if (y < g_dirty_y0)
        g_dirty_y0 = y;
    if (y + h > g_dirty_y1)
        g_dirty_y1 = y + h;
}

void fb_flush() {
    flush_rows(g_dirty_y0, g_dirty_y1);
    g_dirty_y0 = UINT32_MAX;
    g_dirty_y1 = 0;
}

void fb_flush_all() {
    flush_rows(0, g_height);
    g_dirty_y0 = UINT32_MAX;
    g_dirty_y1 = 0;
}
```

#### Line by line

**The maximum-mode constants.** These are §3's second decision expressed as two numbers.
`static_cast<size_t>` on the first operand is not decoration: promote once at the top and
every later expression is 64-bit, so nobody overflows when they try 3840x2160. Keep the
*pixel* count as the constant, not the byte count — it is what the bounds check compares
against, and it removes a `* 4` from every call site.

**The array, and the missing initialiser**
```cpp
alignas(64) uint32_t g_back[BACK_MAX_PIXELS];
```
Three things are load-bearing here, one of them by absence.

*No initialiser.* The most consequential character in the file is the one that is not there.
A static array with no initialiser (or an all-zero one) is zero-initialised by the language,
and GCC places it in `.bss`, a `NOBITS` section occupying **no bytes in the ELF**. Write
`= {1}` and it becomes `.data`, `PROGBITS`, and `kernel.elf` gains 3.91 MiB of mostly-zeros
that must be read from disk on every boot. §4 has the table; §7 has the symptom.

*`uint32_t`, not `uint8_t`.* The back buffer is an array of pixels, so make it an array of
the pixel type. Declaring it `uint8_t[]` and reading it through a `uint32_t*` is a strict
aliasing violation GCC is entitled to miscompile, and there is no `-fno-strict-aliasing` in
this project's flags ([[08 - Build System]]). Typing it correctly makes the question
disappear rather than answering it.

*`alignas(64)`.* WC buffers are 64 bytes. Starting on a 64-byte boundary means row 0 of the
flush begins at the start of a buffer rather than partway into one; without it the first
burst of every flush is a partial one. One line, free.

**`g_back` and `g_backbuf` are two different things.** `g_back` is the storage; `g_backbuf`
is the *decision*, and null means unbuffered. Every drawing function branches on this one
pointer, so §3's fallback is a single null check rather than a `bool` threaded through the
file, and Stage 4.4 switching to `kmalloc` is one assignment.

`g_back_stride` is in **pixels**; `g_pitch` is in **bytes**. Deliberately different names,
deliberately different units, because the failure mode of treating them as interchangeable
is the shear bug. Comment the units at the declaration and at every use.

**The dirty range's empty representation**
```cpp
uint32_t g_dirty_y0 = UINT32_MAX;
uint32_t g_dirty_y1 = 0;
```
The empty range is the *inverted* one. That makes `fb_mark_dirty` two unconditional
compare-and-assign pairs with no "is it empty yet?" special case, and makes "is it empty?"
the single test `y0 >= y1` — which `flush_rows` already performs as its own bounds check,
so emptiness costs nothing extra. Initialising both to `0` would look tidier and would mean
`fb_flush()` before any drawing flushes row 0.

**`flush_rows` — the guards, and their order**
```cpp
    if (g_backbuf == nullptr || g_fb == nullptr) return;
    if (y1 > g_height) y1 = g_height;
    if (y0 >= y1)      return;
```
Unbuffered means there is nothing to flush — drawing already went to the screen — so this
must be a no-op rather than an error, or every call site needs a guard. The `g_fb` check
covers a machine with no framebuffer at all, where `fb_init` returned early.

Clamping `y1` **before** testing `y0 >= y1` is what makes `fb_flush()` on an empty range
work: `y0` is `UINT32_MAX`, `y1` is `0`, and after the clamp `y1` is still `0`, so the
second test returns. Clamp *after* using `y1` and you write past the end of the
framebuffer. There is no clamp on `y0` because `y0 >= y1` after clamping already excludes
anything out of range.

**`flush_rows` — the two cursors**
```cpp
    const uint32_t*   src = g_backbuf + static_cast<size_t>(y0) * g_back_stride;
    volatile uint8_t* dst = g_fb      + static_cast<size_t>(y0) * g_pitch;
```
Both advance to the first dirty row before the loop, each in its own units. `src` is a
`uint32_t*` and moves in pixels; `dst` is a `uint8_t*` and moves in bytes, because that is
the unit `pitch` is expressed in and byte-pointer arithmetic is the only way to add a byte
count without a cast on every line. `static_cast<size_t>(y0)` goes *before* the multiply:
`y0 * g_pitch` in `uint32_t` overflows at a 4 GiB offset. It cannot happen at any real
resolution and it costs nothing to make impossible.

**`flush_rows` — the inner loop, and why it is written by hand**
```cpp
        volatile uint32_t* d = reinterpret_cast<volatile uint32_t*>(dst);
        for (uint32_t x = 0; x < g_width; ++x)
            d[x] = src[x];
```
Read this as a specification of machine behaviour, not as a copy.

*Ascending `x`, one row at a time.* Addresses increase monotonically across the whole flush,
so each 64-byte WC buffer receives sixteen consecutive 4-byte stores and leaves as one
burst. Iterate downwards or column-major and you get the same pixels at a fraction of the
throughput.

*`d[x] = src[x]` and never the reverse.* No expression in this loop loads from `d`. That is
the invariant of the entire stage, and it is worth a source comment precisely because
nothing in the language enforces it.

*`volatile` on `d` does two jobs.* It is the MMIO annotation [[13 - Coding Standards]]
rule 3 exists for — these stores have effects the compiler cannot see, so it may not elide
them, sink them, or merge two writes to the same pixel. And, the part people miss, **it
prevents GCC recognising this loop as `memcpy` and replacing it with a library call.**
GCC's loop-idiom recognition does exactly that to a plain copy loop; `memcpy` would
probably be fine here, but "probably fine" is not how you want the one hot loop in your
display path chosen. Volatile accesses must be performed exactly as written.

*`src` is not volatile.* It is cached RAM — let the compiler unroll and keep values in
registers. Making both sides volatile is a common and costly reflex.

*The stores are 4 bytes each.* With `-mno-sse` there are no vector stores. You could halve
the instruction count with `volatile uint64_t*` when `g_width` is even and both pointers
are 8-byte aligned, and it is a legitimate refinement — but WC buffers fill at 64-byte
granularity regardless of store width, so the win is in instruction count, not bus traffic.
Measure before adding the special case.

**`flush_rows` — the two strides**
```cpp
        src += g_back_stride;           // pixels
        dst += g_pitch;                 // BYTES, and not width * 4
```
The entire pitch lesson in two lines. `src` is a `uint32_t*`, so `+= g_back_stride` advances
`g_back_stride * 4` bytes — one packed row. `dst` is a `uint8_t*`, so `+= g_pitch` advances
exactly the hardware's scanline stride, padding included. Write `dst += g_width * 4`
instead and everything works until you boot a mode where `pitch != width * 4`; then each
row lands a few bytes left of where the last one ended, the error accumulates, and the
image shears progressively further down the screen while the top still looks fine. §6
insists you boot at least once at a resolution that exposes it.

**`fb_init` — the asserts.** `BootInfo` stores geometry as `uint64_t`; the driver keeps
`uint32_t` because pixel coordinates are 32-bit throughout. That narrowing is safe for every
mode that will ever exist, which is the definition of an invariant, which is what `KASSERT`
is for ([[Stage 0.7 - Panic and KASSERT]]). Nothing outside this kernel can make it false —
the value came from Limine via your own `BootInfo` copy — so it is an assert, not an error
return.

**`fb_init` — the fit test**
```cpp
    if (info->fb_bpp == 32 && pixels <= BACK_MAX_PIXELS) {
```
Both conditions are necessary. The size test is obvious. The `bpp == 32` test is there
because the back buffer stores pixels **already packed in the framebuffer's own format**,
so the flush can be a pure byte copy. On a 24bpp or 16bpp display a copy would not be a
copy — it would need per-pixel conversion, at which point the flush is no longer a linear
sweep and most of the benefit evaporates. Refusing to buffer is the honest response.
Storing pre-packed pixels rather than canonical RGB888 is itself the decision that makes
this possible: `fb_pack()` runs once at draw time, not once per pixel per flush.

**`fb_init` — logging which path was taken.** This line will save you an hour. "The console
is still slow" has two causes — flushing too often, or not buffered at all — and they look
identical from outside. One serial line at boot distinguishes them permanently, and it is
the first thing §7 tells you to check.

**`fb_init` — the final `fb_mark_dirty(0, g_height)`.** The back buffer is all zeros; the
screen holds whatever the firmware and Limine left. Marking everything dirty means the
first `fb_flush()` brings them into agreement. Skip it and Limine's boot output stays behind
your text in every region you have not drawn over.

**`fb_putpixel` — the branch, and the volatile asymmetry.** The back-buffer store is **not**
volatile and the framebuffer store **is**, in the same function, deliberately. The back
buffer is RAM: let the compiler keep it in registers, merge repeated writes, unroll the
glyph loop. The framebuffer is a device and may do none of those. Making the back buffer
volatile "for consistency" pessimises every drawing primitive in the kernel for no benefit.
The bounds check returns silently, because a clipped pixel is a normal event (a glyph at
the screen edge), not an error — the condition-versus-invariant distinction in
[[13 - Coding Standards]] rule 7.

**`fb_fill_rect` — the clip written to avoid overflow**
```cpp
    if (w > g_width - x)
        w = g_width - x;
```
The natural form, `if (x + w > g_width) w = g_width - x;`, has a bug: `x` and `w` are
`uint32_t`, so a large `w` wraps the sum to a small number, the test passes, and the loop
writes past the end of the row — or of the buffer. Subtracting is safe because `x < g_width`
is already established. Same shape as the clamp in `fb_mark_dirty`. Note also that the whole
rectangle gets **one** `fb_mark_dirty`, not one per row: the range widens to the same thing
and the call site reads as what it is.

**`fb_scroll_up` — the RAM copy, and the absent `volatile`**
```cpp
        for (size_t i = 0; i < words; ++i)
            d[i] = s[i];
```
The line the whole stage was written for: the scroll that used to be 3.83 MiB of device
reads is now 3.83 MiB of cached RAM reads — roughly 0.4 ms instead of 0.1–0.5 s.

Note the deliberate contrast with `flush_rows`. There, `volatile` stops GCC turning the loop
into `memcpy`. Here there is no `volatile`, and GCC turning this into `rep movsb` or a
`memcpy` call is exactly what you want. **The caveat that catches people:** GCC in
freestanding mode still assumes `memcpy`, `memset`, `memmove` and `memcmp` exist and will
emit calls to them. If `kernel/lib/string.cpp` does not define them, this loop can produce
`undefined reference to 'memcpy'` at link time — a link error in a file that does not
mention `memcpy`. That is the freestanding contract
([[ADR-0007 - Freestanding C++20 as the Kernel Language]]), not a bug in your loop.

`d < s` strictly and the loop runs forward, so the overlap is harmless: every word is read
before the iteration that overwrites it. That is why this can be a `memcpy` and does not
need `memmove`. Scroll *downwards* one day and you will need the reverse loop.

**`fb_scroll_up` — `fb_mark_dirty(0, g_height)`.** The honest line. A scroll changes what
every row displays, so the whole screen is dirty and the next flush is full-size; §3
explains why there is no way around this without hardware panning. Do not mark only the
newly exposed band — the back buffer would be right and the screen would keep the old
unscrolled image with one changing line at the bottom.

**`fb_scroll_up` — the unbuffered fallback.** The only place in the file that reads `g_fb`,
present so an oversized mode still scrolls rather than smearing. It is slow, it is labelled
slow, and `fb_init` has already warned over serial. Keep the comment: it is what stops
someone "tidying up" by routing the buffered path through it.

**`fb_mark_dirty` — clamping before widening.** `flush_rows` clamps again, so why clamp
here? Because a range claiming `y1 = 10000` on an 800-row screen is *wrong data*, and
carrying wrong data forward on the assumption that someone downstream will fix it is how
the dirty-tracking bug class starts. Clamp at the boundary; keep the invariant true
everywhere inside.

**`fb_flush` — resetting the range.** Not optional and not an optimisation. Forget it and
every flush copies from row 0 to the high-water mark forever — *correct*, but it restores
the full-screen cost you added the tracking to avoid, and hides the mistake because the
screen looks right. Trap 5 is the opposite error: resetting without flushing.
`fb_flush_all` resets too, because after copying everything nothing is dirty.

---

### `kernel/drivers/char/console.cpp`

Only the flush policy and the scroll change; the cursor, colours and tab handling from
[[Stage 1.3 - A Console - Cursor, Colour, Scrolling|Stage 1.3]] are unchanged.

```cpp
#include "kernel/console.hpp"

#include "kernel/fbcon.hpp"
#include "kernel/panic.hpp"

#include <stddef.h>

namespace {

constexpr uint32_t GLYPH_W = 8;
constexpr uint32_t GLYPH_H = 16;

uint32_t g_cols = 0, g_rows = 0;        // in characters
uint32_t g_col  = 0, g_row  = 0;        // cursor, in characters
uint32_t g_fg = 0, g_bg = 0;

// Scroll by one text line. Back buffer only -- no flush, no framebuffer.
void scroll_one_line() {
    fb_scroll_up(GLYPH_H, g_bg);
    g_row = g_rows - 1;
}

// Everything console_putc used to do, MINUS the flush. The only function that
// writes glyphs, and deliberately not exported: the flush policy belongs to
// the public entry points.
void putc_noflush(char c) {
    switch (c) {
    case '\n':
        g_col = 0;
        if (++g_row >= g_rows)
            scroll_one_line();
        return;
    case '\r':
        g_col = 0;
        return;
    case '\b':
        if (g_col > 0)
            --g_col;
        return;
    default:
        break;
    }

    fb_draw_glyph(c, g_col * GLYPH_W, g_row * GLYPH_H, g_fg, g_bg);

    if (++g_col >= g_cols) {
        g_col = 0;
        if (++g_row >= g_rows)
            scroll_one_line();
    }
}

// Panic's console sink. Registered with panic_set_console_sink() so panic.cpp
// never learns a framebuffer exists (Stage 0.7).
//
// THE fb_flush_all() IS NOT OPTIONAL. panic() calls this as its last act
// before cli;hlt forever. Without it the report is in RAM and the screen still
// shows whatever was there when the kernel died.
void console_panic_sink(const char* text, size_t len) {
    for (size_t i = 0; i < len; ++i)
        putc_noflush(text[i]);
    fb_flush_all();     // ALL rows: the dirty range may describe an operation
                        // that a fault interrupted halfway through.
}

}  // namespace

void console_init() {
    if (!fb_present())
        return;

    g_cols = fb_width()  / GLYPH_W;
    g_rows = fb_height() / GLYPH_H;
    g_fg   = fb_pack(0xC0, 0xC0, 0xC0);
    g_bg   = fb_pack(0x00, 0x00, 0x00);
    g_col  = 0;
    g_row  = 0;

    fb_fill_rect(0, 0, fb_width(), fb_height(), g_bg);
    fb_flush();                              // black screen, actually on screen

    panic_set_console_sink(&console_panic_sink);
}

void console_flush() {
    fb_flush();
}

void console_putc(char c) {
    putc_noflush(c);
    fb_flush();
}

void console_write(const char* buf, size_t len) {
    for (size_t i = 0; i < len; ++i)
        putc_noflush(buf[i]);
    fb_flush();                              // ONE flush for the whole string
}

void console_puts(const char* s) {
    for (; *s != '\0'; ++s)
        putc_noflush(*s);
    fb_flush();
}
```

#### Line by line

**`scroll_one_line`.** Three lines, and the whole of Stage 1.3's scroll is gone. The console
no longer knows how scrolling is implemented; it knows a text line is `GLYPH_H` pixels tall
and that the cursor ends on the last row. `g_bg` is passed so the exposed band uses the
console's current background rather than a hardcoded black — otherwise a colour-scheme
change leaves black stripes marching up the screen. There is no flush here: printing a
200-character string that wraps four times scrolls four times and flushes once.

**`putc_noflush` — the split.** The most important structural change in the file. Stage
1.3's `console_putc` did the work *and* made it visible; those are now separate, and the
private function does the work. Everything public becomes "call the private one N times,
then flush once" — §3's option A expressed so it cannot be got wrong, because there is no
code path that writes a glyph and returns to a caller without a flush. Note the recursion
through `scroll_one_line` is bounded: a scroll never draws a glyph.

**`console_panic_sink` — the shape, and the trap.** The signature is `PanicSink` from
[[Stage 0.7 - Panic and KASSERT]]: `void (*)(const char* text, size_t len)`. Panic hands it
the whole captured report at step 7 and then, at step 8, halts forever. **There is no
later.** Every other console function can rely on someone eventually calling `fb_flush()`;
this one cannot, because nothing ever runs again.

This is a genuinely easy bug to ship. Serial still prints the panic — step 2, long before
this — so your terminal shows a perfect report, the machine halts, and the screen shows a
stale console. You will not notice until you debug on real hardware with no serial cable,
which is the exact situation where you needed it.

`fb_flush_all()` rather than `fb_flush()` for a second reason beyond §3's: a panic can fire
from inside `fb_fill_rect`, halfway through a glyph, or between a draw and its
`fb_mark_dirty`. In any of those the dirty range is an unreliable description of what
changed. Copying every row is 2 ms and has no failure mode. The sink takes no locks and
allocates nothing, satisfying the rules in the header of `panic.cpp`; when
[[Phase 12 - Overview|Phase 12]] adds a console lock, this function must be the exception
that skips it, because a panic may already hold it.

**`console_init` — the first flush, and registration order.** The fill writes black into the
back buffer; without the flush the screen keeps Limine's boot output underneath everything
you print afterwards. This is the first place the mark-dirty/flush pair is exercised, so if
the screen does not go black at boot, stop here — nothing later will work. Registration is
last, so a fault during console setup does not invoke a half-initialised sink.

**`console_flush` — why it is exported.** `console_write` already flushes, so nothing needs
this today. It exists for the §6 benchmark, for the 16 ms coalescing policy that arrives
with [[Stage 3.1 - The Programmable Interval Timer|the timer]], and to keep `fbcon.hpp` out
of the includes of anything that only wants to print.

**`console_write` — the one line that is the whole optimisation.** The `fb_flush()` is
outside the loop. Move it inside and the code still works, still looks reasonable in review,
and is roughly fifty times slower for a full line of text. That is trap 4, and the most
common reason people conclude double buffering "did not help".

---

### A measurement helper: `kernel/arch/x86_64/cpu/tsc.hpp`

You cannot claim a speedup you have not measured. There is no timer until
[[Phase 3 - Overview|Phase 3]], but the time-stamp counter needs no setup at all.

```cpp
#pragma once

#include <stdint.h>

// Read the time-stamp counter: a free-running per-core cycle counter.
//
// These are TICKS, not seconds. Converting needs a calibration source, which
// is the PIT in Phase 3. Ratios between two measurements on the same machine
// are valid, and a ratio is all this stage needs.
static inline uint64_t rdtsc() {
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return (static_cast<uint64_t>(hi) << 32) | lo;
}
```

`rdtsc` returns its 64-bit result split across `edx:eax`, hence two 32-bit outputs and a
shift rather than one `"=r"(uint64_t)`. `volatile` is essential for the same reason as in
`io.hpp` ([[Stage 0.6 - Serial Output]]): without it GCC treats the asm as a pure function
of its inputs — it has none — and may hoist it out of a loop or fold two calls into one,
making both timestamps identical. No `"memory"` clobber, because it touches no memory.
`rdtsc` is not serialising, so out-of-order execution can move a few instructions across it;
that matters when timing a dozen cycles and is noise when timing milliseconds. This file
goes under `kernel/arch/` because it contains inline assembly
([[07 - Repository Layout]] rule 1).

---

## 6. How to verify

### Now, without booting: the buffer is in `.bss`

```sh
make
x86_64-elf-size -A build/kernel.elf | grep -E '\.(text|data|bss)'
```
```
.text        24576   ...
.data          512   ...
.bss       4102144   ...
```

```sh
x86_64-elf-readelf -S build/kernel.elf | grep -A1 '\.bss'
```

The `Type` column must read `NOBITS`. `PROGBITS` means the buffer is file-backed and your
image just grew by 3.91 MiB — trap 6.

```sh
ls -l build/kernel.elf build/os.iso
x86_64-elf-nm -S --size-sort build/kernel.elf | tail -3
```
```
ffffffff80104000 00000000003e8000 b _ZN12_GLOBAL__N_16g_backE
```

Both file sizes must be essentially unchanged from before this stage — a few hundred bytes
for the new code. Lowercase `b` is a local symbol in `.bss`; `0x3e8000` is 4,096,000, the
size you asked for. Uppercase `D` or `d` means `.data`.

### Prove the flush loop has no loads from the framebuffer

```sh
x86_64-elf-objdump -d build/kernel.elf | grep -A25 'flush_rows'
```

The innermost loop should be one load from the back buffer and one store to the framebuffer
per pixel:

```
  mov    (%rsi,%rax,4),%ecx      ; load from src (RAM)
  mov    %ecx,(%rdi,%rax,4)      ; store to dst (framebuffer)
  add    $0x1,%rax
```

A second load using the *destination* register means something reads the framebuffer. A
`call memcpy` in place of the loop body means the `volatile` on `d` was dropped.

### Booting: measure it

Add this to `kernel_init` temporarily, after `console_init()`:

```cpp
#include "arch/x86_64/cpu/tsc.hpp"

const uint64_t t0 = rdtsc();
for (int i = 0; i < 1000; ++i)
    console_puts("scroll benchmark 0123456789 abcdefghijklmnopqrstuvwxyz\n");
const uint64_t t1 = rdtsc();

serial_puts("1000 lines: ");
serial_write_dec(t1 - t0);
serial_puts(" TSC ticks, buffered=");
serial_puts(fb_buffered() ? "yes\n" : "no\n");
```

Run it **before** the change (stash your work, or force `g_backbuf = nullptr` in `fb_init`
for one run) and after.

```sh
make run-serial
```
```
1000 lines: 41302847511 TSC ticks, buffered=no
1000 lines:   903118240 TSC ticks, buffered=yes
```

The exact figures depend on your host; the **ratio** is the result, and it should be tens at
minimum.

**Read this before you trust the number.** Under QEMU the framebuffer is not a device
aperture — it is ordinary host RAM presented to the guest — so guest reads of it are cheap.
**The emulator systematically understates the win**, and on a machine with a real graphics
card the gap is much larger. You will still see a clear improvement, because QEMU's
dirty-page tracking makes framebuffer writes cost more than plain RAM writes and you removed
half the traffic; but if you measure only 3x, that is the emulator, not your code. The
physics in §2 is the reason to believe the change. The measurement is a sanity check that
you did not make it slower.

For a rough wall-clock figure without the PIT, `time` the whole QEMU run with the loop count
raised to 10,000 and diff the two runs.

### Booting: no flicker, and the panic still reaches the screen

Print continuously with a crude delay (`for (volatile int d = 0; d < 2000000; ++d) {}`) and
watch the screen, not the log. Before: the screen visibly redraws in bands with a blank
strip at the bottom during each scroll. After: text moves up cleanly. An occasional faint
horizontal seam is the tearing §2 says remains, and is expected.

Then `panic("double buffering test");`. The banner and message must appear **on the screen**,
not only in `serial.log`. Delete the `fb_flush_all()` from `console_panic_sink`, rebuild,
and run again: serial still shows the full report, the screen shows the console as it was
before the panic. That is the bug, deliberately reproduced once so you recognise it. Put the
flush back.

### Booting: a mode where `pitch != width * 4`

The most valuable check here, because your default mode almost certainly has
`pitch == width * 4` and hides the bug. First print both at boot:

```cpp
serial_puts("fb: width*4=");  serial_write_dec(info->fb_width * 4);
serial_puts(" pitch=");       serial_write_dec(info->fb_pitch);
serial_putc('\n');
```

Then request an awkward mode in `boot/limine.conf` — 1366x768 is the classic one, because
`1366 * 4 = 5464` is not a multiple of most hardware stride alignments so the driver rounds
up. Check Limine's `CONFIG.md` for the exact spelling of the resolution key in `v8.6.0`; it
is a per-boot-entry setting.

```
fb: width*4=5464 pitch=5504
```

If the two numbers differ and the screen is not sheared, `flush_rows` is right. If Limine
will not give you a padded mode, test it on the host instead — this is the Tier-2 case
[[Phase 1 - Overview|the phase overview]] names. Compile `flush_rows` against a fake
framebuffer with `pitch = width * 4 + 64`, flush a known pattern, and assert that row *n*
begins at byte `n * pitch`.

### Only checkable later

- **`kmalloc`-backed sizing** — [[Stage 4.4 - The Kernel Heap|Stage 4.4]].
- **The framebuffer still write-combining under your own page tables** —
  [[Stage 4.3 - Enabling Paging|Stage 4.3]]. See §8.
- **Timer-coalesced flushing at ~60 Hz** — [[Phase 3 - Overview|Phase 3]].
- **Correct behaviour with two cores printing** — [[Phase 12 - Overview|Phase 12]].

- [ ] `.bss` grew by ~4,096,000 bytes; `.data` did not
- [ ] `readelf` shows `.bss` as `NOBITS`
- [ ] `kernel.elf` and `os.iso` file sizes essentially unchanged
- [ ] `fbcon: buffered` appears on serial
- [ ] The disassembled flush loop has one load and one store per pixel, no `call`
- [ ] The 1000-line benchmark is at least ten times faster than before
- [ ] Scrolling shows no blank band and no partial redraw
- [ ] A test panic appears on the screen
- [ ] Removing the panic flush reproduces the blank-screen bug (then put it back)
- [ ] Boots correctly at a resolution where `pitch != width * 4`
- [ ] Benchmark code removed; the machinery stays

---

## 7. Common traps

**"The screen is blank after switching to a back buffer — but serial output is fine."**
Nothing ever flushed. Every drawing call now writes RAM, so the code is doing exactly what
you asked and the display has no idea. The tell is that serial is perfect: this is not a
crash, the kernel is running normally. Check three places in order. Does `console_write`
call `fb_flush()` at the end? Does `console_init` flush after clearing the screen? Is
`fb_flush()` actually reaching `flush_rows` — put a `serial_putc('F')` inside it for one
run. A near-miss variant: you flush, but `fb_mark_dirty` is never called from your drawing
primitives, so the range is always empty and `flush_rows` returns immediately.

**"The panic message never appears on the screen, but it is in `serial.log`."** The panic
path has no flush. [[Stage 0.7 - Panic and KASSERT]] step 7 hands your sink the report and
step 8 halts the core forever; if the sink only writes the back buffer, the report is in RAM
when the machine stops. `console_panic_sink` must end with `fb_flush_all()` — not
`fb_flush()`, because a fault can land between a draw and its `fb_mark_dirty`, leaving the
dirty range untrustworthy at exactly the moment you need it most. This bug hides behind
serial for months and surfaces the first time you debug on hardware with no serial port.

**"The image is sheared diagonally, and only since this change."** The copy assumed
`pitch == width * 4`. In `flush_rows` the destination must advance `g_pitch` **bytes** per
row while the source advances `g_back_stride` **pixels** — different numbers, different
units. Each row lands a few bytes left of where the last one ended, the error accumulates,
and the picture slants further the further down you look. It is invisible on any mode where
the two happen to be equal, which is most of them, which is why §6 makes you boot an awkward
resolution. The same bug in the opposite direction — using `pitch` on the back buffer —
reads past the end of `g_back`.

**"It is still slow."** Two causes, and one serial line separates them. If boot printed
`fbcon: UNBUFFERED`, the mode did not fit `BACK_MAX_PIXELS` (or is not 32bpp) and every draw
goes straight to the device; raise the constants or pin a smaller mode. If it printed
`fbcon: buffered`, you are flushing too often — almost always `fb_flush()` inside the
character loop of `console_write` instead of after it, which turns a 60-character line into
60 full-screen copies. Third and rarer: something still reads the framebuffer. Grep every
use of `g_fb` and confirm `flush_rows` is the only bulk consumer and that `g_fb` never
appears on the right-hand side of an assignment.

**"Stale text in a region that should have changed."** The dirty tracking is wrong. Some
function writes the back buffer without calling `fb_mark_dirty`, so `flush_rows` skips rows
that genuinely changed and the screen keeps old pixels in a band that never updates. The
diagnostic is decisive: replace `fb_flush()` with `fb_flush_all()` for one run. If the
problem disappears it is the tracking, not the drawing. Then audit — every write to
`g_backbuf` must be followed by a mark, and the usual culprit is an optimised glyph or
rectangle routine that bypasses `fb_putpixel`. The mirror-image bug is forgetting to
**reset** the range in `fb_flush`, which is invisible on screen and silently restores the
full-screen cost.

**"The kernel image grew by 4 MiB and the build got slow."** The back buffer is in `.data`
instead of `.bss`. A static array with no initialiser — or an all-zero one — is
zero-initialised, and GCC puts it in `.bss`, a `NOBITS` section recording only an address
and a size: **no bytes in the file**. Limine allocates and zero-fills it at load time, as
the ELF specification requires. Give it any non-zero initialiser and it becomes `.data`,
`PROGBITS`, and all 4,096,000 bytes are stored in `kernel.elf`, copied into `os.iso`, and
read off the disk on every boot. Marking it `const` is the same mistake with a different
section name — `.rodata` is also file-backed. Check with `readelf -S` and look for `NOBITS`,
not by reading the source.

**"The link fails with `undefined reference to memcpy`."** The RAM copy in `fb_scroll_up`
was recognised by GCC as a `memcpy` idiom and turned into a call. That is legal and
desirable in freestanding C++ — the compiler assumes `memcpy`, `memset`, `memmove` and
`memcmp` exist regardless of `-ffreestanding` — so the fix is to provide them in
`kernel/lib/string.cpp`, not to fight the optimiser. Note the contrast with `flush_rows`,
where the `volatile` destination prevents the same transformation on purpose.

**"Boots fine in QEMU, black screen on hardware."** Usually the real panel's mode is bigger
than `BACK_MAX_PIXELS` — 1920x1080 against a 1280x800 buffer — and the unbuffered fallback
is running. That should still draw, so if the screen is black, check that the fallback paths
in `fb_putpixel`, `fb_fill_rect` and `fb_scroll_up` all exist and that none of them was left
calling `fb_flush()` (which does nothing when `g_backbuf` is null). The serial line from
`fb_init` tells you which path you are on before you guess.

---

## 8. What this unlocks

Every later use of the console. [[Stage 1.5 - The Log Ring Buffer and Levels|Stage 1.5]]
replays buffered history to the screen — hundreds of lines at once, exactly the burst
pattern that is unusable without this stage — and
[[Stage 1.7 - Symbolised Backtraces|Stage 1.7]] prints multi-line panic reports through the
sink you just made flush. From [[Phase 2 - Overview|Phase 2]] onward, printing from an
interrupt handler stops being something you avoid because it is slow.

Done wrong, the failures are quiet in a specific way. A missing flush in the panic path
costs nothing until the day you have no serial cable. Wrong dirty tracking produces stale
regions you will blame on the font renderer. A back buffer in `.data` inflates every image
you build from here to Phase 15 with no visible symptom at all.

One forward hazard worth writing down now. In
[[Stage 4.3 - Enabling Paging|Stage 4.3]] you replace Limine's page tables with your own,
and the framebuffer mapping's **memory type comes with it**. Map that range write-back and
the flush becomes very fast and mostly invisible: stores land in cache and reach the device
only when a line is evicted, so the screen updates partially, late, and in an order that
looks like memory corruption. The framebuffer mapping needs its PAT/PCD/PWT bits set for
write-combining (or uncacheable). This is the note to come back to when the screen starts
behaving strangely three phases from now.

---

## 9. Reading

- OSDev — *Drawing In a Linear Framebuffer*:
  <https://wiki.osdev.org/Drawing_In_a_Linear_Framebuffer>
  The pitch-versus-width arithmetic §5 depends on, with the same warning.
- OSDev — *Double Buffering*: <https://wiki.osdev.org/Double_Buffering>
  Short. Read it for the framing; the memory-constraint discussion here is the part it does
  not cover.
- Intel SDM Vol. 3A, *Memory Cache Control*:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
  The authority on WB/WC/UC and on what forces a write-combining buffer out. Its memory-type
  table is the one §4 summarises.
- Intel — *Write Combining Memory Implementation Guidelines*:
  <https://www.intel.com/content/dam/support/us/en/documents/processors/pentiumii/sb/24442201.pdf>
  Old, and still the clearest explanation of why partially-filled WC buffers are slow.
- Limine — `PROTOCOL.md`:
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
  The framebuffer response fields, and what Limine guarantees about the mapping.
- ELF specification, section headers and `SHT_NOBITS`:
  <https://refspecs.linuxfoundation.org/elf/elf.pdf>
  Why `.bss` costs nothing in the file and why the loader must zero it.
- [[Stage 0.7 - Panic and KASSERT]] — the sink contract, the eight-step panic sequence, and
  why step 7 is last. The flush in `console_panic_sink` only makes sense against that
  ordering.
- [[Stage 0.3 - Freestanding C++ and kmain]] — the same `.bss`-before-a-heap argument applied
  to `BootInfo`, including why a static aggregate needs nothing to run.
- [[13 - Coding Standards]] — rule 3 for when `volatile` is the right tool, rule 7 for the
  clip-versus-assert distinction in `fb_putpixel`.
- [[Phase 4 - Overview]] — what changes once a real allocator exists, and which stage
  revisits the static buffer.

Next: **[[Stage 1.5 - The Log Ring Buffer and Levels]]**

# Stage 1.1 — The Linear Framebuffer

**Difficulty:** Easy · ~45 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `kernel/include/kernel/framebuffer.hpp`, `kernel/drivers/char/fbcon.cpp`
**Deliverable:** **your first pixel** — a coloured rectangle, a frame and three colour bars on the screen, drawn by code you wrote, at whatever resolution the firmware happened to give you.

---

> This is the milestone stage of Phase 1. Everything in Phase 0 came out of a serial
> port — a channel that exists because a chip from 1987 is still emulated on every
> machine. This stage puts something on the **glass**. From here on the kernel has a
> display, and every later stage in this phase is built on the three functions you
> write today.

---

## Progress

- [ ] Read the framebuffer block of `kernel/include/kernel/boot_info.hpp` and confirm the field names you chose in [[Stage 0.3 - Freestanding C++ and kmain]]
- [ ] Boot once and write down the `pitch` and `width` your machine actually reports — before writing any drawing code
- [ ] Create `kernel/include/kernel/framebuffer.hpp` with `Colour`, `FramebufferInfo` and the six functions
- [ ] Create `kernel/drivers/char/fbcon.cpp` with the `FbState` aggregate in an anonymous namespace
- [ ] Implement `pixel_address()` — `y * pitch + x * bytes_per_pixel`, with 64-bit arithmetic
- [ ] Implement `place_channel()` and `fb_pack_colour()` from the reported mask sizes and shifts
- [ ] Implement `fb_init()`, null-checking `info`, `fb_present` and `fb_addr`, and validating the geometry before storing it
- [ ] Implement `fb_put_pixel()` with a bounds check, and `fb_fill_rect()` that clips once instead of per pixel
- [ ] Implement `fb_test_pattern()`
- [ ] Add `drivers/char/fbcon.cpp` to `kernel/CMakeLists.txt` — the source list is explicit, not globbed
- [ ] Call `fb_init(info)` then `fb_test_pattern()` from `kernel_init`, **after** `serial_init()`
- [ ] `make run` — a coloured rectangle
- [ ] Change `resolution:` in `boot/limine.conf`, boot again, confirm the picture is still square and still centred
- [ ] Break it on purpose once (`g_fb.pitch -= 16;`) and look at what a pitch bug looks like
- [ ] Committed with a message like `feat(fb): linear framebuffer, pixels and rectangles`

---

## 1. Why this stage exists

At the end of Phase 0 the kernel can talk, but only down a wire. `serial_puts` is
enough to prove the machine booted and to print a number, and it will stay the primary
debug channel for the entire project — but it is not a console. It has no position, no
colour, no history you can scroll, and on a real laptop with no serial header it does
not exist at all. Every piece of feedback you get from now until Phase 2 has to come
from somewhere, and on a machine you can actually hold, the only somewhere is the
screen.

The reason this is a *stage* and not a footnote is that "the screen" is not a device
you can ask for. There is no `print` in firmware you can call once the bootloader has
handed over — [[ADR-0004 - Framebuffer Console Not VGA Text]] covers why the UEFI
Graphics Output Protocol is unreachable after boot services are exited, and why the
classic `0xB8000` text buffer is not there either. What you get instead is a
**rectangle of memory** and a promise: whatever bytes are in it, the display
controller will put on the panel, sixty times a second, forever, with no further
involvement from you. Everything the kernel will ever draw — glyphs, a cursor, a
panic screen in Phase 2, a scrolled console in Stage 1.3 — is a program that writes
bytes into that rectangle.

Skip this stage and there is nothing to skip *to*. Stage 1.2 rasterises a font by
calling `fb_put_pixel` eight times per glyph row; Stage 1.3's console is a cursor
plus `fb_fill_rect`; Stage 1.4's double buffering is a back buffer that gets flushed
into the same address this stage computes. All three are one function deep on top of
what you write in the next forty-five minutes.

And there is one specific thing here that costs people an evening, which is why the
stage is longer than the sixty lines of code deserve. The mapping from a pixel
coordinate to a byte address contains a number — `pitch` — that is usually, but not
always, equal to the number you would guess. Guess it, and everything works on your
development machine and produces a diagonally smeared mess on the first real computer
you try. §2 explains what pitch is, §7 shows you what the failure looks like, and §6
has you cause it deliberately so that you recognise it in five seconds instead of
five hours.

---

## 2. The concept

### 2.1 What a framebuffer is

A **linear framebuffer** is a contiguous region of memory that a display controller
reads continuously and converts into a signal for the panel. That is the entire
mechanism. There is no command queue, no draw call, no acknowledgement. The controller
is a machine that walks the region from start to end, emitting a pixel every few
nanoseconds, and starts again from the beginning when it reaches the end — roughly
sixty times a second.

```
                                        ┌──────────────────────────────┐
   memory                                │        the panel             │
   ┌──────────────────────────────┐      │                              │
   │ row 0  ██████████████████░░░ │──┐   │  ████████████████████████    │
   │ row 1  ██████████████████░░░ │  │   │  ████████████████████████    │
   │ row 2  ██████████████████░░░ │  ├──►│  ████████████████████████    │
   │ ...                          │  │   │  ████████████████████████    │
   │ row 799██████████████████░░░ │──┘   │                              │
   └──────────────────────────────┘      └──────────────────────────────┘
        the display controller scans this out at ~60 Hz, unprompted
```

The consequence is the thing to internalise: **writing to that memory is the only
step.** You do not tell anyone. There is no flush, no present, no swap. The instant
your store retires, the next scan-out picks it up. That is why the deliverable of this
stage is achievable in sixty lines, and it is also why every bug in this stage is
silent — nothing validates what you wrote, so a wrong address just draws in the wrong
place.

Limine put the adapter into a graphics mode before it jumped to `kmain`, asked the
firmware where the buffer lives, and reported the answer through the framebuffer
request. [[Stage 0.3 - Freestanding C++ and kmain]] copied that answer into `BootInfo`.
The address it gives you is a **virtual** address inside the higher-half direct map
that Limine set up, already mapped, already writable. You do not map anything in this
stage, and you do **not** add `hhdm_offset` to it — that is a real bug people hit, and
it is in §7.

### 2.2 What one pixel is

A pixel is a small fixed number of bytes. How many is `bpp / 8`, where `bpp` — bits
per pixel — is reported by the bootloader alongside the geometry. The three modes you
will meet:

| bpp | bytes per pixel | Typical layout | Where you see it |
|---|---|---|---|
| 32 | 4 | 8 bits each of R, G, B, plus one unused byte | everything modern, and QEMU |
| 24 | 3 | 8 bits each of R, G, B, no padding | some VESA modes, older adapters |
| 16 | 2 | 5 red, 6 green, 5 blue | old hardware, some embedded panels |

Within those bytes, the channels are not at fixed positions. The adapter tells you
where they are with three pairs of numbers: a **mask size** (how many bits this
channel gets) and a **mask shift** (how far left the field sits inside the pixel
value). A 32-bit pixel with red at size 8 shift 16, green at size 8 shift 8 and blue
at size 8 shift 0 is the familiar `0x00RRGGBB` arrangement:

```
   bit 31                                                          bit 0
   ┌────────────┬────────────┬────────────┬────────────┐
   │  unused    │    red     │   green    │    blue    │
   │  31..24    │   23..16   │   15..8    │    7..0    │
   └────────────┴────────────┴────────────┴────────────┘
        shift 16 for red ────────┘   shift 8 ──┘  shift 0 ──┘
```

But that is a *value*, and memory stores bytes. x86 is little-endian, so storing the
32-bit value `0x00FF0000` writes the bytes `00 00 FF 00` in ascending address order —
the **blue** byte first. This is the single most common source of "my red is coming
out blue": people reason about bytes in memory as if they were written left to right,
and they are not. Build the value with shifts, store the value; never lay out bytes by
hand.

### 2.3 Pitch, and why it is not width

Now the important part.

The framebuffer is a rectangle of memory, and the rows are laid out one after another.
The obvious address for pixel `(x, y)` would be

```
   offset = (y * width + x) * bytes_per_pixel        // WRONG
```

and it is wrong, because **rows are not necessarily packed.** The display controller
does not step from one scanline to the next by adding `width * bytes_per_pixel`; it
adds a separate, independently reported number called the **pitch** (also called
stride or scanline length), measured in **bytes**, and the pitch is frequently larger
than the row of pixels it contains.

```
      x = 0                                    x = width-1
        │                                            │  padding, not displayed
        ▼                                            ▼  ┌─────────┐
      ┌──────────────────────────────────────────────┬─────────┐
 y=0  │ pixel pixel pixel ...................  pixel │░░░░░░░░░│
      ├──────────────────────────────────────────────┼─────────┤
 y=1  │ pixel pixel pixel ...................  pixel │░░░░░░░░░│
      ├──────────────────────────────────────────────┼─────────┤
 y=2  │ pixel pixel pixel ...................  pixel │░░░░░░░░░│
      └──────────────────────────────────────────────┴─────────┘
        │◄──────── width × bytes_per_pixel ─────────►│
        │◄─────────────────── pitch (bytes) ───────────────────►│
```

Why the padding exists: display hardware fetches memory in bursts, and a scanline that
starts on a 64-byte or 128-byte boundary is fetched more efficiently than one that
starts halfway through a burst. So the adapter rounds each scanline up. The classic
example is 1366×768, a resolution that exists on an enormous number of laptop panels:
`1366 × 4 = 5464` bytes, which is not a multiple of 64. Round up and you get a pitch
of `5504`, forty bytes — ten pixels — of invisible padding on every single row.

So the formula, and it is the formula of this entire stage:

```
   offset = y * pitch + x * (bpp / 8)
```

Get it wrong in the obvious way — use `width * bytes_per_pixel` as the row step — and
each row you draw lands a little earlier than the display expects. The drift per row
is `(pitch − width × bytes_per_pixel) / bytes_per_pixel` pixels to the left, and it
accumulates:

```
   intended                          what appears with a short row step
   ┌────────────────┐                ┌────────────────┐
   │ ██████████████ │                │ ██████████████ │
   │ ██████████████ │                │██████████████  │
   │ ██████████████ │                │█████████████   │
   │ ██████████████ │                │████████████    │
   └────────────────┘                └───────────────┘
                                       every row slides left by a
                                       constant, so the image shears
```

Ten pixels of drift per row means that after eighty rows the picture has walked 800
pixels sideways, wrapped around the screen edge, and turned into a field of diagonal
stripes. It is the most recognisable bug in graphics programming once you have seen it
once, which is why §6 has you cause it on purpose.

There is a nasty wrinkle: **QEMU's emulated adapters almost always report a pitch
exactly equal to `width × bytes_per_pixel`.** Your development machine cannot tell you
that you got this wrong. The bug is dormant until the first time you boot on real
hardware, in [[Phase 15 - Overview|Phase 15]], months from now, with a hundred other
suspects. That asymmetry — free to get right today, expensive to find later — is why a
forty-five minute stage spends this much text on one multiplication.

### 2.4 What this memory is, physically

The framebuffer usually is not RAM. It is a region of a PCI device's address space — a
BAR — mapped into your virtual address space by the firmware and by Limine. Two
properties follow, and both matter later in this phase.

**It is uncached.** More precisely it is normally mapped write-combining: writes are
gathered in a small buffer inside the CPU and flushed to the device in bursts, which
makes sequential writing fast. **Reads bypass the cache entirely** and go all the way
out to the device across the bus, which makes reading catastrophically slow —
hundreds of nanoseconds against roughly one for an L1 hit. A hot loop that reads a
pixel back is not a little slow, it is two to three orders of magnitude slow. This is
the reason [[ADR-0004 - Framebuffer Console Not VGA Text]] specifies a back buffer for
scrolling and why [[Stage 1.4 - Double Buffering]] exists. In this stage, obey one
rule and you cannot get it wrong: **never read from `g_fb.base`.**

**It is not ordinary memory to the compiler either.** Nothing in the C++ abstract
machine observes those writes — no other function reads the bytes back, so an
optimiser is within its rights to decide the stores are dead and delete them. That is
what `volatile` is for, and §3 covers exactly what it does and does not buy you.

---

## 3. Design decisions and tradeoffs

### Decision: framebuffer, or the VGA text buffer at `0xB8000`?

This is the defining decision of the whole phase, already recorded as
[[ADR-0004 - Framebuffer Console Not VGA Text]]. It is repeated here because it is the
one you would otherwise get wrong by following almost every tutorial written before
about 2015.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Linear framebuffer (chosen)** | The bootloader sets a graphics mode and reports base address, geometry, pitch and channel masks. You write pixels | You must rasterise your own font ([[Stage 1.2 - Rasterising a Bitmap Font]]); scrolling is a bulk copy rather than a two-byte-per-cell shuffle | ✅ |
| VGA text mode at `0xB8000` | Write 80×25 pairs of (character, attribute) bytes into a fixed physical address the adapter scans out as text | **Does not exist** on a UEFI-booted modern machine. No error, no output, black screen | ❌ |
| Both, choosing at runtime | Detect a text-capable adapter, fall back to the framebuffer | Two console implementations, one of which cannot be tested on the target hardware at all | ❌ |
| Limine's terminal service | Call a `write()` the bootloader provides | Deprecated — the vendored `limine.h` marks `limine_terminal` `LIMINE_DEPRECATED` — and it means running bootloader code against bootloader-owned data after handoff, which is precisely what Stage 0.3 spent an afternoon escaping | ❌ |

**Why the framebuffer.** It is the only option that exists on the machine this OS is
meant to run on. UEFI firmware makes no guarantee that the display adapter is left in
a VGA-compatible mode, and on a modern laptop it is not — the adapter is in a native
graphics mode and there is no text buffer anywhere in the address space.

**Why not `0xB8000` — the exact shape of the failure.** This is worth stating
concretely because the failure mode is unusually cruel. `0xB8000` is a valid address
in the sense that a write to it does not fault: under Limine's direct map the page is
present and writable. So the code runs. No exception, no diagnostic, no hint. The
bytes land somewhere that nothing reads, and the screen stays black. You will then
debug the *code*, which is correct, on a *platform* that does not implement the thing
the code assumes — and there is no feedback loop anywhere in that situation that leads
to the answer. People lose entire weekends here, and the tutorials they are following
do not mention it because they were written for BIOS.

**When VGA text mode would be right.** A BIOS-only 32-bit hobby kernel where you want
a character on screen in ten lines of code and are never going to boot it on hardware
made after 2010. In that world it is genuinely the better first milestone: no font, no
pitch, no masks, `0xB8000[0] = 'A'; 0xB8000[1] = 0x0F;` and you are done. The moment
UEFI enters the picture the option evaporates, and it does not degrade gracefully — it
goes from perfect to invisible with nothing in between.

---

### Decision: hardcode a pixel format, or read the reported masks?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Pack from the reported masks (chosen)** | `place_channel()` truncates each 8-bit channel to `*_mask_size` bits and shifts it to `*_mask_shift` | About twelve lines of arithmetic and three extra fields carried in `FbState` | ✅ |
| Assume 32bpp `0x00RRGGBB` | `*(uint32_t*)p = (r << 16) \| (g << 8) \| b` | Correct in QEMU, wrong on any adapter that reports a different order or a non-8-bit channel. Fails as *wrong colours*, not as a crash | ❌ |
| Assume 32bpp, but *verify* the masks at init and refuse otherwise | Same fast path, plus a check | Refuses to boot with a display on a machine that would work fine with ten more lines of arithmetic | ❌ |
| Build a 256-entry lookup table per channel at init | Precompute every `place_channel` result | 3 KiB of `.bss` and an init loop to save three shifts on a path that is not yet hot | ❌ |

**Why the masks.** They cost almost nothing and they are the difference between "works
on my machine" and "works". The bootloader already did the work of asking the
firmware; the fields are sitting in `BootInfo` because Stage 0.3 copied them. Ignoring
data you already have, in favour of an assumption that is *usually* true, is the exact
habit that produces a kernel which only boots on the developer's laptop.

**Why not hardcode.** The failure is quiet and misattributed. A framebuffer reported as
BGR rather than RGB — which real adapters do report — renders your red rectangle blue.
Nothing crashes. You will conclude that your *colour constants* are wrong, swap them,
and now the code is wrong twice in a way that cancels out on one machine and is doubly
wrong on the next. The same applies to 16bpp: a 5:6:5 mode fed `0xFF` in an 8-bit
field produces saturated garbage, because the top bits of the channel land in the next
channel's field.

**Why not verify-and-refuse.** It sounds disciplined and it is actually worse for the
user: a machine with a perfectly usable 24bpp or 5:6:5 framebuffer would boot to a
black screen because you did not want to write a shift. Reserve refusal for geometry
that is genuinely impossible (§5 does exactly that for `pitch < width × bytes`).

**When hardcoding would be right.** When the mode is yours to choose and you have
verified it — an embedded target with one soldered panel, or a mode you set yourself
through a driver you also wrote. The rule is not "never assume", it is "never assume
something you have been told".

---

### Decision: write pixels straight into the framebuffer, or start with a back buffer?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Direct writes (chosen for this stage)** | `fb_put_pixel` stores into the framebuffer immediately | Every write crosses the bus; scrolling and redraws will visibly crawl and tear once there is text | ✅ for now |
| Back buffer from the start | Draw into normal RAM, `memcpy` to the framebuffer on flush | You cannot debug a back buffer before you can draw a pixel: two unverified layers, one screen, no way to tell which one is lying | ❌ now, ✅ in 1.4 |
| Write-combining plus explicit flush ordering | Direct writes, with an `sfence` at a defined flush point | Solves a problem you do not have yet — nothing here depends on write ordering | ❌ |

**Why direct, today.** Because of what a bug looks like in each design. With direct
writes, `fb_put_pixel(10, 10, red)` either puts a red pixel at (10,10) or tells you
something specific about what is wrong: nothing at all means the address is off-screen
or the buffer is elsewhere; the wrong place means the pitch arithmetic; the wrong
colour means the masks. Every failure mode maps to exactly one line of code.

Add a back buffer first and a blank screen has twice as many causes, half of which are
in a flush path whose correctness you cannot check because you have never seen a
correct pixel. **You cannot debug a back buffer before you can draw a pixel.** One
thing at a time is not a stylistic preference here; it is the only way the diagnosis
stays a one-step deduction.

**Why not direct forever.** Because of §2.4. Framebuffer memory is uncached
write-combining, so the moment there is text and the screen must scroll, the obvious
implementation — copy each row up by reading it from the framebuffer and writing it
back — performs *reads* from the device. Scrolling one line on a 1280×800 screen would
read about 4 MB across the bus and you will watch it happen.
[[Stage 1.4 - Double Buffering]] moves all drawing into normal RAM and touches the
framebuffer exactly once per flush, write-only. The functions you write today keep
their signatures; only their destination changes. That is deliberate — design them so the swap is a change to
`pixel_address()` and nothing else.

**When a back buffer belongs on day one.** If the surface were being composited from
multiple sources, or if tearing were user-visible from the very first frame. Here the
first frame is a static test pattern that nobody will see mid-draw.

---

### Decision: is the framebuffer pointer `volatile`?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **`volatile uint8_t*` (chosen)** | Every store through it is an observable side effect the compiler must emit, in program order relative to other volatile accesses | Blocks vectorisation and store merging: four one-byte stores where one 32-bit store would do | ✅ |
| Plain `uint8_t*` | Ordinary memory rules | The optimiser may legally delete stores nothing reads back, or sink them out of a loop. It usually does not today. "Usually" is not a guarantee | ❌ |
| Plain pointer plus a compiler barrier after each batch | `asm volatile("" ::: "memory")` | Same effect, more machinery, and a barrier you will forget in the one place it matters | ❌ |
| `std::atomic` | — | There is no libstdc++ in the toolchain ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]), and this is not a concurrency problem | ❌ |

**Why volatile.** [[13 - Coding Standards]] rule 3 is exact about this: *volatile is for
MMIO, never for concurrency.* A framebuffer is MMIO — a window onto a device's memory,
whose contents are consumed by hardware the compiler knows nothing about. That is
precisely the case volatile was designed for. The store to `pixel_address(x, y)` has
an effect (a pixel changes) that no amount of program analysis can discover, so you
have to tell the compiler not to reason about it.

**What volatile does not do, and this is the nuance that matters.** Volatile guarantees
that the store is *emitted*, and that volatile accesses are not reordered *with respect
to each other* by the compiler. It gives you none of the following:

- **No CPU ordering.** The processor's write-combining buffer may still merge, reorder
  and delay your stores on their way to the device. Only a fence (`sfence`) or an
  uncacheable mapping orders them. For a framebuffer this is irrelevant — the display
  does not care in which order the row was filled, only what it holds at scan-out —
  but it becomes very relevant for a device with a command ring, and assuming volatile
  gave you ordering is a bug you will otherwise write in Phase 9.
- **No flush.** Nothing forces the write-combining buffer out. It drains when it feels
  like it, which is quickly, which is why you will never notice.
- **No atomicity.** A 32-bit volatile store is atomic here because x86 makes aligned
  32-bit stores atomic, not because it is volatile.

**One concrete cost, so you recognise the error.** C++20 deprecated compound assignment
through volatile lvalues, and GCC enables `-Wvolatile` by default in C++20 mode. With
`-Werror`, a line like `p[i] |= mask;` is a **build failure**, not a warning. Read
back, modify, write is the shape you must not use on this memory anyway (§2.4), so
treat the diagnostic as the language agreeing with the hardware.

---

### Decision: what happens when a coordinate is off-screen?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Drop it silently (chosen)** | `if (x >= width \|\| y >= height) return;` | An off-by-one in a caller is invisible rather than loud | ✅ |
| `KASSERT(x < width)` | Panic on an out-of-range coordinate | Drawing the edge of a glyph that is half off-screen is a legitimate thing for Stage 1.3 to do. A panic would make partial rendering impossible | ❌ |
| No check at all | Trust the caller | A pixel at `y = height` writes past the end of the framebuffer into whatever device or memory is next. On QEMU that is usually spare VRAM — silent. On real hardware it is another device's aperture | ❌ |

**Why drop.** [[13 - Coding Standards]] rule 7 draws the line at "is this a bug by
construction, or a condition the outside world can cause?" Clipping is the second kind.
A console at the bottom of the screen, a glyph half past the right margin, a rectangle
sized from a value that came from somewhere else — all normal, all produce out-of-range
coordinates, all should draw the part that fits. That is what every drawing API does.

**Why not "no check".** Because of what is on the other side of the buffer. The mapped
region is `pitch × height` bytes. One row past the end is up to a few kilobytes beyond
it. Under QEMU the emulated adapter usually has a BAR much larger than the mode needs,
so the write lands in unused video memory and does nothing at all — the bug survives
every test you run. On a real machine that address may be another device's registers,
and a write there does whatever that device does when you poke it. There is no IDT
until [[Phase 2 - Overview|Phase 2]], so if it faults instead, the result is a triple
fault and an instant reboot with no message.

Note the small elegance in the chosen form: the parameters are **unsigned**, so a
caller that computes a negative coordinate hands you a huge positive one, and the same
`>=` comparison catches it. One test per axis covers both ends.

---

## 4. Specification

### The framebuffer fields in `BootInfo`

From `kernel/include/kernel/boot_info.hpp`, filled by `collect_boot_info()` in
[[Stage 0.3 - Freestanding C++ and kmain]]. **Use the names you actually wrote**; these
are the ones that stage specifies.

| Field | Type | Meaning |
|---|---|---|
| `fb_present` | `bool` | False on a headless machine. Check this before anything else |
| `fb_addr` | `uintptr_t` | **Virtual** address of pixel (0,0). Already mapped. Do not add `hhdm_offset` |
| `fb_width` | `uint64_t` | Visible pixels per row |
| `fb_height` | `uint64_t` | Visible rows |
| `fb_pitch` | `uint64_t` | **Bytes** per scanline. `>= fb_width * (fb_bpp/8)` |
| `fb_bpp` | `uint16_t` | Bits per pixel: 16, 24 or 32 in practice |
| `fb_red_size`, `fb_green_size`, `fb_blue_size` | `uint8_t` | Bits in each channel's field |
| `fb_red_shift`, `fb_green_shift`, `fb_blue_shift` | `uint8_t` | Position of each field's low bit within the pixel value |

### Where those came from — the real Limine struct

From the vendored `kernel/arch/x86_64/boot/limine.h`. Reproduced so you can check the
copy in `boot_info.cpp` against it; nothing outside `kernel/arch/x86_64/boot/` may
include this header.

```c
struct limine_framebuffer {
    LIMINE_PTR(void *) address;
    uint64_t width;
    uint64_t height;
    uint64_t pitch;
    uint16_t bpp;
    uint8_t memory_model;
    uint8_t red_mask_size;
    uint8_t red_mask_shift;
    uint8_t green_mask_size;
    uint8_t green_mask_shift;
    uint8_t blue_mask_size;
    uint8_t blue_mask_shift;
    uint8_t unused[7];
    uint64_t edid_size;
    LIMINE_PTR(void *) edid;
    /* Response revision 1 */
    uint64_t mode_count;
    LIMINE_PTR(struct limine_video_mode **) modes;
};
```

Three notes.

- The **field order differs from `limine_video_mode`**, which starts `pitch, width,
  height`. If you ever iterate `modes`, do not copy-paste the field order from here.
- `memory_model` is `LIMINE_FRAMEBUFFER_RGB` (`1`) for every mode you will encounter;
  it is the only model Limine defines. `BootInfo` does not carry it. If you want the
  check, add it in `boot_info.cpp` — the boundary file — not here.
- `mode_count` and `modes` are only valid at framebuffer **response** revision ≥ 1.
  Not used in this phase.

Reached through `framebuffer_request.response->framebuffers[0]` — an array of
pointers, because a machine can have several displays. We use the first and ignore the
rest; multi-head is not in the roadmap.

### The address formula

| Quantity | Expression | Units |
|---|---|---|
| bytes per pixel | `bpp / 8` | bytes |
| start of row `y` | `base + y * pitch` | bytes |
| pixel `(x, y)` | `base + y * pitch + x * (bpp / 8)` | bytes |
| size of the mapped region | `pitch * height` | bytes |
| padding per row | `pitch - width * (bpp / 8)` | bytes, ≥ 0 |

`x` is valid for `0 <= x < width`, `y` for `0 <= y < height`. The padding bytes are
inside the mapped region and writing them is harmless, but nothing displays them.

### Packing a colour

```
   pixel_value = ((r >> (8 - red_size))   << red_shift)
               | ((g >> (8 - green_size)) << green_shift)
               | ((b >> (8 - blue_size))  << blue_shift)
```

Then store the low `bpp / 8` bytes of `pixel_value` in ascending address order
(little-endian).

| Mode | red size/shift | green size/shift | blue size/shift | Pure red packs to |
|---|---|---|---|---|
| 32bpp XRGB8888 (QEMU, most UEFI) | 8 / 16 | 8 / 8 | 8 / 0 | `0x00FF0000` |
| 32bpp XBGR8888 | 8 / 0 | 8 / 8 | 8 / 16 | `0x000000FF` |
| 24bpp RGB888 | 8 / 16 | 8 / 8 | 8 / 0 | `0x00FF0000`, three bytes stored |
| 16bpp RGB565 | 5 / 11 | 6 / 5 | 5 / 0 | `0xF800` |

The `>> (8 - size)` keeps the **high** bits of the channel. Truncating `0xFF` to five
bits must give `0x1F` (still maximum brightness), not `0x07` — masking off the low
five bits of the input would darken every colour and invert the ordering of shades.

### What you will actually be handed

| | QEMU (`-vga std`, `resolution: 1280x800x32`) | A real UEFI laptop |
|---|---|---|
| `width` × `height` | exactly what `limine.conf` asked for | the panel's native mode, or the closest available |
| `bpp` | 32 | 32, occasionally 24 |
| `pitch` | `width * 4` exactly — **no padding** | often padded; 1366×768 gives 5504, not 5464 |
| masks | 8/8/8 at 16/8/0 | usually the same, sometimes BGR |

The second column is the whole reason this stage insists on reading every one of those
numbers rather than assuming any of them.

---

## 5. Writing the code

Two files. The header first, because the driver includes it.

### `kernel/include/kernel/framebuffer.hpp`

The public face of the display: geometry, a colour type, and five drawing calls. No
Limine types, no hardware constants — this header is consumed by the font rasteriser
in Stage 1.2 and the console in Stage 1.3, and neither of those may know what a
bootloader is.

```cpp
// kernel/include/kernel/framebuffer.hpp
//
// The kernel's only display surface. Limine put the adapter into a graphics
// mode and reported a linear framebuffer; Stage 0.3 copied its geometry into
// BootInfo. There is no VGA text mode anywhere in this tree — see ADR-0004.
//
// Stage 1.1: pixels and rectangles. Stage 1.2 rasterises a font on top of
// these primitives. Stage 1.4 puts a back buffer underneath them.

#pragma once

#include "kernel/boot_info.hpp"

#include <stdint.h>

// A pixel value already packed into THIS framebuffer's layout. It is not
// 0xRRGGBB and it is not portable between modes: build one with
// fb_pack_colour() and never hand a raw literal to a drawing call.
struct Colour {
    uint32_t value;
};

// Geometry, in the units drawing code actually needs.
struct FramebufferInfo {
    uint32_t width;            // pixels
    uint32_t height;           // pixels
    uint32_t pitch;            // BYTES per scanline — often != width * bpp/8
    uint32_t bytes_per_pixel;  // bpp / 8
};

// Step 6 of the initialisation order in 06 - Architecture Overview. Safe on a
// headless machine: returns false, and every drawing call below becomes a
// no-op instead of a write through a null pointer.
bool fb_init(const BootInfo* info);

// True once fb_init() has accepted a framebuffer.
[[nodiscard]] bool fb_ready();

// All-zero if !fb_ready().
[[nodiscard]] FramebufferInfo fb_info();

// Pack three 8-bit channels into the hardware's layout using the mask sizes
// and shifts the bootloader reported. Cheap, but not free: hoist it out of
// loops.
[[nodiscard]] Colour fb_pack_colour(uint8_t r, uint8_t g, uint8_t b);

// Bounds-checked. Coordinates outside the screen are dropped, not clamped.
void fb_put_pixel(uint32_t x, uint32_t y, Colour c);

// Clipped to the screen once, then drawn with no per-pixel bounds test.
void fb_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, Colour c);

// The whole screen. Equivalent to fb_fill_rect(0, 0, width, height, c).
void fb_clear(Colour c);

// Stage 1.1's deliverable: a frame, three colour bars, a diagonal and a solid
// rectangle. Proves geometry, pitch and colour packing in one glance. Delete
// it once Stage 1.3 has a real console.
void fb_test_pattern();
```

#### Line by line

**Lines 1–8 — the banner**
```cpp
// kernel/include/kernel/framebuffer.hpp
// ...
// Stage 1.1: pixels and rectangles. Stage 1.2 rasterises a font on top of
// these primitives. Stage 1.4 puts a back buffer underneath them.
```
[[13 - Coding Standards]] rule 10: comments explain why. The "why" for a header is
what the file is *for* and what is going to happen to it. The forward reference to
Stage 1.4 is the useful line — it tells the next reader that these signatures were
chosen to survive a change of destination, so nobody "simplifies" them by exposing the
raw base pointer.

**Lines 10–14 — includes**
```cpp
#pragma once

#include "kernel/boot_info.hpp"

#include <stdint.h>
```
`#pragma once`, per the coding standards; include guards are noise.

`boot_info.hpp` is included rather than forward-declared. `struct BootInfo;` would
compile — the parameter is a pointer — but a caller of `fb_init` always has a real
`BootInfo` to pass, so the include costs nothing and keeps the header self-sufficient.

`<stdint.h>`, **not** `<cstdint>`. The toolchain image does not build libstdc++, and
kernel translation units are compiled `-nostdinc++`; `#include <cstdint>` is
`fatal error: cstdint: No such file or directory`. GCC's freestanding C headers are
compiled into the compiler and always available. See
[[ADR-0007 - Freestanding C++20 as the Kernel Language]]. `<stddef.h>` is not needed
here because this header names no `size_t`; the .cpp includes it for itself rather
than relying on a transitive include.

**Lines 16–21 — `Colour`**
```cpp
struct Colour {
    uint32_t value;
};
```
A one-field wrapper that generates no code — it is passed in a register exactly as a
bare `uint32_t` would be — and buys one thing: `fb_put_pixel(10, 10, 0xFF0000)` stops
compiling. That literal is the single most common first mistake in this stage, and it
is *usually right by accident* on QEMU's 8/8/8 layout, which is what makes it
dangerous. Same reasoning as `PhysAddr`/`VirtAddr` in [[13 - Coding Standards]] rule 1:
when two things share an integer representation but must not be interchanged, make them
different types and let the compiler do the remembering.

**Lines 23–29 — `FramebufferInfo`**
```cpp
struct FramebufferInfo {
    uint32_t width;
    uint32_t height;
    uint32_t pitch;
    uint32_t bytes_per_pixel;
};
```
Narrowed to `uint32_t` from the `uint64_t` in `BootInfo`, deliberately: a framebuffer
wider than four billion pixels is not a thing, and the narrowing then happens exactly
once, inside `fb_init`, after validation. `bytes_per_pixel` is stored rather than `bpp`
because every consumer wants bytes — the division happens once at init instead of in
every inner loop, and a caller can never forget the `/ 8`.

Sixteen bytes of integer-class members, so the SysV ABI returns this in `RAX:RDX` — no
hidden `memcpy`, unlike the return-`BootInfo`-by-value case dissected in
[[Stage 0.3 - Freestanding C++ and kmain]]. Returning it by value is free.

**Lines 31–40 — init and the state queries**
```cpp
bool fb_init(const BootInfo* info);

[[nodiscard]] bool fb_ready();
[[nodiscard]] FramebufferInfo fb_info();
```
`fb_init` takes `const BootInfo*`: this driver reads the machine description and never
writes it.

It returns `bool` but is **not** `[[nodiscard]]`, which looks like a violation of rule 6
and is the same deliberate exception argued in [[Stage 0.6 - Serial Output]]. With
`-Werror`, `[[nodiscard]]` forces every caller to consume the value, and the only thing
`kernel_init` can sensibly do with it is carry on regardless — meaning an empty `if`
written purely to silence a warning. The result is available to anyone who wants it
through `fb_ready()`, which *is* `[[nodiscard]]`, because discarding *that* answer is
always a bug.

**Lines 42–54 — the drawing calls**
```cpp
[[nodiscard]] Colour fb_pack_colour(uint8_t r, uint8_t g, uint8_t b);
void fb_put_pixel(uint32_t x, uint32_t y, Colour c);
void fb_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, Colour c);
void fb_clear(Colour c);
```
The `fb_` prefix matches `serial_` from Phase 0: these are free functions in a kernel
with no namespaces below the top level, and the prefix keeps `init` and `clear` from
colliding with the next subsystem.

Coordinates are `uint32_t` and unsigned on purpose — see the last decision in §3. There
is no error return: drawing is best-effort, and a caller that could not have known the
screen size should not have to handle a failure it cannot act on. `fb_clear` is one
`fb_fill_rect` call, named now so that Stage 1.3 never has to ask `fb_info()` for the
geometry just to wipe the screen.

**Lines 56–59 — the test pattern**
```cpp
void fb_test_pattern();
```
Declared in the public header, not hidden in the .cpp, because `kernel_init` calls it.
It is scaffolding with an expiry date and the comment says so.

---

### `kernel/drivers/char/fbcon.cpp`

The driver. `drivers/char/` because it lives beside `serial.cpp` — both are character
output devices from the console's point of view, per the layout rule in
[[07 - Repository Layout]].

```cpp
// kernel/drivers/char/fbcon.cpp
//
// The linear framebuffer driver. Three rules live in this file and nowhere
// else in the kernel:
//
//   1. Step between scanlines with `pitch`, never `width`.
//   2. Build pixel values from the reported masks, never from a guess about
//      byte order.
//   3. Never READ framebuffer memory. It is uncached write-combining; a read
//      goes across the bus and is orders of magnitude slower than RAM. This
//      is why Stage 1.4 exists.

#include "kernel/framebuffer.hpp"

#include "kernel/boot_info.hpp"
#include "kernel/serial.hpp"

#include <stddef.h>
#include <stdint.h>

namespace {

// The whole driver's state. A plain aggregate of scalars, so `g_fb` needs no
// constructor and gets no .init_array entry — Coding Standards rule 9.
struct FbState {
    volatile uint8_t* base;    // MMIO-shaped memory: Coding Standards rule 3
    uint32_t width;
    uint32_t height;
    uint32_t pitch;            // BYTES per scanline
    uint32_t bytes_per_pixel;  // bpp / 8

    uint8_t red_size,   red_shift;
    uint8_t green_size, green_shift;
    uint8_t blue_size,  blue_shift;

    bool ready;
};

// Zero-initialised into .bss by the ELF loader, so `ready` is false until
// fb_init says otherwise and a draw call that happens too early does nothing.
FbState g_fb;

// Byte address of pixel (x, y). THE formula of this stage.
//     offset = y * pitch + x * bytes_per_pixel
// The size_t casts force 64-bit arithmetic: uint32_t * uint32_t is evaluated
// in 32 bits and only widened afterwards, which is a silent overflow waiting
// for a big enough screen.
inline volatile uint8_t* pixel_address(uint32_t x, uint32_t y) {
    return g_fb.base
         + static_cast<size_t>(y) * g_fb.pitch
         + static_cast<size_t>(x) * g_fb.bytes_per_pixel;
}

// Store one packed pixel, little-endian, `bytes` wide. One loop covers 32, 24
// and 16 bpp. A single `*(volatile uint32_t*)p = value` would write four bytes
// into a three-byte pixel at 24bpp, and would assume an alignment that the
// protocol does not promise at 16.
inline void store_pixel(volatile uint8_t* p, uint32_t value, uint32_t bytes) {
    for (uint32_t i = 0; i < bytes; ++i)
        p[i] = static_cast<uint8_t>(value >> (i * 8));
}

// Fit an 8-bit channel into a field of `size` bits and slide it to `shift`.
//   size == 8 -> identity: the 8/8/8 case QEMU gives you
//   size == 5 -> keep the TOP five bits, so 0xFF becomes 0x1F, not 0x07
//   size == 0 -> this mode has no such channel
inline uint32_t place_channel(uint8_t value, uint8_t size, uint8_t shift) {
    if (size == 0)
        return 0;

    uint32_t v = value;
    if (size < 8)
        v >>= (8 - size);   // drop the low bits; keep the bright end
    else if (size > 8)
        v <<= (size - 8);   // a 10-bit channel: scale up, precision is lost

    return v << shift;
}

}  // namespace

bool fb_init(const BootInfo* info) {
    g_fb.ready = false;

    // The response is optional: a headless machine is a legitimate machine.
    if (info == nullptr || !info->fb_present || info->fb_addr == 0) {
        serial_puts("fb: no framebuffer; console is serial only\n");
        return false;
    }

    // 15bpp (5:5:5 in a 16-bit container) is reported by some firmware and
    // would break every `/ 8` below, so it is rejected rather than mangled.
    if (info->fb_bpp < 16 || info->fb_bpp > 32 || (info->fb_bpp % 8) != 0) {
        serial_puts("fb: unsupported bpp=");
        serial_write_dec(info->fb_bpp);
        serial_puts("; refusing to draw\n");
        return false;
    }

    const uint32_t bytes = static_cast<uint32_t>(info->fb_bpp) / 8;

    // A scanline cannot be shorter than the pixels on it. If this fires,
    // suspect the BootInfo copy in Stage 0.3 before you suspect the firmware.
    if (info->fb_width == 0 || info->fb_height == 0 ||
        info->fb_pitch < info->fb_width * bytes) {
        serial_puts("fb: impossible geometry; refusing to draw\n");
        return false;
    }

    g_fb.base            = reinterpret_cast<volatile uint8_t*>(info->fb_addr);
    g_fb.width           = static_cast<uint32_t>(info->fb_width);
    g_fb.height          = static_cast<uint32_t>(info->fb_height);
    g_fb.pitch           = static_cast<uint32_t>(info->fb_pitch);
    g_fb.bytes_per_pixel = bytes;

    g_fb.red_size    = info->fb_red_size;
    g_fb.red_shift   = info->fb_red_shift;
    g_fb.green_size  = info->fb_green_size;
    g_fb.green_shift = info->fb_green_shift;
    g_fb.blue_size   = info->fb_blue_size;
    g_fb.blue_shift  = info->fb_blue_shift;

    if (g_fb.red_size == 0 && g_fb.green_size == 0 && g_fb.blue_size == 0) {
        // The protocol requires these fields, so all-zero almost always means
        // the Stage 0.3 copy dropped them. Assume the near-universal 32bpp
        // layout so the machine stays usable, and say so loudly.
        if (bytes != 4) {
            serial_puts("fb: no colour masks and bpp != 32; refusing\n");
            return false;
        }
        serial_puts("fb: WARNING colour masks are all zero; assuming 8:8:8 "
                    "at 16/8/0 — check boot_info.cpp\n");
        g_fb.red_size = g_fb.green_size = g_fb.blue_size = 8;
        g_fb.red_shift   = 16;
        g_fb.green_shift = 8;
        g_fb.blue_shift  = 0;
    }

    g_fb.ready = true;

    // Print pitch AND width*bytes side by side. If they differ, this line is
    // the proof that the padding is real on this machine.
    serial_puts("fb: ");
    serial_write_dec(g_fb.width);
    serial_putc('x');
    serial_write_dec(g_fb.height);
    serial_putc('x');
    serial_write_dec(info->fb_bpp);
    serial_puts(" pitch=");
    serial_write_dec(g_fb.pitch);
    serial_puts(" (width*bytes=");
    serial_write_dec(static_cast<uint64_t>(g_fb.width) * bytes);
    serial_puts(") @ ");
    serial_write_hex(info->fb_addr);
    serial_putc('\n');

    return true;
}

bool fb_ready() {
    return g_fb.ready;
}

FramebufferInfo fb_info() {
    return FramebufferInfo{g_fb.width, g_fb.height, g_fb.pitch,
                           g_fb.bytes_per_pixel};
}

Colour fb_pack_colour(uint8_t r, uint8_t g, uint8_t b) {
    return Colour{place_channel(r, g_fb.red_size,   g_fb.red_shift)
                | place_channel(g, g_fb.green_size, g_fb.green_shift)
                | place_channel(b, g_fb.blue_size,  g_fb.blue_shift)};
}

void fb_put_pixel(uint32_t x, uint32_t y, Colour c) {
    if (!g_fb.ready)
        return;

    // Unsigned, so a caller's negative coordinate arrives as a huge positive
    // one and is caught by this same test. One comparison covers both ends.
    if (x >= g_fb.width || y >= g_fb.height)
        return;

    store_pixel(pixel_address(x, y), c.value, g_fb.bytes_per_pixel);
}

void fb_fill_rect(uint32_t x, uint32_t y, uint32_t w, uint32_t h, Colour c) {
    if (!g_fb.ready)
        return;

    if (x >= g_fb.width || y >= g_fb.height)
        return;  // origin is off-screen: nothing of this rectangle is visible

    // Clip ONCE, then draw with no per-pixel bounds test. Both subtractions
    // are safe because x < width and y < height were just established.
    if (w > g_fb.width - x)
        w = g_fb.width - x;
    if (h > g_fb.height - y)
        h = g_fb.height - y;

    for (uint32_t row = 0; row < h; ++row) {
        // Recompute the row start from `pitch` every row, then walk along it.
        volatile uint8_t* p = pixel_address(x, y + row);
        for (uint32_t col = 0; col < w; ++col) {
            store_pixel(p, c.value, g_fb.bytes_per_pixel);
            p += g_fb.bytes_per_pixel;
        }
    }
}

void fb_clear(Colour c) {
    fb_fill_rect(0, 0, g_fb.width, g_fb.height, c);
}

void fb_test_pattern() {
    if (!g_fb.ready)
        return;

    const Colour background = fb_pack_colour(0x10, 0x10, 0x18);
    const Colour frame      = fb_pack_colour(0xFF, 0xFF, 0xFF);
    const Colour red        = fb_pack_colour(0xFF, 0x00, 0x00);
    const Colour green      = fb_pack_colour(0x00, 0xFF, 0x00);
    const Colour blue       = fb_pack_colour(0x00, 0x00, 0xFF);
    const Colour box        = fb_pack_colour(0x30, 0x90, 0xE0);

    fb_clear(background);

    // A one-pixel frame around the whole screen. If the scanline step is
    // wrong, the two vertical edges are the first thing to slant.
    fb_fill_rect(0, 0, g_fb.width, 1, frame);                  // top
    fb_fill_rect(0, g_fb.height - 1, g_fb.width, 1, frame);    // bottom
    fb_fill_rect(0, 0, 1, g_fb.height, frame);                 // left
    fb_fill_rect(g_fb.width - 1, 0, 1, g_fb.height, frame);    // right

    // Colour bars, top to bottom: red, green, blue. In any other order,
    // fb_pack_colour is using the wrong masks — see §7.
    fb_fill_rect(16, 16, 64, 32, red);
    fb_fill_rect(16, 56, 64, 32, green);
    fb_fill_rect(16, 96, 64, 32, blue);

    // The only thing here drawn one pixel at a time, so fb_put_pixel is
    // exercised too: a short diagonal in from the top-right corner.
    for (uint32_t i = 0; i < 128 && i < g_fb.width && i < g_fb.height; ++i)
        fb_put_pixel(g_fb.width - 1 - i, i, frame);

    // The deliverable: a solid rectangle, a quarter of each axis, centred.
    const uint32_t w = g_fb.width / 4;
    const uint32_t h = g_fb.height / 4;
    fb_fill_rect((g_fb.width - w) / 2, (g_fb.height - h) / 2, w, h, box);
}
```

#### Line by line

**Lines 1–11 — the three rules**
```cpp
//   1. Step between scanlines with `pitch`, never `width`.
//   2. Build pixel values from the reported masks, never from a guess.
//   3. Never READ framebuffer memory.
```
This is rule 10 of [[13 - Coding Standards]] applied at file scope. All three are
invariants that a future edit can break silently, and none of them is visible from the
code alone. A reader who adds a "just read the pixel back to blend it" helper six
months from now will not otherwise know why the console suddenly crawls.

**Lines 13–19 — includes, in the mandated order**
```cpp
#include "kernel/framebuffer.hpp"

#include "kernel/boot_info.hpp"
#include "kernel/serial.hpp"

#include <stddef.h>
#include <stdint.h>
```
Own header first — this makes the header self-contained by construction, because if
`framebuffer.hpp` forgot an include it fails here first. Then kernel headers, then
GCC's freestanding C headers. `<stddef.h>` for `size_t` in `pixel_address`;
`<stdint.h>` for the fixed-width types. `serial.hpp` because init reports through the
channel that already works — which is the whole point of having built serial first
([[ADR-0004 - Framebuffer Console Not VGA Text]] insists on that ordering).

There is no `limine.h` here and there never will be. This file lives outside
`kernel/arch/x86_64/boot/`, and CI greps for exactly that.

**Lines 21–36 — `FbState`**
```cpp
namespace {

struct FbState {
    volatile uint8_t* base;
    uint32_t width;
    // ...
    bool ready;
};
```
An anonymous namespace gives everything inside internal linkage — `FbState`,
`g_fb`, `pixel_address`, `store_pixel` and `place_channel` are invisible to the
linker and cannot collide with anything. This is the C++ replacement for `static` at
file scope and is what [[13 - Coding Standards]] expects for driver-private state.

`base` is `volatile uint8_t*`: `uint8_t` because all the arithmetic is in bytes and a
typed pointer would tempt you into `ptr[index]` with the wrong unit; `volatile`
because this is MMIO, argued at length in §3.

`ready` is last and is the only thing that gates drawing. Note that it is *state*, not
a redundant copy of `base != nullptr`: `fb_init` can reject a framebuffer that has a
perfectly good address but geometry it refuses to work with.

**Lines 38–40 — the global**
```cpp
FbState g_fb;
```
`g_` prefix per the naming table. At namespace scope this is zero-initialised into
`.bss` — the ELF loader zero-fills the part of the segment beyond the file size, and
Limine does. There is no constructor, so there is no `.init_array` entry, so it does
not matter that nothing walks `.init_array` until Phase 4 (rule 9). The consequence
that makes this design safe: **before `fb_init` runs, `ready` is false and `base` is
null**, so any drawing call that sneaks in early does nothing rather than writing
through a null pointer at ring 0 with no IDT installed.

**Lines 42–51 — `pixel_address`, the formula**
```cpp
inline volatile uint8_t* pixel_address(uint32_t x, uint32_t y) {
    return g_fb.base
         + static_cast<size_t>(y) * g_fb.pitch
         + static_cast<size_t>(x) * g_fb.bytes_per_pixel;
}
```
This is the stage. Everything else is arrangement.

`y * g_fb.pitch` — **pitch, not width, not `width * bytes_per_pixel`.** §2.3 has the
diagram; §7 has the symptom.

The `static_cast<size_t>` on each left operand is not decoration. In C++, `uint32_t *
uint32_t` is computed in 32 bits and the result is only widened afterwards, so an
expression that overflows produces a wrapped 32-bit value and *then* gets zero-extended
into your 64-bit pointer arithmetic. At 1280×800 nothing overflows and the cast is
free; at some future resolution, on some future path, it stops being free, and the
failure would be a wild write. Casting one operand first forces the whole expression
into 64 bits. Make it a habit in any address computation.

`inline` here is about giving the definition internal-linkage-friendly semantics inside
the anonymous namespace and letting GCC fold it into callers; at `-O2` this compiles to
a multiply-add with no call.

Returning `volatile uint8_t*` rather than `void*` keeps the volatility attached to the
pointer. Drop it and the callers silently get an ordinary pointer, and the guarantee
from §3 disappears with no diagnostic.

**Lines 53–59 — `store_pixel`**
```cpp
inline void store_pixel(volatile uint8_t* p, uint32_t value, uint32_t bytes) {
    for (uint32_t i = 0; i < bytes; ++i)
        p[i] = static_cast<uint8_t>(value >> (i * 8));
}
```
Byte `i` of a little-endian value is bits `8i..8i+7`, which is exactly
`value >> (i * 8)` truncated. The loop therefore writes the packed value in the
machine's native byte order for any pixel width from 1 to 4 bytes, with one body.

Why not `*reinterpret_cast<volatile uint32_t*>(p) = value;`? Two reasons, both real.
At 24bpp it writes **four** bytes into a three-byte pixel, corrupting the low byte of
the pixel to its right — a bug that looks like a colour fringe and is agonising to
identify. And the Limine protocol does not promise that `pitch` is a multiple of 4, so
at 16bpp (and in principle at 32bpp with an odd pitch) the pointer can be misaligned,
which is undefined behaviour in C++ even though x86 tolerates it in hardware.

The honest cost: four separate one-byte stores per pixel, which volatile forbids the
compiler from merging. If you later want the fast path, the correct form is a flag
computed **once** in `fb_init` —
`fast32 = (bytes == 4) && (reinterpret_cast<uintptr_t>(base) % 4 == 0) && (pitch % 4 == 0)` —
and a branch in `store_pixel`. Do not add it now. Stage 1.4 moves these stores into
normal RAM where the question stops mattering, and premature micro-optimisation of a
function you have not yet proved correct is how you end up debugging two things at once.

**Lines 61–74 — `place_channel`**
```cpp
inline uint32_t place_channel(uint8_t value, uint8_t size, uint8_t shift) {
    if (size == 0)
        return 0;

    uint32_t v = value;
    if (size < 8)
        v >>= (8 - size);
    else if (size > 8)
        v <<= (size - 8);

    return v << shift;
}
```
The colour-format translation, one channel at a time.

`size == 0` means the mode has no field for this channel; contributing zero is the only
correct answer. It also protects the shift below: `8 - 0` is 8, and `uint32_t >> 8` is
perfectly defined, but the early return states the intent.

`size < 8` is the truncating case — a 5-bit or 6-bit field. Shifting **right** keeps
the high bits, which is what preserves brightness: `0xFF >> 3` is `0x1F`, the maximum
value of a 5-bit field. The tempting alternative, `value & 0x1F`, keeps the *low* bits,
so full-brightness white (`0xFF`) becomes `0x1F` by luck while mid-grey (`0x80`)
becomes `0x00` — every shade lands in the wrong place and gradients turn into stripes.

`size > 8` is the deep-colour case (10 bits per channel exists). Shifting left scales
the value up; the low bits are zero, so the brightest input maps slightly below the
true maximum. This is an approximation and the comment says so. Without the branch,
`8 - size` on an unsigned type underflows to an enormous number and the shift is
undefined behaviour.

`v << shift` puts the field where the hardware expects it. All three results are OR-ed
together by the caller; because the fields do not overlap, OR is the whole composition.

**Lines 78–84 — `fb_init`, the null checks**
```cpp
bool fb_init(const BootInfo* info) {
    g_fb.ready = false;

    if (info == nullptr || !info->fb_present || info->fb_addr == 0) {
        serial_puts("fb: no framebuffer; console is serial only\n");
        return false;
    }
```
`ready = false` first, unconditionally, so that every early return below leaves the
driver in a defined, safe state without repeating the assignment on each path.

Three checks, in strictly increasing order of dereference depth: the pointer, then the
flag Stage 0.3 set, then the address the flag claims exists. Short-circuit evaluation
means `info->fb_present` is never read when `info` is null.

`fb_present` is the honest test. Inferring "no display" from `fb_addr == 0` alone
conflates *absent* with *the bootloader gave us address zero*, which is exactly the
distinction Stage 0.3 added the flag for. Both are checked anyway, because a `true`
flag with a null address is a bug in the copy and should not become a null dereference
here.

And the failure is **not fatal**. A headless machine must boot; it just has no console
on the glass. The serial line is what turns "black screen" from a mystery into a
sentence.

**Lines 86–95 — bpp validation**
```cpp
    if (info->fb_bpp < 16 || info->fb_bpp > 32 || (info->fb_bpp % 8) != 0) {
        serial_puts("fb: unsupported bpp=");
        serial_write_dec(info->fb_bpp);
        serial_puts("; refusing to draw\n");
        return false;
    }

    const uint32_t bytes = static_cast<uint32_t>(info->fb_bpp) / 8;
```
Everything downstream divides `bpp` by 8 and assumes the result is a usable pixel
width. The three conditions between them admit exactly 16, 24 and 32.

The interesting exclusion is 15. Some firmware reports 15bpp for a 5:5:5 mode stored in
a 16-bit container; `15 / 8` is 1, so every pixel would be written one byte wide and
the picture would be unrecognisable. Rejecting is right: an unsupported mode with a
clear message beats a supported-looking mode drawn wrong.

`serial_write_dec` prints the offending value. A diagnostic that names the number is
worth ten that say "unsupported".

**Lines 97–104 — geometry validation**
```cpp
    if (info->fb_width == 0 || info->fb_height == 0 ||
        info->fb_pitch < info->fb_width * bytes) {
        serial_puts("fb: impossible geometry; refusing to draw\n");
        return false;
    }
```
`pitch >= width * bytes_per_pixel` is a property of any real framebuffer: a scanline
cannot be shorter than the pixels on it. If it is violated, every `fb_fill_rect` you
issue runs off the end of its row into the row below, and the picture is scrambled from
the first frame.

Where it actually comes from matters for debugging, so the code comment says it: this
almost never means the firmware lied. It means the `BootInfo` copy assigned `pitch` and
`width` to the wrong fields, or copied `pitch` from `limine_video_mode` (whose field
order is `pitch, width, height` — different from `limine_framebuffer`). Checking the
invariant here turns that into one line of serial output instead of a visual puzzle.

Note the operand types: `fb_width` is `uint64_t` and `bytes` is `uint32_t`, so the
multiplication is promoted to 64-bit and cannot overflow. No cast is needed and no
`-Wsign-compare` fires because everything is unsigned.

**Lines 106–118 — storing the geometry and masks**
```cpp
    g_fb.base            = reinterpret_cast<volatile uint8_t*>(info->fb_addr);
    g_fb.width           = static_cast<uint32_t>(info->fb_width);
    // ...
    g_fb.blue_shift  = info->fb_blue_shift;
```
`reinterpret_cast` from `uintptr_t` to a pointer is the one place in this file where an
integer becomes an address, and it is legitimate precisely because `fb_addr` is a
**virtual** address in a region Limine has already mapped. Nothing here maps anything.

Do **not** write `info->fb_addr + info->hhdm_offset`. Limine reports the framebuffer
address already translated into its higher-half direct map; adding the HHDM offset
again produces a non-canonical or unmapped address, and with no IDT the resulting fault
is a triple fault and a reboot loop. This is a real and popular mistake — see §7.

The narrowing casts are explicit. `-Wconversion` is not in the flag set, so implicit
narrowing would compile silently; writing the cast is a statement that the range was
checked above.

The six mask fields are copied one for one. Tedious, and the tedium is the point: a
transposed pair here — `green_shift` into `blue_shift` — is a colour bug that will be
blamed on `place_channel`. Read them twice now.

**Lines 120–135 — the all-zero mask fallback**
```cpp
    if (g_fb.red_size == 0 && g_fb.green_size == 0 && g_fb.blue_size == 0) {
        if (bytes != 4) {
            serial_puts("fb: no colour masks and bpp != 32; refusing\n");
            return false;
        }
        serial_puts("fb: WARNING colour masks are all zero; assuming 8:8:8 "
                    "at 16/8/0 — check boot_info.cpp\n");
        g_fb.red_size = g_fb.green_size = g_fb.blue_size = 8;
        g_fb.red_shift   = 16;
        g_fb.green_shift = 8;
        g_fb.blue_shift  = 0;
    }
```
Without this, an all-zero mask set makes `place_channel` return 0 for every channel,
`fb_pack_colour` returns black for every colour, and the deliverable of the stage is a
black screen that looks exactly like "nothing ran". That is a two-hour debugging
session, and the cause is almost always mundane: the Stage 0.3 copy has the mask fields
missing or misnamed.

So the code guesses, and **shouts about the guess**. The guess is only made when it is
nearly certain to be right — 32bpp, where 8:8:8 at 16/8/0 is close to universal — and
refused otherwise, because guessing a 16bpp layout would produce plausible-looking
wrong colours instead of an obvious failure.

The warning text names the file to look in. A diagnostic that tells you where to go
next is worth several that describe the symptom.

**Lines 137–155 — `ready` and the geometry report**
```cpp
    g_fb.ready = true;

    serial_puts("fb: ");
    // ... width x height x bpp, pitch, width*bytes, address ...
    return true;
}
```
`ready` is set only after every check has passed and every field is stored. Set it
earlier and a failed check leaves a half-initialised driver marked usable.

The report prints `pitch` **and** `width * bytes` next to each other, which is the one
line in this project that will eventually tell you the padding is real. On QEMU they
will be equal and you will learn that QEMU cannot test this. On a laptop they will
differ and the number in the gap is exactly the drift-per-row from §2.3, divided by
`bytes`.

Printing the address matters for a different reason: when [[Phase 4 - Overview|Phase 4]]
builds its own page tables, this address must still be mapped, and comparing this line
before and after that change is the fastest way to catch a mapping regression.

**Lines 157–168 — the trivial accessors**
```cpp
bool fb_ready() { return g_fb.ready; }

FramebufferInfo fb_info() {
    return FramebufferInfo{g_fb.width, g_fb.height, g_fb.pitch,
                           g_fb.bytes_per_pixel};
}
```
Aggregate initialisation in declaration order. When `!fb_ready()` every field is zero,
which is a safe answer: a caller that loops `for (x = 0; x < info.width; ++x)` does
nothing rather than something wrong.

These exist so that Stage 1.2 and Stage 1.3 never touch `g_fb`. The console needs
`width` and `height` to work out how many characters fit; it must not need `base`.

**Lines 170–175 — `fb_pack_colour`**
```cpp
Colour fb_pack_colour(uint8_t r, uint8_t g, uint8_t b) {
    return Colour{place_channel(r, g_fb.red_size,   g_fb.red_shift)
                | place_channel(g, g_fb.green_size, g_fb.green_shift)
                | place_channel(b, g_fb.blue_size,  g_fb.blue_shift)};
}
```
Three fields, three placements, one OR. Because the fields are disjoint by definition,
OR is exactly the composition operator — no masking of the result is needed, and any
bits outside the three fields (a 32bpp mode's unused byte) stay zero.

It reads `g_fb` rather than taking a `FramebufferInfo`, so callers cannot pass masks
from a different mode. It is *not* `constexpr`: the masks are only known at runtime.
And it is deliberately cheap enough to call in `fb_test_pattern` for each colour, but
the header tells you to hoist it out of loops — six shifts per pixel in a glyph
rasteriser is real work for a value that never changes.

**Lines 177–188 — `fb_put_pixel`**
```cpp
void fb_put_pixel(uint32_t x, uint32_t y, Colour c) {
    if (!g_fb.ready)
        return;

    if (x >= g_fb.width || y >= g_fb.height)
        return;

    store_pixel(pixel_address(x, y), c.value, g_fb.bytes_per_pixel);
}
```
Two guards and one store.

The `ready` guard means a caller never has to check. That matters more than it looks:
the panic handler in [[Stage 0.7 - Panic and KASSERT]] will eventually try to draw, and
it may be running because initialisation itself failed. A drawing primitive that is
safe to call at any time is a drawing primitive the panic path can use.

The bounds guard is the one from the last decision in §3. Compare against `width` and
`height` — the *visible* extents — never against `pitch`. Pixels in the padding
region are addressable and invisible; letting `x` reach into them writes bytes the
display never scans out, which looks like the pixel vanished.

What happens without the guard is worth being precise about, because the QEMU
behaviour hides it. The mapped region is `pitch × height` bytes. A `y` one row past the
end writes a few kilobytes beyond it, which on QEMU's emulated adapter usually lands in
unused video RAM: no fault, no visible effect, no test failure. On real hardware the
next page may be another device's MMIO aperture, and the write does whatever that
device does with it. If it is unmapped instead, it faults — and with no IDT before
Phase 2, that is a triple fault and an instant silent reboot.

**Lines 190–214 — `fb_fill_rect`**
```cpp
    if (x >= g_fb.width || y >= g_fb.height)
        return;

    if (w > g_fb.width - x)
        w = g_fb.width - x;
    if (h > g_fb.height - y)
        h = g_fb.height - y;
```
Clipping, done once, in the only order that is safe on unsigned types. `g_fb.width - x`
would wrap to an enormous number if `x > width` — which is exactly why the early return
above establishes `x < width` first. Reversing those two blocks introduces a bug that
only appears for fully off-screen rectangles.

Clipping rather than rejecting is the right call for a console: Stage 1.3 will draw a
glyph that is partly past the right margin, and it should render the visible part.

```cpp
    for (uint32_t row = 0; row < h; ++row) {
        volatile uint8_t* p = pixel_address(x, y + row);
        for (uint32_t col = 0; col < w; ++col) {
            store_pixel(p, c.value, g_fb.bytes_per_pixel);
            p += g_fb.bytes_per_pixel;
        }
    }
```
The row start is recomputed from `pitch` on every iteration of the outer loop, and the
inner loop advances by `bytes_per_pixel` only. That is the structural expression of §2.3:
*within* a row, pixels are packed; *between* rows, the step is `pitch`. Writing the
inner loop as `p += bytes` and then, at the end of the row, `p += bytes` again would
skip the padding and reintroduce the shear.

Calling `fb_put_pixel` in the inner loop instead would re-run both guards and recompute
the full address for every pixel — for a full-screen clear at 1280×800 that is a
million redundant multiplies. The clip-then-walk structure is why `fb_fill_rect` exists
as a separate function rather than a loop in the caller.

**Lines 216–218 — `fb_clear`**
```cpp
void fb_clear(Colour c) {
    fb_fill_rect(0, 0, g_fb.width, g_fb.height, c);
}
```
Safe when `!ready`, twice over: `fb_fill_rect` checks the flag, and the zeroed width
would fail the origin test anyway.

**Lines 220–260 — `fb_test_pattern`**
```cpp
    fb_fill_rect(0, 0, g_fb.width, 1, frame);                  // top
    fb_fill_rect(0, g_fb.height - 1, g_fb.width, 1, frame);    // bottom
    fb_fill_rect(0, 0, 1, g_fb.height, frame);                 // left
    fb_fill_rect(g_fb.width - 1, 0, 1, g_fb.height, frame);    // right
```
The pattern is not decoration; each element proves one thing that nothing else proves,
and it is designed so that a *glance* diagnoses the failure.

The frame proves geometry and stride together. The two vertical edges are the sensitive
part: a one-pixel-wide column at `x = width - 1` is drawn from `height` separate row
addresses, so if the row step is wrong the column is not a line, it is a diagonal. The
top and bottom edges confirm that `width` and `height` are the real extents — if the
bottom edge is off-screen, `height` is wrong; if the right edge is missing, so is the
last column.

```cpp
    fb_fill_rect(16, 16, 64, 32, red);
    fb_fill_rect(16, 56, 64, 32, green);
    fb_fill_rect(16, 96, 64, 32, blue);
```
The bars prove colour packing, and they are three rather than one because a single red
bar tells you nothing when it comes out blue — you cannot tell whether the channels are
swapped or your constant was wrong. Three bars in a known order make the failure
unambiguous: red-green-blue top to bottom is correct, blue-green-red is a
`red_shift`/`blue_shift` swap (a BGR framebuffer read as RGB), anything dim or muddy is
a mask *size* problem.

The coordinates are absolute and small so the bars fit on the smallest mode you might
be given — 96 + 32 is 128 rows, inside even 640×480.

```cpp
    for (uint32_t i = 0; i < 128 && i < g_fb.width && i < g_fb.height; ++i)
        fb_put_pixel(g_fb.width - 1 - i, i, frame);
```
The only caller of `fb_put_pixel` in the pattern, so that the per-pixel path is
exercised rather than assumed. A diagonal is the right shape for it: it changes `x` and
`y` together, so it fails visibly if either axis is mis-scaled. The `i < width` and
`i < height` terms keep it inside the smallest plausible screen without relying on the
bounds check to silently discard work.

```cpp
    const uint32_t w = g_fb.width / 4;
    const uint32_t h = g_fb.height / 4;
    fb_fill_rect((g_fb.width - w) / 2, (g_fb.height - h) / 2, w, h, box);
```
The deliverable. Sized and positioned from the reported geometry rather than from
constants, which is what makes the resolution-change test in §6 meaningful: if any
part of the pipeline is hardcoded to 1280×800, this rectangle stops being centred (or
stops being a quarter of the screen) the moment the mode changes.

---

### Wiring it in

Two edits outside the new files.

**`kernel/CMakeLists.txt`** — the source list is explicit, never globbed, for the reason
[[Stage 0.8 - The Build System]] gives: a `file(GLOB)` is evaluated at configure time
and does not re-run, so a new `.cpp` is silently not compiled and you get an undefined
reference to a function whose definition is sitting right there.

```cmake
add_executable(kernel.elf
    arch/x86_64/boot/entry.cpp
    arch/x86_64/boot/boot_info.cpp
    drivers/char/serial.cpp
    drivers/char/fbcon.cpp        # new in Stage 1.1
    lib/panic.cpp
    main.cpp
)
```

**`kernel/main.cpp`** — step 6 of the initialisation order in
[[06 - Architecture Overview]]: after serial, after `BootInfo`, before anything that
wants to print to a screen.

```cpp
#include "kernel/framebuffer.hpp"

void kernel_init(BootInfo* info) {
    serial_init();
    // ... the Stage 0.6 greeting ...

    fb_init(info);        // step 6: needs BootInfo and nothing else
    fb_test_pattern();

    for (;;)
        __builtin_ia32_pause();
}
```

`fb_init` before `fb_test_pattern`, obviously — but note that reversing them does not
crash. The test pattern would see `ready == false` and return, and you would get a
black screen with a perfectly healthy serial log. That is one of the four causes in
the third trap in §7.

---

## 6. How to verify

### Now — it builds and the symbols exist

```bash
make
```

Then confirm the new translation unit was actually compiled and linked:

```bash
x86_64-elf-nm build/kernel.elf | grep ' T fb_'
```

Expected — six global text symbols, addresses in the higher half (yours will differ):

```
ffffffff80102a10 T fb_clear
ffffffff801029c0 T fb_fill_rect
ffffffff80102880 T fb_info
ffffffff801026e0 T fb_init
ffffffff80102960 T fb_pack_colour
ffffffff80102a40 T fb_put_pixel
ffffffff80102a80 T fb_ready
ffffffff80102ac0 T fb_test_pattern
```

`pixel_address`, `store_pixel` and `place_channel` do **not** appear: they are in an
anonymous namespace and inlined. If you see them as `t` (lowercase, local), that is
fine too — it only means GCC kept an out-of-line copy.

If `fb_init` is missing entirely, you forgot the CMake line.

### Now — the deliverable

```bash
make run
```

Expect, in this order: the Limine menu for three seconds, then the screen clears to a
very dark blue-grey and you see

- a **one-pixel white frame** around the entire screen,
- three bars near the top left — **red, then green, then blue**, top to bottom,
- a short **white diagonal** coming in from the top-right corner,
- a **solid blue rectangle**, one quarter of the screen in each direction, exactly
  centred.

On serial (in your terminal with `make run-serial`, or in `build/serial.log`), after
the Stage 0.6 greeting:

```
fb: 1280x800x32 pitch=5120 (width*bytes=5120) @ 0xFD000000
```

The address varies by machine and QEMU version. The two numbers in the middle being
equal is expected under QEMU and is itself information — see the killer test.

### Now — the killer test: change the resolution

Edit `boot/limine.conf` and change **every** `resolution:` line:

```ini
    resolution: 1024x768x32
```

Then:

```bash
make run
```

The rectangle must still be a quarter of the screen in each axis, still centred, still
square-cornered; the frame must still hug all four edges. Nothing on screen may be
clipped, offset or sheared.

What this proves: no part of your pipeline hardcodes 1280×800. What it does **not**
prove is the pitch arithmetic, because QEMU hands out `pitch == width × 4` at both
resolutions — which is exactly what the `(width*bytes=...)` half of the serial line is
telling you. Put the resolution back when you are done.

### Now — cause the pitch bug on purpose

This is the most valuable five minutes in the stage. Temporarily add one line to
`fb_init`, immediately before `g_fb.ready = true;`:

```cpp
    g_fb.pitch -= 16;   // TEMPORARY: what a pitch bug looks like. Remove me.
```

`make run`. Everything shears into diagonal stripes: each row starts 16 bytes — four
pixels — earlier than the display expects, so the picture leans progressively left and
wraps around the screen edge. The frame becomes a set of parallel diagonals. Look at
it for ten seconds. That image is what a `y * width` bug looks like, and you now
recognise it instantly instead of spending an evening on it in Phase 15.

It is safe to run: a *smaller* stride only ever moves writes closer to the start of the
buffer, so nothing lands outside the mapping. Do **not** try the same experiment with
`+= 16`, which writes past the end of the framebuffer.

Delete the line.

### Later — what cannot be checked yet

| Check | Where |
|---|---|
| Pixels land at the right offsets when `pitch != width * bytes` | Tier-2 test with a synthetic framebuffer, per the testing table in [[Phase 1 - Overview]]. A fake buffer with `pitch = width * 4 + 64`, drawn into, then inspected byte by byte — the only way to test this without real hardware |
| The framebuffer is still mapped after the kernel installs its own page tables | [[Phase 4 - Overview\|Phase 4]] — and it must be mapped **write-combining**, not uncacheable, or drawing gets slower by an order of magnitude |
| Text is readable | [[Stage 1.2 - Rasterising a Bitmap Font]] |
| Redraws do not tear or crawl | [[Stage 1.4 - Double Buffering]] |
| Real panel, real pitch, real masks | [[Phase 15 - Overview\|Phase 15]] |

- [ ] `make` succeeds with `-Werror` clean
- [ ] `nm` shows `fb_init`, `fb_put_pixel`, `fb_fill_rect`, `fb_pack_colour`, `fb_test_pattern`
- [ ] `make run` shows the frame, the three bars in R-G-B order, the diagonal and the centred rectangle
- [ ] The serial line reports the same geometry that `boot/limine.conf` asked for
- [ ] Changing `resolution:` keeps the rectangle centred and correctly proportioned
- [ ] The deliberate `pitch -= 16` produces diagonal stripes, and you removed it again
- [ ] `grep -rn limine kernel/ --include=*.cpp --include=*.hpp | grep -v arch/x86_64/boot` still returns nothing

---

## 7. Common traps

**The image is sheared into a diagonal parallelogram, or the whole screen is a field
of slanted stripes.**
You used `width` where `pitch` belongs — `offset = (y * width + x) * bytes` instead of
`offset = y * pitch + x * bytes`. Every row lands
`(pitch − width × bytes) / bytes` pixels to the left of where the display expects it,
and the error accumulates down the screen. On a 1366×768 panel with pitch 5504 that is
ten pixels per row: eighty rows in, the picture has walked a full screen width
sideways. Nothing faults, because the wrong addresses are all *inside* the framebuffer
— the bug is purely visual, which is why it survives every test that does not have a
human looking at a screen. Fix: `pixel_address` computes the row start from
`g_fb.pitch`, and `fb_fill_rect` recomputes it per row rather than adding a constant.
Note that **QEMU will not reproduce this**; its emulated adapters report a pitch equal
to `width × bytes`, so the code is wrong and the screen is right until you boot real
hardware.

**Colours are wrong — red comes out blue, or everything is a muddy green.**
You assumed a byte order instead of reading the masks. Two distinct causes. First,
endianness: writing the 32-bit value `0x00FF0000` puts the bytes `00 00 FF 00` in
memory, low byte first, so a framebuffer that expects blue in byte 0 shows your "red"
as blue. Reasoning about *bytes* in memory is the mistake; reason about the *value* and
let `store_pixel` handle the order. Second, a genuine BGR framebuffer, where
`red_mask_shift` is 0 and `blue_mask_shift` is 16 — real adapters report this, and the
only correct response is to use the numbers you were given. Muddy or banded colours
instead of swapped ones mean a mask *size* problem: an 8-bit value written into a 5-bit
field with `&` instead of `>>` keeps the low bits, so brightness is scrambled. Check
the three-bar test pattern: top to bottom must read red, green, blue.

**Nothing on screen, but serial says the kernel ran fine.**
Four causes, in the order they are worth checking.
*One:* `fb_init` returned false — read the serial line, it says which check failed. The
usual reason is `fb_present == false`, which means the framebuffer response was null,
which usually means the request is missing from the `.limine_requests` section or the
copy in `boot_info.cpp` skipped it ([[Stage 0.2 - The Limine Request Section]]).
*Two:* you called `fb_test_pattern()` before `fb_init()`. `ready` is false, everything
returns immediately, and nothing distinguishes it from a hang except the serial log.
*Three:* you drew off-screen. A rectangle at `y = height + 10` is silently dropped by
the bounds check (or silently written into someone else's memory without it).
*Four:* you drew the right thing in the wrong colour — black on black. If
`fb_pack_colour` returns 0 for every input, the masks are all zero; the fallback in
`fb_init` exists precisely to turn this into a warning line instead of a black screen,
so if you skipped it, add it.

**It works perfectly in QEMU and gives a black screen on real hardware.**
The catalogue of things QEMU is too generous about. It gives you exactly the resolution
you asked for, always 32bpp, always 8/8/8 masks at 16/8/0, always a pitch equal to
`width × bytes`, and a large enough BAR that modest out-of-bounds writes go unnoticed.
Real firmware gives you the panel's native mode (which may be none of the above), a
padded pitch, occasionally BGR, and no slack past the end of the buffer. Anything you
hardcoded — geometry, bpp, pitch, channel order — is fine in QEMU and wrong there. The
same trap has a second form: leftover `0xB8000` code from a tutorial. Under Limine's
direct map that address is writable, so the write succeeds and does nothing; there is
no VGA text buffer on a UEFI machine, and there is none anywhere in this OS
([[ADR-0004 - Framebuffer Console Not VGA Text]]).

**Drawing is unbearably slow — you can watch the screen fill.**
You are reading from framebuffer memory. It is uncached write-combining: a write is
buffered and fast, a read goes all the way to the device across the bus and costs
hundreds of nanoseconds against about one for an L1 hit. The read is rarely obvious in
the source — it hides inside `p[i] |= mask` (read, modify, write), inside any blending
or transparency, and inside a scroll implemented as "copy each row up from the
framebuffer to the framebuffer". The rule is absolute in this file: **never read
`g_fb.base`.** If you need the previous contents, keep them in RAM — which is precisely
what [[Stage 1.4 - Double Buffering]] does. A secondary, much smaller cost is the
four-byte-at-a-time `store_pixel` loop, which volatile forbids the compiler from
merging; leave it alone until Stage 1.4 moves the stores into normal RAM.

**The machine reboots the instant you draw anything.**
You added `hhdm_offset` to `fb_addr`. Limine reports the framebuffer address *already*
inside its higher-half direct map, so adding the offset a second time yields an
unmapped or non-canonical address. With no IDT before [[Phase 2 - Overview|Phase 2]],
the page fault becomes a double fault, then a triple fault, then a reset — a reboot
loop with nothing on screen and nothing on serial past the last line you printed.
The other route to the same symptom is writing far past the end of the framebuffer
because a bounds check is missing.

**`error: compound assignment with 'volatile'-qualified type is deprecated`.**
C++20 deprecated `|=`, `&=` and friends on volatile lvalues, GCC enables `-Wvolatile`
by default in C++20 mode, and `-Werror` turns it into a build failure. The fix is never
to disable the warning: read-modify-write on this memory is the previous trap, so
rewrite it as a plain assignment of a value you computed in registers.

**The build succeeds but nothing in `fbcon.cpp` is in the binary.**
You did not add `drivers/char/fbcon.cpp` to `kernel/CMakeLists.txt`, and the link
error names a function you can see with your own eyes in a file you just saved. The
source list is explicit on purpose; see [[Stage 0.8 - The Build System]].

---

## 8. What this unlocks

Every remaining stage in this phase sits directly on these three functions.
[[Stage 1.2 - Rasterising a Bitmap Font]] turns a glyph bitmap into eight `fb_put_pixel`
calls per row; Stage 1.3's console is a cursor, `fb_fill_rect` for the background and
scroll region, and `fb_info()` for how many characters fit;
[[Stage 1.4 - Double Buffering]] replaces the destination inside `pixel_address` with a
back buffer in normal RAM and flushes it write-only; [[Stage 1.6 - kprintf]] and
[[Stage 1.7 - Symbolised Backtraces]] print through all of it, including from the panic
handler, which is why every entry point here is safe to call before initialisation.
Beyond this phase, [[Phase 4 - Overview|Phase 4]] must keep `fb_addr` mapped — and
mapped **write-combining** — when it installs the kernel's own page tables, and
[[Phase 15 - Overview|Phase 15]] is where a hardcoded geometry or an assumed pitch
finally shows itself. Get the pitch arithmetic and the mask-based packing right today
and none of that is ever a question again; get either wrong and every subsequent stage
inherits a bug that only appears on hardware you do not own yet.

---

## 9. Reading

- **OSDev — Drawing In a Linear Framebuffer**:
  <https://wiki.osdev.org/Drawing_In_a_Linear_Framebuffer>
  The canonical page for this stage. Read it for the pitch discussion and the
  bytes-per-pixel cases; ignore its examples that assume a fixed 32bpp RGB layout.
- **Limine boot protocol — the framebuffer feature**:
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
  The authority on what each field means and what is guaranteed. Read the framebuffer
  section against the vendored `limine.h`, and check the tag you pinned rather than
  `trunk` if the two disagree.
- **OSDev — GOP**: <https://wiki.osdev.org/GOP>
  Where the numbers originally come from. `EFI_GRAPHICS_OUTPUT_MODE_INFORMATION` has
  `PixelsPerScanLine` — the pitch, in pixels rather than bytes — and this is the layer
  Limine queried on your behalf before exiting boot services.
- **OSDev — VESA Video Modes**: <https://wiki.osdev.org/VESA_Video_Modes>
  The historical origin of the mask size/shift pairs, and the best explanation of why
  they exist rather than a simple format enum. Useful when you meet a 5:6:5 mode.
- **OSDev — Double Buffering**: <https://wiki.osdev.org/Double_Buffering>
  Read it now, implement it in Stage 1.4. It explains why the framebuffer is the wrong
  place to keep the only copy of what is on screen.
- **Intel® 64 and IA-32 Architectures Software Developer's Manual, Volume 3A, chapter
  11 (Memory Cache Control)**:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
  §11.3 defines the write-combining memory type. This is the specification behind
  "reads from the framebuffer are catastrophically slow", and it is what Phase 4 needs
  when it chooses the PAT/MTRR type for this region.
- **UEFI Specification, chapter 12 — Console Support**: <https://uefi.org/specifications>
  For the Graphics Output Protocol, and for the absence of any promise about VGA
  compatibility that [[ADR-0004 - Framebuffer Console Not VGA Text]] rests on.
- Vault: [[ADR-0004 - Framebuffer Console Not VGA Text]] ·
  [[Stage 0.3 - Freestanding C++ and kmain]] (where `BootInfo` came from) ·
  [[Stage 0.6 - Serial Output]] (the channel this stage reports through) ·
  [[13 - Coding Standards]] (rule 3 on volatile, rule 7 on assert versus check) ·
  [[06 - Architecture Overview]] (the initialisation order) ·
  [[14 - Debugging Playbook]] (what to do when the screen stays black)

Next: **[[Stage 1.2 - Rasterising a Bitmap Font]]**

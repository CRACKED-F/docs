# Phase 1 — Console & Logging

**Goal:** make the kernel talk, properly. You will draw pixels into a **linear
framebuffer**, rasterise a bitmap font into text, add scrolling and double buffering,
build a `kprintf`, and put a **log ring buffer** behind it so nothing is lost when
the screen scrolls or the machine crashes. Finally you will add **symbolised
backtraces**, so a panic names functions and line numbers instead of raw addresses.

Output is the tool you debug every later phase with. Build it well now.

> Prerequisite: [[Phase 0 - Overview|Phase 0]] complete (`make run` boots and serial
> works).

---

## Why there is no VGA text mode here

The classic first milestone is writing a character into the VGA text buffer at
physical `0xB8000`. **We do not do that, anywhere in this OS.**

UEFI firmware makes no guarantee that the display is left in a VGA-compatible mode,
and on modern machines it is not — there is no text buffer at all. Writing to
`0xB8000` on a UEFI-booted laptop produces nothing: no error, no output, a black
screen. That is a brutal thing to debug, because the *code is correct* and the
*platform* is wrong, and there is no feedback loop that leads to the answer.

Instead, Limine gives us a **linear framebuffer**: a base address, width, height,
pitch, and pixel format. We draw pixels, and text is "rasterise a bitmap font into
pixels."

Full reasoning: [[ADR-0004 - Framebuffer Console Not VGA Text]].

---

## Why this phase exists

After Phase 0 your only feedback is a line over serial. That is enough to know the
kernel booted and not much else. To debug interrupts, paging, or a scheduler you need
to print values, and you need to still have them after the screen has scrolled or the
kernel has died.

Three things this phase adds that the original plan did not have at all:

- **A log ring buffer with levels.** Output goes to a fixed in-memory buffer *first*,
  then to the console and serial. When a fault happens, the panic handler dumps the
  last N lines. Without this, the message that explained the crash has already
  scrolled away.
- **Double buffering.** Framebuffer memory is uncached and write-combining. *Reading*
  from it is catastrophically slow, and scrolling by reading-and-writing the
  framebuffer directly will make your console visibly crawl. Draw into normal RAM,
  flush once.
- **Symbolised backtraces.** A panic that says `heap_expand+0x8C
  (kernel/mm/heap.cpp:214)` is worth an hour each time, compared to one that says
  `0xFFFFFFFF80104A2C`.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 1.1 | Stage 1.1 - The Linear Framebuffer | Easy | A coloured rectangle — **your first pixel** |
| 1.2 | Stage 1.2 - Rasterising a Bitmap Font | Medium | Characters drawn from an 8x16 font |
| 1.3 | Stage 1.3 - A Console: Cursor, Colour, Scrolling | Medium | `print`, a tracked cursor, a scrolling screen |
| 1.4 | Stage 1.4 - Double Buffering | Medium | Flicker-free, fast redraws |
| 1.5 | Stage 1.5 - The Log Ring Buffer and Levels | Medium | `dmesg`-style history with severity levels |
| 1.6 | Stage 1.6 - kprintf | Medium | `kprintf("%d %x %s %p", ...)` |
| 1.7 | Stage 1.7 - Symbolised Backtraces | Hard | Panics that name functions and lines |

---

## Deliverable

`kprintf` prints formatted text to the framebuffer console **and** the serial log,
the screen scrolls without flicker, colours work, and the last 256 log lines are
retrievable after the fact. A deliberate panic prints a register dump plus a
backtrace with function names and source lines, and the recent log history.

That panic output is the single most valuable artefact in the project. Everything
from Phase 2 onward is debugged by reading it.

---

## The hard parts, named in advance

**Pitch is not width.** The framebuffer's `pitch` (bytes per scanline) is often
larger than `width * bytes_per_pixel`, because of hardware alignment. Computing a
pixel address as `y * width + x` produces a sheared image — a distinctive and
instantly recognisable bug once you have seen it.

**Never read from framebuffer memory.** It is uncached write-combining memory. Reads
are orders of magnitude slower than RAM. This is precisely why scrolling needs a back
buffer (Stage 1.4) rather than a `memmove` on the framebuffer itself.

**The font has to come from somewhere.** We embed a public-domain 8x16 VGA-style
bitmap font, converted to a C array at build time by `tools/mkfont`. No runtime font
parsing in v1.

**Log before console.** The ring buffer must accept messages even before the
framebuffer is initialised, so early-boot logging is not lost. It writes to memory
and to serial; the console attaches later and replays.

---

## Testing

| Tier | What |
|---|---|
| 1 | `kprintf` formatting — every specifier, width, precision, edge case, and `%p` on a 64-bit pointer. Ring-buffer wraparound. Font glyph lookup |
| 2 | Framebuffer writes land at the right offsets given a pitch that differs from width; scroll preserves content correctly |
| 3 | Boot and assert expected strings appear on serial in order |

`kprintf` is the ideal Tier-1 candidate: pure logic, enormous edge-case surface, and
a bug in it will mislead you about *every other* subsystem for years.

---

## Read before you start

- OSDev — *Drawing In a Linear Framebuffer*:
  <https://wiki.osdev.org/Drawing_In_a_Linear_Framebuffer>
- Limine protocol — the framebuffer request (pitch, bpp, red/green/blue mask
  positions): <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- OSDev — *Serial Ports*: <https://wiki.osdev.org/Serial_Ports>
- OSDev — *Stack Trace* (walking saved RBP for a backtrace):
  <https://wiki.osdev.org/Stack_Trace>
- OSDev — *PC Screen Font* (the bitmap font format): <https://wiki.osdev.org/PC_Screen_Font>

Previous: [[Phase 0 - Overview]] · Next: [[Phase 2 - Overview]]

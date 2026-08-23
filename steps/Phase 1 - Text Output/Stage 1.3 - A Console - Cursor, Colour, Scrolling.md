# Stage 1.3 — A Console: Cursor, Colour, Scrolling

**Difficulty:** Medium · ~75 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `kernel/include/kernel/console.hpp`, `kernel/drivers/char/console.cpp`
**Deliverable:** `console_write("...")` puts text on the framebuffer at a tracked cursor, honours `\n` `\t` `\r` `\b`, draws in 16 colours, wraps at the right-hand edge, and scrolls when the screen fills.

---

> [!warning] INCOMPLETE DRAFT
> This note was cut off mid-write when the writing session hit its API limit.
> It stops partway through §2 and is missing §3 tradeoffs, §5 the code
> walkthrough, §6 verification, and §7 traps. **Do not follow it as-is.**
> Everything present is correct; there is simply not enough of it yet.

## Progress

- [ ] Read §2 and convince yourself why the text lives in RAM and not in the framebuffer
- [ ] Create `kernel/include/kernel/console.hpp` with the `Colour` enum and the API
- [ ] Add `kernel/drivers/char/console.cpp` to the kernel source list in `kernel/CMakeLists.txt`
- [ ] Implement the grid, the palette table, and `draw_cell()`
- [ ] Implement `console_init()`, including the clamp-and-log path for oversized modes
- [ ] Implement `console_clear()` — clear the whole *surface*, not just the cells
- [ ] Implement `console_putc()` with `\n`, `\r`, `\t`, `\b` and the deferred wrap
- [ ] Implement `console_scroll()` and confirm the cursor moves up with the content
- [ ] Implement `console_write()` (both overloads) and `console_set_colour()`
- [ ] Write `memcpy`/`memmove`/`memset`/`memcmp` in `kernel/lib/string.cpp` if you have not already
- [ ] Call `console_init(info)` from `kernel_init()` after `fb_init(info)`
- [ ] Verify scrolling, wrapping, and every control character (§6)
- [ ] Boot at a second `resolution:` from `boot/limine.conf` and confirm the grid adapts
- [ ] Committed with a message like `feat(console): cursor, colour and scrolling over the framebuffer`

---

## 1. Why this stage exists

After [[Stage 1.2 - Rasterising a Bitmap Font]] you can draw a glyph at an arbitrary pixel coordinate. That is not a console. To print a message you must currently pick the pixel position yourself, count how many characters you have emitted, decide where the next one goes, and remember that the letter `M` is eight pixels wide. Every caller does that arithmetic, every caller gets it slightly wrong, and the moment two subsystems print at once they overwrite each other.

More importantly, you have no answer for the bottom of the screen. At 1280×800 with an 8×16 font you get fifty lines. Phase 2 alone prints more than fifty lines during IDT setup, and a page fault handler in Phase 4 will print more than fifty lines *by itself*. Without scrolling, everything after line fifty is drawn off the end of the framebuffer — either silently discarded by a bounds check in `fb_put_pixel`, or, if you skipped that bounds check, written past the end of the mapping into whatever the bootloader put next. The second failure mode is a triple fault that looks like it came from the subsystem you were debugging.

This stage converts "draw a glyph somewhere" into "print text". It introduces exactly one new idea — a **character grid held in normal RAM** that the framebuffer is a *rendering* of — and everything else in this stage falls out of that idea: the cursor is a position in the grid, scrolling is a shift of the grid, colour is an attribute stored per cell, and control characters are edits to the cursor.

The alternative, which is what almost every first-attempt console does, is to treat the framebuffer itself as the source of truth and scroll it with a `memmove`. That works, produces correct output, and makes your console **visibly crawl**. Understanding why is the single most valuable thing in this stage, and it is §3's first decision.

---

## 2. The concept

### A grid layered over a surface

The framebuffer is a rectangle of pixels: `fb_width` across, `fb_height` down. The font is a fixed 8×16 cell. Divide one by the other and the rectangle of pixels becomes a rectangle of **character cells**:

```
cols = fb_width  / FONT_WIDTH      // 1280 / 8  = 160
rows = fb_height / FONT_HEIGHT     // 800  / 16 = 50
```

Integer division, always rounding **down**. A partial cell is not a cell — there is nowhere to draw the bottom half of a glyph.

Cell `(col, row)` occupies the pixel rectangle whose top-left corner is:

```
x = col * FONT_WIDTH               // col * 8
y = row * FONT_HEIGHT              // row * 16
```

That is the whole mapping. It appears exactly once in the code, in `draw_cell()`, and nowhere else.

```
   pixel x →  0        8       16       24            1272   1279
             ┌────────┬────────┬────────┬── ... ──┬────────┐
 pixel y  0  │ (0,0)  │ (1,0)  │ (2,0)  │         │(159,0) │  row 0
             │  8x16  │        │        │         │        │
        16   ├────────┼────────┼────────┼── ... ──┼────────┤
             │ (0,1)  │ (1,1)  │        │         │        │  row 1
        32   ├────────┼────────┼── ... ─┴─────────┴────────┤
             ⋮                                              ⋮
       784   ├────────┬────────┬── ... ──┬────────┬────────┤
             │ (0,49) │        │         │        │(159,49)│  row 49
       799   └────────┴────────┴── ... ──┴────────┴────────┘
```

At 1280×800 the division is exact and every pixel belongs to some cell. That is not generally true. At 1366×768 — an extremely common laptop panel — `1366 / 8` is 170 with **6 pixels left over**, so there is a six-pixel-wide vertical strip down the right edge of the screen that no glyph will ever cover. At 800×600, `600 / 16` is 37 with **8 pixels left over** along the bottom. Those margin strips still contain whatever Limine's boot menu left there. Clearing the screen therefore means clearing the *surface*, not the cells.

### The cursor

The cursor is two integers, `(g_col, g_row)`. It is where the next printable character goes. Printing advances it. `\n` resets the column and advances the row. Reaching the last row and needing another one is the condition that triggers a scroll.

There is **no hardware cursor**. In VGA text mode the display hardware drew a blinking underline for you, positioned through I/O ports `0x3D4`/`0x3D5`. In a linear framebuffer no such thing exists — the hardware draws exactly the pixels you put there and nothing else. This stage tracks the cursor position but deliberately draws nothing for it: a visible cursor has to be erased before every write and repainted after, and a *blinking* one needs a timer that does not exist until Phase 3. Nothing reads keyboard input yet, so there is nothing for a cursor to indicate. It is added in Phase 8 with the shell, where it earns its cost.

### Why the text lives in RAM

Here is the load-bearing idea. Consider what scrolling requires: every row of pixels moves up sixteen pixels, and the bottom sixteen pixel rows are blanked. The obvious implementation moves the pixels:

```cpp
// The obvious implementation. Do not write this.
memmove(fb_base, fb_base + pitch * FONT_HEIGHT, pitch * (fb_height - FONT_HEIGHT));
```

`memmove` **reads** its source. The source is framebuffer memory, and framebuffer memory is not RAM. It is a window onto the display adapter, mapped **write-combining** — a memory type in which stores are buffered and coalesced into large burst transfers, but loads are not cached, not combined, and not prefetched. Every read is a separate uncached transaction that has to cross the system bus and wait for the adapter. Writes are cheap because the hardware is allowed to batch them; reads are expensive because it is not allowed to do anything at all.

The size makes it worse. At 1280×800×32 the framebuffer is about 4 MiB. Scrolling by `memmove` reads nearly all of it and writes nearly all of it, **per line of output**. The result is a console that takes a visible fraction of a second per scroll: a boot that prints two hundred lines spends most of its time scrolling, and the screen appears to crawl. This is not a subtle regression you discover with a profiler. You watch it happen.

So the console keeps its own copy:

```
        RAM (fast, readable)                    framebuffer (write-only, in practice)
   ┌──────────────────────────────┐            ┌──────────────────────────────┐
   │ g_grid[row][col]             │            │                              │
   │   { glyph, attribute }       │  render →  │        pixels                │
   │   36 KiB, .bss               │            │        ~4 MiB, WC            │
   └──────────────────────────────┘            └──────────────────────────────┘
         ↑ source of truth                            ↑ a rendering of it
         read and written freely                      only ever WRITTEN
```

Scrolling now means: shift rows in the grid (a RAM-to-RAM copy of 36 KiB — fast, and readable memory), blank the last grid row, then repaint every cell. The repaint writes about 4 MiB to the framebuffer and reads none of it. Writing 4 MiB to write-combining memory is not free, but it is the operation that memory type is *good* at, and it is roughly two orders of magnitude cheaper than reading the same bytes.

[[Stage 1.4 - Double Buffering]] closes the remaining gap by putting a normal-RAM back buffer between the grid and the framebuffer, at which point the scroll becomes a `memmove` in RAM plus a single flush. Note what does *not* change in Stage 1.4: the grid stays. It is the source of truth for the *text*, which is a different thing from the source of truth for the *pixels*.

There is a second, quieter reason to keep the grid, and it matters more than performance in the long run: with the text in RAM, anything that overdraws the screen is recoverable. A splash screen, a panic banner, Phase 15's diagnostic overlays — after any of them, one call to `redraw_all()` restores the console exactly. If the framebuffer were the only copy, overdrawing would destroy the text permanently.

---

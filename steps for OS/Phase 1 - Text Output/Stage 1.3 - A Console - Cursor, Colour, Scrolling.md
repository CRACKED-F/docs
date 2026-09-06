# Stage 1.3 — A Console: Cursor, Colour, Scrolling

**Difficulty:** Medium · ~75 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `kernel/include/kernel/console.hpp`, `kernel/drivers/char/console.cpp`
**Deliverable:** `console_write("...")` puts text on the framebuffer at a tracked cursor, honours `\n` `\t` `\r` `\b`, draws in 16 colours, wraps at the right-hand edge, and scrolls when the screen fills.

---

## Progress

- [ ] Read §2 and convince yourself why the text lives in RAM and not in the framebuffer
- [ ] Create `kernel/include/kernel/console.hpp` with the `ConsoleColour` enum, the limits, and the API
- [ ] Add `kernel/drivers/char/console.cpp` to the kernel source list in `kernel/CMakeLists.txt`
- [ ] Implement the grid, the palette table, and `draw_cell()`
- [ ] Implement `console_init()`, including the clamp-and-warn path for oversized modes
- [ ] Implement `console_clear()` — clear the whole *surface*, not just the cells
- [ ] Implement `console_putc()` with `\n`, `\r`, `\t`, `\b` and the deferred wrap
- [ ] Implement `console_scroll()` and confirm the cursor moves up with the content
- [ ] Implement `console_write()` (both overloads), `console_set_colour()` and `console_redraw()`
- [ ] Write `memcpy`/`memmove`/`memset`/`memcmp` in `kernel/lib/string.cpp` if you have not already
- [ ] Call `console_init()` from `kernel_init()` after `fb_init(info)`
- [ ] Verify scrolling, wrapping, and every control character (§6)
- [ ] Boot at a second `resolution:` from `boot/limine.conf` and confirm the grid adapts
- [ ] Force the clamp path with a small `CONSOLE_MAX_ROWS` and confirm it degrades instead of corrupting
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

There is a second, quieter reason to keep the grid, and it matters more than performance in the long run: with the text in RAM, anything that overdraws the screen is recoverable. A splash screen, a panic banner, Phase 15's diagnostic overlays — after any of them, one call to `console_redraw()` restores the console exactly. If the framebuffer were the only copy, overdrawing would destroy the text permanently.

### Colour is per cell, not global

If colour were a single global — "everything after this point is red" — then `console_redraw()` could not work. Repainting the screen would need to know what colour each *historical* cell was, and that information would be gone. So the colour travels with the character, in the cell, as one byte:

```
   attribute byte
   ┌───────┬───────┐
   │ 7 6 5 4 3 2 1 0
   │  bg   │  fg   │      bg = palette index 0..15 of the background
   └───────┴───────┘      fg = palette index 0..15 of the foreground
```

This is exactly the VGA text-mode attribute byte, and adopting its layout is not nostalgia — it is the smallest encoding that holds two 16-colour indices, and it makes a cell fit in two bytes with no padding.

The indices are **not** pixel values. A pixel value is whatever this adapter's masks require, and [[Stage 1.1 - The Linear Framebuffer]] already built `fb_pack_colour()` to produce one. The console holds sixteen packed `Colour`s in a table, built once at init from `fb_pack_colour()`. On an adapter that reports BGR instead of RGB, the table's contents differ and every call site is unchanged.

### The control characters the console owns

Four bytes do not mean "draw this glyph":

```
   \n  0x0A   line feed        col ← 0, row ← row+1  (scroll if that leaves the grid)
   \r  0x0D   carriage return  col ← 0
   \t  0x09   horizontal tab   advance to the NEXT multiple-of-8 column
   \b  0x08   backspace        step back one cell and blank it
```

The tab is the one people get wrong. A tab is not "add 8". It is "move to the next tab stop", where the stops are at columns 0, 8, 16, 24 … That is what makes columns line up:

```
   col:  0    5   8       16      24
         |    |   |       |       |
         name█fred        ← "name\tfred": tab at col 4 advances to col 8
         id  █42          ← "id\t42":     tab at col 2 advances to col 8
              ^ both land on column 8, so the second field is aligned

   with a fixed +8 you would instead get
         name    fred     ← col 4 + 8 = 12
         id  42           ← col 2 + 8 = 10       nothing lines up
```

Anything else — including the other control codes, `0x1B` among them — is drawn as its font glyph. A console that silently swallows bytes hides the bug that produced them.

### Deferred wrap

The last subtlety, and the one that separates a console that *looks* right from one that *is* right.

When a character is written into the final column, the naive thing to do is immediately move the cursor to column 0 of the next row. Then consider a line that is exactly `cols` characters long, followed by `\n`:

```
   eager wrap                            deferred wrap (chosen)
   ─────────────────────────────         ─────────────────────────────
   write 160 chars → cursor jumps        write 160 chars → cursor STAYS on
   to (0, next row)                      column 159, with a "wrap pending" flag
   then \n → another row advance         then \n → clears the flag, one advance

   ┌────────────────────────────┐        ┌────────────────────────────┐
   │AAAA ... 160 chars ... AAAA │        │AAAA ... 160 chars ... AAAA │
   │                            │ ← lost │BBBB ...                    │
   │BBBB ...                    │        │                            │
   └────────────────────────────┘        └────────────────────────────┘
        a spurious blank line                    no blank line
```

Every terminal since the VT100 has this flag — xterm calls it the "last column flag" — for exactly this reason. The rule is: **writing into the last column sets a flag instead of moving the cursor; the wrap happens when the next printable character arrives.** A `\n`, `\r` or `\b` arriving first cancels the flag instead.

The cost is one `bool` and three lines of code. The benefit is that a 160-character line and a 159-character line behave the same way, which is the property your log output relies on the first time a register dump is exactly as wide as the screen.

---

## 3. Design decisions and tradeoffs

### Decision: keep a character grid in RAM and redraw, or move pixels on scroll?

The central decision of the stage. Everything else follows from it.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — grid in RAM, repaint from it (chosen)** | `Cell g_grid[MAX_ROWS][MAX_COLS]` holds glyph + attribute. Scroll shifts rows in RAM, blanks the last row, repaints every cell | 36 KiB of `.bss`; a full-screen repaint (~4 MiB of writes) per scroll | ✅ |
| B — framebuffer is the only copy, `memmove` the pixels | Copy `pitch * (height - 16)` bytes up by one cell height, then fill the bottom strip | **Reads ~4 MiB of write-combining memory per scroll.** Visibly slow, and the text becomes unrecoverable after anything overdraws it | ❌ |
| C — grid in RAM, and scroll by `memmove`ing the pixels too | Keep the grid for recovery, but scroll with a pixel move for speed | Same catastrophic read; keeps the memory cost of A and the performance of B | ❌ |
| D — no scroll: stop printing at the bottom | Ignore output past the last row | Every kernel this side of Phase 2 prints more than a screenful. The information you need is always the part that was dropped | ❌ |

**Why A.** Two independent arguments, either of which would be sufficient.

*Performance.* §2 has the mechanism; here is the shape of it. A scroll under A performs a 36 KiB RAM-to-RAM copy plus about 4 MiB of framebuffer **writes**. A scroll under B performs about 4 MiB of framebuffer **reads** plus about 4 MiB of framebuffer writes. The writes cost the same in both. The difference is entirely the reads, and reads from write-combining memory are the single most expensive thing you can do to a framebuffer: no caching, no combining, no prefetch, a full bus round trip per access, hundreds of nanoseconds against roughly one for an L1 hit. A is not "a bit faster". It removes the expensive half of the operation.

*Recoverability, which outlives the performance argument.* Under A the text exists in two places, and the framebuffer copy is derived. Anything may draw over the screen — a splash bitmap, a panic banner, a Phase 15 overlay, a future graphics mode change — and one `console_redraw()` puts the console back, exactly, including scrollback that was already on screen. Under B the pixels *are* the text, so overdrawing destroys it permanently and the panic banner you drew to report a fault also erases the log lines that would have explained it.

That second property is why C is not a sensible compromise. C pays A's memory to keep the recovery guarantee, then throws away the performance reason for having paid it.

**Why not B — concretely.** Take the pinned mode from `boot/limine.conf`, 1280×800×32: `pitch` is 5120 bytes, so a scroll moves `5120 × (800 − 16)` = 4,014,080 bytes. Assume a conservative 100 ns per uncached read of a cache line and 64 bytes per line: that is roughly 62,700 lines, about **6 milliseconds of pure read stall per scrolled line**, before any writing. A boot that emits three hundred lines spends nearly two seconds inside the scroll routine. You do not measure this; you sit and watch the screen fill.

There is a second failure in B that is worse than slow. Reading framebuffer memory means `memmove` sees a source that is not ordinary memory, and if a future edit ever maps the framebuffer uncacheable rather than write-combining, the same code gets slower by another order of magnitude with no code change to blame.

**When B would be right.** When the surface you are scrolling is ordinary cached RAM. That is precisely what [[Stage 1.4 - Double Buffering]] creates: once every pixel lives in a normal-RAM back buffer, moving pixels *is* a `memmove` in RAM, and it is faster than repainting cell by cell. So Stage 1.4 will legitimately do the thing this stage forbids — because the memory it does it to is different memory. Note what does not change: the grid stays, because the grid is not there for speed. Do not delete it in 1.4.

---

### Decision: fixed static state, or dynamic allocation sized to the mode?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — fixed maxima in `.bss`, clamp at init (chosen)** | `Cell g_grid[CONSOLE_MAX_ROWS][CONSOLE_MAX_COLS]`; `console_init()` computes the live `cols`/`rows` and clamps them to the maxima | 36 KiB always resident, even at 640×480; a mode larger than the maxima loses its right/bottom margin | ✅ |
| B — `kmalloc(cols * rows * 2)` at init | Exactly the memory the mode needs | **There is no heap until [[Phase 4 - Overview\|Phase 4]].** Not a tradeoff — the function does not exist | ❌ |
| C — a fixed buffer, but no clamp | Same array, trust `fb_width/8` to fit | An oversized mode writes past the end of a `.bss` array with no IDT installed. Triple fault, or silent corruption of whatever `.bss` follows | ❌ |
| D — clamp by *refusing* to initialise | If the mode is bigger than the maxima, `console_init()` returns false | A perfectly usable 4K display gets a black screen because the console did not want to draw a smaller rectangle on it | ❌ |

**Why A.** B is not available and that settles it, but A would still be right if it were. The console is the debugging path. It must work before the allocator does — that is the whole dependency-ordering argument [[Stage 1.2 - Rasterising a Bitmap Font]] made for the embedded font, and it applies with more force here, because the first thing you will want to debug with this console *is* the allocator.

Choosing the maxima is arithmetic, not taste:

| Mode | cols × rows | Fits 256 × 72? | Left over |
|---|---|---|---|
| 640×480 | 80 × 30 | yes | 0 × 0 px |
| 800×600 | 100 × 37 | yes | 0 × 8 px |
| 1024×768 | 128 × 48 | yes | 0 × 0 px |
| **1280×800** (`boot/limine.conf`) | **160 × 50** | **yes** | 0 × 0 px |
| 1366×768 | 170 × 48 | yes | 6 × 0 px |
| 1920×1080 | 240 × 67 | yes | 0 × 8 px |
| 2048×1152 | 256 × 72 | exactly | 0 × 0 px |
| 1920×1200 | 240 × 75 | **rows clamp to 72** | bottom 48 px unused |
| 3840×2160 | 480 × 135 | **both clamp** | right 1792 px, bottom 1008 px unused |

256 × 72 × 2 bytes is 36,864 bytes — 36 KiB — and covers every mode up to 2048×1152 exactly, including the pinned 1280×800 with a factor of two in hand and every 1080p panel you are likely to boot on. If you routinely boot taller panels, raise `CONSOLE_MAX_ROWS` to 96 and pay 48 KiB; the cost is linear and no code changes.

**Why not C — the exact failure.** `fb_width / 8` on a 3840-wide panel is 480. Writing `g_grid[row][480]` into an array declared `[...][256]` is not a bounds error the compiler can see: it is a valid pointer computation into the *next row* of the array, and past the last row it is a valid pointer computation into whatever `.bss` object the linker placed next. So there is no fault at the moment of the bug. Instead some other subsystem's globals get overwritten with text, and you debug *that* subsystem. And when the row index finally runs off the end of the segment, the resulting page fault is a **triple fault** — there is no IDT until [[Phase 2 - Overview|Phase 2]] — so the machine reboots instantly with no message, at whichever point in the boot happened to reach it.

The clamp is three lines. Write them.

**When B would be right.** After [[Phase 4 - Overview|Phase 4]], for a console whose geometry can change at runtime — a mode switch, a resize, a second head. At that point `console_init()` grows an allocation and a reallocation path, and it must still keep a static fallback grid for the window in which the allocator itself is broken. The static grid never goes away; it stops being the only option.

---

### Decision: does the console interpret control characters, or does the caller?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — the console owns `\n \r \t \b` (chosen)** | `console_putc()` switches on the byte; every caller gets identical behaviour | One `switch` in one file; callers cannot opt out of the interpretation | ✅ |
| B — callers position the cursor themselves | `console_write()` draws glyphs only; a caller wanting a new line calls `console_newline()` | Every caller reimplements line handling, and each gets the tab stops slightly different. A string literal `"...\n"` silently draws a glyph | ❌ |
| C — a full ANSI/ECMA-48 escape parser | `\x1b[2J`, `\x1b[31m`, cursor addressing | A state machine, a parameter buffer, and an unbounded input surface, in the one code path that must never fail. Buys nothing until there is a shell | ❌ |

**Why A.** The rule is that the console is the only thing that knows what a line is. The instant that knowledge is duplicated, it diverges: one caller resets the column on `\n` and another does not, and the output staircases for half the kernel. Owning it also means every future writer — `kprintf` in [[Stage 1.6 - kprintf]], the log sink in [[Stage 1.5 - The Log Ring Buffer and Levels]], the panic handler in [[Stage 0.7 - Panic and KASSERT]] — inherits correct behaviour by writing a plain C string.

The exact semantics matter more than the choice, so they are pinned down in §4. Three of them are worth arguing here.

*`\n` does the job of both LF and CR.* ECMA-48 says line feed advances the line and leaves the column alone; carriage return resets the column. A strict reading would mean `"a\nb"` draws `b` in column 1 of the next row, and a log of a hundred lines walks diagonally off the right edge. Every caller in this kernel writes `"...\n"` and means "end of line", so `\n` does both. `\r` remains available for the one thing it is actually useful for: rewriting the current line in place.

*`\t` advances to the next multiple-of-8 column, not by 8.* A fixed `+8` produces output that is *almost* aligned, which is worse than obviously misaligned because you stop noticing it. The console emits spaces up to the stop rather than merely moving, so the cells it passes over are genuinely blank and wrapping and scrolling are handled by the same code path as every other character. It clamps at the right margin instead of wrapping — a tab is a within-line operation.

*`\b` erases.* See below.

**Why not B.** The concrete failure is that `"\n"` inside a string literal is invisible at the call site. Under B it renders as glyph 0x0A — a CP437 note symbol — in the middle of your message, and the line keeps going. You will not read that as "the console does not handle newlines"; you will read it as a font bug and go and look at the rasteriser.

**Why not C.** Escape sequences buy cursor addressing and colour changes *in the byte stream*, which matters when the writer and the console are separated by a pipe. Here they are separated by a function call: `console_set_colour()` is more direct, cannot be malformed, and cannot be split across two writes. A parser also adds a failure mode to a component whose value is that it has none — a half-consumed escape sequence swallows the next twenty characters of a panic message.

**When C would be right.** When the console has a client it does not link against: a userspace shell in [[Phase 8 - Overview|Phase 8]] writing to `/dev/tty`, or a serial terminal on the other end of a wire. Then the escape sequence is the only channel and a parser becomes mandatory. It belongs on top of this console, in the tty layer, not inside it.

---

### Decision: a `ConsoleColour` enum, or raw 32-bit values at call sites?

Note the name. `Colour` is already taken — [[Stage 1.1 - The Linear Framebuffer]] uses it for a pixel value packed into *this* framebuffer's layout. The two are genuinely different types: one is an index into a palette, one is a hardware-specific bit pattern. Reusing the name would be a redefinition error, and the fact that the language stops you is a hint that you were about to conflate two things.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A — `enum class ConsoleColour : uint8_t`, packed to `Colour` at init (chosen)** | 16 enumerators; `console_init()` runs each through `fb_pack_colour()` into `g_palette[16]` | 64 bytes of `.bss`; callers cannot express a colour outside the 16 | ✅ |
| B — callers pass `uint32_t` pixel values | `console_write_coloured(s, 0x00FF0000)` | Correct on QEMU's 8:8:8, wrong on a BGR adapter — as *wrong colours*, never as a crash. And it does not fit in an attribute byte | ❌ |
| C — plain `enum` or `#define`s | `RED`, `BLUE` … as ints | No type safety: `console_set_colour(3, 7)` compiles, and so does passing a row index | ❌ |
| D — a full RGB triple per cell | Store 3 bytes of colour in each cell | Quadruples the grid to over 100 KiB and buys nothing a kernel log needs | ❌ |

**Why A.** The enum is a palette index; `fb_pack_colour()` is the only thing that knows how to turn one into pixels, and it does so from the masks the bootloader reported. Pack once, at init, into a sixteen-entry table. Every subsequent lookup is an array subscript, the call sites never see a pixel format, and the *same source* renders correctly on an RGB adapter, a BGR adapter and a 5:6:5 panel.

`enum class` rather than plain `enum` because it does not implicitly convert to `int`. In a file where `uint32_t col`, `uint32_t row` and a colour index are all small integers, that conversion is exactly the accident you want the compiler to reject.

Sixteen colours, not more, because the attribute must fit in a byte alongside the background, and because kernel log colour is a three-way distinction — normal, warning, error — with room to spare. [[Stage 1.5 - The Log Ring Buffer and Levels]] uses about five of them.

**Why not B — the exact failure.** `0x00FF0000` is red on an adapter that reports red at shift 16, and blue on one that reports it at shift 0. Both adapters exist; QEMU is the first kind, so the bug is invisible on your development machine and appears on the first real laptop, months later, as "the colours are swapped". You will then swap your constants, which fixes that machine and breaks QEMU, and now the code is wrong in two places in a way that cancels out in one configuration. This is the same argument [[Stage 1.1 - The Linear Framebuffer]] makes for reading the masks; the enum is what stops the raw literal reaching the call site in the first place.

**Why not D.** A 24-bit colour per cell would make the grid `256 × 72 × 7` bytes if you kept fg and bg, and every cell would carry information no kernel log has ever needed. The cheaper version of the same idea — allow arbitrary colours but only for the *current* attribute, not per cell — breaks `console_redraw()`, which is the thing the grid exists for.

**When B or D would be right.** A graphical console with themes, syntax highlighting, or images — a Phase 15 concern, in a compositor, where colour is content rather than a severity marker. At that point the cell stops being two bytes and the console stops being the debugging path.

---

## 4. Specification

### Grid geometry

| Quantity | Expression | at 1280×800 | at 1024×768 |
|---|---|---|---|
| `cols` | `fb_width / FONT_WIDTH`, truncating | 160 | 128 |
| `rows` | `fb_height / FONT_HEIGHT`, truncating | 50 | 48 |
| pixel `x` of column `c` | `c * FONT_WIDTH` | | |
| pixel `y` of row `r` | `r * FONT_HEIGHT` | | |
| right margin, unused | `fb_width - cols * FONT_WIDTH` | 0 px | 0 px |
| bottom margin, unused | `fb_height - rows * FONT_HEIGHT` | 0 px | 0 px |

Valid indices are `0 <= col < cols` and `0 <= row < rows`. The margins are inside the framebuffer and are painted once, by `console_clear()`, and never again.

### Static budget

| Object | Type | Size | Section |
|---|---|---|---|
| `g_grid` | `Cell[72][256]` | 36,864 B (36 KiB) | `.bss` |
| `g_palette` | `Colour[16]` | 64 B | `.bss` |
| `PALETTE_RGB` | `const Rgb[16]` | 48 B | `.rodata` |
| cursor + geometry + flags | 4 × `uint32_t`, 1 × `uint8_t`, 2 × `bool` | 20 B | `.bss` |

Nothing here has a constructor, so nothing needs `.init_array` — which nothing walks until [[Phase 4 - Overview|Phase 4]]. Rule 9 of [[13 - Coding Standards]].

### The cell

```
   struct Cell {  uint8_t ch;    uint8_t attr;  };      // exactly 2 bytes
                     │                │
                     │                └── 7654 3210
                     │                    bbbb ffff   bg index, fg index
                     └── font glyph index 0..255, CP437 above 0x7F
```

`sizeof(Cell) == 2` is asserted at compile time. The grid's `memmove` stride and the 36 KiB budget both assume it.

### The palette

| Index | `ConsoleColour` | R,G,B | Index | `ConsoleColour` | R,G,B |
|---|---|---|---|---|---|
| 0 | `Black` | 00,00,00 | 8 | `DarkGrey` | 55,55,55 |
| 1 | `Blue` | 00,00,AA | 9 | `LightBlue` | 55,55,FF |
| 2 | `Green` | 00,AA,00 | 10 | `LightGreen` | 55,FF,55 |
| 3 | `Cyan` | 00,AA,AA | 11 | `LightCyan` | 55,FF,FF |
| 4 | `Red` | AA,00,00 | 12 | `LightRed` | FF,55,55 |
| 5 | `Magenta` | AA,00,AA | 13 | `LightMagenta` | FF,55,FF |
| 6 | `Brown` | AA,55,00 | 14 | `Yellow` | FF,FF,55 |
| 7 | `LightGrey` | AA,AA,AA | 15 | `White` | FF,FF,FF |

The IBM CGA/VGA 16. Index 7 on 0 is the default: light grey on black, not white on black, so that `White` stays available as an emphasis colour.

Each triple is passed through `fb_pack_colour(r, g, b)` **once**, in `console_init()`. The stored `Colour` values are only valid for the mode `fb_init()` accepted.

### Control characters

| Byte | Escape | Console does | Cursor after | Cells changed |
|---|---|---|---|---|
| `0x08` | `\b` | Cancel a pending wrap, else step left one column; then blank that cell. At column 0 with no pending wrap: nothing | one left, floor 0 | 1 |
| `0x09` | `\t` | Emit spaces until `col % 8 == 0`, stopping at the right margin | next multiple of 8, or the last column | 1–8 |
| `0x0A` | `\n` | Clear pending wrap; `col ← 0`; `row ← row + 1`, scrolling if that leaves the grid | column 0 of the next row | 0 |
| `0x0D` | `\r` | Clear pending wrap; `col ← 0` | column 0 of the same row | 0 |
| anything else | — | Draw `font_glyph((unsigned char)c)` at the cursor with the current attribute | one right, or pending wrap | 1 |

### Tab, worked

With `CONSOLE_TAB_WIDTH = 8` and `cols = 160`:

| col before | next stop | spaces written | col after | wrap pending after |
|---|---|---|---|---|
| 0 | 8 | 8 | 8 | no |
| 1 | 8 | 7 | 8 | no |
| 7 | 8 | 1 | 8 | no |
| 8 | 16 | 8 | 16 | no |
| 13 | 16 | 3 | 16 | no |
| 155 | 160 — off the grid | 5 (cols 155–159) | 159 | **yes** |

The last row is the clamp: a tab never wraps by itself. It fills to the right margin and leaves the wrap to the next printable character.

### Cursor invariants

These hold on entry to and exit from every public function once `console_ready()` is true.

| Invariant | Why it matters |
|---|---|
| `0 <= g_col < g_cols` | The grid subscript is in bounds by construction; no bounds check needed in `draw_cell()` |
| `0 <= g_row < g_rows` | Same, and `g_rows <= CONSOLE_MAX_ROWS` was established by the clamp |
| `g_wrap_pending` implies `g_col == g_cols - 1` | The flag means "the last column is written", not "the cursor is off-screen" |
| `g_cols <= CONSOLE_MAX_COLS && g_rows <= CONSOLE_MAX_ROWS` | Established once, in `console_init()`, and never recomputed |

### What Stages 1.1 and 1.2 must already provide

| Symbol | Declared in | Signature this stage assumes |
|---|---|---|
| `Colour` | `kernel/include/kernel/framebuffer.hpp` | `struct Colour { uint32_t value; };` |
| `fb_ready()` | same | `bool fb_ready()` |
| `fb_info()` | same | `FramebufferInfo fb_info()` → `{width, height, pitch, bytes_per_pixel}` |
| `fb_pack_colour()` | same | `Colour fb_pack_colour(uint8_t r, uint8_t g, uint8_t b)` |
| `fb_clear()` | same | `void fb_clear(Colour c)` |
| `fb_putchar()` | same, added by Stage 1.2 | `void fb_putchar(char c, uint32_t x, uint32_t y, Colour fg, Colour bg)` |
| `FONT_WIDTH`, `FONT_HEIGHT` | `kernel/drivers/char/font.hpp` | `inline constexpr uint32_t`, 8 and 16 |

> **Two names to reconcile before you start.** The prose in [[Stage 1.2 - Rasterising a Bitmap Font]] refers to the framebuffer header as `fbcon.hpp` in places and declares `fb_putchar` with `uint32_t fg, uint32_t bg`; [[Stage 1.1 - The Linear Framebuffer]] created the header as `kernel/include/kernel/framebuffer.hpp` and introduced `struct Colour`. It is one header and one colour type. Settle on Stage 1.1's — change `fb_putchar`'s two colour parameters to `Colour`, which is a one-word edit because `Colour` is a trivial wrapper — and use the path you actually created. If you prefer to leave `fb_putchar` taking `uint32_t`, pass `fg.value` and `bg.value` in `draw_cell()` below and nothing else in this stage changes.

### Initialisation order

| Step | Call | Notes |
|---|---|---|
| 1 | `serial_init()` | [[Stage 0.6 - Serial Output]] — the channel that reports this stage's own failures |
| 5 | `fb_init(info)` | [[Stage 1.1 - The Linear Framebuffer]] — validates and stores the geometry |
| **6** | **`console_init()`** | **This stage. Takes no arguments** |
| 6b | `log_register_sink(&console_log_sink)` | [[Stage 1.5 - The Log Ring Buffer and Levels]] — the last two lines of `console_init()` |

---

## 5. Writing the code

Two files. The header first.

### `kernel/include/kernel/console.hpp`

The public face of the text console: sixteen colours, the static limits, and nine calls. Note what is *absent* — no `Colour`, no `FramebufferInfo`, no `BootInfo`. A caller of `console_write()` should not have to know that pixels exist.

```cpp
// kernel/include/kernel/console.hpp
//
// The kernel's text console: a character grid laid over the linear
// framebuffer. cols = fb_width/8, rows = fb_height/16, and cell (col, row) is
// drawn at pixel (col*8, row*16).
//
// The grid is the source of truth for the text; the framebuffer is a rendering
// of it. That is why console_redraw() can put the console back after anything
// has drawn over the screen. See Stage 1.3 section 3.
//
// Stage 1.4 changes where the pixels land, not this interface.
// Stage 1.5 registers console_log_sink() at the end of console_init().

#pragma once

#include <stddef.h>
#include <stdint.h>

// The IBM CGA/VGA 16-colour palette, by INDEX. These are not pixel values:
// console_init() runs each one through fb_pack_colour(), so the same
// enumerator produces the right pixel on an RGB adapter and on a BGR one.
//
// The name is ConsoleColour, not Colour, because Stage 1.1 already uses
// `Colour` for a pixel value packed into this framebuffer's layout. A palette
// index and a packed pixel are different things and must not be interchanged.
enum class ConsoleColour : uint8_t {
    Black        = 0,
    Blue         = 1,
    Green        = 2,
    Cyan         = 3,
    Red          = 4,
    Magenta      = 5,
    Brown        = 6,
    LightGrey    = 7,
    DarkGrey     = 8,
    LightBlue    = 9,
    LightGreen   = 10,
    LightCyan    = 11,
    LightRed     = 12,
    LightMagenta = 13,
    Yellow       = 14,
    White        = 15,
};

// The largest grid the statically allocated backing store can hold. There is
// no heap until Phase 4, so these are compile-time limits, and a mode larger
// than this is CLAMPED — the extra pixels go unused — never overflowed.
//
//   256 x 72 cells x 2 bytes = 36 KiB of .bss.
//   Covers every mode up to 2048x1152, which includes 1920x1080.
inline constexpr uint32_t CONSOLE_MAX_COLS = 256;
inline constexpr uint32_t CONSOLE_MAX_ROWS = 72;

// Tab stops sit at columns 0, 8, 16, ... A tab advances to the NEXT stop,
// which is not the same thing as advancing by 8.
inline constexpr uint32_t CONSOLE_TAB_WIDTH = 8;

inline constexpr ConsoleColour CONSOLE_DEFAULT_FG = ConsoleColour::LightGrey;
inline constexpr ConsoleColour CONSOLE_DEFAULT_BG = ConsoleColour::Black;

// One cell's colours packed into a byte: high nibble background, low nibble
// foreground. The VGA text-mode attribute layout, kept because it is the
// smallest encoding of two 16-colour indices.
[[nodiscard]] inline constexpr uint8_t console_attr(ConsoleColour fg,
                                                    ConsoleColour bg) {
    return static_cast<uint8_t>((static_cast<uint8_t>(bg) << 4) |
                                 static_cast<uint8_t>(fg));
}

// Step 6 of the initialisation order in 06 - Architecture Overview. Call AFTER
// fb_init(). Takes no BootInfo: the geometry it needs was validated and stored
// by fb_init() and is reachable through fb_info().
bool console_init();

[[nodiscard]] bool     console_ready();
[[nodiscard]] uint32_t console_cols();
[[nodiscard]] uint32_t console_rows();

// One byte. Interprets \n, \r, \t and \b; every other value is drawn as its
// font glyph, including the remaining control codes.
void console_putc(char c);

// NUL-terminated, and the length form. The length form is not a convenience:
// a log ring slot is a slice of a fixed-width buffer and is not terminated.
void console_write(const char* s);
void console_write(const char* s, size_t len);

// Applies to cells written from now on. Does not repaint what is already on
// screen — each cell keeps the attribute it was written with.
void console_set_colour(ConsoleColour fg, ConsoleColour bg);

// Blanks every cell, homes the cursor, and clears the whole SURFACE, including
// the margin strips outside the grid.
void console_clear();

// Shifts the grid up by one row, blanks the vacated last row, repaints. The
// cursor moves up with its content.
void console_scroll();

// Repaints every cell from the grid. Call after anything has drawn over the
// console — a splash screen, a panic banner, a Phase 15 overlay.
void console_redraw();
```

#### Line by line

**The banner and `#pragma once`**

Rule 10 of [[13 - Coding Standards]]: comments explain why. The two "why"s a reader needs here are *what the grid is for* (recovery, not just speed) and *what is going to happen to this file* — Stage 1.4 keeps the interface and changes the destination, Stage 1.5 appends two lines to `console_init()`. Without the second note, someone will "simplify" `console_redraw()` away as dead code, because nothing calls it yet.

**The includes**
```cpp
#include <stddef.h>
#include <stdint.h>
```
`<stdint.h>` and `<stddef.h>`, **never** `<cstdint>`. The toolchain image does not build libstdc++ and kernel translation units compile `-nostdinc++`; `#include <cstdint>` is `fatal error: cstdint: No such file or directory`. GCC's freestanding C headers are built into the compiler and are always available. See [[ADR-0007 - Freestanding C++20 as the Kernel Language]]. `<stddef.h>` is for `size_t` in the length overload.

No `framebuffer.hpp`. Nothing in this header names a framebuffer type, and leaving it out is what makes the layering claim in the banner true rather than aspirational — a caller literally cannot reach the pixels through this file.

**The enum**
```cpp
enum class ConsoleColour : uint8_t { Black = 0, ..., White = 15 };
```
`enum class`, so it does not implicitly convert to `int`. In a file where a column index, a row index and a colour are all small unsigned integers, that implicit conversion is precisely the mistake you want rejected at compile time: `console_set_colour(row, col)` must not compile.

`: uint8_t` fixes the underlying type. Without it the underlying type is implementation-defined (`int` in practice), `sizeof` grows, and `static_cast<uint8_t>` in `console_attr` becomes a narrowing conversion the reader has to reason about.

The values are written out explicitly rather than left implicit. They are not arbitrary — they are the CP437/VGA palette order, and they are also the indices into `g_palette` and the nibble values in the attribute byte. Three things agree on these numbers; write them down.

**The limits**
```cpp
inline constexpr uint32_t CONSOLE_MAX_COLS = 256;
inline constexpr uint32_t CONSOLE_MAX_ROWS = 72;
```
`inline constexpr` at namespace scope: one entity shared by every translation unit, no storage emitted, no one-definition-rule violation. `uint32_t` rather than `int` so that every comparison against `g_cols`, `g_col` and `fb_width` is unsigned throughout — mixing a signed constant into those comparisons is a `-Wsign-compare` warning, and `-Werror` makes it a build failure.

They live in the **header**, not the `.cpp`, for one specific reason: §6 has you set `CONSOLE_MAX_ROWS` to 20 temporarily to force the clamp path, and a test that wants to reason about the limits needs to see them.

**`console_attr`**
```cpp
[[nodiscard]] inline constexpr uint8_t console_attr(ConsoleColour fg, ConsoleColour bg) {
    return static_cast<uint8_t>((static_cast<uint8_t>(bg) << 4) |
                                 static_cast<uint8_t>(fg));
}
```
The single definition of the attribute layout. It is `constexpr`, so `console_attr(ConsoleColour::LightGrey, ConsoleColour::Black)` is a compile-time `0x07` and can initialise a constant.

Note the outer `static_cast<uint8_t>`. `static_cast<uint8_t>(bg) << 4` promotes to `int` before shifting — integral promotion, unavoidable — so the expression's type is `int` and returning it directly is a narrowing conversion that `-Wconversion` would object to. The cast states the intent instead of hoping the warning stays off.

`bg` in the **high** nibble. The order is arbitrary in isolation but it is not arbitrary here: it is the VGA text-mode attribute byte, which means anyone who has met a `0x0F`-on-`0x00` attribute before reads this correctly on sight.

**The API block**

`console_init()` returns `bool` but is deliberately **not** `[[nodiscard]]`, for exactly the reason [[Stage 1.1 - The Linear Framebuffer]] gives for `fb_init`: with `-Werror`, `[[nodiscard]]` forces every caller to consume the value, and the only sensible thing `kernel_init` can do with it is carry on regardless — meaning an empty `if` written to silence a warning. The answer is available through `console_ready()`, which *is* `[[nodiscard]]`, because discarding *that* is always a bug.

The `console_` prefix is not decoration. This kernel has no namespaces below the top level ([[13 - Coding Standards]]), so `clear()` and `init()` at global scope would collide with the next subsystem. Same rule that gives Stage 1.1 its `fb_` and Phase 0 its `serial_`.

Two `console_write` overloads. The length form exists because [[Stage 1.5 - The Log Ring Buffer and Levels]] defines a sink as `void (*)(LogLevel, const char* text, size_t len)` where `text` is a slice of a fixed-width ring slot and is **not** NUL-terminated. Without this overload the sink would have to copy into a scratch buffer first, in the one code path whose value is that it allocates nothing.

---

### `kernel/drivers/char/console.cpp`

The console. `drivers/char/` because it sits beside `serial.cpp` and `fbcon.cpp` — all three are character output devices ([[07 - Repository Layout]]).

```cpp
// kernel/drivers/char/console.cpp
//
// The text console. Three rules live in this file:
//
//   1. The GRID is the source of truth for the text; the framebuffer is a
//      rendering of it. Never read pixels back to work out what is on screen —
//      framebuffer memory is uncached write-combining and a read costs
//      hundreds of nanoseconds. This is why scrolling repaints instead of
//      moving pixels. See Stage 1.3 section 3.
//   2. The grid's row stride is CONSOLE_MAX_COLS, not g_cols. It is the exact
//      analogue of `pitch` in fbcon.cpp, and getting it wrong shears the text
//      the same way a wrong pitch shears an image.
//   3. draw_cell() holds the ONLY grid-to-pixel arithmetic in the kernel.
//      Every path that changes a cell goes through it.

#include "kernel/console.hpp"

#include "kernel/framebuffer.hpp"
#include "kernel/serial.hpp"
#include "kernel/string.hpp"   // memmove — use whatever header name you gave
                               // kernel/lib/string.cpp

#include "font.hpp"            // FONT_WIDTH, FONT_HEIGHT — beside this file

#include <stddef.h>
#include <stdint.h>

namespace {

// One character cell. Two parallel arrays — a glyph grid and an attribute
// array — would behave identically; interleaving them means one index reaches
// both, and they can never disagree about their dimensions.
struct Cell {
    uint8_t ch;    // font glyph index 0..255. NOT a signed char.
    uint8_t attr;  // high nibble = background index, low = foreground
};

static_assert(sizeof(Cell) == 2,
              "Cell must not be padded: the 36 KiB budget and the memmove "
              "stride in console_scroll() both assume two bytes");

// 72 * 256 * 2 = 36864 bytes of .bss. Fixed, because there is no heap until
// Phase 4. Indexed [row][col] — that order, everywhere, without exception.
Cell g_grid[CONSOLE_MAX_ROWS][CONSOLE_MAX_COLS];

uint32_t g_cols;          // live grid width,  <= CONSOLE_MAX_COLS
uint32_t g_rows;          // live grid height, <= CONSOLE_MAX_ROWS
uint32_t g_col;           // cursor column, 0 .. g_cols-1
uint32_t g_row;           // cursor row,    0 .. g_rows-1
uint8_t  g_attr;          // attribute stamped into newly written cells
bool     g_wrap_pending;  // last column written; wrap before the NEXT glyph
bool     g_ready;

inline constexpr uint32_t CONSOLE_COLOURS = 16;

// The IBM CGA/VGA palette as 8-bit RGB triples. These are NOT pixel values —
// fb_pack_colour() turns each into whatever this adapter's masks require,
// once, in console_init().
struct Rgb {
    uint8_t r, g, b;
};

constexpr Rgb PALETTE_RGB[CONSOLE_COLOURS] = {
    {0x00, 0x00, 0x00},  //  0 Black
    {0x00, 0x00, 0xAA},  //  1 Blue
    {0x00, 0xAA, 0x00},  //  2 Green
    {0x00, 0xAA, 0xAA},  //  3 Cyan
    {0xAA, 0x00, 0x00},  //  4 Red
    {0xAA, 0x00, 0xAA},  //  5 Magenta
    {0xAA, 0x55, 0x00},  //  6 Brown
    {0xAA, 0xAA, 0xAA},  //  7 LightGrey
    {0x55, 0x55, 0x55},  //  8 DarkGrey
    {0x55, 0x55, 0xFF},  //  9 LightBlue
    {0x55, 0xFF, 0x55},  // 10 LightGreen
    {0x55, 0xFF, 0xFF},  // 11 LightCyan
    {0xFF, 0x55, 0x55},  // 12 LightRed
    {0xFF, 0x55, 0xFF},  // 13 LightMagenta
    {0xFF, 0xFF, 0x55},  // 14 Yellow
    {0xFF, 0xFF, 0xFF},  // 15 White
};

// Packed once at init, indexed by ConsoleColour. .bss: no constructor.
Colour g_palette[CONSOLE_COLOURS];

// ---- grid -> pixels -------------------------------------------------------

// THE mapping of this stage, and the only place it appears. Cell (col, row)
// occupies the 8x16 pixel rectangle at (col*8, row*16).
//
// No bounds check: the nibble masks make both palette lookups provably in
// range, and every caller respects the cursor invariants in section 4.
void draw_cell(uint32_t col, uint32_t row) {
    const Cell cell = g_grid[row][col];

    fb_putchar(static_cast<char>(cell.ch),
               col * FONT_WIDTH,
               row * FONT_HEIGHT,
               g_palette[cell.attr & 0x0FU],
               g_palette[(cell.attr >> 4) & 0x0FU]);
}

// Every live cell, top-left to bottom-right. ~4 MiB of framebuffer WRITES at
// 1280x800 and zero reads.
void redraw_all() {
    for (uint32_t row = 0; row < g_rows; ++row) {
        for (uint32_t col = 0; col < g_cols; ++col) {
            draw_cell(col, row);
        }
    }
}

// Blanks the grid row only. Does not draw: every caller either repaints the
// whole screen afterwards or is about to clear the surface.
void blank_row(uint32_t row) {
    for (uint32_t col = 0; col < g_cols; ++col) {
        g_grid[row][col].ch   = ' ';
        g_grid[row][col].attr = g_attr;
    }
}

// ---- cursor ---------------------------------------------------------------

// Move down one row, scrolling if that would leave the grid. console_scroll()
// puts the cursor back on the last row, so there is no clamp here.
void newline_row() {
    ++g_row;
    if (g_row >= g_rows) {
        console_scroll();
    }
}

// Deferred wrap: writing the last column set a flag instead of moving the
// cursor. This is where the move finally happens.
void flush_pending_wrap() {
    if (!g_wrap_pending) {
        return;
    }
    g_wrap_pending = false;
    g_col = 0;
    newline_row();
}

void put_printable(char c) {
    flush_pending_wrap();

    Cell& cell = g_grid[g_row][g_col];
    cell.ch    = static_cast<uint8_t>(c);
    cell.attr  = g_attr;
    draw_cell(g_col, g_row);

    if (g_col + 1 >= g_cols) {
        g_wrap_pending = true;   // stay put; wrap when the next glyph arrives
    } else {
        ++g_col;
    }
}

void do_backspace() {
    if (g_wrap_pending) {
        g_wrap_pending = false;  // cursor already sits on the cell to erase
    } else if (g_col > 0) {
        --g_col;
    } else {
        return;                  // column 0: nothing here to erase
    }

    g_grid[g_row][g_col].ch   = ' ';
    g_grid[g_row][g_col].attr = g_attr;
    draw_cell(g_col, g_row);
}

void do_tab() {
    // Advance to the next multiple-of-8 column by writing spaces, so the cells
    // passed over are genuinely blanked and wrapping and scrolling are handled
    // by exactly the code that handles them for every other character. Stops
    // at the right margin: a tab never wraps by itself.
    do {
        put_printable(' ');
    } while ((g_col % CONSOLE_TAB_WIDTH) != 0 && !g_wrap_pending);
}

}  // namespace

// ---- public API -----------------------------------------------------------

bool console_init() {
    g_ready = false;

    // fb_init() has already run and either accepted a framebuffer or not.
    // A headless machine is a legitimate machine; serial still works.
    if (!fb_ready()) {
        serial_puts("console: no framebuffer; console disabled\n");
        return false;
    }

    const FramebufferInfo fb = fb_info();

    // Truncating division. A partial cell is not a cell.
    uint32_t cols = fb.width  / FONT_WIDTH;
    uint32_t rows = fb.height / FONT_HEIGHT;

    if (cols == 0 || rows == 0) {
        serial_puts("console: framebuffer smaller than one character cell\n");
        return false;
    }

    // CLAMP, never overflow. g_grid is dimensioned by the maxima, and there is
    // no IDT yet, so an out-of-range row index is a triple fault at best.
    bool clamped = false;
    if (cols > CONSOLE_MAX_COLS) {
        cols    = CONSOLE_MAX_COLS;
        clamped = true;
    }
    if (rows > CONSOLE_MAX_ROWS) {
        rows    = CONSOLE_MAX_ROWS;
        clamped = true;
    }

    g_cols = cols;
    g_rows = rows;

    // Pack the palette ONCE, from the masks the bootloader reported. This is
    // what makes the same ConsoleColour correct on an RGB and a BGR adapter.
    for (uint32_t i = 0; i < CONSOLE_COLOURS; ++i) {
        g_palette[i] = fb_pack_colour(PALETTE_RGB[i].r,
                                      PALETTE_RGB[i].g,
                                      PALETTE_RGB[i].b);
    }

    g_attr  = console_attr(CONSOLE_DEFAULT_FG, CONSOLE_DEFAULT_BG);
    g_ready = true;

    // Blanks the grid AND paints the whole surface, so Limine's boot menu is
    // gone from the margin strips too.
    console_clear();

    serial_puts("console: ");
    serial_write_dec(g_cols);
    serial_putc('x');
    serial_write_dec(g_rows);
    serial_puts(" cells from ");
    serial_write_dec(fb.width);
    serial_putc('x');
    serial_write_dec(fb.height);
    serial_puts(" px, margin ");
    serial_write_dec(fb.width  - g_cols * FONT_WIDTH);
    serial_putc('x');
    serial_write_dec(fb.height - g_rows * FONT_HEIGHT);
    serial_puts(" px\n");

    if (clamped) {
        serial_puts("console: WARNING mode exceeds CONSOLE_MAX_COLS/ROWS; "
                    "part of the screen is unused\n");
    }

    // --- Stage 1.5 hook ----------------------------------------------------
    // The log ring does not exist yet. When it does, these two lines go HERE,
    // at the very end of console_init(), and the entire boot history appears
    // on screen the instant the console can draw. Registration replays the
    // ring immediately, so it must come after console_clear() and after
    // g_ready is true.
    //
    //   if (!log_register_sink(&console_log_sink))
    //       log_write(LogLevel::Warn, "console: log sink table full");
    //   panic_set_console_sink(&console_panic_sink);

    return true;
}

bool console_ready() {
    return g_ready;
}

uint32_t console_cols() {
    return g_cols;
}

uint32_t console_rows() {
    return g_rows;
}

void console_set_colour(ConsoleColour fg, ConsoleColour bg) {
    g_attr = console_attr(fg, bg);
}

void console_putc(char c) {
    if (!g_ready) {
        return;
    }

    switch (c) {
    case '\n':
        g_wrap_pending = false;
        g_col          = 0;
        newline_row();
        break;

    case '\r':
        g_wrap_pending = false;
        g_col          = 0;
        break;

    case '\t':
        do_tab();
        break;

    case '\b':
        do_backspace();
        break;

    default:
        put_printable(c);
        break;
    }
}

void console_write(const char* s) {
    if (!g_ready || s == nullptr) {
        return;
    }
    for (; *s != '\0'; ++s) {
        console_putc(*s);
    }
}

void console_write(const char* s, size_t len) {
    if (!g_ready || s == nullptr) {
        return;
    }
    for (size_t i = 0; i < len; ++i) {
        console_putc(s[i]);
    }
}

void console_clear() {
    if (!g_ready) {
        return;
    }

    for (uint32_t row = 0; row < g_rows; ++row) {
        blank_row(row);
    }

    g_col          = 0;
    g_row          = 0;
    g_wrap_pending = false;

    // The whole SURFACE, not just the cells: the margin strips outside the
    // grid are inside the framebuffer and nothing else ever paints them.
    // No redraw_all() afterwards — every cell is now a space on this exact
    // background, so repainting them would write 4 MiB to no effect.
    fb_clear(g_palette[(g_attr >> 4) & 0x0FU]);
}

void console_scroll() {
    if (!g_ready) {
        return;
    }

    // Rows 1..g_rows-1 move to 0..g_rows-2. sizeof(g_grid[0]) is the array's
    // TRUE row stride, CONSOLE_MAX_COLS * 2 — not g_cols * 2. Writing the
    // narrower figure shears the text, exactly as a wrong pitch shears an
    // image in fbcon.cpp.
    memmove(&g_grid[0][0], &g_grid[1][0],
            static_cast<size_t>(g_rows - 1) * sizeof(g_grid[0]));

    // The vacated last row still holds a copy of what was there before the
    // move. Blank it, or the old bottom line stays on screen forever.
    blank_row(g_rows - 1);

    // The cursor follows its content. At row 0 there is no content to follow.
    if (g_row > 0) {
        --g_row;
    }

    redraw_all();
}

void console_redraw() {
    if (!g_ready) {
        return;
    }
    redraw_all();
}
```

#### Line by line

**Lines 1–14 — the three rules**
```cpp
//   1. The GRID is the source of truth for the text ...
//   2. The grid's row stride is CONSOLE_MAX_COLS, not g_cols ...
//   3. draw_cell() holds the ONLY grid-to-pixel arithmetic ...
```
File-scope invariants that a later edit can break silently and that are not visible from the code. Rule 1 is what stops someone adding a "read the cell back to blend it" helper. Rule 2 is the one that will actually catch someone: `g_cols` is the number they will reach for, and it is right in every loop and wrong in the `memmove`. Rule 3 is what keeps `* 8` and `* 16` from appearing in the scroll routine and drifting out of step with the font.

**Lines 16–27 — includes**
```cpp
#include "kernel/console.hpp"

#include "kernel/framebuffer.hpp"
#include "kernel/serial.hpp"
#include "kernel/string.hpp"

#include "font.hpp"

#include <stddef.h>
#include <stdint.h>
```
Own header first, so a missing include in `console.hpp` fails here rather than in some distant consumer. Then kernel headers, then the local subsystem header, then GCC's freestanding C headers — the order `.clang-format`'s `IncludeCategories` enforces.

`font.hpp` is quoted and unqualified because it lives *beside* this file in `kernel/drivers/char/`, and [[07 - Repository Layout]] reserves `include/kernel/` for cross-subsystem interfaces. Nothing outside `drivers/char/` has any business touching the font.

`"kernel/string.hpp"` is the one name here this vault has not fixed: it is whatever header you declared `memmove` in when you wrote `kernel/lib/string.cpp`. Check the name you used. If you have not written it yet, replace the `memmove` in `console_scroll()` with the loop given below and drop this include; everything else compiles unchanged.

There is no `limine.h` and there never will be — this file is outside `kernel/arch/x86_64/boot/`, and CI greps for exactly that.

**Lines 29–41 — `Cell` and the assertion**
```cpp
struct Cell {
    uint8_t ch;
    uint8_t attr;
};

static_assert(sizeof(Cell) == 2, "...");
```
Two `uint8_t`s: alignment 1, size 2, no padding. The `static_assert` is not paranoia about this struct — it is a guard on the *next* edit. Add a `uint16_t` field for Unicode later and `sizeof(Cell)` becomes 6 with padding, the 36 KiB budget quietly becomes 108 KiB, and the `memmove` stride silently changes meaning. The assertion turns that into a compile error with a message that says what to reconsider.

`ch` is `uint8_t`, not `char`. Plain `char` is **signed** on x86-64 SysV, and a signed `char` holding `0xDB` is −37; `font8x16[-37]` reads 592 bytes before the array. Storing the byte unsigned means the sign question is settled once, at the point of storage, rather than at every use.

**Lines 43–45 — the grid**
```cpp
Cell g_grid[CONSOLE_MAX_ROWS][CONSOLE_MAX_COLS];
```
`[row][col]`, in that order, everywhere. Getting the two transposed is the single most damaging typo available in this file: `g_grid[col][row]` with `col` up to 159 and `CONSOLE_MAX_ROWS` of 72 indexes rows 72–159 of a 72-row array, which is a perfectly valid pointer computation into the `.bss` objects that follow. No fault, no warning, just another subsystem's globals filling with text. See §7.

At namespace scope inside an anonymous namespace this is zero-initialised into `.bss` by the ELF loader, which Limine performs. No constructor, so no `.init_array` entry — which matters because nothing walks `.init_array` until [[Phase 4 - Overview|Phase 4]] (rule 9 of [[13 - Coding Standards]]). The consequence that makes the design safe: before `console_init()` runs, `g_ready` is false and every entry point returns immediately.

**Lines 47–55 — the state**
```cpp
uint32_t g_cols, g_rows, g_col, g_row;
uint8_t  g_attr;
bool     g_wrap_pending;
bool     g_ready;
```
Everything in an anonymous namespace: internal linkage, invisible to the linker, cannot collide. This is the C++ replacement for file-scope `static` and is what [[13 - Coding Standards]] expects for driver-private state.

`g_cols`/`g_rows` are the **live** geometry and `CONSOLE_MAX_COLS`/`CONSOLE_MAX_ROWS` are the **capacity**. Four names for two concepts is the price of a static allocation; confusing them is §7's shearing bug.

`g_ready` is genuine state, not a redundant `g_cols != 0`: `console_init()` can reject a framebuffer that has perfectly good geometry.

**Lines 57–82 — the palette table**
```cpp
constexpr Rgb PALETTE_RGB[CONSOLE_COLOURS] = { {0x00,0x00,0x00}, ... };
Colour g_palette[CONSOLE_COLOURS];
```
`constexpr` puts the triples in `.rodata` with no runtime initialisation. `g_palette` is `.bss` and is filled by `console_init()`.

Two arrays rather than one because they hold different things: the RGB triples are a property of the *palette*, fixed forever; the packed `Colour`s are a property of the *mode*, and are only valid for the framebuffer `fb_init()` accepted. Keeping them apart is what makes it obvious that a mode change must repack.

**Lines 86–98 — `draw_cell`, the mapping**
```cpp
void draw_cell(uint32_t col, uint32_t row) {
    const Cell cell = g_grid[row][col];
    fb_putchar(static_cast<char>(cell.ch),
               col * FONT_WIDTH,
               row * FONT_HEIGHT,
               g_palette[cell.attr & 0x0FU],
               g_palette[(cell.attr >> 4) & 0x0FU]);
}
```
This is the stage. Everything else is arrangement.

`col * FONT_WIDTH` and `row * FONT_HEIGHT` — the mapping from §2, written once. It appears nowhere else, which is what lets you swap an 8×8 font by changing two constants in `font.hpp`. A literal `16` in `console_scroll()` would compile and would then disagree with the font.

`cell.attr & 0x0FU` and `(cell.attr >> 4) & 0x0FU` are 0–15 by construction, so both subscripts into a 16-element array are provably in range and **no bounds check is needed**. That is worth stating explicitly: with no IDT until [[Phase 2 - Overview|Phase 2]], an out-of-range read here would be a triple fault, so "provably in range" has to be provable, not likely. The mask is the proof.

`static_cast<char>(cell.ch)` converts back to the type `fb_putchar` takes, and Stage 1.2's implementation immediately converts it to `unsigned char` again. The round trip is exact — C++20 mandates two's complement, so the conversion of a value above 127 to signed `char` and back is value-preserving. If it makes you uneasy, change `fb_putchar`'s parameter to `unsigned char`; nothing else in this stage cares.

`const Cell cell = ...` copies two bytes out of the grid before the call, rather than passing `g_grid[row][col].ch` and `.attr` separately. One read of RAM, and the compiler is free to fold it into a 16-bit load.

**Lines 100–109 — `redraw_all`**
```cpp
void redraw_all() {
    for (uint32_t row = 0; row < g_rows; ++row) {
        for (uint32_t col = 0; col < g_cols; ++col) {
            draw_cell(col, row);
        }
    }
}
```
Row-major, matching the grid's layout and the framebuffer's, so both walks are sequential. Sequential writes are what write-combining memory is good at: the CPU's WC buffers fill and flush in bursts instead of dribbling out one partial line at a time.

`< g_rows` and `< g_cols`, the live geometry, **not** the maxima. Using the maxima would draw 256 columns on a 160-column screen; `fb_putchar` clips whole glyphs so nothing would corrupt, but you would spend 60% of every repaint drawing characters that are discarded.

**Lines 111–118 — `blank_row`**
```cpp
void blank_row(uint32_t row) {
    for (uint32_t col = 0; col < g_cols; ++col) {
        g_grid[row][col].ch   = ' ';
        g_grid[row][col].attr = g_attr;
    }
}
```
A loop rather than `memset`, because a blank cell is `{0x20, g_attr}` and those two bytes are not equal in general. `memset(row, 0x20, ...)` would set the attribute to 0x20 as well — background 2 (green) on foreground 0 (black) — which produces a green stripe you will spend twenty minutes explaining.

It blanks `g_cols` cells, not `CONSOLE_MAX_COLS`. The cells past `g_cols` are never drawn, so leaving whatever `memmove` shifted into them is harmless.

It deliberately does **not** draw. Both callers repaint afterwards — `console_scroll()` through `redraw_all()`, `console_clear()` through `fb_clear()` — and drawing here as well would double the cost of a scroll.

**Lines 122–128 — `newline_row`**
```cpp
void newline_row() {
    ++g_row;
    if (g_row >= g_rows) {
        console_scroll();
    }
}
```
The only place the row advances. `>=` rather than `==` because it costs nothing and survives a future edit that moves the row by more than one.

There is no clamp after the scroll, and that is deliberate rather than sloppy: `console_scroll()` decrements `g_row`, so entering with `g_row == g_rows` leaves with `g_row == g_rows - 1`. Putting the clamp here as well would work but would spread the invariant across two functions. One owner. If you delete the decrement in `console_scroll()`, this function writes past the end of the grid on the very next character.

**Lines 130–139 — `flush_pending_wrap`**
```cpp
void flush_pending_wrap() {
    if (!g_wrap_pending) return;
    g_wrap_pending = false;
    g_col = 0;
    newline_row();
}
```
The deferred wrap from §2, discharged. Called at the top of `put_printable` and nowhere else — the wrap must happen *before* the next glyph is placed, never at the end of the previous one.

Clearing the flag before calling `newline_row()` matters: `newline_row` may call `console_scroll`, which calls `redraw_all`, and none of that should observe a half-applied wrap.

**Lines 141–156 — `put_printable`, the cursor advance**
```cpp
void put_printable(char c) {
    flush_pending_wrap();

    Cell& cell = g_grid[g_row][g_col];
    cell.ch    = static_cast<uint8_t>(c);
    cell.attr  = g_attr;
    draw_cell(g_col, g_row);

    if (g_col + 1 >= g_cols) {
        g_wrap_pending = true;
    } else {
        ++g_col;
    }
}
```
Four steps in a fixed order: discharge any pending wrap, write the cell, draw the cell, then advance.

**Write before draw.** `draw_cell` reads the grid, so the cell must already hold the new character. Reversing them draws the *previous* occupant and the screen lags the grid by one character — output that looks like an off-by-one in the cursor and is not.

**Advance after draw.** Drawing at `g_col` and then incrementing is what makes the cursor mean "where the next character goes". Increment first and every character lands one cell right of where it should, with column 0 permanently blank.

`g_col + 1 >= g_cols` is the deferred-wrap test and the exact place a one-column error lives. With `g_cols == 160`, the last valid column is 159; after writing there, `159 + 1 >= 160` is true, so the flag is set and `g_col` stays 159 — never 160, which would be out of bounds. Writing `>` instead of `>=` sets the flag one column too late and the *next* write goes to column 160, past the live grid and into the dead cells that `blank_row` never clears. Writing `g_col >= g_cols` (no `+ 1`) sets it a column early and the right-hand column is never used.

All the arithmetic is unsigned and `g_cols >= 1`, so `g_col + 1` cannot wrap.

**Lines 158–172 — `do_backspace`**
```cpp
void do_backspace() {
    if (g_wrap_pending) {
        g_wrap_pending = false;
    } else if (g_col > 0) {
        --g_col;
    } else {
        return;
    }
    g_grid[g_row][g_col].ch   = ' ';
    g_grid[g_row][g_col].attr = g_attr;
    draw_cell(g_col, g_row);
}
```
Three branches, and each is a decision from §3.

*Pending wrap: cancel it, do not move.* If the last column was just written, the cursor is *already* on the cell to erase. Decrementing as well would erase the second-to-last character and leave the last one on screen — the classic "backspace deletes the wrong character at the end of a full line".

*Otherwise step left, if there is anywhere to step.*

*Column 0: do nothing.* Backspace does not wrap up to the end of the previous row. Doing so would require knowing whether that row was full — which the grid does not record — and after a scroll the previous row may not exist at all. Clamping is the only behaviour that is always correct.

**Backspace erases rather than merely moving**, and the argument is short: if the caller only wanted to move, the erase costs one cell write and is immediately overwritten by whatever they write next, so the visible result is identical. If the caller wanted to delete — a progress counter rubbing out a digit, a spinner — then erasing is the only version that works. Erasing is never worse and is sometimes the only correct answer, so it wins.

**Lines 174–184 — `do_tab`**
```cpp
void do_tab() {
    do {
        put_printable(' ');
    } while ((g_col % CONSOLE_TAB_WIDTH) != 0 && !g_wrap_pending);
}
```
Five lines that get three things right at once.

*It advances to the next stop, not by 8.* The loop exits when `g_col` is a multiple of 8, so a tab at column 5 writes three spaces and a tab at column 8 writes eight. `g_col += 8` would be one line and would misalign every column of output. §4 has the worked table.

*A do-while, not a while.* From column 0 the loop must still emit a full eight spaces; a `while` with the same condition would emit none, because `0 % 8 == 0` is already true. A tab that sometimes does nothing is a bug that only shows up at the start of a line.

*It reuses `put_printable`.* Wrapping, scrolling, cell writes and repainting are all handled by the one function that already handles them for every other character. A tab that fell off the bottom of the screen would otherwise need its own scroll call.

The `!g_wrap_pending` guard is the right-margin clamp. At `g_cols == 160` with the cursor at column 155, the loop writes spaces at 155–159; the last of those sets the pending flag and leaves `g_col` at 159. Without the guard, `159 % 8` is 7, the loop would run again, `put_printable` would discharge the wrap, and the tab would continue onto the next line to column 8 — a tab that consumed a line break.

**Lines 190–265 — `console_init`**

```cpp
    if (!fb_ready()) {
        serial_puts("console: no framebuffer; console disabled\n");
        return false;
    }
```
The console is layered strictly on top of the framebuffer, so this is the whole of its dependency check. A headless machine is legitimate; serial still works, and every console call becomes a no-op through `g_ready`.

Reporting through `serial_puts` and not through the console is the point of having built serial first: the component that is failing cannot be the component that reports the failure ([[ADR-0004 - Framebuffer Console Not VGA Text]] insists on that ordering).

```cpp
    const FramebufferInfo fb = fb_info();

    uint32_t cols = fb.width  / FONT_WIDTH;
    uint32_t rows = fb.height / FONT_HEIGHT;
```
No `BootInfo` parameter. `fb_init()` already validated the geometry and stored it, and `fb_info()` is the single place it lives; taking `BootInfo` here would mean the console knows what a bootloader is, which Stage 1.1's header explicitly forbids one layer down. If you saw `console_init(info)` in an earlier draft, this is the version to keep.

Truncating division, per §2 — the language does it for you, and it is the behaviour you want.

```cpp
    if (cols == 0 || rows == 0) { ...; return false; }
```
A framebuffer narrower than 8 pixels or shorter than 16 has no cells. Every subsequent expression — `g_rows - 1` in the scroll, `g_cols - 1` in the wrap test — assumes at least one, so reject here rather than defending everywhere.

```cpp
    bool clamped = false;
    if (cols > CONSOLE_MAX_COLS) { cols = CONSOLE_MAX_COLS; clamped = true; }
    if (rows > CONSOLE_MAX_ROWS) { rows = CONSOLE_MAX_ROWS; clamped = true; }
```
The three lines that stand between a 4K panel and a silently corrupted `.bss`. §3's decision 2 has the failure in detail; the short version is that `g_grid[80][0]` on a 72-row array is a valid pointer into the next object and there is no IDT to catch it.

Clamping rather than refusing means a 3840×2160 machine gets a 256×72 console in the top-left of its screen: cramped, entirely usable, and obviously not a crash. `clamped` is carried to the diagnostic rather than logged inline so the message reads as one statement about the mode.

```cpp
    for (uint32_t i = 0; i < CONSOLE_COLOURS; ++i)
        g_palette[i] = fb_pack_colour(PALETTE_RGB[i].r, PALETTE_RGB[i].g, PALETTE_RGB[i].b);
```
The colour decision from §3, made concrete. Sixteen calls, once, at init. Stage 1.1's header says of `fb_pack_colour`: *"Cheap, but not free: hoist it out of loops"* — this is the hoist. Doing it per cell would put three shifts and three masks in front of every glyph in every repaint.

It must come **after** `fb_ready()` is confirmed, because `fb_pack_colour` reads the mask fields that `fb_init` filled in. Packing before `fb_init` yields sixteen zeroes and a permanently black screen — see §7.

```cpp
    g_attr  = console_attr(CONSOLE_DEFAULT_FG, CONSOLE_DEFAULT_BG);
    g_ready = true;

    console_clear();
```
`g_ready` must be set **before** `console_clear()`, because `console_clear()` starts with `if (!g_ready) return;`. Order these the other way and initialisation silently clears nothing: Limine's boot menu stays on screen, the grid keeps whatever `.bss` held, and the first scroll paints all of it.

`console_clear()` is what handles the margin strips from §2 — the six-pixel column at 1366 wide, the eight-pixel band at 800 tall. It is the only call in the whole console that touches them.

```cpp
    serial_puts("console: ");
    serial_write_dec(g_cols);
    ...
    serial_write_dec(fb.width  - g_cols * FONT_WIDTH);
```
Printing the grid size, the pixel size and the leftover margin on one line makes three separate bugs visible at a glance: a wrong `cols` (division against the wrong font width), a mode you did not expect, and a clamp you did not notice. §6 reads this line.

```cpp
    //   if (!log_register_sink(&console_log_sink))
    //       log_write(LogLevel::Warn, "console: log sink table full");
    //   panic_set_console_sink(&console_panic_sink);
```
The log-replay hook, commented because `kernel/lib/log.cpp` does not exist until [[Stage 1.5 - The Log Ring Buffer and Levels]]. Uncomment it then, and add `#include "kernel/log.hpp"` and `#include "kernel/panic.hpp"`.

Its **position is the specification**, not a formatting choice. `log_register_sink()` immediately replays the entire ring to the newly registered sink, so at the instant these lines run the console must be completely initialised: geometry set, palette packed, `g_ready` true, screen cleared. Move them earlier — say, right after the clamp — and the replay draws the whole boot history through a `draw_cell` with an unpacked palette, onto a screen that has not been cleared. Move them into `kernel_init` instead and you have separated the two facts that must not drift: "the console can draw" and "the console is receiving log lines".

The sink itself belongs in this file when you write it, and is about four lines:

```cpp
    // Stage 1.5 will add roughly this, next to console_init():
    void console_log_sink(LogLevel level, const char* text, size_t len) {
        console_set_colour(colour_for(level), CONSOLE_DEFAULT_BG);
        console_write(text, len);          // NOT NUL-terminated: length form
        console_putc('\n');                // the ring stripped it
        console_set_colour(CONSOLE_DEFAULT_FG, CONSOLE_DEFAULT_BG);
    }
```

That is the whole reason `console_write` has a length overload and why `console_set_colour` is a plain setter a caller can restore.

**`console_putc` — the switch**
```cpp
    switch (c) {
    case '\n': g_wrap_pending = false; g_col = 0; newline_row(); break;
    case '\r': g_wrap_pending = false; g_col = 0; break;
    case '\t': do_tab();       break;
    case '\b': do_backspace(); break;
    default:   put_printable(c); break;
    }
```
`\n` resets the column **and** advances the row — LF doing CR's job as well, argued in §3. Delete `g_col = 0` and the output staircases diagonally off the right edge, which is §7's first surprise for anyone who implements ECMA-48 literally.

Both `\n` and `\r` clear `g_wrap_pending` before touching the cursor. If they did not, a pending wrap set by the last column would survive the newline and be discharged by the next printable character — producing exactly the spurious blank line the deferred wrap exists to prevent.

`default` catches everything else, including `0x1B` and `0x00`, and draws its glyph. A console that swallows bytes hides the bug that emitted them; a CP437 escape symbol appearing in your output tells you immediately that somebody started writing ANSI sequences.

The `if (!g_ready) return;` at the top is the single gate for the whole file: every public entry point has it, so a print from a subsystem that initialised before the console is a no-op rather than a write through an unpacked palette.

**`console_write`, both overloads**
```cpp
void console_write(const char* s) {
    if (!g_ready || s == nullptr) return;
    for (; *s != '\0'; ++s) console_putc(*s);
}
```
The `nullptr` check is not defensive clutter: a format-string bug or an uninitialised pointer reaching here would dereference null in ring 0 with no IDT, which is an instant triple fault and a reboot with no message. One comparison buys a silently-dropped message instead of a vanished machine.

Both overloads route through `console_putc`, so there is exactly one implementation of the control characters. Duplicating the switch for speed would be the classic way to end up with two consoles that disagree about tabs.

**`console_clear`**
```cpp
    for (uint32_t row = 0; row < g_rows; ++row) blank_row(row);
    g_col = 0; g_row = 0; g_wrap_pending = false;
    fb_clear(g_palette[(g_attr >> 4) & 0x0FU]);
```
Grid first, then cursor, then surface.

`fb_clear` paints the **entire framebuffer**, including the margin strips no cell covers. That is the only reason this function calls `fb_clear` instead of `redraw_all()`: repainting the cells would leave Limine's boot-menu pixels in the margins forever, visible as a thin bright band down the right edge or along the bottom on any resolution that does not divide exactly.

And there is deliberately **no** `redraw_all()` after it. Every cell is now a space with background `(g_attr >> 4)`, and `fb_clear` just painted the whole screen that colour. Repainting would write about 4 MiB to produce a pixel-for-pixel identical screen.

`g_wrap_pending = false` is easy to forget and produces a genuinely confusing bug: clear the screen while a wrap is pending and the first character afterwards appears on row 1, not row 0.

**`console_scroll` — the heart of the stage**
```cpp
    memmove(&g_grid[0][0], &g_grid[1][0],
            static_cast<size_t>(g_rows - 1) * sizeof(g_grid[0]));
```
Rows 1…`g_rows-1` move up one position. Destination and source overlap, so this is `memmove` and not `memcpy` — `memcpy`'s permission to copy in any order is exactly what would corrupt an upward overlapping move on some implementations.

`sizeof(g_grid[0])` is the load-bearing expression. `g_grid[0]` has type `Cell[CONSOLE_MAX_COLS]`, so this is `256 * 2 = 512` bytes: the array's **declared** row stride. Writing `g_cols * sizeof(Cell)` instead gives 320 bytes at 1280×800 and is wrong in the same way that using `width * bytes_per_pixel` instead of `pitch` is wrong in `fbcon.cpp` — each row lands 192 bytes short of where the next row actually begins, and the text shears diagonally on the first scroll. Deriving the stride from `sizeof` rather than writing it out means it cannot disagree with the declaration.

The `static_cast<size_t>` forces the multiplication into 64 bits. At these sizes nothing overflows and the cast is free; making it a habit in every size and address computation is what stops the one that would.

This copies the dead cells beyond `g_cols` as well. They are never drawn, and copying them is what keeps the stride exact.

```cpp
    blank_row(g_rows - 1);
```
After the move, the last row still contains a byte-for-byte copy of what was in it before — `memmove` moves, it does not vacate. Skip this and the old bottom line stays on screen through every subsequent scroll, drifting nowhere, looking exactly like a redraw bug. §7 has the symptom.

```cpp
    if (g_row > 0) --g_row;
```
The cursor follows its content. Everything moved up by one row, so the cell the cursor pointed at is now one row higher, and the cursor must move with it or it will point at different text than it did a microsecond ago.

This is also what makes `newline_row()` correct without a clamp: entering the scroll with `g_row == g_rows` (one past the end) leaves with `g_row == g_rows - 1`, the newly blanked last row, which is exactly where the next character belongs.

The `> 0` guard covers a direct call to `console_scroll()` with the cursor on row 0. The content that was on row 0 is gone, there is nothing above to follow, and the cursor stays.

```cpp
    redraw_all();
```
The whole screen, from the grid, write-only. About 4 MiB of stores at 1280×800 and not one load from the framebuffer — the entire point of §3's first decision.

This is the most expensive operation in the console, and it is the one [[Stage 1.4 - Double Buffering]] fixes: with a back buffer in normal RAM, the scroll becomes a `memmove` of the pixels *in RAM* plus one flush, and the grid repaint is only needed for the single blanked row. The grid does not go away; only this line changes.

**If you have not written `memmove` yet**, the loop below is equivalent and has no dependency. It is slower by a constant and is not worth keeping once `kernel/lib/string.cpp` exists:

```cpp
    for (uint32_t row = 1; row < g_rows; ++row)
        for (uint32_t col = 0; col < g_cols; ++col)
            g_grid[row - 1][col] = g_grid[row][col];
```

Note that this version walks only `g_cols` columns and is *still correct*, because it addresses cells through the two-dimensional subscript and lets the compiler compute the stride. The stride bug is only reachable when you compute a byte count by hand.

---

### Wiring it up

In `kernel/CMakeLists.txt`, add the source to the explicit list — the source list is not globbed ([[Stage 0.8 - The Build System]]):

```cmake
    drivers/char/console.cpp
```

In `kernel_init()`, after `fb_init(info)`:

```cpp
#include <kernel/console.hpp>

    fb_init(info);                 // step 5, unchanged
    console_init();                // step 6 — no BootInfo argument

    console_set_colour(ConsoleColour::LightGreen, ConsoleColour::Black);
    console_write("CRACKED OS\n");
    console_set_colour(CONSOLE_DEFAULT_FG, CONSOLE_DEFAULT_BG);
```

Delete `fb_test_pattern()` from `kernel_init` at the same time. It was scaffolding with an expiry date and this is the date: leaving it in means `console_clear()` immediately erases it, which wastes a screenful of writes and confuses the first person to wonder where the colour bars went.

---

## 6. How to verify

### Checkable now

**1. It builds, and the grid is the size you think it is.**

```sh
make
x86_64-elf-nm -S build/kernel.elf | grep g_grid
```
```
ffffffff80108000 0000000000009000 b _ZN12_GLOBAL__N_16g_gridE
```

`0x9000` is 36,864 — 256 × 72 × 2, exactly the budget in §4. A `b` (lower case) means `.bss`: allocated, not stored in the ELF file, so the kernel image did not grow by 36 KiB. If the size is `0x12000` you added a field to `Cell` and the `static_assert` should have caught it.

**2. The geometry line is right.**

```sh
make run
```
On the serial console, before anything is drawn:
```
fb: 1280x800x32 pitch=5120 (width*bytes=5120) @ 0xFFFF8000FD000000
console: 160x50 cells from 1280x800 px, margin 0x0 px
```
`1280 / 8 = 160` and `800 / 16 = 50`, matching §4's table. A `console:` line reporting 640×400 means you divided by 16 and 32; reporting 1280×800 means you forgot to divide at all.

### Checkable on screen

Paste this into `kernel_init` after `console_init()`. It is scaffolding — delete it before committing, or keep it behind a `console_selftest()` you can call from the Phase 8 shell.

```cpp
    // --- 1. scrolling: print more lines than fit -------------------------
    for (uint32_t i = 1; i <= console_rows() + 5; ++i) {
        console_write("line ");
        serial_write_dec(i);          // reuse until kprintf exists (Stage 1.6)
        console_putc('\n');
    }
```

Replace `serial_write_dec` with a two-digit hand-rolled print, or simply print a distinguishable pattern per line; the point is that the lines are numbered.

- [ ] **Scrolling.** With 50 rows you printed 55 lines. Six of them scrolled off, so the top visible line is `line 7`, the bottom text line is `line 55`, and there is exactly **one** blank row beneath it (the cursor's row). If the top line is `line 6` or `line 8`, the scroll trigger is off by one. If there is no blank row at the bottom, `newline_row` is scrolling one line late.
- [ ] **The scroll is instant.** Fifty-five lines with six scrolls must appear in one frame — you should never see the screen fill progressively. If you can watch it happen, you are reading framebuffer memory somewhere. §7, first trap.

```cpp
    // --- 2. wrapping: a line longer than the screen ----------------------
    for (uint32_t i = 0; i < console_cols() + 8; ++i)
        console_putc(static_cast<char>('0' + (i % 10)));
    console_putc('\n');
```

- [ ] **Wrapping.** The digit sequence must be continuous across the break: at 160 columns, the last character of the first row is `9` (index 159) and the first character of the next row is `0` (index 160). A character missing at the seam means the wrap fires a column early; a character overwritten means it fires late.

```cpp
    // --- 3. deferred wrap ------------------------------------------------
    for (uint32_t i = 0; i < console_cols(); ++i) console_putc('#');
    console_write("\nNEXT\n");
```

- [ ] **Deferred wrap.** `NEXT` must be on the row **immediately** below the row of `#`. A blank row between them means the wrap was eager: the 160th `#` moved the cursor, and the `\n` moved it again.

```cpp
    // --- 4. control characters -------------------------------------------
    console_write("A\tB\tC\n");           // tab stops
    console_write("12345\tX\n");
    console_write("1234567\tY\n");
    console_write("12345678\tZ\n");
    console_write("XXXXXXXX\rOK\n");      // carriage return
    console_write("done!!\b\b\n");        // backspace erases
    console_write("abc\bZ\n");            // backspace then overwrite
    console_write("\b\bhi\n");            // backspace at column 0
```

- [ ] **Tabs.** `A` at column 0, `B` at column 8, `C` at column 16. `X`, `Y` and `Z` must all be at column 8, 8 and **16** respectively. That last one is the discriminator: with a fixed `+8`, `X` lands at 13, `Y` at 15 and `Z` at 16, so only the `12345678` case looks right.
- [ ] **Carriage return.** The line reads `OKXXXXXX` — `OK` overwrote the first two cells, the rest survived.
- [ ] **Backspace erases.** The line reads `done` with no trailing `!!` and no leftover pixels.
- [ ] **Backspace then overwrite.** The line reads `abZ`.
- [ ] **Backspace at column 0.** The line reads `hi` at column 0. Nothing on the row above was touched, and the machine did not reboot.

```cpp
    // --- 5. colour --------------------------------------------------------
    console_set_colour(ConsoleColour::LightRed,  ConsoleColour::Black);
    console_write("error\n");
    console_set_colour(ConsoleColour::Black,     ConsoleColour::LightGrey);
    console_write("inverse\n");
    console_set_colour(CONSOLE_DEFAULT_FG, CONSOLE_DEFAULT_BG);
    console_write("normal\n");
```

- [ ] **Colour.** `error` is bright red on black; `inverse` is black text on a light grey bar that extends the full width of the word and no further; `normal` is light grey on black. If `error` comes out blue, `fb_pack_colour` is using the wrong masks — that is a Stage 1.1 bug, not a console bug.
- [ ] **Colour is per cell.** Scroll the screen after the colour test (print another 50 lines). The coloured lines keep their colours as they move up. If they turn grey, the attribute is not being stored in the cell.

```cpp
    // --- 6. redraw --------------------------------------------------------
    fb_fill_rect(100, 100, 400, 200, fb_pack_colour(0x30, 0x90, 0xE0));
    console_redraw();
```

- [ ] **Redraw.** The blue rectangle appears, and `console_redraw()` erases it completely, restoring the text underneath. This is the recoverability property from §3 and it is what a panic banner will rely on.

### Checkable by changing the mode

- [ ] **A second resolution.** Edit `resolution: 1024x768x32` in `boot/limine.conf`, `make run`, and confirm the serial line reads `console: 128x48 cells from 1024x768 px, margin 0x0 px` — and that the text still fills the screen without corruption.
- [ ] **A non-dividing resolution.** Try `800x600x32`. Expect `console: 100x37 cells from 800x600 px, margin 0x8 px`. The eight leftover pixels along the bottom must be the clear colour, not Limine's menu — that is `console_clear()` calling `fb_clear` rather than repainting cells.
- [ ] **The clamp.** Set `CONSOLE_MAX_ROWS = 20` in `console.hpp`, rebuild, and boot at 1280×800. Expect `console: 160x20 cells ... ` followed by `console: WARNING mode exceeds CONSOLE_MAX_COLS/ROWS`. The console must occupy the top 320 pixels and scroll within them; the bottom of the screen stays the clear colour. Nothing may corrupt and the machine must not reboot. Put the constant back to 72 afterwards.

Reaching the clamp honestly needs a mode wider than 2048 or taller than 1152; whether your QEMU offers one depends on the emulated adapter's VRAM, so the shrunk-constant test above is the reliable version.

### Only checkable later

- **Log replay.** The two commented lines at the end of `console_init()` cannot be tested until [[Stage 1.5 - The Log Ring Buffer and Levels]] exists. When it does, the check is that the boot history — every line logged since before the framebuffer worked — appears on screen the moment the console initialises.
- **Scroll cost.** The repaint is the console's dominant cost and stays invisible until there is a timer to measure it ([[Phase 3 - Overview|Phase 3]]) or enough output to feel it. [[Stage 1.4 - Double Buffering]] is where it is measured and fixed.
- **Real hardware.** Padded `pitch` and a BGR mask order only appear on a real machine ([[Phase 15 - Overview|Phase 15]]). The console is insulated from both — it never touches a pixel address and never builds a pixel value — which is the payoff for routing everything through `fb_putchar` and `fb_pack_colour`.

---

## 7. Common traps

**Symptom: scrolling visibly crawls — you can watch the screen fill, and a boot that prints two hundred lines takes seconds.**

Something is **reading** framebuffer memory. The usual culprit is a `memmove` over the pixels rather than the grid — the "obvious implementation" in §2 — but it can also be a helper that reads a pixel back to blend or invert it, or a `fb_get_pixel` someone added for a cursor.

Framebuffer memory is uncached write-combining: writes are buffered and burst, reads are a full bus round trip each, hundreds of nanoseconds against roughly one for an L1 hit. A single scroll at 1280×800 reads about 4 MB. Grep the console and the framebuffer driver for any expression that *loads* through `g_fb.base` — there must be exactly none. Rule 3 in `fbcon.cpp`'s banner exists to make this greppable.

**Symptom: the bottom line of the screen is cut off, or the last row is never used.**

An off-by-one in the row count or the scroll trigger. Three distinct versions:

- `rows = (fb_height + FONT_HEIGHT - 1) / FONT_HEIGHT` — rounding **up**. At 800 pixels this gives 50 (harmless, it divides exactly) but at 600 it gives 38, and row 37 is drawn into the last 8 pixels of the screen with the bottom half of every glyph off the surface. Round down. A partial cell is not a cell.
- `if (g_row > g_rows)` in `newline_row` instead of `>=`. The cursor reaches `g_rows`, writes one row past the live grid, and only scrolls on the row after that.
- `for (row = 0; row < g_rows - 1; ...)` in `redraw_all`. The last row is never painted; text scrolls into it and vanishes.

The §6 line-number test distinguishes all three: with 50 rows and 55 lines the top must read `line 7`.

**Symptom: text wraps one column early — the right-hand column is always blank — or one column late, and a character goes missing at every wrap.**

The deferred-wrap test in `put_printable`. It must be `if (g_col + 1 >= g_cols)`, evaluated **after** the character has been drawn at `g_col`.

`if (g_col >= g_cols)` wraps a column early: the flag is never set on the last valid column, so column `g_cols - 1` is never written. `if (g_col + 1 > g_cols)` wraps a column late: `g_col` reaches `g_cols`, `draw_cell` computes a pixel `x` past the right edge, `fb_putchar` clips the whole glyph, and the character is silently discarded. Testing before drawing produces the same lost character with a different cause.

Count the digits in §6's wrapping test rather than eyeballing the seam; a missing `9` or a missing `0` is invisible at a glance and unambiguous in the sequence.

**Symptom: tab moves an inconsistent distance — columns almost line up but drift, and the drift depends on the length of the preceding field.**

`g_col += CONSOLE_TAB_WIDTH` instead of advancing to the next tab stop. A tab goes to the next multiple of 8, so from column 5 it moves 3 and from column 8 it moves 8. A fixed `+8` moves 8 every time, and the whole point of a tab — that two lines with different field widths align — is lost.

The trap is that it looks correct in the one case people test first, `"a\tb"` from column 0. Use §6's four-case test; the `12345678\tZ` line is the one that separates them.

The subtler version is the right margin: `g_col = ((g_col / 8) + 1) * 8` computed without a clamp can leave `g_col == g_cols` or beyond, and the next `draw_cell` indexes past the live grid.

**Symptom: ghost text remains on the last line after scrolling — an old line sits at the bottom of the screen and never moves again.**

`blank_row(g_rows - 1)` is missing after the `memmove`, or it runs before the move rather than after.

`memmove` copies; it does not vacate. After rows 1…n−1 have moved up, row n−1 still holds a byte-for-byte copy of its previous contents, and `redraw_all()` faithfully paints it. The result is a line that is always one scroll out of date, which reads as a redraw bug rather than a scroll bug and sends you to the wrong function.

The related version: `blank_row` sets `ch` but not `attr`, so the vacated row inherits the old line's colours and you get a stripe of coloured spaces.

**Symptom: garbage at high resolution — text appears in the wrong places, unrelated subsystems misbehave, or the machine reboots the instant anything prints.**

The mode's grid exceeded `CONSOLE_MAX_COLS` or `CONSOLE_MAX_ROWS` and there is no clamp.

`g_grid` is declared `[72][256]`. On a 3840×2160 panel `fb_height / 16` is 135, and `g_grid[100][0]` is a perfectly valid pointer computation 28 rows past the end of the array — into whatever `.bss` object the linker put next. There is no fault at the moment of the bug: some other subsystem's globals fill with text and *that* subsystem starts failing. When the index eventually runs off the segment, the page fault is a triple fault, because there is no IDT until [[Phase 2 - Overview|Phase 2]]: instant reboot, no message.

The fix is the three lines in `console_init()`. Verify with §6's shrunk-`CONSOLE_MAX_ROWS` test, which reaches the clamp path at any resolution.

**Symptom: after the first scroll the whole screen shears — each row is shifted a little further left than the one above, exactly like the pitch bug from Stage 1.1.**

The `memmove` used the live width as the row stride: `g_cols * sizeof(Cell)` instead of `sizeof(g_grid[0])`.

`g_grid` is declared with `CONSOLE_MAX_COLS` columns, so consecutive rows are 512 bytes apart no matter what `g_cols` is. At 1280×800, `g_cols * 2` is 320, so every row lands 192 bytes short of where the next row begins and the content walks left by 96 cells per row. This is the same class of bug as using `width * bytes_per_pixel` instead of `pitch`, one level up, and it produces the same recognisable diagonal.

Derive the stride from `sizeof(g_grid[0])` and it cannot disagree with the declaration. Note that a per-cell copy loop using `g_grid[row - 1][col] = g_grid[row][col]` is immune, because the compiler computes the stride; the bug is only reachable when you compute a byte count by hand.

**Symptom: output steps diagonally down and to the right — a staircase.**

`\n` advanced the row but did not reset the column. Strict ECMA-48 says a line feed does exactly that and a carriage return resets the column, so an implementation faithful to the standard staircases when the caller writes `"...\n"` and means "end of line".

This console deliberately deviates: `\n` does both. Add `g_col = 0;` to the `'\n'` case. If you ever want the strict behaviour back, it belongs in a tty layer above the console, not here.

**Symptom: the screen stays black, or everything is drawn in black on black, but the serial log shows the console initialising normally.**

`g_palette` was packed before `fb_init()` accepted the framebuffer, so `fb_pack_colour` read mask sizes and shifts that were still zero and returned sixteen identical zeroes. Everything is being drawn, in black, on black.

Check the call order in `kernel_init`: `fb_init(info)` then `console_init()`. The `if (!fb_ready())` guard at the top of `console_init` is what makes this impossible — if you removed it because "the framebuffer is obviously up by then", put it back.

The same symptom with a different cause: `g_ready = true` placed *after* `console_clear()`, so the clear returned immediately and the grid was never blanked. The screen then shows Limine's boot menu with your text drawn over it.

**Symptom: printing corrupts an unrelated subsystem's state, and the corruption looks like text.**

`g_grid[col][row]` — the subscripts transposed. With 160 columns and a 72-row array, `g_grid[159][…]` addresses rows 72 through 159 of a 72-row array: valid pointer arithmetic, no warning, straight into the next `.bss` object.

The tell is that the corrupted bytes are printable ASCII. If a subsystem's globals contain fragments of your log messages, look for a transposed subscript before you look anywhere else. Keeping `[row][col]` in that order everywhere, and never passing a bare pair of integers where a `(col, row)` is expected, is the only real defence — which is why `draw_cell(col, row)` takes them in the opposite order from the subscript and says so.

---

## 8. What this unlocks

Every text-producing subsystem from here on writes through `console_write`. [[Stage 1.4 - Double Buffering]] replaces the destination of `fb_putchar` with a RAM back buffer and turns the repaint in `console_scroll()` into a `memmove` plus one flush — the console's interface does not change, which is the test of whether this stage's layering was right. [[Stage 1.5 - The Log Ring Buffer and Levels]] registers `console_log_sink` at the end of `console_init()` and the whole boot history appears on screen; it depends on the length overload of `console_write` and on `console_set_colour` being a restorable setter. [[Stage 1.6 - kprintf]] formats into a buffer and hands it here. [[Stage 0.7 - Panic and KASSERT]]'s step-7 console hook draws a banner over the screen and relies on `console_redraw()` to be able to put the log back. Phase 8's shell adds the visible cursor this stage deliberately omitted.

Done wrong, the failures are quiet and late. A missing clamp corrupts `.bss` only on hardware you have not booted yet. A pixel-moving scroll works perfectly and simply makes every later stage slower to debug. An eager wrap inserts a blank line only when a line is exactly the width of the screen — which is what a register dump will be. And if the grid is not the source of truth, the panic banner in [[Phase 2 - Overview|Phase 2]] erases the evidence it was drawn to explain.

---

## 9. Reading

- [Drawing In a Linear Framebuffer](https://wiki.osdev.org/Drawing_In_a_Linear_Framebuffer) — OSDev's page on the surface this console sits on. Skim it for the pixel arithmetic you already wrote in Stage 1.1; the value here is the section on why you buffer.
- [Text UI](https://wiki.osdev.org/Text_UI) — OSDev on building a character grid over pixels. Reasonable on structure, weaker on scroll cost; read it after §3 so you can see which decisions it skips.
- [VGA Hardware](https://wiki.osdev.org/VGA_Hardware) — where the attribute byte's `bbbbffff` layout and the 16-colour palette in §4 come from. Worth reading once so the constants stop looking arbitrary.
- [ECMA-48, Control Functions for Coded Character Sets](https://ecma-international.org/publications-and-standards/standards/ecma-48/) — the actual standard for BS, HT, CR and LF. §8.3 defines each. Read it to see precisely which part of it this console deliberately does not implement, and why the `\n`-does-CR deviation is a deviation.
- [XTerm Control Sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html) — search for "wraparound" and "last column". The deferred-wrap flag in §2 is xterm's, and this document is the clearest statement of the behaviour a real terminal has.
- [Linux `drivers/tty/vt/vt.c`](https://github.com/torvalds/linux/blob/master/drivers/tty/vt/vt.c) — the production version of this stage. Look at `lf()`, `cr()`, `bs()` and `con_scroll()`; the shape is the same and the amount of extra state is a good preview of what a tty layer costs.
- [Linux `drivers/video/fbdev/core/fbcon.c`](https://github.com/torvalds/linux/blob/master/drivers/video/fbdev/core/fbcon.c) — Linux's framebuffer console. `fbcon_scroll()` implements several scroll strategies and picks between them; that choice is §3's first decision, made in production.
- [Intel 64 and IA-32 Architectures Software Developer's Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html) — Volume 3A, the "Methods of Caching Available" section, for what write-combining actually guarantees. The paragraph on WC reads bypassing the cache is the whole justification for this stage's central decision.
- [[Stage 1.1 - The Linear Framebuffer]] — §2.4 and §3 for the memory-type argument and `fb_pack_colour`; §5 for the exact API this stage calls.
- [[Stage 1.2 - Rasterising a Bitmap Font]] — §2.5 for the monospace-makes-a-grid argument, and the `fb_putchar` contract (opaque, whole-glyph clipping) that lets `draw_cell` overwrite a cell without erasing it first.
- [[Stage 1.5 - The Log Ring Buffer and Levels]] — the sink contract, and why the two commented lines belong at the *end* of `console_init()`.
- [[13 - Coding Standards]] — rules 3 (volatile), 6 (`[[nodiscard]]`), 9 (no static constructors) and 10 (comments explain why) all show up in this file.

Next: **[[Stage 1.4 - Double Buffering]]**

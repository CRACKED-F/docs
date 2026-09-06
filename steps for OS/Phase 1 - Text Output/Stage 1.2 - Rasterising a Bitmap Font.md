# Stage 1.2 — Rasterising a Bitmap Font

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Console & Logging]]
**Files you create:** `tools/mkfont/mkfont.cpp`, `tools/mkfont/vga8x16.fnt`, `tools/CMakeLists.txt`, `kernel/drivers/char/font.hpp`, additions to `kernel/drivers/char/fbcon.cpp` / `fbcon.hpp`, and wiring in `CMakeLists.txt` and `kernel/CMakeLists.txt`
**Deliverable:** `fb_putchar('A', x, y, fg, bg)` draws a real, legible glyph on the framebuffer, and `fb_puts` writes a string across the screen.

---

## Progress

- [ ] Obtain a raw 8x16 font blob, exactly 4096 bytes, at `tools/mkfont/vga8x16.fnt`
- [ ] Record where it came from and under what licence in `tools/mkfont/README.md`
- [ ] Prove git will actually commit it — `git check-ignore -v tools/mkfont/vga8x16.fnt` prints nothing
- [ ] `tools/mkfont/mkfont.cpp` — the host generator
- [ ] `tools/CMakeLists.txt` — a standalone **native** CMake project
- [ ] `ExternalProject_Add(host_tools ...)` in the top-level `CMakeLists.txt`
- [ ] `add_custom_command` for `font8x16.cpp` in `kernel/CMakeLists.txt`, with the generated file in the `kernel.elf` source list
- [ ] `kernel/drivers/char/font.hpp`
- [ ] `fb_putchar` and `fb_puts` in `kernel/drivers/char/fbcon.cpp`
- [ ] `build/host-tools/bin/mkfont` runs **on your machine** — it is not a cross binary
- [ ] `nm -S build/kernel.elf` shows `font8x16` as a global `R` symbol of size `0x1000`
- [ ] The printable range `0x20`–`0x7E` draws legibly on screen
- [ ] A character `>= 0x80` draws its glyph and does **not** reboot the machine
- [ ] Touching the font blob regenerates `font8x16.cpp`; two clean builds produce byte-identical output
- [ ] `make lint` passes — `clang-format` covers `tools/` too
- [ ] Committed with a message like `feat(fbcon): rasterise an 8x16 bitmap font`

---

## 1. Why this stage exists

[[Stage 1.1 - The Linear Framebuffer]] left you with `put_pixel(x, y, colour)` and a coloured rectangle. That proves the framebuffer works. It is not output. You cannot debug a page-fault handler with a rectangle.

The gap is larger than it looks, because **the hardware has no concept of a character.** There is no font in the GPU, no font in the firmware you can still reach, and — as [[ADR-0004 - Framebuffer Console Not VGA Text]] explains — no VGA text buffer at `0xB8000` on a UEFI machine. A linear framebuffer is an array of pixels and nothing else. If you want an `A` on the screen, *you* must supply the picture of an `A`, pixel by pixel, and you must supply it for all 256 byte values you might ever want to print.

So this stage answers two separate questions, and the second one is the interesting one:

1. **How do you turn a picture of a letter into pixels?** Two nested loops. It is thirty lines and you will get it right in ten minutes.
2. **Where does the picture come from, given what the kernel does not have yet?**

That second question is what makes this a Medium stage. At the moment the console first wants to print, the kernel has:

- **no filesystem** — the VFS arrives in [[Phase 7 - Overview|Phase 7]], real filesystems in [[Phase 10 - Overview|Phase 10]]
- **no heap** — `kmalloc` arrives in [[Phase 4 - Overview|Phase 4]]
- **no block device** — AHCI/NVMe arrive in [[Phase 9 - Overview|Phase 9]]
- **no interrupt table** — the IDT arrives in [[Phase 2 - Overview|Phase 2]], so *any* CPU exception right now is a triple fault and an instant silent reboot
- **no floating point, ever** — the kernel is compiled `-mno-sse -mno-mmx -mno-80387` ([[ADR-0007 - Freestanding C++20 as the Kernel Language]])

Every one of those rules out a font technology that a userspace program would reach for by default. What is left is the oldest and dumbest option: **put the glyph bitmaps in the kernel image**, as a plain `const` array, and index it.

There is a second reason to want the dumbest option, and it outlives the constraint list. This is the **debugging path**. Every subsystem from [[Phase 2 - Overview|Phase 2]] onward is debugged by printing. A console that can itself fail — because a file was missing, a parse went wrong, or an allocation returned null — fails precisely when you need it, and it fails while you are already confused about something else. The console must depend on strictly less than everything it reports on. An array in `.rodata` depends on nothing at all: the bootloader already placed it in memory, and reading it is a subscript.

Skip this stage and Stages 1.3 through 1.7 have nothing to draw with. Get the *data path* wrong here — hand-paste the array, or parse a file at runtime — and you will pay for it in [[Phase 4 - Overview|Phase 4]], when the print path breaks in the middle of debugging the allocator that the print path now depends on.

---

## 2. The concept

### 2.1 A glyph is a picture, stored as bits

A **bitmap font** contains, for each character, a small rectangle of pixels. Ours is **8 pixels wide by 16 pixels tall**. That is 128 pixels. Each pixel is one of two states — *ink* or *paper*, foreground or background — so one pixel is one bit, and one glyph is 128 bits, which is exactly **16 bytes**.

The 16 bytes are the 16 **scanlines**, top row first. Each byte is one horizontal row of 8 pixels. 8 pixels is exactly one byte, which is not an accident — it is the whole reason 8 is the width. Nothing straddles a byte boundary, no bit-unpacking across bytes, no remainder arithmetic.

Within a scanline byte, **bit 7 (`0x80`) is the leftmost pixel** and bit 0 (`0x01`) is the rightmost. That is the convention every VGA-derived and PSF font uses, and it reads naturally: write the byte in binary and the ones are where the ink is.

Here is one glyph, drawn out. (The exact bytes depend on which font you install; this is a representative `A` and the format is what matters.)

```
   one glyph, 8 x 16 pixels                  the same glyph, 16 bytes
   ------------------------                  ------------------------
   col: 0 1 2 3 4 5 6 7
        . . . . . . . .   row  0             0x00   0 0 0 0 0 0 0 0
        . . . . . . . .   row  1             0x00   0 0 0 0 0 0 0 0
        . . . # . . . .   row  2             0x10   0 0 0 1 0 0 0 0
        . . # # # . . .   row  3             0x38   0 0 1 1 1 0 0 0
        . # # . # # . .   row  4             0x6C   0 1 1 0 1 1 0 0
        # # . . . # # .   row  5             0xC6   1 1 0 0 0 1 1 0
        # # . . . # # .   row  6             0xC6   1 1 0 0 0 1 1 0
        # # # # # # # .   row  7             0xFE   1 1 1 1 1 1 1 0
        # # . . . # # .   row  8             0xC6   1 1 0 0 0 1 1 0
        # # . . . # # .   row  9             0xC6   1 1 0 0 0 1 1 0
        # # . . . # # .   row 10             0xC6   1 1 0 0 0 1 1 0
        # # . . . # # .   row 11             0xC6   1 1 0 0 0 1 1 0
        . . . . . . . .   row 12             0x00   0 0 0 0 0 0 0 0
        . . . . . . . .   row 13             0x00   0 0 0 0 0 0 0 0
        . . . . . . . .   row 14             0x00   0 0 0 0 0 0 0 0
        . . . . . . . .   row 15             0x00   0 0 0 0 0 0 0 0
        ^             ^
        bit 7 = 0x80  bit 0 = 0x01
        leftmost      rightmost
```

Read row 4 across: `0x6C` is `0110 1100`, and the ink is at columns 1, 2, 4, 5 — the two diagonal strokes of the `A`. Row 7 is `0xFE` = `1111 1110`, the crossbar, seven pixels wide with a one-pixel gap on the right so adjacent characters do not touch.

The right-hand column of every glyph is usually blank for exactly that reason: **the inter-character gap is part of the glyph**, not something the renderer adds. Same for the top two and bottom four rows — that is the line spacing, baked in. This is why you can draw glyphs back to back at `x`, `x+8`, `x+16` and get readable text with no gap logic anywhere.

### 2.2 256 glyphs, indexed by byte value

Stack 256 of those 16-byte glyphs, in index order, and you have a **4096-byte font**. Glyph *g*'s scanline *r* is at byte offset `g * 16 + r`.

The index is a **byte value**, 0 to 255. Not a Unicode code point, not a `char`. For the ASCII range it coincides with ASCII, so `'A'` (0x41) is at glyph 65. Above 0x7F the meaning depends on the font's code page; a classic VGA font is **CP437**, where 0xB0 is a light shade block and 0xDB is a solid block — the characters that make box-drawing and progress bars possible.

In C++ this is a two-dimensional array:

```cpp
const uint8_t font8x16[256][16];
//                     ^^^^ glyph index    ^^ scanline
```

`font8x16[c]` is a `const uint8_t*` to that glyph's 16 scanlines. The compiler does the `* 16` for you.

### 2.3 Rendering is two nested loops

To draw glyph *g* with its top-left corner at pixel (`x`, `y`):

```
for row in 0..15:
    bits = font8x16[g][row]
    for col in 0..7:
        if bits has bit (7 - col) set:
            put_pixel(x + col, y + row, foreground)
        else:
            put_pixel(x + col, y + row, background)
```

128 `put_pixel` calls per character. That is the entire algorithm.

The only part that is easy to get wrong is testing "bit (7 - col)". Written directly:

```cpp
if (bits & (0x80 >> col))     // col 0 -> 0x80, col 7 -> 0x01
```

`0x80 >> col` walks the mask **left to right** as `col` increases, which matches the pixel order. The natural-looking alternative, `1 << col`, walks it **right to left** and mirrors every glyph horizontally. See §7 — it is the single most common bug in this stage.

### 2.4 The build-time pipeline

The kernel never sees a font *file*. A host program reads the blob and writes a `.cpp`; that `.cpp` is compiled and linked like any other kernel source.

```
   tools/mkfont/vga8x16.fnt         4096 bytes, checked into git
            |
            |  build time, on the HOST, with the NATIVE compiler
            v
   build/host-tools/bin/mkfont      an ordinary Linux program.
            |                       Uses <fstream>, <vector>, <string>.
            v
   build/kernel/generated/font8x16.cpp
            |
            |  x86_64-elf-g++ -ffreestanding -nostdinc++ -mno-red-zone ...
            v
   const uint8_t font8x16[256][16]  in .rodata, inside kernel.elf
            |
            |  runtime: one array subscript. No parse. No file. No malloc.
            v
   fb_putchar('A', ...)  ->  128 put_pixel() calls
```

The asymmetry across the middle of that diagram is the teaching point of this stage. **`mkfont` is a host program and may use the entire C++ standard library. The kernel may not use any of it.** Same repository, same `.cpp` extension, same language standard, two completely different environments — and the build system is what keeps them apart. This is the "three toolchains, one tree" rule from [[Stage 0.8 - The Build System]], and `mkfont` is the first time you actually build something in the third one.

### 2.5 Monospace makes the console a grid

Because every glyph occupies exactly 8x16 pixels, the framebuffer becomes a character grid with no bookkeeping:

```
   framebuffer, 1024 x 768 pixels        the console it becomes
   +------------------------------+      +-------------------------+
   |                              |      | col 0  col 1 ...  col 127|
   |   every cell is 8 x 16,      |  =>  | row  0                   |
   |   always, for every glyph    |      | row  1                   |
   |                              |      |  ...                     |
   +------------------------------+      | row 47                   |
                                         +-------------------------+

   pixel x of column c = c * 8            columns = fb_width  / 8
   pixel y of row    r = r * 16           rows    = fb_height / 16
```

Everything in [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] and [[Stage 1.4 - Double Buffering]] rests on this: a cursor is two small integers, scrolling is one `memmove` of `16 * pitch` bytes, and clearing a cell is drawing a space with an opaque background. None of that survives variable-width glyphs. §3 has the full argument.

---

## 3. Design decisions and tradeoffs

### Decision: where do the glyph pictures come from?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Embedded bitmap array (chosen)** | 4 KiB `const uint8_t[256][16]` linked into `.rodata`, generated at build time | Fixed size, fixed glyph set, no Unicode beyond one code page | ✅ |
| Parse a PSF file at runtime | Font arrives as a bootloader module or a file on disk; the kernel reads a header and points at the glyph data | Needs a module list or a filesystem, a parser, and error handling *in the one code path you need most when debugging* | ❌ |
| TrueType / OpenType | Scalable outlines, hinted, rasterised on demand at any size | Needs floating point — which this kernel cannot execute — plus a rasteriser, a glyph cache, and a heap | ❌ |

**Why the embedded array.** Count what it needs at runtime: nothing. The bootloader loaded the kernel image; the array is already in memory at a known address; reading it is a subscript against a compile-time constant base. There is no failure mode. Contrast that with the dependency list in §1 — no filesystem until [[Phase 7 - Overview|Phase 7]], no heap until [[Phase 4 - Overview|Phase 4]], no IDT until [[Phase 2 - Overview|Phase 2]] — and the choice makes itself.

The deeper argument is the one about dependency order. Printing is how you debug everything else, so the print path must sit *below* everything else in the dependency graph. The moment the console depends on the allocator, debugging the allocator by printing becomes a circular problem, and you are back to blinking an LED. 4 KiB in `.rodata` buys permanent immunity from that.

**Why not parsing PSF at runtime.** It is not hard, and Limine will happily hand you a font as a boot module, so this is a real option rather than a straw man. It fails on the dependency-inversion argument above: the debug path now depends on the module request being present in the request section, on Limine's response being non-null, on the module actually being in the ISO, and on a parser you wrote at 2am. Each of those has a failure mode whose symptom is *a blank screen*, which is indistinguishable from the framebuffer bug you were actually trying to find.

And nothing is gained. Runtime parsing only pays when you want to change the font *without rebuilding the kernel* — which, for a project where changing anything means rebuilding the kernel, is not a thing you will ever want.

**When runtime loading would be right.** When the font is user-selectable (a real console with `setfont`), or when you need glyph coverage that would be megabytes if embedded — CJK, or a full Unicode BMP. At that point the font becomes a resource loaded from a filesystem. Note how Linux resolves this: it compiles several bitmap fonts *into* the kernel (`drivers/video/console/font_8x16.c` and friends) as the console that always works, and supports loading a different one later from userspace. The embedded font is the floor, not the ceiling.

**Why not TrueType — and why the reason is absolute.** Scalable outlines are described by quadratic Bézier curves and rasterised with coverage arithmetic. That is floating-point-shaped work. This kernel is compiled with `-mno-sse -mno-mmx -mno-80387`, and that is not a preference:

- The x86-64 FP and SSE register files are **per-task state**. Using them in the kernel means saving and restoring them on every interrupt and every context switch, or carefully proving you never touch them across a preemption point. That is an `XSAVE`/lazy-FPU design conversation, and it belongs in [[Phase 12 - Overview|Phase 12]] and [[Phase 13 - Overview|Phase 13]], not in Stage 1.2.
- Whether SSE is even *usable* at kernel entry depends on what the bootloader left in `CR0` and `CR4` — check the machine-state section of Limine's `PROTOCOL.md` before assuming either way. It does not matter, because there is no IDT until [[Phase 2 - Overview|Phase 2]], so a `#UD` or `#NM` right now is a triple fault: the machine reboots, instantly, with no message.
- Most usefully, the argument never reaches runtime. With those flags GCC **refuses to compile** code that needs an FP register: `error: SSE register return with SSE disabled`. The decision is enforced by the compiler on every translation unit.

So: no floats, therefore no outline rasteriser, therefore no TrueType, no OpenType, no signed-distance-field tricks. Ruling out an entire branch of font technology in one line is worth doing early and out loud, because otherwise you will rediscover it three hours into a library port.

**When that flips.** A graphical desktop with real typography. The correct home for that is **userspace**, where floating point is allowed, there is a heap, and a crash kills one process instead of the machine. It is not the kernel log.

---

### Decision: how does the array get into the tree?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Generate at build time with `tools/mkfont` (chosen)** | A real font file is the source of truth; a host tool emits the `.cpp` into `build/` | One more host tool; one more dependency chain to get right | ✅ |
| Commit a hand-written array | Paste 4096 numbers into `kernel/drivers/char/font8x16.cpp` and never touch it again | The source of truth becomes a wall of hex nobody can review, regenerate, or change | ❌ |
| `objcopy -I binary -O elf64-x86-64` | Wraps the raw blob in an object file with auto-generated `_binary_..._start/_end/_size` symbols | Path-derived symbol names, no type, no header, no validation, no readable diff | ❌ |

**Why generate.** Three properties, each of which you will use.

*The source of truth stays a font.* `tools/mkfont/vga8x16.fnt` can be opened in a font editor, diffed against upstream, and replaced wholesale. A hex array cannot.

*It is reproducible.* Same blob in, same bytes out, every time, on every machine. `mkfont` reads no clock, no environment, no locale, and no absolute path. That is what makes `make verify-repro` ([[08 - Build System]]) a meaningful check rather than a coin flip.

*The output is reviewable.* Because you control the emitter, the generated file gets one line per glyph with the index and character in a comment:

```cpp
    /* 0x41 'A' */ { 0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, ... },
```

Change a font and the diff tells you *which characters changed*. That is the property `objcopy` cannot give you at any price.

**Why not commit the array.** Be fair to it: it works, it is what most tutorials do, and it removes a build step. The bill arrives later. A year from now you want a different font, or a fixed glyph, and the only route back to a font file is to write the tool you skipped — except now you must also verify that the array you are replacing matched the file you think it did. And in the meantime every font change is a 4096-number diff with no way to see what it did.

**Why not `objcopy`.** This is the real competitor and deserves the detail. The invocation is:

```sh
x86_64-elf-objcopy -I binary -O elf64-x86-64 -B i386:x86-64 \
    tools/mkfont/vga8x16.fnt font.o
```

It produces an object file whose contents are the raw bytes, with three symbols named after the **input path**, with every character that is not alphanumeric replaced by an underscore:

```
_binary_tools_mkfont_vga8x16_fnt_start
_binary_tools_mkfont_vga8x16_fnt_end
_binary_tools_mkfont_vga8x16_fnt_size
```

Four things follow, and they are all bad:

1. **The symbol name is a function of the file's path.** Move the font, rename it, or invoke `objcopy` from a different working directory, and the kernel stops linking with an undefined reference to a name nobody typed.
2. **There is no header and no type.** You write `extern "C" const uint8_t _binary_..._start[];` by hand — an unsized 1-D array. All the `* 16` arithmetic the compiler was doing for you is now yours to get right, and there is no `[256][16]` for it to check against.
3. **There is no validation.** A truncated or CRLF-mangled blob links perfectly and draws confetti. `mkfont` refuses to write output unless the input is exactly 4096 bytes, and that check has caught more real problems than any other line in the tool.
4. **The diff is unreadable.** A binary blob in git shows as `Binary files differ`.

Sixty lines of C++ buys you a chosen symbol name, a declared two-dimensional type the compiler enforces, a size assertion, and a diff a human can review.

**When `objcopy` is right.** For a large opaque payload where none of those four things matter — an initrd image, a compressed firmware blob, a disk template. Then the content is not meant to be read by anyone, and `objcopy` is one line of CMake instead of a program. Use it there; do not use it for structured data you will want to inspect.

**A note on `#embed`.** C23 (and C++26) add `#embed`, which would let the preprocessor pull the blob in directly. It is not available in the pinned GCC 14.2.0 ([[ADR-0005 - Containerised Pinned Toolchain]]), so it is not an option here. Even when it is, it gives you a flat comma-separated byte sequence — the same untyped, unvalidated, unreviewable blob as `objcopy`, just spelled differently.

---

### Decision: monospace 8x16, or proportional?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **Monospace 8x16 (chosen)** | Every glyph occupies an identical cell; character (col, row) is at pixel (col·8, row·16) | Aesthetically inferior; `W` is cramped and `i` is lonely | ✅ |
| Proportional | Per-glyph width and advance; `x` moves by a variable amount after each character | Cursor position stops being derivable from a column index; scroll, erase, backspace and overwrite all become per-glyph problems | ❌ |

**Why monospace.** The console is a grid, and every remaining stage in [[Phase 1 - Overview|Phase 1]] assumes it:

| Operation | With monospace | With proportional |
|---|---|---|
| Address of cell (c, r) | `c * 8`, `r * 16` — two multiplies, no state | requires the widths of every glyph to the left of `c` on that row |
| Grid dimensions | `fb_width / 8` by `fb_height / 16`, constant for the boot | undefined; depends on what is on the line |
| Scroll one line (1.3) | one `memmove` of `16 * pitch` bytes | same, but the cursor's column must be recomputed |
| Overwrite a cell | draw the new glyph with opaque background — done | a narrower glyph leaves the right-hand pixels of the old one behind |
| Backspace | `col -= 1`, redraw a space | must know the width of the glyph you are erasing, so you must remember what it was |
| Aligned hex dumps, `%-16s` | works | does not |

The last row is the honest one. Kernel logs are read as **columns**: register dumps, page-table entries, memory maps, aligned field widths from `kprintf` ([[Stage 1.6 - kprintf]]). Proportional type makes those actively harder to read. You would be spending real complexity to make your most important diagnostic output worse.

**Why 8x16 rather than 8x8.** Two reasons. Width 8 means one scanline is exactly one byte, so no bit spans a byte boundary anywhere in the renderer or the generator. Height 16 is legible on a modern panel: at 1920x1080 you get 240 x 67 characters, which is a comfortable density; 8x8 gives 240 x 135, which is a wall of ants on a 15-inch laptop screen.

**When proportional would be right.** A GUI, in userspace, in [[Phase 15 - Overview|Phase 15]] or beyond. Never in the kernel log.

---

### Decision: where does the generator live — a host C++ tool, a Python script, or checked-in output?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **`tools/mkfont`, host C++ (chosen)** | Built by the **native** compiler in a nested CMake project; run by `add_custom_command` | A second CMake project and some `ExternalProject` boilerplate | ✅ |
| A Python script in `scripts/` | `python3 scripts/mkfont.py in.fnt out.cpp` | Adds an interpreter to the build's dependency surface; nothing type-checks it | ❌ |
| Check the generated `.cpp` into git | Run the generator by hand once, commit the result | Input and output drift silently; 256 lines of noise in every blame and diff | ❌ |

**Why host C++.** This is the concrete instance of "three toolchains, one tree" from [[Stage 0.8 - The Build System]]. The repository contains code for three genuinely different environments, and `mkfont` is the first thing you build in the third one:

| Target | Toolchain | Standard library | Runs on |
|---|---|---|---|
| Kernel | `cmake/x86_64-kernel.cmake` | none — `-nostdinc++`, freestanding | the target machine, ring 0 |
| Userspace ([[Phase 6 - Overview\|Phase 6]]) | `cmake/x86_64-user.cmake` | our own libc | the target machine, ring 3 |
| **`tools/`, Tier-1 tests** | **native — no toolchain file** | **the real one** | **your laptop, and CI** |

Making `mkfont` a first-class CMake target in the third column means it gets `-Wall -Wextra -Werror` like everything else, it can grow a Tier-1 unit test, `clang-format` covers it (`scripts/lint.sh` already globs `tools/`), and — most importantly — **getting the toolchain wrong fails loudly**. See the trap in §7: a cross-compiled `mkfont` dies at `#include <fstream>` with a message that names the actual problem. A silent failure here would be far worse, because the symptom would surface as a wrong font two stages later.

The rule to carry forward: **`tools/` is never compiled with the cross-compiler.** `mkinitrd` ([[Phase 7 - Overview|Phase 7]]), `symbolise` ([[Stage 1.7 - Symbolised Backtraces]]) and `gdbinit-gen` all use the wiring you write here. Getting it right once makes each of those a two-line addition.

**Why not Python.** Python is genuinely better *at this task* — the whole generator is about twenty lines. The objection is not about the language, it is about the build's dependency surface. [[ADR-0005 - Containerised Pinned Toolchain]] exists so that every build on every machine runs identical binaries, and that guarantee is only as strong as the least-pinned thing participating in the build. Python 3 *is* in the toolchain image (the Tier-3 `pexpect` tests need it), so this is a close call rather than an obvious one.

The tiebreaker is that a compiled tool is checked before it runs. A typo in `mkfont.cpp` is a build error that stops the build with a file and a line number; the same typo in a Python script is a `NameError` in the middle of a build, on a rarely-taken branch, possibly only in CI. In a program whose entire job is to be correct before anything else runs, that asymmetry is worth more than the forty lines it costs.

**The honest counter.** If this project already had five Python build scripts, adding a sixth would be correct and the C++ tool would be the odd one out. Consistency inside a build system is worth more than the marginal argument for either language.

**Why not commit the generated file.** It decouples the output from its input, and nothing then forces them to agree. Someone edits the blob, forgets to regenerate, and the kernel keeps drawing the old glyphs with no signal at all — the build succeeds, the tests pass, and the screen is subtly wrong. On top of that, a 256-line generated file in the source tree shows up in every `git blame`, every diff, and every code review of anything nearby.

The general rule, which applies to `initrd.tar` and the symbol table too: **generated artefacts live in `build/`, never in the source tree.** That is also why `.gitignore` needs no entry for `font8x16.cpp` — it is never anywhere git can see it.

---

## 4. Specification

### The font blob

| Property | Value |
|---|---|
| Path | `tools/mkfont/vga8x16.fnt` |
| Size | **exactly** 4096 bytes — `mkfont` refuses anything else |
| Contents | 256 glyphs, contiguous, in index order, no header |
| Glyph size | 16 bytes: one byte per scanline, **top scanline first** |
| Offset of glyph `g`, scanline `r` | `g * 16 + r` |
| Bit meaning | set = foreground (ink), clear = background (paper) |
| Bit order | bit 7 (`0x80`) is the **leftmost** pixel, bit 0 (`0x01`) the rightmost |

### Column-to-mask table

The whole rendering loop hinges on this. `col` is the pixel column within the glyph, left to right.

| `col` | expression | mask | bit number |
|---|---|---|---|
| 0 | `0x80 >> 0` | `0x80` | 7 |
| 1 | `0x80 >> 1` | `0x40` | 6 |
| 2 | `0x80 >> 2` | `0x20` | 5 |
| 3 | `0x80 >> 3` | `0x10` | 4 |
| 4 | `0x80 >> 4` | `0x08` | 3 |
| 5 | `0x80 >> 5` | `0x04` | 2 |
| 6 | `0x80 >> 6` | `0x02` | 1 |
| 7 | `0x80 >> 7` | `0x01` | 0 |

Equivalent formulation: `(bits >> (7 - col)) & 1`. Both are correct. `1 << col` is **not** — it produces the table above reversed, and mirrors every glyph.

### The generated file's contract

| Item | Value |
|---|---|
| Path | `build/kernel/generated/font8x16.cpp` (never in the source tree) |
| Symbol | `font8x16` |
| Type | `const uint8_t[256][16]` |
| Linkage | **external** — an explicit `extern` declaration is mandatory in C++ |
| Section | `.rodata` |
| Size | 4096 bytes; `nm -S` reports `0000000000001000` |
| Includes | `<stdint.h>` only — it is compiled with the kernel flags, so no libstdc++ |

> **Why the `extern` matters.** In C, a `const` object at file scope has *external* linkage. In C++ it has **internal** linkage unless you say otherwise. So `const uint8_t font8x16[256][16] = {...};` alone compiles into a `static`-equivalent symbol the kernel cannot reach, and you get `undefined reference to 'font8x16'` from a file that visibly defines it. `mkfont` emits an `extern` declaration immediately before the definition; the definition then inherits external linkage from it.

### Grid geometry

| Quantity | Expression | at 1920x1080 | at 1024x768 |
|---|---|---|---|
| Columns | `fb_width() / FONT_WIDTH` | 240 | 128 |
| Rows | `fb_height() / FONT_HEIGHT` | 67 | 48 |
| Pixel `x` of column `c` | `c * FONT_WIDTH` | | |
| Pixel `y` of row `r` | `r * FONT_HEIGHT` | | |

### What [[Stage 1.1 - The Linear Framebuffer]] must already provide

This stage builds directly on it. If your names differ, use yours and adapt the code below.

| Symbol | Meaning |
|---|---|
| `void put_pixel(uint32_t x, uint32_t y, uint32_t colour)` | Writes one pixel, handling `pitch` correctly |
| `uint32_t fb_width()` | Framebuffer width in pixels |
| `uint32_t fb_height()` | Framebuffer height in pixels |
| colour encoding | whatever Stage 1.1 established; on a 32-bpp framebuffer with the usual masks, `0x00RRGGBB` |

### Where the font blob comes from

You need a raw 4096-byte 8x16 font. Real, obtainable sources:

| Font | Where | Licence |
|---|---|---|
| Spleen 8x16 | <https://github.com/fcambus/spleen> (`spleen-8x16.psfu`) | BSD 2-clause |
| Terminus `ter-116n` | <https://terminus-font.sourceforge.net/> | SIL OFL 1.1 |
| Debian/Ubuntu console fonts | `/usr/share/consolefonts/*.psf.gz` | varies per file |
| IBM VGA 8x16 (exact original metrics) | <https://int10h.org/oldschool-pc-fonts/> | CC BY-SA 4.0 |

**Copy the licence text into `tools/mkfont/` and name the source in a `README.md` there.** A font you cannot ship is a problem you find at release time, which is the worst possible time to find it.

Most of these ship as PSF, which has a header you must strip. `mkfont` deliberately does not parse PSF — the conversion is a one-off, and a one-off does not belong in the build:

```sh
# PSF1: 4-byte header (magic 0x36 0x04, mode, charsize).
dd if=font.psf of=tools/mkfont/vga8x16.fnt bs=1 skip=4 count=4096

# PSF2: header size is a little-endian uint32 at offset 8 (normally 32).
hdr=$(od -An -tu4 -j8 -N4 font.psf | tr -d ' ')
dd if=font.psf of=tools/mkfont/vga8x16.fnt bs=1 skip="$hdr" count=4096
```

`count=4096` is what discards a `.psfu` file's trailing Unicode table, and `mkfont`'s size check is what tells you if you got the header size wrong. Note that a PSF2 font need not be CP437-ordered above 0x7F — check what you actually get at 0xB0 and 0xDB before assuming box-drawing characters.

---

## 5. Writing the code

### `tools/mkfont/mkfont.cpp`

The host generator. Reads the 4096-byte blob, writes a compilable C++ source file.

```cpp
// mkfont - converts a raw 8x16 bitmap font blob into a C++ source file that
// the kernel links directly into its image.
//
// THIS IS A HOST PROGRAM. It is compiled by the NATIVE compiler and runs on the
// build machine, never on the target. It may therefore use the entire C++
// standard library - which the kernel may not. That asymmetry is the point of
// tools/: do the parsing here, where parsing is cheap and safe, and hand the
// kernel a plain array.
//
// usage: mkfont <input.fnt> <output.cpp> [symbol]
//
// See steps/Phase 1 - Text Output/Stage 1.2 - Rasterising a Bitmap Font.

#include <cstddef>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

namespace {

constexpr std::size_t GLYPH_WIDTH  = 8;    // pixels per scanline - exactly one byte
constexpr std::size_t GLYPH_HEIGHT = 16;   // scanlines per glyph
constexpr std::size_t GLYPH_COUNT  = 256;  // one glyph per possible byte value
constexpr std::size_t BLOB_SIZE    = GLYPH_COUNT * GLYPH_HEIGHT;  // 4096

std::string hex_byte(unsigned char v) {
    constexpr char DIGITS[] = "0123456789ABCDEF";
    return std::string("0x") + DIGITS[v >> 4] + DIGITS[v & 0x0FU];
}

// A printable character for the trailing comment, or a dot. Deliberately does
// NOT use isprint(): that is locale-dependent, and a locale-dependent build
// tool is a non-reproducible build tool.
char comment_char(std::size_t index) {
    return (index >= 0x20 && index < 0x7F) ? static_cast<char>(index) : '.';
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) {
        std::cerr << "usage: mkfont <input.fnt> <output.cpp> [symbol]\n";
        return 2;
    }

    const std::string in_path  = argv[1];
    const std::string out_path = argv[2];
    const std::string symbol   = (argc == 4) ? argv[3] : "font8x16";

    std::ifstream in(in_path, std::ios::binary);
    if (!in) {
        std::cerr << "mkfont: cannot open " << in_path << '\n';
        return 1;
    }

    const std::vector<unsigned char> blob((std::istreambuf_iterator<char>(in)),
                                          std::istreambuf_iterator<char>());

    if (blob.size() != BLOB_SIZE) {
        std::cerr << "mkfont: " << in_path << " is " << blob.size() << " bytes, expected "
                  << BLOB_SIZE << " (" << GLYPH_COUNT << " glyphs x " << GLYPH_HEIGHT
                  << " scanlines of " << GLYPH_WIDTH << " pixels)\n";
        return 1;
    }

    // Only the BASENAME goes into the output. An absolute path would differ
    // between build directories and break reproducible builds.
    const std::size_t slash = in_path.find_last_of("/\\");
    const std::string base  = (slash == std::string::npos) ? in_path : in_path.substr(slash + 1);

    std::ofstream out(out_path, std::ios::binary | std::ios::trunc);
    if (!out) {
        std::cerr << "mkfont: cannot write " << out_path << '\n';
        return 1;
    }

    out << "// GENERATED FILE - DO NOT EDIT.\n"
        << "// Produced by tools/mkfont from " << base << ".\n"
        << "//\n"
        << "// Layout: [glyph][scanline]. Bit 0x80 is the LEFTMOST pixel of a scanline.\n"
        << "\n"
        << "#include <stdint.h>\n"
        << "\n"
        << "// The `extern` is load-bearing. In C++ a const object at namespace scope has\n"
        << "// INTERNAL linkage by default; without this declaration the kernel fails to\n"
        << "// link with `undefined reference to " << symbol << "`.\n"
        << "extern const uint8_t " << symbol << "[" << GLYPH_COUNT << "][" << GLYPH_HEIGHT
        << "];\n"
        << "\n"
        << "const uint8_t " << symbol << "[" << GLYPH_COUNT << "][" << GLYPH_HEIGHT << "] = {\n";

    for (std::size_t g = 0; g < GLYPH_COUNT; ++g) {
        out << "    /* " << hex_byte(static_cast<unsigned char>(g)) << " '" << comment_char(g)
            << "' */ {";
        for (std::size_t row = 0; row < GLYPH_HEIGHT; ++row) {
            out << (row == 0 ? " " : ", ") << hex_byte(blob[g * GLYPH_HEIGHT + row]);
        }
        out << " },\n";
    }

    out << "};\n";
    out.flush();

    if (!out) {
        std::cerr << "mkfont: write failed for " << out_path << '\n';
        return 1;
    }
    return 0;
}
```

#### Line by line

**The header comment**

It exists to answer one question for whoever opens this file next: *why does a kernel project contain a program that includes `<fstream>`?* Without that paragraph, someone will "fix" this file by removing the standard-library includes, because [[13 - Coding Standards]] says the kernel has none. State the boundary at the top of every file in `tools/`.

**Lines: the includes**

```cpp
#include <cstddef>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
```

All six are forbidden in kernel code and all six are fine here. `<iterator>` is for `std::istreambuf_iterator` — easy to omit, because it often arrives transitively through `<fstream>` on libstdc++ and then fails on a different standard library. Include what you use ([[13 - Coding Standards]]).

Note what is *not* here: `<cstdint>`. `uint8_t` appears only inside string literals we emit, never in this program's own types, so we do not need it.

**The constants**

```cpp
constexpr std::size_t GLYPH_WIDTH  = 8;
constexpr std::size_t GLYPH_HEIGHT = 16;
constexpr std::size_t GLYPH_COUNT  = 256;
constexpr std::size_t BLOB_SIZE    = GLYPH_COUNT * GLYPH_HEIGHT;  // 4096
```

In an anonymous namespace, so they have internal linkage and no chance of colliding if this file ever grows a second translation unit. `BLOB_SIZE` is derived rather than written as `4096` so that changing the height to 8 or 32 changes exactly one line — and so the error message and the check can never disagree.

`GLYPH_WIDTH` is used only in the error message. Keep it: the error text explains the shape of the file the user got wrong, and 8 is a real constraint (one byte per scanline), not a coincidence.

**`hex_byte`**

```cpp
std::string hex_byte(unsigned char v) {
    constexpr char DIGITS[] = "0123456789ABCDEF";
    return std::string("0x") + DIGITS[v >> 4] + DIGITS[v & 0x0FU];
}
```

Manual formatting rather than `std::hex`. Three reasons: `std::hex` is sticky on the stream so you must remember to reset it; it needs `std::setw`/`std::setfill` to get a leading zero, so `0x0A` does not come out as `0xA`; and stream formatting can in principle be perturbed by the global locale, whereas this cannot be. Every byte comes out as exactly four characters, so the generated file's columns line up and diffs are readable.

`v >> 4` promotes `v` to `int` before shifting — fine for a value that is at most 255. `v & 0x0FU` masks the low nibble.

**`comment_char`**

```cpp
char comment_char(std::size_t index) {
    return (index >= 0x20 && index < 0x7F) ? static_cast<char>(index) : '.';
}
```

The printable ASCII range is 0x20 (space) through 0x7E (`~`); 0x7F is DEL and is not printable. Everything else becomes `.`.

The comment about `isprint()` is the point of the function. `isprint` consults the current locale, so its answer for bytes 0x80–0xFF depends on the environment the build ran in — and a build tool whose output depends on `LC_ALL` is a build tool that breaks reproducibility. This is the same class of problem as `__DATE__`, which `scripts/lint.sh` already greps for.

**Argument handling**

```cpp
if (argc < 3 || argc > 4) {
    std::cerr << "usage: mkfont <input.fnt> <output.cpp> [symbol]\n";
    return 2;
}
```

`argc > 4` matters as much as `argc < 3`. Silently ignoring a fourth argument is how someone spends twenty minutes wondering why `--verbose` did nothing.

Exit code 2 for a usage error, 1 for an operational failure, 0 for success — the conventional split, and it lets a wrapper script tell "you invoked me wrong" from "the input was bad". Any non-zero exit fails the build, which is the behaviour you want: a build that continues after its code generator failed produces a kernel with a stale font and no warning.

**Reading the blob**

```cpp
const std::vector<unsigned char> blob((std::istreambuf_iterator<char>(in)),
                                      std::istreambuf_iterator<char>());
```

The idiomatic "read a whole binary file" construction: an iterator pair over the stream's buffer, default-constructed `istreambuf_iterator` being the end sentinel.

**The extra parentheses around the first argument are required**, and this is the single most confusing line in the file. Without them the compiler parses the whole statement as a *function declaration* — a function called `blob` taking a stream iterator and a function pointer, returning a vector. This is C++'s "most vexing parse", and the error it produces is about `blob` not being a vector, thirty lines later, which is unhelpful. The parentheses make the first argument unambiguously an expression.

`std::ios::binary` on the `ifstream` is not optional. On Windows without it, every `0x0D 0x0A` in the font data is silently collapsed to `0x0A` and the blob comes back short. The build runs in a Linux container so it does not bite today, but a teammate running the tool by hand on Windows would hit it.

`unsigned char`, not `char`, for the element type. The bytes are values 0–255, and the moment they are `char` they are *signed* on this platform and every subsequent operation has to remember that. Fixing it at the point of entry is cheaper than fixing it everywhere. Same principle as `fb_putchar`'s cast — see §7.

**The size check**

```cpp
if (blob.size() != BLOB_SIZE) {
    std::cerr << "mkfont: " << in_path << " is " << blob.size() << " bytes, expected "
              << BLOB_SIZE << " (" << GLYPH_COUNT << " glyphs x " << GLYPH_HEIGHT
              << " scanlines of " << GLYPH_WIDTH << " pixels)\n";
    return 1;
}
```

The most valuable six lines in the tool, and the thing `objcopy` cannot do.

Any wrong size is a wrong font. 4100 means a PSF1 header you did not strip. 4128 means a PSF2 header. 8192 means a 512-glyph font. Anything a few bytes over means end-of-line conversion mangled a binary file in git. Without this check every one of those produces a *plausible-looking* font whose glyphs are shifted, and you debug your rendering loop for an hour before suspecting the data.

The message prints both the actual size and the expected one, plus the shape that produces it, because "expected 4096" alone does not tell a first-time reader why.

**The basename**

```cpp
const std::size_t slash = in_path.find_last_of("/\\");
const std::string base  = (slash == std::string::npos) ? in_path : in_path.substr(slash + 1);
```

CMake passes an absolute path, so `in_path` is something like `/os/tools/mkfont/vga8x16.fnt`. Emitting that into the generated file would make the output depend on where the repository is checked out, which breaks the reproducibility guarantee in [[08 - Build System]] and makes `make verify-repro` fail with a diff nobody can interpret.

Only the basename is emitted, and it is the only part that carries information anyway. `find_last_of("/\\")` handles both separators so the tool behaves the same if someone runs it natively on Windows.

**Opening the output**

```cpp
std::ofstream out(out_path, std::ios::binary | std::ios::trunc);
```

`binary` again, so the output has LF line endings on every platform — the repository is `eol=lf` throughout (`.gitattributes`), and a generated file with CRLF would produce a spurious difference between two builds. `trunc` is the default for `ofstream` but stating it makes the intent explicit: this file is replaced wholesale, never appended to.

**The file header**

```cpp
out << "// GENERATED FILE - DO NOT EDIT.\n"
    << "// Produced by tools/mkfont from " << base << ".\n"
```

Someone will find this file in `build/`, fix a glyph in it, rebuild, and watch their fix vanish. The banner is for them. Naming the producer and the input tells them where the fix actually goes.

Notice what is absent: no date, no time, no user, no host, no version string. Each of those would make consecutive builds differ. `scripts/lint.sh` greps the source tree for `__DATE__` and `__TIME__` for exactly this reason; a generator that stamps a timestamp defeats that rule from outside the tree where the grep cannot see it.

**The declaration and definition**

```cpp
    << "extern const uint8_t " << symbol << "[" << GLYPH_COUNT << "][" << GLYPH_HEIGHT
    << "];\n"
    << "\n"
    << "const uint8_t " << symbol << "[" << GLYPH_COUNT << "][" << GLYPH_HEIGHT << "] = {\n";
```

Two statements, and the first is not redundant. See the callout in §4: in C++, a namespace-scope `const` object has internal linkage by default. Emitting only the definition produces a symbol local to this translation unit, and the kernel fails to link against a file that visibly defines the array — a genuinely baffling error the first time you meet it. The `extern` declaration gives the name external linkage; the definition that follows inherits it.

The generated file includes only `<stdint.h>`, not `font.hpp`. That keeps it self-contained: it can be compiled with no include path beyond the compiler's own freestanding headers, which is one less thing for the CMake rule to get right. The cost is that the array's type is written down twice — here and in `font.hpp` — so keep them in step. If you would rather have exactly one declaration, give `mkfont` a fourth argument naming a header to `#include` and add the include directory to the kernel target.

**The glyph loop**

```cpp
for (std::size_t g = 0; g < GLYPH_COUNT; ++g) {
    out << "    /* " << hex_byte(static_cast<unsigned char>(g)) << " '" << comment_char(g)
        << "' */ {";
    for (std::size_t row = 0; row < GLYPH_HEIGHT; ++row) {
        out << (row == 0 ? " " : ", ") << hex_byte(blob[g * GLYPH_HEIGHT + row]);
    }
    out << " },\n";
}
```

One output line per glyph. This is the review argument from §3 made concrete:

```cpp
    /* 0x41 'A' */ { 0x00, 0x00, 0x10, 0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0xC6, 0x00, 0x00, 0x00, 0x00 },
```

Swap the font and `git diff` on the build output — or a side-by-side of two runs — names exactly which characters changed. A blob-in-an-object-file gives you `Binary files differ`.

`blob[g * GLYPH_HEIGHT + row]` is the offset formula from §4, written once, in the one place that reads the file.

The `(row == 0 ? " " : ", ")` trick puts the separator *before* each element except the first, which avoids a trailing comma inside the braces without a second loop or an index test at the end. A trailing comma would in fact be legal C++, but it reads as an accident.

**Flush and check**

```cpp
out.flush();

if (!out) {
    std::cerr << "mkfont: write failed for " << out_path << '\n';
    return 1;
}
```

Streams do not throw by default; they set a failure bit. Without this check, a full disk produces a *truncated* `.cpp`, `mkfont` exits 0, the build proceeds, and the compiler reports a syntax error at the last line of a generated file — which sends you looking for a bug in the generator's formatting instead of in the disk.

`flush()` before the test forces the buffered data out so the check covers the actual write, not just the buffering. The destructor would flush too, but by then `main` has returned and there is nowhere to report.

---

### The CMake wiring

Three files change. This is the part that is easy to get subtly wrong, and the failure mode — a font that does not regenerate — is silent.

#### `tools/CMakeLists.txt`

A **separate project**, configured by a **separate CMake process**, built with the **native** compiler.

```cmake
# Host tools. This is a SEPARATE CMake project on purpose.
#
# It is deliberately NOT add_subdirectory()'d from the top-level CMakeLists.txt.
# That configure ran with -DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake, so
# every target in it is built by x86_64-elf-g++ for a machine with no OS. A tool
# built there cannot run on the machine doing the building.
#
# See steps/08 - Build System, "Three toolchains, one tree", and Stage 0.8.

cmake_minimum_required(VERSION 3.20)

project(cracked_host_tools LANGUAGES CXX)

set(CMAKE_CXX_STANDARD          20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)

# NOTE: KernelFlags.cmake is deliberately NOT included. These are host binaries.
# They link the real libstdc++ and run on your laptop.
add_executable(mkfont mkfont/mkfont.cpp)
target_compile_options(mkfont PRIVATE -Wall -Wextra -Werror)
```

**`cmake_minimum_required` and `project()` again.** They are here because this genuinely is a different project, configured from scratch. If those lines look redundant, that is the signal you have understood the design: the top-level tree and this tree share a directory and nothing else.

**No `include(cmake/KernelFlags.cmake)`.** Applying `-ffreestanding -nostdinc++ -mcmodel=kernel` to `mkfont` would break it in three ways at once. The comment says so, because "the absence of a line" is invisible in review and someone will eventually add it for consistency.

**`-Wall -Wextra -Werror` kept.** Host tools get the same standard as the kernel. A build tool that silently does the wrong thing is worse than a kernel that crashes, because it fails quietly and misleads you about the kernel.

#### Top-level `CMakeLists.txt`

Add this block to the file from [[Stage 0.8 - The Build System]], **before** `add_subdirectory(kernel)`.

```cmake
# ---------------------------------------------------------------------------
# Host tools (tools/) - built with the NATIVE compiler via a nested CMake.
#
# ExternalProject_Add starts a SECOND, INDEPENDENT cmake configure in its own
# binary directory. It does not inherit this project's cache, flags, or
# toolchain file; it forwards the generator plus whatever CMAKE_ARGS lists. We
# name the host compiler explicitly anyway, so the result does not depend on
# CMake's forwarding rules.
# ---------------------------------------------------------------------------
include(ExternalProject)

set(HOST_TOOL_DIR ${CMAKE_BINARY_DIR}/host-tools/bin)
set(MKFONT        ${HOST_TOOL_DIR}/mkfont)

ExternalProject_Add(host_tools
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/tools
    BINARY_DIR ${CMAKE_BINARY_DIR}/host-tools
    CMAKE_ARGS
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_CXX_COMPILER=c++
        -DCMAKE_RUNTIME_OUTPUT_DIRECTORY=${HOST_TOOL_DIR}
    BUILD_ALWAYS     TRUE
    INSTALL_COMMAND  ""
    BUILD_BYPRODUCTS ${MKFONT}
)

add_subdirectory(kernel)
```

**`SOURCE_DIR ${CMAKE_SOURCE_DIR}/tools`** points the nested configure at `tools/CMakeLists.txt`. There is no `add_subdirectory(tools)` anywhere; that is the whole design. If you add one "so the IDE sees the files", you have just cross-compiled your host tools — see §7.

**`-DCMAKE_CXX_COMPILER=c++`** names the native compiler explicitly. `c++` resolves through `PATH` to the system compiler, which in the toolchain image is Ubuntu 24.04's `g++` from `build-essential`. This one line removes any dependence on what the parent process did or did not forward.

**`-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=${HOST_TOOL_DIR}`** pins where the binary lands. Without it you are guessing at the sub-build's layout, and the guess changes if `tools/CMakeLists.txt` ever grows a subdirectory. Same reasoning as `RUNTIME_OUTPUT_DIRECTORY` on `kernel.elf` in [[Stage 0.8 - The Build System]].

**`BUILD_ALWAYS TRUE`** is not optional, and its absence is a nasty bug. By default `ExternalProject` stamps its build step and never re-runs it — so you edit `mkfont.cpp`, rebuild, and *nothing happens*, forever, until you delete `build/`. With `BUILD_ALWAYS` the sub-build's Ninja runs on every build; when nothing changed that is a null build costing milliseconds, and `mkfont`'s timestamp does not move, so nothing downstream re-runs either.

**`INSTALL_COMMAND ""`** disables the install step. There is nothing to install; the tool is consumed in place from the build tree.

**`BUILD_BYPRODUCTS ${MKFONT}`** tells the parent's Ninja that this step produces that file. Ninja refuses to generate a build graph containing a file that nothing produces, so without this the next section's `DEPENDS ${MKFONT}` fails at *generate* time with `'build/host-tools/bin/mkfont', needed by ..., missing and no known rule to make it`. That error names a file that plainly does get built, which is confusing until you know the rule: Ninja only knows about outputs that were declared.

**`MKFONT` and `HOST_TOOL_DIR` are ordinary variables**, set before `add_subdirectory(kernel)`. CMake variables are inherited by subdirectories added after they are set, so `kernel/CMakeLists.txt` sees both. Set them after the `add_subdirectory` and they are empty in the kernel scope, and the custom command silently invokes the empty string.

#### `kernel/CMakeLists.txt`

The generation rule and the source-list entry.

```cmake
# --- the embedded font -----------------------------------------------------
#
# tools/mkfont turns the 4096-byte raw blob into a C++ source file, which is
# then compiled and linked like any other kernel source. Nothing is parsed at
# runtime: the kernel indexes an array in .rodata.

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

add_executable(kernel.elf
    arch/x86_64/boot/entry.cpp
    arch/x86_64/boot/boot_info.cpp
    drivers/char/serial.cpp
    drivers/char/fbcon.cpp
    lib/panic.cpp
    main.cpp
    ${FONT_GEN}                     # generated - produced by the rule above
)

# ... target_compile_options / include_directories / link_options as in Stage 0.8
```

**The custom command must live in this file.** A CMake `add_custom_command(OUTPUT ...)` is attached to the directory it appears in, and only a target in **that same directory** picks it up automatically. Put this block in the top-level `CMakeLists.txt` and `kernel.elf` will not see the rule; Ninja reports "no known rule" for the generated source, and the fix is not obvious from the message.

**`OUTPUT ${FONT_GEN}`** declares what this rule produces. Listing that same path in `add_executable` is what connects the two: CMake sees a source file it has a rule for, marks it `GENERATED`, and builds it before compiling.

**The `make_directory` command.** `mkfont` opens the output with `ofstream`, which creates a *file* but not the directories above it. The first build has no `build/kernel/generated/`, so the open fails and you get `mkfont: cannot write .../font8x16.cpp` — on a clean checkout only, which means it passes locally and fails in CI. `${CMAKE_COMMAND} -E make_directory` is CMake's portable `mkdir -p` and is idempotent.

**The `DEPENDS` line is the part to get right.** Three entries, three distinct jobs:

| Entry | Kind | What it buys |
|---|---|---|
| `${FONT_BLOB}` | file | Edit the font -> the rule re-runs. Omit it and **the font never updates**, which is the trap in §7. |
| `${MKFONT}` | file | Edit `mkfont.cpp` -> the tool relinks, its timestamp moves, the rule re-runs. Omit it and a fixed generator does not regenerate anything. |
| `host_tools` | target | Ordering: build the tool before running it. A file dependency alone does not order two targets. |

`${MKFONT}` as a file dependency is only accepted because of `BUILD_BYPRODUCTS` in the previous section. The two go together.

**`VERBATIM`** makes CMake quote the arguments correctly for the shell it ends up using. Without it, a path containing a space — `C:\Users\Some Name\os` on a native Windows build — splits into two arguments and `mkfont` reports a usage error. Always pass `VERBATIM`; there is no case where you want the other behaviour.

**`COMMENT`** is what Ninja prints for this step. It is how you *see*, in the build log, whether the font regenerated — which makes the §6 check a matter of reading one line rather than diffing files.

**`${FONT_GEN}` in the source list** is the last link in the chain. Generate the file but forget this line and you get `undefined reference to 'font8x16'` at link time, pointing at a file that exists and is correct and was simply never compiled.

**A reproducibility footnote.** The generated file lives under `${CMAKE_CURRENT_BINARY_DIR}`, so its absolute path differs between `build-repro-a` and `build-repro-b`. `-ffile-prefix-map` in the kernel flags normalises source paths in debug info; make sure the mapping covers the *build* directory as well as the source directory, or `make verify-repro` will report `kernel.elf` differing for a reason that has nothing to do with the font. Checking `cmp` on the two generated `.cpp` files (§6) isolates `mkfont`'s own determinism from that question.

---

### `kernel/drivers/char/font.hpp`

The kernel-side declaration of the generated array, plus the one accessor everything should go through.

```cpp
#pragma once

#include <stdint.h>

// The 8x16 bitmap font the console draws with.
//
// The array is GENERATED at build time by tools/mkfont from
// tools/mkfont/vga8x16.fnt and compiled into the kernel like any other source.
// There is no font file at runtime and no parser: by the time anything wants to
// print there is no filesystem (Phase 7), no heap (Phase 4), and no IDT
// (Phase 2), so any fault is a triple fault.
//
// Layout:  font8x16[glyph][scanline] is one row of 8 pixels.
//          bit 0x80 = leftmost pixel   ...   bit 0x01 = rightmost pixel
//
// See steps/Phase 1 - Text Output/Stage 1.2 - Rasterising a Bitmap Font.

inline constexpr uint32_t FONT_WIDTH  = 8;
inline constexpr uint32_t FONT_HEIGHT = 16;
inline constexpr uint32_t FONT_GLYPHS = 256;

// Defined in the generated font8x16.cpp. `extern` is REQUIRED: a const object
// at namespace scope has internal linkage in C++ unless it is declared extern.
extern const uint8_t font8x16[FONT_GLYPHS][FONT_HEIGHT];

// Always index the font through this. The parameter is `unsigned char` on
// purpose: it forces the char -> 0..255 conversion to happen at the call
// boundary, so a high-bit character can never index the array negatively.
inline const uint8_t* font_glyph(unsigned char code) {
    return font8x16[code];
}
```

#### Line by line

**`#pragma once`** — the house style ([[13 - Coding Standards]]). Include guards are noise.

**`#include <stdint.h>`, not `<cstdint>`.** There is no libstdc++ in the toolchain image, and `-nostdinc++` makes that fail immediately rather than picking up a host header ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]). `stdint.h` is one of the freestanding headers GCC provides itself, so it is available. This is the first thing that will trip you if you type this file from muscle memory.

**The header comment** records *where the array comes from*, because there is no `font8x16.cpp` in the source tree to find. Without this, the first person to grep for `font8x16` concludes the symbol does not exist.

**`inline constexpr uint32_t FONT_WIDTH = 8;`**

`constexpr` for compile-time constants, `inline` so every translation unit shares one entity rather than getting a private copy. `uint32_t` rather than `int` so the arithmetic in `fb_putchar` is unsigned throughout and never mixes signedness — `-Wall -Wextra -Werror` will otherwise stop the build on a sign-compare warning the first time you write `col < FONT_WIDTH` with a signed `col`.

Naming is `SCREAMING_SNAKE` per [[13 - Coding Standards]], which `.clang-tidy`'s `readability-identifier-naming.ConstantCase` enforces.

These are the numbers that [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] multiplies by everywhere. Defining them beside the font is what stops a literal `16` appearing in the scroll routine and silently disagreeing with the font when you swap in an 8x8.

**`extern const uint8_t font8x16[FONT_GLYPHS][FONT_HEIGHT];`**

The mirror of what `mkfont` emits. Both must agree on the type exactly. `FONT_GLYPHS` and `FONT_HEIGHT` are `constexpr`, so they are valid array bounds.

Note the type is two-dimensional. That is not decoration: `font8x16[c]` decays to `const uint8_t*` pointing at 16 bytes, and the `* 16` is the compiler's job. An `objcopy`-style flat `extern const uint8_t blob[];` would make it yours.

**`font_glyph`**

```cpp
inline const uint8_t* font_glyph(unsigned char code) {
    return font8x16[code];
}
```

This function exists for exactly one reason: **the parameter type**.

On x86-64 with the System V ABI, plain `char` is **signed**. `font8x16[c]` with a `char` that holds `0xDB` sees the value **-37**, and `font8x16[-37]` reads 592 bytes *before* the array. Making the parameter `unsigned char` means the conversion happens at the call boundary, where the language guarantees a well-defined modulo-256 result: `-37` becomes `219`, which is what you meant. A caller that passes a `char` gets the right answer without thinking about it.

`inline` because it is defined in a header and must not violate the one-definition rule. There is no call overhead — it compiles to the same address arithmetic as writing the subscript directly, and it is `-O2`'d away entirely.

The trap it prevents is in §7, and it is the second most likely thing to cost you an evening in this stage.

---

### `kernel/drivers/char/fbcon.hpp` — additions

Add two declarations to the header [[Stage 1.1 - The Linear Framebuffer]] created.

```cpp
// --- Stage 1.2: glyph rendering -------------------------------------------

// Draw one character with its top-left corner at pixel (x, y). Opaque: every
// pixel of the 8x16 cell is written, foreground or background. Clipped as a
// whole - a glyph that would not fit entirely is not drawn at all.
void fb_putchar(char c, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg);

// Draw a NUL-terminated string left to right from (x, y). No newline handling,
// no wrapping, no cursor - that is Stage 1.3.
void fb_puts(const char* s, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg);
```

The comments state the two contracts that later stages depend on: **opaque**, and **whole-glyph clipping**. Both are decisions, not accidents, and both are argued below.

---

### `kernel/drivers/char/fbcon.cpp` — additions

The renderer itself.

```cpp
#include "fbcon.hpp"

#include "font.hpp"

#include <stdint.h>

// ... fb_init(), put_pixel(), fb_clear(), fb_width(), fb_height() from Stage 1.1 ...

void fb_putchar(char c, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg) {
    // Widen through unsigned char, NEVER through char. Plain char is signed on
    // x86-64, so a byte >= 0x80 arrives as a negative number and indexes the
    // array backwards. font_glyph() takes unsigned char so the conversion is
    // forced here, at the boundary.
    const uint8_t* glyph = font_glyph(static_cast<unsigned char>(c));

    // Clip whole glyphs. put_pixel() does not know what a character is; without
    // this, a glyph started three pixels from the right edge wraps onto the
    // next scanline (pitch arithmetic) or runs off the end of the mapping.
    if (x + FONT_WIDTH > fb_width() || y + FONT_HEIGHT > fb_height()) {
        return;
    }

    for (uint32_t row = 0; row < FONT_HEIGHT; ++row) {
        const uint8_t bits = glyph[row];

        for (uint32_t col = 0; col < FONT_WIDTH; ++col) {
            // 0x80 >> col walks the mask LEFT to RIGHT: col 0 tests bit 7, the
            // leftmost pixel; col 7 tests bit 0. Writing (1u << col) instead
            // mirrors every glyph horizontally. See Stage 1.2 section 7.
            const bool lit = (bits & (0x80U >> col)) != 0;
            put_pixel(x + col, y + row, lit ? fg : bg);
        }
    }
}

void fb_puts(const char* s, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg) {
    for (uint32_t pen = x; *s != '\0'; ++s, pen += FONT_WIDTH) {
        fb_putchar(*s, pen, y, fg, bg);
    }
}
```

#### Line by line

**The includes**

```cpp
#include "fbcon.hpp"

#include "font.hpp"

#include <stdint.h>
```

Own header first, then kernel headers, then freestanding C headers — the order `.clang-format`'s `IncludeCategories` enforces, and the order [[13 - Coding Standards]] specifies. `font.hpp` is quoted rather than angle-bracketed because it is *internal to this subsystem* and lives beside the source, per [[07 - Repository Layout]]: `include/kernel/` is for cross-subsystem interfaces only, and nothing outside `drivers/char/` has any business touching the font.

**Lines 1–1 of the body — the index cast**

```cpp
const uint8_t* glyph = font_glyph(static_cast<unsigned char>(c));
```

The cast is redundant — `font_glyph` takes `unsigned char`, so the conversion happens anyway — and it stays anyway, for two reasons. It documents the hazard at the point where a reader will be looking for it, and it survives a refactor that changes `font_glyph`'s parameter type. This is a five-character insurance policy against a bug whose symptom is a reboot with no message.

Hoisting the pointer out of the loop also means the two-dimensional subscript happens once instead of 16 times. At `-O2` the compiler would do that anyway; writing it explicitly makes the inner loop obviously a walk over 16 contiguous bytes.

**The clip test**

```cpp
if (x + FONT_WIDTH > fb_width() || y + FONT_HEIGHT > fb_height()) {
    return;
}
```

`put_pixel` from Stage 1.1 works in pixels and knows nothing about glyph cells. What happens without this test depends on how defensively you wrote it:

- If `put_pixel` clips per pixel, a glyph starting at `fb_width() - 3` draws its left three columns and silently drops the rest. Text near the right edge is chopped, which looks like a font bug.
- If `put_pixel` does not clip, `x = width - 3, col = 5` computes an offset one row down and three pixels in — the character **wraps onto the following scanline**, producing a distinctive stripe of debris. This is the same class of bug as confusing `pitch` with `width`, and it looks identical.
- Near the bottom edge with no clipping, the write goes past the end of the framebuffer mapping. Best case nothing visible; worst case a page fault, and with no IDT until [[Phase 2 - Overview|Phase 2]] that is a triple fault and an instant reboot.

Clipping the **whole glyph** rather than per pixel is the deliberate choice. A half-drawn character is worse than no character: it looks like a rendering bug and sends you debugging the loop. A missing character at the very edge looks like what it is, and [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] will make it unreachable anyway by wrapping at `fb_width() / FONT_WIDTH` columns.

Note that all four operands are unsigned, so `x + FONT_WIDTH` cannot go negative — but it *can* wrap if a caller passes something near `UINT32_MAX`. That only happens if a caller computed a negative column, which the grid arithmetic in Stage 1.3 will not do.

**The outer loop — one scanline per iteration**

```cpp
for (uint32_t row = 0; row < FONT_HEIGHT; ++row) {
    const uint8_t bits = glyph[row];
```

16 iterations, top scanline first, matching the blob layout in §4. Loading `bits` once per row rather than re-subscripting inside the inner loop is the natural way to write it and keeps the memory access pattern obvious: 16 sequential byte reads from `.rodata`.

`row` is `uint32_t` to match `FONT_HEIGHT` and `y`. Mixing a signed loop counter with unsigned bounds is a `-Wsign-compare` warning, and `-Werror` turns it into a build failure.

**The inner loop — bit extraction**

```cpp
for (uint32_t col = 0; col < FONT_WIDTH; ++col) {
    const bool lit = (bits & (0x80U >> col)) != 0;
    put_pixel(x + col, y + row, lit ? fg : bg);
}
```

This is the line the whole stage exists for. Take it apart:

`0x80U >> col` produces the mask table from §4. At `col = 0` it is `0x80`, which is bit 7, which is the **leftmost** pixel. At `col = 7` it is `0x01`, bit 0, the rightmost. As `col` increases left to right across the screen, the mask walks from the high bit to the low bit — which is exactly the correspondence the format defines.

The `U` suffix keeps the literal unsigned. It makes no difference for `0x80` (which fits in `int` regardless) but it costs nothing and it means the expression stays correct if you ever widen the font to 16 pixels and write `0x8000U`.

`bits & mask` yields an `int` that is either zero or a single power of two — `0x80`, `0x40`, and so on. It is **not** `0` or `1`. Comparing `!= 0` converts it to a `bool` explicitly. You could write `if (bits & mask)` and rely on the implicit conversion; naming the result `lit` makes the following line read as what it is.

`put_pixel(x + col, y + row, ...)` translates glyph-local coordinates to screen coordinates by simple addition. All the `pitch` arithmetic — the thing [[Phase 1 - Overview|Phase 1]] warns about — stays inside `put_pixel` where Stage 1.1 put it. This function never touches a framebuffer address.

**Why the `else` branch draws the background**

`lit ? fg : bg` means **every** pixel of the cell is written, 128 of them, whether or not there is ink. The alternative is transparent rendering — skip the write when the bit is clear:

```cpp
if (lit) {                                  // transparent variant - do NOT use
    put_pixel(x + col, y + row, fg);
}
```

Transparent is tempting: it halves the writes for a typical glyph and it lets you overlay text on an image. It is wrong here, for four reasons that compound through the rest of the phase:

1. **Overwriting a cell stops working.** Draw `M`, then draw `i` over it, and you get an `M` with an `i` inside it. Every cell would need an explicit clear first — which is the same 128 writes you just saved, plus a second pass.
2. **Backspace and cursor blink stop working.** [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] erases a cell by drawing a space over it. With transparent rendering a space draws nothing at all.
3. **You would want to read the framebuffer.** Any real transparency eventually means blending, and blending means reading back. Framebuffer memory is uncached write-combining; reads from it are orders of magnitude slower than RAM, and [[Phase 1 - Overview|Phase 1]] calls this out as a headline hazard. Opaque rendering keeps the console **write-only**, which is exactly the property [[Stage 1.4 - Double Buffering]] needs.
4. **It is not actually faster.** The two branches issue the same number of instructions per pixel; the `if` version just swaps a store for a branch, and a mispredicted branch on a bit pattern with no structure costs more than the store.

Opaque is the right default for a console. Keep transparency for a splash screen, where you draw once and nothing overwrites it.

**`fb_puts`**

```cpp
void fb_puts(const char* s, uint32_t x, uint32_t y, uint32_t fg, uint32_t bg) {
    for (uint32_t pen = x; *s != '\0'; ++s, pen += FONT_WIDTH) {
        fb_putchar(*s, pen, y, fg, bg);
    }
}
```

`pen` is the running x coordinate; `s` walks the string. Both advance in the loop's third clause, so there is one exit condition and no chance of advancing one without the other.

`pen += FONT_WIDTH` is where monospace pays off — the advance is a constant, so there is no per-glyph metric to look up and no state to carry between calls. This is the property §3 argued for.

**No `\n` handling, deliberately.** A newline here would need a cursor, and a cursor needs a scroll policy, and that is [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]]'s entire job. `fb_puts` draws one line at one position. Passing it a string containing `\n` draws whatever glyph the font has at index 10 — which is the correct behaviour for a function that has not been told what a line is.

**Trying it from `kmain`**

```cpp
    fb_puts("CRACKED OS", 8, 8, 0x00FFFFFF, 0x00202020);
```

Use whatever colour encoding [[Stage 1.1 - The Linear Framebuffer]] established. On the common 32-bpp framebuffer with the usual masks, `0x00FFFFFF` is white and `0x00202020` is a dark grey that is *not* your clear colour — which is deliberate, and is the diagnostic in §7: if you see grey rectangles and no letters, the loop works and the foreground colour is wrong.

---

## 6. How to verify

### Prove the blob is right before you debug the kernel

Do this first. It renders a glyph straight from the file, using the same bit expression the kernel uses, so it separates "the data is wrong" from "my loop is wrong".

```sh
python3 - <<'EOF'
blob = open('tools/mkfont/vga8x16.fnt', 'rb').read()
print(len(blob), 'bytes')
for g in (0x41, 0x62):                      # 'A' and 'b'
    print('--- glyph 0x%02X %r ---' % (g, chr(g)))
    for row in blob[g*16:(g+1)*16]:
        print(''.join('#' if row & (0x80 >> c) else '.' for c in range(8)))
EOF
```

```
4096 bytes
--- glyph 0x41 'A' ---
........
........
...#....
..###...
.##.##..
##...##.
...
```

`b` is in there because it is **asymmetric**: if it comes out looking like `d`, the mirroring bug is in this script and therefore in the font file's bit order, not in your kernel.

### Prove `mkfont` is a host binary

```sh
make
build/host-tools/bin/mkfont
```

```
usage: mkfont <input.fnt> <output.cpp> [symbol]
```

**That it runs at all is the test.** A cross-compiled tool would not have got this far — see §7. For confirmation:

```sh
file build/host-tools/bin/mkfont
```

```
build/host-tools/bin/mkfont: ELF 64-bit LSB pie executable, x86-64, ...
  dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2, ...
```

`dynamically linked` with an `interpreter` means it links the host's libstdc++ and is a normal Linux program. A cross-built one says `statically linked` and names no interpreter.

### Prove the generated file is well formed

```sh
grep -c '^    /\* 0x' build/kernel/generated/font8x16.cpp
head -20 build/kernel/generated/font8x16.cpp
```

The count must be exactly **256**.

```
// GENERATED FILE - DO NOT EDIT.
// Produced by tools/mkfont from vga8x16.fnt.
//
// Layout: [glyph][scanline]. Bit 0x80 is the LEFTMOST pixel of a scanline.

#include <stdint.h>

// The `extern` is load-bearing. ...
extern const uint8_t font8x16[256][16];

const uint8_t font8x16[256][16] = {
    /* 0x00 '.' */ { 0x00, 0x00, ... },
```

### Prove the symbol landed in the kernel with the right size and linkage

```sh
x86_64-elf-nm -S build/kernel.elf | grep font8x16
```

```
ffffffff8000a000 0000000000001000 R font8x16
```

Three things to read here:

- **`R`, uppercase** — global symbol in read-only data. A lowercase `r` would mean internal linkage, i.e. the missing `extern` (though in practice that fails at link time first).
- **`0000000000001000`** — 4096 bytes, exactly. Anything else means the array's declared dimensions and the blob disagree.
- **`ffffffff8...`** — inside the higher-half kernel mapping from [[Stage 0.4 - The Linker Script and Higher-Half Layout]], as expected for `.rodata`.

### Prove the dependency chain actually fires

```sh
touch tools/mkfont/vga8x16.fnt
make
```

The build log **must** contain the `COMMENT` line:

```
[1/3] mkfont: vga8x16.fnt -> font8x16.cpp
[2/3] Building CXX object kernel/CMakeFiles/kernel.elf.dir/generated/font8x16.cpp.obj
[3/3] Linking CXX executable kernel.elf
```

If it does not, `DEPENDS` is wrong. Ask Ninja directly:

```sh
ninja -C build -t query kernel/generated/font8x16.cpp
```

```
kernel/generated/font8x16.cpp:
  input: CUSTOM_COMMAND
    ../tools/mkfont/vga8x16.fnt
    host-tools/bin/mkfont
  outputs:
    kernel/CMakeFiles/kernel.elf.dir/generated/font8x16.cpp.obj
```

Both inputs must be listed. If the blob is missing from `input:`, that is the trap in §7. `ninja -C build -d explain` prints, for every step, why it decided to run or skip.

Now the end-to-end version — change the data and confirm the pixels change. Glyph `'A'` is 0x41, so its first scanline is at byte `0x41 * 16 = 1040`:

```sh
printf '\xFF' | dd of=tools/mkfont/vga8x16.fnt bs=1 seek=1040 count=1 conv=notrunc
make run
# every 'A' now has a solid bar across its top row
git checkout tools/mkfont/vga8x16.fnt
```

### Prove the output is reproducible

```sh
cmake -S . -B build-a -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake && cmake --build build-a
cmake -S . -B build-b -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake && cmake --build build-b
cmp build-a/kernel/generated/font8x16.cpp build-b/kernel/generated/font8x16.cpp && echo "identical"
rm -rf build-a build-b
```

`identical`. If it differs, something in `mkfont` is reading the environment — a clock, a locale, or the absolute input path.

```sh
make verify-repro
```

covers the whole image, including this.

### On screen — the printable range

Call this from `kmain` after the framebuffer is up. It is worth keeping as a debug helper.

```cpp
static void fb_font_demo() {
    constexpr uint32_t FG = 0x00FFFFFF;
    constexpr uint32_t BG = 0x00000000;

    // The printable ASCII range, 0x20..0x7E, sixteen characters per line.
    for (uint32_t code = 0x20; code <= 0x7E; ++code) {
        const uint32_t n = code - 0x20;
        fb_putchar(static_cast<char>(code), 8 + (n % 16) * FONT_WIDTH,
                   8 + (n / 16) * FONT_HEIGHT, FG, BG);
    }

    // Two high-bit glyphs. If these draw garbage - or the machine reboots -
    // something on the path is still indexing with a signed char.
    fb_putchar(static_cast<char>(0xB0), 8, 8 + 8 * FONT_HEIGHT, FG, BG);
    fb_putchar(static_cast<char>(0xDB), 8 + FONT_WIDTH, 8 + 8 * FONT_HEIGHT, FG, BG);
}
```

```sh
make run
```

- [ ] Six full rows of characters, starting with a space and `!"#$%&'()*+,-./`, ending with `~`
- [ ] Digits and letters are legible at normal viewing distance
- [ ] `b` and `d` face the correct way; `E` and `F` open to the right; `<` points left
- [ ] Characters do not touch — there is a one-pixel gap between adjacent cells
- [ ] The two high-bit glyphs draw *something* deliberate, and the machine does not reboot. With a CP437-ordered font, 0xB0 is a light-shade checkerboard and 0xDB is a solid 8x16 block
- [ ] `make lint` passes — `clang-format` covers `tools/` as well as `kernel/`

### What can only be checked later

| Property | Checked in |
|---|---|
| Scrolling leaves no ghost pixels (needs opaque rendering to be correct) | [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] |
| The console never *reads* the framebuffer | [[Stage 1.4 - Double Buffering]] |
| Every byte value 0x00–0xFF prints without faulting, under a real IDT | [[Phase 2 - Overview\|Phase 2]] |
| Glyph lookup as a Tier-1 host unit test | [[09 - Testing Strategy]] |

---

## 7. Common traps

**Symptom: every glyph is mirrored left-to-right. `b` looks like `d`, `E` and `F` open to the left, `<` points right. Symmetric characters like `H`, `O` and `0` look perfectly fine.**
The bit order in the inner loop. You wrote `bits & (1u << col)`, which tests bit 0 first — the *rightmost* pixel — while `col` counts from the left. Every glyph comes out reversed within its 8-pixel cell.
Fix: `bits & (0x80U >> col)`, or equivalently `(bits >> (7 - col)) & 1`. §4 has the mask table.
Why it survives a quick look: roughly a third of the printable set is horizontally symmetric, so a screen of digits and `HIMOTUVWXY` looks right. Always test with `b`, `d`, `E`, `<`. The Python check at the top of §6 uses the correct expression, so if it prints a proper `b` from the file and your screen shows `d`, the bug is in your loop and nowhere else.

**Symptom: characters at or above 0x80 draw garbage from a different part of the image, or the machine reboots instantly with no output.**
`char` is **signed** on x86-64. `static_cast<char>(0xDB)` holds **-37**, and `font8x16[-37]` reads `-37 * 16 = -592` bytes from the start of the array. That address is still inside `.rodata` most of the time, so you get 16 bytes of some unrelated constant rendered as a glyph — plausible-looking noise. But if the font happens to sit near the beginning of `.rodata`, or after a linker rearrangement, the read crosses into an unmapped page. That is a page fault, and there is **no IDT until [[Phase 2 - Overview|Phase 2]]**, so a page fault becomes a double fault becomes a triple fault: the CPU resets. You see a reboot with no message and no way to tell what caused it.
Fix: convert at the boundary — `font_glyph(static_cast<unsigned char>(c))`, with `font_glyph` itself taking `unsigned char`. Both, so the guarantee survives a refactor.
What not to do: `-funsigned-char`. It "works", and it changes the meaning of `char` for the entire kernel, so the code stays wrong and merely stops manifesting — until someone builds a file without the flag. Fix the conversion, not the language.
This one is mechanisable: `.clang-tidy` enables `bugprone-*` and lists it in `WarningsAsErrors`, and `bugprone-signed-char-misuse` exists for precisely this. `make lint-tidy`.

**Symptom: you edit the font blob, rebuild, and the screen is unchanged. `make clean && make` fixes it.**
The CMake dependency chain. "`make clean` fixes it" is the signature of a missing `DEPENDS` — the output is stale but the build system believes it is current.
Three separate causes, in order of likelihood:
1. `${FONT_BLOB}` is not in the custom command's `DEPENDS`. Nothing connects the blob to the rule, so the rule never re-runs.
2. `${MKFONT}` is not in `DEPENDS`. The blob triggers correctly but a change to `mkfont.cpp` does not — the tool relinks and its output is still considered current.
3. `BUILD_ALWAYS TRUE` is missing from `ExternalProject_Add`. The sub-build ran once, was stamped, and will never run again. `mkfont.cpp` edits do nothing at all, permanently, until you delete `build/`.
Diagnose with `ninja -C build -t query kernel/generated/font8x16.cpp` and read the `input:` list; `ninja -C build -d explain` says why each step ran or did not.
This is exactly the class of bug [[Stage 0.8 - The Build System]] §1 warned about — a build that is confidently, silently out of date — with the twist that this dependency is one CMake **cannot** infer. It has no idea `mkfont` reads that file. You have to say so.

**Symptom: `fatal error: fstream: No such file or directory` while compiling `mkfont.cpp`.**
`mkfont` is being built with the **cross-compiler**. The toolchain image contains no libstdc++ ([[ADR-0005 - Containerised Pinned Toolchain]] builds `all-gcc all-target-libgcc` and stops), and the kernel flags include `-nostdinc++`, so no C++ standard header resolves.
The cause is nearly always `add_subdirectory(tools)` in the top-level `CMakeLists.txt` instead of `ExternalProject_Add`. That configure carries `-DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake`, so **every** `add_executable` in that tree — kernel or not — is compiled by `x86_64-elf-g++`.
This is the same message as [[Stage 0.8 - The Build System]]'s `cstdint` trap, with the **opposite** fix. There, the answer is to stop including standard headers, because it is kernel code. Here, the answer is to stop using the cross-compiler, because it is not. Reading the message alone will send you the wrong way. Ask which of the three toolchains this file belongs to first.
The variant to know about: a host tool that happens to use no standard-library headers will compile, link, and then fail at run time with `/bin/sh: build/host-tools/bin/mkfont: cannot execute binary file: Exec format error` — a freestanding ELF with no interpreter, handed to a Linux loader. `file` on the binary tells them apart immediately.

**Symptom: the code runs, no errors, but the screen shows nothing where the text should be.**
Almost always `fg == bg`, or `fg` equal to whatever `fb_clear` painted. The glyphs are being drawn perfectly, in the colour of the background.
The bisect: call `fb_putchar` with a background that is definitely not your clear colour — `fb_putchar('A', 8, 8, 0x00FFFFFF, 0x00FF0000)`. Three outcomes, three different conclusions:
- **A red 8x16 rectangle with a white `A` in it** — everything works, and your original call had a colour problem.
- **A solid red 8x16 rectangle, no letter** — the loop and `put_pixel` work; the glyph data is all zeros. Check the blob with the Python script in §6, and check that `font8x16` is not accidentally a zero-initialised array because the generated file was never compiled.
- **Nothing at all** — the problem is below this stage. `put_pixel` is not reaching the framebuffer, which is a [[Stage 1.1 - The Linear Framebuffer]] problem.
Also check the colour encoding: if Stage 1.1's `put_pixel` expects a value already packed for the framebuffer's red/green/blue mask positions, a hard-coded `0x00FF0000` may not be red on that machine.

**Symptom: the build works for you and fails in CI with `mkfont: cannot open tools/mkfont/vga8x16.fnt`.**
The font blob is not in git. Check `.gitignore`: it contains **`*.bin`**, so a font named `vga8x16.bin` is ignored, `git add -A` skips it silently, and the file exists only on your machine.
Fix: name it `.fnt` (as this stage does), or add an explicit negation. Verify, do not assume:
```sh
git check-ignore -v tools/mkfont/vga8x16.fnt   # must print nothing
git ls-files tools/mkfont/                     # must list the blob
```
While you are there, add `*.fnt binary` to `.gitattributes`. The existing `* text=auto eol=lf` rule relies on git's content heuristic to classify the file, which for 4096 bytes containing many NULs gets it right — but the file already declares `*.psf binary`, and being explicit costs one line and removes the question.

**Symptom: `mkfont: ... is 4100 bytes, expected 4096`.**
The size check doing its job. 4100 is a PSF1 header (4 bytes) you did not strip; 4128 is PSF2 (32 bytes); 8192 is a 512-glyph font. A size a few bytes over with no clean explanation is end-of-line conversion mangling a binary file — `git check-attr text eol -- tools/mkfont/vga8x16.fnt`.
Why the check earns its place: without it a 4-byte offset makes every glyph consist of the last twelve scanlines of the *previous* character plus the first four of its own. Every character on screen looks like two characters stacked on top of each other. That is an hour of staring at a correct rendering loop.

**Symptom: `undefined reference to 'font8x16'` at link time, from a file that plainly defines it.**
Two distinct causes; the object file tells you which.
```sh
nm build/kernel/CMakeFiles/kernel.elf.dir/generated/font8x16.cpp.obj | grep font8x16
```
- The object file **does not exist**: `${FONT_GEN}` is not in `add_executable`'s source list. The file was generated and never compiled.
- It exists and shows a lowercase **`r`**: internal linkage. The `extern` declaration is missing. In C++ a namespace-scope `const` object is internal by default, unlike C — §4 has the full explanation. `mkfont` emits the declaration; you get here by hand-editing the output, which you should not be doing anyway.

**Symptom: glyphs are upside down.**
The scanline order is reversed. PSF and every VGA-derived font store the **top** scanline first, so this means your source font is a different format. Confirm with the Python script in §6 — it reads the file directly, so if it prints an upside-down `A`, the data is upside down and the kernel is innocent.

---

## 8. What this unlocks

Everything else in [[Phase 1 - Overview|Phase 1]] is built on `fb_putchar`. [[Stage 1.3 - A Console - Cursor, Colour, Scrolling]] wraps it in a cursor and a grid, and depends on two properties this stage established: the cell is *exactly* `FONT_WIDTH` by `FONT_HEIGHT`, and drawing a glyph *completely repaints* its cell. Break the first and column arithmetic drifts across the line; break the second — by rendering transparently — and scrolling leaves ghosts of the previous text, and a space no longer erases. [[Stage 1.4 - Double Buffering]] depends on the console being strictly **write-only**, which is exactly what opaque rendering guarantees. [[Stage 1.6 - kprintf]] and [[Stage 1.7 - Symbolised Backtraces]] both funnel every byte they produce through this path, which is why it has to work before there is an IDT, a heap, or a filesystem.

The build wiring is the other half of what you built. `tools/mkfont` is the first host tool in the tree, and `mkinitrd` ([[Phase 7 - Overview|Phase 7]]), `symbolise` ([[Stage 1.7 - Symbolised Backtraces]]) and `gdbinit-gen` are each now a two-line addition to `tools/CMakeLists.txt` plus one `add_custom_command`. Get the `ExternalProject`/`BUILD_BYPRODUCTS`/`DEPENDS` chain right once, here, and you never revisit it.

Two failures from this stage are silent and surface far from their cause. The **signed-char index** does not manifest until something prints a byte above 0x7F — which will be a hex dump of memory in [[Phase 4 - Overview|Phase 4]], at which point the symptom is "the kernel reboots when I print the page tables" and nothing points at a font. The **missing `DEPENDS`** does not manifest for you at all; it manifests for the next person who changes the font, or for CI on a clean checkout. Both are caught by §6's checks, which is why they are checks and not suggestions.

---

## 9. Reading

- **OSDev — PC Screen Font**: <https://wiki.osdev.org/PC_Screen_Font>
  The format most bitmap fonts you will download are packaged in. Read the PSF1 and PSF2 header layouts before running the `dd` recipe in §4 — the header sizes are the numbers you need.
- **OSDev — Drawing In a Linear Framebuffer**: <https://wiki.osdev.org/Drawing_In_a_Linear_Framebuffer>
  The `pitch` vs `width` problem, which lives in `put_pixel` and is why this stage never computes a framebuffer address itself.
- **Code page 437**: <https://en.wikipedia.org/wiki/Code_page_437>
  What the glyphs above 0x7F mean in a classic VGA font. Worth a look before you use box-drawing characters in a panic banner.
- **CMake — `add_custom_command`**: <https://cmake.org/cmake/help/latest/command/add_custom_command.html>
  Read the `DEPENDS` and `BYPRODUCTS` sections properly, and the note that a custom command's `OUTPUT` is consumed by targets **in the same directory**. Both bite in §7.
- **CMake — `ExternalProject`**: <https://cmake.org/cmake/help/latest/module/ExternalProject.html>
  In particular `BUILD_ALWAYS` and `BUILD_BYPRODUCTS`. The superbuild pattern here is the one [[08 - Build System]] specifies for host tools.
- **Ninja manual**: <https://ninja-build.org/manual.html>
  For `-d explain` and `-t query`, which turn "why did it not rebuild?" from guesswork into a one-line answer.
- **GNU binutils — `objcopy`**: <https://sourceware.org/binutils/docs/binutils/objcopy.html>
  The `-I binary` section, so the rejected option in §3 is a thing you understand rather than a thing you were told about.
- **Spleen** (BSD 2-clause, ships an 8x16): <https://github.com/fcambus/spleen>
- **Terminus** (OFL 1.1, `ter-116n` is 8x16): <https://terminus-font.sourceforge.net/>
- **The Ultimate Oldschool PC Font Pack** (CC BY-SA 4.0, exact IBM VGA metrics): <https://int10h.org/oldschool-pc-fonts/>
- [[Stage 0.8 - The Build System]] — the three-toolchains rule this stage instantiates for the first time
- [[08 - Build System]] — the superbuild specification, and the reproducibility rules `mkfont` has to satisfy
- [[07 - Repository Layout]] — why the tool is in `tools/` and the header beside its source
- [[13 - Coding Standards]] — fixed-width types, header order, and the clang-tidy checks that catch the signed-char bug
- [[ADR-0004 - Framebuffer Console Not VGA Text]] — why there is no text mode to fall back on
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]] — no libstdc++, no floating point, and what that rules out

Next: **[[Stage 1.3 - A Console - Cursor, Colour, Scrolling]]**

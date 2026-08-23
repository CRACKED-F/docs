# ADR-0004 — Framebuffer console, not VGA text mode

**Status:** Accepted · **Date:** 2026-08-20
**Supersedes:** the VGA text buffer plan in v1 Phase 1

---

## Context

The v1 guide wrote characters into the **VGA text buffer at physical `0xB8000`** —
the standard first-output trick, and the reason "a white `A` in the corner" is the
canonical first milestone in hobby OS development.

This does not work on the hardware we intend to ship on. **UEFI and VGA are mutually
exclusive in practice.** UEFI firmware makes no guarantee that the display adapter is
left in a VGA-compatible mode, and on most modern machines it is not — the adapter is
in a native graphics mode with no text buffer at all. Writing to `0xB8000` on a
UEFI-booted modern laptop produces nothing: no error, no output, a black screen.

Debugging that as a beginner is brutal, because the *code is correct* and the
*platform* is wrong. There is no feedback loop that leads to the answer.

Modern practice is a **linear framebuffer**: firmware or the bootloader sets a
graphics mode and reports base address, width, height, pitch, and pixel format. You
write pixels. Text becomes "rasterise a bitmap font into pixels."

> "Framebuffer effectively replaced the VGA Text Mode, which might still be
> considered when making a BIOS bootloader or targeting obsolete hardware."
> — OSDev Wiki, *Drawing In a Linear Framebuffer*

## Decision

The kernel console is a **linear framebuffer console** from Stage 1.1. There is **no
VGA text-mode code path anywhere in the tree.**

- Limine's framebuffer request supplies base, width, height, pitch, and bpp
  ([[ADR-0003 - Limine as the Bootloader]]).
- Text is rendered with an 8x16 bitmap font compiled into the kernel as a byte array.
- **Serial output (COM1, 16550 UART) is implemented in Stage 0.4 — before the
  framebuffer.** Serial is the primary debug channel; the framebuffer is the human
  channel. This ordering is deliberate and is reversed from v1.

## Consequences

- The "first pixel" milestone replaces the "first character" milestone. Stage 1.1
  draws a coloured rectangle; Stage 1.2 rasterises glyphs. Slightly more work, and
  the result runs on real hardware.
- Scrolling is a `memmove` of `pitch * font_height` bytes, not a two-byte-per-cell
  shuffle. It is slower and must be **double-buffered** (Stage 1.4) or the screen
  tears visibly. Writes go to a back buffer in normal RAM; only the flush touches
  the framebuffer, because framebuffer memory is uncached and write-combining —
  reading from it is catastrophically slow and must never happen in a hot loop.
- We must carry a font. We embed a public-domain 8x16 VGA-style bitmap font,
  converted to a C array at build time by `tools/mkfont`. No runtime font parsing
  in v1.
- The console is a graphics surface from day one. That is a gift later: Phase 15's
  diagnostic screens and any future GUI build on the same primitive instead of
  requiring a rewrite.
- **Early-boot failures before framebuffer init are invisible on screen.** This is
  precisely why serial comes first, and why the panic handler
  ([[ADR-0010 - Testing Strategy and the QEMU Exit Device]]) writes to serial
  unconditionally before it attempts any drawing.

## Alternatives rejected

- **VGA text mode with framebuffer fallback.** Two code paths, one of which cannot
  be tested on our actual target. Pure maintenance cost for zero benefit.
- **Calling UEFI GOP at runtime.** Requires remaining in EFI boot services, which are
  exited at handoff. Limine has already done this work and reports the result.

## Related

[[ADR-0003 - Limine as the Bootloader]] · [[Phase 1 - Overview]]

# Stage 1.1 — The VGA Text Buffer

**Difficulty:** Easy · ~20 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Text Output]]

---

## Concept

In text mode the screen is not drawn pixel by pixel by you. The video hardware shows
a grid of **80 columns × 25 rows** of characters, and it reads that grid straight out
of memory at physical address `0xB8000`. Write a byte there and a character appears.
This is **memory-mapped I/O**: the screen is just memory you write to.

Each cell is **two bytes**: the character byte, then an **attribute byte** that sets
the foreground and background color.

---

## Specification

- Base address: `0xB8000`. Dimensions: 80 × 25.
- Cell layout (little-endian 16-bit value): low byte = ASCII character, high byte =
  attribute.
- Attribute byte: low nibble = foreground color, high nibble = background color.
  Example: `0x0F` = white on black. `0x1F` = white on blue.
- The cell for row `y`, column `x` is at index `y * 80 + x` in a `uint16_t*` pointed
  at `0xB8000`.

---

## Your task

1. Define a `volatile uint16_t*` pointing at `0xB8000`. `volatile` stops the compiler
   from optimizing the writes away.
2. Write a helper `vga_entry(char c, uint8_t color)` that packs a character and an
   attribute into one `uint16_t`.
3. Write `put_char_at(char c, uint8_t color, int x, int y)` that stores the entry at
   index `y * 80 + x`.
4. From `kernel_main`, clear the screen: fill all 80×25 cells with a space and your
   chosen background.
5. Print a few characters at known positions to confirm placement and color.

---

## How to verify

- The screen clears to your background color (no leftover BIOS text).
- Your test characters appear at the exact cells you chose, in the right colors.
- Changing the attribute byte changes the color as the table predicts.

---

## Common traps

- **Forgetting `volatile`.** With optimization on, the compiler may drop "useless"
  writes to memory it thinks nobody reads. The screen stays blank.
- Off-by-one in the index math. Row-major means `y * 80 + x`, not `x * 25 + y`.
- Writing one byte per cell and forgetting the attribute byte, so every other cell is
  wrong.

---

## Reading

- OSDev — *Printing to Screen*: <https://wiki.osdev.org/Printing_to_Screen>
- OSDev — *VGA Hardware* (text mode section): <https://wiki.osdev.org/VGA_Hardware>

Next: **[[Stage 1.2 - A Terminal Driver]]**.

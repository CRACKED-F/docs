# Stage 1.2 — A Terminal Driver

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Text Output]]

---

## Concept

Writing one character at a fixed cell does not scale. A **terminal driver** tracks a
**cursor** — the current row and column — and advances it as you print. Then you can
call `print("hello")` and each character lands after the last, exactly like a real
console. This stage wraps Stage 1.1's primitive in state.

You will also move the **hardware cursor** (the blinking underline) so it follows
your text. The hardware cursor is controlled through VGA I/O ports, your first use of
the `in`/`out` port instructions.

---

## Specification

- Track `size_t cursor_row, cursor_col` and a current `uint8_t color`.
- `print_char(char c)`: place the character at the cursor, then advance the cursor.
  On column 80, wrap to the next row.
- `print(const char* s)`: loop `print_char` over the string.
- Hardware cursor position is set through ports `0x3D4` (index) and `0x3D5` (data),
  registers `0x0F` (low byte) and `0x0E` (high byte) of the linear position
  `row * 80 + col`.
- You need port I/O helpers `outb(port, value)` and `inb(port)` written in inline
  assembly. You will reuse these constantly, so put them in a small `io.h`.

---

## Your task

1. Write `outb` and `inb` inline-assembly helpers in `io.h`.
2. Add terminal state: cursor row, cursor column, current color.
3. Write `print_char(char c)` that places a character and advances the cursor, with
   column wrap.
4. Write `print(const char* s)`.
5. Write `set_color(fg, bg)` and `update_hardware_cursor()` using the ports above.
6. From `kernel_main`, print a multi-line message and confirm the blinking cursor
   sits right after it.

---

## How to verify

- `print("...")` lays text left to right, wrapping at column 80.
- `set_color` changes the color of text printed after it.
- The blinking hardware cursor sits immediately after the last character.

---

## Common traps

- Wrapping the column but forgetting to advance the row.
- Writing the hardware-cursor bytes in the wrong order (low vs high register).
- Reusing a value where you need the linear position `row * 80 + col`, not just the
  column.

---

## Reading

- OSDev — *Text Mode Cursor* (moving the hardware cursor):
  <https://wiki.osdev.org/Text_Mode_Cursor>
- OSDev — *Inline Assembly* and *I/O ports*:
  <https://wiki.osdev.org/Inline_Assembly> · <https://wiki.osdev.org/Port_IO>

Next: **[[Stage 1.3 - Scrolling & Newlines]]**.

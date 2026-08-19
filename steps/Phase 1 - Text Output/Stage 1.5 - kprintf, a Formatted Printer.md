# Stage 1.5 — kprintf, a Formatted Printer

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Text Output]]

---

## Concept

You can print strings, but debugging needs **values**: "page fault at address
`0x...`", "tick = 42". A `printf`-style function takes a format string with
placeholders and a variable number of arguments, and prints them. There is no C
library, so you write it. It is simpler than it looks: walk the format string, and on
each `%` read the next argument and convert it to text.

This is the single most useful debugging tool you will build. Every later phase uses
it.

---

## Specification

- Signature: `void kprintf(const char* fmt, ...);` using `<stdarg.h>` (`va_start`,
  `va_arg`, `va_end`) — these are compiler built-ins and are available even
  freestanding.
- Support at least:
  - `%d` / `%i` — signed decimal integer.
  - `%u` — unsigned decimal.
  - `%x` — lowercase hexadecimal.
  - `%s` — null-terminated string.
  - `%c` — single character.
  - `%%` — a literal percent sign.
- To convert an integer to text, repeatedly divide by the base and collect digits,
  then reverse them. Handle the sign for `%d`.
- Route output through the terminal driver **and** serial, so every `kprintf` is also
  logged.

---

## Your task

1. Write integer-to-string helpers for base 10 and base 16 (and the unsigned case).
2. Write `kprintf` using `va_list`. Walk `fmt`; copy plain characters; on `%`, read
   the next specifier and the matching argument.
3. Support `%d`, `%u`, `%x`, `%s`, `%c`, `%%` at minimum.
4. Send output to both the screen and serial.
5. Test with a line that mixes types, for example
   `kprintf("val=%d hex=%x str=%s\n", -7, 0xDEAD, "ok");`.

---

## How to verify

- `kprintf("val=%d hex=%x str=%s\n", -7, 0xDEAD, "ok")` prints
  `val=-7 hex=dead str=ok` on screen and in the serial log.
- Negative numbers, zero, and large values all print correctly.
- `%%` prints a single `%`.

---

## Common traps

- **Argument promotion.** `char` and `short` arguments arrive as `int` through
  `...`; read them with `va_arg(args, int)`.
- Printing digits in reverse because you forgot to reverse the collected buffer.
- Forgetting the sign, so `%d` of a negative number prints a huge unsigned value.
- Reading a `%s` argument as `int`. Use `va_arg(args, const char*)`.

---

## Reading

- OSDev — *Meaty Skeleton* (shows a `printf` in a kernel):
  <https://wiki.osdev.org/Meaty_Skeleton>
- `stdarg.h` reference (variadic macros):
  <https://en.cppreference.com/w/c/variadic>

---

## Phase 1 is complete

You can print formatted text to the screen and to a captured serial log, with color
and scrolling. Commit. You now have the tools to debug everything ahead.

Next phase: **[[Phase 2 - Overview]]**.

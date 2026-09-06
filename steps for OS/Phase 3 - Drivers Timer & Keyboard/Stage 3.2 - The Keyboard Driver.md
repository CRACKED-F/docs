# Stage 3.2 — The Keyboard Driver

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 3 - Overview|Phase 3 — Drivers: Timer & Keyboard]]

---

## Concept

A PS/2 keyboard fires **IRQ 1** on every key event and hands you a **scancode** — a
number identifying the key, *not* the letter. Press 'A' and you get one scancode; let
go and you get another (the "release", with the high bit set). Your driver reads the
scancode, maps it to a character with a **keymap**, tracks modifier keys like Shift,
and delivers the character.

QEMU emulates the keyboard in "scancode set 1", the simplest set, which keeps this
manageable.

---

## Specification

- Read the scancode from the PS/2 data port `0x60` inside your IRQ 1 handler.
- A scancode with the top bit (`0x80`) set is a **release**; otherwise it is a
  **press**. Track Shift press/release to pick the right character.
- Keep a **scancode-to-ASCII table** for set 1. Map the common keys: letters, digits,
  space, Enter, Backspace. Non-printing keys can be ignored at first.
- Register the handler on IRQ 1 and unmask that line.
- Deliver each decoded character somewhere the rest of the kernel can read it — a
  callback or a small ring buffer. Stage 3.3 turns this into full lines.

---

## Your task

1. Write an IRQ 1 handler that reads port `0x60`.
2. Detect press vs release using the `0x80` bit; update a Shift-held flag.
3. Map press scancodes to ASCII with a set-1 table, choosing the shifted or unshifted
   character based on the Shift flag.
4. Register on IRQ 1 and unmask it.
5. For now, echo each decoded character with `kprintf` to prove the mapping.

---

## How to verify

- Typing letters in the QEMU window echoes the correct characters, and Shift produces
  capitals and shifted symbols.
- Holding then releasing a key produces exactly one character (on press), not two.
- Enter and Backspace produce distinct, recognizable codes you can act on.

---

## Common traps

- Treating release scancodes as presses, so every key types twice.
- A wrong or incomplete keymap; start small and grow it.
- Reading port `0x60` outside the interrupt without checking the status port, which
  can read stale or empty data. Reading inside the IRQ 1 handler avoids this early on.
- Forgetting to unmask IRQ 1.

---

## Reading

- OSDev — *PS/2 Keyboard* and *"8042" PS/2 Controller*:
  <https://wiki.osdev.org/PS/2_Keyboard> · <https://wiki.osdev.org/%228042%22_PS/2_Controller>
- Scancode set 1 table: <https://wiki.osdev.org/PS/2_Keyboard#Scan_Code_Set_1>

Next: **[[Stage 3.3 - An Input Line Buffer]]**.

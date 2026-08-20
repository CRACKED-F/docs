# Stage 0.6 — Serial Output

**Difficulty:** Medium · ~45 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

This is your **proof of life**. Not a pixel — a character out of the serial port.

The classic first milestone is a white `A` in the corner of the screen. We do serial
first, deliberately, and it is strictly better in every way that matters:

| | Screen | Serial |
|---|---|---|
| Works before any display code | no | **yes** |
| Survives the crash that follows | no — the screen freezes | **yes — already written to a file** |
| Works on real hardware with no text mode | no | **yes** |
| Readable by CI | no | **yes** |
| Needs a font, a framebuffer, and pitch arithmetic | yes | no |

Chasing a pixel before you have serial output is how people spend a weekend debugging
a display when the kernel was never reached at all.

A serial port is also about the simplest device on the machine: a handful of I/O
ports, one status bit to poll, one data register to write.

---

## Specification

COM1 is at I/O port base **`0x3F8`**. The registers you need, as offsets from the
base:

| Offset | Register | Use |
|---|---|---|
| 0 | Data / divisor low | Write a byte to transmit |
| 1 | Interrupt enable / divisor high | Set to 0 — we poll, we do not use IRQs |
| 2 | FIFO control | Enable and clear the FIFOs |
| 3 | Line control | 8N1, and the DLAB bit for baud setting |
| 4 | Modem control | DTR/RTS, and loopback for self-test |
| 5 | Line status | **Bit 5 = transmitter holding register empty** |

Initialisation sequence:

1. Disable interrupts (`offset 1` ← `0x00`).
2. Set DLAB (`offset 3` ← `0x80`) to expose the divisor registers.
3. Write the baud divisor. `115200 / 115200 = 1`, so divisor low ← `0x01`, high ←
   `0x00`.
4. Clear DLAB and set the line format: 8 data bits, no parity, 1 stop bit
   (`offset 3` ← `0x03`).
5. Enable and clear the FIFOs (`offset 2` ← `0xC7`).
6. Set DTR, RTS, OUT2 (`offset 4` ← `0x0B`).
7. **Self-test:** set loopback mode (`offset 4` ← `0x1E`), write a byte, read it back.
   If it does not match, no serial port is present — record that and carry on rather
   than hanging.
8. Leave loopback (`offset 4` ← `0x0F`).

To transmit: poll line status bit 5 until set, then write the byte to offset 0.

Port I/O needs `outb`/`inb`, which are inline assembly — so they live in
`kernel/arch/x86_64/io.hpp` and nowhere else ([[07 - Repository Layout]] rule 1).

---

## Your task

1. Write `outb`, `inb`, `outw`, `inw`, `outl`, `inl` as `inline` functions in
   `kernel/arch/x86_64/io.hpp`. **Every one needs a `"memory"` clobber** — see
   [[13 - Coding Standards]] rule 2.
2. Write `kernel/drivers/char/serial.cpp` with `serial_init()`, `serial_putc(char)`,
   and `serial_write(const char*, size_t)`.
3. Translate `\n` to `\r\n` on output — terminals expect it, and without it your log
   is a staircase.
4. Perform the loopback self-test and remember the result. **Do not hang if there is
   no serial port** — a real machine may genuinely lack one, and the kernel must still
   boot.
5. Call `serial_init()` as the **very first thing** in `kernel_init()`, before
   anything else can fail.
6. Print a greeting: the project name, the version string, and the framebuffer
   geometry from `BootInfo`.

---

## How to verify

You cannot boot until Stage 0.5 builds an image. From then on:

```sh
make run-serial
```

Expected:

```
CRACKED-F OS v0.0.1-dev
framebuffer: 1280x800x32 pitch=5120 @ 0xFD000000
memory: 12 regions, 511 MiB usable
hhdm offset: 0xFFFF800000000000
```

Checks:

- The text appears in your terminal, not just in a QEMU window.
- `make run` writes the same text to `build/serial.log`.
- The framebuffer geometry matches what you asked for in `boot/limine.conf`.
- Boot with `-m 128M` and confirm the usable-memory figure changes accordingly —
  proof you are reading the real memory map, not a hardcoded value.

---

## Common traps

- **Forgetting the DLAB dance.** Offsets 0 and 1 are *either* data/interrupt-enable
  *or* the baud divisor, depending on bit 7 of the line-control register. Set the
  divisor with DLAB on, then clear DLAB before transmitting. Leaving DLAB set means
  every byte you "transmit" goes into the divisor register instead.
- **Not polling the transmit-ready bit.** Writing bytes faster than the UART can send
  them silently drops characters, and your log has holes in exactly the interesting
  places.
- **Hanging when no serial port exists.** The self-test tells you. Record the result
  and continue — a kernel that refuses to boot on a machine with no UART is not
  deployable.
- **Missing the `"memory"` clobber on `outb`.** The compiler may reorder around the
  port write. It works today and breaks after an unrelated change alters inlining.
- **Only `\n`, without `\r`.** Your output marches diagonally down the terminal.
- **Forgetting `-serial stdio`.** The port works; you are just not looking at it.
  `make run-serial` handles this.

---

## Why this comes before the framebuffer

Look at the initialisation order in [[06 - Architecture Overview]]. Serial is step 1;
the framebuffer console is step 6. Everything between them — the boot-info copy, the
GDT, the IDT, the panic handler — can fail, and if it does, serial is the only thing
that can tell you.

This ordering is reversed from the original plan, and it is one of the more valuable
changes in the whole vault.

---

## Reading

- OSDev — *Serial Ports* (the register table, in full):
  <https://wiki.osdev.org/Serial_Ports>
- OSDev — *Inline Assembly* (constraints and clobbers):
  <https://wiki.osdev.org/Inline_Assembly>
- [[14 - Debugging Playbook]] — why serial is the first thing every failure section
  asks about

Next: **Stage 0.7 - Panic and KASSERT**

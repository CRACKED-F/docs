# Stage 1.4 — Serial Port Logging

**Difficulty:** Medium · ~25 minutes
**Phase:** [[Phase 1 - Overview|Phase 1 — Text Output]]

---

## Concept

The screen is useless the instant the kernel crashes — it freezes on whatever was
there. The **serial port** solves this. It is an old, dead-simple hardware interface.
QEMU can pipe it straight to your terminal or a file, so every line you send is saved
*before* a crash can hide it. From here on, log everything important to serial. When a
later phase gives you a blank screen, the serial log's last line is usually the clue.

---

## Specification

- COM1 is at I/O port base `0x3F8`.
- Initialize it once: disable interrupts on the chip, set the baud divisor, set 8
  bits / no parity / 1 stop bit (the `0x03` line-control value), enable the FIFO, and
  set the modem control bits. The exact register sequence is on the OSDev *Serial
  Ports* page — copy it, it is standard boilerplate.
- To send a byte: poll the line-status register (base `+ 5`) until the
  transmit-empty bit (`0x20`) is set, then write the byte to the data register
  (base `+ 0`).
- Run QEMU with `-serial stdio` (your `make run-serial` target from Stage 0.6) to see
  the output in your terminal, or `-serial file:serial.log` to capture it.

---

## Your task

1. Write `serial_init()` following the OSDev register sequence for COM1.
2. Write `serial_write_char(char c)` that waits for the transmit-empty bit, then
   writes the byte.
3. Write `serial_write(const char* s)`.
4. Route your terminal output through both: make `print` (or a new `klog`) also send
   to serial.
5. Boot with `-serial stdio` and confirm your kernel's messages appear in the
   terminal, not only on the QEMU screen.

---

## How to verify

- `make run-serial` shows your kernel's text in the terminal that launched QEMU.
- Messages appear in serial even if you deliberately hang the kernel right after
  printing them (proof it survives a freeze).
- `-serial file:serial.log` writes the same text to a file you can open.

---

## Common traps

- Not polling the transmit-empty bit before writing, so bytes are dropped and output
  looks truncated.
- Initializing the wrong port base. COM1 is `0x3F8`.
- Expecting serial to appear on the QEMU *screen*. It does not — it goes to the
  terminal or file you routed it to.

---

## Reading

- OSDev — *Serial Ports* (has the exact init sequence):
  <https://wiki.osdev.org/Serial_Ports>
- QEMU serial documentation (`-serial` options):
  <https://www.qemu.org/docs/master/system/invocation.html>

Next: **[[Stage 1.5 - kprintf, a Formatted Printer]]**.

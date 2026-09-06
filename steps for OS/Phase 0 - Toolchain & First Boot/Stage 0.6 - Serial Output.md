# Stage 0.6 — Serial Output

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `kernel/arch/x86_64/io.hpp`, `kernel/drivers/char/serial.cpp`, `kernel/include/kernel/serial.hpp`
**Deliverable:** **FIRST OUTPUT** — a line of text leaves COM1, appears in your terminal, and is captured to `build/serial.log`.

---

## Progress

- [ ] Write `kernel/arch/x86_64/io.hpp` with `outb`/`inb`/`outw`/`inw`/`outl`/`inl`
- [ ] Confirm every one has a `"memory"` clobber and every `inX` is `volatile`
- [ ] Write `kernel/include/kernel/serial.hpp` — the portable interface, no asm
- [ ] Write `kernel/drivers/char/serial.cpp` with named register constants, no bare hex
- [ ] Implement `serial_init()` following the 9-step sequence in §4
- [ ] Implement the loopback self-test with a **bounded** spin — it must not hang
- [ ] Implement `serial_putc` polling LSR bit 5, with `\n` → `\r\n` in the driver
- [ ] Implement `serial_write`, `serial_puts`, `serial_write_dec`, `serial_write_hex`
- [ ] Call `serial_init()` as the very first statement of `kernel_init()`
- [ ] Print the greeting: name, version, framebuffer geometry, memory, HHDM offset
- [ ] Confirm `make run` writes `build/serial.log` as well as printing to your terminal
- [ ] `make run-serial` shows the greeting **in your terminal**
- [ ] `make run-serial QEMU_MEM=128M` shows a **different** usable-memory figure
- [ ] `make lint` still passes (no inline asm outside `kernel/arch/`)
- [ ] Committed with a message like `feat(boot): serial output over COM1`

---

## 1. Why this stage exists

The kernel is currently a black box. [[Stage 0.5 - Building a Bootable Image|Stage 0.5]]
proved that Limine loads the image and jumps to `kmain`, but the only proof was
attaching the QEMU monitor and reading `RIP`. That works exactly once. It does not
scale to "the page-fault handler is entered with the wrong error code", and it cannot
be automated.

Every debugging technique you will use for the next two years reduces to *the kernel
telling you something*. Without an output channel you are bisecting by `hlt` — insert
a halt, see if the machine stops, move the halt. That is genuinely how people debug
kernels with no output, and it costs about an hour per bug.

The specific failure this stage prevents is expensive. If your first output attempt is
a pixel, a black screen has at least five causes: `kmain` was never reached, `BootInfo`
was never populated, `fb_addr` is wrong, `pitch` is wrong, or the pixel format is BGR
where you assumed RGB. You cannot distinguish them, because the only diagnostic you
have is the thing that is broken. People lose weekends here writing and rewriting
correct display code on a machine where `kmain` never ran.

Serial breaks the loop because it has no dependencies: no memory map, no page tables,
no `BootInfo`, no font, no IDT. Nine `out` instructions and the port is live. From here
on every failure is *reportable*, which is the foundation of
[[Stage 0.7 - Panic and KASSERT|Stage 0.7]], of the log ring in
[[Phase 1 - Overview|Phase 1]], and of every automated test in [[09 - Testing Strategy]].

---

## 2. The concept

### What a UART is

A **UART** — Universal Asynchronous Receiver/Transmitter — converts between two
representations of a byte: **parallel** inside the machine (eight bits at once) and
**serial** on the wire (one bit at a time). "Asynchronous" means there is no clock wire;
the two ends agree in advance on a **bit rate** and the receiver recovers timing from
the edge at the start of each byte. That agreement is the whole configuration problem —
get the rate wrong and the receiver samples at the wrong instants. The chip is the
**16550**, which shipped in the IBM PC/AT and has been carried forward by every
PC-compatible machine and every emulator since: old, tiny, completely specified, which
is exactly why it is the right first device.

### The byte on the wire

```
       idle   start │ d0  d1  d2  d3  d4  d5  d6  d7 │ stop   idle
   ─────────┐       ┌───┬───┬───┬───┬───┬───┬───┬───┐        ┌────────
            └───────┴───┴───┴───┴───┴───┴───┴───┴───┴────────┘
             1 bit  │      8 data bits, LSB first    │ 1 bit

   115200 baud → 1 bit ≈ 8.68 us → 10 bits ≈ 86.8 us per byte ≈ 11.5 KB/s
```

The line idles high; a falling edge is the **start bit** ("a byte begins now"). Then
eight data bits, LSB first, then a **stop bit** returning the line to idle so there is
an edge available for the next start bit. **8N1** names this frame: **8** data bits,
**N**o parity, **1** stop bit. Parity is a single error-detecting bit nobody uses over a
two-foot cable; two stop bits were for mechanical teletypes that needed settling time.
8N1 is the universal default.

### "Serial port" on a machine with no serial connector

Your laptop has no 9-pin D-sub. It may still have a 16550 in the chipset with nothing
wired to it, or none at all. Neither matters, because you are developing under QEMU, and
**QEMU emulates a 16550 whether or not the host has one**. The emulated chip is real
from the kernel's point of view — same ports, same registers, same bits. What differs is
what happens after the transmit register: the byte goes to a host-side **character
device backend** you choose on the command line.

```
  your kernel        emulated 16550          QEMU chardev backend      you
 ┌────────────┐    ┌──────────────────┐    ┌──────────────────┐   ┌──────────┐
 │ outb 0x3F8 │───►│ THR ─► shift reg │───►│ stdio            │──►│ terminal │
 └────────────┘    └──────────────────┘    │ logfile=...      │──►│ file     │
                                           │ (vc / null)      │──►│ nowhere  │
                                           └──────────────────┘   └──────────┘
```

`-serial stdio` wires it to your terminal; `-serial file:build/serial.log` to a file.
Pass neither and QEMU still emulates the UART perfectly and sends the bytes somewhere
you are not looking. That is trap 1 in §7. On real hardware you reach the same port
with a £10 USB-to-TTL adapter and none of this code changes.

### Port-mapped I/O versus MMIO

x86 has **two separate address spaces**:

```
   MEMORY ADDRESS SPACE                    I/O PORT SPACE
   64-bit addresses                        16-bit addresses (0x0000-0xFFFF)
   reached by mov / any instruction        reached ONLY by in / out
   translated by the page tables           NOT translated — no paging
   cacheable, reorderable                  uncached, strongly ordered
   a C++ pointer names a location          no C++ construct names a port
```

**MMIO** puts device registers at physical *memory* addresses: you map them with page
tables and access them through a `volatile` pointer — precisely the case
[[13 - Coding Standards]] rule 3 allows `volatile` for. Every modern device is MMIO:
LAPIC, IOAPIC, HPET, PCIe config space, AHCI, NVMe, the framebuffer itself.

**Port-mapped I/O** puts them in the separate 64 KiB I/O space, reachable only by the
`in`/`out` families. The legacy PC devices are all here, because the 8086 had a separate
I/O space and the ecosystem is still bit-compatible with the 1981 IBM PC: PIC at
`0x20`/`0xA0`, PIT at `0x40`–`0x43`, PS/2 at `0x60`/`0x64`, CMOS at `0x70`/`0x71`, PCI
config at `0xCF8`/`0xCFC`, and **COM1 at `0x3F8`**.

The consequence: **there is no C++ expression that reads or writes an I/O port.** A
pointer cannot name one. You must emit an `in` or `out` instruction, which means inline
assembly, which by [[07 - Repository Layout]] rule 1 may appear only under
`kernel/arch/` — and `scripts/lint.sh` greps for it on every `make lint`. Port I/O also
does not exist at all on ARM or RISC-V, so confining it is the difference between
porting a driver and rewriting a kernel.

The instructions themselves are `out <data>, <port>` and `in <port>, <data>`, in three
widths — 8, 16, 32 bits; there is no 64-bit form. The **data** operand must be
`AL`/`AX`/`EAX`; no other register can encode. The **port** operand must be `DX`, or an
8-bit immediate if the port is below 256. Those two constraints are why the inline
assembly in §5 looks the way it does — they are encoding rules, not style.

### Baud rate and the divisor

The UART has a fixed **1.8432 MHz** input clock and a 16-bit **divisor latch**. The
generator divides by the divisor, then by a further 16 (the receiver oversamples each
bit sixteen times to find its centre), so `baud = 1843200 / (16 * divisor) = 115200 /
divisor`. 115200 is therefore the maximum, at **divisor 1** — that is where
`115200 / 115200 = 1` comes from. Divisor 3 gives 38400, divisor 12 gives 9600. Take the
maximum: serial is your slowest resource and a panic dump at 9600 takes twelve times as
long to appear.

Under QEMU the divisor is functionally irrelevant — there is no wire and no clock, just
a pipe — so a wrong divisor produces perfect output in the emulator and mojibake on real
hardware. Set it correctly now; you will not find this bug later.

---

## 3. Design decisions and tradeoffs

### Decision: serial before the framebuffer

The central ordering decision of Phase 0, reversed from the classic tutorial path where
the first milestone is a white `A` in the corner of the screen.

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — serial first, framebuffer in Phase 1** | Nine `out` instructions programme COM1; text goes to a host pipe | Text only, ~11.5 KB/s | ✅ |
| B — framebuffer first | Read `BootInfo`, compute a pixel offset, blit a glyph from a font | Depends on `BootInfo`, a font, and pitch arithmetic before any of them is verified | ❌ |
| C — VGA text mode at `0xB8000` | Write char+attribute pairs into a fixed buffer | Does not exist on UEFI machines at all | ❌ |

| | Screen | Serial |
|---|---|---|
| Works before any display code exists | no | **yes** |
| Survives the crash that follows | no — the screen freezes as-is | **yes — already flushed to a file** |
| Works on real hardware with no text mode | no | **yes** |
| Readable by CI | no | **yes** |
| Needs a font, a base address, and pitch arithmetic | yes | no |
| Needs a valid `BootInfo` | yes | no |

**Why A.** Serial has *no dependencies*. Look at the initialisation order in
[[06 - Architecture Overview]]: serial is **step 1**, the `BootInfo` copy is step 2, GDT
is 3, IDT is 4, the panic handler is 5, and the framebuffer console is **step 6**.
Everything in between can fail, and if serial is not already live none of those failures
can be reported. That table is not a preference; it is a dependency order, and serial
sits at its root precisely because it depends on nothing. The second property matters as
much: a framebuffer console shows the last thing drawn, and when the machine
triple-faults and resets the screen is gone, whereas serial output has already left the
machine — `scripts/test.sh` runs QEMU with `-serial file:build/serial.log`, so by the
time the kernel dies the evidence is on the host filesystem, which is why its failure
path can print the last 60 lines of the log.

**Why not B.** Concretely: black screen, five hypotheses, zero diagnostics. With serial
working, four of the five are answered by one `serial_write_hex(info->fb_addr)`.

**Why not C.** [[ADR-0004 - Framebuffer Console Not VGA Text]] settles it: UEFI makes no
guarantee the display is left VGA-compatible, and on modern machines it is not. Writing
to `0xB8000` produces no error and no output — the code is correct and the platform is
wrong, which is the worst debugging experience there is.

**When B would be right.** On a target with no UART and no debug header — a locked-down
board, a console, a VM with the serial device removed. Note what you would reach for
instead: JTAG, a debug UART on test pads, or a ring buffer in a fixed physical page a
host tool reads post-mortem. *Some* output before *any* logic is the invariant; serial
is just how a PC satisfies it.

---

### Decision: polled transmit, not interrupt-driven

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — poll LSR bit 5** | Spin on the line-status register until the transmit holding register is empty, then write | ~87 us of CPU per byte at 115200 | ✅ |
| B — interrupt-driven with a ring buffer | Enable the THRE interrupt, queue bytes, drain in the IRQ handler | Needs an IDT, an IRQ handler, a buffer, and a lock — none exist in Phase 0, all are hostile in a panic | ❌ |
| C — write blindly, no polling | Just `outb` and move on | Silently drops characters whenever you outrun the UART | ❌ |

**Why A.** Three reasons in increasing order of importance. **It works now** — the IDT
does not exist until [[Phase 2 - Overview|Phase 2]], so B is not implementable here at
all. **It cannot deadlock** — one read-only global, one hardware register, no queue, no
lock, no handler to re-enter. And **it is the only thing safe in `panic()`**: when the
panic handler runs you may be inside an interrupt handler, holding a spinlock, with a
corrupt heap and an overflowed stack, so you must not allocate, must not lock, and must
not depend on interrupt delivery. The panic path runs with interrupts disabled, so an
interrupt-driven driver would enqueue the message and wait forever for an IRQ that can
never arrive — **the panic handler would hang instead of printing why it panicked.**

**Why not B.** Beyond the deadlock, the throughput argument is weaker than it looks:
interrupts do not make the wire faster, they only free the CPU during the wait, and in
Phase 0 the CPU has nothing else to do.

**Why not C.** The transmit holding register accepts one byte. Write a second before the
first has moved to the shift register and the first is overwritten — silently, no error
bit. The bytes you lose are the ones you wrote fastest: a panic dump, a tight loop, an
interrupt storm. Your log develops holes in exactly the interesting places and you spend
hours believing execution stopped where the log stops.

**When B would be right.** When serial becomes a real logging transport rather than a
debug channel — a high-throughput `dmesg`, or a console with input — where 87 us per
character of a time slice becomes measurable. The right shape then is a **hybrid**:
interrupt-driven with a ring buffer for normal `printk`, and the polled path retained and
used unconditionally by `panic()` and early boot. Linux does exactly this (`earlycon`,
and polled writes in oops paths). **The polled path never goes away.**

---

### Decision: port I/O via inline assembly, confined to `kernel/arch/`

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — `static inline` extended asm in `kernel/arch/x86_64/io.hpp`** | One `in`/`out` inlined at every call site | Inline asm must be written correctly once | ✅ |
| B — out-of-line accessors in a `.asm` file | NASM implements them; C++ calls them | A `call`/`ret` pair around a single instruction, and an opaque barrier to the optimiser | ❌ |
| C — a libc-style `<sys/io.h>` | Let the toolchain provide it | glibc-only, absent in a freestanding build, and its userspace form needs `ioperm`/`iopl` | ❌ |

**Why A.** Inline assembly is unavoidable — the I/O space is unreachable from C++ — so
the only questions are where it lives and whether it inlines. `static inline` in a header
gives one instruction per call site with no call overhead and lets the compiler keep the
port number in a register across a sequence of writes. Since inline asm is confined to
`kernel/arch/` by [[07 - Repository Layout]] rule 1, a header there is the only legal
home.

**Why not B.** `serial_init()` performs eleven port writes and a polled `serial_putc`
performs at least one `inb` per byte; wrapping each in a function call is pure waste, and
you lose the ability to reason precisely about what the compiler may reorder — the
subject of the `"memory"` clobber in §5.

**Why not C.** `<sys/io.h>` is a userspace facility requiring `iopl(3)`/`ioperm(2)` to
grant ring-3 access. The kernel is ring 0 and has that access unconditionally — and has
no libc ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]).

**When B would be right.** When a routine needs more than a couple of instructions or
precise control over register allocation: the ISR stubs, the context switch, the AP
trampoline — which is what `kernel/arch/x86_64/asm/` is for. Rule of thumb: one
instruction with a clean operand mapping → inline asm; a sequence with its own control
flow or stack discipline → a `.asm` file.

---

### Decision: fail soft when there is no UART

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — self-test, record the result, continue** | Loopback test sets `g_present`; later calls become a cheap no-op if false | One `bool`, one branch per character | ✅ |
| B — hang or panic if the self-test fails | `for(;;) hlt;` when the byte does not round-trip | The kernel refuses to boot on hardware that is otherwise fine | ❌ |
| C — no self-test, always write blindly | Skip detection entirely | Wasted spins per character, and no way to answer "is serial alive?" | ❌ |

**Why A.** A machine may genuinely have no UART, and that is a configuration, not an
error. The kernel's job is to boot. Recording the result also gives the rest of the
kernel a fact it can act on: Phase 1's log subsystem decides whether serial is a valid
sink, and the panic handler decides whether it must rely on the framebuffer alone.

Detection falls out of how an absent device behaves. On x86, reading an I/O port that
nothing decodes returns **`0xFF`** — the bus floats high — so `inb(0x3F8)` returns
`0xFF`, which is not the `0xAE` you wrote, and the test fails correctly with no special
case. A *wedged* UART is the other failure: LSR reads `0x00` forever, data-ready never
sets, and the **bounded** spin in `wait_for_lsr` times out rather than hanging. Both
modes are covered by the same eight lines.

**Why not B.** A kernel that refuses to boot because a debug channel is missing is not
shippable. You would ship a build that runs on your laptop and bricks a customer's
machine with no output — because the thing you would have used to diagnose it is the
thing that halted. More mundanely, QEMU configurations without an ISA serial device, and
hypervisors that present none, become un-bootable for no reason.

**Why not C.** C is *harmless* rather than wrong: with no UART, LSR reads `0xFF`, which
has bit 5 set, so the poll succeeds immediately and each byte goes into the void. What
you lose is the ability to answer "is serial working?" anywhere else, and the timeout
protection — a *wedged* UART with LSR stuck at `0x00` hangs in the first `serial_putc`,
which is the exact hang B was rejected for. C is B with extra steps.

**When B would be right.** In the self-test build, where serial *is* the deliverable.
`kernel-test.elf` (the `self-test` entry in `boot/limine.conf`) reports through serial
and the QEMU exit device per [[ADR-0010 - Testing Strategy and the QEMU Exit Device]];
if serial is dead there the harness observes nothing, so failing loudly is correct. That
is a different binary with a different contract, not the shipping kernel.

---

### Decision: `\n` → `\r\n` in the driver, not at the call site

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — the driver expands `\n`** | `serial_putc('\n')` emits `\r` then `\n` | One comparison per character | ✅ |
| B — callers write `"\r\n"` | Every literal in the kernel carries `\r\n` | Enforced by memory across hundreds of sites | ❌ |
| C — no translation | Emit `\n` only | Output marches diagonally down the terminal | ❌ |

**Why A.** This is a **terminal convention, not a kernel concept**. On a teletype `\n`
advanced the paper and `\r` moved the print head back to column zero — two mechanisms,
both needed — and terminal emulators still behave that way. The kernel's internal
representation of "end of line" should be a single `\n`, as it is in every string
literal, log message, and file the kernel will ever write. The translation belongs where
the convention is imposed: at the device boundary.

**Why not B.** The penalty for forgetting is not a compile error but a corrupted-looking
log. It also poisons the data — the moment you add the log ring in Phase 1 or write
kernel messages to a file in Phase 7 you are storing device escape bytes in structured
data.

**Why not C.** This is trap 2 in §7, and it looks like a staircase.

**When B would be right.** Never for `\n` — but the principle flips for *escape
sequences*. Colour, cursor positioning and screen clearing are also terminal conventions,
and you would not want the driver scanning every byte for them. The line is: the driver
normalises the one convention that is universal and unavoidable; anything richer belongs
in a terminal layer above it.

---

## 4. Specification

**COM port bases (PC convention):** COM1 `0x3F8`, COM2 `0x2F8`, COM3 `0x3E8`,
COM4 `0x2E8`.

### 16550 register map — offsets from the base

| Offset | Read | Write | DLAB |
|---|---|---|---|
| 0 | RBR — receive buffer | THR — transmit holding | 0 |
| 0 | DLL — divisor latch, low byte | DLL | **1** |
| 1 | IER — interrupt enable | IER | 0 |
| 1 | DLH — divisor latch, high byte | DLH | **1** |
| 2 | IIR — interrupt identification | FCR — FIFO control | — |
| 3 | LCR — line control | LCR | — |
| 4 | MCR — modem control | MCR | — |
| 5 | **LSR — line status** | — | — |
| 6 | MSR — modem status | — | — |
| 7 | SCR — scratch | SCR | — |

**Offsets 0 and 1 have two completely different meanings**, selected by bit 7 of LCR
(the DLAB bit). This is the single most common source of "it does nothing" in this
stage.

### Line Control Register (offset 3)

| Bits | Meaning |
|---|---|
| 1:0 | word length: `00`=5, `01`=6, `10`=7, **`11`=8** data bits |
| 2 | stop bits: **`0`=1**, `1`=2 (1.5 for 5-bit words) |
| 5:3 | parity: **`000`=none**, `001`=odd, `011`=even, `101`=mark, `111`=space |
| 6 | set break enable |
| 7 | **DLAB** — divisor latch access |

`0x03` = 8 data bits, 1 stop bit, no parity = **8N1**. `0x80` = DLAB alone.

### FIFO Control (offset 2, write-only) · Modem Control (offset 4)

| FCR bit | Value | Meaning | | MCR bit | Value | Meaning |
|---|---|---|---|---|---|---|
| 0 | `0x01` | enable FIFOs | | 0 | `0x01` | DTR — data terminal ready |
| 1 | `0x02` | clear receive FIFO | | 1 | `0x02` | RTS — request to send |
| 2 | `0x04` | clear transmit FIFO | | 2 | `0x04` | OUT1 — unused on a PC |
| 3 | `0x08` | DMA mode select | | 3 | `0x08` | OUT2 — **gates the UART IRQ** |
| 7:6 | `0xC0` | receive trigger = 14 bytes | | 4 | `0x10` | LOOP — internal loopback |

`FCR = 0xC7` = enable + clear both + 14-byte trigger.
`MCR = 0x0B` (normal) · `0x1E` (self-test) · `0x0F` (normal, after the test).

### Line Status Register (offset 5, read-only)

| Bit | Value | Meaning |
|---|---|---|
| 0 | `0x01` | **data ready** — a byte is waiting in RBR |
| 1 | `0x02` | overrun error |
| 2 | `0x04` | parity error |
| 3 | `0x08` | framing error |
| 4 | `0x10` | break interrupt |
| 5 | `0x20` | **transmitter holding register empty — safe to write offset 0** |
| 6 | `0x40` | transmitter empty (THR *and* shift register) |
| 7 | `0x80` | error in received FIFO |

### Baud divisor

`baud = 115200 / divisor`

| Baud | Divisor | DLL | DLH |
|---|---|---|---|
| **115200** | **1** | `0x01` | `0x00` |
| 57600 | 2 | `0x02` | `0x00` |
| 38400 | 3 | `0x03` | `0x00` |
| 9600 | 12 | `0x0C` | `0x00` |

### Initialisation sequence

| # | Write | Value | Why |
|---|---|---|---|
| 1 | offset 1 (IER) | `0x00` | mask all UART interrupts — there is no IDT yet |
| 2 | offset 3 (LCR) | `0x80` | set DLAB, exposing the divisor latch at offsets 0/1 |
| 3 | offset 0 (DLL) | `0x01` | divisor low byte — 115200 baud |
| 4 | offset 1 (DLH) | `0x00` | divisor high byte |
| 5 | offset 3 (LCR) | `0x03` | clear DLAB **and** set 8N1 in one write |
| 6 | offset 2 (FCR) | `0xC7` | enable and clear both FIFOs |
| 7 | offset 4 (MCR) | `0x0B` | DTR + RTS + OUT2 |
| 8 | offset 4 (MCR) | `0x1E` | loopback; write `0xAE` to offset 0, read it back |
| 9 | offset 4 (MCR) | `0x0F` | leave loopback, normal operation |

Transmit: poll LSR (offset 5) until bit 5 is set, then write the byte to offset 0.

---

## 5. Writing the code

### `kernel/arch/x86_64/io.hpp`

The only place in the tree that can reach the I/O port space. Six functions, one
instruction each.

> The tree in [[07 - Repository Layout]] shows this under `kernel/arch/x86_64/cpu/`.
> Either location is fine; what the lint rule enforces is that it is somewhere under
> `kernel/arch/`. Pick one and be consistent.

```cpp
// Port-mapped I/O for x86_64.
//
// The x86 I/O space is NOT the memory address space: no C++ pointer can name
// port 0x3F8, and only the in/out instruction families can reach it. That makes
// inline assembly unavoidable here, which is why this header lives under
// kernel/arch/ and nowhere else (07 - Repository Layout, rule 1).
#pragma once

#include <stdint.h>

static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port) : "memory");
}

static inline uint8_t inb(uint16_t port) {
    uint8_t ret;
    __asm__ volatile("inb %1, %0" : "=a"(ret) : "Nd"(port) : "memory");
    return ret;
}

static inline void outw(uint16_t port, uint16_t val) {
    __asm__ volatile("outw %0, %1" : : "a"(val), "Nd"(port) : "memory");
}

static inline uint16_t inw(uint16_t port) {
    uint16_t ret;
    __asm__ volatile("inw %1, %0" : "=a"(ret) : "Nd"(port) : "memory");
    return ret;
}

static inline void outl(uint16_t port, uint32_t val) {
    __asm__ volatile("outl %0, %1" : : "a"(val), "Nd"(port) : "memory");
}

static inline uint32_t inl(uint16_t port) {
    uint32_t ret;
    __asm__ volatile("inl %1, %0" : "=a"(ret) : "Nd"(port) : "memory");
    return ret;
}
```

#### Line by line

**The extended-asm form** — `__asm__ volatile ( "template" : outputs : inputs :
clobbers );`. Four colon-separated fields; an empty field is nothing between colons,
which is why `outb` has `: :`. The compiler substitutes `%0`, `%1`, … with the operands,
**numbered across the output list first and then the input list**. This is GCC's
*extended* asm; basic `asm("...")` has no operands and is almost never what you want.

**`outb` — template and operand order.** The toolchain assembles AT&T syntax, where
**source comes first, destination second**, so `outb %0, %1` reads "write `%0` (the
value) to `%1` (the port)" and assembles to `outb %al, %dx`. Intel-syntax documentation,
including the Intel SDM, shows the operands the other way round; getting this backwards
produces an assembler error rather than a runtime bug, which is the one mercy in this
file. There are no outputs, so `%0` is the first *input*, `val`, and `%1` is `port`.

**The `"a"` constraint.** "Put this operand in the accumulator." GCC picks the width from
the C++ type: `uint8_t` → `%al`, `uint16_t` → `%ax`, `uint32_t` → `%eax`. This is not a
convenience but a hardware requirement — `out` can *only* encode `AL`/`AX`/`EAX` as the
data operand. Writing `"r"(val)` would let GCC choose `%rbx` or `%r12` and the assembler
would reject the instruction, because no such encoding exists.

**The `"Nd"` constraint — why two letters.** A multi-character constraint string is a
list of **alternatives, tried in order**. `N` is "unsigned 8-bit integer constant, for
`in` and `out` instructions" — only a compile-time constant in 0–255. `d` is the `d`
register (`%dl`/`%dx`/`%edx`). Two letters because the instruction has two encodings for
the port: an 8-bit immediate usable only below 256, and `DX` for the whole space. So
`outb(0x20, 0x11)` to the PIC compiles to `outb $0x11, $0x20` with no register at all,
while `outb(0x3F8, c)` fails `N` (0x3F8 > 255), falls to `d`, and emits a `mov` into
`%dx` then `outb %al, %dx`. Writing only `"d"` would work everywhere but waste an
instruction on low ports; only `"N"` would fail to compile for COM1 with "impossible
constraint".

**`inb` — the output operand, and renumbering.** `"=a"(ret)` is an output; `=` means
write-only (the compiler need not preserve the prior value). Because there is now an
output the numbering shifts — **`%0` is `ret` and `%1` is `port`** — so `inb %1, %0`
assembles to `inb %dx, %al`. Copy the operand order from `outb` without renumbering and
you get `inb %al, %dx`, which is not a valid instruction.

**`volatile` — what it actually prevents.** An `asm` with no output operands is
implicitly volatile, so on `outb` the keyword is redundant and written for uniformity.
On `inb` it is **load-bearing**: without it GCC treats an asm with outputs as a pure
function of its inputs and may **delete** it if the output is unused, **hoist it out of
a loop** because the inputs do not change, or **common-subexpression** two identical
`inb(0x3F8 + 5)` calls into one. Apply that to `wait_for_lsr`, whose entire job is to
read the same port repeatedly until the *device* changes the answer: GCC would hoist the
read, compare one stale value forever, and produce an infinite loop on a UART that is
working perfectly. `volatile` says: this statement has effects you cannot see; execute
it exactly where written, exactly as often as written.

**The `"memory"` clobber — the bug that arrives in six months.** It tells the compiler
the asm may read or write *any* memory. Three consequences, all of which matter: values
held in registers must be **written back before** the asm; values read after must be
**re-loaded**, not reused; and loads and stores may **not move across** it in either
direction. Without it, GCC's model says the asm touches only `%al` and `%dx`, and every
other memory access is fair game to reorder — so a driver that writes a command byte
into a DMA descriptor and then kicks the device with an `outb` may legally have the
descriptor store sunk to *after* the `outb`, and the device reads a descriptor that has
not been written.

This is [[13 - Coding Standards]] rule 2, and it is a rule rather than a suggestion
because of the timeline. **The code works** — at `-O2`, with this call graph, GCC
happened not to reorder anything. Six months later someone adds a struct field, marks a
function `inline`, or turns an `if` into a `switch`; inlining decisions shift, the
reordering becomes profitable, GCC takes it — legally, because you told it the asm has
no memory effects — and a driver that has worked for months starts corrupting data.
`git bisect` lands on a commit with nothing to do with the failure. Add the clobber to
every asm that touches hardware and the category never happens.

Note that `"memory"` is a **compiler** barrier, not a CPU barrier: on x86 the CPU
already guarantees memory accesses are not reordered with I/O instructions (Intel SDM
Vol 3A, the memory-ordering chapter). The compiler knows none of that, which is why the
clobber is needed anyway.

**`static inline`, and why not `[[nodiscard]]`.** `static` gives internal linkage — each
TU gets its own copy, no multiple-definition errors from a header, no symbol emitted if
unused — and `inline` for a one-instruction body always takes at `-O2`, so
`outb(0x3F8, 'A')` compiles to two instructions with no call. The `inX` functions are
deliberately **not** `[[nodiscard]]`, despite [[13 - Coding Standards]] rule 6:
read-to-clear is a real hardware pattern (draining the PS/2 output buffer in Phase 3,
reading IIR to acknowledge a UART interrupt) and marking these would force
`(void)inb(...)` at every such site. Rule 6 is about *fallible* functions whose error
the caller must handle; a port read is not one.

---

### `kernel/include/kernel/serial.hpp`

The portable interface: no assembly, no port numbers, so any subsystem may include it
without pulling in architecture code.

```cpp
#pragma once

#include <stddef.h>
#include <stdint.h>

// COM1, 16550-compatible UART. Polled, never interrupt-driven: this must work
// before the IDT exists (Phase 2) and must never block or allocate inside
// panic(). See Stage 0.6.

// Programme COM1 and run the loopback self-test. Never hangs: if no UART is
// present the result is recorded and every later call becomes a no-op.
void serial_init();

// True if the loopback self-test round-tripped a byte.
[[nodiscard]] bool serial_present();

void serial_putc(char c);                       // '\n' is expanded to "\r\n"
void serial_write(const char* buf, size_t len);
void serial_puts(const char* s);                // NUL-terminated

// Minimal number formatting, enough for the boot greeting. kprintf() in
// Phase 1 replaces these; they remain as its lowest-level backend.
void serial_write_dec(uint64_t v);
void serial_write_hex(uint64_t v);              // "0x" + uppercase, minimal width
```

#### Line by line

**`void serial_init()` — why it does not return `bool`.** The obvious signature is
`[[nodiscard]] bool serial_init()`, rejected for a concrete reason: with `-Werror`,
`[[nodiscard]]` forces every caller to consume the value, and the only sane thing
`kernel_init` can do with it is carry on regardless — meaning an empty `if` to silence
the warning. Recording the result and exposing it through `serial_present()` says the
same thing without the ceremony, and makes the fact available to code that never called
`serial_init` (the Phase 1 log subsystem, the Stage 0.7 panic handler).
`serial_present()` *is* `[[nodiscard]]`, because discarding that answer is always a bug.

**`serial_write(const char*, size_t)` vs `serial_puts`.** `serial_write` takes an
explicit length because the Phase 1 log ring hands out non-NUL-terminated slices, and
because the panic path must print a bounded number of bytes from a buffer it does not
trust to be terminated. `serial_puts` is the convenience wrapper for string literals.

**The two number formatters.** There is no `printf` yet — `kernel/lib/printf.cpp`
arrives in Phase 1 — and rather than skip the interesting half of the greeting this
stage provides the two conversions it needs. `serial_write_hex` prints a `0x` prefix,
uppercase digits, and **minimal width** (no zero padding), so a framebuffer address
prints as `0xFD000000` and the HHDM offset as `0xFFFF800000000000`.

---

### `kernel/drivers/char/serial.cpp`

Register definitions, the init sequence, the self-test, and polled transmit.

```cpp
#include "kernel/serial.hpp"

#include "arch/x86_64/io.hpp"

#include <stddef.h>
#include <stdint.h>

namespace {

// 16550 register map, offsets from the port base.
// Reference: TI PC16550D datasheet, register summary; OSDev "Serial Ports".
constexpr uint16_t COM1_BASE = 0x3F8;   // IBM PC convention; COM2 is 0x2F8

constexpr uint16_t REG_DATA = 0;   // RBR (read) / THR (write), when DLAB = 0
constexpr uint16_t REG_DLL  = 0;   // divisor latch, low byte,  when DLAB = 1
constexpr uint16_t REG_IER  = 1;   // interrupt enable,         when DLAB = 0
constexpr uint16_t REG_DLH  = 1;   // divisor latch, high byte, when DLAB = 1
constexpr uint16_t REG_FCR  = 2;   // FIFO control (write-only)
constexpr uint16_t REG_LCR  = 3;   // line control
constexpr uint16_t REG_MCR  = 4;   // modem control
constexpr uint16_t REG_LSR  = 5;   // line status (read-only)

// LCR: bits 1:0 = 11 (8 data bits), bit 2 = 0 (1 stop), bits 5:3 = 000 (no parity)
constexpr uint8_t LCR_8N1  = 0x03;
constexpr uint8_t LCR_DLAB = 0x80;   // bit 7: divisor latch access

constexpr uint8_t FCR_ENABLE   = 0x01;
constexpr uint8_t FCR_CLEAR_RX = 0x02;
constexpr uint8_t FCR_CLEAR_TX = 0x04;
constexpr uint8_t FCR_TRIG_14  = 0xC0;   // receive interrupt at 14 bytes

constexpr uint8_t MCR_DTR  = 0x01;
constexpr uint8_t MCR_RTS  = 0x02;
constexpr uint8_t MCR_OUT1 = 0x04;
constexpr uint8_t MCR_OUT2 = 0x08;   // gates the UART IRQ onto the PC's IRQ4
constexpr uint8_t MCR_LOOP = 0x10;   // internal loopback

constexpr uint8_t LSR_DATA_READY = 0x01;   // bit 0: a byte is waiting in RBR
constexpr uint8_t LSR_THR_EMPTY  = 0x20;   // bit 5: safe to write REG_DATA

// The UART clock is 1.8432 MHz and the generator divides by a further 16, so
// the fastest rate is 1843200/16 = 115200 baud, at divisor 1.
constexpr uint16_t BAUD_DIVISOR = 1;

constexpr uint8_t LOOPBACK_PATTERN = 0xAE;   // 10101110 — asymmetric on purpose

// Bounded spin. One byte takes ~87 us on the wire at 115200 8N1, so this is
// orders of magnitude larger. That it is FINITE is the property that matters:
// this loop runs inside panic().
constexpr uint32_t SPIN_LIMIT = 100000;

bool g_present = false;

// Poll LSR until every bit in `mask` is set. False on timeout, never a hang.
bool wait_for_lsr(uint8_t mask) {
    for (uint32_t i = 0; i < SPIN_LIMIT; ++i) {
        if ((inb(COM1_BASE + REG_LSR) & mask) != 0)
            return true;
    }
    return false;
}

// Transmit one byte: no newline translation, no presence check.
void putc_raw(char c) {
    if (!wait_for_lsr(LSR_THR_EMPTY))
        return;   // wedged UART: drop the byte, never hang
    outb(COM1_BASE + REG_DATA, static_cast<uint8_t>(c));
}

}  // namespace

void serial_init() {
    // 1. Mask every UART interrupt source. We poll, and there is no IDT until
    //    Phase 2 — an IRQ arriving now would find a null gate and triple fault.
    outb(COM1_BASE + REG_IER, 0x00);

    // 2. Set DLAB. Offsets 0 and 1 now address the divisor latch.
    outb(COM1_BASE + REG_LCR, LCR_DLAB);

    // 3-4. Divisor, low byte then high byte. 1 => 115200 baud.
    outb(COM1_BASE + REG_DLL, static_cast<uint8_t>(BAUD_DIVISOR & 0xFF));
    outb(COM1_BASE + REG_DLH, static_cast<uint8_t>(BAUD_DIVISOR >> 8));

    // 5. Clear DLAB and set 8N1 in one write. Offsets 0 and 1 are data and IER
    //    again from here on. Omitting this is trap 3 in Stage 0.6.
    outb(COM1_BASE + REG_LCR, LCR_8N1);

    // 6. Enable the FIFOs and discard whatever the firmware left in them.
    outb(COM1_BASE + REG_FCR,
         FCR_ENABLE | FCR_CLEAR_RX | FCR_CLEAR_TX | FCR_TRIG_14);

    // 7. Assert DTR/RTS so the far end sees a ready terminal, plus OUT2, which
    //    gates the UART's interrupt line. Unused now; required in Phase 3.
    outb(COM1_BASE + REG_MCR, MCR_DTR | MCR_RTS | MCR_OUT2);

    // 8. Self-test: loop the transmitter into the receiver and see whether a
    //    byte survives the round trip. An absent UART reads back 0xFF (the bus
    //    floats high); a wedged one never sets data-ready and times out.
    outb(COM1_BASE + REG_MCR, MCR_LOOP | MCR_OUT1 | MCR_OUT2 | MCR_RTS);
    outb(COM1_BASE + REG_DATA, LOOPBACK_PATTERN);

    g_present = wait_for_lsr(LSR_DATA_READY) &&
                inb(COM1_BASE + REG_DATA) == LOOPBACK_PATTERN;

    // 9. Leave loopback whatever the answer was.
    outb(COM1_BASE + REG_MCR, MCR_DTR | MCR_RTS | MCR_OUT1 | MCR_OUT2);
}

bool serial_present() {
    return g_present;
}

void serial_putc(char c) {
    if (!g_present)
        return;
    if (c == '\n')
        putc_raw('\r');   // terminals need both; see Stage 0.6 section 3
    putc_raw(c);
}

void serial_write(const char* buf, size_t len) {
    for (size_t i = 0; i < len; ++i)
        serial_putc(buf[i]);
}

void serial_puts(const char* s) {
    for (; *s != '\0'; ++s)
        serial_putc(*s);
}

void serial_write_dec(uint64_t v) {
    char buf[20];   // 2^64 - 1 is 20 digits
    size_t i = 0;
    do {
        buf[i++] = static_cast<char>('0' + (v % 10));
        v /= 10;
    } while (v != 0);
    while (i > 0)
        serial_putc(buf[--i]);
}

void serial_write_hex(uint64_t v) {
    constexpr char DIGITS[] = "0123456789ABCDEF";
    serial_puts("0x");
    char buf[16];   // 16 nibbles in a uint64_t
    size_t i = 0;
    do {
        buf[i++] = DIGITS[v & 0xF];
        v >>= 4;
    } while (v != 0);
    while (i > 0)
        serial_putc(buf[--i]);
}
```

#### Line by line

**Includes.** Own header first, then kernel headers, then freestanding headers
([[13 - Coding Standards]], Headers). Own-header-first means the header is compiled
standalone in at least one TU, so a missing include inside it is caught here rather than
at a distant call site. Note what `#include "arch/x86_64/io.hpp"` means: this driver is
*not* architecture-neutral. It contains no assembly, so `make lint` passes, but the
include path names an architecture. When a second architecture arrives, the fix is to add
`kernel/arch/<arch>/io.hpp` and let the build system resolve `arch/io.hpp` to the right
one — not to move this file. `kernel/` goes on the include path in
[[Stage 0.8 - The Build System|Stage 0.8]]; until then use whatever relative path
compiles.

**The anonymous namespace.** Everything inside has internal linkage: the constants,
`g_present`, `wait_for_lsr` and `putc_raw` are invisible outside this file and emit no
symbols. `static` on each would do the same; the namespace states the intent once.

**The register constants.** [[13 - Coding Standards]] rule 8 — no magic numbers in
hardware code, every constant carrying a comment naming the register and the conditions
under which it applies. When a bit turns out to be wrong the only way to check is against
the datasheet, and you will not remember which one; `clang-tidy`'s
`readability-magic-numbers` mechanises this. Note that `REG_DATA` and `REG_DLL` are both
`0`, and `REG_IER` and `REG_DLH` are both `1`. That is not redundancy — it is the DLAB
hazard made visible in the source. `outb(COM1_BASE + REG_DLL, 0x01)` tells you the
divisor latch is expected to be exposed at that point; `outb(COM1_BASE + 0, 0x01)` tells
you nothing.

**`SPIN_LIMIT` and `wait_for_lsr`.** The bounded loop is the difference between a kernel
that fails soft and one that hangs. `while ((inb(...) & mask) == 0);` is the version in
most tutorials, and on a machine where LSR reads `0x00` — a UART held in reset, one the
firmware disabled, an emulator configured without one — it never returns. The machine
appears to hang at boot with no output, and the reason it produces no output is that it
is stuck inside the code that produces output. The exact limit does not matter; what
matters is that this function is called from `panic()`, and a panic handler that can hang
is worse than none, because it converts a diagnosable fault into a silent freeze. `inb`
is called fresh each iteration and — because of the `volatile` on the asm — genuinely
re-reads the port. This loop is the concrete reason `volatile` is not optional in
`io.hpp`.

**`putc_raw`.** LSR bit 5 is **transmitter holding register empty**. While it is clear,
the THR still holds a byte that has not been handed to the shift register; writing anyway
overwrites and loses it — no error bit, no notification, just a gap in your log. Poll
first, always (trap 4). `static_cast<uint8_t>(c)` is explicit because `char` is signed on
x86-64 and `bugprone-signed-char-misuse` exists for exactly this. `putc_raw` deliberately
does not check `g_present`, so the self-test path and the `\r` injection do not pay a
redundant branch; the check lives one level up.

**`serial_init` steps 1–5 — the DLAB dance.** Step 1 masks the UART's four interrupt
sources: there is no IDT until [[Phase 2 - Overview|Phase 2]], so a delivered IRQ would
find a null gate and triple fault. The firmware may well have left them enabled — do not
assume any register holds a known value at entry.

Steps 2–5 are the part that costs people an evening. **Offsets 0 and 1 are two different
pairs of registers**, selected by bit 7 of LCR:

```
   DLAB = 0                       DLAB = 1
   offset 0 -> RBR / THR          offset 0 -> divisor low
   offset 1 -> IER                offset 1 -> divisor high
```

Set DLAB, write the two divisor bytes, clear DLAB. Step 5 does two jobs in one write —
`0x03` sets 8N1 *and* clears bit 7, because bit 7 of `0x03` is zero. That is why there
is no separate "clear DLAB" instruction. Omit step 5, or write `0x83` instead, and DLAB
stays set: every subsequent `outb(COM1_BASE + REG_DATA, c)` writes the divisor-latch low
byte instead of the transmit register. Nothing is transmitted, and as a bonus the baud
rate is reset to `115200 / c` for each character you attempt to print. Trap 3.

**Steps 6–7.** `0xC7`: enabling the FIFOs turns the 16550 into a 16-byte-buffered device
instead of a one-byte one, and clearing both discards anything the firmware or bootloader
left in them — Limine writes its own output to serial (`serial: yes` in
`boot/limine.conf`), so there genuinely may be bytes in flight. The trigger level only
affects the receive interrupt, which is masked; set it correctly now so it is right when
Phase 3 enables receive. `0x0B`: DTR and RTS are flow-control signals telling the far end
a terminal is present and ready — nothing on a QEMU pipe cares, but a real USB-to-TTL
adapter does. **OUT2** is a PC-specific quirk: the UART's interrupt output is wired
through an AND gate controlled by OUT2, so with OUT2 clear the UART can never raise IRQ4
no matter what IER says. It costs one bit now, and it is the standard cause of "my serial
interrupt handler is never called" in Phase 3.

**Step 8 — the self-test.**

```cpp
outb(COM1_BASE + REG_MCR, MCR_LOOP | MCR_OUT1 | MCR_OUT2 | MCR_RTS);
outb(COM1_BASE + REG_DATA, LOOPBACK_PATTERN);
g_present = wait_for_lsr(LSR_DATA_READY) &&
            inb(COM1_BASE + REG_DATA) == LOOPBACK_PATTERN;
```

`0x1E` sets LOOP, internally connecting the transmitter's output to the receiver's input,
so a byte written to THR shifts out and arrives in RBR without ever reaching a pin. Write
`0xAE`, wait for LSR bit 0, read offset 0, compare. `0xAE` is `10101110` — alternating
bits, so a stuck-at-zero bus, a stuck-at-one bus, and a byte shifted by one position all
produce a different value.

| Situation | LSR reads | RBR reads | Result |
|---|---|---|---|
| Working UART | data-ready sets | `0xAE` | `g_present = true` |
| No UART at all | `0xFF` (bus floats high) | `0xFF` | `false` — mismatch |
| Wedged UART | `0x00` forever | — | `false` — `wait_for_lsr` times out |

The middle row is worth pausing on: `0xFF` has bit 0 set, so `wait_for_lsr` returns
`true` immediately. Detection therefore relies on the *value* comparison, not on the
wait. The short-circuit `&&` means the read is skipped entirely when the wait times out,
so a wedged UART is never read. Step 9 restores `0x0F` regardless of the result —
leaving the chip in loopback would make it echo the kernel's own output back at itself
and transmit nothing.

**`serial_putc`.** The presence check goes here rather than in `putc_raw` so a machine
without a UART pays one predictable branch per character instead of `SPIN_LIMIT` port
reads per character — over a few thousand characters at boot, the difference between an
imperceptible pause and a visible one. Note the order: `\r` first, then `\n`. Reversed,
the cursor returns to column zero *after* moving down, which looks identical on most
terminals but is wrong on a printing terminal and on some serial consoles.

**`serial_write_dec` and `serial_write_hex`.** Division produces digits
least-significant first, so they are buffered and emitted in reverse. `20` is exact:
`2^64 - 1` is `18446744073709551615`; the hex buffer is `16` for the same reason. A
`do`/`while` rather than a `while`, so that `v == 0` prints `0` rather than nothing.
`constexpr char DIGITS[]` rather than `static const char DIGITS[]` because `constexpr`
guarantees constant initialisation, so there is no guard variable and no call to
`__cxa_guard_acquire`, which does not exist in a freestanding build and would be a link
error — the same hazard as [[13 - Coding Standards]] rule 9, one level down. 64-bit
division compiles to a single `div` on x86-64 and needs no libgcc helper; the same code
on i686 would emit a call to `__udivdi3` and fail to link, one more small consequence of
[[ADR-0002 - Target x86_64 Not i686|targeting x86_64]].

---

### Wiring it in: `kernel/main.cpp`

`serial_init()` is the very first statement of `kernel_init()` — step 1 of the
initialisation order in [[06 - Architecture Overview]].

```cpp
#include "kernel/boot_info.hpp"
#include "kernel/serial.hpp"

#include <stdint.h>

namespace {
constexpr const char* KERNEL_NAME    = "CRACKED-F OS";
constexpr const char* KERNEL_VERSION = "0.0.1-dev";
}  // namespace

void kernel_init(BootInfo* info) {
    // Step 1. Nothing may be placed above this line, because nothing above
    // this line could report that it failed.
    serial_init();

    serial_puts(KERNEL_NAME);
    serial_puts(" v");
    serial_puts(KERNEL_VERSION);
    serial_putc('\n');

    serial_puts("framebuffer: ");
    serial_write_dec(info->fb_width);
    serial_putc('x');
    serial_write_dec(info->fb_height);
    serial_putc('x');
    serial_write_dec(info->fb_bpp);
    serial_puts(" pitch=");
    serial_write_dec(info->fb_pitch);
    serial_puts(" @ ");
    serial_write_hex(info->fb_addr);
    serial_putc('\n');

    uint64_t usable = 0;
    for (size_t i = 0; i < info->region_count; ++i) {
        if (info->regions[i].type == MemoryRegionType::USABLE)
            usable += info->regions[i].length;
    }

    serial_puts("memory: ");
    serial_write_dec(info->region_count);
    serial_puts(" regions, ");
    serial_write_dec(usable / (1024 * 1024));
    serial_puts(" MiB usable\n");

    serial_puts("hhdm offset: ");
    serial_write_hex(info->hhdm_offset);
    serial_putc('\n');

    for (;;)
        __builtin_ia32_pause();
}
```

> **Check your own header.** `fb_width`, `fb_pitch`, `region_count`, `hhdm_offset`,
> `regions[].length` and `MemoryRegionType::USABLE` are the names *you* chose in
> [[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]]. Open
> `kernel/include/kernel/boot_info.hpp` and use what is actually there. The structure of
> the greeting is what matters, not the field spellings.

**Why these four lines and not "hello world".** Each proves something no other test can
prove at this point:

| Line | Proves |
|---|---|
| name + version | the port is programmed, the greeting path runs, `\n` translation works |
| framebuffer geometry | `BootInfo` was populated by Limine, and it matches `boot/limine.conf` |
| memory regions + total | the memory map was copied out and can be walked — the `-m 128M` test in §6 turns this into a real check |
| HHDM offset | Limine honoured the HHDM request; Phase 4 depends on this value |

"Hello world" proves only the first row. These four cost ten extra lines and retire four
risks that would otherwise surface in Phase 4. **Do not add a build timestamp** —
`__DATE__` and `__TIME__` are banned by `scripts/lint.sh` (reproducible builds: the same
source must produce a byte-identical kernel), and a version string injected by CMake in
[[Stage 0.8 - The Build System|Stage 0.8]] is the supported way to get a build identifier
into the greeting.

**Ordering footnote: `kmain` runs before `kernel_init`.**
[[Stage 0.3 - Freestanding C++ and kmain|Stage 0.3]] has `kmain` call
`collect_boot_info()` and then `kernel_init(info)`. But [[06 - Architecture Overview]]
makes the `BootInfo` copy step 2, depending on serial "to report failure" — and as
written, `collect_boot_info()` runs before serial exists, so a null Limine response still
halts silently. One line at the top of `kmain` fixes it:

```cpp
extern "C" void kmain(void) {
    serial_init();                       // so step 2 can report its own failure
    BootInfo* info = collect_boot_info();
    kernel_init(info);
    for (;;) __asm__ volatile("cli; hlt");
}
```

`serial_init()` is safe to call twice — it just reprogrammes the same registers — so
leaving the call in `kernel_init()` as well costs nothing. The only caveat is that the
second call briefly re-enters loopback, so do not print anything between the two.

---

### How the Makefile captures it (already done)

Serial that exists only in the terminal disappears when you scroll, and CI cannot read
it. So every run target tees the port to your terminal *and* to a file, via QEMU's
chardev layer:

```make
SERIAL_LOG ?= $(BUILD_DIR)/serial.log
SERIAL_TEE ?= -chardev stdio,id=ser0,logfile=$(SERIAL_LOG) -serial chardev:ser0
```

`run`, `run-serial` and `run-uefi` all use `$(SERIAL_TEE)`. `logfile=` is a generic
chardev option, so the same bytes reach both sinks; it truncates on each run, which is
what you want. `scripts/test.sh` uses `-serial file:...` for the headless tiers.

Nothing to change here — just know that **`build/serial.log` is where your output
lives after QEMU exits**, and that it is the first thing to attach to a bug report
([[14 - Debugging Playbook]]).

---

## 6. How to verify

### Now

```sh
make lint
```

Expected: `no inline asm outside kernel/arch/  ok`. A failure means an `__asm__` block
escaped into `serial.cpp` or `io.hpp` landed outside `kernel/arch/`.

```sh
make all
x86_64-elf-nm build/kernel.elf | grep serial
x86_64-elf-objdump -d build/kernel.elf | grep -m 5 'out    %al,(%dx)'
```

Expected: `serial_init`, `serial_putc`, `serial_write`, `serial_puts` and
`serial_present` as defined text symbols (`T`); `wait_for_lsr` and `putc_raw` absent,
because they are in the anonymous namespace. The `objdump` should show several `out`
instructions — that is `outb` inlined at its call sites. `call` instructions to an
`outb` symbol instead mean `static inline` did not take effect; check you did not build
at `-O0`.

### After booting

```sh
make run-serial
```

`run-serial` passes `-display none`, so there is no QEMU window at all — anything you
see arrived through the serial port and out of QEMU's stdout. Expected: Limine's own
banner first (`serial: yes` in `boot/limine.conf`), the three-second menu timeout, then:

```
CRACKED-F OS v0.0.1-dev
framebuffer: 1280x800x32 pitch=5120 @ 0xFD000000
memory: 12 regions, 511 MiB usable
hhdm offset: 0xFFFF800000000000
```

The framebuffer base and the region count differ between machines and QEMU versions.
**Do not hardcode either.**

- [ ] **The text appears in YOUR TERMINAL, not just in a QEMU window.** With
      `-display none` there is no window, so this is proved by construction. Running plain
      `qemu-system-x86_64` without `-serial stdio` and seeing nothing is trap 1, not a
      kernel bug.
- [ ] **`make run` writes `build/serial.log` as well as stdout.** `make run`, quit QEMU, `cat build/serial.log`, confirm the same four
      lines are in the file.
- [ ] **The framebuffer geometry matches `boot/limine.conf`.** The config asks for
      `resolution: 1280x800x32`, so the greeting must say `1280x800x32`, and at 32 bpp a
      1280-pixel row is `1280 * 4 = 5120` bytes, so `pitch=5120` is consistent. If Limine
      could not set the mode it falls back to something else — fine, but the number in the
      greeting must match what the kernel will actually draw into in Phase 1, which is
      why it is printed.
- [ ] **The killer test — the memory figure must change.** `make run-serial
      QEMU_MEM=128M`. Expected: the `memory:` line reports roughly **127 MiB usable**
      instead of 511, and probably a different region count. If it still says 511 MiB you
      are not reading the memory map — you are printing a constant, summing the wrong
      field, or reading a `BootInfo` that was never populated. This is the one check in
      this stage that cannot be passed by accident, and it is why the greeting prints
      memory at all.
- [ ] **No UART, no hang.** `qemu-system-x86_64 -cdrom build/os.iso -m 512M -display
      none -serial none -no-reboot -no-shutdown`. The machine must reach the idle loop
      rather than freezing. You will see nothing (there is no backend), so confirm with
      the QEMU monitor or GDB that `RIP` is in the idle loop and not in `wait_for_lsr`.

### Later

`\n` handling under a real terminal is only fully exercised once output scrolls
(Phase 1). Interrupt-driven receive — typing into the kernel over serial — needs the IDT
and IRQ4, from [[Phase 2 - Overview|Phase 2]] and Phase 3; OUT2 is already set for it.
Real hardware is Phase 15, over a USB-to-TTL adapter at 115200 8N1, which is when the
baud divisor stops being decorative.

---

## 7. Common traps

**No output at all, but the kernel is clearly running.** You forgot `-serial stdio`, or
ran QEMU by hand instead of `make run-serial`. The UART is emulated and programmed
correctly; QEMU is routing the bytes to a virtual console tab or discarding them.
*Diagnostic:* `boot/limine.conf` sets `serial: yes`, so **Limine prints its own menu
over the same port**. See Limine's output but not your greeting and the port and flags
are both fine — the bug is yours. See nothing at all, not even Limine, and the problem
is the QEMU invocation.

**Output marches diagonally down the screen.**

```
CRACKED-F OS v0.0.1-dev
                       framebuffer: 1280x800x32 ...
                                                    memory: 12 regions ...
```

You are emitting `\n` without `\r`. Line feed moves down; carriage return moves to
column zero; terminals need both. *Fix:* `if (c == '\n') putc_raw('\r');` in
`serial_putc` — in the driver, not at the call sites.

**The first few characters appear, then garbage or nothing.** DLAB (bit 7 of LCR) is
still set, so writes to offset 0 land in the divisor-latch low byte instead of the
transmit register. Nothing is transmitted, *and* the baud rate is silently reprogrammed
to `115200 / <the byte you wrote>` for every character, so anything that does emerge
afterwards is unreadable. *Fix:* step 5 — `outb(base + 3, 0x03)`, which sets 8N1 and
clears DLAB in the same instruction. A closely related version is writing `0x83` there,
which sets 8N1 *and leaves DLAB on*.

**Characters dropped under load — the log has holes in the interesting places.** You are
not polling LSR bit 5 before writing. The transmit holding register holds one byte;
write a second before the first has moved to the shift register and the first is gone,
with no error bit and nothing to notice. The bytes you lose are the ones you wrote
fastest — a panic dump, a tight loop, an interrupt storm — which is exactly the output
you needed. *Fix:* `wait_for_lsr(LSR_THR_EMPTY)` before every `outb` to offset 0.

**It works, then breaks after an unrelated refactor.** A missing `"memory"` clobber on an
`asm` block, or a missing `volatile` on an `inX`. Both are undefined behaviour the
optimiser is entitled to exploit and usually does not — until an inlining decision
changes elsewhere in the tree and it becomes profitable. The symptom is a driver that
has worked for months breaking on a commit that does not touch it, and a `git bisect`
that lands on something irrelevant. *Fix:* every `asm` that touches hardware gets
`"memory"` ([[13 - Coding Standards]] rule 2); every `asm` with an output operand that
reads a device gets `volatile`. There is no case in this kernel where omitting either is
correct.

**The kernel hangs at boot on a machine with no serial port.** The self-test result was
ignored, or the transmit poll is an unbounded `while`. With no UART at all, LSR reads
`0xFF` so the poll actually succeeds harmlessly into the void; the hang comes from a
UART that is *present but wedged*, where LSR reads `0x00` forever. Either way the
machine stops inside the code whose job is to tell you why it stopped. *Fix:* the
bounded `SPIN_LIMIT` loop, plus `g_present` recorded at init and checked in
`serial_putc`. A kernel that refuses to boot without a debug channel is not shippable.

**`make lint` fails with "no inline asm outside kernel/arch/".** You put `__asm__` in
`serial.cpp`, or created `io.hpp` outside `kernel/arch/`. The assembly belongs in
`kernel/arch/x86_64/io.hpp`; `serial.cpp` only calls it.

**`serial_write_dec` prints nothing for zero.** You wrote a `while` loop instead of a
`do`/`while`; `v == 0` fails the condition immediately and no digits are buffered.

---

## 8. What this unlocks

Everything diagnosable from here on. [[Stage 0.7 - Panic and KASSERT|Stage 0.7]]'s panic
handler writes its register dump through `serial_putc` unconditionally, before it
attempts any drawing — safe only because the path is polled and bounded.
[[Phase 1 - Overview|Phase 1]]'s framebuffer console and log ring both use serial as
their second sink, so a message that never reaches the screen still reaches the log
file. [[Phase 2 - Overview|Phase 2]]'s exception handlers are useful only because they
can report; a page fault before this stage was a silent reboot.
[[09 - Testing Strategy]]'s Tier-2 and Tier-3 tests are `scripts/test.sh` reading
`build/serial.log` and matching expected output — **serial is the harness's only
observation channel** — and [[10 - CI Pipeline]] runs the same script on every push.

Done wrong, the failures are quiet. A missing `"memory"` clobber breaks an unrelated
driver months from now. An unbounded poll turns a machine without a UART into a boot
hang with no output. A missing presence check makes every future `printk` on such a
machine burn a hundred thousand port reads per character. None of these announce
themselves in this stage, which is exactly why they are worth the sixty minutes here.

---

## 9. Reading

- OSDev — **Serial Ports**: <https://wiki.osdev.org/Serial_Ports>
  The full register table with every bit, plus the standard init sequence this stage
  follows. The one page to keep open while writing `serial.cpp`.
- OSDev — **I/O Ports**: <https://wiki.osdev.org/I/O_Ports>
  Why the I/O space is separate from memory, and which legacy device sits at which port.
  Read it once and `0x3F8` stops being a magic number.
- OSDev — **Inline Assembly**: <https://wiki.osdev.org/Inline_Assembly>
  Kernel-flavoured introduction to constraints and clobbers.
- GCC — **Extended Asm**: <https://gcc.gnu.org/onlinedocs/gcc/Extended-Asm.html>
  The authoritative rules for `volatile`, the clobber list, and what the compiler may and
  may not do around an `asm` statement. The `"memory"` section is the one that matters.
- GCC — **Machine Constraints**:
  <https://gcc.gnu.org/onlinedocs/gcc/Machine-Constraints.html>
  Where `a`, `d` and `N` are defined. Search for "i386 family".
- TI — **PC16550D datasheet**: <https://www.ti.com/lit/ds/symlink/pc16550d.pdf>
  The actual chip. Ten minutes for the register summary and the FIFO description settles
  arguments the wiki leaves open.
- QEMU — **Invocation** (`-serial`, `-chardev`):
  <https://www.qemu.org/docs/master/system/invocation.html>
  What `stdio`, `file:`, `logfile=` and `mon:stdio` actually do to your bytes.
- [[ADR-0004 - Framebuffer Console Not VGA Text]] — why there is no VGA text mode to
  fall back on, and why serial is therefore the *only* early channel.
- [[06 - Architecture Overview]] — the initialisation order this stage sits at the root
  of.
- [[13 - Coding Standards]] — rule 2 (clobbers), rule 3 (`volatile` is for MMIO, not
  concurrency), rule 8 (no magic numbers in hardware code).
- [[14 - Debugging Playbook]] — "is serial alive?" is the first question in every symptom
  section. Not a coincidence; it is the payoff for this stage.

Next: **[[Stage 0.7 - Panic and KASSERT]]**

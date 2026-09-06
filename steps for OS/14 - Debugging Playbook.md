# Debugging Playbook

When the machine gives you a blank screen instead of an error message.

v1 had good debugging *habits*. This adds the **infrastructure** that turns a blank
screen into a stack trace, and a symptom lookup table for the failures that actually
happen.

---

## The infrastructure (build this early, not when you need it)

You need all five before Phase 4. Building them under pressure, while debugging the
bug that made you want them, is miserable.

| Tool | Stage | What it gives you |
|---|---|---|
| Serial output | 0.4 | Survives a crash; captured to a file |
| Panic + `KASSERT` | 0.5 | Register dump, message, halt — not a silent reboot |
| Log ring buffer | 1.5 | The last N messages, even after the screen scrolled |
| Symbolised backtrace | 1.6 | Function names and line numbers, not raw addresses |
| GDB + `.gdbinit` | 0.6 | Single-step, breakpoints, page-table walks |

### Panic output — the target

```
================= KERNEL PANIC =================
Page fault: not-present write, ring 0
CR2 = 0xFFFF8000DEADBEEF   (unmapped)
RIP = 0xFFFFFFFF80104A2C   heap_expand+0x8C  (kernel/mm/heap.cpp:214)

RAX=0000000000000000  RBX=FFFFFFFF80210000  RCX=0000000000001000
RDX=0000000000000008  RSI=0000000000000000  RDI=FFFF8000DEADBEEF
RSP=FFFFFFFF801FFE40  RBP=FFFFFFFF801FFE80  RFLAGS=00010246

Backtrace:
  #0  heap_expand+0x8C          kernel/mm/heap.cpp:214
  #1  kmalloc+0x142             kernel/mm/heap.cpp:98
  #2  task_create+0x33          kernel/sched/task.cpp:61
  #3  kernel_init+0x2A1         kernel/main.cpp:143

Last 8 log lines:
  [  0.412] mm: heap initialised at 0xFFFFFFFF00000000
  [  0.418] sched: creating idle task
================================================
```

Everything here is mechanically derivable. The backtrace walks saved `RBP` values
(build with `-fno-omit-frame-pointer` in debug builds); symbolisation uses the
symbol table generated at build time and embedded in the kernel by `tools/symbolise`.

**A panic must never reboot.** Halt with interrupts off (`cli; hlt`) so the message
stays on screen. QEMU must always run with `-no-reboot -no-shutdown` for the same
reason: a triple fault that reboots destroys the evidence.

---

## Symptom → cause lookup

The table you actually want at 1am.

### QEMU reboots in a loop

**Triple fault.** The CPU faulted, faulting the fault handler, faulting again.

```sh
qemu-system-x86_64 -d int,cpu_reset -no-reboot -no-shutdown ... 2> trace.log
```

`-d int` logs every exception. The *first* one is your bug; everything after is
cascade. Read from the top.

Usual causes, in order of likelihood: no stack set up; bad GDT/IDT descriptor;
unmapped the code that is currently executing (see Phase 4); `ltr` with a bad TSS
selector.

### Blank screen, no output at all

1. **Is serial alive?** `make run-serial`. If serial works and the screen does not,
   the bug is in the framebuffer console, not the kernel.
2. If serial is also dead, you did not reach `kmain`. Suspect the linker script, the
   Limine request section being stripped, or `limine.conf` pointing at the wrong path.
3. `-d in_asm` to see whether any instruction executed at all.

### Boots in QEMU, dead on real hardware

The single most common category once you leave the emulator.

| Cause | Check |
|---|---|
| Assuming VGA text mode | [[ADR-0004 - Framebuffer Console Not VGA Text]] — must be framebuffer |
| Assuming a memory layout QEMU happens to have | Actually read the memory map; do not hardcode |
| Assuming a device exists | Enumerate PCI; do not assume |
| Timing loops calibrated against QEMU | Calibrate against HPET/TSC at runtime |
| Secure Boot enabled | Disable it — our bootloader is unsigned |
| Not reserving firmware-reserved memory | Honour every non-usable memory-map entry |

Serial over USB-to-TTL on a real machine is worth the £10 cable. Without it you are
debugging by screenshot.

### Works with 1 core, breaks with `-smp 4`

A race that was always there and only now has the opportunity to fire.

- A spinlock not taken, or taken without IRQ-save
- `volatile` used where `std::atomic` was needed
  ([[13 - Coding Standards]] rule 3)
- Per-CPU data accessed without disabling preemption
- A lock taken out of the documented order in `kernel/sched/locks.md`

Reproduce with `-smp 4 -accel tcg,thread=multi`, which interleaves more aggressively
than the single-threaded emulator.

### Random corruption with no pattern

Suspect `-mno-red-zone` first. Check every translation unit:

```sh
jq -r '.[].command' build/compile_commands.json | grep -c -- '-mno-red-zone'
```

If that count is lower than the file count, you have found it. This is common enough
that CI checks for it ([[10 - CI Pipeline]]).

Then: stack overflow (add a guard page below each kernel stack — an overflow becomes
a clean page fault instead of silent corruption), and use-after-free (poison freed
heap memory with `0xDEADBEEF` in debug builds so stale reads are obvious).

### A syscall returns garbage

`r10`, not `rcx`, holds the fourth argument — the `syscall` instruction clobbers
`rcx` with the return address. This catches everyone exactly once
([[06 - Architecture Overview]]).

---

## GDB against QEMU

```sh
make debug      # QEMU with -s -S, frozen, listening on :1234
make gdb        # GDB with symbols and .gdbinit
```

`.gdbinit` (generated by `tools/gdbinit-gen`) provides:

```
target remote :1234
symbol-file build/kernel.elf
set disassembly-flavor intel

define pt                 # walk the page tables for an address
define regs               # registers formatted readably
define tasks              # dump the task list
define heapinfo           # heap block chain
define lastlog            # dump the kernel log ring buffer
```

Most useful commands:

```
b kmain                   break at kernel entry
b *0xFFFFFFFF80104A2C     break at a raw address from a panic
info registers
p/x $cr2                  faulting address
p/x $cr3                  page directory base
x/16i $rip                disassemble at the fault
bt                        backtrace (needs -fno-omit-frame-pointer)
monitor info mem          QEMU's own view of the page tables
monitor info registers    QEMU's view, including hidden segment state
```

`monitor info mem` is the fastest way to answer "is this address actually mapped?"
without walking tables by hand.

---

## QEMU flags worth knowing

| Flag | Use |
|---|---|
| `-d int,cpu_reset` | Log every exception — the triple-fault workhorse |
| `-d guest_errors` | Bad MMIO, invalid device access |
| `-d in_asm` | Every instruction (enormous; last resort) |
| `-no-reboot -no-shutdown` | **Always.** Preserve the evidence |
| `-serial file:serial.log` | Capture output |
| `-monitor stdio` | QEMU monitor: `info mem`, `info registers`, `screendump` |
| `-s -S` | Wait for GDB on :1234 |
| `-smp 4 -accel tcg,thread=multi` | Shake out races |
| `-m 128M` | Prove you handle small memory |

---

## Bochs, for the bugs GDB cannot see

Bochs is far slower than QEMU but has a debugger that **understands x86 descriptor
tables natively**. For GDT/IDT/TSS/paging bugs it will show you the decoded structure
where GDB shows you bytes.

```
bochs> info gdt
bochs> info idt
bochs> info tab       # page tables, decoded
bochs> creg           # control registers
```

Keep a `bochsrc` in the repo. You will use it perhaps five times in the project, and
each time it will save a day.

---

## Habits (kept from v1, still correct)

- **Change one thing at a time.** Two changes plus a blank screen is zero
  information.
- **Commit after every green stage.** `git bisect` is the highest-leverage tool in a
  project where bugs surface far from their cause.
- **Log over serial, not just the screen.** The screen freezes; the log file is
  already written.
- **Read the first error, not the last.** Cascading faults hide their cause.
- **Write down what you ruled out.** After an hour, the list is worth more than the
  memory of it — and it is what makes asking your teammate productive
  ([[12 - Team Workflow]]).

---

## Related

[[09 - Testing Strategy]] · [[13 - Coding Standards]] · [[10 - CI Pipeline]]

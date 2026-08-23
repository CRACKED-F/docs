# Phase 2 — CPU Tables & Interrupts

**Goal:** take control of the CPU's own tables. You will build a **64-bit GDT**, a
**TSS** with **interrupt stacks**, and a **256-entry IDT**; handle every CPU
exception with a useful report; and route hardware interrupts so a device can get
your attention.

> Prerequisite: [[Phase 1 - Overview|Phase 1]] (you need `kprintf` and the panic
> handler to see what the CPU is telling you).

---

## Why this phase exists

Limine leaves you in long mode with its own temporary GDT and no IDT at all. That
means **any fault triple-faults the machine** — the CPU tries to find a handler,
finds nothing, faults on that, and resets. Every mistake from here to Phase 15 shows
up as a silent reboot until you fix this.

Building the IDT converts the entire remainder of the project from "it rebooted" into
"page fault, write to `0xDEADBEEF`, from `heap_expand+0x8C`." That is the difference
between debugging and guessing, and it is why this phase comes before memory
management rather than after.

---

## What is different in 64-bit

If you have read 32-bit material, these are the changes that matter. Each one is a
place where following a 32-bit tutorial produces a triple fault.

| | 32-bit (classic tutorials) | x86_64 (here) |
|---|---|---|
| Segmentation | Real — base and limit are enforced | **Flat.** Base and limit ignored; segments carry only privilege and type |
| GDT entries | 8 bytes each | 8 bytes, but the **TSS descriptor is 16** |
| IDT entries | 8 bytes | **16 bytes** |
| TSS contents | `ss0`/`esp0` for the ring-0 stack | `rsp0` plus the **IST** — seven known-good stacks |
| Interrupt frame | 5 dwords | 5 **qwords**, and `rsp`/`ss` are **always** pushed, not only on a ring change |
| Handler arguments | pushed on the stack | in `rdi`, `rsi`, ... (SysV AMD64) |

**The IST is the most valuable 64-bit addition.** It lets you say "when a double
fault happens, switch to *this* known-good stack unconditionally." Without it, a
stack overflow causes a page fault, whose handler needs the stack that just
overflowed, which causes a double fault, which needs the same stack — and the machine
triple-faults with no diagnostic at all. With an IST entry for the double-fault
vector, you get a readable panic. **Set this up in Stage 2.2, not later.**

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 2.1 | [[Stage 2.1 - The Global Descriptor Table]] | Medium | Our own 64-bit GDT, with ring-3 descriptors ready |
| 2.2 | Stage 2.2 - The TSS and Interrupt Stacks | Medium | `rsp0` and IST entries — a survivable double fault |
| 2.3 | Stage 2.3 - The Interrupt Descriptor Table | Hard | 256 gates, correct types and privilege |
| 2.4 | Stage 2.4 - Interrupt Stubs and the Saved Frame | Hard | One consistent `registers_t` for every vector |
| 2.5 | [[Stage 2.3 - CPU Exception Handlers\|Stage 2.5 - CPU Exception Handlers]] | Hard | Every fault reported with cause, address, and backtrace |
| 2.6 | Stage 2.6 - The 8259 PIC: Remap and Mask | Medium | Legacy IRQs working, ready to be replaced |
| 2.7 | [[Stage 2.5 - Hardware Interrupts (IRQs)\|Stage 2.7 - Hardware Interrupts]] | Medium | A device interrupt reaching your handler |

> **On the PIC.** Stage 2.6 sets up the legacy 8259 because it is simple and gets
> interrupts working today. It is **replaced by the APIC** in
> [[Phase 11 - Overview|Phase 11]] — the PIC cannot route to more than one core, so
> it is a hard blocker for [[Phase 12 - Overview|SMP]]. Write the IRQ layer behind an
> interface so swapping the controller later is one file, not a rewrite.

---

## Deliverable

The kernel installs its own GDT, TSS, and IDT. A deliberate divide-by-zero, an
invalid opcode, a page fault, and a stack overflow each produce a clean, informative
panic naming the exception, the faulting address, the error-code bits decoded into
words, and a symbolised backtrace. Hardware interrupts arrive and are acknowledged.

The machine no longer reboots when you make a mistake. That is the whole point.

---

## The hard parts, named in advance

**Error codes.** Some exceptions push one, some do not. Your stubs must normalise
this — push a dummy zero for the vectors that do not — or the saved frame layout
differs per vector and every field you read is offset by eight bytes.

**A consistent saved frame.** Every stub must build the *same* `registers_t` layout,
because the scheduler in [[Phase 5 - Overview|Phase 5]] will save and restore through
it. Design it once, here, with Phase 5 in mind. Getting this wrong is discovered
three phases later.

**Generate the 256 stubs.** Write them with a NASM macro, not by hand. Hand-writing
256 near-identical stubs guarantees exactly one typo, in the vector you have not
triggered yet.

**Decode the page-fault error code.** Bits for present/write/user/reserved/instruction
fetch. Printing "error code 7" is nearly useless; printing "user-mode write to a
present page (protection violation)" tells you what happened.

---

## Testing

| Tier | What |
|---|---|
| 1 | GDT and IDT descriptor encoding — build a descriptor, decode it back, compare against known-good bytes from the Intel manual |
| 2 | Each exception vector fires its handler with the right vector number and error code; a stack overflow lands on the IST stack and produces a readable panic |
| 3 | Boot and assert the panic output format is stable — the debugging playbook depends on it |

Descriptor encoding is an excellent Tier-1 target: it is pure bit manipulation with a
published correct answer, and it is very easy to get subtly wrong.

---

## Read before you start

- OSDev — *Global Descriptor Table* (the x86-64 section):
  <https://wiki.osdev.org/Global_Descriptor_Table>
- OSDev — *Interrupt Descriptor Table* (x86-64 layout):
  <https://wiki.osdev.org/Interrupt_Descriptor_Table>
- OSDev — *Task State Segment* (the 64-bit TSS and the IST):
  <https://wiki.osdev.org/Task_State_Segment>
- OSDev — *Exceptions* — the vector list and which push an error code:
  <https://wiki.osdev.org/Exceptions>
- OSDev — *8259 PIC*: <https://wiki.osdev.org/8259_PIC>
- Intel SDM Vol. 3, Ch. 6 "Interrupt and Exception Handling" — the ground truth
- [[14 - Debugging Playbook]] — especially the triple-fault section

Previous: [[Phase 1 - Overview]] · Next: [[Phase 3 - Overview]]

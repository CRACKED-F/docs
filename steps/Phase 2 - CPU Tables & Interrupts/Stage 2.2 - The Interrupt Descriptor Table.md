# Stage 2.2 — The Interrupt Descriptor Table

**Difficulty:** Medium · ~40 minutes
**Phase:** [[Phase 2 - Overview|Phase 2 — CPU Tables & Interrupts]]

---

## Concept

When an interrupt fires — a fault, a key press, a software `int` — the CPU looks up
its number in the **Interrupt Descriptor Table (IDT)** to find which function to run.
The IDT has 256 entries, one per interrupt vector (0–255). Each entry points at a
handler and says at which privilege it may run.

This stage builds and loads the empty framework: the table, the entries, and the
`lidt` load. The actual handlers come in Stage 2.3.

---

## Specification

- The IDT has 256 entries, each 8 bytes. You load it with `lidt` and an `idt_ptr`
  (limit + base), the same shape as the GDT pointer.
- Each entry (a **gate**) stores: the handler address split into low and high 16-bit
  halves, the code **segment selector** (`0x08`, your kernel code segment), and a
  **type/attribute byte**.
- Use **interrupt gates** (type `0x8E` for ring 0). An interrupt gate clears the
  interrupt flag on entry, so a handler is not itself interrupted mid-way.
- The handler address in an entry points at an assembly **stub** (Stage 2.3), not
  directly at a C++ function, because the CPU's interrupt calling convention differs
  from C++'s.

---

## Your task

1. Define a packed `idt_entry` struct (8 bytes) and an `idt_ptr` struct.
2. Allocate an array of 256 `idt_entry` values, zeroed.
3. Write `idt_set_gate(n, handler_addr, selector, flags)` that splits the address
   into the low/high fields and fills the entry.
4. Write `idt_load()` that runs `lidt` with a pointer to your table.
5. Call IDT setup after the GDT in `kernel_main`. Leave gates empty for now; Stage
   2.3 fills them.

---

## How to verify

- The kernel survives `idt_load()` and keeps running. (An IDT with a bad limit or
  base faults on the next interrupt, so pairing this with Stage 2.3 gives the real
  test.)
- After Stage 2.3, triggering `int $3` (breakpoint) reaches your handler — proof the
  gate you set points where you think.

---

## Common traps

- Splitting the handler address incorrectly into the low and high 16-bit fields.
- Using the wrong selector. It must be your **kernel code** selector (`0x08`), not
  the data selector.
- Wrong type byte. `0x8E` is a 32-bit ring-0 interrupt gate; other values silently
  misbehave.
- Forgetting the table must persist. Do not build it on a stack that unwinds; make it
  a global/static.

---

## Reading

- OSDev — *Interrupt Descriptor Table*:
  <https://wiki.osdev.org/Interrupt_Descriptor_Table>
- OSDev — *IDT* gate-type table (the attribute byte):
  <https://wiki.osdev.org/Interrupt_Descriptor_Table#Gate_Descriptor_2>

Next: **[[Stage 2.3 - CPU Exception Handlers]]**.

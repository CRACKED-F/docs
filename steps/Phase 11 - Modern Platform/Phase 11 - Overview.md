# Phase 11 — Modern Platform

**Goal:** stop pretending it is 1995. You will parse **ACPI** tables, replace the
legacy 8259 **PIC** with the **APIC**, enumerate the **PCI** bus, get a real
**wall clock** from the RTC, calibrate a high-resolution timer (**HPET/TSC**), and —
finally — make the machine **power itself off**.

> Prerequisite: [[Phase 4 - Overview|Phase 4]] (you must map firmware tables before
> reading them). Everything in [[Phase 12 - Overview|Phase 12]] depends on this phase.

---

## Why this phase exists

The v1 vault used the **8259 PIC**, the **PIT**, and no device discovery at all.
Every one of those is legacy hardware kept alive only for backward compatibility:

- The **PIC** cannot route interrupts to more than one core. It is a hard blocker for
  SMP.
- The **PIT** is coarse (~838 ns resolution) and is not present on some modern
  systems at all.
- **No PCI enumeration** means you cannot find any device that is not at a hardcoded
  legacy port. Your disk controller from [[Phase 9 - Overview|Phase 9]] is on the PCI
  bus.
- **No ACPI** means the OS literally **cannot turn the machine off.** On real
  hardware you hold the power button — see [[05 - Gap Analysis (v1 to Product)]], gap
  B5. It also means no way to discover how many cores exist, since that information
  lives in the ACPI MADT.

This phase is the bridge between "runs in an emulator" and "runs on a computer."

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 11.1 | Stage 11.1 - Finding and Validating ACPI Tables | Medium | RSDP → RSDT/XSDT → any table by signature |
| 11.2 | Stage 11.2 - The MADT and Interrupt Topology | Medium | The list of CPUs, LAPICs, and IOAPICs |
| 11.3 | Stage 11.3 - PCI Enumeration | Medium | Every device, with its BARs and IRQ routing |
| 11.4 | Stage 11.4 - The Local APIC | Hard | Per-CPU interrupt controller, LAPIC timer |
| 11.5 | Stage 11.5 - The I/O APIC | Hard | Device IRQs routed through the APIC, PIC disabled |
| 11.6 | Stage 11.6 - HPET and TSC Calibration | Hard | Nanosecond timing, a monotonic clock |
| 11.7 | Stage 11.7 - The RTC and Wall Clock Time | Easy | Real dates on files |
| 11.8 | Stage 11.8 - ACPI Shutdown and Reboot | Medium | `poweroff` and `reboot` actually work |

---

## Deliverable

The OS boots, prints its ACPI table inventory, lists every PCI device with vendor and
class decoded, routes the keyboard and timer interrupts through the IOAPIC with the
8259 fully masked, keeps a monotonic nanosecond clock, shows the correct wall-clock
date, and **powers the machine off cleanly** when you type `poweroff`.

Under QEMU, `poweroff` makes QEMU exit with status 0. On real hardware, the machine
turns off.

---

## The hard parts, named in advance

**ACPI tables are firmware-provided and firmware is buggy.** Validate every checksum.
Handle a missing table gracefully — the HPET table is genuinely absent on some
systems and you must fall back to the PIT. Never assume a table exists because it did
on your machine.

**RSDT versus XSDT.** ACPI 1.0 uses 32-bit pointers (RSDT); ACPI 2.0+ uses 64-bit
(XSDT). Read the revision field and pick correctly. Using the wrong one gives you
pointers that are subtly wrong rather than obviously wrong.

**Interrupt source overrides.** The MADT tells you that, for example, IRQ 0 is
actually delivered on IOAPIC input 2. Ignoring the override table means your timer
interrupt never arrives, and the symptom is a hang with no error.

**The PIC must be fully masked, not merely ignored.** If you enable the APIC without
masking the 8259, you get spurious interrupts from both controllers and a very
confusing debugging session.

**TSC calibration.** The TSC counts cycles, not time. You must calibrate it against a
known-rate timer (HPET, or the PIT if there is no HPET) at boot. Also check the
`invariant TSC` CPUID bit — on older CPUs the TSC changes rate with power states and
is unusable as a clock.

**Shutdown is simple once you have the tables.** The FADT gives you `PM1a_CNT_BLK`
and the `SLP_TYPa` value from the `\_S5` object in the DSDT; writing
`SLP_TYPa | SLP_EN` powers the machine off. Parsing enough AML to find `\_S5` is the
only awkward part, and it can be done with a targeted byte-pattern search rather than
a full AML interpreter.

---

## A note on ACPICA

Intel's reference ACPI implementation, ACPICA, is the production answer and it is
what Linux uses. It is also ~200 000 lines and porting it is a project in itself.

**v1 decision: hand-rolled table parsing, no AML interpreter.** We parse the static
tables (RSDP, XSDT, MADT, FADT, HPET, MCFG) directly, and find `\_S5` with a pattern
search. This covers everything we need. A full AML interpreter is post-1.0, and
required only if we want thermal management, battery status, or lid events.

---

## Testing

| Tier | What |
|---|---|
| 1 | Table checksum validation, RSDP signature search, MADT entry iteration, PCI BAR size decoding, CMOS BCD conversion |
| 2 | ACPI tables found and valid; PCI enumeration finds the QEMU devices we expect; IOAPIC-routed timer IRQ actually fires; TSC calibration lands within 1% of HPET |
| 3 | `poweroff` makes QEMU exit 0; `reboot` restarts and reaches the shell again; wall clock matches the host within a second |

---

## Read before you start

- OSDev — *ACPI*, *RSDP*, *MADT*, *FADT*: <https://wiki.osdev.org/ACPI>
- OSDev — *APIC* and *IOAPIC*: <https://wiki.osdev.org/APIC> · <https://wiki.osdev.org/IOAPIC>
- OSDev — *PCI* and *PCI Express*: <https://wiki.osdev.org/PCI>
- OSDev — *HPET*, *TSC*, *CMOS*: <https://wiki.osdev.org/HPET> · <https://wiki.osdev.org/TSC>
- OSDev — *Shutdown* and *Reboot*: <https://wiki.osdev.org/Shutdown>
- ACPI Specification 6.5 (UEFI Forum) — the ground truth for every table layout
- Intel SDM Vol. 3, "Advanced Programmable Interrupt Controller"

Previous: [[Phase 10 - Overview]] · Next: [[Phase 12 - Overview]]

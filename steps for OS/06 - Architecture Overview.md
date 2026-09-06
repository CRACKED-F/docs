# Architecture Overview

What the system is, how the pieces fit, and what runs where. Read this before any
phase — it is the map every stage note assumes you have seen.

---

## One-line description

A monolithic, preemptive, SMP-capable x86_64 operating system that boots via UEFI or
BIOS, runs isolated user processes with a Unix-like syscall interface, persists data
to real disks, and talks TCP/IP.

---

## The boot chain

```
Power on
   │
   ├── UEFI firmware ──► ESP:/EFI/BOOT/BOOTX64.EFI  (Limine)
   └── Legacy BIOS  ──► MBR/El Torito stage         (Limine)
                              │
                              ▼
                    Limine reads limine.conf
                              │
                  loads kernel.elf + initrd.tar
                  sets a graphics mode
                  builds page tables, enters long mode
                  starts application processors, parks them
                              │
                              ▼
              kmain(void)  ── already 64-bit, paging on
                              │
              copy Limine responses into boot_info_t   ◄── the ONE place
                              │                             Limine is known
                              ▼
                      kernel_init() ...
```

**Why the kernel never sees Limine directly** — `kernel/arch/x86_64/boot/` translates
every Limine response into our own `boot_info_t` and nothing outside that directory
includes `limine.h`. CI enforces it. See
[[ADR-0003 - Limine as the Bootloader]].

**The trap:** Limine's response structures live in *bootloader-reclaimable* memory.
Everything needed must be **copied out** before Phase 4 reclaims that memory. Failing
to do this produces a fault long after the mistake.

---

## Kernel initialisation order

Order is not arbitrary. Each step depends on the ones above it, and getting it wrong
produces faults that look like bugs in unrelated subsystems.

| # | Step | Depends on | Phase |
|---|---|---|---|
| 1 | Serial (COM1) | nothing | 0 |
| 2 | `boot_info_t` copied out of Limine responses | serial (to report failure) | 0 |
| 3 | GDT + TSS | — | 2 |
| 4 | IDT + exception handlers | GDT | 2 |
| 5 | Panic / `KASSERT` | serial, IDT | 0/2 |
| 6 | Framebuffer console | `boot_info_t` | 1 |
| 7 | Log ring buffer | console, serial | 1 |
| 8 | Physical memory manager | `boot_info_t` memory map | 4 |
| 9 | Virtual memory — our own page tables | PMM | 4 |
| 10 | Kernel heap | VMM | 4 |
| 11 | Global constructors (`.init_array`) | heap | 4 |
| 12 | ACPI table parsing | VMM (to map tables) | 11 |
| 13 | LAPIC + IOAPIC | ACPI (MADT) | 11 |
| 14 | HPET / TSC calibration | ACPI, LAPIC | 11 |
| 15 | Scheduler + idle task | heap, timer | 5 |
| 16 | SMP — start APs | LAPIC, scheduler, per-CPU | 12 |
| 17 | PCI enumeration | VMM (MMCONFIG) | 11 |
| 18 | Device drivers | PCI, heap, IRQs | 3/9/14 |
| 19 | VFS + tmpfs, unpack initrd | heap | 7 |
| 20 | Block layer, mount root | drivers, VFS | 9/10 |
| 21 | Spawn `init` in ring 3 | everything | 8 |

**Rule:** serial output works from step 1, so any failure from step 2 onward is
reportable. This is the entire reason serial precedes the framebuffer.

---

## Memory layout (x86_64, 4-level paging)

Canonical 48-bit address space. Kernel is higher-half.

```
0xFFFFFFFFFFFFFFFF ┌──────────────────────────────┐
                   │  (top 2 GiB)                 │
0xFFFFFFFF80000000 │  Kernel image  .text .rodata │  -mcmodel=kernel
                   │                .data  .bss   │  requires this range
                   ├──────────────────────────────┤
0xFFFFFFFF00000000 │  Kernel heap (grows up)      │
                   ├──────────────────────────────┤
0xFFFF900000000000 │  Per-CPU areas               │
                   ├──────────────────────────────┤
0xFFFF800000000000 │  HHDM — direct map of all    │  phys 0 maps here;
                   │  physical RAM                │  phys_to_virt = +offset
                   ├──────────────────────────────┤
                   │  ##### non-canonical hole ## │
                   ├──────────────────────────────┤
0x0000800000000000 │                              │
                   │  USER SPACE                  │
0x0000700000000000 │    user stack (grows down)   │
                   │    mmap region               │
0x0000000000400000 │    user program .text/.data  │
0x0000000000000000 │    (first 4 MiB unmapped —   │  so a null-pointer
                   │     null deref faults)       │  dereference faults
                   └──────────────────────────────┘
```

Key properties:

- **The kernel is mapped into every address space** (upper half), so a syscall or
  interrupt from user mode does not need a page-table switch to run kernel code.
  Only the lower half changes on a process switch.
- **User pages have the USER bit set; kernel pages do not.** The CPU enforces the
  boundary in hardware.
- **HHDM** means any physical address is reachable as `hhdm_offset + phys`. No
  temporary mappings needed to touch arbitrary physical memory.
- The **first 4 MiB of user space is deliberately unmapped** so null-pointer
  dereferences fault instead of silently reading whatever is at address 0.

---

## Subsystem map

```
┌───────────────────────────────────────────────────────────┐
│ USER (ring 3)                                             │
│   init · sh · coreutils · net tools                       │
│   libc  (syscall wrappers, malloc, stdio, string)         │
└──────────────────────────┬────────────────────────────────┘
                    syscall instruction
┌──────────────────────────▼────────────────────────────────┐
│ KERNEL (ring 0)                                           │
│                                                           │
│  syscall/  dispatch · argument validation · errno         │
│  ─────────────────────────────────────────────────────    │
│  sched/    tasks · scheduler · spinlocks · mutexes        │
│  fs/       VFS ──┬── tmpfs ── FAT32 ── ext2               │
│  net/      sockets · TCP · UDP · IP · ARP                 │
│  ─────────────────────────────────────────────────────    │
│  drivers/  block ─┬─ AHCI ─ NVMe                          │
│            net   ─┴─ e1000 · virtio-net                   │
│            char  ─── serial · keyboard · framebuffer      │
│  ─────────────────────────────────────────────────────    │
│  mm/       heap · VMM · PMM                               │
│  lib/      kstd:: · printf · string · log ring            │
│  ─────────────────────────────────────────────────────    │
│  arch/x86_64/   GDT IDT TSS · APIC · paging · ctx switch  │
│                 boot/ (the only Limine-aware code)        │
└───────────────────────────────────────────────────────────┘
```

**Dependency rule:** a layer may call downward and sideways within its layer. It may
**not** call upward. `mm/` must never call `fs/`. CI cannot fully enforce this, so it
is a review responsibility ([[12 - Team Workflow]]).

---

## Concurrency model

This is where kernels go wrong, so the rules are explicit and they apply from
[[Phase 5 - Overview]] onward — not from Phase 12 when SMP arrives.

| Context | May sleep? | May take a mutex? | May take a spinlock? |
|---|---|---|---|
| Process context (syscall) | yes | yes | yes |
| Interrupt handler | **no** | **no** | yes — must be IRQ-save |
| Scheduler internals | no | no | yes |

**Non-preemptible kernel in v1.** A task in kernel mode runs until it blocks or
returns to user mode. This eliminates a large class of races and is what xv6 does.
Revisit post-1.0.

**Lock ordering** is documented in `kernel/sched/locks.md` and must be respected
globally. Any lock taken out of order is a deadlock waiting for load. Every lock
gets a documented rank; taking a lower rank while holding a higher one is a bug and
is checked by `KASSERT` in debug builds.

**IRQ-save discipline.** A spinlock shared with an interrupt handler must be taken
with interrupts disabled on the local CPU, or the handler can interrupt the holder
and spin forever on a lock the same CPU already owns. RAII guards
(`irq_lock_guard`) make this the default and the easy path.

---

## Syscall interface

`syscall`/`sysret` (the fast path), **not** `int 0x80` — v1 planned `int 0x80`, which
is the 32-bit convention and roughly an order of magnitude slower on x86_64.

- Number in `rax`; arguments in `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9`.
  **`r10`, not `rcx`** — the `syscall` instruction clobbers `rcx` with the return
  address. This catches everyone once.
- Return value in `rax`; errors as negative errno, Linux-style.
- **Every user pointer is validated before dereference**: canonical, below the user
  ceiling, and mapped. A missing check here is a full kernel compromise, and it is
  the single most security-critical code in the tree.

The syscall table, numbers, and `errno` values live in `kernel/include/abi/` — the
one place shared by kernel and libc ([[ADR-0008 - Monorepo Layout]]).

---

## Related

[[05 - Gap Analysis (v1 to Product)]] · [[07 - Repository Layout]] · [[15 - Roadmap and Milestones]]

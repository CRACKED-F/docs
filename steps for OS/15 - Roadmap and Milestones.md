# Roadmap and Milestones

The plan from empty repository to v1.0, with honest estimates and pre-agreed cut
lines.

---

## Milestones

Each milestone is a **releasable state** — it boots, it does something demonstrable,
it gets a version tag and a GitHub Release ([[11 - Release and Deployment]]).

| M | Name | Phases | Version | Estimate | Demonstrable outcome |
|---|---|---|---|---|---|
| **M1** | It boots | 0–2 | `v0.1.0` | 6–10 wk | Boots UEFI + BIOS, prints to framebuffer and serial, faults report cleanly with a symbolised backtrace |
| **M2** | It's interactive | 3–5 | `v0.2.0` | 10–14 wk | Type on the keyboard, timer ticks, `kmalloc` works, two kernel tasks preempt |
| **M3** | It has users | 6–8 | `v0.3.0` | 12–16 wk | Boots to a shell in ring 3, runs programs from a ramdisk |
| **M4** | It remembers | 9–10 | `v0.4.0` | 10–14 wk | Writes a file to a real disk, reboots, reads it back |
| **M5** | It's modern | 11–12 | `v0.5.0` | 10–14 wk | ACPI shutdown, PCI enumeration, 4 cores online |
| **M6** | It's Unix | 13 | `v0.6.0` | 8–12 wk | `fork`, pipes, signals, `Ctrl-C`, job control |
| **M7** | It's networked | 14 | `v0.7.0` | 10–14 wk | Pings, serves TCP |
| **M8** | It's hardened | 15 | `v1.0.0` | 6–10 wk | NX/SMEP/SMAP/W^X, users and permissions, boots on real hardware |

**Total: 72–104 weeks — roughly 18–26 months part-time for two people.**

That number is uncomfortable and it is honest. Every hobby OS that shipped took this
long. The correct response to disliking it is to **cut scope deliberately** (see below),
not to compress estimates.

---

## Phase index

### Rearchitected from v1

| Phase | Name | Changed how |
|---|---|---|
| [[Phase 0 - Overview\|0]] | Toolchain & First Boot | x86_64, Limine, container toolchain, serial + panic added |
| [[Phase 1 - Overview\|1]] | Console & Logging | Framebuffer instead of VGA text; log ring + backtrace added |
| [[Phase 2 - Overview\|2]] | CPU Tables & Interrupts | 64-bit GDT/IDT/TSS, IST stacks |
| [[Phase 3 - Overview\|3]] | Drivers: Timer & Keyboard | Unchanged in shape |
| [[Phase 4 - Overview\|4]] | Memory Management | 4-level paging, higher-half, our own tables |
| [[Phase 5 - Overview\|5]] | Multitasking | **Stage 5.0 added: synchronisation before preemption** |
| [[Phase 6 - Overview\|6]] | User Mode & Syscalls | `syscall`/`sysret` instead of `int 0x80` |
| [[Phase 7 - Overview\|7]] | VFS & Program Loading | Writable tmpfs instead of read-only tar |
| [[Phase 8 - Overview\|8]] | The Shell | Unchanged in shape |

### New

| Phase | Name | Delivers |
|---|---|---|
| [[Phase 9 - Overview\|9]] | Storage | Block layer, buffer cache, AHCI, NVMe |
| [[Phase 10 - Overview\|10]] | Real Filesystems | FAT32, ext2, mount, persistence |
| [[Phase 11 - Overview\|11]] | Modern Platform | ACPI, APIC, PCI, HPET/TSC, RTC, shutdown |
| [[Phase 12 - Overview\|12]] | SMP | Multicore, per-CPU, scalable locking |
| [[Phase 13 - Overview\|13]] | Unix Process Model | fork/COW, pipes, signals, TTY, full libc |
| [[Phase 14 - Overview\|14]] | Networking | e1000/virtio-net, ARP/IP/UDP/TCP, sockets |
| [[Phase 15 - Overview\|15]] | Hardening & Real Hardware | NX/SMEP/SMAP/W^X, users, real-metal bring-up |

---

## Critical path and parallelism

The dependency chain is what forces the ordering. Everything below the line is what
two people can do at once.

```
0 ──► 1 ──► 2 ──► 4 ──► 5 ──► 6 ──► 7 ──► 8        the spine
            │           │
            └──► 3 ─────┘                          drivers, joins at 5
                        │
                 11 ────┼──► 12                    platform, then SMP
                        │
                  9 ──► 10                         storage, then filesystems
                        │
                       13 ──► 14                   process model, then net
                        │
                       15                          hardening
```

**Where the two of you genuinely work in parallel** ([[12 - Team Workflow]]):

| Window | Member A ("Down") | Member B ("Up") |
|---|---|---|
| M1 | Phase 0, 2 — boot, CPU tables | Phase 1 — console, log, backtrace |
| M2 | Phase 3 — timer, keyboard | Phase 4 heap, Phase 5 sync + sched |
| M3 | Phase 4 address spaces, `fork` prep | Phase 6, 7, 8 — syscalls, VFS, shell |
| M4 | Phase 9 — AHCI, NVMe | Phase 10 — FAT32, ext2 on a stub blockdev |
| M5 | Phase 11 — ACPI, APIC, PCI | Phase 12 — per-CPU, locking, scheduler |
| M6 | Phase 12 finish — AP bring-up | Phase 13 — fork, pipes, signals, libc |
| M7 | Phase 14 — NIC drivers | Phase 14 — TCP/IP stack, sockets |
| M8 | Phase 15 — real hardware bring-up | Phase 15 — users, permissions |

The interface-first rule from [[12 - Team Workflow]] is what makes the M4 and M7 rows
possible: agree `blockdev.hpp` and `netdev.hpp` first, then both sides build against
it independently.

---

## Cut lines — decide these now, not at month 14

If the schedule slips (it will), these are the pre-agreed places to cut. Deciding in
advance prevents the far worse outcome: cutting in a panic, badly.

| Priority | Scope | Cut? |
|---|---|---|
| 1 | M1–M4 (boot → persistence) | **Never.** Below this it is not an OS |
| 2 | M5 platform: ACPI + PCI | **Never.** Without ACPI it cannot power off |
| 3 | M5 SMP | **Cuttable.** Single-core is a legitimate v1.0 |
| 4 | M6 process model | **Never.** `fork`/pipes/signals is what "Unix-like" means |
| 5 | M7 networking | **First to cut.** Ship v1.0 at M6; networking becomes v1.1 |
| 6 | M8 hardening | **Partially cuttable.** Keep NX + W^X; defer users/permissions |

**If you cut one thing, cut networking.** It is the largest single chunk (10–14
weeks), the most self-contained, and the least load-bearing for the claim "we built
an operating system."

**If you cut two, cut networking and SMP.** That gets v1.0 to roughly 12–16 months
and loses nothing essential — a single-core OS that boots real hardware, persists
data, and runs a Unix process model is unambiguously a real operating system.

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| One member drops out | Medium | Fatal | Both review everything; no single-owner knowledge; docs current |
| Stuck on one bug for weeks | **High** | High | 1-day time-box rule; park with a workaround and an issue |
| Real hardware does not boot at M8 | Medium | High | **Test on metal from M1**, not at M8. Do not let this accumulate |
| Scope creep | High | Medium | Cut lines above; ADR required for scope changes |
| Toolchain drift | Low | High | Already mitigated — [[ADR-0005 - Containerised Pinned Toolchain]] |
| Losing motivation in a long phase | **High** | High | Milestones are demoable; ship a release at each |
| Limine breaking change | Low | Medium | Pinned version; escape hatch in [[ADR-0003 - Limine as the Bootloader]] |

Two of these deserve emphasis.

**"Test on metal from M1."** The temptation is to stay in QEMU until the end and then
port. That is how projects discover at month 20 that a foundational assumption was
emulator-specific. Buy a cheap second-hand x86_64 UEFI laptop now. Boot the M1 build
on it. Repeat every milestone.

**"Losing motivation."** This is the actual leading cause of death for hobby OS
projects — not technical difficulty. The mitigation is structural: every milestone
produces something you can show someone.

---

## Working agreement

- Milestones are **demoable**, not just complete. If you cannot show it to a friend
  in two minutes, it is not done.
- Ship a tagged release at every milestone, even if only the two of you ever install
  it. The release ritual keeps the pipeline healthy.
- Re-estimate at every milestone retro using actual velocity, not hope.
- If a phase runs 50% over, stop and re-plan rather than pushing through.

---

## Related

[[05 - Gap Analysis (v1 to Product)]] · [[12 - Team Workflow]] · [[11 - Release and Deployment]] · [[00 - Start Here]]

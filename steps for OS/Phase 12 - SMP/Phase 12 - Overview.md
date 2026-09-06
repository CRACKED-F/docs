# Phase 12 — SMP (Symmetric Multiprocessing)

**Goal:** use every core. You will set up **per-CPU data**, start the **application
processors**, make the scheduler run tasks on all of them, and — the real work —
make every shared data structure in the kernel **safe against genuine concurrency**.

> Prerequisite: [[Phase 11 - Overview|Phase 11]] (LAPIC and ACPI MADT), and
> **[[Phase 5 - Overview|Phase 5]] Stage 5.0**, which introduced spinlocks and IRQ
> discipline before the first preemptive switch. If Stage 5.0 was skipped, stop and
> do it now — this phase will otherwise be an unbounded debugging exercise.

---

## Why this phase exists

Every machine you will run on has between 4 and 16 cores. Using one is leaving 75–94%
of the machine idle.

But the real reason this phase is hard is not the bring-up. **Starting the other
cores takes an afternoon. Making the kernel correct on them takes weeks.**

On a single core with a non-preemptible kernel, disabling interrupts is a sufficient
critical section — nothing else can be running. On multiple cores, that guarantee
evaporates: another core is genuinely executing your code at the same moment.
Every shared structure — the scheduler run queue, the physical frame allocator, the
heap, the buffer cache, the VFS mount table, every driver's state — becomes a race.

This is why [[05 - Gap Analysis (v1 to Product)]] flagged v1's missing synchronisation
(gap S7) as a *structural* gap rather than a missing feature. The fix was to introduce
locking discipline in Phase 5, before it was needed, so that this phase is an
extension rather than a retrofit.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 12.1 | Stage 12.1 - Per-CPU Data | Medium | `this_cpu()` via GS-base, per-core structures |
| 12.2 | Stage 12.2 - Atomics and Memory Ordering | Hard | Correct use of `std::atomic`, barriers, and the x86 memory model |
| 12.3 | Stage 12.3 - Starting the Application Processors | Hard | All cores running kernel code |
| 12.4 | Stage 12.4 - Per-CPU Scheduling and Load Balancing | Hard | Tasks distributed across cores |
| 12.5 | Stage 12.5 - Auditing the Kernel for Races | **Hard** | Every shared structure locked, with a documented order |
| 12.6 | Stage 12.6 - TLB Shootdown | Hard | Page-table changes propagated to other cores via IPI |
| 12.7 | Stage 12.7 - Scalable Locking | Medium | Reader-writer locks, per-CPU freelists, reduced contention |

**Stage 12.5 is the phase.** Budget more time for it than for all the others
combined. It is not glamorous — it is reading every file in `kernel/` and asking "what
happens if two cores are here at once?" — and it is the difference between an SMP
kernel and an SMP kernel that crashes once a day.

---

## Deliverable

The OS boots with `-smp 4` (and on real hardware, with however many cores exist),
reports all cores online, distributes tasks across them, survives a multi-core stress
test that would expose races, and correctly invalidates TLB entries on remote cores
when a mapping changes.

`ps` shows which core each task is on. Killing a task on one core from another works.

---

## The hard parts, named in advance

**Limine starts the APs for us.** The AP trampoline — the 16-bit real-mode stub, the
INIT/SIPI sequence, the transition to long mode — is handled by the bootloader's SMP
request ([[ADR-0003 - Limine as the Bootloader]]). This removes an entire class of
bring-up bugs. Our job is what the APs do once they are running, which is the part
that actually matters.

**`this_cpu()` must work before anything else on a new core.** Per-CPU data is
accessed via the `GS` base MSR (`IA32_KERNEL_GS_BASE`). Setting that up is the first
thing an AP does, because every lock, every log line, and every assertion needs to
know which core it is on.

**`swapgs` and the syscall path.** On entry from user mode you must `swapgs` to get
the kernel's per-CPU base, and swap back on return. Getting this wrong — or getting
it wrong on the *nested interrupt* path — is a classic and severe bug. There is a
well-known class of vulnerabilities in real kernels from exactly this.

**The x86 memory model helps, and will lull you.** x86 is strongly ordered: stores are
not reordered with other stores, loads not with loads. That means many naive
lock-free patterns *happen* to work. They are still wrong — the compiler will reorder
even when the CPU does not, and a future change to inlining will expose it. Use
`std::atomic` with explicit ordering, always.

**TLB shootdown.** When core 0 unmaps a page, cores 1–3 may still have the old
translation cached. You must send them an IPI and wait for acknowledgement before
freeing the frame. Skipping this produces use-after-free that only manifests under
load, on multicore, occasionally.

**Lock ordering becomes load-bearing.** With one core, taking locks out of order is
usually survivable. With four, it is a deadlock waiting for the right interleaving.
`kernel/sched/locks.md` stops being documentation and becomes a specification.

---

## The audit checklist for Stage 12.5

Every one of these was written assuming one core. Every one needs review:

```
[ ] PMM free-frame bitmap
[ ] Heap block list
[ ] Scheduler run queue          (per-CPU queues + a balancer, not one global)
[ ] Task list / PID allocation
[ ] Page-table modification      (+ TLB shootdown)
[ ] Buffer cache
[ ] VFS mount table, open-file table
[ ] Every filesystem's in-memory state
[ ] Every driver's command queue
[ ] The kernel log ring buffer
[ ] The console (two cores printing interleave into garbage)
[ ] PCI config-space access      (0xCF8/0xCFC is a global two-register protocol)
[ ] The RTC / CMOS index port    (same problem)
```

Those last two are easy to miss: they are *port-based* protocols where two cores
interleaving their index/data writes corrupt each other's reads.

---

## Testing

| Tier | What |
|---|---|
| 1 | Lock-order rank checking; the run-queue balancer's selection given a synthetic multi-core state |
| 2 | All cores reach the kernel; atomic increment from 4 cores × 1M iterations gives exactly 4M; TLB shootdown observed via a mapping change |
| 3 | Boot `-smp 1/2/4/8`; run a stress load on all cores for 10 minutes with no deadlock, no corruption, no lost wakeup |

Run Tier 2 and 3 with `-accel tcg,thread=multi`, which interleaves far more
aggressively than the default and shakes out races the hardware would hide.

---

## Read before you start

- OSDev — *Symmetric Multiprocessing*: <https://wiki.osdev.org/Symmetric_Multiprocessing>
- OSDev — *Synchronization Primitives*: <https://wiki.osdev.org/Synchronization_Primitives>
- Limine protocol — the SMP request
- Intel SDM Vol. 3, Ch. 8 "Multiple-Processor Management" and Ch. 9 "Memory Cache
  Control"
- Paul McKenney, *Is Parallel Programming Hard, And, If So, What Can You Do About
  It?* — free, and the best treatment of kernel concurrency in print:
  <https://mirrors.edge.kernel.org/pub/linux/kernel/people/paulmck/perfbook/perfbook.html>
- OSTEP — "Concurrency" chapters: <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Previous: [[Phase 11 - Overview]] · Next: [[Phase 13 - Overview]]

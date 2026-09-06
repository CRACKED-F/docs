# Phase 9 — Storage

**Goal:** reach a real disk. You will build a **block device** abstraction, a
**buffer cache** so the same sector is not read twice, an **AHCI** driver for SATA
disks, and an **NVMe** driver for the drives modern machines actually ship with.

At the end of this phase the kernel can read and write raw sectors on a physical
disk. No filesystem yet — that is [[Phase 10 - Overview|Phase 10]]. This phase is
about getting bytes on and off the platter.

> Prerequisite: [[Phase 4 - Overview|Phase 4]] (heap, and DMA needs physical
> addresses), [[Phase 11 - Overview|Phase 11]] Stage 11.3 (PCI enumeration — you
> cannot find an AHCI or NVMe controller without it).

---

## Why this phase exists

Everything up to here lives in RAM. Power off, and it is gone. The v1 vault ended at
a **read-only tar ramdisk**, which is fine for a teaching milestone and useless for a
product — see [[05 - Gap Analysis (v1 to Product)]], gap B4.

An operating system that cannot persist is a demo. This phase is the foundation of
persistence, and it is also the first time you write a driver for a device that
**does not respond immediately**. That changes the shape of your code: reads become
asynchronous, the calling task blocks, and an interrupt wakes it. The blocking
machinery from [[Stage 5.4 - Sleep and Blocking]] finally earns its keep.

### The ordering decision

Block layer → cache → driver, not driver → cache → block layer. Writing the
abstraction first means the FAT32 work in Phase 10 can start against a **RAM-backed
stub block device** while the AHCI driver is still being written. That is the
interface-first rule from [[12 - Team Workflow]], and it is what lets both members
work through M4 in parallel.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 9.1 | Stage 9.1 - The Block Device Interface | Medium | One API over any disk; a RAM-disk implementation |
| 9.2 | Stage 9.2 - DMA and Physically Contiguous Memory | Medium | Allocator for buffers hardware can reach |
| 9.3 | Stage 9.3 - The Buffer Cache | Hard | Cached, write-back sector access |
| 9.4 | Stage 9.4 - PCI Device Discovery for Storage | Medium | Find the disk controller |
| 9.5 | Stage 9.5 - The AHCI Driver | Hard | Read and write real SATA sectors |
| 9.6 | Stage 9.6 - The NVMe Driver | Hard | Read and write real NVMe sectors |
| 9.7 | Stage 9.7 - Partition Table Parsing | Medium | Find partitions via GPT and MBR |

---

## Deliverable

The kernel enumerates the storage controllers present, identifies attached disks with
their capacity and sector size, parses the partition table, and reads and writes
arbitrary sectors through a cache — verified by writing a pattern, dropping the
cache, reading it back, and comparing.

Under QEMU this works against both `-drive if=none,...  -device ahci` and
`-device nvme`. On real hardware it is the moment the OS touches your actual SSD.

---

## What makes this phase different

**Asynchrony.** Every previous driver responded instantly. A disk takes
milliseconds — millions of cycles. You must issue a command, block the calling task,
and complete it from an interrupt handler. Getting this wrong produces a kernel that
appears to hang.

**DMA.** The disk controller writes directly into RAM without the CPU. That means:

- Buffers must be **physically contiguous** — the device does not walk your page
  tables. A `kmalloc`'d buffer that is virtually contiguous may be physically
  scattered.
- You give the device a **physical** address, not a virtual one. Passing a virtual
  address is the classic first AHCI bug and it corrupts whatever happens to live at
  that physical address.
- Alignment requirements are strict (AHCI command structures need 1 KiB alignment;
  PRDT entries have their own rules).

**Real hardware is unforgiving.** QEMU's AHCI implementation is forgiving about
timing and about not fully resetting the port. Real controllers are not. Test on
metal early — this is one of the phases where [[15 - Roadmap and Milestones]]'s "test
on metal from M1" advice pays for itself.

---

## Why both AHCI and NVMe

| | AHCI (SATA) | NVMe |
|---|---|---|
| Found on | Most machines 2005–2020, all QEMU defaults | Most machines 2018+ |
| Complexity | Moderate — port registers, command lists | Moderate — submission/completion queues |
| Worth it? | Yes — it is what QEMU and older hardware give you | Yes — it is what your test laptop actually has |

Writing both is not duplicated effort: it is the second implementation that proves
the block-device interface from Stage 9.1 is a real abstraction rather than an
AHCI-shaped hole. This is the same argument as three filesystems behind one VFS in
[[ADR-0009 - Filesystem Strategy FAT32 then ext2]].

---

## Testing

| Tier | What |
|---|---|
| 1 | GPT/MBR parsing, CRC32 of the GPT header, LBA arithmetic, cache eviction policy |
| 2 | Write a pattern to a RAM disk through the cache, drop the cache, read back; AHCI identify returns a plausible capacity |
| 3 | Boot with a QEMU disk attached, write, reboot, read back — **the real persistence proof** |

Run Tier 3 against both `-device ahci` and `-device nvme`.

---

## Read before you start

- OSDev — *AHCI*: <https://wiki.osdev.org/AHCI>
- OSDev — *NVMe*: <https://wiki.osdev.org/NVMe>
- OSDev — *PCI*: <https://wiki.osdev.org/PCI>
- OSDev — *GPT* and *Partition Table*: <https://wiki.osdev.org/GPT>
- Serial ATA AHCI Specification 1.3.1 (the ground truth for the register layout)
- NVM Express Base Specification (queues, admin vs I/O commands)
- OSTEP — "Hard Disk Drives" and "I/O Devices" for the model:
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>

Previous: [[Phase 8 - Overview]] · Next: [[Phase 10 - Overview]]

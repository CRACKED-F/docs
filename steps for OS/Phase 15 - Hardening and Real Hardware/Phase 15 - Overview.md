# Phase 15 — Hardening and Real Hardware

**Goal:** ship it. You will turn on the CPU's memory-protection features (**NX**,
**SMEP**, **SMAP**, **W^X**, **KASLR**), add **users and permissions**, audit the
syscall boundary, and then do the thing the whole project has been aiming at —
**boot on a real computer**, repeatedly and reliably.

This phase ends at `v1.0.0`.

> Prerequisite: everything. This is the last phase.

---

## Why this phase exists

Two separate reasons, and they are both about the gap between "works" and "shipped".

**Security.** Up to now, every protection has been the one the CPU gives you for free
(rings and page permissions). A kernel with no NX bit will happily execute data. A
kernel without SMAP will happily dereference a user pointer it should have validated.
These are single-bit-flip mitigations that turn whole vulnerability classes into
clean faults, and turning them on is cheap — but only if the kernel was written
correctly, which is exactly what turning them on tests.

**Real hardware.** QEMU is a model, and models are forgiving. Real firmware is buggy,
real devices have quirks, real timing is different, and real machines have devices
QEMU never emulated. Every hobby OS discovers this. The only question is whether you
discover it in Phase 15 or across all fifteen phases.

**This is why [[15 - Roadmap and Milestones]] says test on metal from M1.** If you
did, this phase is a week of polish. If you did not, it is a rewrite of assumptions
you made two years ago.

---

## Stages

| # | Stage | Difficulty | You will have |
|---|---|---|---|
| 15.1 | Stage 15.1 - NX and W^X | Medium | No page is both writable and executable |
| 15.2 | Stage 15.2 - SMEP and SMAP | Medium | The kernel cannot accidentally run or read user memory |
| 15.3 | Stage 15.3 - Guard Pages and Stack Protection | Medium | Stack overflow faults cleanly instead of corrupting |
| 15.4 | Stage 15.4 - KASLR | Hard | Kernel base randomised per boot |
| 15.5 | Stage 15.5 - Auditing the Syscall Boundary | **Hard** | Every user pointer, length, and fd validated |
| 15.6 | Stage 15.6 - Users, Groups, and Permissions | Hard | `uid`/`gid`, mode bits enforced, `setuid` |
| 15.7 | Stage 15.7 - Resource Limits | Medium | A process cannot exhaust the machine |
| 15.8 | Stage 15.8 - Real Hardware Bring-Up | **Hard** | It boots on an actual computer |
| 15.9 | Stage 15.9 - The Release Checklist | Medium | `v1.0.0` published with artefacts |

---

## Deliverable

The OS boots from a USB stick on a physical x86_64 UEFI machine, reaches a shell,
runs programs as a non-root user with permissions enforced, refuses a deliberately
malicious syscall, survives a stack-overflow attempt with a clean fault, and powers
off cleanly.

`v1.0.0` is tagged, built by CI, and published with an ISO, a disk image, VM
appliances, checksums, and an honest known-limitations list.

---

## The protections, and what each one actually stops

| Feature | Bit | Stops |
|---|---|---|
| **NX** (No-Execute) | PTE bit 63 | Executing injected data — the entire shellcode-on-the-stack class |
| **W^X** | policy | A page being writable *and* executable at the same time |
| **SMEP** | CR4.SMEP | The kernel jumping to user-mode code (a classic privilege escalation) |
| **SMAP** | CR4.SMAP | The kernel *reading* user memory without an explicit `stac`/`clac` — catches every missing validation |
| **Guard pages** | unmapped page | Stack overflow becomes a page fault, not silent corruption of the neighbour |
| **KASLR** | random base | Makes an attacker guess where the kernel is |

**SMAP is the most valuable one for a project like this**, and not primarily for
security: it converts every place you forgot to validate a user pointer into an
immediate, loud, obvious fault. Turning it on will find bugs. Expect it to, and turn
it on before the audit in Stage 15.5 rather than after.

**W^X has a real consequence**: the kernel's own `.text` must become read-only after
init, and `.data`/`.bss`/heap must become non-executable. This is why the linker
script in [[08 - Build System]] 4 KiB-aligns every section — so permissions can differ
per section without a relayout at this late stage.

---

## Stage 15.5 — the syscall audit

Every syscall, every argument, every time:

```
[ ] Pointer is canonical (not in the non-canonical hole)
[ ] Pointer + length does not overflow
[ ] The whole range is below the user ceiling
[ ] The whole range is mapped, with the right permission
[ ] Length is bounded (no 2^63-byte read)
[ ] fd is in range, open, and of the right type
[ ] String arguments are bounded (strnlen against a limit, not strlen)
[ ] Nothing is re-read after validation  ← TOCTOU: copy in, then use the copy
[ ] The return value cannot leak a kernel address
```

That second-to-last item is the subtle one. If you validate a user pointer and then
read from it twice, another thread in the same process can change the memory between
the check and the second read. **Copy user data into the kernel once, then operate on
the copy.**

This is the most security-critical code in the tree ([[13 - Coding Standards]] rule 5)
and it is the one place where a two-person team should always review together.

---

## Stage 15.8 — real hardware bring-up

What actually goes wrong, in rough order of frequency:

| Problem | Cause | Fix |
|---|---|---|
| Nothing on screen | Assuming VGA text mode | Framebuffer — [[ADR-0004 - Framebuffer Console Not VGA Text]] |
| Firmware refuses to boot | Secure Boot | Disable it in firmware |
| Hangs after Limine | Hardcoded memory assumptions | Honour the actual memory map |
| Keyboard dead | **No PS/2 controller** | The known limitation; needs a USB stack |
| Disk not found | Assuming AHCI when it is NVMe | Enumerate, do not assume |
| Random hangs | Timing calibrated against QEMU | Calibrate against HPET at runtime |
| Faults with more RAM | 32-bit truncation somewhere | Test with 4 GiB+ in QEMU too |

**Get a serial cable.** A USB-to-TTL adapter costs almost nothing and turns
real-hardware debugging from screenshot archaeology into the same workflow you have
in QEMU. On a machine with no serial header, a PCIe or USB serial adapter works if
you have the driver — which is a good reason to write one.

**Keep a dedicated test machine.** A cheap second-hand x86_64 UEFI laptop. It will
have hardware QEMU never modelled, which is the entire point.

---

## Testing

| Tier | What |
|---|---|
| 1 | Pointer-validation logic against adversarial inputs: overflow, non-canonical, boundary-straddling, zero-length, huge-length |
| 2 | NX faults on executing a data page; SMAP faults on an unguarded kernel read of user memory; a guard page catches stack overflow |
| 3 | A deliberately malicious user program tries every attack in the audit list and is rejected each time. Permission enforcement: a non-root user cannot read a `0600` file owned by root |

Then the manual real-hardware checklist from [[11 - Release and Deployment]].

---

## Read before you start

- OSDev — *Security*: <https://wiki.osdev.org/Security>
- Intel SDM Vol. 3, Ch. 4.6 "Access Rights" (SMEP/SMAP), Ch. 5 "Protection"
- OSDev — *Page Frame Allocation*, "NX bit": <https://wiki.osdev.org/Paging>
- The Linux `copy_from_user` implementation — the reference for doing this correctly
- OSTEP — "Security" chapters: <https://pages.cs.wisc.edu/~remzi/OSTEP/>

---

## Then what

See [[Capstone - You Built an OS]] — and note that shipping `v1.0.0` is not the end of
the project, it is the point at which the project has users, even if the users are
just the two of you.

Previous: [[Phase 14 - Overview]] · Next: [[Capstone - You Built an OS]]

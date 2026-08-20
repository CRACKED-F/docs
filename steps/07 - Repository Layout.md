# Repository Layout

Where every file goes and why. Decided in [[ADR-0008 - Monorepo Layout]].

Two repositories:

| Repo | Contains | Why separate |
|---|---|---|
| `CRACKED-F/os` | All code, tests, build, CI, release | One atomic version |
| `CRACKED-F/docs` | This Obsidian vault | Different audience, cadence, no build coupling |

---

## The tree

```
os/
├── .github/
│   ├── workflows/
│   │   ├── ci.yml              push + PR: lint, unit, kernel, boot
│   │   ├── release.yml         tag v*: build all images, GitHub Release
│   │   ├── nightly.yml         full matrix + long-running stress
│   │   └── toolchain.yml       rebuild + push the toolchain image
│   ├── ISSUE_TEMPLATE/
│   ├── pull_request_template.md
│   └── CODEOWNERS
│
├── boot/
│   ├── limine.conf             boot menu, kernel path, module list
│   ├── limine.mk               PINNED Limine version + fetch rule
│   └── stage/                  ISO/ESP staging tree (gitignored output)
│
├── kernel/
│   ├── arch/x86_64/            ◄── ONLY architecture-specific code
│   │   ├── boot/
│   │   │   ├── entry.cpp       kmain, Limine requests
│   │   │   ├── boot_info.cpp   Limine responses ──► boot_info_t
│   │   │   └── linker.ld       higher-half layout
│   │   ├── cpu/
│   │   │   ├── gdt.cpp  idt.cpp  tss.cpp
│   │   │   ├── exceptions.cpp
│   │   │   ├── lapic.cpp  ioapic.cpp
│   │   │   └── cpuid.cpp  msr.hpp  io.hpp
│   │   ├── mm/
│   │   │   ├── paging.cpp      4-level page tables
│   │   │   └── tlb.cpp
│   │   ├── asm/
│   │   │   ├── isr_stubs.asm   the 256 interrupt entry points
│   │   │   ├── switch.asm      context switch
│   │   │   ├── syscall.asm     syscall/sysret entry
│   │   │   └── ap_trampoline.asm
│   │   └── smp/
│   │
│   ├── mm/                     architecture-neutral, HOST-TESTABLE
│   │   ├── pmm.cpp             physical frame allocator
│   │   ├── vmm.cpp             address-space objects
│   │   ├── heap.cpp            kmalloc / free
│   │   └── slab.cpp
│   ├── sched/
│   │   ├── task.cpp  sched.cpp
│   │   ├── spinlock.hpp  mutex.cpp  semaphore.cpp
│   │   ├── percpu.hpp
│   │   └── locks.md            ◄── THE LOCK ORDER. Read before adding a lock.
│   ├── fs/
│   │   ├── vfs.cpp  path.cpp
│   │   ├── tmpfs/  fat32/  ext2/
│   ├── drivers/
│   │   ├── char/   serial.cpp  fbcon.cpp  keyboard.cpp
│   │   ├── block/  ahci/  nvme/  blockdev.cpp  bcache.cpp
│   │   ├── net/    e1000/  virtio_net/
│   │   ├── pci/    pci.cpp  mmconfig.cpp
│   │   └── acpi/   tables.cpp  madt.cpp  fadt.cpp  shutdown.cpp
│   ├── net/        arp.cpp ipv4.cpp udp.cpp tcp.cpp socket.cpp
│   ├── syscall/    dispatch.cpp  validate.cpp  sys_*.cpp
│   ├── lib/        printf.cpp  string.cpp  log.cpp  kstd/
│   └── include/
│       ├── abi/    ◄── SHARED WITH LIBC. syscall numbers, errno, structs
│       └── kernel/
│
├── libc/           userspace C library
│   ├── include/    stdio.h stdlib.h string.h unistd.h ...
│   ├── src/        syscall wrappers, malloc, stdio, string
│   └── crt/        crt0.asm
│
├── user/           userspace programs
│   ├── init/  sh/
│   └── bin/        cat ls echo ps kill mkdir rm cp mv ...
│
├── tests/
│   ├── unit/       host-compiled, doctest, milliseconds
│   ├── kernel/     in-kernel self-tests, run under QEMU
│   └── integration/ pexpect scripts against the real image
│
├── tools/          host tools: mkinitrd, mkfont, symbolise, gdbinit-gen
├── scripts/        build.sh run.sh test.sh mkimage.sh debug.sh fmt.sh
├── toolchain/      Dockerfile + pinned versions
├── cmake/          toolchain files, KernelFlags.cmake
├── CMakeLists.txt
├── Makefile        thin host wrapper -> container
└── .clang-format .clang-tidy .editorconfig .gitattributes .gitignore
```

---

## The four boundary rules

These are enforced by CI, not by good intentions. Each has a grep in
`.github/workflows/ci.yml`.

### 1. Architecture code is confined

Inline assembly, x86 register names, and port I/O may appear **only** under
`kernel/arch/`. Everything else is portable C++.

*Why:* it is the only thing that keeps a second architecture from being a rewrite,
and it is what makes `kernel/mm/` host-testable.

### 2. Limine is confined

`limine.h` may be included **only** under `kernel/arch/x86_64/boot/`.

*Why:* the escape hatch in [[ADR-0003 - Limine as the Bootloader]] is worthless if
the protocol leaks into the kernel proper.

### 3. Kernel never includes userspace

`kernel/` must not include from `libc/` or `user/`.

*Why:* different privilege domain, different memory rules, different allocator. A
kernel that accidentally links a userspace `malloc` is a very confusing afternoon.

### 4. The ABI has exactly one home

Anything crossing the kernel/user boundary — syscall numbers, `errno` values, struct
layouts, flag constants — lives in `kernel/include/abi/` and nowhere else. `libc/`
includes from there.

*Why:* two copies of a syscall number drift, and the failure is a syscall silently
doing the wrong thing. **Changes here require both reviewers.**

---

## Where does new code go?

| You are writing | Put it in |
|---|---|
| Something touching a CPU register or port | `kernel/arch/x86_64/` |
| Pure logic, no hardware | `kernel/<subsystem>/` — and write a Tier-1 test |
| A device driver | `kernel/drivers/<class>/<device>/` |
| A new syscall | number in `include/abi/`, handler in `syscall/`, wrapper in `libc/` |
| A user program | `user/bin/<name>/` |
| A host-side build tool | `tools/<name>/` |
| A test of pure logic | `tests/unit/` |
| A test needing real hardware behaviour | `tests/kernel/` |
| A test of the whole system | `tests/integration/` |

---

## Naming conventions

- Files: `snake_case.cpp` / `.hpp`. Assembly: `snake_case.asm`.
- One subsystem per directory; a directory gets its own `CMakeLists.txt`.
- Headers that are internal to a subsystem live beside the source, not in
  `include/`. `include/kernel/` is for cross-subsystem interfaces only.
- Anything under `include/abi/` uses plain C types and is `extern "C"`-safe, because
  libc consumes it.

## Related

[[ADR-0008 - Monorepo Layout]] · [[08 - Build System]] · [[13 - Coding Standards]]

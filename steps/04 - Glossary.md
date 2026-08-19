# Glossary

Plain-language definitions for every term and acronym in this vault. When a stage
uses a word you do not know, look here first.

---

## Boot & toolchain

- **Bare metal** — running with no operating system underneath. Your kernel runs on
  bare metal (inside the emulator).
- **Cross-compiler** — a compiler that builds programs for a different target than
  the machine it runs on. You use `i686-elf-gcc` to build for a bare x86 machine.
- **Freestanding** — a C/C++ mode with no standard library and no OS services. You
  get the language, not `printf` or `malloc`. You build those yourself.
- **Target triple** — the string naming what you build for, like `i686-elf`
  (32-bit x86, ELF format, no OS).
- **ELF (Executable and Linkable Format)** — the file format for the kernel and,
  later, for user programs.
- **Linker script** — a file that tells the linker where each part of the kernel
  goes in memory. You write one in Phase 0.
- **GRUB** — a bootloader. Firmware loads GRUB, GRUB loads your kernel.
- **Multiboot** — a specification GRUB follows. If your kernel has a Multiboot
  header, GRUB can load it directly, so you skip writing a bootloader.
- **QEMU** — the emulator that runs your OS as if it were a real PC.
- **ISO** — a CD-image file. GRUB plus your kernel are packed into an ISO that QEMU
  boots.

## CPU & memory basics

- **x86 / i386 / IA-32** — the 32-bit Intel-compatible instruction set you target.
- **Register** — a tiny, fast storage slot inside the CPU (for example `eax`,
  `esp`). `esp` holds the stack pointer.
- **Real mode** — the CPU's 16-bit startup mode. Limited and old. GRUB leaves it
  for you.
- **Protected mode** — the 32-bit mode with memory protection and privilege rings.
  GRUB hands your kernel a machine already in protected mode.
- **Privilege ring** — a hardware privilege level. **Ring 0** is the kernel (full
  power). **Ring 3** is user programs (limited). Rings 1 and 2 go unused here.
- **Port I/O** — talking to hardware through special addresses with the `in` and
  `out` instructions, separate from normal memory.
- **MMIO (memory-mapped I/O)** — talking to hardware by reading and writing normal
  memory addresses. The VGA text buffer at `0xB8000` is an example.

## Tables the CPU reads

- **GDT (Global Descriptor Table)** — a table that defines memory segments and their
  privilege. The CPU requires it in protected mode.
- **Segment / segment selector** — an entry in the GDT and the small number that
  points at it. Loaded into segment registers like `cs` and `ds`.
- **IDT (Interrupt Descriptor Table)** — a table mapping each interrupt number to
  the function that handles it.
- **TSS (Task State Segment)** — a structure the CPU uses to find the kernel stack
  when a user program traps into the kernel. Needed for Ring 3.

## Interrupts

- **Interrupt** — a signal that makes the CPU stop and jump to a handler. It comes
  from hardware (a key press) or from software (`int`) or from a CPU fault.
- **Exception / fault** — an interrupt the CPU raises on an error, like divide by
  zero (vector 0) or page fault (vector 14).
- **ISR (Interrupt Service Routine)** — the function that handles an interrupt.
- **IRQ (Interrupt Request)** — a hardware interrupt line (keyboard is IRQ 1, the
  timer is IRQ 0).
- **PIC (8259 Programmable Interrupt Controller)** — the chip that routes IRQs to
  the CPU. You must *remap* it so its numbers do not collide with CPU exceptions.
- **PIT (Programmable Interval Timer)** — a chip that fires IRQ 0 at a rate you set.
  It is your system clock and your preemption source.
- **EOI (End Of Interrupt)** — the signal you send the PIC to say "handled, send the
  next one".

## Memory management

- **Physical address** — a real address in RAM.
- **Virtual address** — an address a program uses; paging maps it to a physical one.
- **Paging** — hardware that maps virtual pages to physical frames, one 4 KiB block
  at a time. It gives isolation and lets each program think it owns memory.
- **Page / frame** — a 4 KiB block. "Page" is the virtual block; "frame" is the
  physical block it maps to.
- **Page directory / page table** — the two-level tables the x86 MMU walks to
  translate an address.
- **Page fault** — the exception (vector 14) the CPU raises when a virtual address
  has no valid mapping.
- **Frame allocator** — your code that hands out free physical frames.
- **Heap** — the region your `kmalloc`/`free` manage for dynamic allocation.
- **Higher half** — a layout that maps the kernel into the top of every address
  space (for example at `0xC0000000`), so user and kernel can coexist.

## Processes & multitasking

- **Task / thread / process** — a unit of running work. In this guide a *task* has
  its own stack and CPU context; a *process* adds its own address space.
- **Context switch** — saving one task's registers and loading another's, so the CPU
  runs a different task.
- **Scheduler** — the code that picks which task runs next.
- **Preemption** — the timer interrupting a task to force a switch, so no task can
  hog the CPU.
- **System call (syscall)** — the controlled doorway a user program uses to ask the
  kernel for a service (write, read, exit). Made with a software interrupt or a
  special instruction.

## Filesystem

- **initrd / ramdisk** — a filesystem image loaded into RAM at boot, given to you by
  GRUB as a Multiboot *module*. Your first filesystem.
- **VFS (Virtual File System)** — a layer that gives one `open`/`read`/`write`
  interface over different filesystems.
- **inode** — a filesystem's record of one file (its size, location, type).
- **USTAR / tar** — a simple archive format, easy to use as a read-only filesystem.

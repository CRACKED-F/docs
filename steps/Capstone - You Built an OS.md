# Capstone — You Built an OS

If you reached this note by finishing **[[Phase 8 - Overview|Phase 8]]**, you built a
real operating system in C++ from an empty folder. Take a moment. Most developers
never do this.

---

## What you have

- A kernel GRUB boots on bare x86, written by you.
- Screen and serial output with a `kprintf`.
- A CPU that handles faults and hardware interrupts.
- Timer and keyboard drivers.
- Physical and virtual memory management with a heap.
- A preemptive multitasking scheduler.
- A user/kernel privilege boundary with system calls.
- A filesystem and an ELF program loader.
- An interactive shell that runs your programs.

That is the full stack of a small operating system.

---

## Where to go next

Pick what interests you. Each is a new mini-project on the base you built.

- **A real disk driver and filesystem.** Replace the ramdisk: write an ATA/AHCI
  driver and a writable filesystem (FAT, ext2, or your own). Start:
  <https://wiki.osdev.org/ATA_PIO_Mode> · <https://wiki.osdev.org/FAT>
- **A proper `fork` with copy-on-write.** Make process creation cheap. See OSTEP's
  paging chapters and <https://wiki.osdev.org/Fork>.
- **Inter-process communication.** Pipes and signals, so programs can talk. Then the
  shell can do `a | b`.
- **A graphics mode and a window server.** Leave text mode for a framebuffer (VESA/VBE
  or GOP). <https://wiki.osdev.org/Getting_VBE_Mode_Info>
- **The network stack.** An e1000 driver, then ARP/IP/UDP/TCP.
  <https://wiki.osdev.org/Network_Stack>
- **Port to 64-bit (x86_64).** Long mode, 4-level paging, the SysV calling
  convention. A big but well-trodden step.
- **Port to real hardware.** Boot your ISO on an old PC or a USB stick, not just
  QEMU. Expect new bugs the emulator hid.

---

## Recommended deeper study

- **MIT 6.1810 / 6.S081** — the labs turn a reader into an OS engineer:
  <https://pdos.csail.mit.edu/6.828/>
- **OSTEP** — reread the chapters now that you have implemented them; they read
  differently: <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- **Reference hobby OSes** — study how larger systems structure the same ideas:
  ToaruOS <https://github.com/klange/toaruos>, SerenityOS
  <https://github.com/SerenityOS/serenity>, SkiftOS
  <https://github.com/skift-org/skift>.

See **[[03 - Resources and Reading]]** for the full list.

---

## A last note

Keep the Git history. The commit where the white `A` first appeared, and the one
where the shell first echoed a line, are worth looking back on. You learned how a
computer really works — from the first instruction after power-on to a program you can
talk to.

Back to **[[00 - Start Here]]**.

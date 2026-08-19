# Resources & Reading

The master list. Each phase note links to the exact pages you need, but this note
is the place to browse and to bookmark. Start with the **core four**, then use the
rest as reference.

> **How to read these.** The OSDev wiki is a reference, not a course — it assumes
> you know why you are there. Read a book chapter or tutorial *first* for the story,
> then use the wiki for the exact bytes. Reference implementations show you working
> code when words are not enough.

---

## The core four (read these no matter what)

- **OSDev Wiki** — the central reference for everything in this guide.
  <https://wiki.osdev.org>
  Start with **Bare Bones** and **Meaty Skeleton**:
  <https://wiki.osdev.org/Bare_Bones> · <https://wiki.osdev.org/Meaty_Skeleton>
- **The Little OS Book** — a free, beginner book that builds a 32-bit x86 kernel in
  almost the exact order this guide uses. Your best single companion.
  <https://littleosbook.github.io>
- **Operating Systems: Three Easy Pieces (OSTEP)** — a free university textbook for
  the *concepts* (processes, scheduling, virtual memory, filesystems). Read the
  matching chapter before each theory-heavy phase.
  <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- **OSDev — Beginner Mistakes** — read this now and again after Phase 2. It will
  save you days.
  <https://wiki.osdev.org/Beginner_Mistakes>

---

## Toolchain & environment

- OSDev — *Why do I need a Cross Compiler?* <https://wiki.osdev.org/Why_do_I_need_a_Cross_Compiler%3F>
- OSDev — *GCC Cross-Compiler* (build it from source) <https://wiki.osdev.org/GCC_Cross-Compiler>
- OSDev — *Cross-Compiler Successful Build Test* <https://wiki.osdev.org/Bare_Bones#Building_a_Cross-Compiler>
- OSDev — *C++* (freestanding C++ in a kernel) <https://wiki.osdev.org/C++>
- OSDev — *Calling Global Constructors* <https://wiki.osdev.org/Calling_Global_Constructors>

## Booting & Multiboot

- Multiboot Specification (what GRUB expects) <https://www.gnu.org/software/grub/manual/multiboot/multiboot.html>
- OSDev — *Multiboot* <https://wiki.osdev.org/Multiboot>
- OSDev — *GRUB* <https://wiki.osdev.org/GRUB>
- Nick Blundell — *Writing a Simple Operating System from Scratch* (real-mode boot,
  read even though we use GRUB — it explains what GRUB does for you).
  <https://www.cs.bham.ac.uk/~exr/lectures/opsys/10_11/lectures/os-dev.pdf>

## Screen, serial & drivers

- OSDev — *Printing To Screen* / *VGA Hardware* <https://wiki.osdev.org/Printing_to_Screen> · <https://wiki.osdev.org/VGA_Hardware>
- OSDev — *Serial Ports* <https://wiki.osdev.org/Serial_Ports>
- OSDev — *"8259 PIC"* <https://wiki.osdev.org/8259_PIC>
- OSDev — *Programmable Interval Timer (PIT)* <https://wiki.osdev.org/Programmable_Interval_Timer>
- OSDev — *PS/2 Keyboard* <https://wiki.osdev.org/PS/2_Keyboard>

## CPU tables & interrupts

- OSDev — *Global Descriptor Table (GDT)* <https://wiki.osdev.org/Global_Descriptor_Table>
- OSDev — *GDT Tutorial* <https://wiki.osdev.org/GDT_Tutorial>
- OSDev — *Interrupt Descriptor Table (IDT)* <https://wiki.osdev.org/Interrupt_Descriptor_Table>
- OSDev — *Interrupts* / *Interrupt Service Routines* <https://wiki.osdev.org/Interrupts> · <https://wiki.osdev.org/Interrupt_Service_Routines>
- OSDev — *Exceptions* (the CPU fault list) <https://wiki.osdev.org/Exceptions>

## Memory management

- OSTEP — *Virtual Memory* chapters (address spaces, paging) <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *Detecting Memory (x86)* / the Multiboot memory map <https://wiki.osdev.org/Detecting_Memory_(x86)>
- OSDev — *Paging* <https://wiki.osdev.org/Paging>
- OSDev — *Setting Up Paging* <https://wiki.osdev.org/Setting_Up_Paging>
- OSDev — *Higher Half Kernel* <https://wiki.osdev.org/Higher_Half_Kernel>
- OSDev — *Writing a memory manager* / *Page Frame Allocation* <https://wiki.osdev.org/Page_Frame_Allocation>

## Multitasking, user mode & syscalls

- OSTEP — *Processes*, *Scheduling* chapters <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *Kernel Multitasking* / *Brendan's Multi-tasking Tutorial* <https://wiki.osdev.org/Multitasking_Systems>
- OSDev — *Task State Segment (TSS)* <https://wiki.osdev.org/Task_State_Segment>
- OSDev — *Getting to Ring 3* <https://wiki.osdev.org/Getting_to_Ring_3>
- OSDev — *System Calls* <https://wiki.osdev.org/System_Calls>

## Filesystem & program loading

- OSTEP — *File Systems* chapters <https://pages.cs.wisc.edu/~remzi/OSTEP/>
- OSDev — *VFS* (virtual filesystem) <https://wiki.osdev.org/VFS>
- OSDev — *USTAR* / tar-based initrd <https://wiki.osdev.org/USTAR>
- OSDev — *ELF* and *ELF Tutorial* (load and run programs) <https://wiki.osdev.org/ELF> · <https://wiki.osdev.org/ELF_Tutorial>

---

## Full tutorials (follow one end-to-end alongside this guide)

- **JamesM's Kernel Development Tutorial** — the classic C walk-through that this
  roadmap's middle phases mirror. Note: it has known bugs; read the errata.
  <http://www.jamesmolloy.co.uk/tutorial_html/> · errata:
  <https://wiki.osdev.org/James_Molloy's_Tutorial_Known_Bugs>
- **cfenollosa/os-tutorial** — a clean, staged GitHub tutorial, one folder per step.
  Excellent to compare your progress against. <https://github.com/cfenollosa/os-tutorial>
- **Bran's Kernel Development Tutorial** — older, but the GDT/IDT chapters are still
  widely referenced. <http://www.osdever.net/bkerndev/Docs/title.htm>
- **Writing an OS in Rust** by Philipp Oppermann — Rust, not C++, but the *best*
  written explanations of Multiboot, VGA, interrupts, and paging anywhere. Read for
  understanding, translate the code. <https://os.phil-opp.com>

## Reference implementations (read working code when stuck)

- **xv6** (MIT teaching OS) — small, clean, heavily commented. The gold standard for
  learning. RISC-V version: <https://github.com/mit-pdos/xv6-riscv> · x86 version:
  <https://github.com/mit-pdos/xv6-public>
- **cfenollosa/os-tutorial** kernel — matches this guide's early phases.
- **ToaruOS** — a complete hobby OS with a shell and GUI, for when you want to see
  how the pieces fit at scale. <https://github.com/klange/toaruos>
- **SkiftOS** — a modern C++ hobby OS. <https://github.com/skift-org/skift>

## Course

- **MIT 6.1810 / 6.S081 — Operating System Engineering** — free lectures, labs, and
  the xv6 book. The most structured way to go deeper. <https://pdos.csail.mit.edu/6.828/>

---

## Debugging

- OSDev — *Kernel Debugging* <https://wiki.osdev.org/Kernel_Debugging>
- QEMU monitor (dump registers, memory): press `Ctrl-Alt-2` in QEMU, or read
  <https://qemu-project.gitlab.io/qemu/system/monitor.html>
- GDB attached to QEMU (`qemu ... -s -S`, then `target remote :1234`):
  <https://wiki.osdev.org/Kernel_Debugging#Use_a_Serial_Port_and_GDB>
- **Bochs** — a slower emulator with a built-in debugger that understands x86
  descriptor tables. Priceless for GDT/IDT/paging bugs. <https://bochs.sourceforge.io>

## Reference manuals (look up, do not read cover to cover)

- Intel 64 & IA-32 Architectures Software Developer Manuals (the ground truth for
  every instruction and table) <https://www.intel.com/sdm>
- felixcloutier x86 instruction reference (fast lookup) <https://www.felixcloutier.com/x86/>
- NASM manual <https://www.nasm.us/docs.php>
- Paul Carter — *PC Assembly Language* (learn x86 assembly from zero)
  <https://pacman128.github.io/pcasm/>

---

## Suggested reading order

1. **Before Phase 0:** OSDev *Bare Bones*, *Why do I need a Cross Compiler?*, and
   the *Beginner Mistakes* page.
2. **Phases 1–3:** The Little OS Book, chapters 1–7. cfenollosa/os-tutorial in
   parallel.
3. **Phase 4:** OSTEP virtual-memory chapters, then OSDev *Paging* and *Setting Up
   Paging*.
4. **Phases 5–6:** OSTEP process/scheduling chapters, OSDev *Getting to Ring 3*.
5. **Phases 7–8:** OSTEP filesystem chapters, OSDev *VFS* and *ELF*.

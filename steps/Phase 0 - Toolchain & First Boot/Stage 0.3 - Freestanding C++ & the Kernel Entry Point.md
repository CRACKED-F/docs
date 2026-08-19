# Stage 0.3 — Freestanding C++ & the Kernel Entry Point

**Difficulty:** Medium · ~30 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

GRUB jumps to a single assembly entry point, not to C++. Assembly must do two small
jobs first, then call your C++.

1. **Set up a stack.** C++ needs a stack for local variables and calls. GRUB does
   not give you a reliable one, so you reserve a block of memory and point `esp` at
   its top.
2. **Call `kernel_main`.** After the stack is ready, jump into C++.

"Freestanding C++" means the language without its usual runtime: no standard
library, no `new`/`delete` yet, no exceptions, no `std::`. You still get classes,
templates, and functions. You will build the missing pieces (like memory
allocation) yourself in later phases.

---

## Specification

- The stack grows **downward** on x86. Reserve, say, 16 KiB in the `.bss` section
  and set `esp` to the **top** (highest address) of that block.
- The C++ entry is `extern "C" void kernel_main(void)`. The `extern "C"` stops C++
  name mangling so assembly can call the plain symbol name.
- Compile C++ with, at minimum:
  `-ffreestanding -fno-exceptions -fno-rtti -nostdlib -m32`.
- After `kernel_main` returns, the assembly must not "fall off the end". Disable
  interrupts (`cli`) and halt in a loop (`hlt`) so the CPU stops cleanly.

---

## Your task

1. In `boot.asm`, below the Multiboot header, reserve a stack in `.bss` and add a
   global `_start` label (this is GRUB's entry point).
2. In `_start`: set `esp` to the top of the reserved stack.
3. `call kernel_main`.
4. After the call returns, run `cli`, then an infinite `hlt` loop.
5. Create `kernel.cpp` with `extern "C" void kernel_main(void) { }` (empty for now).
6. As proof of life, have `kernel_main` write one byte directly to video memory:
   store the value `0x0F41` (white 'A') at address `0xB8000`. This is the crudest
   possible "we reached C++".
7. Compile `kernel.cpp` with the freestanding flags into `kernel.o`.

---

## How to verify

You cannot boot yet — the linker script (Stage 0.4) comes next. For now:

- `kernel.cpp` compiles with the freestanding flags and **no** warnings about a
  missing library or `main`.
- `nm kernel.o` lists `kernel_main` as a defined symbol (`T kernel_main`).
- The full boot test happens at the end of Stage 0.4: you should see a single white
  `A` in the top-left corner of the QEMU window.

---

## Common traps

- **No stack.** If you call C++ before setting `esp`, the first push corrupts memory
  and the machine triple-faults (QEMU reboots in a loop).
- **Name mangling.** Without `extern "C"`, the C++ symbol is something like
  `_Z11kernel_mainv` and assembly's `call kernel_main` finds nothing at link time.
- **Global objects.** C++ objects with constructors at global scope will not run
  their constructors unless you call them. Avoid global objects for now; see OSDev
  *Calling Global Constructors* when you need them.
- Forgetting `-m32` builds a 64-bit object that will not link into the 32-bit
  kernel.

---

## Reading

- OSDev — *Bare Bones* (entry point and stack): <https://wiki.osdev.org/Bare_Bones>
- OSDev — *C++* (which language features are safe): <https://wiki.osdev.org/C++>
- OSDev — *Calling Global Constructors*:
  <https://wiki.osdev.org/Calling_Global_Constructors>

Next: **[[Stage 0.4 - The Linker Script & Booting with QEMU]]**.

# Stage 0.6 — The Makefile & Build-Run Loop

**Difficulty:** Easy · ~20 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

You will build and boot hundreds of times. Typing the compile, link, ISO, and QEMU
commands by hand is slow and — worse — a typo in a flag looks exactly like an OS bug.
A `Makefile` turns the whole loop into `make run`. This is not busywork: a reliable
build is the difference between debugging your kernel and debugging your commands.

---

## Specification

A minimal `Makefile` has:

- Variables for the tools (`CC = i686-elf-gcc`, `AS = nasm`) and flags
  (`CFLAGS = -ffreestanding -fno-exceptions -fno-rtti -m32 -Wall -Wextra`).
- A rule to assemble `boot.asm` → `boot.o`.
- A pattern rule to compile each `.cpp` → `.o`.
- A rule to link all `.o` into `mykernel.bin` with the linker script.
- An `iso` rule that stages `isodir` and runs `grub-mkrescue`.
- A `run` rule that depends on the ISO and launches QEMU.
- A `clean` rule.

Add a debug target while you are here:

```
run-serial: os.iso
    qemu-system-i386 -cdrom os.iso -serial stdio

debug: os.iso
    qemu-system-i386 -cdrom os.iso -s -S &   # waits for GDB on :1234
```

---

## Your task

1. Write a `Makefile` with variables for `CC`, `AS`, `CFLAGS`, `ASFLAGS`.
2. Add rules for: assemble, compile (`%.o: %.cpp`), link, `iso`, `run`, `clean`.
3. Add `run-serial` (routes the serial port to your terminal — you will need it in
   **[[Phase 1 - Overview|Phase 1]]**) and `debug` (waits for GDB).
4. Run `make run` and confirm the white `A` appears.
5. Commit everything to Git. Tag or note this as your first known-good build.

---

## How to verify

- `make` rebuilds only what changed and links `mykernel.bin`.
- `make run` boots to the white `A` with one command.
- `make clean` removes all build products.
- `git status` is clean after a commit. From now on, commit after every green stage.

---

## Common traps

- **Makefiles need tabs, not spaces**, to indent recipe lines. A space gives
  "missing separator".
- Not listing header dependencies, so edits to a `.h` do not trigger a rebuild. For
  now, `make clean && make` when in doubt; add proper dependencies later.
- Hardcoding one `.cpp` file. Use a wildcard (`wildcard *.cpp`) so new files build
  automatically as your kernel grows.

---

## Reading

- OSDev — *Meaty Skeleton* (a fuller project layout and Makefile to grow into):
  <https://wiki.osdev.org/Meaty_Skeleton>
- GNU Make manual: <https://www.gnu.org/software/make/manual/make.html>

---

## Phase 0 is complete

You have a reproducible build, a kernel GRUB boots, and proof your C++ runs. Commit,
then move to text output.

Next phase: **[[Phase 1 - Overview]]**.

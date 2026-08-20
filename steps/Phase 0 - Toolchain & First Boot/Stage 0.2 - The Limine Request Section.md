# Stage 0.2 — The Limine Request Section

**Difficulty:** Easy · ~30 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

Firmware loads Limine. Limine then needs to recognise *your* kernel as something it
can load, and it needs to know what services you want from it.

The **Limine boot protocol** works differently from Multiboot. Instead of a single
magic header, you place **request structures** in your kernel binary. Each request is
a struct with a unique 128-bit ID. Limine scans the kernel for them, and for each one
it recognises it fills in a **response** pointer before jumping to your entry point.

The model is: *you declare what you want; the bootloader provides it and tells you
where it put it.*

This is more pleasant than Multiboot's fixed info structure, because you ask only for
what you need and each response is a typed struct rather than an offset into a flags
word.

---

## Specification

Every request is a global with `__attribute__((used, section(".limine_requests")))`
so the linker keeps it and places it where Limine can find it.

Requests you need in Phase 0:

| Request | Gives you | Needed by |
|---|---|---|
| `LIMINE_BASE_REVISION` | Protocol version negotiation | always |
| `limine_framebuffer_request` | Base, width, height, pitch, bpp | [[Phase 1 - Overview\|Phase 1]] |
| `limine_memmap_request` | The memory map | [[Phase 4 - Overview\|Phase 4]] |
| `limine_hhdm_request` | Higher-half direct map offset | [[Phase 4 - Overview\|Phase 4]] |
| `limine_kernel_address_request` | Physical and virtual kernel base | Stage 1.7 (backtraces) |
| `limine_module_request` | Loaded modules — our initrd | [[Phase 7 - Overview\|Phase 7]] |
| `limine_rsdp_request` | ACPI RSDP pointer | [[Phase 11 - Overview\|Phase 11]] |

Also required by the protocol:

- A **start marker** and **end marker** around the requests, so Limine can bound its
  scan.
- The `.limine_requests` section must survive linking — the linker script in
  Stage 0.6 keeps it explicitly.
- The kernel entry point is a plain `extern "C" void kmain(void)` taking **no
  arguments**. Everything arrives through the response pointers, not registers.

**When Limine jumps to `kmain`, the CPU is already in 64-bit long mode with paging
enabled and interrupts disabled.** You do not write a long-mode trampoline. See
[[ADR-0003 - Limine as the Bootloader]].

---

## Your task

1. Vendor `limine.h` from the pinned Limine release into
   `kernel/arch/x86_64/boot/`. **Only this directory may include it** — that boundary
   is enforced by CI, and it is what keeps the escape hatch in ADR-0003 real.
2. Create `kernel/arch/x86_64/boot/entry.cpp`.
3. Declare the base revision marker and the start/end request markers.
4. Declare the seven requests above as `volatile` globals in the `.limine_requests`
   section. (`volatile` here is correct — the bootloader writes them behind the
   compiler's back. This is the MMIO-shaped exception in
   [[13 - Coding Standards]] rule 3.)
5. Write `extern "C" void kmain(void)` that, for now, halts: `for (;;) asm("hlt");`
6. Compile it. You cannot link or boot yet — the linker script is Stage 0.6.

---

## How to verify

You cannot boot yet. What you can check:

- It compiles with the kernel flags from Stage 0.1, with no warnings.
- `x86_64-elf-nm entry.o` lists `kmain` as a defined text symbol (`T kmain`).
- `x86_64-elf-objdump -h entry.o` shows a `.limine_requests` section that is **not
  empty**. If it is missing, the `used` attribute or the section name is wrong and
  Limine will silently ignore every request.

Full verification happens at the end of Stage 0.7, when the image boots.

---

## Common traps

- **Forgetting `__attribute__((used))`.** The optimiser sees a global nobody reads,
  removes it, and Limine finds no requests. The kernel then boots with every response
  pointer null, and you get a page fault at address zero with no obvious cause.
- **Checking a response before checking it is non-null.** If Limine did not honour a
  request — wrong protocol revision, or an older bootloader — the response pointer is
  `nullptr`. **Every response must be null-checked**, and the failure path must say so
  over serial rather than dereferencing it.
- **Omitting the start/end markers.** Limine needs them to bound the scan.
- **Expecting Multiboot.** `mbi`, `mods_addr`, magic `0x2BADB002` — none of that
  exists here. Tutorials that parse the Multiboot info structure do not apply.
- **Putting `limine.h` anywhere else.** CI fails the build. The point is that
  swapping bootloaders should mean rewriting one file, not auditing the tree.

---

## The trap that bites later

Limine's response structures live in **bootloader-reclaimable memory**. That memory
is yours to reuse — and in [[Phase 4 - Overview|Phase 4]] the physical memory manager
*will* reclaim it.

**Everything you need must be copied out of the responses into your own `boot_info_t`
before then.** A pointer into a reclaimed response works fine for several phases and
then starts returning garbage, long after the mistake. Copy at boot, in Stage 0.3, and
never keep a Limine pointer.

---

## Reading

- **Limine protocol specification** — read the whole thing once; it is short:
  <https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md>
- OSDev — *Limine Bare Bones*: <https://wiki.osdev.org/Limine_Bare_Bones>
- [[ADR-0003 - Limine as the Bootloader]]

Next: **Stage 0.3 - Freestanding C++ and kmain**

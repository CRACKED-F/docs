# Stage 0.3 — Freestanding C++ and `kmain`

**Difficulty:** Medium · ~45 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]

---

## Concept

"Freestanding C++" means the language without its usual runtime: no standard library,
no `new`/`delete` yet, no exceptions, no `std::` containers. You still get classes,
templates, references, `constexpr`, and namespaces — the parts that make C++ worth
using in a kernel.

This stage does two things. It establishes what is and is not legal C++ in kernel
context, and it captures everything Limine told us into **our own struct**, so that
nothing outside `kernel/arch/x86_64/boot/` ever touches a Limine type.

That second part is the more important one. It is the escape hatch from
[[ADR-0003 - Limine as the Bootloader]] made real, and it is the fix for the
reclaimed-memory trap from Stage 0.2.

---

## Specification

### The legal C++ subset

Fully specified in [[ADR-0007 - Freestanding C++20 as the Kernel Language]]. In short:

**Banned:** exceptions, RTTI, the standard library, floating point/SSE, global objects
with non-trivial constructors.

**Encouraged:** classes, references, templates, `constexpr`, `enum class`,
`[[nodiscard]]`, and the header-only freestanding `std::` headers (`<cstdint>`,
`<cstddef>`, `<type_traits>`, `<bit>`, `<atomic>`).

`operator new` is **deliberately not provided** until [[Phase 4 - Overview|Phase 4]]
supplies a heap. Using it is a link error by design, so the mistake is caught at build
time rather than at runtime.

### `boot_info_t`

A plain struct in `kernel/include/kernel/boot_info.hpp`, containing **copies** — never
pointers into bootloader memory:

```cpp
struct BootInfo {
    // Framebuffer
    uintptr_t fb_addr;
    uint64_t  fb_width, fb_height, fb_pitch;
    uint16_t  fb_bpp;
    uint8_t   fb_red_shift, fb_green_shift, fb_blue_shift;

    // Memory
    MemoryRegion regions[MAX_REGIONS];   // copied, not referenced
    size_t       region_count;
    uintptr_t    hhdm_offset;

    // Kernel placement (needed to symbolise a backtrace)
    uintptr_t kernel_phys_base, kernel_virt_base;

    // Modules — the initrd
    Module modules[MAX_MODULES];
    size_t module_count;

    // ACPI
    uintptr_t rsdp_addr;
};
```

Module *contents* stay where they are — they can be large — but the descriptors are
copied, and the ranges are reserved in Phase 4 so the allocator never hands them out.

### Stack

Limine gives you a valid stack, so unlike the 32-bit path you do **not** need to set
one up before calling C++. You will define your own kernel stack with a **guard page**
in Stage 0.6, once the linker script exists.

---

## Your task

1. Define `BootInfo`, `MemoryRegion`, and `Module` in
   `kernel/include/kernel/boot_info.hpp`. Plain types only — no Limine types.
2. In `kernel/arch/x86_64/boot/boot_info.cpp`, write
   `BootInfo* collect_boot_info()` that:
   - null-checks **every** Limine response,
   - copies each field into a statically allocated `BootInfo`,
   - copies the memory map entries into the array,
   - returns a pointer to it.
3. Make the failure path loud: if a required response is null, halt with a distinct
   pattern. You cannot print yet — Stage 0.4 fixes that — so for now write a
   recognisable value to a register and `hlt`, and note which check failed.
4. In `kmain`, call `collect_boot_info()`, then `kernel_init(info)`.
5. Create `kernel/main.cpp` with `void kernel_init(BootInfo*)`, empty for now. **This
   file must not include `limine.h`** — that is the boundary, and CI checks it.
6. Ensure `kmain` never returns. If `kernel_init` returns, disable interrupts and halt
   in a loop.

---

## How to verify

- Everything compiles with the kernel flags, no warnings, `-Werror` clean.
- `grep -rn "limine" kernel/ --include='*.cpp' | grep -v arch/x86_64/boot/` returns
  nothing. This is the CI rule; check it locally now.
- `x86_64-elf-nm kernel/main.o` shows `kernel_init` defined and no Limine symbols.
- The full boot test is at the end of Stage 0.7.

---

## Common traps

- **Storing a Limine pointer instead of copying.** The single most consequential
  mistake in this stage. Limine's responses sit in bootloader-reclaimable memory, and
  [[Phase 4 - Overview|Phase 4]] will reclaim it. The pointer keeps working for
  several phases, then starts returning garbage — with nothing in the diff to
  suggest why. **Copy everything.**
- **Not null-checking a response.** An unhonoured request leaves a null pointer, and
  dereferencing it before the IDT exists ([[Phase 2 - Overview|Phase 2]]) triple-faults
  with no diagnostic at all.
- **Name mangling.** `kmain` needs `extern "C"`, or the symbol is `_Z5kmainv` and the
  linker script's `ENTRY(kmain)` finds nothing.
- **A global with a constructor.** `static Console g_console;` will not run its
  constructor — nothing has called the `.init_array` entries yet, and the heap does
  not exist. Use explicit `init()` functions in the documented order from
  [[06 - Architecture Overview]].
- **Assuming the memory map is sorted or contiguous.** It is neither. Treat it as an
  unordered list of ranges.

---

## Reading

- OSDev — *C++* (which language features are safe): <https://wiki.osdev.org/C++>
- OSDev — *Calling Global Constructors*:
  <https://wiki.osdev.org/Calling_Global_Constructors>
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]]
- [[06 - Architecture Overview]] — the initialisation order this feeds into

Next: **Stage 0.4 - Serial Output First**

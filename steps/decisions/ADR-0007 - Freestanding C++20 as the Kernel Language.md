# ADR-0007 — Freestanding C++20 as the kernel language

**Status:** Accepted · **Date:** 2026-08-20

---

## Context

The v1 vault said "C++" without saying *which* C++ or which subset is legal in
kernel context. That ambiguity is dangerous: C++ has language features that silently
require a runtime the kernel does not have, and the failure mode is a link error at
best or a mysterious fault at worst.

## Decision

**Freestanding C++20**, compiled with `-std=c++20 -ffreestanding`.

### Banned outright in kernel context

| Feature | Flag | Why |
|---|---|---|
| Exceptions | `-fno-exceptions` | Requires unwinder + heap; unusable in an interrupt handler |
| RTTI / `dynamic_cast` | `-fno-rtti` | Requires runtime type tables |
| The standard library | `-nostdlib` | Assumes an OS underneath |
| Floating point / SSE | `-mno-sse -mno-mmx -mno-80387` | Would require FPU state save on every context switch |
| The red zone | `-mno-red-zone` | Interrupts corrupt it — see [[ADR-0002 - Target x86_64 Not i686]] |
| Global objects with non-trivial constructors | convention | Constructor order is undefined and they run before the heap exists |
| Threads, `std::` anything | `-nostdlib` | No runtime |

### Allowed and encouraged

- Classes, references, namespaces, `enum class`
- Templates and `constexpr` — zero runtime cost, real type safety
- `constexpr` / `consteval` for compile-time table generation (GDT, IDT, page flags)
- `[[nodiscard]]`, `[[maybe_unused]]`, `static_assert`
- Concepts, for readable template constraints
- `std::` types from **freestanding-safe headers only**: `<cstdint>`, `<cstddef>`,
  `<type_traits>`, `<limits>`, `<utility>`, `<bit>`, `<concepts>`, `<atomic>`.
  These are header-only and require no runtime.
- Our own `kstd::` namespace for kernel-safe containers (`kstd::vector`,
  `kstd::optional`, `kstd::span`) once the heap exists in Phase 4.

### Assembly

NASM (Intel syntax) for standalone `.asm` files: boot trampoline, interrupt stubs,
context switch. GCC inline assembly for one-to-three-instruction operations
(`outb`, `inb`, `lgdt`, `invlpg`) wrapped in `inline` functions in `kernel/arch/`.

**Every inline `asm` block must have a correct clobber list.** An omitted clobber is
undefined behaviour that the optimiser will eventually exploit, usually months later.

### `operator new` / `delete`

Not available until Phase 4 provides the heap. Before that, any use is a link error
by design — we deliberately do **not** provide a stub, so misuse is caught at build
time rather than at runtime.

## Consequences

- Compiler flags are non-negotiable and enforced in `cmake/KernelFlags.cmake`. CI
  fails the build if any are missing — a grep test, because forgetting
  `-mno-red-zone` on one translation unit is both easy and devastating.
- Global constructors are not called unless we call them. We do run them, but only
  **after** the heap and console exist, from `kernel_init()` walking `.init_array`.
  Objects that need earlier initialisation use explicit `init()` functions.
- Userspace is **not** bound by these rules. User programs link against our libc
  ([[Phase 6 - Overview]]) and may use exceptions once we implement unwinding —
  which is post-v1.
- C++20 modules are **not** used. Toolchain support in a cross-compiled freestanding
  context is not mature enough to bet on.

## Alternatives rejected

- **C99/C11.** Simpler, and what most tutorials use. Rejected: we lose `constexpr`
  table generation, type-safe enums, RAII for lock guards (which genuinely prevents
  deadlock bugs in Phase 12), and templates for the container types the kernel needs
  from Phase 4 onward.
- **Rust.** Excellent fit technically — the borrow checker prevents exactly the
  memory bugs that dominate kernel debugging. Rejected on the same grounds as Nix in
  [[ADR-0005 - Containerised Pinned Toolchain]]: neither member knows it, and the
  learning curve competes with the project. This is the strongest rejected
  alternative and worth revisiting if C++ memory bugs become the dominant time sink.
- **Zig.** Interesting, excellent cross-compilation story, but a smaller ecosystem
  and a moving language spec.

## Related

[[ADR-0002 - Target x86_64 Not i686]] · [[13 - Coding Standards]]

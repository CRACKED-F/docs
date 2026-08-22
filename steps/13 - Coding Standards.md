# Coding Standards

Rules that prevent specific kernel bugs. Style questions that do not prevent bugs are
delegated to `clang-format` and are not worth discussing.

Language subset is decided in [[ADR-0007 - Freestanding C++20 as the Kernel Language]].

---

## Formatting — not a discussion

`.clang-format` is the standard. `make fmt` applies it, CI enforces it. There is no
style debate because the file decides. Based on LLVM style with a 100-column limit
and 4-space indent.

---

## The rules that matter

### 1. Fixed-width integer types everywhere

```cpp
uint64_t phys_addr;    // yes
unsigned long addr;    // no — size is not guaranteed
```

Use `uintptr_t` for anything that holds an address, `size_t` for sizes.

**Distinguish physical from virtual addresses in the type system:**

```cpp
struct PhysAddr { uint64_t value; };
struct VirtAddr { uint64_t value; };
```

Confusing the two is one of the most common and most confusing kernel bugs — it is
also one the compiler can catch for free if you let it.

### 2. Every `asm` block has a complete clobber list

```cpp
// yes
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" :: "a"(val), "Nd"(port) : "memory");
}

// no — missing "memory", compiler may reorder around it
__asm__ volatile("outb %0, %1" :: "a"(val), "Nd"(port));
```

An omitted clobber is undefined behaviour the optimiser will eventually exploit —
typically months later, after an unrelated change alters inlining. Assume every
`asm` that touches hardware needs `"memory"`.

### 3. Volatile is for MMIO, never for concurrency

```cpp
volatile uint32_t* reg = ...;      // yes — MMIO register
volatile bool flag;                // NO — use std::atomic<bool>
```

`volatile` does not provide atomicity or ordering. Using it for shared state between
tasks or cores is a race that works until it does not.

### 4. Lock discipline

```cpp
{
    IrqLockGuard guard(sched_lock);   // RAII: saves IRQ state, restores on scope exit
    // ...
}                                     // released even on early return
```

- **Never** take a lock without RAII. Manual `lock()`/`unlock()` pairs leak on early
  return, and early returns get added later by someone who did not notice.
- **Never** take a lock in an order not documented in `kernel/sched/locks.md`. Every
  lock has a rank; taking a lower rank while holding a higher one is a deadlock and
  is `KASSERT`ed in debug builds.
- A lock shared with an interrupt handler **must** be IRQ-save, or the handler can
  interrupt the holder and spin forever on a lock the same CPU owns.
- **Never sleep while holding a spinlock.** No `kmalloc` (it can grow the heap), no
  I/O, no blocking.

### 5. Every user pointer is validated before use

```cpp
// The most security-critical pattern in the kernel.
if (!validate_user_ptr(buf, len, ACCESS_WRITE))
    return -EFAULT;
```

Checks: canonical address, entirely below the user ceiling, mapped, and correct
permission. A missing check here is a complete kernel compromise — a user program
hands the kernel a kernel-space pointer and the kernel obligingly writes to it.

Never dereference a user pointer directly. Use `copy_from_user` / `copy_to_user`,
which validate and handle a fault mid-copy.

### 6. Errors are returned, never ignored

```cpp
[[nodiscard]] int vfs_read(File*, void*, size_t);
```

Mark every fallible function `[[nodiscard]]`. Negative errno on failure, Linux-style.
`-Werror` turns an ignored result into a build failure.

The kernel has no exceptions ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]),
so an unchecked return is a silently-corrupted system.

### 7. `KASSERT` for invariants, error returns for conditions

```cpp
KASSERT(is_aligned(addr, PAGE_SIZE));   // a bug if false — panic
if (!page_exists(addr)) return -EFAULT;  // can legitimately happen — return
```

Assert what must be true by construction. Return errors for what the outside world
can cause. Asserting on user input turns a user bug into a kernel panic; returning an
error for a broken invariant hides the bug until it does more damage.

`KASSERT` is compiled out in release builds. `KASSERT_ALWAYS` is not — use it where
the check is cheap and the consequence of proceeding is corruption.

### 8. No magic numbers in hardware code

```cpp
constexpr uint64_t PTE_PRESENT  = 1ULL << 0;
constexpr uint64_t PTE_WRITABLE = 1ULL << 1;
constexpr uint64_t PTE_USER     = 1ULL << 2;
constexpr uint64_t PTE_NX       = 1ULL << 63;
```

Every constant carries a comment citing the manual section it came from. When a bit
is wrong, the only way to check is against the specification, and you will not
remember which one.

### 9. No global objects with constructors

```cpp
Scheduler g_sched;                    // NO — runs before the heap exists
Scheduler& scheduler() {              // yes — explicit init
    static Scheduler* s = nullptr;
    return *s;
}
```

Constructor order across translation units is undefined, and all of it runs before
the heap exists. Use explicit `init()` called in the documented order from
[[06 - Architecture Overview]].

### 10. Comments explain why, not what

```cpp
// Reload CR3 to flush the TLB. invlpg would be faster but is not
// safe here: we may have changed a PDPT entry, which invalidates
// more than one page. Intel SDM Vol 3, 4.10.4.1.
write_cr3(read_cr3());
```

The line above is worth more than the code. In kernel work, "why" is almost always
"because the hardware does something non-obvious", and that is exactly what the next
reader will not know.

---

## Naming

| Kind | Convention | Example |
|---|---|---|
| Types | `PascalCase` | `PageTable`, `TaskState` |
| Functions, variables | `snake_case` | `map_page`, `frame_count` |
| Constants, enum values | `SCREAMING_SNAKE` | `PAGE_SIZE`, `PTE_PRESENT` |
| Macros | `SCREAMING_SNAKE` | `KASSERT` |
| Files | `snake_case.cpp/.hpp` | `page_table.cpp` |
| Members | trailing `_` | `head_`, `count_` |
| Globals | `g_` prefix | `g_boot_info` |

Prefer no macros. If a macro is unavoidable (`KASSERT`, `offsetof`-style), document
why a function or template would not do.

---

## Headers

- `#pragma once`. Include guards are noise.
- Include what you use; do not rely on transitive includes.
- Order: own header, then kernel headers, then GCC's freestanding C headers
  (`<stdint.h>`, `<stddef.h>` etc. — there is no libstdc++ in the toolchain, see
  [[ADR-0007 - Freestanding C++20 as the Kernel Language]]).
- Keep subsystem-internal headers beside the source, not in `include/`.
- `include/abi/` is plain C, `extern "C"`-safe, because libc consumes it.

---

## What clang-tidy enforces

```
bugprone-*
cert-*
performance-*
readability-*                 (a few noisy checks disabled)
-modernize-use-trailing-return-type
```

Notably enabled: `bugprone-signed-char-misuse`, `bugprone-sizeof-expression`,
`cert-dcl21-cpp`, `readability-magic-numbers` (rule 8, mechanised).

---

## Related

[[ADR-0007 - Freestanding C++20 as the Kernel Language]] · [[07 - Repository Layout]] · [[14 - Debugging Playbook]]

# Stage 0.8 — The Build System

**Difficulty:** Medium · ~60 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** `CMakeLists.txt`, `cmake/x86_64-kernel.cmake`, `cmake/KernelFlags.cmake`, `kernel/CMakeLists.txt`
**Deliverable:** `make run` builds the kernel, wraps it in an ISO, and boots it — one command, no hand-typed compiler invocations. `build/compile_commands.json` exists, so your editor resolves kernel headers for the first time.

---

## Progress

- [ ] `cmake/x86_64-kernel.cmake` — the cross-compilation toolchain file
- [ ] `cmake/KernelFlags.cmake` — every compile and link flag, defined once
- [ ] `CMakeLists.txt` — the top-level project
- [ ] `kernel/CMakeLists.txt` — the `kernel.elf` target
- [ ] `make configure` succeeds (this is where the try-compile trap bites)
- [ ] `make` produces `build/kernel.elf` at the **build root**, not in a subdirectory
- [ ] `build/kernel.sym` is produced alongside it
- [ ] `build/compile_commands.json` exists and every kernel entry carries `-mno-red-zone`
- [ ] `readelf -h` shows the entry point at `0xFFFFFFFF80000000`
- [ ] `.text` is 4 KiB-aligned in the file, not 2 MiB
- [ ] `make run` boots exactly as it did in [[Stage 0.5 - Building a Bootable Image]]
- [ ] Touching one header rebuilds only what depends on it
- [ ] `make lint` passes — the red-zone rule now has a compile database to check
- [ ] Committed with a message like `build: CMake kernel build`

---

## 1. Why this stage exists

Everything so far has been compiled by hand:

```sh
x86_64-elf-g++ -ffreestanding -fno-exceptions -fno-rtti \
    -mno-red-zone -mno-sse -mno-mmx -mno-80387 -mcmodel=kernel \
    -std=c++20 -Wall -Wextra -Werror -c kernel/arch/x86_64/boot/entry.cpp -o entry.o
```

**That was deliberate.** Every flag in that line prevents a specific failure, and you now know which. A build system introduced in Stage 0.1 would have hidden all of them behind `make`, and you would have inherited a working build you could not debug.

That trade stops paying about now. You have four source files and one linker script. By [[Phase 4 - Overview|Phase 4]] you will have forty, spread across subsystems, with headers included by other headers. Three things break at that scale, and none of them announce themselves:

**Header dependencies.** You edit `boot_info.hpp` and rebuild. Did every translation unit that includes it get recompiled? By hand, no. You now have object files built against two different definitions of the same struct, linked into one binary. The symptom is a field reading as garbage, and nothing in your diff explains it. This class of bug is the single best argument for a build system, and it is invisible until it costs you a day.

**Three toolchains in one tree.** The kernel is freestanding and `-mcmodel=kernel`. Userspace ([[Phase 6 - Overview|Phase 6]]) is freestanding and links your libc. Host tools like `mkinitrd` and the Tier-1 unit tests are *native* — they run on your laptop and use the real standard library. Compile any of these with another's flags and you get either a link error you will not understand or, worse, a binary that runs and is subtly wrong.

**`compile_commands.json`.** Without it your editor cannot resolve `#include <kernel/boot_info.hpp>`, so you lose autocomplete and go-to-definition across the entire project — for the next two years. It is free with CMake and impossible with hand-rolled Make.

---

## 2. The concept

### 2.1 What a build system actually does

Three jobs, in order:

1. **Work out what to build.** Which sources produce which objects, which objects link into which binary.
2. **Work out what to *re*build.** This is the hard one, and it is entirely about *dependency tracking* — if `entry.cpp` includes `limine.h`, then touching `limine.h` must rebuild `entry.o`. Compilers can emit this dependency information (`-MMD`); a build system must consume and act on it.
3. **Run the commands, in parallel, in a correct order.**

Hand-written Make does (1) fine, does (2) badly unless you are careful and disciplined every single time, and does (3) adequately.

### 2.2 CMake is a generator, not a build tool

This trips people up. CMake does not build anything. It **generates** build files for something else — Ninja, in our case — and that tool does the building. So there are two phases:

```
   CMakeLists.txt ──► [ cmake -S . -B build -G Ninja ] ──► build/build.ninja
                              "configure + generate"
                                                              │
   sources ────────────────► [ ninja ] ◄──────────────────────┘
                              "build"
```

`make configure` runs the first. `make` runs both (configure is a dependency). You re-run configure only when you change `CMakeLists.txt`; CMake also re-runs itself automatically when it detects that.

### 2.3 Why cross-compilation needs a toolchain file

By default CMake assumes you are building **for the machine you are building on**. It probes the host compiler, host libraries, host headers. That assumption is wrong here in every particular: we build on x86_64 Linux, *for* a bare machine with no OS.

A **toolchain file** tells CMake to stop assuming. It is a small file, read very early — before any compiler probing — that names the target system and the cross-compiler.

### 2.4 The try-compile problem

This is the wall almost everyone hits, so understand it before you meet it.

When CMake first sees a compiler, it verifies the compiler works by **compiling and linking a tiny test program**. Linking is the operative word. Linking a complete executable requires a C runtime startup object (`crt0.o`), a standard library, and an entry point called `main`.

Our target has none of those. So the test fails, and CMake stops with:

```
CMake Error: The C++ compiler "/opt/cross/bin/x86_64-elf-g++" is not able to
compile a simple test program.
```

which is alarming and completely misleading — the compiler is fine, and you proved it in [[Stage 0.1 - Prove Your Toolchain Works]]. The fix is one line telling CMake to build a **static library** for its test instead of an executable, because producing a `.a` requires only compiling and archiving, never linking:

```cmake
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
```

---

## 3. Design decisions and tradeoffs

### Decision: CMake + Ninja, or a hand-written Makefile, or Meson, or Bazel?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **CMake + Ninja (chosen)** | Generates Ninja files; toolchain files handle cross-compilation | Verbose, idiosyncratic language; a real learning curve | ✅ |
| Hand-written Makefile | You write every rule | Header deps are manual and always subtly wrong; three toolchains means three parallel rule sets | ❌ |
| Meson | Generates Ninja; cleaner cross-file model than CMake | Smaller ecosystem; less OSDev prior art to copy from when stuck | ❌ |
| Bazel | Hermetic, reproducible by construction | Enormous configuration overhead; designed for problems two people do not have | ❌ |

**Why CMake.** It handles header dependencies correctly and automatically, it models three toolchains as three toolchain files rather than three copies of everything, it builds host-native unit tests in the same tree without contaminating them, and it emits `compile_commands.json` for free. That last one is worth more than it looks — see §1.

**Why not a hand-written Makefile.** Be fair to it: for six files it is *better* than CMake. It is shorter, there is no generator step, and you can read the whole thing. The crossover is roughly **when you have more directories than you can hold in your head, or more than one toolchain** — for this project, around Phase 4. The reason not to start there and migrate is that migrating a build system mid-project is a day of work nobody schedules, and it always happens during a week you needed for something else.

The real killer is dependency tracking. A hand-rolled Makefile that gets it wrong does not fail loudly; it produces a binary built from two versions of a header. See §1.

**Why not Meson.** Meson's cross-compilation model is genuinely cleaner than CMake's toolchain files — this is a close call and Meson is a defensible choice. It loses on ecosystem: when you are stuck at 1am on a linker error, the OSDev wiki, Stack Overflow, and every hobby-OS repository you might crib from are using CMake or Make.

**Why not Bazel.** Hermeticity is exactly what [[ADR-0005 - Containerised Pinned Toolchain]] already buys us with a pinned container, at a fraction of the setup cost.

**When the answer flips.** If this were a single-architecture kernel of under ~30 files with no userspace and no host tools, hand-written Make is correct and CMake is overhead. If it grew to a multi-repo product with several teams, Bazel starts to earn its cost.

---

### Decision: Ninja or Make as the generator backend?

| Option | Cost | Verdict |
|---|---|---|
| **Ninja (chosen)** | Extra tool (already in the image) | ✅ |
| Make | Slower null builds; worse parallel scheduling | ❌ |

**Why Ninja.** It is designed for exactly one job — execute a pre-computed dependency graph as fast as possible — and it is markedly faster at the null build (the "did anything change?" check you run hundreds of times a day).

**Why it matters more than it sounds.** Your teammate is on macOS. The container runs under `linux/amd64` emulation there ([[ADR-0006 - Apple Silicon Is Not a Boot Target]]), so every build is slower than yours. Build latency is where momentum goes to die, and it is worth optimising for the person with the slower machine.

---

### Decision: keep a thin `Makefile` on top of CMake?

| Option | Cost | Verdict |
|---|---|---|
| **Thin `Makefile` wrapper (chosen)** | One more file; a rule people must respect | ✅ |
| Type `cmake` commands directly | Nobody remembers the flags; container plumbing repeated by hand | ❌ |

**Why.** Two reasons. First, verbs: `make run` is memorable, `cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=... && cmake --build build && ./scripts/mkimage.sh iso && qemu-system-x86_64 -cdrom ...` is not. Second, and more important, **the wrapper is where the container boundary lives** — the `docker run -v "$(CURDIR):/os"` plumbing, and the rule that the build happens inside the container while QEMU runs on the host.

**The rule that makes it work: no build logic in the `Makefile`.** It may run commands; it may not decide how anything is compiled.

**Why not.** The failure mode is drift. A flag added to the `Makefile` instead of `KernelFlags.cmake` applies when you type `make` and not when CI invokes CMake directly — so CI and local builds silently diverge, which is precisely what [[ADR-0005 - Containerised Pinned Toolchain]] exists to prevent. Every time you are tempted to put logic in the `Makefile`, that is the cost.

---

### Decision: three toolchains, or one with overrides?

| Target | Toolchain | Compiler | Standard library |
|---|---|---|---|
| Kernel | `cmake/x86_64-kernel.cmake` | `x86_64-elf-g++` | none — freestanding |
| Userspace ([[Phase 6 - Overview\|Phase 6]]) | `cmake/x86_64-user.cmake` | `x86_64-elf-g++` | our own libc |
| Host tools, Tier-1 tests | native (no toolchain file) | host `g++` | the real one |

**Why separate.** These are three genuinely different environments and conflating them produces confusing failures in both directions. A host unit test compiled with `-mcmodel=kernel` produces an executable your laptop refuses to load. A kernel translation unit that picks up the host's `<string.h>` gets declarations for a `memcpy` that will not exist at link time — and if it *does* link, it linked against host libc, which is a very confusing afternoon ([[07 - Repository Layout]], boundary rule 3).

**When the answer flips.** Never, really. This one is settled: the moment you have code running in two privilege domains you have two toolchains.

---

### Decision: flags defined once, or per target?

| Option | Cost | Verdict |
|---|---|---|
| **Once in `KernelFlags.cmake` (chosen)** | Indirection — you must open another file to see the flags | ✅ |
| Repeated per target | Drift; a new target quietly missing `-mno-red-zone` | ❌ |

**Why.** The flags are not stylistic. `-mno-red-zone` in particular prevents silent memory corruption that surfaces weeks later in unrelated code ([[Stage 0.1 - Prove Your Toolchain Works]] §5). A new subsystem added in Phase 9 that forgets it will appear to work for months.

**And this is why it is mechanised, not reviewed.** `scripts/lint.sh` reads `compile_commands.json` and fails if any kernel translation unit lacks the flag:

```sh
jq -r '.[] | select(.file | test("/kernel/"))
           | select((.command // (.arguments | join(" "))) | contains("-mno-red-zone") | not)
           | .file' build/compile_commands.json
```

A human reviewer will miss this on the fortieth pull request. A grep will not. See [[Stage 0.9 - CI From Day One]].

---

### Decision: `-Werror` from the first commit?

| Option | Cost | Verdict |
|---|---|---|
| **`-Werror` on now (chosen)** | An unrelated warning can block you mid-task | ✅ |
| Add it later | Never happens | ❌ |

**Why.** Turning it on later means fixing several hundred warnings in one sitting, which nobody ever schedules, so the flag never goes on and the warnings become background noise. Kernel warnings are disproportionately real bugs — an uninitialised variable in userspace is a wrong answer, in a kernel it is a fault at an address that means nothing.

**The honest counter-argument.** `-Werror` means a *compiler upgrade* can break your build on a morning you had other plans, because a new GCC version added a new warning. This is a real and widely-cited objection.

**Why it does not apply here.** The compiler cannot change underneath you: it is pinned inside the toolchain image ([[ADR-0005 - Containerised Pinned Toolchain]]), and upgrading it is a deliberate, reviewed pull request that changes a digest. Two decisions reinforcing each other — pinning makes `-Werror` safe, and `-Werror` makes pinning pay.

---

## 4. Specification

### Files and responsibilities

| File | Responsible for |
|---|---|
| `cmake/x86_64-kernel.cmake` | Target system, cross-compiler, try-compile workaround |
| `cmake/KernelFlags.cmake` | Every compile and link flag, defined exactly once |
| `CMakeLists.txt` | Project declaration, C++ standard, subdirectories |
| `kernel/CMakeLists.txt` | The `kernel.elf` target, its sources, and the link step |

### Compile flags

| Flag | Prevents |
|---|---|
| `-ffreestanding` | Compiler assuming a hosted runtime exists |
| `-fno-exceptions` | Requiring an unwinder and `.eh_frame` machinery |
| `-fno-rtti` | Requiring runtime type tables |
| `-fno-stack-protector` | Emitting calls to `__stack_chk_fail`, which does not exist |
| `-fno-pic -fno-pie` | Position-independent code; the kernel loads at a fixed address |
| `-nostdinc++` | Silently picking up host C++ headers — there is no libstdc++ ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]) |
| `-mcmodel=kernel` | Addressing that does not reach the top 2 GiB |
| `-mno-red-zone` | **Interrupt frames silently destroying live data** |
| `-mno-sse -mno-mmx -mno-80387` | FP state the kernel would have to save across interrupts |
| `-fno-omit-frame-pointer` | A fictional backtrace in [[Stage 0.7 - Panic and KASSERT]] |
| `-Wall -Wextra -Werror` | Warnings becoming background noise |

### Link flags

| Flag | Prevents |
|---|---|
| `-T .../linker.ld` | The default layout instead of your higher-half one |
| `-nostdlib` | Linking crt0, libc, and libgcc |
| `-static` | A dynamic loader that does not exist |
| `-Wl,-z,max-page-size=0x1000` | **2 MiB segment alignment** — see the trap in §7 |
| `-Wl,--build-id=none` | A build-id note that breaks reproducibility |

> **Note the `-Wl,` prefix and the commas.** You are invoking the linker *through*
> `g++`, not directly, so linker options must be forwarded. `-Wl,-z,max-page-size=0x1000`
> forwards `-z max-page-size=0x1000`. Writing the bare `-z max-page-size=0x1000` in
> `target_link_options` will not do what you expect.

### Required output paths

`scripts/mkimage.sh` looks for artefacts at the **build root**:

```sh
KERNEL="${BUILD_DIR}/kernel.elf"     # build/kernel.elf
```

CMake's default is to place a target's output in the binary directory *mirroring the source subdirectory* — so `add_executable` inside `kernel/CMakeLists.txt` produces `build/kernel/kernel.elf`, which `mkimage.sh` will not find. Set `RUNTIME_OUTPUT_DIRECTORY` explicitly.

---

## 5. Writing the code

Everything below has been configured, built, and inspected in the real toolchain image. The resulting `kernel.elf` reports entry point `0xffffffff80000000` with `.text` at file offset `0x1000`.

### `cmake/x86_64-kernel.cmake`

Tells CMake it is cross-compiling, and to which target.

```cmake
# Cross-compilation toolchain: freestanding x86_64-elf kernel.
# Read very early, before any compiler probing. See steps/08 - Build System.

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER        x86_64-elf-gcc)
set(CMAKE_CXX_COMPILER      x86_64-elf-g++)
set(CMAKE_ASM_NASM_COMPILER nasm)

# CMake verifies a compiler by LINKING a test executable. That needs crt0, a
# libc, and main() — none of which exist for a bare target. Building a static
# library instead only compiles and archives, so the check passes.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Look for programs on the host; look for libraries and headers ONLY in the
# target sysroot, never in /usr/include.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

#### Line by line

**`set(CMAKE_SYSTEM_NAME Generic)`**
The single most important line. Setting `CMAKE_SYSTEM_NAME` at all is what puts CMake into cross-compiling mode (`CMAKE_CROSSCOMPILING` becomes true). The value `Generic` means "a system with no operating system" — which is exactly right, and which suppresses the OS-specific behaviour CMake would otherwise apply.

**`set(CMAKE_SYSTEM_PROCESSOR x86_64)`**
Informational; available to your `CMakeLists.txt` if you ever branch on architecture. It does not select a compiler.

**`CMAKE_C_COMPILER` / `CMAKE_CXX_COMPILER`**
The cross-compilers by name. They resolve via `PATH`, which the container sets to include `/opt/cross/bin`. If you ever see the host `g++` here, this file was not passed to CMake — check `-DCMAKE_TOOLCHAIN_FILE=`.

**`set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)`**
The try-compile fix from §2.4. Without it, `make configure` fails with "is not able to compile a simple test program" before it does anything else, and the message points you at the wrong problem entirely.

**The three `CMAKE_FIND_ROOT_PATH_MODE_*` lines**
These govern where `find_program`, `find_library`, and `find_path` search. Programs (`nasm`, `objcopy`) run on the *host*, so `NEVER` means "do not confine the search to the target sysroot". Libraries and headers must come from the *target*, so `ONLY` prevents CMake from cheerfully finding `/usr/include/stdio.h` and handing you a header describing a Linux system your kernel is not running on.

---

### `cmake/KernelFlags.cmake`

Every flag, defined once. Nothing else in the tree may add or override a kernel flag.

```cmake
# The kernel's compile and link flags. Defined ONCE, applied to every kernel
# target. These are not stylistic — each prevents a specific, real failure.
# See steps/08 - Build System and Stage 0.1 for the full reasoning.

set(KERNEL_CXX_FLAGS
    -ffreestanding                      # no hosted runtime assumptions
    -fno-exceptions -fno-rtti           # no unwinder, no type tables  ADR-0007
    -fno-stack-protector                # no __stack_chk_fail to link against
    -fno-pic -fno-pie                   # loaded at a fixed address
    -nostdinc++                         # there is no libstdc++        ADR-0007
    -mcmodel=kernel                     # addressing valid in the top 2 GiB
    -mno-red-zone                       # CRITICAL: interrupts clobber it
    -mno-sse -mno-mmx -mno-80387        # no FP state to save
    -fno-omit-frame-pointer             # so panic() can walk the stack
    -Wall -Wextra -Werror)

set(KERNEL_LINK_FLAGS
    -nostdlib                           # no crt0, no libc, no libgcc
    -static                             # no dynamic loader exists
    -Wl,-z,max-page-size=0x1000         # 4 KiB segments, not the 2 MiB default
    -Wl,--build-id=none)                # reproducible builds
```

#### Line by line

**`-nostdinc++`** is the flag worth dwelling on, because it is the one that differs from most tutorials. Our toolchain image contains **no libstdc++** — `toolchain/Dockerfile` builds `all-gcc all-target-libgcc` and stops. Without `-nostdinc++`, an accidental `#include <cstdint>` produces a confusing "no such file" that people fix by adding a host include path, which then compiles against headers describing a completely different environment. With it, the failure is immediate and unambiguous. Use `<stdint.h>` and `kstd::` ([[ADR-0007 - Freestanding C++20 as the Kernel Language]]).

**`-fno-omit-frame-pointer`** is here rather than only in the debug build because [[Stage 0.7 - Panic and KASSERT]]'s backtrace walks `rbp` as a frame-pointer chain. At `-O2` without this flag, GCC uses `rbp` as a general-purpose register and your backtrace prints plausible-looking fiction — which is worse than printing nothing.

**`-Wl,-z,max-page-size=0x1000`** — see §7. This is the one whose absence produces a build that *works* and is quietly wrong.

---

### `CMakeLists.txt`

The top-level project.

```cmake
cmake_minimum_required(VERSION 3.20)

project(cracked_os LANGUAGES CXX ASM_NASM)

set(CMAKE_CXX_STANDARD          20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)

# Emit build/compile_commands.json for clangd, clang-tidy, and the CI rule
# that proves every kernel TU carries -mno-red-zone.
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(cmake/KernelFlags.cmake)

add_subdirectory(kernel)
```

#### Line by line

**`project(cracked_os LANGUAGES CXX ASM_NASM)`**
Declaring the languages up front matters. Listing `CXX` triggers the C++ compiler probe — which is where the try-compile problem surfaces, so if this line errors, look at the toolchain file. `ASM_NASM` enables NASM support for the `.asm` files that arrive in [[Phase 2 - Overview|Phase 2]] (interrupt stubs) and [[Phase 5 - Overview|Phase 5]] (context switch). Declaring it now costs nothing and saves a confusing re-configure later.

Note there is no `C` — the kernel is C++ only. Add it when something needs it.

**`CMAKE_CXX_EXTENSIONS OFF`**
Selects `-std=c++20` rather than `-std=gnu++20`. GNU extensions are not forbidden by [[ADR-0007 - Freestanding C++20 as the Kernel Language]], but having them off by default means anything relying on one is a deliberate choice rather than an accident that fails on a different compiler.

**`set(CMAKE_EXPORT_COMPILE_COMMANDS ON)`**
Writes `build/compile_commands.json`. This is what gives your editor working autocomplete and go-to-definition, what `clang-tidy` reads, and what `scripts/lint.sh` greps for `-mno-red-zone`. The `Makefile` also passes `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`; belt and braces.

**`include(cmake/KernelFlags.cmake)`**
Brings `KERNEL_CXX_FLAGS` and `KERNEL_LINK_FLAGS` into scope. Variables set at this level are visible in subdirectories, which is how `kernel/CMakeLists.txt` sees them.

---

### `kernel/CMakeLists.txt`

The kernel target itself.

```cmake
# The kernel image. Sources are listed explicitly rather than globbed: a glob
# does not re-run when you add a file, so a new .cpp silently is not built.

add_executable(kernel.elf
    arch/x86_64/boot/entry.cpp
    arch/x86_64/boot/boot_info.cpp
    drivers/char/serial.cpp
    lib/panic.cpp
    main.cpp
)

target_compile_options(kernel.elf PRIVATE ${KERNEL_CXX_FLAGS})

target_include_directories(kernel.elf PRIVATE
    ${CMAKE_SOURCE_DIR}/kernel/include
)

set(LD_SCRIPT ${CMAKE_SOURCE_DIR}/kernel/arch/x86_64/boot/linker.ld)

target_link_options(kernel.elf PRIVATE
    ${KERNEL_LINK_FLAGS}
    -T ${LD_SCRIPT}
)

set_target_properties(kernel.elf PROPERTIES
    # Re-link when the linker script changes. CMake cannot infer this.
    LINK_DEPENDS ${LD_SCRIPT}
    # scripts/mkimage.sh expects build/kernel.elf, NOT build/kernel/kernel.elf.
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
)

# A separate symbol file: GDB loads it, and Stage 1.7 uses it to symbolise
# backtraces. Keep kernel.elf unstripped as well — it is what you debug.
add_custom_command(TARGET kernel.elf POST_BUILD
    COMMAND x86_64-elf-objcopy --only-keep-debug
            $<TARGET_FILE:kernel.elf> ${CMAKE_BINARY_DIR}/kernel.sym
    COMMENT "Generating kernel.sym"
)
```

#### Line by line

**The explicit source list.** It is tempting to write `file(GLOB_RECURSE SOURCES *.cpp)`. Do not. CMake evaluates a glob at *configure* time, so adding a new source file does not re-run configure, and your new file is silently not compiled — you get an undefined-reference error for a function whose definition is sitting right there in the tree. Listing files means adding one is a two-line diff that a reviewer sees.

Trim this list to the files you actually have. Early in [[Phase 0 - Overview|Phase 0]] it is just `entry.cpp`.

**`target_compile_options(... PRIVATE ${KERNEL_CXX_FLAGS})`**
`PRIVATE` means these flags apply to this target and are not inherited by anything linking it. For an executable that is the only sensible choice; the distinction matters when libraries arrive.

**`target_include_directories(... ${CMAKE_SOURCE_DIR}/kernel/include)`**
Makes `#include <kernel/boot_info.hpp>` resolve. `${CMAKE_SOURCE_DIR}` is the repo root, so this is `kernel/include` — matching [[07 - Repository Layout]], where `include/kernel/` holds cross-subsystem interfaces and headers internal to a subsystem live beside their source.

**`-T ${LD_SCRIPT}` in `target_link_options`**
Points the linker at your script from [[Stage 0.4 - The Linker Script and Higher-Half Layout]] instead of its built-in default layout. An absolute path via `${CMAKE_SOURCE_DIR}` because the linker runs with the build directory as its working directory.

**`LINK_DEPENDS ${LD_SCRIPT}`**
CMake tracks `#include` dependencies automatically but has no idea that `-T somefile` means the output depends on that file. Without this line, editing `linker.ld` does not relink, and you spend twenty minutes wondering why your layout change had no effect. This is exactly the class of dependency bug §1 warned about — it just happens to be one CMake cannot infer.

**`RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}`**
CMake defaults to mirroring the source tree in the build tree, so this target would land at `build/kernel/kernel.elf`. `scripts/mkimage.sh` looks for `build/kernel.elf` and would die with `missing build/kernel.elf — run 'make' first`, which reads as "the build did not run" when in fact it ran perfectly and put the file somewhere else. Pin it.

**The `POST_BUILD` `objcopy`**
`--only-keep-debug` extracts the debug and symbol information into `build/kernel.sym`, leaving `kernel.elf` untouched. Two consumers: `make gdb` loads symbols from it, and [[Phase 1 - Overview|Phase 1]]'s backtrace symbolisation turns a panic's raw addresses into file-and-line. `$<TARGET_FILE:kernel.elf>` is a generator expression — it resolves to the target's final path at build time, which is more robust than re-deriving the path yourself.

---

## 6. How to verify

### Configure

```sh
make configure
```

Expected — note the **skipped** compiler check, which is the try-compile fix working:

```
-- The CXX compiler identification is GNU 14.2.0
-- Check for working CXX compiler: /opt/cross/bin/x86_64-elf-g++ - skipped
-- Configuring done
-- Generating done
-- Build files have been written to: /os/build
```

### Build

```sh
make
```

```
[1/2] Building CXX object kernel/CMakeFiles/kernel.elf.dir/arch/x86_64/boot/entry.cpp.obj
[2/2] Linking CXX executable kernel.elf
```

### Inspect the result

```sh
ls -l build/kernel.elf build/kernel.sym
x86_64-elf-readelf -h build/kernel.elf | grep -E 'Entry point|Machine|Type:'
```

```
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0xffffffff80000000
```

**The entry point must be `0xffffffff80000000`.** If it is `0x0`, `ENTRY(kmain)` did not resolve — usually a missing `extern "C"` ([[Stage 0.2 - The Limine Request Section]]).

### Prove the page size is 4 KiB, not 2 MiB

```sh
x86_64-elf-readelf -S build/kernel.elf | grep -A1 '\.text'
```

The file offset must be `0x1000`-aligned, not `0x200000`-aligned:

```
  [ 1] .text  PROGBITS  ffffffff80000000  00001000
```

### Prove the flags reached every translation unit

```sh
test -f build/compile_commands.json && echo "compile db present"

jq -r '.[] | select(.file | test("/kernel/"))
           | select((.command // (.arguments | join(" "))) | contains("-mno-red-zone") | not)
           | .file' build/compile_commands.json
```

The `jq` command must print **nothing**. Any file it lists is compiled without `-mno-red-zone` and will corrupt memory unpredictably. This is the same query CI runs.

### Prove incremental rebuild is correct

```sh
touch kernel/include/kernel/boot_info.hpp
make
```

Every translation unit that includes it — and only those — must rebuild. This is the capability §1 said you were buying.

### Full loop

```sh
make run
```

Identical behaviour to [[Stage 0.5 - Building a Bootable Image]], now from one command.

- [ ] `make configure` reports "skipped" for the compiler check, not an error
- [ ] `build/kernel.elf` and `build/kernel.sym` exist at the build root
- [ ] Entry point is `0xffffffff80000000`
- [ ] `.text` file offset is 4 KiB-aligned
- [ ] The `jq` red-zone query prints nothing
- [ ] Touching a header rebuilds its dependents and nothing else
- [ ] `make run` boots as before
- [ ] `make lint` now passes the red-zone rule instead of skipping it

---

## 7. Common traps

**Symptom: `The C++ compiler "/opt/cross/bin/x86_64-elf-g++" is not able to compile a simple test program.`**
The compiler is fine — you proved it in [[Stage 0.1 - Prove Your Toolchain Works]]. CMake's check tries to *link* an executable, which needs crt0, a libc, and `main`. Add `set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)` to the toolchain file. If it persists, read `build/CMakeFiles/CMakeError.log` — the real error is in there, not in the message CMake printed.

**Symptom: the build works but `build/os.iso` is enormous, or `mkimage.sh` says `missing build/kernel.elf`.**
Two separate bugs with a similar flavour. The size one is a missing `-Wl,-z,max-page-size=0x1000`: the x86-64 linker defaults to **2 MiB** maximum page size and pads every segment to that boundary, inflating the image by megabytes *and* silently defeating the 4 KiB section alignment [[Stage 0.4 - The Linker Script and Higher-Half Layout]] asked for — which is what [[Phase 15 - Overview|Phase 15]] needs to apply per-section permissions. The missing-file one is `RUNTIME_OUTPUT_DIRECTORY`: your kernel is at `build/kernel/kernel.elf`.

**Symptom: `undefined reference to 'memcpy'` (or `memset`, `memmove`, `memcmp`).**
Not a build-system bug. The C++ standard *requires* a freestanding implementation to provide these four, and GCC emits calls to them for struct assignment, array initialisation, and zeroing — even when you never wrote the name. `-nostdlib` means nothing provides them. **You must implement all four yourself** in `kernel/lib/string.cpp`. Compile that file with `-fno-builtin` or GCC may cheerfully optimise your `memset` implementation into a call to `memset`.

**Symptom: `undefined reference to '__stack_chk_fail'`.**
`-fno-stack-protector` is missing from a target.

**Symptom: `fatal error: cstdint: No such file or directory`.**
There is no libstdc++ in the toolchain image. Use `<stdint.h>`, and write what you need in `kstd::` — see [[ADR-0007 - Freestanding C++20 as the Kernel Language]]. `-nostdinc++` makes this fail immediately and legibly rather than depending on what happens to be installed.

**Symptom: editing `linker.ld` changes nothing.**
`LINK_DEPENDS` is missing, so CMake does not know the link output depends on the script. `make clean` proves it; `LINK_DEPENDS` fixes it.

**Symptom: a new `.cpp` file is not compiled, and its functions are undefined at link time.**
You used `file(GLOB ...)`. Globs are evaluated at configure time and do not re-run. List sources explicitly.

**Symptom: host unit tests fail to run with `cannot execute binary file`.**
A host target picked up the kernel toolchain. Host tools and Tier-1 tests must build natively — no toolchain file — via a superbuild or `ExternalProject`. See [[08 - Build System]].

**Symptom: your editor has no autocomplete for kernel headers.**
`build/compile_commands.json` is missing, or your editor is not looking in `build/`. Most clangd setups want it at the repo root: `ln -s build/compile_commands.json .` — and add that symlink to `.gitignore`.

---

## 8. What this unlocks

Everything after this point assumes `make` works. [[Stage 0.9 - CI From Day One]] runs the exact same `make` targets inside the exact same container, which is what makes a CI failure reproducible with one local command rather than a guessing game.

The subtler unlock is `compile_commands.json`. It is what gives you working navigation across a codebase that will reach tens of thousands of lines, what `clang-tidy` consumes, and what lets CI enforce `-mno-red-zone` mechanically instead of trusting forty pull-request reviews to catch its absence.

Done wrong, the failures are quiet: a build that works but is 2 MiB-aligned, or a subsystem added in [[Phase 9 - Overview|Phase 9]] that quietly lacks a flag. Both are caught by §6's checks — which is why they are checks and not suggestions.

---

## 9. Reading

- **CMake — cross-compiling**: <https://cmake.org/cmake/help/latest/manual/cmake-toolchains.7.html#cross-compiling>
  The authoritative description of toolchain files and `CMAKE_SYSTEM_NAME`.
- **CMake — `CMAKE_TRY_COMPILE_TARGET_TYPE`**: <https://cmake.org/cmake/help/latest/variable/CMAKE_TRY_COMPILE_TARGET_TYPE.html>
  Short, and explains the one line that unblocks the whole stage.
- **GCC — `-ffreestanding` and the four required functions**:
  <https://gcc.gnu.org/onlinedocs/gcc/Standards.html>
  Read the freestanding paragraph; it is where `memcpy`/`memmove`/`memset`/`memcmp` come from.
- OSDev — *CMake build system*: <https://wiki.osdev.org/CMake>
- [[08 - Build System]] — the specification this stage implements
- [[13 - Coding Standards]] — what `-Werror` is enforcing
- [[ADR-0005 - Containerised Pinned Toolchain]] — why pinning makes `-Werror` safe

Next: **[[Stage 0.9 - CI From Day One]]**

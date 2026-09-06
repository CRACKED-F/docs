# Stage 0.1 — Prove Your Toolchain Works

**Difficulty:** Very Easy · ~20 minutes
**Phase:** [[Phase 0 - Overview|Phase 0 — Toolchain & First Boot]]
**Files you create:** none permanent — a throwaway `probe.cpp` you delete at the end
**Deliverable:** the pinned container runs, `x86_64-elf-g++` produces a genuine `ELF 64-bit LSB relocatable, x86-64` object under the kernel flag set, and `qemu-system-x86_64 ` starts on the host — all three proven by inspection, not assumed.

---

## Progress

- [ ] `docker --version` and `qemu-system-x86_64 --version` both answer on the **host**
- [ ] `make shell` drops you into the toolchain container at `/os`
- [ ] `uname -m` inside the container prints `x86_64`, not `aarch64`
- [ ] Tools report pinned versions: gcc/g++ **14.2.0**, ld **2.43**, nasm, cmake
- [ ] `ls "$LIMINE_DIR/BOOTX64.EFI"` finds the UEFI bootloader
- [ ] `x86_64-elf-g++ -dumpmachine` prints `x86_64-elf`
- [ ] `probe.cpp` written in **`/tmp` inside the container**, not in the repo
- [ ] It compiles with the kernel flag set — silently, exit status 0
- [ ] `file probe.o` says `ELF 64-bit LSB relocatable, x86-64`
- [ ] `x86_64-elf-readelf -h probe.o` shows `ELF64` / `REL` / `Advanced Micro Devices X86-64`
- [ ] The red-zone disassembly test shows `%rsp` moving before anything is stored below it
- [ ] `#include <stdio.h>` **fails** — proof there is no host libc on the include path
- [ ] QEMU on the host opens and complains it has nothing to boot
- [ ] `ls /usr/share/OVMF/` shows the firmware you need from [[Stage 0.5 - Building a Bootable Image]]
- [ ] Nothing to commit — `git status` is clean

---

## 1. Why this stage exists

A kernel has no error messages. When it fails the screen stays black — no shell to
report to, no logger, no exit code. There is only ever one symptom, so you cannot work
backwards from it. Instead you verify each link before depending on it. Between "I
wrote C++" and "the CPU executed it" sit a container, a cross-compiler, a linker, an
image builder, a bootloader, firmware, and an emulator. Seven things. Check none and
the black screen at Stage 0.5 has seven suspects and no evidence.

The concrete version: you skip this stage, and three stages later the kernel will not
boot. The real cause is that you typed `gcc` instead of `x86_64-elf-g++` in one place,
so one translation unit was built by Ubuntu's system compiler — position-independent,
stack-protected, with glibc's headers on the search path. It compiled without a
warning and linked without an error, and it faults on its first stack-protector check
because `%fs` is not what glibc assumes. You will not find that by staring at `kmain`.
You will find it by eventually running `file` on an object.

The second reason is reproducibility. Two developers on different operating systems
plus a CI runner is three environments. Three compilers make three different inlining
and stack-layout decisions, and a race that never fires on your machine fires every
time on your teammate's. You lose a day, and the answer is "your GCC is 14.2 and mine
is 15.1". [[ADR-0005 - Containerised Pinned Toolchain]] exists to make that impossible;
this stage confirms the mechanism works rather than trusting a `docker pull` you never
looked at.

This is a smoke test and it is meant to fail loudly. Twenty minutes here buys the right
to assume, for the rest of the project, that when something breaks it is your code.

---

## 2. The concept

### A "compiler" is four programs

```
probe.cpp ──cc1plus──► probe.s ──x86_64-elf-as──► probe.o ──x86_64-elf-ld -T──► kernel.elf
           preprocess          assemble                    link
           + compile           (binutils, ELF64)           (Stage 0.4, linker script)
           ▲
           the flags in §5 act HERE: red zone, SSE, code model, ABI
```

Each step fails for a different reason. Only the first two run today; the stage stops
at `probe.o` on purpose — one stage, one thing.

### Target triples, and what "hosted" assumes

A compiler is built for exactly one target, named by a triple: `cpu-vendor-os`.
Ubuntu's is `x86_64-linux-gnu`; ours is `x86_64-elf`. The third field is the
interesting one. `linux-gnu` promises a Linux kernel underneath and a GNU C library on
top, and that promise licenses a long list of silent assumptions: that `/usr/include`
and a real `printf` exist; that execution begins at `_start` in `crt1.o`, which builds
a stack, runs global constructors and calls `main`; that `%fs` points at a
thread-control block (GCC's default stack protector reads its canary from `%fs:0x28`);
that a dynamic loader will relocate the image, since Ubuntu's GCC defaults to PIE; and
that an OS turns a null dereference into a signal rather than a triple fault.

Your kernel provides none of that. `x86_64-elf` has an empty OS field, which is the
point. The C++ standard's name for this is a **freestanding implementation**: start-up
and termination are implementation-defined (there need be no `main`), and only the
subset of library headers requiring no runtime must exist. `-ffreestanding` *asks* a
compiler to behave that way; building the compiler for `x86_64-elf` makes it
structural — no target `/usr/include` to include from, no `crt1.o` to link, no
`--enable-default-pie` in its configuration.

### Where everything runs

```
  Windows 11 (WSL2 Ubuntu 24.04)          or        macOS (Apple Silicon)
  ────────────────────────────────────────────────────────────────────────
  editor, git                                       editor, git
  repo at ~/os   (ext4 — NOT /mnt/c)                repo at ~/os
       │                                                 │
       ├── docker run -v ~/os:/os ──►  TOOLCHAIN CONTAINER  (linux/amd64)
       │                               ubuntu:24.04
       │                               x86_64-elf-gcc/g++  14.2.0
       │                               binutils            2.43
       │                               nasm, cmake, ninja, ccache
       │                               xorriso, mtools, dosfstools, parted
       │                               limine  v8.6.0-binary
       │                                     │  writes through the mount
       │                                     ▼
       │                               build/kernel.elf, build/os.iso
       │                                     │
       └── qemu-system-x86_64  8.2.2  ◄──────┘
           runs on the HOST, never in the container (interactively)
```

**The bind mount.** `-v ~/os:/os` makes the repository the *same directory* inside and
outside — the same inodes, not a copy. A file created at `/os/foo` in the container
appears in `git status` outside it immediately. That is what makes `make` work, and it
is why you will write `probe.cpp` into `/tmp`: `/tmp` lives in the container's own
writable layer and is destroyed on exit by `--rm`.

**The platform.** The image is `linux/amd64`, so on Apple Silicon it runs emulated.
Deliberate (§3), and why `uname -m` is one of the checks below.

### Why an object file is real proof

An ELF relocatable object records, in its 64-byte header, the compiler's answers to
exactly the questions that go wrong:

| Question | ELF field | A wrong answer |
|---|---|---|
| 32 or 64 bit? | `EI_CLASS` | `ELF32` — you built for i686 |
| Which machine? | `e_machine` | `Intel 80386`, `ARM aarch64` |
| Which object format? | `EI_MAG0..3` | `Mach-O` — you ran Apple's compiler |
| Whose conventions? | `EI_OSABI` | `UNIX - GNU` — a hosted GNU toolchain |

`file` reads that header and prints it as a sentence. One line, one second, definitive.

---

## 3. Design decisions and tradeoffs

### Decision: cross-compiler, or the compiler already on the machine?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — `x86_64-elf-gcc/g++`** | GCC configured `--target=x86_64-elf --without-headers`, built from source in the image, with `x86_64-elf-` binutils | ~25 min to build the image once | ✅ |
| B — host `gcc` with `-ffreestanding -nostdlib` | Ubuntu's `x86_64-linux-gnu` GCC told to behave freestanding by flags | Every hosted default stays armed; the triple still says Linux | ❌ |
| C — Apple clang on macOS | The teammate's system compiler | Cannot emit ELF at all; `ld64` cannot use a linker script | ❌ |
| D — clang `--target=x86_64-elf` | One clang binary cross-compiles anywhere; `ld.lld` links | Needs `compiler-rt` instead of `libgcc`; a second toolchain to keep in step | ❌ *for now* |

**Why A.** A cross-compiler makes the mistakes structurally impossible rather than
merely discouraged. Built `--without-headers`, it has no target `/usr/include`, so
`#include <stdio.h>` does not resolve to something wrong — it fails. It is not
configured `--enable-default-pie`, so PIE is not the default. Its linker is GNU `ld`,
which understands the `-T` script Stage 0.4 needs. And the Dockerfile builds
`all-target-libgcc` deliberately: the kernel links `libgcc` for compiler builtins such
as 128-bit division, and linking without it produces undefined-reference errors that
look unrelated to their cause.

**Why not B.** `-ffreestanding` is a hint about *semantics*; it does not undo how the
compiler was configured. With that flag on the command line, Ubuntu's GCC still:

- reports `x86_64-linux-gnu` from `-dumpmachine` and defines `__linux__`, `__unix__`,
  `__gnu_linux__`, so any platform `#if` takes the Linux branch;
- keeps `/usr/include` on the header path, so `#include <stdio.h>` succeeds and hands
  you glibc's declarations. Your kernel compiles. It cannot link, and the error names
  a symbol you never wrote;
- generates position-independent code with GOT addressing (`--enable-default-pie`) —
  wrong for an image linked at a fixed higher-half address. `-fno-pic -fno-pie` fixes
  it, and you have to know to;
- inserts `-fstack-protector-strong` canaries loaded from `%fs:0x28`, calling
  `__stack_chk_fail` on mismatch. In kernel context `%fs` is whatever firmware left,
  the symbol does not exist, and the first check faults. `-fno-stack-protector` fixes
  it, and again you have to know to;
- adds `crt1.o`, `crti.o`, `crtn.o`, default libraries, and — because of default PIE —
  a `PT_INTERP` header naming `/lib64/ld-linux-x86-64.so.2` the moment you link. You
  have produced a kernel that asks to be loaded by a dynamic linker.

Each has a flag that fixes it. The problem is you are now maintaining six flags whose
only job is to unwind decisions made for a different kind of program, and forgetting
one is silent.

**Why not C.** Apple's toolchain emits Mach-O; object format is not a switch, so no
flag produces ELF. And `ld64` does not accept a GNU linker script, which makes
[[Stage 0.4 - The Linker Script and Higher-Half Layout]] impossible. The macOS path is
closed, not merely worse.

**When B or C would be right.** B is right for building a Linux *program* — exactly
what the Tier 1 host unit tests in [[09 - Testing Strategy]] are, and they use the host
compiler on purpose. C is right for macOS-native tooling. The line: host compiler for
anything that runs *under* an OS, cross-compiler for anything that *is* one.

**When D would be right.** Clang is a real alternative — one binary targets everything,
`ld.lld` handles linker scripts, and its kernel sanitizer support is ahead of GCC's on
some targets. Switch if the cross-GCC build becomes a maintenance burden, if you want
KASAN-style instrumentation, or if someone must build without Docker. Not casual:
`libgcc` and `compiler-rt` are not interchangeable, and
[[ADR-0007 - Freestanding C++20 as the Kernel Language]] is written against GCC.

**Detecting the wrong one, in one line:**

```sh
x86_64-elf-g++ -dumpmachine    # x86_64-elf        ← correct
g++ -dumpmachine               # x86_64-linux-gnu  ← the host compiler
```

`-dumpmachine` reports the triple the compiler was *built for*. No flag changes it, so
unlike `file` it is never ambiguous.

---

### Decision: pinned container, or install the toolchain on each machine?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — pinned Docker image** | `toolchain/Dockerfile` builds every tool at a pinned version; published to GHCR; used by both devs and CI | Docker becomes a hard prerequisite; emulated on Apple Silicon | ✅ |
| B — Homebrew / apt packages | `brew install x86_64-elf-gcc`, or a PPA | Versions differ per machine, drift on every `brew upgrade` | ❌ |
| C — build from source by hand, per machine | The classic OSDev recipe on each dev box | ~1 hour per machine; three subtly different compilers | ❌ |
| D — Nix | Genuinely reproducible, declarative, no daemon | Neither team member knows Nix | ❌ |

**Why A.** One image, one set of versions, byte-identical output on macOS, Windows 11
and CI. Onboarding drops from "budget an hour, maybe a day if the cross-compiler build
fails" to `git clone && make shell`. Upgrading the toolchain becomes a reviewed commit
that changes `toolchain/Dockerfile` and appears in `git log` — not a silent
`brew upgrade` on one laptop at 11pm.

**Why not B or C.** Same failure, different effort: three developers, three compilers.
In application work that is a nuisance; in kernel work it is what eats days.

- Different GCC versions make different **inlining** decisions, so a function inlined
  on your machine and not your teammate's has a different stack layout. A stack overrun
  that lands in padding on one build lands on a live variable on the other.
- Different **register allocation and spill** decisions mean a missing clobber in an
  inline `asm` block — the exact bug
  [[ADR-0007 - Freestanding C++20 as the Kernel Language]] warns about — is harmless
  until the optimiser keeps something live in the register you quietly destroyed.
- Result: your teammate reports a boot crash you cannot reproduce. You are reading the
  same source; neither of you is wrong. You lose a day discovering the difference was
  `gcc 14.2` versus `gcc 15.1`, spent reading correct code.
- Worse and permanent: **green in CI, red locally.** Once CI disagrees with a
  developer's machine and nobody knows which is right, CI stops being evidence. It gets
  bypassed, then ignored — and an ignored CI is worse than no CI, because it produces a
  badge that means nothing.

For a two-person team, one lost afternoon is a meaningful fraction of a week's output.

**The price paid, stated plainly.** On Apple Silicon the image runs under `linux/amd64`
emulation and is noticeably slower. Deliberate: a native `arm64` image would be a
*different build environment* producing different bytes from CI, which throws away the
whole point. `ccache` on a named volume (`-v os-ccache:/ccache`) keeps incremental
builds quick — a full kernel rebuild is still under a minute. The check is `uname -m`
inside the container: it must print `x86_64`. If it prints `aarch64`, someone built the
image natively and the guarantee is void.

**When B or C would be right.** Solo project, one machine, no CI, nobody else will ever
build it — install the compiler and skip Docker. The container's value scales with the
number of independent environments, and at one it is zero. Also: if you want to *learn*
how a cross-compiler is built, do it by hand once — `toolchain/Dockerfile` is exactly
that recipe.

**When D would be right.** If Docker becomes painful — image size, daemon problems, CI
cache misses — Nix is technically better and
[[ADR-0005 - Containerised Pinned Toolchain]] says so. It was rejected on team
familiarity, not merit: the learning curve competes directly with the project, which is
a real cost and the correct thing to weigh.

---

### Decision: where does QEMU run?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen) — build in container, run QEMU on host** | The container produces `os.iso`; the host's QEMU boots it through the shared mount | QEMU is a second host install; its version can drift | ✅ |
| B — everything in the container, QEMU included | Forward X11/Wayland and `/dev/kvm` into the container | Display socket forwarding plus device access; neither works on macOS or Windows | ❌ *interactively* |
| C — everything on the host, no container | The pre-ADR-0005 world | Reintroduces toolchain drift, which is the problem | ❌ |

**Why A.** The split follows a clean line: **the container owns anything that changes
the bytes; the host owns anything that only looks at them.** Compiler, assembler,
linker, `xorriso`, `mtools` and Limine all change the artefact, so they are pinned.
QEMU consumes a finished artefact — its version does not change what you built. You can
see the split in the `Makefile`: build targets are prefixed with the container runner,
run targets are not.

```make
all: configure
	$(RUNQ) cmake --build $(BUILD_DIR) -j $(JOBS)

run: iso
	$(QEMU) -cdrom $(BUILD_DIR)/os.iso -m $(QEMU_MEM) -smp $(QEMU_SMP) \
	    -serial stdio -no-reboot -no-shutdown
```

**Why not B, interactively.** Three obstacles, in order of severity:

1. **Acceleration does not cross the boundary.** KVM needs `/dev/kvm` passed in plus
   matching group permissions, and exists only on Linux hosts. macOS accelerates
   through the Hypervisor framework and Windows through WHPX — neither is visible to a
   Linux container. On both of your machines this means pure software emulation.
2. **GUI output needs a display socket** forwarded (`-e DISPLAY`, `-v /tmp/.X11-unix`,
   plus `xhost` permissions), and macOS has no X server without XQuartz and loosened
   access control. That is a lot of configuration to keep working on two operating
   systems, for a window.
3. It buys nothing — you would be pinning a component whose version does not affect the
   artefact.

**The honest caveat.** QEMU's version is not *entirely* irrelevant: it fixes the device
models, the ACPI tables the guest sees, and the SeaBIOS and OVMF builds in play. So this
is a tradeoff, not a free win — and it is mitigated. CI runs QEMU **inside** the
container, headless, with `-display none`, which makes the authoritative boot test
reproducible. That is why the Dockerfile installs `qemu-system-x86` and `ovmf` even
though you never use them interactively. The host QEMU is for interactive work, where a
window and acceleration matter more than byte-identical behaviour.

**When B would be right.** It already is, for CI. Also on a headless remote build box,
where you would use `-display none -serial stdio` anyway and there is no display to
forward.

**When C would be right.** A throwaway experiment on one machine that will never be
shared. Not this project.

---

### Decision: pin the image by tag, or by digest?

| Option | How it works | Cost | Verdict |
|---|---|---|---|
| **A (chosen for now) — `:latest`** | `TOOLCHAIN ?= ghcr.io/cracked-f/os-toolchain:latest` | The tag floats; two machines can hold different images under one name | ✅ *today* |
| B — digest | `ghcr.io/cracked-f/os-toolchain@sha256:<64 hex>` | Every toolchain update becomes a commit touching the `Makefile` and workflows | ✅ *before you rely on reproducibility* |
| C — immutable version tag | `:14.2.0-2`, never overwritten, by convention | Convention, not enforcement — nothing stops a re-push | ⚠️ middle ground |

**Why A today.** On day one there may be no published image at all; you are running
`make toolchain` locally and iterating on the Dockerfile. Pinning a digest you are about
to invalidate is friction with no benefit.

**Why B before long — and exactly what goes wrong without it.** A tag is a mutable
pointer, resolved to an image at **pull time** and never re-resolved: `docker run` uses
the local copy if a matching name exists. So:

- You pull on Monday and get image **N**.
- The Dockerfile is updated; CI publishes **N+1** under the same tag.
- Your teammate pulls on Thursday and gets **N+1**.
- CI runs on a fresh runner and always pulls the newest: **N+1**.
- You are still on **N**, and nothing anywhere says so.

You are now back in the situation [[ADR-0005 - Containerised Pinned Toolchain]] was
written to prevent — three environments, different compilers — except worse, because
you *believe* they are identical and will not suspect the toolchain. It surfaces as
"works on my machine" from inside the system whose selling point was eliminating that
sentence.

A digest is a content hash: `@sha256:...` names exactly one immutable image, verified on
pull, and a mismatch is an error rather than a silent substitution. And
`make verify-repro` — which builds twice and diffs the artefacts, with
`SOURCE_DATE_EPOCH` forwarded into the container for timestamp determinism — is
meaningless while the image underneath can change between the two builds. Digest pinning
is the precondition for that check meaning anything. The toolchain workflow prints the
digest after every build, so adopting it is copy-and-paste, and the "cost" — a reviewed
commit per toolchain change — is the feature.

**Why not C.** A version tag you promise never to overwrite beats `:latest` and loses to
a digest for one reason: nothing enforces the promise. Registries allow re-pushing a
tag, and the first time someone fixes "just one thing" and re-pushes `:14.2.0-2` you
have floating tags again, with extra confidence.

**When A stays right.** While you are actively editing the Dockerfile, and any time you
deliberately want the newest image. The switch point is the moment you first need to say
"my build and yours are the same" and be believed.

---

## 4. Specification

### What must be true when this stage is done

| # | Claim | Where | Proof |
|---|---|---|---|
| 1 | Docker runs | host | `docker --version` |
| 2 | The container starts and mounts the repo | host | `make shell`, then `pwd` → `/os` |
| 3 | The container is `linux/amd64` | container | `uname -m` → `x86_64` |
| 4 | The cross-compiler exists, pinned version | container | `x86_64-elf-g++ --version` |
| 5 | It targets `x86_64-elf` | container | `x86_64-elf-g++ -dumpmachine` |
| 6 | Cross-binutils exist, pinned version | container | `x86_64-elf-ld --version` |
| 7 | Limine's UEFI binary is present | container | `ls "$LIMINE_DIR/BOOTX64.EFI"` |
| 8 | The kernel flag set compiles cleanly | container | the command in §5 |
| 9 | The output is a 64-bit x86-64 ELF object | container | `file probe.o` |
| 10 | QEMU runs | host | `qemu-system-x86_64 --version` |
| 11 | UEFI firmware is available | host | `ls /usr/share/OVMF/` |

### Pinned versions and paths (from `toolchain/Dockerfile`)

| Component | Value | Set by |
|---|---|---|
| Base image | `ubuntu:24.04` | `FROM` |
| binutils | **2.43** | `ARG BINUTILS_VERSION` |
| GCC (C and C++ only) | **14.2.0** | `ARG GCC_VERSION` |
| Limine | **`v8.6.0-binary`** | `ARG LIMINE_VERSION` |
| Target triple | **`x86_64-elf`** | `ARG TARGET` |
| Cross-tool prefix | `/opt/cross` (first on `$PATH`) | `ARG PREFIX` |
| `$LIMINE_DIR` | `/opt/limine` — `BOOTX64.EFI`, BIOS stages, deploy tool | `ENV` |
| `$CCACHE_DIR` | `/ccache`, from the named volume `os-ccache` | `ENV` |
| Working directory | `/os` — the bind-mounted repository | `WORKDIR` |
| NASM / CMake | 2.16.01 / 3.28.3, from `ubuntu:24.04` | `apt-get` |
| QEMU | **8.2.2**, on the **host** | your host package manager |

### Container invocation (from the `Makefile`)

```
docker run --rm -it \
    -v "$(CURDIR):/os" \        # the repo — same inodes inside and out
    -v os-ccache:/ccache \      # persistent compile cache
    -w /os \
    -e CONTAINER=1 \            # so a nested `make` does not re-enter Docker
    -e SOURCE_DATE_EPOCH \      # forwarded for reproducible-build checks
    ghcr.io/cracked-f/os-toolchain:latest
```

`--rm` deletes the container on exit; anything outside `/os` and `/ccache` dies with it.
That is exactly the property `probe.cpp` should have.

### The kernel compile flags

The full production set, from `cmake/KernelFlags.cmake` and
[[ADR-0007 - Freestanding C++20 as the Kernel Language]]:

```
-ffreestanding -fno-exceptions -fno-rtti -fno-stack-protector
-fno-pic -fno-pie -mcmodel=kernel -mno-red-zone
-mno-sse -mno-mmx -mno-80387 -std=c++20 -Wall -Wextra -Werror
```

| Flag | Turns off / changes | Symptom if omitted | Bites at |
|---|---|---|---|
| `-ffreestanding` | libc semantics for standard functions; `__STDC_HOSTED__` → 0 | the optimiser rewrites your loop into a `printf` call | compile / link |
| `-fno-exceptions` | `throw`/`try`, landing pads, personality routine | undefined `__gxx_personality_v0`, `__cxa_throw` | link |
| `-fno-rtti` | `typeid`, `dynamic_cast`, typeinfo objects | undefined `__cxxabiv1::__class_type_info` | link, once a class is polymorphic |
| `-fno-stack-protector` | canary load from `%fs:0x28`, `__stack_chk_fail` | fault on the first guarded function | run time, immediately |
| `-fno-pic -fno-pie` | position-independent codegen, GOT addressing | GOT-relative loads against a GOT nobody built | link / run time |
| `-mcmodel=kernel` | assumes symbols live in the top 2 GiB | `relocation truncated to fit: R_X86_64_32S` | link (Stage 0.4) |
| `-mno-red-zone` | the 128-byte scratch area below `%rsp` | random, unreproducible memory corruption | run time, weeks later |
| `-mno-sse` | XMM registers and SSE instructions | `#UD` if `CR4.OSFXSR` is clear; FPU state to save per switch | run time |
| `-mno-mmx` | MMX registers (aliased onto the x87 stack) | as above | run time |
| `-mno-80387` | x87 FPU, `long double` | as above | run time |
| `-std=c++20` | language version (GCC 14 defaults to `gnu++17`) | designated initialisers rejected in Stage 0.2 | compile |
| `-Wall -Wextra -Werror` | nothing — makes warnings fatal | a warning nobody reads becomes a fault nobody explains | compile |

### Expected ELF header of `probe.o`

| Field | Value | Meaning |
|---|---|---|
| Magic | `7f 45 4c 46` | `\x7fELF` |
| Class | `ELF64` | `EI_CLASS = 2` |
| Data | `2's complement, little endian` | `EI_DATA = 1` |
| OS/ABI | `UNIX - System V` | `EI_OSABI = 0` |
| Type | `REL (Relocatable file)` | `e_type = 1` — an object, not an executable |
| Machine | `Advanced Micro Devices X86-64` | `e_machine = 62` (`EM_X86_64`) |
| Entry point | `0x0` | objects have none |
| Program headers | `0` | objects have none; only linked images do |

### The long-mode interrupt stack frame

Written **below** the interrupted code's `%rsp`, after the CPU aligns it down to a
16-byte boundary (which alone can consume up to 15 bytes).

| Offset from `%rsp` | Contents | Pushed by |
|---|---|---|
| `-8` | `SS` | CPU — **always** in long mode, even with no privilege change |
| `-16` | `RSP` | CPU |
| `-24` | `RFLAGS` | CPU |
| `-32` | `CS` | CPU |
| `-40` | `RIP` | CPU |
| `-48` | error code | CPU, for vectors that have one (`#PF`, `#GP`, `#DF`, …) |
| `-56` | vector number | your ISR stub |
| `-56 … -176` | 15 general-purpose registers | your ISR stub |

Roughly **176 bytes**, against a 128-byte red zone. Every byte of it is in the blast
radius.

---

## 5. Writing the code

### `probe.cpp` — throwaway

One file, written inside the container in `/tmp` so it cannot reach the repository. Its
job is to fail loudly if the wrong compiler or the wrong flags are in play, and to emit
one function whose disassembly proves the red zone is off.

```sh
make shell          # you are now at /os inside the container
cd /tmp             # NOT /os — /os is the bind-mounted repo
```

```cpp
// probe.cpp — Stage 0.1 smoke test. Throwaway. Not kernel code.
// Compiled, inspected, deleted. Nothing here ships.

// --- 1. Refuse a hosted host compiler --------------------------------------
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#  error "A hosted host compiler is compiling this. You wanted x86_64-elf-g++."
#endif

#if __STDC_HOSTED__ != 0
#  error "Hosted mode: -ffreestanding is missing from the command line."
#endif

// --- 2. Refuse the wrong machine or object format --------------------------
#if !defined(__x86_64__)
#  error "Not an x86_64 target. Check x86_64-elf-g++ -dumpmachine."
#endif

#if !defined(__ELF__)
#  error "Not an ELF target. Mach-O and PE cannot be linked into this kernel."
#endif

#if defined(__ILP32__)          // the x32 ABI: 64-bit CPU, 32-bit pointers
#  error "x32 ABI selected. Pointers are 32-bit. Drop -mx32."
#endif

// --- 3. Sizes the kernel will assume everywhere ----------------------------
static_assert(sizeof(void*)         == 8, "64-bit pointers required");
static_assert(sizeof(unsigned long) == 8, "LP64 data model expected");
static_assert(sizeof(int)           == 4, "32-bit int expected");
static_assert(__CHAR_BIT__          == 8, "8-bit bytes expected");

// --- 4. A leaf function that needs one stack slot --------------------------
// Read this in the disassembly: it is where the red zone shows up, or does not.
unsigned long probe(unsigned long x) {
    volatile unsigned long tmp = x * 3;   // volatile => must live in memory
    return tmp + 1;
}

// --- 5. The empty function from the original smoke test --------------------
void probe_empty() {}
```

#### Line by line

**Lines 5–7 — the hosted-compiler guard**

```cpp
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#  error "A hosted host compiler is compiling this. You wanted x86_64-elf-g++."
#endif
```

Every hosted compiler advertises its OS through a predefined macro: Ubuntu's GCC
defines `__linux__` (and `__unix__`, `__gnu_linux__`), Apple's clang defines `__APPLE__`
and `__MACH__`, MSVC defines `_WIN32`. `x86_64-elf-g++` defines none, because its triple
has no OS field. If one is defined the wrong compiler is running and the build stops
here with a sentence — instead of producing a plausible object you will trust for three
stages. This is the first trap in §7 turned into a compile error.

**Lines 9–11 — the freestanding guard**

```cpp
#if __STDC_HOSTED__ != 0
#  error "Hosted mode: -ffreestanding is missing from the command line."
#endif
```

`__STDC_HOSTED__` is 1 in a hosted implementation and 0 in a freestanding one; GCC sets
it to 0 under `-ffreestanding`. This catches the right compiler with the wrong flags.

One subtlety worth internalising, because it recurs: **an undefined macro evaluates to 0
in a preprocessor `#if`.** If `__STDC_HOSTED__` were not defined at all this test would
silently pass. Guards written this way fail loudly but never fail safely — which is why
§6 also dumps the macros with `-dM -E`. The dump is authoritative; the `#error` is the
convenience.

**Lines 14–24 — machine, format, and data model**

```cpp
#if !defined(__x86_64__)
#  error "Not an x86_64 target. Check x86_64-elf-g++ -dumpmachine."
#endif

#if !defined(__ELF__)
#  error "Not an ELF target. Mach-O and PE cannot be linked into this kernel."
#endif

#if defined(__ILP32__)          // the x32 ABI: 64-bit CPU, 32-bit pointers
#  error "x32 ABI selected. Pointers are 32-bit. Drop -mx32."
#endif
```

`__x86_64__` is defined by any compiler generating x86-64 code, catching an i686 or
`aarch64` toolchain. `__ELF__` is defined by GCC when the target's object format is ELF
— the compile-time twin of the `file` check, catching an Apple toolchain before you get
that far. Verify both are genuinely defined with the `-dM` dump in §6; if one is missing
on your toolchain, fix the guard, not the compiler.

`__ILP32__` catches x32: a 64-bit instruction set with 32-bit pointers. `file` would
still say "64-bit" and `__x86_64__` would still be defined, but every pointer would be
four bytes — which cannot address a higher-half kernel at `0xFFFFFFFF80000000` at all.

**Lines 27–30 — the size assertions**

```cpp
static_assert(sizeof(void*)         == 8, "64-bit pointers required");
static_assert(sizeof(unsigned long) == 8, "LP64 data model expected");
static_assert(sizeof(int)           == 4, "32-bit int expected");
static_assert(__CHAR_BIT__          == 8, "8-bit bytes expected");
```

`static_assert` is a compile-time check with no runtime cost and no runtime dependency,
which makes it one of the few C++ features unconditionally appropriate in kernel code.
These four pin the data model: **LP64** — `long` and pointers are 64 bits, `int` stays
32. Page-table entries, physical addresses and MMIO register layouts in later phases all
assume exactly this. The pattern matters more than the four lines: from Phase 2 onward
every hardware structure gets a `static_assert(sizeof(...) == N)` beside it, so a
mislaid field is a build error rather than a triple fault.

**Lines 34–37 — the leaf function**

```cpp
unsigned long probe(unsigned long x) {
    volatile unsigned long tmp = x * 3;   // volatile => must live in memory
    return tmp + 1;
}
```

Three deliberate properties. **It is a leaf** — it calls nothing, and the red zone is
where GCC puts a leaf function's frame. **`volatile` forces a memory slot**: without it
the optimiser keeps `tmp` in a register, the function needs no stack at all, and the
red-zone test in §6 shows nothing because there is nothing to show. And it **returns a
value derived from `tmp`**, so the store cannot be eliminated as dead.

This is the function you disassemble. With the red zone available, the store goes to a
negative offset from `%rsp` and `%rsp` never moves. With `-mno-red-zone`, `%rsp` moves
first — a `sub` or a `push` — and the store lands above it.

**Line 40 — the empty function**

```cpp
void probe_empty() {}
```

Preserved from the original smoke test: a symbol with a trivial body.
`x86_64-elf-objdump -d probe.o` should show it as a `ret`, possibly with a frame-pointer
prologue at `-O0`. If even this surprises you, stop.

---

### The compile command

```sh
x86_64-elf-g++ -ffreestanding -fno-exceptions -fno-rtti \
    -mno-red-zone -mno-sse -mno-mmx -mno-80387 -mcmodel=kernel \
    -std=c++20 -c probe.cpp -o probe.o
```

Silence and exit status 0 is success. Now the flags, one at a time.

#### `-ffreestanding`

Declares that the program does not run under an operating system. In GCC:
`__STDC_HOSTED__` becomes 0; the program need not have a `main`, and `main` gets no
special treatment; and `-fno-builtin` is implied, so the compiler stops assuming a
function named `printf`, `strlen` or `abs` has the standard meaning and stops
substituting its own optimised version.

That last point is the one that bites. Without it the compiler may recognise patterns in
your code and *rewrite them into libc calls* — a hand-written byte-copy loop can legally
become a call to `memcpy`. In a hosted program that is a free optimisation. In a kernel
it is an undefined reference to a function you never wrote and, if you did write one, a
call at a point where you may not be ready for one.

**Know the exception.** Even with `-ffreestanding`, GCC still reserves the right to emit
calls to four functions: `memcpy`, `memmove`, `memset` and `memcmp`. No flag fully
prevents this — the code generator uses them for structure assignment and array
initialisation — so the kernel must *provide* those four, a job for
[[Stage 0.3 - Freestanding C++ and kmain]]. It does not matter today because nothing
here copies a structure. Note it now so the eventual undefined reference to `memset` is
recognised in ten seconds rather than an hour.

#### `-fno-exceptions`

Removes C++ exception support: `throw`, `try` and `catch` become compile errors, and the
compiler stops generating the machinery behind them — landing pads, cleanup paths,
`.gcc_except_table` entries, and references to `__gxx_personality_v0`, `_Unwind_Resume`
and `__cxa_throw`. Those symbols live in `libsupc++`/`libstdc++`, which the kernel does
not link, so without this flag the first `try` block — or the first destructor that must
run during unwinding — produces undefined references at link time.

The deeper reason: exceptions are not implementable here even if you linked the runtime.
Throwing requires an unwinder that walks the stack interpreting DWARF metadata, plus the
heap (`__cxa_allocate_exception`). Neither is available in an interrupt handler, which
is where kernel failures happen. Kernel error handling is return codes and `KASSERT` —
see [[Stage 0.7 - Panic and KASSERT]].

**One detail that will confuse you in Stage 0.4.** `-fno-exceptions` does not
necessarily stop a `.eh_frame` section appearing: on x86-64, GCC enables
`-fasynchronous-unwind-tables` by default because the psABI expects unwind information
for debuggers and profilers, emitted independently of exceptions. It is harmless and the
linker script can discard it. Check what you actually got with
`x86_64-elf-readelf -S probe.o | grep -E 'eh_frame|gcc_except'`. `.eh_frame` present is
expected; `.gcc_except_table` present means `-fno-exceptions` did not take effect.

#### `-fno-rtti`

Removes run-time type information: `typeid` and `dynamic_cast` become compile errors,
and the compiler stops emitting the `typeinfo` objects polymorphic classes otherwise
carry. Those objects reference vtables belonging to `__cxxabiv1::__class_type_info` and
its siblings, which live in `libsupc++`. The failure mode is specific and confusing:
everything links until you give a class a virtual function, and then you get an
undefined reference to a mangled name you have never seen, in a file you did not change.

The probe has no classes, so this does nothing today. It is in the command because it is
in the kernel flag set, and because the cost is zero — RTTI buys dynamic downcasting,
which a kernel with no class hierarchies to speak of does not want.

#### `-mno-red-zone`

The most important flag in the set, and the only one whose absence produces a bug you
cannot debug.

**What the red zone is.** The System V AMD64 ABI reserves the 128 bytes *below* the
stack pointer:

> The 128-byte area beyond the location pointed to by `%rsp` is considered to be
> reserved and shall not be modified by signal or interrupt handlers. Therefore,
> functions may use this area for temporary data that is not needed across function
> calls. In particular, leaf functions may use this area for their entire stack frame,
> rather than adjusting the stack pointer in the prologue and epilogue.

So a leaf function needing 16 bytes of scratch does not adjust `%rsp` at all — it writes
at `-8(%rsp)` and `-16(%rsp)`:

```
   higher addresses
        │   [ caller's frame                ]
        ├──────────────────────────────  %rsp ← never moved
        │   -8    [ tmp              ]  ┐
        │   -16   [ scratch          ]  │  the 128-byte RED ZONE:
        │   -24   [ spilled register ]  │  the leaf frame lives here
        │    ...                        │
        │   -128  [ ...              ]  ┘
        ├──────────────────────────────
   lower addresses
```

It saves two instructions per leaf call — a `sub` and an `add`. Small, real, and why the
ABI has it.

**Why it works in user space.** The rule holds because the *kernel* upholds it. When
Linux delivers a signal it deliberately skips 128 bytes below the user `%rsp` before
building the signal frame: the one entity capable of writing below your stack pointer
has been told not to. And a hardware interrupt arriving while user code runs does not
touch the user stack at all — the CPU switches to the kernel stack from `RSP0` in the
TSS on the privilege transition.

**Why it fails catastrophically in kernel space.** There is nobody above you to uphold
the rule. When an interrupt arrives while the CPU is *already* in ring 0 there is no
privilege change, so there is no stack switch. The CPU aligns `%rsp` down to 16 bytes
and starts pushing the interrupt frame right there — into the red zone of whatever
function was running:

```
   ──────────────────────────────  %rsp at the moment of the interrupt
        -8    [ SS         ]   ← CPU. In long mode SS:RSP are pushed
        -16   [ RSP        ]     unconditionally, even with no CPL change.
        -24   [ RFLAGS     ]
        -32   [ CS         ]
        -40   [ RIP        ]
        -48   [ error code ]   ← for #PF, #GP, #DF, …
        -56   [ vector     ]   ← your ISR stub
        -64   [ rax        ]   ┐
         ...                   │ 15 general-purpose registers
        -176  [ r15        ]   ┘
   ──────────────────────────────
```

About 176 bytes against a 128-byte red zone. The interrupt does not corrupt *part* of it
— it can obliterate all of it, and the alignment adjustment can eat up to 15 more bytes
before the first push happens. Then the ISR returns with `iret`, `%rsp` goes back where
it was, the interrupted leaf function resumes and reads `-8(%rsp)` — which now holds the
low half of a saved segment selector, or part of an `RFLAGS` value, or a register from
an unrelated context.

**Why this specific bug is so expensive.** Four things must line up:

1. The function must be a leaf that needed stack space — a minority of functions.
2. The compiler must have chosen the red zone for it — mostly at `-O1` and above, so
   your debug build can be clean while your release build is broken.
3. An interrupt must arrive in the exact window between the store and the load — a
   handful of instructions.
4. The corrupted value must then be *used* in a way that produces visible damage,
   possibly much later, possibly in a different subsystem.

Every one is probabilistic, so the bug does not reproduce. It appears as a wrong value in
a struct nobody wrote to, a pointer that is almost right, a counter that skips. You will
chase it in the *innocent* code where the damage surfaced — not in the function that was
interrupted, and not in the file compiled without the flag. And the flag was probably
lost weeks earlier: a new file added to `CMakeLists.txt` with a hand-written flag list,
or one object built by a rule somebody wrote quickly.

**Four things that do not save you:**

- **`cli` does not.** Non-maskable interrupts and machine-check exceptions ignore the
  interrupt flag. "I disabled interrupts here" is not a defence.
- **The IST does not.** The Interrupt Stack Table switches to a known-good stack for
  vectors you configure to use it. The corruption is on the *interrupted* function's
  stack, before any switch is decided.
- **Compiling the ISRs correctly does not.** The flag protects the code that gets
  interrupted, which is every function in the kernel.
- **One file is enough.** A single translation unit compiled without `-mno-red-zone`
  arms the whole kernel. That is why CI greps for the flag on every kernel compile
  command from [[Stage 0.9 - CI From Day One]] onward, and why
  [[ADR-0007 - Freestanding C++20 as the Kernel Language]] calls forgetting it "both
  easy and devastating".

**What it costs.** A `sub $N, %rsp` and a matching `add` in leaf functions that need
stack space. Unmeasurable.

**Do not assume `-mcmodel=kernel` implies it.** Some GCC configurations disable the red
zone under the kernel code model; do not rely on it. Linux passes both flags explicitly
and so do we. §6 shows how to check rather than believe.

**Forward note.** The red zone is *correct* for user space. When we eventually deliver
signals to user programs, our signal-frame setup must skip 128 bytes below the user
`%rsp` exactly as Linux does, or user programs break the same unreproducible way. The
prohibition is kernel-only.

#### `-mno-sse -mno-mmx -mno-80387`

Three flags, one policy: **the kernel touches no register outside the general-purpose
file.** `-mno-sse` bars the XMM registers and SSE instructions, `-mno-80387` bars the x87
FPU and `long double`, `-mno-mmx` bars MMX — whose registers are aliased onto the x87
stack. Two independent problems are prevented.

**Those units may not be enabled.** SSE instructions raise `#UD` (invalid opcode) unless
`CR4.OSFXSR` is set, and x87 behaviour depends on `CR0.EM`, `CR0.MP` and `CR0.TS`. At
CPU reset none of that is configured, and a `#UD` before you have an IDT is a triple
fault — a silent reboot with no message. Limine's `PROTOCOL.md` documents which
control-register bits are set when your kernel is entered; check it if you are curious,
but the question does not arise for us because we never use those units.

**Their state must be saved.** SSE and x87 registers are part of the ABI and part of a
thread's context. If kernel code uses them, every context switch and every interrupt
that can preempt kernel code must save and restore 512 bytes of `FXSAVE` state — a large
cost on the hottest path in the system, for functionality a kernel does not need. There
is no floating point in a page-table walk.

**The best part is what happens when you slip.** With `-mno-sse`, the SysV ABI's
floating-point argument and return registers (`xmm0`–`xmm7`) are unavailable, so GCC
cannot compile a function taking or returning a `double`. You get an error — "SSE
register return with SSE disabled" — at the exact line. Without the flag you get a clean
compile and a triple fault at boot. The flag converts a runtime disaster into a compile
error, the best trade available anywhere in this list.

One caution: `-mno-sse` also removes the compiler's fastest block-copy strategy, so
struct assignment falls back to integer moves or a `memcpy` call — see the
`-ffreestanding` note about the four functions the kernel must provide. (GCC also has a
single switch forbidding all non-general-purpose registers at once; check with
`x86_64-elf-g++ --help=target | grep general-regs`. We use the explicit trio because it
is what ADR-0007 names, and because three flags document three intentions.)

#### `-mcmodel=kernel`

A **code model** is a promise about where symbols will end up in the address space, which
decides how the compiler generates addresses. It matters because x86-64 has no cheap
single-instruction way to load an arbitrary 64-bit address.

| Model | Assumes symbols live in | Addressing generated |
|---|---|---|
| `small` (default) | the low 2 GiB, `[0, 2³¹)` | 32-bit zero-extended immediates, RIP-relative |
| `kernel` | the **top** 2 GiB, `[-2³¹, 0)` | 32-bit **sign-extended** immediates, RIP-relative |
| `medium` | small code, large data | mixed |
| `large` | anywhere | full 64-bit `movabs` everywhere — bigger and slower |

Our kernel is linked at `0xFFFFFFFF80000000`, the top 2 GiB, chosen precisely so this
model applies (see [[ADR-0002 - Target x86_64 Not i686]] and
[[Stage 0.4 - The Linker Script and Higher-Half Layout]]). Sign extension is the trick:
`0xFFFFFFFF80000000` is `0x80000000` sign-extended to 64 bits, so a 32-bit displacement
can still name it, instructions stay short, and addressing stays RIP-relative.

**What goes wrong without it.** With the default `small` model the compiler emits 32-bit
*zero*-extended relocations for addresses that will sit above `0xFFFFFFFF00000000`. The
value does not fit, and the linker says so:

```
relocation truncated to fit: R_X86_64_32S against symbol `kmain'
```

That is the good case — a loud failure at **link** time in Stage 0.4, not a runtime
mystery. Today, with `-c`, the flag has no visible effect at all. It is in the command so
the command matches the real build.

#### `-std=c++20`

Selects the language standard. GCC 14 defaults to `gnu++17`, so without this you get a
different language than [[ADR-0007 - Freestanding C++20 as the Kernel Language]]
specifies — and a different one from your teammate if they type it differently. C++20
specifically buys, in kernel context: **designated initialisers** (`.field = value`) as
standard C++ rather than a GNU extension, used immediately in
[[Stage 0.2 - The Limine Request Section]] where initialising a field by name rather
than position is the difference between a bootloader that recognises your kernel and one
that silently ignores it; **concepts**, for readable constraints on the `kstd::`
containers of Phase 4; **`constinit`**, which asserts at compile time that a global needs
no dynamic initialisation — directly relevant, because global constructors do not run in
a kernel unless you call them yourself; and improved `constexpr`, which is how GDT, IDT
and page-flag tables get built at compile time at no runtime cost.

Note it is `c++20`, not `gnu++20`: the GNU dialects enable extensions that are not
portable and, more importantly, not what CI will use if someone writes it differently.

#### `-c` and `-o probe.o`

`-c` means compile and assemble but **do not link**. That is the entire reason this stage
works with no linker script, no entry point, no `main` and no C library — none of those
are needed until link time. `-o` names the output; you would get `probe.o` anyway, but
naming it is a habit worth having when the current directory might be a bind mount.

#### The flags this command omits

The production set has four more. They are absent here only because they do nothing
observable to a single `-c` of this file — not because they are optional.

- **`-fno-stack-protector`** cancels Ubuntu-GCC's default `-fstack-protector-strong`. Our
  cross-compiler was not configured with that default, so it is already off; the flag is
  there so the build does not silently depend on how the compiler was built. The failure
  it prevents is concrete: the canary is loaded from `%fs:0x28`, and in kernel context at
  boot `%fs` is not a thread-control block, so the load faults — and `__stack_chk_fail`,
  which it wants to call, does not exist.
- **`-fno-pic -fno-pie`** cancels position-independent code generation. A PIE build
  reaches globals through a Global Offset Table a dynamic loader is expected to populate.
  There is no loader; the kernel is linked at one fixed address and loaded there, so
  absolute addressing is both correct and cheaper.
- **`-Wall -Wextra -Werror`** makes warnings fatal. The usual argument against `-Werror`
  is weaker here, because the warnings GCC gives you (uninitialised use, sign-compare,
  unused result, missing field initialiser) map almost one-to-one onto faults with no
  diagnostics. See [[13 - Coding Standards]].
- **`-nostdlib`** is a **link-time** option — passing it alongside `-c` does nothing at
  all. It becomes load-bearing the moment you produce an executable, where it suppresses
  the standard start-up files and default libraries. The original smoke test names the
  pairing `-ffreestanding -nostdlib -c`, which is the right thing to memorise as long as
  you know which half acts when.

---

## 6. How to verify

### On the host, first

```sh
docker --version                 # any version; "command not found" fails
qemu-system-x86_64 --version     # QEMU emulator version 8.2.2 (Debian 1:8.2.2+ds-...)
```

If `docker` is not found on Windows, Docker Desktop is not running or WSL2 integration is
not enabled for your Ubuntu distribution (Settings → Resources → WSL Integration).

### Enter the container and check every tool

```sh
cd ~/os && make shell            # the WSL filesystem, NOT /mnt/c
```
```sh
uname -m                               # x86_64   ← if aarch64, see §7
x86_64-elf-gcc --version | head -1     # x86_64-elf-gcc (GCC) 14.2.0
x86_64-elf-g++ --version | head -1     # x86_64-elf-g++ (GCC) 14.2.0
x86_64-elf-ld  --version | head -1     # GNU ld (GNU Binutils) 2.43
nasm --version                         # NASM version 2.16.01 ...
cmake --version | head -1              # cmake version 3.28.3
ls "$LIMINE_DIR/BOOTX64.EFI"           # /opt/limine/BOOTX64.EFI
```

Versions must match the `ARG`s in `toolchain/Dockerfile`. If GCC reports 13.x you are
looking at the container's *system* compiler, not the cross-compiler.

### The compiler targets what you think it does

```sh
x86_64-elf-g++ -dumpmachine                  # x86_64-elf
command -v x86_64-elf-g++                    # /opt/cross/bin/x86_64-elf-g++
x86_64-elf-g++ -print-file-name=libgcc.a     # /opt/cross/lib/gcc/x86_64-elf/14.2.0/libgcc.a
```

`libgcc.a` resolving to a real path matters: the Dockerfile builds `all-target-libgcc` so
the kernel can link the compiler builtins. If this prints just `libgcc.a` with no
directory it was not installed, and Stage 0.4 fails with undefined references to symbols
like `__udivti3`.

```sh
x86_64-elf-g++ -ffreestanding -std=c++20 -mcmodel=kernel -dM -E -x c++ /dev/null | \
    grep -E '__ELF__|__x86_64__|__STDC_HOSTED__|__SIZEOF_POINTER__|__linux__|code_model'
```

Expect `__ELF__ 1`, `__x86_64__ 1`, `__STDC_HOSTED__ 0`, `__SIZEOF_POINTER__ 8`, and
**no** `__linux__`. This is the authoritative check, because a `#if` guard on a macro
that does not exist passes silently.

### There is no host libc on the include path

```sh
echo '#include <stdio.h>' | x86_64-elf-g++ -ffreestanding -std=c++20 -x c++ -c - -o /dev/null
```
```
<stdin>:1:10: fatal error: stdio.h: No such file or directory
```

**The error is the pass.** The cross-compiler was built `--without-headers`, so there is
no target C library to accidentally include from. Run the same line with `g++` and it
succeeds — exactly the silent wrongness a cross-compiler prevents. Now check what *is*
available:

```sh
for h in stdint.h stddef.h stdarg.h type_traits; do
  echo "#include <$h>" | x86_64-elf-g++ -ffreestanding -std=c++20 -x c++ -c - -o /dev/null \
    && echo "$h OK" || echo "$h MISSING"
done
```

The first three come with the *compiler* — GCC ships its own freestanding headers
(`stdint.h`, `stddef.h`, `stdarg.h`, `limits.h`, `float.h`, …) which need no library.
`<type_traits>` comes from **libstdc++**, which the image builds only as far as
`all-target-libgcc`. If it is missing, that is a real gap between the Dockerfile and
[[ADR-0007 - Freestanding C++20 as the Kernel Language]], and it lands in
[[Stage 0.3 - Freestanding C++ and kmain]]: either the image gains a freestanding
libstdc++ build, or the kernel uses `stdint.h` plus our own `kstd::` traits. Record the
answer — do not discover it three stages from now.

### The object is the right kind of object

```sh
cd /tmp && x86_64-elf-g++ -ffreestanding -fno-exceptions -fno-rtti \
    -mno-red-zone -mno-sse -mno-mmx -mno-80387 -mcmodel=kernel \
    -std=c++20 -c probe.cpp -o probe.o
file probe.o
```
```
probe.o: ELF 64-bit LSB relocatable, x86-64, version 1 (SYSV), not stripped
```

Four words carry the result: **ELF**, **64-bit**, **relocatable**, **x86-64**.

**The three wrong answers:**

| `file` says | Diagnosis | Fix |
|---|---|---|
| `Mach-O 64-bit object arm64` (or `x86_64`) | Apple's compiler ran — you are outside the container, or `PATH` found `/usr/bin/c++`. Mach-O can never be linked into this kernel. | `make shell` first; check `command -v x86_64-elf-g++` |
| `ELF 64-bit LSB relocatable, x86-64` from a **Linux system compiler** — with `for GNU/Linux x.y.z`, or `(GNU/Linux)` in place of `(SYSV)` | The hosted `x86_64-linux-gnu` compiler ran | use `x86_64-elf-g++`; confirm with `-dumpmachine` |
| `ELF 32-bit LSB relocatable, Intel 80386` | Wrong target: an i686 toolchain, or `-m32` on the command line. Nothing 32-bit can boot this kernel. | check `ARG TARGET=x86_64-elf` and `-dumpmachine` |

**Be precise about the second row, because it can fool you.** For a plain `-c` object the
system compiler's `file` output is often *identical* to the cross-compiler's — both say
`(SYSV)`, because the ELF header's OS/ABI byte is 0 in both. The `GNU/Linux` marker
appears in two situations: as `for GNU/Linux x.y.z` once you **link an executable** with
the system toolchain (from the `.note.ABI-tag` section glibc's start-up files
contribute), and as `(GNU/Linux)` on an object whose OS/ABI byte is `ELFOSABI_GNU`
because it uses a GNU-specific feature such as an IFUNC or a unique symbol. So `file`
catches macOS and 32-bit unambiguously but may *not* distinguish the two Linux compilers.
`-dumpmachine` always does. Use `file` as the fast check and `-dumpmachine` as the proof.

### The ELF header and the symbols

```sh
x86_64-elf-readelf -h probe.o
```
```
  Class:                             ELF64
  Data:                              2's complement, little endian
  OS/ABI:                            UNIX - System V
  Type:                              REL (Relocatable file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0x0
  Number of program headers:         0
```
```sh
x86_64-elf-nm probe.o
```
```
0000000000000000 T _Z5probem
0000000000000010 T _Z11probe_emptyv
```

`Class`, `Type` and `Machine` must be exact — compare against §4. The two `T` symbols are
`probe(unsigned long)` and `probe_empty()`, C++-mangled (`x86_64-elf-nm -C` demangles).
Mangling is why the Limine request symbols in [[Stage 0.2 - The Limine Request Section]]
need `extern "C"`, and that is much easier to remember having seen this output.

### The red zone really is off

The check nobody does, and the one that matters. Compile twice, differing only in the
flag, and diff the assembly:

```sh
cd /tmp
x86_64-elf-g++ -O2 -ffreestanding -std=c++20               -S probe.cpp -o with-redzone.s
x86_64-elf-g++ -O2 -ffreestanding -std=c++20 -mno-red-zone -S probe.cpp -o no-redzone.s
diff with-redzone.s no-redzone.s
```

They must differ inside `_Z5probem`, and the shape of the difference is the point:

- **With the red zone**, `%rsp` is never modified; the store to `tmp` goes to a negative
  offset — something like `movq %rax, -8(%rsp)`.
- **With `-mno-red-zone`**, `%rsp` moves *before* anything is written below it — a
  `subq $N, %rsp` or a `push` in the prologue, a matching `addq`/`pop` in the epilogue —
  and the store lands at a non-negative offset such as `8(%rsp)`.

Exact registers and offsets vary by GCC version; the presence or absence of the
stack-pointer adjustment does not. If the diff is empty, GCC kept `tmp` in a register —
check `volatile` is still there, or add two more locals. Read it from the object with
`x86_64-elf-objdump -d probe.o | head -30`. This same test is how you check whether
`-mcmodel=kernel` implies `-mno-red-zone` on *your* GCC: drop `-mno-red-zone`, add
`-mcmodel=kernel`, and look. Do not take anyone's word for it, including this note's —
pass both flags regardless.

### QEMU runs on the host

Exit the container, then `qemu-system-x86_64 -m 512M`. A window opens, SeaBIOS runs,
finds no bootable media and says so:

```
Booting from Hard Disk...
Boot failed: could not read the boot disk
Booting from DVD/CD...
Boot failed: Could not read from CDROM (code 0003)
No bootable device.
```

**That "error" is the pass** — QEMU launched, the BIOS executed, a display appeared.
Exact wording depends on the SeaBIOS build shipped with your QEMU. Close the window, or
press `Ctrl-Alt-2` for the QEMU monitor and type `quit`. If no window appears (headless
host, WSLg unavailable), use `qemu-system-x86_64 -m 512M -display none -monitor stdio`
and type `info status`, then `quit`.

### UEFI firmware is on the host

```sh
ls /usr/share/OVMF/
```

On Ubuntu 24.04 expect `OVMF_CODE_4M.fd` and `OVMF_VARS_4M.fd`. **Ubuntu renamed these**
— plain `OVMF_CODE.fd` may not exist, while the `Makefile` still defaults to
`OVMF_CODE ?= /usr/share/OVMF/OVMF_CODE.fd`. From
[[Stage 0.5 - Building a Bootable Image]] you will either override it
(`make run-uefi OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd`) or fix the default. Note it
now. The same rename is why the toolchain image build prints
`WARN: OVMF path differs on this base image`: expected, not a failure.

### Clean up

```sh
rm -f /tmp/probe.cpp /tmp/probe.o /tmp/*.s     # inside the container
exit
git status                                      # on the host — must be clean
```

If `git status` shows `probe.cpp` or `probe.o` you wrote them in `/os` instead of `/tmp`.
Delete them; nothing from this stage belongs in the repository.

### Checklist

- [ ] `docker --version` and `qemu-system-x86_64 --version` answer on the host
- [ ] `make shell` gives a prompt at `/os`; `uname -m` prints `x86_64`
- [ ] gcc/g++ report **14.2.0**, ld reports **2.43**, `$LIMINE_DIR/BOOTX64.EFI` exists
- [ ] `-dumpmachine` prints `x86_64-elf`; `-print-file-name=libgcc.a` returns a real path
- [ ] The macro dump shows `__STDC_HOSTED__ 0`, `__ELF__ 1`, no `__linux__`
- [ ] `#include <stdio.h>` fails; `stdint.h` succeeds; you recorded the `<type_traits>` answer
- [ ] The compile is silent and exits 0
- [ ] `file probe.o` → `ELF 64-bit LSB relocatable, x86-64`
- [ ] `readelf -h` → `ELF64` / `REL` / `Advanced Micro Devices X86-64`
- [ ] The `-mno-red-zone` diff shows `%rsp` moving before any store below it
- [ ] QEMU starts and reports no bootable device
- [ ] You know the exact OVMF filename on your host
- [ ] `git status` is clean

### What can only be checked later

| Claim | Checked in |
|---|---|
| `-mcmodel=kernel` produces linkable addressing at `0xFFFFFFFF80000000` | [[Stage 0.4 - The Linker Script and Higher-Half Layout]] |
| Limine recognises and loads the kernel | [[Stage 0.2 - The Limine Request Section]] |
| The image boots under both BIOS and UEFI | [[Stage 0.5 - Building a Bootable Image]] |
| The kernel actually executes | [[Stage 0.6 - Serial Output]] |
| Every translation unit gets the full flag set | [[Stage 0.9 - CI From Day One]] (a grep test) |
| `-mno-red-zone` prevented real corruption | never provable — only its absence is observable |

---

## 7. Common traps

**Symptom: everything compiles, `file` says `Mach-O 64-bit object arm64`.** Apple's
compiler ran — you are outside the container, or `PATH` resolved to `/usr/bin/c++`.
Mach-O can never become this kernel, and `ld64` cannot consume the linker script Stage
0.4 needs. Run `make shell`, then `command -v x86_64-elf-g++`.

**Symptom: `file` output looks right but the kernel misbehaves later.** You typed `gcc`
or `g++` out of habit inside the container and got the *system* compiler — Ubuntu 24.04's
hosted `x86_64-linux-gnu` GCC 13.x, installed in the image because it is needed to build
the cross-compiler. Its `-c` output can look identical to `file`.
`x86_64-elf-g++ -dumpmachine` versus `g++ -dumpmachine` settles it. The habit that
prevents this permanently: after [[Stage 0.8 - The Build System]], never type a compiler
name — type `make`.

**Symptom: `file` says `ELF 32-bit LSB relocatable, Intel 80386`.** Wrong target entirely
— an i686 toolchain, or `-m32` picked up from somewhere. A 32-bit object cannot be linked
into an x86_64 long-mode kernel; [[ADR-0002 - Target x86_64 Not i686]] explains why
32-bit is not an option here.

**Symptom: `make shell` prints `Cannot connect to the Docker daemon`.** On Windows,
Docker Desktop is not running or WSL2 integration is not enabled for your Ubuntu
distribution. On Linux, `docker: permission denied` means you are not in the `docker`
group — or you are, but have not logged out since being added. Group membership applies
at login, not at `usermod`.

**Symptom: `probe.cpp` and `probe.o` appear in `git status`.** You created them in `/os`,
the bind-mounted repository — the same files inside and outside the container. Delete
them and work in `/tmp`, which lives in the container's writable layer and is destroyed
on exit by `--rm`.

**Symptom: builds are painfully slow and `uname -m` says `aarch64`.** You built the image
natively on Apple Silicon: `make toolchain` runs `docker build` with no platform
argument, so an arm64 host produces an arm64 image. The cross-compiler still targets
`x86_64-elf` — the output is fine — but the build environment is not the one CI uses,
which voids the byte-identical guarantee. Rebuild with
`docker build --platform linux/amd64`, or just `docker pull` the published image.

**Symptom: on Apple Silicon, Docker warns the image platform does not match the host, and
everything feels slow.** Expected, not an error. The image is `linux/amd64` deliberately
so its output matches CI ([[ADR-0005 - Containerised Pinned Toolchain]]). `ccache` on the
persistent `os-ccache` volume keeps incremental builds quick; a full kernel rebuild is
still under a minute. Your Mac is a development machine, not a boot target — see
[[ADR-0006 - Apple Silicon Is Not a Boot Target]].

**Symptom: builds are slow on Windows and `git` reports every file as modified.** The
repository is on `/mnt/c`. Every file access crosses a translation layer, and CRLF line
endings fight `.gitattributes`. Move it into the WSL filesystem at `~/os`.

**Symptom: no QEMU window on WSL2.** WSLg provides the display and needs no configuration
on Windows 11, but can be absent on older builds or in remote setups. Use `-display none`
with `-serial stdio` or `-monitor stdio`. Everything from
[[Stage 0.6 - Serial Output]] onward is serial-first precisely so a display is never on
the critical path.

**Symptom: `make run-uefi` cannot find the firmware.** Ubuntu 24.04 ships
`/usr/share/OVMF/OVMF_CODE_4M.fd`, not `OVMF_CODE.fd`, and the `Makefile` defaults to the
old name. Pass `OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd` or change the default. On
macOS, `brew install qemu` places the firmware somewhere else again.

**Symptom: nothing yet — you skipped `-mno-red-zone` and it compiled fine.** It always
compiles fine; that is the trap. The consequence arrives once interrupts are enabled in
[[Phase 2 - Overview|Phase 2]], as corruption you cannot reproduce, in code that is not
at fault, from a flag you dropped weeks earlier. It costs nothing today. CI enforces it
from [[Stage 0.9 - CI From Day One]]; enforce it on yourself until then.

**Symptom: the container's tool versions do not match the Dockerfile.** Your local image
is stale. `:latest` is resolved at pull time and never re-checked, so `docker run` keeps
using whatever you first pulled. `docker pull ghcr.io/cracked-f/os-toolchain:latest`
refreshes it — and re-read the digest discussion in §3, because this is exactly the
failure mode that argues for pinning one.

---

## 8. What this unlocks

Everything, and silently. [[Stage 0.2 - The Limine Request Section]] needs objects the
bootloader can parse — wrong object format and the request magic is never found.
[[Stage 0.3 - Freestanding C++ and kmain]] needs a compiler that does not assume a libc.
[[Stage 0.4 - The Linker Script and Higher-Half Layout]] needs GNU `ld` and
`-mcmodel=kernel`, or the link fails with truncated relocations.
[[Stage 0.5 - Building a Bootable Image]] needs `xorriso`, `mtools` and the pinned Limine
binaries that exist only inside this image. [[Stage 0.8 - The Build System]] and
[[Stage 0.9 - CI From Day One]] assume the container is the single build environment —
the assumption that lets CI's result mean something about your machine.

The failure this stage prevents is not a broken build; a broken build tells you it is
broken. It is a build that succeeds while being subtly wrong: one object compiled by the
host compiler, one file missing `-mno-red-zone`, one machine on a stale image. All three
produce artefacts that look correct, link correctly, and fail later somewhere unrelated.
Twenty minutes of `file`, `-dumpmachine` and `objdump` buys the right to stop suspecting
the toolchain.

---

## 9. Reading

- OSDev — *Why do I need a Cross Compiler?* The canonical answer; read it in full rather
  than skimming: <https://wiki.osdev.org/Why_do_I_need_a_Cross_Compiler%3F>
- OSDev — *GCC Cross-Compiler*. The build recipe `toolchain/Dockerfile` automates — read
  it once so the Dockerfile is not magic: <https://wiki.osdev.org/GCC_Cross-Compiler>
- OSDev — *System V ABI*. Calling convention, register roles, and the red zone at
  hobby-OS altitude: <https://wiki.osdev.org/System_V_ABI>
- **System V AMD64 psABI**, the source document. The red zone is §3.2.2 — read the actual
  sentence, it is two lines and explains the whole bug:
  <https://gitlab.com/x86-psABIs/x86-64-ABI>
- GCC — *Options Controlling C Dialect*, for the exact wording of `-ffreestanding`:
  <https://gcc.gnu.org/onlinedocs/gcc/C-Dialect-Options.html>
- GCC — *x86 Options*, for `-mno-red-zone`, `-mcmodel=` and the `-mno-sse` family:
  <https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html>
- Intel SDM Volume 3A, chapter 6 — interrupt and exception handling; §6.14 covers the
  64-bit-mode stack frame and its 16-byte alignment:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html>
- OSDev — *Beginner Mistakes*. Read it now and again after Phase 2; the cross-compiler
  and red-zone entries mean more the second time:
  <https://wiki.osdev.org/Beginner_Mistakes>
- Docker — *Pull an image by digest*, for the pinning discussion in §3:
  <https://docs.docker.com/reference/cli/docker/image/pull/>
- [[02 - Toolchain Setup]] — if any tool is missing, the fix is here
- [[ADR-0005 - Containerised Pinned Toolchain]] — why the build lives in a container
- [[ADR-0002 - Target x86_64 Not i686]] — why 64-bit, with the red zone as a consequence
- [[ADR-0007 - Freestanding C++20 as the Kernel Language]] — the banned and allowed
  language features and the flags that enforce them
- [[08 - Build System]] — where these flags live permanently
- [[14 - Debugging Playbook]] — what to do when the screen is black anyway

Next: **[[Stage 0.2 - The Limine Request Section]]**

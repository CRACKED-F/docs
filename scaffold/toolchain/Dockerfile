# syntax=docker/dockerfile:1
#
# Pinned build toolchain for the CRACKED-F OS.
# See steps/decisions/ADR-0005 - Containerised Pinned Toolchain.
#
# Every build — on macOS, on Windows 11, and in CI — happens inside this image,
# so all three produce identical bytes. Nothing is installed on the host except
# Docker and (for `make run`) QEMU.
#
# Build:  docker build -t os-toolchain toolchain/
# Push:   handled by .github/workflows/toolchain.yml
#
# IMPORTANT: bump the versions below deliberately, in a reviewed PR. Never
# float them. A toolchain that updates itself breaks your build on a morning
# you had other plans.

FROM ubuntu:24.04

# ---------------------------------------------------------------------------
# Pinned versions. These are the whole point of this file.
# ---------------------------------------------------------------------------
ARG BINUTILS_VERSION=2.43
ARG GCC_VERSION=14.2.0
ARG LIMINE_VERSION=v8.6.0-binary
ARG TARGET=x86_64-elf
ARG PREFIX=/opt/cross

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="${PREFIX}/bin:${PATH}"
ENV TARGET=${TARGET}

# ---------------------------------------------------------------------------
# Host packages
#   build-*      : to build the cross-compiler
#   nasm         : standalone assembly (boot trampoline, ISR stubs, ctx switch)
#   xorriso      : hybrid ISO creation (BIOS + UEFI in one image)
#   mtools       : write into the FAT32 ESP without needing loop mounts / root
#   dosfstools   : mkfs.fat for the ESP
#   e2fsprogs    : mke2fs for the root partition  (Phase 10)
#   parted       : GPT partition table            (Phase 11 release images)
#   ovmf         : UEFI firmware for QEMU         (the UEFI half of the boot matrix)
#   qemu-*       : headless test runs inside the container (CI)
#   python3      : Tier 3 integration tests (pexpect)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential bison flex libgmp3-dev libmpc-dev libmpfr-dev texinfo \
      libisl-dev wget curl xz-utils ca-certificates git make cmake ninja-build \
      nasm xorriso mtools dosfstools e2fsprogs parted \
      qemu-system-x86 ovmf \
      gdb ccache jq \
      clang-format clang-tidy \
      python3 python3-pip python3-pexpect \
      file bc \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# binutils  (assembler + linker for x86_64-elf)
# ---------------------------------------------------------------------------
RUN mkdir -p /tmp/src && cd /tmp/src \
 && wget -q "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz" \
 && tar -xf "binutils-${BINUTILS_VERSION}.tar.xz" \
 && mkdir build-binutils && cd build-binutils \
 && ../binutils-${BINUTILS_VERSION}/configure \
      --target="${TARGET}" \
      --prefix="${PREFIX}" \
      --with-sysroot \
      --disable-nls \
      --disable-werror \
 && make -j"$(nproc)" \
 && make install \
 && cd / && rm -rf /tmp/src

# ---------------------------------------------------------------------------
# gcc  (C and C++ only; no libc — this is a freestanding cross-compiler)
#
# `all-target-libgcc` is required: the kernel links against libgcc for
# compiler builtins such as 128-bit division. Linking without it produces
# undefined-reference errors that look unrelated to the actual cause.
# ---------------------------------------------------------------------------
RUN mkdir -p /tmp/src && cd /tmp/src \
 && wget -q "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz" \
 && tar -xf "gcc-${GCC_VERSION}.tar.xz" \
 && mkdir build-gcc && cd build-gcc \
 && ../gcc-${GCC_VERSION}/configure \
      --target="${TARGET}" \
      --prefix="${PREFIX}" \
      --disable-nls \
      --enable-languages=c,c++ \
      --without-headers \
      --disable-hosted-libstdcxx \
 && make -j"$(nproc)" all-gcc all-target-libgcc \
 && make install-gcc install-target-libgcc \
 && cd / && rm -rf /tmp/src

# ---------------------------------------------------------------------------
# Limine — prebuilt binary branch, pinned by tag.
# ADR-0003. Contains BOOTX64.EFI, BIOS stages, and the limine deploy tool.
# ---------------------------------------------------------------------------
RUN git clone --depth 1 --branch "${LIMINE_VERSION}" \
      https://github.com/limine-bootloader/limine.git /opt/limine \
 && make -C /opt/limine \
 && rm -rf /opt/limine/.git
ENV LIMINE_DIR=/opt/limine

# ---------------------------------------------------------------------------
# ccache — meaningful on Apple Silicon, where this image runs emulated.
# ---------------------------------------------------------------------------
ENV CCACHE_DIR=/ccache
ENV PATH="/usr/lib/ccache:${PATH}"
RUN mkdir -p /ccache && chmod 777 /ccache

# ---------------------------------------------------------------------------
# Verification — fail the image build, not someone's afternoon.
# ---------------------------------------------------------------------------
RUN set -e; \
    echo "=== toolchain verification ==="; \
    ${TARGET}-gcc --version | head -1; \
    ${TARGET}-g++ --version | head -1; \
    ${TARGET}-ld --version | head -1; \
    nasm --version; \
    qemu-system-x86_64 --version | head -1; \
    xorriso --version 2>&1 | head -1; \
    cmake --version | head -1; \
    test -f "${LIMINE_DIR}/BOOTX64.EFI" || { echo "FATAL: Limine BOOTX64.EFI missing"; exit 1; }; \
    test -f /usr/share/OVMF/OVMF_CODE.fd || echo "WARN: OVMF path differs on this base image"; \
    echo "=== ok ==="

WORKDIR /os
CMD ["/bin/bash"]

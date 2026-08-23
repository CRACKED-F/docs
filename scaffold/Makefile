# Thin host wrapper. Contains NO build logic — CMake owns that.
#
# Its only job is to provide the verbs people type and to run them inside the
# pinned toolchain container, so macOS, Windows 11 and CI all do exactly the
# same thing. See ADR-0005 and steps/08 - Build System.
#
# Build in the container. Run QEMU on the host. GUI output and KVM/HVF
# acceleration do not survive containerisation cleanly.

# --- Pin this to a digest once the image is published ----------------------
TOOLCHAIN ?= ghcr.io/cracked-f/os-toolchain:latest

BUILD_TYPE ?= Debug
BUILD_DIR  ?= build
JOBS       ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Run everything in the container unless we are already inside one (CI sets
# CONTAINER=1, and the image itself is the execution context there).
ifeq ($(CONTAINER),1)
  RUN :=
else
  RUN := docker run --rm -it \
           -v "$(CURDIR):/os" \
           -v os-ccache:/ccache \
           -w /os \
           -e CONTAINER=1 \
           -e SOURCE_DATE_EPOCH \
           $(TOOLCHAIN)
endif

# Non-interactive variant, for anything CI or a pipe will run.
RUNQ := $(subst -it,,$(RUN))

QEMU       ?= qemu-system-x86_64
QEMU_MEM   ?= 512M
QEMU_SMP   ?= 1
# UEFI firmware for `make run-uefi`. The path differs per platform, so take the
# first one that exists. Ubuntu 24.04 renamed it to OVMF_CODE_4M.fd; older
# Debian/Ubuntu use OVMF_CODE.fd; Homebrew QEMU on macOS ships edk2-x86_64-code.fd.
# Override if yours is elsewhere:  make run-uefi OVMF_CODE=/path/to/firmware.fd
OVMF_CODE  ?= $(firstword $(wildcard \
                /usr/share/OVMF/OVMF_CODE_4M.fd \
                /usr/share/OVMF/OVMF_CODE.fd \
                /usr/share/ovmf/OVMF.fd \
                /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
                /usr/local/share/qemu/edk2-x86_64-code.fd))

# Serial goes to your terminal AND to a file, in one shot. The terminal is for
# the edit-run loop; the file is what survives the crash, what you paste into a
# bug report, and what `scripts/test.sh` greps. A run whose only output vanished
# with the QEMU window is a run you cannot debug.
SERIAL_LOG ?= $(BUILD_DIR)/serial.log
SERIAL_TEE ?= -chardev stdio,id=ser0,logfile=$(SERIAL_LOG) -serial chardev:ser0

.DEFAULT_GOAL := all
.PHONY: all configure iso img vm-images run run-serial run-uefi run-smp \
        debug gdb test test-unit test-kernel test-boot fmt lint lint-tidy \
        compile-commands clean distclean shell toolchain verify-repro help

## --- Build -----------------------------------------------------------------

configure:
	$(RUNQ) cmake -S . -B $(BUILD_DIR) -G Ninja \
	    -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	    -DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake \
	    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

all: configure                    ## Build kernel, libc, user programs, initrd
	$(RUNQ) cmake --build $(BUILD_DIR) -j $(JOBS)

iso: all                          ## Build the hybrid BIOS+UEFI ISO
	$(RUNQ) ./scripts/mkimage.sh iso

img: all                          ## Build the GPT disk image (ESP + root)
	$(RUNQ) ./scripts/mkimage.sh img

vm-images: img                    ## Build .ova and .vhdx from os.img
	$(RUNQ) ./scripts/mkimage.sh vm

compile-commands: configure       ## Generate build/compile_commands.json
	@test -f $(BUILD_DIR)/compile_commands.json

## --- Run (QEMU on the HOST, not in the container) --------------------------

run: iso                          ## Boot the ISO in QEMU (BIOS), serial to stdout + serial.log
	$(QEMU) -cdrom $(BUILD_DIR)/os.iso \
	    -m $(QEMU_MEM) -smp $(QEMU_SMP) \
	    $(SERIAL_TEE) -no-reboot -no-shutdown

run-serial: iso                   ## Boot headless, serial only
	$(QEMU) -cdrom $(BUILD_DIR)/os.iso \
	    -m $(QEMU_MEM) -display none \
	    $(SERIAL_TEE) -no-reboot -no-shutdown

run-uefi: img                     ## Boot the disk image under UEFI (OVMF)
	$(QEMU) -drive format=raw,file=$(BUILD_DIR)/os.img \
	    -bios $(OVMF_CODE) \
	    -m $(QEMU_MEM) -smp $(QEMU_SMP) \
	    $(SERIAL_TEE) -no-reboot -no-shutdown

run-smp: img                      ## Boot with 4 cores under UEFI
	$(MAKE) run-uefi QEMU_SMP=4

## --- Debug -----------------------------------------------------------------

debug: iso                        ## QEMU frozen, waiting for GDB on :1234
	@echo "QEMU waiting on :1234 — run 'make gdb' in another terminal"
	$(QEMU) -cdrom $(BUILD_DIR)/os.iso \
	    -m $(QEMU_MEM) -smp $(QEMU_SMP) \
	    -serial file:$(BUILD_DIR)/serial.log \
	    -no-reboot -no-shutdown -s -S

gdb:                              ## Attach GDB with symbols and our .gdbinit
	gdb -x tools/gdbinit $(BUILD_DIR)/kernel.elf

## --- Test ------------------------------------------------------------------

test: test-unit test-kernel test-boot   ## All three tiers

test-unit:                        ## Tier 1 — host unit tests (seconds)
	$(RUNQ) ./scripts/test.sh unit

test-kernel: iso                  ## Tier 2 — in-kernel self-tests under QEMU
	$(RUNQ) ./scripts/test.sh kernel

test-boot: iso img                ## Tier 3 — integration boot matrix
	$(RUNQ) ./scripts/test.sh boot --firmware bios --media iso
	$(RUNQ) ./scripts/test.sh boot --firmware uefi --media iso
	$(RUNQ) ./scripts/test.sh boot --firmware uefi --media img
	$(RUNQ) ./scripts/test.sh boot --firmware uefi --media img --smp 4

## --- Quality ---------------------------------------------------------------

fmt:                              ## Apply clang-format in place
	$(RUNQ) ./scripts/fmt.sh

lint: compile-commands            ## Format check + architectural boundary rules
	$(RUNQ) ./scripts/lint.sh

lint-tidy: compile-commands       ## clang-tidy over the compile database
	$(RUNQ) run-clang-tidy -p $(BUILD_DIR) -quiet 'kernel/|libc/|user/'

verify-repro:                     ## Build twice, diff the artefacts
	$(RUNQ) ./scripts/verify-repro.sh

## --- Environment -----------------------------------------------------------

shell:                            ## Interactive shell inside the toolchain
	$(RUN) bash

toolchain:                        ## Rebuild the toolchain image locally
	docker build -t $(TOOLCHAIN) toolchain/

clean:
	rm -rf $(BUILD_DIR) boot/stage

distclean: clean
	docker volume rm os-ccache 2>/dev/null || true

help:                             ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ADR-0003 — Limine as the bootloader

**Status:** Accepted · **Date:** 2026-08-20
**Supersedes:** GRUB2 + Multiboot 1 in the v1 vault

---

## Context

The v1 guide used **GRUB2 with Multiboot 1**. In practice that combination is
legacy-BIOS only: a Multiboot-1 kernel is 32-bit, and obtaining a working
`BOOTX64.EFI` GRUB build is awkward on both macOS and Windows. The v1 toolchain doc
even conceded the point, telling macOS users to run GRUB inside a Docker container
because it does not exist natively.

We need a boot path that produces **one image that boots on both UEFI and legacy
BIOS**, and that can hand a 64-bit kernel a framebuffer and a memory map without us
writing firmware code first.

Options considered: GRUB2 + Multiboot 2, Limine, a hand-written UEFI application,
and chainloaders such as systemd-boot or rEFInd.

## Decision

Use **Limine** with the **Limine boot protocol**.
<https://github.com/limine-bootloader/limine>

## Rationale

- Ships **prebuilt UEFI binaries** (`BOOTX64.EFI`, `BOOTIA32.EFI`) alongside BIOS
  stages. One `limine.conf` and one `xorriso` invocation produces an image that
  boots both ways. This removes the single largest source of macOS/Windows toolchain
  pain in the v1 plan.
- Enters the kernel **already in 64-bit long mode with paging enabled** and a
  higher-half direct map established. This is what makes
  [[ADR-0002 - Target x86_64 Not i686]] tractable for a two-person team.
- Supplies, as protocol requests, everything early boot needs:
  - **memory map** (Phase 4)
  - **linear framebuffer** — base, width, height, pitch, bpp (Phase 1, see
    [[ADR-0004 - Framebuffer Console Not VGA Text]])
  - **RSDP** pointer for ACPI (Phase 11)
  - **modules** — our initrd (Phase 7)
  - **kernel address** — physical and virtual base, needed for symbolising panics
  - **HHDM** — higher-half direct map offset, so physical memory is trivially
    addressable from the start
  - **SMP** — it will start the application processors and park them in a callback,
    removing an entire class of INIT/SIPI bugs from Phase 12
- Deliberately scoped for hobby kernels, actively maintained, well documented, and
  measurably faster to boot than GRUB2.

## Consequences

- We depend on a third-party bootloader and its protocol. **The Limine version is
  pinned** in the toolchain container and in `boot/limine.mk`. Protocol changes are
  adopted deliberately, never automatically.
- We do not learn to write a bootloader. This is an accepted trade: bootloader
  authorship is a separate project, and every hour there is an hour not spent on the
  kernel.
- Limine's protocol is not Multiboot. Tutorials that parse the Multiboot info
  structure do not apply. Every Phase 0 note documents the Limine request/response
  model directly rather than linking to Multiboot material.
- Booting real hardware requires the ESP to contain `/EFI/BOOT/BOOTX64.EFI`. Handled
  by `scripts/mkimage.sh`.
- Limine responses live in bootloader-reclaimable memory. **Everything we need must
  be copied out before that memory is reclaimed in Phase 4.** Failing to do this
  produces a fault that appears long after the mistake — it is called out explicitly
  in Stage 4.2.

## Escape hatch

Kernel entry is isolated behind `kernel/arch/x86_64/boot/` and a `boot_info_t`
struct populated from the Limine responses. **Nothing outside that directory knows
Limine exists.** Swapping bootloaders means rewriting one translation unit. This
constraint is enforced by a CI grep that fails the build if `limine.h` is included
anywhere else.

## Alternatives rejected

- **GRUB2 + Multiboot 2.** Works, and is more widely known. Rejected because staging
  GRUB's EFI binaries cross-platform is materially harder, Multiboot 2 still enters
  in 32-bit protected mode (we would write the long-mode trampoline ourselves in
  Stage 0), and GRUB offers no SMP assistance.
- **Hand-written UEFI application.** Maximum control and genuinely educational, but
  adds weeks before the first "hello", and makes legacy-BIOS boot a second,
  separate implementation. Revisit as a post-1.0 project.
- **From-scratch MBR/real-mode bootloader.** An educational dead end for a
  UEFI-first product.

## Related

[[ADR-0002 - Target x86_64 Not i686]] · [[ADR-0004 - Framebuffer Console Not VGA Text]]

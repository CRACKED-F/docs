#!/usr/bin/env bash
#
# Builds the bootable artefacts. Runs inside the toolchain container.
#
#   ./scripts/mkimage.sh iso   -> build/os.iso   hybrid BIOS + UEFI
#   ./scripts/mkimage.sh img   -> build/os.img   GPT: FAT32 ESP + ext2 root
#   ./scripts/mkimage.sh vm    -> build/os.ova, build/os.vhdx
#
# See steps/11 - Release and Deployment.

set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
STAGE="${BUILD_DIR}/stage"
LIMINE_DIR="${LIMINE_DIR:-/opt/limine}"

KERNEL="${BUILD_DIR}/kernel.elf"
INITRD="${BUILD_DIR}/initrd.tar"

ESP_MB="${ESP_MB:-64}"
ROOT_MB="${ROOT_MB:-256}"

die() { echo "error: $*" >&2; exit 1; }

require() {
  [[ -f "$1" ]] || die "missing $1 — run 'make' first"
}

# ---------------------------------------------------------------------------
# Staging tree, shared by both image types.
#
# Limine looks for limine.conf next to its own binary. We put everything at the
# root of the boot volume for simplicity.
# ---------------------------------------------------------------------------
stage_common() {
  require "$KERNEL"
  require "boot/limine.conf"

  # The initrd does not exist until Phase 7 (tools/mkinitrd). Until then stage an
  # empty archive: the image still builds, and Limine still finds the module that
  # limine.conf tells it to load instead of failing the boot entry.
  if [[ ! -f "$INITRD" ]]; then
    echo ">> note: ${INITRD} not built yet — staging an empty placeholder (Phase 7 replaces it)"
    mkdir -p "$(dirname "$INITRD")"
    tar -cf "$INITRD" -T /dev/null
  fi

  rm -rf "$STAGE"
  mkdir -p "$STAGE/EFI/BOOT"

  cp "$KERNEL"            "$STAGE/kernel.elf"
  cp "$INITRD"            "$STAGE/initrd.tar"
  cp boot/limine.conf     "$STAGE/limine.conf"

  # UEFI: firmware looks for the removable-media fallback path.
  cp "$LIMINE_DIR/BOOTX64.EFI"  "$STAGE/EFI/BOOT/BOOTX64.EFI"
  # 32-bit UEFI exists on some older tablets/netbooks. Cheap to include.
  [[ -f "$LIMINE_DIR/BOOTIA32.EFI" ]] && cp "$LIMINE_DIR/BOOTIA32.EFI" "$STAGE/EFI/BOOT/BOOTIA32.EFI"

  # BIOS stages.
  cp "$LIMINE_DIR/limine-bios.sys"     "$STAGE/" 2>/dev/null || true
  cp "$LIMINE_DIR/limine-bios-cd.bin"  "$STAGE/" 2>/dev/null || true
  cp "$LIMINE_DIR/limine-uefi-cd.bin"  "$STAGE/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Hybrid ISO — one file that boots BIOS *and* UEFI.
#
# El Torito with two boot catalogue entries: a BIOS no-emulation entry, and an
# EFI entry pointing at an embedded FAT image. -isohybrid-gpt-basdat is what
# makes `dd`-ing it to a USB stick work.
# ---------------------------------------------------------------------------
build_iso() {
  stage_common
  echo ">> building ${BUILD_DIR}/os.iso"

  xorriso -as mkisofs \
      -R -r -J \
      -b limine-bios-cd.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
      -hfsplus \
      -apm-block-size 2048 \
      --efi-boot limine-uefi-cd.bin \
        -efi-boot-part --efi-boot-image \
        --protective-msdos-label \
      "$STAGE" -o "${BUILD_DIR}/os.iso"

  # Install the BIOS boot record into the ISO.
  "$LIMINE_DIR/limine" bios-install "${BUILD_DIR}/os.iso"

  echo "   $(du -h "${BUILD_DIR}/os.iso" | cut -f1)"
}

# ---------------------------------------------------------------------------
# GPT disk image — the real-hardware and VM artefact.
#
#   Partition 1: FAT32 ESP    (UEFI mandates FAT; ADR-0009)
#   Partition 2: ext2 root    (writable — this is what proves persistence)
#
# mtools writes into the FAT filesystem without loop mounts or root, which is
# what lets this run in an unprivileged container.
# ---------------------------------------------------------------------------
build_img() {
  stage_common
  local img="${BUILD_DIR}/os.img"
  local total=$(( ESP_MB + ROOT_MB + 2 ))

  echo ">> building ${img} (${total} MiB)"
  rm -f "$img"
  truncate -s "${total}M" "$img"

  parted -s "$img" \
      mklabel gpt \
      mkpart ESP  fat32 1MiB "$(( ESP_MB + 1 ))MiB" \
      set 1 esp on \
      mkpart root ext2  "$(( ESP_MB + 1 ))MiB" 100%

  # Offsets in bytes. 1 MiB alignment for partition 1.
  local esp_off=$(( 1024 * 1024 ))
  local esp_size=$(( ESP_MB * 1024 * 1024 ))
  local root_off=$(( esp_off + esp_size ))

  # --- ESP -----------------------------------------------------------------
  local esp="${BUILD_DIR}/esp.img"
  rm -f "$esp"
  truncate -s "${ESP_MB}M" "$esp"
  mkfs.fat -F 32 -n "OSBOOT" "$esp" >/dev/null

  mmd   -i "$esp" ::/EFI ::/EFI/BOOT
  mcopy -i "$esp" "$STAGE/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
  [[ -f "$STAGE/EFI/BOOT/BOOTIA32.EFI" ]] && mcopy -i "$esp" "$STAGE/EFI/BOOT/BOOTIA32.EFI" ::/EFI/BOOT/
  mcopy -i "$esp" "$STAGE/kernel.elf"   ::/
  mcopy -i "$esp" "$STAGE/initrd.tar"   ::/
  mcopy -i "$esp" "$STAGE/limine.conf"  ::/
  [[ -f "$STAGE/limine-bios.sys" ]] && mcopy -i "$esp" "$STAGE/limine-bios.sys" ::/

  dd if="$esp" of="$img" bs=1M seek=1 conv=notrunc status=none
  rm -f "$esp"

  # --- root ----------------------------------------------------------------
  local root="${BUILD_DIR}/root.img"
  rm -f "$root"
  truncate -s "${ROOT_MB}M" "$root"
  # -F: it is a file, not a block device. -b 1024: matches our ext2 driver's
  # first supported block size (Phase 10).
  mke2fs -q -t ext2 -b 1024 -F -L "OSROOT" "$root"
  dd if="$root" of="$img" bs=1M seek=$(( root_off / 1024 / 1024 )) conv=notrunc status=none
  rm -f "$root"

  # BIOS boot record, so the same image also boots on legacy firmware.
  "$LIMINE_DIR/limine" bios-install "$img" 2>/dev/null || \
      echo "   (note: BIOS install skipped — image is UEFI-only)"

  echo "   $(du -h "$img" | cut -f1)"
}

# ---------------------------------------------------------------------------
# VM appliances, derived from os.img.
# ---------------------------------------------------------------------------
build_vm() {
  require "${BUILD_DIR}/os.img"

  if command -v qemu-img >/dev/null; then
    echo ">> building ${BUILD_DIR}/os.vhdx (Hyper-V)"
    qemu-img convert -f raw -O vhdx "${BUILD_DIR}/os.img" "${BUILD_DIR}/os.vhdx"

    echo ">> building ${BUILD_DIR}/os.vmdk (for the OVA)"
    qemu-img convert -f raw -O vmdk "${BUILD_DIR}/os.img" "${BUILD_DIR}/os.vmdk"
  else
    die "qemu-img not found; cannot build VM images"
  fi

  # An OVA is a tar of the OVF descriptor plus the disk. The descriptor is
  # generated by tools/mkovf so the version and disk size stay in sync.
  if [[ -x tools/mkovf.sh ]]; then
    echo ">> building ${BUILD_DIR}/os.ova (VirtualBox / VMware)"
    tools/mkovf.sh "${BUILD_DIR}/os.vmdk" "${BUILD_DIR}/os.ova"
  else
    echo "   (skipping .ova — tools/mkovf.sh not present yet)"
  fi
}

case "${1:-}" in
  iso) build_iso ;;
  img) build_img ;;
  vm)  build_vm  ;;
  all) build_iso; build_img; build_vm ;;
  *)   sed -n '2,12p' "$0"; exit 2 ;;
esac

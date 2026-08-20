#!/usr/bin/env bash
#
# The test runner for all three tiers. See steps/09 - Testing Strategy.
#
#   ./scripts/test.sh unit
#   ./scripts/test.sh kernel
#   ./scripts/test.sh boot [--firmware bios|uefi] [--media iso|img] [--smp N] [--mem 512M] [--timeout 90]
#   ./scripts/test.sh shutdown [--firmware ...] [--media ...]
#   ./scripts/test.sh stress --suite heap|sched|fs --iterations N
#   ./scripts/test.sh soak --minutes 30
#
# Tier 2 reports through QEMU's isa-debug-exit device: the kernel writes N to
# port 0xf4 and QEMU exits with (N<<1)|1. So 0 -> exit 1 (pass), 1 -> exit 3
# (fail). See ADR-0010.

set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
QEMU="${QEMU:-qemu-system-x86_64}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"

FIRMWARE=bios
MEDIA=iso
SMP=1
MEM=512M
TIMEOUT=90
SUITE=""
ITERATIONS=10000
MINUTES=30

CMD="${1:-}"; shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --firmware)   FIRMWARE="$2"; shift 2 ;;
    --media)      MEDIA="$2";    shift 2 ;;
    --smp)        SMP="$2";      shift 2 ;;
    --mem)        MEM="$2";      shift 2 ;;
    --timeout)    TIMEOUT="$2";  shift 2 ;;
    --suite)      SUITE="$2";    shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --minutes)    MINUTES="$2";  shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# --- Assemble the QEMU command line ----------------------------------------
#
# -no-reboot -no-shutdown is NOT optional. Without it a triple fault silently
# reboots into a loop, you get a timeout instead of the fault message, and you
# lose the one piece of information you needed.
qemu_args() {
  local args=(
    -m "$MEM" -smp "$SMP"
    -display none
    -no-reboot -no-shutdown
    -serial "file:${BUILD_DIR}/serial.log"
    -d guest_errors
    -D "${BUILD_DIR}/qemu-stderr.log"
  )

  case "$MEDIA" in
    iso) args+=(-cdrom "${BUILD_DIR}/os.iso") ;;
    img) args+=(-drive "format=raw,file=${BUILD_DIR}/os.img") ;;
    *)   echo "bad --media: $MEDIA" >&2; exit 2 ;;
  esac

  case "$FIRMWARE" in
    bios) ;;
    uefi)
      if [[ ! -f "$OVMF_CODE" ]]; then
        echo "OVMF firmware not found at $OVMF_CODE" >&2
        echo "Install the 'ovmf' package or set OVMF_CODE." >&2
        exit 2
      fi
      args+=(-bios "$OVMF_CODE")
      ;;
    *) echo "bad --firmware: $FIRMWARE" >&2; exit 2 ;;
  esac

  printf '%s\n' "${args[@]}"
}

report_failure() {
  red "--- serial.log (last 60 lines) ---"
  tail -n 60 "${BUILD_DIR}/serial.log" 2>/dev/null || echo "(no serial output — did the kernel reach serial init?)"
  red "--- qemu stderr ---"
  tail -n 30 "${BUILD_DIR}/qemu-stderr.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
case "$CMD" in

  unit)
    # Tier 1 — host-native, milliseconds.
    cmake -S . -B "${BUILD_DIR}-host" -G Ninja -DBUILD_HOST_TESTS=ON >/dev/null
    cmake --build "${BUILD_DIR}-host" -j "$(nproc)"
    ctest --test-dir "${BUILD_DIR}-host" --output-on-failure
    ;;

  kernel)
    # Tier 2 — in-kernel self-tests, reported via isa-debug-exit.
    mkdir -p "$BUILD_DIR"
    mapfile -t ARGS < <(qemu_args)
    set +e
    timeout --foreground "$TIMEOUT" \
      "$QEMU" "${ARGS[@]}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04
    rc=$?
    set -e

    case "$rc" in
      1)   green "PASS  (isa-debug-exit 0)"; cat "${BUILD_DIR}/serial.log"; exit 0 ;;
      3)   red   "FAIL  (isa-debug-exit 1)"; report_failure; exit 1 ;;
      124) red   "TIMEOUT after ${TIMEOUT}s — the kernel hung"; report_failure; exit 1 ;;
      0)   red   "QEMU exited 0 without writing to the exit device."
           red   "The test kernel probably never reached test_exit()."
           report_failure; exit 1 ;;
      *)   red   "QEMU exited ${rc} (crash or bad invocation)"; report_failure; exit 1 ;;
    esac
    ;;

  boot)
    # Tier 3 — drive the real image over serial with pexpect.
    mkdir -p "$BUILD_DIR"
    mapfile -t ARGS < <(qemu_args)
    echo "boot test: firmware=${FIRMWARE} media=${MEDIA} smp=${SMP} mem=${MEM}"
    if python3 tests/integration/run.py \
         --qemu "$QEMU" --timeout "$TIMEOUT" -- "${ARGS[@]}"; then
      green "PASS  boot ${FIRMWARE}/${MEDIA}/smp${SMP}"
    else
      red "FAIL  boot ${FIRMWARE}/${MEDIA}/smp${SMP}"
      report_failure
      exit 1
    fi
    ;;

  shutdown)
    # ACPI shutdown must make QEMU exit cleanly. Note: -no-shutdown is
    # deliberately absent here, because a successful power-off IS the assertion.
    mkdir -p "$BUILD_DIR"
    local_args=(-m "$MEM" -smp "$SMP" -display none -no-reboot
                -serial "file:${BUILD_DIR}/serial.log")
    [[ "$MEDIA" == iso ]] && local_args+=(-cdrom "${BUILD_DIR}/os.iso") \
                          || local_args+=(-drive "format=raw,file=${BUILD_DIR}/os.img")
    [[ "$FIRMWARE" == uefi ]] && local_args+=(-bios "$OVMF_CODE")

    set +e
    timeout --foreground 60 python3 tests/integration/shutdown.py -- "$QEMU" "${local_args[@]}"
    rc=$?
    set -e
    [[ $rc -eq 0 ]] && green "PASS  clean ACPI shutdown" || { red "FAIL  shutdown (rc=$rc)"; report_failure; exit 1; }
    ;;

  stress)
    [[ -n "$SUITE" ]] || { echo "--suite required" >&2; exit 2; }
    mkdir -p "$BUILD_DIR"
    mapfile -t ARGS < <(qemu_args)
    set +e
    timeout --foreground 3000 \
      "$QEMU" "${ARGS[@]}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -append "stress=${SUITE} iterations=${ITERATIONS}"
    rc=$?
    set -e
    [[ $rc -eq 1 ]] && green "PASS  stress/${SUITE}" || { red "FAIL  stress/${SUITE} (rc=$rc)"; report_failure; exit 1; }
    ;;

  soak)
    # Boot and idle. Catches tick drift, slow leaks, lost wakeups.
    mkdir -p "$BUILD_DIR"
    python3 tests/integration/soak.py --minutes "$MINUTES" -- "$QEMU" $(qemu_args | tr '\n' ' ')
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac

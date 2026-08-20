#!/usr/bin/env bash
#
# Build twice into separate directories and diff the artefacts.
#
# Two builds of the same commit must produce identical bytes. That is what
# makes "it works on my machine" a falsifiable claim rather than an argument.
# See steps/08 - Build System.

set -Eeuo pipefail

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --pretty=%ct)}"

build_into() {
  local dir="$1"
  rm -rf "$dir"
  cmake -S . -B "$dir" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE=cmake/x86_64-kernel.cmake >/dev/null
  cmake --build "$dir" -j "$(nproc)" >/dev/null
}

echo ">> build 1"; build_into build-repro-a
echo ">> build 2"; build_into build-repro-b

rc=0
for f in kernel.elf initrd.tar; do
  if cmp -s "build-repro-a/$f" "build-repro-b/$f"; then
    printf '  %-16s identical\n' "$f"
  else
    printf '  %-16s DIFFERS\n' "$f"
    rc=1
  fi
done

if [ $rc -ne 0 ]; then
  echo
  echo "Build is not reproducible. Usual causes:"
  echo "  - __DATE__ / __TIME__ somewhere (lint catches this)"
  echo "  - absolute paths leaking in (need -ffile-prefix-map)"
  echo "  - SOURCE_DATE_EPOCH not honoured by the archiver"
fi

rm -rf build-repro-a build-repro-b
exit $rc

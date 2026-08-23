#!/usr/bin/env bash
# Apply clang-format in place. `make fmt`.
set -Eeuo pipefail

# Only search directories that actually exist. Through most of Phase 0 only
# kernel/ has been created; `find` on a missing path exits non-zero, and under
# `set -e` with `pipefail` that fails the whole script — so `make fmt` would be
# broken until Phase 6 created libc/ and user/.
dirs=()
for d in kernel libc user tools tests; do
  [[ -d "$d" ]] && dirs+=("$d")
done

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "no source directories yet — nothing to format"
  exit 0
fi

find "${dirs[@]}" \
     \( -name '*.cpp' -o -name '*.hpp' -o -name '*.c' -o -name '*.h' \) -print0 \
  | xargs -0 -r clang-format -i

echo "formatted (${dirs[*]})"

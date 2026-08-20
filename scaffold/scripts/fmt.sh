#!/usr/bin/env bash
# Apply clang-format in place. `make fmt`.
set -Eeuo pipefail
find kernel libc user tools tests \
     \( -name '*.cpp' -o -name '*.hpp' -o -name '*.c' -o -name '*.h' \) -print0 2>/dev/null \
  | xargs -0 -r clang-format -i
echo "formatted"

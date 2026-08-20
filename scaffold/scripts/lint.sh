#!/usr/bin/env bash
#
# Format check + architectural boundary rules.
#
# This is the SAME script CI runs. That is deliberate: when CI fails you
# reproduce it with `make lint`, not by pushing commits. See steps/10 - CI
# Pipeline.
#
# Each rule below protects a specific ADR. Do not add a rule without saying
# which one, and do not remove one without superseding the ADR.

set -Eeuo pipefail

BUILD_DIR="${BUILD_DIR:-build}"
CDB="${BUILD_DIR}/compile_commands.json"
fail=0

rule() { printf '\033[1m%-52s\033[0m' "$1"; }
ok()   { printf '\033[32mok\033[0m\n'; }
bad()  { printf '\033[31mFAIL\033[0m\n'; fail=1; }

# ---------------------------------------------------------------------------
rule "clang-format"
if find kernel libc user tools tests \
        \( -name '*.cpp' -o -name '*.hpp' -o -name '*.c' -o -name '*.h' \) -print0 2>/dev/null \
     | xargs -0 -r clang-format --dry-run --Werror >/dev/null 2>&1; then
  ok
else
  bad
  echo "   run 'make fmt'"
fi

# ---------------------------------------------------------------------------
# ADR-0002: the red zone. An interrupt arriving in a leaf function that used
# the 128 bytes below rsp will silently destroy live data. The symptom is
# random corruption, weeks later, in unrelated code.
rule "-mno-red-zone on every kernel TU"
if [[ -f "$CDB" ]]; then
  missing=$(jq -r '.[]
                   | select(.file | test("/kernel/"))
                   | select((.command // (.arguments | join(" "))) | contains("-mno-red-zone") | not)
                   | .file' "$CDB")
  if [[ -z "$missing" ]]; then ok; else bad; echo "$missing" | sed 's/^/   /'; fi
else
  bad; echo "   no compile_commands.json — run 'make compile-commands'"
fi

# ---------------------------------------------------------------------------
# ADR-0003: the bootloader escape hatch is worthless if the protocol leaks.
rule "limine.h confined to arch/x86_64/boot/"
leak=$(grep -rl 'limine\.h' kernel/ --include='*.cpp' --include='*.hpp' --include='*.h' 2>/dev/null \
       | grep -v '^kernel/arch/x86_64/boot/' || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; }

# ---------------------------------------------------------------------------
# ADR-0008: keeps a second architecture additive rather than a rewrite, and
# keeps kernel/mm host-testable (Tier 1).
rule "no inline asm outside kernel/arch/"
leak=$(grep -rnE '\b(asm|__asm__)[[:space:]]*(volatile)?[[:space:]]*\(' kernel/ \
         --include='*.cpp' --include='*.hpp' 2>/dev/null \
       | grep -v '^kernel/arch/' || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; }

# ---------------------------------------------------------------------------
rule "kernel does not include userspace headers"
leak=$(grep -rnE '#include[[:space:]]*[<"](libc|user)/' kernel/ 2>/dev/null || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; }

# ---------------------------------------------------------------------------
rule "no __DATE__ / __TIME__ (reproducible builds)"
leak=$(grep -rn '__DATE__\|__TIME__' kernel/ libc/ user/ 2>/dev/null || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; }

# ---------------------------------------------------------------------------
rule "no TODO without an issue number"
leak=$(grep -rnP 'TODO(?!\(#\d+\))' kernel/ libc/ user/ 2>/dev/null || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; echo "   use TODO(#123)"; }

# ---------------------------------------------------------------------------
# steps/13 rule 3: volatile provides neither atomicity nor ordering.
rule "no volatile on non-pointer shared state"
leak=$(grep -rnE '^\s*(static\s+)?volatile\s+(bool|int|unsigned|uint[0-9]+_t|size_t)\s+\w+\s*(=|;)' \
         kernel/ --include='*.cpp' --include='*.hpp' 2>/dev/null \
       | grep -v 'kernel/arch/' || true)
[[ -z "$leak" ]] && ok || { bad; echo "$leak" | sed 's/^/   /'; echo "   use std::atomic — volatile is not a concurrency primitive"; }

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32mall boundary rules pass\033[0m\n'
else
  printf '\033[31mlint failed\033[0m\n'
fi
exit $fail

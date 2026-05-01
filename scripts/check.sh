#!/usr/bin/env bash
# Verify all .nu files are topiary-formatted. Topiary has no --check flag,
# so we format each file via stdin and diff against the original.
#
# Usage:
#   scripts/check.sh
#
# Exits non-zero if any file would change under formatting.

set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

status=0
while IFS= read -r -d '' f; do
  if ! diff -u --label "a/$f" --label "b/$f" "$f" <(topiary fmt -l nu < "$f"); then
    status=1
  fi
done < <(find . -name '*.nu' -not -path './.git/*' -print0)

if [ "$status" -ne 0 ]; then
  echo "formatting check failed; run 'nu scripts/lint.nu' to fix" >&2
fi
exit "$status"

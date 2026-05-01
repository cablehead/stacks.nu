#!/usr/bin/env nu
# Format all .nu files in the repo via topiary.
#
# Usage:
#   nu scripts/lint.nu
#
# Topiary has no --check flag; for verification see scripts/check.sh.

const repo = path self | path dirname | path dirname

cd $repo
let files = glob **/*.nu --no-dir
print $"formatting ($files | length) file\(s\)"
for f in $files {
  print $"  ($f | path relative-to $repo)"
  topiary fmt $f
}

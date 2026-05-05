#!/usr/bin/env bash
# Screenshot /design and POST it as a clip into the currently-selected
# stack. See scripts/shoot-design.mjs for the implementation.
#
#   scripts/shoot-design.sh                     # uses default BASE
#   BASE=http://other:port scripts/shoot-design.sh

set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"

# Implementation lives in tests-browser/ alongside its playwright-core
# install -- node ESM resolves bare imports relative to the script's path.
exec node --no-warnings "$repo/tests-browser/shoot-design.mjs" "$@"

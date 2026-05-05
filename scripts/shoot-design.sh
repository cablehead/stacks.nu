#!/usr/bin/env bash
# Screenshot /design and POST it as a clip into the currently-selected
# stack. Defaults to a 1500x3500 viewport (so the design grid lays tiles
# 2-up) and resizes the result to 900px wide before posting -- a comfy
# size for the in-app preview.
#
#   scripts/shoot-design.sh                     # 2-up @ 900px
#   W=1280 H=5500 TARGET_W=0 scripts/shoot-design.sh   # 1-up, full size
#   BASE=http://other:port scripts/shoot-design.sh

set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"

export W="${W:-1500}"
export H="${H:-3500}"
export TARGET_W="${TARGET_W:-900}"

# Implementation lives in tests-browser/ alongside its playwright-core
# install -- node ESM resolves bare imports relative to the script's path.
exec node --no-warnings "$repo/tests-browser/shoot-design.mjs" "$@"

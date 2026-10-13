#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
habu_root=${HABU_ROOT:-"$HOME/.local/lib/habu/c53b4d2c"}
mkdir -p "$project/bin" "$project/.build/cache" "$project/.build/tmp"
cd "$habu_root"
HABU_BUILD_CACHE="$project/.build/cache" HB_TMP="$project/.build/tmp" \
  bin/hb --load tools/hb-build.f -- --size-report "$project/main.f" -o "$project/bin/dot"

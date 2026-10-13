#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hb=$(command -v hb) || { echo 'build.sh: hb is not on PATH' >&2; exit 127; }
habu_root=$(dirname -- "$(dirname -- "$(readlink -f -- "$hb")")")
mkdir -p "$project/bin" "$project/.build/cache" "$project/.build/tmp"
cd "$habu_root"
HABU_BUILD_CACHE="$project/.build/cache" HB_TMP="$project/.build/tmp" \
  bin/hb --load tools/hb-build.f -- --size-report "$project/main.f" -o "$project/bin/dot"

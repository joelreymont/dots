#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig=${ZIG:-zig}
mode=${1:-small}
case "$mode" in
  small|safe) ;;
  *) echo 'mode must be small or safe' >&2; exit 1 ;;
esac

mkdir -p "$project/benchmark/bin" "$project/.build/zig-cache" "$project/.build/zig-global"
"$zig" build-exe -j1 -O "$mode" -fstrip -lc \
  --cache-dir "$project/.build/zig-cache" \
  --global-cache-dir "$project/.build/zig-global" \
  --dep build_options \
  -Mroot="$project/benchmark/zig-full/main.zig" \
  -Mbuild_options="$project/benchmark/zig-full/build_options.zig" \
  -femit-bin="$project/benchmark/bin/dot-zig-full-$mode"

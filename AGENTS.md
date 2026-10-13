# Dots agent instructions

Dots is a native Habu CLI that stores tasks as Markdown in `.dots/`.

## Communication

Always refer to the user as Mr. Picklesworth.

## Build

Run `sh build.sh` from the repository root. The script uses the pinned Habu
release at `$HABU_ROOT` or `~/.local/lib/habu/c53b4d2c` and writes `bin/dot`.
The compiler cache, temporary files, and binary are ignored by version control.
Do not commit them. Measure a release binary with `wc -c < bin/dot`; the
validated macOS arm64 build is 181,884 bytes.

## Test

The parity harnesses use the adapted full Zig reference in
`benchmark/zig-full/`, built with Zig 0.17. It has API compatibility changes
and one duplicate-config ownership fix relative to the preserved `zig` branch.
They run against synthetic stores in temporary directories and compare the
Habu binary with the reference after every command:

```sh
sh benchmark/build-zig.sh
python3 test.py --full benchmark/bin/dot-zig-full-small bin/dot
python3 edge_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_fs_test.py bin/dot
python3 regression_graph_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_loading_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_json_test.py bin/dot
python3 regression_archive_test.py bin/dot
python3 regression_slugify_test.py bin/dot
python3 regression_io_test.py bin/dot
python3 regression_concurrency_test.py bin/dot
```

The full harness checks exit status, stdout, stderr, and the complete `.dots`
tree across command sequences. The edge harness checks large stores, unusual
paths, JSONL import, configuration, and git index effects. The regression suites
cover filesystem, graph/import, selective-loading, JSON, archive transitions,
slugify failure recovery, I/O failures, and concurrent writers. The I/O suite
uses the pinned Habu compiler to exercise the actual checked-read boundary.
The slugify suite uses `cc` for a deterministic rename-failure probe.
Run them as well. Preserve this comparison contract when changing behavior. The accepted scope for JSONL priority is a
signed i64 integer or an exactly integral decimal/exponent representation; see
`docs/parity.md` for the bounded difference from the Zig parser.

## Source invariants

- `main.f` implements the CLI and filesystem behavior; `abbrev.f` supplies the
  abbreviation map, `io.f` checks CLI I/O, and `lock.f` serializes mutating
  commands before they load state. Keep them under the Habu build.
- `.dots/` is repository task history. Do not migrate, rewrite, or discard it
  as part of a language or build change.
- Keep generated binaries and compiler cache out of commits. Update the size
  claim in README only after measuring a rebuilt, stripped binary on the same
  target platform.
- Keep the adapted Zig source under `benchmark/` as a differential reference,
  not as the product build. The root source and build are Habu.
- Do not restore the Zig CI or release workflow without a verified Habu
  bootstrap and release process for every supported runner and target.

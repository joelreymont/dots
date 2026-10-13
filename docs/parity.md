# Habu port: compatibility and validation

This port preserves the CLI and Markdown store behavior of the Zig revision
`f107d0165e2c0f080a911a420e1275433df05f4d`, available on the
[`zig` branch](https://github.com/joelreymont/dots/tree/zig). The adapted
full reference in `benchmark/zig-full/` adds Zig 0.17 API compatibility
changes and one narrow duplicate-config ownership fix; its persisted values
match the original source. The Habu program implements filesystem operations
itself; it does not invoke the Zig binary.
`main.f` is the CLI and `abbrev.f` is its slug abbreviation map. Both were
copied byte for byte from the accepted full port.

## Behavior covered

The port implements default ready JSON output, help and version, quick add,
`add`/`create`, `ls`/`list`, `ready`, `show`, `find`, `on`/`it`, `off`/`done`,
`update`, `close`, `rm`/`delete`, `tree`, `fix`, `purge`, `slugify`, and `init`
with JSONL import. The comparisons include normal and error output, return
codes, persistent files, archive moves, dependency rewrites, configuration,
and git index effects. See `test.py` and `edge_test.py` for the exact command
sequences and fixtures.

The full harness checks return code, stdout, stderr, and the entire `.dots`
tree after each command in paired synthetic stores with the same project
basename. It substitutes generated random ID suffixes and timestamps and
sorts only the reference's unspecified `find` enumeration within its open and
closed groups. A duplicate configuration edge compares the key/value map
because file order is unspecified, while requiring unique keys. Other content
and side effects remain compared. The edge harness also checks large stores,
newline-containing filenames, JSONL failures, filesystem limits, and staged
git index content. The repository's `.dots/` history is never used as a
fixture.

The accepted pinned Habu release was `c53b4d2c`, and its `bin/hb` SHA-256 was
`ccf0798dd4e11a3ea4308386704bd09a5f183750d18b802b9b2d9c28d6af2b96`.
The final macOS arm64 build used `sh build.sh` and produced a stripped
**165,372-byte** `bin/dot` with SHA-256
`5439c8622ed61c6b0f1029676f533e40a1940403249e45934fef33b72452eea0`.
`main.f` SHA-256 was
`7ca835b7547c2e27aaa74a890ebb7341285aabde6e87b0c07d4ba99695f777c4`.
For the same platform, the ordinary Zig Small reference measured 335,280
bytes and the separately minimized Zig build measured 268,320 bytes. The
Habu binary was 50.7% smaller than the first and 38.4% smaller than the
second. These are binary size measurements, not runtime speed comparisons.

The final Habu binary passed **96/96** full command-sequence steps and
**60/60** focused edges against each Zig reference. The full test and edge
test source hashes at that run were respectively
`66bfe630cb43b456c8f43c50c5404bb85928c3e12b15f12c0dd5cf112847c1e7`
and `8e1128bdf509d97b865b86d05b61fe6131a0b72d68e9246486ca29b931b54c27`.
This repository copy changes only their temporary output location from the
source directory to the system temporary directory. The final independent
review of the accepted source and 96/60 results found no remaining confirmed
issues in its reviewed scope; it did not rerun the suites.

The original [validation record](../benchmark/results/dot-review-fix-validation.json),
[memory record](../benchmark/results/dot-review-fix-memory.json), and
[final review](../benchmark/results/final-review.md) are retained as compact
historical evidence. Absolute paths inside those records identify the
comparison workspace used at the time; they are not build instructions for
this repository. The memory record measured one 4,096-line duplicate JSONL
fixture at 2,064,384 bytes peak RSS for Habu and 3,178,496 bytes for Zig
Small, with matching output and store trees. It is not a general performance
claim.

To repeat the comparison with Zig 0.17, build the retained full reference and
pass its executable explicitly:

```sh
sh build.sh
sh benchmark/build-zig.sh
python3 test.py --full benchmark/bin/dot-zig-full-small bin/dot
python3 edge_test.py benchmark/bin/dot-zig-full-small bin/dot
```

## Bounds and deliberate difference

The upstream compatible limits are an ID of at most 128 bytes, issue file
of at most 1 MiB, config of at most 64 KiB, path buffer of 512 bytes,
recursive path search depth of 10, and JSONL line of at most 1 MiB. Issue
count, aggregate data, and child count use dynamic buffers. The synthetic
edges include more than 300 issues, 70 KiB descriptions, 630 long filenames,
4.5 MiB JSON output, newline-containing filenames, and 10-level paths.

JSONL `priority` import accepts signed i64 integers and exactly integral
decimal or exponent forms, including decimal strings such as `"1e0"`.
The accepted scope excludes exotic nonintegral values that Zig's binary128
parser rounds to an integer, such as `1e-5000`, and quoted hexadecimal floats
such as `"0x1.0p0"`. Those inputs return `Invalid JSONL file` in the Habu CLI
and are outside the differential parity claim. No binary128 or hex parser is
needed for this port.

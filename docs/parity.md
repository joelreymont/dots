# Habu port: compatibility and validation

Dots is a native Habu implementation of the CLI and Markdown store from Zig
revision `f107d0165e2c0f080a911a420e1275433df05f4d`, preserved on the
[`zig` branch](https://github.com/joelreymont/dots/tree/zig). It does not invoke
Zig at runtime. The differential reference in `benchmark/zig-full/` has Zig
0.17 API adaptations and a duplicate-config ownership fix. The reference is
retained for tests; `main.f` and `abbrev.f` are the product source.

## Current validation

The 2026-10-13 adversarial pass found defects that the initial 96/60 checks
missed. The repairs prevent `purge` and `fix` from traversing static symlinks,
restore orphan visibility in `tree`, preserve imported dependency IDs and
parent paths, avoid parsing unrelated files for mutations, constrain child
checks to the actual active parent folder, report the reproduced filesystem
errors, and preserve Zig JSON byte-string semantics. Permanent minimal
regressions accompany the repairs.

The current macOS arm64 binary was built with `sh build.sh` using Habu
`c53b4d2c`. Compiler SHA-256:
`ccf0798dd4e11a3ea4308386704bd09a5f183750d18b802b9b2d9c28d6af2b96`.
Current `main.f` SHA-256:
`867bacd378a4c2bc85ef1f86b3bff53a4ace4f31aca98704984ef04de99ff783`.
Current `bin/dot` SHA-256:
`db3ccd79a409ea4d86c2bb26f2f36703513cc81d462d062d70d727969bf811ca`.

| Executable, macOS arm64 | Bytes |
| --- | ---: |
| Habu, current repaired build | 181,884 |
| Habu, initial port | 165,372 |
| Ordinary Zig Small reference | 335,280 |
| Separately minimized Zig reference | 268,320 |

The repaired binary is 45.8% smaller than ordinary Zig Small and 32.2% smaller
than the minimized reference. Its 16,512-byte increase over the initial port
includes a 16 KiB Mach-O text-segment alignment step; the `__text` section
itself grew 5,244 bytes. The size report attributes the current file to
140,232 bytes of code, 7,383 bytes of embedded data, 30,979 bytes of padding,
and 3,290 other bytes. No arbitrary-precision numeric tower was added. These
are executable-size measurements, not runtime speed measurements. Reserved
runtime capacity is not counted as on-disk data.

The rebuilt candidate passes these permanent suites against the ordinary
Zig Small reference:

| Suite | Result |
| --- | ---: |
| Full command sequences | 96/96 steps |
| Focused edges | 60/60 cases |
| Filesystem regressions | 8/8 cases |
| Graph/import regressions | 4/4 cases |
| Selective-loading regressions | 47/47 cases |
| JSON regressions | 20/20 fixtures |

The full and edge harnesses compare exit status, stdout, stderr, and the
complete `.dots` tree. They normalize generated ID suffixes and timestamps,
and sort only unspecified `find` ordering within open/closed groups. Duplicate
config entries compare a unique key/value map because ordering is unspecified.
The regression suites add explicit assertions and, where relevant, paired
complete-tree comparisons.

A separate run used stable copies of **4,590 files from 11 repositories**.
It exercised listing, every existing task ID, prefixes, searches, task and
dependency lifecycles, closing/reopening/removal, hierarchy, and maintenance.
Of **5,941 command comparisons, 5,939 matched completely**. The other two
were `slugify` progress-output differences described below; exit status,
stderr, and resulting files matched. Read-only commands preserved every
copied store. No test ran a mutation command against a live task store.

A generated run added **2,211 matching command observations**: 720 mixed
command steps, 951 malformed-storage/numeric observations, and 540 dependency
observations. Separate probes covered 18 simultaneous adds (at most six at
once), two simultaneous closes, and 18 concurrent updates per binary. They
left complete files, preserved unrelated tasks, and leaked no new temporary
files. Eight SIGTERM timings per binary left complete tasks or no new task;
they did not establish interruption during the temporary-file write. Existing
temporary-file sentinels and external symlink targets were preserved.

The compact [adversarial validation record](../benchmark/results/adversarial-2026-10-13.json)
records counts, binary measurements, and remaining limits without private task
contents.

Independent review found and verified two further repairs: byte arrays in
JSONL dependency fields and incorrect child selection. After those fixes,
12 independently selected paired cases matched output, errors, return code,
and complete store contents. The review reported no remaining confirmed
findings in its scope. Testing and review do not establish correctness for
every possible filesystem failure or process interleaving.

## Repeat the permanent checks

Build the reference with Zig 0.17, then use its executable explicitly:

```sh
sh build.sh
sh benchmark/build-zig.sh
python3 test.py --full benchmark/bin/dot-zig-full-small bin/dot
python3 edge_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_fs_test.py bin/dot
python3 regression_graph_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_loading_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_json_test.py bin/dot
```

All harnesses create disposable synthetic stores. Real task contents are not
committed as fixtures. Rebuild and rerun after source or toolchain changes.

## Remaining differences and inherited behavior

- On two copied stores, both CLIs fail `slugify` with `Issue not found` after
  some renames. Their resulting trees are identical. Habu prints the completed
  rename progress; Zig loses part of its buffered stdout on the failure.
- With a closed stdout pipe, Habu exits via SIGPIPE; Zig reports `WriteFailed`.
  Both had already created one complete task. This is a diagnostic difference.
- With a read-only task directory, Habu `add` reports `Permission denied`;
  the adapted Zig reference aborts with a double-free panic. Neither creates
  a task in that probe.
- Both implementations leave a reopened task under `archive/`; reopening does
  not move it back to active storage.
- Both can rewrite a task as closed before a failed archive move. The command
  reports failure, but the status change is not rolled back.
- Both follow an archive-directory symlink when closing a task. The repaired
  destructive commands `purge` and `fix` have separate no-follow checks; this
  is not a general filesystem sandbox or protection against symlink races.

These behaviors limit the parity and readiness claim. The installed CLI was
not replaced as part of validation.

## Historical evidence

The initial port's [validation record](../benchmark/results/dot-review-fix-validation.json),
[memory record](../benchmark/results/dot-review-fix-memory.json), and
[review](../benchmark/results/final-review.md) remain for provenance. Their
96/60 results did not catch the later adversarial defects and do not supersede
this report. Paths in those historical records refer to retired comparison
workspaces, not current build instructions. The earlier one-fixture memory
measurement is not a general performance claim.

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

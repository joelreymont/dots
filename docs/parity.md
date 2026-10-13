# Habu port: compatibility and validation

Dots is a native Habu implementation of the CLI and Markdown store from Zig
revision `f107d0165e2c0f080a911a420e1275433df05f4d`, preserved on the
[`zig` branch](https://github.com/joelreymont/dots/tree/zig). It does not invoke
Zig at runtime. The differential reference in `benchmark/zig-full/` has Zig
0.17 API adaptations and a duplicate-config ownership fix. The product source
is `main.f`, `abbrev.f`, `io.f`, and `lock.f`.

## Current validation

The 2026-10-13 adversarial pass completed on source commit `c735764e` and
binary SHA-256
`dd71cd5378c2a05fd361f00f8fa0ab49f1cdc5ea795e5171f05353f5e6ea4e0b`.
All 289 permanent checks, 5,956 copied-store checks, and 2,211 generated
observations passed. No mutation command targeted a live repository store.
The installed CLI was not replaced.

The repairs cover these reproduced failures:

- Destructive maintenance following symlinks; invisible orphan tree rows;
  lost imported dependency bytes and incorrect archived or nested parent paths.
- Mutations parsing unrelated oversized files or selecting another parent's
  children; JSON byte arrays and invalid UTF-8 handling.
- Reopening leaving tasks hidden in the archive; failed moves changing task
  status; archive symlink writes; nested subtree and ancestor transitions.
- Slugify losing archived/nested paths or dependency targets, overwriting
  occupied destinations, or leaving inconsistent references after failure.
- Failed reads treated as EOF, failed/partial stdout writes, and concurrent
  status changes leaving duplicate active and archived tasks.

The repaired commands serialize cooperating writers before reading state.
Archive transitions preserve the original bytes on the tested move/write
failures. Slugify stages each rename and its dependent rewrites, rolls back
ordinary failures, and preserves all matching targets of duplicated old IDs.
Closing a parent requires every descendant affected by the operation to be
valid and closed.

## Permanent suites and review

All **289 checks across ten suites** pass on binary `dd71cd53`:

| Suite | Result |
| --- | ---: |
| Full command sequences | 98/98 steps |
| Focused edges | 60/60 cases |
| Filesystem | 8/8 cases |
| Graph/import | 4/4 cases |
| Selective loading | 47/47 cases |
| JSON bytes | 20/20 fixtures |
| Archive transitions | 33/33 cases |
| Slugify recovery | 7/7 cases |
| I/O failures | 8/8 cases |
| Concurrent writers | 4/4 cases |

Independent review reported no blocking findings in the reviewed scope after
18 final boundary probes. Review rounds also exercised duplicate IDs,
dependency chains, broken pipes, competing writers, and 16 one-shot injected
syscall failures across closing, reopening, and slugify. Follow-up review
verified the affected behavior after every resulting repair. Passing these
checks does not establish correctness for every filesystem failure or process
interleaving.

## Copied stores and generated cases

Stable snapshots contained **4,590 files from 11 repositories**. The final
run passed **5,956/5,956 checks**: 5,522 reads, 287 lifecycle steps, 13 successful
reopens, 44 each for fix/purge/slugify, and two occupied-destination refusals.
Read-only commands preserved the copied trees. Slugify preserved **4,578 task
files**, including 957 archived tasks and 1,177 dependency target references.
The corpus uses exact comparisons plus the explicit corrected contracts below.

Generated tests added **2,211 observations with zero mismatches**: 720 mixed
command steps, 951 storage/numeric cases, and 540 dependency observations.
Directed fixtures additionally check duplicate-ID dependency fan-out and
readiness, slugify idempotence, nested reopening, descendant close refusal,
and safe closing of standalone archived tasks beside unrelated records.

## Size

Build with `sh build.sh` and pinned Habu `c53b4d2c`. Compiler SHA-256:
`ccf0798dd4e11a3ea4308386704bd09a5f183750d18b802b9b2d9c28d6af2b96`.

| Executable, macOS arm64 | Bytes |
| --- | ---: |
| Habu, final repaired build | 198,396 |
| Smallest verified Zig build | 268,320 |
| Ordinary Zig Small differential reference | 335,280 |
| Habu, initial port | 165,372 |

The repaired binary is **26.1% smaller than the smallest verified Zig build** and
40.8% smaller than ordinary Zig Small. The increase from the initial Habu port
is 33,024 bytes. The repairs add code and cross two 16 KiB Mach-O alignment
boundaries; the increase is not all useful code or all padding. No arbitrary
precision, binary128, or hexadecimal numeric parser was added. Reserved
runtime capacity is distinct from bytes carried in the executable. Exact
hashes and section totals are in the
[validation record](../benchmark/results/adversarial-2026-10-13.json).
The final file contains 155,816 bytes of code, 7,694 bytes of
embedded data, 31,524 bytes of alignment padding, and 3,362 other bytes.
The loader restores a 6,202,840-byte data window; 6,195,146 of those bytes do
not travel in the file. These are size measurements, not speed or memory
benchmarks.

## Comparison contract

The full and edge harnesses compare exit status, stdout, stderr, and the
complete `.dots` tree. They normalize generated suffixes and timestamps, sort
only unspecified `find` ordering within open/closed groups, and compare
config entries as a unique key/value map where ordering is unspecified.

Corrected Zig bugs have explicit expectations. For reopening, both reference
and Habu commands must succeed; the harness then relocates only the named
archived path in the disposable Zig fixture before resuming exact comparison.
Two additional Habu assertions check the reopened active paths, metadata,
children, and empty output. Slugify archive/nested cases and refusal to close
over malformed descendants assert the corrected state directly. The Zig
reference source and executable remain unchanged.

Real-store slugify checks compare task contents, archive placement, and the
set of dependency targets before and after renaming, then require an
idempotent second pass. A duplicate ID may expand to multiple new IDs;
checking the target set catches lost edges that a simple count would miss.
Habu and Tender copies now slugify successfully where Zig fails. Listing and
search checks after those repairs use an independent file census.

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
python3 regression_archive_test.py bin/dot
python3 regression_slugify_test.py bin/dot
python3 regression_io_test.py bin/dot
python3 regression_concurrency_test.py bin/dot
```

All harnesses use disposable stores. The I/O suite uses the pinned compiler
for a direct failed-read probe; the slugify suite uses `cc` to inject an
actual rename failure after the original file has moved. Archive tests also
inject failed writes with a zero file-size limit and ignored `SIGXFSZ`.
Real task contents are not committed as fixtures. Rebuild and rerun after
source or toolchain changes.

## Deliberate behavior and limits

- Reopening an archived child restores its subtree and reopens closed
  ancestors. Existing open/active ancestors and unaffected siblings retain
  their data. A competing active destination is refused without merging;
  two such existing conflicts were tested on copied stores.
- Multi-ID commands commit successful earlier IDs before a later ID fails.
  Slugify similarly commits one consistent rename at a time. Neither is a
  transaction over the entire command batch.
- Cleanup can fail after a successful reopen. The diagnostic explicitly says
  `Reopened issue; temporary cleanup failed`; the transition remains complete.
- Directory locks serialize cooperating Dots writers. Direct file editors do
  not take that lock. Static symlink refusal is not protection against hostile
  concurrent symlink replacement.
- Execution evidence here is macOS arm64. Linux-specific syscall paths have
  not been validated by this run.
- Injected syscall failures test rollback, not power-loss or process-kill
  durability across multiple files. A rollback can itself fail if the
  filesystem keeps failing; no blanket crash-durability guarantee is made.
- On a read-only task directory, Habu reports `Permission denied`; the adapted
  Zig reference can abort with a double-free panic. The Habu diagnostic is
  intentional.

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

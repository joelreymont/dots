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
- Mutations parsing unrelated oversized files, selecting another parent's
  children, or closing a nested task over open children in `.dots/<id>/`;
  JSON byte arrays and invalid UTF-8 handling.
- Reopening leaving tasks hidden in the archive; failed moves changing task
  status; archive symlink writes; nested subtree and ancestor transitions.
- Slugify losing archived/nested paths or dependency targets, overwriting
  occupied destinations, or leaving inconsistent references after failure.
- Failed reads treated as EOF, failed/partial stdout writes, and concurrent
  status changes leaving duplicate active and archived tasks.

The repaired commands serialize cooperating writers before reading state.
Archive transitions preserve the original bytes on the tested move/write
failures. Slugify stages each rename and its dependent rewrites, moves the
children a task keeps in `.dots/<id>/` with it, never moves `.dots/archive` as
the folder of a task named `archive`, rolls back ordinary failures,
and preserves all matching targets of duplicated old IDs.
Closing a task requires every descendant affected by the operation, including
the children a nested or archived task keeps in `.dots/<id>/`, to be valid and
closed; the Zig reference skips a malformed child there, and Habu refuses.

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

Build with `sh build.sh`, which uses the installed `hb` on `PATH`. A build
with Habu `3164d371` measured 198,396 bytes and passed all ten permanent
suites.

| Executable, macOS arm64 | Bytes |
| --- | ---: |
| Habu, current build | 198,396 |
| Zig 0.15.2 ReleaseSmall, stripped, as shipped | 205,104 |
| Zig 0.15.2, same source, smallest flags | 188,320 |
| Habu, initial port | 165,372 |

The Habu binary is **3.3% smaller than the shipped Zig build** and 5.4%
larger than the smallest Zig build of the same source. The shipped release
used Zig 0.15.2 (`release.yml` at `3855fcf`): `zig build -Doptimize=ReleaseSmall`,
then `strip`. The smallest build adds `-fsingle-threaded -fno-unwind-tables`
and strips with `strip -u -r`. Zig 0.15.2 links against the macOS 27 SDK
only with `-target aarch64-macos.14.0`, the shipped runner's target. The later
Zig 0.16 and 0.17 ports add about 55 KB of `std.Io` code, so the 0.17
differential reference under `benchmark/` is not a size baseline.

The file contains 155,100 bytes of code, 9,918 bytes of embedded data, 30,025
bytes of alignment padding, and 3,353 other bytes. Mach-O segments grow in
16 KiB pages, so the file shrinks only when code and data leave a page empty.
Importing JSONL through Habu's shared `jsonl.f` and `decimal.f` replaced 4,216
bytes of Dots-specific code with 9,932 bytes of library code (previously
181,884 bytes). The build keeps only words reachable from `MAIN`, and every one
of the 65 added words is called. Requiring both files without calling them
leaves a binary byte-identical. The library code is larger because its cursor
handles memory and file input, cleanup and close errors, and its decimal
conversion checks overflow exactly. The extra 5,716 bytes of code overflowed
the last `__TEXT` page, so 10,604 bytes of page padding, 128 bytes of code
signature and 64 bytes of data-cell bitmap make up the rest of the 16,512-byte
step. No arbitrary precision, binary128, or hexadecimal numeric parser was
added. The loader restores a 5,919,256-byte data window; 5,909,338 of those
bytes do not travel in the file. These are size measurements, not speed or memory
benchmarks. The [validation record](../benchmark/results/adversarial-2026-10-13.json)
holds hashes and section totals of the earlier 198,396-byte build with Habu
`c53b4d2c`.

## Comparison contract

The full and edge harnesses compare exit status, stdout, stderr, and the
complete `.dots` tree. They normalize generated suffixes and timestamps, sort
only unspecified `find` ordering within open/closed groups, and compare
config entries as a unique key/value map where ordering is unspecified.

Corrected Zig bugs have explicit expectations. For reopening, both reference
and Habu commands must succeed; the harness then relocates only the named
archived path in the disposable Zig fixture before resuming exact comparison.
Two additional Habu assertions check the reopened active paths, metadata,
children, and empty output. Slugify archive/nested cases, refusal to close
over malformed descendants, the reserved `archive` ID and the nested-layout
cases assert both sides' outcome directly. The Zig reference source and
executable remain unchanged.

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

All harnesses use disposable stores. The I/O suite uses the installed `hb`
for a direct failed-read probe; the slugify suite uses `cc` to inject an
actual rename failure after the original file has moved. Archive tests also
inject failed writes with a zero file-size limit and ignored `SIGXFSZ`.
Real task contents are not committed as fixtures. Rebuild and rerun after
source or toolchain changes.

## Nested layout

A task's file is `D/t.md`, where `D` is a partition root (`.dots` or
`.dots/archive`) or its parent's own folder. A task with children has its own
folder `D/t/`, holding its file `D/t/t.md` and its children. A file named after
its folder is that folder's task, and its parent is the task owning the
enclosing folder, if any. Any other file is a child of the folder it sits in.
Zig reads only the first path component, so below the top level it gives a
nested owner no parent and cannot find an archived child.

A task with a parent closes in place; a parentless task moves to the archive
with its whole folder. Reopening moves the top-most archived folder containing
the target back and reopens its closed ancestors. Closing requires the
descendants under the task's own folder, under `<partition>/<id>/` and, for an
archived task, under `.dots/<id>/` to be closed at any depth. A folder
`.dots/<id>/` whose task lives elsewhere, as Zig's `add -P` writes for a nested
parent, still reads as that task's children; `tree` shows them as orphan
roots, as Zig does. Habu finds a task at any depth the 512-byte path buffer
admits; Zig's search stops at 10 levels.

| Case | Zig | Habu | Check |
| --- | --- | --- | --- |
| `show` of an archived child | `Issue not found` | shows it | `test.py` hierarchy step 11; edge `show-archived-child` |
| `show` 11 levels deep | `Issue not found` | shows it | edge `show-depth-eleven` |
| `tree` over a nested owner | omits the owner | lists it under its parent | edge `tree-nested-owner`, `tree-nested-owner-id` |
| `tree` over a deep child without a parent file | omits it | lists it as an orphan root | `test.py` tree-shapes step 0; edge `tree-deep-root` |
| `off a child` once `a` has moved to the archive | `Issue not found` | closes the archived child | loading `status-after-parent-move` |
| `rm` of an archived child | `Issue not found` | removes it | edge `rm-archived-child` |
| `rm q` while an archived child blocks on `q` | `Issue not found` | removes `q` and the reference | edge `rm-archived-child-referencer` |
| JSONL import blocking on an archived child | skips the dependency with a warning | keeps it | edge `import-block-archived-child` |

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
- `archive` names the archive partition, so no command creates a task with
  that ID. `add -P archive` fails with `Invalid issue id`, and JSONL import
  skips a row whose ID or parent is `archive`, counting it in the
  skipped-issues warning. Zig writes those tasks into `.dots/archive/`.
  Existing records named `archive` still read. `edge_test.py` asserts both
  sides in `import-archive-id` and `add-parent-archive-id`.
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
under 1 MiB, config under 64 KiB, path buffer of 512 bytes, and JSONL line of
at most 1 MiB. Issue
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

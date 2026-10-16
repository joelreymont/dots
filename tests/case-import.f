\ case-import.f - JSONL import: `dot init --from-jsonl import.jsonl` on rows,
\ priorities, byte arrays, dependencies, parents, line limits, duplicates, read
\ failures and a path that is no file, then init beside a broken .git, beside
\ a .git with no git on PATH, and concurrent inits. An import
\ case writes import.jsonl beside `.dots` and runs one import on its own store.
require src/lib/fs.f
require src/lib/fs-mutate.f
require dot.f
using DOT-T
package DOT-IMPORT

\ Write import.jsonl beside `.dots`.
: JSONL ( ptr u8 n -- ) {: a:ptr u:n :}
   s" ../import.jsonl" a u PUT ;

: IMPORT ( -- )
   s" init|--from-jsonl|import.jsonl" RUN ;

\ The smallest valid row, which the padded cases repeat.
: ROW-A ( -- ptr u8 n )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}" ;

DYNAMIC-BUFFER LINE u8

\ Append the row to import.jsonl count times, each padded with spaces to u
\ bytes before its LF.
: PADDED ( ptr u8 n n n -- )
   {: row:ptr rowu:n u:n count:n :}
   u 1+ LINE-RESERVE
   row 0 LINE rowu BYTE-COPY
   u rowu ?do 32 i LINE c! loop
   10 u LINE c!
   count 0 ?do s" import.jsonl" FILE$ 0 LINE u 1+ APPEND-FILE loop ;

s" import" SECTION

\ Rows become task files with every field; a done row is archived and reads back.
: ROWS ( -- )
   s\" {\"id\":\"a\",\"title\":\"Imported root\",\"description\":\"Body\",\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"assignee\":\"joel\",\"created_at\":\"2026-01-01T00:00:00Z\",\"updated_at\":\"2026-01-05T00:00:00Z\"}
{\"id\":\"b\",\"title\":\"Imported done\",\"status\":\"done\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-02T00:00:00Z\",\"closed_at\":\"2026-01-03T00:00:00Z\",\"close_reason\":\"ok\",\"dependencies\":[{\"depends_on_id\":\"a\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: Imported root
  status: open
  priority: 2
  issue-type: task
  assignee: joel
  created-at: \"2026-01-01T00:00:00Z\"
  ---
  
  Body
.
d .dots/archive
f .dots/archive/b.md
  ---
  title: Imported done
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-02T00:00:00Z\"
  closed-at: \"2026-01-03T00:00:00Z\"
  close-reason: ok
  blocks:
    - a
  ---
.
" TREE=
   s" find|Imported" RUN
   0 RC=
   s\" [a] o Imported root\n[b] x Imported done\n" OUT=
   s" " ERR=
;
s" rows" ' ROWS DOT-CASE

\ A malformed line ends the import; the rows before it stay.
: MALFORMED-LINE ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
not json
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" malformed-line" ' MALFORMED-LINE DOT-CASE

\ A row still waiting for its parent's row when a malformed line ends the
\ import stays too, in the folder named after its parent.
: MALFORMED-LINE-WAITING ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
not json
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s\" d .dots
d .dots/archive
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" malformed-line-waiting" ' MALFORMED-LINE-WAITING DOT-CASE

\ An empty close reason is kept as an empty string.
: EMPTY-CLOSE-REASON ( -- )
   s\" {\"id\":\"closed\",\"title\":\"Closed\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"close_reason\":\"\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/closed.md
  ---
  title: Closed
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  close-reason: \"\"
  ---
.
" TREE=
;
s" empty-close-reason" ' EMPTY-CLOSE-REASON DOT-CASE

\ An integral float priority is the integer.
: PRIORITY-FLOAT ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1.0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-float" ' PRIORITY-FLOAT DOT-CASE

\ A fractional mantissa scaled by its exponent is an integer.
: PRIORITY-SCALED ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1.2e1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 12
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-scaled" ' PRIORITY-SCALED DOT-CASE

\ A negative exponent that leaves an integer is that integer.
: PRIORITY-NEGATIVE-EXPONENT ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":120e-1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 12
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-negative-exponent" ' PRIORITY-NEGATIVE-EXPONENT DOT-CASE

\ The largest i64, written as a float, is kept exactly.
: PRIORITY-MAX ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":9223372036854775807.0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 9223372036854775807
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-max" ' PRIORITY-MAX DOT-CASE

\ The smallest i64, written as a float, is kept exactly.
: PRIORITY-MIN ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":-9223372036854775808.0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: -9223372036854775808
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-min" ' PRIORITY-MIN DOT-CASE

\ A string priority reads as a number, exponent form included.
: PRIORITY-STRING ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":\"1e0\",\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" priority-string" ' PRIORITY-STRING DOT-CASE

\ A string priority reads in decimal.f's grammar, which takes one `_` between
\ digits.
: PRIORITY-STRING-SEPARATORS ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":\"1__2\",\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" priority-string-separators" ' PRIORITY-STRING-SEPARATORS DOT-CASE

\ A byte-array element reads in decimal.f's grammar, which takes one `_`
\ between digits.
: BYTE-STRING-SEPARATORS ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":2,\"description\":[\"1__2\"],\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" byte-string-separators" ' BYTE-STRING-SEPARATORS DOT-CASE

\ A priority that is not an integer is refused.
: PRIORITY-FRACTION ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1.2e0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" priority-fraction" ' PRIORITY-FRACTION DOT-CASE

\ A priority past the i64 range is refused.
: PRIORITY-OVERFLOW ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":9223372036854775808.0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" priority-overflow" ' PRIORITY-OVERFLOW DOT-CASE

\ A row naming a key twice is refused.
: DUPLICATE-KEY ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" duplicate-key" ' DUPLICATE-KEY DOT-CASE

\ A dependency naming depends_on_id twice is refused.
: DUPLICATE-DEPENDENCY-ID ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"x\",\"depends_on_id\":\"y\",\"type\":\"blocks\"}]}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" duplicate-dependency-id" ' DUPLICATE-DEPENDENCY-ID DOT-CASE

\ A dependency naming type twice is refused.
: DUPLICATE-DEPENDENCY-TYPE ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"x\",\"type\":\"blocks\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" duplicate-dependency-type" ' DUPLICATE-DEPENDENCY-TYPE DOT-CASE

\ Empty optional strings are written as empty strings.
: OPTIONAL-EMPTY ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"assignee\":\"\",\"closed_at\":\"\",\"close_reason\":\"\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  assignee: \"\"
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"\"
  close-reason: \"\"
  ---
.
d .dots/archive
" TREE=
;
s" optional-empty" ' OPTIONAL-EMPTY DOT-CASE

\ A row whose parent id is empty is skipped and counted.
: EMPTY-PARENT ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s" " OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" empty-parent" ' EMPTY-PARENT DOT-CASE

\ A row whose parent folder is taken by a file is skipped and counted.
: PARENT-PATH-IS-FILE ( -- )
   s" p" s\" ordinary file\n" PUT
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s" " OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s" d .dots
d .dots/archive
f .dots/p
  ordinary file
.
" TREE=
;
s" parent-path-is-file" ' PARENT-PATH-IS-FILE DOT-CASE

\ A row whose parent folder is a link is skipped and counted, nothing written.
: PARENT-PATH-IS-SYMLINK ( -- )
   s" outside" FILE$ MAKE-DIRS
   s" ../outside" s" p" LINK
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s" " OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s" d .dots
d .dots/archive
l .dots/p -> ../outside
" TREE=
   s" outside" s\" d outside\n" DIR=
;
s" parent-path-is-symlink" ' PARENT-PATH-IS-SYMLINK DOT-CASE

\ A failure making a parent's folder ends the import, the waiting row unplaced.
: PARENT-FOLDER-FAILS ( -- )
   s" x/x.md" s" X" s" open" 1 PUT-ISSUE
   s" x/p.md" s" P" s" open" 1 PUT-ISSUE
   s" x" READ-ONLY MODE
   s\" {\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"q\",\"type\":\"parent-child\"}]}
{\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   s" x" WRITABLE MODE
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" d .dots
d .dots/archive
d .dots/x
f .dots/x/p.md
  ---
  title: P
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/x/x.md
  ---
  title: X
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" parent-folder-fails" ' PARENT-FOLDER-FAILS DOT-CASE

\ A parentless row whose folder is a link is skipped and counted, as add refuses
\ it.
: OWN-PATH-IS-SYMLINK ( -- )
   s" outside" FILE$ MAKE-DIRS
   s" ../outside" s" a" LINK
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s" " OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s" d .dots
l .dots/a -> ../outside
d .dots/archive
" TREE=
   s" outside" s\" d outside\n" DIR=
;
s" own-path-is-symlink" ' OWN-PATH-IS-SYMLINK DOT-CASE

\ A child row after its parent nests both in the parent's folder.
: PARENT-NESTS ( -- )
   s\" {\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" parent-nests" ' PARENT-NESTS DOT-CASE

\ A line of 1048575 bytes before its LF is read.
: LINE-AT-LIMIT ( -- )
   ROW-A 1048575 1 PADDED
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" line-at-limit" ' LINE-AT-LIMIT DOT-CASE

\ A line of 1048576 bytes before its LF ends the import.
: LINE-OVER-LIMIT ( -- )
   ROW-A 1048576 1 PADDED
   IMPORT
   1 RC=
   s" " OUT=
   s\" JSONL line too long\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" line-over-limit" ' LINE-OVER-LIMIT DOT-CASE

\ A 32 MiB stream repeating one id imports it once.
: STREAM-DUPLICATES ( -- )
   ROW-A 8192 4096 PADDED
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" stream-duplicates" ' STREAM-DUPLICATES DOT-CASE

\ A row whose id this run imported is dropped with its dependencies.
: DUPLICATE-ROW ( -- )
   s" b.md" s" B" s" open" 1 PUT-ISSUE
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"a\",\"title\":\"Again\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"b\",\"type\":\"blocks\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" duplicate-row" ' DUPLICATE-ROW DOT-CASE

\ A dependency id holding a newline is skipped, not split into two ids.
: DEPENDENCY-NEWLINE-ID ( -- )
   s" a.md" s" A" s" open" 1 PUT-ISSUE
   s" b.md" s" B" s" open" 1 PUT-ISSUE
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"a\\nb\",\"type\":\"blocks\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 dependencies due to errors\n" ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" dependency-newline-id" ' DEPENDENCY-NEWLINE-ID DOT-CASE

\ A dependency listed twice is recorded once.
: DEPENDENCY-REPEATED ( -- )
   s" a.md" s" A" s" open" 1 PUT-ISSUE
   s" b.md" s" B" s" open" 1 PUT-ISSUE
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"a\"},{\"depends_on_id\":\"a\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - a
  ---
.
" TREE=
;
s" dependency-repeated" ' DEPENDENCY-REPEATED DOT-CASE

\ Under an archived parent an open row is skipped and a closed row nests in the
\ archive; a row it blocks gets its edge.
: ARCHIVED-PARENT ( -- )
   s" archive/p.md" s" P" s" closed" 1 PUT-ISSUE
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"d\",\"title\":\"D\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"blocks\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/d.md
  ---
  title: D
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p
  ---
.
" TREE=
;
s" archived-parent" ' ARCHIVED-PARENT DOT-CASE

\ A closed row does not nest under an archived parent through an archive that
\ is a symlink: the import fails before it writes.
: ARCHIVED-PARENT-SYMLINK ( -- )
   s" ../external/p.md" s" P" s" closed" 1 PUT-ISSUE
   s" archive" RM-DIR
   s" ../external" s" archive" LINK
   s\" {\"id\":\"d\",\"title\":\"D\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Unsafe archive symlink\n" ERR=
   s" d .dots
l .dots/archive -> ../external
" TREE=
   s" external" s" d external
f external/p.md
  ---
  title: P
  status: closed
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" DIR=
;
s" archived-parent-symlink" ' ARCHIVED-PARENT-SYMLINK DOT-CASE

\ Rows naming a nested parent: the child goes in the parent's own folder, made
\ where the parent lives, and the blocker gets its edge.
: NESTED-PARENT ( -- )
   s" q/q.md" s" Q" s" open" 1 PUT-ISSUE
   s" q/p.md" s" P" s" open" 1 PUT-ISSUE
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"blocks\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p
  ---
.
d .dots/q
d .dots/q/p
f .dots/q/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/q/p/p.md
  ---
  title: P
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/q/q.md
  ---
  title: Q
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" nested-parent" ' NESTED-PARENT DOT-CASE

\ Under a closed parent an open row is skipped, as add -P refuses it, and a
\ closed row goes in the parent's own folder.
: CLOSED-PARENT ( -- )
   s" p/p.md" s" P" s" open" 1 PUT-ISSUE
   s" p/c.md" s" C" s" closed" 1 PUT-ISSUE
   s\" {\"id\":\"k\",\"title\":\"K\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"parent-child\"}]}
{\"id\":\"m\",\"title\":\"M\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s\" d .dots
d .dots/archive
d .dots/p
d .dots/p/c
f .dots/p/c/c.md
  ---
  title: C
  status: closed
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/c/m.md
  ---
  title: M
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" closed-parent" ' CLOSED-PARENT DOT-CASE

\ Under a closed parent row an open row is skipped and a closed row nests, also
\ before the parent's row; the closed family is archived.
: CLOSED-PARENT-ROW ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"d\",\"title\":\"D\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/d.md
  ---
  title: D
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" closed-parent-row" ' CLOSED-PARENT-ROW DOT-CASE

\ Rows before their parent's row nest as they would after it.
: CHILD-BEFORE-PARENT ( -- )
   s\" {\"id\":\"g\",\"title\":\"G\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"parent-child\"}]}
{\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/p
d .dots/p/c
f .dots/p/c/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/c/g.md
  ---
  title: G
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" child-before-parent" ' CHILD-BEFORE-PARENT DOT-CASE

\ Rows waiting only on each other, a parent cycle, start from the first live
\ row when the stream ends: c, blocked on the waiting p, goes first, then p,
\ and q follows into p's own folder.
: WAITING-PARENT-CYCLE ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"q\",\"type\":\"parent-child\"}]}
{\"id\":\"q\",\"title\":\"Q\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/q
d .dots/q/p
f .dots/q/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/q/p/q.md
  ---
  title: Q
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" waiting-parent-cycle" ' WAITING-PARENT-CYCLE DOT-CASE

\ A row whose parent row was skipped is skipped, at any depth.
: SKIPPED-FAMILY ( -- )
   s\" {\"id\":\"p\",\"title\":\"P\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"g\",\"title\":\"G\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 2 issues due to errors\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p.md
  ---
  title: P
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" skipped-family" ' SKIPPED-FAMILY DOT-CASE

\ The same rows before their parent's row are skipped as they would be after it.
: SKIPPED-FAMILY-WAITING ( -- )
   s\" {\"id\":\"g\",\"title\":\"G\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"parent-child\"}]}
{\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 2 issues due to errors\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p.md
  ---
  title: P
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" skipped-family-waiting" ' SKIPPED-FAMILY-WAITING DOT-CASE

\ An edge to a row still waiting for its parent's row is written when that row
\ is placed.
: HELD-EDGE ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" held-edge" ' HELD-EDGE DOT-CASE

\ An edge held for a waiting row that is finally skipped counts as a skipped
\ dependency and is never written.
: HELD-EDGE-SKIPPED ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"closed\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\nWarning: skipped 1 dependencies due to errors\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p.md
  ---
  title: P
  status: closed
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" held-edge-skipped" ' HELD-EDGE-SKIPPED DOT-CASE

\ A held edge is written before the waiting row's own edges, so the row's edge
\ back to its blocker is a refused cycle, as when the rows come in order.
: HELD-EDGE-ORDER ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"},{\"depends_on_id\":\"b\",\"type\":\"blocks\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 dependencies due to errors\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" held-edge-order" ' HELD-EDGE-ORDER DOT-CASE

\ The tree both held-edge-duplicate cases leave: c waited on p and b's held
\ edge to it is written.
: HELD-DUPLICATE-TREE$ ( -- ptr u8 n )
   s\" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" ;

\ A duplicate of a held edge's blocker, skipped for its parent, leaves the
\ blocker's held edge.
: HELD-EDGE-DUPLICATE ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"archive\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   HELD-DUPLICATE-TREE$ TREE=
;
s" held-edge-duplicate" ' HELD-EDGE-DUPLICATE DOT-CASE

\ A duplicate of a held edge's waiting row, skipped for its parent, leaves the
\ edge held for the waiting row, uncounted.
: HELD-EDGE-DUPLICATE-TARGET ( -- )
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}
{\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"archive\",\"type\":\"parent-child\"}]}
{\"id\":\"p\",\"title\":\"P\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 3 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   HELD-DUPLICATE-TREE$ TREE=
;
s" held-edge-duplicate-target" ' HELD-EDGE-DUPLICATE-TARGET DOT-CASE

\ A row naming a malformed parent is skipped, as add -P refuses it.
: MALFORMED-PARENT ( -- )
   s" p.md" s\" not a task\n" PUT
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s" " OUT=
   s\" Warning: skipped 1 issues due to errors\n" ERR=
   s" d .dots
d .dots/archive
f .dots/p.md
  not a task
.
" TREE=
;
s" malformed-parent" ' MALFORMED-PARENT DOT-CASE

\ A file where the parent's own folder goes is no folder: the import ends before
\ the row's first write, as add -P refuses.
: PARENT-NOT-DIRECTORY ( -- )
   s" p.md" s" P" s" open" 1 PUT-ISSUE
   s" p" s\" junk\n" PUT
   s\" {\"id\":\"c\",\"title\":\"C\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Not a directory: .dots/p\n" ERR=
   s" d .dots
d .dots/archive
f .dots/p
  junk
.
f .dots/p.md
  ---
  title: P
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" parent-not-directory" ' PARENT-NOT-DIRECTORY DOT-CASE

\ With p at the 1015-byte path, p's own folder is 1012 bytes: p's file there,
\ 1017 bytes, fits FS-PATH-CAP, but the 9-byte id's file, 1025 bytes, does
\ not. The import ends before p gains a folder, as add -P refuses. The tree is
\ read with the top folder renamed back to `a`.
: CHILD-PATH-TOO-LONG ( -- )
   LONG BUF:CLEAR s" a/" L+ D-NAME BCD+ s" /p.md" L+
   L$ s" P" s" open" 1 PUT-ISSUE
   s\" {\"id\":\"child-row\",\"title\":\"Child\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"p\",\"type\":\"parent-child\"}]}
" JSONL
   true MOVE-TOP
   IMPORT
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   false MOVE-TOP
   LONG BUF:CLEAR
   s\" d .dots\nd .dots/a\nd .dots/a/" L+ [char] b NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ [char] b NAME-MAX L-BYTES s" /" L+ [char] c NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ D-NAME BCD+ s\" \nf .dots/a/" L+ D-NAME BCD+
   s\" /p.md\n  ---\n  title: P\n  status: open\n  priority: 1\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\n" L+
   L$ TREE=
;
s" child-path-too-long" ' CHILD-PATH-TOO-LONG DOT-CASE

\ Strings given as byte arrays are written as their bytes.
: BYTE-STRINGS ( -- )
   s\" {\"id\":\"a\",\"title\":[65,195,169],\"description\":[98,111,100,121,255],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A\xc3\xa9
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
  
  body\xff
.
d .dots/archive
" TREE=
;
s" byte-strings" ' BYTE-STRINGS DOT-CASE

\ Byte array elements may be integral floats or decimal strings.
: BYTE-FORMS ( -- )
   s\" {\"id\":\"a\",\"title\":[1.0,\"65\",12,255],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: \x01A\x0c\xff
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" byte-forms" ' BYTE-FORMS DOT-CASE

\ A byte array element above 255 is refused.
: BYTE-ABOVE-RANGE ( -- )
   s\" {\"id\":\"a\",\"title\":[256],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" byte-above-range" ' BYTE-ABOVE-RANGE DOT-CASE

\ A negative byte array element is refused.
: BYTE-NEGATIVE ( -- )
   s\" {\"id\":\"a\",\"title\":[-1],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" byte-negative" ' BYTE-NEGATIVE DOT-CASE

\ A byte array element that is not an integer is refused.
: BYTE-FRACTION ( -- )
   s\" {\"id\":\"a\",\"title\":[1.5],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" byte-fraction" ' BYTE-FRACTION DOT-CASE

\ A byte array element that is not a number or string is refused.
: BYTE-NOT-NUMBER ( -- )
   s\" {\"id\":\"a\",\"title\":[true],\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Invalid JSONL file\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" byte-not-number" ' BYTE-NOT-NUMBER DOT-CASE

\ A dependency's id and type may be byte arrays.
: DEPENDENCY-BYTE-ARRAYS ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"b\",\"title\":\"B\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":[97.0],\"type\":[\"98\",108,111,99,107,115]}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 2 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - a
  ---
.
" TREE=
;
s" dependency-byte-arrays" ' DEPENDENCY-BYTE-ARRAYS DOT-CASE

\ A row with the archive id, or under it, is skipped and counted.
: ARCHIVE-ID ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"archive\",\"title\":\"Archive\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
{\"id\":\"kid\",\"title\":\"Kid\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"archive\",\"type\":\"parent-child\"}]}
" JSONL
   IMPORT
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s\" Warning: skipped 2 issues due to errors\n" ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" archive-id" ' ARCHIVE-ID DOT-CASE

\ A file import cannot open is an I/O error.
: UNREADABLE-FILE ( -- )
   s\" {\"id\":\"a\",\"title\":\"A\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\"}
" JSONL
   s" ../import.jsonl" 0 MODE
   IMPORT
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" unreadable-file" ' UNREADABLE-FILE DOT-CASE

\ init refuses an import path that is no regular file before it creates
\ anything.
: NOT-A-FILE ( -- )
   s" ../.dots" RM-DIR
   s" import.jsonl" FILE$ MAKE-DIRS
   IMPORT
   1 RC=
   s" " OUT=
   s\" Not a file: import.jsonl\n" ERR=
   s" " TREE=
;
s" not-a-file" ' NOT-A-FILE DOT-CASE

\ A row whose task path is taken by a directory is refused.
: IMPORT-OVER-TASK-DIR ( -- )
   s" .dots/a.md" FILE$ MAKE-DIRS
   ROW-A JSONL
   IMPORT
   1 RC=
   s" " OUT=
   s\" Not a file: .dots/a.md\n" ERR=
   s\" d .dots\nd .dots/a.md\nd .dots/archive\n" TREE=
;
s" import-over-task-dir" ' IMPORT-OVER-TASK-DIR DOT-CASE

\ A read that fails after the open is an I/O error, never the end of input.
: READ-FAILURE ( -- )
   s" import.jsonl" FILE$ MAKE-DIRS
   s" tests/read-probe.f" RUN-HB
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" read-failure" ' READ-FAILURE DOT-CASE

\ init beside a .git that is no repository warns that git add failed.
: INIT-GIT-INVALID ( -- )
   s" .git" FILE$ MAKE-DIRS
   s" init" RUN
   0 RC=
   s" " OUT=
   s\" Warning: git add failed with exit code 128\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" init-git-invalid" ' INIT-GIT-INVALID DOT-CASE

\ init beside a .git with no git on PATH warns that .dots is not staged.
: INIT-NO-GIT ( -- )
   s" ../.dots" RM-DIR
   s" .git" FILE$ MAKE-DIRS
   s" init" RUN-NO-GIT
   0 RC=
   s" " OUT=
   s\" Warning: git not found; .dots not staged\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" init-no-git" ' INIT-NO-GIT DOT-CASE

\ Concurrent inits on a directory without `.dots` all succeed.
: INIT-CONCURRENT ( -- )
   s" ../.dots" RM-DIR
   s" init" SPAWN s" init" SPAWN s" init" SPAWN s" init" SPAWN
   WAIT 0 RC= WAIT 0 RC= WAIT 0 RC= WAIT 0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" init-concurrent" ' INIT-CONCURRENT DOT-CASE

;package
;using

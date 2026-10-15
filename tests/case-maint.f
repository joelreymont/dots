\ case-maint.f - maintenance: rm removes a task's whole family and strips the
\ references to it, purge empties the archive without following a symlink, fix moves the files of
\ a folder no task owns to the top, and each mutation reports Permission denied
\ on a read-only store. Each case is one `dot` command on its own store.
require dot.f
using DOT-T
package DOT-MAINT

365 constant RO-MODE                    \ 0555: `.dots` refuses new entries
493 constant RW-MODE                    \ 0755: restored before the checks

s" maint" SECTION

\ ---- rm -------------------------------------------------------------------------

: RM-STRIPS-REFERENCES ( -- )
   s" a.md" s" ---
title: A
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - b
  - c
---
" PUT
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/k.md" s" ---
title: K
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - b
---
" PUT
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" c.md" s" C" s" open" 2 PUT-ISSUE
   s" rm|b" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
d .dots/archive
d .dots/archive/p
f .dots/archive/p/k.md
  ---
  title: K
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/c.md
  ---
  title: C
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" rm-strips-references" ' RM-STRIPS-REFERENCES DOT-CASE

\ P's file has no own folder: its family is P, its legacy folder p/ and, to a
\ fixed point, C's legacy folder c/. Q keeps only its block on K.
: RM-LEGACY-FAMILY ( -- )
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c.md" s" C" s" open" 2 PUT-ISSUE
   s" c/g.md" s" G" s" open" 2 PUT-ISSUE
   s" k.md" s" K" s" open" 2 PUT-ISSUE
   s" q.md" s" ---
title: Q
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - c
  - g
  - k
---
" PUT
   s" rm|p" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/k.md
  ---
  title: K
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/q.md
  ---
  title: Q
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - k
  ---
.
" TREE=
;
s" rm-legacy-family" ' RM-LEGACY-FAMILY DOT-CASE

\ c went with p's family, so its own operand is done.
: RM-FAMILY-OPERAND ( -- )
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c.md" s" C" s" open" 2 PUT-ISSUE
   s" k.md" s" K" s" open" 2 PUT-ISSUE
   s" rm|p|c" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/k.md
  ---
  title: K
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" rm-family-operand" ' RM-FAMILY-OPERAND DOT-CASE

: RM-ARCHIVE-SYMLINK ( -- )
   s" ../outside/r/r.md" s" R" s" closed" 2 PUT-ISSUE
   s" archive" RM-DIR
   s" ../outside" s" archive" LINK
   s" rm|r" RUN
   1 RC=
   s" " OUT=
   s\" Unsafe archive symlink\n" ERR=
   s" d .dots
l .dots/archive -> ../outside
" TREE=
   s" outside" s" d outside
d outside/r
f outside/r/r.md
  ---
  title: R
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" DIR=
;
s" rm-archive-symlink" ' RM-ARCHIVE-SYMLINK DOT-CASE

\ G's own folder sits under C's: it goes whole, with G's legacy folder g/, and
\ P and C stay. P keeps only its block on C.
: RM-DEEP-OWN-FOLDER ( -- )
   s" p/p.md" s" ---
title: P
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - c
  - g
  - h
  - k
---
" PUT
   s" p/c/c.md" s" C" s" open" 2 PUT-ISSUE
   s" p/c/g/g.md" s" G" s" open" 2 PUT-ISSUE
   s" p/c/g/h.md" s" H" s" open" 2 PUT-ISSUE
   s" g/k.md" s" K" s" open" 2 PUT-ISSUE
   s" rm|g" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/p
d .dots/p/c
f .dots/p/c/c.md
  ---
  title: C
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
" TREE=
;
s" rm-deep-own-folder" ' RM-DEEP-OWN-FOLDER DOT-CASE

\ Archived R's family is its own folder archive/r/ and its legacy folder r/ in
\ the active partition; folders named r elsewhere are not R's. H keeps only its
\ blocks on X2 and X3.
: RM-ARCHIVED-FAMILY ( -- )
   s" archive/r/r.md" s" R" s" closed" 2 PUT-ISSUE
   s" archive/r/d.md" s" D" s" closed" 2 PUT-ISSUE
   s" archive/o/r/x3.md" s" X3" s" closed" 2 PUT-ISSUE
   s" r/x.md" s" X" s" open" 2 PUT-ISSUE
   s" o/r/x2.md" s" X2" s" open" 2 PUT-ISSUE
   s" h.md" s" ---
title: H
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - d
  - x
  - x2
  - x3
---
" PUT
   s" rm|r" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/o
d .dots/archive/o/r
f .dots/archive/o/r/x3.md
  ---
  title: X3
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/h.md
  ---
  title: H
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - x2
    - x3
  ---
.
d .dots/o
d .dots/o/r
f .dots/o/r/x2.md
  ---
  title: X2
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" rm-archived-family" ' RM-ARCHIVED-FAMILY DOT-CASE

\ A blocks B: removing A first must not write A back while stripping B.
: RM-REFERENCER-FIRST ( -- )
   s" a.md" s" ---
title: A
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - b
---
" PUT
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" rm|a|b" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" rm-referencer-first" ' RM-REFERENCER-FIRST DOT-CASE

: RM-LATER-MISSING ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" rm|a|absent" RUN
   1 RC=
   s" " OUT=
   s\" Issue not found: absent\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" rm-later-missing" ' RM-LATER-MISSING DOT-CASE

: RM-READ-ONLY ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" ." RO-MODE MODE
   s" rm|a" RUN
   s" ." RW-MODE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" rm-read-only" ' RM-READ-ONLY DOT-CASE

: UPDATE-READ-ONLY ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" ." RO-MODE MODE
   s" update|a|--status|done" RUN
   s" ." RW-MODE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" update-read-only" ' UPDATE-READ-ONLY DOT-CASE

\ ---- purge ----------------------------------------------------------------------

: PURGE-ARCHIVE ( -- )
   s" archive/old.md" s" Old" s" closed" 2 PUT-ISSUE
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/c.md" s" C" s" closed" 2 PUT-ISSUE
   s" live.md" s" Live" s" open" 2 PUT-ISSUE
   s" purge" RUN
   0 RC=
   s\" Archive purged\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/live.md
  ---
  title: Live
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" purge-archive" ' PURGE-ARCHIVE DOT-CASE

\ The archive links to keep/: purge unlinks it and keep/ keeps its file.
: PURGE-ARCHIVE-SYMLINK ( -- )
   s" archive" RM-DIR
   s" keep/sentinel.txt" s\" untouched\n" PUT
   s" keep" s" archive" LINK
   s" purge" RUN
   0 RC=
   s\" Archive purged\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/keep
f .dots/keep/sentinel.txt
  untouched
.
" TREE=
;
s" purge-archive-symlink" ' PURGE-ARCHIVE-SYMLINK DOT-CASE

: PURGE-DEEP ( -- )
   s" archive/d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/d12/d13/d14/d15/d16/d17/d18/d19/d20/d21/d22/d23/d24/d25/d26/d27/d28/d29/d30/d31/d32/d33/d34/x.md"
   s" Deep archived" s" closed" 2 PUT-ISSUE
   s" purge" RUN
   0 RC=
   s\" Archive purged\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" purge-deep" ' PURGE-DEEP DOT-CASE

\ The archive's files go before the archive itself is refused; the archive
\ stays, empty.
: PURGE-READ-ONLY ( -- )
   s" archive/a.md" s" A" s" closed" 2 PUT-ISSUE
   s" ." RO-MODE MODE
   s" purge" RUN
   s" ." RW-MODE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" purge-read-only" ' PURGE-READ-ONLY DOT-CASE

\ ---- fix ------------------------------------------------------------------------

\ The second run finds nothing left to repair.
: FIX-ORPHAN-FOLDER ( -- )
   s" orphan/child.md" s" Orphan child" s" open" 2 PUT-ISSUE
   s" fix" RUN
   0 RC=
   s\" Fixed 1 orphan parent(s), moved 1 file(s)\n" OUT=
   s" " ERR=
   s" fix" RUN
   0 RC=
   s\" No fixes needed\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/child.md
  ---
  title: Orphan child
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" fix-orphan-folder" ' FIX-ORPHAN-FOLDER DOT-CASE

\ Without `.dots` fix finds nothing to repair and creates nothing.
: FIX-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" fix" RUN
   0 RC=
   s\" No fixes needed\n" OUT=
   s" " ERR=
   s" " TREE=
;
s" fix-no-store" ' FIX-NO-STORE DOT-CASE

\ The orphan file's name holds a newline; it moves to the top like any other.
: FIX-NEWLINE-NAME ( -- )
   s\" orphan/odd\nname.md" s" Orphan newline child" s" open" 2 PUT-ISSUE
   s" fix" RUN
   0 RC=
   s\" Fixed 1 orphan parent(s), moved 1 file(s)\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/odd\nname.md\n  ---\n  title: Orphan newline child\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" fix-newline-name" ' FIX-NEWLINE-NAME DOT-CASE

: FIX-OWNED-FOLDER ( -- )
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c.md" s" C" s" open" 2 PUT-ISSUE
   s" fix" RUN
   0 RC=
   s\" No fixes needed\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/c.md
  ---
  title: C
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" fix-owned-folder" ' FIX-OWNED-FOLDER DOT-CASE

\ orphan links to a directory beside `.dots` holding x.md, which stays there.
: FIX-SYMLINK-FOLDER ( -- )
   s" ../external/x.md" s" X" s" open" 2 PUT-ISSUE
   s" ../external" s" orphan" LINK
   s" fix" RUN
   0 RC=
   s\" No fixes needed\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
l .dots/orphan -> ../external
" TREE=
;
s" fix-symlink-folder" ' FIX-SYMLINK-FOLDER DOT-CASE

\ orphan/x.md links to a task file beside `.dots`; the link stays in place.
: FIX-SYMLINK-CHILD ( -- )
   s" ../external.md" s" X" s" open" 2 PUT-ISSUE
   s" ../../external.md" s" orphan/x.md" LINK
   s" fix" RUN
   0 RC=
   s\" Fixed 1 orphan parent(s), moved 0 file(s)\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/orphan
l .dots/orphan/x.md -> ../../external.md
" TREE=
;
s" fix-symlink-child" ' FIX-SYMLINK-CHILD DOT-CASE

\ b.md is taken at the top, so neither orphan file moves, a.md included.
: FIX-OCCUPIED ( -- )
   s" orphan/a.md" s" A" s" open" 2 PUT-ISSUE
   s" orphan/b.md" s" B" s" open" 2 PUT-ISSUE
   s" b.md" s" Top" s" open" 2 PUT-ISSUE
   s" fix" RUN
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: Top
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/orphan
f .dots/orphan/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/orphan/b.md
  ---
  title: B
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" fix-occupied" ' FIX-OCCUPIED DOT-CASE

: FIX-READ-ONLY ( -- )
   s" orphan/x.md" s" X" s" open" 2 PUT-ISSUE
   s" ." RO-MODE MODE
   s" fix" RUN
   s" ." RW-MODE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/orphan
f .dots/orphan/x.md
  ---
  title: X
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" fix-read-only" ' FIX-READ-ONLY DOT-CASE

;package
;using

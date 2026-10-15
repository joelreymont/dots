\ case-status.f - closing and reopening: where a task moves, the metadata it
\ gains and loses, the reason flag, the descendants that refuse a close, and
\ the failures that leave every byte where it was. Each case is one `dot`
\ command on its own store, or a short sequence where the behaviour is one.
require dot.f
using DOT-T
package DOT-STATUS

$16D constant READ-ONLY                 \ r-xr-xr-x
$1ED constant WRITABLE                  \ rwxr-xr-x
$180 constant OWNER-ONLY                \ rw-------
$1A4 constant SHARED-READ               \ rw-r--r--
create LONG BUF:HDR-BYTES allot         \ a long path, or the tree holding it
LONG 1024 BUF:N>BLEN BUF:INIT

: L+ ( ptr u8 n -- ) BUF:N>BLEN LONG BUF:APPEND-SPAN ;
: L$ ( -- ptr u8 n ) LONG BUF:SPAN$ BUF:BLEN>N ;
: L-BYTES ( n n -- ) {: c:n k:n :} k 0 ?do c LONG BUF:APPEND-BYTE loop ;
\ Append `<255 x's>/<255 y's>`, a folder 511 bytes below its root.
: DEEP+ ( -- ) [char] x NAME-MAX L-BYTES s" /" L+ [char] y NAME-MAX L-BYTES ;

s" status" SECTION

: OFF-ARCHIVES ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" off|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" off-archives" ' OFF-ARCHIVES DOT-CASE

\ Without an archive off creates it to hold the closed task.
: OFF-NO-ARCHIVE ( -- )
   s" archive" RM-DIR
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" off|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" off-no-archive" ' OFF-NO-ARCHIVE DOT-CASE

: CLOSE-REASON ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" close|a|--reason|finished" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: finished
  ---
.
" TREE=
;
s" close-reason" ' CLOSE-REASON DOT-CASE

: UPDATE-STATUS-CLOSED ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" update|a|--status|closed" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" update-status-closed" ' UPDATE-STATUS-CLOSED DOT-CASE

: REOPEN-CLEARS-CLOSED ( -- )
   s" archive/a.md" s" ---
title: A
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-04T00:00:00Z
close-reason: Old fix
---
" PUT
   s" on|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" reopen-clears-closed" ' REOPEN-CLEARS-CLOSED DOT-CASE

: REOPEN-FOLDER ( -- )
   s" archive/p/p.md" s" ---
title: Parent
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-04T00:00:00Z
close-reason: Old fix
---
" PUT
   s" archive/p/c.md" s" Child" s" closed" 2 PUT-ISSUE
   s" on|p" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/p
f .dots/p/c.md
  ---
  title: Child
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/p.md
  ---
  title: Parent
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" reopen-folder" ' REOPEN-FOLDER DOT-CASE

\ A task more than 512 bytes below `.dots/archive` reopens with its folder:
\ only the OS path limit applies.
: ON-LONG-ARCHIVED ( -- )
   LONG BUF:CLEAR s" archive/" L+ DEEP+ s" /deep.md" L+
   L$ s" Deep" s" closed" 2 PUT-ISSUE
   s" on|deep" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   LONG BUF:CLEAR
   s\" d .dots\nd .dots/archive\nd .dots/archive/" L+ [char] x NAME-MAX L-BYTES
   s\" \nd .dots/" L+ [char] x NAME-MAX L-BYTES s\" \nd .dots/" L+ DEEP+
   s\" \nf .dots/" L+ DEEP+
   s\" /deep.md\n  ---\n  title: Deep\n  status: active\n  priority: 2\n  issue-type: task\n  created-at: \"2026-01-01T00:00:00Z\"\n  ---\n.\n" L+
   L$ TREE=
;
s" on-long-archived" ' ON-LONG-ARCHIVED DOT-CASE

: OFF-SHARES-TIME ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" off|a|b" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/b.md
  ---
  title: B
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
   s" archive/a.md" s" archive/b.md" s" closed-at:" SAME-LINE
;
s" off-shares-time" ' OFF-SHARES-TIME DOT-CASE

: CLOSE-MANY ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" close|a|b" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/b.md
  ---
  title: B
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
   s" archive/a.md" s" archive/b.md" s" closed-at:" SAME-LINE
;
s" close-many" ' CLOSE-MANY DOT-CASE

: OFF-REASON-FLAG-VALUE ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" off|a|-r|-r|b" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: -r
  ---
.
f .dots/archive/b.md
  ---
  title: B
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: -r
  ---
.
" TREE=
;
s" off-reason-flag-value" ' OFF-REASON-FLAG-VALUE DOT-CASE

\ close takes off's arguments: after the reason flag's value, wow is an id.
: CLOSE-REASON-FLAG-VALUE ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" close|a|--reason|--reason|wow" RUN
   1 RC=
   s" " OUT=
   s\" Issue not found: wow\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: --reason
  ---
.
" TREE=
;
s" close-reason-flag-value" ' CLOSE-REASON-FLAG-VALUE DOT-CASE

: OFF-REASON-WITHOUT-ID ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" off|-r|missing" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot off <id> [id2 ...] [-r reason]\n" ERR=
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
s" off-reason-without-id" ' OFF-REASON-WITHOUT-ID DOT-CASE

: OFF-EMPTY-REASON ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" off|a|-r|" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: \"\"
  ---
.
" TREE=
;
s" off-empty-reason" ' OFF-EMPTY-REASON DOT-CASE

\ Closing a closed task changes nothing: not its time, reason or bytes.
: CLOSE-ARCHIVED-EMPTY-REASON ( -- )
   s" archive/a.md" s" ---
title: A
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-04T00:00:00Z
close-reason: Old fix
---
" PUT
   s" close|a|--reason|" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  closed-at: 2026-02-04T00:00:00Z
  close-reason: Old fix
  ---
.
" TREE=
;
s" close-archived-empty-reason" ' CLOSE-ARCHIVED-EMPTY-REASON DOT-CASE

: OFF-MALFORMED-CHILD ( -- )
   s" p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" p/bad.md" s\" not frontmatter\n" PUT
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/bad.md
  not frontmatter
.
f .dots/p/p.md
  ---
  title: Parent
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-malformed-child" ' OFF-MALFORMED-CHILD DOT-CASE

: OFF-MALFORMED-DESCENDANT ( -- )
   s" c/c.md" s" Container" s" open" 2 PUT-ISSUE
   s" c/p/leaf.md" s\" not frontmatter\n" PUT
   s" off|c" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s" d .dots
d .dots/archive
d .dots/c
f .dots/c/c.md
  ---
  title: Container
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/c/p
f .dots/c/p/leaf.md
  not frontmatter
.
" TREE=
;
s" off-malformed-descendant" ' OFF-MALFORMED-DESCENDANT DOT-CASE

\ c's folder holds an open child, so no command closes c.
: PUT-OPEN-CHILD ( -- )
   s" c/c.md" s" C" s" open" 2 PUT-ISSUE
   s" c/x.md" s" X" s" open" 2 PUT-ISSUE ;

\ c and its open child, untouched by the refused close.
: OPEN-CHILD-TREE ( -- )
   s" d .dots
d .dots/archive
d .dots/c
f .dots/c/c.md
  ---
  title: C
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/c/x.md
  ---
  title: X
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE= ;

: CLOSE-OPEN-CHILD ( -- )
   PUT-OPEN-CHILD
   s" close|c" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close c: children are not all closed\n" ERR=
   OPEN-CHILD-TREE
;
s" close-open-child" ' CLOSE-OPEN-CHILD DOT-CASE

: UPDATE-CLOSED-OPEN-CHILD ( -- )
   PUT-OPEN-CHILD
   s" update|c|--status|closed" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close c: children are not all closed\n" ERR=
   OPEN-CHILD-TREE
;
s" update-closed-open-child" ' UPDATE-CLOSED-OPEN-CHILD DOT-CASE

: OFF-ARCHIVED-OPEN-DESCENDANT ( -- )
   s" archive/p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" archive/p/deep/leaf.md" s" Leaf" s" open" 2 PUT-ISSUE
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close p: children are not all closed\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
d .dots/archive/p/deep
f .dots/archive/p/deep/leaf.md
  ---
  title: Leaf
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/p.md
  ---
  title: Parent
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-archived-open-descendant" ' OFF-ARCHIVED-OPEN-DESCENDANT DOT-CASE

: OFF-ARCHIVED-INVALID-STATUS ( -- )
   s" archive/p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" archive/p/deep/leaf.md" s" Leaf" s" unknown" 2 PUT-ISSUE
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue status\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
d .dots/archive/p/deep
f .dots/archive/p/deep/leaf.md
  ---
  title: Leaf
  status: unknown
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/p.md
  ---
  title: Parent
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-archived-invalid-status" ' OFF-ARCHIVED-INVALID-STATUS DOT-CASE

\ An archived task's descendants include everything under the active
\ `.dots/p/` at any depth: an open one refuses the close, a closed one does not
\ move when p closes in the archive.
: OFF-ARCHIVED-ACTIVE-FOLDER ( -- )
   s" archive/p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" archive/p/deep/leaf.md" s" Leaf" s" closed" 2 PUT-ISSUE
   s" p/deep/other.md" s" Other" s" open" 2 PUT-ISSUE
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close p: children are not all closed\n" ERR=
   s" p/deep/other.md" s" Other" s" closed" 2 PUT-ISSUE
   s" off|p" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p
d .dots/archive/p/deep
f .dots/archive/p/deep/leaf.md
  ---
  title: Leaf
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/p.md
  ---
  title: Parent
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
d .dots/p
d .dots/p/deep
f .dots/p/deep/other.md
  ---
  title: Other
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-archived-active-folder" ' OFF-ARCHIVED-ACTIVE-FOLDER DOT-CASE

\ Neither a malformed sibling nor a folder named `a` elsewhere is a's.
: OFF-IGNORES-UNRELATED ( -- )
   s" a/a.md" s" A" s" open" 2 PUT-ISSUE
   s" b.md" s\" not frontmatter\n" PUT
   s" other/a/old.md" s" Old" s" open" 2 PUT-ISSUE
   s" archive/other/a/old.md" s" Old" s" open" 2 PUT-ISSUE
   s" off|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/a
f .dots/archive/a/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
d .dots/archive/other
d .dots/archive/other/a
f .dots/archive/other/a/old.md
  ---
  title: Old
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/b.md
  not frontmatter
.
d .dots/other
d .dots/other/a
f .dots/other/a/old.md
  ---
  title: Old
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-ignores-unrelated" ' OFF-IGNORES-UNRELATED DOT-CASE

: OFF-ARCHIVED-IGNORES-UNRELATED ( -- )
   s" archive/a.md" s" A" s" active" 2 PUT-ISSUE
   s" archive/b.md" s\" not frontmatter\n" PUT
   s" archive/other/deep.md" s" Deep" s" open" 2 PUT-ISSUE
   s" off|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/b.md
  not frontmatter
.
d .dots/archive/other
f .dots/archive/other/deep.md
  ---
  title: Deep
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-archived-ignores-unrelated" ' OFF-ARCHIVED-IGNORES-UNRELATED DOT-CASE

: OFF-LATER-FAILURE ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" archive/b.md/sentinel.txt" s\" untouched\n" PUT
   s" off|a|b" RUN
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
d .dots/archive/b.md
f .dots/archive/b.md/sentinel.txt
  untouched
.
f .dots/b.md
  ---
  title: B
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-later-failure" ' OFF-LATER-FAILURE DOT-CASE

: ON-LATER-FAILURE ( -- )
   s" archive/a.md" s" A" s" closed" 2 PUT-ISSUE
   s" archive/b.md" s" B" s" closed" 2 PUT-ISSUE
   s" b.md/sentinel.txt" s\" untouched\n" PUT
   s" on|a|b" RUN
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
f .dots/archive/b.md
  ---
  title: B
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/b.md
f .dots/b.md/sentinel.txt
  untouched
.
" TREE=
;
s" on-later-failure" ' ON-LATER-FAILURE DOT-CASE

: OFF-ARCHIVE-OCCUPIED ( -- )
   s" p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" p/c.md" s" Child" s" closed" 2 PUT-ISSUE
   s" archive/p/sentinel.txt" s\" untouched\n" PUT
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/sentinel.txt
  untouched
.
d .dots/p
f .dots/p/c.md
  ---
  title: Child
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/p.md
  ---
  title: Parent
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-archive-occupied" ' OFF-ARCHIVE-OCCUPIED DOT-CASE

: OFF-ARCHIVE-SYMLINK ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" ../external/sentinel.txt" s\" untouched\n" PUT
   s" archive" RM-DIR
   s" ../external" s" archive" LINK
   s" off|a" RUN
   1 RC=
   s" " OUT=
   s\" Unsafe archive symlink\n" ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
l .dots/archive -> ../external
" TREE=
   s" external" s" d external
f external/sentinel.txt
  untouched
.
" DIR=
;
s" off-archive-symlink" ' OFF-ARCHIVE-SYMLINK DOT-CASE

: ON-ARCHIVE-SYMLINK ( -- )
   s" ../external/a.md" s" A" s" closed" 2 PUT-ISSUE
   s" archive" RM-DIR
   s" ../external" s" archive" LINK
   s" on|a" RUN
   1 RC=
   s" " OUT=
   s\" Unsafe archive symlink\n" ERR=
   s" d .dots
l .dots/archive -> ../external
" TREE=
   s" external" s" d external
f external/a.md
  ---
  title: A
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" DIR=
;
s" on-archive-symlink" ' ON-ARCHIVE-SYMLINK DOT-CASE

: ON-ACTIVE-SYMLINK ( -- )
   s" archive/c/p/p.md" s" Parent" s" closed" 2 PUT-ISSUE
   s" ../external/sentinel.txt" s\" untouched\n" PUT
   s" ../external" s" c" LINK
   s" on|p" RUN
   1 RC=
   s" " OUT=
   s\" Unsafe active symlink\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/c
d .dots/archive/c/p
f .dots/archive/c/p/p.md
  ---
  title: Parent
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
l .dots/c -> ../external
" TREE=
   s" external" s" d external
f external/sentinel.txt
  untouched
.
" DIR=
;
s" on-active-symlink" ' ON-ACTIVE-SYMLINK DOT-CASE

: OFF-READ-ONLY-FOLDER ( -- )
   s" p/p.md" s" Parent" s" open" 2 PUT-ISSUE
   s" p" READ-ONLY MODE
   s" off|p" RUN
   s" p" WRITABLE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/p.md
  ---
  title: Parent
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" off-read-only-folder" ' OFF-READ-ONLY-FOLDER DOT-CASE

: ON-READ-ONLY-FOLDER ( -- )
   s" archive/p/p.md" s" Parent" s" closed" 2 PUT-ISSUE
   s" archive/p" READ-ONLY MODE
   s" on|p" RUN
   s" archive/p" WRITABLE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/p.md
  ---
  title: Parent
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" on-read-only-folder" ' ON-READ-ONLY-FOLDER DOT-CASE

\ Reopening p under the folder c, which is no task, makes `.dots/c`; the
\ failed move removes it again.
: ON-NESTED-READ-ONLY ( -- )
   s" archive/c/p/p.md" s" Parent" s" closed" 2 PUT-ISSUE
   s" archive/c/p" READ-ONLY MODE
   s" on|p" RUN
   s" archive/c/p" WRITABLE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/c
d .dots/archive/c/p
f .dots/archive/c/p/p.md
  ---
  title: Parent
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" on-nested-read-only" ' ON-NESTED-READ-ONLY DOT-CASE

\ Reopening l reopens its closed ancestors c and g too; c's folder refuses the
\ write, so g and l stay closed as well.
: ON-ANCESTORS-READ-ONLY ( -- )
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c/c.md" s" C" s" closed" 2 PUT-ISSUE
   s" p/c/g/g.md" s" G" s" closed" 2 PUT-ISSUE
   s" p/c/g/l.md" s" L" s" closed" 2 PUT-ISSUE
   s" p/c" READ-ONLY MODE
   s" on|l" RUN
   s" p/c" WRITABLE MODE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/p
d .dots/p/c
f .dots/p/c/c.md
  ---
  title: C
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/p/c/g
f .dots/p/c/g/g.md
  ---
  title: G
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/c/g/l.md
  ---
  title: L
  status: closed
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
s" on-ancestors-read-only" ' ON-ANCESTORS-READ-ONLY DOT-CASE

\ Reopening l reaches its owner p, whose malformed file refuses the change.
: ON-MALFORMED-OWNER ( -- )
   s" p/p.md" s\" not frontmatter\n" PUT
   s" p/l.md" s" L" s" closed" 2 PUT-ISSUE
   s" on|l" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/l.md
  ---
  title: L
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/p.md
  not frontmatter
.
" TREE=
;
s" on-malformed-owner" ' ON-MALFORMED-OWNER DOT-CASE

\ The folder moves before p.md is rewritten; the failed write moves it back
\ and removes the `.dots/c` it made.
: ON-WRITE-FAILURE ( -- )
   s" archive/c/p/p.md" s" Parent" s" closed" 2 PUT-ISSUE
   s" archive/c/p/k.md" s" Child" s" closed" 2 PUT-ISSUE
   s" on|p" RUN-LIMITED
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/c
d .dots/archive/c/p
f .dots/archive/c/p/k.md
  ---
  title: Child
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/c/p/p.md
  ---
  title: Parent
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" on-write-failure" ' ON-WRITE-FAILURE DOT-CASE

\ The rewritten file takes the mode of a new file, not the old file's.
: OFF-REWRITE-MODE ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" a.md" OWNER-ONLY MODE
   s" off|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" archive/a.md" SHARED-READ MODE=
;
s" off-rewrite-mode" ' OFF-REWRITE-MODE DOT-CASE

\ Open a holding child, closed on 2026-02-04.
: PUT-CLOSED-CHILD ( -- )
   s" a/a.md" s" A" s" open" 2 PUT-ISSUE
   s" a/child.md" s" ---
title: Child
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-04T00:00:00Z
---
" PUT ;

\ The tree both orders leave: a closed with its folder, the child untouched.
: CLOSED-FAMILY-TREE ( -- )
   s\" d .dots
d .dots/archive
d .dots/archive/a
f .dots/archive/a/a.md
  ---
  title: A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/a/child.md
  ---
  title: Child
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  closed-at: 2026-02-04T00:00:00Z
  ---
.
" TREE= ;

\ Closing a moves its folder into the archive; closing its child after that
\ finds it there, already closed, and changes nothing.
: OFF-PARENT-THEN-CHILD ( -- )
   PUT-CLOSED-CHILD
   s" off|a|child" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   CLOSED-FAMILY-TREE
;
s" off-parent-then-child" ' OFF-PARENT-THEN-CHILD DOT-CASE

\ The child, already closed, stays as it is in a's folder, which then moves
\ whole.
: OFF-CHILD-THEN-PARENT ( -- )
   PUT-CLOSED-CHILD
   s" off|child|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   CLOSED-FAMILY-TREE
;
s" off-child-then-parent" ' OFF-CHILD-THEN-PARENT DOT-CASE

;package
;using

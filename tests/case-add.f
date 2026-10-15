\ case-add.f - add: the id it prints from the prefix and the title's slug, the
\ fields and options it writes, where a child goes, and the adds it refuses.
\ Each case is one `dot add` on its own store, parent-folder then reading it
\ with `tree`; a refused add's store holds a config with a prefix, so the
\ refusal alone decides its tree.
require dot.f
using DOT-T
package DOT-ADD

: PREFIX-X ( -- ) s" config" s\" prefix=x\n" PUT ;

s" add" SECTION

: CONFIG-PREFIX ( -- )
   s" config" s\" prefix=proj\n" PUT
   s" add|Design API|-p|1|-d|REST endpoints" RUN
   s" A" SAVE-ID
   s" A" s" proj-design-api-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=proj
.
f .dots/<A>.md
  ---
  title: Design API
  status: open
  priority: 1
  issue-type: task
  created-at: \"<time>\"
  ---
  
  REST endpoints
.
" TREE=
;
s" config-prefix" ' CONFIG-PREFIX DOT-CASE

\ Without a config the prefix is the working directory's name, the store's,
\ less its trailing dashes.
: CWD-PREFIX ( -- )
   s" add|Plain task" RUN
   s" A" SAVE-ID
   s" A" s" cwd-prefix-plain-task-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=cwd-prefix
.
f .dots/<A>.md
  ---
  title: Plain task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" cwd-prefix--" ' CWD-PREFIX DOT-CASE

\ A working directory named only with dashes leaves no prefix: dot stands in.
: PREFIX-FALLBACK ( -- )
   s" add|Plain task" RUN
   s" A" SAVE-ID
   s" A" s" dot-plain-task-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=dot
.
f .dots/<A>.md
  ---
  title: Plain task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" ---" ' PREFIX-FALLBACK DOT-CASE

: SLUG-ABBREVIATION ( -- )
   PREFIX-X
   s" add|Database migration" RUN
   s" A" SAVE-ID
   s" A" s" x-db-migration-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: Database migration
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-abbreviation" ' SLUG-ABBREVIATION DOT-CASE

: SLUG-THREE-WORDS ( -- )
   PREFIX-X
   s" add|one two three four" RUN
   s" A" SAVE-ID
   s" A" s" x-one-two-three-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: one two three four
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-three-words" ' SLUG-THREE-WORDS DOT-CASE

\ A slug past 30 bytes ends at the last whole word within them.
: SLUG-BYTE-CUT ( -- )
   PREFIX-X
   s" add|Internationalization localization globalization" RUN
   s" A" SAVE-ID
   s" A" s" x-internationalization-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: Internationalization localization globalization
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-byte-cut" ' SLUG-BYTE-CUT DOT-CASE

: SLUG-UNTITLED ( -- )
   PREFIX-X
   s" add|(!)" RUN
   s" A" SAVE-ID
   s" A" s" x-untitled-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: (!)
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-untitled" ' SLUG-UNTITLED DOT-CASE

\ A first word longer than 30 bytes has no word boundary to cut at.
: SLUG-LONG-WORD ( -- )
   PREFIX-X
   s" add|Supercalifragilisticexpialidocious" RUN
   s" A" SAVE-ID
   s" A" s" x-untitled-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: Supercalifragilisticexpialidocious
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-long-word" ' SLUG-LONG-WORD DOT-CASE

: PRIORITY-HIGH ( -- )
   PREFIX-X
   s" add|T|-p|99" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 9
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" priority-high" ' PRIORITY-HIGH DOT-CASE

: PRIORITY-LOW ( -- )
   PREFIX-X
   s" add|T|-p|-100" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 0
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" priority-low" ' PRIORITY-LOW DOT-CASE

: PRIORITY-PLUS ( -- )
   PREFIX-X
   s" add|T|-p|+4" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 4
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" priority-plus" ' PRIORITY-PLUS DOT-CASE

: PRIORITY-INVALID ( -- )
   s" add|-p|bogus|Title" RUN
   1 RC=
   s" " OUT=
   s\" Invalid priority: bogus\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" priority-invalid" ' PRIORITY-INVALID DOT-CASE

: EMPTY-DESCRIPTION ( -- )
   PREFIX-X
   s" add|T|-d|" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" empty-description" ' EMPTY-DESCRIPTION DOT-CASE

: JSON-OUTPUT ( -- )
   PREFIX-X
   s" add|Design API|-p|1|-d|REST endpoints|--json" RUN
   s" A" SAVE-ID
   0 RC=
   s\" {\"id\":\"<A>\",\"title\":\"Design API\",\"description\":\"REST endpoints\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"<time>\",\"closed_at\":null,\"close_reason\":null}\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: Design API
  status: open
  priority: 1
  issue-type: task
  created-at: \"<time>\"
  ---
  
  REST endpoints
.
" TREE=
;
s" json-output" ' JSON-OUTPUT DOT-CASE

\ The parent gets its own folder, which then holds the child; tree shows it.
: PARENT-FOLDER ( -- )
   PREFIX-X
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" add|Kid|-P|p" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s" tree" RUN
   0 RC=
   s\" [p] ○ P\n  └─ [<A>] ○ Kid\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/p
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/<A>.md
  ---
  title: Kid
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" parent-folder" ' PARENT-FOLDER DOT-CASE

\ A nested parent's own folder is made where its file lives, in its parent's.
: NESTED-PARENT ( -- )
   PREFIX-X
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c.md" s" C" s" open" 2 PUT-ISSUE
   s" add|Kid|-P|c" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
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
f .dots/p/c/<A>.md
  ---
  title: Kid
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
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
s" nested-parent" ' NESTED-PARENT DOT-CASE

: AFTER-BLOCKS ( -- )
   PREFIX-X
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" add|T|-a|b" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/b.md
  ---
  title: B
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  blocks:
    - b
  ---
.
" TREE=
;
s" after-blocks" ' AFTER-BLOCKS DOT-CASE

\ `archive` names the archive partition, never a task.
: PARENT-ARCHIVE-ID ( -- )
   PREFIX-X
   s" archive.md" s" Archive" s" open" 2 PUT-ISSUE
   s" add|Kid|-P|archive" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue id\n" ERR=
   s" d .dots
d .dots/archive
f .dots/archive.md
  ---
  title: Archive
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
" TREE=
;
s" parent-archive-id" ' PARENT-ARCHIVE-ID DOT-CASE

: PARENT-ABSENT ( -- )
   PREFIX-X
   s" add|T|-P|absent" RUN
   1 RC=
   s" " OUT=
   s\" Parent issue not found: absent\n" ERR=
   s" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
" TREE=
;
s" parent-absent" ' PARENT-ABSENT DOT-CASE

: AFTER-ABSENT ( -- )
   PREFIX-X
   s" add|T|-a|absent" RUN
   1 RC=
   s" " OUT=
   s\" After issue not found: absent\n" ERR=
   s" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
" TREE=
;
s" after-absent" ' AFTER-ABSENT DOT-CASE

: PARENT-IS-AFTER ( -- )
   s" add|T|-P|same|-a|same" RUN
   1 RC=
   s" " OUT=
   s\" Error: parent and after cannot be the same issue\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" parent-is-after" ' PARENT-IS-AFTER DOT-CASE

: ARCHIVED-PARENT ( -- )
   PREFIX-X
   s" archive/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" add|Kid|-P|p" RUN
   1 RC=
   s" " OUT=
   s\" Parent issue is archived: p\n" ERR=
   s" d .dots
d .dots/archive
f .dots/archive/p.md
  ---
  title: P
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
" TREE=
;
s" archived-parent" ' ARCHIVED-PARENT DOT-CASE

\ A config without a prefix gains one; its other keys stay, a repeated key
\ once, with its last value.
: CONFIG-KEYS ( -- )
   s" config" s\" mode=a\nmode=b\nother=c\n" PUT
   s" add|T" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  mode=b
  other=c
  prefix=config-keys
.
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" config-keys" ' CONFIG-KEYS DOT-CASE

\ A 400-byte title of 200 two-byte characters is kept whole.
: UTF8-TITLE ( -- )
   PREFIX-X
   s" add|éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
f .dots/<A>.md
  ---
  title: éééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééééé
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" utf8-title" ' UTF8-TITLE DOT-CASE

\ ---- id collisions ----------------------------------------------------------

\ RUN-PINNED pins add's random suffix, so the new id, x-task-5eed1d00, is known
\ before the run, and add refuses it where it is taken. The id is taken at the
\ top and in the archive, file or folder, and in active folders other than any
\ named archive, ten levels down, never through a symlink. An empty folder of
\ the id's name takes the new task. Each store holds task a beside the
\ placements.
: PINNED-STORE ( -- )
   PREFIX-X
   s" a.md" s" A" s" open" 2 PUT-ISSUE ;

: PINNED-TAKEN-TOP ( -- )
   PINNED-STORE
   s" x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
f .dots/config
  prefix=x
.
f .dots/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-taken-top" ' PINNED-TAKEN-TOP DOT-CASE

: PINNED-TAKEN-FOLDER ( -- )
   PINNED-STORE
   s" x-task-5eed1d00/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
f .dots/config
  prefix=x
.
d .dots/x-task-5eed1d00
f .dots/x-task-5eed1d00/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-taken-folder" ' PINNED-TAKEN-FOLDER DOT-CASE

: PINNED-TAKEN-ARCHIVE ( -- )
   PINNED-STORE
   s" archive/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
f .dots/archive/x-task-5eed1d00.md
  ---
  title: Taken
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
" TREE=
;
s" pinned-taken-archive" ' PINNED-TAKEN-ARCHIVE DOT-CASE

: PINNED-TAKEN-ARCHIVE-FOLDER ( -- )
   PINNED-STORE
   s" archive/x-task-5eed1d00/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
d .dots/archive/x-task-5eed1d00
f .dots/archive/x-task-5eed1d00/x-task-5eed1d00.md
  ---
  title: Taken
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
" TREE=
;
s" pinned-taken-archive-folder" ' PINNED-TAKEN-ARCHIVE-FOLDER DOT-CASE

: PINNED-TAKEN-ACTIVE-CHILD ( -- )
   PINNED-STORE
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
f .dots/config
  prefix=x
.
d .dots/p
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-taken-active-child" ' PINNED-TAKEN-ACTIVE-CHILD DOT-CASE

: PINNED-TAKEN-DEPTH-10 ( -- )
   PINNED-STORE
   s" d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
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
f .dots/config
  prefix=x
.
d .dots/d1
d .dots/d1/d2
d .dots/d1/d2/d3
d .dots/d1/d2/d3/d4
d .dots/d1/d2/d3/d4/d5
d .dots/d1/d2/d3/d4/d5/d6
d .dots/d1/d2/d3/d4/d5/d6/d7
d .dots/d1/d2/d3/d4/d5/d6/d7/d8
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10
f .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-taken-depth-10" ' PINNED-TAKEN-DEPTH-10 DOT-CASE

: PINNED-FREE-ARCHIVED-CHILD ( -- )
   PINNED-STORE
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
d .dots/archive/p
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/x-task-5eed1d00.md
  ---
  title: Taken
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
f .dots/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" pinned-free-archived-child" ' PINNED-FREE-ARCHIVED-CHILD DOT-CASE

: PINNED-FREE-ARCHIVED-CHILD-CHILD ( -- )
   PINNED-STORE
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
   s" add|Task|-P|a" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/a
f .dots/a/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/a/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
d .dots/archive/p
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/x-task-5eed1d00.md
  ---
  title: Taken
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=x
.
" TREE=
;
s" pinned-free-archived-child-child" ' PINNED-FREE-ARCHIVED-CHILD-CHILD DOT-CASE

: PINNED-FREE-NESTED-ARCHIVE ( -- )
   PINNED-STORE
   s" x/archive/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/x
d .dots/x/archive
f .dots/x/archive/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" pinned-free-nested-archive" ' PINNED-FREE-NESTED-ARCHIVE DOT-CASE

: PINNED-FREE-NESTED-ARCHIVE-CHILD ( -- )
   PINNED-STORE
   s" x/archive/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task|-P|a" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/a
f .dots/a/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/a/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/x
d .dots/x/archive
f .dots/x/archive/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-free-nested-archive-child" ' PINNED-FREE-NESTED-ARCHIVE-CHILD DOT-CASE

: PINNED-FREE-SYMLINKED-DIR ( -- )
   PINNED-STORE
   s" ../outside/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" ../outside" s" linked" LINK
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
l .dots/linked -> ../outside
f .dots/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" pinned-free-symlinked-dir" ' PINNED-FREE-SYMLINKED-DIR DOT-CASE

: PINNED-FREE-SYMLINKED-DIR-CHILD ( -- )
   PINNED-STORE
   s" ../outside/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" ../outside" s" linked" LINK
   s" add|Task|-P|a" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/a
f .dots/a/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/a/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
l .dots/linked -> ../outside
" TREE=
;
s" pinned-free-symlinked-dir-child" ' PINNED-FREE-SYMLINKED-DIR-CHILD DOT-CASE

: PINNED-FREE-DEPTH-11 ( -- )
   PINNED-STORE
   s" d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/d1
d .dots/d1/d2
d .dots/d1/d2/d3
d .dots/d1/d2/d3/d4
d .dots/d1/d2/d3/d4/d5
d .dots/d1/d2/d3/d4/d5/d6
d .dots/d1/d2/d3/d4/d5/d6/d7
d .dots/d1/d2/d3/d4/d5/d6/d7/d8
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11
f .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" pinned-free-depth-11" ' PINNED-FREE-DEPTH-11 DOT-CASE

: PINNED-FREE-DEPTH-11-CHILD ( -- )
   PINNED-STORE
   s" d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task|-P|a" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/a
f .dots/a/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/a/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/d1
d .dots/d1/d2
d .dots/d1/d2/d3
d .dots/d1/d2/d3/d4
d .dots/d1/d2/d3/d4/d5
d .dots/d1/d2/d3/d4/d5/d6
d .dots/d1/d2/d3/d4/d5/d6/d7
d .dots/d1/d2/d3/d4/d5/d6/d7/d8
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10
d .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11
f .dots/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/x-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-free-depth-11-child" ' PINNED-FREE-DEPTH-11-CHILD DOT-CASE

: PINNED-FREE-EMPTY-FOLDER ( -- )
   PINNED-STORE
   s" .dots/x-task-5eed1d00" FILE$ MAKE-DIRS
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/x-task-5eed1d00
f .dots/x-task-5eed1d00/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" pinned-free-empty-folder" ' PINNED-FREE-EMPTY-FOLDER DOT-CASE

: PINNED-FREE-EMPTY-FOLDER-CHILD ( -- )
   PINNED-STORE
   s" .dots/x-task-5eed1d00" FILE$ MAKE-DIRS
   s" add|Task|-P|a" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/a
f .dots/a/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/a/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/x-task-5eed1d00
" TREE=
;
s" pinned-free-empty-folder-child" ' PINNED-FREE-EMPTY-FOLDER-CHILD DOT-CASE

;package
;using

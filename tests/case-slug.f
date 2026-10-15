\ case-slug.f - slugify: every task takes the id `<prefix>-<title slug>-<hex>`
\ wherever it lives, its folders follow it, every blocks reference is
\ rewritten, and an occupied destination, an unsafe archive or a failed write
\ leaves the store as it was. Each store's config fixes the prefix `p`.
require dot.f
using DOT-T
package DOT-SLUG

$16D constant READ-ONLY-DIR             \ r-xr-xr-x

: PUT-PREFIX ( -- ) s" config" s\" prefix=p\n" PUT ;

\ An old id `old-12345678` titled Target, whose new id the case occupies.
: PUT-TARGET ( -- )
   PUT-PREFIX
   s" old-12345678.md" s" Target" s" open" 2 PUT-ISSUE ;

s" slug" SECTION

: FOLDERS-AND-BLOCKERS ( -- )
   PUT-PREFIX
   s" active-aaaabbbb.md" s" ---
title: Active task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - archived-child-eeeeffff
---
" PUT
   s" parent-bbbbcccc/parent-bbbbcccc.md" s" ---
title: Parent task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - active-aaaabbbb
---
" PUT
   s" parent-bbbbcccc/child-ccccdddd.md" s" ---
title: Child task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - parent-bbbbcccc
---
" PUT
   s" archive/archived-ddddeeee/archived-ddddeeee.md" s" ---
title: Archived parent
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - child-ccccdddd
---
" PUT
   s" archive/archived-ddddeeee/archived-child-eeeeffff.md" s" ---
title: Archived child
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - active-aaaabbbb
  - parent-bbbbcccc
---
" PUT
   s" archive/archived-simple-ffff0000.md" s" ---
title: Archived simple
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - archived-ddddeeee
---
" PUT
   s" slugify" RUN
   0 RC=
   s" active-aaaabbbb -> p-active-task-aaaabbbb
parent-bbbbcccc -> p-parent-task-bbbbcccc
child-ccccdddd -> p-child-task-ccccdddd
archived-simple-ffff0000 -> p-archived-simple-ffff0000
archived-child-eeeeffff -> p-archived-child-eeeeffff
archived-ddddeeee -> p-archived-parent-ddddeeee
Slugified 6 issue(s)
" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p-archived-parent-ddddeeee
f .dots/archive/p-archived-parent-ddddeeee/p-archived-child-eeeeffff.md
  ---
  title: Archived child
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-active-task-aaaabbbb
    - p-parent-task-bbbbcccc
  ---
.
f .dots/archive/p-archived-parent-ddddeeee/p-archived-parent-ddddeeee.md
  ---
  title: Archived parent
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-child-task-ccccdddd
  ---
.
f .dots/archive/p-archived-simple-ffff0000.md
  ---
  title: Archived simple
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-archived-parent-ddddeeee
  ---
.
f .dots/config
  prefix=p
.
f .dots/p-active-task-aaaabbbb.md
  ---
  title: Active task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-archived-child-eeeeffff
  ---
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/p-child-task-ccccdddd.md
  ---
  title: Child task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-parent-task-bbbbcccc
  ---
.
f .dots/p-parent-task-bbbbcccc/p-parent-task-bbbbcccc.md
  ---
  title: Parent task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-active-task-aaaabbbb
  ---
.
" TREE=
;
s" folders-and-blockers" ' FOLDERS-AND-BLOCKERS DOT-CASE

: SETTLED-STORE ( -- )
   PUT-PREFIX
   s" p-active-task-aaaabbbb.md" s" Active task" s" open" 2 PUT-ISSUE
   s" p-parent-task-bbbbcccc/p-parent-task-bbbbcccc.md" s" Parent task" s" open" 2 PUT-ISSUE
   s" p-parent-task-bbbbcccc/p-child-task-ccccdddd.md" s" Child task" s" open" 2 PUT-ISSUE
   s" archive/p-archived-simple-ffff0000.md" s" Archived simple" s" closed" 2 PUT-ISSUE
   s" slugify" RUN
   0 RC=
   s\" Slugified 0 issue(s)\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/archive/p-archived-simple-ffff0000.md
  ---
  title: Archived simple
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=p
.
f .dots/p-active-task-aaaabbbb.md
  ---
  title: Active task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/p-child-task-ccccdddd.md
  ---
  title: Child task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p-parent-task-bbbbcccc/p-parent-task-bbbbcccc.md
  ---
  title: Parent task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" settled-store" ' SETTLED-STORE DOT-CASE

\ Two tasks share an id: the dependent keeps a blocker for each new id, so it
\ stays blocked until both are closed.
: DUPLICATE-IDS ( -- )
   PUT-PREFIX
   s" same-12345678.md" s" First target" s" open" 2 PUT-ISSUE
   s" nested/same-12345678.md" s" Second target" s" open" 2 PUT-ISSUE
   s" dependent-22222222.md" s" ---
title: Dependent
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - same-12345678
---
" PUT
   s" slugify" RUN
   0 RC=
   s" dependent-22222222 -> p-dependent-22222222
same-12345678 -> p-first-target-12345678
same-12345678 -> p-second-target-12345678
Slugified 3 issue(s)
" OUT=
   s" " ERR=
   s" off|p-first-target-12345678" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" ready" RUN
   0 RC=
   s\" [p-second-target-12345678] o Second target\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p-first-target-12345678.md
  ---
  title: First target
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/config
  prefix=p
.
d .dots/nested
f .dots/nested/p-second-target-12345678.md
  ---
  title: Second target
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p-dependent-22222222.md
  ---
  title: Dependent
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-second-target-12345678
    - p-first-target-12345678
  ---
.
" TREE=
;
s" duplicate-ids" ' DUPLICATE-IDS DOT-CASE

: DUPLICATE-ID-ARCHIVED ( -- )
   PUT-PREFIX
   s" same-12345678.md" s" Active target" s" open" 2 PUT-ISSUE
   s" archive/same-12345678.md" s" Archived target" s" closed" 2 PUT-ISSUE
   s" dependent-22222222.md" s" ---
title: Dependent
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - same-12345678
---
" PUT
   s" slugify" RUN
   0 RC=
   s" dependent-22222222 -> p-dependent-22222222
same-12345678 -> p-active-target-12345678
same-12345678 -> p-archived-target-12345678
Slugified 3 issue(s)
" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p-archived-target-12345678.md
  ---
  title: Archived target
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/config
  prefix=p
.
f .dots/p-active-target-12345678.md
  ---
  title: Active target
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p-dependent-22222222.md
  ---
  title: Dependent
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-archived-target-12345678
    - p-active-target-12345678
  ---
.
" TREE=
;
s" duplicate-id-archived" ' DUPLICATE-ID-ARCHIVED DOT-CASE

: SKIPPED-TARGET ( -- )
   0 RC=
   s\" Slugified 0 issue(s)\n" OUT=
   s\" Skipping old-12345678: new ID p-target-12345678 already exists\n" ERR= ;

: OCCUPIED-FILE ( -- )
   PUT-TARGET
   s" p-target-12345678.md" s\" occupied\n" PUT
   s" slugify" RUN
   SKIPPED-TARGET
   s" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
f .dots/old-12345678.md
  ---
  title: Target
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p-target-12345678.md
  occupied
.
" TREE=
;
s" occupied-file" ' OCCUPIED-FILE DOT-CASE

: OCCUPIED-LINK ( -- )
   PUT-TARGET
   s" outside.txt" s\" outside\n" PUT
   s" outside.txt" s" p-target-12345678.md" LINK
   s" slugify" RUN
   SKIPPED-TARGET
   s" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
f .dots/old-12345678.md
  ---
  title: Target
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/outside.txt
  outside
.
l .dots/p-target-12345678.md -> outside.txt
" TREE=
;
s" occupied-link" ' OCCUPIED-LINK DOT-CASE

: OCCUPIED-DANGLING-LINK ( -- )
   PUT-TARGET
   s" missing.txt" s" p-target-12345678.md" LINK
   s" slugify" RUN
   SKIPPED-TARGET
   s" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
f .dots/old-12345678.md
  ---
  title: Target
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
l .dots/p-target-12345678.md -> missing.txt
" TREE=
;
s" occupied-dangling-link" ' OCCUPIED-DANGLING-LINK DOT-CASE

: OCCUPIED-DIR ( -- )
   PUT-TARGET
   s" p-target-12345678.md/sentinel" s\" occupied\n" PUT
   s" slugify" RUN
   SKIPPED-TARGET
   s" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
f .dots/old-12345678.md
  ---
  title: Target
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/p-target-12345678.md
f .dots/p-target-12345678.md/sentinel
  occupied
.
" TREE=
;
s" occupied-dir" ' OCCUPIED-DIR DOT-CASE

\ The legacy folder `.dots/parent-bbbbcccc/` holds an extra child of the
\ parent wherever the parent lives; it moves with the parent's new id.
: PUT-EXTRA ( -- )
   s" parent-bbbbcccc/extra-ddddeeee.md" s" ---
title: Extra task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - parent-bbbbcccc
---
" PUT ;

: CHILD-FOLDER-ARCHIVED-PARENT ( -- )
   PUT-PREFIX
   s" archive/parent-bbbbcccc/parent-bbbbcccc.md" s" Parent task" s" closed" 2 PUT-ISSUE
   s" archive/parent-bbbbcccc/child-ccccdddd.md" s" Archived child" s" closed" 2 PUT-ISSUE
   PUT-EXTRA
   s" slugify" RUN
   0 RC=
   s" extra-ddddeeee -> p-extra-task-ddddeeee
parent-bbbbcccc -> p-parent-task-bbbbcccc
child-ccccdddd -> p-archived-child-ccccdddd
Slugified 3 issue(s)
" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p-parent-task-bbbbcccc
f .dots/archive/p-parent-task-bbbbcccc/p-archived-child-ccccdddd.md
  ---
  title: Archived child
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/archive/p-parent-task-bbbbcccc/p-parent-task-bbbbcccc.md
  ---
  title: Parent task
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/config
  prefix=p
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/p-extra-task-ddddeeee.md
  ---
  title: Extra task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-parent-task-bbbbcccc
  ---
.
" TREE=
;
s" child-folder-archived-parent" ' CHILD-FOLDER-ARCHIVED-PARENT DOT-CASE

\ The moved folder still holds the parent's child: off refuses the parent.
: CHILD-FOLDER-PLAIN-PARENT ( -- )
   PUT-PREFIX
   s" parent-bbbbcccc.md" s" Parent task" s" open" 2 PUT-ISSUE
   PUT-EXTRA
   s" slugify" RUN
   0 RC=
   s" parent-bbbbcccc -> p-parent-task-bbbbcccc
extra-ddddeeee -> p-extra-task-ddddeeee
Slugified 2 issue(s)
" OUT=
   s" " ERR=
   s" off|p-parent-task-bbbbcccc" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close p-parent-task-bbbbcccc: children are not all closed\n" ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/p-extra-task-ddddeeee.md
  ---
  title: Extra task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-parent-task-bbbbcccc
  ---
.
f .dots/p-parent-task-bbbbcccc.md
  ---
  title: Parent task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" child-folder-plain-parent" ' CHILD-FOLDER-PLAIN-PARENT DOT-CASE

: CHILD-FOLDER-NESTED-PARENT ( -- )
   PUT-PREFIX
   s" group-aaaabbbb/group-aaaabbbb.md" s" Group task" s" open" 2 PUT-ISSUE
   s" group-aaaabbbb/parent-bbbbcccc.md" s" Parent task" s" open" 2 PUT-ISSUE
   PUT-EXTRA
   s" slugify" RUN
   0 RC=
   s" group-aaaabbbb -> p-group-task-aaaabbbb
parent-bbbbcccc -> p-parent-task-bbbbcccc
extra-ddddeeee -> p-extra-task-ddddeeee
Slugified 3 issue(s)
" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
d .dots/p-group-task-aaaabbbb
f .dots/p-group-task-aaaabbbb/p-group-task-aaaabbbb.md
  ---
  title: Group task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p-group-task-aaaabbbb/p-parent-task-bbbbcccc.md
  ---
  title: Parent task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/p-extra-task-ddddeeee.md
  ---
  title: Extra task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - p-parent-task-bbbbcccc
  ---
.
" TREE=
;
s" child-folder-nested-parent" ' CHILD-FOLDER-NESTED-PARENT DOT-CASE

: OCCUPIED-CHILD-FOLDER ( -- )
   PUT-PREFIX
   s" archive/parent-bbbbcccc/parent-bbbbcccc.md" s" Parent task" s" closed" 2 PUT-ISSUE
   s" parent-bbbbcccc/p-extra-task-ddddeeee.md" s" ---
title: Extra task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - parent-bbbbcccc
---
" PUT
   s" p-parent-task-bbbbcccc/sentinel" s\" occupied\n" PUT
   s" slugify" RUN
   0 RC=
   s\" Slugified 0 issue(s)\n" OUT=
   s\" Skipping parent-bbbbcccc: new ID p-parent-task-bbbbcccc already exists\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/parent-bbbbcccc
f .dots/archive/parent-bbbbcccc/parent-bbbbcccc.md
  ---
  title: Parent task
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=p
.
d .dots/p-parent-task-bbbbcccc
f .dots/p-parent-task-bbbbcccc/sentinel
  occupied
.
d .dots/parent-bbbbcccc
f .dots/parent-bbbbcccc/p-extra-task-ddddeeee.md
  ---
  title: Extra task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - parent-bbbbcccc
  ---
.
" TREE=
;
s" occupied-child-folder" ' OCCUPIED-CHILD-FOLDER DOT-CASE

\ `.dots/archive` is the archive, never the folder of a task whose id is
\ archive; the id has no hex suffix, so its new one is random.
: TASK-NAMED-ARCHIVE ( -- )
   PUT-PREFIX
   s" archive.md" s" Archive" s" open" 2 PUT-ISSUE
   s" archive/p-kept-task-11112222.md" s" Kept task" s" closed" 2 PUT-ISSUE
   s" slugify" RUN
   s" archive -> " s" A" SAVE-AFTER
   0 RC=
   s\" archive -> <A>\nSlugified 1 issue(s)\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/p-kept-task-11112222.md
  ---
  title: Kept task
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=p
.
f .dots/<A>.md
  ---
  title: Archive
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" task-named-archive" ' TASK-NAMED-ARCHIVE DOT-CASE

: ARCHIVED-TASK-NAMED-ARCHIVE ( -- )
   PUT-PREFIX
   s" archive/archive.md" s" Archive" s" closed" 2 PUT-ISSUE
   s" archive/p-kept-task-11112222.md" s" Kept task" s" closed" 2 PUT-ISSUE
   s" slugify" RUN
   s" archive -> " s" A" SAVE-AFTER
   0 RC=
   s\" archive -> <A>\nSlugified 1 issue(s)\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/<A>.md
  ---
  title: Archive
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/archive/p-kept-task-11112222.md
  ---
  title: Kept task
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=p
.
" TREE=
;
s" archived-task-named-archive" ' ARCHIVED-TASK-NAMED-ARCHIVE DOT-CASE

\ A symlinked archive is refused before anything is read or written.
: ARCHIVE-SYMLINK ( -- )
   PUT-PREFIX
   s" archive" RM-DIR
   s" elsewhere/old-12345678.md" s" Elsewhere" s" closed" 2 PUT-ISSUE
   s" elsewhere" s" archive" LINK
   s" old-abcdef12.md" s" Local task" s" open" 2 PUT-ISSUE
   s" slugify" RUN
   1 RC=
   s" " OUT=
   s\" Unsafe archive symlink\n" ERR=
   s" d .dots
l .dots/archive -> elsewhere
f .dots/config
  prefix=p
.
d .dots/elsewhere
f .dots/elsewhere/old-12345678.md
  ---
  title: Elsewhere
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/old-abcdef12.md
  ---
  title: Local task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" archive-symlink" ' ARCHIVE-SYMLINK DOT-CASE

\ The target with an archived dependent whose blocks reference it.
: PUT-DEPENDENT ( -- )
   PUT-TARGET
   s" archive/dependent-22222222.md" s" ---
title: Dependent
status: closed
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - old-12345678
---
" PUT ;

\ A failed write left PUT-DEPENDENT's store as it was: no task is renamed, no
\ reference is stranded and no staged or backup file stays behind.
: DEPENDENT-KEPT ( -- )
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
f .dots/archive/dependent-22222222.md
  ---
  title: Dependent
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - old-12345678
  ---
.
f .dots/config
  prefix=p
.
f .dots/old-12345678.md
  ---
  title: Target
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE= ;

\ The archived dependent cannot be rewritten.
: UNWRITABLE-ARCHIVE ( -- )
   PUT-DEPENDENT
   s" archive" READ-ONLY-DIR MODE
   s" slugify" RUN
   s" archive" FS-MUT-MODE-DIR MODE
   DEPENDENT-KEPT
;
s" unwritable-archive" ' UNWRITABLE-ARCHIVE DOT-CASE

\ The target's rename fails mid-commit, once its file has moved to its backup:
\ every renamed and rewritten file is put back.
: COMMIT-RENAME-FAILS ( -- )
   PUT-DEPENDENT
   s" slugify" s" .dots/p-target-12345678.md" s" .dots/old-12345678.md" RUN-PROBE
   DEPENDENT-KEPT
;
s" commit-rename-fails" ' COMMIT-RENAME-FAILS DOT-CASE

\ The parent's own rename fails once both its folders have moved: the folders
\ move back, and the extra task keeps its file and its reference.
: CHILD-FOLDER-RENAME-FAILS ( -- )
   PUT-PREFIX
   s" archive/parent-bbbbcccc/parent-bbbbcccc.md" s" Parent task" s" closed" 2 PUT-ISSUE
   s" archive/parent-bbbbcccc/p-archived-child-ccccdddd.md" s" Archived child" s" closed" 2 PUT-ISSUE
   s" parent-bbbbcccc/p-extra-task-ddddeeee.md" s" ---
title: Extra task
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - parent-bbbbcccc
---
" PUT
   s" slugify"
   s" .dots/archive/p-parent-task-bbbbcccc/p-parent-task-bbbbcccc.md"
   s" .dots/parent-bbbbcccc" RUN-PROBE
   1 RC=
   s" " OUT=
   s\" Permission denied\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/parent-bbbbcccc
f .dots/archive/parent-bbbbcccc/p-archived-child-ccccdddd.md
  ---
  title: Archived child
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/parent-bbbbcccc/parent-bbbbcccc.md
  ---
  title: Parent task
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/config
  prefix=p
.
d .dots/parent-bbbbcccc
f .dots/parent-bbbbcccc/p-extra-task-ddddeeee.md
  ---
  title: Extra task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - parent-bbbbcccc
  ---
.
" TREE=
;
s" child-folder-rename-fails" ' CHILD-FOLDER-RENAME-FAILS DOT-CASE

\ A parent folder below a plain directory below another parent's folder.
: DEEP-NESTING ( -- )
   PUT-PREFIX
   s" a-12345678/a-12345678.md" s" A parent" s" open" 2 PUT-ISSUE
   s" a-12345678/a+a/b-12345678/b-12345678.md" s" B parent" s" open" 2 PUT-ISSUE
   s" a-12345678/a+a/b-12345678/x-12345678.md" s" X leaf" s" open" 2 PUT-ISSUE
   s" slugify" RUN
   0 RC=
   s" b-12345678 -> p-b-parent-12345678
x-12345678 -> p-x-leaf-12345678
a-12345678 -> p-a-parent-12345678
Slugified 3 issue(s)
" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
d .dots/p-a-parent-12345678
d .dots/p-a-parent-12345678/a+a
d .dots/p-a-parent-12345678/a+a/p-b-parent-12345678
f .dots/p-a-parent-12345678/a+a/p-b-parent-12345678/p-b-parent-12345678.md
  ---
  title: B parent
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p-a-parent-12345678/a+a/p-b-parent-12345678/p-x-leaf-12345678.md
  ---
  title: X leaf
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p-a-parent-12345678/p-a-parent-12345678.md
  ---
  title: A parent
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" deep-nesting" ' DEEP-NESTING DOT-CASE

\ In a git repository slugify stages `.dots`: the index drops the old path.
: GIT-INDEX ( -- )
   PUT-PREFIX
   s" legacy-12345678.md" s" Normal title" s" open" 2 PUT-ISSUE
   s" init|-q" GIT
   0 RC=
   s" add|.dots" GIT
   0 RC=
   s" slugify" RUN
   0 RC=
   s\" legacy-12345678 -> p-normal-title-12345678\nSlugified 1 issue(s)\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=p
.
f .dots/p-normal-title-12345678.md
  ---
  title: Normal title
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
   s" ls-files|--stage|.dots" GIT
   0 RC=
   s\" 100644 a537bf96613880db8a33ae4a2732149fb45c4d23 0\t.dots/config
100644 334cf23d7bba0506813ec71ba11f56d0db8ae057 0\t.dots/p-normal-title-12345678.md
" OUT=
   s" " ERR=
;
s" git-index" ' GIT-INDEX DOT-CASE

;package
;using

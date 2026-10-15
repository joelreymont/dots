\ case-layout.f - the nested layout: where a family's files live as its tasks
\ close and reopen, which tasks the archive holds, and how folders and parent
\ files make the tree. Each case is one `dot` command on its own store.
require dot.f
using DOT-T
package DOT-LAYOUT

\ P > C > G > L, each owner in its own folder: `p/p.md`, `p/c/c.md`,
\ `p/c/g/g.md` and the leaf `p/c/g/l.md`; P is open, C, G and L as given.
: FAMILY ( ptr u8 n ptr u8 n ptr u8 n -- ) {: c:ptr cu:n g:ptr gu:n l:ptr lu:n :}
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c/c.md" s" C" c cu 2 PUT-ISSUE
   s" p/c/g/g.md" s" G" g gu 2 PUT-ISSUE
   s" p/c/g/l.md" s" L" l lu 2 PUT-ISSUE ;

\ The family closed, its whole folder in the archive.
: ARCHIVED-FAMILY ( -- )
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/c/c.md" s" C" s" closed" 2 PUT-ISSUE
   s" archive/p/c/g/g.md" s" G" s" closed" 2 PUT-ISSUE
   s" archive/p/c/g/l.md" s" L" s" closed" 2 PUT-ISSUE ;

\ P's folder holds C's own folder, and C's folder holds G.
: OWNERS ( -- )
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c/c.md" s" C" s" open" 2 PUT-ISSUE
   s" p/c/g.md" s" G" s" open" 2 PUT-ISSUE ;

\ C, a closed child of archived P.
: ARCHIVED-CHILD ( -- )
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/c.md" s" C" s" closed" 2 PUT-ISSUE ;

\ Lead's folder holds a child in each status beside a malformed file; Gate,
\ an open root task, blocks the open child.
: TREE-MARKERS-STORE ( -- )
   s" lead/lead.md" s" Lead parent" s" open" 1 PUT-ISSUE
   s" lead/kid.md" s" ---
title: Open kid
status: open
priority: 3
created-at: 2026-01-01T00:00:00Z
blocks:
  - gate
---
" PUT
   s" lead/shut.md" s" Closed kid" s" done" 0 PUT-ISSUE
   s" lead/run.md" s" Active kid" s" active" 2 PUT-ISSUE
   s" lead/broken.md" s\" not frontmatter\n" PUT
   s" gate.md" s" Gate" s" open" 2 PUT-ISSUE ;

s" layout" SECTION

: OFF-OPEN-DESCENDANT ( -- )
   s" closed" s" closed" s" open" FAMILY
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Cannot close p: children are not all closed\n" ERR=
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
s" off-open-descendant" ' OFF-OPEN-DESCENDANT DOT-CASE

: OFF-CHILD-IN-PLACE ( -- )
   s" open" s" open" s" open" FAMILY
   s" off|l" RUN
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
d .dots/p/c/g
f .dots/p/c/g/g.md
  ---
  title: G
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p/c/g/l.md
  ---
  title: L
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
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
s" off-child-in-place" ' OFF-CHILD-IN-PLACE DOT-CASE

: OFF-OWNER-IN-PLACE ( -- )
   s" open" s" open" s" closed" FAMILY
   s" off|g" RUN
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
d .dots/p/c/g
f .dots/p/c/g/g.md
  ---
  title: G
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
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
s" off-owner-in-place" ' OFF-OWNER-IN-PLACE DOT-CASE

: OFF-ROOT-MOVES-FAMILY ( -- )
   s" closed" s" closed" s" closed" FAMILY
   s" off|p" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p
d .dots/archive/p/c
f .dots/archive/p/c/c.md
  ---
  title: C
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive/p/c/g
f .dots/archive/p/c/g/g.md
  ---
  title: G
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/c/g/l.md
  ---
  title: L
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/p.md
  ---
  title: P
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" off-root-moves-family" ' OFF-ROOT-MOVES-FAMILY DOT-CASE

: ON-OWNER-IN-PLACE ( -- )
   s" open" s" closed" s" closed" FAMILY
   s" on|g" RUN
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
d .dots/p/c/g
f .dots/p/c/g/g.md
  ---
  title: G
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
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
s" on-owner-in-place" ' ON-OWNER-IN-PLACE DOT-CASE

: ON-REOPENS-ARCHIVED-FAMILY ( -- )
   ARCHIVED-FAMILY
   s" on|l" RUN
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
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/p/c/g
f .dots/p/c/g/g.md
  ---
  title: G
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/c/g/l.md
  ---
  title: L
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" on-reopens-archived-family" ' ON-REOPENS-ARCHIVED-FAMILY DOT-CASE

: ON-COMPETING-FOLDER ( -- )
   s" p/existing.md" s" Existing" s" open" 2 PUT-ISSUE
   ARCHIVED-CHILD
   s" on|p" RUN
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/c.md
  ---
  title: C
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
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
d .dots/p
f .dots/p/existing.md
  ---
  title: Existing
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" on-competing-folder" ' ON-COMPETING-FOLDER DOT-CASE

: SHOW-ARCHIVED-MEMBER ( -- )
   ARCHIVED-FAMILY
   s" show|l" RUN
   0 RC=
   s" ID:       l
Title:    L
Status:   done
Priority: 2
Created:  2026-01-01T00:00:00Z
" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/archive/p
d .dots/archive/p/c
f .dots/archive/p/c/c.md
  ---
  title: C
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive/p/c/g
f .dots/archive/p/c/g/g.md
  ---
  title: G
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/p/c/g/l.md
  ---
  title: L
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
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
" TREE=
;
s" show-archived-member" ' SHOW-ARCHIVED-MEMBER DOT-CASE

: RM-ARCHIVED-CHILD ( -- )
   ARCHIVED-CHILD
   s" q.md" s" Q" s" open" 2 PUT-ISSUE
   s" rm|c" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
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
f .dots/q.md
  ---
  title: Q
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" rm-archived-child" ' RM-ARCHIVED-CHILD DOT-CASE

: IMPORT-BLOCKS-ARCHIVED-CHILD ( -- )
   ARCHIVED-CHILD
   s" ../import.jsonl" s\" {\"id\":\"x\",\"title\":\"X\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"dependencies\":[{\"depends_on_id\":\"c\",\"type\":\"blocks\"}]}\n" PUT
   s" init|--from-jsonl|import.jsonl" RUN
   0 RC=
   s\" Imported 1 issues from import.jsonl\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
d .dots/archive/p
f .dots/archive/p/c.md
  ---
  title: C
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
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
f .dots/x.md
  ---
  title: X
  status: open
  priority: 1
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  blocks:
    - c
  ---
.
" TREE=
;
s" import-blocks-archived-child" ' IMPORT-BLOCKS-ARCHIVED-CHILD DOT-CASE

: TREE-NESTED-OWNER ( -- )
   OWNERS
   s" tree" RUN
   0 RC=
   s" [p] ○ P
  └─ [c] ○ C
" OUT=
   s" " ERR=
   s" d .dots
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
f .dots/p/c/g.md
  ---
  title: G
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
s" tree-nested-owner" ' TREE-NESTED-OWNER DOT-CASE

: TREE-OWNER-CHILDREN ( -- )
   OWNERS
   s" tree|c" RUN
   0 RC=
   s" [c] ○ C
  └─ [g] ○ G
" OUT=
   s" " ERR=
   s" d .dots
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
f .dots/p/c/g.md
  ---
  title: G
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
s" tree-owner-children" ' TREE-OWNER-CHILDREN DOT-CASE

\ Each child shows its status marker, and a blocked open child says so.
: TREE-CHILD-MARKERS ( -- )
   TREE-MARKERS-STORE
   s" tree" RUN
   0 RC=
   s" [lead] ○ Lead parent
  └─ [shut] ✓ Closed kid
  └─ [run] > Active kid
  └─ [kid] ○ Open kid (blocked)
[gate] ○ Gate
" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/gate.md
  ---
  title: Gate
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/lead
f .dots/lead/broken.md
  not frontmatter
.
f .dots/lead/kid.md
  ---
  title: Open kid
  status: open
  priority: 3
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - gate
  ---
.
f .dots/lead/lead.md
  ---
  title: Lead parent
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/lead/run.md
  ---
  title: Active kid
  status: active
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/lead/shut.md
  ---
  title: Closed kid
  status: done
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-child-markers" ' TREE-CHILD-MARKERS DOT-CASE

: TREE-DEEP-ORPHAN ( -- )
   s" p/q/leaf.md" s" Leaf" s" open" 2 PUT-ISSUE
   s" tree" RUN
   0 RC=
   s\" [leaf] ○ Leaf\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/p
d .dots/p/q
f .dots/p/q/leaf.md
  ---
  title: Leaf
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-deep-orphan" ' TREE-DEEP-ORPHAN DOT-CASE

: TREE-MALFORMED-PARENT ( -- )
   s" bent/bent.md" s\" not frontmatter\n" PUT
   s" bent/sprout.md" s" Sprout" s" open" 2 PUT-ISSUE
   s" tree" RUN
   0 RC=
   s\" [sprout] ○ Sprout\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/bent
f .dots/bent/bent.md
  not frontmatter
.
f .dots/bent/sprout.md
  ---
  title: Sprout
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-malformed-parent" ' TREE-MALFORMED-PARENT DOT-CASE

: TREE-MALFORMED-ID ( -- )
   TREE-MARKERS-STORE
   s" tree|broken" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s" d .dots
d .dots/archive
f .dots/gate.md
  ---
  title: Gate
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/lead
f .dots/lead/broken.md
  not frontmatter
.
f .dots/lead/kid.md
  ---
  title: Open kid
  status: open
  priority: 3
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - gate
  ---
.
f .dots/lead/lead.md
  ---
  title: Lead parent
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/lead/run.md
  ---
  title: Active kid
  status: active
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/lead/shut.md
  ---
  title: Closed kid
  status: done
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-malformed-id" ' TREE-MALFORMED-ID DOT-CASE

: TREE-STRAY-CHILD ( -- )
   s" b.md" s" B" s" open" 2 PUT-ISSUE
   s" a/b/c.md" s" C" s" open" 2 PUT-ISSUE
   s" tree" RUN
   0 RC=
   s" [b] ○ B
  └─ [c] ○ C
[c] ○ C
" OUT=
   s" " ERR=
   s" d .dots
d .dots/a
d .dots/a/b
f .dots/a/b/c.md
  ---
  title: C
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
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
s" tree-stray-child" ' TREE-STRAY-CHILD DOT-CASE

: TREE-LEGACY-FOLDER ( -- )
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/x.md" s" X" s" open" 2 PUT-ISSUE
   s" tree" RUN
   0 RC=
   s" [p] ○ P
  └─ [x] ○ X
[x] ○ X
" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/x.md
  ---
  title: X
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-legacy-folder" ' TREE-LEGACY-FOLDER DOT-CASE

: TREE-TWIN-OWNERS ( -- )
   s" twin.md" s" Twin file" s" open" 2 PUT-ISSUE
   s" twin/twin.md" s" Twin folder" s" open" 2 PUT-ISSUE
   s" twin/pair.md" s" Pair" s" open" 2 PUT-ISSUE
   s" tree" RUN
   0 RC=
   s" [twin] ○ Twin file
  └─ [pair] ○ Pair
[twin] ○ Twin folder
  └─ [pair] ○ Pair
" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/twin
f .dots/twin/pair.md
  ---
  title: Pair
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/twin/twin.md
  ---
  title: Twin folder
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/twin.md
  ---
  title: Twin file
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" tree-twin-owners" ' TREE-TWIN-OWNERS DOT-CASE

: SHOW-DEPTH-ELEVEN ( -- )
   s" d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/leaf.md" s" Deep leaf" s" open" 2 PUT-ISSUE
   s" show|leaf" RUN
   0 RC=
   s" ID:       leaf
Title:    Deep leaf
Status:   open
Priority: 2
Created:  2026-01-01T00:00:00Z
" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
d .dots/d0
d .dots/d0/d1
d .dots/d0/d1/d2
d .dots/d0/d1/d2/d3
d .dots/d0/d1/d2/d3/d4
d .dots/d0/d1/d2/d3/d4/d5
d .dots/d0/d1/d2/d3/d4/d5/d6
d .dots/d0/d1/d2/d3/d4/d5/d6/d7
d .dots/d0/d1/d2/d3/d4/d5/d6/d7/d8
d .dots/d0/d1/d2/d3/d4/d5/d6/d7/d8/d9
d .dots/d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10
f .dots/d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/leaf.md
  ---
  title: Deep leaf
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" show-depth-eleven" ' SHOW-DEPTH-ELEVEN DOT-CASE

;package
;using

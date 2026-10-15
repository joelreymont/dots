\ case-add.f - add: the id it prints from the prefix and the title's slug, the
\ fields and options it writes, where a child goes, and the adds it refuses.
\ Each case is one `dot add` on its own store, parent-folder then reading it
\ with `tree`. A refused add leaves the store as it was: it writes no config,
\ folder or archive.
require dot.f
using DOT-T
package DOT-ADD

: PREFIX-X ( -- ) s" config" s\" prefix=x\n" PUT ;

65536 constant CONFIG-LIMIT             \ dot's config limit, inclusive
create CONF BUF:HDR-BYTES allot         \ a generated config
CONF 256 BUF:N>BLEN BUF:INIT
create CONF-TREE BUF:HDR-BYTES allot    \ the tree expected beside it
CONF-TREE 256 BUF:N>BLEN BUF:INIT

: CONF+ ( ptr u8 n -- ) BUF:N>BLEN CONF BUF:APPEND-SPAN ;
: CONF-TREE+ ( ptr u8 n -- ) BUF:N>BLEN CONF-TREE BUF:APPEND-SPAN ;
: CONF$ ( -- ptr u8 n ) CONF BUF:SPAN$ BUF:BLEN>N ;
: CONF-TREE$ ( -- ptr u8 n ) CONF-TREE BUF:SPAN$ BUF:BLEN>N ;
: CONF-BYTES ( n n ptr a -- ) {: c:n k:n b:ptr :}
   k 0 ?do c b BUF:APPEND-BYTE loop ;

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

\ The store's name holds `#`, which no id may hold, so the id add derives is
\ invalid and the refusal writes nothing.
: INVALID-STORE-ID ( -- )
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue id\n" ERR=
   s\" d .dots\nd .dots/archive\n" TREE=
;
s" add-invalid-store#id" ' INVALID-STORE-ID DOT-CASE

\ A prefix too long for any id fails as an invalid one, however long the
\ config lets it be, and the refusal writes nothing.
1020 constant PREFIX-LONG               \ prefix bytes past any id
: ADD-PREFIX-TOO-LONG ( -- )
   CONF BUF:CLEAR
   s" prefix=" CONF+  [char] p PREFIX-LONG CONF CONF-BYTES  s\" \n" CONF+
   s" config" CONF$ PUT
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue id\n" ERR=
   CONF-TREE BUF:CLEAR
   s\" d .dots\nd .dots/archive\nf .dots/config\n  prefix=" CONF-TREE+
   [char] p PREFIX-LONG CONF-TREE CONF-BYTES  s\" \n.\n" CONF-TREE+
   CONF-TREE$ TREE=
;
s" add-prefix-too-long" ' ADD-PREFIX-TOO-LONG DOT-CASE

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

\ A first word longer than 30 bytes is cut at the 30th byte.
: SLUG-LONG-WORD ( -- )
   PREFIX-X
   s" add|Supercalifragilisticexpialidocious" RUN
   s" A" SAVE-ID
   s" A" s" x-supercalifragilisticexpialidoc-<hex>" ID=
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

: SLUG-WORD-AT-CAP ( -- )
   PREFIX-X
   s" add|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbb" RUN
   s" A" SAVE-ID
   s" A" s" x-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-<hex>" ID=
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
  title: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbb
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-word-at-cap" ' SLUG-WORD-AT-CAP DOT-CASE

: SLUG-WORD-OVER-CAP ( -- )
   PREFIX-X
   s" add|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbb" RUN
   s" A" SAVE-ID
   s" A" s" x-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-<hex>" ID=
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
  title: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbb
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" slug-word-over-cap" ' SLUG-WORD-OVER-CAP DOT-CASE

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

\ A priority reads in decimal.f's grammar: `1_2` is 12, clamped to 9, and
\ `1__2` is refused.
: PRIORITY-SEPARATOR ( -- )
   PREFIX-X
   s" add|T|-p|1_2" RUN
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
s" priority-separator" ' PRIORITY-SEPARATOR DOT-CASE

: PRIORITY-SEPARATORS ( -- )
   s" add|-p|1__2|Title" RUN
   1 RC=
   s" " OUT=
   s\" Invalid priority: 1__2\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" priority-separators" ' PRIORITY-SEPARATORS DOT-CASE

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

\ An empty priority is refused, and the message ends where the value would.
: ADD-EMPTY-PRIORITY ( -- )
   s" add|T|-p|" RUN
   1 RC=
   s" " OUT=
   s\" Invalid priority: \n" ERR=
   s\" d .dots\nd .dots/archive\n" TREE=
;
s" add-empty-priority" ' ADD-EMPTY-PRIORITY DOT-CASE

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
" TREE=
;
s" parent-archive-id" ' PARENT-ARCHIVE-ID DOT-CASE

\ In a directory without `.dots` add creates the store with its task and config,
\ but no archive.
: ADD-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" add|T" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/config
  prefix=add-no-store
.
" TREE=
;
s" add-no-store" ' ADD-NO-STORE DOT-CASE

\ In a directory without `.dots` the refusal creates nothing.
: PARENT-ABSENT ( -- )
   s" ../.dots" RM-DIR
   s" add|Title|-P|absent" RUN
   1 RC=
   s" " OUT=
   s\" Parent issue not found: absent\n" ERR=
   s" " TREE=
;
s" parent-absent" ' PARENT-ABSENT DOT-CASE

: AFTER-ABSENT ( -- )
   s" add|T|-a|absent" RUN
   1 RC=
   s" " OUT=
   s\" After issue not found: absent\n" ERR=
   s" d .dots
d .dots/archive
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
" TREE=
;
s" archived-parent" ' ARCHIVED-PARENT DOT-CASE

: CLOSED-PARENT ( -- )
   PREFIX-X
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/c.md" s" C" s" closed" 2 PUT-ISSUE
   s" add|Kid|-P|c" RUN
   1 RC=
   s" " OUT=
   s\" Parent issue is closed: c\n" ERR=
   s" d .dots
d .dots/archive
f .dots/config
  prefix=x
.
d .dots/p
f .dots/p/c.md
  ---
  title: C
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
s" closed-parent" ' CLOSED-PARENT DOT-CASE

: MALFORMED-PARENT ( -- )
   PREFIX-X
   s" c.md" s\" not frontmatter\n" PUT
   s" add|Kid|-P|c" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s" d .dots
d .dots/archive
f .dots/c.md
  not frontmatter
.
f .dots/config
  prefix=x
.
" TREE=
;
s" malformed-parent" ' MALFORMED-PARENT DOT-CASE

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

\ A config of n bytes ends with its prefix, so only a whole read finds it.
: PUT-CONFIG ( n -- ) {: n:n :}
   CONF BUF:CLEAR
   s" pad=" CONF+  [char] x n 14 - CONF CONF-BYTES  s\" \nprefix=x\n" CONF+
   s" config" CONF$ PUT ;

\ The tree of a store holding PUT-CONFIG's n bytes and nothing else.
: CONFIG-TREE ( n -- ) {: n:n :}
   CONF-TREE BUF:CLEAR
   s\" d .dots\nd .dots/archive\nf .dots/config\n  pad=" CONF-TREE+
   [char] x n 14 - CONF-TREE CONF-BYTES
   s\" \n  prefix=x\n.\n" CONF-TREE+ ;

\ A config of exactly the limit is read.
: CONFIG-AT-LIMIT ( -- )
   CONFIG-LIMIT PUT-CONFIG
   s" add|T" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s" A" s" x-t-<hex>" ID=
   CONFIG-LIMIT CONFIG-TREE
   s\" f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" CONF-TREE+
   CONF-TREE$ TREE=
;
s" config-at-limit" ' CONFIG-AT-LIMIT DOT-CASE

: CONFIG-TOO-LARGE ( -- )
   CONFIG-LIMIT 1+ PUT-CONFIG
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Config file too large: .dots/config\n" ERR=
   CONFIG-LIMIT 1+ CONFIG-TREE
   CONF-TREE$ TREE=
;
s" config-too-large" ' CONFIG-TOO-LARGE DOT-CASE

: CONFIG-DIRECTORY ( -- )
   s" .dots/config" FILE$ MAKE-DIRS
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Not a file: .dots/config\n" ERR=
   s\" d .dots\nd .dots/archive\nd .dots/config\n" TREE=
;
s" config-directory" ' CONFIG-DIRECTORY DOT-CASE

\ A config of n bytes as one pad line and no prefix, so add records the
\ store's derived prefix, the case name.
: PUT-PAD ( n -- ) {: n:n :}
   CONF BUF:CLEAR
   s" pad=" CONF+  [char] x n 5 - CONF CONF-BYTES  s\" \n" CONF+
   s" config" CONF$ PUT ;

\ The tree of a store holding PUT-PAD's n bytes, up to the end of its pad line.
: PAD-TREE ( n -- ) {: n:n :}
   CONF-TREE BUF:CLEAR
   s\" d .dots\nd .dots/archive\nf .dots/config\n  pad=" CONF-TREE+
   [char] x n 5 - CONF-TREE CONF-BYTES
   s\" \n" CONF-TREE+ ;

\ The prefix line add appends in config-write-at-limit.
: AT-LIMIT-PREFIX ( -- ptr u8 n ) s\" prefix=config-write-at-limit\n" ;

\ A config add rewrites to exactly the limit is written.
: CONFIG-WRITE-AT-LIMIT ( -- )
   CONFIG-LIMIT AT-LIMIT-PREFIX nip - {: n:n :}
   n PUT-PAD
   s" add|T" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s" A" s" config-write-at-limit-t-<hex>" ID=
   n PAD-TREE
   s\"   prefix=config-write-at-limit
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
" CONF-TREE+
   CONF-TREE$ TREE=
;
s" config-write-at-limit" ' CONFIG-WRITE-AT-LIMIT DOT-CASE

\ dot never writes a config it cannot read: add refuses a config its prefix
\ would take past the limit and leaves the store as it was.
: CONFIG-WRITE-TOO-LARGE ( -- )
   65530 PUT-PAD
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Config file too large: .dots/config\n" ERR=
   65530 PAD-TREE
   s\" .\n" CONF-TREE+
   CONF-TREE$ TREE=
;
s" config-write-too-large" ' CONFIG-WRITE-TOO-LARGE DOT-CASE

\ A config that holds a prefix is never rewritten: its lines stay as they were.
: CONFIG-KEPT ( -- )
   s" config" s\" mode=a\nprefix=x\nmode=b\nnote\n" PUT
   s" add|T" RUN
   s" A" SAVE-ID
   s" A" s" x-t-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  mode=a
  prefix=x
  mode=b
  note
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
s" config-kept" ' CONFIG-KEPT DOT-CASE

\ A symlinked config is read through and never replaced.
: CONFIG-SYMLINK ( -- )
   s" ../shared/config" s\" prefix=x\n" PUT
   s" ../shared/config" s" config" LINK
   s" add|T" RUN
   s" A" SAVE-ID
   s" A" s" x-t-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
l .dots/config -> ../shared/config
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
   s" shared" s\" d shared\nf shared/config\n  prefix=x\n.\n" DIR=
;
s" config-symlink" ' CONFIG-SYMLINK DOT-CASE

\ The prefix add would record cannot go through a symlinked config.
: CONFIG-SYMLINK-UNPREFIXED ( -- )
   s" ../shared/config" s\" mode=a\n" PUT
   s" ../shared/config" s" config" LINK
   s" add|T" RUN
   1 RC=
   s" " OUT=
   s\" Config is a symlink: .dots/config\n" ERR=
   s" d .dots
d .dots/archive
l .dots/config -> ../shared/config
" TREE=
   s" shared" s\" d shared\nf shared/config\n  mode=a\n.\n" DIR=
;
s" config-symlink-unprefixed" ' CONFIG-SYMLINK-UNPREFIXED DOT-CASE

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
\ before the run, and add refuses it where it is taken: where any task the
\ loader reads has it, in either partition at any depth, where the new file's
\ path holds anything, and where `.dots/<id>` links to a folder. A file below a
\ folder named archive under the top or through a symlink is no task. An empty
\ folder of the id's name takes the new task. Each store holds task a beside
\ the placements.
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

\ Without a config the pinned id takes the store's name as its prefix, and the
\ refusal writes no config.
: PINNED-TAKEN-NO-CONFIG ( -- )
   s" pinned-taken-no-config-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Issue already exists\n" ERR=
   s" d .dots
d .dots/archive
f .dots/pinned-taken-no-config-task-5eed1d00.md
  ---
  title: Taken
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" pinned-taken-no-config" ' PINNED-TAKEN-NO-CONFIG DOT-CASE

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

: PINNED-TAKEN-DEPTH-11 ( -- )
   PINNED-STORE
   s" d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/x-task-5eed1d00.md" s" Taken" s" open" 2 PUT-ISSUE
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
s" pinned-taken-depth-11" ' PINNED-TAKEN-DEPTH-11 DOT-CASE

: PINNED-TAKEN-ARCHIVED-CHILD ( -- )
   PINNED-STORE
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
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
s" pinned-taken-archived-child" ' PINNED-TAKEN-ARCHIVED-CHILD DOT-CASE

\ The refusal comes before a moves into its own folder.
: PINNED-TAKEN-ARCHIVED-CHILD-CHILD ( -- )
   PINNED-STORE
   s" archive/p/p.md" s" P" s" closed" 2 PUT-ISSUE
   s" archive/p/x-task-5eed1d00.md" s" Taken" s" closed" 2 PUT-ISSUE
   s" add|Task|-P|a" RUN-PINNED
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
s" pinned-taken-archived-child-child" ' PINNED-TAKEN-ARCHIVED-CHILD-CHILD DOT-CASE

\ A dangling link takes the id as any other entry does.
: PINNED-TAKEN-FILE-SYMLINK ( -- )
   PINNED-STORE
   s" gone.md" s" x-task-5eed1d00.md" LINK
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
l .dots/x-task-5eed1d00.md -> gone.md
" TREE=
;
s" pinned-taken-file-symlink" ' PINNED-TAKEN-FILE-SYMLINK DOT-CASE

: PINNED-TAKEN-FILE-DIRECTORY ( -- )
   PINNED-STORE
   s" .dots/x-task-5eed1d00.md" FILE$ MAKE-DIRS
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
d .dots/x-task-5eed1d00.md
" TREE=
;
s" pinned-taken-file-directory" ' PINNED-TAKEN-FILE-DIRECTORY DOT-CASE

\ add writes nothing through a folder link, so the outside folder stays empty.
: PINNED-TAKEN-FOLDER-SYMLINK ( -- )
   PINNED-STORE
   s" outside" FILE$ MAKE-DIRS
   s" ../outside" s" x-task-5eed1d00" LINK
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
l .dots/x-task-5eed1d00 -> ../outside
" TREE=
   s" outside" s\" d outside\n" DIR=
;
s" pinned-taken-folder-symlink" ' PINNED-TAKEN-FOLDER-SYMLINK DOT-CASE

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

\ A task more than 512 bytes below `.dots` is checked too: only the OS path
\ limit applies.
: PINNED-FREE-LONG-PATH ( -- )
   PINNED-STORE
   LONG BUF:CLEAR DEEP+ s" /deep.md" L+
   L$ s" Deep" s" open" 2 PUT-ISSUE
   s" add|Task" RUN-PINNED
   0 RC=
   s\" x-task-5eed1d00\n" OUT=
   s" " ERR=
   LONG BUF:CLEAR
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
f .dots/x-task-5eed1d00.md
  ---
  title: Task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/" L+
   [char] x NAME-MAX L-BYTES s\" \nd .dots/" L+ DEEP+ s\" \nf .dots/" L+ DEEP+
   s\" /deep.md\n  ---\n  title: Deep\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" L+
   L$ TREE=
;
s" pinned-free-long-path" ' PINNED-FREE-LONG-PATH DOT-CASE

\ A child whose path would pass FS-PATH-CAP is refused before p gains a
\ folder. The tree is read with the top folder renamed back to `a`.
: PINNED-PARENT-PATH-TOO-LONG ( -- )
   PINNED-STORE
   LONG BUF:CLEAR s" a/" L+ D-NAME BCD+ s" /p.md" L+
   L$ s" P" s" open" 2 PUT-ISSUE
   true MOVE-TOP
   s" add|Kid|-P|p" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   false MOVE-TOP
   LONG BUF:CLEAR
   s\" d .dots\nd .dots/a\nd .dots/a/" L+ [char] b NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ [char] b NAME-MAX L-BYTES s" /" L+ [char] c NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ D-NAME BCD+ s\" \nf .dots/a/" L+ D-NAME BCD+
   s\" /p.md\n  ---\n  title: P\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" L+
   s\" f .dots/a.md
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
" L+
   L$ TREE=
;
s" pinned-parent-path-too-long" ' PINNED-PARENT-PATH-TOO-LONG DOT-CASE

\ With a 210-byte d folder, p's own folder for the 20-byte id is 1005 bytes:
\ the child's file there, 1023 bytes, fits FS-PATH-CAP, but p's own file
\ there, 1029 bytes, does not. add refuses before p gains a folder.
210 constant OWN-D-NAME                 \ the d folder that bounds p's own path
: PINNED-PARENT-OWN-PATH-TOO-LONG ( -- )
   PINNED-STORE
   LONG BUF:CLEAR s" a/" L+ OWN-D-NAME BCD+ s" /pppppppppppppppppppp.md" L+
   L$ s" P" s" open" 2 PUT-ISSUE
   true MOVE-TOP
   s" add|Kid|-P|pppppppppppppppppppp" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   false MOVE-TOP
   LONG BUF:CLEAR
   s\" d .dots\nd .dots/a\nd .dots/a/" L+ [char] b NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ [char] b NAME-MAX L-BYTES s" /" L+ [char] c NAME-MAX L-BYTES
   s\" \nd .dots/a/" L+ OWN-D-NAME BCD+ s\" \nf .dots/a/" L+ OWN-D-NAME BCD+
   s\" /pppppppppppppppppppp.md\n  ---\n  title: P\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" L+
   s\" f .dots/a.md
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
" L+
   L$ TREE=
;
s" pinned-parent-own-path-too-long" ' PINNED-PARENT-OWN-PATH-TOO-LONG DOT-CASE

\ A link where p's own folder goes is no folder: add moves nothing and writes
\ nothing through it, so the outside folder stays empty.
: PINNED-PARENT-FOLDER-SYMLINK ( -- )
   PINNED-STORE
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" outside" FILE$ MAKE-DIRS
   s" ../outside" s" p" LINK
   s" add|Kid|-P|p" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Not a directory: .dots/p\n" ERR=
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
l .dots/p -> ../outside
f .dots/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
   s" outside" s\" d outside\n" DIR=
;
s" pinned-parent-folder-symlink" ' PINNED-PARENT-FOLDER-SYMLINK DOT-CASE

\ Without a config the same refusal writes none.
: PARENT-FOLDER-SYMLINK-NO-CONFIG ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" outside" FILE$ MAKE-DIRS
   s" ../outside" s" p" LINK
   s" add|Kid|-P|p" RUN
   1 RC=
   s" " OUT=
   s\" Not a directory: .dots/p\n" ERR=
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
l .dots/p -> ../outside
f .dots/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
   s" outside" s\" d outside\n" DIR=
;
s" parent-folder-symlink-no-config" ' PARENT-FOLDER-SYMLINK-NO-CONFIG DOT-CASE

: PINNED-PARENT-FOLDER-FILE ( -- )
   PINNED-STORE
   s" p.md" s" P" s" open" 2 PUT-ISSUE
   s" p" s\" text\n" PUT
   s" add|Kid|-P|p" RUN-PINNED
   1 RC=
   s" " OUT=
   s\" Not a directory: .dots/p\n" ERR=
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
f .dots/p
  text
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
s" pinned-parent-folder-file" ' PINNED-PARENT-FOLDER-FILE DOT-CASE

;package
;using

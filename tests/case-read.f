\ case-read.f - storage and reading: how ls, ready, show and find read a
\ store's task files: listing order and filters, field defaults, quoted
\ scalars, malformed files, entries that are not regular files, nested archive
\ folders, a missing `.dots` or archive, which reading never creates, selective
\ loading beside an oversized file, the commands that refuse one, a file of
\ exactly the limit, and stores past one directory read or one output buffer.
\ Each case is one `dot` command on its own store.
require dot.f
require src/lib/string.f
require src/lib/byte-buffer.f
require src/lib/fmt.f
using DOT-T
package DOT-READ

1048576 constant ISSUE-LIMIT            \ dot's task file limit, inclusive
630 constant MANY                       \ names past one 64 KiB directory read
65 constant WIDE                        \ tasks whose JSON passes 4 MiB
70000 constant WIDE-DESC                \ each one's description bytes
104 constant NAME-PAD                   \ makes each generated name 117 bytes

create GEN-FILE BUF:HDR-BYTES allot     \ a generated task file
create GEN-NAME BUF:HDR-BYTES allot     \ its name
create GEN-OUT BUF:HDR-BYTES allot      \ the expected stdout or stderr
create GEN-TREE BUF:HDR-BYTES allot     \ the expected tree
create DIG-BUF 20 allot
GEN-FILE 256 BUF:N>BLEN BUF:INIT
GEN-NAME 256 BUF:N>BLEN BUF:INIT
GEN-OUT 4096 BUF:N>BLEN BUF:INIT
GEN-TREE 4096 BUF:N>BLEN BUF:INIT

\ ---- generated stores -------------------------------------------------------

: GEN+ ( ptr u8 n ptr a -- ) {: a:ptr u:n b:ptr :}
   a u BUF:N>BLEN b BUF:APPEND-SPAN ;

: GEN$ ( ptr a -- ptr u8 n )
   BUF:SPAN$ BUF:BLEN>N ;

: GEN-BYTES ( n n ptr a -- ) {: c:n k:n b:ptr :}
   k 0 ?do c b BUF:APPEND-BYTE loop ;

: GEN-NUMBER ( n ptr a -- ) {: k:n b:ptr :}
   SB-RESET k FMT:SB-INT SB$ b GEN+ ;

\ The low w decimal digits of v, zero-padded.
: GEN-DIGITS ( n n ptr a -- ) {: v:n w:n b:ptr :}
   v w 0 ?do 10 /mod swap [char] 0 + DIG-BUF w i - 1- + c! loop drop
   DIG-BUF w b GEN+ ;

\ `2026-01-01T00:MM:SSZ`, k seconds into the year.
: GEN-STAMP ( n ptr a -- ) {: k:n b:ptr :}
   s" 2026-01-01T00:" b GEN+
   k 60 / 2 b GEN-DIGITS  s" :" b GEN+  k 60 mod 2 b GEN-DIGITS
   s" Z" b GEN+ ;

: TREE-FROM ( ptr u8 n -- )
   GEN-TREE BUF:CLEAR GEN-TREE GEN+ ;

\ The entry TREE$ gives `.dots/<path>` holding the bytes.
: TREE-FILE ( ptr u8 n ptr u8 n -- ) {: path:ptr pathu:n a:ptr u:n :}
   s" f .dots/" GEN-TREE GEN+  path pathu GEN-TREE GEN+  10 GEN-TREE BUF:APPEND-BYTE
   true u 0 ?do
      if s"   " GEN-TREE GEN+ then
      a i + c@ dup GEN-TREE BUF:APPEND-BYTE 10 =
   loop
   0= if s\" \n\\\n" GEN-TREE GEN+ then
   s\" .\n" GEN-TREE GEN+ ;

\ Seed `item-NNNN-x…x.md`, task "Item k" created k seconds into 2026 with a
\ description of desc bytes (0: none), and add it to the expected tree.
: GEN-ITEM ( n n -- ) {: k:n desc:n :}
   GEN-NAME BUF:CLEAR
   s" item-" GEN-NAME GEN+  k 4 GEN-NAME GEN-DIGITS  s" -" GEN-NAME GEN+
   [char] x NAME-PAD GEN-NAME GEN-BYTES  s" .md" GEN-NAME GEN+
   GEN-FILE BUF:CLEAR
   s\" ---\ntitle: Item " GEN-FILE GEN+  k GEN-FILE GEN-NUMBER
   s\" \nstatus: open\npriority: 2\ncreated-at: " GEN-FILE GEN+  k GEN-FILE GEN-STAMP
   s\" \n---\n" GEN-FILE GEN+
   desc 0 > if
      10 GEN-FILE BUF:APPEND-BYTE
      [char] x desc GEN-FILE GEN-BYTES
      10 GEN-FILE BUF:APPEND-BYTE
   then
   GEN-NAME GEN$ GEN-FILE GEN$ PUT
   GEN-NAME GEN$ GEN-FILE GEN$ TREE-FILE ;

: ITEM-ID ( -- ptr u8 n ) GEN-NAME GEN$ 3 - ;

\ A file at the path one byte over the limit, in GEN-FILE.
: BIG ( ptr u8 n -- )
   GEN-FILE BUF:CLEAR  [char] x ISSUE-LIMIT 1+ GEN-FILE GEN-BYTES
   GEN-FILE GEN$ PUT ;

\ a.md, open, beside z.md one byte over the limit.
: BIG-STORE ( -- )
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" z.md" BIG ;

\ BIG-STORE's tree.
: BIG-STORE-TREE ( -- ptr u8 n )
   s\" d .dots\nf .dots/a.md\n  ---\n  title: A\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\n" TREE-FROM
   s" z.md" GEN-FILE GEN$ TREE-FILE
   GEN-TREE GEN$ ;

\ A command that reads z.md refuses it by its path and changes nothing.
: TOO-LARGE ( ptr u8 n -- )
   BIG-STORE
   RUN
   1 RC=
   s" " OUT=
   s\" Issue file too large: .dots/z.md\n" ERR=
   BIG-STORE-TREE TREE= ;

\ `<255 x's>/<255 y's>/deep.md` in GEN-NAME, 519 bytes below `.dots`.
: DEEP-NAME ( -- )
   GEN-NAME BUF:CLEAR
   [char] x NAME-MAX GEN-NAME GEN-BYTES  s" /" GEN-NAME GEN+
   [char] y NAME-MAX GEN-NAME GEN-BYTES  s" /deep.md" GEN-NAME GEN+ ;

\ Append `<255 b>/<255 c>/<236 d>`, the deep path's folders below the top.
: GEN-BCD+ ( ptr a -- ) {: b:ptr :}
   [char] b NAME-MAX b GEN-BYTES  s" /" b GEN+  [char] c NAME-MAX b GEN-BYTES
   s" /" b GEN+  [char] d D-NAME b GEN-BYTES ;

\ ---- the listing store ------------------------------------------------------

\ Open, active, blocked, done, nested, archived and defaulted tasks.
: LISTING ( -- )
   s" alpha.md" s" ---
title: Alpha login
status: open
priority: 1
created-at: 2026-01-01T00:00:00Z
blocks:
  - beta
---

Auth implementation
" PUT
   s" beta.md" s" Beta backend" s" active" 0 PUT-ISSUE
   s" delta.md" s" ---
title: Closed root
status: done
priority: 4
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-03T00:00:00Z
close-reason: Merged auth patch
---
" PUT
   s" epsilon.md" s" ---
title: Ready with done dependency
status: open
priority: 3
created-at: 2026-01-01T00:00:00Z
blocks:
  - delta
---
" PUT
   s" gamma.md" s" ---
title: Ready with missing dependency
status: open
priority: 2
created-at: 2026-01-01T00:00:00Z
blocks:
  - missing
---
" PUT
   s" project/project.md" s" Project parent" s" open" 5 PUT-ISSUE
   s" project/child.md" s" ---
title: Nested child
status: open
priority: 2
created-at: 2026-01-02T00:00:00Z
---
" PUT
   s" archive/old.md" s" ---
title: Archived AUTH task
status: closed
priority: 0
created-at: 2026-01-01T00:00:00Z
closed-at: 2026-02-04T00:00:00Z
close-reason: Old fix
---
" PUT
   s" defaults.md" s" ---
title: Defaults
created-at: 2026-01-03T00:00:00Z
---
" PUT ;

\ `\x20` spells a trailing space, which source text cannot keep.
: LISTING-TREE ( -- ptr u8 n )
   s\" d .dots
f .dots/alpha.md
  ---
  title: Alpha login
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - beta
  ---
\x20\x20
  Auth implementation
.
d .dots/archive
f .dots/archive/old.md
  ---
  title: Archived AUTH task
  status: closed
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  closed-at: 2026-02-04T00:00:00Z
  close-reason: Old fix
  ---
.
f .dots/beta.md
  ---
  title: Beta backend
  status: active
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/defaults.md
  ---
  title: Defaults
  created-at: 2026-01-03T00:00:00Z
  ---
.
f .dots/delta.md
  ---
  title: Closed root
  status: done
  priority: 4
  created-at: 2026-01-01T00:00:00Z
  closed-at: 2026-02-03T00:00:00Z
  close-reason: Merged auth patch
  ---
.
f .dots/epsilon.md
  ---
  title: Ready with done dependency
  status: open
  priority: 3
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - delta
  ---
.
f .dots/gamma.md
  ---
  title: Ready with missing dependency
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - missing
  ---
.
d .dots/project
f .dots/project/child.md
  ---
  title: Nested child
  status: open
  priority: 2
  created-at: 2026-01-02T00:00:00Z
  ---
.
f .dots/project/project.md
  ---
  title: Project parent
  status: open
  priority: 5
  created-at: 2026-01-01T00:00:00Z
  ---
.
" ;

\ Tasks tied on priority and creation time but for Zero; two share the id
\ bravo.
: TIES ( -- )
   s" foxtrot.md" s" Foxtrot" s" open" 2 PUT-ISSUE
   s" nested/bravo.md" s" Nested bravo" s" open" 2 PUT-ISSUE
   s" charlie.md" s" Charlie" s" active" 2 PUT-ISSUE
   s" zero.md" s" Zero" s" open" 0 PUT-ISSUE
   s" bravo.md" s" Bravo" s" open" 2 PUT-ISSUE
   s" alpha.md" s" Alpha" s" open" 2 PUT-ISSUE
   s" hotel.md" s" Hotel" s" done" 2 PUT-ISSUE
   s" archive/zulu.md" s" Zulu" s" closed" 2 PUT-ISSUE
   s" archive/kilo.md" s" Kilo" s" closed" 2 PUT-ISSUE ;

: TIES-TREE ( -- ptr u8 n )
   s" d .dots
f .dots/alpha.md
  ---
  title: Alpha
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
f .dots/archive/kilo.md
  ---
  title: Kilo
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/archive/zulu.md
  ---
  title: Zulu
  status: closed
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/bravo.md
  ---
  title: Bravo
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/charlie.md
  ---
  title: Charlie
  status: active
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/foxtrot.md
  ---
  title: Foxtrot
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/hotel.md
  ---
  title: Hotel
  status: done
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/nested
f .dots/nested/bravo.md
  ---
  title: Nested bravo
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/zero.md
  ---
  title: Zero
  status: open
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  ---
.
" ;

s" read" SECTION

\ ---- listing ----------------------------------------------------------------

\ Open and active tasks, nested ones too, by priority then creation time.
: LS-TEXT ( -- )
   LISTING
   s" ls" RUN
   0 RC=
   s" [beta] > Beta backend
[alpha] o Alpha login
[gamma] o Ready with missing dependency
[child] o Nested child
[defaults] o Defaults
[epsilon] o Ready with done dependency
[project] o Project parent
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-text" ' LS-TEXT DOT-CASE

\ Every field, with defaults for the ones a file leaves out.
: LS-JSON ( -- )
   LISTING
   s" ls|--json" RUN
   0 RC=
   s\" [{\"id\":\"beta\",\"title\":\"Beta backend\",\"description\":null,\"status\":\"active\",\"priority\":0,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"alpha\",\"title\":\"Alpha login\",\"description\":\"Auth implementation\",\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"gamma\",\"title\":\"Ready with missing dependency\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"child\",\"title\":\"Nested child\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-02T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"defaults\",\"title\":\"Defaults\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-03T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"epsilon\",\"title\":\"Ready with done dependency\",\"description\":null,\"status\":\"open\",\"priority\":3,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null},{\"id\":\"project\",\"title\":\"Project parent\",\"description\":null,\"status\":\"open\",\"priority\":5,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-json" ' LS-JSON DOT-CASE

: LS-STATUS-ACTIVE ( -- )
   LISTING
   s" ls|--status|active" RUN
   0 RC=
   s\" [beta] > Beta backend\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-status-active" ' LS-STATUS-ACTIVE DOT-CASE

\ Done tasks outside the archive only.
: LS-STATUS-DONE ( -- )
   LISTING
   s" ls|--status|done" RUN
   0 RC=
   s\" [delta] x Closed root\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-status-done" ' LS-STATUS-DONE DOT-CASE

: LS-STATUS-CLOSED ( -- )
   LISTING
   s" ls|--status|closed" RUN
   0 RC=
   s\" [delta] x Closed root\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-status-closed" ' LS-STATUS-CLOSED DOT-CASE

: LS-STATUS-OPEN ( -- )
   LISTING
   s" ls|--status|open" RUN
   0 RC=
   s" [alpha] o Alpha login
[gamma] o Ready with missing dependency
[child] o Nested child
[defaults] o Defaults
[epsilon] o Ready with done dependency
[project] o Project parent
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ls-status-open" ' LS-STATUS-OPEN DOT-CASE

\ Ties go by id, and records sharing an id by path.
: LS-TIES ( -- )
   TIES
   s" ls" RUN
   0 RC=
   s" [zero] o Zero
[alpha] o Alpha
[bravo] o Bravo
[bravo] o Nested bravo
[charlie] > Charlie
[foxtrot] o Foxtrot
" OUT=
   s" " ERR=
   TIES-TREE TREE=
;
s" ls-ties" ' LS-TIES DOT-CASE

\ A dependency that is done or missing does not block; an active one does.
: READY-TEXT ( -- )
   LISTING
   s" ready" RUN
   0 RC=
   s" [gamma] o Ready with missing dependency
[child] o Nested child
[defaults] o Defaults
[epsilon] o Ready with done dependency
[project] o Project parent
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" ready-text" ' READY-TEXT DOT-CASE

\ ---- find -------------------------------------------------------------------

\ One match per searched field, archived tasks included, case ignored.
: FIND-DESCRIPTION ( -- )
   LISTING
   s" find|IMPLEMENTATION" RUN
   0 RC=
   s\" [alpha] o Alpha login\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" find-description" ' FIND-DESCRIPTION DOT-CASE

: FIND-CLOSE-REASON ( -- )
   LISTING
   s" find|patch" RUN
   0 RC=
   s\" [delta] x Closed root\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" find-close-reason" ' FIND-CLOSE-REASON DOT-CASE

: FIND-CLOSED-AT ( -- )
   LISTING
   s" find|2026-02-04" RUN
   0 RC=
   s\" [old] x Archived AUTH task\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" find-closed-at" ' FIND-CLOSED-AT DOT-CASE

: FIND-CREATED-AT ( -- )
   LISTING
   s" find|2026-01-02" RUN
   0 RC=
   s\" [child] o Nested child\n" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" find-created-at" ' FIND-CREATED-AT DOT-CASE

: FIND-NO-MATCH ( -- )
   LISTING
   s" find|no-match" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" find-no-match" ' FIND-NO-MATCH DOT-CASE

\ Open and active matches, then closed ones, each in ls order.
: FIND-TIES ( -- )
   TIES
   s" find|2026" RUN
   0 RC=
   s" [zero] o Zero
[alpha] o Alpha
[bravo] o Bravo
[bravo] o Nested bravo
[charlie] > Charlie
[foxtrot] o Foxtrot
[hotel] x Hotel
[kilo] x Kilo
[zulu] x Zulu
" OUT=
   s" " ERR=
   TIES-TREE TREE=
;
s" find-ties" ' FIND-TIES DOT-CASE

\ ---- show -------------------------------------------------------------------

: SHOW-ROOT ( -- )
   LISTING
   s" show|alpha" RUN
   0 RC=
   s" ID:       alpha
Title:    Alpha login
Status:   open
Priority: 1
Desc:     Auth implementation
Created:  2026-01-01T00:00:00Z
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" show-root" ' SHOW-ROOT DOT-CASE

: SHOW-PREFIX ( -- )
   LISTING
   s" show|bet" RUN
   0 RC=
   s" ID:       beta
Title:    Beta backend
Status:   active
Priority: 0
Created:  2026-01-01T00:00:00Z
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" show-prefix" ' SHOW-PREFIX DOT-CASE

: SHOW-NESTED ( -- )
   LISTING
   s" show|child" RUN
   0 RC=
   s" ID:       child
Title:    Nested child
Status:   open
Priority: 2
Created:  2026-01-02T00:00:00Z
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" show-nested" ' SHOW-NESTED DOT-CASE

\ An archived task reads as done, with its closing time and reason.
: SHOW-ARCHIVED ( -- )
   LISTING
   s" show|old" RUN
   0 RC=
   s" ID:       old
Title:    Archived AUTH task
Status:   done
Priority: 0
Created:  2026-01-01T00:00:00Z
Closed:   2026-02-04T00:00:00Z
Reason:   Old fix
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" show-archived" ' SHOW-ARCHIVED DOT-CASE

: SHOW-DEFAULTS ( -- )
   LISTING
   s" show|defaults" RUN
   0 RC=
   s" ID:       defaults
Title:    Defaults
Status:   open
Priority: 2
Created:  2026-01-03T00:00:00Z
" OUT=
   s" " ERR=
   LISTING-TREE TREE=
;
s" show-defaults" ' SHOW-DEFAULTS DOT-CASE

\ ---- scalars ----------------------------------------------------------------

\ Quoted values with escapes, a quoted priority, unknown keys and a padded
\ description.
: QUOTED ( -- )
   s" quote.md" s\" ---
title: \"Quotes: \\\"hello\\\" \\t café A\\nB\\rC\\\\E\\qF\"
status: open
priority: \"-8\"
created-at: \"\\\"2026-01-05T00:00:00Z\\\"\"
closed-at: \"\\\"2026-03-01\\\"\"
close-reason: \"Why: \\\"yes\\\"\"
issue-type: feature
assignee: alice
unknown: ignored
---

  two lines
second line\x20\x20
" PUT ;

: QUOTED-TREE ( -- ptr u8 n )
   s\" d .dots
d .dots/archive
f .dots/quote.md
  ---
  title: \"Quotes: \\\"hello\\\" \\t café A\\nB\\rC\\\\E\\qF\"
  status: open
  priority: \"-8\"
  created-at: \"\\\"2026-01-05T00:00:00Z\\\"\"
  closed-at: \"\\\"2026-03-01\\\"\"
  close-reason: \"Why: \\\"yes\\\"\"
  issue-type: feature
  assignee: alice
  unknown: ignored
  ---
\x20\x20
    two lines
  second line\x20\x20
.
" ;

: SHOW-QUOTED ( -- )
   QUOTED
   s" show|quote" RUN
   0 RC=
   s\" ID:       quote
Title:    Quotes: \"hello\" \t café A\nB\rC\\E\\qF
Status:   open
Priority: -8
Desc:     two lines
second line
Created:  2026-01-05T00:00:00Z
Closed:   2026-03-01
Reason:   Why: \"yes\"
" OUT=
   s" " ERR=
   QUOTED-TREE TREE=
;
s" show-quoted" ' SHOW-QUOTED DOT-CASE

: JSON-QUOTED ( -- )
   QUOTED
   s" ls|--json" RUN
   0 RC=
   s\" [{\"id\":\"quote\",\"title\":\"Quotes: \\\"hello\\\" \\t café A\\nB\\rC\\\\E\\\\qF\",\"description\":\"two lines\\nsecond line\",\"status\":\"open\",\"priority\":-8,\"issue_type\":\"feature\",\"created_at\":\"2026-01-05T00:00:00Z\",\"closed_at\":\"2026-03-01\",\"close_reason\":\"Why: \\\"yes\\\"\"}]\n" OUT=
   s" " ERR=
   QUOTED-TREE TREE=
;
s" json-quoted" ' JSON-QUOTED DOT-CASE

\ A created-at that opens a quote and never closes it is kept as written.
: UNTERMINATED-TIMESTAMP ( -- )
   s" un.md" s\" ---\ntitle: Unterminated\nstatus: open\npriority: 2\ncreated-at: \"2026-01-01\n---\n" PUT
   s" show|un" RUN
   0 RC=
   s\" ID:       un\nTitle:    Unterminated\nStatus:   open\nPriority: 2\nCreated:  \"2026-01-01\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/un.md\n  ---\n  title: Unterminated\n  status: open\n  priority: 2\n  created-at: \"2026-01-01\n  ---\n.\n" TREE=
;
s" unterminated-timestamp" ' UNTERMINATED-TIMESTAMP DOT-CASE

: PRIORITY-UNDERSCORE ( -- )
   s" number.md" s\" ---\ntitle: Number\nstatus: open\npriority: 0_2\ncreated-at: 2026-01-01T00:00:00Z\n---\n" PUT
   s" show|number" RUN
   0 RC=
   s\" ID:       number\nTitle:    Number\nStatus:   open\nPriority: 2\nCreated:  2026-01-01T00:00:00Z\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/number.md\n  ---\n  title: Number\n  status: open\n  priority: 0_2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" priority-underscore" ' PRIORITY-UNDERSCORE DOT-CASE

: PRIORITY-LEADING-ZEROS ( -- )
   s" number.md" s\" ---\ntitle: Number\nstatus: open\npriority: 000000000000000000000000000000000000000000000000000000000000000000000000000000002\ncreated-at: 2026-01-01T00:00:00Z\n---\n" PUT
   s" show|number" RUN
   0 RC=
   s\" ID:       number\nTitle:    Number\nStatus:   open\nPriority: 2\nCreated:  2026-01-01T00:00:00Z\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/number.md\n  ---\n  title: Number\n  status: open\n  priority: 000000000000000000000000000000000000000000000000000000000000000000000000000000002\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" priority-leading-zeros" ' PRIORITY-LEADING-ZEROS DOT-CASE

\ An undecodable description lists as its bytes.
: DESCRIPTION-BYTES ( -- )
   s" a.md" s\" ---\ntitle: Bytes\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---\n\nbody\xFF\n" PUT
   s" ls|--json" RUN
   0 RC=
   s\" [{\"id\":\"a\",\"title\":\"Bytes\",\"description\":[98,111,100,121,255],\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" OUT=
   s" " ERR=
   s\" d .dots\nf .dots/a.md\n  ---\n  title: Bytes\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n  \n  body\xFF\n.\nd .dots/archive\n" TREE=
;
s" description-bytes" ' DESCRIPTION-BYTES DOT-CASE

\ ---- malformed files --------------------------------------------------------

: LS-SKIPS-MALFORMED ( -- )
   s" good.md" s" Good" s" open" 2 PUT-ISSUE
   s" plain.md" s\" not frontmatter\n" PUT
   s" mystery.md" s" Bad status" s" mystery" 2 PUT-ISSUE
   s" banana.md" s\" ---\ntitle: Bad priority\nstatus: open\npriority: banana\ncreated-at: 2026-01-01T00:00:00Z\n---\n" PUT
   s" outside.md" s\" ---\ntitle: Bad dependency\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\nblocks:\n  - ../outside\n---\n" PUT
   s" untitled.md" s\" ---\ncreated-at: 2026-01-01\n---\n" PUT
   s" ls" RUN
   0 RC=
   s\" [good] o Good\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/banana.md
  ---
  title: Bad priority
  status: open
  priority: banana
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/good.md
  ---
  title: Good
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/mystery.md
  ---
  title: Bad status
  status: mystery
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/outside.md
  ---
  title: Bad dependency
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - ../outside
  ---
.
f .dots/plain.md
  not frontmatter
.
f .dots/untitled.md
  ---
  created-at: 2026-01-01
  ---
.
" TREE=
;
s" ls-skips-malformed" ' LS-SKIPS-MALFORMED DOT-CASE

: SHOW-INVALID-STATUS ( -- )
   s" mystery.md" s" Bad status" s" mystery" 2 PUT-ISSUE
   s" show|mystery" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue status\n" ERR=
   s\" d .dots\nd .dots/archive\nf .dots/mystery.md\n  ---\n  title: Bad status\n  status: mystery\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" show-invalid-status" ' SHOW-INVALID-STATUS DOT-CASE

\ A dependency id that climbs out of the store.
: SHOW-INVALID-FRONTMATTER ( -- )
   s" outside.md" s\" ---\ntitle: Bad dependency\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\nblocks:\n  - ../outside\n---\n" PUT
   s" show|outside" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s\" d .dots\nd .dots/archive\nf .dots/outside.md\n  ---\n  title: Bad dependency\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  blocks:\n    - ../outside\n  ---\n.\n" TREE=
;
s" show-invalid-frontmatter" ' SHOW-INVALID-FRONTMATTER DOT-CASE

\ A priority reads in decimal.f's grammar, which takes one `_` between digits.
: SHOW-PRIORITY-SEPARATORS ( -- )
   s" number.md" s\" ---\ntitle: Number\nstatus: open\npriority: 1__2\ncreated-at: 2026-01-01T00:00:00Z\n---\n" PUT
   s" show|number" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s\" d .dots\nd .dots/archive\nf .dots/number.md\n  ---\n  title: Number\n  status: open\n  priority: 1__2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" show-priority-separators" ' SHOW-PRIORITY-SEPARATORS DOT-CASE

\ Only a line that is exactly `---`, or `---` and a CR as here, closes the
\ frontmatter; `---tail` below closes nothing, so its file is malformed.
: CLOSING-CRLF ( -- )
   s" delimiter.md" s\" ---\ntitle: Closing CRLF\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---\r\n\nBody\n" PUT
   s" show|delimiter" RUN
   0 RC=
   s\" ID:       delimiter\nTitle:    Closing CRLF\nStatus:   open\nPriority: 2\nDesc:     Body\nCreated:  2026-01-01T00:00:00Z\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/delimiter.md\n  ---\n  title: Closing CRLF\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\r\n  \n  Body\n.\n" TREE=
;
s" closing-crlf" ' CLOSING-CRLF DOT-CASE

\ A closing `---` that is the file's last line, without a final newline.
: CLOSING-LAST-LINE ( -- )
   s" last.md" s\" ---\ntitle: Last\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---" PUT
   s" show|last" RUN
   0 RC=
   s\" ID:       last\nTitle:    Last\nStatus:   open\nPriority: 2\nCreated:  2026-01-01T00:00:00Z\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/last.md\n  ---\n  title: Last\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n\\\n.\n" TREE=
;
s" closing-last-line" ' CLOSING-LAST-LINE DOT-CASE

: CLOSING-TAIL ( -- )
   s" delimiter.md" s\" ---\ntitle: Closing prefix\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---tail\n\nBody\n" PUT
   s" show|delimiter" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s\" d .dots\nd .dots/archive\nf .dots/delimiter.md\n  ---\n  title: Closing prefix\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---tail\n  \n  Body\n.\n" TREE=
;
s" closing-tail" ' CLOSING-TAIL DOT-CASE

: CLOSING-SPACES ( -- )
   s" delimiter.md" s\" ---\ntitle: Closing spaces\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---  \n\nBody\n" PUT
   s" show|delimiter" RUN
   1 RC=
   s" " OUT=
   s\" Invalid issue frontmatter\n" ERR=
   s\" d .dots\nd .dots/archive\nf .dots/delimiter.md\n  ---\n  title: Closing spaces\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---  \n  \n  Body\n.\n" TREE=
;
s" closing-spaces" ' CLOSING-SPACES DOT-CASE

: LS-SKIPS-CLOSING-TAIL ( -- )
   s" good.md" s" Good" s" open" 2 PUT-ISSUE
   s" delimiter.md" s\" ---\ntitle: Closing prefix\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---tail\n\nBody\n" PUT
   s" ls" RUN
   0 RC=
   s\" [good] o Good\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/delimiter.md\n  ---\n  title: Closing prefix\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---tail\n  \n  Body\n.\nf .dots/good.md\n  ---\n  title: Good\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" ls-skips-closing-tail" ' LS-SKIPS-CLOSING-TAIL DOT-CASE

\ ---- entries that are not task files -----------------------------------------

: LS-SKIPS-SYMLINKS ( -- )
   s" alpha.md" s" Alpha" s" open" 1 PUT-ISSUE
   s" project/project.md" s" Project" s" open" 2 PUT-ISSUE
   s" alpha.md" s" link.md" LINK
   s" project" s" linkdir" LINK
   s" ls" RUN
   0 RC=
   s\" [alpha] o Alpha\n[project] o Project\n" OUT=
   s" " ERR=
   s" d .dots
f .dots/alpha.md
  ---
  title: Alpha
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
l .dots/link.md -> alpha.md
l .dots/linkdir -> project
d .dots/project
f .dots/project/project.md
  ---
  title: Project
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" ls-skips-symlinks" ' LS-SKIPS-SYMLINKS DOT-CASE

: SHOW-SYMLINK ( -- )
   s" alpha.md" s" Alpha" s" open" 1 PUT-ISSUE
   s" alpha.md" s" link.md" LINK
   s" show|link" RUN
   1 RC=
   s" " OUT=
   s\" Issue not found: link\n" ERR=
   s\" d .dots\nf .dots/alpha.md\n  ---\n  title: Alpha\n  status: open\n  priority: 1\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\nl .dots/link.md -> alpha.md\n" TREE=
;
s" show-symlink" ' SHOW-SYMLINK DOT-CASE

\ A named pipe is never opened: reading one would block.
: LS-SKIPS-FIFOS ( -- )
   s" a.md" s" A" s" open" 1 PUT-ISSUE
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" pipe.md" PUT-FIFO
   s" p/pipe.md" PUT-FIFO
   s" ls" RUN
   0 RC=
   s\" [a] o A\n[p] o P\n" OUT=
   s" " ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
d .dots/p
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
p .dots/p/pipe.md
p .dots/pipe.md
" TREE=
;
s" ls-skips-fifos" ' LS-SKIPS-FIFOS DOT-CASE

: SHOW-FIFO ( -- )
   s" a.md" s" A" s" open" 1 PUT-ISSUE
   s" pipe.md" PUT-FIFO
   s" show|pipe" RUN
   1 RC=
   s" " OUT=
   s\" Issue not found: pipe\n" ERR=
   s\" d .dots\nf .dots/a.md\n  ---\n  title: A\n  status: open\n  priority: 1\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\np .dots/pipe.md\n" TREE=
;
s" show-fifo" ' SHOW-FIFO DOT-CASE

\ ---- folders ----------------------------------------------------------------

: NESTED-ARCHIVE ( -- )
   s" project/project.md" s" Visible project" s" open" 2 PUT-ISSUE
   s" project/archive/hidden.md" s" Hidden project" s" open" 2 PUT-ISSUE ;

: NESTED-ARCHIVE-TREE ( -- ptr u8 n )
   s" d .dots
d .dots/archive
d .dots/project
d .dots/project/archive
f .dots/project/archive/hidden.md
  ---
  title: Hidden project
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/project/project.md
  ---
  title: Visible project
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" ;

\ Only the store's own `archive` is the archive; a deeper one is not read.
: NESTED-ARCHIVE-LS ( -- )
   NESTED-ARCHIVE
   s" ls" RUN
   0 RC=
   s\" [project] o Visible project\n" OUT=
   s" " ERR=
   NESTED-ARCHIVE-TREE TREE=
;
s" nested-archive-ls" ' NESTED-ARCHIVE-LS DOT-CASE

: NESTED-ARCHIVE-FIND ( -- )
   NESTED-ARCHIVE
   s" find|project" RUN
   0 RC=
   s\" [project] o Visible project\n" OUT=
   s" " ERR=
   NESTED-ARCHIVE-TREE TREE=
;
s" nested-archive-find" ' NESTED-ARCHIVE-FIND DOT-CASE

\ A folder without its owner's file still lists its tasks.
: ORPHAN-FOLDER ( -- )
   s" orphan/kid.md" s" Kid" s" open" 2 PUT-ISSUE
   s" ls" RUN
   0 RC=
   s\" [kid] o Kid\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nd .dots/orphan\nf .dots/orphan/kid.md\n  ---\n  title: Kid\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" orphan-folder" ' ORPHAN-FOLDER DOT-CASE

: NEWLINE-NAME ( -- )
   s\" odd\nname.md" s" Odd name" s" open" 2 PUT-ISSUE
   s" ls|--json" RUN
   0 RC=
   s\" [{\"id\":\"odd\\nname\",\"title\":\"Odd name\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nf .dots/odd\nname.md\n  ---\n  title: Odd name\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE=
;
s" newline-name" ' NEWLINE-NAME DOT-CASE

\ ---- missing store pieces ----------------------------------------------------

\ Reading writes nothing: without `.dots` each read finds no task and creates
\ nothing.
: LS-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" ls" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" " TREE=
;
s" ls-no-store" ' LS-NO-STORE DOT-CASE

: LS-JSON-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" ls|--json" RUN
   0 RC=
   s\" []\n" OUT=
   s" " ERR=
   s" " TREE=
;
s" ls-json-no-store" ' LS-JSON-NO-STORE DOT-CASE

: READY-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" ready" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" " TREE=
;
s" ready-no-store" ' READY-NO-STORE DOT-CASE

: FIND-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" find|A" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" " TREE=
;
s" find-no-store" ' FIND-NO-STORE DOT-CASE

: SHOW-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" show|a" RUN
   1 RC=
   s" " OUT=
   s\" Issue not found: a\n" ERR=
   s" " TREE=
;
s" show-no-store" ' SHOW-NO-STORE DOT-CASE

\ No arguments lists the ready tasks as JSON.
: NO-ARGS-NO-STORE ( -- )
   s" ../.dots" RM-DIR
   s" " RUN
   0 RC=
   s\" []\n" OUT=
   s" " ERR=
   s" " TREE=
;
s" no-args-no-store" ' NO-ARGS-NO-STORE DOT-CASE

\ A store without an archive lists its tasks and creates none.
: LS-NO-ARCHIVE ( -- )
   s" archive" RM-DIR
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" ls" RUN
   0 RC=
   s\" [a] o A\n" OUT=
   s" " ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" ls-no-archive" ' LS-NO-ARCHIVE DOT-CASE

: LS-JSON-NO-ARCHIVE ( -- )
   s" archive" RM-DIR
   s" a.md" s" A" s" open" 2 PUT-ISSUE
   s" ls|--json" RUN
   0 RC=
   s\" [{\"id\":\"a\",\"title\":\"A\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" OUT=
   s" " ERR=
   s" d .dots
f .dots/a.md
  ---
  title: A
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" ls-json-no-archive" ' LS-JSON-NO-ARCHIVE DOT-CASE

\ ---- selective loading and capacity ------------------------------------------

\ show reads only the task it names, not an oversized sibling.
: OVERSIZED-SIBLING-SHOW ( -- )
   BIG-STORE
   s" show|a" RUN
   0 RC=
   s\" ID:       a\nTitle:    A\nStatus:   open\nPriority: 2\nCreated:  2026-01-01T00:00:00Z\n" OUT=
   s" " ERR=
   BIG-STORE-TREE TREE=
;
s" oversized-sibling-show" ' OVERSIZED-SIBLING-SHOW DOT-CASE

\ In a store without legacy folders a mutation reads only the task it changes,
\ not an oversized sibling.
: OVERSIZED-SIBLING-ON ( -- )
   BIG-STORE
   s" on|a" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots\nf .dots/a.md\n  ---\n  title: A\n  status: active\n  priority: 2\n  issue-type: task\n  created-at: \"2026-01-01T00:00:00Z\"\n  ---\n.\nd .dots/archive\n" TREE-FROM
   s" z.md" GEN-FILE GEN$ TREE-FILE
   GEN-TREE GEN$ TREE=
;
s" oversized-sibling-on" ' OVERSIZED-SIBLING-ON DOT-CASE

\ A legacy folder, q's without q's own file, makes a mutation read every task,
\ the oversized sibling included.
: OVERSIZED-SIBLING-ON-LEGACY ( -- )
   BIG-STORE
   s" q/x.md" s" X" s" open" 2 PUT-ISSUE
   s" on|a" RUN
   1 RC=
   s" " OUT=
   s\" Issue file too large: .dots/z.md\n" ERR=
   s\" d .dots\nf .dots/a.md\n  ---\n  title: A\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\nd .dots/q\nf .dots/q/x.md\n  ---\n  title: X\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE-FROM
   s" z.md" GEN-FILE GEN$ TREE-FILE
   GEN-TREE GEN$ TREE=
;
s" oversized-sibling-on-legacy" ' OVERSIZED-SIBLING-ON-LEGACY DOT-CASE

: TOO-LARGE-LS ( -- ) s" ls" TOO-LARGE ;
s" too-large-ls" ' TOO-LARGE-LS DOT-CASE

: TOO-LARGE-LS-JSON ( -- ) s" ls|--json" TOO-LARGE ;
s" too-large-ls-json" ' TOO-LARGE-LS-JSON DOT-CASE

: TOO-LARGE-ON ( -- ) s" on|z" TOO-LARGE ;
s" too-large-on" ' TOO-LARGE-ON DOT-CASE

: TOO-LARGE-OFF ( -- ) s" off|z" TOO-LARGE ;
s" too-large-off" ' TOO-LARGE-OFF DOT-CASE

: TOO-LARGE-UPDATE ( -- ) s" update|z|--status|active" TOO-LARGE ;
s" too-large-update" ' TOO-LARGE-UPDATE DOT-CASE

: TOO-LARGE-CLOSE ( -- ) s" close|z" TOO-LARGE ;
s" too-large-close" ' TOO-LARGE-CLOSE DOT-CASE

\ Closing p reads its child z to see that it is closed.
: TOO-LARGE-CHILD ( -- )
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p/z.md" BIG
   s" off|p" RUN
   1 RC=
   s" " OUT=
   s\" Issue file too large: .dots/p/z.md\n" ERR=
   s\" d .dots\nd .dots/archive\nd .dots/p\nf .dots/p/p.md\n  ---\n  title: P\n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\n" TREE-FROM
   s" p/z.md" GEN-FILE GEN$ TREE-FILE
   GEN-TREE GEN$ TREE=
;
s" too-large-child" ' TOO-LARGE-CHILD DOT-CASE

\ The error names the whole path, past the 1024 bytes a string builder holds.
\ The tree is read with the top folder renamed back to `a`.
: TOO-LARGE-LONG-PATH ( -- )
   GEN-NAME BUF:CLEAR  s" a/" GEN-NAME GEN+  GEN-NAME GEN-BCD+  s" /z.md" GEN-NAME GEN+
   GEN-NAME GEN$ BIG
   true MOVE-TOP
   s" ls" RUN
   1 RC=
   s" " OUT=
   GEN-OUT BUF:CLEAR  s" Issue file too large: .dots/" GEN-OUT GEN+
   [char] a NAME-MAX GEN-OUT GEN-BYTES  s" /" GEN-OUT GEN+  GEN-OUT GEN-BCD+
   s\" /z.md\n" GEN-OUT GEN+
   GEN-OUT GEN$ ERR=
   false MOVE-TOP
   s\" d .dots\nd .dots/a\nd .dots/a/" TREE-FROM  [char] b NAME-MAX GEN-TREE GEN-BYTES
   s\" \nd .dots/a/" GEN-TREE GEN+  [char] b NAME-MAX GEN-TREE GEN-BYTES
   s" /" GEN-TREE GEN+  [char] c NAME-MAX GEN-TREE GEN-BYTES
   s\" \nd .dots/a/" GEN-TREE GEN+  GEN-TREE GEN-BCD+  10 GEN-TREE BUF:APPEND-BYTE
   GEN-NAME GEN$ GEN-FILE GEN$ TREE-FILE
   s\" d .dots/archive\n" GEN-TREE GEN+
   GEN-TREE GEN$ TREE=
;
s" too-large-long-path" ' TOO-LARGE-LONG-PATH DOT-CASE

\ A task file of exactly the limit is read.
: AT-LIMIT ( -- )
   GEN-FILE BUF:CLEAR
   s\" ---\ntitle: Big\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---\n\n" GEN-FILE GEN+
   [char] x ISSUE-LIMIT GEN-FILE GEN$ nip - 1- GEN-FILE GEN-BYTES
   10 GEN-FILE BUF:APPEND-BYTE
   s" big.md" GEN-FILE GEN$ PUT
   s" ls" RUN
   0 RC=
   s\" [big] o Big\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\n" TREE-FROM
   s" big.md" GEN-FILE GEN$ TREE-FILE
   GEN-TREE GEN$ TREE=
;
s" at-limit" ' AT-LIMIT DOT-CASE

: LARGE-DIRECTORY ( -- )
   s\" d .dots\nd .dots/archive\n" TREE-FROM
   GEN-OUT BUF:CLEAR
   MANY 0 ?do
      i 0 GEN-ITEM
      s" [" GEN-OUT GEN+  ITEM-ID GEN-OUT GEN+  s" ] o Item " GEN-OUT GEN+
      i GEN-OUT GEN-NUMBER  10 GEN-OUT BUF:APPEND-BYTE
   loop
   s" ls" RUN
   0 RC=
   GEN-OUT GEN$ OUT=
   s" " ERR=
   GEN-TREE GEN$ TREE=
;
s" large-directory" ' LARGE-DIRECTORY DOT-CASE

: LARGE-JSON ( -- )
   s\" d .dots\nd .dots/archive\n" TREE-FROM
   GEN-OUT BUF:CLEAR
   s" [" GEN-OUT GEN+
   WIDE 0 ?do
      i 0 > if s" ," GEN-OUT GEN+ then
      i WIDE-DESC GEN-ITEM
      s\" {\"id\":\"" GEN-OUT GEN+  ITEM-ID GEN-OUT GEN+
      s\" \",\"title\":\"Item " GEN-OUT GEN+  i GEN-OUT GEN-NUMBER
      s\" \",\"description\":\"" GEN-OUT GEN+  [char] x WIDE-DESC GEN-OUT GEN-BYTES
      s\" \",\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"" GEN-OUT GEN+
      i GEN-OUT GEN-STAMP
      s\" \",\"closed_at\":null,\"close_reason\":null}" GEN-OUT GEN+
   loop
   s\" ]\n" GEN-OUT GEN+
   s" ls|--json" RUN
   0 RC=
   GEN-OUT GEN$ OUT=
   s" " ERR=
   GEN-TREE GEN$ TREE=
;
s" large-json" ' LARGE-JSON DOT-CASE

\ A task more than 512 bytes below `.dots` is read: only the OS path limit
\ applies.
: LONG-PATH ( -- )
   DEEP-NAME
   GEN-NAME GEN$ s" Deep" s" open" 2 PUT-ISSUE
   s" ls" RUN
   0 RC=
   s\" [deep] o Deep\n" OUT=
   s" " ERR=
   s\" d .dots\nd .dots/archive\nd .dots/" TREE-FROM
   [char] x NAME-MAX GEN-TREE GEN-BYTES  s\" \nd .dots/" GEN-TREE GEN+
   GEN-NAME GEN$ 8 - GEN-TREE GEN+  10 GEN-TREE BUF:APPEND-BYTE
   GEN-NAME GEN$ s\" ---\ntitle: Deep\nstatus: open\npriority: 2\ncreated-at: 2026-01-01T00:00:00Z\n---\n" TREE-FILE
   GEN-TREE GEN$ TREE=
;
s" long-path" ' LONG-PATH DOT-CASE

;package
;using

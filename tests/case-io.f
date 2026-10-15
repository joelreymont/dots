\ case-io.f - output and concurrency: what dot does when its stdout is closed,
\ has no reader, is read-only, is read in small pieces or is closed mid-output,
\ and what concurrent writers leave in the store.
require dot.f
using DOT-T
package DOT-IO-CASES

24 constant WRITERS                     \ the most concurrent dots one case starts
create PIDS WRITERS cells allot
create WANT BUF:HDR-BYTES allot         \ an expectation too long for a literal
WANT 256 BUF:N>BLEN BUF:INIT
create LETTER 1 allot

: W+ ( ptr u8 n -- ) BUF:N>BLEN WANT BUF:APPEND-SPAN ;
: W$ ( -- ptr u8 n ) WANT BUF:SPAN$ BUF:BLEN>N ;
: W-INT ( n -- ) SB-RESET FMT:SB-INT SB$ W+ ;

: XS ( n -- )
   0 ?do [char] x WANT BUF:APPEND-BYTE loop ;

: WRITE-FAILED ( -- ptr u8 n )
   s\" I/O error\n" ;

\ Seed `a` with a title of n x's, as one line.
: PUT-LONG ( n -- )
   WANT BUF:CLEAR XS
   s" a.md" W$ s" open" 2 PUT-ISSUE ;

\ The tree PUT-LONG seeded.
: LONG-TREE ( n -- ptr u8 n ) {: n:n :}
   WANT BUF:CLEAR
   s\" d .dots\nf .dots/a.md\n  ---\n  title: " W+ n XS
   s\" \n  status: open\n  priority: 2\n  created-at: 2026-01-01T00:00:00Z\n  ---\n.\nd .dots/archive\n" W+
   W$ ;

: PID! ( pid n -- ) {: pid:pid k:n :}
   pid PID>N k cells PIDS + ! ;

: PID@ ( n -- pid ) {: k:n :}
   k cells PIDS + @ >PID ;

\ Wait for the child, then check it exited 0 with nothing on stderr.
: REAPED ( n -- ) {: k:n :}
   k CHILD k PID@ WAIT
   0 RC=
   s" " ERR= ;

s" io" SECTION

: BROKEN-PIPE-HELP ( -- )
   s" help" RUN-BROKEN
   1 RC=
   WRITE-FAILED ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" broken-pipe-help" ' BROKEN-PIPE-HELP DOT-CASE

\ The add commits the task before its id fails to print.
: BROKEN-PIPE-ADD ( -- )
   s" add|Output failure task" RUN-BROKEN
   1 RC=
   WRITE-FAILED ERR=
   s" ls|--json" RUN  s" A" SAVE-ID
   s\" d .dots
d .dots/archive
f .dots/<A>.md
  ---
  title: Output failure task
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/config
  prefix=broken-pipe-add
.
" TREE=
;
s" broken-pipe-add" ' BROKEN-PIPE-ADD DOT-CASE

: CLOSED-STDOUT-SILENT ( -- )
   s" a.md" s" Seeded task" s" open" 2 PUT-ISSUE
   s" on|a" RUN-CLOSED
   0 RC=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: Seeded task
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;
s" closed-stdout-silent" ' CLOSED-STDOUT-SILENT DOT-CASE

: CLOSED-STDOUT-HELP ( -- )
   s" help" RUN-CLOSED
   1 RC=
   WRITE-FAILED ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" closed-stdout-help" ' CLOSED-STDOUT-HELP DOT-CASE

: READ-ONLY-STDOUT ( -- )
   s" help" RUN-READONLY
   1 RC=
   WRITE-FAILED ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" read-only-stdout" ' READ-ONLY-STDOUT DOT-CASE

\ 100,000 bytes of JSON reach a reader that takes 127 bytes per read.
: SMALL-READS ( -- )
   100000 PUT-LONG
   s" ls|--json" 127 RUN-PIPE
   0 RC=
   WANT BUF:CLEAR
   s\" [{\"id\":\"a\",\"title\":\"" W+ 100000 XS
   s\" \",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" W+
   W$ OUT=
   s" " ERR=
   100000 LONG-TREE TREE=
;
s" small-reads" ' SMALL-READS DOT-CASE

\ The reader closes after 128 of 500,000 bytes.
: READER-HANGS-UP ( -- )
   500000 PUT-LONG
   s" ls|--json" 128 RUN-HANGUP
   1 RC=
   WANT BUF:CLEAR s\" [{\"id\":\"a\",\"title\":\"" W+ 108 XS
   W$ OUT=
   WRITE-FAILED ERR=
   500000 LONG-TREE TREE=
;
s" reader-hangs-up" ' READER-HANGS-UP DOT-CASE

\ Each round, 18 concurrent updates alternately close and reopen `a`; a last
\ reopen then finds the one task file.
: ROUND ( -- )
   18 0 ?do
      i CHILD
      i 2 mod 0<> if s" update|a|--status|done" else s" update|a|--status|open" then
      SPAWN i PID!
   loop
   18 0 ?do i REAPED s" " OUT= loop
   -1 CHILD
   s" update|a|--status|open" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
f .dots/a.md
  ---
  title: Seeded task
  status: open
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
d .dots/archive
" TREE=
;

: ALTERNATING-UPDATES ( -- )
   s" a.md" s" Seeded task" s" open" 2 PUT-ISSUE
   4 0 ?do ROUND loop
;
s" alternating-updates" ' ALTERNATING-UPDATES DOT-CASE

\ 24 concurrent adds each print their own id and write their own file.
: CONCURRENT-ADDS ( -- )
   WRITERS 0 ?do
      i CHILD
      WANT BUF:CLEAR s" add|Concurrent " W+ i W-INT
      W$ SPAWN i PID!
   loop
   WRITERS 0 ?do
      i REAPED
      i [char] A + LETTER c!
      LETTER 1 SAVE-ID
      WANT BUF:CLEAR s" <" W+ LETTER 1 W+ s\" >\n" W+
      W$ OUT=
   loop
   -1 CHILD
   s\" d .dots
d .dots/archive
f .dots/<A>.md
  ---
  title: Concurrent 0
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<B>.md
  ---
  title: Concurrent 1
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<K>.md
  ---
  title: Concurrent 10
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<L>.md
  ---
  title: Concurrent 11
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<M>.md
  ---
  title: Concurrent 12
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<N>.md
  ---
  title: Concurrent 13
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<O>.md
  ---
  title: Concurrent 14
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<P>.md
  ---
  title: Concurrent 15
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<Q>.md
  ---
  title: Concurrent 16
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<R>.md
  ---
  title: Concurrent 17
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<S>.md
  ---
  title: Concurrent 18
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<T>.md
  ---
  title: Concurrent 19
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<C>.md
  ---
  title: Concurrent 2
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<U>.md
  ---
  title: Concurrent 20
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<V>.md
  ---
  title: Concurrent 21
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<W>.md
  ---
  title: Concurrent 22
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<X>.md
  ---
  title: Concurrent 23
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<D>.md
  ---
  title: Concurrent 3
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<E>.md
  ---
  title: Concurrent 4
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<F>.md
  ---
  title: Concurrent 5
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<G>.md
  ---
  title: Concurrent 6
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<H>.md
  ---
  title: Concurrent 7
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<I>.md
  ---
  title: Concurrent 8
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/<J>.md
  ---
  title: Concurrent 9
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
f .dots/config
  prefix=concurrent-adds
.
" TREE=
;
s" concurrent-adds" ' CONCURRENT-ADDS DOT-CASE

\ Four concurrent closes each move their task to the archive.
: CONCURRENT-CLOSES ( -- )
   s" a.md" s" Task A" s" open" 2 PUT-ISSUE
   s" b.md" s" Task B" s" open" 2 PUT-ISSUE
   s" c.md" s" Task C" s" open" 2 PUT-ISSUE
   s" d.md" s" Task D" s" open" 2 PUT-ISSUE
   0 CHILD s" off|a" SPAWN 0 PID!
   1 CHILD s" off|b" SPAWN 1 PID!
   2 CHILD s" off|c" SPAWN 2 PID!
   3 CHILD s" off|d" SPAWN 3 PID!
   4 0 ?do i REAPED s" " OUT= loop
   -1 CHILD
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: Task A
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/b.md
  ---
  title: Task B
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/c.md
  ---
  title: Task C
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
f .dots/archive/d.md
  ---
  title: Task D
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" concurrent-closes" ' CONCURRENT-CLOSES DOT-CASE

;package
;using

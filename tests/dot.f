\ dot.f - the integration harness: each case seeds a store, runs bin/dot in it
\ and states the exact rc, stdout, stderr and resulting `.dots` tree.
\
\ A case is a word of a case file, which DOT-CASE runs under the case's name:
\
\    : QUICK-ADD ( -- )
\       s" Fix the bug" RUN  s" A" SAVE-ID
\       0 RC=  s\" <A>\n" OUT=  s" " ERR=  s\" d .dots\n…" TREE=
\    ;
\    s" quick-add" ' QUICK-ADD DOT-CASE
\
\ DOT-CASE makes a fresh store `<root>/<section>/<name>/` holding `.dots/archive`;
\ the store's name is the case's, so the prefix dot derives from it is too. It
\ runs the word under catch, so a throw fails the case with its code and the run
\ goes on, then prints PASS or FAIL with `<section>/<name>`. RUN's
\ argument is dot's argv with `|` between arguments: `s" add|Fix it|-d|"` is
\ `dot add "Fix it" -d ""`, the empty string no argument at all, and an
\ argument `@A` the id SAVE-ID captured as A. bin/dot runs with the store as
\ its working directory, /dev/null as stdin, stdout and stderr in the files
\ `out` and `err` beside `.dots`, and an environment of PATH, HOME and TZ=UTC
\ only, for at most RUN-MS. TREE$ is the store's `.dots` in byte order, one
\ line per entry: `d <path>`, `l <path> -> <target>`, `p <path>` for any other
\ non-file, and `f <path>` followed by the file's lines, each indented two
\ spaces, a `\` line when the bytes lack a final newline, and a `.` line. Every
\ compared text is masked: each
\ captured id reads `<A>`, `<B>`…, and each generated timestamp
\ (2026-10-15T11:05:55.731062+00:00) reads `<time>`.
require src/lib/errors.f
require src/lib/string.f
require src/lib/byte-buffer.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-list.f
require src/lib/fs-lock.f
require src/lib/process.f
require src/lib/process-argv.f
require src/lib/process-env.f
require src/lib/process-cwd.f
require src/lib/fmt.f
require src/lib/test/runner.f

package DOT-T

10000 constant RUN-MS                   \ the longest one dot command may take
124 constant ARG-SEP                    \ `|` between RUN's arguments
26 constant ID-MAX                      \ ids A through Z
512 constant ID-CAP                     \ main.f refuses a longer id
64 constant NAME-CAP
128 constant LABEL-CAP

create DOT-BUF FS-PATH-CAP allot        \ bin/dot, absolute
variable DOT-U
create STORE-BUF FS-PATH-CAP allot      \ the current case's store
variable STORE-U
create FILE-BUF FS-PATH-CAP allot       \ a path inside the store
variable FILE-U
create WALK-BUF FS-PATH-CAP allot       \ the entry TREE$ visits
variable WALK-U
variable REL-AT                         \ where WALK-BUF's store-relative path starts
FS-PATH-CAP SPAN-BUFFER: LINK-BUF
create SECTION-BUF NAME-CAP allot
variable SECTION-U
create CASE-BUF NAME-CAP allot
variable CASE-U
create LABEL-BUF LABEL-CAP allot
variable LABEL-U
create IDS ID-MAX ID-CAP * allot
create ID-US ID-MAX cells allot
variable RC                             \ the last command's rc; RUN-MS passing is 124
variable EARLY                          \ 1: WAITING already reaped the child
variable EARLY-RC
variable LOCK-FD

create TEXT BUF:HDR-BYTES allot         \ a seeded file's bytes
create SNAP BUF:HDR-BYTES allot         \ TREE$
create MASKED BUF:HDR-BYTES allot       \ the text a check compares
DYNAMIC-BUFFER RAW u8                   \ a file read back
DYNAMIC-BUFFER NAMES u8                 \ the open directories' listings, innermost last
variable NAMES-U

\ ---- text ---------------------------------------------------------------------

: B+ ( ptr u8 n ptr a -- ) {: a:ptr u:n b:ptr :}
   a u BUF:N>BLEN b BUF:APPEND-SPAN ;

: B$ ( ptr a -- ptr u8 n )
   BUF:SPAN$ BUF:BLEN>N ;

: COPY! ( ptr u8 n ptr u8 n ptr n -- ) {: a:ptr u:n dst:ptr cap:n lenp:ptr :}
   u cap > if E-STR-CAPACITY throw then
   a dst u BYTE-COPY
   u lenp ! ;

: JOIN! ( ptr u8 n ptr u8 n ptr u8 ptr n -- ) {: a:ptr u:n b:ptr v:n dst:ptr lenp:ptr :}
   a u b v dst JOIN-PATH lenp ! ;

: STORE$ ( -- ptr u8 n ) STORE-BUF STORE-U @ ;

\ A path inside the store; the next call reuses the buffer.
: FILE$ ( ptr u8 n -- ptr u8 n )
   STORE$ 2swap FILE-BUF FILE-U JOIN!
   FILE-BUF FILE-U @ ;

: DOTS$ ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   SB-RESET s" .dots/" SB-APPEND a u SB-APPEND SB$ FILE$ ;

: READ-FILE ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   a u FILE-SIZE {: size:n :}
   size 1+ RAW-RESERVE
   a u 0 RAW size READ-ALL {: got:n :}
   0 RAW got ;

\ ---- ids and masking ------------------------------------------------------------

: ID-SLOT ( n -- ptr u8 ) {: k:n :}
   k 0 < if E-TBL-BOUNDS throw then
   k ID-MAX >= if E-TBL-BOUNDS throw then
   k ID-CAP * IDS + ;

: ID-U-PTR ( n -- ptr n ) {: k:n :}
   k 0 < if E-TBL-BOUNDS throw then
   k ID-MAX >= if E-TBL-BOUNDS throw then
   k cells ID-US + ;

: ID$ ( n -- ptr u8 n ) {: k:n :}
   k ID-SLOT k ID-U-PTR @ ;

: IDS-RESET ( -- )
   ID-MAX 0 ?do 0 i ID-U-PTR ! loop ;

: LETTER ( ptr u8 n -- n ) {: a:ptr u:n :}
   u 1 <> if E-TBL-BOUNDS throw then
   a c@ [char] A - ;

\ The saved id an argument `@A` names, else the argument itself.
: EXPAND ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   u 2 <> if a u exit then
   a c@ [char] @ <> if a u exit then
   a 1+ 1 LETTER {: k:n :}
   k ID$ dup 0= if E-TBL-BOUNDS throw then ;

\ The saved id the text starts with, or -1.
: ID-AT ( ptr u8 n -- n ) {: a:ptr u:n :}
   ID-MAX 0 ?do
      i ID$ {: id:ptr idu:n :}
      idu 0 > idu u <= and if
         a idu id idu STR= if i unloop exit then
      then
   loop -1 ;

: TIME-SHAPE ( -- ptr u8 n ) s" dddd-dd-ddTdd:dd:dd.dddddd+dd:dd" ;

: TIME-BYTE? ( n n -- bool ) {: c:n want:n :}
   want [char] d = if c STR-DIGIT? exit then
   want [char] + = if c [char] + = c [char] - = or exit then
   c want = ;

\ Whether the text starts with a timestamp dot generates.
: TIME-AT? ( ptr u8 n -- bool ) {: a:ptr u:n :}
   TIME-SHAPE {: shape:ptr shapeu:n :}
   u shapeu < if false exit then
   shapeu 0 ?do
      a i + c@ shape i + c@ TIME-BYTE? 0= if false unloop exit then
   loop true ;

: MASK ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   MASKED BUF:CLEAR
   0 begin dup u < while {: at:n :}
      a at + u at - ID-AT {: k:n :}
      k 0 >= if
         [char] < MASKED BUF:APPEND-BYTE
         k [char] A + MASKED BUF:APPEND-BYTE
         [char] > MASKED BUF:APPEND-BYTE
         at k ID$ nip +
      else a at + u at - TIME-AT? if
         s" <time>" MASKED B+
         at TIME-SHAPE nip +
      else
         a at + c@ MASKED BUF:APPEND-BYTE
         at 1+
      then then
   repeat drop
   MASKED B$ ;

\ ---- the store's tree -----------------------------------------------------------

: WALK$ ( -- ptr u8 n ) WALK-BUF WALK-U @ ;
: REL$ ( -- ptr u8 n ) WALK-BUF REL-AT @ + WALK-U @ REL-AT @ - ;

\ Step into a child of the visited entry; the old length steps back out.
: WALK-PUSH ( ptr u8 n -- n ) {: a:ptr u:n :}
   WALK-U @ {: old:n :}
   old u + 1+ FS-PATH-CAP > if E-FS-CAPACITY throw then
   [char] / WALK-BUF old + c!
   a WALK-BUF old + 1+ u BYTE-COPY
   old u + 1+ WALK-U !
   old ;

: ENTRY ( ptr u8 n -- )
   SNAP B+ s"  " SNAP B+ REL$ SNAP B+ ;

: SNAP-FILE ( -- )
   s" f" ENTRY 10 SNAP BUF:APPEND-BYTE
   WALK$ READ-FILE {: a:ptr u:n :}
   0 begin dup u < while {: from:n :}
      a u 10 from SPLIT-NEXT drop {: line:ptr lineu:n next:n :}
      s"   " SNAP B+ line lineu SNAP B+ 10 SNAP BUF:APPEND-BYTE
      next
   repeat drop
   u 0 > if
      a u + 1- c@ 10 <> if s\" \\\n" SNAP B+ then
   then
   s\" .\n" SNAP B+ ;

: SNAP-LINK ( -- )
   s" l" ENTRY s"  -> " SNAP B+
   WALK$ LINK-BUF READ-LINK {: n:n :}
   LINK-BUF SPAN:$ drop n SNAP B+ 10 SNAP BUF:APPEND-BYTE ;

\ The names of the visited directory, appended to NAMES; answers where they start.
: NAMES-COUNT ( ptr u8 n -- ) nip 1+ NAMES-U +! ;

: LIST ( -- n n )
   NAMES-U @ {: at:n :}
   WALK$ [: NAMES-COUNT ;] FS-LIST:EACH
   NAMES-U @ 1+ NAMES-RESERVE
   WALK$ at NAMES NAMES-U @ at - FS-LIST:NAMES {: n:n :}
   at n + NAMES-U !
   at at n + ;

: SNAP-ENTRY ( -- )
   WALK$ SYMLINK? if SNAP-LINK exit then
   WALK$ FILE? if SNAP-FILE exit then
   WALK$ DIR? 0= if s" p" ENTRY 10 SNAP BUF:APPEND-BYTE exit then
   s" d" ENTRY 10 SNAP BUF:APPEND-BYTE
   LIST {: at:n end:n :}
   at begin dup end < while {: from:n :}
      0 NAMES end 10 from SPLIT-NEXT drop {: name:ptr nameu:n next:n :}
      name nameu WALK-PUSH {: old:n :}
      RECURSE
      old WALK-U !
      next
   repeat drop
   at NAMES-U ! ;

: TREE$ ( -- ptr u8 n )
   SNAP BUF:CLEAR
   0 NAMES-U !
   STORE$ WALK-BUF FS-PATH-CAP WALK-U COPY!
   WALK-U @ 1+ REL-AT !
   s" .dots" WALK-PUSH drop
   WALK$ SYMLINK? WALK$ EXISTS? or if SNAP-ENTRY then
   SNAP B$ ;

\ ---- running dot ----------------------------------------------------------------

\ The parent's value of the variable; the run dies when the parent lacks it.
: ENV-COPY ( ptr u8 n -- ) {: a:ptr u:n :}
   a u GETENV {: v:ptr vu:n :}
   v NULL-PTR = if
      SB-RESET s" tests: the environment lacks " SB-APPEND a u SB-APPEND SB$ 2 die
   then
   a u >LEN v vu >LEN PROC-ENV+ ;

: ARGV+ ( ptr u8 n -- ) {: a:ptr u:n :}
   u 0= if exit then
   a u ARG-SEP 0 begin SPLIT-NEXT while {: arg:ptr argu:n next:n :}
      arg argu EXPAND >LEN PROC-ARGV+
      a u ARG-SEP next
   repeat drop 2drop ;

: OPEN-OUT ( ptr u8 n -- n ) {: a:ptr u:n :}
   a u FILE$ s" " WRITE-ALL
   a u FILE$ OPEN-APPEND-FD ;

: CLOSE ( n -- )
   FS-ATOMIC:CLOSE-FD 0<> if E-FS-IO throw then ;

\ `<section>/<case>`, the name PASS and FAIL lines give.
: CASE$ ( -- ptr u8 n )
   SB-RESET SECTION-BUF SECTION-U @ SB-APPEND [char] / SB-APPEND-C
   CASE-BUF CASE-U @ SB-APPEND SB$ ;

\ A check's name: the case's, then what it compares.
: LABEL ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   CASE$ LABEL-BUF LABEL-CAP LABEL-U COPY!
   LABEL-U @ u + 1+ LABEL-CAP > if E-STR-CAPACITY throw then
   32 LABEL-BUF LABEL-U @ + c!
   a LABEL-BUF LABEL-U @ + 1+ u BYTE-COPY
   LABEL-U @ u + 1+ LABEL-U !
   LABEL-BUF LABEL-U @ ;

public

\ ---- the run --------------------------------------------------------------------

\ The root under $HB_TMP or $TMPDIR and bin/dot from the script's argument.
: START ( -- )
   SCRIPT-ARGC 1 <> if s" usage: hb --load tests/run.f -- bin/dot" 2 die then
   s" dots" GT-START
   0 SCRIPT-ARGV$ {: a:ptr u:n :}
   u 0 > a c@ [char] / = and if
      a u DOT-BUF FS-PATH-CAP DOT-U COPY!
   else
      SOURCE-ROOT:CWD$ a u DOT-BUF DOT-U JOIN!
   then
   DOT-BUF DOT-U @ FILE? 0= if s" tests/run.f: no dot binary at the argument" 2 die then
   TEXT 256 BUF:N>BLEN BUF:INIT
   SNAP 4096 BUF:N>BLEN BUF:INIT
   MASKED 4096 BUF:N>BLEN BUF:INIT ;

\ The report: exit 0 when every case passed, else 2 keeping the root.
: FINISH ( -- )
   GT-FAILURES 0<> if
      GT-ROOT CLEANUP-FORGET
      s" stores kept in " type GT-ROOT type cr
   then
   GT-REPORT ;

: SECTION ( ptr u8 n -- )
   SECTION-BUF NAME-CAP SECTION-U COPY! ;

\ Seed `.dots/<path>` with the bytes.
: PUT ( ptr u8 n ptr u8 n -- ) {: path:ptr pathu:n a:ptr u:n :}
   path pathu DOTS$ {: f:ptr fu:n :}
   fu begin dup 0 > while
      dup 1- f + c@ [char] / = if 1- f swap MAKE-DIRS 0 else 1- then
   repeat drop
   path pathu DOTS$ a u WRITE-ALL ;

\ Seed a task file in the frontmatter dot writes.
: PUT-ISSUE ( ptr u8 n ptr u8 n ptr u8 n n -- )
   {: path:ptr pathu:n title:ptr titleu:n status:ptr statusu:n prio:n :}
   TEXT BUF:CLEAR
   s\" ---\ntitle: " TEXT B+ title titleu TEXT B+
   s\" \nstatus: " TEXT B+ status statusu TEXT B+
   s\" \npriority: " TEXT B+ SB-RESET prio FMT:SB-INT SB$ TEXT B+
   s\" \ncreated-at: 2026-01-01T00:00:00Z\n---\n" TEXT B+
   path pathu TEXT B$ PUT ;

\ Start bin/dot in the store with the |-separated arguments.
: SPAWN ( ptr u8 n -- pid ) {: a:ptr u:n :}
   PROC-ARGV-ENV-RESET
   a u ARGV+
   s" PATH" ENV-COPY
   s" HOME" ENV-COPY
   s" TZ" >LEN s" UTC" >LEN PROC-ENV+
   s" /dev/null" FS-PATHZ open-rd {: in:n :}
   in 0 < if E-FS-OPEN throw then
   s" out" OPEN-OUT {: out:n :}
   s" err" OPEN-OUT {: err:n :}
   DOT-BUF DOT-U @ >LEN STORE$ >LEN in >FD out >FD err >FD
   PROC-CWD:SPAWN-ARGV-ENV-CWD-IO {: pid:pid :}
   in CLOSE out CLOSE err CLOSE
   pid ;

\ Wait for the child, at most RUN-MS, and keep its rc.
: WAIT ( pid -- ) {: pid:pid :}
   EARLY @ 0<> if EARLY-RC @ RC ! 0 EARLY ! exit then
   pid RUN-MS >MS PROC-WAIT-BOUNDED {: o:outcome :}
   o MATCH outcome
      timeout OF
         pid PROC-KILL-TREE
         pid PROC-WAIT-OUTCOME MATCH outcome
            timeout OF ENDOF
            exited OF drop ENDOF
            signaled OF drop ENDOF
         ;MATCH
      ENDOF
      exited OF drop ENDOF
      signaled OF drop ENDOF
   ;MATCH
   o PROC-OUTCOME>DEADLINE-RC RC>N RC ! ;

: RUN ( ptr u8 n -- )
   SPAWN WAIT ;

\ The child is still running after ms: it waits on something the case holds.
: WAITING ( pid n -- pid ) {: pid:pid ms:n :}
   pid ms >MS PROC-WAIT-BOUNDED {: o:outcome :}
   o MATCH outcome
      timeout OF true ENDOF
      exited OF drop false ENDOF
      signaled OF drop false ENDOF
   ;MATCH {: waiting:bool :}
   waiting 0= if o PROC-OUTCOME>DEADLINE-RC RC>N EARLY-RC ! 1 EARLY ! then
   waiting s" waiting" LABEL GT-CHECK
   pid ;

\ Hold, then release, the exclusive lock dot's writers take on the store.
: HOLD ( -- )
   STORE$ FS-LOCK:OPEN-DIR {: fd:fd :}
   fd FS-LOCK:TRY 0= if E-FS-IO throw then
   fd FD>N LOCK-FD ! ;

: RELEASE ( -- )
   LOCK-FD @ CLOSE -1 LOCK-FD ! ;

\ Capture the first stdout line, the id add printed, as the letter's id.
: SAVE-ID ( ptr u8 n -- ) {: la:ptr lu:n :}
   la lu LETTER {: k:n :}
   s" out" FILE$ READ-FILE 10 0 SPLIT-NEXT 2drop {: id:ptr idu:n :}
   idu 0 > idu ID-CAP <= and {: ok:bool :}
   ok s" id" LABEL GT-CHECK
   ok if
      id k ID-SLOT idu BYTE-COPY
      idu k ID-U-PTR !
   then ;

\ Run the case's word on a fresh store, then print PASS or FAIL with its name.
: DOT-CASE ( ptr u8 n [ -- ] -- ) {: a:ptr u:n body :}
   a u CASE-BUF NAME-CAP CASE-U COPY!
   GT-ROOT CASE$ STORE-BUF STORE-U JOIN!
   STORE$ EXISTS? if s" tests: two cases are named " type CASE$ type cr s" tests: duplicate case" 2 die then
   s" .dots/archive" FILE$ MAKE-DIRS
   IDS-RESET
   0 EARLY !
   -1 LOCK-FD !
   GT-FAILURES {: before:n :}
   body catch {: code:n :}
   code 0 s" throw" LABEL GT-CHECK-N
   LOCK-FD @ 0 >= if RELEASE then
   GT-FAILURES before = if s" PASS " else s" FAIL " then type
   CASE$ type cr ;

\ ---- the checks -----------------------------------------------------------------

: RC= ( n -- )
   RC @ swap s" rc" LABEL GT-CHECK-N ;

: OUT= ( ptr u8 n -- ) {: want:ptr wantu:n :}
   s" out" FILE$ READ-FILE MASK want wantu s" stdout" LABEL GT-CHECK$ ;

: ERR= ( ptr u8 n -- ) {: want:ptr wantu:n :}
   s" err" FILE$ READ-FILE MASK want wantu s" stderr" LABEL GT-CHECK$ ;

: TREE= ( ptr u8 n -- ) {: want:ptr wantu:n :}
   TREE$ MASK want wantu s" tree" LABEL GT-CHECK$ ;

;package

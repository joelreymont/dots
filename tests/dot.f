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
\ only, under umask 022, for at most RUN-MS. TREE$ is the store's `.dots` in
\ byte order, one line per entry: `d <path>`, `l <path> -> <target>`,
\ `p <path>` for any other non-file, and `f <path>` followed by the file's
\ lines, each indented two spaces, a `\` line when the bytes lack a final
\ newline, and a `.` line. Every compared text is masked: each captured id
\ reads `<A>`, `<B>`…, and each generated timestamp
\ (2026-10-15T11:05:55.731062+00:00) reads `<time>`.
\
\ A seed's path is relative to `.dots/`; `../<name>` reaches beside it. PUT
\ writes a file and LINK makes a symlink to the target, each making the
\ directories above it; PUT-FIFO makes a named pipe and PUT-ISSUE writes a task
\ in dot's frontmatter. MODE sets permission bits, `.` being `.dots` itself,
\ and RM-DIR removes a directory tree: `s" archive" RM-DIR` leaves a store
\ without an archive. FILE$ is a path beside `.dots` for a Habu fs word no seed
\ covers: `s" .git" FILE$ MAKE-DIRS`. MOVE-TOP reaches a path too deep for
\ FILE$: a case seeds it under `.dots/a` and renames `a` to its long name.
\
\ SAVE-ID captures the id on stdout's first line: the whole line, as add prints
\ it, or the first `"id"` of a JSON line, as `add --json` and `ls --json` print
\ it. ID= states a captured id's text, its eight random hex digits read as
\ `<hex>`: `s" A" s" proj-fix-the-bug-<hex>" ID=`. SAVE-AFTER captures the rest
\ of stdout's first line after a marker, the new id in slugify's `old -> new`
\ line: `s" archive -> " s" A" SAVE-AFTER`.
\
\ RUN-LIMITED runs dot as RUN does under tests/limit.f, which lets it write no
\ byte to any file. RUN-PROBE runs dot as RUN does with tests/probe.c, which
\ the run compiles with `cc` into its root, preloaded: `s" slugify"
\ s" .dots/new.md" s" .dots/old.md" RUN-PROBE` fails dot's no-replace rename
\ to a destination ending `.dots/new.md` with EACCES once `.dots/old.md`, a
\ path from the store, has moved. RUN-PINNED runs dot as RUN does with the
\ probe preloaded and its random bytes pinned, so add's id ends `-5eed1d00`.
\ RUN-NO-GIT runs dot as RUN does with PATH the empty directory `no-git`
\ beside `.dots`, so dot finds no git.
\ GIT runs git in the store as RUN runs dot, so RC=, OUT= and ERR= check git's
\ rc and output. RUN-HB runs `hb --load <script> -- <main.f>`
\ as RUN runs bin/dot, for a probe script that loads dot's source to reach a
\ path no command can. RUN's other variants give dot another stdout:
\ RUN-CLOSED none, fd 1 closed; RUN-BROKEN a pipe with no reader; RUN-READONLY
\ /dev/null opened read-only; `n RUN-PIPE` a pipe the harness reads n bytes at
\ a time to EOF, and `n RUN-HANGUP` one it closes after the first n bytes, both
\ keeping what they read in `out`. SPAWN starts dot and WAIT reaps it, for
\ concurrent writers; after `n CHILD` both and the checks use `out-<n>` and
\ `err-<n>`.
\
\ Beside RC=, OUT=, ERR= and TREE=, MODE= checks a path's permission bits,
\ SAME-LINE that two files hold the same line under a prefix, unmasked, and
\ DIR= a directory beside `.dots` in TREE$'s form.
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
require src/lib/engine-id.f
require src/lib/fmt.f
require src/lib/test/runner.f

package DOT-T

10000 constant RUN-MS                   \ the longest one dot command may take
124 constant ARG-SEP                    \ `|` between RUN's arguments
26 constant ID-MAX                      \ ids A through Z
512 constant ID-CAP                     \ main.f refuses a longer id
8 constant HEX-U                        \ the random hex digits ending a new id
64 constant NAME-CAP
128 constant LABEL-CAP
$12 constant UMASK                      \ 022: dot creates files rw-r--r--
$1FF constant PERMISSIONS               \ a mode's rwxrwxrwx bits

create DOT-BUF FS-PATH-CAP allot        \ bin/dot, absolute
variable DOT-U
create LIMIT-BUF FS-PATH-CAP allot      \ tests/limit.f, absolute
variable LIMIT-U
create PROBE-BUF FS-PATH-CAP allot      \ the library cc builds from tests/probe.c
variable PROBE-U
create CC-BUF FS-PATH-CAP allot         \ cc, resolved on PATH
create GIT-BUF FS-PATH-CAP allot        \ git, resolved on PATH
create STORE-BUF FS-PATH-CAP allot      \ the current case's store
variable STORE-U
create FILE-BUF FS-PATH-CAP allot       \ a path inside the store
variable FILE-U
create REPO-BUF FS-PATH-CAP allot       \ a path inside the repository
variable REPO-U
create HB-BUF FS-PATH-CAP allot         \ the installed hb, absolute
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
variable CHILD-K                        \ -1: `out` and `err`; else `out-<n>` and `err-<n>`
128 constant CHUNK-CAP                  \ the most one read of a pipe asks for
create CHUNK CHUNK-CAP allot

create TEXT BUF:HDR-BYTES allot         \ a seeded file's bytes, or what a pipe gave
create SNAP BUF:HDR-BYTES allot         \ TREE$
create MASKED BUF:HDR-BYTES allot       \ the text a check compares
DYNAMIC-BUFFER RAW u8                   \ a file read back
DYNAMIC-BUFFER NAMES u8                 \ the open directories' names, each NUL-ended, innermost last
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

\ A path inside the repository, the directory the run started in; the next
\ call reuses the buffer.
: REPO$ ( ptr u8 n -- ptr u8 n )
   SOURCE-ROOT:CWD$ 2swap REPO-BUF REPO-U JOIN!
   REPO-BUF REPO-U @ ;

: DOTS$ ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   SB-RESET s" .dots/" SB-APPEND a u SB-APPEND SB$ FILE$ ;

\ Make the directories above the path.
: PARENTS ( ptr u8 n -- ) {: f:ptr fu:n :}
   fu begin dup 0 > while
      dup 1- f + c@ [char] / = if 1- f swap MAKE-DIRS 0 else 1- then
   repeat drop ;

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

: JSON-ID-KEY ( -- ptr u8 n ) s\" {\"id\":\"" ;

\ The id a line of dot's output names: the first `id` of a JSON line, as in
\ `{"id":"…"` and `[{"id":"…"`, empty when unterminated, else the whole line.
\ The ids dot makes need no JSON escape.
: LINE-ID ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   a u s" [" STARTS-WITH? if 1 else 0 then {: list:n :}
   a list + u list - JSON-ID-KEY STARTS-WITH? 0= if a u exit then
   list JSON-ID-KEY nip + {: at:n :}
   a at + u at - [char] " INDEX-OF MATCH option
      none OF a 0 ENDOF
      some OF IDX>N {: end:n :} a at + end ENDOF
   ;MATCH ;

: HEX-BYTE? ( n -- bool ) {: c:n :}
   c STR-DIGIT? c [char] a >= c [char] f <= and or ;

\ Whether the text ends in HEX-U lowercase hex digits, a new id's random part.
: HEX-TAIL? ( ptr u8 n -- bool ) {: a:ptr u:n :}
   u HEX-U < if false exit then
   HEX-U 0 ?do
      a u + HEX-U - i + c@ HEX-BYTE? 0= if false unloop exit then
   loop true ;

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

\ Append the name, NUL-ended: a name holds any byte but NUL and `/`.
: NAME+ ( ptr u8 n -- ) {: a:ptr u:n :}
   NAMES-U @ {: at:n :}
   at u + 1+ NAMES-RESERVE
   a 0 NAMES at + u BYTE-COPY
   0 0 NAMES at u + + c!
   at u + 1+ NAMES-U ! ;

\ The names of the visited directory, appended to NAMES; answers where they
\ start and end.
: LIST ( -- n n )
   NAMES-U @ {: at:n :}
   WALK$ [: NAME+ ;] FS-LIST:EACH
   at NAMES-U @ ;

: NAME@ ( n -- ptr u8 n ) {: at:n :}
   0 NAMES at + {: a:ptr :}
   0 begin a over + c@ 0<> while 1+ repeat {: u:n :}
   a u ;

variable BEST

\ The offset of the name at or after at, before end, that follows the one at
\ prev (-1: none) in byte order; -1 when no name follows it.
: NEXT-NAME ( n n n -- n ) {: at:n end:n prev:n :}
   -1 BEST !
   at begin dup end < while {: from:n :}
      prev 0 < if true else prev NAME@ from NAME@ STR< then
      if
         BEST @ 0 < if true else from NAME@ BEST @ NAME@ STR< then
         if from BEST ! then
      then
      from NAME@ nip 1+ from +
   repeat drop
   BEST @ ;

: SNAP-ENTRY ( -- )
   WALK$ SYMLINK? if SNAP-LINK exit then
   WALK$ FILE? if SNAP-FILE exit then
   WALK$ DIR? 0= if s" p" ENTRY 10 SNAP BUF:APPEND-BYTE exit then
   s" d" ENTRY 10 SNAP BUF:APPEND-BYTE
   LIST {: at:n end:n :}
   -1 begin at end rot NEXT-NAME dup 0 >= while {: name:n :}
      name NAME@ WALK-PUSH {: old:n :}
      RECURSE
      old WALK-U !
      name
   repeat drop
   at NAMES-U ! ;

: SNAP$ ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   SNAP BUF:CLEAR
   0 NAMES-U !
   STORE$ WALK-BUF FS-PATH-CAP WALK-U COPY!
   WALK-U @ 1+ REL-AT !
   a u WALK-PUSH drop
   WALK$ SYMLINK? WALK$ EXISTS? or if SNAP-ENTRY then
   SNAP B$ ;

: TREE$ ( -- ptr u8 n ) s" .dots" SNAP$ ;

\ The text's first line that starts with the prefix, else an empty span.
: LINE-AT ( ptr u8 n ptr u8 n -- ptr u8 n ) {: a:ptr u:n p:ptr pu:n :}
   0 begin dup u < while {: from:n :}
      a u 10 from SPLIT-NEXT drop {: line:ptr lineu:n next:n :}
      lineu pu >= if
         line pu p pu STR= if line lineu exit then
      then
      next
   repeat drop
   a 0 ;

PROCESS-SYMBOLS
FUNCTION: MKFIFO-CALL mkfifo ( ptr u8 n -- i32 ) ;FUNCTION
FUNCTION: SET-UMASK umask ( n -- n ) ;FUNCTION
420 constant FIFO-MODE                  \ 0644

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

\ The stream's file, `out` or `err`, suffixed with CHILD's number.
: STREAM$ ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   SB-RESET a u SB-APPEND
   CHILD-K @ 0 >= if [char] - SB-APPEND-C CHILD-K @ FMT:SB-INT then
   SB$ FILE$ ;

: OPEN-OUT ( ptr u8 n -- n ) {: a:ptr u:n :}
   a u STREAM$ s" " WRITE-ALL
   a u STREAM$ OPEN-APPEND-FD ;

: OPEN-NULL ( -- n )
   s" /dev/null" FS-PATHZ open-rd {: fd:n :}
   fd 0 < if E-FS-OPEN throw then
   fd ;

: CLOSE ( n -- )
   FS-ATOMIC:CLOSE-FD 0<> if E-FS-IO throw then ;

\ Start the program in the store with the argv and PATH PROC-ARGV+ and PROC-ENV+
\ built and the fd as its stdout, which LAUNCH-PATHED closes once the child
\ holds it; -1 gives the child the harness's own. stdin is /dev/null and
\ stderr the `err` file.
: LAUNCH-PATHED ( ptr u8 n n -- pid ) {: prog:ptr progu:n out:n :}
   s" HOME" ENV-COPY
   s" TZ" >LEN s" UTC" >LEN PROC-ENV+
   OPEN-NULL {: in:n :}
   s" err" OPEN-OUT {: err:n :}
   prog progu >LEN STORE$ >LEN in >FD out >FD err >FD
   PROC-CWD:SPAWN-ARGV-ENV-CWD-IO {: pid:pid :}
   in CLOSE err CLOSE
   out 0 >= if out CLOSE then
   pid ;

\ LAUNCH-PATHED with the parent's PATH.
: LAUNCH ( ptr u8 n n -- pid )
   s" PATH" ENV-COPY LAUNCH-PATHED ;

\ Make dot's argv the |-separated arguments; answers bin/dot for LAUNCH.
: DOT-ARGV ( ptr u8 n -- ptr u8 n )
   PROC-ARGV-ENV-RESET
   ARGV+
   DOT-BUF DOT-U @ ;

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

: FIRST-LINE$ ( -- ptr u8 n )
   s" out" STREAM$ READ-FILE 10 0 SPLIT-NEXT 2drop ;

\ Keep the text as the letter's id; an empty or oversized one fails the case.
: KEEP-ID ( ptr u8 n ptr u8 n -- ) {: id:ptr idu:n la:ptr lu:n :}
   la lu LETTER {: k:n :}
   idu 0 > idu ID-CAP <= and {: ok:bool :}
   ok s" id" LABEL GT-CHECK
   ok if
      id k ID-SLOT idu BYTE-COPY
      idu k ID-U-PTR !
   then ;

\ Build tests/probe.c into the run's root with cc; the run dies without cc,
\ since no other suite covers what RUN-PROBE and RUN-PINNED do.
: BUILD-PROBE ( -- )
   s" cc" >LEN CC-BUF FIND-EXECUTABLE MATCH option
      none OF s" tests/run.f: no cc on PATH to build tests/probe.c" 2 die ENDOF
      some OF LEN>N ENDOF
   ;MATCH {: ccu:n :}
   GT-ROOT HB-TARGET-MACOS? if s" probe.dylib" else s" probe.so" then
   PROBE-BUF PROBE-U JOIN!
   SOURCE-ROOT:CURRENT$ s" probe.c" REPO-BUF REPO-U JOIN!
   PROC-ARGV-RESET
   HB-TARGET-MACOS? if
      s" -dynamiclib" >LEN PROC-ARGV+
   else
      s" -shared" >LEN PROC-ARGV+  s" -fPIC" >LEN PROC-ARGV+
   then
   s" -o" >LEN PROC-ARGV+
   PROBE-BUF PROBE-U @ >LEN PROC-ARGV+
   REPO-BUF REPO-U @ >LEN PROC-ARGV+
   HB-TARGET-MACOS? 0= if s" -ldl" >LEN PROC-ARGV+ then
   CC-BUF ccu >LEN -1 >FD -1 >FD -1 >FD PROC-RUN-ARGV-IO-RC MATCH result
      ok OF drop ENDOF
      err OF drop s" tests/run.f: cc failed to build tests/probe.c" 2 die ENDOF
   ;MATCH ;

\ Preload the probe into the next LAUNCH.
: PRELOAD ( -- )
   HB-TARGET-MACOS? if s" DYLD_INSERT_LIBRARIES" else s" LD_PRELOAD" then
   >LEN PROBE-BUF PROBE-U @ >LEN PROC-ENV+ ;

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
   SOURCE-ROOT:CURRENT$ s" limit.f" LIMIT-BUF LIMIT-U JOIN!
   LIMIT-BUF LIMIT-U @ FILE? 0= if s" tests/run.f: no tests/limit.f beside it" 2 die then
   BUILD-PROBE
   UMASK SET-UMASK drop
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
   path pathu DOTS$ PARENTS
   path pathu DOTS$ a u WRITE-ALL ;

\ Seed `.dots/<path>` as a symlink to the target.
: LINK ( ptr u8 n ptr u8 n -- ) {: target:ptr targetu:n path:ptr pathu:n :}
   path pathu DOTS$ PARENTS
   target targetu path pathu DOTS$ MAKE-SYMLINK ;

\ Make `.dots/<path>` a named pipe.
: PUT-FIFO ( ptr u8 n -- )
   DOTS$ FS-PATHZ FIFO-MODE MKFIFO-CALL 0<> if E-FS-IO throw then ;

\ Set the permission bits of `.dots/<path>`; `.` is `.dots` itself.
: MODE ( ptr u8 n n -- ) {: path:ptr pathu:n mode:n :}
   path pathu DOTS$ mode CHMOD-MODE ;

\ Remove the directory tree `.dots/<path>`.
: RM-DIR ( ptr u8 n -- )
   DOTS$ REMOVE-TREE ;

\ Seed a task file in the frontmatter dot writes.
: PUT-ISSUE ( ptr u8 n ptr u8 n ptr u8 n n -- )
   {: path:ptr pathu:n title:ptr titleu:n status:ptr statusu:n prio:n :}
   TEXT BUF:CLEAR
   s\" ---\ntitle: " TEXT B+ title titleu TEXT B+
   s\" \nstatus: " TEXT B+ status statusu TEXT B+
   s\" \npriority: " TEXT B+ SB-RESET prio FMT:SB-INT SB$ TEXT B+
   s\" \ncreated-at: 2026-01-01T00:00:00Z\n---\n" TEXT B+
   path pathu TEXT B$ PUT ;

\ A path beside `.dots` for a Habu fs word no seed covers.
EXPORT FILE$

\ A deep path, such as the 1015-byte `.dots/<255 a>/<255 b>/<255 c>/<236 d>/p.md`,
\ would pass FS-PATH-CAP joined to the store's absolute path, so FILE$ cannot
\ form it. A case seeds it with the top folder `.dots/a`, `true MOVE-TOP`
\ renames that to its long name, NAME-MAX `a`s, before dot runs, and
\ `false MOVE-TOP` renames it back before the tree is read. TOP$ is the top
\ folder, long or short; D-NAME is the 1015-byte path's last folder's length.
255 constant NAME-MAX                   \ the longest name a folder can have
236 constant D-NAME                     \ the deep path's last folder name
create TOP BUF:HDR-BYTES allot          \ the deep path's top folder
TOP 512 BUF:N>BLEN BUF:INIT
create HELD BUF:HDR-BYTES allot         \ one store path while FILE$ forms another
HELD 1024 BUF:N>BLEN BUF:INIT
: TOP$ ( bool -- ptr u8 n ) {: long:bool :}
   TOP BUF:CLEAR s" .dots/" TOP B+
   long if NAME-MAX else 1 then 0 ?do [char] a TOP BUF:APPEND-BYTE loop
   TOP B$ ;
: MOVE-TOP ( bool -- ) {: long:bool :}
   HELD BUF:CLEAR long 0= TOP$ FILE$ HELD B+
   HELD B$ long TOP$ FILE$ RENAME-FILE ;

create LONG BUF:HDR-BYTES allot         \ a long path, or the tree holding it
LONG 1024 BUF:N>BLEN BUF:INIT
: L+ ( ptr u8 n -- ) BUF:N>BLEN LONG BUF:APPEND-SPAN ;
: L$ ( -- ptr u8 n ) LONG BUF:SPAN$ BUF:BLEN>N ;
: L-BYTES ( n n -- ) {: c:n k:n :} k 0 ?do c LONG BUF:APPEND-BYTE loop ;
\ Append `<255 x's>/<255 y's>`, a folder 511 bytes below its root.
: DEEP+ ( -- ) [char] x NAME-MAX L-BYTES s" /" L+ [char] y NAME-MAX L-BYTES ;
\ Append `<255 b>/<255 c>/<n d>`, a deep parent's folders below the top.
: BCD+ ( n -- ) {: du:n :}
   [char] b NAME-MAX L-BYTES s" /" L+ [char] c NAME-MAX L-BYTES
   s" /" L+ [char] d du L-BYTES ;

\ Start bin/dot in the store with the |-separated arguments.
: SPAWN ( ptr u8 n -- pid )
   DOT-ARGV s" out" OPEN-OUT LAUNCH ;

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

\ RUN under tests/limit.f, run by this hb.
: RUN-LIMITED ( ptr u8 n -- )
   PROC-ARGV-ENV-RESET
   s" --load" >LEN PROC-ARGV+
   LIMIT-BUF LIMIT-U @ >LEN PROC-ARGV+
   s" --" >LEN PROC-ARGV+
   DOT-BUF DOT-U @ >LEN PROC-ARGV+
   ARGV+
   ENGINE-ID:PATH$ s" out" OPEN-OUT LAUNCH WAIT ;

\ RUN with tests/probe.c preloaded: dot's no-replace rename to a destination
\ ending with dst fails with EACCES once the path `moved`, from the store, has
\ moved.
: RUN-PROBE ( ptr u8 n ptr u8 n ptr u8 n -- ) {: a:ptr u:n dst:ptr du:n moved:ptr mu:n :}
   a u DOT-ARGV {: prog:ptr progu:n :}
   PRELOAD
   s" DOTS_PROBE_RENAME" >LEN dst du >LEN PROC-ENV+
   s" DOTS_PROBE_MOVED" >LEN moved mu >LEN PROC-ENV+
   prog progu s" out" OPEN-OUT LAUNCH WAIT ;

\ RUN with tests/probe.c preloaded and the random bytes pinned: add's id ends
\ `-5eed1d00`.
: RUN-PINNED ( ptr u8 n -- )
   DOT-ARGV {: prog:ptr progu:n :}
   PRELOAD
   s" DOTS_PROBE_RANDOM" >LEN s" 5eed1d00" >LEN PROC-ENV+
   prog progu s" out" OPEN-OUT LAUNCH WAIT ;

\ RUN with PATH the empty directory `no-git` beside `.dots`: dot finds no git.
: RUN-NO-GIT ( ptr u8 n -- )
   DOT-ARGV {: prog:ptr progu:n :}
   s" no-git" FILE$ MAKE-DIRS
   s" PATH" >LEN s" no-git" FILE$ >LEN PROC-ENV+
   prog progu s" out" OPEN-OUT LAUNCH-PATHED WAIT ;

\ Run git in the store with the |-separated arguments as RUN runs dot.
: GIT ( ptr u8 n -- ) {: a:ptr u:n :}
   s" git" >LEN GIT-BUF RESOLVE-EXECUTABLE LEN>N {: gu:n :}
   PROC-ARGV-ENV-RESET
   a u ARGV+
   GIT-BUF gu s" out" OPEN-OUT LAUNCH WAIT ;

\ Run `hb --load <script> -- <main.f>` in the store as RUN runs bin/dot, the
\ script a path from the repository root: a probe that loads dot's source.
: RUN-HB ( ptr u8 n -- ) {: a:ptr u:n :}
   PROC-ARGV-ENV-RESET
   s" --load" >LEN PROC-ARGV+
   a u REPO$ >LEN PROC-ARGV+
   s" --" >LEN PROC-ARGV+
   s" main.f" REPO$ >LEN PROC-ARGV+
   s" hb" >LEN HB-BUF RESOLVE-EXECUTABLE LEN>N {: hbu:n :}
   HB-BUF hbu s" out" OPEN-OUT LAUNCH WAIT ;

private

\ Run bin/dot with its stdout a pipe the harness reads at most chunk bytes at a
\ time into `out`, closing its end after max bytes, or at EOF when max is -1.
: READ-PIPE ( ptr u8 n n n -- ) {: a:ptr u:n chunk:n max:n :}
   chunk 1 < chunk CHUNK-CAP > or if E-STR-CAPACITY throw then
   PIPE-PAIR {: rd:fd wr:fd :}
   rd FD-CLOEXEC!
   a u DOT-ARGV wr FD>N LAUNCH {: pid:pid :}
   TEXT BUF:CLEAR
   0 begin {: total:n :}
      max 0 < if chunk else max total - chunk min then {: want:n :}
      want 0 > if rd FD>N CHUNK want read else 0 then {: got:n :}
      got 0 < if E-FS-IO throw then
      CHUNK got TEXT B+
      total got +  got 0=
   until drop
   rd FD>N CLOSE
   pid WAIT
   s" out" STREAM$ TEXT B$ WRITE-ALL ;

public

\ Run bin/dot with fd 1 closed: the harness's own stdout, close-on-exec while
\ dot starts.
: RUN-CLOSED ( ptr u8 n -- )
   1 >FD FD-CLOEXEC!
   DOT-ARGV -1 LAUNCH {: pid:pid :}
   1 F-SETFD 0 fcntl 0<> if E-FS-IO throw then
   pid WAIT ;

\ Run bin/dot with its stdout a pipe whose read end is already closed.
: RUN-BROKEN ( ptr u8 n -- ) {: a:ptr u:n :}
   PIPE-PAIR {: rd:fd wr:fd :}
   rd FD>N CLOSE
   a u DOT-ARGV wr FD>N LAUNCH WAIT ;

\ Run bin/dot with its stdout /dev/null opened read-only.
: RUN-READONLY ( ptr u8 n -- )
   DOT-ARGV OPEN-NULL LAUNCH WAIT ;

\ Run bin/dot with its stdout a pipe the harness reads chunk bytes at a time
\ to EOF, keeping the bytes in `out`.
: RUN-PIPE ( ptr u8 n n -- )
   -1 READ-PIPE ;

\ Run bin/dot with its stdout a pipe the harness closes after reading n bytes,
\ which `out` keeps.
: RUN-HANGUP ( ptr u8 n n -- ) {: a:ptr u:n max:n :}
   a u CHUNK-CAP max READ-PIPE ;

\ Later SPAWNs, RUNs and checks use `out-<n>` and `err-<n>`; -1 restores `out`
\ and `err`, as each case starts.
: CHILD ( n -- )
   CHILD-K ! ;

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

\ Capture the id add printed on its first stdout line as the letter's id.
: SAVE-ID ( ptr u8 n -- ) {: la:ptr lu:n :}
   FIRST-LINE$ LINE-ID la lu KEEP-ID ;

\ Capture the rest of the first stdout line after the marker as the letter's id.
: SAVE-AFTER ( ptr u8 n ptr u8 n -- ) {: m:ptr mu:n la:ptr lu:n :}
   FIRST-LINE$ {: line:ptr lineu:n :}
   line lineu m mu STARTS-WITH? if
      line mu + lineu mu - la lu KEEP-ID
   else line 0 la lu KEEP-ID then ;

\ Run the case's word on a fresh store, then print PASS or FAIL with its name.
: DOT-CASE ( ptr u8 n [ -- ] -- ) {: a:ptr u:n body :}
   a u CASE-BUF NAME-CAP CASE-U COPY!
   GT-ROOT CASE$ STORE-BUF STORE-U JOIN!
   STORE$ EXISTS? if s" tests: two cases are named " type CASE$ type cr s" tests: duplicate case" 2 die then
   s" .dots/archive" FILE$ MAKE-DIRS
   IDS-RESET
   -1 CHILD-K !
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
   s" out" STREAM$ READ-FILE MASK want wantu s" stdout" LABEL GT-CHECK$ ;

: ERR= ( ptr u8 n -- ) {: want:ptr wantu:n :}
   s" err" STREAM$ READ-FILE MASK want wantu s" stderr" LABEL GT-CHECK$ ;

: TREE= ( ptr u8 n -- ) {: want:ptr wantu:n :}
   TREE$ MASK want wantu s" tree" LABEL GT-CHECK$ ;

\ The letter's captured id is the text, `<hex>` standing for its random part.
: ID= ( ptr u8 n ptr u8 n -- ) {: la:ptr lu:n want:ptr wantu:n :}
   la lu LETTER ID$ {: id:ptr idu:n :}
   MASKED BUF:CLEAR
   id idu HEX-TAIL? if
      id idu HEX-U - MASKED B+ s" <hex>" MASKED B+
   else id idu MASKED B+ then
   MASKED B$ want wantu s" id-text" LABEL GT-CHECK$ ;

\ The snapshot of a directory beside `.dots`, named as the store sees it.
: DIR= ( ptr u8 n ptr u8 n -- ) {: a:ptr u:n want:ptr wantu:n :}
   a u SNAP$ MASK want wantu s" dir" LABEL GT-CHECK$ ;

: MODE= ( ptr u8 n n -- ) {: a:ptr u:n want:n :}
   a u DOTS$ STAT-MODE PERMISSIONS and want s" mode" LABEL GT-CHECK-N ;

\ `.dots/<a>` and `.dots/<b>` hold the same line under the prefix, unmasked:
\ two times one command wrote.
: SAME-LINE ( ptr u8 n ptr u8 n ptr u8 n -- ) {: a:ptr u:n b:ptr v:n p:ptr pu:n :}
   a u DOTS$ READ-FILE p pu LINE-AT {: x:ptr xu:n :}
   xu 0 > s" line" LABEL GT-CHECK
   TEXT BUF:CLEAR x xu TEXT B+
   b v DOTS$ READ-FILE p pu LINE-AT TEXT B$ s" same line" LABEL GT-CHECK$ ;

;package

\ limit.f - run dot unable to write a byte to any file:
\    hb --load tests/limit.f -- <dot> <arg>…
\ The launcher lowers its own RLIMIT_FSIZE soft limit to 0 and ignores SIGXFSZ;
\ dot inherits both, so every write it makes to a file fails with EFBIG while
\ it can still create, rename and remove entries. dot's stdout and stderr are
\ pipes, which the limit does not reach. Once dot exits the launcher restores
\ its limit, copies dot's output to its own stdout and stderr, and exits with
\ dot's rc. Only this process carries the limit, never the harness.
require src/lib/errors.f
require src/lib/string.f
require src/lib/process.f
require src/lib/process-argv.f
require src/lib/fd-io.f

package DOT-LIMIT

1 constant RLIMIT-FSIZE                 \ the same on macOS and Linux
25 constant SIGXFSZ                     \ the same on macOS and Linux
1 constant SIG-IGN
16 constant RLIMIT-BYTES                \ rlim_cur, then rlim_max
10000 constant RUN-MS
65536 constant CAP

PROCESS-SYMBOLS
FUNCTION: GET-LIMIT getrlimit ( n ptr u8 -- i32 )
   1 16 WRITES-BYTES
;FUNCTION
FUNCTION: SET-LIMIT setrlimit ( n ptr u8 -- i32 ) ;FUNCTION
FUNCTION: SET-SIGNAL signal ( n n -- n ) ;FUNCTION

create SAVED RLIMIT-BYTES allot
create NO-WRITES RLIMIT-BYTES allot
create OUT CAP allot
create ERR CAP allot

: LIMIT! ( ptr u8 -- )
   RLIMIT-FSIZE swap SET-LIMIT 0<> if E-FS-IO throw then ;

\ The saved limit with a soft limit of 0; the hard limit stays, so the launcher
\ can restore the soft one.
: LOWER ( -- )
   RLIMIT-FSIZE SAVED GET-LIMIT 0<> if E-FS-IO throw then
   SAVED NO-WRITES RLIMIT-BYTES BYTE-COPY
   8 0 ?do 0 NO-WRITES i + c! loop
   SIGXFSZ SIG-IGN SET-SIGNAL -1 = if E-FS-IO throw then
   NO-WRITES LIMIT! ;

public

: LAUNCH ( -- )
   SCRIPT-ARGC 1 < if s" usage: hb --load tests/limit.f -- <dot> <arg>..." 2 die then
   PROC-ARGV-RESET
   SCRIPT-ARGC 1 ?do i SCRIPT-ARGV$ >LEN PROC-ARGV+ loop
   LOWER
   0 SCRIPT-ARGV$ >LEN OUT CAP >LEN ERR CAP >LEN RUN-MS >MS
   RUN-ARGV-CAPTURE-OUTCOME {: outu:len erru:len o:outcome :}
   SAVED LIMIT!
   1 >FD OUT outu LEN>N FD-IO:WRITE-FULL
   2 >FD ERR erru LEN>N FD-IO:WRITE-FULL
   o PROC-OUTCOME>DEADLINE-RC RC>N {: rc:n :}
   rc 0<> if s" " rc die then ;

;package

DOT-LIMIT:LAUNCH

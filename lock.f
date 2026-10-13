\ Serialize dot writers before they load any issue state. The current directory
\ exists even for `dot init`, and locking it leaves no persistent lock file.
require lib/fs.f
require lib/process.f
require lib/ffi-abi.f

package DOT-LOCK
PROCESS-SYMBOLS
FUNCTION: FLOCK-CALL flock ( n n -- i32 ) ;FUNCTION

public
: ACQUIRE ( -- )
   s" ." FS-PATHZ 0 0 open {: fd:n :}
   fd 0 < if s" Cannot lock current directory" 1 die then
   fd >FD FD-CLOEXEC!
   fd 2 FLOCK-CALL 0<> if s" Cannot lock current directory" 1 die then ;
;package

\ Checked CLI output: partial writes continue; failed writes are fatal.
require src/lib/process.f
require src/lib/fmt.f

package DOT-IO
create CHAR-BUF 1 allot
variable OUTPUT-READY
: WRITE-FAIL ( -- )
   s" I/O error" 1 die ;
: INIT-OUTPUT ( -- )
   OUTPUT-READY @ if exit then
   [: 1 >FD FD-NOSIGPIPE! ;] catch 0<> if WRITE-FAIL then
   1 OUTPUT-READY ! ;
public
: PRINT ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 0= if exit then
   INIT-OUTPUT
   0 begin dup u < while
      {: at:n :}
      1 a at + u at - write {: written:n :}
      written 0 <= if WRITE-FAIL then
      at written +
   repeat drop ;
: PRINT-BYTE ( n -- ) CHAR-BUF c! CHAR-BUF 1 PRINT ;
: NL ( -- ) 10 PRINT-BYTE ;
: PRINTLN ( ptr u8 n -- ) PRINT NL ;
: INT ( n -- ) SB-RESET FMT:SB-INT SB$ PRINT ;
;package

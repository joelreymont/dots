\ Native, filesystem-compatible dots CLI for the full size comparison.
require lib/errors.f
require lib/string.f
require lib/fs.f
require lib/fs-mutate.f
require lib/fs-list.f
require lib/process-env.f
require lib/json-write.f
require lib/json-read.f
require lib/fmt.f
require abbrev.f

package DOT-READ

1048576 constant FILE-CAP
512 constant MAX-DEPTH
31 constant REC-CELLS

0 constant F-ID
1 constant F-TITLE
2 constant F-DESC
3 constant F-TYPE
4 constant F-CREATED
5 constant F-CLOSED
6 constant F-REASON
7 constant F-BLOCKS
8 constant F-ASSIGNEE
9 constant F-PATH
10 constant F-PARENT
22 constant F-STATUS
23 constant F-PRIORITY
24 constant F-ARCHIVED
25 constant F-ERROR
26 constant F-CHILD
27 constant F-REASON-PRESENT
28 constant F-ASSIGNEE-PRESENT
29 constant F-CLOSED-PRESENT
30 constant F-PARENT-PRESENT

DYNAMIC-BUFFER RECORDS n
DYNAMIC-BUFFER ARENA u8
variable ARENA-U
variable ISSUE-N
create FILE-BUF FILE-CAP allot
variable FILE-U
DYNAMIC-BUFFER BLOCK-BUF u8
create NUM-BUF 32 allot
variable NUM-U
variable NUM-DIGIT
variable NUM-SIG
variable NUM-START
create PATHS MAX-DEPTH FS-PATH-CAP * allot
DYNAMIC-BUFFER SCAN-NAMES u8
variable SCAN-NAMES-U
create JSON-OUT-BUF BUF:HDR-BYTES allot
TYPED-VARIABLE JSON-W JSON-WRITE:writer
variable CURRENT
variable VALID
variable BLOCK-ON
variable BLOCK-U
variable DECODE-U
variable FILTER
variable USE-JSON
variable WANT-READY
PTR-VARIABLE QUERY-A
variable QUERY-U
variable FIRST
variable MATCH-I
variable SORT-TMP
variable SCAN-NAME-ONLY
create TARGET-PATH FS-PATH-CAP allot
create TARGET-ID 129 allot
DYNAMIC-BUFFER ORDER n

: FAIL ( ptr u8 n -- ) 1 die ;
: CAP-FAIL ( -- ) s" Capacity exceeded" FAIL ;
: ISSUE-ERROR ( ptr u8 n ptr u8 n -- )
   {: prefix:ptr pu:n id:ptr iu:n :}
   SB-RESET prefix pu SB-APPEND id iu SB-APPEND SB$ FAIL ;

: REC-CELL ( n n -- ptr n )
   {: idx:n field:n :}
   idx REC-CELLS * field + RECORDS ;
: FIELD$ ( n n -- ptr u8 n )
   {: idx:n field:n :}
   idx field 2 * REC-CELL @ ARENA idx field 2 * 1+ REC-CELL @ ;
: FIELD! ( ptr u8 n n n -- )
   {: a:ptr u:n idx:n field:n :}
   \ A field may be copied from this arena. Growth remaps it, so retain its
   \ offset and reacquire the source after reserve.
   ARENA-U @ 0 > if
      a NULL-PTR BYTE-VIEW - {: addr:n :}
      0 ARENA NULL-PTR BYTE-VIEW - {: base:n :}
      addr base >= addr base ARENA-U @ + < and if
         addr base - {: off:n :}
         ARENA-U @ u + 1+ ARENA-RESERVE
         ARENA-U @ idx field 2 * REC-CELL !
         u idx field 2 * 1+ REC-CELL !
         off ARENA ARENA-U @ ARENA u BYTE-COPY
         ARENA-U @ u + ARENA-U ! exit
      then
   then
   ARENA-U @ u + 1+ ARENA-RESERVE
   ARENA-U @ idx field 2 * REC-CELL !
   u idx field 2 * 1+ REC-CELL !
   a ARENA-U @ ARENA u BYTE-COPY
   ARENA-U @ u + ARENA-U ! ;
: FIELD-EMPTY ( n n -- )
   {: idx:n field:n :}
   ARENA-U @ idx field 2 * REC-CELL !
   0 idx field 2 * 1+ REC-CELL ! ;
: PATH-AT ( n -- ptr u8 ) FS-PATH-CAP * PATHS + ;
: PATH-JOIN ( ptr u8 n ptr u8 n ptr u8 -- n ) JOIN-PATH ;
: PATH-SLASHES ( n -- n )
   F-PATH FIELD$ {: path:ptr pu:n :}
   0 pu 0 ?do path i + c@ 47 = if 1+ then loop ;
: NEXT-LINE ( ptr u8 n n -- ptr u8 n n bool ) 10 swap SPLIT-NEXT ;

: STATUS>DISPLAY ( n -- ptr u8 n )
   dup 0 = if drop s" open" exit then
   dup 1 = if drop s" active" exit then
   drop s" done" ;
: STATUS>CHAR ( n -- n )
   dup 0 = if drop 111 exit then
   dup 1 = if drop 62 exit then
   drop 120 ;
: PARSE-STATUS ( ptr u8 n -- n )
   2dup s" open" STR= if 2drop 0 exit then
   2dup s" active" STR= if 2drop 1 exit then
   2dup s" closed" STR= if 2drop 2 exit then
   2dup s" done" STR= if 2drop 2 exit then
   2drop -1 ;

\ Decode precisely the escape repertoire used by upstream scalar YAML.
: DECODE ( ptr u8 n -- ptr u8 n )
   {: a:ptr u:n :}
   u 2 < if a u exit then
   a c@ 34 <> a u 1- + c@ 34 <> or if a u exit then
   a 1+ {: src:ptr :}
   u 2 - {: size:n :}
   0 DECODE-U !
   0 begin dup size < while
      {: at:n :}
      src at + c@ 92 = at 1+ size < and if
         src at 1+ + c@ {: esc:n :}
         esc 110 = if 10 else
         esc 114 = if 13 else
         esc 116 = if 9 else
         esc 34 = if 34 else
         esc 92 = if 92 else -1 then then then then then
         {: val:n :}
         val -1 = if
            92 src DECODE-U @ + c! 1 DECODE-U +!
            esc src DECODE-U @ + c! 1 DECODE-U +!
         else val src DECODE-U @ + c! 1 DECODE-U +! then
         at 2 +
      else
         src at + c@ src DECODE-U @ + c! 1 DECODE-U +!
         at 1+
      then
   repeat drop
   src DECODE-U @ ;
: QUOTED? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   u 2 < if false exit then
   a c@ 34 = a u 1- + c@ 34 = and ;
: TIMESTAMP-DECODE ( ptr u8 n -- ptr u8 n )
   DECODE
   begin 2dup QUOTED? while DECODE repeat ;

: BLOCK-ADD ( ptr u8 n -- )
   {: a:ptr u:n :}
   BLOCK-U @ u + 1+ BLOCK-BUF-RESERVE
   a BLOCK-U @ BLOCK-BUF u BYTE-COPY
   10 BLOCK-U @ u + BLOCK-BUF c!
   BLOCK-U @ u 1+ + BLOCK-U ! ;
: DIGIT? ( n -- bool ) dup 48 >= swap 57 <= and ;
: NUM-APPEND ( n -- bool )
   NUM-U @ 32 >= if drop false exit then
   NUM-BUF NUM-U @ + c! 1 NUM-U +! true ;
: NORMALIZE-PRIORITY ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   0 NUM-U ! 0 NUM-DIGIT ! 0 NUM-SIG !
   u 0= if false exit then
   0 NUM-START !
   a c@ 45 = if 45 NUM-APPEND drop 1 NUM-START ! then
   a c@ 43 = if 1 NUM-START ! then
   NUM-START @ u >= if false exit then
   NUM-START @ begin dup u < while
      {: at:n :}
      a at + c@ {: ch:n :}
      ch 95 = if
         at NUM-START @ = at 1+ u >= or if false exit then
      else
         ch DIGIT? 0= if false exit then
         1 NUM-DIGIT !
         ch 48 <> NUM-SIG @ 0<> or if
            1 NUM-SIG ! ch NUM-APPEND 0= if false exit then
         then
      then
      at 1+
   repeat drop
   NUM-DIGIT @ 0= if false exit then
   NUM-SIG @ 0= if 48 NUM-APPEND 0= if false exit then then
   true ;
: PARSE-PRIORITY ( ptr u8 n -- option<n> )
   NORMALIZE-PRIORITY if NUM-BUF NUM-U @ STR>NUMBER? else OPTION:NONE then ;
: VALID-ID? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   u 0= u 128 > or if false exit then
   a u s" ." STR= if false exit then
   u 0 ?do
      a i + c@ {: ch:n :}
      ch 32 < ch 127 = or if false unloop exit then
      ch 47 = ch 92 = or ch 35 = or ch 58 = or if false unloop exit then
      ch 39 = ch 34 = or if false unloop exit then
      ch 46 = i 1+ u < and if
         a i 1+ + c@ 46 = if false unloop exit then
      then
   loop true ;
: SET-SCALAR ( ptr u8 n ptr u8 n -- )
   {: key:ptr ku:n raw:ptr ru:n :}
   key ku s" created-at" STR= if raw ru TIMESTAMP-DECODE CURRENT @ F-CREATED FIELD! exit then
   key ku s" closed-at" STR= if
      raw ru TIMESTAMP-DECODE 2dup CURRENT @ F-CLOSED FIELD!
      nip 0 > if 1 CURRENT @ F-CLOSED-PRESENT REC-CELL ! then exit
   then
   raw ru DECODE {: val:ptr vu:n :}
   key ku s" title" STR= if val vu CURRENT @ F-TITLE FIELD! exit then
   key ku s" status" STR= if
      val vu PARSE-STATUS dup -1 = if drop 2 VALID ! else CURRENT @ F-STATUS REC-CELL ! then exit
   then
   key ku s" priority" STR= if
      val vu PARSE-PRIORITY MATCH option
         none OF 1 VALID ! ENDOF
         some OF CURRENT @ F-PRIORITY REC-CELL ! ENDOF
      ;MATCH exit
   then
   key ku s" issue-type" STR= if val vu CURRENT @ F-TYPE FIELD! exit then
   key ku s" assignee" STR= if
      val vu CURRENT @ F-ASSIGNEE FIELD!
      vu 0 > if 1 CURRENT @ F-ASSIGNEE-PRESENT REC-CELL ! then exit
   then
   key ku s" close-reason" STR= if
      vu 0 > if
         val vu CURRENT @ F-REASON FIELD!
         1 CURRENT @ F-REASON-PRESENT REC-CELL !
      else
         CURRENT @ F-REASON FIELD-EMPTY
         0 CURRENT @ F-REASON-PRESENT REC-CELL !
      then exit
   then
   key ku s" blocks" STR= if 1 BLOCK-ON ! then ;

: TRIM-SPACES ( ptr u8 n -- ptr u8 n )
   {: a:ptr u:n :}
   0 begin
      dup u < if a over + c@ 32 = else false then
   while 1+
   repeat {: first:n :}
   u begin
      dup first > if a over 1- + c@ 32 = else false then
   while 1-
   repeat
   first - a first + swap ;

: PARSE-LINE ( ptr u8 n -- )
   VALID @ 0<> if 2drop exit then
   TRIM {: line:ptr lu:n :}
   BLOCK-ON @ 0<> if
      line lu s" - " STARTS-WITH? if
         line 2 + lu 2 - TRIM 2dup VALID-ID? 0= if 1 VALID ! then BLOCK-ADD exit
      then
      lu 0= if exit then
      0 BLOCK-ON !
   then
   line lu 58 INDEX-OF MATCH option
      none OF ENDOF
      some OF {: col:idx :}
         line col IDX>N line col IDX>N 1+ + lu col IDX>N 1+ - TRIM-SPACES SET-SCALAR
      ENDOF
   ;MATCH ;

: FRONT-END ( -- n )
   FILE-U @ 3 - 4 ?do
      FILE-BUF i + c@ 10 = if
         FILE-BUF i 1+ + c@ 45 =
         FILE-BUF i 2 + + c@ 45 = and
         FILE-BUF i 3 + + c@ 45 = and if i unloop exit then
      then
   loop -1 ;

: PARSE-FILE ( ptr u8 n ptr u8 n bool bool -- )
   {: path:ptr pu:n id:ptr iu:n archived:bool child:bool :}
   ISSUE-N @ 1+ REC-CELLS * RECORDS-RESERVE
   ISSUE-N @ 1+ ORDER-RESERVE
   ISSUE-N @ CURRENT !
   0 VALID ! 0 BLOCK-ON ! 0 BLOCK-U !
   id iu CURRENT @ F-ID FIELD!
   path pu CURRENT @ F-PATH FIELD!
   CURRENT @ F-TITLE FIELD-EMPTY
   CURRENT @ F-DESC FIELD-EMPTY
   s" task" CURRENT @ F-TYPE FIELD!
   CURRENT @ F-CREATED FIELD-EMPTY
   CURRENT @ F-CLOSED FIELD-EMPTY
   CURRENT @ F-REASON FIELD-EMPTY
   0 CURRENT @ F-REASON-PRESENT REC-CELL !
   CURRENT @ F-ASSIGNEE FIELD-EMPTY
   0 CURRENT @ F-ASSIGNEE-PRESENT REC-CELL !
   0 CURRENT @ F-CLOSED-PRESENT REC-CELL !
   CURRENT @ F-PARENT FIELD-EMPTY
   0 CURRENT @ F-PARENT-PRESENT REC-CELL !
   0 CURRENT @ F-STATUS REC-CELL !
   2 CURRENT @ F-PRIORITY REC-CELL !
   archived if 1 else 0 then CURRENT @ F-ARCHIVED REC-CELL !
   child if 1 else 0 then CURRENT @ F-CHILD REC-CELL !
   1 CURRENT @ F-ERROR REC-CELL !
   ISSUE-N @ 1+ ISSUE-N !
   SCAN-NAME-ONLY @ 0<> if exit then
   path pu FILE-SIZE FILE-CAP > if
      s" Unexpected internal error (code: StreamTooLong)" FAIL
   then
   path pu FILE-BUF FILE-CAP READ-ALL FILE-U !
   FILE-BUF FILE-U @ 0 NEXT-LINE {: head:ptr hu:n off:n more:bool :}
   head hu s" ---" STR= 0= if exit then
   more 0= if exit then
   FRONT-END dup -1 = if drop exit then {: endpos:n :}
   FILE-BUF endpos 4 + + FILE-U @ endpos 4 + - TRIM CURRENT @ F-DESC FIELD!
   off begin dup endpos < while
      {: pos:n :}
      FILE-BUF endpos pos NEXT-LINE drop {: line:ptr lu:n next:n :}
      line lu PARSE-LINE
      next
   repeat drop
   BLOCK-U @ 0 > if
      0 BLOCK-BUF BLOCK-U @ CURRENT @ F-BLOCKS FIELD!
   else CURRENT @ F-BLOCKS FIELD-EMPTY then
   VALID @ 0<> if VALID @ CURRENT @ F-ERROR REC-CELL ! exit then
   CURRENT @ F-TITLE FIELD$ nip 0= if exit then
   CURRENT @ F-CREATED FIELD$ nip 0= if exit then
   0 CURRENT @ F-ERROR REC-CELL ! ;

: FILE-ENTRY? ( ptr u8 n -- bool )
   {: name:ptr u:n :}
   u 3 < if false exit then
   name u s" .md" ENDS-WITH? ;

: GATHER-SCAN-NAME ( ptr u8 n -- )
   {: a:ptr u:n :}
   SCAN-NAMES-U @ u + 2 + SCAN-NAMES-RESERVE
   u 256 mod SCAN-NAMES-U @ SCAN-NAMES c!
   u 256 / SCAN-NAMES-U @ 1+ SCAN-NAMES c!
   a SCAN-NAMES-U @ 2 + SCAN-NAMES u BYTE-COPY
   SCAN-NAMES-U @ u 2 + + SCAN-NAMES-U ! ;

\ A separate names and path buffer per level permits recursive scans.
: SCAN-DIR ( n n bool -- )
   {: depth:n plen:n archived:bool :}
   depth MAX-DEPTH 1- >= if CAP-FAIL then
   depth PATH-AT {: path:ptr :}
   SCAN-NAMES-U @ {: begin-at:n :}
   path plen [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   begin-at begin dup end-at < while
      {: at:n :}
      at SCAN-NAMES c@ at 1+ SCAN-NAMES c@ 256 * + {: nu:n :}
      at 2 + SCAN-NAMES {: name:ptr :}
      at nu 2 + + {: next:n :}
      name nu s" archive" STR= if
         next
      else
         path plen name nu depth 1+ PATH-AT PATH-JOIN {: child-u:n :}
         \ Upstream's scan path is relative to the active/archive directory
         \ and is formatted into a 512-byte array.
         child-u archived if 14 else 6 then - 512 >= if
            s" I/O error" FAIL
         then
         depth 1+ PATH-AT {: child:ptr :}
         child child-u SYMLINK? if next else
            child child-u FILE? name nu FILE-ENTRY? and if
               depth 0 > if
                  path plen BASENAME name nu 3 - STR= 0=
               else false then {: is-child:bool :}
               child child-u name nu 3 - archived is-child PARSE-FILE
               is-child if path plen BASENAME CURRENT @ F-PARENT FIELD! then
            else
               child child-u DIR? if depth 1+ child-u archived RECURSE then
            then
            next
         then
      then
   repeat drop ;

: LOAD-ISSUES ( bool -- )
   {: include-archive:bool :}
   0 ISSUE-N ! 0 ARENA-U ! 0 SCAN-NAMES-U !
   s" .dots/archive" MAKE-DIRS
   s" .dots" 0 PATH-AT swap BYTE-COPY
   0 s" .dots" nip false SCAN-DIR
   include-archive if
      s" .dots/archive" DIR? if
         s" .dots/archive" 0 PATH-AT swap BYTE-COPY
         0 s" .dots/archive" nip true SCAN-DIR
      then
   then ;
: LOAD-TARGET ( n -- n )
   {: idx:n :}
   idx F-ID FIELD$ VALID-ID? 0= if s" Invalid issue id" FAIL then
   idx F-ARCHIVED REC-CELL @ 0<> idx F-CHILD REC-CELL @ 0<> and if
      s" Issue not found: " 1 script-argv$ ISSUE-ERROR
   then
   idx PATH-SLASHES 11 > if s" Issue not found: " 1 script-argv$ ISSUE-ERROR then
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   idx F-ID FIELD$ {: id:ptr iu:n :}
   path TARGET-PATH pu BYTE-COPY
   id TARGET-ID iu BYTE-COPY
   0 SCAN-NAME-ONLY !
   TARGET-PATH pu TARGET-ID iu
   idx F-ARCHIVED REC-CELL @ 0<>
   idx F-CHILD REC-CELL @ 0<> PARSE-FILE
   ISSUE-N @ 1- ;

: BYTE-LESS? ( ptr u8 n ptr u8 n -- bool )
   {: a:ptr au:n b:ptr bu:n :}
   au bu min 0 ?do
      a i + c@ b i + c@ <> if a i + c@ b i + c@ < unloop exit then
   loop
   au bu < ;
: ISSUE-LESS? ( n n -- bool )
   {: a:n b:n :}
   a F-PRIORITY REC-CELL @ b F-PRIORITY REC-CELL @ <> if
      a F-PRIORITY REC-CELL @ b F-PRIORITY REC-CELL @ < exit
   then
   a F-CREATED FIELD$ b F-CREATED FIELD$ BYTE-LESS? ;
: SORT-ISSUES ( -- )
   ISSUE-N @ ORDER-RESERVE
   ISSUE-N @ 0 ?do i i ORDER ! loop
   ISSUE-N @ 1 ?do
      i begin dup 0 > while
         dup ORDER @ over 1- ORDER @ ISSUE-LESS? if
            dup ORDER @ SORT-TMP !
            dup 1- ORDER @ over ORDER !
            SORT-TMP @ over 1- ORDER ! 1-
         else drop 0 then
      repeat drop
   loop ;

: BLOCKED? ( n -- bool )
   F-BLOCKS FIELD$ {: a:ptr u:n :}
   0 begin dup u < while
      {: at:n :}
      a u at NEXT-LINE drop {: block:ptr bu:n next:n :}
      ISSUE-N @ 0 ?do
         i F-ARCHIVED REC-CELL @ 0= i F-ERROR REC-CELL @ 0= and if
            i F-ID FIELD$ block bu STR= if
               i F-STATUS REC-CELL @ 2 <> if true unloop exit then
            then
         then
      loop
      next
   repeat drop false ;
: READY? ( n -- bool )
   dup F-ARCHIVED REC-CELL @ 0<> if drop false exit then
   dup F-STATUS REC-CELL @ 0<> if drop false exit then
   BLOCKED? 0= ;
: SHOW-IN-LIST? ( n -- bool )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if false exit then
   idx F-ARCHIVED REC-CELL @ 0<> if false exit then
   WANT-READY @ 0<> if idx READY? exit then
   FILTER @ -1 <> if idx F-STATUS REC-CELL @ FILTER @ = exit then
   idx F-STATUS REC-CELL @ 2 <> ;

: JSON-FIELD-S ( ptr writer n n ptr u8 n -- ptr writer )
   {: w:ptr idx:n field:n key:ptr ku:n :}
   w key ku idx field FIELD$ JSON-WRITE:FIELD-S ;
: JSON-FIELD-OPT ( ptr writer n n ptr u8 n -- ptr writer )
   {: w:ptr idx:n field:n key:ptr ku:n :}
   field F-CLOSED = if
      idx F-CLOSED-PRESENT REC-CELL @ 0= if w key ku JSON-WRITE:FIELD-NULL exit then
   else
      idx field FIELD$ nip 0= if w key ku JSON-WRITE:FIELD-NULL exit then
   then
   w key ku idx field FIELD$ JSON-WRITE:FIELD-S ;
: JSON-FIELD-REASON ( ptr writer n -- ptr writer )
   {: w:ptr idx:n :}
   idx F-REASON-PRESENT REC-CELL @ 0= if
      w s" close_reason" JSON-WRITE:FIELD-NULL
   else
      w s" close_reason" idx F-REASON FIELD$ JSON-WRITE:FIELD-S
   then ;
: JSON-ISSUE ( ptr writer n -- ptr writer )
   {: w:ptr idx:n :}
   w JSON-WRITE:OBJECT-START
   idx F-ID s" id" JSON-FIELD-S JSON-WRITE:COMMA
   idx F-TITLE s" title" JSON-FIELD-S JSON-WRITE:COMMA
   idx F-DESC s" description" JSON-FIELD-OPT JSON-WRITE:COMMA
   s" status" JSON-WRITE:KEY idx F-STATUS REC-CELL @ STATUS>DISPLAY JSON-WRITE:STRING JSON-WRITE:COMMA
   s" priority" idx F-PRIORITY REC-CELL @ JSON-WRITE:FIELD-INT JSON-WRITE:COMMA
   idx F-TYPE s" issue_type" JSON-FIELD-S JSON-WRITE:COMMA
   idx F-CREATED s" created_at" JSON-FIELD-S JSON-WRITE:COMMA
   idx F-CLOSED s" closed_at" JSON-FIELD-OPT JSON-WRITE:COMMA
   idx JSON-FIELD-REASON
   JSON-WRITE:OBJECT-END ;
: PRINT-ISSUE ( n -- )
   {: idx:n :}
   s" [" type idx F-ID FIELD$ type s" ] " type
   idx F-STATUS REC-CELL @ STATUS>CHAR emit 32 emit
   idx F-TITLE FIELD$ type cr ;
: PRINT-LIST ( -- )
   SORT-ISSUES
   USE-JSON @ 0<> if
      JSON-OUT-BUF 1024 BUF:N>BLEN BUF:INIT
      JSON-W JSON-OUT-BUF JSON-WRITE:OPEN-BUF JSON-WRITE:ARRAY-START
      0 FIRST !
      ISSUE-N @ 0 ?do
         i ORDER @ SHOW-IN-LIST? if
            FIRST @ 0<> if JSON-WRITE:COMMA then
            i ORDER @ JSON-ISSUE
            1 FIRST !
         then
      loop
      JSON-WRITE:ARRAY-END dup JSON-WRITE:$ type cr JSON-WRITE:CLOSE
      JSON-OUT-BUF BUF:DISPOSE
   else
      ISSUE-N @ 0 ?do i ORDER @ dup SHOW-IN-LIST? if PRINT-ISSUE else drop then loop
   then ;

: CONTAINS-CI? ( ptr u8 n ptr u8 n -- bool )
   {: a:ptr au:n q:ptr qu:n :}
   qu au > if false exit then
   au qu - 1+ 0 ?do
      a i + qu q qu STR=CI if true unloop exit then
   loop false ;
: MATCHES? ( n -- bool )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if false exit then
   idx F-TITLE FIELD$ QUERY-A @ QUERY-U @ CONTAINS-CI? if true exit then
   idx F-DESC FIELD$ QUERY-A @ QUERY-U @ CONTAINS-CI? if true exit then
   idx F-REASON FIELD$ QUERY-A @ QUERY-U @ CONTAINS-CI? if true exit then
   idx F-CREATED FIELD$ QUERY-A @ QUERY-U @ CONTAINS-CI? if true exit then
   idx F-CLOSED FIELD$ QUERY-A @ QUERY-U @ CONTAINS-CI? ;
: PRINT-FIND ( -- )
   ISSUE-N @ 0 ?do
      i F-STATUS REC-CELL @ 2 <> if i dup MATCHES? if PRINT-ISSUE else drop then then
   loop
   ISSUE-N @ 0 ?do
      i F-STATUS REC-CELL @ 2 = if i dup MATCHES? if PRINT-ISSUE else drop then then
   loop ;

: RESOLVE ( ptr u8 n -- n )
   {: prefix:ptr pu:n :}
   -1 MATCH-I !
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ prefix pu STARTS-WITH? if
         MATCH-I @ -1 <> if s" Ambiguous ID: " prefix pu ISSUE-ERROR then
         i MATCH-I !
      then
   loop
   MATCH-I @ -1 = if s" Issue not found: " prefix pu ISSUE-ERROR then
   MATCH-I @ ;
: SHOW ( n -- )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> idx F-CHILD REC-CELL @ 0<> and if
      s" Issue not found: " 1 script-argv$ ISSUE-ERROR
   then
   idx F-ERROR REC-CELL @ 2 = if s" Invalid issue status" FAIL then
   idx F-ERROR REC-CELL @ 0<> if s" Invalid issue frontmatter" FAIL then
   s" ID:       " type idx F-ID FIELD$ type cr
   s" Title:    " type idx F-TITLE FIELD$ type cr
   s" Status:   " type idx F-STATUS REC-CELL @ STATUS>DISPLAY type cr
   s" Priority: " type idx F-PRIORITY REC-CELL @ FMT:.INT cr
   idx F-DESC FIELD$ dup 0<> if s" Desc:     " type type cr else 2drop then
   s" Created:  " type idx F-CREATED FIELD$ type cr
   idx F-CLOSED FIELD$ dup 0<> if s" Closed:   " type type cr else 2drop then
   idx F-REASON-PRESENT REC-CELL @ 0<> if
      s" Reason:   " type idx F-REASON FIELD$ type cr
   then ;

: ARG= ( ptr u8 n ptr u8 n -- bool ) STR= ;
: USAGE ( -- )
   s" dots - Connect the dots" type cr cr
   s" Usage: dot [command] [options]" type cr cr
   s" Commands:" type cr
   s"   dot " type 34 emit s" title" type 34 emit s"                   Quick add a dot" type cr
   s"   dot add " type 34 emit s" title" type 34 emit s"  [options]    Add a dot (-p priority, -d desc, -P parent, -a after)" type cr
   s"   dot ls [--status S] [--json] List dots" type cr
   s"   dot on <id>                  Start working (turn it on!)" type cr
   s"   dot off <id> [-r reason]     Complete (" type 34 emit s" cross it off" type 34 emit s" )" type cr
   s"   dot rm <id>                  Remove a dot" type cr
   s"   dot show <id>                Show dot details" type cr
   s"   dot ready [--json]           Show unblocked dots" type cr
   s"   dot tree [id]                Show hierarchy (with id: includes closed children)" type cr
   s"   dot fix                      Repair missing parents" type cr
   s"   dot find " type 34 emit s" query" type 34 emit s"              Search all dots (open first, then archived)" type cr
   s"   dot purge                    Delete archived dots" type cr
   s"   dot init                     Initialize .dots directory" type cr cr
   s" Examples:" type cr
   s"   dot " type 34 emit s" Fix the bug" type 34 emit cr
   s"   dot add " type 34 emit s" Design API" type 34 emit s"  -p 1 -d " type 34 emit s" REST endpoints" type 34 emit cr
   s"   dot add " type 34 emit s" Implement" type 34 emit s"  -P dots-1 -a dots-2" type cr
   s"   dot on dots-3" type cr
   s"   dot off dots-3 -r " type 34 emit s" shipped" type 34 emit cr ;
: VERSION ( -- ) s" dots 0.6.4 (f107d016)" type cr ;
: FIND-USAGE ( -- )
   s" Usage: dot find <query>" type cr cr
   s" Search all dots (open first, then archived)." type cr cr
   s" Searches: title, description, close-reason, created-at, closed-at" type cr cr
   s" Examples:" type cr
   s"   dot find " type 34 emit s" auth" type 34 emit s"       Search for dots mentioning auth" type cr
   s"   dot find " type 34 emit s" 2026-01" type 34 emit s"    Find dots from January 2026" type cr ;
: UNSUPPORTED ( -- ) s" Unsupported command" FAIL ;
: PARSE-LIST-ARGS ( n -- )
   0 USE-JSON ! -1 FILTER ! 0 WANT-READY !
   script-argc swap ?do
      i script-argv$ 2dup s" --json" ARG= if 2drop 1 USE-JSON ! else
      2dup s" --status" ARG= if
         2drop i 1+ script-argc < if
            i 1+ script-argv$ PARSE-STATUS dup -1 = if
               drop s" Invalid status: " i 1+ script-argv$ ISSUE-ERROR
            then FILTER !
         then
      else 2drop then then
   loop ;
: PARSE-READY-ARGS ( -- )
   0 USE-JSON ! -1 FILTER ! 1 WANT-READY !
   script-argc 1 ?do
      i script-argv$ s" --json" ARG= if 1 USE-JSON ! then
   loop ;
: FIND-HELP? ( -- bool )
   script-argc 1 ?do
      i script-argv$ 2dup s" --help" ARG= if 2drop true unloop exit then
      s" -h" ARG= if true unloop exit then
   loop false ;

\ The writer owns a growable byte row.  All Markdown rewrites pass through it.
DYNAMIC-BUFFER OUT-BUF u8
variable OUT-U
: OUT-RESET ( -- ) 0 OUT-U ! 1 OUT-BUF-RESERVE ;
: OUT-APPEND ( ptr u8 n -- )
   {: a:ptr u:n :}
   OUT-U @ u + 1+ OUT-BUF-RESERVE
   a OUT-U @ OUT-BUF u BYTE-COPY
   OUT-U @ u + OUT-U ! ;
: OUT-CHAR ( n -- )
   OUT-U @ 2 + OUT-BUF-RESERVE
   OUT-U @ OUT-BUF c!
   1 OUT-U +! ;
: OUT-NUM ( n -- )
   SB-RESET FMT:SB-INT SB$ OUT-APPEND ;
: OUT$ ( -- ptr u8 n ) 0 OUT-BUF OUT-U @ ;

: QUOTE-YAML? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   u 0= if true exit then
   a c@ 32 = a c@ 9 = or a u 1- + c@ 32 = or a u 1- + c@ 9 = or
   if true exit then
   u 0 ?do
      a i + c@ {: ch:n :}
      ch 10 = ch 13 = or ch 58 = or ch 35 = or
      ch 34 = or ch 39 = or ch 92 = or if true unloop exit then
   loop false ;
: OUT-YAML ( ptr u8 n -- )
   {: a:ptr u:n :}
   a u QUOTE-YAML? 0= if a u OUT-APPEND exit then
   34 OUT-CHAR
   u 0 ?do
      a i + c@ {: ch:n :}
      ch 34 = if 92 OUT-CHAR 34 OUT-CHAR else
      ch 92 = if 92 OUT-CHAR 92 OUT-CHAR else
      ch 10 = if 92 OUT-CHAR 110 OUT-CHAR else
      ch 13 = if 92 OUT-CHAR 114 OUT-CHAR else
      ch 9 = if 92 OUT-CHAR 116 OUT-CHAR else
         ch OUT-CHAR
      then then then then then
   loop 34 OUT-CHAR ;
: OUT-FIELD ( n n ptr u8 n -- )
   {: idx:n field:n key:ptr ku:n :}
   key ku OUT-APPEND idx field FIELD$ OUT-YAML 10 OUT-CHAR ;
: OUT-OPTIONAL ( n n ptr u8 n -- )
   {: idx:n field:n key:ptr ku:n :}
   field F-ASSIGNEE = if
      idx F-ASSIGNEE-PRESENT REC-CELL @ 0<> if idx field key ku OUT-FIELD then exit
   then
   field F-CLOSED = if
      idx F-CLOSED-PRESENT REC-CELL @ 0<> if idx field key ku OUT-FIELD then exit
   then
   idx field FIELD$ nip 0 > if idx field key ku OUT-FIELD then ;
: SERIALIZE ( n -- )
   {: idx:n :}
   OUT-RESET
   s" ---" OUT-APPEND 10 OUT-CHAR
   idx F-TITLE s" title: " OUT-FIELD
   s" status: " OUT-APPEND idx F-STATUS REC-CELL @ STATUS>DISPLAY
   2dup s" done" STR= if 2drop s" closed" then OUT-APPEND 10 OUT-CHAR
   s" priority: " OUT-APPEND idx F-PRIORITY REC-CELL @ OUT-NUM 10 OUT-CHAR
   idx F-TYPE s" issue-type: " OUT-FIELD
   idx F-ASSIGNEE s" assignee: " OUT-OPTIONAL
   idx F-CREATED s" created-at: " OUT-FIELD
   idx F-CLOSED s" closed-at: " OUT-OPTIONAL
   idx F-REASON-PRESENT REC-CELL @ 0<> if
      idx F-REASON s" close-reason: " OUT-FIELD
   then
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   bu 0 > if
      s" blocks:" OUT-APPEND
      0 begin dup bu < while
         {: at:n :}
         blocks bu at NEXT-LINE drop {: b:ptr bsz:n next:n :}
         10 OUT-CHAR s"   - " OUT-APPEND b bsz OUT-APPEND
         next
      repeat drop
      10 OUT-CHAR
   then
   s" ---" OUT-APPEND 10 OUT-CHAR
   idx F-DESC FIELD$ dup 0 > if
      10 OUT-CHAR OUT-APPEND 10 OUT-CHAR
   else 2drop then ;
PROCESS-SYMBOLS
FUNCTION: FSYNC-CALL fsync ( n -- i32 ) ;FUNCTION
13 constant FS-ACCESS-DENIED
: FS-DIR-NOT-EMPTY ( -- n ) HB-TARGET-MACOS? if 66 else 39 then ;
: FS-RENAME-ERROR ( n -- )
   dup FS-ACCESS-DENIED = if drop s" Permission denied" FAIL then
   FS-DIR-NOT-EMPTY = if
      s" Unexpected internal error (code: DirNotEmpty)" FAIL
   then
   E-FS-IO throw ;
PROCESS-SYMBOLS
FUNCTION: RENAME-CALL rename ( ptr u8 ptr u8 -- i32 ) ;FUNCTION
: RENAME-CAUSE ( ptr u8 n ptr u8 n -- n )
   {: src:ptr su:n dst:ptr du:n :}
   src su FS-PATHZ dst du FS-MUT-PATHZ2 RENAME-CALL 0< if
      FFI:ERRNO dup 0= if drop -1 then exit
   then
   0 ;
: RENAME-ISSUE ( ptr u8 n ptr u8 n -- )
   RENAME-CAUSE dup 0<> if FS-RENAME-ERROR else drop then ;
PROCESS-SYMBOLS
FUNCTION: ACCESS-WRITE access ( ptr u8 n -- i32 ) ;FUNCTION
: PARENT-WRITABLE? ( ptr u8 n -- bool )
   {: path:ptr pu:n :}
   pu begin dup 0 > while
      dup 1- path + c@ 47 = if
         1- path swap FS-PATHZ 2 ACCESS-WRITE 0= exit
      then
      1-
   repeat drop
   s" ." FS-PATHZ 2 ACCESS-WRITE 0= ;
PTR-VARIABLE RESERVED-TEMP
variable RESERVED-U
variable RESERVED-FD
: RESERVE-STASH ( ptr u8 n -- ptr u8 n )
   {: path:ptr pu:n :}
   path pu RESERVE-SIBLING {: temp:ptr tu:n fd:n :}
   temp RESERVED-TEMP ! tu RESERVED-U ! fd RESERVED-FD !
   path pu ;
: RESERVE-ISSUE-SIBLING ( ptr u8 n -- ptr u8 n n )
   {: path:ptr pu:n :}
   path pu [: RESERVE-STASH ;] catch {: code:n :}
   2drop
   code 0= if RESERVED-TEMP @ RESERVED-U @ RESERVED-FD @ exit then
   code E-FS-OPEN = if
      path pu PARENT-WRITABLE? 0= if
         FFI:ERRNO FS-ACCESS-DENIED = if s" Permission denied" FAIL then
      then
   then
   code throw ;
: WRITE-ATOMIC ( ptr u8 n ptr u8 n -- )
   {: path:ptr pu:n src:ptr su:n :}
   path pu RESERVE-ISSUE-SIBLING {: temp:ptr tu:n fd:n :}
   0 begin dup su < while
      {: off:n :}
      fd src off + su off - write {: count:n :}
      count 0 <= if
         fd close temp tu REMOVE-FILE s" I/O error" FAIL
      then
      off count +
   repeat drop
   fd FSYNC-CALL 0<> if
      fd close temp tu REMOVE-FILE s" I/O error" FAIL
   then
   fd close
   temp tu path pu RENAME-CAUSE {: reason:n :}
   reason 0<> if
      temp tu REMOVE-FILE
      path pu DIR? if s" Unexpected internal error (code: IsDir)" FAIL then
      reason FS-RENAME-ERROR
   then ;
: SAVE-RECORD ( n -- )
   {: idx:n :}
   idx SERIALIZE
   idx F-PATH FIELD$ OUT$ WRITE-ATOMIC ;

\ Match the Zig writer's localtime and secure 32-bit random suffix.
PROCESS-SYMBOLS
FUNCTION: GETTIME-CALL gettimeofday ( ptr u8 n -- i32 ) ;FUNCTION
FUNCTION: LOCALTIME-CALL localtime_r ( ptr u8 ptr u8 -- ptr u8 ) ;FUNCTION
FUNCTION: GETCWD-CALL getcwd ( ptr u8 n -- ptr u8 ) ;FUNCTION
FUNCTION: RANDOM-CALL arc4random_buf ( ptr u8 n -- ) ;FUNCTION
create TIMEVAL 16 allot
create CALENDAR 64 allot
create RANDOM-ROW 4 allot
create CWD-ROW 4096 allot
create SLUG-ROW 32 allot
variable SLUG-U
create WORD-ROW 64 allot
create HEX-ROW 8 allot
variable WORD-START
variable WORD-COUNT
create PREFIX-ROW 65536 allot
variable PREFIX-U
create CONFIG-ROW 65536 allot
variable CONFIG-U
variable PAD-COPY

: WORD32@ ( ptr u8 -- n )
   {: a:ptr :}
   a c@ a 1+ c@ 256 * + a 2 + c@ 65536 * +
   a 3 + c@ 16777216 * + ;
: CELL64@ ( ptr u8 -- n ) CELL-VIEW @ ;
: SB-PAD ( n n -- )
   {: value:n width:n :}
   value 0 < if value FMT:SB-INT exit then
   value PAD-COPY !
   width 1- 0 ?do
      PAD-COPY @ 10 < if 48 SB-APPEND-C then
      PAD-COPY @ 10 / PAD-COPY !
   loop
   value FMT:SB-U ;
: TIMESTAMP$ ( -- ptr u8 n )
   TIMEVAL 0 GETTIME-CALL 0<> if s" Invalid system time" FAIL then
   TIMEVAL CALENDAR LOCALTIME-CALL NULL-PTR = if s" Failed to read local time" FAIL then
   CALENDAR 20 + WORD32@ 1900 + {: year:n :}
   CALENDAR 16 + WORD32@ 1+ {: month:n :}
   CALENDAR 12 + WORD32@ {: day:n :}
   CALENDAR 8 + WORD32@ {: hour:n :}
   CALENDAR 4 + WORD32@ {: minute:n :}
   CALENDAR WORD32@ {: second:n :}
   TIMEVAL 8 + CELL64@ {: micro:n :}
   CALENDAR 40 + CELL64@ {: offset:n :}
   SB-RESET
   year 4 SB-PAD 45 SB-APPEND-C month 2 SB-PAD 45 SB-APPEND-C day 2 SB-PAD
   84 SB-APPEND-C hour 2 SB-PAD 58 SB-APPEND-C minute 2 SB-PAD 58 SB-APPEND-C
   second 2 SB-PAD 46 SB-APPEND-C micro 6 SB-PAD
   offset 0 < if 45 else 43 then SB-APPEND-C
   offset abs 3600 / 2 SB-PAD 58 SB-APPEND-C
   offset abs 3600 mod 60 / 2 SB-PAD SB$ ;
: HEX-CHAR ( n -- n )
   dup 10 < if 48 + else 87 + then ;
: RANDOM-SUFFIX ( -- ptr u8 n )
   RANDOM-ROW 4 RANDOM-CALL
   SB-RESET
   4 0 ?do
      RANDOM-ROW i + c@ dup 16 / HEX-CHAR SB-APPEND-C
      16 mod HEX-CHAR SB-APPEND-C
   loop SB$ ;
: CWD-LEN ( -- n )
   CWD-ROW 4096 GETCWD-CALL NULL-PTR = if s" I/O error" FAIL then
   0 begin dup 4096 < while
      dup CWD-ROW + c@ 0= if exit then 1+
   repeat ;
: PREFIX! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 65536 > if CAP-FAIL then
   a PREFIX-ROW u BYTE-COPY u PREFIX-U ! ;
: PREFIX$ ( -- ptr u8 n ) PREFIX-ROW PREFIX-U @ ;
: CONFIG-LATER? ( ptr u8 n n -- bool )
   {: key:ptr ku:n start:n :}
   start begin dup CONFIG-U @ < while
      {: at:n :}
      CONFIG-ROW CONFIG-U @ at NEXT-LINE drop {: line:ptr lu:n next:n :}
      line lu 61 INDEX-OF MATCH option
         none OF ENDOF
         some OF
            IDX>N {: eq:n :}
            line eq key ku STR= if true exit then
         ENDOF
      ;MATCH
      next
   repeat drop false ;
: LOAD-PREFIX ( -- )
   0 CONFIG-U !
   s" .dots/config" FILE? if
      s" .dots/config" FILE-SIZE 65536 > if
         s" Unexpected internal error (code: StreamTooLong)" FAIL
      then
      [: s" .dots/config" CONFIG-ROW 65536 READ-ALL CONFIG-U ! ;] catch
      dup E-FS-CAPACITY = if drop s" Unexpected internal error (code: StreamTooLong)" FAIL then
      dup 0<> if throw then drop
      CONFIG-U @ {: len:n :}
      0 begin dup len < while
         {: at:n :}
         CONFIG-ROW len at NEXT-LINE drop {: line:ptr lu:n next:n :}
         line lu s" prefix=" STARTS-WITH? if
            line 7 + lu 7 - PREFIX! exit
         then
         next
      repeat drop
   then
   CWD-LEN CWD-ROW swap BASENAME {: base:ptr size:n :}
   size begin dup 0 > if base over 1- + c@ 45 = else false then while
      1-
   repeat {: trim:n :}
   trim 0= if s" dot" PREFIX! else base trim PREFIX! then
   OUT-RESET
   0 begin dup CONFIG-U @ < while
      {: at:n :}
      CONFIG-ROW CONFIG-U @ at NEXT-LINE drop {: line:ptr lu:n next:n :}
      line lu 61 INDEX-OF MATCH option
         none OF ENDOF
         some OF
            IDX>N {: eq:n :}
            line eq next CONFIG-LATER? 0= if
               line lu OUT-APPEND 10 OUT-CHAR
            then
         ENDOF
      ;MATCH
      next
   repeat drop
   s" prefix=" OUT-APPEND PREFIX$ OUT-APPEND 10 OUT-CHAR
   s" .dots/config" OUT$ WRITE-ATOMIC ;

: ALNUM? ( n -- bool )
   {: ch:n :}
   ch 48 >= ch 57 <= and
   ch 65 >= ch 90 <= and or
   ch 97 >= ch 122 <= and or ;
: APPEND-SLUG-WORD ( ptr u8 n -- )
   {: a:ptr u:n :}
   SB$ nip 0 > if 45 SB-APPEND-C then
   u 64 <= if
      u 0 ?do a i + c@ ASCII-LOWER WORD-ROW i + c! loop
      WORD-ROW u ABBREV SB-APPEND
   else
      u 0 ?do
         a i + c@ ASCII-LOWER SB-APPEND-C
         SB$ nip 30 > if unloop exit then
      loop
   then ;
: SLUGIFY$ ( ptr u8 n -- ptr u8 n )
   {: a:ptr u:n :}
   SB-RESET -1 WORD-START ! 0 WORD-COUNT !
   u 1+ 0 ?do
      i u < if a i + c@ ALNUM? else false then {: alnum:bool :}
      alnum if
         WORD-START @ -1 = if i WORD-START ! then
      else
         WORD-START @ -1 <> if
            a WORD-START @ + i WORD-START @ - APPEND-SLUG-WORD
            -1 WORD-START ! 1 WORD-COUNT +!
            SB$ nip 30 >= WORD-COUNT @ 3 >= or if leave then
         then
      then
   loop
   SB$ {: slug:ptr size:n :}
   size 30 > if
      30 begin dup 0 > if slug over 1- + c@ 45 <> else false then while 1- repeat
      dup 0 > if 1- then
   else size then {: final:n :}
   final 0= if s" untitled" {: fallback:ptr fu:n :}
      fallback SLUG-ROW fu BYTE-COPY fu SLUG-U !
   else
      slug SLUG-ROW final BYTE-COPY final SLUG-U !
   then
   SLUG-ROW SLUG-U @ ;
: NEW-ID$ ( ptr u8 n -- ptr u8 n )
   SLUGIFY$ 2drop
   RANDOM-SUFFIX drop HEX-ROW 8 BYTE-COPY
   SB-RESET PREFIX$ SB-APPEND 45 SB-APPEND-C
   SLUG-ROW SLUG-U @ SB-APPEND 45 SB-APPEND-C
   HEX-ROW 8 SB-APPEND SB$ ;

create PATH-ONE 512 allot
variable PATH-ONE-U
create PATH-TWO 512 allot
variable PATH-TWO-U
PTR-VARIABLE TITLE-A
variable TITLE-U
PTR-VARIABLE DESC-A
variable DESC-U
PTR-VARIABLE PARENT-A
variable PARENT-U
variable PARENT-SET
PTR-VARIABLE AFTER-A
variable AFTER-U
variable AFTER-SET
variable ADD-PRIORITY
variable ARG-I
variable AFTER-IDX
variable PARENT-IDX

: PATH-ONE! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 512 >= if s" I/O error" FAIL then
   a PATH-ONE u BYTE-COPY u PATH-ONE-U ! ;
: PATH-TWO! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 512 >= if s" I/O error" FAIL then
   a PATH-TWO u BYTE-COPY u PATH-TWO-U ! ;
: PATH-ONE$ ( -- ptr u8 n ) PATH-ONE PATH-ONE-U @ ;
: PATH-TWO$ ( -- ptr u8 n ) PATH-TWO PATH-TWO-U @ ;
: ARG-AT? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   script-argc 0 ?do i script-argv$ a u STR= if true unloop exit then loop false ;
: NEXT-ARG? ( -- bool ) ARG-I @ 1+ script-argc < ;
: TAKE-ARG ( -- ptr u8 n )
   1 ARG-I +! ARG-I @ script-argv$ ;
: FIND-PREFIX ( ptr u8 n -- n )
   {: a:ptr u:n :}
   -1 MATCH-I !
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ a u STARTS-WITH? if
         MATCH-I @ -1 <> if -2 MATCH-I ! else i MATCH-I ! then
      then
   loop MATCH-I @ ;
: FIND-EXACT ( ptr u8 n -- n )
   {: a:ptr u:n :}
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ a u STR= if i unloop exit then
   loop -1 ;
: RESOLVE-LABELED ( ptr u8 n ptr u8 n -- n )
   {: a:ptr u:n label:ptr lu:n :}
   a u FIND-PREFIX dup -1 = if
      drop label lu a u ISSUE-ERROR
   then
   dup -2 = if drop s" Ambiguous ID: " a u ISSUE-ERROR then ;
: NEW-RECORD ( ptr u8 n -- n )
   {: id:ptr iu:n :}
   ISSUE-N @ 1+ REC-CELLS * RECORDS-RESERVE
   ISSUE-N @ {: idx:n :}
   ISSUE-N @ 1+ ISSUE-N !
   id iu idx F-ID FIELD!
   idx F-DESC FIELD-EMPTY
   idx F-CLOSED FIELD-EMPTY
   idx F-REASON FIELD-EMPTY
   0 idx F-REASON-PRESENT REC-CELL !
   idx F-BLOCKS FIELD-EMPTY
   idx F-ASSIGNEE FIELD-EMPTY
   0 idx F-ASSIGNEE-PRESENT REC-CELL !
   0 idx F-CLOSED-PRESENT REC-CELL !
   idx F-PARENT FIELD-EMPTY
   0 idx F-PARENT-PRESENT REC-CELL !
   s" task" idx F-TYPE FIELD!
   0 idx F-STATUS REC-CELL !
   0 idx F-ARCHIVED REC-CELL !
   0 idx F-ERROR REC-CELL !
   0 idx F-CHILD REC-CELL !
   idx ;
: MAKE-CHILD-FOLDER ( n -- )
   {: parent:n :}
   SB-RESET s" .dots/" SB-APPEND parent F-ID FIELD$ SB-APPEND SB$ PATH-ONE!
   PATH-ONE$ MAKE-DIRS
   SB-RESET PATH-ONE$ SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO!
   PATH-TWO$ FILE? if
      SB-RESET PATH-ONE$ SB-APPEND 47 SB-APPEND-C
      parent F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$ PATH-ONE!
      PATH-TWO$ PATH-ONE$ RENAME-FILE
   then ;
: PARSE-ADD ( n -- )
   ARG-I !
   0 TITLE-U ! 0 DESC-U ! 0 PARENT-U ! 0 AFTER-U !
   0 PARENT-SET ! 0 AFTER-SET ! 2 ADD-PRIORITY !
   begin ARG-I @ script-argc < while
      ARG-I @ script-argv$ {: a:ptr u:n :}
      a u s" -p" STR= NEXT-ARG? and if
         TAKE-ARG 2dup PARSE-PRIORITY MATCH option
            none OF s" Invalid priority: " 2swap ISSUE-ERROR ENDOF
            some OF {: value:n :} 2drop value 0 max 9 min ADD-PRIORITY ! ENDOF
         ;MATCH
      else a u s" -d" STR= NEXT-ARG? and if
         TAKE-ARG DESC-U ! DESC-A !
      else a u s" -P" STR= NEXT-ARG? and if
         TAKE-ARG PARENT-U ! PARENT-A ! 1 PARENT-SET !
      else a u s" -a" STR= NEXT-ARG? and if
         TAKE-ARG AFTER-U ! AFTER-A ! 1 AFTER-SET !
      else TITLE-U @ 0= u 0 > and if
         a c@ 45 <> if a TITLE-A ! u TITLE-U ! then
      then then then then then
      1 ARG-I +!
   repeat ;
: ADD-COMMAND ( n -- )
   {: first:n :}
   script-argc first = if s" Usage: dot add <title> [options]" FAIL then
   first PARSE-ADD
   TITLE-U @ 0= if s" Error: title required" FAIL then
   PARENT-SET @ 0<> AFTER-SET @ 0<> and if
      PARENT-A @ PARENT-U @ AFTER-A @ AFTER-U @ STR= if
         s" Error: parent and after cannot be the same issue" FAIL
      then
   then
   true LOAD-ISSUES LOAD-PREFIX
   -1 AFTER-IDX !
   AFTER-SET @ 0<> if AFTER-A @ AFTER-U @ s" After issue not found: " RESOLVE-LABELED AFTER-IDX ! then
   -1 PARENT-IDX !
   PARENT-SET @ 0<> if PARENT-A @ PARENT-U @ s" Parent issue not found: " RESOLVE-LABELED PARENT-IDX ! then
   TITLE-A @ TITLE-U @ NEW-ID$ 2dup VALID-ID? 0= if 2drop s" Invalid issue id" FAIL then
   2dup FIND-EXACT -1 <> if 2drop s" Issue already exists" FAIL then
   NEW-RECORD {: idx:n :}
   TITLE-A @ TITLE-U @ idx F-TITLE FIELD!
   DESC-U @ 0 > if DESC-A @ DESC-U @ idx F-DESC FIELD! then
   ADD-PRIORITY @ idx F-PRIORITY REC-CELL !
   TIMESTAMP$ idx F-CREATED FIELD!
   AFTER-IDX @ -1 <> if
      0 BLOCK-U ! AFTER-IDX @ F-ID FIELD$ BLOCK-ADD
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
   then
   PARENT-IDX @ -1 <> if
      PARENT-IDX @ MAKE-CHILD-FOLDER
      PARENT-IDX @ F-ID FIELD$ idx F-PARENT FIELD!
      1 idx F-CHILD REC-CELL !
   then
   SB-RESET s" .dots/" SB-APPEND
   PARENT-IDX @ -1 <> if PARENT-IDX @ F-ID FIELD$ SB-APPEND 47 SB-APPEND-C then
   idx F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$
   idx F-PATH FIELD!
   idx SAVE-RECORD
   s" --json" ARG-AT? if
      JSON-OUT-BUF 1024 BUF:N>BLEN BUF:INIT
      JSON-W JSON-OUT-BUF JSON-WRITE:OPEN-BUF
      idx JSON-ISSUE dup JSON-WRITE:$ type cr JSON-WRITE:CLOSE
      JSON-OUT-BUF BUF:DISPOSE
   else idx F-ID FIELD$ type cr then ;

variable STATUS-TARGET
PTR-VARIABLE REASON-A
variable REASON-U
variable REASON-PRESENT
variable STATUS-INDEX
variable STATUS-MODE
variable CLOSED-STYLE
DYNAMIC-BUFFER STATUS-ARGS n
create CLOSED-TIME 40 allot
variable CLOSED-TIME-U

: RECORD-PATH? ( n -- bool )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> idx F-CHILD REC-CELL @ 0<> and if false exit then
   idx F-PATH FIELD$ FILE? ;
: STATUS-CHILDREN-OPEN? ( n -- bool )
   {: idx:n :}
   ISSUE-N @ 0 ?do
      i F-ARCHIVED REC-CELL @ 0= i F-ERROR REC-CELL @ 0= and if
         i F-PARENT FIELD$ idx F-ID FIELD$ STR= if
            i F-STATUS REC-CELL @ 2 <> if true unloop exit then
         then
      then
   loop false ;
: ARCHIVE-CHILDREN-CHECK ( n -- )
   {: idx:n :}
   ISSUE-N @ 0 ?do
      i F-PARENT FIELD$ idx F-ID FIELD$ STR= if
         i F-ERROR REC-CELL @ 2 = if s" Invalid issue status" FAIL then
         i F-ERROR REC-CELL @ 0<> if s" Invalid issue frontmatter" FAIL then
         i F-STATUS REC-CELL @ 2 <> if
            s" Cannot close: children are not all closed" FAIL
         then
      then
   loop ;
: REBASE-ARCHIVED-CHILDREN ( n -- )
   {: idx:n :}
   ISSUE-N @ 0 ?do
      i F-PARENT FIELD$ idx F-ID FIELD$ STR= if
         1 i F-ARCHIVED REC-CELL !
         SB-RESET s" .dots/archive/" SB-APPEND idx F-ID FIELD$ SB-APPEND
         47 SB-APPEND-C i F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$
         i F-PATH FIELD!
      then
   loop ;
: ARCHIVE-STATUS ( n -- )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> if exit then
   idx F-CHILD REC-CELL @ 0<> if exit then
   idx F-ID FIELD$ {: id:ptr iu:n :}
   SB-RESET s" .dots/" SB-APPEND id iu SB-APPEND SB$ PATH-ONE!
   PATH-ONE$ DIR? if
      idx ARCHIVE-CHILDREN-CHECK
      SB-RESET s" .dots/archive/" SB-APPEND id iu SB-APPEND SB$ PATH-TWO!
      PATH-ONE$ PATH-TWO$ RENAME-ISSUE
      SB-RESET PATH-TWO$ SB-APPEND 47 SB-APPEND-C id iu SB-APPEND s" .md" SB-APPEND SB$
      idx F-PATH FIELD! idx REBASE-ARCHIVED-CHILDREN
   else
      SB-RESET s" .dots/archive/" SB-APPEND id iu SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO!
      idx F-PATH FIELD$ PATH-TWO$ RENAME-ISSUE
      PATH-TWO$ idx F-PATH FIELD!
   then
   1 idx F-ARCHIVED REC-CELL ! ;
: STATUS-CHANGE ( n n -- )
   {: idx:n status:n :}
   idx RECORD-PATH? 0= if s" Issue not found" FAIL then
   idx F-ERROR REC-CELL @ 2 = if s" Invalid issue status" FAIL then
   idx F-ERROR REC-CELL @ 0<> if s" Invalid issue frontmatter" FAIL then
   status 2 = if
      idx STATUS-CHILDREN-OPEN? if
         CLOSED-STYLE @ 0= if
            s" Cannot close: children are not all closed" FAIL
         else
            s" Cannot close " idx F-ID FIELD$ s" : children are not all closed" 
            {: prefix:ptr pu:n id:ptr iu:n suffix:ptr su:n :}
            SB-RESET prefix pu SB-APPEND id iu SB-APPEND suffix su SB-APPEND SB$ FAIL
         then
      then
      CLOSED-TIME-U @ 0 > if
         CLOSED-TIME CLOSED-TIME-U @ idx F-CLOSED FIELD!
      else TIMESTAMP$ idx F-CLOSED FIELD! then
      1 idx F-CLOSED-PRESENT REC-CELL !
      REASON-PRESENT @ 0<> if
         REASON-A @ REASON-U @ idx F-REASON FIELD!
         1 idx F-REASON-PRESENT REC-CELL !
      then
   else
      idx F-CLOSED FIELD-EMPTY idx F-REASON FIELD-EMPTY
      0 idx F-CLOSED-PRESENT REC-CELL !
      0 idx F-REASON-PRESENT REC-CELL !
   then
   status idx F-STATUS REC-CELL !
   idx SAVE-RECORD
   status 2 = if idx ARCHIVE-STATUS then ;
: RESOLVE-ARG ( n -- n )
   {: arg:n :}
   arg script-argv$ RESOLVE ;
: STATUS-MULTI ( n -- )
   STATUS-MODE !
   script-argc 2 < if
      STATUS-MODE @ 2 = if s" Usage: dot off <id> [id2 ...] [-r reason]" FAIL then
      s" Usage: dot on <id> [id2 ...]" FAIL
   then
   0 REASON-U ! 0 REASON-PRESENT ! 0 CLOSED-TIME-U !
   0 STATUS-INDEX ! 1 ARG-I !
   begin ARG-I @ script-argc < while
      STATUS-MODE @ 2 = ARG-I @ script-argv$ s" -r" STR= and
      NEXT-ARG? and if
         TAKE-ARG REASON-U ! REASON-A ! 1 REASON-PRESENT !
      else
         STATUS-INDEX @ 1+ STATUS-ARGS-RESERVE
         ARG-I @ STATUS-INDEX @ STATUS-ARGS !
         1 STATUS-INDEX +!
      then
      1 ARG-I +!
   repeat
   STATUS-INDEX @ 0= if s" Usage: dot off <id> [id2 ...] [-r reason]" FAIL then
   true LOAD-ISSUES
   STATUS-MODE @ 2 = if
      TIMESTAMP$ {: ts:ptr tu:n :}
      ts CLOSED-TIME tu BYTE-COPY tu CLOSED-TIME-U !
   then
   STATUS-INDEX @ 0 ?do
      i STATUS-ARGS @ RESOLVE-ARG STATUS-MODE @ STATUS-CHANGE
   loop ;
: STATUS-SINGLE ( n -- )
   STATUS-MODE !
   script-argc 2 < if
      STATUS-MODE @ 2 = if s" Usage: dot close <id> [--reason R]" FAIL then
      s" Usage: dot update <id> [--status S]" FAIL
   then
   0 REASON-U ! 0 REASON-PRESENT ! 0 CLOSED-TIME-U !
   STATUS-MODE @ -1 = if
      2 ARG-I !
      begin ARG-I @ script-argc < while
         ARG-I @ script-argv$ s" --status" STR= NEXT-ARG? and if
            TAKE-ARG 2dup PARSE-STATUS dup -1 = if
               drop s" Invalid status: " 2swap ISSUE-ERROR
            then STATUS-MODE ! 2drop
         then
         1 ARG-I +!
      repeat
      STATUS-MODE @ -1 = if s" --status required" FAIL then
   else
      2 ARG-I !
      begin ARG-I @ script-argc < while
         ARG-I @ script-argv$ s" --reason" STR= NEXT-ARG? and if
            TAKE-ARG REASON-U ! REASON-A ! 1 REASON-PRESENT !
         then
         1 ARG-I +!
      repeat
   then
   true LOAD-ISSUES 1 RESOLVE-ARG STATUS-MODE @ STATUS-CHANGE ;
: INIT-EMPTY ( -- )
   s" .dots/archive" MAKE-DIRS ;
: SCANNED-NAME ( n -- ptr u8 n n )
   {: at:n :}
   at SCAN-NAMES c@ at 1+ SCAN-NAMES c@ 256 * + {: size:n :}
   at 2 + SCAN-NAMES size at size 2 + + ;
: REMOVE-DEEP-TREE ( n n -- )
   {: depth:n plen:n :}
   depth MAX-DEPTH 1- >= if s" I/O error" FAIL then
   depth PATH-AT {: path:ptr :}
   path plen SYMLINK? if path plen REMOVE-FILE exit then
   SCAN-NAMES-U @ {: begin-at:n :}
   path plen [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      path plen name nu depth 1+ PATH-AT PATH-JOIN {: child-u:n :}
      depth 1+ PATH-AT {: child:ptr :}
      child child-u SYMLINK? if child child-u REMOVE-FILE else
         child child-u DIR? if depth 1+ child-u RECURSE
         else child child-u REMOVE-FILE then
      then
      next
   repeat drop
   path plen REMOVE-DIR ;
: REMOVE-ISSUE-TREE ( ptr u8 n -- )
   {: path:ptr pu:n :}
   0 SCAN-NAMES-U !
   path 0 PATH-AT pu BYTE-COPY
   0 pu REMOVE-DEEP-TREE ;
: PURGE-COMMAND ( -- )
   s" .dots/archive" SYMLINK? 0= if s" .dots/archive" MAKE-DIRS then
   s" .dots/archive" REMOVE-ISSUE-TREE
   s" .dots/archive" MAKE-DIRS
   s" Archive purged" type cr ;
: REMOVE-BLOCK-REFERENCE ( n n -- )
   {: idx:n deleted:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   \ Earlier operands of a multi-delete may have removed this snapshot entry.
   idx RECORD-PATH? 0= if exit then
   0 BLOCK-U ! 0 VALID !
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   0 begin dup bu < while
      {: at:n :}
      blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
      block sz deleted F-ID FIELD$ STR= if 1 VALID !
      else block sz BLOCK-ADD then
      next
   repeat drop
   VALID @ 0<> if
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
      idx RECORD-PATH? 0= if s" Issue not found" FAIL then
      idx SAVE-RECORD
   then ;
: REMOVE-REFERENCES ( n -- )
   {: deleted:n :}
   ISSUE-N @ 0 ?do i deleted REMOVE-BLOCK-REFERENCE loop ;
: RM-ONE ( n -- )
   {: idx:n :}
   idx RECORD-PATH? 0= if s" Issue not found" FAIL then
   idx REMOVE-REFERENCES
   idx F-ID FIELD$ {: id:ptr iu:n :}
   idx F-ARCHIVED REC-CELL @ 0<> if s" .dots/archive/" else s" .dots/" then
   {: base:ptr bu:n :}
   SB-RESET base bu SB-APPEND id iu SB-APPEND SB$ PATH-ONE!
   idx F-CHILD REC-CELL @ 0= PATH-ONE$ DIR? and if
      ISSUE-N @ 0 ?do
         i F-PARENT FIELD$ idx F-ID FIELD$ STR= if i REMOVE-REFERENCES then
      loop
      PATH-ONE$ REMOVE-ISSUE-TREE
   else
      idx F-PATH FIELD$ REMOVE-FILE
   then
   idx F-PATH FIELD-EMPTY ;
: RM-COMMAND ( -- )
   script-argc 2 < if s" Usage: dot rm <id> [id2 ...]" FAIL then
   true LOAD-ISSUES
   script-argc 1 ?do i RESOLVE-ARG RM-ONE loop ;
: TREE-HELP ( -- )
   s" Usage: dot tree [id]" type cr cr
   s" Show dot hierarchy." type cr cr
   s" Without arguments: shows all open root dots and their children." type cr
   s" With id: shows that specific dot's tree (including closed children)." type cr cr
   s" Examples:" type cr
   s"   dot tree                    Show all open root dots" type cr
   s"   dot tree my-project         Show specific dot and its children" type cr ;
: STATUS-SYMBOL ( n -- ptr u8 n )
   dup 0 = if drop s" ○" exit then
   dup 1 = if drop s" >" exit then
   drop s" ✓" ;
: TREE-ROOT? ( n -- bool )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> idx F-ERROR REC-CELL @ 0<> or if false exit then
   idx F-STATUS REC-CELL @ 2 = if false exit then
   idx PATH-SLASHES 2 > if false exit then
   idx F-PARENT FIELD$ dup 0= if 2drop true exit then
   {: parent:ptr pu:n :}
   SB-RESET s" .dots/" SB-APPEND parent pu SB-APPEND
   47 SB-APPEND-C parent pu SB-APPEND s" .md" SB-APPEND SB$
   {: path:ptr plen:n :}
   ISSUE-N @ 0 ?do
      i F-PATH FIELD$ path plen STR= i F-ERROR REC-CELL @ 0= and if
         false unloop exit
      then
   loop true ;
: PRINT-TREE-ROOT ( n -- )
   {: idx:n :}
   91 emit idx F-ID FIELD$ type s" ] " type
   idx F-STATUS REC-CELL @ STATUS-SYMBOL type 32 emit
   idx F-TITLE FIELD$ type cr
   ISSUE-N @ 0 ?do
      i ORDER @ {: child:n :}
      child F-ERROR REC-CELL @ 0= child F-ARCHIVED REC-CELL @ 0= and if
         child PATH-SLASHES 2 = if
            child F-PARENT FIELD$ idx F-ID FIELD$ STR= if
               s"   └─ [" type child F-ID FIELD$ type s" ] " type
               child F-STATUS REC-CELL @ STATUS-SYMBOL type 32 emit
               child F-TITLE FIELD$ type
               child BLOCKED? if s"  (blocked)" type then cr
            then
         then
      then
   loop ;
: TREE-COMMAND ( -- )
   FIND-HELP? if TREE-HELP exit then
   script-argc 2 > if s" Usage: dot tree [id]" FAIL then
   false LOAD-ISSUES
   SORT-ISSUES
   script-argc 2 = if
      1 RESOLVE-ARG dup RECORD-PATH? 0= if
         s" Issue not found: " 1 script-argv$ ISSUE-ERROR
      then
      dup F-ERROR REC-CELL @ 2 = if s" Invalid issue status" FAIL then
      dup F-ERROR REC-CELL @ 0<> if s" Invalid issue frontmatter" FAIL then
      PRINT-TREE-ROOT exit
   then
   ISSUE-N @ 0 ?do i ORDER @ dup TREE-ROOT? if PRINT-TREE-ROOT else drop then loop ;
variable FIX-FOLDERS
variable FIX-FILES
variable FIX-COUNT
variable FIX-LEFT
create FIX-FOLDER-ROW 256 allot
: COUNT-FIX-ENTRY ( ptr u8 n -- ) 2drop 1 FIX-LEFT +! ;
: FIX-PARENT-VALID? ( ptr u8 n -- bool )
   {: name:ptr nu:n :}
   SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND
   47 SB-APPEND-C name nu SB-APPEND s" .md" SB-APPEND SB$
   {: path:ptr pu:n :}
   ISSUE-N @ 0 ?do
      i F-PATH FIELD$ path pu STR= i F-ERROR REC-CELL @ 0= and if
         true unloop exit
      then
   loop false ;
: FIX-PATHS ( ptr u8 n ptr u8 n -- )
   {: folder:ptr fu:n name:ptr nu:n :}
   SB-RESET s" .dots/" SB-APPEND folder fu SB-APPEND 47 SB-APPEND-C
   name nu SB-APPEND SB$ PATH-ONE!
   SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND SB$ PATH-TWO! ;
: FIX-FOLDER ( ptr u8 n -- )
   {: folder:ptr fu:n :}
   folder FIX-FOLDER-ROW fu BYTE-COPY
   SB-RESET s" .dots/" SB-APPEND FIX-FOLDER-ROW fu SB-APPEND
   SB$ 1 PATH-AT swap BYTE-COPY
   1 PATH-AT {: path:ptr :}
   path fu 6 + SYMLINK? if exit then
   SCAN-NAMES-U @ {: begin-at:n :}
   path fu 6 + [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   0 FIX-COUNT !
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu FILE-ENTRY? if
         FIX-FOLDER-ROW fu name nu FIX-PATHS
         PATH-ONE$ SYMLINK? 0= PATH-ONE$ FILE? and if
            PATH-TWO$ SYMLINK? PATH-TWO$ FILE? or PATH-TWO$ DIR? or if
               s" Issue already exists" FAIL
            then
            1 FIX-COUNT +!
         then
      then
      next
   repeat drop
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu FILE-ENTRY? if
         FIX-FOLDER-ROW fu name nu FIX-PATHS
         PATH-ONE$ SYMLINK? 0= PATH-ONE$ FILE? and if
            PATH-ONE$ PATH-TWO$ RENAME-FILE
         then
      then
      next
   repeat drop
   0 FIX-LEFT !
   path fu 6 + [: COUNT-FIX-ENTRY ;] FS-LIST:EACH
   FIX-LEFT @ 0= if path fu 6 + REMOVE-DIR then
   1 FIX-FOLDERS +!
   FIX-COUNT @ FIX-FILES +! ;
: FIX-COMMAND ( -- )
   false LOAD-ISSUES
   0 FIX-FOLDERS ! 0 FIX-FILES !
   0 SCAN-NAMES-U !
   s" .dots" [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   0 begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu s" archive" STR= 0= if
         SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND SB$ PATH-TWO!
         PATH-TWO$ SYMLINK? 0= PATH-TWO$ DIR? and if
            name nu FIX-PARENT-VALID? 0= if name nu FIX-FOLDER then
         then
      then
      next
   repeat drop
   FIX-FOLDERS @ 0= if s" No fixes needed" type cr exit then
   s" Fixed " type FIX-FOLDERS @ FMT:.INT
   s"  orphan parent(s), moved " type FIX-FILES @ FMT:.INT
   s"  file(s)" type cr ;
FUNCTION: STDERR-WRITE write ( n ptr u8 n -- n ) ;FUNCTION
create OLD-ID-ROW 129 allot
variable OLD-ID-U
create NEW-ID-ROW 512 allot
variable NEW-ID-U
variable LAST-DASH
variable SLUG-RENAMED
variable SLUG-CHANGED
: OLD-ID! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 128 > if s" Invalid issue id" FAIL then
   a OLD-ID-ROW u BYTE-COPY u OLD-ID-U ! ;
: OLD-ID$ ( -- ptr u8 n ) OLD-ID-ROW OLD-ID-U @ ;
: NEW-ID! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 512 > if s" Invalid issue id" FAIL then
   a NEW-ID-ROW u BYTE-COPY u NEW-ID-U ! ;
: RENAMED-ID$ ( -- ptr u8 n ) NEW-ID-ROW NEW-ID-U @ ;
: HEX? ( n -- bool )
   dup 48 >= over 57 <= and swap
   dup 65 >= over 70 <= and swap
   dup 97 >= swap 102 <= and or or ;
: SLUG-SUFFIX ( -- )
   -1 LAST-DASH !
   OLD-ID-U @ 0 ?do OLD-ID-ROW i + c@ 45 = if i LAST-DASH ! then loop
   LAST-DASH @ -1 <> OLD-ID-U @ LAST-DASH @ - 1- 8 = and if
      1 VALID !
      8 0 ?do
         OLD-ID-ROW LAST-DASH @ 1+ i + + c@ HEX? 0= if 0 VALID ! then
      loop
      VALID @ 0<> if
         OLD-ID-ROW LAST-DASH @ 1+ + HEX-ROW 8 BYTE-COPY exit
      then
   then
   RANDOM-SUFFIX drop HEX-ROW 8 BYTE-COPY ;
: SLUG-NEW-ID ( n -- )
   {: idx:n :}
   idx F-TITLE FIELD$ SLUGIFY$ 2drop
   SLUG-SUFFIX
   SB-RESET PREFIX$ SB-APPEND 45 SB-APPEND-C
   SLUG-ROW SLUG-U @ SB-APPEND 45 SB-APPEND-C
   HEX-ROW 8 SB-APPEND SB$ NEW-ID! ;
: REBASE-RENAMED-CHILDREN ( -- )
   SB-RESET s" .dots/" SB-APPEND OLD-ID$ SB-APPEND 47 SB-APPEND-C
   SB$ PATH-ONE!
   ISSUE-N @ 0 ?do
      i F-PARENT FIELD$ OLD-ID$ STR= if
         RENAMED-ID$ i F-PARENT FIELD!
      then
      i F-PATH FIELD$ PATH-ONE$ STARTS-WITH? if
         i F-PATH FIELD$ {: old-path:ptr old-u:n :}
         SB-RESET s" .dots/" SB-APPEND RENAMED-ID$ SB-APPEND
         47 SB-APPEND-C
         old-path PATH-ONE-U @ + old-u PATH-ONE-U @ - SB-APPEND SB$
         i F-PATH FIELD!
      then
   loop ;
: RENAME-PATH ( n -- )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> idx F-CHILD REC-CELL @ 0= and
   idx PATH-SLASHES 3 = and if
      s" Missing issue file or directory in .dots" FAIL
   then
   idx F-ARCHIVED REC-CELL @ 0= idx F-CHILD REC-CELL @ 0= and if
      SB-RESET s" .dots/" SB-APPEND OLD-ID$ SB-APPEND SB$ PATH-ONE!
      PATH-ONE$ DIR? if
         SB-RESET s" .dots/" SB-APPEND RENAMED-ID$ SB-APPEND SB$ PATH-TWO!
         PATH-ONE$ PATH-TWO$ RENAME-FILE
         REBASE-RENAMED-CHILDREN
         SB-RESET PATH-TWO$ SB-APPEND 47 SB-APPEND-C OLD-ID$ SB-APPEND
         s" .md" SB-APPEND SB$ PATH-ONE!
         SB-RESET PATH-TWO$ SB-APPEND 47 SB-APPEND-C RENAMED-ID$ SB-APPEND
         s" .md" SB-APPEND SB$ idx F-PATH FIELD!
         idx SAVE-RECORD
         PATH-ONE$ REMOVE-FILE
         exit
      then
   then
   idx F-PATH FIELD$ PATH-ONE!
   SB-RESET s" .dots/" SB-APPEND
   idx F-PATH FIELD$ {: old-path:ptr old-u:n :}
   idx F-CHILD REC-CELL @ 0<> idx F-ARCHIVED REC-CELL @ 0= or if
      old-path 6 + old-u 6 - 47 INDEX-OF MATCH option
         none OF ENDOF
         some OF old-path 6 + swap IDX>N SB-APPEND 47 SB-APPEND-C ENDOF
      ;MATCH
   then
   RENAMED-ID$ SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO!
   PATH-TWO$ idx F-PATH FIELD!
   0 idx F-ARCHIVED REC-CELL !
   idx SAVE-RECORD
   PATH-ONE$ REMOVE-FILE ;
: REWRITE-OLD-BLOCKS ( n -- )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   0 BLOCK-U ! 0 SLUG-CHANGED !
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   0 begin dup bu < while
      {: at:n :}
      blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
      block sz OLD-ID$ STR= if
         RENAMED-ID$ BLOCK-ADD 1 SLUG-CHANGED !
      else block sz BLOCK-ADD then
      next
   repeat drop
   SLUG-CHANGED @ 0<> if
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
      idx RECORD-PATH? 0= if s" Issue not found" FAIL then
      idx SAVE-RECORD
   then ;
: SLUGIFY-ONE ( n -- )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   idx F-ID FIELD$ OLD-ID!
   idx SLUG-NEW-ID
   OLD-ID$ RENAMED-ID$ STR= if exit then
   RENAMED-ID$ VALID-ID? 0= if s" Invalid issue id" FAIL then
   RENAMED-ID$ FIND-EXACT -1 <> if
      SB-RESET s" Skipping " SB-APPEND OLD-ID$ SB-APPEND
      s" : new ID " SB-APPEND RENAMED-ID$ SB-APPEND
      s"  already exists" SB-APPEND 10 SB-APPEND-C
      SB$ 2 -rot STDERR-WRITE drop exit
   then
   idx RECORD-PATH? 0= if s" Issue not found" FAIL then
   RENAMED-ID$ idx F-ID FIELD!
   idx RENAME-PATH
   ISSUE-N @ 0 ?do i REWRITE-OLD-BLOCKS loop
   OLD-ID$ type s"  -> " type RENAMED-ID$ type cr
   1 SLUG-RENAMED +! ;
create GIT-EXEC-ROW PATH-CAP allot
: GIT-ADD-DOTS ( -- )
   s" .git" EXISTS? 0= if exit then
   s" git" >LEN GIT-EXEC-ROW FIND-EXECUTABLE MATCH option
      none OF s" Missing issue file or directory in .dots" FAIL ENDOF
      some OF {: path-u:len :}
         PROC-ARGV-RESET
         s" add" >LEN PROC-ARGV+
         s" .dots" >LEN PROC-ARGV+
         s" /dev/null" FS-PATHZ FS-O-WRONLY FS-MODE-0644 open {: sink:n :}
         GIT-EXEC-ROW path-u -1 >FD sink >FD sink >FD PROC-RUN-ARGV-IO-RC
         sink close
         MATCH result
            ok OF drop ENDOF
            err OF
               SB-RESET s" Warning: git add failed with exit code " SB-APPEND
               FMT:SB-INT 10 SB-APPEND-C
               SB$ 2 -rot STDERR-WRITE drop
            ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;
: SLUGIFY-COMMAND ( -- )
   true LOAD-ISSUES LOAD-PREFIX
   0 SLUG-RENAMED !
   ISSUE-N @ 0 ?do i SLUGIFY-ONE loop
   s" Slugified " type SLUG-RENAMED @ FMT:.INT s"  issue(s)" type cr
   GIT-ADD-DOTS ;

\ JSONL migration uses the checked JSON cursor and keeps each source line live
\ until every typed field and dependency has been decoded.
create JSONL-STATE JR:STORAGE-BYTES allot
create JSONL-DECODE-BUF 1048576 allot
DYNAMIC-BUFFER JSONL-FILE-BUF u8
create JSONL-CHUNK 8192 allot
variable JSONL-CHUNK-U
variable JSONL-FILE-U
DYNAMIC-BUFFER IMPORT-DEP-BUF u8
PTR-VARIABLE JSONL-LINE-A
variable JSONL-LINE-U
variable IMPORT-IDX
variable IMPORT-DEP-U
variable IMPORTED-N
variable IMPORT-SKIPPED-N
variable DEP-SKIPPED-N
create DEP-ID-ROW 1048576 allot
variable DEP-ID-U
create DEP-TYPE-ROW 1048576 allot
variable DEP-TYPE-U
variable JSONL-SEEN
variable JSONL-NUM-AT
variable JSONL-NUM-DIGITS
variable JSONL-NUM-FRAC
variable JSONL-NUM-EXP
variable JSONL-NUM-EXP-NEG
variable JSONL-HAS-FRAC
variable JSONL-DEP-SEEN

: JSONL-KEY-BIT ( JR:reader -- JR:reader n )
   s" id" JR:STR-EQ? if 1 exit then
   s" title" JR:STR-EQ? if 2 exit then
   s" description" JR:STR-EQ? if 4 exit then
   s" status" JR:STR-EQ? if 8 exit then
   s" priority" JR:STR-EQ? if 16 exit then
   s" issue_type" JR:STR-EQ? if 32 exit then
   s" assignee" JR:STR-EQ? if 64 exit then
   s" created_at" JR:STR-EQ? if 128 exit then
   s" updated_at" JR:STR-EQ? if 256 exit then
   s" closed_at" JR:STR-EQ? if 512 exit then
   s" close_reason" JR:STR-EQ? if 1024 exit then
   s" dependencies" JR:STR-EQ? if 2048 exit then
   0 ;

: JSONL-START ( -- JR:reader )
   JSONL-STATE JR:STORAGE-BYTES JSONL-LINE-A @ JSONL-LINE-U @ JR:INIT
   JR:NEXT JR:T-OBJ <> if JR:CLOSE E-JR-MALFORMED throw then ;
: JSONL-VALIDATE ( -- )
   0 JSONL-SEEN !
   JSONL-START
   begin JR:NEXT dup JR:T-OBJ-END <> while
      JR:T-KEY <> if JR:CLOSE E-JR-MALFORMED throw then
      JSONL-KEY-BIT {: bit:n :}
      JSONL-SEEN @ bit and 0<> if JR:CLOSE E-JR-MALFORMED throw then
      JSONL-SEEN @ bit or JSONL-SEEN !
      JR:NEXT drop JR:SKIP-VALUE
   repeat drop
   JR:NEXT JR:T-END <> if JR:CLOSE E-JR-MALFORMED throw then
   JR:CLOSE ;
: JSONL-FIND ( ptr u8 n -- JR:reader bool )
   {: key:ptr ku:n :}
   JSONL-START key ku JR:FIND-KEY ;
: JSONL-STRING-FIELD ( ptr u8 n n -- bool )
   {: key:ptr ku:n field:n :}
   key ku JSONL-FIND if
      JR:TOKEN dup JR:T-STR = if
         drop JSONL-DECODE-BUF 1048576 JR:STR {: size:n :}
         JSONL-DECODE-BUF size IMPORT-IDX @ field FIELD!
         JR:CLOSE true exit
      then
      JR:T-NULL = if JR:CLOSE false exit then
      JR:CLOSE E-JR-MALFORMED throw
   then JR:CLOSE false ;
: JSONL-REQUIRED-STRING ( ptr u8 n n -- )
   JSONL-STRING-FIELD 0= if E-JR-MALFORMED throw then ;
: JSONL-DECIMAL-DIGIT? ( ptr u8 n n -- bool )
   {: a:ptr u:n at:n :}
   a at + c@ DIGIT? if true exit then
   a at + c@ 95 <> at 0= or at 1+ u >= or if false exit then
   a at 1- + c@ DIGIT? a at 1+ + c@ DIGIT? and ;
: JSONL-DECIMAL ( ptr u8 n -- option<n> )
   {: a:ptr u:n :}
   a u PARSE-PRIORITY MATCH option
      none OF ENDOF
      some OF OPTION:SOME exit ENDOF
   ;MATCH
   0 JSONL-NUM-AT ! 0 JSONL-NUM-DIGITS ! 0 JSONL-NUM-FRAC !
   0 JSONL-NUM-EXP ! 0 JSONL-NUM-EXP-NEG !
   0 NUM-U ! 0 NUM-SIG !
   u 0= if OPTION:NONE exit then
   a c@ dup 45 = swap 43 = or if
      a c@ 45 = if 45 NUM-APPEND drop then
      1 JSONL-NUM-AT !
   then
   JSONL-NUM-AT @ {: start:n :}
   begin JSONL-NUM-AT @ u < if a u JSONL-NUM-AT @ JSONL-DECIMAL-DIGIT? else false then while
      a JSONL-NUM-AT @ + c@ 95 <> if 1 JSONL-NUM-DIGITS +! then
      1 JSONL-NUM-AT +!
   repeat
   JSONL-NUM-AT @ u < if
      a JSONL-NUM-AT @ + c@ 46 = if
         1 JSONL-NUM-AT +!
         begin JSONL-NUM-AT @ u < if a u JSONL-NUM-AT @ JSONL-DECIMAL-DIGIT? else false then while
            a JSONL-NUM-AT @ + c@ 95 <> if
               1 JSONL-NUM-DIGITS +! 1 JSONL-NUM-FRAC +!
            then
            1 JSONL-NUM-AT +!
         repeat
      then
   then
   JSONL-NUM-DIGITS @ 0= if OPTION:NONE exit then
   JSONL-NUM-AT @ {: mantissa-end:n :}
   JSONL-NUM-AT @ u < if
      a JSONL-NUM-AT @ + c@ dup 101 = swap 69 = or if
         1 JSONL-NUM-AT +!
         JSONL-NUM-AT @ u < if
            a JSONL-NUM-AT @ + c@ dup 45 = swap 43 = or if
               a JSONL-NUM-AT @ + c@ 45 = if 1 JSONL-NUM-EXP-NEG ! then
               1 JSONL-NUM-AT +!
            then
         then
         JSONL-NUM-AT @ u >= if OPTION:NONE exit then
         a JSONL-NUM-AT @ + c@ DIGIT? 0= if OPTION:NONE exit then
         begin JSONL-NUM-AT @ u < if a u JSONL-NUM-AT @ JSONL-DECIMAL-DIGIT? else false then while
            JSONL-NUM-EXP @ 1048576 < a JSONL-NUM-AT @ + c@ 95 <> and if
               JSONL-NUM-EXP @ 10 * a JSONL-NUM-AT @ + c@ 48 - +
               1048576 min JSONL-NUM-EXP !
            then
            1 JSONL-NUM-AT +!
         repeat
      then
   then
   JSONL-NUM-AT @ u <> if OPTION:NONE exit then
   JSONL-NUM-EXP-NEG @ 0<> if JSONL-NUM-EXP @ negate JSONL-NUM-EXP ! then
   JSONL-NUM-DIGITS @ JSONL-NUM-FRAC @ - JSONL-NUM-EXP @ +
   {: whole:n :}
   0 JSONL-NUM-DIGITS ! 0 JSONL-HAS-FRAC !
   start begin dup mantissa-end < while
      {: at:n :}
      a at + c@ {: ch:n :}
      ch 46 <> ch 95 <> and if
         JSONL-NUM-DIGITS @ whole < if
            NUM-SIG @ 0<> ch 48 <> or if
               ch NUM-APPEND 0= if OPTION:NONE exit then
               1 NUM-SIG !
            then
         else
            ch 48 <> if 1 JSONL-HAS-FRAC ! then
         then
         1 JSONL-NUM-DIGITS +!
      then
      at 1+
   repeat drop
   NUM-SIG @ 0<> if
      whole JSONL-NUM-DIGITS @ - dup 0 > if
         NUM-U @ over + 32 > if drop OPTION:NONE exit then
         0 ?do 48 NUM-APPEND drop loop
      else drop then
   else
      48 NUM-APPEND drop
   then
   NUM-BUF NUM-U @ STR>NUMBER? MATCH option
      none OF OPTION:NONE exit ENDOF
      some OF ENDOF
   ;MATCH {: integer:n :}
   JSONL-HAS-FRAC @ 0<> if OPTION:NONE exit then
   integer OPTION:SOME ;
: JSONL-PRIORITY ( -- )
   s" priority" JSONL-FIND 0= if JR:CLOSE E-JR-MALFORMED throw then
   JR:TOKEN {: kind:n :}
   kind JR:T-INT = if
      JR:INT IMPORT-IDX @ F-PRIORITY REC-CELL ! JR:CLOSE exit
   then
   kind JR:T-STR = if
      JSONL-DECODE-BUF 1048576 JR:STR {: size:n :}
      JSONL-DECODE-BUF size JSONL-DECIMAL MATCH option
         none OF JR:CLOSE E-JR-MALFORMED throw ENDOF
         some OF IMPORT-IDX @ F-PRIORITY REC-CELL ! ENDOF
      ;MATCH
      JR:CLOSE exit
   then
   kind JR:T-FLOAT = if
      JR:SPAN$ {: a:ptr u:n :}
      a u JSONL-DECIMAL MATCH option
         none OF JR:CLOSE E-JR-MALFORMED throw ENDOF
         some OF IMPORT-IDX @ F-PRIORITY REC-CELL ! ENDOF
      ;MATCH
      JR:CLOSE exit
   then
   JR:CLOSE E-JR-MALFORMED throw ;
: JSONL-STATUS ( -- )
   s" status" F-REASON JSONL-REQUIRED-STRING
   IMPORT-IDX @ F-REASON FIELD$ 2dup s" in_progress" STR= if 2drop 1 else
      2dup PARSE-STATUS dup -1 = if drop 0 then
      -rot 2drop
   then IMPORT-IDX @ F-STATUS REC-CELL !
   IMPORT-IDX @ F-REASON FIELD-EMPTY ;
: IMPORT-DEP-ADD ( ptr u8 n -- )
   {: a:ptr u:n :}
   a u VALID-ID? 0= if
      \ One empty entry preserves the post-create warning for this dependency.
      IMPORT-DEP-U @ 1+ IMPORT-DEP-BUF-RESERVE
      10 IMPORT-DEP-U @ IMPORT-DEP-BUF c!
      1 IMPORT-DEP-U +! exit
   then
   IMPORT-DEP-U @ u + 1+ IMPORT-DEP-BUF-RESERVE
   a IMPORT-DEP-U @ IMPORT-DEP-BUF u BYTE-COPY
   10 IMPORT-DEP-U @ u + IMPORT-DEP-BUF c!
   IMPORT-DEP-U @ u 1+ + IMPORT-DEP-U ! ;
: DEP-ID! ( ptr u8 n -- )
   {: a:ptr u:n :}
   a DEP-ID-ROW u BYTE-COPY u DEP-ID-U ! ;
: DEP-TYPE! ( ptr u8 n -- )
   {: a:ptr u:n :}
   a DEP-TYPE-ROW u BYTE-COPY u DEP-TYPE-U ! ;
: JSONL-DEP-OBJECT ( JR:reader -- JR:reader )
   -1 DEP-ID-U ! -1 DEP-TYPE-U !
   0 JSONL-DEP-SEEN !
   begin JR:NEXT dup JR:T-OBJ-END <> while
      JR:T-KEY <> if E-JR-MALFORMED throw then
      s" depends_on_id" JR:STR-EQ? {: id-key:bool :}
      s" type" JR:STR-EQ? {: type-key:bool :}
      id-key if
         JSONL-DEP-SEEN @ 1 and 0<> if E-JR-MALFORMED throw then
         JSONL-DEP-SEEN @ 1 or JSONL-DEP-SEEN !
      then
      type-key if
         JSONL-DEP-SEEN @ 2 and 0<> if E-JR-MALFORMED throw then
         JSONL-DEP-SEEN @ 2 or JSONL-DEP-SEEN !
      then
      JR:NEXT {: token:n :}
      id-key if
         token JR:T-STR <> if E-JR-MALFORMED throw then
         JSONL-DECODE-BUF 1048576 JR:STR {: size:n :}
         JSONL-DECODE-BUF size DEP-ID!
      else type-key if
         token JR:T-NULL = if -1 DEP-TYPE-U ! else
            token JR:T-STR <> if E-JR-MALFORMED throw then
            JSONL-DECODE-BUF 1048576 JR:STR {: size:n :}
            JSONL-DECODE-BUF size DEP-TYPE!
         then
      else JR:SKIP-VALUE then then
   repeat drop
   DEP-ID-U @ -1 = if E-JR-MALFORMED throw then
   DEP-TYPE-U @ -1 = if s" blocks" DEP-TYPE! then
   DEP-TYPE-ROW DEP-TYPE-U @ s" parent-child" STR= if
      IMPORT-IDX @ F-PARENT-PRESENT REC-CELL @ 0= if
         DEP-ID-ROW DEP-ID-U @ IMPORT-IDX @ F-PARENT FIELD!
         1 IMPORT-IDX @ F-PARENT-PRESENT REC-CELL !
      then
   else
      DEP-TYPE-ROW DEP-TYPE-U @ s" blocks" STR= if
         DEP-ID-ROW DEP-ID-U @ IMPORT-DEP-ADD
      then
   then ;
: JSONL-DEPENDENCIES ( -- )
   s" dependencies" JSONL-FIND if
      JR:TOKEN dup JR:T-NULL = if drop JR:CLOSE exit then
      JR:T-ARR <> if JR:CLOSE E-JR-MALFORMED throw then
      begin JR:NEXT dup JR:T-ARR-END <> while
         JR:T-OBJ <> if E-JR-MALFORMED throw then
         JSONL-DEP-OBJECT
      repeat drop JR:CLOSE
   else JR:CLOSE then ;
: JSONL-PARSE-LINE ( -- )
   JSONL-VALIDATE
   s" " NEW-RECORD IMPORT-IDX !
   0 IMPORT-DEP-U !
   s" id" F-ID JSONL-REQUIRED-STRING
   s" title" F-TITLE JSONL-REQUIRED-STRING
   s" description" F-DESC JSONL-STRING-FIELD drop
   JSONL-STATUS JSONL-PRIORITY
   s" issue_type" F-TYPE JSONL-REQUIRED-STRING
   s" assignee" F-ASSIGNEE JSONL-STRING-FIELD if
      1 IMPORT-IDX @ F-ASSIGNEE-PRESENT REC-CELL !
   then
   s" created_at" F-CREATED JSONL-REQUIRED-STRING
   s" updated_at" F-REASON JSONL-STRING-FIELD drop
   IMPORT-IDX @ F-REASON FIELD-EMPTY
   s" closed_at" F-CLOSED JSONL-STRING-FIELD if
      1 IMPORT-IDX @ F-CLOSED-PRESENT REC-CELL !
   then
   s" close_reason" F-REASON JSONL-STRING-FIELD if
      1 IMPORT-IDX @ F-REASON-PRESENT REC-CELL !
   then
   JSONL-DEPENDENCIES ;

DYNAMIC-BUFFER CYCLE-SEEN n
DYNAMIC-BUFFER CYCLE-QUEUE n
variable CYCLE-HEAD
variable CYCLE-TAIL
: WOULD-CYCLE? ( n -- bool )
   {: target:n :}
   ISSUE-N @ CYCLE-SEEN-RESERVE
   ISSUE-N @ 0 ?do 0 i CYCLE-SEEN ! loop
   0 CYCLE-HEAD ! 1 CYCLE-TAIL !
   1 CYCLE-QUEUE-RESERVE target 0 CYCLE-QUEUE !
   begin CYCLE-HEAD @ CYCLE-TAIL @ < while
      CYCLE-HEAD @ CYCLE-QUEUE @ {: idx:n :}
      1 CYCLE-HEAD +!
      idx IMPORT-IDX @ = if true exit then
      idx CYCLE-SEEN @ 0= if
         1 idx CYCLE-SEEN !
         idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
         0 begin dup bu < while
            {: at:n :}
            blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
            block sz FIND-EXACT dup -1 <> if
               CYCLE-TAIL @ 1+ CYCLE-QUEUE-RESERVE
               CYCLE-TAIL @ CYCLE-QUEUE ! 1 CYCLE-TAIL +!
            else drop then
            next
         repeat drop
      then
   repeat false ;
: IMPORT-ADD-BLOCK ( ptr u8 n -- )
   {: block:ptr bu:n :}
   block bu VALID-ID? 0= if 1 DEP-SKIPPED-N +! exit then
   block bu FIND-EXACT dup -1 = if drop 1 DEP-SKIPPED-N +! exit then
   {: target:n :}
   target RECORD-PATH? 0= if 1 DEP-SKIPPED-N +! exit then
   target WOULD-CYCLE? if 1 DEP-SKIPPED-N +! exit then
   IMPORT-IDX @ F-BLOCKS FIELD$ {: old:ptr ou:n :}
   0 BLOCK-U ! 0 VALID !
   0 begin dup ou < while
      {: at:n :}
      old ou at NEXT-LINE drop {: item:ptr iu:n next:n :}
      item iu block bu STR= if 1 VALID ! then
      item iu BLOCK-ADD
      next
   repeat drop
   VALID @ 0<> if exit then
   block bu BLOCK-ADD
   0 BLOCK-BUF BLOCK-U @ IMPORT-IDX @ F-BLOCKS FIELD!
   IMPORT-IDX @ SAVE-RECORD ;
: IMPORT-ADD-DEPENDENCIES ( -- )
   0 begin dup IMPORT-DEP-U @ < while
      {: at:n :}
      0 IMPORT-DEP-BUF IMPORT-DEP-U @ at NEXT-LINE drop
      {: block:ptr bu:n next:n :}
      block bu IMPORT-ADD-BLOCK
      next
   repeat drop ;
: IMPORT-CHILD-FOLDER ( ptr u8 n -- )
   {: parent:ptr pu:n :}
   SB-RESET s" .dots/" SB-APPEND parent pu SB-APPEND SB$ PATH-ONE!
   PATH-ONE$ MAKE-DIRS
   SB-RESET s" .dots/" SB-APPEND parent pu SB-APPEND s" .md" SB-APPEND SB$ PATH-ONE!
   PATH-ONE$ FILE? if
      SB-RESET s" .dots/" SB-APPEND parent pu SB-APPEND
      47 SB-APPEND-C parent pu SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO!
      PATH-ONE$ PATH-TWO$ RENAME-FILE
      ISSUE-N @ 0 ?do
         i F-PATH FIELD$ PATH-ONE$ STR= if
            PATH-TWO$ i F-PATH FIELD!
         then
      loop
   then ;
: IMPORT-DUPLICATE? ( -- bool )
   IMPORT-IDX @ 0 ?do
      i F-ID FIELD$ IMPORT-IDX @ F-ID FIELD$ STR= if true unloop exit then
   loop false ;
: IMPORT-CREATE ( -- )
   IMPORT-IDX @ F-ID FIELD$ VALID-ID? 0= if
      1 IMPORT-SKIPPED-N +! ISSUE-N @ 1- ISSUE-N ! exit
   then
   IMPORT-IDX @ F-PARENT-PRESENT REC-CELL @ 0<> if
      IMPORT-IDX @ F-PARENT FIELD$
      VALID-ID? 0= if
         1 IMPORT-SKIPPED-N +! ISSUE-N @ 1- ISSUE-N ! exit
      then
   then
   IMPORT-DUPLICATE? if ISSUE-N @ 1- ISSUE-N ! exit then
   IMPORT-IDX @ F-PARENT FIELD$ dup 0 > if
      2dup IMPORT-CHILD-FOLDER
      2drop
      1 IMPORT-IDX @ F-CHILD REC-CELL !
   else 2drop then
   SB-RESET s" .dots/" SB-APPEND
   IMPORT-IDX @ F-PARENT FIELD$ dup 0 > if
      SB-APPEND 47 SB-APPEND-C
   else 2drop
      SB$ PATH-ONE!
      SB-RESET PATH-ONE$ SB-APPEND IMPORT-IDX @ F-ID FIELD$ SB-APPEND SB$
      PATH-TWO!
      PATH-TWO$ DIR? if
         SB-RESET PATH-TWO$ SB-APPEND 47 SB-APPEND-C
      else
         SB-RESET PATH-ONE$ SB-APPEND
      then
   then
   IMPORT-IDX @ F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$
   IMPORT-IDX @ F-PATH FIELD!
   IMPORT-IDX @ SAVE-RECORD
   IMPORT-ADD-DEPENDENCIES
   1 IMPORTED-N +! ;
: IMPORT-ARCHIVE-CLOSED ( -- )
   ISSUE-N @ 0 ?do
      i F-ERROR REC-CELL @ 0= i F-ARCHIVED REC-CELL @ 0= and if
         i F-STATUS REC-CELL @ 2 = if
            i STATUS-CHILDREN-OPEN? 0= if i ARCHIVE-STATUS then
         then
      then
   loop ;
: WARN-IMPORT-NUM ( n ptr u8 n -- )
   {: count:n suffix:ptr su:n :}
   count 0= if exit then
   SB-RESET s" Warning: skipped " SB-APPEND count FMT:SB-INT
   suffix su SB-APPEND 10 SB-APPEND-C
   SB$ 2 -rot STDERR-WRITE drop ;
: IMPORT-PROCESS-LINE ( -- )
   JSONL-FILE-U @ 0= if exit then
   ARENA-U @ {: arena-before:n :}
   0 JSONL-FILE-BUF JSONL-LINE-A !
   JSONL-FILE-U @ JSONL-LINE-U !
   [: JSONL-PARSE-LINE ;] catch 0<> if s" Invalid JSONL file" FAIL then
   [: IMPORT-CREATE ;] catch 0<> if
      1 IMPORT-SKIPPED-N +!
      ISSUE-N @ 1- ISSUE-N !
   then
   IMPORT-IDX @ ISSUE-N @ >= if arena-before ARENA-U ! then ;
: IMPORT-JSONL-FILE ( ptr u8 n -- )
   {: path:ptr pu:n :}
   path pu FILE? 0= if exit then
   true LOAD-ISSUES
   0 IMPORTED-N ! 0 IMPORT-SKIPPED-N ! 0 DEP-SKIPPED-N !
   0 JSONL-FILE-U !
   path pu FS-PATHZ open-rd {: fd:n :}
   fd 0 < if s" I/O error" FAIL then
   begin
      fd JSONL-CHUNK 8192 read JSONL-CHUNK-U !
      JSONL-CHUNK-U @ 0 >
   while
      JSONL-CHUNK-U @ 0 ?do
         JSONL-CHUNK i + c@ 10 = if
            IMPORT-PROCESS-LINE 0 JSONL-FILE-U !
         else
            JSONL-FILE-U @ 1+ 1048576 >= if s" JSONL line too long" FAIL then
            JSONL-FILE-U @ 1+ JSONL-FILE-BUF-RESERVE
            JSONL-CHUNK i + c@ JSONL-FILE-U @ JSONL-FILE-BUF c!
            1 JSONL-FILE-U +!
         then
      loop
   repeat
   IMPORT-PROCESS-LINE
   fd close
   IMPORT-ARCHIVE-CLOSED
   IMPORTED-N @ 0 > if
      s" Imported " type IMPORTED-N @ FMT:.INT
      s"  issues from " type path pu type cr
   then
   IMPORT-SKIPPED-N @ s"  issues due to errors" WARN-IMPORT-NUM
   DEP-SKIPPED-N @ s"  dependencies due to errors" WARN-IMPORT-NUM ;
: INIT-FULL-COMMAND ( -- )
   INIT-EMPTY
   1 ARG-I !
   begin ARG-I @ script-argc < while
      ARG-I @ script-argv$ s" --from-jsonl" STR= NEXT-ARG? and if
         TAKE-ARG IMPORT-JSONL-FILE
      then
      1 ARG-I +!
   repeat
   GIT-ADD-DOTS ;
public
: MAIN ( -- )
   script-argc 0= if
      1 USE-JSON ! -1 FILTER ! 1 WANT-READY ! false LOAD-ISSUES PRINT-LIST exit
   then
   0 script-argv$ 2dup s" help" ARG= if 2drop USAGE exit then
   2dup s" -h" ARG= if 2drop USAGE exit then
   2dup s" --help" ARG= if 2drop USAGE exit then
   2dup s" --version" ARG= if 2drop VERSION exit then
   2dup s" -v" ARG= if 2drop VERSION exit then
   2dup s" hook" ARG= if 2drop s" Unknown command: hook" FAIL then
   2dup s" add" ARG= if 2drop 1 ADD-COMMAND exit then
   2dup s" create" ARG= if 2drop 1 ADD-COMMAND exit then
   2dup s" on" ARG= if 2drop 1 STATUS-MULTI exit then
   2dup s" it" ARG= if 2drop 1 STATUS-MULTI exit then
   2dup s" off" ARG= if 2drop 1 CLOSED-STYLE ! 2 STATUS-MULTI exit then
   2dup s" done" ARG= if 2drop 1 CLOSED-STYLE ! 2 STATUS-MULTI exit then
   2dup s" update" ARG= if 2drop 0 CLOSED-STYLE ! -1 STATUS-SINGLE exit then
   2dup s" close" ARG= if 2drop 0 CLOSED-STYLE ! 2 STATUS-SINGLE exit then
   2dup s" init" ARG= if 2drop INIT-FULL-COMMAND exit then
   2dup s" purge" ARG= if 2drop PURGE-COMMAND exit then
   2dup s" rm" ARG= if 2drop RM-COMMAND exit then
   2dup s" delete" ARG= if 2drop RM-COMMAND exit then
   2dup s" tree" ARG= if 2drop TREE-COMMAND exit then
   2dup s" fix" ARG= if 2drop FIX-COMMAND exit then
   2dup s" slugify" ARG= if 2drop SLUGIFY-COMMAND exit then
   2dup s" ls" ARG= if
      2drop 1 PARSE-LIST-ARGS false LOAD-ISSUES PRINT-LIST exit
   then
   2dup s" list" ARG= if
      2drop 1 PARSE-LIST-ARGS false LOAD-ISSUES PRINT-LIST exit
   then
   2dup s" ready" ARG= if
      2drop PARSE-READY-ARGS false LOAD-ISSUES PRINT-LIST exit
   then
   2dup s" show" ARG= if
      2drop script-argc 2 < if s" Usage: dot show <id>" FAIL then
      1 SCAN-NAME-ONLY !
      true LOAD-ISSUES 1 script-argv$ RESOLVE LOAD-TARGET SHOW exit
   then
   2dup s" find" ARG= if
      2drop script-argc 2 < if FIND-USAGE exit then
      FIND-HELP? if FIND-USAGE exit then
      1 script-argv$ QUERY-U ! QUERY-A !
      true LOAD-ISSUES PRINT-FIND exit
   then
   2drop 0 ADD-COMMAND ;

;package

: MAIN ( -- ) DOT-READ:MAIN ;

\ Native, filesystem-compatible dots CLI for the full size comparison.
require src/lib/errors.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-list.f
require src/lib/process-env.f
require src/lib/json-write.f
require src/lib/json-read.f
require src/lib/decimal.f
require src/lib/jsonl.f
require src/lib/utf8-scalar.f
require src/lib/fmt.f
require abbrev.f
require io.f
require lock.f

package DOT-READ

\ The read limits are inclusive: a file of exactly the limit is read.
1048576 constant ISSUE-MAX
65536 constant CONFIG-MAX
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
create FILE-BUF ISSUE-MAX allot
variable FILE-U
DYNAMIC-BUFFER BLOCK-BUF u8
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
\ A command that names its tasks sets SCAN-KEYED: the walk then records only
\ the files SCAN-KEEP? admits and leaves their parsing to the command. Its keys
\ are the ids or prefixes it names, back to back in SCAN-KEY-BYTES, each ending
\ at its SCAN-KEY-ENDS offset. SCAN-FAMILY adds what a status change reaches
\ beyond its keys.
variable SCAN-KEYED
DYNAMIC-BUFFER SCAN-KEY-BYTES u8
DYNAMIC-BUFFER SCAN-KEY-ENDS n
variable SCAN-KEY-N
variable SCAN-FAMILY
DYNAMIC-BUFFER ORDER n
DYNAMIC-BUFFER SORT-BUF n

: FAIL ( ptr u8 n -- ) 1 die ;
: ?FAIL ( bool ptr u8 n -- ) rot if FAIL then 2drop ;
: ?CAP-FAIL ( bool -- ) s" Capacity exceeded" ?FAIL ;
\ The prefix goes to fd 2 as written, partial writes continued, and die ends
\ the line with the id, so no buffer bounds a path the message names. die
\ writes nothing for an empty span: an empty id leaves the prefix the message.
: ISSUE-ERROR ( ptr u8 n ptr u8 n -- )
   {: prefix:ptr pu:n id:ptr iu:n :}
   iu 0= if prefix pu FAIL then
   0 begin dup pu < while
      {: at:n :}
      2 prefix at + pu at - write {: written:n :}
      written 0 <= if pu else at written + then
   repeat drop
   id iu FAIL ;
: ?ISSUE-ERROR ( bool ptr u8 n ptr u8 n -- )
   {: c:bool prefix:ptr pu:n id:ptr iu:n :}
   c if prefix pu id iu ISSUE-ERROR then ;
: ?ARG-NOT-FOUND ( bool -- )
   if s" Issue not found: " 1 script-argv$ ISSUE-ERROR then ;

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
\ The record id index: chained hash buckets of record numbers. It holds
\ exactly the records 0..ISSUE-N-1, keyed by their current F-ID. It keeps no
\ key pointer, since arena growth remaps and the import rewinds the arena:
\ lookup re-reads each candidate's id through FIELD$. ID-HEADS holds the first
\ record of each bucket and ID-NEXT the record after each, -1 for none.
DYNAMIC-BUFFER ID-HEADS n
DYNAMIC-BUFFER ID-NEXT n
variable ID-BUCKETS
\ FNV-1a, its high half folded onto the low bits a power-of-two table masks.
: STR-HASH ( ptr u8 n -- n )
   {: a:ptr u:n :}
   $CBF29CE484222325 u 0 ?do a i + c@ xor $100000001B3 * loop
   dup 32 rshift xor ;
: BUCKET ( n n -- n ) 1- and ;   \ hash, bucket count (a power of two)
: ID-CHAIN ( n -- )
   {: idx:n :}
   idx F-ID FIELD$ STR-HASH ID-BUCKETS @ BUCKET {: b:n :}
   b ID-HEADS @ idx ID-NEXT !
   idx b ID-HEADS ! ;
\ At least 64 buckets, doubled until no fewer than the records.
: ID-REBUILD ( -- )
   ID-BUCKETS @ 64 max begin dup ISSUE-N @ < while 2 * repeat {: count:n :}
   count ID-BUCKETS !
   count ID-HEADS-RESERVE
   count 0 ?do -1 i ID-HEADS ! loop
   ISSUE-N @ ID-NEXT-RESERVE
   ISSUE-N @ 0 ?do i ID-CHAIN loop ;
\ Index a record whose F-ID is written, below ISSUE-N.
: ID-LINK ( n -- )
   ISSUE-N @ ID-BUCKETS @ > if drop ID-REBUILD exit then
   ISSUE-N @ ID-NEXT-RESERVE ID-CHAIN ;
: ID-UNLINK ( n -- )
   {: idx:n :}
   idx F-ID FIELD$ STR-HASH ID-BUCKETS @ BUCKET {: b:n :}
   b ID-HEADS @ idx = if idx ID-NEXT @ b ID-HEADS ! exit then
   b ID-HEADS @ begin dup ID-NEXT @ idx <> while ID-NEXT @ repeat
   {: prev:n :}
   idx ID-NEXT @ prev ID-NEXT ! ;
\ The only writer of an existing record's id.
: ID! ( ptr u8 n n -- )
   {: a:ptr u:n idx:n :}
   idx ID-UNLINK a u idx F-ID FIELD! idx ID-LINK ;
\ Drop the last record.
: POP-RECORD ( -- ) ISSUE-N @ 1- dup ID-UNLINK ISSUE-N ! ;
: PATH-AT ( n -- ptr u8 ) FS-PATH-CAP * PATHS + ;
: PATH-JOIN ( ptr u8 n ptr u8 n ptr u8 -- n ) JOIN-PATH ;
\ A record's own folder is the directory of its path when that directory lies
\ below the record's partition root and is named after it. The length of that
\ directory in the path, or 0 without one.
: OWN-FOLDER-U ( n -- n )
   {: idx:n :}
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   pu path pu BASENAME nip - 1- {: dir-u:n :}
   idx F-ARCHIVED REC-CELL @ 0<> if s" .dots/archive" else s" .dots" then nip
   dir-u >= if 0 exit then
   path dir-u BASENAME idx F-ID FIELD$ STR= if dir-u else 0 then ;
: OWN-FOLDER? ( n -- bool ) OWN-FOLDER-U 0 > ;
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
128 constant ID-MAX
: VALID-ID? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   u 0= u ID-MAX > or if false exit then
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
\ `archive` names the archive partition; existing records still read under VALID-ID?.
: CREATABLE-ID? ( ptr u8 n -- bool )
   2dup VALID-ID? 0= if 2drop false exit then
   s" archive" STR= 0= ;
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
      val vu DECIMAL:EXACT MATCH option
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

\ The frontmatter closes on its first line that is exactly `---`, or `---` and
\ a CR. Return that line's offset and the offset past it.
: DELIMITER? ( ptr u8 n -- bool )
   2dup s" ---" STR= if 2drop true exit then
   s\" ---\r" STR= ;
: FRONT-END ( n -- n n bool )
   begin dup FILE-U @ < while
      {: at:n :}
      FILE-BUF FILE-U @ at NEXT-LINE drop {: line:ptr lu:n next:n :}
      line lu DELIMITER? if at next FILE-U @ min true exit then
      next
   repeat 0 false ;

: PARSE-RECORD ( n -- )
   {: idx:n :}
   idx CURRENT !
   0 VALID ! 0 BLOCK-ON ! 0 BLOCK-U !
   1 idx F-ERROR REC-CELL !
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   path pu [: 2dup FILE-BUF ISSUE-MAX READ-ALL FILE-U ! ;] catch
   dup E-FS-CAPACITY = s" Issue file too large: " path pu ?ISSUE-ERROR
   dup 0<> if throw then drop 2drop
   FILE-BUF FILE-U @ 0 NEXT-LINE {: head:ptr hu:n off:n more:bool :}
   head hu s" ---" STR= 0= if exit then
   more 0= if exit then
   off FRONT-END 0= if 2drop exit then {: endpos:n body:n :}
   FILE-BUF body + FILE-U @ body - TRIM CURRENT @ F-DESC FIELD!
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

: PARSE-FILE ( ptr u8 n ptr u8 n bool bool -- )
   {: path:ptr pu:n id:ptr iu:n archived:bool child:bool :}
   ISSUE-N @ 1+ REC-CELLS * RECORDS-RESERVE
   ISSUE-N @ CURRENT !
   id iu CURRENT @ F-ID FIELD!
   path pu CURRENT @ F-PATH FIELD!
   CURRENT @ F-TITLE FIELD-EMPTY
   CURRENT @ F-DESC FIELD-EMPTY
   CURRENT @ F-BLOCKS FIELD-EMPTY
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
   CURRENT @ ID-LINK
   SCAN-KEYED @ 0= if CURRENT @ PARSE-RECORD then ;
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
: SCANNED-NAME ( n -- ptr u8 n n )
   {: at:n :}
   at SCAN-NAMES c@ at 1+ SCAN-NAMES c@ 256 * + {: size:n :}
   at 2 + SCAN-NAMES size at size 2 + + ;

: SCAN-KEY+ ( ptr u8 n -- )
   {: a:ptr u:n :}
   SCAN-KEY-N @ 0 > if SCAN-KEY-N @ 1- SCAN-KEY-ENDS @ else 0 then {: start:n :}
   start u + 1+ SCAN-KEY-BYTES-RESERVE
   a start SCAN-KEY-BYTES u BYTE-COPY
   SCAN-KEY-N @ 1+ SCAN-KEY-ENDS-RESERVE
   start u + SCAN-KEY-N @ SCAN-KEY-ENDS !
   1 SCAN-KEY-N +! ;
: KEY-PREFIX? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   0 SCAN-KEY-N @ 0 ?do
      {: start:n :}
      i SCAN-KEY-ENDS @ {: end:n :}
      a u start SCAN-KEY-BYTES end start - STARTS-WITH? if true unloop exit then
      end
   loop drop false ;
\ Below is set under a directory a key starts and owner for a folder's own
\ file. With SCAN-FAMILY these are kept: the descendants and the ancestors a
\ status change reaches.
: SCAN-KEEP? ( ptr u8 n bool bool -- bool )
   {: id:ptr iu:n below:bool owner:bool :}
   SCAN-KEYED @ 0= below or if true exit then
   SCAN-FAMILY @ 0<> owner and if true exit then
   id iu KEY-PREFIX? ;

\ A separate names and path buffer per level permits recursive scans.
: SCAN-DIR ( n n bool bool -- )
   {: depth:n plen:n archived:bool below:bool :}
   depth MAX-DEPTH 1- >= ?CAP-FAIL
   depth PATH-AT {: path:ptr :}
   \ A nested file named after its directory is that folder's own task, a child
   \ of the folder enclosing it below the top level; any other nested file is a
   \ child of its directory.
   path plen BASENAME {: dir:ptr du:n :}
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
         \ A path is bounded only by the fs library's FS-PATH-CAP.
         plen nu + 1+ FS-PATH-CAP > s" I/O error" ?FAIL
         path plen name nu depth 1+ PATH-AT PATH-JOIN {: child-u:n :}
         depth 1+ PATH-AT {: child:ptr :}
         \ One lstat types the entry: symlinks, other types and unstatable
         \ entries match neither branch and are skipped.
         child child-u FS-TRY-LSTAT-MODE MATCH option
            none OF 0 ENDOF
            some OF S-IFMT and ENDOF
         ;MATCH {: kind:n :}
         kind S-IFREG = name nu FILE-ENTRY? and if
            name nu 3 - {: id:ptr iu:n :}
            depth 0 > if dir du id iu STR= else false then {: owner:bool :}
            depth 0 > owner 0= and owner depth 1 > and or {: has-parent:bool :}
            id iu below owner SCAN-KEEP? if
               child child-u id iu archived has-parent PARSE-FILE
               has-parent if
                  owner if path plen du - 1- BASENAME else dir du then
                  CURRENT @ F-PARENT FIELD!
               then
            then
         else
            kind S-IFDIR = if
               SCAN-FAMILY @ 0<> if name nu KEY-PREFIX? else false then
               below or {: inner:bool :}
               depth 1+ child-u archived inner RECURSE
            then
         then
         next
      then
   repeat drop ;

\ Whether .dots exists. Reading creates nothing: without .dots the store is
\ empty, and the archive is read only where it is a directory.
: STORE? ( -- bool ) s" .dots" FS-TRY-LSTAT ;
: LOAD-ISSUES ( bool -- )
   {: include-archive:bool :}
   0 ISSUE-N ! 0 ID-BUCKETS ! 0 ARENA-U ! 0 SCAN-NAMES-U !
   STORE? 0= if exit then
   s" .dots" 0 PATH-AT swap BYTE-COPY
   0 s" .dots" nip false false SCAN-DIR
   include-archive if
      s" .dots/archive" DIR? if
         s" .dots/archive" 0 PATH-AT swap BYTE-COPY
         0 s" .dots/archive" nip true false SCAN-DIR
      then
   then ;
: LOAD-TARGET ( n -- n )
   {: idx:n :}
   idx F-ID FIELD$ VALID-ID? 0= s" Invalid issue id" ?FAIL
   idx PARSE-RECORD
   idx ;

\ Records sharing an id fall back to their paths, which are unique, so both
\ orders are total and the same on every filesystem.
: ID-LESS? ( n n -- bool )
   {: a:n b:n :}
   a F-ID FIELD$ b F-ID FIELD$ STR= if
      a F-PATH FIELD$ b F-PATH FIELD$ STR< exit
   then
   a F-ID FIELD$ b F-ID FIELD$ STR< ;
\ Listing order: priority, then created-at bytewise, then id.
: ISSUE-LESS? ( n n -- bool )
   {: a:n b:n :}
   a F-PRIORITY REC-CELL @ b F-PRIORITY REC-CELL @ <> if
      a F-PRIORITY REC-CELL @ b F-PRIORITY REC-CELL @ < exit
   then
   a F-CREATED FIELD$ b F-CREATED FIELD$ STR= if a b ID-LESS? exit then
   a F-CREATED FIELD$ b F-CREATED FIELD$ STR< ;
: TAKE-RIGHT? ( n n n [ n n -- bool ] -- bool )
   {: l:n r:n hi:n less :}
   r hi < if r ORDER @ l SORT-BUF @ less execute exit then
   false ;
\ Merge sorted ORDER[lo,mid) and ORDER[mid,hi) via a SORT-BUF copy of the left
\ run.
: MERGE-RUN ( n n n [ n n -- bool ] -- )
   {: lo:n mid:n hi:n less :}
   mid lo ?do i ORDER @ i lo - SORT-BUF ! loop
   0 mid begin
      {: l:n r:n :}
      l mid lo - <
   while
      l r + mid - lo + {: k:n :}
      l r hi less TAKE-RIGHT? if
         r ORDER @ k ORDER ! l r 1+
      else
         l SORT-BUF @ k ORDER ! l 1+ r
      then
   repeat ;
: MERGE-PASS ( n [ n n -- bool ] -- )
   {: width:n less :}
   0 begin
      {: lo:n :}
      lo width + ISSUE-N @ <
   while
      lo lo width + lo width 2 * + ISSUE-N @ min less MERGE-RUN
      lo width 2 * +
   repeat ;
\ ORDER holds every record index sorted by the total order `less`.
: SORT-ISSUES ( [ n n -- bool ] -- )
   {: less :}
   ISSUE-N @ ORDER-RESERVE
   ISSUE-N @ SORT-BUF-RESERVE
   ISSUE-N @ 0 ?do i i ORDER ! loop
   1 begin dup ISSUE-N @ < while dup less MERGE-PASS 2 * repeat drop ;

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

: JSON-BYTES ( ptr writer ptr u8 n -- ptr writer )
   {: w:ptr a:ptr u:n :}
   a u UTF8:VALID? if w a u JSON-WRITE:STRING exit then
   w JSON-WRITE:ARRAY-START
   u 0 ?do
      i 0<> if JSON-WRITE:COMMA then
      a i + c@ JSON-WRITE:U
   loop
   JSON-WRITE:ARRAY-END ;
: JSON-FIELD-S ( ptr writer n n ptr u8 n -- ptr writer )
   {: w:ptr idx:n field:n key:ptr ku:n :}
   w key ku JSON-WRITE:KEY idx field FIELD$ JSON-BYTES ;
: JSON-FIELD-OPT ( ptr writer n n ptr u8 n -- ptr writer )
   {: w:ptr idx:n field:n key:ptr ku:n :}
   field F-CLOSED = if
      idx F-CLOSED-PRESENT REC-CELL @ 0= if w key ku JSON-WRITE:FIELD-NULL exit then
   else
      idx field FIELD$ nip 0= if w key ku JSON-WRITE:FIELD-NULL exit then
   then
   w key ku JSON-WRITE:KEY idx field FIELD$ JSON-BYTES ;
: JSON-FIELD-REASON ( ptr writer n -- ptr writer )
   {: w:ptr idx:n :}
   idx F-REASON-PRESENT REC-CELL @ 0= if
      w s" close_reason" JSON-WRITE:FIELD-NULL
   else
      w s" close_reason" JSON-WRITE:KEY idx F-REASON FIELD$ JSON-BYTES
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
   s" [" DOT-IO:PRINT idx F-ID FIELD$ DOT-IO:PRINT s" ] " DOT-IO:PRINT
   idx F-STATUS REC-CELL @ STATUS>CHAR DOT-IO:PRINT-BYTE 32 DOT-IO:PRINT-BYTE
   idx F-TITLE FIELD$ DOT-IO:PRINTLN ;
: PRINT-LIST ( -- )
   ['] ISSUE-LESS? SORT-ISSUES
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
      JSON-WRITE:ARRAY-END dup JSON-WRITE:$ DOT-IO:PRINTLN JSON-WRITE:CLOSE
      JSON-OUT-BUF BUF:DISPOSE
   else
      ISSUE-N @ 0 ?do i ORDER @ dup SHOW-IN-LIST? if PRINT-ISSUE else drop then loop
   then ;

: CONTAINS-CI? ( ptr u8 n ptr u8 n -- bool )
   {: a:ptr au:n q:ptr qu:n :}
   qu au > if false exit then
   qu 0= if true exit then
   \ Fold the first query byte once; compare the rest only where it matches.
   q c@ ASCII-LOWER {: first:n :}
   au qu - 1+ 0 ?do
      a i + c@ ASCII-LOWER first = if
         a i + 1+ qu 1- q 1+ qu 1- STR=CI if true unloop exit then
      then
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
   ['] ISSUE-LESS? SORT-ISSUES
   ISSUE-N @ 0 ?do
      i ORDER @ {: idx:n :}
      idx F-STATUS REC-CELL @ 2 <> if idx MATCHES? if idx PRINT-ISSUE then then
   loop
   ISSUE-N @ 0 ?do
      i ORDER @ {: idx:n :}
      idx F-STATUS REC-CELL @ 2 = if idx MATCHES? if idx PRINT-ISSUE then then
   loop ;

: RESOLVE ( ptr u8 n -- n )
   {: prefix:ptr pu:n :}
   -1 MATCH-I !
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ prefix pu STARTS-WITH? if
         MATCH-I @ -1 <> s" Ambiguous ID: " prefix pu ?ISSUE-ERROR
         i MATCH-I !
      then
   loop
   MATCH-I @ -1 = s" Issue not found: " prefix pu ?ISSUE-ERROR
   MATCH-I @ ;
: CHECK-ERROR ( n -- )
   F-ERROR REC-CELL @ dup 2 = s" Invalid issue status" ?FAIL
   0<> s" Invalid issue frontmatter" ?FAIL ;
: SHOW ( n -- )
   {: idx:n :}
   idx CHECK-ERROR
   s" ID:       " DOT-IO:PRINT idx F-ID FIELD$ DOT-IO:PRINTLN
   s" Title:    " DOT-IO:PRINT idx F-TITLE FIELD$ DOT-IO:PRINTLN
   s" Status:   " DOT-IO:PRINT idx F-STATUS REC-CELL @ STATUS>DISPLAY DOT-IO:PRINTLN
   s" Priority: " DOT-IO:PRINT idx F-PRIORITY REC-CELL @ DOT-IO:INT DOT-IO:NL
   idx F-DESC FIELD$ dup 0<> if s" Desc:     " DOT-IO:PRINT DOT-IO:PRINTLN else 2drop then
   s" Created:  " DOT-IO:PRINT idx F-CREATED FIELD$ DOT-IO:PRINTLN
   idx F-CLOSED FIELD$ dup 0<> if s" Closed:   " DOT-IO:PRINT DOT-IO:PRINTLN else 2drop then
   idx F-REASON-PRESENT REC-CELL @ 0<> if
      s" Reason:   " DOT-IO:PRINT idx F-REASON FIELD$ DOT-IO:PRINTLN
   then ;

: ARG= ( ptr u8 n ptr u8 n -- bool ) STR= ;
: USAGE ( -- )
   s\" dots - Connect the dots\n\nUsage: dot [command] [options]\n\nCommands:\n  dot \"title\"                  Quick add a dot\n  dot add \"title\" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)\n  dot ls [--status S] [--json] List dots\n  dot on <id>                  Start working (turn it on!)\n  dot off <id> [-r reason]     Complete (\"cross it off\")\n  dot rm <id>                  Remove a dot\n  dot show <id>                Show dot details\n  dot ready [--json]           Show unblocked dots\n  dot tree [id]                Show hierarchy (with id: includes closed children)\n  dot fix                      Repair orphan and legacy folders\n  dot find \"query\"             Search all dots (open first, then archived)\n  dot purge                    Delete archived dots\n  dot init                     Initialize .dots directory\n\nExamples:\n  dot \"Fix the bug\"\n  dot add \"Design API\" -p 1 -d \"REST endpoints\"\n  dot add \"Implement\" -P dots-1 -a dots-2\n  dot on dots-3\n  dot off dots-3 -r \"shipped\"\n" DOT-IO:PRINT ;
: VERSION ( -- ) s" dots 0.6.4" DOT-IO:PRINTLN ;
: FIND-USAGE ( -- )
   s\" Usage: dot find <query>\n\nSearch all dots (open first, then archived).\n\nSearches: title, description, close-reason, created-at, closed-at\n\nExamples:\n  dot find \"auth\"      Search for dots mentioning auth\n  dot find \"2026-01\"   Find dots from January 2026\n" DOT-IO:PRINT ;
: PARSE-LIST-ARGS ( n -- )
   0 USE-JSON ! -1 FILTER ! 0 WANT-READY !
   script-argc swap ?do
      i script-argv$ 2dup s" --json" ARG= if 2drop 1 USE-JSON ! else
      2dup s" --status" ARG= if
         2drop i 1+ script-argc < if
            i 1+ script-argv$ PARSE-STATUS dup -1 =
            s" Invalid status: " i 1+ script-argv$ ?ISSUE-ERROR FILTER !
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
2 constant FS-NO-ENTRY
13 constant FS-ACCESS-DENIED
: FS-DIR-NOT-EMPTY ( -- n ) HB-TARGET-MACOS? if 66 else 39 then ;
\ The errno a mutation of path failed with: a non-empty directory where it
\ needs an empty one is named, any other cause is an I/O error.
: ?FS-MUTATION-ERROR ( n ptr u8 n -- )
   {: reason:n path:ptr pu:n :}
   reason 0= if exit then
   reason FS-ACCESS-DENIED = s" Permission denied" ?FAIL
   reason FS-DIR-NOT-EMPTY = s" Directory not empty: " path pu ?ISSUE-ERROR
   E-FS-IO throw ;
PROCESS-SYMBOLS
FUNCTION: RENAME-CALL rename ( ptr u8 ptr u8 -- i32 ) ;FUNCTION
FUNCTION: RENAME-X-CALL renamex_np ( ptr u8 ptr u8 n -- i32 ) ;FUNCTION
FUNCTION: RENAME-AT2-CALL renameat2 ( n ptr u8 n ptr u8 n -- i32 ) ;FUNCTION
FUNCTION: UNLINK-CALL unlink ( ptr u8 -- i32 ) ;FUNCTION
FUNCTION: RMDIR-CALL rmdir ( ptr u8 -- i32 ) ;FUNCTION
: FS-CAUSE ( n -- n )
   0< if FFI:ERRNO dup 0= if drop -1 then exit then
   0 ;
: RENAME-CAUSE ( ptr u8 n ptr u8 n -- n )
   {: src:ptr su:n dst:ptr du:n :}
   src su FS-PATHZ dst du FS-MUT-PATHZ2 RENAME-CALL FS-CAUSE ;
: RENAME-ISSUE ( ptr u8 n ptr u8 n -- )
   {: src:ptr su:n dst:ptr du:n :}
   src su dst du RENAME-CAUSE dst du ?FS-MUTATION-ERROR ;
\ macOS RENAME_EXCL is 4; Linux RENAME_NOREPLACE is 1 and AT_FDCWD is -100.
\ Both calls refuse an occupied destination in the same rename operation.
: RENAME-NOREPLACE-CAUSE ( ptr u8 n ptr u8 n -- n )
   {: src:ptr su:n dst:ptr du:n :}
   src su FS-PATHZ {: src-z:ptr :}
   dst du FS-MUT-PATHZ2 {: dst-z:ptr :}
   HB-TARGET-MACOS? if
      src-z dst-z 4 RENAME-X-CALL FS-CAUSE
   else
      HB-TARGET-LINUX? if
         -100 src-z -100 dst-z 1 RENAME-AT2-CALL FS-CAUSE
      else E-FS-IO throw then
   then ;
: RENAME-ISSUE-NOREPLACE ( ptr u8 n ptr u8 n -- )
   {: src:ptr su:n dst:ptr du:n :}
   src su dst du RENAME-NOREPLACE-CAUSE
   dup 17 = over FS-DIR-NOT-EMPTY = or s" Issue already exists" ?FAIL
   dst du ?FS-MUTATION-ERROR ;
: REMOVE-ISSUE-FILE ( ptr u8 n -- )
   {: path:ptr pu:n :}
   path pu FS-PATHZ UNLINK-CALL FS-CAUSE path pu ?FS-MUTATION-ERROR ;
: REMOVE-ISSUE-DIR ( ptr u8 n -- )
   {: path:ptr pu:n :}
   path pu FS-PATHZ RMDIR-CALL FS-CAUSE path pu ?FS-MUTATION-ERROR ;
PROCESS-SYMBOLS
FUNCTION: ACCESS-CALL access ( ptr u8 n -- i32 ) ;FUNCTION
: PARENT-WRITABLE? ( ptr u8 n -- bool )
   {: path:ptr pu:n :}
   pu begin dup 0 > while
      dup 1- path + c@ 47 = if
         1- path swap FS-PATHZ 2 ACCESS-CALL 0= exit
      then
      1-
   repeat drop
   s" ." FS-PATHZ 2 ACCESS-CALL 0= ;
PTR-VARIABLE RESERVED-TEMP
variable RESERVED-U
variable RESERVED-FD
-91001 constant E-ISSUE-PERMISSION
-91002 constant E-ISSUE-ISDIR
-91003 constant E-ISSUE-TOO-LARGE
\ The path an E-ISSUE-ISDIR or E-ISSUE-TOO-LARGE names. It reached a syscall,
\ so it fits FS-PATH-CAP.
create FAILED-PATH FS-PATH-CAP allot
variable FAILED-PATH-U
: FAILED-PATH$ ( -- ptr u8 n ) FAILED-PATH FAILED-PATH-U @ ;
: PATH-THROW ( ptr u8 n n -- )
   {: path:ptr pu:n code:n :}
   path FAILED-PATH pu BYTE-COPY pu FAILED-PATH-U !
   code throw ;
: TEMP-THROW ( n ptr u8 n n -- )
   {: fd:n temp:ptr tu:n code:n :}
   fd close temp tu REMOVE-FILE code throw ;
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
         FFI:ERRNO FS-ACCESS-DENIED = if E-ISSUE-PERMISSION throw then
      then
   then
   code throw ;
: WRITE-ATOMIC-THROW ( ptr u8 n ptr u8 n -- )
   {: path:ptr pu:n src:ptr su:n :}
   path pu RESERVE-ISSUE-SIBLING {: temp:ptr tu:n fd:n :}
   0 begin dup su < while
      {: off:n :}
      fd src off + su off - write {: count:n :}
      count 0 <= if fd temp tu E-FS-IO TEMP-THROW then
      off count +
   repeat drop
   fd FSYNC-CALL 0<> if fd temp tu E-FS-IO TEMP-THROW then
   fd close
   temp tu path pu RENAME-CAUSE {: reason:n :}
   reason 0<> if
      temp tu REMOVE-FILE
      path pu DIR? if path pu E-ISSUE-ISDIR PATH-THROW then
      reason FS-ACCESS-DENIED = if E-ISSUE-PERMISSION throw then
      E-FS-IO throw
   then ;
\ Whether code is a failure of Habu's filesystem or directory listing words.
: FS-FAILURE? ( n -- bool )
   {: code:n :}
   code E-FS-LAST >= code E-FS-FIRST <= and
   code E-FS-LIST-LAST >= code E-FS-LIST-FIRST <= and or ;
\ Ends dot with the message a failure's code names; a filesystem failure
\ without one is an I/O error. Any other code is not dot's to name.
: REPORT-FAILURE ( n -- )
   dup E-ISSUE-PERMISSION = s" Permission denied" ?FAIL
   dup E-ISSUE-ISDIR = s" Not a file: " FAILED-PATH$ ?ISSUE-ERROR
   dup E-ISSUE-TOO-LARGE = s" Issue file too large: " FAILED-PATH$ ?ISSUE-ERROR
   dup FS-FAILURE? s" I/O error" ?FAIL
   throw ;
\ Runs xt; a failure it throws ends dot with the message REPORT-FAILURE names.
: REPORTING ( [ -- ] -- )
   catch {: code:n :}
   code 0<> if code REPORT-FAILURE then ;
PTR-VARIABLE WRITE-PATH
variable WRITE-PATH-U
PTR-VARIABLE WRITE-SRC
variable WRITE-SRC-U
: WRITE-ATOMIC ( ptr u8 n ptr u8 n -- )
   {: path:ptr pu:n src:ptr su:n :}
   path WRITE-PATH ! pu WRITE-PATH-U !
   src WRITE-SRC ! su WRITE-SRC-U !
   [: WRITE-PATH @ WRITE-PATH-U @ WRITE-SRC @ WRITE-SRC-U @
      WRITE-ATOMIC-THROW ;] catch
   dup 0<> if REPORT-FAILURE else drop then ;
: SAVE-RECORD-THROW ( n -- )
   {: idx:n :}
   idx SERIALIZE
   idx F-PATH FIELD$ OUT$ WRITE-ATOMIC-THROW ;
: SAVE-RECORD ( n -- )
   {: idx:n :}
   idx SERIALIZE
   idx F-PATH FIELD$ OUT$ WRITE-ATOMIC ;

\ Times are local; a new id ends in a secure 32-bit random suffix.
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
create CONFIG-ROW CONFIG-MAX allot
variable CONFIG-U
variable PREFIX-STORED                  \ 1: the config holds the prefix
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
   TIMEVAL 0 GETTIME-CALL 0<> s" Invalid system time" ?FAIL
   TIMEVAL CALENDAR LOCALTIME-CALL NULL-PTR = s" Failed to read local time" ?FAIL
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
   CWD-ROW 4096 GETCWD-CALL NULL-PTR = s" I/O error" ?FAIL
   0 begin dup 4096 < while
      dup CWD-ROW + c@ 0= if exit then 1+
   repeat ;
: PREFIX! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u 65536 > ?CAP-FAIL
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
\ Whether .dots/config exists; anything there but a file is refused.
: CONFIG? ( -- bool )
   s" .dots/config" FS-TRY-STAT-MODE MATCH option
      none OF false ENDOF
      some OF S-IFMT and S-IFREG <> s" Not a file: .dots/config" ?FAIL true ENDOF
   ;MATCH ;
: LOAD-PREFIX ( -- )
   0 CONFIG-U ! 1 PREFIX-STORED !
   CONFIG? if
      [: s" .dots/config" CONFIG-ROW CONFIG-MAX READ-ALL CONFIG-U ! ;] catch
      dup E-FS-CAPACITY = s" Config file too large: .dots/config" ?FAIL
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
   0 PREFIX-STORED !
   CWD-LEN CWD-ROW swap BASENAME {: base:ptr size:n :}
   size begin dup 0 > if base over 1- + c@ 45 = else false then while
      1-
   repeat {: trim:n :}
   trim 0= if s" dot" PREFIX! else base trim PREFIX! then ;
\ add records a derived prefix, the only change it makes to the config: the
\ other keys stay, a repeated key once with its last value. A symlinked config
\ is read through and never replaced.
: SAVE-CONFIG ( -- )
   PREFIX-STORED @ if exit then
   s" .dots/config" SYMLINK? s" Config is a symlink: .dots/config" ?FAIL
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
   OUT$ nip CONFIG-MAX > s" Config file too large: .dots/config" ?FAIL
   s" .dots/config" OUT$ WRITE-ATOMIC ;

\ A slug ends at the last whole word within SLUG-CAP bytes, or at SLUG-CAP when
\ its first word is longer. Its bytes are ASCII, so the cut is a UTF-8 boundary.
30 constant SLUG-CAP
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
         SB$ nip SLUG-CAP > if unloop exit then
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
            SB$ nip SLUG-CAP >= WORD-COUNT @ 3 >= or if leave then
         then
      then
   loop
   SB$ {: slug:ptr size:n :}
   size SLUG-CAP > if
      SLUG-CAP begin dup 0 > if slug over 1- + c@ 45 <> else false then while 1- repeat
      dup 0 > if 1- else drop SLUG-CAP then
   else size then {: final:n :}
   final 0= if s" untitled" {: fallback:ptr fu:n :}
      fallback SLUG-ROW fu BYTE-COPY fu SLUG-U !
   else
      slug SLUG-ROW final BYTE-COPY final SLUG-U !
   then
   SLUG-ROW SLUG-U @ ;
\ A new id is the prefix, the title's slug and a random suffix. One longer
\ than ID-MAX fails as invalid before SB holds it, whatever the prefix's length.
: NEW-ID$ ( ptr u8 n -- ptr u8 n )
   SLUGIFY$ 2drop
   PREFIX-U @ 1+ SLUG-U @ + 1+ 8 + ID-MAX > s" Invalid issue id" ?FAIL
   RANDOM-SUFFIX drop HEX-ROW 8 BYTE-COPY
   SB-RESET PREFIX$ SB-APPEND 45 SB-APPEND-C
   SLUG-ROW SLUG-U @ SB-APPEND 45 SB-APPEND-C
   HEX-ROW 8 SB-APPEND SB$ ;

create PATH-ONE FS-PATH-CAP allot
variable PATH-ONE-U
create PATH-TWO FS-PATH-CAP allot
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
   u FS-PATH-CAP > s" I/O error" ?FAIL
   a PATH-ONE u BYTE-COPY u PATH-ONE-U ! ;
: PATH-TWO! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u FS-PATH-CAP > s" I/O error" ?FAIL
   a PATH-TWO u BYTE-COPY u PATH-TWO-U ! ;
: PATH-ONE$ ( -- ptr u8 n ) PATH-ONE PATH-ONE-U @ ;
: PATH-TWO$ ( -- ptr u8 n ) PATH-TWO PATH-TWO-U @ ;
\ Whether an argument after the first is the text: quick add's first argument
\ is its title, whatever it reads.
: ARG-AT? ( ptr u8 n -- bool )
   {: a:ptr u:n :}
   script-argc 1 ?do i script-argv$ a u STR= if true unloop exit then loop false ;
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
\ The lowest record with the id, or -1. Filesystem ids may repeat and ID!
\ reorders a chain, so the walk keeps the least match.
: FIND-EXACT ( ptr u8 n -- n )
   {: a:ptr u:n :}
   ID-BUCKETS @ 0= if -1 exit then
   -1 a u STR-HASH ID-BUCKETS @ BUCKET ID-HEADS @
   begin dup -1 <> while
      {: best:n at:n :}
      at F-ID FIELD$ a u STR= best -1 = at best < or and
      if at else best then
      at ID-NEXT @
   repeat drop ;
: RESOLVE-LABELED ( ptr u8 n ptr u8 n -- n )
   {: a:ptr u:n label:ptr lu:n :}
   a u FIND-PREFIX
   dup -1 = label lu a u ?ISSUE-ERROR
   dup -2 = s" Ambiguous ID: " a u ?ISSUE-ERROR ;
: NEW-RECORD ( ptr u8 n -- n )
   {: id:ptr iu:n :}
   ISSUE-N @ 1+ REC-CELLS * RECORDS-RESERVE
   ISSUE-N @ {: idx:n :}
   ISSUE-N @ 1+ ISSUE-N !
   id iu idx F-ID FIELD!
   idx ID-LINK
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
\ A parent's own folder, built in SB: the one it has, else D/p beside its file
\ D/p.md, D being a partition root or the own folder of p's parent.
: OWN-FOLDER$ ( n -- ptr u8 n )
   {: idx:n :}
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   idx OWN-FOLDER-U {: own-u:n :}
   SB-RESET
   own-u 0 > if path own-u SB-APPEND SB$ exit then
   path pu path pu BASENAME nip - SB-APPEND idx F-ID FIELD$ SB-APPEND SB$ ;
\ Refuses a record whose file D/<id>.md would not fit FS-PATH-CAP, given the
\ length of its folder D.
: CHECK-FILE-FITS ( n n -- )
   {: du:n idx:n :}
   du 1+ idx F-ID FIELD$ nip + 3 + FS-PATH-CAP > s" I/O error" ?FAIL ;
\ Refuses a parent whose own folder path holds anything but a directory, a link
\ included, or whose file moved into it would not fit FS-PATH-CAP. SB holds
\ the own folder.
: CHECK-OWN-FOLDER ( n -- )
   {: idx:n :}
   idx OWN-FOLDER$ {: own:ptr ou:n :}
   own ou FS-TRY-LSTAT-MODE MATCH option
      none OF false ENDOF
      some OF S-IFMT and S-IFDIR <> ENDOF
   ;MATCH s" Not a directory: " own ou ?ISSUE-ERROR
   ou idx CHECK-FILE-FITS ;
\ A parent without its own folder gets one: D/p.md moves to D/p/p.md. Its
\ callers run CHECK-OWN-FOLDER before they write anything.
: ENSURE-OWN-FOLDER ( n -- )
   {: parent:n :}
   parent OWN-FOLDER? if exit then
   parent OWN-FOLDER$ PATH-ONE!
   SB-RESET PATH-ONE$ SB-APPEND 47 SB-APPEND-C
   parent F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO!
   PATH-ONE$ MAKE-DIRS
   parent F-PATH FIELD$ PATH-TWO$ RENAME-ISSUE-NOREPLACE
   PATH-TWO$ parent F-PATH FIELD! ;
: PARSE-ADD ( n -- )
   ARG-I !
   0 TITLE-U ! 0 DESC-U ! 0 PARENT-U ! 0 AFTER-U !
   0 PARENT-SET ! 0 AFTER-SET ! 2 ADD-PRIORITY !
   begin ARG-I @ script-argc < while
      ARG-I @ script-argv$ {: a:ptr u:n :}
      a u s" -p" STR= NEXT-ARG? and if
         TAKE-ARG 2dup DECIMAL:EXACT MATCH option
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
\ Add the task whose title and options PARSE-ADD read.
: ADD-TASK ( -- )
   TITLE-U @ 0= s" Error: title required" ?FAIL
   PARENT-SET @ 0<> AFTER-SET @ 0<> and if
      PARENT-A @ PARENT-U @ AFTER-A @ AFTER-U @ STR=
      s" Error: parent and after cannot be the same issue" ?FAIL
   then
   \ The new id needs the prefix. One keyed walk then loads what add checks:
   \ under the first key, the new id, every task that has it in either
   \ partition at any depth; then the -a and -P tasks.
   LOAD-PREFIX
   1 SCAN-KEYED !
   TITLE-A @ TITLE-U @ NEW-ID$ SCAN-KEY+
   AFTER-SET @ 0<> if AFTER-A @ AFTER-U @ SCAN-KEY+ then
   PARENT-SET @ 0<> if PARENT-A @ PARENT-U @ SCAN-KEY+ then
   true LOAD-ISSUES
   -1 AFTER-IDX !
   AFTER-SET @ 0<> if AFTER-A @ AFTER-U @ s" After issue not found: " RESOLVE-LABELED AFTER-IDX ! then
   -1 PARENT-IDX !
   PARENT-SET @ 0<> if PARENT-A @ PARENT-U @ s" Parent issue not found: " RESOLVE-LABELED PARENT-IDX ! then
   PARENT-IDX @ -1 <> if
      PARENT-IDX @ F-ID FIELD$ CREATABLE-ID? 0= s" Invalid issue id" ?FAIL
      PARENT-IDX @ F-ARCHIVED REC-CELL @ 0<>
      s" Parent issue is archived: " PARENT-A @ PARENT-U @ ?ISSUE-ERROR
      PARENT-IDX @ PARSE-RECORD
      PARENT-IDX @ CHECK-ERROR
      PARENT-IDX @ F-STATUS REC-CELL @ 2 =
      s" Parent issue is closed: " PARENT-A @ PARENT-U @ ?ISSUE-ERROR
   then
   \ The first key is the new id.
   0 SCAN-KEY-BYTES 0 SCAN-KEY-ENDS @ 2dup CREATABLE-ID? 0= s" Invalid issue id" ?FAIL
   2dup FIND-EXACT -1 <> s" Issue already exists" ?FAIL
   NEW-RECORD {: idx:n :}
   TITLE-A @ TITLE-U @ idx F-TITLE FIELD!
   DESC-U @ 0 > if DESC-A @ DESC-U @ idx F-DESC FIELD! then
   ADD-PRIORITY @ idx F-PRIORITY REC-CELL !
   TIMESTAMP$ idx F-CREATED FIELD!
   AFTER-IDX @ -1 <> if
      0 BLOCK-U ! AFTER-IDX @ F-ID FIELD$ BLOCK-ADD
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
   then
   \ A child goes in its parent's own folder, which is missing or a directory.
   \ With no parent, a folder already named after the task holds it, unless a
   \ link names that folder. The new file's path and the path the parent's
   \ file moves to fit FS-PATH-CAP, and the new path holds nothing. So add
   \ neither replaces an entry nor writes through a link, and it refuses before
   \ any write. SB holds the folder; nest says whether the file goes in it.
   PARENT-IDX @ -1 <> if
      PARENT-IDX @ CHECK-OWN-FOLDER
      true
   else
      SB-RESET s" .dots/" SB-APPEND idx F-ID FIELD$ SB-APPEND
      SB$ DIR? dup if SB$ SYMLINK? s" Issue already exists" ?FAIL then
   then {: nest:bool :}
   nest if SB$ nip else s" .dots" nip then idx CHECK-FILE-FITS
   nest if 47 SB-APPEND-C idx F-ID FIELD$ SB-APPEND then
   s" .md" SB-APPEND SB$ FS-TRY-LSTAT s" Issue already exists" ?FAIL
   SB$ idx F-PATH FIELD!
   s" .dots" MAKE-DIRS SAVE-CONFIG
   PARENT-IDX @ -1 <> if
      PARENT-IDX @ ENSURE-OWN-FOLDER
      PARENT-IDX @ F-ID FIELD$ idx F-PARENT FIELD!
      1 idx F-CHILD REC-CELL !
   then
   idx SAVE-RECORD
   s" --json" ARG-AT? if
      JSON-OUT-BUF 1024 BUF:N>BLEN BUF:INIT
      JSON-W JSON-OUT-BUF JSON-WRITE:OPEN-BUF
      idx JSON-ISSUE dup JSON-WRITE:$ DOT-IO:PRINTLN JSON-WRITE:CLOSE
      JSON-OUT-BUF BUF:DISPOSE
   else idx F-ID FIELD$ DOT-IO:PRINTLN then ;
: ADD-COMMAND ( -- )
   script-argc 1 = s" Usage: dot add <title> [options]" ?FAIL
   1 PARSE-ADD ADD-TASK ;
\ Quick add takes its first argument verbatim as the title, over any PARSE-ADD
\ found, and the rest as add's options.
: QUICK-ADD ( -- )
   1 PARSE-ADD 0 script-argv$ TITLE-U ! TITLE-A ! ADD-TASK ;

PTR-VARIABLE REASON-A
variable REASON-U
variable REASON-PRESENT
variable STATUS-INDEX
variable STATUS-MODE
DYNAMIC-BUFFER STATUS-ARGS n
create CLOSED-TIME 40 allot
variable CLOSED-TIME-U

: RECORD-PATH? ( n -- bool ) F-PATH FIELD$ FILE? ;
: CHECK-PATH ( n -- ) RECORD-PATH? 0= s" Issue not found" ?FAIL ;
: STATUS-DIR-U ( ptr u8 n -- n )
   {: path:ptr pu:n :}
   pu begin dup 0 > while
      dup 1- path + c@ 47 = if 1- exit then
      1-
   repeat drop 0 ;
: STATUS-UNDER? ( ptr u8 n ptr u8 n -- bool )
   {: path:ptr pu:n dir:ptr du:n :}
   pu du <= if false exit then
   path du dir du STR= 0= if false exit then
   path du + c@ 47 = ;
\ A task's descendants are the records, at any depth, under its own folder and
\ under its legacy folder, the one named after it at the top of its partition,
\ where add -P used to put its children. An archived task also has those under
\ the active .dots/<id>/.
: STATUS-DESCENDANT? ( n n -- bool )
   {: child:n parent:n :}
   child parent = if false exit then
   child F-PATH FIELD$ {: cp:ptr cpu:n :}
   parent F-ARCHIVED REC-CELL @ 0<> {: archived:bool :}
   child F-ARCHIVED REC-CELL @ parent F-ARCHIVED REC-CELL @ = if
      parent OWN-FOLDER-U {: own-u:n :}
      own-u 0 > if
         cp cpu parent F-PATH FIELD$ drop own-u STATUS-UNDER? if true exit then
      then
      archived if s" .dots/archive/" else s" .dots/" then nip {: base-u:n :}
      cp base-u + cpu base-u - parent F-ID FIELD$ STATUS-UNDER? exit
   then
   archived 0= if false exit then
   s" .dots/" nip {: active-u:n :}
   cp active-u + cpu active-u - parent F-ID FIELD$ STATUS-UNDER? ;
: ARCHIVE-PATH? ( ptr u8 n -- bool )
   {: p:ptr u:n :} u 14 >= if p 14 s" .dots/archive/" STR= else false then ;
\ i is a descendant of idx that is error-free and not closed.
: OPEN-DESCENDANT? ( n n -- bool )
   {: i:n idx:n :}
   i idx STATUS-DESCENDANT? i F-ERROR REC-CELL @ 0= and
   i F-STATUS REC-CELL @ 2 <> and ;
: CHECK-DESCENDANT ( n n -- )
   {: i:n idx:n :} i idx STATUS-DESCENDANT? if i CHECK-ERROR then ;
: STATUS-CHILDREN-OPEN? ( n -- bool )
   {: idx:n :}
   ISSUE-N @ 0 ?do
      i idx OPEN-DESCENDANT? if true unloop exit then
   loop false ;
\ Fails with <prefix><id>: children are not all closed.
: CHILDREN-OPEN-FAIL ( ptr u8 n ptr u8 n -- )
   {: prefix:ptr pu:n id:ptr iu:n :}
   SB-RESET prefix pu SB-APPEND id iu SB-APPEND
   s" : children are not all closed" SB-APPEND SB$ FAIL ;
: VALIDATE-STATUS-DESCENDANTS ( n -- )
   {: idx:n :}
   ISSUE-N @ 0 ?do i idx CHECK-DESCENDANT loop ;
: STATUS-IN-SUBTREE? ( ptr u8 n ptr u8 n -- bool )
   {: path:ptr pu:n root:ptr ru:n :}
   path pu root ru STR= if true exit then
   path pu root ru STATUS-UNDER? ;
\ Move a record in the subtree at the old path to the new one, archived when
\ the new path is.
: REBASE-RECORD ( n ptr u8 n ptr u8 n bool -- )
   {: i:n old:ptr ou:n new:ptr nu:n archived:bool :}
   i F-PATH FIELD$ {: path:ptr pu:n :}
   path pu old ou STATUS-IN-SUBTREE? 0= if exit then
   SB-RESET new nu SB-APPEND path ou + pu ou - SB-APPEND SB$ i F-PATH FIELD!
   archived if 1 else 0 then i F-ARCHIVED REC-CELL ! ;
: REBASE-STATUS-SUBTREE ( ptr u8 n ptr u8 n -- )
   {: old:ptr ou:n new:ptr nu:n :}
   new nu ARCHIVE-PATH? {: archived:bool :}
   ISSUE-N @ 0 ?do i old ou new nu archived REBASE-RECORD loop ;
: REBASE-STATUS-MOVED ( -- ) PATH-ONE$ PATH-TWO$ REBASE-STATUS-SUBTREE ;
: ASSERT-ARCHIVE-REAL ( -- )
   s" .dots/archive" SYMLINK? s" Unsafe archive symlink" ?FAIL ;
: ASSERT-ARCHIVE-PATH-REAL ( ptr u8 n -- )
   {: path:ptr pu:n :}
   ASSERT-ARCHIVE-REAL
   s" .dots/archive/" nip begin dup pu < while
      path over + c@ 47 = if
         path over SYMLINK? s" Unsafe archive symlink" ?FAIL
      then
      1+
   repeat drop
   path pu SYMLINK? s" Unsafe archive symlink" ?FAIL ;
: STATUS-ENSURE-ARCHIVE-PARENT ( ptr u8 n -- )
   {: path:ptr pu:n :}
   path pu STATUS-DIR-U {: parent-u:n :}
   s" .dots/archive" nip parent-u > if exit then
   s" .dots/archive" nip 1+ begin dup parent-u < while
      path over + c@ 47 = if
         path over SYMLINK? s" Unsafe archive symlink" ?FAIL
      then
      1+
   repeat drop
   path parent-u SYMLINK? s" Unsafe archive symlink" ?FAIL
   path parent-u MAKE-DIRS ;
\ Move a top-level record's file or own folder between the partitions, leaving
\ the paths in PATH-ONE and PATH-TWO. Whether it moved: not when the record is
\ a child or already in the target partition.
: STATUS-RENAME ( n bool -- bool )
   {: idx:n to-archive:bool :}
   idx F-ARCHIVED REC-CELL @ 0<> {: from-archive:bool :}
   from-archive if
      to-archive if false exit then
   else
      to-archive 0= if false exit then
   then
   idx F-CHILD REC-CELL @ 0<> if false exit then
   ASSERT-ARCHIVE-REAL
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   path pu STATUS-DIR-U {: dir-u:n :}
   from-archive if s" .dots/archive" nip else s" .dots" nip then
   {: base-u:n :}
   dir-u base-u > if path dir-u else path pu then PATH-ONE!
   PATH-ONE$ {: src:ptr su:n :}
   SB-RESET to-archive if s" .dots/archive/" else s" .dots/" then
   SB-APPEND
   src from-archive if 14 else 6 then +
   su from-archive if 14 else 6 then - SB-APPEND
   SB$ PATH-TWO!
   to-archive if PATH-TWO$ STATUS-ENSURE-ARCHIVE-PARENT then
   PATH-ONE$ PATH-TWO$ RENAME-ISSUE-NOREPLACE true ;
: MOVE-STATUS-PATH ( n bool -- ) STATUS-RENAME if REBASE-STATUS-MOVED then ;
: ARCHIVE-STATUS-UNCHECKED ( n -- ) true MOVE-STATUS-PATH ;
: ARCHIVE-STATUS ( n -- )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> if exit then
   idx F-CHILD REC-CELL @ 0<> if exit then
   idx VALIDATE-STATUS-DESCENDANTS
   idx ARCHIVE-STATUS-UNCHECKED ;
: UNARCHIVE-STATUS ( n -- ) false MOVE-STATUS-PATH ;
\ A task's family: the records an rm or close operand removes or moves, the
\ named task first.
DYNAMIC-BUFFER FAMILY n
variable FAMILY-N
: FAMILY-ADD ( n -- )
   FAMILY-N @ 1+ FAMILY-RESERVE
   FAMILY-N @ FAMILY !
   1 FAMILY-N +! ;
: IN-FAMILY? ( n -- bool )
   {: idx:n :}
   FAMILY-N @ 0 ?do i FAMILY @ idx = if true unloop exit then loop false ;
: FAMILY-ID? ( ptr u8 n -- bool )
   {: id:ptr iu:n :}
   FAMILY-N @ 0 ?do
      i FAMILY @ F-ID FIELD$ id iu STR= if true unloop exit then
   loop false ;
\ A task's family is the task and, to a fixed point, every status descendant
\ of a member. A record an earlier operand removed has no path.
: GATHER-FAMILY ( n -- )
   0 FAMILY-N ! FAMILY-ADD
   0 begin dup FAMILY-N @ < while
      dup FAMILY @ {: member:n :}
      ISSUE-N @ 0 ?do
         i F-PATH FIELD$ nip 0<> if
            i member STATUS-DESCENDANT? if
               i IN-FAMILY? 0= if i FAMILY-ADD then
            then
         then
      loop
      1+
   repeat drop ;
\ Whether anything, a dangling symlink included, takes the path.
: OCCUPIED? ( ptr u8 n -- bool )
   {: path:ptr pu:n :}
   path pu EXISTS? path pu SYMLINK? or ;
\ fix repairs each top-level folder .dots/<f>/ holding no valid task f. With no
\ task f anywhere it is an orphan folder: its regular .md files move to .dots/.
\ With one valid task f it is f's legacy folder: what a scan reads in it,
\ regular .md files and directories, nests into f's own folder, the archived
\ one when f is archived. fix repairs task files only, so a folder none move
\ from stays. Orphan folders go before legacy ones. Each folder is checked
\ before its first move and done before the next: a failure leaves earlier
\ folders repaired and a rerun completes.
variable FIX-FILES
variable FIX-NESTED
variable FIX-MOVES
variable FIX-TAKEN
variable FIX-LEFT
variable FIX-NEST
variable FIX-BAD
variable FIX-ORPHANS
create FIX-SOURCE-ROW FS-PATH-CAP allot
variable FIX-SOURCE-U
create FIX-DEST-ROW FS-PATH-CAP allot
variable FIX-DEST-U
: FIX-SOURCE$ ( -- ptr u8 n ) FIX-SOURCE-ROW FIX-SOURCE-U @ ;
: FIX-DEST$ ( -- ptr u8 n ) FIX-DEST-ROW FIX-DEST-U @ ;
: FIX-DEST! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u FS-PATH-CAP > s" I/O error" ?FAIL
   a FIX-DEST-ROW u BYTE-COPY u FIX-DEST-U ! ;
: COUNT-FIX-ENTRY ( ptr u8 n -- ) 2drop 1 FIX-LEFT +! ;
\ Whether a valid task f lies in the folder, which is then that task's own.
: FIX-HOME? ( ptr u8 n -- bool )
   {: id:ptr iu:n :}
   ISSUE-N @ 0 ?do
      i F-ERROR REC-CELL @ 0= i F-ID FIELD$ id iu STR= and if
         i F-PATH FIELD$ FIX-SOURCE$ STATUS-UNDER? if true unloop exit then
      then
   loop false ;
\ The one valid task f in either partition, -1 without one. A malformed task f
\ keeps its folder from being an orphan: with no valid f it ends fix with its
\ diagnostic.
: FIX-OWNER ( ptr u8 n -- n )
   {: id:ptr iu:n :}
   -1 FIX-BAD !
   -1 ISSUE-N @ 0 ?do
      i F-ID FIELD$ id iu STR= if
         i F-ERROR REC-CELL @ 0= if
            dup 0 >= s" Ambiguous ID: " id iu ?ISSUE-ERROR
            drop i
         else i FIX-BAD ! then
      then
   loop
   dup 0< FIX-BAD @ 0 >= and if FIX-BAD @ CHECK-ERROR then ;
: FIX-PATHS ( ptr u8 n -- )
   {: name:ptr nu:n :}
   SB-RESET FIX-SOURCE$ SB-APPEND 47 SB-APPEND-C name nu SB-APPEND SB$ PATH-ONE!
   SB-RESET FIX-DEST$ SB-APPEND 47 SB-APPEND-C name nu SB-APPEND SB$ PATH-TWO! ;
\ Whether the entry at PATH-ONE moves: a regular .md file, or, when the folder
\ nests, a directory other than archive.
: FIX-MOVES? ( ptr u8 n -- bool )
   {: name:ptr nu:n :}
   PATH-ONE$ FS-TRY-LSTAT-MODE MATCH option
      none OF 0 ENDOF
      some OF S-IFMT and ENDOF
   ;MATCH {: kind:n :}
   kind S-IFREG = if name nu FILE-ENTRY? exit then
   kind S-IFDIR = FIX-NEST @ 0<> and if name nu s" archive" STR= 0= exit then
   false ;
\ Counts the entries that move and notes whether anything takes a destination,
\ or a legacy entry would take f's own file's. FIX-FOLDER refuses on that
\ after it checks the destination folder, before the first move.
: FIX-CHECK ( n n -- )
   {: begin-at:n end-at:n :}
   FIX-SOURCE$ BASENAME {: id:ptr iu:n :}
   0 FIX-MOVES ! 0 FIX-TAKEN !
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu FIX-PATHS
      name nu FIX-MOVES? if
         PATH-TWO$ OCCUPIED?
         FIX-NEST @ 0<> name nu FILE-ENTRY? and if name nu 3 - id iu STR= or then
         if 1 FIX-TAKEN ! then
         1 FIX-MOVES +!
      then
      next
   repeat drop ;
: FIX-MOVE ( n n -- )
   {: begin-at:n end-at:n :}
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu FIX-PATHS
      name nu FIX-MOVES? if
         PATH-ONE$ PATH-TWO$ RENAME-ISSUE-NOREPLACE
         REBASE-STATUS-MOVED
      then
      next
   repeat drop
   0 FIX-LEFT !
   FIX-SOURCE$ [: COUNT-FIX-ENTRY ;] FS-LIST:EACH
   FIX-LEFT @ 0= if FIX-SOURCE$ REMOVE-ISSUE-DIR then ;
: FIX-FOLDER ( ptr u8 n -- )
   {: name:ptr nu:n :}
   SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND SB$ {: a:ptr u:n :}
   a FIX-SOURCE-ROW u BYTE-COPY u FIX-SOURCE-U !
   FIX-SOURCE$ BASENAME {: id:ptr iu:n :}
   id iu FIX-HOME? if exit then
   id iu FIX-OWNER {: owner:n :}
   \ A nest can depend on an orphan repair.
   owner 0< if FIX-ORPHANS @ 0= else FIX-ORPHANS @ 0<> then if exit then
   owner 0< if
      0 FIX-NEST ! s" .dots" FIX-DEST!
   else
      1 FIX-NEST ! owner OWN-FOLDER$ FIX-DEST!
      \ f's file lies beside the folder at the top: it moves in.
      FIX-DEST$ FIX-SOURCE$ STR= if
         owner CHECK-OWN-FOLDER
         owner ENSURE-OWN-FOLDER 1 FIX-NESTED +! exit
      then
   then
   SCAN-NAMES-U @ {: begin-at:n :}
   FIX-SOURCE$ [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   begin-at end-at FIX-CHECK
   FIX-MOVES @ 0= if exit then
   owner 0< if
      FIX-TAKEN @ 0<> s" Issue already exists" ?FAIL
      begin-at end-at FIX-MOVE
      FIX-MOVES @ FIX-FILES +! exit
   then
   \ An archived f takes only what close allows: every descendant valid and
   \ closed.
   owner F-ARCHIVED REC-CELL @ 0<> if
      owner VALIDATE-STATUS-DESCENDANTS
      owner STATUS-CHILDREN-OPEN? if s" Cannot nest " id iu CHILDREN-OPEN-FAIL then
      FIX-DEST$ ASSERT-ARCHIVE-PATH-REAL
   then
   owner CHECK-OWN-FOLDER
   FIX-TAKEN @ 0<> s" Issue already exists" ?FAIL
   owner ENSURE-OWN-FOLDER
   begin-at end-at FIX-MOVE
   1 FIX-NESTED +! ;
\ Runs FIX-FOLDER on the top-level folder .dots/<name>, archive and links aside.
: FIX-NAME ( ptr u8 n -- )
   {: name:ptr nu:n :}
   name nu s" archive" STR= if exit then
   SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND SB$ PATH-TWO!
   PATH-TWO$ SYMLINK? 0= PATH-TWO$ DIR? and if name nu FIX-FOLDER then ;
\ Runs FIX-NAME on each name the scanned names hold before byte n.
: FIX-PASS ( n -- )
   {: end-at:n :}
   0 begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu FIX-NAME
      next
   repeat drop ;
: FIX-COMMAND ( -- )
   true LOAD-ISSUES
   0 FIX-FILES ! 0 FIX-NESTED !
   0 SCAN-NAMES-U !
   STORE? if s" .dots" [: GATHER-SCAN-NAME ;] FS-LIST:EACH then
   SCAN-NAMES-U @ {: end-at:n :}
   1 FIX-ORPHANS ! end-at FIX-PASS
   0 FIX-ORPHANS ! end-at FIX-PASS
   FIX-FILES @ FIX-NESTED @ + 0= if s" No fixes needed" DOT-IO:PRINTLN exit then
   FIX-FILES @ 0 > if
      s" Moved " DOT-IO:PRINT FIX-FILES @ DOT-IO:INT
      s"  file(s) out of orphan folders" DOT-IO:PRINTLN
   then
   FIX-NESTED @ 0 > if
      s" Nested " DOT-IO:PRINT FIX-NESTED @ DOT-IO:INT
      s"  legacy folder(s)" DOT-IO:PRINTLN
   then ;
\ Nests each family member's legacy folder as fix does, the top's first. A
\ keyed load has none (LEGACY-LAYOUT?).
: NEST-FAMILY ( n -- )
   {: top:n :}
   SCAN-KEYED @ 0<> if exit then
   0 FIX-ORPHANS !
   top GATHER-FAMILY
   FAMILY-N @ 0 ?do i FAMILY @ F-ID FIELD$ FIX-NAME loop ;
256 constant REOPEN-MAX
create REOPEN-INDICES REOPEN-MAX cells allot
create REOPEN-BACKUP-PATHS REOPEN-MAX 1024 * allot
create REOPEN-BACKUP-US REOPEN-MAX cells allot
create REOPEN-SOURCE FS-PATH-CAP allot
variable REOPEN-SOURCE-U
create REOPEN-DEST FS-PATH-CAP allot
variable REOPEN-DEST-U
variable REOPEN-N
variable REOPEN-BACKUPS
variable REOPEN-CLEAN-ERROR
variable REOPEN-TARGET
variable REOPEN-WANTED-STATUS
variable REOPEN-PARENT-KEEP-U
: REOPEN-SOURCE$ ( -- ptr u8 n ) REOPEN-SOURCE REOPEN-SOURCE-U @ ;
: REOPEN-DEST$ ( -- ptr u8 n ) REOPEN-DEST REOPEN-DEST-U @ ;
: REOPEN-INDEX ( n -- n ) cells REOPEN-INDICES + @ ;
: REOPEN-BACKUP$ ( n -- ptr u8 n )
   {: at:n :}
   at 1024 * REOPEN-BACKUP-PATHS +
   at cells REOPEN-BACKUP-US + @ ;
: REOPEN-ADD ( n -- )
   REOPEN-N @ REOPEN-MAX >= ?CAP-FAIL
   REOPEN-N @ cells REOPEN-INDICES + !
   1 REOPEN-N +! ;
\ The records a reopen changes: the closed ancestors in the target's partition,
\ each the owner of a folder holding it, then the target.
: REOPEN-COLLECT ( n -- )
   {: idx:n :}
   0 REOPEN-N !
   idx F-ARCHIVED REC-CELL @ {: archived:n :}
   ISSUE-N @ 0 ?do
      i idx <> i F-ARCHIVED REC-CELL @ archived = and i OWN-FOLDER? and if
         i F-PATH FIELD$ {: path:ptr pu:n :}
         path pu STATUS-DIR-U {: dir-u:n :}
         idx F-PATH FIELD$ path dir-u STATUS-IN-SUBTREE? if
            archived 0<> if path pu ASSERT-ARCHIVE-PATH-REAL then
            i PARSE-RECORD
            i CHECK-ERROR
            i F-STATUS REC-CELL @ 2 = if i REOPEN-ADD then
         then
      then
   loop
   idx REOPEN-ADD ;
: REOPEN-ROOTS! ( n -- )
   F-PATH FIELD$ {: path:ptr pu:n :}
   s" .dots/archive/" nip {: base-u:n :}
   path pu STATUS-DIR-U {: dir-u:n :}
   dir-u base-u >= if dir-u else pu then {: root-u:n :}
   root-u FS-PATH-CAP > s" I/O error" ?FAIL
   path REOPEN-SOURCE root-u BYTE-COPY root-u REOPEN-SOURCE-U !
   ISSUE-N @ 0 ?do
      i F-ARCHIVED REC-CELL @ 0<> i OWN-FOLDER? and if
         i F-PATH FIELD$ {: ancestor:ptr au:n :}
         ancestor au STATUS-DIR-U {: ancestor-dir:n :}
         ancestor-dir REOPEN-SOURCE-U @ <
         path pu ancestor ancestor-dir STATUS-IN-SUBTREE? and if
            ancestor REOPEN-SOURCE ancestor-dir BYTE-COPY
            ancestor-dir REOPEN-SOURCE-U !
         then
      then
   loop
   SB-RESET s" .dots/" SB-APPEND
   REOPEN-SOURCE base-u + REOPEN-SOURCE-U @ base-u - SB-APPEND
   SB$ {: dst:ptr du:n :}
   du FS-PATH-CAP > s" I/O error" ?FAIL
   dst REOPEN-DEST du BYTE-COPY
   du REOPEN-DEST-U ! ;
: REOPEN-ENSURE-DEST-PARENT ( -- )
   REOPEN-DEST$ {: path:ptr pu:n :}
   path pu STATUS-DIR-U {: parent-u:n :}
   s" .dots" SYMLINK? s" Unsafe active symlink" ?FAIL
   s" .dots" nip REOPEN-PARENT-KEEP-U !
   s" .dots" nip parent-u >= if exit then
   s" .dots" nip 1+ begin dup parent-u < while
      path over + c@ 47 = if
         path over SYMLINK? s" Unsafe active symlink" ?FAIL
         path over DIR? if dup REOPEN-PARENT-KEEP-U ! then
      then
      1+
   repeat drop
   path parent-u SYMLINK? s" Unsafe active symlink" ?FAIL
   path parent-u DIR? if parent-u REOPEN-PARENT-KEEP-U ! then
   path parent-u MAKE-DIRS ;
: REOPEN-CLEAN-NEW-PARENTS ( -- )
   REOPEN-DEST$ {: path:ptr pu:n :}
   path pu STATUS-DIR-U
   begin dup REOPEN-PARENT-KEEP-U @ > while
      {: parent-u:n :}
      path parent-u REMOVE-ISSUE-DIR
      path parent-u STATUS-DIR-U
   repeat drop ;
: REOPEN-STAGE-ONE ( n -- )
   {: at:n :}
   at REOPEN-INDEX F-PATH FIELD$ {: path:ptr pu:n :}
   path pu [: 2dup FILE-BUF ISSUE-MAX READ-ALL FILE-U ! ;] catch
   dup E-FS-CAPACITY = if path pu E-ISSUE-TOO-LARGE PATH-THROW then
   dup 0<> if throw then drop 2drop
   FILE-U @ {: size:n :}
   path pu RESERVE-ISSUE-SIBLING {: temp:ptr tu:n fd:n :}
   tu 1024 >= if fd temp tu E-FS-CAPACITY TEMP-THROW then
   temp at 1024 * REOPEN-BACKUP-PATHS + tu BYTE-COPY
   tu at cells REOPEN-BACKUP-US + !
   0 begin dup size < while
      {: off:n :}
      fd FILE-BUF off + size off - write {: count:n :}
      count 0 <= if fd temp tu E-FS-IO TEMP-THROW then
      off count +
   repeat drop
   fd FSYNC-CALL 0<> if fd temp tu E-FS-IO TEMP-THROW then
   fd close
   1 REOPEN-BACKUPS +! ;
: REOPEN-STAGE-ALL ( -- )
   0 REOPEN-BACKUPS !
   REOPEN-N @ 0 ?do i REOPEN-STAGE-ONE loop ;
: REOPEN-CHANGE-RECORDS ( -- )
   REOPEN-N @ 0 ?do
      i REOPEN-INDEX {: idx:n :}
      idx F-CLOSED FIELD-EMPTY idx F-REASON FIELD-EMPTY
      0 idx F-CLOSED-PRESENT REC-CELL !
      0 idx F-REASON-PRESENT REC-CELL !
      idx REOPEN-TARGET @ = if REOPEN-WANTED-STATUS @ else 0 then
      idx F-STATUS REC-CELL !
   loop ;
: REOPEN-WRITE-ALL ( -- )
   REOPEN-N @ 0 ?do i REOPEN-INDEX SAVE-RECORD-THROW loop ;
: REOPEN-RECORDS ( -- )
   REOPEN-STAGE-ALL
   REOPEN-CHANGE-RECORDS
   REOPEN-WRITE-ALL ;
: REOPEN-FINISH ( -- )
   REOPEN-SOURCE$ REOPEN-DEST$ REBASE-STATUS-SUBTREE
   REOPEN-RECORDS ;
: REOPEN-RESTORE ( -- )
   REOPEN-BACKUPS @ 0 ?do
      i REOPEN-BACKUP$ i REOPEN-INDEX F-PATH FIELD$ RENAME-ISSUE
   loop ;
: REOPEN-CLEAN-BACKUPS ( -- )
   0 REOPEN-CLEAN-ERROR !
   REOPEN-BACKUPS @ 0 ?do
      i REOPEN-BACKUP$ FS-PATHZ UNLINK-CALL FS-CAUSE
      dup 0<> if REOPEN-CLEAN-ERROR ! else drop then
   loop
   REOPEN-CLEAN-ERROR @ 0<> s" Reopened issue; temporary cleanup failed" ?FAIL ;
\ Whether a family check covers the member: any member, or with outside set
\ only one outside the archive.
: CHECK-COVERS? ( n bool -- bool )
   0= swap F-ARCHIVED REC-CELL @ 0= or ;
\ Refuses unless every family member the check covers, the top aside, is
\ valid, then unless each is closed; a keyed load parses them first. A close
\ covers the whole family; a reopen's nest, with outside set, only the members
\ outside the archive, which it would carry in. The refusal names the top
\ after the prefix.
: CHECK-FAMILY-CLOSED ( ptr u8 n n bool -- )
   {: pre:ptr pu:n idx:n outside:bool :}
   idx GATHER-FAMILY
   FAMILY-N @ 1 ?do
      i FAMILY @ dup outside CHECK-COVERS? over F-ERROR REC-CELL @ 0<> and
      if PARSE-RECORD else drop then
   loop
   FAMILY-N @ 1 ?do
      i FAMILY @ dup outside CHECK-COVERS? if CHECK-ERROR else drop then
   loop
   FAMILY-N @ 1 ?do
      i FAMILY @ dup outside CHECK-COVERS? swap F-STATUS REC-CELL @ 2 <> and
      if pre pu idx F-ID FIELD$ CHILDREN-OPEN-FAIL then
   loop ;
\ The archived task whose own folder a reopen of the task moves back, or the
\ task itself when it lies bare at the archive root: the top whose family's
\ legacy folders nest first.
: REOPEN-TOP ( n -- n )
   {: idx:n :}
   idx REOPEN-ROOTS!
   ISSUE-N @ 0 ?do
      i F-ARCHIVED REC-CELL @ 0<> i OWN-FOLDER? and if
         i F-PATH FIELD$ drop i OWN-FOLDER-U REOPEN-SOURCE$ STR= if i unloop exit then
      then
   loop idx ;
\ Nests the reopened family's legacy folders, refusing first unless every
\ member the nests would carry into the archive is valid and closed.
: REOPEN-NEST ( n -- )
   {: top:n :}
   SCAN-KEYED @ 0<> if exit then
   s" Cannot nest " top true CHECK-FAMILY-CLOSED
   top NEST-FAMILY ;
: REOPEN-ARCHIVED ( n n -- )
   {: idx:n status:n :}
   idx F-PATH FIELD$ ASSERT-ARCHIVE-PATH-REAL
   idx REOPEN-COLLECT
   idx REOPEN-TOP REOPEN-NEST
   idx REOPEN-ROOTS!
   idx REOPEN-TARGET ! status REOPEN-WANTED-STATUS !
   0 REOPEN-BACKUPS !
   REOPEN-DEST$ {: dest:ptr du:n :}
   dest du SYMLINK? dest du FILE? or dest du DIR? or s" Issue already exists" ?FAIL
   REOPEN-ENSURE-DEST-PARENT
   REOPEN-SOURCE$ REOPEN-DEST$ RENAME-NOREPLACE-CAUSE
   dup 0<> if
      REOPEN-CLEAN-NEW-PARENTS
      dup 17 = over FS-DIR-NOT-EMPTY = or s" Issue already exists" ?FAIL
      REOPEN-DEST$ ?FS-MUTATION-ERROR
   else drop then
   [: REOPEN-FINISH ;] catch {: code:n :}
   code 0<> if
      REOPEN-RESTORE
      REOPEN-DEST$ REOPEN-SOURCE$ RENAME-ISSUE-NOREPLACE
      REOPEN-DEST$ REOPEN-SOURCE$ REBASE-STATUS-SUBTREE
      REOPEN-CLEAN-NEW-PARENTS
      code REPORT-FAILURE
   then
   REOPEN-CLEAN-BACKUPS ;
\ An active target's closed ancestors reopen where they lie, its whole family
\ written from staged copies that a failed write restores.
: REOPEN-IN-PLACE ( n n -- )
   REOPEN-WANTED-STATUS ! REOPEN-TARGET !
   [: REOPEN-RECORDS ;] catch {: code:n :}
   code 0<> if
      REOPEN-RESTORE
      code REPORT-FAILURE
   then
   REOPEN-CLEAN-BACKUPS ;
variable STATUS-SAVE-IDX
: STATUS-CHANGE ( n n -- )
   {: idx:n status:n :}
   idx F-ARCHIVED REC-CELL @ 0<> status 2 <> and if
      idx F-PATH FIELD$ FILE? 0= s" Issue not found" ?FAIL
      idx CHECK-ERROR
      idx status REOPEN-ARCHIVED exit
   then
   idx CHECK-PATH
   idx CHECK-ERROR
   status 2 = idx F-STATUS REC-CELL @ 2 = and if exit then
   status 2 <> if
      idx REOPEN-COLLECT
      REOPEN-N @ 1 > if idx status REOPEN-IN-PLACE exit then
   then
   idx F-ARCHIVED REC-CELL @ 0<> if ASSERT-ARCHIVE-REAL then
   status 2 = if s" Cannot close " idx false CHECK-FAMILY-CLOSED then
   0
   status 2 = if
      idx F-ARCHIVED REC-CELL @ 0= idx F-CHILD REC-CELL @ 0= and if
         drop ASSERT-ARCHIVE-REAL idx NEST-FAMILY idx ARCHIVE-STATUS 1
      then
   then {: moved:n :}
   status 2 = if
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
   idx STATUS-SAVE-IDX !
   [: STATUS-SAVE-IDX @ SAVE-RECORD-THROW ;] catch {: code:n :}
   code 0<> if
      moved 1 = if idx UNARCHIVE-STATUS then
      code REPORT-FAILURE
   then ;
: REASON-FLAG? ( ptr u8 n -- bool )
   2dup s" -r" STR= -rot s" --reason" STR= or ;
: RESOLVE-ARG ( n -- n )
   {: arg:n :}
   arg script-argv$ RESOLVE ;
\ Whether a top-level folder .dots/<x>/, archive and links aside, lacks its own
\ file, a regular .dots/<x>/<x>.md typed by lstat as the scan types entries: a
\ legacy folder, which only a full load reads.
: LEGACY-LAYOUT? ( -- bool )
   STORE? 0= if false exit then
   SCAN-NAMES-U @ {: begin-at:n :}
   s" .dots" [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      name nu s" archive" STR= 0= if
         SB-RESET s" .dots/" SB-APPEND name nu SB-APPEND SB$ PATH-ONE!
         PATH-ONE$ SYMLINK? 0= PATH-ONE$ DIR? and if
            SB-RESET PATH-ONE$ SB-APPEND 47 SB-APPEND-C name nu SB-APPEND
            s" .md" SB-APPEND SB$ FS-TRY-LSTAT-MODE MATCH option
               none OF 0 ENDOF
               some OF S-IFMT and ENDOF
            ;MATCH S-IFREG <> if true exit then
         then
      then
      next
   repeat drop false ;
\ A status change reads every task where a legacy folder may hold a family
\ member, else only the tasks it names.
: LOAD-STATUS-ISSUES ( -- ) LEGACY-LAYOUT? if 0 SCAN-KEYED ! then true LOAD-ISSUES ;
: STATUS-MULTI ( n -- )
   STATUS-MODE !
   script-argc 2 < if
      STATUS-MODE @ 2 = s" Usage: dot off <id> [id2 ...] [-r reason]" ?FAIL
      s" Usage: dot on <id> [id2 ...]" FAIL
   then
   0 REASON-U ! 0 REASON-PRESENT ! 0 CLOSED-TIME-U !
   0 STATUS-INDEX ! 1 ARG-I !
   begin ARG-I @ script-argc < while
      STATUS-MODE @ 2 = ARG-I @ script-argv$ REASON-FLAG? and
      NEXT-ARG? and if
         TAKE-ARG REASON-U ! REASON-A ! 1 REASON-PRESENT !
      else
         STATUS-INDEX @ 1+ STATUS-ARGS-RESERVE
         ARG-I @ STATUS-INDEX @ STATUS-ARGS !
         1 STATUS-INDEX +!
      then
      1 ARG-I +!
   repeat
   STATUS-INDEX @ 0= s" Usage: dot off <id> [id2 ...] [-r reason]" ?FAIL
   1 SCAN-KEYED ! 1 SCAN-FAMILY !
   STATUS-INDEX @ 0 ?do i STATUS-ARGS @ script-argv$ SCAN-KEY+ loop
   LOAD-STATUS-ISSUES
   STATUS-MODE @ 2 = if
      TIMESTAMP$ {: ts:ptr tu:n :}
      ts CLOSED-TIME tu BYTE-COPY tu CLOSED-TIME-U !
   then
   STATUS-INDEX @ 0 ?do
      i STATUS-ARGS @ RESOLVE-ARG dup F-PATH FIELD$ FILE? if dup PARSE-RECORD then
      STATUS-MODE @ STATUS-CHANGE
   loop ;
: UPDATE-COMMAND ( -- )
   script-argc 2 < s" Usage: dot update <id> [--status S]" ?FAIL
   -1 STATUS-MODE !
   0 REASON-U ! 0 REASON-PRESENT ! 0 CLOSED-TIME-U !
   2 ARG-I !
   begin ARG-I @ script-argc < while
      ARG-I @ script-argv$ s" --status" STR= NEXT-ARG? and if
         TAKE-ARG 2dup PARSE-STATUS dup -1 = if
            drop s" Invalid status: " 2swap ISSUE-ERROR
         then STATUS-MODE ! 2drop
      then
      1 ARG-I +!
   repeat
   STATUS-MODE @ -1 = s" --status required" ?FAIL
   1 SCAN-KEYED ! 1 SCAN-FAMILY ! 1 script-argv$ SCAN-KEY+
   LOAD-STATUS-ISSUES 1 RESOLVE-ARG dup F-PATH FIELD$ FILE? if dup PARSE-RECORD then
   STATUS-MODE @ STATUS-CHANGE ;
: INIT-EMPTY ( -- )
   s" .dots/archive" MAKE-DIRS ;
: REMOVE-DEEP-TREE ( n n -- )
   {: depth:n plen:n :}
   depth MAX-DEPTH 1- >= s" I/O error" ?FAIL
   depth PATH-AT {: path:ptr :}
   path plen SYMLINK? if path plen REMOVE-ISSUE-FILE exit then
   SCAN-NAMES-U @ {: begin-at:n :}
   path plen [: GATHER-SCAN-NAME ;] FS-LIST:EACH
   SCAN-NAMES-U @ {: end-at:n :}
   begin-at begin dup end-at < while
      {: at:n :}
      at SCANNED-NAME {: name:ptr nu:n next:n :}
      path plen name nu depth 1+ PATH-AT PATH-JOIN {: child-u:n :}
      depth 1+ PATH-AT {: child:ptr :}
      child child-u SYMLINK? if child child-u REMOVE-ISSUE-FILE else
         child child-u DIR? if depth 1+ child-u RECURSE
         else child child-u REMOVE-ISSUE-FILE then
      then
      next
   repeat drop
   path plen REMOVE-ISSUE-DIR ;
: REMOVE-ISSUE-TREE ( ptr u8 n -- )
   {: path:ptr pu:n :}
   0 SCAN-NAMES-U !
   path 0 PATH-AT pu BYTE-COPY
   0 pu REMOVE-DEEP-TREE ;
: PURGE-COMMAND ( -- )
   s" .dots/archive" SYMLINK? 0= if s" .dots/archive" MAKE-DIRS then
   s" .dots/archive" REMOVE-ISSUE-TREE
   s" .dots/archive" MAKE-DIRS
   s" Archive purged" DOT-IO:PRINTLN ;
\ Drops every family id from a remaining task's blocks, archived ones too.
: STRIP-FAMILY-REFERENCES ( n -- )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   idx F-PATH FIELD$ nip 0= if exit then
   idx IN-FAMILY? if exit then
   0 BLOCK-U ! 0 VALID !
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   0 begin dup bu < while
      {: at:n :}
      blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
      block sz FAMILY-ID? if 1 VALID !
      else block sz BLOCK-ADD then
      next
   repeat drop
   VALID @ 0<> if
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
      idx CHECK-PATH
      idx SAVE-RECORD
   then ;
\ Removes the folder named after a task under base when the scan reads it: a
\ directory, never a symlink, and never the archive.
: RM-FOLDER ( ptr u8 n ptr u8 n -- )
   {: base:ptr bu:n id:ptr iu:n :}
   id iu s" archive" STR= if exit then
   SB-RESET base bu SB-APPEND id iu SB-APPEND SB$ PATH-ONE!
   PATH-ONE$ FS-TRY-LSTAT-MODE MATCH option
      none OF false ENDOF
      some OF S-IFMT and S-IFDIR = ENDOF
   ;MATCH if PATH-ONE$ REMOVE-ISSUE-TREE then ;
\ A task's legacy folders, where add -P used to put its children: the one
\ named after it at the top of its partition and, when archived, at the top of
\ .dots.
: RM-LEGACY ( n -- )
   {: idx:n :}
   idx F-ID FIELD$ {: id:ptr iu:n :}
   idx F-ARCHIVED REC-CELL @ 0<> if s" .dots/archive/" id iu RM-FOLDER then
   s" .dots/" id iu RM-FOLDER ;
\ A task goes with its family: its own folder, or else its file, and every
\ member's legacy folders, which hold the rest of the family. The references to
\ the family go first.
: RM-ONE ( n -- )
   {: idx:n :}
   \ An operand an earlier operand's family removed is done.
   idx F-PATH FIELD$ nip 0= if exit then
   idx CHECK-PATH
   idx GATHER-FAMILY
   ISSUE-N @ 0 ?do i STRIP-FAMILY-REFERENCES loop
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   idx OWN-FOLDER-U {: own-u:n :}
   own-u 0 > if path own-u REMOVE-ISSUE-TREE else path pu REMOVE-ISSUE-FILE then
   FAMILY-N @ 0 ?do i FAMILY @ RM-LEGACY loop
   FAMILY-N @ 0 ?do i FAMILY @ F-PATH FIELD-EMPTY loop ;
: RM-COMMAND ( -- )
   script-argc 2 < s" Usage: dot rm <id> [id2 ...]" ?FAIL
   ASSERT-ARCHIVE-REAL
   true LOAD-ISSUES
   script-argc 1 ?do i RESOLVE-ARG RM-ONE loop ;
: TREE-HELP ( -- )
   s\" Usage: dot tree [id]\n\nShow dot hierarchy.\n\nWithout arguments: shows all open root dots and their children.\nWith id: shows that specific dot's tree (including closed children).\n\nExamples:\n  dot tree                    Show all open root dots\n  dot tree my-project         Show specific dot and its children\n" DOT-IO:PRINT ;
: STATUS-SYMBOL ( n -- ptr u8 n )
   dup 0 = if drop s" ○" exit then
   dup 1 = if drop s" >" exit then
   drop s" ✓" ;
\ The tree index, built once after SORT-ISSUES. Per record: its parent, the
\ first of its children and its next sibling, -1 for none and ending a list.
\ TREE-SLOT interleaves two open-addressed tables of TREE-CAP slots, each
\ holding a record index + 1 (0 empty): PATH-KEYS by F-PATH among non-error
\ records and ID-KEYS by F-ID among valid active records. The first record per
\ key owns the slot.
DYNAMIC-BUFFER TREE-UP n
DYNAMIC-BUFFER TREE-SEEN n
DYNAMIC-BUFFER TREE-HEAD n
DYNAMIC-BUFFER TREE-NEXT n
DYNAMIC-BUFFER TREE-SLOT n
variable TREE-CAP
0 constant PATH-KEYS
1 constant ID-KEYS
: TREE-FIELD ( n -- n ) PATH-KEYS = if F-PATH else F-ID then ;
\ The slot of table holding key, or the empty slot where key belongs. The
\ capacity exceeds the record count, so an empty slot ends every probe.
: TREE-FIND ( ptr u8 n n -- n )
   {: key:ptr ku:n table:n :}
   table TREE-FIELD {: field:n :}
   TREE-CAP @ 1- {: mask:n :}
   key ku STR-HASH mask and begin
      {: at:n :}
      at 2 * table + {: slot:n :}
      slot TREE-SLOT @ {: rec:n :}
      rec 0= if slot exit then
      rec 1- field FIELD$ key ku STR= if slot exit then
      at 1+ mask and
   again ;
: TREE-ADD ( n n -- )
   {: idx:n table:n :}
   idx table TREE-FIELD FIELD$ table TREE-FIND {: slot:n :}
   slot TREE-SLOT @ 0= if idx 1+ slot TREE-SLOT ! then ;
\ The first record with key in table, or -1.
: TREE-GET ( ptr u8 n n -- n ) TREE-FIND TREE-SLOT @ 1- ;
: TREE-CHILD? ( n -- bool )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0= idx F-ARCHIVED REC-CELL @ 0= and
   idx F-CHILD REC-CELL @ 0<> and ;
\ A child's parent is the valid record at its parent file, <parent>.md in the
\ enclosing folder named after the parent: the child's own directory, or the
\ one above a folder's own task. A folder at the top of .dots is also the
\ parent's legacy folder: without that file, the parent is the first valid
\ active record with its id. Any other child is an orphan root.
: TREE-PARENT ( n -- n )
   {: idx:n :}
   idx TREE-CHILD? 0= if -1 exit then
   idx F-PATH FIELD$ {: path:ptr pu:n :}
   path pu STATUS-DIR-U {: dir-u:n :}
   idx OWN-FOLDER? if path dir-u STATUS-DIR-U else dir-u then {: at-u:n :}
   SB-RESET path at-u SB-APPEND 47 SB-APPEND-C
   idx F-PARENT FIELD$ SB-APPEND s" .md" SB-APPEND SB$ PATH-KEYS TREE-GET
   dup 0 >= if exit then drop
   path at-u STATUS-DIR-U s" .dots" nip <> if -1 exit then
   idx F-PARENT FIELD$ ID-KEYS TREE-GET ;
\ Legacy parents can close a loop in a hand-made store: `.dots/p/x.md` beside
\ `.dots/x/p.md`. Walking up from each record in ORDER, a walk that meets its
\ own trail cuts the loop there, and the record it met becomes a root.
: TREE-CUT-LOOPS ( -- )
   ISSUE-N @ 0 ?do -1 i TREE-SEEN ! loop
   ISSUE-N @ 0 ?do
      i ORDER @ {: start:n :}
      start begin dup 0 >= if dup TREE-SEEN @ 0< else false then while
         start over TREE-SEEN ! TREE-UP @
      repeat {: at:n :}
      at 0 >= if at TREE-SEEN @ start = if -1 at TREE-UP ! then then
   loop ;
: TREE-INDEX ( -- )
   ISSUE-N @ {: count:n :}
   2 begin dup count 2 * < while 2 * repeat {: cap:n :}
   cap TREE-CAP !
   count TREE-UP-RESERVE count TREE-SEEN-RESERVE
   count TREE-HEAD-RESERVE count TREE-NEXT-RESERVE
   cap 2 * TREE-SLOT-RESERVE
   cap 2 * 0 ?do 0 i TREE-SLOT ! loop
   count 0 ?do
      -1 i TREE-HEAD !
      i F-ERROR REC-CELL @ 0= if
         i PATH-KEYS TREE-ADD
         i F-ARCHIVED REC-CELL @ 0= if i ID-KEYS TREE-ADD then
      then
   loop
   count 0 ?do i TREE-PARENT i TREE-UP ! loop
   TREE-CUT-LOOPS
   \ Prepend in reverse ORDER so every child list runs in ORDER.
   count 0 ?do
      count i - 1- ORDER @ {: child:n :}
      child TREE-UP @ {: parent:n :}
      parent 0 >= if
         parent TREE-HEAD @ child TREE-NEXT !
         child parent TREE-HEAD !
      then
   loop ;
\ Every open, valid active task without a parent is a root.
: TREE-ROOT? ( n -- bool )
   {: idx:n :}
   idx F-ARCHIVED REC-CELL @ 0<> idx F-ERROR REC-CELL @ 0<> or if false exit then
   idx F-STATUS REC-CELL @ 2 = if false exit then
   idx TREE-UP @ 0< ;
\ A task at depth d below the tree's root: 2·d spaces and `└─ `, then its row,
\ which notes an open blocker.
: PRINT-TREE-ROW ( n n -- )
   {: idx:n depth:n :}
   depth 0 ?do s"   " DOT-IO:PRINT loop
   depth 0 > if s" └─ " DOT-IO:PRINT then
   91 DOT-IO:PRINT-BYTE idx F-ID FIELD$ DOT-IO:PRINT s" ] " DOT-IO:PRINT
   idx F-STATUS REC-CELL @ STATUS-SYMBOL DOT-IO:PRINT 32 DOT-IO:PRINT-BYTE
   idx F-TITLE FIELD$ DOT-IO:PRINT
   depth 0 > if idx BLOCKED? if s"  (blocked)" DOT-IO:PRINT then then
   DOT-IO:NL ;
\ The row after a task without children: the next sibling of the task or of its
\ nearest ancestor below root that has one, -1 once the walk is back at root.
: TREE-SUCCESSOR ( n n n -- n n )
   {: idx:n depth:n root:n :}
   idx depth begin
      {: at:n d:n :}
      at root = if -1 0 exit then
      at TREE-NEXT @ dup 0 >= if d exit then drop
      at TREE-UP @ d 1-
   again ;
\ The task and every descendant in pre-order, children in ORDER. The walk
\ follows the forest TREE-INDEX built, so a chain as long as the store needs
\ neither a stack nor a depth limit.
: PRINT-TREE-ROOT ( n -- )
   {: root:n :}
   root 0 begin
      {: idx:n depth:n :}
      idx depth PRINT-TREE-ROW
      idx TREE-HEAD @ dup 0 >= if depth 1+ else
         drop idx depth root TREE-SUCCESSOR
      then
      over 0<
   until 2drop ;
: TREE-COMMAND ( -- )
   FIND-HELP? if TREE-HELP exit then
   script-argc 2 > s" Usage: dot tree [id]" ?FAIL
   false LOAD-ISSUES
   ['] ISSUE-LESS? SORT-ISSUES
   TREE-INDEX
   script-argc 2 = if
      1 RESOLVE-ARG dup RECORD-PATH? 0= ?ARG-NOT-FOUND
      dup CHECK-ERROR
      PRINT-TREE-ROOT exit
   then
   ISSUE-N @ 0 ?do i ORDER @ dup TREE-ROOT? if PRINT-TREE-ROOT else drop then loop ;
FUNCTION: STDERR-WRITE write ( n ptr u8 n -- n ) ;FUNCTION
create OLD-ID-ROW ID-MAX allot
variable OLD-ID-U
create NEW-ID-ROW ID-MAX allot
variable NEW-ID-U
variable LAST-DASH
variable SLUG-RENAMED
variable SLUG-CHANGED
: OLD-ID! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u ID-MAX > s" Invalid issue id" ?FAIL
   a OLD-ID-ROW u BYTE-COPY u OLD-ID-U ! ;
: OLD-ID$ ( -- ptr u8 n ) OLD-ID-ROW OLD-ID-U @ ;
: NEW-ID! ( ptr u8 n -- )
   {: a:ptr u:n :}
   u ID-MAX > s" Invalid issue id" ?FAIL
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
variable SLUG-LAST-SLASH
variable SLUG-PARENT-SLASH
variable SLUG-FOLDER
variable SLUG-FOLDER-MOVED
variable SLUG-CHILD-FOLDER
variable SLUG-CHILD-MOVED
create SLUG-CHILD-FROM FS-PATH-CAP allot
variable SLUG-CHILD-FROM-U
create SLUG-CHILD-TO FS-PATH-CAP allot
variable SLUG-CHILD-TO-U
variable SLUG-IDX
variable SLUG-KEEP-OLD
8 constant SLUG-TXN-CELLS
DYNAMIC-BUFFER SLUG-TXN n
DYNAMIC-BUFFER SLUG-PATHS u8
variable SLUG-PATH-U
-92001 constant E-SLUG-COLLISION
: SLUG-CELL ( n n -- ptr n )
   {: idx:n field:n :}
   idx SLUG-TXN-CELLS * field + SLUG-TXN ;
: SLUG-STORE ( ptr u8 n n n -- )
   {: a:ptr u:n idx:n field:n :}
   SLUG-PATH-U @ u + 1+ SLUG-PATHS-RESERVE
   SLUG-PATH-U @ idx field SLUG-CELL !
   u idx field 1+ SLUG-CELL !
   a SLUG-PATH-U @ SLUG-PATHS u BYTE-COPY
   SLUG-PATH-U @ u + SLUG-PATH-U ! ;
: SLUG-STORED$ ( n n -- ptr u8 n )
   {: idx:n field:n :}
   idx field SLUG-CELL @ SLUG-PATHS
   idx field 1+ SLUG-CELL @ ;
: SLUG-INIT ( -- )
   ISSUE-N @ SLUG-TXN-CELLS * SLUG-TXN-RESERVE
   ISSUE-N @ SLUG-TXN-CELLS * 0 ?do 0 i SLUG-TXN ! loop
   0 SLUG-PATH-U ! 0 SLUG-FOLDER-MOVED ! 0 SLUG-CHILD-MOVED !
   ISSUE-N @ 0 ?do i F-PATH FIELD$ i 0 SLUG-STORE loop ;
: SLUG-REBASE-RECORDS ( ptr u8 n ptr u8 n -- )
   {: old-dir:ptr old-u:n new-dir:ptr new-u:n :}
   ISSUE-N @ 0 ?do
      i F-PATH FIELD$ {: old-path:ptr path-u:n :}
      old-path path-u old-dir old-u STARTS-WITH?
      path-u old-u > and if
         old-path old-u + c@ 47 = if
            SB-RESET new-dir new-u SB-APPEND
            old-path old-u + path-u old-u - SB-APPEND SB$
            i F-PATH FIELD!
            i F-PARENT FIELD$ OLD-ID$ STR= if
               RENAMED-ID$ i F-PARENT FIELD!
            then
         then
      then
   loop ;
: SLUG-PLAN-PATH ( n -- )
   {: idx:n :}
   idx F-PATH FIELD$ PATH-ONE!
   0 SLUG-FOLDER !
   -1 SLUG-LAST-SLASH ! -1 SLUG-PARENT-SLASH !
   PATH-ONE-U @ 0 ?do
      PATH-ONE i + c@ 47 = if
         SLUG-LAST-SLASH @ SLUG-PARENT-SLASH !
         i SLUG-LAST-SLASH !
      then
   loop
   SLUG-LAST-SLASH @ -1 = s" Missing issue file or directory in .dots" ?FAIL
   \ The task's own folder lies inside its partition, never .dots/archive.
   idx F-ARCHIVED REC-CELL @ 0<> if s" .dots/archive/" else s" .dots/" then
   nip {: base-u:n :}
   SLUG-PARENT-SLASH @ 1+ base-u >= if
      PATH-ONE SLUG-PARENT-SLASH @ 1+ +
      SLUG-LAST-SLASH @ SLUG-PARENT-SLASH @ - 1-
      OLD-ID$ STR= if
         PATH-ONE SLUG-LAST-SLASH @ DIR? if
            1 SLUG-FOLDER !
            SB-RESET PATH-ONE SLUG-PARENT-SLASH @ 1+ SB-APPEND
            RENAMED-ID$ SB-APPEND SB$ PATH-TWO!
            exit
         then
      then
   then
   SB-RESET PATH-ONE SLUG-LAST-SLASH @ 1+ SB-APPEND
   RENAMED-ID$ SB-APPEND s" .md" SB-APPEND SB$ PATH-TWO! ;
: SLUG-CHILD-FROM$ ( -- ptr u8 n ) SLUG-CHILD-FROM SLUG-CHILD-FROM-U @ ;
: SLUG-CHILD-TO$ ( -- ptr u8 n ) SLUG-CHILD-TO SLUG-CHILD-TO-U @ ;
: SLUG-CHILD-PATH ( ptr u8 n ptr u8 -- n )
   {: id:ptr iu:n row:ptr :}
   SB-RESET s" .dots/" SB-APPEND id iu SB-APPEND SB$ {: path:ptr pu:n :}
   pu FS-PATH-CAP > s" I/O error" ?FAIL
   path row pu BYTE-COPY pu ;
\ A task with the old ID inside the folder owns it: SLUG-PLAN-PATH moves a
\ task's own folder, and a duplicate ID keeps its folder.
: SLUG-CHILD-OWNED? ( -- bool )
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ OLD-ID$ STR= if
         i F-PATH FIELD$ SLUG-CHILD-FROM$ STATUS-UNDER? if true unloop exit then
      then
   loop false ;
\ A task's legacy .dots/<id>/, where add -P used to put its children wherever
\ its own file lived, takes the new ID with the task. The archive directory is
\ never a child folder.
: SLUG-CHILD-MOVES? ( -- bool )
   SLUG-CHILD-FROM$ s" .dots/archive" STR= if false exit then
   SLUG-CHILD-FROM$ SYMLINK? if false exit then
   SLUG-CHILD-FROM$ DIR? 0= if false exit then
   SLUG-CHILD-OWNED? 0= ;
: SLUG-PLAN-CHILD ( -- )
   OLD-ID$ SLUG-CHILD-FROM SLUG-CHILD-PATH SLUG-CHILD-FROM-U !
   RENAMED-ID$ SLUG-CHILD-TO SLUG-CHILD-PATH SLUG-CHILD-TO-U !
   SLUG-CHILD-MOVES? if 1 else 0 then SLUG-CHILD-FOLDER ! ;
: SLUG-DEST-OCCUPIED? ( -- bool )
   PATH-TWO$ OCCUPIED? if true exit then
   SLUG-CHILD-FOLDER @ 0<> if SLUG-CHILD-TO$ OCCUPIED? exit then
   false ;
: SLUG-OLD-REMAINS? ( -- bool )
   ISSUE-N @ 0 ?do
      i F-ID FIELD$ OLD-ID$ STR= if true unloop exit then
   loop false ;
: SLUG-REWRITE-BLOCKS ( n -- )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   0 BLOCK-U ! 0 SLUG-CHANGED !
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   0 begin dup bu < while
      {: at:n :}
      blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
      block sz OLD-ID$ STR= if
         SLUG-KEEP-OLD @ 0<> if OLD-ID$ BLOCK-ADD then
         RENAMED-ID$ BLOCK-ADD 1 SLUG-CHANGED !
      else block sz BLOCK-ADD then
      next
   repeat drop
   SLUG-CHANGED @ 0<> if
      0 BLOCK-BUF BLOCK-U @ idx F-BLOCKS FIELD!
      1 idx 7 SLUG-CELL !
   then ;
: SLUG-PREPARE ( -- )
   RENAMED-ID$ SLUG-IDX @ ID!
   SLUG-CHILD-FOLDER @ 0<> if
      SLUG-CHILD-FROM$ SLUG-CHILD-TO$ SLUG-REBASE-RECORDS
   then
   SLUG-FOLDER @ 0<> if
      PATH-ONE SLUG-LAST-SLASH @ PATH-TWO$ SLUG-REBASE-RECORDS
      SB-RESET PATH-TWO$ SB-APPEND 47 SB-APPEND-C
      RENAMED-ID$ SB-APPEND s" .md" SB-APPEND SB$
      SLUG-IDX @ F-PATH FIELD!
   else PATH-TWO$ SLUG-IDX @ F-PATH FIELD! then
   SLUG-OLD-REMAINS? if 1 else 0 then SLUG-KEEP-OLD !
   ISSUE-N @ 0 ?do i SLUG-REWRITE-BLOCKS loop
   1 SLUG-IDX @ 7 SLUG-CELL ! ;
: SLUG-STAGE-ONE ( n -- )
   {: idx:n :}
   idx 0 SLUG-STORED$ RESERVE-ISSUE-SIBLING {: stage:ptr su:n stage-fd:n :}
   stage-fd close
   stage su idx 2 SLUG-STORE
   idx SERIALIZE
   idx 2 SLUG-STORED$ OUT$ WRITE-ATOMIC-THROW
   idx 0 SLUG-STORED$ RESERVE-ISSUE-SIBLING {: backup:ptr bu:n backup-fd:n :}
   backup-fd close
   backup bu idx 4 SLUG-STORE ;
: SLUG-STAGE ( -- )
   ISSUE-N @ 0 ?do
      i 7 SLUG-CELL @ 0<> if
         i 0 SLUG-STORED$ FILE? 0= if E-FS-IO throw then
         i SLUG-STAGE-ONE
      then
   loop ;
: SLUG-RENAME-NOREPLACE-THROW ( ptr u8 n ptr u8 n -- )
   RENAME-NOREPLACE-CAUSE
   dup 17 = if drop E-SLUG-COLLISION throw then
   dup FS-DIR-NOT-EMPTY = if drop E-SLUG-COLLISION throw then
   dup FS-ACCESS-DENIED = if drop E-ISSUE-PERMISSION throw then
   dup 0<> if drop E-FS-IO throw else drop then ;
: SLUG-RENAME-BACKUP ( ptr u8 n ptr u8 n -- )
   RENAME-CAUSE dup FS-ACCESS-DENIED = if drop E-ISSUE-PERMISSION throw then
   dup 0<> if drop E-FS-IO throw else drop then ;
: SLUG-UNLINK ( ptr u8 n -- )
   FS-PATHZ UNLINK-CALL FS-CAUSE
   dup 2 = if drop exit then
   dup FS-ACCESS-DENIED = if drop E-ISSUE-PERMISSION throw then
   dup 0<> if drop E-FS-IO throw else drop then ;
: SLUG-REBASE-STORED ( n n ptr u8 n ptr u8 n -- )
   {: idx:n field:n old:ptr ou:n new:ptr nu:n :}
   idx field SLUG-STORED$ {: path:ptr pu:n :}
   path pu old ou STATUS-UNDER? if
      SB-RESET new nu SB-APPEND path ou + pu ou - SB-APPEND SB$
      idx field SLUG-STORE
   then ;
\ Staged and backup files sit beside the originals and move with a folder.
: SLUG-REBASE-STAGED ( ptr u8 n ptr u8 n -- )
   {: old:ptr ou:n new:ptr nu:n :}
   ISSUE-N @ 0 ?do
      i 0 old ou new nu SLUG-REBASE-STORED
      i 2 old ou new nu SLUG-REBASE-STORED
      i 4 old ou new nu SLUG-REBASE-STORED
   loop ;
: SLUG-MOVE-FOLDERS ( -- )
   SLUG-FOLDER @ 0<> if
      PATH-ONE SLUG-LAST-SLASH @ PATH-TWO$ SLUG-RENAME-NOREPLACE-THROW
      1 SLUG-FOLDER-MOVED !
      PATH-ONE SLUG-LAST-SLASH @ PATH-TWO$ SLUG-REBASE-STAGED
   then
   SLUG-CHILD-FOLDER @ 0<> if
      SLUG-CHILD-FROM$ SLUG-CHILD-TO$ SLUG-RENAME-NOREPLACE-THROW
      1 SLUG-CHILD-MOVED !
      SLUG-CHILD-FROM$ SLUG-CHILD-TO$ SLUG-REBASE-STAGED
   then ;
: SLUG-RESTORE-FOLDERS ( -- )
   SLUG-CHILD-MOVED @ 0<> if
      SLUG-CHILD-TO$ SLUG-CHILD-FROM$ SLUG-RENAME-NOREPLACE-THROW
   then
   SLUG-FOLDER-MOVED @ 0<> if
      PATH-TWO$ PATH-ONE SLUG-LAST-SLASH @ SLUG-RENAME-NOREPLACE-THROW
   then ;
: SLUG-COMMIT ( -- )
   SLUG-MOVE-FOLDERS
   ISSUE-N @ 0 ?do
      i 7 SLUG-CELL @ 0<> if
         i 0 SLUG-STORED$ i 4 SLUG-STORED$ SLUG-RENAME-BACKUP
         1 i 6 SLUG-CELL !
         i 2 SLUG-STORED$ i F-PATH FIELD$ SLUG-RENAME-NOREPLACE-THROW
         2 i 6 SLUG-CELL !
      then
   loop ;
: SLUG-ROLLBACK ( -- )
   ISSUE-N @ 0 ?do
      i 7 SLUG-CELL @ 0<> if
         i 6 SLUG-CELL @ 2 = if i F-PATH FIELD$ SLUG-UNLINK then
         i 6 SLUG-CELL @ 0<> if
            i 4 SLUG-STORED$ i 0 SLUG-STORED$ SLUG-RENAME-NOREPLACE-THROW
         then
         i 2 SLUG-STORED$ nip 0<> if i 2 SLUG-STORED$ SLUG-UNLINK then
         i 4 SLUG-STORED$ nip 0<> if i 4 SLUG-STORED$ SLUG-UNLINK then
      then
   loop
   SLUG-RESTORE-FOLDERS ;
: SLUG-CLEANUP ( -- )
   ISSUE-N @ 0 ?do
      i 7 SLUG-CELL @ 0<> if
         i 2 SLUG-STORED$ SLUG-UNLINK
         i 4 SLUG-STORED$ SLUG-UNLINK
      then
   loop ;
: SLUG-SKIP ( -- )
   SB-RESET s" Skipping " SB-APPEND OLD-ID$ SB-APPEND
   s" : new ID " SB-APPEND RENAMED-ID$ SB-APPEND
   s"  already exists" SB-APPEND 10 SB-APPEND-C
   SB$ 2 -rot STDERR-WRITE drop ;
: SLUGIFY-ONE ( n -- )
   {: idx:n :}
   idx F-ERROR REC-CELL @ 0<> if exit then
   idx F-ID FIELD$ OLD-ID!
   idx SLUG-NEW-ID
   OLD-ID$ RENAMED-ID$ STR= if exit then
   RENAMED-ID$ CREATABLE-ID? 0= s" Invalid issue id" ?FAIL
   RENAMED-ID$ FIND-EXACT -1 <> if SLUG-SKIP exit then
   idx F-PATH FIELD$ FILE? 0= s" Issue not found" ?FAIL
   idx SLUG-PLAN-PATH SLUG-PLAN-CHILD
   SLUG-DEST-OCCUPIED? if SLUG-SKIP exit then
   idx SLUG-IDX !
   SLUG-INIT
   [: SLUG-PREPARE SLUG-STAGE SLUG-COMMIT ;] catch {: code:n :}
   code 0<> if
      [: SLUG-ROLLBACK ;] catch dup 0<> if drop E-FS-IO throw then drop
      code E-SLUG-COLLISION = s" Issue already exists" ?FAIL
      code REPORT-FAILURE
   then
   [: SLUG-CLEANUP ;] catch dup 0<> if
      drop s" Warning: temporary cleanup failed" 2 -rot STDERR-WRITE drop
   else drop then
   OLD-ID$ DOT-IO:PRINT s"  -> " DOT-IO:PRINT RENAMED-ID$ DOT-IO:PRINTLN
   1 SLUG-RENAMED +! ;
create GIT-EXEC-ROW PATH-CAP allot
: GIT-ADD-DOTS ( -- )
   STORE? 0= if exit then
   s" .git" EXISTS? 0= if exit then
   s" git" >LEN GIT-EXEC-ROW FIND-EXECUTABLE MATCH option
      none OF s\" Warning: git not found; .dots not staged\n" 2 -rot STDERR-WRITE drop ENDOF
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
   ASSERT-ARCHIVE-REAL
   true LOAD-ISSUES LOAD-PREFIX
   0 SLUG-RENAMED !
   ['] ID-LESS? SORT-ISSUES
   ISSUE-N @ 0 ?do i ORDER @ SLUGIFY-ONE loop
   s" Slugified " DOT-IO:PRINT SLUG-RENAMED @ DOT-IO:INT s"  issue(s)" DOT-IO:PRINTLN
   GIT-ADD-DOTS ;

\ JSONL migration reads each line through a JSONL cursor, which keeps the line
\ live until every typed field and dependency has been decoded; the cursor
\ closes itself at end of input.
TYPED-VARIABLE JSONL-CURSOR JSONL:cursor
create JSONL-DECODE-BUF 1048576 allot
DYNAMIC-BUFFER IMPORT-DEP-BUF u8
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

: JSONL-MALFORMED ( JR:reader -- ) JR:CLOSE E-JR-MALFORMED throw ;
: JSONL-START ( -- JR:reader )
   JSONL-CURSOR JSONL:READER
   JR:NEXT JR:T-OBJ <> if JSONL-MALFORMED then ;
: JSONL-VALIDATE ( -- )
   0 JSONL-SEEN !
   JSONL-START
   begin JR:NEXT dup JR:T-OBJ-END <> while
      JR:T-KEY <> if JSONL-MALFORMED then
      JSONL-KEY-BIT {: bit:n :}
      JSONL-SEEN @ bit and 0<> if JSONL-MALFORMED then
      JSONL-SEEN @ bit or JSONL-SEEN !
      JR:NEXT drop JR:SKIP-VALUE
   repeat drop
   JR:NEXT JR:T-END <> if JSONL-MALFORMED then
   JR:CLOSE ;
: JSONL-FIND ( ptr u8 n -- JR:reader bool )
   {: key:ptr ku:n :}
   JSONL-START key ku JR:FIND-KEY ;
variable JSONL-BYTE-U
: JSONL-BYTE-VALUE ( ptr u8 n -- n )
   DECIMAL:EXACT MATCH option
      none OF E-JR-MALFORMED throw ENDOF
      some OF ENDOF
   ;MATCH
   dup 0 < over 255 > or if E-JR-MALFORMED throw then ;
: JSONL-BYTE-ELEM ( JR:reader -- JR:reader n )
   JR:TOKEN {: kind:n :}
   kind JR:T-STR = if
      JSONL-DECODE-BUF JSONL-BYTE-U @ +
      1048576 JSONL-BYTE-U @ - JR:STR {: size:n :}
      JSONL-DECODE-BUF JSONL-BYTE-U @ + size JSONL-BYTE-VALUE exit
   then
   kind JR:T-INT = kind JR:T-FLOAT = or if
      JR:SPAN$ JSONL-BYTE-VALUE exit
   then
   E-JR-MALFORMED throw ;
: JSONL-BYTE-ARRAY ( JR:reader -- JR:reader n )
   0 JSONL-BYTE-U !
   begin JR:NEXT dup JR:T-ARR-END <> while
      drop
      JSONL-BYTE-U @ 1048576 >= if E-JR-MALFORMED throw then
      JSONL-BYTE-ELEM JSONL-DECODE-BUF JSONL-BYTE-U @ + c!
      1 JSONL-BYTE-U +!
   repeat drop JSONL-BYTE-U @ ;
: JSONL-STRING-VALUE ( JR:reader -- JR:reader n )
   JR:TOKEN dup JR:T-STR = if
      drop JSONL-DECODE-BUF 1048576 JR:STR exit
   then
   JR:T-ARR = if JSONL-BYTE-ARRAY exit then
   E-JR-MALFORMED throw ;
\ The decoded string under the key, in JSONL-DECODE-BUF, and true; or an
\ empty span and false when the key is absent or null. The reader stays open.
: JSONL-STRING? ( ptr u8 n -- JR:reader ptr u8 n bool )
   JSONL-FIND if
      JR:TOKEN JR:T-NULL = if s" " false exit then
      JSONL-STRING-VALUE {: size:n :}
      JSONL-DECODE-BUF size true exit
   then s" " false ;
: JSONL-STRING-FIELD ( ptr u8 n n -- bool )
   {: field:n :}
   JSONL-STRING? {: present:bool :}
   present if IMPORT-IDX @ field FIELD! else 2drop then
   JR:CLOSE present ;
: JSONL-REQUIRED-STRING ( ptr u8 n n -- )
   JSONL-STRING-FIELD 0= if E-JR-MALFORMED throw then ;
: JSONL-PRIORITY ( -- )
   s" priority" JSONL-FIND 0= if JSONL-MALFORMED then
   JR:TOKEN {: kind:n :}
   kind JR:T-INT = if
      JR:INT IMPORT-IDX @ F-PRIORITY REC-CELL ! JR:CLOSE exit
   then
   kind JR:T-STR = kind JR:T-FLOAT = or 0= if JSONL-MALFORMED then
   kind JR:T-STR = if
      JSONL-DECODE-BUF 1048576 JR:STR {: size:n :} JSONL-DECODE-BUF size
   else JR:SPAN$ then
   DECIMAL:EXACT MATCH option
      none OF JSONL-MALFORMED ENDOF
      some OF IMPORT-IDX @ F-PRIORITY REC-CELL ! ENDOF
   ;MATCH
   JR:CLOSE ;
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
         JSONL-STRING-VALUE {: size:n :}
         JSONL-DECODE-BUF size DEP-ID!
      else type-key if
         token JR:T-NULL = if -1 DEP-TYPE-U ! else
            JSONL-STRING-VALUE {: size:n :}
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
      JR:T-ARR <> if JSONL-MALFORMED then
      begin JR:NEXT dup JR:T-ARR-END <> while
         JR:T-OBJ <> if E-JR-MALFORMED throw then
         JSONL-DEP-OBJECT
      repeat drop JR:CLOSE
   else JR:CLOSE then ;
: JSONL-PARSE-LINE ( -- )
   JSONL-VALIDATE
   s" " NEW-RECORD IMPORT-IDX !
   0 IMPORT-DEP-U !
   s" id" JSONL-STRING? 0= if 2drop JR:CLOSE E-JR-MALFORMED throw then
   IMPORT-IDX @ ID! JR:CLOSE
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
   JSONL-DEPENDENCIES
   \ The requested blockers wait in the blocks field until the row is placed.
   IMPORT-DEP-U @ 0 > if
      0 IMPORT-DEP-BUF IMPORT-DEP-U @ IMPORT-IDX @ F-BLOCKS FIELD!
   then ;

\ A row whose parent is neither a task nor a placed row waits aside, holding
\ its record's cells in PENDING, until that parent's row is placed or the
\ stream ends. A waiting row keeps its slot for the whole import, never shifted
\ or reused, so slot order is row order; PENDING-N counts the live ones and
\ PENDING-SLOTS every slot taken. WAIT holds each slot's own id node (W-NODE,
\ -1 once the row left), its parent's id node (W-PARENT), the next slot
\ waiting on that parent (W-NEXT) and the first and last edges held for the
\ slot (W-HELD, W-HELD-TAIL), each -1 for none. No live slot is below
\ PENDING-FIRST.
DYNAMIC-BUFFER PENDING n
variable PENDING-N
variable PENDING-SLOTS
variable PENDING-FIRST
: PENDING-CELL ( n n -- ptr n )
   {: at:n field:n :}
   at REC-CELLS * field + PENDING ;
: PENDING$ ( n n -- ptr u8 n )
   {: at:n field:n :}
   at field 2 * PENDING-CELL @ ARENA at field 2 * 1+ PENDING-CELL @ ;
DYNAMIC-BUFFER WAIT n
0 constant W-NODE
1 constant W-PARENT
2 constant W-NEXT
3 constant W-HELD
4 constant W-HELD-TAIL
5 constant WAIT-CELLS
: WAIT-CELL ( n n -- ptr n )
   {: at:n field:n :}
   at WAIT-CELLS * field + WAIT ;
\ The waiting slot the row at IMPORT-IDX came from, -1 for a row read straight
\ from its line: UNPEND sets it to the slot, and IMPORT-ROW sets -1 on entry.
variable IMPORT-SLOT
\ The id nodes, one per id that is waiting or waited on, in chained hash
\ buckets as the record id index: NODE-HEADS holds the first node of each
\ bucket and N-NEXT the node after each, -1 for none. N-ROW is the live slot
\ with the id, N-HEAD and N-TAIL the first and last live slots waiting on the
\ id as their parent, linked in slot order through W-NEXT; each is -1 for
\ none. A node is unblocked while N-ROW is -1. Nodes are bump-allocated:
\ NODE-N only grows during an import, no node is released on its own, and
\ IMPORT-JSONL's reset releases them all together.
\ A node's key, N-KEY and N-KEY-U, is the arena offset and length of the id
\ that made it, copied from a waiting slot's F-ID or F-PARENT cells as HOLD
\ copies ids into HELD. The cells cannot go stale: FIELD! only appends, and
\ IMPORT-PROCESS-LINE rewinds the arena only for a line that left no row
\ placed or waiting, so a waiting row's bytes stay for the whole import.
DYNAMIC-BUFFER NODE n
0 constant N-NEXT
1 constant N-ROW
2 constant N-HEAD
3 constant N-TAIL
4 constant N-KEY
5 constant N-KEY-U
6 constant NODE-CELLS
: NODE-CELL ( n n -- ptr n )
   {: node:n field:n :}
   node NODE-CELLS * field + NODE ;
DYNAMIC-BUFFER NODE-HEADS n
variable NODE-N
variable NODE-BUCKETS
: NODE-KEY$ ( n -- ptr u8 n )
   {: node:n :}
   node N-KEY NODE-CELL @ ARENA node N-KEY-U NODE-CELL @ ;
: NODE-CHAIN ( n -- )
   {: node:n :}
   node NODE-KEY$ STR-HASH NODE-BUCKETS @ BUCKET {: b:n :}
   b NODE-HEADS @ node N-NEXT NODE-CELL !
   node b NODE-HEADS ! ;
\ At least 64 buckets, doubled until no fewer than the nodes.
: NODE-REBUILD ( -- )
   NODE-BUCKETS @ 64 max begin dup NODE-N @ < while 2 * repeat {: count:n :}
   count NODE-BUCKETS !
   count NODE-HEADS-RESERVE
   count 0 ?do -1 i NODE-HEADS ! loop
   NODE-N @ 0 ?do i NODE-CHAIN loop ;
\ The node with the id, or -1.
: NODE-FIND ( ptr u8 n -- n )
   {: key:ptr ku:n :}
   NODE-BUCKETS @ 0= if -1 exit then
   key ku STR-HASH NODE-BUCKETS @ BUCKET NODE-HEADS @
   begin dup -1 <> while
      dup NODE-KEY$ key ku STR= if exit then
      N-NEXT NODE-CELL @
   repeat ;
\ The node of the waiting slot's F-ID or F-PARENT, made when it is new.
: NODE-FOR ( n n -- n )
   {: at:n field:n :}
   at field PENDING$ NODE-FIND dup -1 <> if exit then drop
   NODE-N @ {: node:n :}
   node 1+ NODE-CELLS * NODE-RESERVE
   -1 node N-ROW NODE-CELL !
   -1 node N-HEAD NODE-CELL !
   -1 node N-TAIL NODE-CELL !
   at field 2 * PENDING-CELL @ node N-KEY NODE-CELL !
   at field 2 * 1+ PENDING-CELL @ node N-KEY-U NODE-CELL !
   1 NODE-N +!
   NODE-N @ NODE-BUCKETS @ > if NODE-REBUILD else node NODE-CHAIN then
   node ;
\ The root heap: entries of a slot and a node, two cells each, in a binary
\ min-heap by slot. An entry is current while its node is unblocked and the
\ slot is still the node's head: a slot leaves its FIFO once and nodes are
\ never reused, so an entry whose slot left never matches again. Invariant:
\ every live slot whose parent is not waiting is in the FIFO of an unblocked
\ node, and that node has a current entry, so the least current entry is the
\ first live slot whose parent is not waiting. An entry dropped while its node
\ is blocked is not lost: the UNPEND that unblocks the node offers it again.
DYNAMIC-BUFFER ROOTS n
variable ROOTS-N
: ROOT-SLOT ( n -- n ) 2 * ROOTS @ ;
\ Exchange the entries at the two heap positions.
: ROOT-SWAP ( n n -- )
   {: a:n b:n :}
   a 2 * ROOTS @ {: slot:n :}
   a 2 * 1+ ROOTS @ {: node:n :}
   b 2 * ROOTS @ a 2 * ROOTS !
   b 2 * 1+ ROOTS @ a 2 * 1+ ROOTS !
   slot b 2 * ROOTS !
   node b 2 * 1+ ROOTS ! ;
: ROOT-PUSH ( n n -- )
   {: slot:n node:n :}
   ROOTS-N @ 1+ 2 * ROOTS-RESERVE
   ROOTS-N @ {: at:n :}
   slot at 2 * ROOTS !
   node at 2 * 1+ ROOTS !
   1 ROOTS-N +!
   at begin dup 0 > while
      {: pos:n :}
      pos 1- 2 / {: up:n :}
      up ROOT-SLOT pos ROOT-SLOT <= if exit then
      up pos ROOT-SWAP up
   repeat drop ;
\ Take the entry with the least slot.
: ROOT-POP ( -- n n )
   0 ROOTS @ 1 ROOTS @
   -1 ROOTS-N +!
   ROOTS-N @ 2 * ROOTS @ 0 ROOTS !
   ROOTS-N @ 2 * 1+ ROOTS @ 1 ROOTS !
   0 begin
      {: pos:n :}
      pos 2 * 1+ {: left:n :}
      left ROOTS-N @ >= if exit then
      left 1+ ROOTS-N @ < if left 1+ ROOT-SLOT left ROOT-SLOT < else false then
      if left 1+ else left then {: least:n :}
      pos ROOT-SLOT least ROOT-SLOT <= if exit then
      pos least ROOT-SWAP least
   again ;
\ Whether the entry of the slot and node is current.
: ROOT-CURRENT? ( n n -- bool )
   {: slot:n node:n :}
   node N-ROW NODE-CELL @ -1 = node N-HEAD NODE-CELL @ slot = and ;
\ Push the node with its head when it is unblocked and has one.
: ROOT-OFFER ( n -- )
   {: node:n :}
   node N-ROW NODE-CELL @ -1 = node N-HEAD NODE-CELL @ -1 <> and if
      node N-HEAD NODE-CELL @ node ROOT-PUSH
   then ;
\ The waiting row with the id, or -1.
: PENDING-FIND ( ptr u8 n -- n )
   NODE-FIND dup -1 <> if N-ROW NODE-CELL @ then ;
\ The first waiting row whose parent has the id, or -1.
: PENDING-CHILD ( ptr u8 n -- n )
   NODE-FIND dup -1 <> if N-HEAD NODE-CELL @ then ;
\ Set the row at IMPORT-IDX, the last record, aside in a new slot, at the tail
\ of its parent's FIFO. A row that names itself as its parent waits on its own
\ node, so it is blocked.
: PEND ( -- )
   PENDING-SLOTS @ {: at:n :}
   at 1+ REC-CELLS * PENDING-RESERVE
   at 1+ WAIT-CELLS * WAIT-RESERVE
   REC-CELLS 0 ?do IMPORT-IDX @ i REC-CELL @ at i PENDING-CELL ! loop
   at F-ID NODE-FOR {: own:n :}
   at own N-ROW NODE-CELL !
   at F-PARENT NODE-FOR {: up:n :}
   up N-HEAD NODE-CELL @ -1 = {: empty:bool :}
   -1 at W-NEXT WAIT-CELL !
   empty if at up N-HEAD NODE-CELL !
   else at up N-TAIL NODE-CELL @ W-NEXT WAIT-CELL ! then
   at up N-TAIL NODE-CELL !
   own at W-NODE WAIT-CELL !
   up at W-PARENT WAIT-CELL !
   -1 at W-HELD WAIT-CELL !
   -1 at W-HELD-TAIL WAIT-CELL !
   empty if up ROOT-OFFER then
   1 PENDING-SLOTS +!
   1 PENDING-N +!
   POP-RECORD ;
\ Make the waiting row at the slot the last record, at IMPORT-IDX. The slot
\ heads its parent's FIFO, as every caller's does: PENDING-CHILD returns the
\ node's N-HEAD, a current heap entry is its node's N-HEAD, and the fallback
\ returns the lowest live slot, which heads its FIFO since each FIFO is in slot
\ order.
: UNPEND ( n -- )
   {: at:n :}
   ISSUE-N @ 1+ REC-CELLS * RECORDS-RESERVE
   ISSUE-N @ IMPORT-IDX !
   1 ISSUE-N +!
   REC-CELLS 0 ?do at i PENDING-CELL @ IMPORT-IDX @ i REC-CELL ! loop
   IMPORT-IDX @ ID-LINK
   at W-NODE WAIT-CELL @ {: own:n :}
   at W-PARENT WAIT-CELL @ {: up:n :}
   at W-NEXT WAIT-CELL @ {: next:n :}
   next up N-HEAD NODE-CELL !
   next -1 = if -1 up N-TAIL NODE-CELL ! then
   -1 own N-ROW NODE-CELL !
   own ROOT-OFFER
   up own <> if up ROOT-OFFER then
   -1 at W-NODE WAIT-CELL !
   at IMPORT-SLOT !
   -1 PENDING-N +! ;
\ Edges to a waiting row, held until that row is placed or skipped: three
\ cells each, the arena offset and length of the blocking row's id (H-KEY,
\ H-KEY-U) and the next edge held for the same waiting slot (H-NEXT, -1 for
\ none), each slot's edges linked in the order read from its W-HELD to its
\ W-HELD-TAIL. Offsets, not pointers: growth moves the arena. Edges are
\ bump-allocated: HELD-N only grows during an import, and IMPORT-JSONL's reset
\ releases them all.
DYNAMIC-BUFFER HELD n
0 constant H-KEY
1 constant H-KEY-U
2 constant H-NEXT
3 constant HELD-CELLS
: HELD-CELL ( n n -- ptr n )
   {: edge:n field:n :}
   edge HELD-CELLS * field + HELD ;
variable HELD-N
: HELD-BLOCKER$ ( n -- ptr u8 n )
   {: edge:n :}
   edge H-KEY HELD-CELL @ ARENA edge H-KEY-U HELD-CELL @ ;
\ Hold an edge from the row at the source index to the waiting row at the slot,
\ at the tail of the slot's edges. Every hold runs after its source row's
\ SAVE-RECORD, so that row stays placed and no line's arena rewind reaches its
\ id bytes.
: HOLD ( n n -- )
   {: src:n at:n :}
   HELD-N @ {: edge:n :}
   edge 1+ HELD-CELLS * HELD-RESERVE
   src F-ID 2 * REC-CELL @ edge H-KEY HELD-CELL !
   src F-ID 2 * 1+ REC-CELL @ edge H-KEY-U HELD-CELL !
   -1 edge H-NEXT HELD-CELL !
   at W-HELD WAIT-CELL @ -1 = if edge at W-HELD WAIT-CELL !
   else edge at W-HELD-TAIL WAIT-CELL @ H-NEXT HELD-CELL ! then
   edge at W-HELD-TAIL WAIT-CELL !
   1 HELD-N +! ;
\ Who blocks on an id: the inverse of the blocks fields of records
\ 0..ISSUE-N-1 during an import, one node per id named, keyed by arena bytes
\ equal to the id as FIND-EXACT resolves it, in chained hash buckets as the id
\ nodes. BLOCKED-HEADS holds each bucket's first node and BD-NEXT the node
\ after each; BD-EDGES is a node's first edge and E-NEXT the edge after each,
\ each -1 for none; E-SRC is the record whose blocks field names the id. Nodes
\ and edges are bump-allocated and released together by IMPORT-JSONL's reset.
\ No blocks field written during an import escapes the index: the load's,
\ PARSE-RECORD and PARSE-FILE, come before BLOCKED-BUILD indexes them;
\ NEW-RECORD's is empty; JSONL-PARSE-LINE's are the raw requests of the
\ unplaced last record, which IMPORT-TAKE-DEPS empties before any search; and
\ IMPORT-ADD-BLOCK indexes its entry. No key goes stale: FIELD! only appends,
\ ids do not change during an import, and IMPORT-PROCESS-LINE rewinds the arena
\ only for a line that placed nothing, while edges are written only after a
\ placement in the line.
DYNAMIC-BUFFER BLOCKED n
0 constant BD-NEXT
1 constant BD-KEY
2 constant BD-KEY-U
3 constant BD-EDGES
4 constant BLOCKED-CELLS
: BLOCKED-CELL ( n n -- ptr n )
   {: node:n field:n :}
   node BLOCKED-CELLS * field + BLOCKED ;
DYNAMIC-BUFFER BLOCKED-HEADS n
variable BLOCKED-N
variable BLOCKED-BUCKETS
DYNAMIC-BUFFER EDGE n
0 constant E-SRC
1 constant E-NEXT
2 constant EDGE-CELLS
: EDGE-CELL ( n n -- ptr n )
   {: edge:n field:n :}
   edge EDGE-CELLS * field + EDGE ;
variable EDGE-N
: BLOCKED-KEY$ ( n -- ptr u8 n )
   {: node:n :}
   node BD-KEY BLOCKED-CELL @ ARENA node BD-KEY-U BLOCKED-CELL @ ;
: BLOCKED-CHAIN ( n -- )
   {: node:n :}
   node BLOCKED-KEY$ STR-HASH BLOCKED-BUCKETS @ BUCKET {: b:n :}
   b BLOCKED-HEADS @ node BD-NEXT BLOCKED-CELL !
   node b BLOCKED-HEADS ! ;
\ At least 64 buckets, doubled until no fewer than the nodes.
: BLOCKED-REBUILD ( -- )
   BLOCKED-BUCKETS @ 64 max begin dup BLOCKED-N @ < while 2 * repeat {: count:n :}
   count BLOCKED-BUCKETS !
   count BLOCKED-HEADS-RESERVE
   count 0 ?do -1 i BLOCKED-HEADS ! loop
   BLOCKED-N @ 0 ?do i BLOCKED-CHAIN loop ;
\ The node with the id, or -1.
: BLOCKED-FIND ( ptr u8 n -- n )
   {: key:ptr ku:n :}
   BLOCKED-BUCKETS @ 0= if -1 exit then
   key ku STR-HASH BLOCKED-BUCKETS @ BUCKET BLOCKED-HEADS @
   begin dup -1 <> while
      dup BLOCKED-KEY$ key ku STR= if exit then
      BD-NEXT BLOCKED-CELL @
   repeat ;
\ The node of the id at the arena offset and length, made when it is new.
: BLOCKED-FOR ( n n -- n )
   {: off:n u:n :}
   off ARENA u BLOCKED-FIND dup -1 <> if exit then drop
   BLOCKED-N @ {: node:n :}
   node 1+ BLOCKED-CELLS * BLOCKED-RESERVE
   off node BD-KEY BLOCKED-CELL !
   u node BD-KEY-U BLOCKED-CELL !
   -1 node BD-EDGES BLOCKED-CELL !
   1 BLOCKED-N +!
   BLOCKED-N @ BLOCKED-BUCKETS @ > if BLOCKED-REBUILD else node BLOCKED-CHAIN then
   node ;
\ Index the edge from the record at the source index to the id at the arena
\ offset and length.
: EDGE-ADD ( n n n -- )
   {: off:n u:n src:n :}
   off u BLOCKED-FOR {: node:n :}
   EDGE-N @ {: edge:n :}
   edge 1+ EDGE-CELLS * EDGE-RESERVE
   src edge E-SRC EDGE-CELL !
   node BD-EDGES BLOCKED-CELL @ edge E-NEXT EDGE-CELL !
   edge node BD-EDGES BLOCKED-CELL !
   1 EDGE-N +! ;
\ Index the blocks fields of the records loaded.
: BLOCKED-BUILD ( -- )
   0 BLOCKED-N ! 0 BLOCKED-BUCKETS ! 0 EDGE-N !
   ISSUE-N @ 0 ?do
      i F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
      i F-BLOCKS 2 * REC-CELL @ {: base:n :}
      0 begin dup bu < while
         {: at:n :}
         blocks bu at NEXT-LINE drop rot drop {: sz:n next:n :}
         base at + sz i EDGE-ADD
         next
      repeat drop
   loop ;
\ Whether the record at the target reaches the one at the source over the
\ blocks fields, entries resolved as FIND-EXACT resolves them. A forward search
\ from the target over the blocks fields and a backward one from the source
\ over BLOCKED advance one record each in turn: a record both reach is a path,
\ and either running out is none. A row's held edges are written before its own
\ and its own after its placement: the forward search for a held edge finds no
\ edge out of its row, and the backward one for an edge from a row just placed
\ finds no edge into it but those just held and any loaded entry naming its id,
\ so an import's edge costs about one record's degree. A stamp equal to CYCLE-GEN marks a record reached by this
\ search; stamps are never reset, since older ones are older generations.
DYNAMIC-BUFFER CYCLE-FWD n
DYNAMIC-BUFFER CYCLE-BWD n
variable CYCLE-SEEN-N
variable CYCLE-GEN
DYNAMIC-BUFFER CYCLE-QUEUE n
variable CYCLE-HEAD
variable CYCLE-TAIL
DYNAMIC-BUFFER CYCLE-BACK n
variable CYCLE-BHEAD
variable CYCLE-BTAIL
\ Stamps and queue room for every record: a search queues a record at most once
\ on each side. The stamps it exposes are zeroed, older than any search.
: CYCLE-GROW ( -- )
   ISSUE-N @ CYCLE-SEEN-N @ > if
      ISSUE-N @ CYCLE-FWD-RESERVE
      ISSUE-N @ CYCLE-BWD-RESERVE
      ISSUE-N @ CYCLE-QUEUE-RESERVE
      ISSUE-N @ CYCLE-BACK-RESERVE
      ISSUE-N @ CYCLE-SEEN-N @ ?do 0 i CYCLE-FWD ! 0 i CYCLE-BWD ! loop
      ISSUE-N @ CYCLE-SEEN-N !
   then ;
\ Reach the record from the target: true when the source's side reached it.
: FWD-PUSH ( n -- bool )
   {: idx:n :}
   idx CYCLE-FWD @ CYCLE-GEN @ = if false exit then
   idx CYCLE-BWD @ CYCLE-GEN @ = if true exit then
   CYCLE-GEN @ idx CYCLE-FWD !
   idx CYCLE-TAIL @ CYCLE-QUEUE ! 1 CYCLE-TAIL +!
   false ;
\ Reach the record from the source: true when the target's side reached it.
: BWD-PUSH ( n -- bool )
   {: idx:n :}
   idx CYCLE-BWD @ CYCLE-GEN @ = if false exit then
   idx CYCLE-FWD @ CYCLE-GEN @ = if true exit then
   CYCLE-GEN @ idx CYCLE-BWD !
   idx CYCLE-BTAIL @ CYCLE-BACK ! 1 CYCLE-BTAIL +!
   false ;
\ Follow the edges out of the next record the target reached.
: FWD-STEP ( -- bool )
   CYCLE-HEAD @ CYCLE-QUEUE @ {: idx:n :}
   1 CYCLE-HEAD +!
   idx F-BLOCKS FIELD$ {: blocks:ptr bu:n :}
   0 begin dup bu < while
      {: at:n :}
      blocks bu at NEXT-LINE drop {: block:ptr sz:n next:n :}
      block sz FIND-EXACT dup -1 <> if FWD-PUSH if true exit then else drop then
      next
   repeat drop false ;
\ Follow the edges into the next record the source reached.
: BWD-STEP ( -- bool )
   CYCLE-BHEAD @ CYCLE-BACK @ {: idx:n :}
   1 CYCLE-BHEAD +!
   idx F-ID FIELD$
   \ Only the record FIND-EXACT resolves the id to has edges in: filesystem
   \ duplicates are real.
   2dup FIND-EXACT idx <> if 2drop false exit then
   BLOCKED-FIND dup -1 = if drop false exit then
   BD-EDGES BLOCKED-CELL @
   begin dup -1 <> while
      dup E-SRC EDGE-CELL @ BWD-PUSH if drop true exit then
      E-NEXT EDGE-CELL @
   repeat drop false ;
: WOULD-CYCLE? ( n n -- bool )
   {: target:n src:n :}
   CYCLE-GROW 1 CYCLE-GEN +!
   0 CYCLE-HEAD ! 0 CYCLE-TAIL ! 0 CYCLE-BHEAD ! 0 CYCLE-BTAIL !
   target FWD-PUSH drop
   src BWD-PUSH if true exit then   \ a row naming itself
   begin CYCLE-HEAD @ CYCLE-TAIL @ < while
      FWD-STEP if true exit then
      CYCLE-BHEAD @ CYCLE-BTAIL @ < 0= if false exit then
      BWD-STEP if true exit then
   repeat false ;
\ Give the row at the source index an edge to the row with the id; one to a
\ waiting row is held until that row is placed.
: IMPORT-ADD-BLOCK ( ptr u8 n n -- )
   {: block:ptr bu:n src:n :}
   block bu VALID-ID? 0= if 1 DEP-SKIPPED-N +! exit then
   block bu FIND-EXACT dup -1 = if
      drop block bu PENDING-FIND dup -1 <> if src swap HOLD exit then
      drop 1 DEP-SKIPPED-N +! exit
   then
   {: target:n :}
   target RECORD-PATH? 0= if 1 DEP-SKIPPED-N +! exit then
   target src WOULD-CYCLE? if 1 DEP-SKIPPED-N +! exit then
   src F-BLOCKS FIELD$ {: old:ptr ou:n :}
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
   0 BLOCK-BUF BLOCK-U @ src F-BLOCKS FIELD!
   target F-ID 2 * REC-CELL @ target F-ID 2 * 1+ REC-CELL @ src EDGE-ADD
   src SAVE-RECORD ;
: IMPORT-ADD-DEPENDENCIES ( -- )
   0 begin dup IMPORT-DEP-U @ < while
      {: at:n :}
      0 IMPORT-DEP-BUF IMPORT-DEP-U @ at NEXT-LINE drop
      {: block:ptr bu:n next:n :}
      block bu IMPORT-IDX @ IMPORT-ADD-BLOCK
      next
   repeat drop ;
\ Write the edges held for the row placed at the index from IMPORT-SLOT, in the
\ order read. The row's id cells are the slot's, the bytes each edge was held
\ for.
: IMPORT-ADD-HELD ( n -- )
   {: idx:n :}
   IMPORT-SLOT @ {: at:n :}
   at -1 = if exit then
   at W-HELD WAIT-CELL @
   begin dup -1 <> while
      {: edge:n :}
      idx F-ID FIELD$ edge HELD-BLOCKER$ FIND-EXACT IMPORT-ADD-BLOCK
      edge H-NEXT HELD-CELL @
   repeat drop
   -1 at W-HELD WAIT-CELL !
   -1 at W-HELD-TAIL WAIT-CELL ! ;
\ Drop the edges held for the row at IMPORT-IDX, taken from IMPORT-SLOT, each a
\ skipped dependency.
: DROP-HELD ( -- )
   IMPORT-SLOT @ {: at:n :}
   at -1 = if exit then
   at W-HELD WAIT-CELL @
   begin dup -1 <> while
      1 DEP-SKIPPED-N +!
      H-NEXT HELD-CELL @
   repeat drop
   -1 at W-HELD WAIT-CELL !
   -1 at W-HELD-TAIL WAIT-CELL ! ;
\ The import's top-folder groups: every record 0..ISSUE-N-1 is in the group
\ named by the first component of its path below its partition, each group's
\ members in ascending record order. Import links a record as the last step of
\ placing it and its moves keep that component, so the groups stay current. A
\ group's key is re-read from its first member's path, since arena growth
\ remaps: no key pointer is kept.
DYNAMIC-BUFFER TOP-HEADS n   \ bucket -> first group, -1
DYNAMIC-BUFFER TOP-CHAIN n   \ group -> next group in its bucket
DYNAMIC-BUFFER TOP-FIRST n   \ group -> first member
DYNAMIC-BUFFER TOP-LAST n    \ group -> last member
DYNAMIC-BUFFER TOP-NEXT n    \ record -> next member, -1
variable TOP-N
variable TOP-BUCKETS
\ .dots/X.md, .dots/X/... and .dots/archive/X/... name X.
: TOP-NAME ( n -- ptr u8 n )
   F-PATH FIELD$ {: path:ptr pu:n :}
   path pu ARCHIVE-PATH? if 14 else 6 then {: start:n :}
   start begin dup pu < while
      dup path + c@ 47 = if path start + swap start - exit then
      1+
   repeat drop path start + pu start - 3 - ;
: TOP-KEY ( n -- ptr u8 n ) TOP-FIRST @ TOP-NAME ;
\ The group with the name, or -1.
: TOP-FIND ( ptr u8 n -- n )
   {: a:ptr u:n :}
   a u STR-HASH TOP-BUCKETS @ BUCKET TOP-HEADS @
   begin dup -1 <> while dup TOP-KEY a u STR= if exit then TOP-CHAIN @ repeat ;
\ Push the group at the head of its bucket.
: TOP-CHAIN! ( n -- )
   {: g:n :}
   g TOP-KEY STR-HASH TOP-BUCKETS @ BUCKET {: b:n :}
   b TOP-HEADS @ g TOP-CHAIN ! g b TOP-HEADS ! ;
\ Rechain every group into the bucket count.
: TOP-REHASH ( n -- )
   dup TOP-BUCKETS ! dup TOP-HEADS-RESERVE 0 ?do -1 i TOP-HEADS ! loop
   TOP-N @ 0 ?do i TOP-CHAIN! loop ;
\ Append the record to its group, creating the group.
: TOP-LINK ( n -- )
   {: idx:n :}
   idx 1+ TOP-NEXT-RESERVE -1 idx TOP-NEXT !
   idx TOP-NAME TOP-FIND {: found:n :}
   found -1 <> if idx found TOP-LAST @ TOP-NEXT ! idx found TOP-LAST ! exit then
   TOP-N @ {: g:n :}
   g 1+ dup TOP-FIRST-RESERVE dup TOP-LAST-RESERVE TOP-CHAIN-RESERVE
   idx g TOP-FIRST ! idx g TOP-LAST ! g 1+ TOP-N !
   g TOP-BUCKETS @ >= if TOP-BUCKETS @ 2 * TOP-REHASH else g TOP-CHAIN! then ;
: TOP-REBUILD ( -- ) 0 TOP-N ! 64 TOP-REHASH ISSUE-N @ 0 ?do i TOP-LINK loop ;
\ The first member of the record's group.
: TOP-MEMBERS ( n -- n ) TOP-NAME TOP-FIND TOP-FIRST @ ;
\ The archive pass handles top-level records (F-CHILD = 0), whose
\ descendants and subtree all lie in their own group.
: TOP-CHILDREN-OPEN? ( n -- bool )
   {: idx:n :}
   idx TOP-MEMBERS begin dup -1 <> while
      dup idx OPEN-DESCENDANT? if drop true exit then
      TOP-NEXT @
   repeat drop false ;
: TOP-VALIDATE ( n -- )
   {: idx:n :}
   idx TOP-MEMBERS begin dup -1 <> while
      dup idx CHECK-DESCENDANT
      TOP-NEXT @
   repeat drop ;
: TOP-REBASE-SUBTREE ( n ptr u8 n ptr u8 n -- )
   {: idx:n old:ptr ou:n new:ptr nu:n :}
   new nu ARCHIVE-PATH? {: archived:bool :}
   idx TOP-MEMBERS begin dup -1 <> while
      dup old ou new nu archived REBASE-RECORD
      TOP-NEXT @
   repeat drop ;
: TOP-ARCHIVE ( n -- )
   {: idx:n :}
   idx TOP-VALIDATE
   idx true STATUS-RENAME if idx PATH-ONE$ PATH-TWO$ TOP-REBASE-SUBTREE then ;
: IMPORT-ARCHIVE-CLOSED ( -- )
   ISSUE-N @ 0 ?do
      i F-ERROR REC-CELL @ 0= i F-ARCHIVED REC-CELL @ 0= and
      i F-CHILD REC-CELL @ 0= and if
         i F-STATUS REC-CELL @ 2 = if
            i TOP-CHILDREN-OPEN? 0= if i TOP-ARCHIVE then
         then
      then
   loop ;
: WARN-IMPORT-NUM ( n ptr u8 n -- )
   {: count:n suffix:ptr su:n :}
   count 0= if exit then
   SB-RESET s" Warning: skipped " SB-APPEND count FMT:SB-INT
   suffix su SB-APPEND 10 SB-APPEND-C
   SB$ 2 -rot STDERR-WRITE drop ;
: IMPORT-HAS-PARENT? ( -- bool ) IMPORT-IDX @ F-PARENT-PRESENT REC-CELL @ 0<> ;
\ The task or placed row the row at IMPORT-IDX names as its parent, or -1.
: IMPORT-PARENT ( -- n )
   IMPORT-IDX @ F-PARENT FIELD$ FIND-EXACT
   dup IMPORT-IDX @ = if drop -1 then ;
\ A row goes only under a valid parent, as add -P's does; under a closed or
\ archived parent only a closed row goes, wherever the parent lives, the
\ archive included.
: IMPORT-PARENT-OK? ( n -- bool )
   {: parent:n :}
   parent F-ERROR REC-CELL @ 0<> if false exit then
   parent F-STATUS REC-CELL @ 2 = parent F-ARCHIVED REC-CELL @ 0<> or 0=
   IMPORT-IDX @ F-STATUS REC-CELL @ 2 = or ;
\ The ids of the rows skipped from this file, back to back in SKIPPED-BYTES,
\ each ending at its SKIPPED-ENDS offset: one per skipped row, so
\ IMPORT-SKIPPED-N of them.
DYNAMIC-BUFFER SKIPPED-BYTES u8
DYNAMIC-BUFFER SKIPPED-ENDS n
\ The offset in SKIPPED-BYTES where the entry starts.
: SKIPPED-START ( n -- n ) dup 0 > if 1- SKIPPED-ENDS @ else drop 0 then ;
\ The id of the entry.
: SKIPPED$ ( n -- ptr u8 n )
   {: k:n :}
   k SKIPPED-START {: start:n :}
   start SKIPPED-BYTES k SKIPPED-ENDS @ start - ;
\ The skipped id index: chained hash buckets of entry numbers, as the record
\ id index holds record numbers, over the entries 0..IMPORT-SKIPPED-N-1.
\ Lookup re-reads each candidate's id through SKIPPED$. SKIP-HEADS holds the
\ first entry of each bucket and SKIP-NEXT the entry after each, -1 for none.
DYNAMIC-BUFFER SKIP-HEADS n
DYNAMIC-BUFFER SKIP-NEXT n
variable SKIP-BUCKETS
: SKIP-CHAIN ( n -- )
   {: k:n :}
   k SKIPPED$ STR-HASH SKIP-BUCKETS @ BUCKET {: b:n :}
   b SKIP-HEADS @ k SKIP-NEXT !
   k b SKIP-HEADS ! ;
\ Chain the first count entries over at least 64 buckets, doubled until no
\ fewer than the entries.
: SKIP-REBUILD ( n -- )
   {: entries:n :}
   SKIP-BUCKETS @ 64 max begin dup entries < while 2 * repeat {: count:n :}
   count SKIP-BUCKETS !
   count SKIP-HEADS-RESERVE
   count 0 ?do -1 i SKIP-HEADS ! loop
   entries SKIP-NEXT-RESERVE
   entries 0 ?do i SKIP-CHAIN loop ;
\ Index the entry written after the first ones.
: SKIP-LINK ( n -- )
   {: k:n :}
   k 1+ SKIP-BUCKETS @ > if k 1+ SKIP-REBUILD exit then
   k 1+ SKIP-NEXT-RESERVE k SKIP-CHAIN ;
\ Drop the row at IMPORT-IDX, the last record, and count it skipped, with the
\ edges held for it.
: IMPORT-SKIP ( -- )
   IMPORT-IDX @ F-ID FIELD$ {: id:ptr iu:n :}
   IMPORT-SKIPPED-N @ {: k:n :}
   k SKIPPED-START {: start:n :}
   start iu + 1+ SKIPPED-BYTES-RESERVE
   id start SKIPPED-BYTES iu BYTE-COPY
   k 1+ SKIPPED-ENDS-RESERVE
   start iu + k SKIPPED-ENDS !
   k SKIP-LINK
   1 IMPORT-SKIPPED-N +!
   DROP-HELD
   POP-RECORD ;
\ Whether a row skipped from this file had the id.
: SKIPPED? ( ptr u8 n -- bool )
   {: id:ptr iu:n :}
   SKIP-BUCKETS @ 0= if false exit then
   id iu STR-HASH SKIP-BUCKETS @ BUCKET SKIP-HEADS @
   begin dup -1 <> while
      dup SKIPPED$ id iu STR= if drop true exit then
      SKIP-NEXT @
   repeat drop false ;
\ Move the row's requested blockers out of its blocks field: each becomes an
\ edge only when IMPORT-ADD-DEPENDENCIES accepts it.
: IMPORT-TAKE-DEPS ( -- )
   IMPORT-IDX @ F-BLOCKS FIELD$ {: deps:ptr du:n :}
   du IMPORT-DEP-U !
   du 0= if exit then
   du IMPORT-DEP-BUF-RESERVE
   deps 0 IMPORT-DEP-BUF du BYTE-COPY
   IMPORT-IDX @ F-BLOCKS FIELD-EMPTY ;
\ Write the row at IMPORT-IDX where add -P would: in its parent's own folder,
\ made first, wherever the parent lives, the archive included, the row taking
\ the parent's partition. The folder and the row's file in it are checked as
\ add -P checks them, before the first write, and a refusal ends the import. A
\ row whose parent is no task or placed row goes in the folder named after that
\ parent at the top of .dots, made when absent; it is skipped when that
\ parent's row was, or when that path holds anything but a directory, a link
\ included. A parentless row goes at the top of .dots, in a folder named after
\ it if one exists; it is skipped when a link names that folder, as add refuses
\ it. A row is skipped only before its first write: a failure after that ends
\ the import at once.
: IMPORT-PLACE ( -- )
   IMPORT-IDX @ {: idx:n :}
   IMPORT-HAS-PARENT? if
      IMPORT-PARENT {: parent:n :}
      parent -1 = if
         idx F-PARENT FIELD$ SKIPPED? if IMPORT-SKIP exit then
         SB-RESET s" .dots/" SB-APPEND idx F-PARENT FIELD$ SB-APPEND SB$ PATH-ONE!
         PATH-ONE$ FS-TRY-LSTAT-MODE MATCH option
            none OF PATH-ONE$ MAKE-DIRS false ENDOF
            some OF S-IFMT and S-IFDIR <> ENDOF
         ;MATCH if IMPORT-SKIP exit then
         SB-RESET PATH-ONE$ SB-APPEND
      else
         parent IMPORT-PARENT-OK? 0= if IMPORT-SKIP exit then
         parent F-ARCHIVED REC-CELL @ 0<> if ASSERT-ARCHIVE-REAL then
         parent CHECK-OWN-FOLDER
         SB$ nip idx CHECK-FILE-FITS
         parent ENSURE-OWN-FOLDER
         parent F-ARCHIVED REC-CELL @ idx F-ARCHIVED REC-CELL !
         SB-RESET parent F-PATH FIELD$ drop parent OWN-FOLDER-U SB-APPEND
      then
      47 SB-APPEND-C
      1 idx F-CHILD REC-CELL !
   else
      SB-RESET s" .dots/" SB-APPEND idx F-ID FIELD$ SB-APPEND
      SB$ DIR? if
         SB$ SYMLINK? if IMPORT-SKIP exit then
         47 SB-APPEND-C
      else SB-RESET s" .dots/" SB-APPEND then
   then
   idx F-ID FIELD$ SB-APPEND s" .md" SB-APPEND SB$ idx F-PATH FIELD!
   IMPORT-TAKE-DEPS
   idx SAVE-RECORD
   idx IMPORT-ADD-HELD
   IMPORT-ADD-DEPENDENCIES
   1 IMPORTED-N +! idx TOP-LINK ;
\ Place the rows waiting on each record from the index on, in row order: every
\ record a placement appends queues behind it.
: PLACE-WAITING ( n -- )
   begin dup ISSUE-N @ < while
      begin dup F-ID FIELD$ PENDING-CHILD dup -1 <> while
         UNPEND IMPORT-PLACE
      repeat drop
      1+
   repeat drop ;
\ When the stream ends the waiting rows' parents never came. The first row
\ whose parent is not itself waiting goes first and the rows waiting on it
\ follow; rows waiting only on each other, a parent cycle, start from the first.
\ The root heap's least current entry is that first row; with none, every
\ waiting row's parent is waiting and the first live slot is the first row.
: PENDING-ROOT ( -- n )
   begin ROOTS-N @ 0 > while
      ROOT-POP {: slot:n node:n :}
      slot node ROOT-CURRENT? if slot exit then
   repeat
   begin PENDING-FIRST @ W-NODE WAIT-CELL @ -1 = while 1 PENDING-FIRST +! repeat
   PENDING-FIRST @ ;
: PLACE-PENDING ( -- )
   begin PENDING-N @ 0 > while
      PENDING-ROOT UNPEND IMPORT-PLACE
      IMPORT-IDX @ PLACE-WAITING
   repeat ;
\ Whether a row with the id at IMPORT-IDX was already read: a task, a placed
\ row or a waiting one.
: IMPORT-DUPLICATE? ( -- bool )
   IMPORT-IDX @ F-ID FIELD$ PENDING-FIND -1 <> if true exit then
   IMPORT-IDX @ F-ID FIELD$ FIND-EXACT IMPORT-IDX @ <> ;
\ Admit the row the line parsed into the last record, at IMPORT-IDX: place it
\ and the rows waiting on it, or set it aside until its parent's row comes.
: IMPORT-ROW ( -- )
   -1 IMPORT-SLOT !
   IMPORT-IDX @ F-ID FIELD$ CREATABLE-ID? 0= if IMPORT-SKIP exit then
   IMPORT-HAS-PARENT? if
      IMPORT-IDX @ F-PARENT FIELD$ CREATABLE-ID? 0= if IMPORT-SKIP exit then
   then
   IMPORT-DUPLICATE? if POP-RECORD exit then
   IMPORT-HAS-PARENT? if IMPORT-PARENT -1 = if PEND exit then then
   IMPORT-PLACE
   IMPORT-IDX @ PLACE-WAITING ;
\ A malformed line ends the import after the rows waiting on a parent are placed.
\ A line that leaves no row placed or waiting, its row skipped or dropped as a
\ duplicate, gives back the arena bytes it took.
: IMPORT-PROCESS-LINE ( -- )
   ISSUE-N @ {: before:n :}
   PENDING-N @ {: waiting:n :}
   ARENA-U @ {: floor:n :}
   [: JSONL-PARSE-LINE ;] catch 0<> if
      begin ISSUE-N @ before > while POP-RECORD repeat
      PLACE-PENDING s" Invalid JSONL file" FAIL
   then
   IMPORT-ROW
   ISSUE-N @ before = PENDING-N @ waiting = and if floor ARENA-U ! then ;
\ The reader's failure code, nonzero, ends the import after the rows waiting on
\ a parent are placed: a line too long is the limit error.
: IMPORT-READ-FAIL ( n -- )
   PLACE-PENDING
   dup JSONL:E-LIMIT = s" JSONL line too long" ?FAIL
   throw ;
\ A line holds at most 1048575 bytes before its LF: the 1 MiB line limit is
\ exclusive. Only the reader's failures place the waiting rows; a failure
\ placing a row ends the import at once.
: IMPORT-LINES ( ptr u8 n -- )
   [: 2dup JSONL-CURSOR -rot 1048575 BUF:N>BLEN JSONL:OPEN ;] catch
   dup 0<> if IMPORT-READ-FAIL then drop 2drop
   begin
      false [: drop JSONL-CURSOR JSONL:NEXT ;] catch
      dup 0<> if IMPORT-READ-FAIL then drop
   while IMPORT-PROCESS-LINE repeat ;
\ Imports the JSONL at a path: a failed open or read is an I/O error, not EOF.
: IMPORT-JSONL ( ptr u8 n -- )
   {: path:ptr pu:n :}
   true LOAD-ISSUES BLOCKED-BUILD TOP-REBUILD
   0 IMPORTED-N ! 0 IMPORT-SKIPPED-N ! 0 DEP-SKIPPED-N ! 0 HELD-N !
   0 PENDING-SLOTS ! 0 PENDING-N ! 0 PENDING-FIRST ! 0 NODE-N ! 0 NODE-BUCKETS !
   0 ROOTS-N ! 0 SKIP-BUCKETS !
   path pu IMPORT-LINES
   PLACE-PENDING
   IMPORT-ARCHIVE-CLOSED
   IMPORTED-N @ 0 > if
      s" Imported " DOT-IO:PRINT IMPORTED-N @ DOT-IO:INT
      s"  issues from " DOT-IO:PRINT path pu DOT-IO:PRINTLN
   then
   IMPORT-SKIPPED-N @ s"  issues due to errors" WARN-IMPORT-NUM
   DEP-SKIPPED-N @ s"  dependencies due to errors" WARN-IMPORT-NUM ;
\ An import path must name a regular file: an absent one is not found, and any
\ other failure to reach it is an I/O error.
: CHECK-JSONL-PATH ( ptr u8 n -- )
   {: path:ptr pu:n :}
   path pu FILE? if exit then
   path pu FS-PATHZ 0 ACCESS-CALL 0= s" Not a file: " path pu ?ISSUE-ERROR
   FFI:ERRNO FS-NO-ENTRY = s" File not found: " path pu ?ISSUE-ERROR
   s" I/O error" FAIL ;
\ Run the word on the path each `--from-jsonl` names.
: EACH-JSONL ( [ ptr u8 n -- ] -- )
   {: q :}
   1 ARG-I !
   begin ARG-I @ script-argc < while
      ARG-I @ script-argv$ s" --from-jsonl" STR= NEXT-ARG? and if
         TAKE-ARG q execute
      then
      1 ARG-I +!
   repeat ;
\ init checks every import path before it creates anything.
: INIT-FULL-COMMAND ( -- )
   [: CHECK-JSONL-PATH ;] EACH-JSONL
   INIT-EMPTY
   [: IMPORT-JSONL ;] EACH-JSONL
   GIT-ADD-DOTS ;
\ Dispatch codes: a command's group position in COMMAND-TABLE. The read-only
\ commands, which run without the writer lock, come first.
0 constant CMD-TREE
1 constant CMD-LS
2 constant CMD-READY
3 constant CMD-SHOW
4 constant CMD-FIND
5 constant CMD-HELP
6 constant CMD-VERSION
7 constant CMD-ADD
8 constant CMD-ON
9 constant CMD-OFF
10 constant CMD-UPDATE
11 constant CMD-INIT
12 constant CMD-PURGE
13 constant CMD-RM
14 constant CMD-FIX
15 constant CMD-SLUGIFY
32 constant GROUP-SEP
124 constant ALIAS-SEP
\ Command names grouped by dispatch code: GROUP-SEP ends a group and
\ ALIAS-SEP separates the aliases within one.
: COMMAND-TABLE ( -- ptr u8 n )
   s" tree ls|list ready show find help|-h|--help --version|-v add|create on|it off|done|close update init purge rm|delete fix slugify" ;
\ Whether arg is one of the aliases in group.
: ALIAS? ( ptr u8 n ptr u8 n -- bool )
   {: arg:ptr au:n grp:ptr gu:n :}
   grp gu ALIAS-SEP 0 begin SPLIT-NEXT while {: name:ptr nu:n next:n :}
      arg au name nu ARG= if true exit then
      grp gu ALIAS-SEP next
   repeat drop 2drop false ;
\ Dispatch code of the command arg names; an unknown name gets the group
\ count, which no dispatch arm matches.
: COMMAND-CODE ( ptr u8 n -- n )
   {: arg:ptr au:n :}
   0 COMMAND-TABLE GROUP-SEP 0 begin SPLIT-NEXT while {: grp:ptr gu:n next:n :}
      arg au grp gu ALIAS? if exit then
      1+ COMMAND-TABLE GROUP-SEP next
   repeat drop 2drop ;
\ Run a command once MAIN holds any lock it needs; an unknown name quick-adds.
: RUN-COMMAND ( n -- )
   case
      CMD-TREE of TREE-COMMAND endof
      CMD-LS of 1 PARSE-LIST-ARGS false LOAD-ISSUES PRINT-LIST endof
      CMD-READY of PARSE-READY-ARGS false LOAD-ISSUES PRINT-LIST endof
      CMD-SHOW of
         script-argc 2 < s" Usage: dot show <id>" ?FAIL
         1 SCAN-KEYED ! 1 script-argv$ SCAN-KEY+
         true LOAD-ISSUES 1 script-argv$ RESOLVE LOAD-TARGET SHOW
      endof
      CMD-FIND of
         script-argc 2 < if FIND-USAGE exit then
         FIND-HELP? if FIND-USAGE exit then
         1 script-argv$ QUERY-U ! QUERY-A !
         true LOAD-ISSUES PRINT-FIND
      endof
      CMD-ADD of ADD-COMMAND endof
      CMD-ON of 1 STATUS-MULTI endof
      CMD-OFF of 2 STATUS-MULTI endof
      CMD-UPDATE of UPDATE-COMMAND endof
      CMD-INIT of INIT-FULL-COMMAND endof
      CMD-PURGE of PURGE-COMMAND endof
      CMD-RM of RM-COMMAND endof
      CMD-FIX of FIX-COMMAND endof
      CMD-SLUGIFY of SLUGIFY-COMMAND endof
      QUICK-ADD
   endcase ;
public
\ Whether the command with this dispatch code runs without the writer lock.
: READ-ONLY-COMMAND? ( n -- bool ) CMD-HELP < ;
private
: DISPATCH ( -- )
   script-argc 0= if
      1 USE-JSON ! -1 FILTER ! 1 WANT-READY ! false LOAD-ISSUES PRINT-LIST exit
   then
   0 script-argv$ COMMAND-CODE
   case
      CMD-HELP of USAGE endof
      CMD-VERSION of VERSION endof
      dup READ-ONLY-COMMAND? 0= if DOT-LOCK:ACQUIRE then
      dup RUN-COMMAND
   endcase ;
public
: MAIN ( -- ) [: DISPATCH ;] REPORTING ;

;package

: MAIN ( -- ) DOT-READ:MAIN ;

\ read-probe.f - JSONL import's read path on a file whose read fails:
\    hb --load tests/read-probe.f -- <absolute path of main.f>
\ It runs IMPORT-JSONL on import.jsonl in the working directory, reporting a
\ failure as dot's MAIN does. No dot command
\ reaches that path with a file whose open succeeds and whose read fails, a
\ directory, since init refuses a path that is not a regular file; a case runs
\ the probe to show such a read fails as `I/O error`, never as the end of input.
0 SCRIPT-ARGV$ required
package DOT-READ
: PROBE ( -- ) s" import.jsonl" IMPORT-JSONL ;
' PROBE REPORTING
;package

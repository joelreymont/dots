\ run.f - the one entry of the Dots integration harness:
\    hb --load tests/run.f -- bin/dot
\ Each case file runs its cases as it loads, one PASS or FAIL line per case;
\ the run exits 0 when every case passed and 2 otherwise.
require dot.f

DOT-T:START
require case-cli.f
DOT-T:FINISH

\ case-cli.f - invocation and diagnostics: help, version, command aliases, the
\ no-argument ready listing, quick add, every usage diagnostic, option parsing
\ and the writer lock. Each case is one `dot` command on its own store.
require dot.f
using DOT-T
package DOT-CLI

: USAGE-TEXT ( -- ptr u8 n )
   s\" dots - Connect the dots

Usage: dot [command] [options]

Commands:
  dot \"title\"                  Quick add a dot
  dot add \"title\" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)
  dot ls [--status S] [--json] List dots
  dot on <id>                  Start working (turn it on!)
  dot off <id> [-r reason]     Complete (\"cross it off\")
  dot rm <id>                  Remove a dot
  dot show <id>                Show dot details
  dot ready [--json]           Show unblocked dots
  dot tree [id]                Show hierarchy (with id: includes closed children)
  dot fix                      Repair orphan and legacy folders
  dot find \"query\"             Search all dots (open first, then archived)
  dot purge                    Delete archived dots
  dot init                     Initialize .dots directory

Examples:
  dot \"Fix the bug\"
  dot add \"Design API\" -p 1 -d \"REST endpoints\"
  dot add \"Implement\" -P dots-1 -a dots-2
  dot on dots-3
  dot off dots-3 -r \"shipped\"
" ;

: FIND-USAGE-TEXT ( -- ptr u8 n )
   s\" Usage: dot find <query>

Search all dots (open first, then archived).

Searches: title, description, close-reason, created-at, closed-at

Examples:
  dot find \"auth\"      Search for dots mentioning auth
  dot find \"2026-01\"   Find dots from January 2026
" ;

: TREE-USAGE-TEXT ( -- ptr u8 n )
   s" Usage: dot tree [id]

Show dot hierarchy.

Without arguments: shows all open root dots and their children.
With id: shows that specific dot's tree (including closed children).

Examples:
  dot tree                    Show all open root dots
  dot tree my-project         Show specific dot and its children
" ;

s" cli" SECTION

: HELP ( -- )
   s" help" RUN
   0 RC=
   USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" help" ' HELP DOT-CASE

: HELP-SHORT ( -- )
   s" -h" RUN
   0 RC=
   USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" help-short" ' HELP-SHORT DOT-CASE

: HELP-LONG-EXTRA ( -- )
   s" --help|ignored" RUN
   0 RC=
   USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" help-long-extra" ' HELP-LONG-EXTRA DOT-CASE

: VERSION ( -- )
   s" --version|ignored" RUN
   0 RC=
   s\" dots 0.6.4\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" version" ' VERSION DOT-CASE

: VERSION-SHORT ( -- )
   s" -v|ignored" RUN
   0 RC=
   s\" dots 0.6.4\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" version-short" ' VERSION-SHORT DOT-CASE

: HOOK-QUICK-ADD ( -- )
   s" hook" RUN
   s" A" SAVE-ID
   s" A" s" hook-quick-add-hook-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=hook-quick-add
.
f .dots/<A>.md
  ---
  title: hook
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" hook-quick-add" ' HOOK-QUICK-ADD DOT-CASE

\ Each alias runs its command: create is add, it on, done off and delete rm.
: ALIAS-CREATE ( -- )
   s" create|T|--json" RUN
   s" A" SAVE-ID
   s" A" s" alias-create-t-<hex>" ID=
   0 RC=
   s\" {\"id\":\"<A>\",\"title\":\"T\",\"description\":null,\"status\":\"open\",\"priority\":2,\"issue_type\":\"task\",\"created_at\":\"<time>\",\"closed_at\":null,\"close_reason\":null}\n" OUT=
   s" " ERR=
   s\" d .dots
f .dots/<A>.md
  ---
  title: T
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
d .dots/archive
f .dots/config
  prefix=alias-create
.
" TREE=
;
s" alias-create" ' ALIAS-CREATE DOT-CASE

: ALIAS-IT ( -- )
   s" t.md" s" T" s" open" 2 PUT-ISSUE
   s" it|t" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/t.md
  ---
  title: T
  status: active
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  ---
.
" TREE=
;
s" alias-it" ' ALIAS-IT DOT-CASE

: ALIAS-DONE ( -- )
   s" t.md" s" T" s" open" 2 PUT-ISSUE
   s" done|t|-r|shipped" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/t.md
  ---
  title: T
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  close-reason: shipped
  ---
.
" TREE=
;
s" alias-done" ' ALIAS-DONE DOT-CASE

: ALIAS-DELETE ( -- )
   s" t.md" s" T" s" open" 2 PUT-ISSUE
   s" delete|t" RUN
   0 RC=
   s" " OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" alias-delete" ' ALIAS-DELETE DOT-CASE

: NO-ARGS-READY-JSON ( -- )
   s" open.md" s" ---
title: Open
status: open
priority: 1
created-at: 2026-01-01T00:00:00Z
---
" PUT
   s" blocked.md" s" ---
title: Blocked
status: open
priority: 0
created-at: 2026-01-01T00:00:00Z
blocks:
  - open
---
" PUT
   s" " RUN
   0 RC=
   s\" [{\"id\":\"open\",\"title\":\"Open\",\"description\":null,\"status\":\"open\",\"priority\":1,\"issue_type\":\"task\",\"created_at\":\"2026-01-01T00:00:00Z\",\"closed_at\":null,\"close_reason\":null}]\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
f .dots/blocked.md
  ---
  title: Blocked
  status: open
  priority: 0
  created-at: 2026-01-01T00:00:00Z
  blocks:
    - open
  ---
.
f .dots/open.md
  ---
  title: Open
  status: open
  priority: 1
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" no-args-ready-json" ' NO-ARGS-READY-JSON DOT-CASE

: QUICK-ADD ( -- )
   s" Fix the bug" RUN
   s" A" SAVE-ID
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=quick-add
.
f .dots/<A>.md
  ---
  title: Fix the bug
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" quick-add" ' QUICK-ADD DOT-CASE

\ Quick add takes its argument verbatim as the title, an option's look and all.
: QUICK-ADD-VERBATIM ( -- )
   s" -v x" RUN
   s" A" SAVE-ID
   s" A" s" quick-add-verbatim-v-x-<hex>" ID=
   0 RC=
   s\" <A>\n" OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/config
  prefix=quick-add-verbatim
.
f .dots/<A>.md
  ---
  title: -v x
  status: open
  priority: 2
  issue-type: task
  created-at: \"<time>\"
  ---
.
" TREE=
;
s" quick-add-verbatim" ' QUICK-ADD-VERBATIM DOT-CASE

: ADD-USAGE ( -- )
   s" add" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot add <title> [options]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" add-usage" ' ADD-USAGE DOT-CASE

: ADD-WITHOUT-TITLE ( -- )
   s" add|-p|1" RUN
   1 RC=
   s" " OUT=
   s\" Error: title required\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" add-without-title" ' ADD-WITHOUT-TITLE DOT-CASE

: ON-USAGE ( -- )
   s" on" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot on <id> [id2 ...]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" on-usage" ' ON-USAGE DOT-CASE

: OFF-USAGE ( -- )
   s" off" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot off <id> [id2 ...] [-r reason]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" off-usage" ' OFF-USAGE DOT-CASE

: UPDATE-USAGE ( -- )
   s" update" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot update <id> [--status S]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" update-usage" ' UPDATE-USAGE DOT-CASE

: UPDATE-WITHOUT-STATUS ( -- )
   s" update|absent" RUN
   1 RC=
   s" " OUT=
   s\" --status required\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" update-without-status" ' UPDATE-WITHOUT-STATUS DOT-CASE

\ close is another name for off.
: CLOSE-USAGE ( -- )
   s" close" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot off <id> [id2 ...] [-r reason]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" close-usage" ' CLOSE-USAGE DOT-CASE

: SHOW-USAGE ( -- )
   s" show" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot show <id>\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" show-usage" ' SHOW-USAGE DOT-CASE

: RM-USAGE ( -- )
   s" rm" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot rm <id> [id2 ...]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" rm-usage" ' RM-USAGE DOT-CASE

: TREE-TOO-MANY ( -- )
   s" tree|too|many" RUN
   1 RC=
   s" " OUT=
   s\" Usage: dot tree [id]\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" tree-too-many" ' TREE-TOO-MANY DOT-CASE

: FIND-USAGE ( -- )
   s" find" RUN
   0 RC=
   FIND-USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" find-usage" ' FIND-USAGE DOT-CASE

: FIND-HELP ( -- )
   s" find|query|--help" RUN
   0 RC=
   FIND-USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" find-help" ' FIND-HELP DOT-CASE

: FIND-HELP-SHORT ( -- )
   s" find|-h" RUN
   0 RC=
   FIND-USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" find-help-short" ' FIND-HELP-SHORT DOT-CASE

: TREE-HELP ( -- )
   s" tree|--help" RUN
   0 RC=
   TREE-USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" tree-help" ' TREE-HELP DOT-CASE

: TREE-HELP-SHORT ( -- )
   s" tree|-h" RUN
   0 RC=
   TREE-USAGE-TEXT OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" tree-help-short" ' TREE-HELP-SHORT DOT-CASE

: LS-STATUS-WITHOUT-VALUE ( -- )
   s" a.md" s" Seeded task" s" open" 2 PUT-ISSUE
   s" ls|--status" RUN
   0 RC=
   s\" [a] o Seeded task\n" OUT=
   s" " ERR=
   s" d .dots
f .dots/a.md
  ---
  title: Seeded task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" ls-status-without-value" ' LS-STATUS-WITHOUT-VALUE DOT-CASE

: LS-INVALID-STATUS ( -- )
   s" a.md" s" Seeded task" s" open" 2 PUT-ISSUE
   s" ls|--status|mystery" RUN
   1 RC=
   s" " OUT=
   s\" Invalid status: mystery\n" ERR=
   s" d .dots
f .dots/a.md
  ---
  title: Seeded task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" ls-invalid-status" ' LS-INVALID-STATUS DOT-CASE

: LIST-UNKNOWN-OPTION ( -- )
   s" list|--json|--unknown" RUN
   0 RC=
   s\" []\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" list-unknown-option" ' LIST-UNKNOWN-OPTION DOT-CASE

: READY-UNKNOWN-OPTION ( -- )
   s" ready|--json|--unknown" RUN
   0 RC=
   s\" []\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" ready-unknown-option" ' READY-UNKNOWN-OPTION DOT-CASE

: FIX-EXTRA-ARGUMENT ( -- )
   s" fix|ignored" RUN
   0 RC=
   s\" No fixes needed\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" fix-extra-argument" ' FIX-EXTRA-ARGUMENT DOT-CASE

: PURGE-EXTRA-ARGUMENT ( -- )
   s" purge|ignored" RUN
   0 RC=
   s\" Archive purged\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" purge-extra-argument" ' PURGE-EXTRA-ARGUMENT DOT-CASE

: SLUGIFY-EXTRA-ARGUMENT ( -- )
   s" slugify|ignored" RUN
   0 RC=
   s\" Slugified 0 issue(s)\n" OUT=
   s" " ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" slugify-extra-argument" ' SLUGIFY-EXTRA-ARGUMENT DOT-CASE

\ init refuses an absent import file before it creates anything.
: INIT-ABSENT-JSONL ( -- )
   s" ../.dots" RM-DIR
   s" init|--from-jsonl|absent.jsonl" RUN
   1 RC=
   s" " OUT=
   s\" File not found: absent.jsonl\n" ERR=
   s" " TREE=
;
s" init-absent-jsonl" ' INIT-ABSENT-JSONL DOT-CASE

\ init reports an import path it cannot inspect, under a directory it may not
\ search, as an I/O error before it creates anything. `.dots/../p` needs
\ `.dots`, so p's mode is set through MODE first and restored through its path.
: INIT-JSONL-UNREADABLE-DIR ( -- )
   s" p" FILE$ MAKE-DIRS
   s" ../p" 0 MODE
   s" ../.dots" RM-DIR
   s" init|--from-jsonl|p/x.jsonl" RUN
   s" p" FILE$ FS-MUT-MODE-DIR CHMOD-MODE
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" " TREE=
;
s" init-jsonl-unreadable-dir" ' INIT-JSONL-UNREADABLE-DIR DOT-CASE

: UPDATE-INVALID-STATUS-FIRST ( -- )
   s" update|absent|--status|mystery" RUN
   1 RC=
   s" " OUT=
   s\" Invalid status: mystery\n" ERR=
   s" d .dots
d .dots/archive
" TREE=
;
s" update-invalid-status-first" ' UPDATE-INVALID-STATUS-FIRST DOT-CASE

: SHOW-AMBIGUOUS-PREFIX ( -- )
   s" alpha.md" s" Alpha" s" open" 2 PUT-ISSUE
   s" alphabet.md" s" Alphabet" s" open" 2 PUT-ISSUE
   s" show|alph" RUN
   1 RC=
   s" " OUT=
   s\" Ambiguous ID: alph\n" ERR=
   s" d .dots
f .dots/alpha.md
  ---
  title: Alpha
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
f .dots/alphabet.md
  ---
  title: Alphabet
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" show-ambiguous-prefix" ' SHOW-AMBIGUOUS-PREFIX DOT-CASE

\ A filesystem failure with no message of its own is an I/O error: ls cannot
\ list the folder p. The harness restores p's mode to read the tree.
: UNREADABLE-FOLDER ( -- )
   s" p/p.md" s" P" s" open" 2 PUT-ISSUE
   s" p" 0 MODE
   s" ls" RUN
   s" p" FS-MUT-MODE-DIR MODE
   1 RC=
   s" " OUT=
   s\" I/O error\n" ERR=
   s" d .dots
d .dots/archive
d .dots/p
f .dots/p/p.md
  ---
  title: P
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
" TREE=
;
s" unreadable-folder" ' UNREADABLE-FOLDER DOT-CASE

: WRITER-WAITS-FOR-LOCK ( -- )
   s" a.md" s" Before" s" open" 2 PUT-ISSUE
   HOLD
   s" update|a|--status|done" SPAWN
   200 WAITING
   s" a.md" s" Written while waiting" s" open" 2 PUT-ISSUE
   RELEASE
   WAIT
   0 RC=
   s" " OUT=
   s" " ERR=
   s\" d .dots
d .dots/archive
f .dots/archive/a.md
  ---
  title: Written while waiting
  status: closed
  priority: 2
  issue-type: task
  created-at: \"2026-01-01T00:00:00Z\"
  closed-at: \"<time>\"
  ---
.
" TREE=
;
s" writer-waits-for-lock" ' WRITER-WAITS-FOR-LOCK DOT-CASE

: READER-SKIPS-LOCK ( -- )
   s" a.md" s" Seeded task" s" open" 2 PUT-ISSUE
   HOLD
   s" show|a" RUN
   RELEASE
   0 RC=
   s" ID:       a
Title:    Seeded task
Status:   open
Priority: 2
Created:  2026-01-01T00:00:00Z
" OUT=
   s" " ERR=
   s" d .dots
f .dots/a.md
  ---
  title: Seeded task
  status: open
  priority: 2
  created-at: 2026-01-01T00:00:00Z
  ---
.
d .dots/archive
" TREE=
;
s" reader-skips-lock" ' READER-SKIPS-LOCK DOT-CASE

;package
;using

---
title: dot off re-quotes created-at with nested quotes
status: closed
priority: 2
issue-type: task
created-at: "2026-09-16T14:27:50.011758+03:00"
closed-at: "2026-09-23T19:08:16.231389+03:00"
close-reason: fixed by e054b3ff; CLI test add-on-off keeps one layer
---

Problem: closing a dot rewrites its frontmatter with created-at double-quoted inside quotes, e.g. created-at: '"2026-08-07T12:16:55.087642+02:00"' (observed 2026-09-16 in ~/Work/habu/.dots after dot off; recorded there as habu-dot-cli-re-6fc34b33). Acceptance: dot off preserves the created-at value byte-for-byte; a test closes a dot and compares frontmatter. Files: the dots source. Verify: the new test. Depends: none. Ownership: dots. Claim: unassigned.

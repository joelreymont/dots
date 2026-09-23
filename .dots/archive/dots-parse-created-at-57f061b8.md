---
title: Parse created-at and closed-at through parseYamlValue
status: closed
priority: 2
issue-type: task
created-at: "2026-09-14T10:51:47.623450+03:00"
closed-at: "2026-09-23T19:08:16.230108+03:00"
close-reason: e054b3ff reads every scalar through parseYamlValue; c84e8cde proves write-parse-write identity
---

Problem: src/storage.zig parseFrontmatter reads title through parseYamlValue (line ~490) but stores created-at, closed-at, close-reason and assignee raw (lines ~496-499), while serializeFrontmatter writes them through writeYamlValue (lines ~583-584 and the closed-at/close-reason lines), which quotes any value containing ':' and escapes the quotes already inside it. Every rewrite (dot on, dot off, dot edit) therefore nests one more layer: this repo's own .dots/dots-add-dot-slugify-71cb9ef4.md carries created-at with four layers, Maki's archive carries three, and dot find searches created-at text. Acceptance: every frontmatter string field is read through parseYamlValue and written through writeYamlValue so a read-write round trip is the identity; a file already carrying nested layers reads back to the bare timestamp (unwrap repeatedly until the value no longer starts and ends with a quote) and the next write normalizes it; a regression test in test_storage.zig round-trips an issue through serialize/parse twice and asserts byte equality of the second write with the first, plus one test on a hand-written triple-nested created-at. Files: src/storage.zig, src/test_storage.zig. Verify: zig build test; dot on then dot show on a scratch dot shows one layer of quotes. Depends: none. Ownership: src/storage.zig. Claim: unassigned.

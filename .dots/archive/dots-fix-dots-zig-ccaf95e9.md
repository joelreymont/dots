---
title: Fix dots Zig 0.16 CI dependency build
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-06-22T21:42:27.231819+00:00\\\"\""
closed-at: "2026-06-22T21:58:11.146930+00:00"
---

CI now installs Zig 0.16, but the pretty dependency build script still calls the removed Compile.linkLibC helper on Linux CI. Patch dependency usage or override so zig build passes on GitHub Actions.

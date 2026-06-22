---
title: Port dots to Zig 0.16
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-06-22T21:31:23.548803+00:00\\\"\""
closed-at: "2026-06-22T21:32:13.725822+00:00"
close-reason: Ported to Zig 0.16 and verified with zig build -Doptimize=ReleaseSmall
---

Update dots build and source for Zig 0.16: Build root module libc flag, std.process.Init args, DebugAllocator, std.Io filesystem/stdio/random/time APIs, lowercase child Term tags. Verify with zig build -Doptimize=ReleaseSmall, commit and push.

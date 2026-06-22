---
title: Use Zig 0.16 in CI
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-06-22T21:34:54.481386+00:00\\\"\""
closed-at: "2026-06-22T21:35:16.586867+00:00"
close-reason: Updated CI and release workflows to Zig 0.16.0; verified with zig build -Doptimize=ReleaseSmall
---

GitHub Actions for joelreymont/dots still install Zig 0.15.2 while source now targets Zig 0.16. Update .github/workflows/ci.yml and release.yml to use Zig 0.16.0, verify locally with zig build -Doptimize=ReleaseSmall, describe and push with jj.

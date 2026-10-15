# Dots agent instructions

Dots is a native Habu CLI that stores tasks as Markdown in `.dots/`.

## Communication

Always refer to the user as Mr. Picklesworth.

## Build

Run `sh build.sh` from the repository root. The script builds with the
installed Habu that `hb` on `PATH` resolves to and writes `bin/dot`.
Always use the current Habu; never pin a Habu revision in scripts, tests or
docs.
The compiler cache, temporary files, and binary are ignored by version control.
Do not commit them. Measure a release binary with `wc -c < bin/dot`; the
validated macOS arm64 build is 214,908 bytes.

## Test

The integration harness is the one test suite:

```sh
hb --load tests/run.f -- bin/dot
```

Each case seeds a synthetic store in a temporary directory, runs `bin/dot` in
it and checks the exact exit status, stdout, stderr and resulting `.dots` tree.
The run prints PASS or FAIL per case and exits 0 only when every case passed.
The run compiles `tests/probe.c`, an interposer that pins add's random id
and fails a rename mid-slugify, with `cc` and fails without it. `tests/dot.f` documents the case
form.

## Source invariants

- `main.f` implements the CLI and filesystem behavior; `abbrev.f` supplies the
  abbreviation map, `io.f` checks CLI I/O, and `lock.f` serializes mutating
  commands before they load state. Keep them under the Habu build.
- `.dots/` is repository task history. Do not migrate, rewrite, or discard it
  as part of a language or build change.
- Keep generated binaries and compiler cache out of commits. Update the size
  claim in README only after measuring a rebuilt, stripped binary on the same
  target platform.
- The source and build are Habu; the Zig source stays on the `zig` branch.
- Do not restore the Zig CI or release workflow without a verified Habu
  bootstrap and release process for every supported runner and target.

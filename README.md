![Connect the dots](assets/banner.jpg)

# dots

Fast task tracking in plain Markdown files. Dots is a single native Habu CLI;
tasks live in `.dots/` and can be read, edited, and versioned with ordinary
file tools. It needs no database or server at runtime.

The current stripped macOS arm64 binary is **214,908 bytes** (about 210 KiB),
4.8% larger than the shipped Zig build (205,104 bytes, Zig 0.15.2
ReleaseSmall) and 14.1% larger than the same source built with the smallest
Zig flags (188,320 bytes). The previous Zig source, build, CI, and release
setup remain on the [`zig` branch](https://github.com/joelreymont/dots/tree/zig).

## Install from source

Install Habu so that `hb` on `PATH` resolves to an installed release, normally
`~/.local/bin/hb` through `~/.local/lib/habu/current`. `build.sh` builds from
that release's root, which must contain `bin/hb` and `tools/hb-build.f`. To
build with another Habu, put its `bin/hb` first on `PATH`.

```sh
git clone https://github.com/joelreymont/dots.git
cd dots
sh build.sh
install -m 755 bin/dot ~/.local/bin/dot
dot --version
```

`build.sh` writes the binary to `bin/dot` and uses private caches under
`.build/`. These outputs are ignored by version control. The CLI prints
`dots 0.6.4` for `--version`.

## Quick start

```sh
dot init
dot add "Design API" -p 1 -d "REST endpoints"
dot "Write tests"                  # Quick add
dot ls
dot ready
dot on <id>
dot off <id> -r "Shipped"
dot show <id>
```

`dot init` creates `.dots/` and stages it with git when run in a git
repository; without `git` on PATH it warns and continues. Running `dot` with
no arguments prints ready tasks as JSON.

## Commands

| Command | Action |
| --- | --- |
| `dot add "title" [-p N] [-d TEXT] [-P PARENT] [-a BLOCKER] [--json]` | Create a task; `create` is an alias. |
| `dot "title"` | Add a task without writing `add`. |
| `dot ls [--status open\|active\|done] [--json]` | List tasks; `list` is an alias. By default, closed tasks are omitted. |
| `dot ready [--json]` | List open, unblocked tasks. |
| `dot show ID` | Show a task, resolving a unique ID prefix. |
| `dot find QUERY` | Search task details, including the archive. |
| `dot on ID [ID ...]` | Mark tasks active; `it` is an alias. |
| `dot off ID [ID ...] [-r\|--reason REASON]` | Close tasks; `done` and `close` are aliases. |
| `dot update ID --status STATUS` | Change a task status. |
| `dot tree [ID]` | Show task hierarchy. |
| `dot rm ID [ID ...]` | Delete tasks; `delete` is an alias. |
| `dot fix` | Move tasks out of orphan folders and nest legacy folders. |
| `dot slugify` | Rename IDs to title slugs and update references. |
| `dot purge` | Delete the archive. |
| `dot init --from-jsonl FILE` | Import tasks from a JSONL export. |

The `-p` option accepts a signed decimal value and clamps it to 0–9; the
default is 2. A task's ID has a project prefix, a title slug, and an eight
digit hexadecimal suffix. Commands accept unique ID prefixes. A parent task
is stored with its children in a directory, and a closed root task moves to
`.dots/archive/`. Reopening restores archived tasks to active storage and
reopens closed ancestors as needed. Conflicting active and archived folders
are refused without merging. The CLI's `--help` output gives a compact command
summary.

## Storage

Each task is a Markdown file with YAML frontmatter. For example:

```markdown
---
title: Design API
status: open
priority: 1
issue-type: task
created-at: 2026-01-01T00:00:00Z
blocks:
  - dots-design-schema-1234abcd
---

Describe the work here.
```

The `.dots/config` file stores the project ID prefix. Parent task folders hold
their task file and child files. Closed root tasks live under `.dots/archive/`.

## Test

```sh
sh build.sh
hb --load tests/run.f -- bin/dot
```

The harness runs each case in a synthetic store in a temporary directory and
checks the exact exit status, stdout, stderr and resulting `.dots` tree; it
never touches the repository's `.dots/`. It exits 0 only when every case
passes. It compiles `tests/probe.c`, an interposer that pins add's random
id and fails a rename mid-slugify, with `cc`. Rebuild and rerun after a toolchain or source change.

## Migrating from beads

If you have existing tasks in `.beads/beads.db`, run `./migrate-dots.sh`.
The script requires `sqlite3` and `jq` and verifies the imported data before
prompting to delete the old store.

## Contributing

Please open an issue with the feature details, including the AI prompt if
applicable, before submitting a pull request.

## License

MIT. See [LICENSE](LICENSE).

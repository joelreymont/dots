![Connect the dots](assets/banner.jpg)

# dots

Fast task tracking in plain Markdown files. Dots is a single native Habu CLI;
tasks live in `.dots/` and can be read, edited, and versioned with ordinary
file tools. It needs no database or server at runtime.

The accepted stripped macOS arm64 binary is **165,372 bytes** (about 162 KiB).
In the same comparison, the ordinary Zig Small build was 335,280 bytes and a
separately minimized Zig build was 268,320 bytes. See [validation and scope](docs/parity.md)
for the exact measurements and differential tests. The previous Zig source,
build, CI, and release setup remain on the [`zig` branch](https://github.com/joelreymont/dots/tree/zig).

## Install from source

Install the pinned Habu release
`c53b4d2c` at `~/.local/lib/habu/c53b4d2c`, or set `HABU_ROOT` to its root.
The root must contain `bin/hb` and `tools/hb-build.f`.

```sh
git clone https://github.com/joelreymont/dots.git
cd dots
sh build.sh
install -m 755 bin/dot ~/.local/bin/dot
dot --version
```

`build.sh` writes the binary to `bin/dot` and uses private caches under
`.build/`. These outputs are ignored by version control. The CLI currently
prints `dots 0.6.4 (f107d016)` for `--version` to match the reference CLI.

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
repository. Running `dot` with no arguments prints ready tasks as JSON.

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
| `dot off ID [ID ...] [-r REASON]` | Close tasks; `done` is an alias. |
| `dot update ID --status STATUS` | Change a task status. |
| `dot close ID [--reason REASON]` | Close one task. |
| `dot tree [ID]` | Show task hierarchy. |
| `dot rm ID [ID ...]` | Delete tasks; `delete` is an alias. |
| `dot fix` | Promote children of missing parent tasks. |
| `dot slugify` | Rename IDs to title slugs and update references. |
| `dot purge` | Delete the archive. |
| `dot init --from-jsonl FILE` | Import tasks from a JSONL export. |

The `-p` option accepts a signed decimal value and clamps it to 0–9; the
default is 2. A task's ID has a project prefix, a title slug, and an eight
digit hexadecimal suffix. Commands accept unique ID prefixes. A parent task
is stored with its children in a directory, and a closed root task moves to
`.dots/archive/`. The CLI's `--help` output gives a compact command summary.

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
The complete storage and command compatibility contract is in
[the parity ledger](docs/parity.md).

## Test

The Python harnesses compare `bin/dot` with the adapted full Zig reference
under `benchmark/zig-full/`. Zig 0.17 is required for the reference build.
Its source has API compatibility changes and a narrow duplicate-config
ownership fix relative to the `zig` branch:

```sh
sh build.sh
sh benchmark/build-zig.sh
python3 test.py --full benchmark/bin/dot-zig-full-small bin/dot
python3 edge_test.py benchmark/bin/dot-zig-full-small bin/dot
```

They create synthetic stores in system temporary directories; they do not
modify the repository's `.dots/`. The accepted port passed 96 command sequence
steps and 60 focused edges against both ordinary and minimized Zig binaries.
The current repository revision should be rebuilt and checked after a toolchain
or source change.

## Migrating from beads

If you have existing tasks in `.beads/beads.db`, run `./migrate-dots.sh`.
The script requires `sqlite3` and `jq` and verifies the imported data before
prompting to delete the old store.

## Contributing

Please open an issue with the feature details, including the AI prompt if
applicable, before submitting a pull request.

## License

MIT. See [LICENSE](LICENSE).

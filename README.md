![Connect the dots](assets/banner.jpg)

# dots

> **Validation:** the adversarial repairs and expanded regression suites are
> documented in [validation and remaining limits](docs/parity.md).

Fast task tracking in plain Markdown files. Dots is a single native Habu CLI;
tasks live in `.dots/` and can be read, edited, and versioned with ordinary
file tools. It needs no database or server at runtime.

The current stripped macOS arm64 binary is **198,396 bytes** (about 194 KiB),
**26.1% smaller** than the smallest verified Zig build (268,320 bytes).
The ordinary Zig Small reference is 335,280 bytes. See
[validation and scope](docs/parity.md) for measurements and adversarial tests. The previous Zig source,
build, CI, and release setup remain on the [`zig` branch](https://github.com/joelreymont/dots/tree/zig).

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
python3 regression_fs_test.py bin/dot
python3 regression_graph_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_loading_test.py benchmark/bin/dot-zig-full-small bin/dot
python3 regression_json_test.py bin/dot
python3 regression_archive_test.py bin/dot
python3 regression_slugify_test.py bin/dot
python3 regression_io_test.py bin/dot
python3 regression_concurrency_test.py bin/dot
```

They create synthetic stores in system temporary directories; they do not
modify the repository's `.dots/`. The current port passes **289 checks across
10 permanent suites**, including concurrent writers, failed reads and writes,
archive rollback, symlink refusal, and slugify recovery. The broader adversarial
run uses copied task stores from 11 repositories; see the
[validation ledger](docs/parity.md) for results and the comparison contract.
The I/O suite uses the installed `hb`; the slugify failure probe uses
`cc`. Rebuild and rerun after a toolchain or source change.

## Migrating from beads

If you have existing tasks in `.beads/beads.db`, run `./migrate-dots.sh`.
The script requires `sqlite3` and `jq` and verifies the imported data before
prompting to delete the old store.

## Contributing

Please open an issue with the feature details, including the AI prompt if
applicable, before submitting a pull request.

## License

MIT. See [LICENSE](LICENSE).

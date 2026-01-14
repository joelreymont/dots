![Connect the dots](assets/banner.jpg)

# dots

> **Fast, minimal task tracking with plain markdown files — no database required**

Minimal task tracker for AI coding agents.

| | beads (SQLite) | dots (markdown) |
|---|---:|---:|
| Binary | 25 MB | **200 KB** (125x smaller) |
| Lines of code | 115,000 | **2,800** (41x less) |
| Dependencies | Go, SQLite/Wasm | None |
| Portability | Rebuild per platform | Copy `.dots/` anywhere |

## What is dots?

A CLI task tracker with **zero dependencies** — tasks are plain markdown files with YAML frontmatter in `.dots/`. No database, no server, no configuration. Copy the folder between machines, commit to git, edit with any tool. Parent-child relationships map to folders. Each task has an ID, title, status, priority, and optional dependencies.

## Installation

### Homebrew

```bash
brew install joelreymont/tap/dots
```

### From source (requires Zig 0.15+)

```bash
git clone https://github.com/joelreymont/dots.git
cd dots
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/dot ~/.local/bin/
```

### Verify installation

```bash
dot --version
# Output: dots 0.6.2
```

## Quick Start

```bash
# Initialize in current directory
dot init
# Creates: .dots/ directory (added to git if in repo)

# Add a task
dot add "Fix the login bug"
# Output: dots-a1b2c3d4e5f6a7b8

# List tasks
dot ls
# Output: [a1b2c3d] o Fix the login bug

# Start working
dot on a1b2c3d
# Output: (none, task marked active)

# Complete task
dot off a1b2c3d -r "Fixed in commit abc123"
# Output: (none, task marked done and archived)
```

## Command Reference

### Initialize

```bash
dot init
```
Creates `.dots/` directory. Runs `git add .dots` if in a git repository. Safe to run if already exists.

### Add Task

```bash
dot add "title" [-p PRIORITY] [-d "description"] [-P PARENT_ID] [-a AFTER_ID] [--json]
dot "title"  # shorthand for: dot add "title"
```

Options:
- `-p N`: Priority 0-4 (0 = highest, default 2)
- `-d "text"`: Long description (markdown body of the file)
- `-P ID`: Parent task ID (creates folder hierarchy)
- `-a ID`: Blocked by task ID (dependency)
- `--json`: Output created task as JSON

Examples:
```bash
dot add "Design API" -p 1
# Output: dots-1a2b3c4d5e6f7890

dot add "Implement API" -a dots-1a2b3c4d -d "REST endpoints for user management"
# Output: dots-3c4d5e6f7a8b9012

dot add "Write tests" --json
# Output: {"id":"dots-5e6f7a8b9012cdef","title":"Write tests","status":"open","priority":2,...}
```

### List Tasks

```bash
dot ls [--status STATUS] [--json]
```

Options:
- `--status`: Filter by `open`, `active`, or `done` (default: shows open + active)
- `--json`: Output as JSON array

Output format (text):
```
[1a2b3c4] o Design API        # o = open
[3c4d5e6] > Implement API     # > = active
[5e6f7a8] x Write tests       # x = done
```

### Start Working

```bash
dot on <id> [id2 ...]
```
Marks task(s) as `active`. Use when you begin working on tasks. Supports short ID prefixes.

### Complete Task

```bash
dot off <id> [id2 ...] [-r "reason"]
```
Marks task(s) as `done` and archives them. Optional reason applies to all. Root tasks are moved to `.dots/archive/`. Child tasks wait for parent to close before moving.

### Show Task Details

```bash
dot show <id>
```

Output:
```
ID:       dots-1a2b3c4d5e6f7890
Title:    Design API
Status:   open
Priority: 1
Desc:     REST endpoints for user management
Created:  2024-12-24T10:30:00Z
```

### Remove Task

```bash
dot rm <id> [id2 ...]
```
Permanently deletes task file(s). If removing a parent, children are also deleted.

### Show Ready Tasks

```bash
dot ready [--json]
```
Lists tasks that are `open` and have no blocking dependencies (or blocker is `done`).

### Show Hierarchy

```bash
dot tree
```

Output:
```
[1a2b3c4] o Build auth system
  +- [2b3c4d5] o Design schema
  +- [3c4d5e6] o Implement endpoints (blocked)
  +- [4d5e6f7] o Write tests (blocked)
```

### Search Tasks

```bash
dot find "query"
```
Case-insensitive search in title and description.

### Purge Archive

```bash
dot purge
```
Permanently deletes all archived (completed) tasks from `.dots/archive/`.

## Storage Format

Tasks are stored as markdown files with YAML frontmatter in `.dots/`:

```
.dots/
  a1b2c3d4e5f6a7b8.md              # Root dot (no children)
  f9e8d7c6b5a49382/                # Parent with children
    f9e8d7c6b5a49382.md            # Parent dot file
    1a2b3c4d5e6f7890.md            # Child dot
  archive/                          # Closed dots
    oldtask12345678.md             # Archived root dot
    oldparent1234567/              # Archived tree
      oldparent1234567.md
      oldchild23456789.md
  config                            # ID prefix setting
```

### File Format

```markdown
---
title: Fix the bug
status: open
priority: 2
issue-type: task
assignee: joel
created-at: 2024-12-24T10:30:00Z
blocks:
  - a3f2b1c8d9e04a7b
---

Description as markdown body here.
```

### ID Format

IDs have the format `{prefix}-{slug}-{hex}` where:
- `prefix`: Project prefix from `.dots/config` (default: `dots`)
- `slug`: URL-safe abbreviation of the title (max 32 chars)
- `hex`: 8-character random hex suffix

Example: `dots-fix-user-auth-a3f2b1c8`

The slug uses common abbreviations (authentication→auth, configuration→config, etc.) and truncates at word boundaries. Run `dot slugify` to rename existing IDs to include slugs.

Commands accept short prefixes:

```bash
dot on a3f2b1    # Matches dots-fix-user-auth-a3f2b1c8
dot show a3f     # Error if ambiguous (multiple matches)
```

### Slugify

```bash
dot slugify
```
Renames all issue IDs (including archived) to include slugs based on their titles. Preserves the hex suffix and updates all dependency references.

### Status Flow

```
open -> active -> done (archived)
```

- `open`: Task created, not started
- `active`: Currently being worked on
- `done`: Completed, moved to archive

### Priority Scale

- `0`: Critical
- `1`: High
- `2`: Normal (default)
- `3`: Low
- `4`: Backlog

### Dependencies

- `parent (-P)`: Creates folder hierarchy. Parent folder contains child files.
- `blocks (-a)`: Stored in frontmatter. Task blocked until all blockers are `done`.

### Archive Behavior

When a task is marked done:
- **Root tasks**: Immediately moved to `.dots/archive/`
- **Child tasks**: Stay in parent folder until parent is closed
- **Parent tasks**: Only archive when ALL children are closed (moves entire folder)

## Agent Integration

dots is a pure CLI tool. For Claude Code and Codex integration (session management, auto-continuation, context clearing), use [banjo](https://github.com/joelreymont/banjo).

## Migrating from beads

If you have existing tasks in `.beads/beads.db`, use the migration script:

```bash
./migrate-dots.sh
```

This exports your tasks from SQLite and imports them as markdown files. The script verifies the migration was successful before prompting you to delete the old `.beads/` directory.

Requirements: `sqlite3` and `jq` must be installed.

## Why dots?

| Feature | Description |
|---------|-------------|
| Markdown files | Human-readable, git-friendly storage |
| YAML frontmatter | Structured metadata with flexible body |
| Folder hierarchy | Parent-child relationships as directories |
| Short IDs | Type `a3f` instead of `dots-a3f2b1c8d9e04a7b` |
| Archive | Completed tasks out of sight, available if needed |
| Zero dependencies | Single binary, no runtime requirements |

## License

MIT

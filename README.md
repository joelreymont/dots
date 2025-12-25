![Connect the dots](assets/banner.jpg)

# dots

> **Like beads, but smaller and faster!**

Minimal task tracker for AI agents. 16x smaller than beads (1.2MB vs 19MB), 2x faster startup (~3ms), built-in Claude Code hooks, beads-compatible SQLite storage.

## What is dots?

dots is a CLI task tracker designed for Claude Code hooks. It stores tasks in `.beads/beads.db` (SQLite) for beads compatibility, enabling drop-in replacement. Each task has an ID, title, status, priority, and optional parent/dependency relationships.

## Installation

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
# Output: dots 0.2.0
```

## Quick Start

```bash
# Initialize in current directory
dot init
# Creates: .beads/beads.db

# Add a task
dot add "Fix the login bug"
# Output: bd-a1b2c3d4

# List tasks
dot ls
# Output: [bd-a1b2c3d4] o Fix the login bug

# Start working
dot on bd-a1b2c3d4
# Output: (none, task marked active)

# Complete task
dot off bd-a1b2c3d4 -r "Fixed in commit abc123"
# Output: (none, task marked done)
```

## Command Reference

### Initialize

```bash
dot init
```
Creates `.beads/beads.db` SQLite database. Safe to run if already exists.

### Add Task

```bash
dot add "title" [-p PRIORITY] [-d "description"] [-P PARENT_ID] [-a AFTER_ID] [--json]
dot "title"  # shorthand for: dot add "title"
```

Options:
- `-p N`: Priority 0-4 (0 = highest, default 2)
- `-d "text"`: Long description
- `-P ID`: Parent task ID (for hierarchy)
- `-a ID`: Blocked by task ID (dependency)
- `--json`: Output created task as JSON

Examples:
```bash
dot add "Design API" -p 1
# Output: bd-1a2b3c4d

dot add "Implement API" -a bd-1a2b3c4d -d "REST endpoints for user management"
# Output: bd-3c4d5e6f

dot add "Write tests" --json
# Output: {"id":"bd-5e6f7a8b","title":"Write tests","status":"open","priority":2,...}
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
[bd-1a2b3c4d] o Design API        # o = open
[bd-3c4d5e6f] > Implement API     # > = active
[bd-5e6f7a8b] x Write tests       # x = done
```

Output format (JSON):
```json
[{"id":"bd-1a2b3c4d","title":"Design API","status":"open","priority":1,...}]
```

### Start Working

```bash
dot on <id>
```
Marks task as `active`. Use when you begin working on a task.

### Complete Task

```bash
dot off <id> [-r "reason"]
```
Marks task as `done`. Optional reason is stored in task.

### Show Task Details

```bash
dot show <id>
```

Output:
```
ID:       bd-1a2b3c4d
Title:    Design API
Status:   open
Priority: 1
Desc:     REST endpoints for user management
Created:  2024-12-24T10:30:00.000000+00:00
```

### Remove Task

```bash
dot rm <id>
```
Permanently deletes task from database.

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
[bd-1a2b3c4d] ○ Build auth system
  └─ [bd-2b3c4d5e] ○ Design schema
  └─ [bd-3c4d5e6f] ○ Implement endpoints (blocked)
  └─ [bd-4d5e6f7a] ○ Write tests (blocked)
```

### Search Tasks

```bash
dot find "query"
```
Case-insensitive search in title and description.

## Data Model

Tasks are stored in `.beads/beads.db` (SQLite). JSON output format:

```json
{
  "id": "bd-1a2b3c4d",
  "title": "Fix login bug",
  "description": "Users can't log in with special characters",
  "status": "open",
  "priority": 2,
  "created_at": "2024-12-24T10:30:00.000000+00:00",
  "updated_at": "2024-12-24T10:30:00.000000+00:00"
}
```

### Status Flow

```
open → active → done
```

- `open`: Task created, not started
- `active`: Currently being worked on
- `done`: Completed

### Priority Scale

- `0`: Critical
- `1`: High
- `2`: Normal (default)
- `3`: Low
- `4`: Backlog

### Dependencies

- `parent`: Groups tasks hierarchically (shown in `dot tree`)
- `after`: Blocks task until dependency is `done` (shown in `dot ready`)

## Claude Code Integration

dots has built-in hook support—no Python scripts needed.

### Built-in Hook Commands

```bash
dot hook session  # Show active/ready tasks at session start
dot hook sync     # Sync TodoWrite JSON from stdin to dots
```

### Claude Code Settings

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "dot hook session"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "TodoWrite",
        "hooks": [{"type": "command", "command": "dot hook sync"}]
      }
    ]
  }
}
```

The `sync` hook automatically:
- Creates `.beads/` directory if needed
- Maps TodoWrite content to dot IDs (stored in `.beads/todo-mapping.json`)
- Creates new dots for new todos
- Marks dots as done when todos are completed

## Beads Compatibility

dots supports beads command aliases for drop-in replacement:

| beads command | dots equivalent |
|---------------|-----------------|
| `bd create "title"` | `dot create "title"` |
| `bd update ID --status in_progress` | `dot update ID --status active` |
| `bd close ID --reason "done"` | `dot close ID --reason "done"` |
| `bd list --json` | `dot ls --json` |
| `bd ready --json` | `dot ready --json` |

Status mapping: beads `in_progress` = dots `active`

## Why dots?

Both binaries statically link SQLite for zero runtime dependencies.

| | beads | dots | diff |
|---|------:|-----:|------|
| Binary | 19 MB | 1.2 MB | 16x smaller |
| Code | 188K lines | ~800 lines | 235x smaller |
| Startup | ~7ms | ~3ms | 2x faster |
| Storage | SQLite | SQLite | same |
| Daemon | Required | None | — |

## License

MIT

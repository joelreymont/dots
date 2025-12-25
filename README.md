# dots

> **Like beads, but smaller and faster!**

Minimal task tracker for AI agents. 1.3MB binary (static SQLite), ~3ms startup, beads-compatible storage.

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
# Output: dots 0.1.0
```

## Quick Start

```bash
# Initialize in current directory
dot init
# Creates: .dots (empty file)

# Add a task
dot add "Fix the login bug"
# Output: d-a1b2

# List tasks
dot ls
# Output: [d-a1b2] o Fix the login bug

# Start working
dot it d-a1b2
# Output: (none, task marked active)

# Complete task
dot off d-a1b2 -r "Fixed in commit abc123"
# Output: (none, task marked done)
```

## Command Reference

### Initialize

```bash
dot init
```
Creates empty `.dots` file in current directory. Safe to run if file exists.

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
# Output: d-1a2b

dot add "Implement API" -a d-1a2b -d "REST endpoints for user management"
# Output: d-3c4d

dot add "Write tests" --json
# Output: {"id":"d-5e6f","title":"Write tests","status":"open","priority":2,...}
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
[d-1a2b] o Design API        # o = open
[d-3c4d] > Implement API     # > = active
[d-5e6f] x Write tests       # x = done
```

Output format (JSON):
```json
[{"id":"d-1a2b","title":"Design API","status":"open","priority":1,...}]
```

### Start Working

```bash
dot it <id>
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
ID:       d-1a2b
Title:    Design API
Status:   open
Priority: 1
Desc:     REST endpoints for user management
Parent:   (none)
After:    (none)
Created:  2024-12-24T10:30:00.000000+00:00
```

### Remove Task

```bash
dot rm <id>
```
Permanently deletes task from `.dots` file.

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
[d-1] ○ Build auth system
  └─ [d-2] ○ Design schema
  └─ [d-3] ○ Implement endpoints (blocked)
  └─ [d-4] ○ Write tests (blocked)
```

### Search Tasks

```bash
dot find "query"
```
Case-insensitive search in title and description.

## Data Model

Each task is stored as a JSON line in `.dots`:

```json
{
  "id": "d-1a2b",
  "title": "Fix login bug",
  "description": "Users can't log in with special characters",
  "status": "open",
  "priority": 2,
  "parent": null,
  "after": null,
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

### Hook Scripts

Create these Python scripts to sync TodoWrite with dots:

#### `~/.claude/scripts/dots-sync.py`

```python
#!/usr/bin/env python3
"""PostToolUse hook: sync TodoWrite todos to dots."""
import json
import subprocess
import sys
from pathlib import Path

MAPPING_FILE = Path(".dots-mapping.json")

def run_dot(args):
    try:
        result = subprocess.run(["dot"] + args, capture_output=True, text=True, timeout=10)
        return result.returncode, result.stdout
    except:
        return 1, ""

def load_mapping():
    if MAPPING_FILE.exists():
        try:
            return json.loads(MAPPING_FILE.read_text())
        except:
            pass
    return {}

def save_mapping(mapping):
    MAPPING_FILE.write_text(json.dumps(mapping, indent=2))

def main():
    hook_data = json.loads(sys.stdin.read())
    if hook_data.get("tool_name") != "TodoWrite":
        sys.exit(0)

    todos = hook_data.get("tool_input", {}).get("todos", [])

    # Initialize dots if needed
    if not Path(".dots").exists():
        run_dot(["init"])

    mapping = load_mapping()

    for todo in todos:
        content = todo.get("content", "")
        status = todo.get("status", "pending")

        if not content:
            continue

        dot_id = mapping.get(content)

        if status == "completed":
            if dot_id:
                run_dot(["close", dot_id, "--reason", f"Completed: {content}"])
                mapping.pop(content, None)
        elif not dot_id:
            desc = todo.get("activeForm", "")
            priority = 1 if status == "in_progress" else 2
            code, output = run_dot(["create", content, "-p", str(priority), "-d", desc, "--json"])
            if code == 0:
                result = json.loads(output)
                mapping[content] = result.get("id")

    save_mapping(mapping)

if __name__ == "__main__":
    main()
```

#### `~/.claude/scripts/dots-load.py`

```python
#!/usr/bin/env python3
"""SessionStart hook: display open dots."""
import json
import subprocess
import sys
from pathlib import Path

def run_dot(args):
    try:
        result = subprocess.run(["dot"] + args, capture_output=True, text=True, timeout=10)
        return result.returncode, result.stdout
    except:
        return 1, ""

def main():
    if not Path(".dots").exists():
        sys.exit(0)

    code, output = run_dot(["ready", "--json"])
    ready = json.loads(output) if code == 0 and output.strip() else []

    code, output = run_dot(["ls", "--json", "--status", "active"])
    active = json.loads(output) if code == 0 and output.strip() else []

    if not ready and not active:
        sys.exit(0)

    print("--- DOTS ---")
    if active:
        print("ACTIVE:")
        for d in active:
            print(f"  [{d['id']}] {d['title']}")
    if ready:
        print("READY:")
        for d in ready:
            print(f"  [{d['id']}] {d['title']}")

if __name__ == "__main__":
    main()
```

### Claude Code Settings

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{"type": "command", "command": "python3 ~/.claude/scripts/dots-load.py"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "TodoWrite",
        "hooks": [{"type": "command", "command": "python3 ~/.claude/scripts/dots-sync.py"}]
      }
    ]
  }
}
```

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
| Binary | 19 MB | 1.3 MB | 15x smaller |
| Code | 188K lines | ~800 lines | 235x smaller |
| Startup | ~7ms | ~3ms | 2x faster |
| Storage | SQLite | SQLite | same |
| Daemon | Required | None | — |

## License

MIT

![Connect the dots](assets/banner.jpg)

# dots

> **Fast, minimal task tracking with plain markdown files — no database required**

Minimal task tracker for AI agents with built-in Claude Code hooks.

| | beads (SQLite) | dots (markdown) |
|---|---:|---:|
| Binary | 25 MB | **233 KB** (107x smaller) |
| Lines of code | 115,000 | **2,800** (41x less) |
| Dependencies | Go, SQLite/Wasm | None |
| Portability | Rebuild per platform | Copy `.dots/` anywhere |

## What is dots?

A CLI task tracker with **zero dependencies** — tasks are plain markdown files with YAML frontmatter in `.dots/`. No database, no server, no configuration. Copy the folder between machines, commit to git, edit with any tool. Parent-child relationships map to folders. Each task has an ID, title, status, priority, and optional dependencies.

**NEW: ExecPlan Integration** — dots now supports hierarchical execution plans with Plan > Milestone > Task structure, built-in progress tracking, and autonomous agent (Ralph) scaffolding.

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
# Output: dots 0.5.2
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

## ExecPlan Commands

dots supports hierarchical execution plans with Plan > Milestone > Task structure.

### Create Plan

```bash
dot plan "title" [-s "scope"] [-a "acceptance"]
```

Creates a new plan with auto-generated template sections:
- Purpose / Big Picture
- Milestones (auto-populated)
- Progress, Surprises & Discoveries, Decision Log
- Context and Orientation
- Plan of Work
- Validation and Acceptance
- Idempotence and Recovery
- Outcomes & Retrospective

Also creates an `artifacts/` subfolder for research, screenshots, etc.

### Add Milestone

```bash
dot milestone <plan-id> "title"
```

Adds a milestone to a plan. Validates that the parent is a plan.

### Add Task

```bash
dot task <milestone-id> "title"
```

Adds a task to a milestone. Validates that the parent is a milestone.

### Track Progress

```bash
dot progress <id> "message"    # Add timestamped progress entry
dot discover <id> "note"       # Add to Surprises & Discoveries
dot decide <id> "decision"     # Add to Decision Log
```

These commands append structured entries to the plan's markdown body.

### Backlog Management

```bash
dot backlog <id>    # Move plan to backlog/
dot activate <id>   # Move plan from backlog/ to active
```

### Generate Ralph Scaffolding

```bash
dot ralph <plan-id>
```

Generates autonomous execution scaffolding in `.dots/<plan-id>/ralph/`:

```
ralph/
  tasks.json    # Atomic tasks with priorities and dot IDs
  ralph.sh      # Execution script with helper functions
  prompt.md     # Agent prompt with context
  progress.txt  # Live progress tracking
```

The `tasks.json` file maps plan tasks to a format suitable for autonomous agents:

```json
{
  "name": "Plan Title",
  "execplan": ".dots/<plan-id>/<plan-id>.md",
  "tasks": [
    {
      "id": "TASK-001",
      "title": "Task title",
      "priority": 2,
      "done": false,
      "milestone": "milestone-id",
      "dotId": "dots-abc123",
      "verify": ""
    }
  ]
}
```

### Migrate ExecPlans

```bash
dot migrate [path]
```

Migrates existing `.agent/execplans/` (or specified path) to `.dots/` format. Each markdown file becomes a plan with preserved content. Original files are not deleted.

### List by Type

```bash
dot ls --type plan       # List only plans
dot ls --type milestone  # List only milestones
dot ls --type task       # List only tasks
```

## Storage Format

Tasks are stored as markdown files with YAML frontmatter in `.dots/`:

```
.dots/
  config                            # ID prefix setting
  todo-mapping.json                 # TodoWrite sync mapping

  # Simple tasks
  a1b2c3d4e5f6a7b8.md              # Root dot (no children)
  f9e8d7c6b5a49382/                # Parent with children
    f9e8d7c6b5a49382.md            # Parent dot file
    1a2b3c4d5e6f7890.md            # Child dot

  # ExecPlan hierarchy
  <plan-id>/
    <plan-id>.md                   # Plan document (issue-type: plan)
    artifacts/                      # Auto-created artifacts folder
    <milestone-id>/
      <milestone-id>.md            # Milestone (issue-type: milestone)
      <task-id>.md                 # Task (issue-type: task)
    ralph/                         # Generated by: dot ralph
      tasks.json
      ralph.sh
      prompt.md
      progress.txt

  backlog/                          # Draft/future plans
  archive/                          # Closed dots
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

#### Plan-specific frontmatter

```markdown
---
title: User Authentication
status: open
priority: 2
issue-type: plan
created-at: 2024-12-24T10:30:00Z
scope: OAuth2 + JWT implementation
acceptance: All auth endpoints pass integration tests
---
```

The `issue-type` field can be:
- `task` (default) - Regular task
- `plan` - Top-level execution plan
- `milestone` - Milestone within a plan

### ID Format

IDs are prefixed hex strings like `dots-a3f2b1c8d9e04a7b`. The prefix is configurable via `.dots/config`. Commands accept short prefixes:

```bash
dot on a3f2b1    # Matches dots-a3f2b1c8d9e04a7b
dot show a3f     # Error if ambiguous (multiple matches)
```

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
- Creates `.dots/` directory if needed
- Maps TodoWrite content to dot IDs (stored in `.dots/todo-mapping.json`)
- Creates new dots for new todos
- Marks dots as done when todos are completed

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

# dots-plan-progress

Trigger: /progress, plan status, show progress, what's done

## Description

Reports the current status of active plans in `.dots/`, including completion percentages, blockers, and next actions.

## Prerequisites

- `.dots/` directory must exist
- `dot` CLI must be installed and in PATH

## Workflow

### Phase 1: Gather Plan Status

1. List all active plans:
   ```bash
   dot ls --type plan --status open
   dot ls --type plan --status active
   ```

2. For each plan, get the hierarchy:
   ```bash
   dot tree <plan-id>
   ```

### Phase 2: Calculate Progress

For each plan:

1. Count milestones: total, completed, in-progress
2. Count tasks per milestone: total, completed, in-progress
3. Calculate completion percentage:
   - Task completion: done_tasks / total_tasks
   - Milestone completion: done_milestones / total_milestones

### Phase 3: Identify Blockers

1. Find blocked tasks (status: open, has unclosed blockers)
2. Find tasks that have been "active" for a long time
3. Read the latest discoveries and decisions from plan files

### Phase 4: Report

Generate a summary report:

```
## Active Plans

### [dots-abc123] Add user authentication
Progress: ████████░░ 80% (8/10 tasks)

Milestones:
- [x] Setup infrastructure (3/3 tasks)
- [>] Core implementation (4/5 tasks)
- [ ] Testing and validation (1/2 tasks)

Currently active:
- [dots-task9] Write integration tests

Blockers:
- None

Recent progress:
- (2026-01-09) Added login endpoint
- (2026-01-09) Added JWT validation

### [dots-def456] Fix performance issues
Progress: ██░░░░░░░░ 20% (2/10 tasks)
...
```

## Output Format

The report includes:
- Plan title and ID
- Visual progress bar
- Milestone breakdown
- Currently active tasks
- Any blockers
- Recent progress entries

## Example

```
User: /progress

Agent: Checking plan status...

## Active Plans

### [dots-abc123] Add user authentication
Progress: ████████░░ 80% (8/10 tasks)

Milestones:
- [x] Setup infrastructure (3/3)
- [>] Core implementation (4/5)
- [ ] Testing (1/2)

Active: Write integration tests
Next: Run full test suite

No blockers. Last update: 2 hours ago.
```

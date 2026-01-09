---
name: dots-plan-update
description: Use when modifying ExecPlans or when user says "/update-plan", "modify plan", "change plan", "reprioritize" - updates priorities, adds/removes milestones and tasks
---

# dots-plan-update

Trigger: /update-plan, modify plan, change plan, reprioritize

## Description

Updates an existing ExecPlan in `.dots/` - change priorities, add/remove milestones and tasks, or restructure the plan based on new information.

## Prerequisites

- An existing plan in `.dots/`
- `dot` CLI must be installed and in PATH

## Workflow

### Phase 1: Load Current Plan

1. If plan ID not provided, list available plans:
   ```bash
   dot ls --type plan
   ```

2. Load the plan and show current structure:
   ```bash
   dot tree <plan-id>
   dot show <plan-id>
   ```

### Phase 2: Understand Changes Needed

Ask the user what changes are needed:

1. **Priority changes**: Which tasks should be done first/later?
2. **Scope changes**: Add new milestones/tasks? Remove obsolete ones?
3. **Structural changes**: Move tasks between milestones? Split or merge?
4. **Blocking changes**: Add or remove dependencies?

### Phase 3: Apply Changes

#### To change priority:
```bash
dot update <id> --priority <0-4>
```
Priority scale: 0=critical, 1=high, 2=normal, 3=low, 4=backlog

#### To add new milestone:
```bash
dot milestone <plan-id> "New milestone title" -g "<goal - what will exist at the end>"
```
- `-g`: Goal - what will exist at the end of this milestone
- Parent plan's `## Milestones` section auto-updates

#### To add new task:
```bash
dot task <milestone-id> "New task title" -d "<description>" -a "<criterion 1>" -a "<criterion 2>"
```
- `-d`: Description - concrete steps, expected output
- `-a`: Acceptance criteria (can specify multiple times)
- Parent milestone's `## Tasks` section auto-updates

#### To remove task/milestone:
```bash
dot rm <id>
```

#### To move to backlog:
```bash
dot backlog <plan-id>
```

#### To reactivate from backlog:
```bash
dot activate <plan-id>
```

### Phase 4: Update Documentation

After structural changes:

1. Update the "Milestones" section in the plan file
2. Update the "Tasks" section in affected milestones
3. Log the decision:
   ```bash
   dot decide <plan-id> "Restructured plan: <reason>"
   ```

### Phase 5: Confirm Changes

Show the updated structure and confirm with user:
```bash
dot tree <plan-id>
```

## Common Update Patterns

### Reprioritize after discovery
When you find something is more urgent:
```bash
dot update <task-id> --priority 0
dot progress <plan-id> "Reprioritized <task> to critical due to <reason>"
```

### Add tasks discovered during work
When new work is identified:
```bash
dot task <milestone-id> "Newly discovered: <task>" -d "<what to do>" -a "<criterion>"
dot discover <plan-id> "Found additional work needed: <detail>"
```

### Defer work to later
When something is less urgent than thought:
```bash
dot update <task-id> --priority 4
dot decide <plan-id> "Deferred <task> to backlog: <reason>"
```

### Split a large task
When a task is too big:
```bash
dot rm <large-task-id>
dot task <milestone-id> "Part 1: <first part>" -d "<what to do>" -a "<criterion>"
dot task <milestone-id> "Part 2: <second part>" -d "<what to do>" -a "<criterion>"
dot decide <plan-id> "Split <task> into smaller parts for clarity"
```

## Example

```
User: /update-plan p1-user-auth
User: The auth task is too big, split it up

Agent: Looking at the current structure...

Current task:
- [t5-implement-auth] Implement full authentication

I'll split this into smaller tasks:

$ dot rm t5
$ dot task m2 "Add login endpoint" -d "POST /api/login with email/password" -a "Returns JWT on success"
t6-add-login-endpoint
$ dot task m2 "Add logout endpoint" -d "POST /api/logout invalidates token" -a "Token blacklisted"
t7-add-logout-endpoint
$ dot task m2 "Add token refresh endpoint" -d "POST /api/refresh returns new token" -a "New token valid"
t8-add-token-refresh-endpoint

$ dot decide p1 "Split auth task into 3 endpoint-specific tasks"

Updated structure:
- Milestone 2: Core implementation
  - [ ] t6-add-login-endpoint - Add login endpoint
  - [ ] t7-add-logout-endpoint - Add logout endpoint
  - [ ] t8-add-token-refresh-endpoint - Add token refresh endpoint

(The milestone's ## Tasks section was auto-updated with each new task)
```

---
name: dots-plan-execute
description: Use when executing ExecPlans or when user says "execute plan", "/execute", "work on plan", "run plan" - works through plans in controlled batches with verification
---

# dots-plan-execute

Trigger: /execute, run plan, execute plan, work on plan

## Description

Executes an ExecPlan from `.dots/` in controlled batches. Works through tasks methodically, updating progress, logging decisions and discoveries along the way.

## Prerequisites

- An existing plan in `.dots/` (create with `/plan` if needed)
- `dot` CLI must be installed and in PATH

## Workflow

### Phase 1: Load and Review Plan

1. If plan ID not provided, show available plans:
   ```bash
   dot ls --type plan
   ```

2. Load the plan file and review:
   - Current progress (what's done, what's pending)
   - Active milestone and tasks
   - Any blockers or dependencies

3. **Critical Review**: Before executing, verify:
   - Are the tasks still valid?
   - Do paths and commands make sense?
   - Any assumptions that need checking?

### Phase 2: Execute in Batches

Execute tasks in batches of 3 (configurable). For each task:

1. **Start task**:
   ```bash
   dot on <task-id>
   ```

2. **Do the work**: Follow the task description exactly
   - If writing code: Write test first, verify it fails, implement, verify it passes
   - If configuration: Make the change, verify it works

3. **Log progress**:
   ```bash
   dot progress <plan-id> "Completed: <what was done>"
   ```

4. **Log discoveries** (if any unexpected behavior):
   ```bash
   dot discover <plan-id> "<what was found>"
   ```

5. **Log decisions** (if any design choices made):
   ```bash
   dot decide <plan-id> "<decision made>"
   ```

6. **Complete task**:
   ```bash
   dot off <task-id>
   ```

### Phase 3: Checkpoint After Batch

After each batch of 3 tasks:

1. Report what was completed
2. Report any blockers or issues
3. **STOP AND ASK** the user:
   - Should we continue to the next batch?
   - Any feedback or corrections?
   - Need to update the plan?

### Phase 4: Milestone Completion

When all tasks in a milestone are done:

1. Review all task retrospectives
2. Fill in the milestone's "Outcomes & Retrospective" section
3. Mark milestone as complete:
   ```bash
   dot off <milestone-id>
   ```
4. Move to next milestone

### Phase 5: Plan Completion

When all milestones are done:

1. Review all milestone retrospectives
2. Fill in the plan's "Outcomes & Retrospective" section
3. Run final validation (from acceptance criteria)
4. Mark plan as complete:
   ```bash
   dot off <plan-id>
   ```

## Important Rules

- **Never skip verification**: Always verify after each change
- **Stop on blockers**: If something doesn't work, stop and report
- **Evidence first**: Log actual command output, not assumptions
- **Batch size**: Default 3 tasks, adjust if tasks are very small or large

## Example

```
User: /execute dots-abc123

Agent: Loading plan "Add user authentication"...

Current status:
- Milestone 1 "Setup infrastructure": 1/3 tasks done
- Next tasks: Add JWT middleware, Create user model

Starting batch (3 tasks)...

[Task 1: Add JWT middleware]
$ dot on dots-task1
[Does the work]
$ dot progress dots-abc123 "Added JWT middleware to Express app"
$ dot off dots-task1

[After 3 tasks]

Batch complete. Completed:
- Added JWT middleware
- Created user model
- Added password hashing

Should I continue to the next batch?
```

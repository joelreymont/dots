---
name: dots-plan-create
description: Use when creating ExecPlans or when user says "create plan", "/plan", "new plan", "dots plan" - creates hierarchical execution plans with milestones and tasks in .dots/
---

# dots-plan-create

Trigger: /plan, create plan, new plan, start plan

## Description

Creates a new ExecPlan in `.dots/` using the dots CLI. The plan follows the Specs Driven Development philosophy with a hierarchical structure: Plan > Milestones > Tasks.

## Prerequisites

- `dot` CLI must be installed and in PATH
- `.dots/` directory must be initialized (run `dot init` if not)

## Workflow

### Phase 1: Gather Requirements

1. Ask the user for the plan title if not provided
2. Ask clarifying questions about:
   - Scope: What's in scope vs out of scope?
   - Acceptance criteria: How do we know it's done?
   - Context: Current state of the codebase relevant to this work

### Phase 2: Explore and Ground

1. If this is a code change, explore the codebase to understand:
   - Existing patterns and conventions
   - Files that will be modified
   - Dependencies and interfaces
2. Document findings in the Context and Orientation section

### Phase 3: Create the Plan

1. Create the plan using dots:
   ```bash
   dot plan "<title>" -s "<scope summary>" -a "<acceptance criteria>"
   ```

2. Note the generated plan ID (e.g., `dots-abc123`)

3. Add milestones for major phases:
   ```bash
   dot milestone <plan-id> "Setup and infrastructure"
   dot milestone <plan-id> "Core implementation"
   dot milestone <plan-id> "Testing and validation"
   ```

4. Add tasks to each milestone:
   ```bash
   dot task <milestone-id> "Write failing test for X"
   dot task <milestone-id> "Implement X"
   dot task <milestone-id> "Verify X works"
   ```

### Phase 4: Document the Plan

1. Open the plan file at `.dots/<plan-id>/<plan-id>.md`
2. Fill in:
   - Purpose / Big Picture
   - Context and Orientation (from Phase 2)
   - Plan of Work (narrative for each milestone)
   - Validation and Acceptance criteria

### Phase 5: Review

1. Show the user the plan summary
2. Ask if any changes are needed before starting execution

## Output

The plan ID and a summary of milestones/tasks created.

## Example

```
User: /plan Add user authentication

Agent: I'll create an ExecPlan for user authentication. Let me ask a few questions first.

[Asks about scope, acceptance criteria]
[Explores codebase for existing patterns]

Agent: Creating the plan structure:

$ dot plan "Add user authentication" -s "JWT auth with login/logout" -a "All auth tests pass"
dots-abc123

$ dot milestone dots-abc123 "Setup auth infrastructure"
dots-def456

$ dot task dots-def456 "Add JWT dependencies"
dots-ghi789

Created plan with 1 milestone and 1 task.
Plan file: .dots/dots-abc123/dots-abc123.md
```
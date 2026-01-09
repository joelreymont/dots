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

1. Create the plan using dots with content flags:
   ```bash
   dot plan "<title>" -s "<scope summary>" -a "<acceptance criteria>" \
       -p "<purpose/big picture>" -c "<context and orientation>"
   ```
   - `-p`: Purpose / Big Picture - what someone gains after this change
   - `-c`: Context - current state of codebase, key files, definitions

2. Note the generated plan ID (e.g., `p1-user-auth`)

3. Add milestones for major phases with goals:
   ```bash
   dot milestone <plan-id> "Setup and infrastructure" -g "<goal - what will exist at the end>"
   dot milestone <plan-id> "Core implementation" -g "<goal>"
   dot milestone <plan-id> "Testing and validation" -g "<goal>"
   ```
   - `-g`: Goal - what will exist at the end of this milestone
   - Parent plan's `## Milestones` section auto-updates with `- [ ] m1-slug - Title`

4. Add tasks to each milestone with specs:
   ```bash
   dot task <milestone-id> "Write failing test for X" \
       -d "<description of what to do>" \
       -a "<acceptance criterion 1>" \
       -a "<acceptance criterion 2>"
   ```
   - `-d`: Description - concrete steps, expected output
   - `-a`: Acceptance criteria (can specify multiple times)
   - Parent milestone's `## Tasks` section auto-updates with `- [ ] t1-slug - Title`

### Phase 4: Review and Refine

1. Review the generated plan file at `.dots/<plan-id>/_plan.md`
2. Add any additional narrative to:
   - Plan of Work (sequence of edits)
   - Validation and Acceptance (how to verify success)

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

$ dot plan "Add user authentication" -s "JWT auth with login/logout" -a "All auth tests pass" \
    -p "Enable secure user authentication using JWT tokens" \
    -c "Express.js backend, no existing auth. User model exists in models/user.js"
p1-user-auth

$ dot milestone p1 "Setup auth infrastructure" -g "JWT middleware and dependencies configured"
m1-setup-auth-infrastructure

$ dot task m1 "Add JWT dependencies" \
    -d "Install jsonwebtoken and bcrypt packages" \
    -a "Packages in package.json" \
    -a "Package lock updated"
t1-add-jwt-dependencies

Created plan with 1 milestone and 1 task.
Plan file: .dots/p1-user-auth/_plan.md

The plan's ## Milestones section now shows: - [ ] m1-setup-auth-infrastructure - Setup auth infrastructure
The milestone's ## Tasks section now shows: - [ ] t1-add-jwt-dependencies - Add JWT dependencies
```
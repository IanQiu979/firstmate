---
name: ship-planning-gate
description: >-
  Agent-only pre-dispatch gate for Ship tasks in a registered project. Use before writing a Ship
  brief for a new feature or a bug fix whose approach is not already fully specified by the
  request. Owns what a plan must contain and how captain approval is recorded before a brief is
  written. Does not apply to firstmate's own tracked-material maintenance.
user-invocable: false
metadata:
  internal: true
---

# ship-planning-gate

Load this before writing a Ship brief for a registered project, unless the request is a trivial, fully-specified one-off (a version bump, a rename, an obvious copy fix).
Firstmate's own repo maintenance (`bin/`, `.agents/skills/`, `AGENTS.md` itself) never uses this gate; it stays on the existing fast path.

## Stating the plan

Before writing the brief, state back to the captain in chat:

- The problem or feature in one or two sentences.
- The intended approach, named concretely enough that a crewmate could start from it.
- Acceptance criteria: what "done" looks like.
- Affected surface: which project, which rough area of it.

Always restate the plan and wait for an explicit go, even when the captain's own request already read like a full plan; do not infer approval from how detailed the request was or from silence.
Do not write this as a separate document by default - say it in chat and let the captain react.
Only produce a written plan artifact (a Scout report) when there is real investigation or design uncertainty to resolve first; that path already exists (AGENTS.md section 7's Scout bullet) and this gate does not duplicate it.

## Recording approval

Record the one-line plan and the captain's go-ahead in the backlog item's note (section 10) before spawning: `plan: <one-line approach>; approved: <how the captain confirmed it>`.
A Scout promotion (`bin/fm-promote.sh`) already satisfies this gate: the report is the plan, and the captain's authorization to promote is the approval - no separate restating step is needed.

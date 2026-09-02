---
name: ship-maintain-checkback
description: >-
  Agent-only post-deploy verification for Ship tasks in a registered project. Use immediately
  after landing is confirmed, to register a decoupled, single-fire check-back confirming a shipped
  change is still intact after a delay - not just that CI passed at merge time. Owns the default
  interval, the [maintain: ...] tag override, what the check verifies, and how a finding is
  handled at wake time.
user-invocable: false
metadata:
  internal: true
---

# ship-maintain-checkback

Load this immediately after landing is confirmed for a Ship task in a registered project, unless that project's registry entry carries `[maintain: off]`.
This never blocks or delays teardown - the crewmate task tears down exactly as today, and this check-back lives independently of it.

## Registering the check

Register a plain custom check (`state/<id>.check.sh` + `bin/fm-check-register.sh`, AGENTS.md section 7) under a check id distinct from the task id, since the task's own state is expected to be cleaned up at teardown while this check must survive well past it.
The sidecar the check script reads needs: the project, the shipped commit, a one-line description of what shipped, and the due time - `now + <interval>`, default 24h, overridden by the project's `[maintain: <duration>]` tag.
This is a plain check, not a `process-event-sources` condition->action watch: the follow-up judgment - interpret the result, decide whether to escalate - depends on what the check finds, and that class of action stays a wake-time decision per that skill's own eligibility rule, never a bound automatic action.

## What it verifies

The check prints nothing until due, then performs exactly one pass and prints one summary line:

- **Ancestry (always).** The shipped commit is still an ancestor of the project's current default-branch head - catches a silent revert or a force-push over the change.
  This is the only tier that applies to a `local-only` project with no CI.
- **CI status (when the project has CI).** The project's latest CI run on current main is green - catches a regression introduced by anything that landed after the shipped change, without requiring firstmate to understand the shipped feature semantically.

This is a deliberately mechanical, honest default: it confirms the change is still there and the project still builds, not that the feature "works as intended" in some deeper behavioral sense.
A project that wants a stronger signal (a live health-check URL or smoke command) needs one built and registered for that project specifically - this gate does not invent monitoring where none exists.

## Handling the wake

On the resulting `check:` wake, read the one-line result:

- **Clean** (ancestry intact, CI green or absent): no captain-facing message.
  Note the confirmation in the shipped backlog item's note if it still exists, retire the check, done.
- **Problem found** (commit missing, CI red on current main): treat this exactly like any other newly discovered bug - classify and intake it under AGENTS.md section 7 as normal, and escalate to the captain per section 9 (evidence, consequence, recommendation) since a live regression found after the fact is a genuine failure, not routine progress.

Retire the check after handling either outcome; it fires once and does not repeat.

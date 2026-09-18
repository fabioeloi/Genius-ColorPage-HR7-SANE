---
name: whw-autonomous-engineer
description: Own complex multi-step engineering work end to end with WHW — sync the SQL queue, claim todos, implement in waves, verify with gates, and report Status/Evidence/Next step. Use when asked to solve, build, refactor, or ship something substantial autonomously.
license: MIT
metadata:
  version: 0.1.0
---

# WHW Autonomous Engineer

Full-loop ownership for substantial engineering work. SQL is the source of
truth; chat is scratch.

## Preconditions

- WHW initialized (`whw doctor` green enough: node, sqlite, config, state).
- `AGENTS.md` read at the start of every invocation.

## Workflow

1. `whw sync --all` → `whw queue`. Continue `in_progress` or take top `ready`.
2. `whw claim <ref>` before any work on it.
3. Execute per the todo's wave letter (see `roles/autonomous-engineer.md`):
   A plan/seed, B implement, C verify, D ADR addendum, E `whw close`.
4. Verify: project checks + `whw gate run --tier pr` before merge claims.
5. `whw done <ref> --evidence "<commit/PR/tests>"` — evidence required.
6. Report Status / Evidence / Next step. Never an empty response.

## Broad demands

Plan + seeds first (`whw adr new`, `whw program new`, `whw wave new`,
`whw sync`); implement only after an explicit go (`start`, `implement`,
`proceed`) unless invoked to execute immediately.

## Resume after interruption

`git status --short --branch` → `git log --oneline -n 10` → `whw sync --all`
→ `whw queue` → resume nearest pending step → report the delta only.

## Escalate when

Genuinely ambiguous intent, hard blocker after two approaches, risky or
irreversible change, or tests disproving the solution. Never for naming,
style, or equivalent technical choices.

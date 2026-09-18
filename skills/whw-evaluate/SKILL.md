---
name: whw-evaluate
description: Review a wave's change in two phases — deterministic checks at zero AI cost, then the weighted 4-criterion rubric with APPROVE/REJECT. Use on every wave C and before any merge.
license: MIT
metadata:
  version: 0.1.0
---

# WHW Evaluate

Skeptical, stateless review. Evidence only — no credit for effort.

## Phase A — deterministic (always first)

1. `whw evaluate --phase a` (lint/tests/build from config).
2. `whw gate run --tier pr` when planning/docs/adapters changed.
3. Any failure → REJECT with the exact command + output. Never score Phase B
   on a red Phase A.

## Phase B — rubric (green Phase A only)

1. `whw evaluate --phase b` prints the scoring prompt.
2. Review diff vs. ADR + acceptance + `templates/evaluation-criteria.md`.
   Score 0–5: `technical-quality` 1.3×, `originality` 1.3×, `craft` 1.0×,
   `functionality` 1.0×.
3. `whw evaluate --phase b --scores '{…}'` → APPROVE (avg ≥ 3.5) or REJECT
   with exactly the top-3 fixes by leverage.

## Rules

- Score artifacts, not authors. Tiny can be 5; large can be 1.
- REJECT returns to the builder; never rewrite the code in the same pass.
- Record the verdict as evidence on the wave's C todo.

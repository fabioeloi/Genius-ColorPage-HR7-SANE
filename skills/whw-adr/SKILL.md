---
name: whw-adr
description: Author Architecture Decision Records and per-wave addenda in WHW format — context, decision, consequences, and traceable follow-ups. Use when deciding anything consequential or closing a wave D.
license: MIT
metadata:
  version: 0.1.0
---

# WHW ADR

Decisions are the durable part of engineering. Write them so a stranger in a
year understands the why, not just the what.

## New ADR

1. `whw adr new <slug> [--title "…"]` → `docs/adr/NNNN-<slug>.md`.
2. Fill Context (forces), Decision (rules table), Consequences
   (positive + negative/trade-offs), References.
3. Status starts `Proposed`; flip to `Accepted` when the first wave lands,
   `Superseded`/`Rejected` with a pointer when it dies.

## Program charters

`whw program new <slug> --waves N` writes the charter: context, explicit
exclusions (deferred fronts + revisit rule), wave map, execution rules, close
criteria. Keep the `<!-- whw:program … -->` marker intact — the
program-inventory gate reads it.

## Wave addenda (wave D)

Append per wave, newest last:

```md
## Addendum Wave NNN — <topic>

Shipped: … Evidence: <commits/PRs/checkpoints>. Follow-ups: …
```

The `wave-sync` gate requires the addendum to name the wave number.

## Rules

- One decision per ADR; cross-link with Related.
- No wave may cite a `Rejected` ADR; superseding needs a new ADR.
- Record what was *rejected* and why — the options table is the point.

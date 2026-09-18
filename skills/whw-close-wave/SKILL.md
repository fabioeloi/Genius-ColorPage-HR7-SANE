---
name: whw-close-wave
description: Land a WHW wave canonically — verify A–D terminal, ADR addendum, plan entry, and sync gates, then run whw close. Use once per wave, last, when implementation and review are done.
license: MIT
metadata:
  version: 0.1.0
---

# WHW Close Wave

Nothing is "basically done": the checklist holds or the wave stays open.

## Checklist

1. A–D terminal (`done`/`cancelled`); only E may be open.
2. `## Addendum Wave NNN` in the wave's ADR (scope, evidence, follow-ups).
3. `## Wave NNN — <slug>` in `docs/plan.md` with 5W2H rows + PR links.
4. `whw gate run planning-coverage adr-link wave-sync readme-sync` GO.
5. PR numbers recorded in todo evidence, plan entry, and addendum.

## Workflow

1. Verify 1–5, fixing narrative gaps only (never code here).
2. `whw close <wave>` — re-asserts, applies `.done.sql`, audits E.
3. Report Status / Evidence / Next step.
4. Program's last wave: `whw gate run program-inventory` +
   `whw metrics --out .whw/metrics.json`, linked from the addendum.

## Rules

- Never force a close; never close on a red `main`.
- Never invent evidence — commits, PRs, checkpoints, or test output.

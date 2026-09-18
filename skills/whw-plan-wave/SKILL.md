---
name: whw-plan-wave
description: Turn an idea or ADR into a verifiable WHW wave — alignment, design, wave scaffold, seed review, and sync. Use before any implementation wave or when asked to plan scoped work.
license: MIT
metadata:
  version: 0.1.0
---

# WHW Plan Wave

Produce a plan a builder can execute without guessing. No implementation code.

## Workflow

1. **Discover.** Read `WHY.md`, the serving ADR (or `whw adr new <slug>`),
   `docs/plan.md`, `AGENTS.md`. Run `whw queue` — never collide with a wave
   in flight.
2. **Align.** Two genuinely different readings → ask, or record the assumption
   in the ADR and proceed. Never silent ambiguity.
3. **Design.** Smallest plan satisfying the WHY: files touched, data shapes,
   surface changes, explicit non-goals, acceptance as commands.
4. **Scaffold.** `whw wave new <slug> --adr NNNN`; sharpen the generated
   titles/notes; `whw sync <track>`.
5. **Report.** Status / Evidence / Next step; next step names the first claim.

## Rules

- No wave without an ADR; no ADR without a WHY.
- One wave = one reviewable increment (five letters max, then split).
- Program-scale work: `whw program new <slug> --waves N` first; wave 1 is
  documentation-first.

# ADR {{NUMBER}} — Program: {{TITLE}}

<!-- whw:program slug="{{SLUG}}" waves="{{FIRST}}-{{LAST}}" -->

- **Status:** {{STATUS}}
- **Date:** {{DATE}}
- **Waves:** {{FIRST}}–{{LAST}} ({{COUNT}} waves)
- **Related:** WHY.md

> Keep the `whw:program` marker intact — `whw gate run program-inventory`
> reads it. There is **no wave {{AFTER}}** in this program: extension requires
> a new charter ADR.

## Context

Why this program exists. What outcome closes it. What the previous program (if
any) left behind.

## Explicit exclusions

Deferred fronts stay OUT until a new ADR reopens them:

| Front | Reason | Revisit in |
| ----- | ------ | ---------- |
| …     | …      | …          |

## Wave map

| Wave | Slug | ADR |
| ---- | ---- | --- |
{{WAVE_MAP}}

Fill slugs and thematic ADRs as waves are chartered (`whw wave new <slug>
--adr NNNN`). Numbers are global and sequential.

## Execution

- One wave = PRs A–E (plan → build → verify → decide → close); a wave is done
  only when **E** merges.
- First wave is documentation-first: charter finalization + planning seeds.
- Final wave is the program close: inventory gate + retrospective addendum.
- Do not start the next wave until `main` is green.
- Branch/commit conventions: `docs/how/conventions.md`.

## Close criteria

- [ ] Every wave {{FIRST}}–{{LAST}} closed via `whw close`
- [ ] `whw gate run program-inventory` GO
- [ ] `whw metrics --out .whw/metrics.json` recorded and linked below

## References

- …

<!-- Addenda: append `## Addendum Wave NNN — <topic>` per wave D, newest last. -->

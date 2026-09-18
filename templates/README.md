# {{PROJECT}}

> Delivered with WHW (Why · How · What) — an agnostic harness for
> evidence-gated delivery. Start at [WHY.md](WHY.md).

## Status

- Purpose: [WHY.md](WHY.md)
- Plan: [docs/plan.md](docs/plan.md) · Decisions: [docs/adr](docs/adr)
- Live execution state: `whw queue` (authoritative) · `whw status`

## Develop

```bash
whw sync --all   # planning/*.todos.sql → .whw/state.db
whw queue        # actionable work
whw gate run --tier pr   # blocking gates must be GO
```

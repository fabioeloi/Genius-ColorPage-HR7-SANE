## Wave {{WAVE}} — {{SLUG}} — **<status: in progress | done>**

One-paragraph scope: what this wave delivers and what it explicitly leaves out.
ADR: `docs/adr/{{ADR}}-*.md`.

| #   | What (which increment) | How (approach) | Why (reason) | Where (files) | When (wave) | Who | How much (PRs) |
| --- | ---------------------- | -------------- | ------------ | ------------- | ----------- | --- | -------------- |
| A   | Planning seed          | `whw wave new` + refined notes | … | `planning/wave-{{WAVE}}-{{SLUG}}.todos.sql` | {{WAVE}} | … | [#…](…) |
| B   | Implementation         | … | … | … | {{WAVE}} | … | [#…](…) |
| C   | Verification           | tests + `pr` gates | … | … | {{WAVE}} | … | [#…](…) |
| D   | Decision record        | ADR addendum | … | `docs/adr/{{ADR}}-*.md` | {{WAVE}} | … | [#…](…) |
| E   | Canonical close        | `whw close` + sync | … | … | {{WAVE}} | … | [#…](…) |

Sync: `whw sync wave-{{WAVE}}-{{SLUG}}` · Close: `whw close wave-{{WAVE}}-{{SLUG}}`

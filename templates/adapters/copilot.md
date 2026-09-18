# Copilot instructions (WHW-managed)

> Canonical instructions: [`AGENTS.md`](../../AGENTS.md). Edit that file — not this one.

WHW loop: `whw queue` → `whw claim <ref>` → implement → `whw done <ref>
--evidence "…"` → `whw gate run --tier pr`. End every milestone with Status /
Evidence / Next step. SQL is the source of truth; never hand-edit
`.whw/state.db`.

Conventions: branches `feat/wave-NNN-<slug>-<letter>`, commits
`type(scope): summary (Wave NNN L)`, one wave letter per PR, evidence on every
`done`.

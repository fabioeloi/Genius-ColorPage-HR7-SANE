# Gemini instructions (WHW-managed)

> Canonical instructions: [`AGENTS.md`](AGENTS.md). Edit that file — not this one.
> (`.gemini/settings.json` also points Gemini's context file at `AGENTS.md`.)

WHW loop: `whw queue` → `whw claim <ref>` → implement → `whw done <ref>
--evidence "…"` → `whw gate run --tier pr`. End every milestone with Status /
Evidence / Next step. SQL is the source of truth; never hand-edit
`.whw/state.db`.

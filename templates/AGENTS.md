# AGENTS.md — {{PROJECT}}

Canonical agent instructions. Every tool-specific file (`CLAUDE.md`,
`GEMINI.md`, Copilot instructions, Cursor rules, …) defers to this document —
edit here, not there.

## The loop (humans and agents run the same commands)

1. `whw sync --all`, then `whw queue` — **SQL is the source of truth**, never
   chat memory or scratch lists.
2. `whw claim <ref>` — one claim at a time (`--force-wip` to override);
   `whw block <ref> --reason "…"` instead of improvising around obstacles.
3. Implement on `feat/wave-NNN-<slug>-<letter>`; commit
   `type(scope): summary (Wave NNN L)`.
4. `whw done <ref> --evidence "<commit/PR/tests>"` — evidence is required and
   must name artifacts a stranger could re-run.
5. `whw gate run --tier pr` must be GO before any merge.
6. End every milestone with **Status / Evidence / Next step** (`whw status`).

## Wave contract

- One wave = PRs A–E: **A** plan/seed → **B** implement → **C** verify →
  **D** ADR addendum → **E** canonical close (`whw close <wave>`).
- A wave is `done` only when **E** merges. `done` is terminal — to revisit,
  charter a new wave.
- No wave without an ADR; no ADR without a WHY (`WHY.md`).
- Do not start the next wave until `main` is green.

## Broad demands

Plan + seeds first (`whw adr new`, `whw program new`, `whw wave new`,
`whw sync`); start implementing only after an explicit go (`start`,
`implement`, `proceed`) — unless invoked to execute immediately.

## Resume after interruption

Revalidate with `whw resume` (git baseline, `whw sync --all`, queue, next
step). It does **not** auto-claim. Then continue the nearest pending step and
report only the delta:

```bash
whw resume
```

Equivalent by hand:

```bash
git status --short --branch
git log --oneline -n 10
whw sync --all
whw queue
```

## Never

- Never use in-chat lists as canonical execution state.
- Never edit `.whw/state.db` by hand — use `whw claim|done|block|cancel|note`.
- Never commit secrets, tokens, private keys, or personal data.
- Never downgrade `done`, never `--force` a close, never merge on red gates.
- Never commit or push unless the operator asked (or the wave letter requires a PR).

## Roles

- `planner` (compaction) → `builder` (reset per wave) → `evaluator`
  (reset, stateless: deterministic Phase A, then rubric Phase B) → `closer`
  (reset) — see `roles/`. `autonomous-engineer` owns the full loop.
- Optional runner: `whw run <role> [--ref REF]` (configured CLIs only).

## Docs

- `WHY.md`, `docs/plan.md` (narrative), `docs/adr/` (decisions), `planning/` (seeds).
- Process: `docs/why` (manifesto) · `docs/how` (waves, gates, continuity, …) ·
  `docs/what` (CLI, schema, config reference).

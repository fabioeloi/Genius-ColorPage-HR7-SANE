# AGENTS.md — Genius-ColorPage-HR7-SANE

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

## Product constraints

- The only supported Windows USB device is `USB\VID_0458&PID_2013` (Genius ColorPage-HR7).
- Keep the current SANE 1.4.0 Plustek backend and macOS flow intact while adding Windows WIA and TWAIN interfaces.
- End-user Windows setup must be a signed GUI package; end users must not need PowerShell, Zadig, or command-line steps.
- Target Windows 11 x64; Windows 10 22H2 x64 is best-effort. Do not claim universal application compatibility; require WIA and/or TWAIN support.
- Any SANE network endpoint must bind to loopback only. Never expose scanner control or scan data on the LAN.
- Before redistributing bridges, record exact versions, hashes, source locations, licenses, and required source/notices.
- Keep captured pages, scan images, local diagnostics/transcripts, build artifacts, certificates, and private keys untracked. Never commit a signing key or user document.
- The WinUSB installer path must disclose its device-specific libwdi certificate trust operation and require elevated user approval. Preserve existing driver state for rollback/removal when safely possible.
- Keep the English and Brazilian Portuguese user-facing documentation consistent with tested behavior; mark unverified OS/API combinations explicitly.

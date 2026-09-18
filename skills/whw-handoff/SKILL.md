---
name: whw-handoff
description: Migrate active WHW work between IDEs or agent CLIs with a resumable package — git baseline, queue snapshot, gates, and checklist. Use when switching tools or recovering a session.
license: MIT
metadata:
  version: 0.1.0
---

# WHW Handoff

Move the work, not the chat. Raw transcripts stay local — pointers only.

## Workflow

1. `whw handoff --from <tool> --to <tool>` → `docs/handoff/handoff-<date>-<from>-to-<to>.md`.
2. Confirm the git baseline in the target: `git status --short --branch`,
   `git log --oneline -n 10` — must match the package.
3. In the target: `whw resume` (sync + queue; does not claim) → resume the top item.
4. `whw gate run --tier pr` before new work; report Status / Evidence / Next.

## Package contents

Git baseline (branch @ SHA, clean/dirty, recent log), queue snapshot
(`in_progress` + top `ready`), gate checkpoint verdicts, recent transitions,
chat-path map with confidence levels, and the continuity checklist.

## Rules

- Never commit full transcripts; link local session paths with timestamps.
- Never claim a session path is universal — mark confidence
  (official / local-observed / probable / needs-runtime-detection).
- If the baseline diverges, stop: reconcile git before touching the queue.

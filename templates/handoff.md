# Handoff — {{FROM}} → {{TO}} ({{DATE}})

## Objective

{{OBJECTIVE}}

## Git baseline

- branch: {{BRANCH}}
- HEAD: {{HEAD}}
- status: {{STATUS_CLEAN}}
- log:
{{LOG}}

Verify in the target tool before continuing:

```bash
git status --short --branch
git log --oneline -n 10
```

The baseline must match (branch @ SHA, clean/dirty as above) before touching
the queue. If it diverges, stop and reconcile git first.

## Queue snapshot

{{QUEUE}}

## Gate results

{{GATES}}

## Recent transitions

{{TRANSITIONS}}

## Chat-path map (local only — pointers, never transcripts)

| Tool | Session path | Confidence |
| ---- | ------------ | ---------- |
{{CHAT_PATHS}}

## Continuity checklist

1. Baseline matches.
2. `whw resume` (or `whw sync --all` → `whw queue`) — SQL is the source of truth.
3. `whw gate run --tier pr` green before new work.
4. Resume the top queue item; claim before coding.
5. Report Status / Evidence / Next step at the first milestone.

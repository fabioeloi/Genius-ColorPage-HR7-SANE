# Evaluation criteria

Weighted rubric for `whw evaluate --phase b`. Each criterion scores 0–5;
the weighted average must reach the threshold (default **3.5**) for APPROVE.
Weights live in `whw.config.json` (`evaluate.criteria`); this file defines
what the scores mean.

## technical-quality (1.3×)

- **5** — Correct, idiomatic, secure; tests cover the change and edge cases.
- **4** — Correct with minor nits; tests cover the happy path.
- **3** — Works but with a smell (duplication, weak errors, thin tests).
- **2** — Works by accident; obvious cases untested or unhandled.
- **1** — Likely wrong; contradicts repo patterns or docs.
- **0** — Broken, insecure, or fabricated.

## originality (1.3×)

Deliberately heavy: generic filler must fail even when tests pass.

- **5** — Clearly shaped to this problem; decisions explained in code/ADR.
- **4** — Specific with minor boilerplate.
- **3** — Adequate but interchangeable with any similar task.
- **2** — Boilerplate-heavy; abstractions that serve no stated need.
- **1** — Placeholder-laden (`TODO`, stubs, `…`) or copy-paste drift.
- **0** — Plagiarized context or hallucinated APIs.

## craft (1.0×)

- **5** — Edge cases, errors, types, naming, and docs all considered.
- **4** — Solid; one small gap (a message, a comment, a type).
- **3** — Functional but rough (vague names, missing docs).
- **2** — Multiple rough edges; reviewer must guess intent.
- **1** — Sloppy; inconsistent with surrounding code.
- **0** — Unreadable or misleading.

## functionality (1.0×)

- **5** — Does everything the todo claims, verified by commands run.
- **4** — Complete; verification partially indirect.
- **3** — Core works; secondary acceptance unchecked.
- **2** — Partial; main path works, requirements missing.
- **1** — Claims exceed evidence.
- **0** — Does not do what the todo claims.

## Verdict

- `average ≥ threshold` → **APPROVE**.
- `average < threshold` → **REJECT** + exactly the top-3 fixes by leverage,
  returned to the builder (the evaluator never rewrites in the same pass).

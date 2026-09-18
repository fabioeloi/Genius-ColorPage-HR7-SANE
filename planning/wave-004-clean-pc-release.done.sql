-- Wave 004 — clean-pc-release close hook.
-- Applied ONLY by `whw close wave-004-clean-pc-release` after A–D are terminal, the ADR
-- addendum exists, and the sync gates are GO. Never apply by hand.
UPDATE todos SET status = 'done', evidence = COALESCE(evidence, '') || ' | closed 2026-09-18'
WHERE ref LIKE 'wave004-%' AND status != 'done';

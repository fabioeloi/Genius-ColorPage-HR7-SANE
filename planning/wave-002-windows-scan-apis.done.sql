-- Wave 002 — windows-scan-apis close hook.
-- Applied ONLY by `whw close wave-002-windows-scan-apis` after A–D are terminal, the ADR
-- addendum exists, and the sync gates are GO. Never apply by hand.
UPDATE todos SET status = 'done', evidence = COALESCE(evidence, '') || ' | closed 2026-09-18'
WHERE ref LIKE 'wave002-%' AND status != 'done';

-- Wave 003 — gui-installer close hook.
-- Applied ONLY by `whw close wave-003-gui-installer` after A–D are terminal, the ADR
-- addendum exists, and the sync gates are GO. Never apply by hand.
UPDATE todos SET status = 'done', evidence = COALESCE(evidence, '') || ' | closed 2026-09-18'
WHERE ref LIKE 'wave003-%' AND status != 'done';

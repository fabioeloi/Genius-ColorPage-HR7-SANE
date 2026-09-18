-- Wave {{WAVE}} — {{SLUG}} close hook.
-- Applied ONLY by `whw close {{TRACK}}` after A–D are terminal, the ADR
-- addendum exists, and the sync gates are GO. Never apply by hand.
UPDATE todos SET status = 'done', evidence = COALESCE(evidence, '') || ' | closed {{DATE}}'
WHERE ref LIKE '{{REF_PREFIX}}-%' AND status != 'done';

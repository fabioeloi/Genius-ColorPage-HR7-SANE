-- Wave {{WAVE}} — {{SLUG}} (ADR {{ADR}})
-- Apply: whw sync {{TRACK}}
-- Refs: {{REF_PREFIX}}-A .. {{REF_PREFIX}}-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close {{TRACK}}`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
{{ROWS}}
ON CONFLICT (ref) DO UPDATE SET
  title = excluded.title, track = excluded.track, step = excluded.step,
  letter = excluded.letter, adr = excluded.adr, notes = excluded.notes,
  status = CASE WHEN todos.status = 'done' THEN todos.status ELSE excluded.status END;

DELETE FROM todo_deps WHERE ref LIKE '{{REF_PREFIX}}-%';
INSERT INTO todo_deps (ref, depends_on) VALUES
{{DEPS}}
ON CONFLICT DO NOTHING;

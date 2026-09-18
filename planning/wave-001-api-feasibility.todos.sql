-- Wave 001 — api-feasibility (ADR 0001)
-- Apply: whw sync wave-001-api-feasibility
-- Refs: wave001-A .. wave001-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close wave-001-api-feasibility`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
  ('wave001-A', 'Wave 001 A — Plan: api-feasibility', 'pending', 'wave-001-api-feasibility', 1, 'A', '0001', 'Finalize WHY, program charter, architecture hypothesis, exclusions, and API/release acceptance contract. Keep private captures and logs excluded.'),
  ('wave001-B', 'Wave 001 B — Build: api-feasibility', 'pending', 'wave-001-api-feasibility', 2, 'B', '0001', 'Inventory saned, loopback bind/config, WiaSane Win10/11 status, SANEWinDS x86/x64 versions, and exact license/source obligations. Record feasibility and blockers; do not claim WIA/TWAIN compatibility.'),
  ('wave001-C', 'Wave 001 C — Verify: api-feasibility', 'pending', 'wave-001-api-feasibility', 3, 'C', '0001', 'Run WHW doctor, sync and PR gates; confirm diagnostics, scan images, local tools, and signing material are ignored/untracked.'),
  ('wave001-D', 'Wave 001 D — Decide: api-feasibility', 'pending', 'wave-001-api-feasibility', 4, 'D', '0001', 'Append ADR 0001 evidence: known SANE physical scan passes, WIA/TWAIN remain unproven, bridge implementation must gate on real API tests, and code-signing certificate is external.'),
  ('wave001-E', 'Wave 001 E — Close: api-feasibility', 'pending', 'wave-001-api-feasibility', 5, 'E', '0001', 'Close only after documentation is complete, A-D are terminal, and required WHW sync/PR gates are GO.')
ON CONFLICT (ref) DO UPDATE SET
  title = excluded.title, track = excluded.track, step = excluded.step,
  letter = excluded.letter, adr = excluded.adr, notes = excluded.notes,
  status = CASE WHEN todos.status = 'done' THEN todos.status ELSE excluded.status END;

DELETE FROM todo_deps WHERE ref LIKE 'wave001-%';
INSERT INTO todo_deps (ref, depends_on) VALUES
  ('wave001-B', 'wave001-A'),
  ('wave001-C', 'wave001-B'),
  ('wave001-D', 'wave001-C'),
  ('wave001-E', 'wave001-D')
ON CONFLICT DO NOTHING;

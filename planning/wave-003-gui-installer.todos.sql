-- Wave 003 — gui-installer (ADR 0001)
-- Apply: whw sync wave-003-gui-installer
-- Refs: wave003-A .. wave003-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close wave-003-gui-installer`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
  ('wave003-A', 'Wave 003 A — Plan: gui-installer', 'pending', 'wave-003-gui-installer', 1, 'A', '0001', 'Specify GUI flow, online pinned component sources/hashes, user-visible UAC/certificate consent, existing binding backup, rollback, repair, upgrade, and uninstall acceptance.'),
  ('wave003-B', 'Wave 003 B — Build: gui-installer', 'pending', 'wave-003-gui-installer', 2, 'B', '0001', 'Create one WiX Burn GUI installer, integrate libwdi-style HR7-only WinUSB association, install/configure SANE service + WIA/TWAIN providers, verify components, and support rollback/removal.'),
  ('wave003-C', 'Wave 003 C — Verify: gui-installer', 'pending', 'wave-003-gui-installer', 3, 'C', '0001', 'Test fresh install, duplicate install, repair, failed download, rollback, uninstall/driver restore, UAC disclosure, component hash/signature verification, and absence of non-loopback listener/firewall rule.'),
  ('wave003-D', 'Wave 003 D — Decide: gui-installer', 'pending', 'wave-003-gui-installer', 4, 'D', '0001', 'Append installer lifecycle results, package hashes, trust flow, known limits, and external Authenticode-certificate dependency to ADR 0001.'),
  ('wave003-E', 'Wave 003 E — Close: gui-installer', 'pending', 'wave-003-gui-installer', 5, 'E', '0001', 'Close only when lifecycle tests and WHW gates are green; do not call an unsigned build a public release.')
ON CONFLICT (ref) DO UPDATE SET
  title = excluded.title, track = excluded.track, step = excluded.step,
  letter = excluded.letter, adr = excluded.adr, notes = excluded.notes,
  status = CASE WHEN todos.status = 'done' THEN todos.status ELSE excluded.status END;

DELETE FROM todo_deps WHERE ref LIKE 'wave003-%';
INSERT INTO todo_deps (ref, depends_on) VALUES
  ('wave003-B', 'wave003-A'),
  ('wave003-C', 'wave003-B'),
  ('wave003-D', 'wave003-C'),
  ('wave003-E', 'wave003-D')
ON CONFLICT DO NOTHING;

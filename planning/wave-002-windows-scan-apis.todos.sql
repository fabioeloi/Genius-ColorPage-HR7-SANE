-- Wave 002 — windows-scan-apis (ADR 0001)
-- Apply: whw sync wave-002-windows-scan-apis
-- Refs: wave002-A .. wave002-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close wave-002-windows-scan-apis`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
  ('wave002-A', 'Wave 002 A — Plan: windows-scan-apis', 'pending', 'wave-002-windows-scan-apis', 1, 'A', '0001', 'Pin the SANE service endpoint, bridge versions, WIA architecture, TWAIN x86/x64 registration, license obligations, and API test cases before implementation.'),
  ('wave002-B', 'Wave 002 B — Build: windows-scan-apis', 'pending', 'wave-002-windows-scan-apis', 2, 'B', '0001', 'Build/install saned configured for 127.0.0.1 only; adapt WiaSane for WIA and configure SANEWinDS for TWAIN x86/x64. Expose the HR7 flatbed only.'),
  ('wave002-C', 'Wave 002 C — Verify: windows-scan-apis', 'pending', 'wave-002-windows-scan-apis', 3, 'C', '0001', 'Use WIA and TWAIN API test clients to enumerate/acquire; test x86/x64 TWAIN, preview/final, color/grayscale, cancel, repeat/reconnect, nonblank physical image, and loopback bind.'),
  ('wave002-D', 'Wave 002 D — Decide: windows-scan-apis', 'pending', 'wave-002-windows-scan-apis', 4, 'D', '0001', 'Append API proof, selected bridge versions, modifications, license notices/source obligations, and unresolved compatibility limitations to ADR 0001.'),
  ('wave002-E', 'Wave 002 E — Close: windows-scan-apis', 'pending', 'wave-002-windows-scan-apis', 5, 'E', '0001', 'Close only after both APIs have real acquisition evidence, dependency notices are complete, and WHW gates are GO.')
ON CONFLICT (ref) DO UPDATE SET
  title = excluded.title, track = excluded.track, step = excluded.step,
  letter = excluded.letter, adr = excluded.adr, notes = excluded.notes,
  status = CASE WHEN todos.status = 'done' THEN todos.status ELSE excluded.status END;

DELETE FROM todo_deps WHERE ref LIKE 'wave002-%';
INSERT INTO todo_deps (ref, depends_on) VALUES
  ('wave002-B', 'wave002-A'),
  ('wave002-C', 'wave002-B'),
  ('wave002-D', 'wave002-C'),
  ('wave002-E', 'wave002-D')
ON CONFLICT DO NOTHING;

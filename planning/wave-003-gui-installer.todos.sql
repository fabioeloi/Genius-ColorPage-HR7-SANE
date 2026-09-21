-- Wave 003 — gui-installer (ADR 0001)
-- Apply: whw sync wave-003-gui-installer
-- Refs: wave003-A .. wave003-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close wave-003-gui-installer`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
  ('wave003-A', 'Wave 003 A — Plan: gui-installer', 'pending', 'wave-003-gui-installer', 1, 'A', '0001', 'Revise the migration design from the observed 1.0.0.5 Burn log: the explicit 1.0.0.4 uninstall and SANEWinDS removals were skipped by dependency protection. Embed exact signed 1.0.0.5 and 1.0.0.4 predecessors, register shared SANEWinDS packages first, remove predecessors with -burn.related.upgrade semantics, keep global related-bundle handling detect-only, then reinstall all helpers. Define rollback, repair, uninstall, and physical-scan acceptance.'),
  ('wave003-B', 'Wave 003 B — Build: gui-installer', 'pending', 'wave-003-gui-installer', 2, 'B', '0001', 'Build the private-evaluation 1.0.0.6 WiX Burn GUI bundle with hash/signature-validated 1.0.0.5 and 1.0.0.4 predecessors, ordered SANEWinDS dependency registration, related-upgrade cleanup, versioned WIA/runtime/helpers, and all embedded payloads verified. Local build evidence: WiX 5.0.2, .NET SDK 10.0.401 and Microsoft WDK 10.0.26100.6584; Inf2Cat clean; 10 attachments hash-verified; Authenticode signer 1E5EAF5313805BC85012B350720715C3B3954EA3.'),
  ('wave003-C', 'Wave 003 C — Verify: gui-installer', 'pending', 'wave-003-gui-installer', 3, 'C', '0001', 'Verify the 1.0.0.10 recovery bundle on Windows 10 and then Windows 11. Current Win10 evidence: 1.0.0.10 installed/repaired; the 1.0.0.8 bundle and older WIA driver packages removed; active WIA enumeration passes; USB 0458:2013 remains OK on WinUSB; SANE service runs. Owner-reported NAPS2 full acquisitions passed through WIA and TWAIN before cleanup; no full acquisitions were repeated after cleanup. Remaining: Win11 certificate import, install and WIA/TWAIN acquisitions, plus explicit migration, rollback, repair, uninstall, listener/firewall, and reboot validation.'),
  ('wave003-D', 'Wave 003 D — Decide: gui-installer', 'pending', 'wave-003-gui-installer', 4, 'D', '0001', 'After Win10 migration tests, append exact setup/runtime/predecessor hashes, local-evaluation certificate identity and trust limits, Burn plan/log evidence, WIA/TWAIN acquisition results, physical scan result, rollback/repair/uninstall outcome, and remaining licensing/public-signing limits to ADR 0001.'),
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

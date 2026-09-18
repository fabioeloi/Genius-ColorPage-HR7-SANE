-- Wave 004 — clean-pc-release (ADR 0001)
-- Apply: whw sync wave-004-clean-pc-release
-- Refs: wave004-A .. wave004-E (chain A→B→C→D→E)
-- Idempotent: re-syncing never downgrades `done` (runtime also preserves
-- in_progress/blocked/cancelled). Close with `whw close wave-004-clean-pc-release`.

INSERT INTO todos (ref, title, status, track, step, letter, adr, notes) VALUES
  ('wave004-A', 'Wave 004 A — Plan: clean-pc-release', 'pending', 'wave-004-clean-pc-release', 1, 'A', '0001', 'Freeze clean Win11 x64 + Win10 22H2 x64 best-effort matrix, WIA/TWAIN x86/x64 clients, hardware scan steps, release signing and licensing evidence.'),
  ('wave004-B', 'Wave 004 B — Build: clean-pc-release', 'pending', 'wave-004-clean-pc-release', 2, 'B', '0001', 'Execute clean-PC installation and real scan matrix; validate install/reboot/reconnect/rollback/removal; publish aligned English and pt-BR instructions and notices.'),
  ('wave004-C', 'Wave 004 C — Verify: clean-pc-release', 'pending', 'wave-004-clean-pc-release', 3, 'C', '0001', 'Sign final setup with owner-provided trusted Authenticode cert, verify signature/checksums, run PR/ops gates and release-readiness. Block if certificate or clean-host tests are missing.'),
  ('wave004-D', 'Wave 004 D — Decide: clean-pc-release', 'pending', 'wave-004-clean-pc-release', 4, 'D', '0001', 'Append supported OS/API results, release artifact hashes, public certificate identity only (never private key), and any remaining exceptions to ADR 0001.'),
  ('wave004-E', 'Wave 004 E — Close: clean-pc-release', 'pending', 'wave-004-clean-pc-release', 5, 'E', '0001', 'Run canonical close, program inventory, metrics, and release-readiness only after every program close criterion is proven.')
ON CONFLICT (ref) DO UPDATE SET
  title = excluded.title, track = excluded.track, step = excluded.step,
  letter = excluded.letter, adr = excluded.adr, notes = excluded.notes,
  status = CASE WHEN todos.status = 'done' THEN todos.status ELSE excluded.status END;

DELETE FROM todo_deps WHERE ref LIKE 'wave004-%';
INSERT INTO todo_deps (ref, depends_on) VALUES
  ('wave004-B', 'wave004-A'),
  ('wave004-C', 'wave004-B'),
  ('wave004-D', 'wave004-C'),
  ('wave004-E', 'wave004-D')
ON CONFLICT DO NOTHING;

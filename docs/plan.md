# Plan — Genius ColorPage-HR7 SANE

The SQL queue (`whw queue`) is authoritative for execution; this file carries intent and closed-wave history. Update it with every wave close.

## North star

Provide a signed, no-script GUI install that exposes the known-good HR7 SANE engine through WIA and TWAIN on Windows 11 x64 and best-effort Windows 10 22H2 x64. The purpose and boundaries are in [WHY.md](../WHY.md); the architecture baseline and program close criteria are in [ADR 0001](adr/0001-program-hr7-windows-deployment.md).

## Decisions

- Preserve SANE 1.4.0 Plustek and the confirmed `0458:2013` USB identity.
- Keep SANE network transport on `127.0.0.1:6566` only; WIA and TWAIN are separate app-facing sources.
- Candidate bridges are WiaSane (WIA) and SANEWinDS (TWAIN x86/x64); validate old WIA code on Win10/11 and comply with each component's license.
- Use the disclosed libwdi/Zadig-style per-device WinUSB package flow and a trusted Authenticode signature for the public setup. No signing certificate is present locally; release signing depends on the owner obtaining one.
- Apps supporting neither WIA nor TWAIN are out of scope; a dual-API app may display both sources.

## Programs

- [HR7 Windows deployment](adr/0001-program-hr7-windows-deployment.md): waves 001–004; status **in progress**.

## Wave log

### Wave 001 — api-feasibility

Documentation-first baseline. Record the current physical SANE proof and the gap between that proof and WIA/TWAIN. Audit `saned` availability/bind behavior, bridge support, license obligations, and repository hygiene. Do not claim API compatibility until a provider-level scan test exists.

| # | What | How | Why | Where | When | Who | How much |
|---|------|-----|-----|-------|------|-----|----------|
| A | Finalize purpose, constraints, architecture hypothesis, and acceptance contract | Update WHY, charter, plan, and exclusions | Prevent scope drift and false claims | WHY.md, docs/adr, docs/plan.md | 001 | Maintainer + evaluator | planning/wave-001-api-feasibility.todos.sql (wave001-A) |
| B | Audit local SANE server and candidate bridges/licenses | Inspect source/build/OS requirements; record concrete blockers and versions | Verify the bridge approach before product packaging | Windows build/runtime; SOURCES-AND-LICENSES.md | 001 | Builder | planning/wave-001-api-feasibility.todos.sql (wave001-B) |
| C | Verify WHW and repository hygiene gates | Run doctor, sync, PR gates; confirm logs/scans/tools remain ignored | Keep evidence safe and repeatable | repo root, .gitignore, .whw | 001 | Evaluator | planning/wave-001-api-feasibility.todos.sql (wave001-C) |
| D | Record evidence-backed feasibility decision | Append ADR 0001 addendum with proof and unresolved risks | Make implementation conditions explicit | docs/adr/0001-program-hr7-windows-deployment.md | 001 | Maintainer | planning/wave-001-api-feasibility.todos.sql (wave001-D) |
| E | Close baseline wave | Run WHW close and verify sync gates | Freeze the documented baseline before implementation | WHW state and wave close hook | 001 | Closer | planning/wave-001-api-feasibility.todos.sql (wave001-E) |

### Wave 002 — windows-scan-apis

Build and validate the loopback SANE service plus WIA and TWAIN sources. Implement the smallest necessary WiaSane modernization/replacement, configure SANEWinDS x86/x64, and prove enumeration and page acquisition with API test clients. No public installer claim before both API paths pass.

| # | What | How | Why | Where | When | Who | How much |
|---|------|-----|-----|-------|------|-----|----------|
| A | Plan service and provider contracts | Pin component versions, endpoint, bitness, and API test cases | Keep provider behavior consistent | Windows source/build/config | 002 | Planner | planning/wave-002-windows-scan-apis.todos.sql (wave002-A) |
| B | Implement local saned and both providers | Bind only to loopback; add WIA HR7 and TWAIN x86/x64 configuration | Make ordinary Windows scanning clients discover the HR7 | Windows source/build/config | 002 | Builder | planning/wave-002-windows-scan-apis.todos.sql (wave002-B) |
| C | Verify both API paths and physical output | Test enumeration, preview/final, grayscale/color, cancellation, reconnect, and nonblank page capture | Prove the APIs, not just SANE CLI behavior | API test clients and connected HR7 | 002 | Evaluator | planning/wave-002-windows-scan-apis.todos.sql (wave002-C) |
| D | Record API/licensing decision | Add versions, results, required notices/source, and remaining risk to ADR | Preserve reviewable evidence | docs/adr and SOURCES-AND-LICENSES.md | 002 | Maintainer | planning/wave-002-windows-scan-apis.todos.sql (wave002-D) |
| E | Close API wave | Run WHW close only with all bridge tests green | Gate installer work on working providers | WHW state and wave close hook | 002 | Closer | planning/wave-002-windows-scan-apis.todos.sql (wave002-E) |

### Wave 003 — gui-installer

Deliver one online GUI installer with the targeted WinUSB association, explicit UAC/trust consent, pinned component hashes, WIA/TWAIN configuration, rollback, repair, and uninstall. Preserve previous driver state where Windows permits. Keep diagnostic and user scan data out of the installer and repo.

| # | What | How | Why | Where | When | Who | How much |
|---|------|-----|-----|-------|------|-----|----------|
| A | Define bundle and state transitions | Specify first install, existing binding backup, repair, upgrade, rollback, and uninstall | Avoid destructive or ambiguous device changes | Windows installer design | 003 | Planner | planning/wave-003-gui-installer.todos.sql (wave003-A) |
| B | Build the WiX Burn GUI package | Download pinned components, verify hashes/signatures, configure services/providers, and offer repair/removal | Remove end-user command-line/Zadig steps | Windows installer project | 003 | Builder | planning/wave-003-gui-installer.todos.sql (wave003-B) |
| C | Verify install lifecycle and security boundary | Test fresh/repeat/failure/uninstall; inspect driver binding, cert consent, service account, listener, and firewall | Ensure setup is safe and reversible | disposable Windows test host | 003 | Evaluator | planning/wave-003-gui-installer.todos.sql (wave003-C) |
| D | Record installer and signing status | Add hashes, signing model, rollback results, and external certificate dependency | Prevent unsigned artifacts from being presented as release-ready | docs/adr and manifest.json | 003 | Maintainer | planning/wave-003-gui-installer.todos.sql (wave003-D) |
| E | Close installer wave | Run WHW close after lifecycle tests and PR gates are green | Freeze the install contract before clean-PC release tests | WHW state and wave close hook | 003 | Closer | planning/wave-003-gui-installer.todos.sql (wave003-E) |

### Wave 004 — clean-pc-release

Test clean Windows 11 x64 and best-effort Windows 10 22H2 x64, x86/x64 TWAIN clients, WIA clients, full physical scan flows, rollback, and reboot. Publish only after owner-provided Authenticode signing credentials are used to sign the setup and all license/source obligations are met. If the certificate or required tests are unavailable, block release rather than close the wave.

| # | What | How | Why | Where | When | Who | How much |
|---|------|-----|-----|-------|------|-----|----------|
| A | Prepare clean-machine release matrix | Freeze supported OS/API/client/scan cases and test artifacts | Make the release claim auditable | docs and test scripts | 004 | Planner | planning/wave-004-clean-pc-release.todos.sql (wave004-A) |
| B | Run full clean-PC and hardware acceptance | Install without shell/Zadig interaction; exercise both APIs, bitness, image modes, mechanics, recovery, and removal | Validate actual end-user outcome | clean Win11 + Win10 x64 hosts | 004 | Builder | planning/wave-004-clean-pc-release.todos.sql (wave004-B) |
| C | Verify signed release and evidence gates | Sign setup with trusted cert, verify signature/checksums, run PR + ops gates, complete license/source bundle | Ensure public release is trustworthy and compliant | release artifact + WHW checkpoints | 004 | Evaluator | planning/wave-004-clean-pc-release.todos.sql (wave004-C) |
| D | Record release decision and exceptions | Append evidence, certificate identity (never key), OS results, and support caveats | Leave a durable release record | docs/adr and release notes | 004 | Maintainer | planning/wave-004-clean-pc-release.todos.sql (wave004-D) |
| E | Close the program | Run final close, inventory, metrics, and release-readiness gate | Ship only a fully proven end-user package | WHW state and release artifacts | 004 | Closer | planning/wave-004-clean-pc-release.todos.sql (wave004-E) |

## Next

Complete the Wave 001 documentation/feasibility checks, then begin bridge implementation only after its decision and gates record the conditions above.

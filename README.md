# Genius ColorPage-HR7 SANE

An open SANE-based scanning path for the Genius ColorPage-HR7 (`0458:2013`). The scanner's Plustek backend is pinned to SANE 1.4.0. This package also contains the existing macOS route; its behavior is outside the current Windows deployment change.

## Windows deployment status

The current Windows package is still an evaluation/developer setup and requires manual driver binding. `Windows/Configure-WindowsProviders.ps1` configures the installed SANEWinDS x86/x64 TWAIN sources behind the loopback service. Client-level TWAIN acquisition is now verified in both bitnesses for Gray preview using native and memory transfer, and x64 Color full-page native transfer. No verified WIA provider is included, so WIA-only applications still cannot discover the HR7. The package therefore does not meet the end-user deployment goal. The WHW program charter in `docs/adr/` tracks the remaining WIA/API evidence and the replacement of the script/Zadig flow with one signed GUI installer.

The target is Windows 11 x64, with Windows 10 22H2 x64 as best-effort legacy coverage. The eventual package will support applications that use WIA and/or TWAIN; it cannot promise compatibility with software that supports neither API.

Until the GUI installer is released, use the existing platform-specific instructions in [README.pt-BR.md](README.pt-BR.md) only for controlled testing. Do not distribute the current manual package as the planned no-scripts end-user installer.

## Development harness

This repository uses [WHW](https://github.com/fabioeloi/WHW) for intent, decisions, wave planning, evidence, and gates. See `WHY.md`, `docs/plan.md`, `docs/adr/`, and `planning/`. Device scans, diagnostic logs, build outputs, and signing keys are excluded from version control.

## Sources and licenses

See [SOURCES-AND-LICENSES.md](SOURCES-AND-LICENSES.md) and `manifest.json` for component versions, hashes, origins, and license notices.

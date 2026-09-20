# Genius ColorPage-HR7 SANE

An open SANE-based scanning path for the Genius ColorPage-HR7 (`0458:2013`). The scanner's Plustek backend is pinned to SANE 1.4.0. This package also contains the existing macOS route; its behavior is outside the current Windows deployment change.

## Windows deployment status

The currently installed Windows package remains an evaluation/developer setup and requires manual driver binding. `Windows/Configure-WindowsProviders.ps1` configures the installed SANEWinDS x86/x64 TWAIN sources behind the loopback service. Client-level TWAIN acquisition is verified in both bitnesses for Gray preview using native and memory transfer, and x64 Color full-page native transfer. The owner reports that NAPS2 listed the scanner and completed a full scan with the signed 1.0.0.4 setup, but the acquisition API was not recorded. A new 1.0.0.5 migration bundle and WIA minidriver have now compiled on Windows 10; that candidate has not yet been installed or scan-tested, and its private evaluation signer is not trusted by Windows yet. WIA enumeration is still absent after the installed 1.0.0.4 full bundle, so WIA-only compatibility is not established. The project does not yet meet the end-user deployment goal. See [the installer status](Windows/Installer/README.md) and the WHW program charter in `docs/adr/` for migration, signing, WIA, licensing, and clean-host test gates.

The target is Windows 11 x64, with Windows 10 22H2 x64 as best-effort legacy coverage. The eventual package will support applications that use WIA and/or TWAIN; it cannot promise compatibility with software that supports neither API.

Until the GUI installer is released, use the existing platform-specific instructions in [README.pt-BR.md](README.pt-BR.md) only for controlled testing. Do not distribute the current manual package as the planned no-scripts end-user installer.

## Development harness

This repository uses [WHW](https://github.com/fabioeloi/WHW) for intent, decisions, wave planning, evidence, and gates. See `WHY.md`, `docs/plan.md`, `docs/adr/`, and `planning/`. Device scans, diagnostic logs, build outputs, and signing keys are excluded from version control.

[FORGE](https://github.com/fabioeloi/FORGE) is referenced only as an example of a separate public project; this repository is not generated from it and does not use its files or history as a template or dependency.

## Sources and licenses

See [SOURCES-AND-LICENSES.md](SOURCES-AND-LICENSES.md) and `manifest.json` for component versions, hashes, origins, and license notices.

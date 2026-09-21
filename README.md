# Genius ColorPage-HR7 SANE

An open SANE-based scanning path for the Genius ColorPage-HR7 (`0458:2013`). The scanner's Plustek backend is pinned to SANE 1.4.0. This package also contains the existing macOS route; its behavior is outside the current Windows deployment change.

## Windows deployment status

The Windows 10 test host now has the private-evaluation 1.0.0.10 bundle installed. The owner reported successful full acquisitions through both WIA and TWAIN in NAPS2 before cleanup. The 1.0.0.8 bundle was then removed, 1.0.0.10 repaired, and older staged WIA driver packages removed. Post-cleanup checks show WIA enumeration passing, the physical USB device still OK on WinUSB, and the SANE service running; full acquisitions were not repeated after cleanup. Windows 11 installation and acquisition tests remain pending. The evaluation signer is locally trusted only and the package is not approved for public distribution. See [the installer status](Windows/Installer/README.md) and the WHW program charter in `docs/adr/` for migration, signing, WIA, licensing, and clean-host test gates.

The target is Windows 11 x64, with Windows 10 22H2 x64 as best-effort legacy coverage. The eventual package will support applications that use WIA and/or TWAIN; it cannot promise compatibility with software that supports neither API.

Until the GUI installer is released, use the existing platform-specific instructions in [README.pt-BR.md](README.pt-BR.md) only for controlled testing. Do not distribute the current manual package as the planned no-scripts end-user installer.

## Development harness

This repository uses [WHW](https://github.com/fabioeloi/WHW) for intent, decisions, wave planning, evidence, and gates. See `WHY.md`, `docs/plan.md`, `docs/adr/`, and `planning/`. Device scans, diagnostic logs, build outputs, and signing keys are excluded from version control.

[FORGE](https://github.com/fabioeloi/FORGE) is referenced only as an example of a separate public project; this repository is not generated from it and does not use its files or history as a template or dependency.

## Sources and licenses

See [SOURCES-AND-LICENSES.md](SOURCES-AND-LICENSES.md) and `manifest.json` for component versions, hashes, origins, and license notices.

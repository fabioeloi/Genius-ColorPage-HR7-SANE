# ADR 0001 — Program: hr7-windows-deployment

<!-- whw:program slug="hr7-windows-deployment" waves="001-004" -->

- **Status:** Proposed
- **Date:** 2026-09-18
- **Waves:** 001–004 (4 waves)
- **Related:** WHY.md

> Keep the `whw:program` marker intact — `whw gate run program-inventory`
> reads it. There is **no wave 005** in this program: extension requires
> a new charter ADR.

## Context

The HR7 now scans physically through the package's SANE 1.4.0 Plustek backend, but the Windows route is still developer-oriented: it requires PowerShell, a separate Zadig interaction, and XSane. WIA/TWAIN applications cannot currently discover it. This program closes only when an ordinary end user can install a signed GUI package and scan from both Windows acquisition APIs on a clean PC.

### Architecture baseline

| Boundary | Decision |
| --- | --- |
| Scanner engine | Preserve SANE 1.4.0 with only the Plustek backend and HR7 USB ID `0458:2013`. |
| Bridge transport | Use the SANE network protocol on `127.0.0.1:6566` only; confirm the built `saned` supports this bind mode before shipping. |
| WIA | Start from WiaSane; update or replace only as needed to pass supported Windows/API tests. |
| TWAIN | Start from SANEWinDS with x86 and x64 data sources; configure its SANE host as loopback. |
| Driver association | Integrate the libwdi/Zadig-style, per-install device-specific signed WinUSB package. Explain the trust operation and require elevation/consent. |
| Delivery | One online WiX Burn GUI installer; component versions and hashes pinned; setup Authenticode-signed before public release. |
| Network | No scanner listener beyond loopback; do not create firewall openings. |

The existing physical test demonstrates the SANE engine and mechanics, not WIA/TWAIN compatibility. Wave 001 records that distinction; API enumeration and real scans remain release gates.

## Explicit exclusions

Deferred fronts stay OUT until a new ADR reopens them:

| Front | Reason | Revisit in |
| ----- | ------ | ---------- |
| Genius proprietary driver/application | No redistribution rights and incompatible generation | Not in this program |
| Literal compatibility with every scanner app | Software that does not implement WIA/TWAIN cannot use these providers | Not in this program |
| macOS behavior changes | Existing macOS path is outside the Windows deployment objective | New ADR if needed |
| Other scanner IDs, 32-bit Windows, ADF/duplex | Not the tested HR7 x64 flatbed target | New program/ADR |
| Offline installer or Windows Update driver publication | Online bundle is accepted; device-specific libwdi package is the selected binding method | New ADR if required |

## Wave map

| Wave | Slug | ADR |
| ---- | ---- | --- |
| 001 | api-feasibility | 0001 |
| 002 | windows-scan-apis | 0001 |
| 003 | gui-installer | 0001 |
| 004 | clean-pc-release | 0001 |

Fill slugs and thematic ADRs as waves are chartered (`whw wave new <slug>
--adr NNNN`). Numbers are global and sequential.

## Execution

- One wave = PRs A–E (plan → build → verify → decide → close); a wave is done
  only when **E** merges.
- First wave is documentation-first: charter finalization + planning seeds.
- Final wave is the program close: inventory gate + retrospective addendum.
- Do not start the next wave until `main` is green.
- Branch/commit conventions: `docs/how/conventions.md`.

## Close criteria

- [ ] All four waves closed via `whw close`; no wave may be marked done without reproducible evidence.
- [ ] Clean Windows 11 x64 and best-effort Windows 10 22H2 x64 tests pass, including WIA and x86/x64 TWAIN acquisition.
- [ ] GUI install, repair, rollback, uninstall, loopback-only listener, and prior-driver restoration are tested.
- [ ] Release EXE is signed with a trusted Authenticode certificate; certificate acquisition is an external owner prerequisite and its private key is never checked in.
- [ ] Required third-party license/source notices and hashes are published; `program-inventory`, evidence-quality, and release-readiness gates are GO.
- [ ] `whw metrics --out .whw/metrics.json` recorded and linked below.

## References

- `WHY.md`, `README.md`, `README.pt-BR.md`, and `manifest.json`.
- WiaSane: https://github.com/mback2k/wiasane
- SANEWinDS: https://sourceforge.net/projects/sanewinds/
- libwdi certificate model: https://github.com/pbatard/libwdi/wiki/Certification-Practice-Statement
- Microsoft WIA: https://learn.microsoft.com/en-us/previous-versions/windows/desktop/wia/-wia-startpage

<!-- Addenda: append `## Addendum Wave NNN — <topic>` per wave D, newest last. -->

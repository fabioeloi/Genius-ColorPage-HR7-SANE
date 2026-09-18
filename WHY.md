# WHY — Genius ColorPage-HR7 SANE

> Created 2026-09-18. This project's work is bounded to the scanner and outcomes below.

## Purpose

Give owners of the Genius ColorPage-HR7 a maintainable, open scanning path on current Windows PCs. An end user should be able to install one trustworthy GUI package, connect the scanner, and scan from ordinary applications that use Windows Image Acquisition (WIA) or TWAIN—without opening PowerShell, Zadig, or a command-line scanner tool.

The known device is USB `0458:2013`. The existing SANE 1.4.0 Plustek backend and the user's successful physical Windows scan are the starting point, not an excuse to skip clean-machine and API-level validation.

## Non-goals

- Claim compatibility with every application; only WIA- and/or TWAIN-capable software is in scope.
- Recreate or redistribute Genius's proprietary legacy driver or its application.
- Support other scanner models, non-x64 Windows, or Windows releases earlier than Windows 10 22H2.
- Expose the local SANE service to the LAN or cloud.
- Replace the existing macOS path as part of the Windows deployment program.

## Principles

- Preserve the known-good SANE backend and scope USB binding strictly to `USB\\VID_0458&PID_2013`.
- Make trust and elevation explicit: sign the installer, explain the libwdi-style device-specific certificate operation, and require administrator approval.
- Pin and verify downloaded components; retain source/license notices for every redistributed bridge.
- Keep WIA and TWAIN as distinct, discoverable sources and test both application bitnesses where applicable.
- Preserve prior driver state for rollback/uninstall where Windows permits; never silently guess or overwrite unrelated device bindings.
- Keep private scans, diagnostic transcripts, generated packages, and signing secrets out of the repository.
- Keep English and Brazilian Portuguese end-user documentation aligned.

## Success looks like

- A signed, online GUI installer works on a clean Windows 11 x64 PC and best-effort Windows 10 22H2 x64; an end user needs only internet access and normal administrator approval.
- The scanner is enumerated through WIA and TWAIN; x86 and x64 TWAIN applications can acquire from it.
- Preview, color/grayscale final scan, cancel, repeat, reconnect, reboot, repair, rollback, and uninstall behavior are validated.
- A real page is captured without blank/noisy output; carriage travel and return remain smooth.
- The SANE listener is loopback-only, existing user data is preserved, and release artifacts carry verifiable signatures, hashes, and licensing information.

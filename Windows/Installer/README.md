# Windows GUI installer source

This directory contains the source for a WiX Burn GUI bundle. The planned
end-user flow is one signed `GeniusColorPageHR7Setup.exe`; users do not run
PowerShell, Zadig, or separate driver utilities. It installs the private SANE
runtime/service, SANEWinDS TWAIN sources for x86 and x64 applications, and the
WIA 2.0 software-device package. Apps that support neither WIA nor TWAIN are
outside the compatibility scope.

The bundle is self-contained: the runtime MSI and both pinned SANEWinDS MSIs
are embedded in the setup EXE, so end-user installation does not need GitHub or
SourceForge access. Maintainer builds take the SANEWinDS packages from the
hash-checked `.tools/downloads` cache (or fetch the pinned HTTPS URLs when the
cache is absent). The upstream x86 MSI omits its platform in Template Summary;
the build changes only the staged copy to `Intel;1033`, assigns it a stable new
PackageCode, and records the original and packaged hashes in
`release-artifacts.json`.

WinUSB is changed only for USB `0458:2013`. If that device already uses
WinUSB, setup records that existing binding as unowned and leaves it alone.
Otherwise the helper asks before making the device-specific libwdi change;
Windows may also ask the user to trust its generated driver package. That
certificate may remain in Windows trust stores after uninstall because it can
be shared with another libwdi-installed device. TWAIN settings are backed up
per profile and in ProgramData; uninstall restores an untouched original but
keeps later user edits alongside the hidden backup.

## Build inputs

`Build-GuiInstaller.ps1` is maintainer tooling only. A build host needs:

- Visual Studio C++ build tools and a Windows SDK/WDK that provide MSBuild,
  WIA headers/libraries, `Inf2Cat.exe`, and `SignTool.exe`.
- WiX Toolset 5.0.2 (`wix.exe` and the matching SDK packages).
- A current Authenticode code-signing certificate with its private key.
- A trimmed, redistributable SANE/Cygwin runtime tree supplied as
  `RuntimeRoot`; it must contain the service binaries/configuration and no
  compiler, development headers, import/static libraries, or debug artifacts.
- A libwdi 1.5.1 x64 source/build tree supplied as `LibwdiRoot`.
- A compliance directory supplied as `ComplianceRoot`. For a public build it
  must contain `RELEASE-APPROVED.txt`, the reviewed third-party notices, and
  the complete source/offer materials required for redistribution.

Example maintainer invocation:

```powershell
./Windows/Installer/Build-GuiInstaller.ps1 `
  -RuntimeRoot 'C:\staging\hr7-runtime' `
  -LibwdiRoot 'C:\staging\libwdi-1.5.1' `
  -ComplianceRoot 'C:\staging\hr7-compliance' `
  -SigningCertificateThumbprint 'REPLACE_WITH_40_HEX_DIGIT_THUMBPRINT'
```

Private evaluation builds may omit the approval file only with
`-AllowUnreleasedEvaluationBuild`; that output is explicitly marked evaluation
only. The current source pins helper metadata and the WIA INF to version
`1.0.0.4`. Build outputs and intermediate files stay under the ignored
`Windows/build/` directory. Each run gets a unique `release-1.0.0.4-<build-id>`
and matching staging directory so failed or prior builds are preserved rather
than overwritten. The `release-artifacts.json` file records output hashes; it
is evidence, not a substitute for clean-host installation tests.

## Validation status

On 2026-09-20, the installed private-evaluation bundle was repaired successfully.
The physical USB device remains `OK` on its pre-existing WinUSB binding, the
pre-existing loopback SANE service is running, and WIA enumeration finds the
virtual scanner. SANE protocol open read all 45 option descriptors without a
scan. TWAIN `MSG_OPENDS` passed from both x64 and x86 PowerShell, but neither
architecture had passed an acquisition test at that point. Both have since
passed a 75-DPI, 150 x 150 grayscale memory transfer with nonblank image data:
x64 returned 22,800 bytes with 22,799 nonblank; x86 returned 22,800 bytes with
22,797 nonblank.

The first 75-DPI WIA transfer failed with `0x8007000D`. The WIA trace showed a
full-page selection of 637 pixels at 75 DPI, while the sample-derived WIA
capability claimed an 8500-thousandth-inch bed (8.5 inches). That request is
about 215.9 mm wide, but the Plustek backend reports a 215 mm maximum. The bridge
therefore rejected the backend's normal clamp (over its 0.25 mm tolerance)
before starting image acquisition. The WIA bed capability has now been changed
to 8464 x 11692 thousandths of an inch, conservatively representing the
backend's 215 x 297 mm area.

The rebuilt private-evaluation setup is
`Windows/build/release-1.0.0.1-wia-geometry-7716b23135f346d5b5d280217159e64a/`.
It compiled the helpers, x64 WIA provider, runtime MSI, and self-contained Burn
setup. Inf2Cat reported no errors or warnings, WiX completed without warnings,
the setup contains all eight staged payloads byte-for-byte, and Authenticode
verification passed with the local evaluation signer
(`4E086470415F86AEAB2B55B06D5190B49C9ED2B7`). The setup SHA-256 is
`768E608780BB541C5B7D625D8643606C545BD23B186C37E21503B12035730FA9`.
The public certificate is trusted only in this machine's LocalMachine Root and
TrustedPublisher stores; this is not Microsoft certification or public Windows
trust.

The first elevated WIA-only update was rejected because both staged and
installed packages identified as `1.0.0.1` (helper exit 31). The follow-up
`1.0.0.2` driver update installed successfully as `oem89.inf`; Windows now
reports version `1.0.0.2` and WIA enumeration passes. The physical USB device
remains `OK` on WinUSB, and the loopback SANE service remains running.

The post-update 75-DPI grayscale WIA acquisition reached the real SANE scan but
failed after about 68 seconds with `0x8007000D`. Diagnostic driver version
`1.0.0.3` identified the failure as image data exceeding the size declared by
the SANE frame parameters (`0x80040708`). The [SANE network protocol](https://sane-project.gitlab.io/standard/net.html) permits
zero-length data records; WINSANE's receive loop treated such a record as a
128-KB chunk because it returned without clearing the caller's output length.
The receive loop now reports zero bytes for zero-length records, and the
diagnostic HRESULTs have been removed. The signed `1.0.0.4` setup is
`Windows/build/release-1.0.0.4-8628048d3c3043749442a84f8fb727cf/` with SHA-256
`97EA116EA5063EF2C23188440D07C87890D7F53372F3A8C0C5EDF194CD683E8C`. The
WIA-only update installed as `oem92.inf`; the device is `OK` and WIA enumeration
passes. The next 75-DPI grayscale WIA transfer completed successfully and saved
a 633 x 875 BMP (1,662,554 bytes) with 12,709 sampled non-white pixels.

The first post-fix smoke-test run reached image verification but its test script
had not loaded `System.Drawing`; that harness issue is fixed by explicitly
loading the assembly. The saved image was then validated directly with the same
pixel-sampling check.

The known full-bundle upgrade cleanup issue remains unresolved: a prior Burn
upgrade removed packages installed by its replacement. To protect the now
working local setup, version `1.0.0.4` was applied WIA-only; its full Burn bundle
was not installed. Before Windows 11 deployment, validate full-bundle clean
install, upgrade, repair, and uninstall on a disposable Windows 10 test host.
Public distribution still needs third-party redistribution review and a signing
path accepted by arbitrary Windows machines.

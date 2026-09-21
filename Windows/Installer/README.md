# Windows GUI installer source

This directory contains the source for a WiX Burn GUI bundle. The planned
end-user flow is one signed `GeniusColorPageHR7Setup.exe`; users do not run
PowerShell, Zadig, or separate driver utilities. It installs the private SANE
runtime/service, SANEWinDS TWAIN sources for x86 and x64 applications, and the
WIA 2.0 software-device package. Apps that support neither WIA nor TWAIN are
outside the compatibility scope.

The bundle is self-contained: the runtime MSI, both pinned SANEWinDS MSIs, and
the exact supported predecessor bundles are embedded in the setup EXE, so
end-user installation does not need GitHub or SourceForge access. Maintainer
builds take the SANEWinDS packages from the hash-checked `.tools/downloads`
cache (or fetch the pinned HTTPS URLs when the cache is absent). The upstream
x86 MSI omits its platform in Template Summary; the build changes only the
staged copy to `Intel;1033`, assigns it a stable new PackageCode, and records
the original and packaged hashes in `release-artifacts.json`.

The 1.0.0.8 Windows 10 migration attempt exposed a cleanup-order bug. Its log
shows that removing 1.0.0.6 first removed the shared runtime directory and WIA
INF; the subsequent 1.0.0.5 uninstaller then failed with `ERROR_INVALID_NAME`
while trying to remove its WIA package. Burn rolled back the predecessor
uninstalls. The WinUSB binding helper itself returned success, and the physical
scanner remained on WinUSB.

The 1.0.0.10 recovery chain registers the SANEWinDS dependencies, installs the
current runtime MSI so a valid WIA INF remains at the shared path, then
re-stages the current WIA driver before each pinned 1.0.0.6, 1.0.0.5, 1.0.0.4,
and 1.0.0.7 cleanup bundle (with .7 last). This matters because each historical
uninstaller can remove the staged WIA package. It reinstalls the current
WinUSB, service, TWAIN, and WIA helpers after all cleanup. The partial 1.0.0.8
bundle is detected to force that helper refresh, but is not
recursively uninstalled; this avoids re-entering its own failing migration
chain and keeps the offline installer from embedding another 734 MB setup.
Predecessor hashes/signers are pinned and checked against their release
manifests before staging. The runtime MSI and WIA helper/INF advance to 1.0.10
and 1.0.0.10, respectively.

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
- The exact signed 1.0.0.6, 1.0.0.5, 1.0.0.4, and 1.0.0.7 bundles with their
  adjacent release manifests, as `PreviousBundlePath`, `IntermediateBundlePath`,
  `LegacyBundlePath`, and `StrandedBundlePath`.
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
  -SigningCertificateThumbprint 'REPLACE_WITH_40_HEX_DIGIT_THUMBPRINT' `
  -RuntimeMsiVersion '1.0.10' `
  -PreviousBundlePath 'C:\staging\release-1.0.0.6\GeniusColorPageHR7Setup.exe' `
  -IntermediateBundlePath 'C:\staging\release-1.0.0.5\GeniusColorPageHR7Setup.exe' `
  -LegacyBundlePath 'C:\staging\release-1.0.0.4\GeniusColorPageHR7Setup.exe' `
  -StrandedBundlePath 'C:\staging\release-1.0.0.7\GeniusColorPageHR7Setup.exe'
```

Private evaluation builds may omit the approval file only with
`-AllowUnreleasedEvaluationBuild`; that output is explicitly marked evaluation
only. The recovery source pins the bundle and WIA helper/INF to `1.0.0.10`,
the runtime MSI to `1.0.10`, and predecessor inputs to the signed `1.0.0.6`,
`1.0.0.5`, `1.0.0.4`, and `1.0.0.7` artifacts. Build outputs and intermediate files stay under the ignored
`Windows/build/` directory. Each run gets unique output, native-helper, WIA,
WiX, and staged-libwdi paths so previous files are preserved rather than
overwritten. The `release-artifacts.json` file records all Burn attachment
hashes, predecessor provenance, and an exported public signing-certificate
sidecar. That `.cer` contains no private key. On each evaluation PC that must
validate or run this private build (the Windows 10 build/test PC first, then
the Windows 11 target), import it through the Certificates MMC snap-in into
**Local Computer** > **Trusted Root Certification Authorities** and
**Trusted Publishers** before rebuilding or running setup. This creates trust
on that PC only; it is not Microsoft signing or public Windows trust. Never
distribute the signing private key.

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

The owner subsequently installed the full signed 1.0.0.4 Burn setup; NAPS2
listed the scanner and a full scan completed with smooth carriage travel and
return. The exact NAPS2 acquisition API was not recorded. Separately, the
TWAIN API test clients enumerate and acquire through both x86 and x64 sources,
while `Windows/Test-WiaEnumeration.ps1` currently finds no WIA device after the
full-bundle installation. This is consistent with the observed Burn defect:
the prior related-bundle uninstall ran after the new chain and removed the WIA
helper registration. Do not treat the NAPS2 result as WIA-specific evidence.

The 1.0.0.5 local-evaluation setup was installed on Windows 10. The device
remains OK on WinUSB, the loopback SANE service is running, and the WIA software
device enumerates. However, both the 1.0.0.4 and 1.0.0.5 bundles remain in
Programs and Features: Burn's log shows the ordinary predecessor uninstall was
blocked by dependency protection.

The replacement private-evaluation setup is
`Windows/build/release-1.0.0.6-66b3f3d9f5744b66ae65c0c4a684deca/`. It is
183,862,624 bytes with SHA-256
`59475398154caf87c3767b0a2c692f6a2e23e62fdf4d98dbe2bb353306571e62`, and its
Authenticode signature validates under the locally trusted signer
(`1E5EAF5313805BC85012B350720715C3B3954EA3`). MSBuild compiled the helpers and
WIA provider, Inf2Cat reported no errors or warnings, WiX 5.0.2 completed with
zero warnings/errors, and Burn extraction verified all 10 attachment hashes.
The manifest pins both predecessors: 1.0.0.5
(`2af78e0ee8c9be8102e24dbf0a1193a1c3007ea79c0aedfa41417941914d15fb`) and
1.0.0.4
(`97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c`). The
WDK NuGet tool package used for Inf2Cat passed NuGet author/repository
signature verification.

The 1.0.0.6 machine-wide install attempt stopped at UAC and was canceled before
setup launched; no Burn log was created and no driver/package state changed.
The certificate is trusted on this test PC in Local Machine Root and Trusted
Publishers, but this is local evaluation trust only. After administrator
consent, verify migration order and dependency preservation, WIA enumeration
and acquisition, TWAIN x86/x64, a full physical scan, repair, rollback,
uninstall, and loopback-only service before Windows 11 deployment. Public
distribution still needs third-party redistribution review and a signing path
accepted by arbitrary Windows machines.

## Windows 10 cleanup and repair check (2026-09-21)

After the owner reported 100% WIA/TWAIN acquisition success through NAPS2 on
1.0.0.10, the remaining 1.0.0.8 bundle was removed from the Windows 10 test
machine. Its first uninstall attempt had stopped because 1.0.0.10 had already
removed the shared WIA INF. Restoring 1.0.0.10 then briefly rolled back: the
SetupAPI log says the active 1.0.0.10 WIA driver was not better than the
specified same-version package (`ERROR_NO_MORE_ITEMS`), while Burn recorded
helper exit 31. This is a maintenance edge case when the partial 1.0.0.8
registration forces the WIA helper to run again; it is not evidence of a USB
binding or scanner hardware failure.

With the 1.0.0.10 INF present, the signed cached 1.0.0.8 uninstaller completed
with exit 0. Its helper cleanup removed the old bundle registration and the
shared WIA/TWAIN/service helper markers. The physical `0458:2013` scanner
remained `OK` on its pre-existing, unowned WinUSB binding (`oem91.inf`). Repair
of the registered 1.0.0.10 bundle completed with exit 0 and restored the WIA
device. Post-repair checks show: 1.0.0.8 absent from Programs and Features;
1.0.0.10 and its runtime registered; WIA.DeviceManager enumerates `Genius
ColorPage-HR7 (WIA 2.0)`; the loopback SANE service is running; and the physical
USB binding remains WinUSB. The TWAIN enumeration harness printed `PASS` but
hung while closing the DSM; it did not scan. No post-repair acquisition was run,
so the NAPS2 acquisition result above is owner-reported evidence from before
this cleanup/repair sequence.

An elevated, non-forced PnPUtil cleanup then removed the five older WIA
packages `oem88.inf`, `oem89.inf`, `oem90.inf`, `oem92.inf`, and `oem97.inf`
(versions 1.0.0.1/.2/.3/.5/.9). Only the active `oem98.inf` 1.0.0.10 WIA
package remains staged. Afterward, WIA enumeration passed, the physical scanner
remained `OK` on WinUSB `oem91.inf`, and the SANE service remained running. No
`/force` was used, and no WIA/TWAIN acquisition was repeated after this cleanup.

The Windows 11 test remains pending. Transfer the signed setup and its
evaluation `.cer` sidecar to that PC, trust the certificate there in Local
Computer Root and Trusted Publishers, then run NAPS2 WIA and TWAIN acquisitions.
The certificate is local evaluation trust only; this bundle is not approved
for public distribution.

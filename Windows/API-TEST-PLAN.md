# Windows scan API contract and test matrix

This matrix is the entry contract for Wave 002. A provider is not considered
working because its files are installed; each row needs a client-level result
on a connected HR7.

## Fixed transport and device

- SANE engine: 1.4.0, Plustek only, USB `VID_0458&PID_2013`.
- Local daemon: `GeniusColorPage-HR7-SANE`, `127.0.0.1:6566` only; no firewall
  rule and no LAN address.
- SANEWinDS host: `NameOrAddress=127.0.0.1`, `Port=6566`,
  `AutoLocateDevice=plustek`; template: `config/SANEWinDS.ini`.
- The API tests must not select a second scanner or silently fall back to a
  network host.

## Provider contracts

| Provider | Client bitness | Enumeration contract | Acquisition contract |
| --- | --- | --- | --- |
| TWAIN / SANEWinDS 1.6.9221 | x86 | A TWAIN 2.x-capable x86 client lists `SANEWinDS` and opens its data source. | Query identity/capabilities, acquire a small preview, acquire a full page in Gray and Color, cancel once, then reconnect. |
| TWAIN / SANEWinDS 1.6.9221 | x64 | A TWAIN 2.x-capable x64 client lists `SANEWinDS` from `twain_64`. | Run the same capability, preview, full-page, cancel, and reconnect cases. |
| WIA / WiaSane candidate | x64 | `WIA.DeviceManager.DeviceInfos` contains the HR7 provider and selecting it succeeds. | Enumerate `Items`, transfer a preview and a full page, exercise Gray/Color, cancel, and reconnect. |

For every successful acquisition, the test records provider name, bitness,
mode, resolution, elapsed time, status code, image dimensions, and a
nonblank-pixel check. Test pages and logs stay outside Git. A failed case must
record whether the failure occurred in provider enumeration, SANE transport,
USB access, acquisition, cancellation, or cleanup.

## Ordered preflight

1. Confirm the service is `Running` and exactly one listener is
   `127.0.0.1:6566`.
2. Run `scanimage -L` and `scanimage -A` against the private runtime; these
   are enumeration/open checks and must not acquire a page.
3. Confirm the scanner is fully assembled, unlocked, and has a disposable test
   page face down. Stop immediately if the carriage grinds or vibrates.
4. Run x86 TWAIN cases, then x64 TWAIN cases, then WIA cases. Between providers
   disconnect/reconnect the scanner and repeat enumeration.
5. Remove only the temporary test files and preserve the service/driver state
   for the next case.

## Release gates

- No WIA/TWAIN claim until both bitness-specific TWAIN cases and the WIA cases
  have client-level enumeration and image evidence.
- No public installer until the providers are configured by the GUI package,
  all redistributed binaries have pinned hashes and source/notices, and the
  setup itself has a trusted Authenticode signature.
- WiaSane remains a blocked candidate until a binary or reproducible build can
  be retrieved over valid TLS and tested on Windows 10 and Windows 11.

The checked-in `Test-SaneProtocol.ps1` uses the SANEWinDS assembly itself to
run `Net_Init` and `Net_Get_Devices` against the loopback service. It is a
transport/provider preflight; it does not substitute for a TWAIN DSM client
or a WIA COM acquisition test.

`Test-TwainEnumeration.ps1` calls the installed x64 or x86 TWAIN DSM and
enumerates `SANEWinDS`; both bitnesses returned the data source identity.
`Test-TwainOpen.ps1` then opened that source through `DAT_IDENTITY/MSG_OPENDS`
on both bitnesses; its bounded client passes after marshalling the source
identity through an allocated TWAIN data block. Source opening is therefore
verified, but capability exchange, acquisition, cancellation, and reconnect
are still separate gates.

The bounded `Test-SaneOpen.ps1` probe now completes the SANE protocol open path
for both x64 and x86 SANEWinDS: `Net_Open` returned `SANE_STATUS_GOOD`, 45
option descriptors were read, and the handle was closed without acquiring an
image. A temporary loopback trace also confirmed the expected
`INIT → GET_DEVICES → OPEN → GET_OPTION_DESCRIPTORS → CLOSE → EXIT` exchange.
This proves the SANE transport/provider preflight; it does not substitute for
acquiring an image through a TWAIN or WIA client.

`Configure-WindowsProviders.ps1` is the shared elevated provider-configuration
action for the eventual GUI package. It verifies the HR7 WinUSB association,
the running loopback service, and the single `127.0.0.1:6566` listener before
configuring both SANEWinDS TWAIN data sources and recording provider state.
`-InstallTwainPackages` is intentionally explicit; the evaluated SANEWinDS
MSIs are unsigned and must not be silently promoted to release artifacts.

`Test-SaneAcquire.ps1` now exercises the installed SANEWinDS protocol assembly
against the loopback service, including `Net_Start` and frame acquisition. It
passed with and without a pre-start `Net_Get_Parameters` query: one 202x150 RGB
frame, 90,900 bytes, with nonblank pixels. A direct local `scanimage` test also
passed at 75 dpi grayscale, producing a nonblank 295x221 TIFF (65,417 bytes).

After the user restarted the service, `sane-find-scanner -q` saw the HR7 at
`libusb:002:006`, `scanimage -L` listed it, and `Test-SaneOpen.ps1` opened it
and read 45 descriptors. `Test-TwainOpen.ps1` opened `SANEWinDS` through both
the x86 and x64 TWAIN DSMs. The service is currently running with its listener
bound only to `127.0.0.1:6566`.

`Test-TwainAcquire.ps1` was corrected to use `DAT_IMAGENATIVEXFER` (`0x0104`),
read native transfers as DIB blocks, marshal integer `TW_FIX32` resolution
values correctly, and initialize TWAIN memory transfers with the required
app-owned pointer flags and don't-care fields. It now selects the installed
provider log by client bitness and enables verbose logging only in the test
process. The following client-level acquisitions passed and completed
`MSG_ENDXFER`:

- x64 native full-page Color: 423x584 pixels at 96 dpi; the DIB contained
  742,848 pixel bytes and 331 sampled nonblank pixels. The earlier full-bed
  scan and return were observed to be smooth.
- x64 and x86 native Gray preview: each returned a 150x150, 8-bpp DIB with
  1,444 sampled nonblank pixels. The scanner log confirms 75 dpi and a 2-inch
  frame were applied; SANEWinDS returns `TWRC_CHECKSTATUS` for the frame's
  inexact dimension match. Its post-transfer `DAT_IMAGEINFO` changes to 96 dpi,
  so the harness records both pre- and post-transfer values.
- x64 and x86 memory Gray preview: each returned 22,800 bytes at 150x150 and
  75 dpi, with 22,796 and 22,797 nonblank bytes respectively.

The user reports the latest short TWAIN carriage movement and return were
smooth. WIA is not available on this installation: `WIA.DeviceManager` reports
zero devices, so the HR7 is still not discoverable to WIA-only applications.
The public [WiaSane source](https://github.com/mback2k/wiasane) was retrieved
over GitHub TLS at commit `cb38cb469e4dbaed771806d5ca2606baa3086e20`
(2017-02-19; archive SHA-256
`900260b6938c24918b80da34116b7683439e0a36b3ae444c593bede75fa927a2`). Its
README targets Windows 7, WDK 8.0, and Visual Studio 2012. This host has no
Visual Studio, MSBuild, or WDK toolchain, and no validated WIA binary is
installed; the author's linked 2016 alpha installer also fails TLS validation
here with Schannel `SEC_E_WRONG_PRINCIPAL`. No TLS bypass was used and the
installer was not downloaded or run, so the candidate remains unbuilt and
unverified here.
Remaining release coverage includes x86 full-page and Color cases,
cancellation/reconnect cases for both TWAIN bitnesses, a supported WIA
implementation/acquisition, and the signed end-user installer.

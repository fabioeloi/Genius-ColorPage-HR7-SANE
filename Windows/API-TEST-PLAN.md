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
enumerates `SANEWinDS`; both bitnesses returned the data source identity. An
attempt to send `DAT_IDENTITY/MSG_OPENDS` in this host did not return promptly,
so source opening, capability exchange, acquisition, and cancellation remain
explicitly unverified rather than being reported as passing.

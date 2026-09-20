# WIA 2.0 provider work

`upstream/` is Microsoft's stream-based WIA 2.0 `wiadriverex` sample, pinned to
`microsoft/Windows-driver-samples` commit
`3c3fb49073c047c4cc8e6c203c6331f62b426507`. Microsoft's complete MS-PL license
is in [LICENSE-MS-PL.txt](LICENSE-MS-PL.txt); preserve its notices in any
derivative source or binary distribution.
The WINSANE SANE-network client subset is separately vendored under
`thirdparty/winsane/` and `thirdparty/winsane-util/`; preserve
[`COPYING-WINSANE.txt`](thirdparty/COPYING-WINSANE.txt) and the source revision
recorded in `manifest.json` if redistributing it.

The product design is an x64 WIA minidriver that transfers through the local
SANE service at `127.0.0.1:6566`. The physical USB node stays bound to WinUSB;
WIA uses a separate software-enumerated scanner instance. `WiaSaneScanner.cpp`
now implements Gray/Color flatbed transfer over SANE, selection-area mapping,
WIA brightness/contrast processing, and image rotation. The item tree reports
only flatbed capability; `WiaDriver.inx` plus
`Installer/InstallHr7WiaDevice.cpp` describe/register that software device.
The Microsoft sample is therefore modified source, not an unmodified
reference.

This work is not yet a verified WIA provider: no WDK/MSBuild toolchain is
available on the current host, so the minidriver and device-install helper
have not been compiled, the INF/catalog has not been signed, and no WIA device
enumeration or scan has been run. Do not advertise WIA support or distribute a
WIA binary until the x64 build, signed package, install/remove lifecycle,
WIA enumeration, and Gray/Color acquisition pass on clean Windows 11 and
Windows 10 22H2 hosts. Public PnP distribution also depends on meeting
Microsoft's driver-package signing requirements; ordinary setup EXE signing
alone does not establish that the WIA catalog is trusted on other PCs.

The client-side checks are [Test-WiaEnumeration.ps1](../Test-WiaEnumeration.ps1)
and [Test-WiaAcquire.ps1](../Test-WiaAcquire.ps1). They are developer/test
tools only. The end-user package is intended to perform device/provider setup
through its GUI installer, not by asking users to run these scripts.

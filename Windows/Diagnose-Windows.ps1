[CmdletBinding()]
param(
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$fallbackDirectory = Join-Path $env:TEMP 'GeniusColorPage-HR7-SANE'
$logsDirectory = Join-Path $StateDirectory 'logs'
try {
    New-Item -ItemType Directory -Force -Path $logsDirectory -ErrorAction Stop | Out-Null
}
catch {
    $logsDirectory = $fallbackDirectory
    New-Item -ItemType Directory -Force -Path $logsDirectory | Out-Null
}
$logPath = Join-Path $logsDirectory ('diagnose-' + (Get-Date -Format yyyyMMdd-HHmmss) + '.log')
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$devices = @(Get-Hr7UsbDevices)

"Timestamp UTC: $([DateTime]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $logPath -Encoding utf8
"Windows: $($os.Caption) $($os.Version); architecture: $($os.OSArchitecture)" | Add-Content -LiteralPath $logPath -Encoding utf8
"Expected USB ID: USB\VID_0458&PID_2013" | Add-Content -LiteralPath $logPath -Encoding utf8
if ($devices.Count -eq 1) {
    $snapshot = Get-Hr7DriverSnapshot -Device $devices[0]
    "Detected USB ID: $($snapshot.instance_id)" | Add-Content -LiteralPath $logPath -Encoding utf8
    "Driver service: $($snapshot.driver_service); INF: $($snapshot.driver_inf); version: $($snapshot.driver_version)" | Add-Content -LiteralPath $logPath -Encoding utf8
}
else {
    "Detected matching USB devices: $($devices.Count)" | Add-Content -LiteralPath $logPath -Encoding utf8
}

$statePath = Join-Path $StateDirectory 'state.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Hr7State -StatePath $statePath
    $bash = Join-Path ([string]$state.cygwin_root) 'bin\bash.exe'
    $scanimage = Join-Path ([string]$state.cygwin_root) 'opt\genius-hr7\bin\scanimage.exe'
    if ((Test-Path -LiteralPath $bash -PathType Leaf) -and (Test-Path -LiteralPath $scanimage -PathType Leaf)) {
        $saneOutput = & $bash -lc 'export SANE_CONFIG_DIR=/opt/genius-hr7/etc/sane.d; export SANE_DEBUG_DLL=4; export SANE_DEBUG_PLUSTEK=4; /opt/genius-hr7/bin/scanimage -V; /opt/genius-hr7/bin/sane-find-scanner -v 2>&1 | grep -i -E "0458|2013|sane-find-scanner"; /opt/genius-hr7/bin/scanimage -L 2>&1' 2>&1
        $saneOutput | Add-Content -LiteralPath $logPath -Encoding utf8
    }
    else {
        'Private Cygwin runtime not found.' | Add-Content -LiteralPath $logPath -Encoding utf8
    }
}
else {
    'Package state is absent; SANE diagnostics were not run.' | Add-Content -LiteralPath $logPath -Encoding utf8
}

Write-Host "Diagnóstico salvo em $logPath"
Get-Content -LiteralPath $logPath

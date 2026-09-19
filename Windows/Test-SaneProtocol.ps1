[CmdletBinding()]
param(
    [string] $AssemblyPath = (Join-Path $env:ProgramFiles 'SANEWinDS\SANEWinDS.dll'),
    [string] $ServerHost = '127.0.0.1',
    [ValidateRange(1, 65535)]
    [int] $Port = 6566
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
    throw "SANEWinDS assembly is missing: $AssemblyPath"
}

$assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$apiType = $assembly.GetType('SANEWinDS.SANE_API', $true)
$api = [Activator]::CreateInstance($apiType)
$tcp = [Net.Sockets.TcpClient]::new($ServerHost, $Port)
try {
    $initMethod = $apiType.GetMethod('Net_Init', [Reflection.BindingFlags]'Instance,NonPublic')
    $initArgs = [object[]]@($tcp, 'GeniusColorPage-HR7-Test')
    $initStatus = $initMethod.Invoke($api, $initArgs)
    if ([string]$initStatus -ne 'SANE_STATUS_GOOD') {
        throw "SANE Net_Init returned $initStatus"
    }

    $devicesMethod = $apiType.GetMethod('Net_Get_Devices', [Reflection.BindingFlags]'Instance,NonPublic')
    $devicesArgs = [object[]]@($initArgs[0], $null)
    $devicesStatus = $devicesMethod.Invoke($api, $devicesArgs)
    if ([string]$devicesStatus -ne 'SANE_STATUS_GOOD') {
        throw "SANE Net_Get_Devices returned $devicesStatus"
    }
    $devices = @($devicesArgs[1])
    $hr7 = @($devices | Where-Object { $_.vendor -eq 'KYE/Genius' -and $_.model -eq 'ColorPage-HR7' })
    if ($hr7.Count -ne 1) {
        throw "Expected one KYE/Genius ColorPage-HR7 device; found $($hr7.Count)."
    }
    Write-Output "PASS: SANEWinDS SANE protocol enumerated $($hr7[0].name) at $ServerHost`:$Port without acquiring an image."
}
finally {
    $exitMethod = $apiType.GetMethod('Net_Exit', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($null -ne $exitMethod -and $tcp.Connected) {
        try { $exitMethod.Invoke($api, [object[]]@($tcp)) | Out-Null } catch { }
    }
    $tcp.Dispose()
}

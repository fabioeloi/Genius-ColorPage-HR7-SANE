[CmdletBinding()]
param(
    [string] $AssemblyPath = (Join-Path $env:ProgramFiles 'SANEWinDS\SANEWinDS.dll'),
    [string] $ServerHost = '127.0.0.1',
    [ValidateRange(1, 65535)] [int] $Port = 6566,
    [ValidateRange(1, 120)] [int] $TimeoutSeconds = 15,
    [string] $DeviceNameOverride = '',
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'
if (-not $Worker) {
    $outPath = Join-Path $env:TEMP ("hr7-sane-open-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    try {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
            '-AssemblyPath', ('"{0}"' -f $AssemblyPath), '-ServerHost', $ServerHost, '-Port', $Port, '-Worker')
        if ($DeviceNameOverride) { $args += @('-DeviceNameOverride', ('"{0}"' -f $DeviceNameOverride)) }
        $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $completed = $workerProcess.WaitForExit($TimeoutSeconds * 1000)
        $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
        $workerError = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
        if (-not $completed) {
            & taskkill.exe /PID $workerProcess.Id /T /F *> $null
            Start-Sleep -Milliseconds 100
            $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { $workerOutput }
            if ($workerOutput -match 'PASS: SANE protocol opened') {
                Write-Output $workerOutput.Trim()
                exit 0
            }
            throw "SANE Net_Open did not return within $TimeoutSeconds seconds; the provider remains unverified."
        }
        $workerProcess.Refresh()
        if ($workerOutput -match 'PASS: SANE protocol opened') {
            Write-Output $workerOutput.Trim()
            exit 0
        }
        if ($null -eq $workerProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$workerProcess.ExitCode)) {
            throw "SANE Net_Open worker did not report an exit code within $TimeoutSeconds seconds; the provider remains unverified."
        }
        if ($workerProcess.ExitCode -ne 0) {
            if ($workerError) { throw $workerError.Trim() }
            throw "SANE open worker failed with exit code $($workerProcess.ExitCode)."
        }
        Write-Output $workerOutput.Trim()
    }
    finally {
        Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) { throw "SANEWinDS assembly is missing: $AssemblyPath" }
$assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$apiType = $assembly.GetType('SANEWinDS.SANE_API', $true)
$api = [Activator]::CreateInstance($apiType)
$tcp = [Net.Sockets.TcpClient]::new($ServerHost, $Port)
$openedHandle = $null
try {
    $initMethod = $apiType.GetMethod('Net_Init', [Reflection.BindingFlags]'Instance,NonPublic')
    $initArgs = [object[]]@($tcp, 'GeniusColorPage-HR7-Open-Test')
    if ([string]$initMethod.Invoke($api, $initArgs) -ne 'SANE_STATUS_GOOD') { throw 'Net_Init failed.' }
    $devicesMethod = $apiType.GetMethod('Net_Get_Devices', [Reflection.BindingFlags]'Instance,NonPublic')
    $devicesArgs = [object[]]@($tcp, $null)
    if ([string]$devicesMethod.Invoke($api, $devicesArgs) -ne 'SANE_STATUS_GOOD') { throw 'Net_Get_Devices failed.' }
    $hr7 = @($devicesArgs[1] | Where-Object { $_.vendor -eq 'KYE/Genius' -and $_.model -eq 'ColorPage-HR7' })
    if ($hr7.Count -ne 1) { throw "Expected one HR7 device; found $($hr7.Count)." }
    $deviceName = if ($DeviceNameOverride) { $DeviceNameOverride } else { [string]$hr7[0].name }
    $openMethod = $apiType.GetMethod('Net_Open', [Reflection.BindingFlags]'Instance,NonPublic')
    $openArgs = [object[]]@($tcp, $deviceName, 0, '', '')
    $status = [string]$openMethod.Invoke($api, $openArgs)
    if ($status -ne 'SANE_STATUS_GOOD') { throw "Net_Open returned $status for $deviceName." }
    $openedHandle = [int]$openArgs[2]
    $optionMethod = $apiType.GetMethod('Net_Get_Option_Descriptors', [Reflection.BindingFlags]'Instance,NonPublic')
    $descriptors = @($optionMethod.Invoke($api, [object[]]@($tcp, $openedHandle)))
    $closeMethod = $apiType.GetMethod('Net_Close', [Reflection.BindingFlags]'Instance,NonPublic')
    $closeMethod.Invoke($api, [object[]]@($tcp, $openedHandle)) | Out-Null
    $openedHandle = $null
    Write-Output "PASS: SANE protocol opened $deviceName and read $($descriptors.Count) option descriptors without acquiring an image."
    [Console]::Out.Flush()
}
finally {
    if ($null -ne $openedHandle) { try { $apiType.GetMethod('Net_Close', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($api, [object[]]@($tcp, $openedHandle)) | Out-Null } catch { } }
    $tcp.Dispose()
}

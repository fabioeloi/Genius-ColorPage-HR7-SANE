[CmdletBinding()]
param(
    [string] $AssemblyPath = (Join-Path $env:ProgramFiles 'SANEWinDS\SANEWinDS.dll'),
    [string] $ServerHost = '127.0.0.1',
    [ValidateRange(1, 65535)] [int] $Port = 6566,
    [ValidateRange(1, 180)] [int] $TimeoutSeconds = 120,
    [ValidateRange(1, 4)] [int] $MaxFrames = 4,
    [switch] $QueryParametersBeforeStart,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'

if (-not $Worker) {
    $outPath = Join-Path $env:TEMP ("hr7-sane-acquire-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    try {
        $workerArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
            '-AssemblyPath', ('"{0}"' -f $AssemblyPath), '-ServerHost', ('"{0}"' -f $ServerHost),
            '-Port', $Port, '-TimeoutSeconds', $TimeoutSeconds, '-MaxFrames', $MaxFrames, '-Worker'
        )
        if ($QueryParametersBeforeStart) { $workerArgs += '-QueryParametersBeforeStart' }
        $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $workerArgs -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $completed = $workerProcess.WaitForExit($TimeoutSeconds * 1000)
        $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
        $workerError = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
        if (-not $completed) {
            & taskkill.exe /PID $workerProcess.Id /T /F *> $null
            Start-Sleep -Milliseconds 100
            $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { $workerOutput }
            if ($workerOutput -match 'PASS: SANE network acquired') {
                Write-Output $workerOutput.Trim()
                exit 0
            }
            throw "SANE network acquisition did not complete within $TimeoutSeconds seconds."
        }
        $workerProcess.Refresh()
        if ($workerOutput -match 'PASS: SANE network acquired') {
            Write-Output $workerOutput.Trim()
            exit 0
        }
        if ($null -eq $workerProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$workerProcess.ExitCode)) {
            throw 'SANE network acquisition worker did not report an exit code.'
        }
        if ($workerProcess.ExitCode -ne 0) {
            if ($workerError) { throw $workerError.Trim() }
            throw "SANE network acquisition worker failed with exit code $($workerProcess.ExitCode)."
        }
        if ($workerError) { throw $workerError.Trim() }
        throw 'SANE network acquisition worker returned no success evidence.'
    }
    finally {
        Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
    throw "SANEWinDS assembly is missing: $AssemblyPath"
}

$bindingFlags = [Reflection.BindingFlags]'Instance,NonPublic'
$fieldFlags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$apiType = $assembly.GetType('SANEWinDS.SANE_API', $true)
$api = [Activator]::CreateInstance($apiType)
$tcp = [Net.Sockets.TcpClient]::new($ServerHost, $Port)
# Keep control calls below the parent-process deadline so finally can cancel/close.
$controlTimeoutMs = [Math]::Max(15000, ($TimeoutSeconds - 20) * 1000)
$tcp.ReceiveTimeout = $controlTimeoutMs
$tcp.SendTimeout = $controlTimeoutMs
$openedHandle = $null
$scanActive = $false
$frameCount = 0
$totalBytes = 0L
$sampleCount = 0L
$nonblankSamples = 0L
$minimumSample = 255
$maximumSample = 0
$frameSummary = [System.Collections.Generic.List[string]]::new()
$failure = $null

try {
    $initMethod = $apiType.GetMethod('Net_Init', $bindingFlags)
    $initArgs = [object[]]@($tcp, 'GeniusColorPage-HR7-SANE-Acquire-Test')
    $initStatus = [string]$initMethod.Invoke($api, $initArgs)
    if ($initStatus -ne 'SANE_STATUS_GOOD') { throw "SANE Net_Init returned $initStatus." }

    $devicesMethod = $apiType.GetMethod('Net_Get_Devices', $bindingFlags)
    $devicesArgs = [object[]]@($tcp, $null)
    $devicesStatus = [string]$devicesMethod.Invoke($api, $devicesArgs)
    if ($devicesStatus -ne 'SANE_STATUS_GOOD') { throw "SANE Net_Get_Devices returned $devicesStatus." }
    $hr7 = @($devicesArgs[1] | Where-Object { $_.vendor -eq 'KYE/Genius' -and $_.model -eq 'ColorPage-HR7' })
    if ($hr7.Count -ne 1) { throw "Expected exactly one HR7 network device; found $($hr7.Count)." }

    $deviceName = [string]$hr7[0].name
    $openMethod = $apiType.GetMethod('Net_Open', $bindingFlags)
    $openArgs = [object[]]@($tcp, $deviceName, 0, '', '')
    $openStatus = [string]$openMethod.Invoke($api, $openArgs)
    if ($openStatus -ne 'SANE_STATUS_GOOD') { throw "SANE Net_Open returned $openStatus for $deviceName." }
    $openedHandle = [int]$openArgs[2]

    $descriptorMethod = $apiType.GetMethod('Net_Get_Option_Descriptors', $bindingFlags)
    $descriptors = @($descriptorMethod.Invoke($api, [object[]]@($tcp, $openedHandle)))

    if ($QueryParametersBeforeStart) {
        $getParametersMethod = $apiType.GetMethod('Net_Get_Parameters', $bindingFlags)
        $parametersType = $apiType.GetNestedType('SANE_Parameters', [Reflection.BindingFlags]::NonPublic)
        $parametersArgs = [object[]]@($tcp, $openedHandle, [Activator]::CreateInstance($parametersType))
        $parametersStatus = [string]$getParametersMethod.Invoke($api, $parametersArgs)
        if ($parametersStatus -ne 'SANE_STATUS_GOOD') {
            throw "SANE Net_Get_Parameters before start returned $parametersStatus."
        }
    }

    $startMethod = $apiType.GetMethod('Net_Start', $bindingFlags)
    $byteOrderType = $apiType.GetNestedType('SANE_Net_Byte_Order', [Reflection.BindingFlags]::NonPublic)
    $startStatus = 'SANE_STATUS_GOOD'

    for ($frameIndex = 0; $frameIndex -lt $MaxFrames; $frameIndex++) {
        $startArgs = [object[]]@($tcp, $openedHandle, 0, [Enum]::ToObject($byteOrderType, 0x1234), '', '')
        $startStatus = [string]$startMethod.Invoke($api, $startArgs)
        if ($startStatus -ne 'SANE_STATUS_GOOD') {
            throw "SANE Net_Start returned $startStatus before frame $($frameIndex + 1) (after $frameCount frame(s)); options were left at backend defaults."
        }
        $scanActive = $true
        $dataPort = [int]$startArgs[2]
        $byteOrder = $startArgs[3]

        $acquireMethod = $apiType.GetMethod('AcquireFrame', $bindingFlags)
        $acquireArgs = [object[]]@($tcp, $dataPort, $byteOrder, $controlTimeoutMs)
        try {
            $frame = $acquireMethod.Invoke($api, $acquireArgs)
        }
        catch [Reflection.TargetInvocationException] {
            if ($_.Exception.InnerException) { throw "SANE AcquireFrame failed: $($_.Exception.InnerException.Message)" }
            throw
        }

        $frameType = $frame.GetType()
        $paramsField = $frameType.GetField('Params', $fieldFlags)
        $dataField = $frameType.GetField('Data', $fieldFlags)
        if ($null -eq $paramsField -or $null -eq $dataField) { throw 'SANEWinDS returned an unexpected frame structure.' }
        $parameters = $paramsField.GetValue($frame)
        $data = [byte[]]$dataField.GetValue($frame)
        $parametersType = $parameters.GetType()
        $lastFrame = [bool]$parametersType.GetField('last_frame', $fieldFlags).GetValue($parameters)
        $width = [int]$parametersType.GetField('pixels_per_line', $fieldFlags).GetValue($parameters)
        $height = [int]$parametersType.GetField('lines', $fieldFlags).GetValue($parameters)
        $depth = [int]$parametersType.GetField('depth', $fieldFlags).GetValue($parameters)
        $format = [string]$parametersType.GetField('format', $fieldFlags).GetValue($parameters)
        if ($data.LongLength -le 0) { throw "SANE returned an empty network frame ($width x $height, $format, depth $depth)." }

        $frameCount++
        $totalBytes += $data.LongLength
        $frameSummary.Add("$($width)x$($height) $format/$($depth)-bit $($data.LongLength) bytes last=$lastFrame")
        $step = [Math]::Max(1, [int][Math]::Floor($data.LongLength / 4096))
        for ($index = 0; $index -lt $data.LongLength; $index += $step) {
            $sample = [int]$data[$index]
            $sampleCount++
            if ($sample -lt 250) { $nonblankSamples++ }
            if ($sample -lt $minimumSample) { $minimumSample = $sample }
            if ($sample -gt $maximumSample) { $maximumSample = $sample }
        }

        if ($lastFrame) {
            $scanActive = $false
            break
        }
    }

    if ($scanActive) { throw "SANE did not mark a final frame within the $MaxFrames-frame safety limit." }
    if ($nonblankSamples -le 0 -or ($maximumSample - $minimumSample) -le 5) {
        throw "SANE network transfer returned only blank or uniform samples ($nonblankSamples/$sampleCount, $minimumSample..$maximumSample)."
    }
}
catch {
    $failure = $_.Exception.Message
}
finally {
    if ($null -ne $openedHandle) {
        if ($scanActive) {
            try { $apiType.GetMethod('Net_Cancel', $bindingFlags).Invoke($api, [object[]]@($tcp, $openedHandle)) | Out-Null } catch { }
        }
        try { $apiType.GetMethod('Net_Close', $bindingFlags).Invoke($api, [object[]]@($tcp, $openedHandle)) | Out-Null } catch { }
    }
    try { $apiType.GetMethod('Net_Exit', $bindingFlags).Invoke($api, [object[]]@($tcp)) | Out-Null } catch { }
    $tcp.Dispose()
}

if ($failure) { throw $failure }
Write-Output "PASS: SANE network acquired $frameCount frame(s), $totalBytes bytes ($($frameSummary -join '; ')); sampled nonblank=$nonblankSamples/$sampleCount, intensity=$minimumSample..$maximumSample."
[Console]::Out.Flush()

[CmdletBinding()]
param(
    [string] $ExpectedName = 'ColorPage-HR7',
    [ValidateRange(1, 180)] [int] $TimeoutSeconds = 90,
    [ValidateSet(75, 150, 300, 600)] [int] $ResolutionDpi = 75,
    [ValidateSet('Gray', 'Color')] [string] $PixelMode = 'Gray',
    [string] $OutputPath = (Join-Path $env:TEMP ("hr7-wia-{0}.bmp" -f [Guid]::NewGuid().ToString('N'))),
    [switch] $Preview,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'

function Get-WiaPropertyById {
    param(
        [Parameter(Mandatory)] [object] $Properties,
        [Parameter(Mandatory)] [int] $PropertyId
    )

    for ($index = 1; $index -le $Properties.Count; $index++) {
        $candidate = $null
        try {
            $candidate = $Properties.Item($index)
            if ([int]$candidate.PropertyID -eq $PropertyId) {
                $match = $candidate
                $candidate = $null
                return $match
            }
        }
        finally {
            if ($candidate) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($candidate)
            }
        }
    }

    throw "The WIA item does not expose property ID $PropertyId."
}

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ($OutputPath.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Scan outputs must stay outside the repository: $OutputPath"
}

if (-not $Worker) {
    if ([IntPtr]::Size -ne 8) {
        throw 'Run this WIA test from 64-bit Windows PowerShell; the HR7 WIA provider is x64.'
    }
    if (Test-Path -LiteralPath $OutputPath) {
        throw "Refusing to overwrite the existing scan output: $OutputPath"
    }

    $outPath = Join-Path $env:TEMP ("hr7-wia-acquire-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    try {
        $workerArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
            '-ExpectedName', ('"{0}"' -f $ExpectedName), '-TimeoutSeconds', $TimeoutSeconds,
            '-ResolutionDpi', $ResolutionDpi, '-PixelMode', $PixelMode,
            '-OutputPath', ('"{0}"' -f $OutputPath), '-Worker'
        )
        if ($Preview) { $workerArgs += '-Preview' }
        $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $workerArgs -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $completed = $workerProcess.WaitForExit($TimeoutSeconds * 1000)
        $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
        $workerError = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }

        if (-not $completed) {
            try { & taskkill.exe /PID $workerProcess.Id /T /F *> $null } catch { }
            throw "WIA acquisition did not complete within $TimeoutSeconds seconds. A partial file, if created, is at '$OutputPath'."
        }
        if ($workerOutput -match 'PASS: WIA acquired') {
            Write-Output $workerOutput.Trim()
            exit 0
        }
        if ($workerProcess.ExitCode -ne 0) {
            if ($workerError) { throw $workerError.Trim() }
            throw "WIA acquisition worker failed with exit code $($workerProcess.ExitCode). $workerOutput"
        }
        if ($workerError) { throw $workerError.Trim() }
        throw "WIA acquisition worker returned no success evidence. $workerOutput"
    }
    finally {
        Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
}

if ([IntPtr]::Size -ne 8) {
    throw 'The WIA test worker must be 64-bit.'
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to overwrite the existing scan output: $OutputPath"
}

$manager = $null
$deviceInfos = $null
$deviceInfo = $null
$device = $null
$items = $null
$item = $null
$properties = $null
$image = $null
$bitmap = $null
$watch = [Diagnostics.Stopwatch]::StartNew()

try {
    $manager = New-Object -ComObject WIA.DeviceManager
    $deviceInfos = $manager.DeviceInfos
    $matches = @()
    for ($index = 1; $index -le $deviceInfos.Count; $index++) {
        $candidate = $null
        try {
            $candidate = $deviceInfos.Item($index)
            $candidateName = [string]$candidate.Properties.Item('Name').Value
            if ($candidateName -like "*$ExpectedName*") {
                $matches += [pscustomobject]@{
                    Info = $candidate
                    Name = $candidateName
                    DeviceId = [string]$candidate.DeviceID
                }
                $candidate = $null
            }
        }
        finally {
            if ($candidate) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($candidate)
            }
        }
    }
    if ($matches.Count -ne 1) {
        $names = @($matches | ForEach-Object { $_.Name }) -join ', '
        foreach ($match in $matches) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($match.Info)
        }
        throw "Expected one WIA device matching '$ExpectedName'; found $($matches.Count). Matching devices: $names"
    }

    $deviceInfo = $matches[0].Info
    $device = $deviceInfo.Connect()
    $items = $device.Items
    if ($items.Count -lt 1) {
        throw "WIA device '$($matches[0].Name)' has no scan items."
    }
    $item = $items.Item(1)
    $properties = $item.Properties

    $intent = if ($PixelMode -eq 'Color') { 1 } else { 2 }
    $settings = @(
        @{ Id = 6146; Value = $intent; Name = 'scan intent' },
        @{ Id = 6147; Value = $ResolutionDpi; Name = 'horizontal resolution' },
        @{ Id = 6148; Value = $ResolutionDpi; Name = 'vertical resolution' }
    )
    if ($Preview) {
        # WIA_IPS_PREVIEW is 3100 (not a scan-position property ID). The
        # Properties.Item automation collection is positional, so the helper
        # resolves the WIA property ID from each item's PropertyID field.
        $settings = @(@{ Id = 3100; Value = 1; Name = 'preview mode' }) + $settings
    }
    foreach ($setting in $settings) {
        $property = $null
        try {
            $property = Get-WiaPropertyById -Properties $properties -PropertyId $setting.Id
            $property.Value = $setting.Value
        }
        catch {
            throw "Could not set WIA $($setting.Name) to $($setting.Value): $($_.Exception.Message)"
        }
        finally {
            if ($property) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($property)
            }
        }
    }

    $image = $item.Transfer('{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}')
    if (-not $image) {
        throw 'WIA returned no image object; the transfer may have been cancelled.'
    }
    $image.SaveFile($OutputPath)
    $width = [int]$image.Width
    $height = [int]$image.Height
    if ($width -lt 1 -or $height -lt 1) {
        throw "WIA returned invalid image dimensions ${width}x${height}."
    }

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap -ArgumentList $OutputPath
    $stepX = [Math]::Max(1, [int][Math]::Floor($width / 200.0))
    $stepY = [Math]::Max(1, [int][Math]::Floor($height / 200.0))
    $nonWhiteSamples = 0
    for ($y = 0; $y -lt $height; $y += $stepY) {
        for ($x = 0; $x -lt $width; $x += $stepX) {
            $pixel = $bitmap.GetPixel($x, $y)
            if (($pixel.R -lt 248) -or ($pixel.G -lt 248) -or ($pixel.B -lt 248)) {
                $nonWhiteSamples++
            }
        }
    }
    if ($nonWhiteSamples -lt 1) {
        throw 'The WIA image contains no sampled non-white pixels; refusing to count a blank scan as a pass.'
    }

    $watch.Stop()
    $length = (Get-Item -LiteralPath $OutputPath).Length
    $scanKind = if ($Preview) { 'preview' } else { 'final' }
    Write-Output ("PASS: WIA acquired {0} {1} {2} dpi image via '{3}' ({4}x{5}, {6} bytes, {7} sampled non-white pixels, {8:N1}s); file: {9}" -f $scanKind, $PixelMode, $ResolutionDpi, $matches[0].Name, $width, $height, $length, $nonWhiteSamples, $watch.Elapsed.TotalSeconds, $OutputPath)
}
finally {
    if ($bitmap) { $bitmap.Dispose() }
    foreach ($comObject in @($image, $properties, $item, $items, $device, $deviceInfo, $deviceInfos, $manager)) {
        if ($comObject -and [Runtime.InteropServices.Marshal]::IsComObject($comObject)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($comObject)
        }
    }
}

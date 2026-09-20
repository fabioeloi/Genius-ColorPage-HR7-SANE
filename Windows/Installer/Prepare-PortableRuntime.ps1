[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [string] $DestinationRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\build')).TrimEnd([IO.Path]::DirectorySeparatorChar)
$buildPrefix = $buildRoot + [IO.Path]::DirectorySeparatorChar

if (-not $destination.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Portable runtime outputs must remain under the ignored Windows/build directory: $destination"
}
if ($source.Equals($destination, [StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith($destination + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $destination.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source and destination runtime trees must not contain one another.'
}
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "The installed Cygwin root was not found: $source"
}
if (Test-Path -LiteralPath $destination) {
    throw "Refusing to overwrite an existing staged runtime: $destination"
}

# Only stage what the product uses: the Cygwin service/runtime DLLs, saned,
# the Plustek SANE backend, and its SANE configuration.
# In particular, do not copy the build host's /usr tree, accounts, logs, or compiler.
$runtimeFiles = @(
    'bin\cygrunsrv.exe',
    'bin\cygwin1.dll',
    'bin\cygusb-1.0.dll',
    'opt\genius-hr7\bin\cygsane-1.dll',
    'opt\genius-hr7\etc\sane.d\dll.conf',
    'opt\genius-hr7\etc\sane.d\plustek.conf',
    'opt\genius-hr7\etc\sane.d\saned.conf',
    'opt\genius-hr7\lib\sane\cygsane-dll-1.dll',
    'opt\genius-hr7\lib\sane\cygsane-plustek-1.dll',
    'opt\genius-hr7\sbin\saned.exe'
)

foreach ($relativePath in $runtimeFiles) {
    $sourcePath = Join-Path $source $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required runtime file is missing: $sourcePath"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to stage a runtime file that is a reparse point: $sourcePath"
    }
}

New-Item -ItemType Directory -Path $destination -Force | Out-Null
foreach ($relativePath in $runtimeFiles) {
    $sourcePath = Join-Path $source $relativePath
    $destinationPath = Join-Path $destination $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
}

$forbiddenExtensions = @('.a', '.la', '.pc', '.pdb', '.obj', '.ilk', '.lib', '.exp', '.h', '.hpp')
$stagedFiles = @(Get-ChildItem -LiteralPath $destination -File -Force -Recurse -ErrorAction Stop)
$developmentFiles = @($stagedFiles | Where-Object { $_.Extension.ToLowerInvariant() -in $forbiddenExtensions })
if ($developmentFiles.Count -ne 0) {
    throw "Staged runtime unexpectedly contains development artifacts: $($developmentFiles.FullName -join ', ')"
}

Write-Output "Staged $($stagedFiles.Count) service runtime files to $destination"

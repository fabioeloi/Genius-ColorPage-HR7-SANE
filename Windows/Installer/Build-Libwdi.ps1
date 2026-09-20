[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $LibwdiRoot,

    [Parameter(Mandatory)]
    [string] $MSBuildPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedCommit = '9b23b82a2dd1cbffc16d46c212f92c6bf8c0c602'
$libwdiRootPath = [IO.Path]::GetFullPath($LibwdiRoot)
$msbuildPath = [IO.Path]::GetFullPath($MSBuildPath)
$patchPath = Join-Path $PSScriptRoot 'libwdi-1.5.1-hr7-x64.patch'

if (-not (Test-Path -LiteralPath $libwdiRootPath -PathType Container)) {
    throw "The pinned libwdi source tree was not found: $libwdiRootPath"
}
if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
    throw "MSBuild was not found: $msbuildPath"
}
if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
    throw "The HR7 libwdi build patch was not found: $patchPath"
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $git) {
    $gitCandidate = Join-Path ${env:ProgramFiles} 'Git\cmd\git.exe'
    if (-not (Test-Path -LiteralPath $gitCandidate -PathType Leaf)) {
        throw 'Git is required to verify and patch the pinned libwdi source tree.'
    }
    $gitPath = $gitCandidate
} else {
    $gitPath = $git.Source
}

& $gitPath -C $libwdiRootPath rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { throw "LibwdiRoot is not a Git checkout: $libwdiRootPath" }
$actualCommit = (& $gitPath -C $libwdiRootPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $expectedCommit) {
    throw "Expected libwdi commit $expectedCommit, found '$actualCommit'."
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $gitPath -C $libwdiRootPath apply --check $patchPath *> $null
    $applyCheckExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($applyCheckExitCode -eq 0) {
    & $gitPath -C $libwdiRootPath apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the HR7 x64/no-coinstaller libwdi patch.' }
} else {
    $ErrorActionPreference = 'Continue'
    try {
        & $gitPath -C $libwdiRootPath apply --reverse --check $patchPath *> $null
        $reverseCheckExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($reverseCheckExitCode -ne 0) {
        throw 'LibwdiRoot has local changes that are neither the pinned source nor the expected HR7 patch. Preserve and review them before building.'
    }
}

$solutionDir = $libwdiRootPath + [IO.Path]::DirectorySeparatorChar
function Invoke-LibwdiBuild {
    param(
        [string] $Project,
        [string] $Configuration,
        [string] $Platform,
        [string] $Target,
        [switch] $SkipProjectReferences
    )

    $arguments = @(
        $Project,
        '/m:1',
        "/t:$Target",
        '/verbosity:minimal',
        "/p:Configuration=$Configuration",
        "/p:Platform=$Platform",
        "/p:SolutionDir=$solutionDir"
    )
    if ($SkipProjectReferences) { $arguments += '/p:BuildProjectReferences=false' }
    & $msbuildPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed for $(Split-Path -Leaf $Project) ($Configuration|$Platform), exit $LASTEXITCODE."
    }
}

$embedderProject = Join-Path $libwdiRootPath 'libwdi\.msvc\embedder.vcxproj'
$installerProject = Join-Path $libwdiRootPath 'libwdi\.msvc\installer_x64.vcxproj'
$dllProject = Join-Path $libwdiRootPath 'libwdi\.msvc\libwdi_dll.vcxproj'
foreach ($project in @($embedderProject, $installerProject, $dllProject)) {
    if (-not (Test-Path -LiteralPath $project -PathType Leaf)) { throw "Required libwdi project is missing: $project" }
}

# The product is x64-only. Build only the Win32 resource embedder, x64 helper,
# and x64 DLL; upstream's generic solution also requests unrelated x86/ARM64
# helpers and legacy driver families.
Invoke-LibwdiBuild -Project $embedderProject -Configuration Release -Platform Win32 -Target Rebuild
Invoke-LibwdiBuild -Project $installerProject -Configuration Release -Platform x64 -Target Rebuild
Invoke-LibwdiBuild -Project $dllProject -Configuration Release -Platform x64 -Target Rebuild -SkipProjectReferences

$releaseDirectory = Join-Path $libwdiRootPath 'x64\Release\dll'
$requiredOutputs = @(
    (Join-Path $releaseDirectory 'libwdi.dll'),
    (Join-Path $releaseDirectory 'libwdi.lib')
)
foreach ($output in $requiredOutputs) {
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        throw "The x64 libwdi build output is missing: $output"
    }
}

Get-FileHash -LiteralPath $requiredOutputs -Algorithm SHA256 |
    Select-Object Path, Hash |
    Format-Table -AutoSize

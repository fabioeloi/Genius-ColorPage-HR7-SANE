[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RuntimeRoot,

    [Parameter(Mandatory)]
    [string] $LibwdiRoot,

    [Parameter(Mandatory)]
    [string] $ComplianceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $SigningCertificateThumbprint,

    [string] $BundleVersion = '1.0.0.5',
    [string] $RuntimeMsiVersion = '1.0.5',
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $PreviousBundlePath,
    [string] $SaneWinDsPackageRoot,
    [string] $SignToolPath,
    [string] $Inf2CatPath,
    [string] $MSBuildPath,
    [string] $DotNetPath,
    [ValidatePattern('^10\.0\.\d+\.0$')]
    [string] $WindowsSdkVersion = '10.0.26100.0',
    [string] $WixPath,
    [string] $OutputDirectory,
    [switch] $AllowUnreleasedEvaluationBuild,
    [switch] $AllowUntrustedEvaluationSigning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-RequiredCommand {
    param([string] $Name, [string] $ExplicitPath)
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "Required tool was not found: $ExplicitPath" }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw "Required tool '$Name' is not available on PATH. Install the documented build toolchain and retry." }
    return $command.Source
}

function Invoke-Checked {
    param([string] $FilePath, [string[]] $Arguments, [string] $Description)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Get-Sha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Initialize-MsiSummaryInterop {
    if ('Hr7MsiSummaryInterop' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Hr7MsiSummaryInterop {
    [DllImport("msi.dll", CharSet=CharSet.Unicode, EntryPoint="MsiOpenDatabaseW", ExactSpelling=true)]
    public static extern uint OpenDatabase(string path, IntPtr persist, out uint handle);
    [DllImport("msi.dll", CharSet=CharSet.Unicode, EntryPoint="MsiGetSummaryInformationW", ExactSpelling=true)]
    public static extern uint GetSummaryInformation(uint database, string path, uint updateCount, out uint handle);
    [DllImport("msi.dll", CharSet=CharSet.Unicode, EntryPoint="MsiSummaryInfoGetPropertyW", ExactSpelling=true)]
    public static extern uint GetProperty(uint summary, uint property, out uint dataType, out int value,
        IntPtr fileTime, StringBuilder text, ref uint textLength);
    [DllImport("msi.dll", CharSet=CharSet.Unicode, EntryPoint="MsiSummaryInfoSetPropertyW", ExactSpelling=true)]
    public static extern uint SetProperty(uint summary, uint property, uint dataType, int value,
        IntPtr fileTime, string text);
    [DllImport("msi.dll", EntryPoint="MsiSummaryInfoPersist", ExactSpelling=true)]
    public static extern uint PersistSummary(uint summary);
    [DllImport("msi.dll", EntryPoint="MsiDatabaseCommit", ExactSpelling=true)]
    public static extern uint CommitDatabase(uint database);
    [DllImport("msi.dll", EntryPoint="MsiCloseHandle", ExactSpelling=true)]
    public static extern uint CloseHandle(uint handle);
}
'@ -ErrorAction Stop
}

function Get-MsiSummaryString {
    param([string] $Path, [uint32] $PropertyId)
    Initialize-MsiSummaryInterop
    $fullPath = [IO.Path]::GetFullPath($Path)
    [uint32] $database = 0
    [uint32] $summary = 0
    try {
        $result = [Hr7MsiSummaryInterop]::OpenDatabase($fullPath, [IntPtr]::Zero, [ref] $database)
        if ($result -ne 0) { throw "MsiOpenDatabase failed with Windows Installer error $result for $fullPath." }
        $result = [Hr7MsiSummaryInterop]::GetSummaryInformation($database, $null, 0, [ref] $summary)
        if ($result -ne 0) { throw "MsiGetSummaryInformation failed with Windows Installer error $result for $fullPath." }
        [uint32] $dataType = 0
        [int32] $value = 0
        [uint32] $textLength = 1024
        $text = New-Object Text.StringBuilder 1024
        $result = [Hr7MsiSummaryInterop]::GetProperty($summary, $PropertyId, [ref] $dataType, [ref] $value,
            [IntPtr]::Zero, $text, [ref] $textLength)
        if ($result -ne 0) { throw "MsiSummaryInfoGetProperty failed with Windows Installer error $result for PID $PropertyId in $fullPath." }
        if ($dataType -notin @(30, 31)) { throw "Expected a string in MSI summary PID $PropertyId, found type $dataType in $fullPath." }
        return $text.ToString()
    }
    finally {
        if ($summary -ne 0) { [void] [Hr7MsiSummaryInterop]::CloseHandle($summary) }
        if ($database -ne 0) { [void] [Hr7MsiSummaryInterop]::CloseHandle($database) }
    }
}

function Set-MsiSummaryStrings {
    param([string] $Path, [string] $Template, [string] $PackageCode)
    Initialize-MsiSummaryInterop
    $fullPath = [IO.Path]::GetFullPath($Path)
    [uint32] $database = 0
    [uint32] $summary = 0
    try {
        # MSIDBOPEN_TRANSACT is the integer resource value 1.
        $result = [Hr7MsiSummaryInterop]::OpenDatabase($fullPath, [IntPtr] 1, [ref] $database)
        if ($result -ne 0) { throw "MsiOpenDatabase(transaction) failed with Windows Installer error $result for $fullPath." }
        $result = [Hr7MsiSummaryInterop]::GetSummaryInformation($database, $null, 2, [ref] $summary)
        if ($result -ne 0) { throw "MsiGetSummaryInformation(write) failed with Windows Installer error $result for $fullPath." }
        # VT_LPSTR is the MSI summary stream's string type. The original MSI is
        # hash-verified and unsigned before this is called; only its staged copy is edited.
        foreach ($property in @(@{ Id = 7; Value = $Template }, @{ Id = 9; Value = $PackageCode })) {
            $result = [Hr7MsiSummaryInterop]::SetProperty($summary, [uint32] $property.Id, 30, 0,
                [IntPtr]::Zero, [string] $property.Value)
            if ($result -ne 0) { throw "MsiSummaryInfoSetProperty failed with Windows Installer error $result for PID $($property.Id) in $fullPath." }
        }
        $result = [Hr7MsiSummaryInterop]::PersistSummary($summary)
        if ($result -ne 0) { throw "MsiSummaryInfoPersist failed with Windows Installer error $result for $fullPath." }
        $result = [Hr7MsiSummaryInterop]::CommitDatabase($database)
        if ($result -ne 0) { throw "MsiDatabaseCommit failed with Windows Installer error $result for $fullPath." }
    }
    finally {
        if ($summary -ne 0) { [void] [Hr7MsiSummaryInterop]::CloseHandle($summary) }
        if ($database -ne 0) { [void] [Hr7MsiSummaryInterop]::CloseHandle($database) }
    }
}

function Get-DeterministicPackageCode {
    param([string] $Seed)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed))
    }
    finally { $hasher.Dispose() }
    $hex = [BitConverter]::ToString($digest, 0, 16).Replace('-', '')
    return '{' + [Guid]::ParseExact($hex, 'N').ToString().ToUpperInvariant() + '}'
}

function Repair-SaneWinDsX86Summary {
    param([string] $Path, [string] $PackageCode)
    $originalTemplate = Get-MsiSummaryString -Path $Path -PropertyId 7
    if ($originalTemplate -cne ';1033') {
        throw "The pinned x86 SANEWinDS MSI no longer has the expected missing-platform Template Summary ';1033' (found '$originalTemplate'). Review the upstream package before continuing."
    }
    $originalPackageCode = Get-MsiSummaryString -Path $Path -PropertyId 9
    if ($originalPackageCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') {
        throw "The pinned x86 SANEWinDS MSI has an unexpected PackageCode: '$originalPackageCode'."
    }
    Set-MsiSummaryStrings -Path $Path -Template 'Intel;1033' -PackageCode $PackageCode
    $correctedTemplate = Get-MsiSummaryString -Path $Path -PropertyId 7
    $correctedPackageCode = Get-MsiSummaryString -Path $Path -PropertyId 9
    if ($correctedTemplate -cne 'Intel;1033' -or $correctedPackageCode -cne $PackageCode) {
        throw "The staged x86 SANEWinDS MSI summary stream did not retain the corrected platform and package code: '$correctedTemplate', '$correctedPackageCode'."
    }
    return [ordered]@{
        original_template_summary = $originalTemplate
        corrected_template_summary = $correctedTemplate
        original_package_code = $originalPackageCode
        corrected_package_code = $correctedPackageCode
    }
}

function Get-ActiveConfigLines {
    param([string] $Path)
    return @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object {
        $line = ($_ -split '#', 2)[0].Trim()
        if ($line) { $line }
    })
}

function Copy-TreeContents {
    param([string] $Source, [string] $Destination)
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Required directory was not found: $Source" }
    $rootItem = Get-Item -LiteralPath $Source -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to stage a runtime root that is a reparse point: $Source"
    }
    $reparsePoint = Get-ChildItem -LiteralPath $Source -Force -Recurse -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($null -ne $reparsePoint) { throw "Refusing to stage a runtime containing a reparse point: $($reparsePoint.FullName)" }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Assert-PortableRuntime {
    param([string] $Root)
    $forbiddenExtensions = @('.a', '.la', '.pc', '.pdb', '.obj', '.ilk', '.lib', '.exp', '.h', '.hpp')
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse -ErrorAction Stop)
    $developmentFiles = @($files | Where-Object {
        $_.Extension.ToLowerInvariant() -in $forbiddenExtensions -or
        $_.Name -match '^(gcc|g\+\+|cc|make|cmake|ninja|autoconf|automake|libtoolize|pkg-config|pkgconf|meson)(-[^.]*)?\.exe$' -or
        $_.Name -match '(^|[-])(gcc|g\+\+|make|cmake|ninja|autoconf|automake|libtoolize|pkg-config|pkgconf)([-.]|$)'
    } | Select-Object -First 8)
    if ($developmentFiles.Count -ne 0) {
        $examples = ($developmentFiles | ForEach-Object { $_.FullName }) -join "`n  "
        throw "RuntimeRoot contains development tools or non-runtime artifacts. Build a trimmed redistributable tree before packaging:`n  $examples"
    }
    $headerDirectories = @(
        (Join-Path $Root 'usr\include'),
        (Join-Path $Root 'opt\genius-hr7\include')
    )
    foreach ($directory in $headerDirectories) {
        if ((Test-Path -LiteralPath $directory -PathType Container) -and
            (Get-ChildItem -LiteralPath $directory -File -Force -Recurse -ErrorAction Stop | Select-Object -First 1)) {
            throw "RuntimeRoot contains development headers under $directory. Do not ship build headers in the end-user runtime."
        }
    }
}

function Find-WdkTool {
    param([string] $Name, [string] $ExplicitPath)
    if ($ExplicitPath) { return Resolve-RequiredCommand -Name $Name -ExplicitPath $ExplicitPath }
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kitsRoot -PathType Container) {
        $candidate = Get-ChildItem -LiteralPath $kitsRoot -Filter $Name -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'x64' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) { return $candidate.FullName }
    }
    throw "Required WDK tool '$Name' was not found. Install a Windows SDK/WDK build environment or pass its path."
}

function Sign-AndVerify {
    param(
        [string] $Path,
        [string] $SignTool,
        [string] $Thumbprint,
        [string] $TimestampUrl,
        [switch] $AllowUntrustedRoot
    )
    Invoke-Checked -FilePath $SignTool -Arguments @(
        'sign', '/fd', 'SHA256', '/sha1', $Thumbprint, '/tr', $TimestampUrl, '/td', 'SHA256', $Path
    ) -Description "Sign $([IO.Path]::GetFileName($Path))"
    Assert-AuthenticodeSignature -Path $Path -SignTool $SignTool -Thumbprint $Thumbprint `
        -VerifyArguments @('verify', '/pa', '/v', $Path) -AllowUntrustedRoot:$AllowUntrustedRoot
}

function Assert-AuthenticodeSignature {
    param(
        [string] $Path,
        [string] $SignTool,
        [string] $Thumbprint,
        [string[]] $VerifyArguments,
        [switch] $AllowUntrustedRoot
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $verificationOutput = @(& $SignTool @VerifyArguments 2>&1)
        $verificationExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($verificationExitCode -eq 0) { return }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $verificationText = $verificationOutput | Out-String
    $untrustedRootOnly = $verificationText -match '(?is)certificate chain processed, but terminated in a root.*not trusted by the trust provider|0x800B0109'
    $badDigest = $verificationText -match '(?i)0x80096010|TRUST_E_BAD_DIGEST|bad digest|hash mismatch'
    if ($AllowUntrustedRoot -and
        $signature.SignerCertificate -and
        $signature.SignerCertificate.Thumbprint -eq $Thumbprint -and
        $signature.Status -eq [System.Management.Automation.SignatureStatus]::UnknownError -and
        $untrustedRootOnly -and -not $badDigest) {
        $script:UntrustedEvaluationRootAccepted = $true
        Write-Warning "Signature/content checks identify the expected evaluation signer, but Windows does not yet trust its root. This private artifact is not install-ready until local machine trust is configured: $Path"
        return
    }
    throw "SignTool verification failed for '$Path' (exit $verificationExitCode, status $($signature.Status)): $verificationText"
}

$version = [version]$BundleVersion
if ($BundleVersion -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $version.Build -lt 0 -or $version.Revision -lt 0) {
    throw 'BundleVersion must have four numeric fields, for example 1.0.0.4.'
}
if ($BundleVersion -ne '1.0.0.5') {
    throw 'This migration build is pinned to bundle 1.0.0.5 and the signed 1.0.0.4 predecessor. Update the migration artifact, helper/INF versions, and lifecycle tests together before changing it.'
}
$msiVersion = [version]$RuntimeMsiVersion
if ($RuntimeMsiVersion -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$' -or
    $msiVersion.Major -gt 255 -or $msiVersion.Minor -gt 255 -or $msiVersion.Build -gt 65535) {
    throw 'RuntimeMsiVersion must be a valid three-field Windows Installer product version.'
}
if ($RuntimeMsiVersion -ne '1.0.5') {
    throw 'The 1.0.0.5 migration must advance the runtime MSI from 1.0.0 to 1.0.5.'
}
if ($AllowUntrustedEvaluationSigning -and -not $AllowUnreleasedEvaluationBuild) {
    throw '-AllowUntrustedEvaluationSigning is permitted only together with -AllowUnreleasedEvaluationBuild for a private evaluation artifact.'
}
$script:UntrustedEvaluationRootAccepted = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$windowsRoot = Join-Path $repoRoot 'Windows'
$buildRoot = Join-Path $windowsRoot 'build'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null

# The previous full Burn setup removed packages from its replacement because
# Burn executes related-bundle upgrades after the current chain. Embed only the
# exact released 1.0.0.4 bundle admitted by its build manifest and pinned digest.
$previousBundleVersion = '1.0.0.4'
$previousBundleExpectedSha256 = '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c'
$previousBundleExpectedSigner = '4E086470415F86AEAB2B55B06D5190B49C9ED2B7'
$previousBundlePath = [IO.Path]::GetFullPath($PreviousBundlePath)
if (-not (Test-Path -LiteralPath $previousBundlePath -PathType Leaf)) {
    throw "The signed 1.0.0.4 migration bundle was not found: $previousBundlePath"
}
$previousBundleManifestPath = Join-Path (Split-Path -Parent $previousBundlePath) 'release-artifacts.json'
if (-not (Test-Path -LiteralPath $previousBundleManifestPath -PathType Leaf)) {
    throw "The predecessor release manifest is required beside the bundle: $previousBundleManifestPath"
}
$previousBundleManifest = Get-Content -LiteralPath $previousBundleManifestPath -Raw | ConvertFrom-Json
if ([string]$previousBundleManifest.bundle_version -cne $previousBundleVersion -or
    [string]$previousBundleManifest.bundle.sha256 -ine $previousBundleExpectedSha256 -or
    [string]$previousBundleManifest.signing_certificate_thumbprint -ine $previousBundleExpectedSigner) {
    throw 'The predecessor release manifest is not the pinned signed 1.0.0.4 release.'
}
$previousBundleActualSha256 = Get-Sha256 -Path $previousBundlePath
if ($previousBundleActualSha256 -ine $previousBundleExpectedSha256) {
    throw "The predecessor setup SHA-256 is not the pinned 1.0.0.4 release: $previousBundleActualSha256"
}
$previousBundleSignature = Get-AuthenticodeSignature -LiteralPath $previousBundlePath
if ($previousBundleSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
    -not $previousBundleSignature.SignerCertificate -or
    $previousBundleSignature.SignerCertificate.Thumbprint -ine $previousBundleExpectedSigner) {
    throw 'The predecessor setup must have a valid Authenticode signature from the pinned local-evaluation signer.'
}

$saneWinDsPackageSource = if ($SaneWinDsPackageRoot) {
    [IO.Path]::GetFullPath($SaneWinDsPackageRoot)
} else {
    Join-Path $repoRoot '.tools\downloads'
}
$buildId = [Guid]::NewGuid().ToString('N')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $buildRoot "release-$BundleVersion-$buildId" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith([IO.Path]::GetFullPath($buildRoot) + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release outputs must remain under the ignored Windows/build directory: $OutputDirectory"
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Output directory already exists; choose a new version/output path instead of overwriting it: $OutputDirectory"
}

$runtimeSource = [IO.Path]::GetFullPath($RuntimeRoot)
$libwdiRootPath = [IO.Path]::GetFullPath($LibwdiRoot)
$complianceSource = [IO.Path]::GetFullPath($ComplianceRoot)
foreach ($requiredDirectory in @($runtimeSource, $libwdiRootPath, $complianceSource)) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Required input directory was not found: $requiredDirectory"
    }
}
$releaseApprovalPath = Join-Path $complianceSource 'RELEASE-APPROVED.txt'
if (-not (Test-Path -LiteralPath $releaseApprovalPath -PathType Leaf) -and -not $AllowUnreleasedEvaluationBuild) {
    throw "No reviewed release/compliance approval is present at $releaseApprovalPath. Use -AllowUnreleasedEvaluationBuild only for a private test artifact."
}
$requiredRuntimeFiles = @(
    'bin\cygrunsrv.exe',
    'bin\cygwin1.dll',
    'bin\cygusb-1.0.dll',
    'opt\genius-hr7\bin\cygsane-1.dll',
    'opt\genius-hr7\sbin\saned.exe',
    'opt\genius-hr7\etc\sane.d\saned.conf',
    'opt\genius-hr7\etc\sane.d\dll.conf',
    'opt\genius-hr7\etc\sane.d\plustek.conf',
    'opt\genius-hr7\lib\sane\cygsane-dll-1.dll',
    'opt\genius-hr7\lib\sane\cygsane-plustek-1.dll'
)
foreach ($relative in $requiredRuntimeFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeSource $relative) -PathType Leaf)) {
        throw "The staged portable SANE runtime is incomplete; missing $relative under $runtimeSource"
    }
}
Assert-PortableRuntime -Root $runtimeSource
$backendList = @(Get-ActiveConfigLines -Path (Join-Path $runtimeSource 'opt\genius-hr7\etc\sane.d\dll.conf'))
if ($backendList.Count -ne 1 -or $backendList[0] -ine 'plustek') {
    throw 'The redistributable runtime must enable only the HR7 Plustek SANE backend in dll.conf.'
}
$sanedConfig = @(Get-ActiveConfigLines -Path (Join-Path $runtimeSource 'opt\genius-hr7\etc\sane.d\saned.conf'))
if ($sanedConfig.Count -ne 1 -or $sanedConfig[0] -ne '127.0.0.1') {
    throw 'The redistributable runtime saned.conf must contain only the IPv4 loopback client address.'
}
$plustekConfig = @(Get-ActiveConfigLines -Path (Join-Path $runtimeSource 'opt\genius-hr7\etc\sane.d\plustek.conf'))
$allowedPlustekLines = @('[usb] 0x0458 0x2013', 'device auto')
if ($plustekConfig.Count -ne $allowedPlustekLines.Count -or
    @($plustekConfig | Where-Object { $_ -notin $allowedPlustekLines }).Count -ne 0 -or
    @($allowedPlustekLines | Where-Object { $_ -notin $plustekConfig }).Count -ne 0) {
    throw 'The redistributable runtime plustek.conf must target only Genius USB 0458:2013.'
}

$certificateMatches = @(
    Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Thumbprint -eq $SigningCertificateThumbprint -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date)
        } | Sort-Object Thumbprint -Unique
)
if ($certificateMatches.Count -ne 1) {
    throw 'The signing certificate thumbprint must identify exactly one current, unexpired code-signing certificate with a private key.'
}
$msbuild = Resolve-RequiredCommand -Name 'msbuild.exe' -ExplicitPath $MSBuildPath
$dotnet = Resolve-RequiredCommand -Name 'dotnet.exe' -ExplicitPath $DotNetPath
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$sdkInclude = Join-Path $sdkRoot "Include\$WindowsSdkVersion"
$sdkLib = Join-Path $sdkRoot "Lib\$WindowsSdkVersion\um\x64"
$sdkUm = Join-Path $sdkInclude 'um'
$sdkShared = Join-Path $sdkInclude 'shared'
foreach ($sdkInput in @(
    (Join-Path $sdkUm 'Wia.h'),
    (Join-Path $sdkShared 'driverspecs.h'),
    (Join-Path $sdkLib 'wiaguid.lib'),
    (Join-Path $sdkLib 'wiaservc.lib'),
    (Join-Path $sdkLib 'sti.lib')
)) {
    if (-not (Test-Path -LiteralPath $sdkInput -PathType Leaf)) {
        throw "The selected Windows SDK is incomplete for x64 WIA builds: $sdkInput"
    }
}
$signTool = Find-WdkTool -Name 'signtool.exe' -ExplicitPath $SignToolPath
$inf2Cat = Find-WdkTool -Name 'Inf2Cat.exe' -ExplicitPath $Inf2CatPath
$wix = Resolve-RequiredCommand -Name 'wix.exe' -ExplicitPath $WixPath
$dotnetRoot = Split-Path -Parent $dotnet
$env:DOTNET_ROOT = $dotnetRoot
$env:DOTNET_ROOT_X64 = $dotnetRoot
$env:DOTNET_ROLL_FORWARD = 'Major'
$wixVersionOutput = & $wix '--version'
$wixVersionExitCode = $LASTEXITCODE
$wixVersionLine = @($wixVersionOutput) | Select-Object -First 1
$wixVersion = ([string]$wixVersionLine).Trim()
if ($wixVersionExitCode -ne 0 -or -not [regex]::IsMatch($wixVersion, '^5\.0\.2(?:$|\+)')) {
    throw "WiX CLI 5.0.2 is required to match the pinned WiX SDK; found '$wixVersion'."
}

$manifestPath = Join-Path $repoRoot 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$stageRoot = Join-Path $buildRoot "stage-$BundleVersion-$buildId"
if (Test-Path -LiteralPath $stageRoot) {
    throw "Stage directory already exists; preserve it and use another version: $stageRoot"
}
$payloadRoot = Join-Path $stageRoot 'payload'
New-Item -ItemType Directory -Path $OutputDirectory, $payloadRoot | Out-Null
$evaluationCertificatePath = Join-Path $OutputDirectory 'GeniusColorPageHR7-Evaluation-CodeSigning.cer'
Export-Certificate -Cert $certificateMatches[0] -FilePath $evaluationCertificatePath -Type CERT | Out-Null
$exportedEvaluationCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($evaluationCertificatePath)
if ($exportedEvaluationCertificate.Thumbprint -ine $SigningCertificateThumbprint -or
    $exportedEvaluationCertificate.HasPrivateKey) {
    throw 'The exported evaluation certificate must match the signer and must not contain a private key.'
}
$evaluationCertificateSha256 = Get-Sha256 -Path $evaluationCertificatePath
foreach ($directoryName in @('runtime', 'WIA', 'config', 'Licenses', 'Documentation', 'tools', 'third-party', 'packages', 'migration')) {
    New-Item -ItemType Directory -Path (Join-Path $payloadRoot $directoryName) | Out-Null
}
$stagedPreviousBundlePath = Join-Path $payloadRoot 'migration\GeniusColorPageHR7Setup-1.0.0.4.exe'
Copy-Item -LiteralPath $previousBundlePath -Destination $stagedPreviousBundlePath
if ((Get-Sha256 -Path $stagedPreviousBundlePath) -ine $previousBundleExpectedSha256) {
    throw 'The staged migration bundle changed during copy; refusing to create the Burn package.'
}

Copy-TreeContents -Source $runtimeSource -Destination (Join-Path $payloadRoot 'runtime')
foreach ($requiredLicenseFile in @(
    (Join-Path $repoRoot 'SOURCES-AND-LICENSES.md'),
    (Join-Path $repoRoot 'Windows\WIA2\LICENSE-MS-PL.txt'),
    (Join-Path $repoRoot 'Windows\WIA2\thirdparty\COPYING-WINSANE.txt')
)) {
    if (-not (Test-Path -LiteralPath $requiredLicenseFile -PathType Leaf)) { throw "Required license/notice file is missing: $requiredLicenseFile" }
    Copy-Item -LiteralPath $requiredLicenseFile -Destination (Join-Path $payloadRoot 'Licenses')
}
Copy-TreeContents -Source $complianceSource -Destination (Join-Path $payloadRoot 'Licenses\ThirdParty')
Copy-Item -LiteralPath (Join-Path $windowsRoot 'config\SANEWinDS.ini') -Destination (Join-Path $payloadRoot 'config\SANEWinDS.ini')
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $payloadRoot 'Documentation\README.md')

# Build the product-specific elevated helpers. They do not run on this build host.
$libwdiBuildScript = Join-Path $PSScriptRoot 'Build-Libwdi.ps1'
$powerShell = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
    $powerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
if (-not (Test-Path -LiteralPath $libwdiBuildScript -PathType Leaf) -or
    -not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
    throw 'The pinned libwdi build script or Windows PowerShell 5.1 executable is missing.'
}
$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$gitPath = if ($gitCommand) { $gitCommand.Source } else { Join-Path $env:ProgramFiles 'Git\cmd\git.exe' }
if (-not (Test-Path -LiteralPath $gitPath -PathType Leaf)) {
    throw 'Git is required to make an isolated working copy of the pinned libwdi source.'
}
$stagedLibwdiRoot = Join-Path $stageRoot 'libwdi-source'
Invoke-Checked -FilePath $gitPath -Arguments @('clone', '--shared', $libwdiRootPath, $stagedLibwdiRoot) `
    -Description 'Create an isolated working copy of the pinned libwdi source'
$expectedLibwdiPatchFiles = @(
    'libwdi/.msvc/libwdi_dll.vcxproj',
    'libwdi/embedder.h',
    'libwdi/winusb.inf.in',
    'msvc/config.h'
)
$libwdiWorkingTreeStatus = @(& $gitPath -C $libwdiRootPath status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect local libwdi source changes.' }
if ($libwdiWorkingTreeStatus.Count -gt 0) {
    $actualLibwdiChangedFiles = @($libwdiWorkingTreeStatus | ForEach-Object { $_.Substring(3).Replace('\', '/') } | Sort-Object)
    $expectedLibwdiChangedFiles = @($expectedLibwdiPatchFiles | Sort-Object)
    if ([string]::Join('|', $actualLibwdiChangedFiles) -cne [string]::Join('|', $expectedLibwdiChangedFiles) -or
        @($libwdiWorkingTreeStatus | Where-Object { $_.Substring(0, 2) -cne ' M' }).Count -gt 0) {
        throw 'The libwdi source has local changes outside the four pinned HR7 patch files. Preserve and review them before building.'
    }
    $libwdiPatchPath = Join-Path $PSScriptRoot 'libwdi-1.5.1-hr7-x64.patch'
    & $gitPath -C $libwdiRootPath apply --reverse --check $libwdiPatchPath *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'The libwdi source changes are not the complete pinned HR7 WinUSB-only patch. Preserve and review them before building.'
    }
    foreach ($relativePatchFile in $expectedLibwdiPatchFiles) {
        $sourceFile = Join-Path $libwdiRootPath ($relativePatchFile.Replace('/', '\'))
        $stagedFile = Join-Path $stagedLibwdiRoot ($relativePatchFile.Replace('/', '\'))
        Copy-Item -LiteralPath $sourceFile -Destination $stagedFile -Force
    }
}
Invoke-Checked -FilePath $powerShell -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $libwdiBuildScript,
    '-LibwdiRoot', $stagedLibwdiRoot,
    '-MSBuildPath', $msbuild
) -Description 'Build the pinned HR7 x64 libwdi dependency'

$toolOutput = Join-Path $stageRoot 'tools-build'
$toolIntermediateRoot = Join-Path $stageRoot 'tools-obj'
New-Item -ItemType Directory -Path $toolOutput, $toolIntermediateRoot | Out-Null
$nativeProjects = @(
    @{ Path = (Join-Path $windowsRoot 'Installer\WinUsbBinding.vcxproj'); Extra = @("/p:LibwdiRoot=$stagedLibwdiRoot") },
    @{ Path = (Join-Path $windowsRoot 'Installer\SaneServiceManager.vcxproj'); Extra = @() },
    @{ Path = (Join-Path $windowsRoot 'Installer\TwainConfigManager.vcxproj'); Extra = @() },
    @{ Path = (Join-Path $windowsRoot 'WIA2\Installer\InstallHr7WiaDevice.vcxproj'); Extra = @() }
)
foreach ($project in $nativeProjects) {
    $projectName = [IO.Path]::GetFileNameWithoutExtension($project.Path)
    $projectIntermediate = Join-Path $toolIntermediateRoot $projectName
    New-Item -ItemType Directory -Path $projectIntermediate | Out-Null
    $projectArguments = @(
        $project.Path, '/m:1', '/t:Rebuild', '/p:Configuration=Release', '/p:Platform=x64',
        "/p:OutDir=$toolOutput\", "/p:IntDir=$projectIntermediate\"
    ) + $project.Extra
    Invoke-Checked -FilePath $msbuild -Arguments $projectArguments `
        -Description "Build $([IO.Path]::GetFileNameWithoutExtension($project.Path))"
}

$helperFiles = @(
    @{ Name = 'WinUsbBinding.exe'; Source = (Join-Path $toolOutput 'WinUsbBinding.exe') },
    @{ Name = 'libwdi.dll'; Source = (Join-Path $toolOutput 'libwdi.dll') },
    @{ Name = 'SaneServiceManager.exe'; Source = (Join-Path $toolOutput 'SaneServiceManager.exe') },
    @{ Name = 'TwainConfigManager.exe'; Source = (Join-Path $toolOutput 'TwainConfigManager.exe') },
    @{ Name = 'InstallHr7WiaDevice.exe'; Source = (Join-Path $toolOutput 'InstallHr7WiaDevice.exe') }
)
foreach ($helper in $helperFiles) {
    $source = $helper.Source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Built helper is missing: $source" }
    $stagedHelper = Join-Path (Join-Path $payloadRoot 'tools') $helper.Name
    Copy-Item -LiteralPath $source -Destination $stagedHelper
    Sign-AndVerify -Path $stagedHelper -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
        -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
}

# Build the x64 WIA minidriver, stage only its INF/DLL/catalog, then sign the
# catalog as one package. Do not register this software device on the build PC.
$wiaProject = Join-Path $windowsRoot 'WIA2\upstream\wiadriverex.vcxproj'
$wiaBuildOutput = Join-Path $stageRoot 'wia-build-output'
$wiaBuildIntermediate = Join-Path $stageRoot 'wia-obj'
New-Item -ItemType Directory -Path $wiaBuildOutput, $wiaBuildIntermediate | Out-Null
$wiaBuildArguments = @(
    $wiaProject,
    '/m:1', '/t:Build',
    '/p:Configuration=Release',
    '/p:Platform=x64',
    "/p:PlatformToolset=v143",
    "/p:WindowsTargetPlatformVersion=$WindowsSdkVersion",
    "/p:SDK_INC_PATH=$sdkUm",
    "/p:DDK_INC_PATH=$sdkShared",
    "/p:OutDir=$wiaBuildOutput\",
    "/p:IntDir=$wiaBuildIntermediate\"
)
Invoke-Checked -FilePath $msbuild -Arguments $wiaBuildArguments `
    -Description 'Build the HR7 WIA 2.0 minidriver'
$wiaInfSource = Join-Path $wiaBuildIntermediate 'GeniusColorPageHR7Wia.inf'
$wiaDllSource = Join-Path $wiaBuildOutput 'wiadriverex.dll'
$wiaInfTemplate = Join-Path $windowsRoot 'WIA2\upstream\WiaDriver.inx'
if (-not (Test-Path -LiteralPath $wiaDllSource -PathType Leaf)) {
    throw "WIA build output is missing: $wiaDllSource"
}
if (-not (Test-Path -LiteralPath $wiaInfTemplate -PathType Leaf)) {
    throw "WIA INF source template is missing: $wiaInfTemplate"
}
$wiaInfText = Get-Content -LiteralPath $wiaInfTemplate -Raw
$requiredInfEntries = @(
    '(?im)^Class=Image\s*$',
    '(?im)^CatalogFile=GeniusColorPageHR7Wia\.cat\s*$',
    '(?im)^PnpLockdown=1\s*$',
    '(?im)^%HR7\.DeviceDesc%=WIADRIVER\.Device,ROOT\\GENIUSCOLORPAGEHR7WIA\s*$'
)
foreach ($requiredInfEntry in $requiredInfEntries) {
    if ($wiaInfText -notmatch $requiredInfEntry) { throw "WIA INF template is missing a required x64 device/package entry: $requiredInfEntry" }
}
$wiaHelperSource = Get-Content -LiteralPath (Join-Path $windowsRoot 'WIA2\Installer\InstallHr7WiaDevice.cpp') -Raw
$expectedHelperVersion = '(?m)^\s*const wchar_t kPackageVersion\[\] = L"' + [regex]::Escape($BundleVersion) + '";\s*$'
if ($wiaHelperSource -notmatch $expectedHelperVersion) {
    throw "WIA installer helper version must remain synchronized with bundle version $BundleVersion."
}
if ($wiaInfText -notmatch '(?im)^%ManufacturerName%=Models,NTamd64(?:\.|\s|$)') {
    throw 'WIA INF template does not declare the x64 manufacturer model section.'
}
if ($wiaInfText -notmatch "(?im)^DriverVer=[^,\r\n]+,$([regex]::Escape($BundleVersion))\s*$") {
    throw "WIA INF DriverVer must remain synchronized with bundle version $BundleVersion."
}
New-Item -ItemType Directory -Path $wiaBuildOutput -Force | Out-Null
$wiaInfDate = Get-Date -Format 'MM/dd/yyyy'
$wiaInfText = [regex]::Replace($wiaInfText, "(?im)^DriverVer=[^,\r\n]+,$([regex]::Escape($BundleVersion))\s*$", "DriverVer=$wiaInfDate,$BundleVersion")
[IO.File]::WriteAllText($wiaInfSource, $wiaInfText, [Text.Encoding]::ASCII)
$wiaPackage = Join-Path $stageRoot 'wia-package'
New-Item -ItemType Directory -Path $wiaPackage | Out-Null
Copy-Item -LiteralPath $wiaInfSource -Destination $wiaPackage
Copy-Item -LiteralPath $wiaDllSource -Destination $wiaPackage
$wiaDll = Join-Path $wiaPackage 'wiadriverex.dll'
$wiaInf = Join-Path $wiaPackage 'GeniusColorPageHR7Wia.inf'
Sign-AndVerify -Path $wiaDll -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
Invoke-Checked -FilePath $inf2Cat -Arguments @(('/driver:' + $wiaPackage), '/os:10_X64') -Description 'Generate the WIA driver package catalog'
$wiaCat = Join-Path $wiaPackage 'GeniusColorPageHR7Wia.cat'
if (-not (Test-Path -LiteralPath $wiaCat -PathType Leaf)) { throw "Inf2Cat did not create $wiaCat" }
Sign-AndVerify -Path $wiaCat -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
Assert-AuthenticodeSignature -Path $wiaCat -SignTool $signTool -Thumbprint $SigningCertificateThumbprint `
    -VerifyArguments @('verify', '/pa', '/v', '/c', $wiaCat, $wiaInf) `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
foreach ($file in @($wiaInf, $wiaDll, $wiaCat)) { Copy-Item -LiteralPath $file -Destination (Join-Path $payloadRoot 'WIA') }

# Fetch only the exact SANEWinDS builds admitted by manifest.json. Burn will
# also verify these files against its bind-time payload hashes at install time.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($id in @('sanewinds-x86', 'sanewinds-x64')) {
    $artifact = $manifest.artifacts | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($null -eq $artifact) { throw "Pinned artifact is missing from manifest.json: $id" }
    try { $artifactUri = [Uri]$artifact.url }
    catch { throw "Pinned artifact has an invalid URL: $id" }
    if (-not $artifactUri.IsAbsoluteUri -or $artifactUri.Scheme -ne [Uri]::UriSchemeHttps -or
        [string]::IsNullOrWhiteSpace($artifactUri.Host)) {
        throw "Pinned artifact must use an absolute HTTPS URL: $id"
    }
    $arch = if ($id -eq 'sanewinds-x86') { 'x86' } else { 'x64' }
    $filename = "SANEWinDS_1.6.9221_$arch.msi"
    $destination = Join-Path $payloadRoot "third-party\$filename"
    $cachedPackage = Join-Path $saneWinDsPackageSource $filename
    if (Test-Path -LiteralPath $cachedPackage -PathType Leaf) {
        $cachedHash = Get-Sha256 -Path $cachedPackage
        if ($cachedHash -ne $artifact.sha256.ToLowerInvariant()) {
            throw "Cached SHA-256 mismatch for $id at $cachedPackage. Expected $($artifact.sha256), got $cachedHash."
        }
        Copy-Item -LiteralPath $cachedPackage -Destination $destination
    } else {
        Invoke-WebRequest -Uri $artifact.url -OutFile $destination -ErrorAction Stop
    }
    $actualHash = Get-Sha256 -Path $destination
    if ($actualHash -ne $artifact.sha256.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $id. Expected $($artifact.sha256), got $actualHash."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $destination
    if ($signature.Status -ne 'NotSigned') {
        throw "$filename changed its unsigned-signature status; review the pinned release before packaging."
    }
}

# The pinned vendor x86 MSI has Template Summary ';1033'. Windows Installer
# interprets the omitted platform as Intel/x86, but WiX 5 cannot infer that and
# treats it as x64. Correct only the private staged copy, change its PackageCode,
# and preserve both original and packaged hashes as build evidence.
$sanewindsX86Artifact = $manifest.artifacts | Where-Object { $_.id -eq 'sanewinds-x86' } | Select-Object -First 1
$sanewindsX86OriginalHash = $sanewindsX86Artifact.sha256.ToLowerInvariant()
$sanewindsX86Path = Join-Path $payloadRoot 'third-party\SANEWinDS_1.6.9221_x86.msi'
$sanewindsX86PackageCode = Get-DeterministicPackageCode -Seed "Genius-ColorPage-HR7/SANEWinDS-x86-Intel-summary-v1/$sanewindsX86OriginalHash"
$sanewindsX86Metadata = Repair-SaneWinDsX86Summary -Path $sanewindsX86Path -PackageCode $sanewindsX86PackageCode
$sanewindsX86PatchedHash = Get-Sha256 -Path $sanewindsX86Path
if ($sanewindsX86PatchedHash -eq $sanewindsX86OriginalHash) {
    throw 'The x86 SANEWinDS summary metadata correction did not alter the staged MSI as expected.'
}

$runtimeWixProject = Join-Path $PSScriptRoot 'WiX\Runtime.wixproj'
$bundleWixProject = Join-Path $PSScriptRoot 'WiX\Bundle.wixproj'
$runtimeWixOutput = Join-Path $stageRoot 'wix-runtime-output'
$runtimeWixIntermediate = Join-Path $stageRoot 'wix-runtime-obj'
$runtimeMsi = Join-Path $runtimeWixOutput 'GeniusColorPageHR7Runtime.msi'
Invoke-Checked -FilePath $dotnet -Arguments @(
    'build', $runtimeWixProject, '-c', 'Release', '-t:Rebuild',
    "-p:PayloadRoot=$payloadRoot", "-p:MsiVersion=$RuntimeMsiVersion",
    "-p:OutputPath=$runtimeWixOutput\", "-p:IntermediateOutputPath=$runtimeWixIntermediate\"
) -Description 'Build the x64 runtime MSI'
if (-not (Test-Path -LiteralPath $runtimeMsi -PathType Leaf)) { throw "Runtime MSI was not produced: $runtimeMsi" }
Sign-AndVerify -Path $runtimeMsi -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
$runtimeCopy = Join-Path $payloadRoot 'packages\GeniusColorPageHR7Runtime.msi'
Copy-Item -LiteralPath $runtimeMsi -Destination $runtimeCopy

$bundleWixOutput = Join-Path $stageRoot 'wix-bundle-output'
$bundleWixIntermediate = Join-Path $stageRoot 'wix-bundle-obj'
Invoke-Checked -FilePath $dotnet -Arguments @(
    'build', $bundleWixProject, '-c', 'Release', '-t:Rebuild',
    "-p:PayloadRoot=$payloadRoot",
    "-p:RuntimeMsiPath=$runtimeCopy",
    "-p:PreviousBundlePath=$stagedPreviousBundlePath",
    "-p:OutputPath=$bundleWixOutput\",
    "-p:IntermediateOutputPath=$bundleWixIntermediate\",
    "-p:BundleVersion=$BundleVersion"
) -Description 'Build the WiX Burn GUI bootstrapper'
$unsignedBundle = Join-Path $bundleWixOutput 'GeniusColorPageHR7Setup.exe'
if (-not (Test-Path -LiteralPath $unsignedBundle -PathType Leaf)) { throw "Burn bundle was not produced: $unsignedBundle" }

# WiX/MSBuild incremental checks do not account for all command-line payload
# property changes. Force Rebuild above and verify the final signed bundle's
# extracted bytes so stale attachments cannot pass as the current release.
$expectedBundlePayloads = @(
    (Join-Path $payloadRoot 'tools\WinUsbBinding.exe'),
    (Join-Path $payloadRoot 'tools\libwdi.dll'),
    $runtimeCopy,
    (Join-Path $payloadRoot 'tools\SaneServiceManager.exe'),
    (Join-Path $payloadRoot 'third-party\SANEWinDS_1.6.9221_x86.msi'),
    (Join-Path $payloadRoot 'third-party\SANEWinDS_1.6.9221_x64.msi'),
    (Join-Path $payloadRoot 'tools\TwainConfigManager.exe'),
    (Join-Path $payloadRoot 'tools\InstallHr7WiaDevice.exe'),
    $stagedPreviousBundlePath
)
$expectedBundleHashes = @($expectedBundlePayloads | ForEach-Object {
    if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Expected Burn payload is missing: $_" }
    Get-Sha256 -Path $_
} | Sort-Object)

$enginePath = Join-Path $OutputDirectory 'GeniusColorPageHR7Setup.engine.exe'
$signedEnginePath = Join-Path $OutputDirectory 'GeniusColorPageHR7Setup.engine.signed.exe'
$finalBundle = Join-Path $OutputDirectory 'GeniusColorPageHR7Setup.exe'
Invoke-Checked -FilePath $wix -Arguments @('burn', 'detach', $unsignedBundle, '-engine', $enginePath) -Description 'Detach the Burn engine for signing'
Sign-AndVerify -Path $enginePath -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
Copy-Item -LiteralPath $enginePath -Destination $signedEnginePath
Invoke-Checked -FilePath $wix -Arguments @('burn', 'reattach', $unsignedBundle, '-engine', $signedEnginePath, '-out', $finalBundle) `
    -Description 'Reattach the signed Burn engine'
Sign-AndVerify -Path $finalBundle -SignTool $signTool -Thumbprint $SigningCertificateThumbprint -TimestampUrl 'http://timestamp.digicert.com' `
    -AllowUntrustedRoot:$AllowUntrustedEvaluationSigning
$bundleValidationRoot = Join-Path $stageRoot 'bundle-validation-final'
if (Test-Path -LiteralPath $bundleValidationRoot) {
    throw "Bundle validation directory already exists; refusing to overwrite it: $bundleValidationRoot"
}
Invoke-Checked -FilePath $wix -Arguments @(
    'burn', 'extract', $finalBundle, '-o', $bundleValidationRoot
) -Description 'Extract the signed Burn bundle for payload verification'
$extractedBundleFiles = @(Get-ChildItem -LiteralPath $bundleValidationRoot -File -Recurse)
$actualBundleHashes = @($extractedBundleFiles | ForEach-Object {
    Get-Sha256 -Path $_.FullName
} | Sort-Object)
if ($actualBundleHashes.Count -ne $expectedBundleHashes.Count -or
    [string]::Join('|', $actualBundleHashes) -cne [string]::Join('|', $expectedBundleHashes)) {
    throw "Signed Burn bundle payload verification failed. Expected $($expectedBundleHashes.Count) current attachments, extracted $($actualBundleHashes.Count). The extracted payloads do not match this build's signed staging tree."
}

$releaseRecord = [ordered]@{
    bundle_version = $BundleVersion
    msi_version = $RuntimeMsiVersion
    bundle = [ordered]@{ path = $finalBundle; sha256 = (Get-Sha256 $finalBundle) }
    previous_bundle = [ordered]@{
        version = $previousBundleVersion
        path = $previousBundlePath
        sha256 = $previousBundleActualSha256
        signing_certificate_thumbprint = $previousBundleExpectedSigner
        embedded_in_bundle = $true
        chain_position = 1
        behavior = 'uninstalled before the current runtime and provider helpers; detect-only related-bundle registration prevents duplicate late uninstall'
    }
    runtime_msi = [ordered]@{ path = $runtimeCopy; sha256 = (Get-Sha256 $runtimeCopy); embedded_in_bundle = $true }
    bundle_payload_verification = [ordered]@{
        extracted_attachment_count = $actualBundleHashes.Count
        sha256 = $actualBundleHashes
        result = 'all extracted Burn attachments match the current signed staging payloads'
    }
    sanewinds_x86 = [ordered]@{
        original_sha256 = $sanewindsX86OriginalHash
        packaged_sha256 = $sanewindsX86PatchedHash
        summary_metadata = $sanewindsX86Metadata
    }
    sanewinds_x64_sha256 = Get-Sha256 (Join-Path $payloadRoot 'third-party\SANEWinDS_1.6.9221_x64.msi')
    signing_certificate_thumbprint = $SigningCertificateThumbprint
    evaluation_certificate = [ordered]@{
        public_certificate_path = $evaluationCertificatePath
        public_certificate_sha256 = $evaluationCertificateSha256
        thumbprint = $SigningCertificateThumbprint
        trust_scope = 'local machine only; certificate is not trusted by arbitrary Windows installations'
    }
    signing_trust_validation = if ($script:UntrustedEvaluationRootAccepted) {
        'PRIVATE EVALUATION: expected Authenticode signer and signature digests were checked; the root is not trusted here, so the package is not install-ready'
    } else {
        'SignTool Authenticode policy verification passed with a trusted certificate chain'
    }
    created_utc = [DateTime]::UtcNow.ToString('o')
    release_status = if ($script:UntrustedEvaluationRootAccepted) {
        'PRIVATE EVALUATION ONLY; the signer root is not trusted on this build machine, so this package must not be installed until local machine trust is configured'
    } elseif (Test-Path -LiteralPath $releaseApprovalPath -PathType Leaf) {
        'release-approved-input; still requires clean-machine install, rollback, WIA and x86/x64 TWAIN acquisition tests'
    } else {
        'PRIVATE EVALUATION ONLY; third-party source/license approval is not recorded'
    }
}
$releaseRecord | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release-artifacts.json') -Encoding UTF8
Write-Host "Signed GUI installer built: $finalBundle"
Write-Host "Release evidence: $(Join-Path $OutputDirectory 'release-artifacts.json')"

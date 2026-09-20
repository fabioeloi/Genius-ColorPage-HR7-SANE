[CmdletBinding()]
param(
    [string] $PreviousBundlePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal {
    param([object] $Actual, [object] $Expected, [string] $Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$bundlePath = Join-Path $repoRoot 'Windows\Installer\WiX\Bundle.wxs'
$bundleProjectPath = Join-Path $repoRoot 'Windows\Installer\WiX\Bundle.wixproj'
$runtimeProjectPath = Join-Path $repoRoot 'Windows\Installer\WiX\Runtime.wixproj'
$buildScriptPath = Join-Path $repoRoot 'Windows\Installer\Build-GuiInstaller.ps1'
$wiaHelperPath = Join-Path $repoRoot 'Windows\WIA2\Installer\InstallHr7WiaDevice.cpp'
$wiaInfPath = Join-Path $repoRoot 'Windows\WIA2\upstream\WiaDriver.inx'

[xml]$bundleXml = Get-Content -LiteralPath $bundlePath -Raw
$namespaces = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $bundleXml.NameTable
$namespaces.AddNamespace('w', 'http://wixtoolset.org/schemas/v4/wxs')
$bundle = $bundleXml.SelectSingleNode('/w:Wix/w:Bundle', $namespaces)
if (-not $bundle) { throw 'Bundle.wxs has no WiX Bundle root.' }
Assert-Equal $bundle.GetAttribute('Version') '$(var.BundleVersion)' 'Bundle version binding is wrong.'
Assert-Equal $bundle.GetAttribute('UpgradeCode') '{95F29C17-0F9F-4428-B844-B5A5BD905A37}' 'Bundle upgrade family changed unexpectedly.'

$relatedBundle = $bundle.SelectSingleNode('w:RelatedBundle', $namespaces)
if (-not $relatedBundle) { throw 'The predecessor bundle must be detected explicitly.' }
Assert-Equal $relatedBundle.GetAttribute('Id') $bundle.GetAttribute('UpgradeCode') 'Related bundle and bundle upgrade family differ.'
Assert-Equal $relatedBundle.GetAttribute('Action') 'Detect' 'The predecessor must not be uninstalled again after the package chain.'

$chain = $bundle.SelectSingleNode('w:Chain', $namespaces)
if (-not $chain) { throw 'Bundle.wxs has no Chain.' }
$packages = @($chain.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
$expectedPackageIds = @(
    'Hr7PreviousBundle', 'Hr7WinUsb', 'Hr7Runtime', 'Hr7SaneService',
    'SaneWinDsX86', 'SaneWinDsX64', 'Hr7TwainConfig', 'Hr7WiaDevice'
)
$actualPackageIds = @($packages | ForEach-Object { $_.GetAttribute('Id') })
if ([string]::Join('|', $actualPackageIds) -cne [string]::Join('|', $expectedPackageIds)) {
    throw "Unexpected Burn package order: $([string]::Join(' -> ', $actualPackageIds))"
}

$legacyPackage = $packages[0]
Assert-Equal $legacyPackage.LocalName 'BundlePackage' 'The first Burn package must remove the prior bundle.'
Assert-Equal $legacyPackage.GetAttribute('InstallCondition') '0' 'The prior bundle must be uninstall-only.'
Assert-Equal $legacyPackage.GetAttribute('SourceFile') '$(var.PreviousBundlePath)' 'The prior bundle input must be explicit.'
Assert-Equal $legacyPackage.GetAttribute('Vital') 'yes' 'Failure to remove the predecessor must abort the migration.'

$bundleProject = Get-Content -LiteralPath $bundleProjectPath -Raw
$runtimeProject = Get-Content -LiteralPath $runtimeProjectPath -Raw
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
$wiaHelper = Get-Content -LiteralPath $wiaHelperPath -Raw
$wiaInf = Get-Content -LiteralPath $wiaInfPath -Raw
Assert-Equal ([regex]::Match($bundleProject, '<BundleVersion[^>]*>([^<]+)</BundleVersion>').Groups[1].Value) '1.0.0.5' 'Bundle project default must match the migration.'
Assert-Equal ([regex]::Match($runtimeProject, '<MsiVersion[^>]*>([^<]+)</MsiVersion>').Groups[1].Value) '1.0.5' 'Runtime MSI default must advance.'
if ($wiaHelper -notmatch '(?m)^\s*const wchar_t kPackageVersion\[\] = L"1\.0\.0\.5";\s*$' -or
    $wiaInf -notmatch '(?im)^DriverVer=[^,\r\n]+,1\.0\.0\.5\s*$') {
    throw 'WIA helper and INF versions must both be 1.0.0.5.'
}
foreach ($requiredBuildInput in @(
    'PreviousBundlePath',
    '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c',
    '4E086470415F86AEAB2B55B06D5190B49C9ED2B7',
    '$stagedPreviousBundlePath'
)) {
    if ($buildScript -notlike "*$requiredBuildInput*") {
        throw "Build script is missing pinned predecessor validation: $requiredBuildInput"
    }
}
if ($buildScript -notmatch '(?m)^\s*msi_version\s*=\s*\$RuntimeMsiVersion\s*$') {
    throw 'The release manifest must serialize the MSI version as a string, not a System.Version object.'
}

if ($PreviousBundlePath) {
    $previousBundle = [IO.Path]::GetFullPath($PreviousBundlePath)
    if (-not (Test-Path -LiteralPath $previousBundle -PathType Leaf)) {
        throw "Predecessor bundle not found: $previousBundle"
    }
    $previousSha256 = (Get-FileHash -LiteralPath $previousBundle -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $previousSha256 '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c' 'Predecessor bundle hash is wrong.'
    $manifestPath = Join-Path (Split-Path -Parent $previousBundle) 'release-artifacts.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal $manifest.bundle_version '1.0.0.4' 'Predecessor manifest version is wrong.'
    Assert-Equal $manifest.bundle.sha256 '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c' 'Predecessor manifest hash is wrong.'
    Assert-Equal $manifest.signing_certificate_thumbprint '4E086470415F86AEAB2B55B06D5190B49C9ED2B7' 'Predecessor signer is wrong.'
    $signature = Get-AuthenticodeSignature -LiteralPath $previousBundle
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne '4E086470415F86AEAB2B55B06D5190B49C9ED2B7') {
        throw 'Predecessor bundle Authenticode validation failed.'
    }
}

Write-Host 'PASS: 1.0.0.5 migration is uninstall-first, detect-only, version-aligned, and predecessor-pinned.'

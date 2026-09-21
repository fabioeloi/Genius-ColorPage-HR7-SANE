[CmdletBinding()]
param(
    [string] $PreviousBundlePath,
    [string] $IntermediateBundlePath,
    [string] $LegacyBundlePath,
    [string] $StrandedBundlePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Equal {
    param([object] $Actual, [object] $Expected, [string] $Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-PinnedBundle {
    param(
        [string] $Path,
        [string] $Version,
        [string] $Sha256,
        [string] $SignerThumbprint
    )

    $bundle = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $bundle -PathType Leaf)) {
        throw "Migration bundle not found: $bundle"
    }
    $actualHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Equal $actualHash $Sha256 "The $Version migration bundle hash is wrong."

    $manifestPath = Join-Path (Split-Path -Parent $bundle) 'release-artifacts.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Migration bundle manifest not found: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal $manifest.bundle_version $Version "Migration manifest version is wrong for $bundle."
    Assert-Equal $manifest.bundle.sha256 $Sha256 "Migration manifest hash is wrong for $bundle."
    Assert-Equal $manifest.signing_certificate_thumbprint $SignerThumbprint "Migration manifest signer is wrong for $bundle."

    $signature = Get-AuthenticodeSignature -LiteralPath $bundle
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ine $SignerThumbprint) {
        throw "The $Version migration bundle Authenticode validation failed."
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
$namespaces.AddNamespace('u', 'http://wixtoolset.org/schemas/v4/wxs/util')
$bundle = $bundleXml.SelectSingleNode('/w:Wix/w:Bundle', $namespaces)
if (-not $bundle) { throw 'Bundle.wxs has no WiX Bundle root.' }
Assert-Equal $bundle.GetAttribute('Version') '$(var.BundleVersion)' 'Bundle version binding is wrong.'
Assert-Equal $bundle.GetAttribute('UpgradeCode') '{95F29C17-0F9F-4428-B844-B5A5BD905A37}' 'Bundle upgrade family changed unexpectedly.'

$relatedBundle = $bundle.SelectSingleNode('w:RelatedBundle', $namespaces)
if (-not $relatedBundle) { throw 'The predecessor bundle must be detected explicitly.' }
Assert-Equal $relatedBundle.GetAttribute('Id') $bundle.GetAttribute('UpgradeCode') 'Related bundle and bundle upgrade family differ.'
Assert-Equal $relatedBundle.GetAttribute('Action') 'Detect' 'Automatic late related-bundle cleanup must remain disabled.'

$chain = $bundle.SelectSingleNode('w:Chain', $namespaces)
if (-not $chain) { throw 'Bundle.wxs has no Chain.' }
$packages = @($chain.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
$expectedPackageIds = @(
    'SaneWinDsX86', 'SaneWinDsX64', 'Hr7Runtime',
    'Hr7WiaBefore006', 'Hr7PreviousBundle', 'Hr7WiaBefore005', 'Hr7IntermediateBundle',
    'Hr7WiaBefore004', 'Hr7LegacyBundle', 'Hr7WiaBefore007', 'Hr7StrandedBundle',
    'Hr7WinUsb', 'Hr7SaneService', 'Hr7TwainConfig', 'Hr7WiaDevice'
)
$actualPackageIds = @($packages | ForEach-Object { $_.GetAttribute('Id') })
if ([string]::Join('|', $actualPackageIds) -cne [string]::Join('|', $expectedPackageIds)) {
    throw "Unexpected Burn package order: $([string]::Join(' -> ', $actualPackageIds))"
}

foreach ($index in 0, 1) {
    Assert-Equal $packages[$index].LocalName 'MsiPackage' 'SANEWinDS packages must be first so their dependencies register before legacy cleanup.'
}
Assert-Equal $packages[2].GetAttribute('Id') 'Hr7Runtime' 'The current runtime must install before legacy cleanup so its WIA INF remains available.'

$wiaPreparations = @(
    [pscustomobject]@{ Package = $packages[3]; Id = 'Hr7WiaBefore006'; CacheId = 'HR7WiaBefore006_1_0_0_10'; PayloadName = 'tools\InstallHr7WiaDevice-prepare-006.exe'; Variable = 'HR7PreviousBundle006Installed' },
    [pscustomobject]@{ Package = $packages[5]; Id = 'Hr7WiaBefore005'; CacheId = 'HR7WiaBefore005_1_0_0_10'; PayloadName = 'tools\InstallHr7WiaDevice-prepare-005.exe'; Variable = 'HR7PreviousBundle005Installed' },
    [pscustomobject]@{ Package = $packages[7]; Id = 'Hr7WiaBefore004'; CacheId = 'HR7WiaBefore004_1_0_0_10'; PayloadName = 'tools\InstallHr7WiaDevice-prepare-004.exe'; Variable = 'HR7PreviousBundle004Installed' },
    [pscustomobject]@{ Package = $packages[9]; Id = 'Hr7WiaBefore007'; CacheId = 'HR7WiaBefore007_1_0_0_10'; PayloadName = 'tools\InstallHr7WiaDevice-prepare-007.exe'; Variable = 'HR7StrandedBundle007Installed' }
)
$wiaCacheIds = @()
$wiaPayloadNames = @()
foreach ($item in $wiaPreparations) {
    Assert-Equal $item.Package.LocalName 'ExePackage' "$($item.Id) must run the WIA staging helper before predecessor cleanup."
    Assert-Equal $item.Package.GetAttribute('CacheId') $item.CacheId "$($item.Id) needs a distinct Burn cache identity despite sharing the WIA helper executable."
    Assert-Equal $item.Package.GetAttribute('Name') $item.PayloadName "$($item.Id) needs a unique embedded payload name."
    $wiaCacheIds += $item.CacheId
    $wiaPayloadNames += $item.PayloadName
    Assert-Equal $item.Package.GetAttribute('SourceFile') '$(var.PayloadRoot)\tools\InstallHr7WiaDevice.exe' "$($item.Id) helper source is wrong."
    Assert-Equal $item.Package.GetAttribute('DetectCondition') '0' "$($item.Id) must re-stage WIA on each cleanup pass."
    Assert-Equal $item.Package.GetAttribute('InstallCondition') $item.Variable "$($item.Id) should run only for its installed predecessor."
    Assert-Equal $item.Package.GetAttribute('InstallArguments') 'install "[HR7InstallFolder]\WIA\GeniusColorPageHR7Wia.inf"' "$($item.Id) must install the current WIA package."
    Assert-Equal $item.Package.GetAttribute('UninstallArguments') 'remove "[HR7InstallFolder]\WIA\GeniusColorPageHR7Wia.inf"' "$($item.Id) must be reversible if Burn rolls back."
    Assert-Equal $item.Package.GetAttribute('PerMachine') 'yes' 'WIA preparation must execute elevated.'
    Assert-Equal $item.Package.GetAttribute('Vital') 'yes' 'WIA preparation failures must stop cleanup.'
}
$finalWia = $bundle.SelectSingleNode("w:Chain/w:ExePackage[@Id='Hr7WiaDevice']", $namespaces)
if (-not $finalWia) { throw 'The final WIA device package is missing.' }
Assert-Equal $finalWia.GetAttribute('CacheId') 'HR7WiaDevice_1_0_0_10' 'The final WIA device package needs a distinct Burn cache identity.'
Assert-Equal $finalWia.GetAttribute('Name') 'tools\InstallHr7WiaDevice.exe' 'The final WIA device package payload name changed unexpectedly.'
$wiaCacheIds += $finalWia.GetAttribute('CacheId')
$wiaPayloadNames += $finalWia.GetAttribute('Name')
if (@($wiaCacheIds | Select-Object -Unique).Count -ne $wiaCacheIds.Count) {
    throw 'Every WIA helper package instance must have a unique Burn CacheId.'
}
if (@($wiaPayloadNames | Select-Object -Unique).Count -ne $wiaPayloadNames.Count) {
    throw 'Every WIA helper package instance must have a unique embedded payload Name.'
}

$predecessors = @(
    [pscustomobject]@{ Package = $packages[4]; Source = '$(var.PreviousBundlePath)'; Name = '1.0.0.6'; Variable = 'HR7PreviousBundle006Installed' },
    [pscustomobject]@{ Package = $packages[6]; Source = '$(var.IntermediateBundlePath)'; Name = '1.0.0.5'; Variable = 'HR7PreviousBundle005Installed' },
    [pscustomobject]@{ Package = $packages[8]; Source = '$(var.LegacyBundlePath)'; Name = '1.0.0.4'; Variable = 'HR7PreviousBundle004Installed' },
    [pscustomobject]@{ Package = $packages[10]; Source = '$(var.StrandedBundlePath)'; Name = '1.0.0.7'; Variable = 'HR7StrandedBundle007Installed' }
)
foreach ($item in $predecessors) {
    Assert-Equal $item.Package.LocalName 'ExePackage' 'Pinned predecessors must use generic EXE cleanup to avoid Burn BundlePackage dependency suppression.'
    Assert-Equal $item.Package.GetAttribute('Bundle') 'no' "The $($item.Name) cleanup EXE must not be dependency-managed as a BundlePackage."
    Assert-Equal $item.Package.GetAttribute('Protocol') 'none' "The $($item.Name) cleanup EXE must remain an opaque one-shot package."
    Assert-Equal $item.Package.GetAttribute('InstallCondition') '0' "The $($item.Name) predecessor must be uninstall-only."
    Assert-Equal $item.Package.GetAttribute('SourceFile') $item.Source "The $($item.Name) predecessor input must be explicit."
    Assert-Equal $item.Package.GetAttribute('DetectCondition') $item.Variable "The $($item.Name) cleanup must run only when that bundle is registered."
    Assert-Equal $item.Package.GetAttribute('InstallArguments') '-quiet -norestart' "The $($item.Name) bundle rollback install must remain quiet and avoid forced restart."
    Assert-Equal $item.Package.GetAttribute('UninstallArguments') '-quiet -norestart -uninstall -burn.related.upgrade' "The $($item.Name) bundle cleanup must be a silent uninstall with Burn related-upgrade semantics."
    Assert-Equal $item.Package.GetAttribute('PerMachine') 'yes' 'Predecessor cleanup must execute elevated.'
    Assert-Equal $item.Package.GetAttribute('Vital') 'yes' "Failure to remove the $($item.Name) predecessor must abort migration."
}

foreach ($variable in 'HR7PreviousBundle004Installed', 'HR7PreviousBundle005Installed', 'HR7PreviousBundle006Installed', 'HR7StrandedBundle007Installed', 'HR7RecoveryBundle008Installed') {
    $search = $bundle.SelectSingleNode("u:RegistrySearch[@Variable='$variable']", $namespaces)
    if (-not $search -or $search.GetAttribute('Result') -cne 'exists') {
        throw "Missing registration search used to force helper reinstallation: $variable"
    }
}
$forceReinstall = 'AND NOT \(HR7PreviousBundle004Installed OR HR7PreviousBundle005Installed OR HR7PreviousBundle006Installed OR HR7StrandedBundle007Installed OR HR7RecoveryBundle008Installed\)'
foreach ($packageId in 'Hr7WinUsb', 'Hr7SaneService', 'Hr7TwainConfig', 'Hr7WiaDevice') {
    $package = $bundle.SelectSingleNode("w:Chain/w:ExePackage[@Id='$packageId']", $namespaces)
    if (-not $package -or $package.GetAttribute('DetectCondition') -notmatch $forceReinstall) {
        throw "$packageId must be reinstalled after either legacy bundle is removed."
    }
}

$bundleProject = Get-Content -LiteralPath $bundleProjectPath -Raw
$runtimeProject = Get-Content -LiteralPath $runtimeProjectPath -Raw
$buildScript = Get-Content -LiteralPath $buildScriptPath -Raw
$wiaHelper = Get-Content -LiteralPath $wiaHelperPath -Raw
$wiaInf = Get-Content -LiteralPath $wiaInfPath -Raw
Assert-Equal ([regex]::Match($bundleProject, '<BundleVersion[^>]*>([^<]+)</BundleVersion>').Groups[1].Value) '1.0.0.10' 'Bundle project default must match the recovery build.'
Assert-Equal ([regex]::Match($runtimeProject, '<MsiVersion[^>]*>([^<]+)</MsiVersion>').Groups[1].Value) '1.0.10' 'Runtime MSI default must advance.'
if ($wiaHelper -notmatch '(?m)^\s*const wchar_t kPackageVersion\[\] = L"1\.0\.0\.10";\s*$' -or
    $wiaInf -notmatch '(?im)^DriverVer=[^,\r\n]+,1\.0\.0\.10\s*$') {
    throw 'WIA helper and INF versions must both be 1.0.0.10.'
}
if ($wiaHelper -notmatch 'ERROR_NO_MORE_ITEMS' -or $wiaHelper -notmatch 'IsHr7DriverAtLeastPackageVersion' -or
    $wiaHelper -notmatch 'ProviderName' -or $wiaHelper -notmatch 'DriverVersion') {
    throw 'The WIA retry path must accept an already-active matching HR7 driver only after identity and version validation.'
}
foreach ($requiredBuildInput in @(
    'PreviousBundlePath', 'IntermediateBundlePath', 'LegacyBundlePath', 'StrandedBundlePath',
    '59475398154caf87c3767b0a2c692f6a2e23e62fdf4d98dbe2bb353306571e62',
    '2af78e0ee8c9be8102e24dbf0a1193a1c3007ea79c0aedfa41417941914d15fb',
    '1E5EAF5313805BC85012B350720715C3B3954EA3',
    '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c',
    '4E086470415F86AEAB2B55B06D5190B49C9ED2B7',
    '7e96dcceaf591caf792e22cbc8d04141bad001d906d6603465fefe00a6ebf108',
    'predecessorBundles[0].StagedPath', 'predecessorBundles[1].StagedPath', 'predecessorBundles[2].StagedPath', 'predecessorBundles[3].StagedPath',
    'Get-MsiRootModifiedTime', 'Set-MsiRootModifiedTime'
)) {
    if ($buildScript.IndexOf($requiredBuildInput, [StringComparison]::Ordinal) -lt 0) {
        throw "Build script is missing pinned migration input validation: $requiredBuildInput"
    }
}
if ($buildScript -notmatch '(?m)^\s*msi_version\s*=\s*\$RuntimeMsiVersion\s*$') {
    throw 'The release manifest must serialize the MSI version as a string, not a System.Version object.'
}

if ($PreviousBundlePath -or $IntermediateBundlePath -or $LegacyBundlePath -or $StrandedBundlePath) {
    if (-not $PreviousBundlePath -or -not $IntermediateBundlePath -or -not $LegacyBundlePath -or -not $StrandedBundlePath) {
        throw 'All four predecessor paths are required for provenance validation.'
    }
    Assert-PinnedBundle -Path $PreviousBundlePath -Version '1.0.0.6' `
        -Sha256 '59475398154caf87c3767b0a2c692f6a2e23e62fdf4d98dbe2bb353306571e62' `
        -SignerThumbprint '1E5EAF5313805BC85012B350720715C3B3954EA3'
    Assert-PinnedBundle -Path $IntermediateBundlePath -Version '1.0.0.5' `
        -Sha256 '2af78e0ee8c9be8102e24dbf0a1193a1c3007ea79c0aedfa41417941914d15fb' `
        -SignerThumbprint '1E5EAF5313805BC85012B350720715C3B3954EA3'
    Assert-PinnedBundle -Path $LegacyBundlePath -Version '1.0.0.4' `
        -Sha256 '97ea116ea5063ef2c23188440d07c87890d7f53372f3a8c0c5edf194cd683e8c' `
        -SignerThumbprint '4E086470415F86AEAB2B55B06D5190B49C9ED2B7'
    Assert-PinnedBundle -Path $StrandedBundlePath -Version '1.0.0.7' `
        -Sha256 '7e96dcceaf591caf792e22cbc8d04141bad001d906d6603465fefe00a6ebf108' `
        -SignerThumbprint '1E5EAF5313805BC85012B350720715C3B3954EA3'
}

Write-Host 'PASS: 1.0.0.10 installs the runtime, re-stages WIA before each predecessor cleanup, then repairs helpers afterward.'

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE'),
    [switch] $InstallPackages,
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Hr7Administrator
$null = Assert-Hr7WindowsX64

$stateDirectory = [IO.Path]::GetFullPath($StateDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
$logPath = Join-Path $stateDirectory 'logs\sanewinds.log'
$downloadDirectory = Join-Path $stateDirectory 'sources'
$configDirectory = Join-Path $env:ProgramData 'SANEWinDS'
$configPath = Join-Path $configDirectory 'SANEWinDS.ini'
$templatePath = Join-Path $PackageRoot 'Windows\config\SANEWinDS.ini'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath), $downloadDirectory, $configDirectory | Out-Null
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "SANEWinDS configuration template is missing: $templatePath"
}

$manifest = Get-Hr7Manifest -PackageRoot $PackageRoot
$artifacts = @(
    (Get-Hr7Artifact -Manifest $manifest -Id 'sanewinds-x64'),
    (Get-Hr7Artifact -Manifest $manifest -Id 'sanewinds-x86')
)

if ($InstallPackages) {
    if (-not $AllowUnsigned) {
        throw 'SANEWinDS MSI files are currently unsigned. Pass -AllowUnsigned only for an explicitly approved local evaluation.'
    }
    foreach ($artifact in $artifacts) {
        $filename = if ($artifact.id -eq 'sanewinds-x64') { 'SANEWinDS_1.6.9221_x64.msi' } else { 'SANEWinDS_1.6.9221_x86.msi' }
        $destination = Join-Path $downloadDirectory $filename
        Get-Hr7VerifiedDownload -Uri $artifact.url -Destination $destination -ExpectedSha256 $artifact.sha256 | Out-Null
        $signature = Get-AuthenticodeSignature -LiteralPath $destination
        if ($signature.Status -ne 'Valid' -and -not ($AllowUnsigned -and $signature.Status -eq 'NotSigned')) {
            throw "SANEWinDS signature policy rejected ${destination}: $($signature.Status)"
        }
        $install = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $destination, '/qn', '/norestart') -Wait -PassThru -WindowStyle Hidden
        if ($install.ExitCode -ne 0) {
            throw "SANEWinDS MSI installation failed for $destination (exit $($install.ExitCode))."
        }
        Write-Hr7Log -LogPath $logPath -Message "Installed $($artifact.id) $($artifact.version); Authenticode=$($signature.Status); SHA256=$($artifact.sha256)"
    }
}

$backupPath = Join-Path $stateDirectory 'sane-winds\SANEWinDS.ini.before-package'
if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and -not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
    Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
}
Copy-Item -LiteralPath $templatePath -Destination $configPath -Force

# SANEWinDS 1.6.9221 reads the host list from the per-user SANEWinDS.ini and
# does not reliably fall back to the shared ProgramData copy when a user file
# already exists. Seed existing profiles and the Default profile so a normal
# TWAIN client can open the source without a command-line first-run step.
$profileRoots = [System.Collections.Generic.List[string]]::new()
foreach ($root in @(
    [Environment]::GetFolderPath('ApplicationData'),
    [Environment]::GetFolderPath('LocalApplicationData')
)) {
    if (-not [string]::IsNullOrWhiteSpace($root)) { $profileRoots.Add($root) }
}
$usersRoot = Join-Path $env:SystemDrive 'Users'
if (Test-Path -LiteralPath $usersRoot -PathType Container) {
    foreach ($profile in Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue) {
        if ($profile.Name -in @('Public', 'All Users')) { continue }
        foreach ($relative in @('AppData\Roaming', 'AppData\Local')) {
            $candidate = Join-Path $profile.FullName $relative
            if (Test-Path -LiteralPath $candidate -PathType Container) { $profileRoots.Add($candidate) }
        }
    }
}
$userConfigPaths = @($profileRoots | Select-Object -Unique | ForEach-Object { Join-Path $_ 'SANEWinDS\SANEWinDS.ini' })
$userBackups = @()
foreach ($userConfigPath in $userConfigPaths) {
    $userDirectory = Split-Path -Parent $userConfigPath
    New-Item -ItemType Directory -Force -Path $userDirectory | Out-Null
    if (Test-Path -LiteralPath $userConfigPath -PathType Leaf) {
        $safeName = (($userConfigPath -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
        $userBackup = Join-Path $stateDirectory ("sane-winds\user-configs\$safeName.before-package")
        if (-not (Test-Path -LiteralPath $userBackup -PathType Leaf)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $userBackup) | Out-Null
            Copy-Item -LiteralPath $userConfigPath -Destination $userBackup -Force
        }
        $userBackups += $userBackup
    }
    Copy-Item -LiteralPath $templatePath -Destination $userConfigPath -Force
}

$twain32 = Join-Path $env:WINDIR 'twain_32\SANEWinDS\SANEWinCDS32.ds'
$twain64 = Join-Path $env:WINDIR 'twain_64\SANEWinDS\SANEWinCDS64.ds'
if (-not (Test-Path -LiteralPath $twain32 -PathType Leaf) -or -not (Test-Path -LiteralPath $twain64 -PathType Leaf)) {
    throw "Both SANEWinDS TWAIN data sources are required: $twain32 and $twain64"
}

$metadata = [ordered]@{
    configured_at_utc = [DateTime]::UtcNow.ToString('o')
    config_path = $configPath
    host = '127.0.0.1'
    port = 6566
    twain_x86 = $twain32
    twain_x64 = $twain64
    user_configs = @($userConfigPaths)
    user_config_backups = @($userBackups)
    artifacts = @($artifacts | ForEach-Object { [ordered]@{ id = $_.id; version = $_.version; sha256 = $_.sha256 } })
}
$statePath = Join-Path $stateDirectory 'state.json'
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Hr7State -StatePath $statePath
    $state | Add-Member -Force -NotePropertyName sanewinds -NotePropertyValue $metadata
    Save-Hr7State -State $state -StatePath $statePath
}
Write-Hr7Log -LogPath $logPath -Message "Configured SANEWinDS for 127.0.0.1:6566; TWAIN x86/x64 data sources verified."
Write-Output "SANEWinDS configured: $configPath"

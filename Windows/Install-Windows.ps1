#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $SkipDriverBinding,
    [switch] $Resume,
    [switch] $NoRestorePoint
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-Hr7Administrator
$os = Assert-Hr7WindowsX64
$packageRoot = Split-Path -Parent $PSScriptRoot
$stateDirectory = Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE'
$statePath = Join-Path $stateDirectory 'state.json'
$logsDirectory = Join-Path $stateDirectory 'logs'
$sourcesDirectory = Join-Path $stateDirectory 'sources'
$cygwinRoot = Join-Path $stateDirectory 'cygwin'
$cygwinCache = Join-Path $stateDirectory 'cygwin-cache'

if ((Test-Path -LiteralPath $statePath) -and -not $Resume) {
    throw "Já existe uma instalação registrada em $statePath. Execute Uninstall-Windows.ps1 antes de instalar novamente."
}

$devices = @(Get-Hr7UsbDevices)
if ($devices.Count -ne 1) {
    throw "Conecte diretamente exatamente um Genius ColorPage HR7 (USB 0458:2013). Encontrados: $($devices.Count)"
}

New-Item -ItemType Directory -Force -Path $logsDirectory, $sourcesDirectory, $cygwinCache | Out-Null
$installLog = Join-Path $logsDirectory 'install.log'
Write-Hr7Log -LogPath $installLog -Message "Starting on $($os.Caption) $($os.Version), x64=$([Environment]::Is64BitOperatingSystem)"

if (-not (Test-Path -LiteralPath $statePath)) {
$state = [ordered]@{
    package = 'Genius ColorPage-HR7 SANE'
    installed_at_utc = [DateTime]::UtcNow.ToString('o')
    package_root = $packageRoot
    state_directory = $stateDirectory
    cygwin_root = $cygwinRoot
    windows = [ordered]@{ caption = $os.Caption; version = $os.Version; architecture = $os.OSArchitecture }
    device_before = Get-Hr7DriverSnapshot -Device $devices[0]
    restore_point = [ordered]@{ attempted = $false; created = $false; message = $null }
}

if (-not $NoRestorePoint) {
    $state.restore_point.attempted = $true
    try {
        Checkpoint-Computer -Description 'Before Genius ColorPage HR7 WinUSB association' -RestorePointType 'MODIFY_SETTINGS'
        $state.restore_point.created = $true
        $state.restore_point.message = 'Requested successfully.'
        Write-Hr7Log -LogPath $installLog -Message 'System restore point requested successfully.'
    }
    catch {
        $state.restore_point.message = $_.Exception.Message
        Write-Hr7Log -LogPath $installLog -Message "Restore point was not created: $($_.Exception.Message)"
    }
}
Save-Hr7State -State $state -StatePath $statePath
}
else {
    $state = Get-Hr7State -StatePath $statePath
    if ($state.cygwin_root -ne $cygwinRoot -or $state.device_before.instance_id -ne $devices[0].InstanceId) {
        throw 'Resume state does not match this runtime and connected scanner.'
    }
}

if (-not $SkipDriverBinding) {
    & (Join-Path $PSScriptRoot 'Configure-HR7-Driver.ps1') -PackageRoot $packageRoot -StateDirectory $stateDirectory
}
else {
    Write-Hr7Log -LogPath $installLog -Message 'Driver association was explicitly skipped. SANE may not reach the scanner until WinUSB is associated.'
}

$manifest = Get-Hr7Manifest -PackageRoot $packageRoot
$cygwin = Get-Hr7Artifact -Manifest $manifest -Id 'cygwin-bootstrap'
$cygwinSetupPath = Join-Path $sourcesDirectory 'setup-x86_64.exe'
if (-not (Test-Path -LiteralPath $cygwinSetupPath -PathType Leaf)) {
    Invoke-WebRequest -Uri $cygwin.url -OutFile $cygwinSetupPath -ErrorAction Stop
}
$cygwinSignature = Get-AuthenticodeSignature -LiteralPath $cygwinSetupPath
$cygwinSubject = if ($null -eq $cygwinSignature.SignerCertificate) { '' } else { $cygwinSignature.SignerCertificate.Subject }
if ($cygwinSignature.Status -ne 'Valid' -or $cygwinSubject -notmatch '^CN=Jon Turney,') {
    throw "O bootstrap Cygwin não possui assinatura Authenticode válida de Cygwin. Status=$($cygwinSignature.Status); Subject=$cygwinSubject"
}
$bootstrapHash = (Get-FileHash -LiteralPath $cygwinSetupPath -Algorithm SHA512).Hash
if ($bootstrapHash -ne $cygwin.sha512) { throw 'Cygwin bootstrap SHA512 does not match the verified official release.' }

$packages = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cygwin-packages.txt') |
    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }
$setupArguments = @('-q', '-s', 'https://mirrors.kernel.org/sourceware/cygwin/', '-R', $cygwinRoot, '-l', $cygwinCache, '-P', ($packages -join ','))
Write-Hr7Log -LogPath $installLog -Message 'Installing required Cygwin x64 packages. Cygwin validates its signed package catalog.'
$setupProcess = Start-Process -FilePath $cygwinSetupPath -ArgumentList $setupArguments -WindowStyle Hidden -Wait -PassThru
if ($setupProcess.ExitCode -ne 0) {
    throw "Cygwin setup failed with exit code $($setupProcess.ExitCode)."
}

$bashPath = Join-Path $cygwinRoot 'bin\bash.exe'
if (-not (Test-Path -LiteralPath $bashPath -PathType Leaf)) {
    throw "Cygwin bash was not installed at $bashPath"
}
$cygwinPackageStatus = & $bashPath -lc 'uname -sr; cygcheck -c cygwin bash coreutils tar gzip make gcc-core pkg-config autoconf automake libtool libusb1.0-devel libjpeg-devel libpng-devel libtiff-devel zlib-devel libgtk2.0-devel liblcms2-devel gettext-devel xinit xorg-server xhost xterm dbus-x11' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Could not record the installed Cygwin package versions. Exit code: $LASTEXITCODE"
}
Write-Hr7Log -LogPath $installLog -Message ('Cygwin runtime and package versions: ' + ($cygwinPackageStatus -join '; '))

$sane = Get-Hr7Artifact -Manifest $manifest -Id 'sane-backends'
$xsane = Get-Hr7Artifact -Manifest $manifest -Id 'xsane'
$saneTarball = Get-Hr7VerifiedDownload -Uri $sane.url -Destination (Join-Path $sourcesDirectory 'backends-1.4.0.tar.gz') -ExpectedSha256 $sane.sha256
$xsaneTarball = Get-Hr7VerifiedDownload -Uri $xsane.url -Destination (Join-Path $sourcesDirectory 'xsane-0.999.tar.gz') -ExpectedSha256 $xsane.sha256

$cygwinBuild = ConvertTo-Hr7CygwinPath -BashPath $bashPath -WindowsPath (Join-Path $PSScriptRoot 'build-cygwin.sh')
$cygwinSane = ConvertTo-Hr7CygwinPath -BashPath $bashPath -WindowsPath $saneTarball
$cygwinXsane = ConvertTo-Hr7CygwinPath -BashPath $bashPath -WindowsPath $xsaneTarball
$buildLog = Join-Path $logsDirectory 'build-cygwin.log'
Write-Hr7Log -LogPath $installLog -Message 'Building SANE 1.4.0 with BACKENDS=plustek and XSane 0.999.'
& $bashPath -lc 'exec bash "$@" 2>&1' bash $cygwinBuild $cygwinSane $cygwinXsane '/opt/genius-hr7' | Tee-Object -FilePath $buildLog
if ($LASTEXITCODE -ne 0) {
    throw "The SANE/XSane build failed. See $buildLog"
}

$scanimagePath = Join-Path $cygwinRoot 'opt\genius-hr7\bin\scanimage.exe'
$xsanePath = Join-Path $cygwinRoot 'opt\genius-hr7\bin\xsane.exe'
if (-not (Test-Path -LiteralPath $scanimagePath) -or -not (Test-Path -LiteralPath $xsanePath)) {
    throw 'The expected private SANE or XSane executable was not produced.'
}

$launcher = Join-Path $PSScriptRoot 'Launch-XSane.ps1'
$shortcutPath = Join-Path $env:PUBLIC 'Desktop\Genius ColorPage HR7 Scan.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Join-Path $PSHOME 'powershell.exe')
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Open XSane configured only for Genius ColorPage HR7'
$shortcut.Save()

$state = Get-Hr7State -StatePath $statePath
$state | Add-Member -Force -NotePropertyName cygwin_setup_signer -NotePropertyValue $cygwinSubject
$state | Add-Member -Force -NotePropertyName sources -NotePropertyValue @(
    [ordered]@{ id = 'cygwin-bootstrap'; version = $cygwin.version; signer = $cygwinSubject },
    [ordered]@{ id = 'sane-backends'; version = $sane.version; sha256 = $sane.sha256 },
    [ordered]@{ id = 'xsane'; version = $xsane.version; sha256 = $xsane.sha256 }
)
$state | Add-Member -Force -NotePropertyName cygwin_package_versions -NotePropertyValue @($cygwinPackageStatus)
$state | Add-Member -Force -NotePropertyName shortcut -NotePropertyValue $shortcutPath
Save-Hr7State -State $state -StatePath $statePath
Write-Hr7Log -LogPath $installLog -Message "Installation completed. Use $shortcutPath and then run Diagnose-Windows.ps1."
Write-Host 'Instalação concluída. Execute Diagnose-Windows.ps1 antes da primeira digitalização.'

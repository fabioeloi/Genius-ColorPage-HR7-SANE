#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Remove')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $StateDirectory,

    [Parameter(Mandatory)]
    [string] $CygwinRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-Hr7Administrator

$serviceName = 'GeniusColorPage-HR7-SANE'
$fullStateDirectory = [IO.Path]::GetFullPath($StateDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
$fullCygwinRoot = [IO.Path]::GetFullPath($CygwinRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$expectedCygwinRoot = Join-Path $fullStateDirectory 'cygwin'
if (-not $fullCygwinRoot.Equals($expectedCygwinRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to manage a SANE service outside the package runtime: $fullCygwinRoot"
}

$cygrunsrvPath = Join-Path $fullCygwinRoot 'bin\cygrunsrv.exe'
$sanedPath = Join-Path $fullCygwinRoot 'opt\genius-hr7\sbin\saned.exe'
$sanedConfigPath = Join-Path $fullCygwinRoot 'opt\genius-hr7\etc\sane.d\saned.conf'
$logPath = Join-Path $fullStateDirectory 'logs\install.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
if (-not (Test-Path -LiteralPath $cygrunsrvPath -PathType Leaf)) {
    throw "Cygwin service manager is missing: $cygrunsrvPath"
}

$existing = Get-CimInstance -ClassName Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    $expectedRunner = [IO.Path]::GetFullPath($cygrunsrvPath)
    if ([string]$existing.PathName -notmatch [regex]::Escape($expectedRunner)) {
        throw "A service named $serviceName already exists but is not owned by this package runtime."
    }
}

if ($Action -eq 'Remove') {
    if ($null -eq $existing) {
        Write-Hr7Log -LogPath $logPath -Message 'No package-owned SANE service was registered.'
        return
    }

    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $serviceName -Force -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
    }

    & $cygrunsrvPath --remove $serviceName
    if ($LASTEXITCODE -ne 0) {
        throw "Cygwin could not remove service $serviceName (exit $LASTEXITCODE)."
    }
    Write-Hr7Log -LogPath $logPath -Message 'Stopped and removed the package-owned loopback SANE service.'
    return
}

if (-not (Test-Path -LiteralPath $sanedPath -PathType Leaf)) {
    throw "SANE daemon is missing: $sanedPath"
}
if (-not (Test-Path -LiteralPath $sanedConfigPath -PathType Leaf)) {
    throw "Loopback access policy is missing: $sanedConfigPath"
}
$allowedHosts = @(Get-Content -LiteralPath $sanedConfigPath -Encoding utf8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($allowedHosts.Count -ne 1) {
    throw 'The saned access list must contain only 127.0.0.1.'
}
if ($allowedHosts[0] -ne '127.0.0.1') {
    throw 'The saned access list must contain only 127.0.0.1.'
}

if ($null -eq $existing) {
    $existingListeners = @(Get-NetTCPConnection -State Listen -LocalPort 6566 -ErrorAction SilentlyContinue)
    if ($existingListeners.Count -gt 0) {
        throw 'TCP port 6566 already has a listener; refusing to start a second SANE service.'
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $fullCygwinRoot 'var\log') | Out-Null
    $serviceArguments = @(
        '--install', $serviceName,
        '--disp', 'Genius ColorPage HR7 SANE',
        '--desc', 'Local SANE bridge endpoint; listens on IPv4 loopback only.',
        '--path', $sanedPath,
        '--args', '-l -b 127.0.0.1 -p 6566 -e',
        '--env', 'PATH=/opt/genius-hr7/bin:/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane:/usr/bin:/bin',
        '--env', 'LD_LIBRARY_PATH=/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane',
        '--env', 'SANE_CONFIG_DIR=/opt/genius-hr7/etc/sane.d',
        '--stdout', '/var/log/hr7-saned.log',
        '--stderr', '/var/log/hr7-saned.log',
        '--type', 'auto',
        '--timeout', '30',
        '--stop-timeout', '30',
        '--shutdown'
    )
    & $cygrunsrvPath @serviceArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Cygwin could not register service $serviceName (exit $LASTEXITCODE)."
    }
    $createdService = $true
}
else {
    $createdService = $false
}

try {
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Start-Service -Name $serviceName -ErrorAction Stop
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 6566 -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($listeners.Count -ne 1) {
        throw 'The SANE service did not establish exactly one listener on 127.0.0.1:6566.'
    }
    if ([string]$listeners[0].LocalAddress -ne '127.0.0.1') {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        throw 'The SANE service did not establish exactly one listener on 127.0.0.1:6566.'
    }
}
catch {
    if ($createdService) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        & $cygrunsrvPath --remove $serviceName 2>$null | Out-Null
    }
    elseif ($null -ne $existing) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    }
    throw
}

Write-Hr7Log -LogPath $logPath -Message 'SANE service is running with a verified 127.0.0.1:6566 listener and no firewall rule.'

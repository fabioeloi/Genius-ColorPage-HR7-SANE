#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE'),
    [switch] $InstallTwainPackages,
    [switch] $AllowUnsignedTwain
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-Hr7Administrator
$null = Assert-Hr7WindowsX64

$stateDirectory = [IO.Path]::GetFullPath($StateDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
$statePath = Join-Path $stateDirectory 'state.json'
$logPath = Join-Path $stateDirectory 'logs\providers.log'
$serviceName = 'GeniusColorPage-HR7-SANE'
$twainScript = Join-Path $PSScriptRoot 'Configure-SANEWinDS.ps1'
$programDataIni = Join-Path $env:ProgramData 'SANEWinDS\SANEWinDS.ini'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "A instalação base não está registrada em $statePath. Execute o instalador base antes de configurar os provedores."
}
if (-not (Test-Path -LiteralPath $twainScript -PathType Leaf)) {
    throw "O configurador TWAIN não foi encontrado: $twainScript"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
$devices = @(Get-Hr7UsbDevices)
if ($devices.Count -ne 1) {
    throw "Conecte exatamente um Genius ColorPage HR7 (USB 0458:2013). Encontrados: $($devices.Count)"
}
$deviceSnapshot = Get-Hr7DriverSnapshot -Device $devices[0]
if ([string]$deviceSnapshot.driver_service -notmatch 'WinUSB') {
    throw "O HR7 não está associado ao WinUSB (service=$($deviceSnapshot.driver_service)). Corrija a associação do dispositivo antes de configurar os provedores."
}

$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -ne 'Running') {
    throw "O serviço $serviceName não está em execução (status=$($service.Status))."
}
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort 6566 -ErrorAction SilentlyContinue)
if ($listeners.Count -ne 1 -or [string]$listeners[0].LocalAddress -ne '127.0.0.1') {
    throw 'A configuração exige exatamente um listener IPv4 em 127.0.0.1:6566; nenhum endpoint de LAN será aceito.'
}

$twainArguments = @('-PackageRoot', $PackageRoot, '-StateDirectory', $stateDirectory)
if ($InstallTwainPackages) { $twainArguments += '-InstallPackages' }
if ($AllowUnsignedTwain) { $twainArguments += '-AllowUnsigned' }
& $twainScript @twainArguments

$twain32 = Join-Path $env:WINDIR 'twain_32\SANEWinDS\SANEWinCDS32.ds'
$twain64 = Join-Path $env:WINDIR 'twain_64\SANEWinDS\SANEWinCDS64.ds'
foreach ($path in @($twain32, $twain64)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "A fonte TWAIN esperada não foi instalada: $path"
    }
}
if (-not (Test-Path -LiteralPath $programDataIni -PathType Leaf)) {
    throw "A configuração compartilhada do SANEWinDS não foi criada: $programDataIni"
}
$ini = Get-Content -LiteralPath $programDataIni -Encoding utf8
if (-not ($ini -contains 'NameOrAddress=127.0.0.1') -or -not ($ini -contains 'Port=6566')) {
    throw 'A configuração do SANEWinDS não aponta exatamente para 127.0.0.1:6566.'
}

$state = Get-Hr7State -StatePath $statePath
$providerState = [ordered]@{
    configured_at_utc = [DateTime]::UtcNow.ToString('o')
    twain = [ordered]@{
        x86 = $twain32
        x64 = $twain64
        host = '127.0.0.1'
        port = 6566
        install_requested = [bool]$InstallTwainPackages
        unsigned_evaluation_allowed = [bool]$AllowUnsignedTwain
    }
    wia = [ordered]@{
        status = 'blocked'
        reason = 'No verified WIA provider has passed Windows 10/11 enumeration and acquisition tests.'
    }
}
$state | Add-Member -Force -NotePropertyName providers -NotePropertyValue $providerState
Save-Hr7State -State $state -StatePath $statePath
Write-Hr7Log -LogPath $logPath -Message "Configured SANEWinDS TWAIN x86/x64 for 127.0.0.1:6566; WIA remains blocked pending a verified provider."
Write-Output 'Windows provider configuration completed: TWAIN x86/x64 configured; WIA remains blocked.'

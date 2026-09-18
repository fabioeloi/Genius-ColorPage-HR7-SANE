#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch] $NoPrompt,
    [string] $PackageRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-Hr7Administrator
$null = Assert-Hr7WindowsX64
$devices = @(Get-Hr7UsbDevices)
if ($devices.Count -ne 1) {
    throw "A associação exige exatamente um HR7 presente. Dispositivos 0458:2013 encontrados: $($devices.Count)"
}

$manifest = Get-Hr7Manifest -PackageRoot $PackageRoot
$zadig = Get-Hr7Artifact -Manifest $manifest -Id 'zadig'
$driverDirectory = Join-Path $StateDirectory 'driver-tools'
$zadigPath = Join-Path $driverDirectory 'zadig-2.9.exe'
$logPath = Join-Path $StateDirectory 'logs\driver-binding.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null

Get-Hr7VerifiedDownload -Uri $zadig.url -Destination $zadigPath -ExpectedSha256 $zadig.sha256 | Out-Null
$signature = Get-AuthenticodeSignature -LiteralPath $zadigPath
$subject = if ($null -eq $signature.SignerCertificate) { '' } else { $signature.SignerCertificate.Subject }
$thumbprint = if ($null -eq $signature.SignerCertificate) { '' } else { $signature.SignerCertificate.Thumbprint }
if ($signature.Status -ne 'Valid' -or $subject -notlike '*Akeo Consulting*' -or $thumbprint -ne $zadig.authenticode_thumbprint) {
    throw "A assinatura do Zadig não confere. Status=$($signature.Status); Subject=$subject; Thumbprint=$thumbprint"
}

$iniPath = Join-Path $driverDirectory 'zadig.ini'
@'
[general]
advanced_mode = true
exit_on_success = false
log_level = 1

[device]
list_all = true
include_hubs = false
trim_whitespaces = true

[driver]
default_driver = 0
extract_only = false
'@ | Set-Content -LiteralPath $iniPath -Encoding ascii

Write-Hr7Log -LogPath $logPath -Message "Validated exact device $($devices[0].InstanceId). Starting verified Zadig $($zadig.version)."
Write-Host ''
Write-Host 'No Zadig, selecione somente a linha cujo USB ID seja 0458:2013.'
Write-Host 'Escolha WinUSB. Não use Create New Device e não selecione hubs ou outros USBs.'
if (-not $NoPrompt) { Read-Host 'Pressione Enter para abrir o Zadig após conferir estas instruções' | Out-Null }

Start-Process -FilePath $zadigPath -WorkingDirectory $driverDirectory -Wait
$postDevices = @(Get-Hr7UsbDevices)
if ($postDevices.Count -ne 1) {
    throw 'O HR7 não está presente após fechar o Zadig. Reconecte-o e execute este script novamente.'
}
$post = Get-Hr7DriverSnapshot -Device $postDevices[0]
Write-Hr7Log -LogPath $logPath -Message "Post-Zadig service=$($post.driver_service), INF=$($post.driver_inf), version=$($post.driver_version)"

$statePath = Join-Path $StateDirectory 'state.json'
if (Test-Path -LiteralPath $statePath) {
    $state = Get-Hr7State -StatePath $statePath
    $state | Add-Member -Force -NotePropertyName driver_binding_after_zadig -NotePropertyValue $post
    Save-Hr7State -State $state -StatePath $statePath
}

if ($post.driver_service -notmatch 'WinUSB') {
    throw 'WinUSB não foi associado ao HR7. Feche outros gerenciadores de driver, confirme o ID 0458:2013 no Zadig e tente novamente. Nenhuma outra associação será tentada.'
}

Write-Host 'WinUSB foi confirmado para o HR7.'

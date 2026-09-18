#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

Assert-Hr7Administrator
$statePath = Join-Path $StateDirectory 'state.json'
$state = Get-Hr7State -StatePath $statePath
$cygwinRoot = [IO.Path]::GetFullPath([string]$state.cygwin_root)
$fullStateDirectory = [IO.Path]::GetFullPath($StateDirectory)
if (-not $cygwinRoot.StartsWith($fullStateDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to delete runtime outside its state directory: $cygwinRoot"
}

$ownedXsane = Get-CimInstance -ClassName Win32_Process | Where-Object {
    $_.Name -ieq 'xsane.exe' -and $_.CommandLine -match 'genius-hr7'
}
foreach ($process in $ownedXsane) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}

$shortcutPath = Join-Path $env:PUBLIC 'Desktop\Genius ColorPage HR7 Scan.lnk'
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    Remove-Item -LiteralPath $shortcutPath -Force
}
if (Test-Path -LiteralPath $cygwinRoot) {
    Remove-Item -LiteralPath $cygwinRoot -Recurse -Force
}
Remove-Item -LiteralPath $fullStateDirectory -Recurse -Force

Write-Host 'O runtime privado, logs e atalho foram removidos.'
Write-Host "Driver registrado antes da alteração: INF=$($state.device_before.driver_inf); provider=$($state.device_before.driver_provider); service=$($state.device_before.driver_service)"
Write-Host 'A associação WinUSB não foi apagada automaticamente. Para voltar, use Device Manager para escolher o driver anterior registrado acima ou use o ponto de restauração criado pelo Windows.'

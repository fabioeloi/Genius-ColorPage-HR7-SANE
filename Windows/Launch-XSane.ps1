[CmdletBinding()]
param(
    [string] $StateDirectory = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE')
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $StateDirectory 'state.json'
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw 'Instalação ausente. Execute Install-Windows.ps1 primeiro.'
}
$state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
$cygwinRoot = [string]$state.cygwin_root
$xwin = Join-Path $cygwinRoot 'bin\XWin.exe'
$bash = Join-Path $cygwinRoot 'bin\bash.exe'
$launcher = Join-Path $cygwinRoot 'opt\genius-hr7\bin\launch-xsane.sh'
if (-not (Test-Path -LiteralPath $xwin) -or -not (Test-Path -LiteralPath $bash) -or -not (Test-Path -LiteralPath $launcher)) {
    throw 'O runtime privado do Cygwin/X ou XSane está incompleto. Execute Diagnose-Windows.ps1.'
}

if (-not (Get-Process -Name XWin -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $xwin -ArgumentList ':0', '-multiwindow', '-clipboard', '-nolisten', 'tcp'
    Start-Sleep -Seconds 2
}

$env:DISPLAY = ':0.0'
Start-Process -FilePath $bash -ArgumentList '-lc', 'exec /opt/genius-hr7/bin/launch-xsane.sh'

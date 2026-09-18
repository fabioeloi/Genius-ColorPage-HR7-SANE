$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'local-driver-transcript.log') -Append | Out-Null
try {
    $driverDirectory = Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE\driver-tools'
    New-Item -ItemType Directory -Force -Path $driverDirectory | Out-Null
    $cached = Join-Path $env:TEMP 'hr7-sources\zadig-2.9.exe'
    if (Test-Path -LiteralPath $cached) { Copy-Item -LiteralPath $cached -Destination (Join-Path $driverDirectory 'zadig-2.9.exe') }
    & (Join-Path $PSScriptRoot 'Configure-HR7-Driver.ps1') -NoPrompt
    'SUCCESS' | Set-Content (Join-Path $PSScriptRoot 'local-driver-result.txt')
}
catch {
    Write-Host ($_ | Out-String)
    ('FAILED: ' + $_.Exception.Message) | Set-Content (Join-Path $PSScriptRoot 'local-driver-result.txt')
}
finally { Stop-Transcript | Out-Null }

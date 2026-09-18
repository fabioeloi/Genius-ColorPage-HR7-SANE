$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'local-install-transcript.log'
$result = Join-Path $PSScriptRoot 'local-install-result.txt'
Start-Transcript -Path $log -Append | Out-Null
'RUNNING' | Set-Content -LiteralPath $result
try {
    & (Join-Path $PSScriptRoot 'Install-Windows.ps1') -SkipDriverBinding -Resume
    'SUCCESS' | Set-Content -LiteralPath $result
}
catch {
    Write-Host ($_ | Out-String)
    ('FAILED: ' + $_.Exception.Message) | Set-Content -LiteralPath $result
}
finally {
    Stop-Transcript | Out-Null
}

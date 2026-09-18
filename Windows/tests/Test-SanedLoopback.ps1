[CmdletBinding()]
param(
    [string] $CygwinRoot = (Join-Path $env:ProgramData 'GeniusColorPage-HR7-SANE\cygwin'),
    [ValidateRange(1025, 65535)]
    [int] $Port = 16566
)

$ErrorActionPreference = 'Stop'
$sanedPath = Join-Path $CygwinRoot 'opt\genius-hr7\sbin\saned.exe'
if (-not (Test-Path -LiteralPath $sanedPath -PathType Leaf)) {
    throw "saned is missing: $sanedPath"
}
$occupied = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
if ($occupied.Count -gt 0) {
    throw "Test port $Port is already listening; refusing to interfere with that process."
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $sanedPath
$startInfo.Arguments = "-l -b 127.0.0.1 -p $Port -e"
$startInfo.WorkingDirectory = $CygwinRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.EnvironmentVariables['PATH'] = @(
    (Join-Path $CygwinRoot 'bin'),
    (Join-Path $CygwinRoot 'opt\genius-hr7\bin'),
    (Join-Path $CygwinRoot 'opt\genius-hr7\lib'),
    (Join-Path $CygwinRoot 'opt\genius-hr7\lib\sane'),
    $env:PATH
) -join ';'
$startInfo.EnvironmentVariables['LD_LIBRARY_PATH'] = '/opt/genius-hr7/lib:/opt/genius-hr7/lib/sane'
$startInfo.EnvironmentVariables['SANE_CONFIG_DIR'] = '/opt/genius-hr7/etc/sane.d'
$server = [Diagnostics.Process]::Start($startInfo)
if ($null -eq $server) {
    throw 'Could not start the local saned test process.'
}

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($server.HasExited) {
            throw "saned exited before opening the test port (exit $($server.ExitCode))."
        }
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if ($listeners.Count -ne 1) {
        throw "Expected one listener on 127.0.0.1:$Port; found $($listeners.Count) listener(s)."
    }
    if ([string]$listeners[0].LocalAddress -ne '127.0.0.1') {
        throw "saned is listening outside IPv4 loopback on port $Port."
    }

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect([Net.IPAddress]::Loopback, $Port)
        if (-not $client.Connected) { throw 'The IPv4 loopback connection was not established.' }
    }
    finally {
        $client.Dispose()
    }

    Write-Output "PASS: saned accepted an IPv4 loopback connection on 127.0.0.1:$Port and exposed no wildcard listener."
}
finally {
    if (-not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit(5000) | Out-Null
    }
    $server.Dispose()

    $cleanupDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remainingListeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($remainingListeners.Count -eq 0) { break }
        foreach ($listener in $remainingListeners) {
            $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($null -ne $owner -and [string]$owner.Path -eq $sanedPath) {
                Stop-Process -Id $owner.Id -Force -ErrorAction Stop
            }
            else {
                throw "Test listener cleanup refused: process $($listener.OwningProcess) is not the package saned binary."
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $cleanupDeadline)

    $remainingListeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($remainingListeners.Count -gt 0) {
        throw "Test listener on port $Port did not stop after cleanup."
    }
}

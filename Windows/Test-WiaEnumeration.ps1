[CmdletBinding()]
param(
    [string] $ExpectedName = 'ColorPage-HR7',
    [switch] $AllowNoHr7
)

$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) {
    throw 'Run this WIA test from 64-bit Windows PowerShell; the HR7 WIA provider is x64.'
}
$manager = $null
$deviceInfos = $null
$found = @()

try {
    $manager = New-Object -ComObject WIA.DeviceManager
    $deviceInfos = $manager.DeviceInfos

    for ($index = 1; $index -le $deviceInfos.Count; $index++) {
        $deviceInfo = $null
        try {
            $deviceInfo = $deviceInfos.Item($index)
            $name = [string]$deviceInfo.Properties.Item('Name').Value
            $found += [pscustomobject]@{
                Name = $name
                Type = [int]$deviceInfo.Type
                DeviceId = [string]$deviceInfo.DeviceID
            }
        }
        finally {
            if ($deviceInfo) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($deviceInfo)
            }
        }
    }

    $matches = @($found | Where-Object { $_.Name -like "*$ExpectedName*" })
    if ($matches.Count -ne 1) {
        $details = if ($found.Count) {
            ($found | ForEach-Object { "$($_.Name)|$($_.DeviceId)|type=$($_.Type)" }) -join '; '
        }
        else {
            '<none>'
        }

        if ($AllowNoHr7 -and $matches.Count -eq 0) {
            Write-Output "BASELINE: WIA.DeviceManager returned $($found.Count) device(s), but none matched '$ExpectedName'. Devices: $details"
        }
        else {
            throw "Expected one WIA device matching '$ExpectedName'; found $($matches.Count). Devices: $details"
        }
    }
    else {
        if ($matches[0].Type -ne 1) {
            throw "WIA device '$($matches[0].Name)' has type $($matches[0].Type), expected scanner type 1."
        }
        Write-Output "PASS: WIA.DeviceManager enumerated scanner '$($matches[0].Name)' (device ID '$($matches[0].DeviceId)')."
    }
}
finally {
    if ($deviceInfos) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($deviceInfos)
    }
    if ($manager) {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($manager)
    }
}

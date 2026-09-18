Set-StrictMode -Version Latest

$script:Hr7HardwareIdPattern = '^USB\\VID_0458&PID_2013(?:&|\\)'

function Assert-Hr7Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute este script em um PowerShell aberto como administrador.'
    }
}

function Assert-Hr7WindowsX64 {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::Is64BitProcess -eq $false) {
        throw 'Este pacote requer Windows x64 e PowerShell x64.'
    }
    if ([version]$os.Version -lt [version]'10.0') {
        throw "Este pacote requer Windows 10 ou 11. Versão detectada: $($os.Version)"
    }
    return $os
}

function Get-Hr7UsbDevices {
    $devices = Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
        $_.InstanceId -match $script:Hr7HardwareIdPattern
    }
    return @($devices)
}

function Get-Hr7PnpProperty {
    param(
        [Parameter(Mandatory)] [string] $InstanceId,
        [Parameter(Mandatory)] [string] $KeyName
    )
    try {
        return (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop).Data
    }
    catch {
        return $null
    }
}

function Get-Hr7DriverSnapshot {
    param([Parameter(Mandatory)] $Device)
    return [ordered]@{
        captured_at_utc = [DateTime]::UtcNow.ToString('o')
        instance_id = $Device.InstanceId
        friendly_name = $Device.FriendlyName
        class = $Device.Class
        status = $Device.Status
        driver_inf = Get-Hr7PnpProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath'
        driver_version = Get-Hr7PnpProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion'
        driver_provider = Get-Hr7PnpProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider'
        driver_service = Get-Hr7PnpProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_Service'
    }
}

function Write-Hr7Log {
    param(
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [string] $Message
    )
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Get-Hr7Manifest {
    param([Parameter(Mandatory)] [string] $PackageRoot)
    $manifestPath = Join-Path $PackageRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Manifesto ausente: $manifestPath"
    }
    return (Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Get-Hr7Artifact {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [string] $Id
    )
    $artifact = @($Manifest.artifacts | Where-Object { $_.id -eq $Id })
    if ($artifact.Count -ne 1) {
        throw "Artefato inválido ou ausente no manifesto: $Id"
    }
    return $artifact[0]
}

function Get-Hr7VerifiedDownload {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $ExpectedSha256
    )
    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -ErrorAction Stop
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 inválido para $Destination. Esperado: $ExpectedSha256. Obtido: $actual"
    }
    return $Destination
}

function ConvertTo-Hr7CygwinPath {
    param(
        [Parameter(Mandatory)] [string] $BashPath,
        [Parameter(Mandatory)] [string] $WindowsPath
    )
    $converted = & $BashPath -lc 'cygpath -u "$1"' bash $WindowsPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
        throw "Não foi possível converter o caminho para Cygwin: $WindowsPath"
    }
    return ($converted | Select-Object -First 1).Trim()
}

function Get-Hr7State {
    param([Parameter(Mandatory)] [string] $StatePath)
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Estado da instalação ausente: $StatePath"
    }
    return (Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Save-Hr7State {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $StatePath
    )
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding utf8
}

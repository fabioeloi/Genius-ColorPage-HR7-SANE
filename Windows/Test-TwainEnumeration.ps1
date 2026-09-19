[CmdletBinding()]
param(
    [string] $DataSourceName = 'SANEWinDS'
)

$ErrorActionPreference = 'Stop'
if (-not ('Hr7Twain.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Hr7Twain {
    [StructLayout(LayoutKind.Sequential, Pack = 2, CharSet = CharSet.Ansi)]
    public struct TW_VERSION {
        public ushort MajorNum;
        public ushort MinorNum;
        public ushort Language;
        public ushort Country;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string Info;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2, CharSet = CharSet.Ansi)]
    public struct TW_IDENTITY {
        public uint Id;
        public TW_VERSION Version;
        public ushort ProtocolMajor;
        public ushort ProtocolMinor;
        public uint SupportedGroups;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string Manufacturer;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string ProductFamily;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 34)] public string ProductName;
    }

    public static class Native {
        [DllImport("TWAINDSM.dll", CallingConvention = CallingConvention.StdCall)]
        public static extern ushort DSM_Entry(ref TW_IDENTITY origin, IntPtr destination, uint dg, ushort dat, ushort msg, IntPtr data);
    }
}
'@
}

function New-Hr7Identity {
    $identity = New-Object Hr7Twain.TW_IDENTITY
    $identity.Id = 0
    $identity.Version = New-Object Hr7Twain.TW_VERSION
    $identity.Version.MajorNum = 2
    $identity.Version.MinorNum = 4
    $identity.Version.Language = 13
    $identity.Version.Country = 55
    $identity.Version.Info = 'HR7 TWAIN enumeration test'
    $identity.ProtocolMajor = 2
    $identity.ProtocolMinor = 4
    $identity.SupportedGroups = 0x00010003
    $identity.Manufacturer = 'Genius HR7 project'
    $identity.ProductFamily = 'ColorPage-HR7'
    $identity.ProductName = 'HR7 TWAIN test client'
    return $identity
}

function Invoke-TwainIdentity {
    param(
        [Parameter(Mandatory)] $Origin,
        [Parameter(Mandatory)] [uint16] $Message,
        [Parameter(Mandatory)] $Destination
    )
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IDENTITY')
    $pointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($Destination, $pointer, $false)
        $result = [Hr7Twain.Native]::DSM_Entry([ref]$Origin, [IntPtr]::Zero, 0x00000001, 0x0003, $Message, $pointer)
        $updatedDestination = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type]'Hr7Twain.TW_IDENTITY')
        return [pscustomobject]@{ Code = $result; Origin = $Origin; Destination = $updatedDestination }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
    }
}

$origin = New-Hr7Identity
Add-Type -AssemblyName System.Windows.Forms
$parentForm = New-Object System.Windows.Forms.Form
$parentForm.ShowInTaskbar = $false
$parentForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$parentForm.CreateControl()
$parentHandle = $parentForm.Handle
$parentPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
[Runtime.InteropServices.Marshal]::WriteIntPtr($parentPointer, $parentHandle)
try {
    $open = [Hr7Twain.Native]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 0x00000001, 0x0004, 0x0301, $parentPointer)
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($parentPointer)
}
if ($open -ne 0) {
    throw "TWAIN DSM open failed with return code $open"
}

$found = @()
try {
    $destination = New-Hr7Identity
    $call = Invoke-TwainIdentity -Origin $origin -Message 0x0004 -Destination $destination
    $returnCode = $call.Code
    $origin = $call.Origin
    $destination = $call.Destination
    while ($returnCode -eq 0) {
        $found += $destination
        $destination = New-Hr7Identity
        $call = Invoke-TwainIdentity -Origin $origin -Message 0x0005 -Destination $destination
        $returnCode = $call.Code
        $origin = $call.Origin
        $destination = $call.Destination
    }
    if ($returnCode -ne 7) {
        throw "TWAIN source enumeration failed with return code $returnCode"
    }

    $matches = @($found | Where-Object { $_.ProductName -like "*$DataSourceName*" })
    if ($matches.Count -ne 1) {
        $details = @($found | ForEach-Object { "$($_.ProductName)|$($_.Manufacturer)|$($_.ProductFamily)" }) -join ', '
        throw "Expected one TWAIN data source matching '$DataSourceName'; found $($matches.Count). Sources: $details"
    }

    Write-Output "PASS: TWAIN DSM enumerated '$($matches[0].ProductName)' (manufacturer '$($matches[0].Manufacturer)')."
}
finally {
    $closePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
    [Runtime.InteropServices.Marshal]::WriteIntPtr($closePointer, $parentHandle)
    try {
        [void][Hr7Twain.Native]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 0x00000001, 0x0004, 0x0302, $closePointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($closePointer)
    }
    $parentForm.Dispose()
}
exit 0

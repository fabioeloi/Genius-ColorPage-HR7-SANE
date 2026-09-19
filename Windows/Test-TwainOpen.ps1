[CmdletBinding()]
param(
    [string] $DataSourceName = 'SANEWinDS',
    [ValidateRange(1, 120)] [int] $TimeoutSeconds = 15,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'

if (-not $Worker) {
    $outPath = Join-Path $env:TEMP ("hr7-twain-open-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    try {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
            '-DataSourceName', ('"{0}"' -f $DataSourceName), '-Worker')
        $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $completed = $workerProcess.WaitForExit($TimeoutSeconds * 1000)
        $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
        $workerError = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
        if (-not $completed) {
            try { & taskkill.exe /PID $workerProcess.Id /T /F *> $null } catch { }
            Start-Sleep -Milliseconds 100
            $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { $workerOutput }
            if ($workerOutput -match 'PASS: TWAIN data source opened') {
                Write-Output $workerOutput.Trim()
                exit 0
            }
            throw "TWAIN MSG_OPENDS did not return within $TimeoutSeconds seconds."
        }
        if ($workerOutput -match 'PASS: TWAIN data source opened') {
            Write-Output $workerOutput.Trim()
            exit 0
        }
        if ($workerProcess.ExitCode -ne 0) {
            if ($workerError) { throw $workerError.Trim() }
            throw "TWAIN source-open worker failed with exit code $($workerProcess.ExitCode)."
        }
        if ($workerError) { throw $workerError.Trim() }
        throw "TWAIN source-open worker returned no success evidence."
    }
    finally {
        Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not ('Hr7Twain.OpenProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

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

    public sealed class OpenResult {
        public ushort Code;
        public TW_IDENTITY Source;
        public string Error;
    }

    public static class OpenProbe {
        [DllImport("TWAINDSM.dll", CallingConvention = CallingConvention.StdCall)]
        public static extern ushort DSM_Entry(ref TW_IDENTITY origin, IntPtr destination, uint dg, ushort dat, ushort msg, IntPtr data);

        [DllImport("TWAINDSM.dll", CallingConvention = CallingConvention.StdCall)]
        public static extern ushort DSM_Entry(ref TW_IDENTITY origin, IntPtr destination, uint dg, ushort dat, ushort msg, ref TW_IDENTITY data);

        public static Task<OpenResult> OpenAsync(TW_IDENTITY origin, TW_IDENTITY source) {
            return Task.Run(() => {
                var result = new OpenResult { Source = source };
                try {
                    var size = Marshal.SizeOf(typeof(TW_IDENTITY));
                    var pointer = Marshal.AllocHGlobal(size);
                    try {
                        Marshal.StructureToPtr(result.Source, pointer, false);
                        result.Code = DSM_Entry(ref origin, IntPtr.Zero, 0x00000001, 0x0003, 0x0401, pointer);
                        result.Source = (TW_IDENTITY)Marshal.PtrToStructure(pointer, typeof(TW_IDENTITY));
                    }
                    finally {
                        Marshal.FreeHGlobal(pointer);
                    }
                }
                catch (Exception ex) {
                    result.Error = ex.ToString();
                    result.Code = 0xffff;
                }
                return result;
            });
        }

        public static ushort CloseSource(ref TW_IDENTITY origin, TW_IDENTITY source) {
            var size = Marshal.SizeOf(typeof(TW_IDENTITY));
            var pointer = Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(source, pointer, false);
                return DSM_Entry(ref origin, IntPtr.Zero, 0x00000001, 0x0003, 0x0402, pointer);
            }
            finally {
                Marshal.FreeHGlobal(pointer);
            }
        }
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
    $identity.Version.Info = 'HR7 TWAIN source-open test'
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
        $result = [Hr7Twain.OpenProbe]::DSM_Entry([ref]$Origin, [IntPtr]::Zero, 0x00000001, 0x0003, $Message, $pointer)
        $updatedDestination = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type]'Hr7Twain.TW_IDENTITY')
        return [pscustomobject]@{ Code = $result; Origin = $Origin; Destination = $updatedDestination }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)
    }
}

Add-Type -AssemblyName System.Windows.Forms
$parentForm = New-Object System.Windows.Forms.Form
$parentForm.ShowInTaskbar = $false
$parentForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$parentForm.CreateControl()
$parentHandle = $parentForm.Handle
$origin = New-Hr7Identity
$parentPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
try {
    [Runtime.InteropServices.Marshal]::WriteIntPtr($parentPointer, $parentHandle)
    $openDsm = [Hr7Twain.OpenProbe]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 0x00000001, 0x0004, 0x0301, $parentPointer)
}
finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($parentPointer)
}
if ($openDsm -ne 0) { throw "TWAIN DSM open failed with return code $openDsm." }

$source = $null
$sourceOpen = $false
try {
    $destination = New-Hr7Identity
    $call = Invoke-TwainIdentity -Origin $origin -Message 0x0004 -Destination $destination
    $returnCode = $call.Code
    $origin = $call.Origin
    $destination = $call.Destination
    while ($returnCode -eq 0) {
        if ($destination.ProductName -like "*$DataSourceName*") { $source = $destination; break }
        $destination = New-Hr7Identity
        $call = Invoke-TwainIdentity -Origin $origin -Message 0x0005 -Destination $destination
        $returnCode = $call.Code
        $origin = $call.Origin
        $destination = $call.Destination
    }
    if ($null -eq $source) { throw "TWAIN data source '$DataSourceName' was not enumerated." }

    $task = [Hr7Twain.OpenProbe]::OpenAsync($origin, $source)
    while (-not $task.Wait(10)) {
        [System.Windows.Forms.Application]::DoEvents()
    }
    $result = $task.Result
    if ($result.Error) { throw $result.Error }
    if ($result.Code -ne 0) { throw "TWAIN MSG_OPENDS returned code $($result.Code) for '$($source.ProductName)'." }
    $sourceOpen = $true
    Write-Output "PASS: TWAIN data source opened '$($source.ProductName)' (manufacturer '$($source.Manufacturer)')."
    [Console]::Out.Flush()
}
finally {
    if ($sourceOpen) {
        try {
            [void][Hr7Twain.OpenProbe]::CloseSource([ref]$origin, $source)
        }
        catch { }
    }
    try {
        $closePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($closePointer, $parentHandle)
        [void][Hr7Twain.OpenProbe]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 0x00000001, 0x0004, 0x0302, $closePointer)
    }
    finally {
        if ($closePointer) { [Runtime.InteropServices.Marshal]::FreeHGlobal($closePointer) }
        $parentForm.Dispose()
    }
}
exit 0

[CmdletBinding()]
param(
    [string] $DataSourceName = 'SANEWinDS',
    [ValidateRange(1, 180)] [int] $TimeoutSeconds = 60,
    [ValidateRange(1, 600)] [int] $ResolutionDpi = 75,
    [ValidateSet('Gray', 'Color')] [string] $PixelMode = 'Gray',
    [ValidateSet('Memory', 'Native')] [string] $TransferMode = 'Memory',
    [switch] $SkipCapabilitySetup,
    [switch] $Worker
)

$ErrorActionPreference = 'Stop'

if (-not $Worker) {
    $outPath = Join-Path $env:TEMP ("hr7-twain-acquire-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $errPath = "$outPath.err"
    try {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
            '-DataSourceName', ('"{0}"' -f $DataSourceName), '-ResolutionDpi', $ResolutionDpi,
            '-PixelMode', $PixelMode, '-TransferMode', $TransferMode)
        if ($SkipCapabilitySetup) { $args += '-SkipCapabilitySetup' }
        $args += '-Worker'
        $workerProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath -PassThru
        $completed = $workerProcess.WaitForExit($TimeoutSeconds * 1000)
        $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
        $workerError = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw } else { '' }
        if (-not $completed) {
            try { & taskkill.exe /PID $workerProcess.Id /T /F *> $null } catch { }
            Start-Sleep -Milliseconds 100
            $workerOutput = if (Test-Path -LiteralPath $outPath) { Get-Content -LiteralPath $outPath -Raw } else { $workerOutput }
            if ($workerOutput -match 'PASS: TWAIN acquired') {
                Write-Output $workerOutput.Trim()
                exit 0
            }
            throw "TWAIN acquisition did not complete within $TimeoutSeconds seconds."
        }
        if ($workerOutput -match 'PASS: TWAIN acquired') {
            Write-Output $workerOutput.Trim()
            exit 0
        }
        if ($workerProcess.ExitCode -ne 0) {
            if ($workerError) { throw $workerError.Trim() }
            throw "TWAIN acquisition worker failed with exit code $($workerProcess.ExitCode)."
        }
        if ($workerError) { throw $workerError.Trim() }
        throw "TWAIN acquisition worker returned no success evidence."
    }
    finally {
        Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

if (-not ('Hr7Twain.AcquireNative' -as [type])) {
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

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_FIX32 {
        public short Whole;
        public ushort Frac;
        public static TW_FIX32 FromDouble(double value) {
            var raw = (int)Math.Round(value * 65536.0);
            return new TW_FIX32 { Whole = (short)(raw >> 16), Frac = (ushort)(raw & 0xffff) };
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_FRAME {
        public TW_FIX32 Left;
        public TW_FIX32 Top;
        public TW_FIX32 Right;
        public TW_FIX32 Bottom;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_IMAGELAYOUT {
        public TW_FRAME Frame;
        public uint DocumentNumber;
        public uint PageNumber;
        public uint FrameNumber;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_USERINTERFACE {
        public ushort ShowUI;
        public ushort ModalUI;
        public IntPtr hParent;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_ONEVALUE {
        public ushort ItemType;
        public int Item;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_CAPABILITY {
        public ushort Cap;
        public ushort ConType;
        public IntPtr hContainer;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_SETUPMEMXFER {
        public uint MinBufSize;
        public uint MaxBufSize;
        public uint Preferred;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_MEMORY {
        public uint Flags;
        public uint Length;
        public IntPtr TheMem;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_IMAGEMEMXFER {
        public ushort Compression;
        public uint BytesPerRow;
        public uint Columns;
        public uint Rows;
        public uint XOffset;
        public uint YOffset;
        public uint BytesWritten;
        public TW_MEMORY Memory;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_IMAGEINFO {
        public TW_FIX32 XResolution;
        public TW_FIX32 YResolution;
        public int ImageWidth;
        public int ImageLength;
        public short SamplesPerPixel;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8, ArraySubType = UnmanagedType.I2)] public short[] BitsPerSample;
        public short BitsPerPixel;
        public ushort Planar;
        public ushort PixelType;
        public ushort Compression;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    public struct TW_PENDINGXFERS {
        public short Count;
        public uint EOJ;
    }

    public static class AcquireNative {
        [DllImport("TWAINDSM.dll", CallingConvention = CallingConvention.StdCall)]
        public static extern ushort DSM_Entry(ref TW_IDENTITY origin, IntPtr destination, uint dg, ushort dat, ushort msg, IntPtr data);

        [DllImport("gdi32.dll", CallingConvention = CallingConvention.StdCall)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeleteObject(IntPtr handle);

        public sealed class OpenResult {
            public ushort Code;
            public TW_IDENTITY Source;
            public string Error;
        }

        public static Task<OpenResult> OpenAsync(TW_IDENTITY origin, TW_IDENTITY source) {
            return Task.Run(() => {
                var result = new OpenResult { Source = source };
                try {
                    var size = Marshal.SizeOf(typeof(TW_IDENTITY));
                    var pointer = Marshal.AllocHGlobal(size);
                    try {
                        Marshal.StructureToPtr(result.Source, pointer, false);
                        result.Code = DSM_Entry(ref origin, IntPtr.Zero, 1, 3, 0x0401, pointer);
                        result.Source = (TW_IDENTITY)Marshal.PtrToStructure(pointer, typeof(TW_IDENTITY));
                    }
                    finally { Marshal.FreeHGlobal(pointer); }
                }
                catch (Exception ex) { result.Error = ex.ToString(); result.Code = 0xffff; }
                return result;
            });
        }

        public static ushort CloseSource(ref TW_IDENTITY origin, TW_IDENTITY source) {
            var size = Marshal.SizeOf(typeof(TW_IDENTITY));
            var pointer = Marshal.AllocHGlobal(size);
            try { Marshal.StructureToPtr(source, pointer, false); return DSM_Entry(ref origin, IntPtr.Zero, 1, 3, 0x0402, pointer); }
            finally { Marshal.FreeHGlobal(pointer); }
        }
    }
}
'@
}

function New-Hr7Identity {
    $identity = New-Object Hr7Twain.TW_IDENTITY
    $identity.Version = New-Object Hr7Twain.TW_VERSION
    $identity.Version.MajorNum = 2
    $identity.Version.MinorNum = 4
    $identity.Version.Language = 13
    $identity.Version.Country = 55
    $identity.Version.Info = 'HR7 TWAIN acquisition test'
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
        $result = [Hr7Twain.AcquireNative]::DSM_Entry([ref]$Origin, [IntPtr]::Zero, 1, 3, $Message, $pointer)
        $updatedDestination = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type]'Hr7Twain.TW_IDENTITY')
        return [pscustomobject]@{ Code = $result; Origin = $Origin; Destination = $updatedDestination }
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
}

function Invoke-Source {
    param(
        [Parameter(Mandatory)] $Origin,
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [uint32] $DataGroup,
        [Parameter(Mandatory)] [uint16] $Data,
        [Parameter(Mandatory)] [uint16] $Message,
        [Parameter(Mandatory)] [object] $Value,
        [int] $Size = 0,
        [string] $ValueTypeName = ''
    )
    $sourceSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IDENTITY')
    $sourcePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($sourceSize)
    $valuePointer = [IntPtr]::Zero
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($Source, $sourcePointer, $false)
        if ($Size -gt 0) {
            $valuePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($Size)
            [Runtime.InteropServices.Marshal]::StructureToPtr($Value, $valuePointer, $false)
        }
        $code = [Hr7Twain.AcquireNative]::DSM_Entry([ref]$Origin, $sourcePointer, $DataGroup, $Data, $Message, $valuePointer)
        $updated = $null
        if ($Size -gt 0 -and $ValueTypeName) {
            switch ($ValueTypeName) {
                'Hr7Twain.TW_IMAGELAYOUT' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_IMAGELAYOUT') }
                'Hr7Twain.TW_USERINTERFACE' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_USERINTERFACE') }
                'Hr7Twain.TW_IMAGEINFO' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_IMAGEINFO') }
                'Hr7Twain.TW_SETUPMEMXFER' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_SETUPMEMXFER') }
                'Hr7Twain.TW_IMAGEMEMXFER' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_IMAGEMEMXFER') }
                'Hr7Twain.TW_PENDINGXFERS' { $updated = [Runtime.InteropServices.Marshal]::PtrToStructure($valuePointer, [type]'Hr7Twain.TW_PENDINGXFERS') }
                'System.IntPtr' { $updated = [Runtime.InteropServices.Marshal]::ReadIntPtr($valuePointer) }
                default { throw "Unsupported TWAIN readback structure: $ValueTypeName" }
            }
        }
        return [pscustomobject]@{ Code = $code; Value = $updated }
    }
    finally {
        if ($valuePointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($valuePointer) }
        [Runtime.InteropServices.Marshal]::FreeHGlobal($sourcePointer)
    }
}

function Set-TwainOneValue {
    param(
        [Parameter(Mandatory)] $Origin,
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] [uint16] $Capability,
        [Parameter(Mandatory)] [uint16] $ItemType,
        [Parameter(Mandatory)] [int] $Item
    )
    $one = New-Object Hr7Twain.TW_ONEVALUE
    $one.ItemType = $ItemType
    $one.Item = $Item
    $oneSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_ONEVALUE')
    $onePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($oneSize)
    $cap = New-Object Hr7Twain.TW_CAPABILITY
    $cap.Cap = $Capability
    $cap.ConType = 5
    $cap.hContainer = $onePointer
    $capSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_CAPABILITY')
    $capPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($capSize)
    try {
        [Runtime.InteropServices.Marshal]::StructureToPtr($one, $onePointer, $false)
        [Runtime.InteropServices.Marshal]::StructureToPtr($cap, $capPointer, $false)
        $sourceSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IDENTITY')
        $sourcePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($sourceSize)
        try {
            [Runtime.InteropServices.Marshal]::StructureToPtr($Source, $sourcePointer, $false)
            return [Hr7Twain.AcquireNative]::DSM_Entry([ref]$Origin, $sourcePointer, 1, 1, 6, $capPointer)
        }
        finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($sourcePointer) }
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($capPointer)
        [Runtime.InteropServices.Marshal]::FreeHGlobal($onePointer)
    }
}

Add-Type -AssemblyName System.Windows.Forms
$parentForm = New-Object System.Windows.Forms.Form
$parentForm.ShowInTaskbar = $false
$parentForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$parentForm.CreateControl()
$parentHandle = $parentForm.Handle
$origin = New-Hr7Identity
$source = $null
$sourceOpen = $false
$enabled = $false
$ui = New-Object Hr7Twain.TW_USERINTERFACE
$ui.ShowUI = 0
$ui.ModalUI = 0
$ui.hParent = $parentHandle
$uiSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_USERINTERFACE')
$uiPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($uiSize)
try {
    [Runtime.InteropServices.Marshal]::StructureToPtr($ui, $uiPointer, $false)
    $parentPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
    try {
        [Runtime.InteropServices.Marshal]::WriteIntPtr($parentPointer, $parentHandle)
        $openDsm = [Hr7Twain.AcquireNative]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 1, 4, 0x0301, $parentPointer)
    }
    finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($parentPointer) }
    if ($openDsm -ne 0) { throw "TWAIN DSM open failed with return code $openDsm." }

    $destination = New-Hr7Identity
    $call = Invoke-TwainIdentity -Origin $origin -Message 4 -Destination $destination
    $returnCode = $call.Code
    $origin = $call.Origin
    $destination = $call.Destination
    while ($returnCode -eq 0) {
        if ($destination.ProductName -like "*$DataSourceName*") { $source = $destination; break }
        $destination = New-Hr7Identity
        $call = Invoke-TwainIdentity -Origin $origin -Message 5 -Destination $destination
        $returnCode = $call.Code
        $origin = $call.Origin
        $destination = $call.Destination
    }
    if ($null -eq $source) { throw "TWAIN data source '$DataSourceName' was not enumerated." }

    $openTask = [Hr7Twain.AcquireNative]::OpenAsync($origin, $source)
    while (-not $openTask.Wait(10)) { [System.Windows.Forms.Application]::DoEvents() }
    $openResult = $openTask.Result
    if ($openResult.Error) { throw $openResult.Error }
    if ($openResult.Code -ne 0) { throw "TWAIN MSG_OPENDS returned code $($openResult.Code)." }
    $source = $openResult.Source
    $sourceOpen = $true

    if (-not $SkipCapabilitySetup) {
        $gray = if ($PixelMode -eq 'Gray') { 1 } else { 2 }
        $transferItem = if ($TransferMode -eq 'Native') { 0 } else { 2 }
        $settings = @(
            @{ Capability = 1; ItemType = 1; Item = 1 },
            @{ Capability = 257; ItemType = 4; Item = $gray },
            @{ Capability = 4376; ItemType = 7; Item = [int]([Math]::Round($ResolutionDpi * 65536.0)) },
            @{ Capability = 4377; ItemType = 7; Item = [int]([Math]::Round($ResolutionDpi * 65536.0)) },
            @{ Capability = 259; ItemType = 4; Item = $transferItem }
        )
        foreach ($setting in $settings) {
            $setCode = Set-TwainOneValue -Origin $origin -Source $source -Capability $setting.Capability -ItemType $setting.ItemType -Item $setting.Item
            if ($setCode -ne 0) { Write-Verbose "TWAIN capability $($setting.Capability) returned $setCode; continuing with provider defaults." }
        }

        $layout = New-Object Hr7Twain.TW_IMAGELAYOUT
        $layout.Frame = New-Object Hr7Twain.TW_FRAME
        $layout.Frame.Left = [Hr7Twain.TW_FIX32]::FromDouble(0)
        $layout.Frame.Top = [Hr7Twain.TW_FIX32]::FromDouble(0)
        $layout.Frame.Right = [Hr7Twain.TW_FIX32]::FromDouble(2)
        $layout.Frame.Bottom = [Hr7Twain.TW_FIX32]::FromDouble(2)
        $layout.DocumentNumber = [uint32]::MaxValue
        $layout.PageNumber = [uint32]::MaxValue
        $layout.FrameNumber = [uint32]::MaxValue
        $layoutCall = Invoke-Source -Origin $origin -Source $source -DataGroup 2 -Data 258 -Message 6 -Value $layout -Size ([Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IMAGELAYOUT')) -ValueTypeName 'Hr7Twain.TW_IMAGELAYOUT'
        if ($layoutCall.Code -ne 0) { Write-Verbose "TWAIN frame setup returned $($layoutCall.Code); continuing with provider defaults." }
    }
    else {
        Write-Verbose 'Skipping capability and frame setup; using provider defaults.'
    }

    $uiCall = Invoke-Source -Origin $origin -Source $source -DataGroup 1 -Data 9 -Message 1282 -Value $ui -Size $uiSize -ValueTypeName 'Hr7Twain.TW_USERINTERFACE'
    if ($uiCall.Code -ne 0) { throw "TWAIN MSG_ENABLEDS returned code $($uiCall.Code)." }
    $enabled = $true

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $imageInfo = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        $info = New-Object Hr7Twain.TW_IMAGEINFO
        $info.BitsPerSample = New-Object 'System.Int16[]' 8
        $infoCall = Invoke-Source -Origin $origin -Source $source -DataGroup 2 -Data 257 -Message 1 -Value $info -Size ([Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IMAGEINFO')) -ValueTypeName 'Hr7Twain.TW_IMAGEINFO'
        if ($infoCall.Code -eq 0) { $imageInfo = $infoCall.Value; break }
        Start-Sleep -Milliseconds 50
    }
    if ($null -eq $imageInfo) { throw 'TWAIN source did not report image information before the acquisition deadline.' }
    $totalBytes = 0L
    $nonBlankBytes = 0L
    $chunks = 0
    if ($TransferMode -eq 'Native') {
        Add-Type -AssemblyName System.Drawing
        $nativeCall = Invoke-Source -Origin $origin -Source $source -DataGroup 2 -Data 4 -Message 1 -Value ([IntPtr]::Zero) -Size ([IntPtr]::Size) -ValueTypeName 'System.IntPtr'
        if ($nativeCall.Code -ne 0 -and $nativeCall.Code -ne 6) { throw "TWAIN DAT_IMAGENATIVEXFER returned code $($nativeCall.Code)." }
        $hBitmap = [IntPtr]$nativeCall.Value
        if ($hBitmap -eq [IntPtr]::Zero) { throw 'TWAIN native transfer returned a null bitmap handle.' }
        $bitmap = $null
        try {
            $bitmap = [System.Drawing.Image]::FromHbitmap($hBitmap)
            $sampleStepX = [Math]::Max(1, [int]($bitmap.Width / 32))
            $sampleStepY = [Math]::Max(1, [int]($bitmap.Height / 32))
            for ($y = 0; $y -lt $bitmap.Height; $y += $sampleStepY) {
                for ($x = 0; $x -lt $bitmap.Width; $x += $sampleStepX) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ($pixel.R -ne 0 -and $pixel.R -ne 255 -or $pixel.G -ne 0 -and $pixel.G -ne 255 -or $pixel.B -ne 0 -and $pixel.B -ne 255) { $nonBlankBytes++ }
                }
            }
            $totalBytes = [int64]$bitmap.Width * [int64]$bitmap.Height * [Math]::Max(1, [int]$imageInfo.SamplesPerPixel)
            $chunks = 1
        }
        finally {
            if ($bitmap) { $bitmap.Dispose() }
            [void][Hr7Twain.AcquireNative]::DeleteObject($hBitmap)
        }
    }
    else {
        $setup = New-Object Hr7Twain.TW_SETUPMEMXFER
        $setupCall = Invoke-Source -Origin $origin -Source $source -DataGroup 1 -Data 6 -Message 1 -Value $setup -Size ([Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_SETUPMEMXFER')) -ValueTypeName 'Hr7Twain.TW_SETUPMEMXFER'
        if ($setupCall.Code -ne 0) { throw "TWAIN DAT_SETUPMEMXFER returned code $($setupCall.Code)." }
        $setup = $setupCall.Value
        $bufferSize = [Math]::Max(65536, [Math]::Min([int]$setup.Preferred, 4 * 1024 * 1024))
        $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal($bufferSize)
        try {
            while ($true) {
                $memory = New-Object Hr7Twain.TW_MEMORY
                $memory.Flags = 1
                $memory.Length = [uint32]$bufferSize
                $memory.TheMem = $buffer
                $transfer = New-Object Hr7Twain.TW_IMAGEMEMXFER
                $transfer.Memory = $memory
                $transferSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_IMAGEMEMXFER')
                $transferCall = Invoke-Source -Origin $origin -Source $source -DataGroup 2 -Data 259 -Message 1 -Value $transfer -Size $transferSize -ValueTypeName 'Hr7Twain.TW_IMAGEMEMXFER'
                if ($transferCall.Code -ne 0 -and $transferCall.Code -ne 6) { throw "TWAIN DAT_IMAGEMEMXFER returned code $($transferCall.Code)." }
                $transfer = $transferCall.Value
                $written = [int][Math]::Min([uint32]$bufferSize, $transfer.BytesWritten)
                if ($written -gt 0) {
                    $chunk = New-Object byte[] $written
                    [Runtime.InteropServices.Marshal]::Copy($buffer, $chunk, 0, $written)
                    $totalBytes += $written
                    $nonBlankBytes += @($chunk | Where-Object { $_ -ne 0 -and $_ -ne 255 }).Count
                    $chunks++
                }
                if ($transferCall.Code -eq 6) { break }
                if ($chunks -gt 10000) { throw 'TWAIN transfer exceeded the safety chunk limit.' }
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
        finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
    }
    $pending = New-Object Hr7Twain.TW_PENDINGXFERS
    $endCall = Invoke-Source -Origin $origin -Source $source -DataGroup 1 -Data 5 -Message 1793 -Value $pending -Size ([Runtime.InteropServices.Marshal]::SizeOf([type]'Hr7Twain.TW_PENDINGXFERS')) -ValueTypeName 'Hr7Twain.TW_PENDINGXFERS'
    if ($endCall.Code -ne 0) { throw "TWAIN MSG_ENDXFER returned code $($endCall.Code)." }
    if ($nonBlankBytes -le 0) { throw 'TWAIN transfer returned only blank pixels.' }
    Write-Output "PASS: TWAIN acquired $totalBytes bytes in $chunks $($TransferMode.ToLowerInvariant()) chunks ($($imageInfo.ImageWidth)x$($imageInfo.ImageLength), $PixelMode, ${ResolutionDpi}dpi); nonblank=$nonBlankBytes."
    [Console]::Out.Flush()
}
finally {
    if ($enabled) { try { [void](Invoke-Source -Origin $origin -Source $source -DataGroup 1 -Data 9 -Message 1281 -Value $ui -Size $uiSize -ValueTypeName 'Hr7Twain.TW_USERINTERFACE') } catch { } }
    if ($sourceOpen) { try { [void][Hr7Twain.AcquireNative]::CloseSource([ref]$origin, $source) } catch { } }
    try {
        $closePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
        [Runtime.InteropServices.Marshal]::WriteIntPtr($closePointer, $parentHandle)
        [void][Hr7Twain.AcquireNative]::DSM_Entry([ref]$origin, [IntPtr]::Zero, 1, 4, 0x0302, $closePointer)
    }
    finally {
        if ($closePointer) { [Runtime.InteropServices.Marshal]::FreeHGlobal($closePointer) }
        [Runtime.InteropServices.Marshal]::FreeHGlobal($uiPointer)
        $parentForm.Dispose()
    }
}
exit 0

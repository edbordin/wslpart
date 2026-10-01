$ErrorActionPreference = 'Stop'

if (-not ('WslPartStopNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartStopNative
{
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetEvent(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

Write-Output 'Detaching WSL disk...'
& wsl.exe --unmount '\\.\PHYSICALDRIVE1'
if ($LASTEXITCODE -ne 0) {
    Write-Output "wsl --unmount returned exit code $LASTEXITCODE; continuing with proxy shutdown."
}

$handle = [WslPartStopNative]::OpenEvent(0x00100002, $false,
    'WslPartSharedRingTestStop')
if ($handle -eq [IntPtr]::Zero) {
    throw "OpenEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
}
try {
    if (-not [WslPartStopNative]::SetEvent($handle)) {
        throw "SetEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
}
finally {
    [void][WslPartStopNative]::CloseHandle($handle)
}
Write-Output 'WSL detached and proxy stop requested.'

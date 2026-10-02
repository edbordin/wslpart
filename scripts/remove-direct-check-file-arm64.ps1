[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [string]$TestPath = '/mnt/wslpart-direct-persistence-check/wslpart-direct-persistence-check.bin',
    [switch]$RemoveGenerated
)

$ErrorActionPreference = 'Stop'
if (-not ('WslPartNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
    [DllImport("kernel32.dll")] public static extern bool SetEvent(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$eventName = "wslpart-remove-check-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$attached = $false
$mounted = $false

function Invoke-WslRoot {
    param([string]$Command)
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed: $Command`n$($output -join "`n")" }
    return $output
}
function Stop-Proxy {
    if ($null -eq $script:process -or $script:process.HasExited) { return }
    $handle = [WslPartNative]::OpenEvent(0x00100001, $false, $script:eventName)
    if ($handle -ne [IntPtr]::Zero) {
        [void][WslPartNative]::SetEvent($handle)
        [void][WslPartNative]::CloseHandle($handle)
    }
    if (-not $script:process.WaitForExit(3000)) {
        Stop-Process -Id $script:process.Id -Force
        $script:process.WaitForExit()
    }
}
try {
    $process = Start-Process -FilePath $proxyExe -ArgumentList @(
        '-d','0','-n','16','-o','3775834112','-w','--shutdown-event',$eventName) -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object FriendlyName -like '*WslPart*' | Select-Object -Last 1)
        if ($disk.Count -eq 1) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ($disk.Count -ne 1) { throw 'Timed out waiting for proxy disk.' }
    $physicalDrive = "\\.\PHYSICALDRIVE$($disk[0].Number)"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true
    $line = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL' | Where-Object { $_ -match '\sWslPart\s*$' } | Select-Object -First 1)
    if ($line.Count -ne 1) { throw 'WslPart disk not found in Linux.' }
    $device = '/dev/' + (($line[0] -split '\s+')[0])
    $mountPoint = Split-Path -Path $TestPath -Parent
    Invoke-WslRoot "mkdir -p '$mountPoint'; mount -o sync '$device' '$mountPoint'"
    $mounted = $true
    if ($RemoveGenerated) {
        Invoke-WslRoot "find '$mountPoint' -maxdepth 1 -type f \( -name 'wslpart-direct-persistence-check*.bin' -o -name 'wslpart-m4-rerun.bin' \) -print -delete; sync; umount '$mountPoint'"
    } else {
        Invoke-WslRoot "rm -f '$TestPath'; sync; umount '$mountPoint'"
    }
    $mounted = $false
    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed.' }
    $attached = $false
    Stop-Proxy
    Write-Host 'Known temporary direct-persistence test file removed.'
}
finally {
    if ($mounted) { try { Invoke-WslRoot "rm -f '$TestPath'; umount '$mountPoint'" | Out-Null } catch {} }
    if ($attached) { try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {} }
    try { Stop-Proxy } catch {}
}

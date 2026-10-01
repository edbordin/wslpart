[CmdletBinding()]
param([string]$Distro = 'Ubuntu')

$ErrorActionPreference = 'Stop'

if (-not ('WslPartNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartNative
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetEvent(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This test must run from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\m4-reuse'
$testLog = Join-Path $artifactDir 'test.log'
$testError = Join-Path $artifactDir 'test.error.log'
$debugLog = Join-Path $artifactDir 'winspd-debug.log'
$mountPoint = '/mnt/wslpart-m4-reuse'
$testFile = "$mountPoint/wslpart-m4-reuse.bin"
$eventName = "wslpart-reuse-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$attached = $false
$mounted = $false
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $testLog, $testError, $debugLog
try { Start-Transcript -Path $testLog -Force | Out-Null } catch {}

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

function Find-ProxyDisk {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' } |
            Select-Object -Last 1)
        if ($disk.Count -eq 1) {
            return "\\.\PHYSICALDRIVE$($disk[0].Number)"
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the WinSpd proxy disk.'
}

function Find-LinuxDevice {
    $lines = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL')
    $line = $lines | Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1
    if ($null -eq $line) {
        throw "Linux did not report a WslPart disk:`n$($lines -join "`n")"
    }
    return '/dev/' + (($line -split '\s+')[0])
}

function Stop-Proxy {
    if ($null -eq $process -or $process.HasExited) { return }
    $handle = [WslPartNative]::OpenEvent(0x00100001, $false, $eventName)
    if ($handle -ne [IntPtr]::Zero) {
        [void][WslPartNative]::SetEvent($handle)
        [void][WslPartNative]::CloseHandle($handle)
    }
    if (-not $process.WaitForExit(10000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

try {
    $process = Start-Process -FilePath $proxyExe -ArgumentList @(
        '-d', '0', '-n', '16', '-o', '3775834112', '-w',
        '--shutdown-event', $eventName, '--debug-log', $debugLog) -WindowStyle Hidden -PassThru
    $physicalDrive = Find-ProxyDisk
    Write-Host "Proxy disk: $physicalDrive"

    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'First wsl --mount failed.' }
    $attached = $true
    $linuxDevice = Find-LinuxDevice
    $writeOutput = Invoke-WslRoot @"
set -eu
mkdir -p '$mountPoint'
mount -o sync '$linuxDevice' '$mountPoint'
dd if=/dev/urandom of='$testFile' bs=1M count=4 conv=fsync status=none
sha256sum '$testFile'
sync
umount '$mountPoint'
mkdir -p '$mountPoint'
mount -o sync '$linuxDevice' '$mountPoint'
sha256sum '$testFile'
test -f '$testFile'
rm -f '$testFile'
sync
umount '$mountPoint'
"@
    $mounted = $false
    $checksums = $writeOutput | Where-Object { $_ -match '^[0-9a-f]{64}\s+' }
    Write-Host "Same-shell remount checksums: $($checksums -join ', ')"

    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'Second wsl --unmount failed.' }
    $attached = $false
    Stop-Proxy
    Write-Host 'Same-proxy M4 persistence test passed.'
}
catch {
    $_ | Out-String | Set-Content -LiteralPath $testError
    throw
}
finally {
    if ($mounted) {
        try { Invoke-WslRoot "rm -f '$testFile'; umount '$mountPoint'" | Out-Null } catch {}
    }
    if ($attached) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    try { Stop-Proxy } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

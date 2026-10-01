[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [string]$PartitionDevice = '\\.\Harddisk0Partition16',
    [string]$TestPath = '/mnt/wslpart-direct-persistence-check/wslpart-direct-persistence-check.bin'
)

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
    throw 'This verification must run from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$readerExe = Join-Path $repoRoot 'build\bin\Release\wslpart-read-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\real-write-verify'
$logPath = Join-Path $artifactDir 'verify.log'
$eventName = "wslpart-real-verify-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$attached = $false
$mounted = $false
$physicalDrive = $null
$linuxDevice = $null
$extent = $null
$expectedHash = $null

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $logPath
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

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
    throw 'Timed out waiting for the read-only proxy disk.'
}

function Find-LinuxDevice {
    $line = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL' |
        Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1)
    if ($line.Count -ne 1) {
        throw 'Linux did not report a WslPart disk.'
    }
    return '/dev/' + (($line[0] -split '\s+')[0])
}

function Stop-Proxy {
    if ($null -eq $process -or $process.HasExited) { return }
    $handle = [WslPartNative]::OpenEvent(0x00100001, $false, $eventName)
    if ($handle -ne [IntPtr]::Zero) {
        [void][WslPartNative]::SetEvent($handle)
        [void][WslPartNative]::CloseHandle($handle)
    }
    if (-not $process.WaitForExit(10000)) {
        throw 'Read-only proxy did not stop gracefully.'
    }
}

try {
    if (-not (Test-Path -LiteralPath $proxyExe) -or
        -not (Test-Path -LiteralPath $readerExe)) {
        throw 'Verifier binaries are not built.'
    }

    $process = Start-Process -FilePath $proxyExe -ArgumentList @(
        '-d', '0', '-n', '16', '-o', '3775834112', '--readonly',
        '--shutdown-event', $eventName) -WindowStyle Hidden -PassThru
    $physicalDrive = Find-ProxyDisk
    Write-Host "Read-only proxy disk: $physicalDrive"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true
    $linuxDevice = Find-LinuxDevice
    Write-Host "Linux device: $linuxDevice"

    $mountPoint = Split-Path -Path $TestPath -Parent
    Invoke-WslRoot "mkdir -p '$mountPoint'; mount -o ro,noload '$linuxDevice' '$mountPoint'"
    $mounted = $true
    Invoke-WslRoot "test -f '$TestPath'"
    $expectedHash = ((Invoke-WslRoot "sha256sum '$TestPath'") |
        Select-Object -First 1).ToString().Split()[0]
    $filefrag = @(Invoke-WslRoot "filefrag -v '$TestPath'")
    $blockLine = $filefrag | Where-Object { $_ -match 'blocks of (\d+) bytes' } | Select-Object -First 1
    if ($null -eq $blockLine) { throw 'Could not determine filesystem block size.' }
    $blockSize = [UInt64]$Matches[1]
    $extentLines = @($filefrag | Where-Object {
        $_ -match '^\s*\d+:\s+\d+\.\.\s+\d+:\s+(\d+)\.\.\s+(\d+):\s+(\d+):'
    })
    if ($extentLines.Count -ne 1) {
        throw "Refusing verification because the test file has $($extentLines.Count) extents; no filesystem changes were made."
    }
    $extentLines[0] -match '^\s*\d+:\s+\d+\.\.\s+\d+:\s+(\d+)\.\.\s+(\d+):\s+(\d+):' | Out-Null
    $physicalBlock = [UInt64]$Matches[1]
    $extentLengthBlocks = [UInt64]$Matches[3]
    $extent = [pscustomobject]@{
        Offset = $physicalBlock * $blockSize
        Length = $extentLengthBlocks * $blockSize
    }
    Write-Host "Expected checksum: $expectedHash"
    Write-Host "Filesystem block size: $blockSize; source offset: $($extent.Offset); length: $($extent.Length)"

    Invoke-WslRoot "umount '$mountPoint'"
    $mounted = $false
    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed.' }
    $attached = $false
    Stop-Proxy

    $direct = @(& $readerExe --device $PartitionDevice `
        --offset ([string]$extent.Offset) --length ([string]$extent.Length) 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Direct read failed:`n$($direct -join "`n")"
    }
    $directHash = ($direct | Select-Object -First 1).ToString().Split()[0]
    Write-Host "Direct post-close checksum: $directHash"
    if ($directHash -ne $expectedHash) {
        throw 'Direct post-close bytes do not match the Linux checksum.'
    }
    Write-Host 'Read-only real-partition persistence verification passed.'
}
finally {
    if ($mounted) { try { Invoke-WslRoot "umount '$mountPoint'" | Out-Null } catch {} }
    if ($attached) { try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {} }
    try { Stop-Proxy } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

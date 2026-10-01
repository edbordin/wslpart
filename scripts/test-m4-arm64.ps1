[CmdletBinding()]
param(
    [UInt32]$DiskNumber = 0,
    [UInt32]$PartitionNumber = 16,
    [UInt64]$ExpectedStartSector = 3775834112,
    [string]$Distro = 'Ubuntu'
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
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetEvent(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
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
$artifactDir = Join-Path $repoRoot 'artifacts\m4-rerun'
$proxyStdout = Join-Path $artifactDir 'proxy.stdout.log'
$proxyStderr = Join-Path $artifactDir 'proxy.stderr.log'
$testLog = Join-Path $artifactDir 'test.log'
$testError = Join-Path $artifactDir 'test.error.log'
$mountPoint = '/mnt/wslpart-m4-rerun'
$testFile = "$mountPoint/wslpart-m4-rerun.bin"

if (-not (Test-Path -LiteralPath $proxyExe)) {
    throw "Proxy executable not found: $proxyExe"
}

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $proxyStdout, $proxyStderr
Remove-Item -Force -ErrorAction SilentlyContinue $testLog, $testError
try { Start-Transcript -Path $testLog -Force | Out-Null } catch {}

$proxyProcesses = @()
$proxyEvents = @{}
$wslKeepAlive = $null
$attached = $false
$mounted = $false

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)

    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

function Start-WslKeepAlive {
    $script:wslKeepAlive = Start-Process -FilePath wsl.exe -ArgumentList @(
        '-d', $Distro, '-u', 'root', '--', 'sleep', '600') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
}

function Stop-WslKeepAlive {
    if ($null -ne $script:wslKeepAlive -and
        -not $script:wslKeepAlive.HasExited) {
        Stop-Process -Id $script:wslKeepAlive.Id -Force
        $script:wslKeepAlive.WaitForExit()
    }
}

function Find-ProxyDisk {
    param([int]$TimeoutSeconds = 10)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' } |
            Sort-Object Number |
            Select-Object -Last 1)
        if ($disk.Count -eq 1) {
            return "\\.\PHYSICALDRIVE$($disk[0].Number)"
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw 'Timed out waiting for the Virtual WinSpd WslPart disk.'
}

function Start-Proxy {
    $eventName = "wslpart-test-$([Guid]::NewGuid().ToString('N'))"
    $arguments = @(
        '-d', [string]$DiskNumber,
        '-n', [string]$PartitionNumber,
        '-o', [string]$ExpectedStartSector,
        '-w',
        '--shutdown-event', $eventName
    )
    $startParameters = @{
        FilePath = $proxyExe
        ArgumentList = $arguments
        RedirectStandardOutput = $proxyStdout
        RedirectStandardError = $proxyStderr
        WindowStyle = 'Hidden'
        PassThru = $true
    }
    $process = Start-Process @startParameters
    $script:proxyProcesses += $process
    $script:proxyEvents[$process.Id] = $eventName
    return Find-ProxyDisk
}

function Wait-ProxyDiskGone {
    param([int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' })
        if ($disk.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw 'Timed out waiting for the WinSpd proxy disk to disappear.'
}

function Stop-Proxy {
    param([System.Diagnostics.Process]$Process)

    if ($null -ne $Process -and -not $Process.HasExited) {
        $eventName = $script:proxyEvents[$Process.Id]
        if ($null -ne $eventName) {
            $eventHandle = [WslPartNative]::OpenEvent(
                0x00100001, $false, $eventName)
            if ($eventHandle -ne [IntPtr]::Zero) {
                [void][WslPartNative]::SetEvent($eventHandle)
                [void][WslPartNative]::CloseHandle($eventHandle)
            }
        }
        if (-not $Process.WaitForExit(10000)) {
            Stop-Process -Id $Process.Id -Force
            $Process.WaitForExit()
        }
    }
}

function Find-LinuxProxyDevice {
    $lines = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL')
    $line = $lines | Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1
    if ($null -eq $line) {
        throw "Linux did not report a WslPart disk:`n$($lines -join "`n")"
    }
    return '/dev/' + (($line -split '\s+')[0])
}

try {
    Write-Host 'Starting first locked writable proxy...'
    $proxy1 = $null
    $physicalDrive = Start-Proxy
    $proxy1 = $proxyProcesses[-1]
    Write-Host "Proxy disk: $physicalDrive"

    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --mount failed with exit code $LASTEXITCODE"
    }
    $attached = $true
    Start-WslKeepAlive
    $linuxDevice = Find-LinuxProxyDevice
    Write-Host "Linux device: $linuxDevice"

    $writeOutput = Invoke-WslRoot @"
set -eu
mkdir -p '$mountPoint'
mount -o sync '$linuxDevice' '$mountPoint'
dd if=/dev/urandom of='$testFile' bs=1M count=4 conv=fsync status=none
sha256sum '$testFile'
sync
umount '$mountPoint'
blockdev --flushbufs '$linuxDevice'
"@
    $mounted = $false
    $checksumLine = $writeOutput | Where-Object { $_ -match '^[0-9a-f]{64}\s+' } |
        Select-Object -Last 1
    if ($null -eq $checksumLine) {
        throw "Could not obtain the first checksum:`n$($writeOutput -join "`n")"
    }
    $checksum = ($checksumLine -split '\s+')[0]
    Write-Host "First checksum: $checksum"

    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) {
        throw "First wsl --unmount failed with exit code $LASTEXITCODE"
    }
    $attached = $false
    Stop-Proxy $proxy1
    Wait-ProxyDiskGone

    Write-Host 'Recreating the locked writable proxy...'
    $proxy2 = $null
    $physicalDrive = Start-Proxy
    $proxy2 = $proxyProcesses[-1]
    Write-Host "Proxy disk: $physicalDrive"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) {
        throw "Second wsl --mount failed with exit code $LASTEXITCODE"
    }
    $attached = $true
    $linuxDevice = Find-LinuxProxyDevice
    $verifyOutput = Invoke-WslRoot @"
set -eu
mkdir -p '$mountPoint'
mount -o sync '$linuxDevice' '$mountPoint'
sha256sum '$testFile'
test "`$(sha256sum '$testFile' | cut -d ' ' -f 1)" = '$checksum'
rm -f '$testFile'
sync
umount '$mountPoint'
"@
    $mounted = $false
    $verifyLine = $verifyOutput | Where-Object { $_ -match '^[0-9a-f]{64}\s+' } |
        Select-Object -Last 1
    if ($null -eq $verifyLine -or ($verifyLine -split '\s+')[0] -ne $checksum) {
        throw "Checksum mismatch:`n$($verifyOutput -join "`n")"
    }
    Write-Host "Reattach checksum: $(($verifyLine -split '\s+')[0])"

    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) {
        throw "Second wsl --unmount failed with exit code $LASTEXITCODE"
    }
    $attached = $false
    Stop-Proxy $proxy2
    Wait-ProxyDiskGone
    Write-Host 'Milestone 4 rerun passed.'
}
catch {
    $_ | Out-String | Set-Content -LiteralPath $testError
    throw
}
finally {
    if ($mounted) {
        try { Invoke-WslRoot "umount '$mountPoint'" | Out-Null } catch {}
    }
    if ($attached) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    foreach ($process in $proxyProcesses) {
        try { Stop-Proxy $process } catch {}
    }
    try { Stop-WslKeepAlive } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

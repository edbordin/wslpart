[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [int]$Disk = 0,
    [int]$Partition = 16,
    [UInt64]$ExpectedStartSector = 3775834112,
    [UInt64]$ExpectedSize = 52427751424
)

$ErrorActionPreference = 'Stop'

if (-not ('WslPartDeathStressNative' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartDeathStressNative
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
    throw 'Run this stress test from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\shared-ring-death-stress'
$logPath = Join-Path $artifactDir 'stress.log'
$proxyOutputPath = Join-Path $artifactDir 'proxy-output.log'
$proxyErrorPath = Join-Path $artifactDir 'proxy-error.log'
$proxyDebugPath = Join-Path $artifactDir 'proxy-debug.log'
$fioOutputPath = Join-Path $artifactDir 'fio-output.log'
$fioErrorPath = Join-Path $artifactDir 'fio-error.log'
$mountPoint = '/mnt/wslpart-ring-death'
$eventName = "wslpart-ring-death-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$fioProcess = $null
$physicalDrive = $null
$attached = $false
$mounted = $false

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue @(
    $logPath, $proxyOutputPath, $proxyErrorPath, $proxyDebugPath,
    $fioOutputPath, $fioErrorPath)
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
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $diskObject = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -like '*WslPart*' -and
                $_.Size -eq $ExpectedSize
            } | Select-Object -Last 1)
        if ($diskObject.Count -eq 1) {
            return "\\.\PHYSICALDRIVE$($diskObject[0].Number)"
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the WslPart disk.'
}

function Stop-Fio {
    if ($null -ne $script:fioProcess -and -not $script:fioProcess.HasExited) {
        Stop-Process -Id $script:fioProcess.Id -Force -ErrorAction SilentlyContinue
        $script:fioProcess.WaitForExit()
    }
}

try {
    if (-not (Test-Path -LiteralPath $proxyExe)) {
        throw "Proxy binary not found: $proxyExe"
    }

    $arguments = @(
        'attach', '--disk', [string]$Disk, '--partition', [string]$Partition,
        '--expected-start-sector', [string]$ExpectedStartSector, '--readonly',
        '--transport', 'shared-ring', '--dispatcher-threads', '2',
        '--shutdown-event', $eventName, '--debug-log', $proxyDebugPath)
    $process = Start-Process -FilePath $proxyExe -ArgumentList $arguments `
        -RedirectStandardOutput $proxyOutputPath -RedirectStandardError $proxyErrorPath `
        -WindowStyle Hidden -PassThru
    $physicalDrive = Find-ProxyDisk
    Write-Host "Proxy disk: $physicalDrive; proxy PID: $($process.Id)"

    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true

    $linuxDevice = (Invoke-WslRoot 'lsblk -dn -o NAME,MODEL' |
        Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1)
    if ($null -eq $linuxDevice) { throw 'WSL did not report the WslPart disk.' }
    $linuxDevice = '/dev/' + (($linuxDevice -split '\s+')[0])
    Write-Host "Linux device: $linuxDevice"

    Invoke-WslRoot "mkdir -p '$mountPoint'; mount -o ro '$linuxDevice' '$mountPoint'"
    $mounted = $true
    Invoke-WslRoot "test -f '$mountPoint/wslpart-m6.fio'"

    $fioArgs = @('-d', $Distro, '-u', 'root', '--', 'fio',
        '--name=ring-death', "--filename=$mountPoint/wslpart-m6.fio",
        '--ioengine=libaio', '--rw=randread', '--bs=4k', '--iodepth=32', '--runtime=60',
        '--time_based=1', '--direct=1', '--group_reporting=1')
    $fioProcess = Start-Process -FilePath 'wsl.exe' -ArgumentList $fioArgs `
        -RedirectStandardOutput $fioOutputPath -RedirectStandardError $fioErrorPath `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    if ($process.HasExited) {
        throw "Proxy exited before forced termination (exit code $($process.ExitCode))."
    }

    Write-Host "Force-terminating proxy PID $($process.Id) while read I/O is active."
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
    Write-Host "Proxy exit code after forced termination: $($process.ExitCode)"

    Stop-Fio
    try { Invoke-WslRoot "umount '$mountPoint'" | Out-Null } catch {}
    $mounted = $false
    try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    $attached = $false

    $deadline = (Get-Date).AddSeconds(20)
    do {
        $remaining = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ($remaining.Count -ne 0) {
        throw 'The synthetic WslPart disk remained after proxy process death.'
    }

    Write-Host 'SharedRingV1 process-death cleanup passed; no synthetic disk remains.'
}
finally {
    Stop-Fio
    if ($mounted) { try { Invoke-WslRoot "umount '$mountPoint'" | Out-Null } catch {} }
    if ($attached -and $null -ne $physicalDrive) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $handle = [WslPartDeathStressNative]::OpenEvent(0x00100002, $false, $eventName)
            if ($handle -ne [IntPtr]::Zero) {
                [void][WslPartDeathStressNative]::SetEvent($handle)
                [void][WslPartDeathStressNative]::CloseHandle($handle)
            }
        } catch {}
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    try { Stop-Transcript | Out-Null } catch {}
}

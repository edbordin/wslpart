param(
    [string]$Distro = 'Ubuntu',
    [int]$Disk = 0,
    [int]$Partition = 16,
    [UInt64]$ExpectedStartSector = 3775834112,
    [UInt64]$ExpectedSize = 52427751424
)

$ErrorActionPreference = 'Stop'

if (-not ('WslPartM5Native' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartM5Native
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
    throw 'Run this test from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\m5-cli'
$transcriptPath = Join-Path $artifactDir 'test.log'
$stdoutPath = Join-Path $artifactDir 'proxy.stdout.log'
$stderrPath = Join-Path $artifactDir 'proxy.stderr.log'
$debugPath = Join-Path $artifactDir 'proxy.debug.log'
$eventName = "wslpart-m5-cli-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$physicalDrive = $null
$attached = $false

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $transcriptPath, $stdoutPath, $stderrPath, $debugPath
try { Start-Transcript -Path $transcriptPath -Force | Out-Null } catch {}

function Get-NewProxyDisk {
    param([object[]]$Before)
    $beforeNumbers = @($Before | ForEach-Object { [int]$_.Number })
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $candidates = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FriendlyName -like '*WslPart*' -and
                $_.Size -eq $ExpectedSize -and
                $beforeNumbers -notcontains [int]$_.Number
            })
        if ($candidates.Count -eq 1) {
            return $candidates[0]
        }
        if ($candidates.Count -gt 1) {
            throw 'More than one new WslPart disk has the expected capacity.'
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the newly-created WslPart disk.'
}

function Signal-Shutdown {
    $handle = [WslPartM5Native]::OpenEvent(0x00100002, $false, $eventName)
    if ($handle -eq [IntPtr]::Zero) {
        throw "OpenEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        if (-not [WslPartM5Native]::SetEvent($handle)) {
            throw "SetEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
    finally {
        [void][WslPartM5Native]::CloseHandle($handle)
    }
}

try {
    if (-not (Test-Path -LiteralPath $proxyExe)) {
        throw "Proxy binary not found: $proxyExe"
    }

    $before = @(Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like '*WslPart*' })
    $arguments = @(
        'attach', '--disk', [string]$Disk, '--partition', [string]$Partition,
        '--expected-start-sector', [string]$ExpectedStartSector, '--readonly',
        '--shutdown-event', $eventName, '--debug-log', $debugPath
    )
    $process = Start-Process -FilePath $proxyExe -ArgumentList $arguments `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -WindowStyle Hidden -PassThru

    $diskObject = Get-NewProxyDisk -Before $before
    $physicalDrive = "\\.\PHYSICALDRIVE$($diskObject.Number)"
    Write-Host "CLI-created proxy disk: $physicalDrive"

    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true
    $linux = @(& wsl.exe -d $Distro -u root -- bash -lc "lsblk -dn -o NAME,TYPE,SIZE,FSTYPE,MODEL" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "lsblk failed: $($linux -join ' ')" }
    $linux | ForEach-Object { Write-Host $_ }
    if (-not ($linux -match '\bdisk\b.*\bWslPart\b')) {
        throw 'WSL did not report the expected standalone WslPart disk.'
    }

    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed.' }
    $attached = $false
    Signal-Shutdown
    if (-not $process.WaitForExit(20000)) {
        throw 'Proxy did not exit after graceful shutdown.'
    }
    $process.Refresh()
    $proxyExitCode = [int]$process.ExitCode
    Write-Host "Proxy exit code: $proxyExitCode"
    if ($proxyExitCode -ne 0) {
        throw "Proxy exited with code $proxyExitCode."
    }

    $stdout = Get-Content $stdoutPath -Raw
    if ($stdout -notmatch 'Attach to WSL with:') {
        throw 'CLI did not print the WSL attach command.'
    }
    if ($stdout -notmatch 'Cache: enabled') {
        throw 'CLI did not report caching enabled.'
    }
    Write-Host 'Milestone 5 CLI/lifecycle test passed.'
}
finally {
    if ($attached -and $null -ne $physicalDrive) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    if ($null -ne $process -and -not $process.HasExited) {
        try { Signal-Shutdown } catch {}
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force
        }
    }
    try { Stop-Transcript | Out-Null } catch {}
}

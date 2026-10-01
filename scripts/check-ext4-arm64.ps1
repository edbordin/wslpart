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
    throw 'This check must run from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\ext4-check'
$logPath = Join-Path $artifactDir 'check.log'
$eventName = "wslpart-ext4-check-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$attached = $false

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $logPath
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    return $output
}

try {
    $process = Start-Process -FilePath $proxyExe -ArgumentList @(
        '-d', '0', '-n', '16', '-o', '3775834112', '--readonly',
        '--shutdown-event', $eventName) -WindowStyle Hidden -PassThru

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' } |
            Select-Object -Last 1)
        if ($disk.Count -eq 1) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ($disk.Count -ne 1) { throw 'Timed out waiting for the proxy disk.' }

    $physicalDrive = "\\.\PHYSICALDRIVE$($disk[0].Number)"
    Write-Host "Proxy disk: $physicalDrive"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true

    $deviceLines = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL')
    $deviceLine = $deviceLines | Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1
    if ($null -eq $deviceLine) { throw 'Linux did not report a WslPart disk.' }
    $linuxDevice = '/dev/' + (($deviceLine -split '\s+')[0])
    Write-Host "Linux device: $linuxDevice"

    $checkOutput = Invoke-WslRoot "e2fsck -fn '$linuxDevice' 2>&1; exit 0"
    $checkOutput | ForEach-Object { Write-Host $_ }

    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed.' }
    $attached = $false

    $handle = [WslPartNative]::OpenEvent(0x00100001, $false, $eventName)
    if ($handle -ne [IntPtr]::Zero) {
        [void][WslPartNative]::SetEvent($handle)
        [void][WslPartNative]::CloseHandle($handle)
    }
    if (-not $process.WaitForExit(10000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    Write-Host 'Read-only ext4 check completed.'
}
finally {
    if ($attached) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $handle = [WslPartNative]::OpenEvent(0x00100001, $false, $eventName)
            if ($handle -ne [IntPtr]::Zero) {
                [void][WslPartNative]::SetEvent($handle)
                [void][WslPartNative]::CloseHandle($handle)
            }
            if (-not $process.WaitForExit(10000)) {
                Stop-Process -Id $process.Id -Force
            }
        } catch {}
    }
    try { Stop-Transcript | Out-Null } catch {}
}

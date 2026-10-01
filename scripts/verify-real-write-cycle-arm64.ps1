[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [string]$PartitionDevice = '\\.\Harddisk0Partition16',
    [string]$TestPath,
    [ValidateSet('legacy', 'shared-ring')]
    [string]$Transport = 'legacy',
    [UInt32]$DispatcherThreads = 2,
    [ValidateSet('always', 'guest')]
    [string]$SyncPolicy = 'guest',
    [ValidateSet('cached', 'none')]
    [string]$Buffering = 'cached',
    [switch]$CleanupOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($TestPath)) {
    $TestPath = "/mnt/wslpart-direct-persistence-check/wslpart-direct-persistence-check-$([Guid]::NewGuid().ToString('N')).bin"
}

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
$artifactDir = Join-Path $repoRoot 'artifacts\real-write-cycle'
$logPath = Join-Path $artifactDir 'verify.log'
$debugLogPath = Join-Path $artifactDir 'proxy-debug.log'
$proxyOutputPath = Join-Path $artifactDir 'proxy-output.log'
$proxyErrorPath = Join-Path $artifactDir 'proxy-error.log'
$mountPoint = '/mnt/wslpart-direct-persistence-check'
$mounted = $false
$attached = $false
$process = $null
$eventName = $null
$physicalDrive = $null
$testCreated = $false
    $expected = @()

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $logPath
Remove-Item -Force -ErrorAction SilentlyContinue $debugLogPath
Remove-Item -Force -ErrorAction SilentlyContinue $proxyOutputPath
Remove-Item -Force -ErrorAction SilentlyContinue $proxyErrorPath
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

function Find-LinuxDevice {
    $line = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL' |
        Where-Object { $_ -match '\sWslPart\s*$' } |
        Select-Object -First 1)
    if ($line.Count -ne 1) { throw 'Linux did not report a WslPart disk.' }
    return '/dev/' + (($line[0] -split '\s+')[0])
}

function Find-ProxyDisk {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*WslPart*' } |
            Select-Object -Last 1)
        if ($disk.Count -eq 1) { return "\\.\PHYSICALDRIVE$($disk[0].Number)" }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the WslPart disk.'
}

function Start-Proxy {
    param([switch]$Writable)
    $script:eventName = "wslpart-direct-check-$([Guid]::NewGuid().ToString('N'))"
    $arguments = @('-d', '0', '-n', '16', '-o', '3775834112',
        '--shutdown-event', $eventName, '-D', $debugLogPath,
        '--transport', $Transport,
        '--dispatcher-threads', [string]$DispatcherThreads,
        '--sync-policy', $SyncPolicy,
        '--buffering', $Buffering)
    if ($Writable) { $arguments += '-w' } else { $arguments += '--readonly' }
    $script:process = Start-Process -FilePath $proxyExe -ArgumentList $arguments -WindowStyle Hidden `
        -RedirectStandardOutput $proxyOutputPath -RedirectStandardError $proxyErrorPath -PassThru
    return Find-ProxyDisk
}

function Stop-Proxy {
    if ($null -eq $script:process -or $script:process.HasExited) { return }
    $handle = [WslPartNative]::OpenEvent(0x00100002, $false, $script:eventName)
    if ($handle -ne [IntPtr]::Zero) {
        $setOk = [WslPartNative]::SetEvent($handle)
        if (-not $setOk) {
            Write-Host "Could not signal shutdown event '$($script:eventName)': Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        [void][WslPartNative]::CloseHandle($handle)
    } else {
        Write-Host "Could not open shutdown event '$($script:eventName)': Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    if (-not $script:process.WaitForExit(30000)) {
        Write-Host 'Proxy did not stop through the test event; closing it after WSL detach.'
        Stop-Process -Id $script:process.Id -Force
        $script:process.WaitForExit()
    }
}

function Detach-And-Stop {
    if ($script:attached) {
        & wsl.exe --unmount $script:physicalDrive
        if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed.' }
        $script:attached = $false
    }
    Stop-Proxy
}

try {
    if (-not (Test-Path -LiteralPath $proxyExe) -or
        -not (Test-Path -LiteralPath $readerExe)) {
        throw 'Verifier binaries are not built.'
    }

    $physicalDrive = Start-Proxy -Writable
    Write-Host "Writable proxy disk: $physicalDrive"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed.' }
    $attached = $true
    $linuxDevice = Find-LinuxDevice
    Write-Host "Linux device: $linuxDevice"

    Invoke-WslRoot "mkdir -p '$mountPoint'; mount -o sync '$linuxDevice' '$mountPoint'"
    $mounted = $true
    if ($CleanupOnly) {
        Invoke-WslRoot "rm -f '$TestPath'; sync; umount '$mountPoint'"
        $mounted = $false
        Detach-And-Stop
        Write-Host "Removed only the requested test artifact: $TestPath"
        return
    }
    Invoke-WslRoot "test ! -e '$TestPath'"
    Invoke-WslRoot "dd if=/dev/zero of='$TestPath' bs=1M count=1 conv=fsync status=none; sync"
    $testCreated = $true
    $filefrag = @(Invoke-WslRoot "filefrag -v '$TestPath'")
    $blockLine = $filefrag | Where-Object { $_ -match 'blocks of (\d+) bytes' } | Select-Object -First 1
    if ($null -eq $blockLine -or -not ($blockLine -match 'blocks of (\d+) bytes')) {
        throw 'Could not determine filesystem block size.'
    }
    $blockSize = [UInt64]$Matches[1]
    $extentLines = @($filefrag | Where-Object {
        $_ -match '^\s*\d+:\s+(\d+)\.\.\s+(\d+):\s+(\d+)\.\.\s+(\d+):\s+(\d+):'
    })
    if ($extentLines.Count -lt 1) { throw 'Could not determine file extents.' }
    foreach ($line in $extentLines) {
        if (-not ($line -match '^\s*\d+:\s+(\d+)\.\.\s+(\d+):\s+(\d+)\.\.\s+(\d+):\s+(\d+):')) {
            throw "Could not parse extent: $line"
        }
        $logicalBlock = [UInt64]$Matches[1]
        $logicalEnd = [UInt64]$Matches[2]
        $physicalBlock = [UInt64]$Matches[3]
        $lengthBlocks = [UInt64]$Matches[5]
        $chunkHash = ((Invoke-WslRoot "dd if='$TestPath' bs=$blockSize skip=$logicalBlock count=$lengthBlocks status=none | sha256sum") |
            Select-Object -First 1).ToString().Split()[0]
        $expected += [pscustomobject]@{
            Offset = $physicalBlock * $blockSize
            Length = $lengthBlocks * $blockSize
            Hash = $chunkHash
            LogicalEnd = $logicalEnd
        }
        Write-Host "Recorded extent offset=$($expected[-1].Offset) length=$($expected[-1].Length) hash=$chunkHash"
    }
    Write-Host "Recorded $($expected.Count) filesystem extent(s) for the temporary file."
    $initialFileHashLine = Invoke-WslRoot "sha256sum '$TestPath'" |
        Where-Object { $_ -match '^[0-9a-f]{64}\s+' } | Select-Object -First 1
    if ($null -eq $initialFileHashLine) { throw 'Could not obtain the temporary file checksum.' }
    $initialFileHash = ($initialFileHashLine -split '\s+')[0]
    Write-Host "Initial file checksum: $initialFileHash"

    Invoke-WslRoot "umount '$mountPoint'"
    $mounted = $false
    Detach-And-Stop

    foreach ($chunk in $expected) {
        $direct = @(& $readerExe --device $PartitionDevice `
            --offset ([string]$chunk.Offset) --length ([string]$chunk.Length) 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Direct read failed: $($direct -join ' ')" }
        $directHash = ($direct | Select-Object -First 1).ToString().Split()[0]
        Write-Host "Extent offset=$($chunk.Offset) length=$($chunk.Length) expected=$($chunk.Hash) direct=$directHash"
        if ($directHash -ne $chunk.Hash) { throw 'Post-close direct bytes do not match.' }
    }
    Write-Host 'Direct post-close partition verification passed.'

    # Reattach the same real partition through a newly-created proxy and verify
    # the file through a normal ext4 mount before removing it.
    $physicalDrive = Start-Proxy -Writable
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'cleanup wsl --mount failed.' }
    $attached = $true
    $linuxDevice = Find-LinuxDevice
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $reattachOutput = @(& wsl.exe -d $Distro -u root -- bash -lc @"
set +e
mkdir -p '$mountPoint'
if mount -o sync '$linuxDevice' '$mountPoint'; then
    echo 'MOUNT_STATUS=0'
    findmnt -T '$mountPoint' -o TARGET,SOURCE,FSTYPE,OPTIONS
    mountpoint '$mountPoint'
    ls -la '$mountPoint'
    sha256sum '$TestPath'
    if rm -f '$TestPath'; then
        echo 'REMOVE_STATUS=0'
    else
        echo 'REMOVE_STATUS=1'
    fi
    sync
    umount '$mountPoint'
else
    echo 'MOUNT_STATUS=1'
fi
exit 0
"@ 2>&1)
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Write-Host "Reattach mount verification: $($reattachOutput -join ' ')"
    $mountStatusLine = $reattachOutput | Where-Object { $_ -match '^MOUNT_STATUS=(\d+)$' } | Select-Object -First 1
    $removeStatusLine = $reattachOutput | Where-Object { $_ -match '^REMOVE_STATUS=(\d+)$' } | Select-Object -First 1
    $reattachHashLine = $reattachOutput | Where-Object { $_ -match '^[0-9a-f]{64}\s+' } | Select-Object -Last 1
    $reattachMounted = $false
    $reattachVerified = $false
    if ($null -ne $mountStatusLine -and $mountStatusLine -match '^MOUNT_STATUS=(\d+)$') {
        $reattachMounted = [int]$Matches[1] -eq 0
        if ($reattachMounted -and $null -ne $reattachHashLine) {
            $reattachHash = ($reattachHashLine -split '\s+')[0]
            $reattachVerified = $reattachHash -eq $initialFileHash
            Write-Host "Reattach checksum: $reattachHash (expected $initialFileHash)"
        }
    }
    $mounted = $false
    Detach-And-Stop
    $removed = $false
    if ($null -ne $removeStatusLine -and $removeStatusLine -match '^REMOVE_STATUS=(\d+)$') {
        $removed = [int]$Matches[1] -eq 0
    }
    if ($reattachMounted -and $removed) {
        $testCreated = $false
    }
    if ((-not $reattachMounted -or -not $removed) -and $testCreated) {
        # The reattach mount failed, so use a final fresh proxy solely to
        # remove the temporary file before reporting the failed verification.
        $physicalDrive = Start-Proxy -Writable
        & wsl.exe --mount $physicalDrive --bare
        if ($LASTEXITCODE -ne 0) { throw 'fallback cleanup wsl --mount failed.' }
        $attached = $true
        $linuxDevice = Find-LinuxDevice
        Invoke-WslRoot "mkdir -p '$mountPoint'; mount -o sync '$linuxDevice' '$mountPoint'; rm -f '$TestPath'; sync; umount '$mountPoint'"
        $mounted = $false
        Detach-And-Stop
        $testCreated = $false
    }
    if (-not $reattachVerified) {
        throw 'Real-partition reattach/remount verification failed.'
    }
    Write-Host 'Real-partition reattach/remount verification passed; temporary file removed.'
}
finally {
    if ($mounted) { try { Invoke-WslRoot "rm -f '$TestPath'; umount '$mountPoint'" | Out-Null } catch {} }
    if ($attached) { try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {} }
    try { Stop-Proxy } catch {}
    try { Stop-Transcript | Out-Null } catch {}
}

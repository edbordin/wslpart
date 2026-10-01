[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [ValidateSet(0, 1)]
    [int]$CacheSupported = 1,
    [switch]$ShutdownVm,
    [switch]$DropCaches,
    [switch]$RestartRawDisk,
    [switch]$UnmountAll,
    [switch]$DeleteLinuxDevice,
    [switch]$NoLoad,
    [switch]$InspectBacking,
    [switch]$DetailedReattach,
    [switch]$FlushAfterReattach,
    [switch]$DropCachesAfterReattach
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$rawdiskExe = Join-Path $repoRoot 'third_party\winspd\build\VStudio\testing\build\Release\rawdisk-ARM64.exe'
$backingFile = Join-Path $repoRoot 'artifacts\m1\m1.rawdisk'
$artifactDir = Join-Path $repoRoot 'artifacts\stock-detach'
$rawdiskLog = Join-Path $artifactDir 'rawdisk.log'
$testLog = Join-Path $artifactDir 'test.log'
$mountPoint = '/mnt/wslpart-stock-detach'
$testFile = "$mountPoint/wslpart-stock-detach.bin"
$testFileFsPath = "/$([IO.Path]::GetFileName($testFile))"
$mountPointFsPath = '/'
$verifyMountOptions = if ($NoLoad) { 'ro,noload' } else { 'sync' }
$repoRootLinux = "/mnt/$($repoRoot.Substring(0, 1).ToLower())$($repoRoot.Substring(2).Replace('\', '/'))"
$backingFileLinux = "$repoRootLinux/artifacts/m1/m1.rawdisk"

if (-not (Test-Path -LiteralPath $rawdiskExe)) {
    throw "Stock rawdisk executable not found: $rawdiskExe"
}
if (-not (Test-Path -LiteralPath $backingFile)) {
    throw "Backing file not found: $backingFile"
}

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $rawdiskLog, $testLog

$rawdisk = $null
$keepAlive = $null
$attached = $false

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

function Invoke-WslProbe {
    param([Parameter(Mandatory)][string]$Command)
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        return @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
}

function Find-RawDisk {
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $disk = @(Get-Disk -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -like '*RawDisk*' } |
            Sort-Object Number | Select-Object -Last 1)
        if ($disk.Count -eq 1) {
            return "\\.\PHYSICALDRIVE$($disk[0].Number)"
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the stock WinSpd RawDisk.'
}

function Wait-LinuxRawDiskGone {
    param([int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $lines = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL')
        if (-not ($lines | Where-Object { $_ -match '\sRawDisk[A-Z]?\s*$' })) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for Linux to remove the stock RawDisk.'
}

function Find-LinuxRawDisk {
    $line = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL' |
        Where-Object { $_ -match '\sRawDisk[A-Z]?\s*$' } |
        Select-Object -First 1)
    if ($line.Count -ne 1) {
        throw 'Linux did not report the stock RawDisk.'
    }
    return '/dev/' + (($line[0] -split '\s+')[0])
}

function Start-KeepAlive {
    $script:keepAlive = Start-Process -FilePath wsl.exe -ArgumentList @(
        '-d', $Distro, '-u', 'root', '--', 'sleep', '600') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 1
}

function Stop-KeepAlive {
    if ($null -ne $script:keepAlive -and -not $script:keepAlive.HasExited) {
        Stop-Process -Id $script:keepAlive.Id -Force
        $script:keepAlive.WaitForExit()
    }
}

try {
    Start-Transcript -Path $testLog -Force | Out-Null
    $rawdisk = Start-Process -FilePath $rawdiskExe -ArgumentList @(
        '-f', $backingFile, '-c', '4194304', '-l', '512',
        '-W', '1', '-C', [string]$CacheSupported, '-U', '0', '-i', 'RawDiskA', '-D', $rawdiskLog) -WindowStyle Hidden -PassThru

    $physicalDrive = Find-RawDisk
    Write-Host "Stock disk: $physicalDrive"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw "wsl --mount failed with exit code $LASTEXITCODE" }
    $attached = $true
    Start-KeepAlive

    $linuxDevice = Find-LinuxRawDisk
    Write-Host "Linux device: $linuxDevice"

    $first = Invoke-WslRoot @"
set -eu
mkdir -p '$mountPoint'
    mount -o sync '$linuxDevice' '$mountPoint'
echo '--- initial mount ---'
findmnt -T '$mountPoint' -o TARGET,SOURCE,FSTYPE,OPTIONS
mountpoint '$mountPoint'
ls -la '$mountPoint'
stat '$mountPoint/test.txt'
dd if=/dev/urandom of='$testFile' bs=1M count=4 conv=fsync status=none
sha256sum '$testFile'
sync
umount '$mountPoint'
blockdev --flushbufs '$linuxDevice'
"@
    Write-Host "Initial mount inspection: $($first -join ' ')"
    if ($DropCaches) {
        Invoke-WslRoot 'sync; echo 3 > /proc/sys/vm/drop_caches'
        Write-Host 'Dropped Linux page and dentry caches before detach.'
    }
    if ($DeleteLinuxDevice) {
        $linuxName = ($linuxDevice -replace '^/dev/', '')
        Invoke-WslRoot "echo 1 > '/sys/block/$linuxName/device/delete'"
        Write-Host "Explicitly removed Linux device /dev/$linuxName before WSL detach."
    }
    $checksum = (($first | Where-Object { $_ -match '^[0-9a-f]{64}\s+' } |
        Select-Object -Last 1) -split '\s+')[0]
    if ([string]::IsNullOrWhiteSpace($checksum)) { throw 'No first checksum was produced.' }
    Write-Host "First checksum: $checksum"

    if ($ShutdownVm) {
        Stop-KeepAlive
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed with exit code $LASTEXITCODE" }
        Start-Sleep -Seconds 3
    } else {
        if ($UnmountAll) {
            & wsl.exe --unmount
        } else {
            & wsl.exe --unmount $physicalDrive
        }
        if ($LASTEXITCODE -ne 0) { throw "wsl --unmount failed with exit code $LASTEXITCODE" }
        Wait-LinuxRawDiskGone
    }
    $attached = $false

    if ($InspectBacking) {
        if ($null -ne $rawdisk -and -not $rawdisk.HasExited) {
            Stop-Process -Id $rawdisk.Id -Force
            $rawdisk.WaitForExit()
            Start-Sleep -Seconds 1
            Write-Host 'Stopped stock RawDisk before inspecting the backing image.'
        }
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $backingInspection = @(
                '--- backing image debugfs stat ---'
                & wsl.exe -d $Distro -u root -- debugfs -R "stat $testFileFsPath" $backingFileLinux 2>&1
                '--- backing image debugfs directory ---'
                & wsl.exe -d $Distro -u root -- debugfs -R "ls -l $mountPointFsPath" $backingFileLinux 2>&1
            )
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        Write-Host "Backing image inspection: $($backingInspection -join ' ')"
    }

    if ($RestartRawDisk) {
        if (-not $rawdisk.HasExited) {
            Stop-Process -Id $rawdisk.Id -Force
            $rawdisk.WaitForExit()
        }
        Start-Sleep -Seconds 2
        $rawdisk = Start-Process -FilePath $rawdiskExe -ArgumentList @(
            '-f', $backingFile, '-c', '4194304', '-l', '512',
            '-W', '1', '-C', [string]$CacheSupported, '-U', '0', '-i', 'RawDiskB', '-D', $rawdiskLog) -WindowStyle Hidden -PassThru
        Write-Host 'Restarted stock RawDisk with a new product ID.'
        $physicalDrive = Find-RawDisk
        Write-Host "Recreated stock disk: $physicalDrive"
    }

    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw "second wsl --mount failed with exit code $LASTEXITCODE" }
    $attached = $true
    $linuxDevice = Find-LinuxRawDisk
    Write-Host "Reattached Linux device: $linuxDevice"
    if ($FlushAfterReattach) {
        Invoke-WslRoot "blockdev --flushbufs '$linuxDevice'"
        Write-Host 'Flushed the reattached Linux block device before mounting.'
    }
    if ($DropCachesAfterReattach) {
        Invoke-WslRoot 'sync; echo 3 > /proc/sys/vm/drop_caches'
        Write-Host 'Dropped Linux page, dentry, and inode caches after reattach.'
    }
    if ($InspectBacking) {
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $deviceInspection = @(& wsl.exe -d $Distro -u root -- debugfs -R 'ls -l /' $linuxDevice 2>&1)
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        Write-Host "Reattached device inspection: $($deviceInspection -join ' ')"
    }
    if ($DetailedReattach) {
        $alternateMountPoint = "$mountPoint-alt"
        $detailedMountInspection = Invoke-WslProbe @"
set +e
for p in '$mountPoint' '$alternateMountPoint'; do
    mkdir -p "`$p"
    umount "`$p" 2>/dev/null
    echo "--- mount `$p ---"
    mount -o sync '$linuxDevice' "`$p"
    echo "mount_exit=`$?"
    findmnt -T "`$p" -o TARGET,SOURCE,FSTYPE,OPTIONS
    ls -la "`$p"
    sha256sum '$testFile' 2>&1
    umount "`$p"
done
exit 0
"@
        Write-Host "Detailed reattach inspection: $($detailedMountInspection -join ' ')"
        Write-Host 'Detailed reattach inspection completed.'
        return
    }
    $second = Invoke-WslProbe @"
set +e
mkdir -p '$mountPoint'
mount -o $verifyMountOptions '$linuxDevice' '$mountPoint'
echo '--- reattach mount ---'
findmnt -T '$mountPoint' -o TARGET,SOURCE,FSTYPE,OPTIONS
mountpoint '$mountPoint'
ls -la '$mountPoint'
stat '$mountPoint/test.txt'
sha256sum '$testFile'
umount '$mountPoint'
exit 0
"@
    Write-Host "Reattach result: $($second -join ' ')"
    $secondChecksumLine = $second | Where-Object { $_ -match '^[0-9a-f]{64}\s+' } | Select-Object -Last 1
    if ($null -eq $secondChecksumLine) {
        throw "Reattach mount inspection did not produce the test-file checksum."
    }
    $secondChecksum = ($secondChecksumLine -split '\s+')[0]
    if ($secondChecksum -ne $checksum) {
        throw "Reattached checksum mismatch: expected $checksum, got $secondChecksum."
    }
    Write-Host "Stock WinSpd detach/reattach test passed (CacheSupported=$CacheSupported)."
}
finally {
    if ($attached) { try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {} }
    try { Stop-KeepAlive } catch {}
    if ($null -ne $rawdisk -and -not $rawdisk.HasExited) {
        Stop-Process -Id $rawdisk.Id -Force
        $rawdisk.WaitForExit()
    }
    try { Stop-Transcript | Out-Null } catch {}
}

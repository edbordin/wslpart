param(
    [string]$Distro = 'Ubuntu',
    [int]$Disk = 0,
    [int]$Partition = 16,
    [UInt64]$ExpectedStartSector = 3775834112,
    [UInt64]$ExpectedSize = 52427751424,
    [UInt64]$TestSizeMiB = 256,
    [int]$RandomRuntimeSeconds = 20,
    [ValidateRange(1, 256)]
    [int]$QueueDepth = 32,
    [ValidateSet('io_uring', 'libaio', 'sync')]
    [string]$IoEngine = 'io_uring',
    [ValidateSet('warm', 'cold')]
    [string]$ReadCacheMode = 'warm',
    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string]$RunTag = '',
    [ValidateSet('seqwrite', 'seqread', 'randread4k', 'randwrite4k', 'fsync4k')]
    [string[]]$Workloads = @('seqwrite', 'seqread', 'randread4k', 'randwrite4k', 'fsync4k'),
    [switch]$DirectIO,
    [ValidateSet('always', 'guest')]
    [string]$ProxySyncPolicy = 'always',
    [ValidateSet('cached', 'none')]
    [string]$ProxyBuffering = 'cached',
    [ValidateRange(1, 1024)]
    [int]$ProxyDispatcherThreads = 0,
    [ValidateRange(1, 256)]
    [int]$RingDepth = 64,
    [ValidateRange(4096, 1048576)]
    [int]$MaxTransferLength = 1048576,
    [ValidateSet('sync', 'overlapped')]
    [string]$ProxyIOMode = 'sync',
    [ValidateSet('legacy', 'shared-ring')]
    [string]$ProxyTransport = 'legacy',
    [switch]$OmitRandomWriteEndFsync,
    [switch]$IoStats,
    [switch]$ProxyFua,
    [switch]$ProxyFuaUnlocked,
    [switch]$SkipVhdxBaseline
)

$ErrorActionPreference = 'Stop'

if ('sync' -eq $IoEngine -and 1 -ne $QueueDepth) {
    throw 'fio ioengine=sync cannot exercise a queue depth greater than 1.'
}
if (0 -ne ($MaxTransferLength % 4096)) {
    throw 'MaxTransferLength must be a multiple of 4096 bytes.'
}

if ($ProxyFua) {
    # The proxy's FUA mode deliberately fixes these source-handle properties.
    $ProxyBuffering = 'none'
    $ProxyIOMode = 'overlapped'
}
if ($ProxyFuaUnlocked) {
    if ($ProxyFua) { throw 'Choose either -ProxyFua or -ProxyFuaUnlocked.' }
    $ProxyFua = $true
    $ProxyBuffering = 'none'
    $ProxyIOMode = 'overlapped'
}

if (-not ('WslPartM6Native' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WslPartM6Native
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
    throw 'Run this benchmark from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$proxyExe = Join-Path $repoRoot 'build\bin\Release\wslpart-ARM64.exe'
$artifactDir = Join-Path $repoRoot 'artifacts\m6'
$defaultVariant = $ProxySyncPolicy -eq 'always' -and
    $ProxyBuffering -eq 'cached'
$dispatcherSuffix = if ($ProxyDispatcherThreads -gt 0) {
    "-threads$ProxyDispatcherThreads"
} else {
    ''
}
$ioModeSuffix = if ($ProxyIOMode -ne 'sync') { "-io$ProxyIOMode" } else { '' }
$fuaSuffix = if ($ProxyFuaUnlocked) { '-fua-unlocked' }
    elseif ($ProxyFua) { '-fua' } else { '' }
$reportName = if ($defaultVariant -and -not $DirectIO) {
    if ($ProxyDispatcherThreads -eq 0 -and $ProxyIOMode -eq 'sync') {
        if ($ProxyFua) { 'benchmark-always-cached-fua.json' }
        else { 'benchmark.json' }
    } else { "benchmark-always-cached$dispatcherSuffix$ioModeSuffix$fuaSuffix.json" }
} elseif ($defaultVariant -and $DirectIO -and $ProxyDispatcherThreads -eq 0) {
    if ($ProxyIOMode -eq 'sync' -and -not $ProxyFua) { 'benchmark-direct.json' }
    else { "benchmark-direct$ioModeSuffix$fuaSuffix.json" }
} else {
    "benchmark-$ProxySyncPolicy-$ProxyBuffering$dispatcherSuffix$ioModeSuffix$fuaSuffix.json"
}
$reportPath = Join-Path $artifactDir $reportName
$reportPath = $reportPath -replace '\.json$', "-$IoEngine-qd$QueueDepth-read$ReadCacheMode.json"
$reportPath = $reportPath -replace '\.json$', "-xfer$MaxTransferLength.json"
if (-not [string]::IsNullOrEmpty($RunTag)) {
    $reportPath = $reportPath -replace '\.json$', "-$RunTag.json"
}
if ($ProxyTransport -eq 'shared-ring') {
    $reportPath = $reportPath -replace '\.json$', '-ring.json'
    $reportPath = $reportPath -replace '\.json$', "-ringdepth$RingDepth.json"
}
if ($SkipVhdxBaseline) {
    $reportPath = $reportPath -replace '\.json$', '-proxy-only.json'
}
$proxyStdout = Join-Path $artifactDir 'proxy.stdout.log'
$proxyStderr = Join-Path $artifactDir 'proxy.stderr.log'
$proxyDebugLog = Join-Path $artifactDir 'proxy.events.log'
$mountPoint = '/mnt/wslpart-m6-proxy'
$proxyFile = "$mountPoint/wslpart-m6-$([Guid]::NewGuid().ToString('N')).fio"
$wslHomeOutput = @(& wsl.exe -d $Distro -- bash -lc 'printf %s "$HOME"' 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not determine WSL user's home directory: $($wslHomeOutput -join "`n")"
}
$wslHome = ($wslHomeOutput -join '').Trim()
if ($wslHome -notmatch '^/home/[^/]+$') {
    throw "Refusing unexpected WSL home path for VHDX benchmark: $wslHome"
}
$vhdxRoot = "$wslHome/wslpart-m6-vhdx-$([Guid]::NewGuid().ToString('N'))"
$vhdxFile = "$vhdxRoot/wslpart-m6.fio"
$eventName = "wslpart-m6-$([Guid]::NewGuid().ToString('N'))"
$process = $null
$physicalDrive = $null
$attached = $false
$mounted = $false
$allResults = @()

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue `
    $reportPath, $proxyStdout, $proxyStderr, $proxyDebugLog

function Invoke-WslRoot {
    param([Parameter(Mandatory)][string]$Command)
    Add-Content -LiteralPath (Join-Path $artifactDir 'wsl-commands.log') -Value $Command
    $output = @(& wsl.exe -d $Distro -u root -- bash -lc $Command 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

function Find-NewProxyDisk {
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
        if ($candidates.Count -eq 1) { return $candidates[0] }
        if ($candidates.Count -gt 1) {
            throw 'More than one new WslPart disk has the expected capacity.'
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Timed out waiting for the WslPart disk.'
}

function Find-LinuxProxyDevice {
    $lines = @(Invoke-WslRoot 'lsblk -dn -o NAME,MODEL')
    $line = $lines | Where-Object { $_ -match '\sWslPart\s*$' } | Select-Object -First 1
    if ($null -eq $line) { throw 'WSL did not report a WslPart disk.' }
    return '/dev/' + (($line -split '\s+')[0])
}

function Signal-ProxyShutdown {
    $handle = [WslPartM6Native]::OpenEvent(0x00100002, $false, $eventName)
    if ($handle -eq [IntPtr]::Zero) {
        throw "OpenEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        if (-not [WslPartM6Native]::SetEvent($handle)) {
            throw "SetEvent failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    }
    finally {
        [void][WslPartM6Native]::CloseHandle($handle)
    }
}

function Get-ProxyCpuSeconds {
    if ($null -eq $process -or $process.HasExited) { return 0.0 }
    $process.Refresh()
    return $process.TotalProcessorTime.TotalSeconds
}

function Get-FioClatUs {
    param($Direction, [double]$Percentile)
    if ($null -eq $Direction -or $null -eq $Direction.clat_ns -or
        $null -eq $Direction.clat_ns.percentile) { return $null }
    $key = '{0:F6}' -f $Percentile
    $entry = $Direction.clat_ns.percentile.PSObject.Properties[$key]
    if ($null -eq $entry) { return $null }
    return [math]::Round(([double]$entry.Value / 1000.0), 2)
}

function Get-FioMeanClatUs {
    param($Direction)
    if ($null -eq $Direction -or $null -eq $Direction.clat_ns -or
        $null -eq $Direction.clat_ns.mean) { return $null }
    return [math]::Round(([double]$Direction.clat_ns.mean / 1000.0), 2)
}

function Invoke-FioJob {
    param(
        [Parameter(Mandatory)][string]$Storage,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][hashtable]$Job,
        [Parameter(Mandatory)][string]$Class
    )

    $jsonPath = "/tmp/wslpart-m6-$([Guid]::NewGuid().ToString('N')).json"
    $workloadSizeMiB = if ($Job.ContainsKey('SizeMiB')) {
        [UInt64]$Job.SizeMiB
    } else {
        $TestSizeMiB
    }
    $size = "${workloadSizeMiB}M"
    $directFlag = if ($DirectIO) { 1 } else { 0 }
    if ('randread4k' -eq $Job.Name -and 'warm' -eq $ReadCacheMode -and
        -not $DirectIO) {
        $warmup = "fio --name=read-cache-warmup --filename='$File' " +
            "--size=$size --ioengine=$IoEngine --rw=read --bs=1M " +
            "--iodepth=1 --direct=0 --invalidate=1 --output=/dev/null"
        $warmOutput = Invoke-WslRoot "if ! timeout --foreground 120s " +
            "$warmup; then echo FIO_WARMUP_FAILED >&2; exit 1; fi"
        if ($warmOutput -match 'FIO_WARMUP_FAILED') {
            throw 'fio read-cache warm-up failed.'
        }
    }
    $common = "--name=$($Job.Name) --filename='$File' --size=$size " +
        "--ioengine=$IoEngine --direct=$directFlag --group_reporting=1 " +
        "--output-format=json --output='$jsonPath'"
    $command = "mkdir -p '$([string]$File.Substring(0, $File.LastIndexOf('/')))' " +
        "; if ! timeout --foreground 120s fio $common $($Job.Options); then " +
        "echo FIO_FAILED >&2; exit 1; fi"
    if ($Storage -eq 'winspd-partition' -and ($null -eq $process -or $process.HasExited)) {
        $stderr = if (Test-Path -LiteralPath $proxyStderr) { Get-Content -Raw $proxyStderr } else { '' }
        throw "Proxy exited before $($Job.Name) started. $stderr"
    }
    $cpuBefore = Get-ProxyCpuSeconds
    $started = Get-Date
    Invoke-WslRoot $command | Out-Null
    if ($Storage -eq 'winspd-partition' -and ($null -eq $process -or $process.HasExited)) {
        $stderr = if (Test-Path -LiteralPath $proxyStderr) { Get-Content -Raw $proxyStderr } else { '' }
        throw "Proxy exited during $($Job.Name). $stderr"
    }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    $json = (Invoke-WslRoot "cat '$jsonPath'; rm -f '$jsonPath'") -join "`n"
    $data = $json | ConvertFrom-Json
    $jobData = $data.jobs[0]
    $cpuAfter = Get-ProxyCpuSeconds
    $read = $jobData.read
    $write = $jobData.write
    $actualQueueDepth = 0.0
    foreach ($depthProperty in $jobData.iodepth_level.PSObject.Properties) {
        if ($depthProperty.Name -match '^\d+$') {
            $actualQueueDepth += [double]$depthProperty.Name *
                ([double]$depthProperty.Value / 100.0)
        }
        elseif ($depthProperty.Name -match '^>=(\d+)$') {
            $actualQueueDepth += [double]$Matches[1] *
                ([double]$depthProperty.Value / 100.0)
        }
    }
    $fioRuntimeMs = [math]::Max([double]$read.runtime, [double]$write.runtime)
    [pscustomobject]@{
        Storage = $Storage
        Workload = $Job.Name
        ReadMiBPerSec = [math]::Round(([double]$read.bw_bytes / 1MB), 2)
        WriteMiBPerSec = [math]::Round(([double]$write.bw_bytes / 1MB), 2)
        ReadIOPS = [math]::Round([double]$read.iops, 2)
        WriteIOPS = [math]::Round([double]$write.iops, 2)
        ReadClatMeanUs = Get-FioMeanClatUs $read
        WriteClatMeanUs = Get-FioMeanClatUs $write
        RuntimeSeconds = [math]::Round($fioRuntimeMs / 1000, 3)
        WallSeconds = [math]::Round($elapsed, 3)
        ProxyCpuSeconds = [math]::Round(($cpuAfter - $cpuBefore), 3)
        ProxyCpuPercent = if ($elapsed -gt 0) {
            [math]::Round((($cpuAfter - $cpuBefore) / $elapsed) * 100, 2)
        } else { 0 }
        FioOptions = $Job.Options
        FioIoEngine = $IoEngine
        RequestedQueueDepth = $QueueDepth
        AverageQueueDepth = [math]::Round($actualQueueDepth, 2)
        FioQueueDepthHistogram = $jobData.iodepth_level
        ReadClatP50Us = Get-FioClatUs $read 50.0
        ReadClatP95Us = Get-FioClatUs $read 95.0
        ReadClatP99Us = Get-FioClatUs $read 99.0
        ReadClatP999Us = Get-FioClatUs $read 99.9
        ReadClatP9999Us = Get-FioClatUs $read 99.99
        ReadClatP99999Us = Get-FioClatUs $read 99.999
        ReadClatPercentiles = $read.clat_ns.percentile
        WriteClatP50Us = Get-FioClatUs $write 50.0
        WriteClatP95Us = Get-FioClatUs $write 95.0
        WriteClatP99Us = Get-FioClatUs $write 99.0
        WriteClatP999Us = Get-FioClatUs $write 99.9
        WriteClatP9999Us = Get-FioClatUs $write 99.99
        WriteClatP99999Us = Get-FioClatUs $write 99.999
        ContextSwitches = [UInt64]$jobData.ctx
        TestSizeMiB = $workloadSizeMiB
        RandomRuntimeSeconds = $RandomRuntimeSeconds
        DirectIO = [bool]$DirectIO
    }
}

$randReadInvalidate = if ('cold' -eq $ReadCacheMode) { ' --invalidate=1' } else { '' }
$randWriteEndFsync = if ($OmitRandomWriteEndFsync) { '' } else { ' --end_fsync=1' }
$jobs = @(
    @{ Name = 'seqwrite'; Options = '--rw=write --bs=1M --iodepth=1 --fsync_on_close=1 --invalidate=1' },
    @{ Name = 'seqread'; Options = '--rw=read --bs=1M --iodepth=1 --invalidate=1' },
    @{ Name = 'randread4k'; Options = "--rw=randread --bs=4k --iodepth=$QueueDepth --runtime=$RandomRuntimeSeconds --time_based=1$randReadInvalidate" },
    @{ Name = 'randwrite4k'; Options = "--rw=randwrite --bs=4k --iodepth=$QueueDepth --runtime=$RandomRuntimeSeconds --time_based=1$randWriteEndFsync" },
    @{ Name = 'fsync4k'; SizeMiB = 16; Options = '--rw=write --bs=4k --iodepth=1 --fsync=1 --invalidate=1' }
)
$jobs = @($jobs | Where-Object { $Workloads -contains $_.Name })
if (0 -eq $jobs.Count) { throw 'No benchmark workloads were selected.' }

try {
    if (-not (Test-Path -LiteralPath $proxyExe)) { throw "Proxy binary not found: $proxyExe" }

    if (-not $SkipVhdxBaseline) {
        # Keep the baseline on the distro's ext4 filesystem (the VHDX), not
        # /tmp, which WSL commonly mounts as tmpfs. Use a unique path and never
        # delete a pre-existing test directory.
        Invoke-WslRoot "mkdir -m 700 '$vhdxRoot'"
        if (($Workloads -contains 'randread4k' -or
            $Workloads -contains 'randwrite4k') -and
            -not ($Workloads -contains 'seqwrite')) {
            $prepareFlag = if ($DirectIO) { 1 } else { 0 }
            $prepare = "fio --name=vhdx-prepare --filename='$vhdxFile' " +
                "--size=${TestSizeMiB}M --ioengine=$IoEngine --direct=$prepareFlag " +
                '--rw=write --bs=1M --iodepth=8 --end_fsync=1 --group_reporting=1'
            Invoke-WslRoot "if ! $prepare >/dev/null; then echo VHDX_PREPARE_FAILED >&2; exit 1; fi"
        }
        foreach ($job in $jobs) {
            $allResults += Invoke-FioJob -Storage 'wsl-vhdx' -File $vhdxFile -Job $job -Class 'baseline'
        }
        Invoke-WslRoot "sync; rm -rf '$vhdxRoot'"
    }

    # Proxy: the selected physical partition through WinSpd.
    $before = @(Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -like '*WslPart*' })
    $arguments = @(
        'attach', '--disk', [string]$Disk, '--partition', [string]$Partition,
        '--expected-start-sector', [string]$ExpectedStartSector, '--readwrite',
        '--sync-policy', $ProxySyncPolicy, '--buffering', $ProxyBuffering,
        '--shutdown-event', $eventName, '--io-mode', $ProxyIOMode,
        '--transport', $ProxyTransport,
        '--max-transfer-length', [string]$MaxTransferLength,
        '--debug-log', $proxyDebugLog, '--debug-log-events'
    )
    if ($ProxyTransport -eq 'shared-ring') {
        $arguments += '--ring-depth'
        $arguments += [string]$RingDepth
    }
    if ($ProxyFuaUnlocked) { $arguments += '--fua-unlocked' }
    elseif ($ProxyFua) { $arguments += '--fua' }
    if ($IoStats) { $arguments += '--io-stats' }
    if ($ProxyDispatcherThreads -gt 0) {
        $arguments += '--dispatcher-threads'
        $arguments += [string]$ProxyDispatcherThreads
    }
    $process = Start-Process -FilePath $proxyExe -ArgumentList $arguments `
        -RedirectStandardOutput $proxyStdout -RedirectStandardError $proxyStderr `
        -WindowStyle Hidden -PassThru
    $diskObject = Find-NewProxyDisk -Before $before
    $physicalDrive = "\\.\PHYSICALDRIVE$($diskObject.Number)"
    & wsl.exe --mount $physicalDrive --bare
    if ($LASTEXITCODE -ne 0) { throw 'wsl --mount failed for proxy.' }
    $attached = $true
    $linuxDevice = Find-LinuxProxyDevice
    Invoke-WslRoot "mkdir -p '$mountPoint'; mount '$linuxDevice' '$mountPoint'"
    $mounted = $true
    $proxyFileAbsent = (Invoke-WslRoot "if test -e '$proxyFile'; then echo EXISTS; else echo ABSENT; fi") -join ''
    if ($proxyFileAbsent.Trim() -ne 'ABSENT') {
        throw "Unique proxy benchmark file unexpectedly exists: $proxyFile"
    }
    if (($Workloads -contains 'randread4k' -or
        $Workloads -contains 'randwrite4k') -and
        -not ($Workloads -contains 'seqwrite')) {
        $prepareFlag = if ($DirectIO) { 1 } else { 0 }
        $prepare = "fio --name=proxy-prepare --filename='$proxyFile' " +
            "--size=${TestSizeMiB}M --ioengine=$IoEngine --direct=$prepareFlag " +
            '--rw=write --bs=1M --iodepth=8 --end_fsync=1 --group_reporting=1'
        Invoke-WslRoot "if ! $prepare >/dev/null; then echo PROXY_PREPARE_FAILED >&2; exit 1; fi"
    }
    foreach ($job in $jobs) {
        $allResults += Invoke-FioJob -Storage 'winspd-partition' -File $proxyFile -Job $job -Class 'proxy'
    }
    Invoke-WslRoot "sync; rm -f -- '$proxyFile'; sync; umount '$mountPoint'"
    $mounted = $false
    & wsl.exe --unmount $physicalDrive
    if ($LASTEXITCODE -ne 0) { throw 'wsl --unmount failed for proxy.' }
    $attached = $false
    Signal-ProxyShutdown
    if (-not $process.WaitForExit(30000)) { throw 'Proxy did not shut down gracefully.' }
    $process.Refresh()
    if ([int]$process.ExitCode -ne 0) { throw "Proxy exit code: $($process.ExitCode)" }

    $ringStats = $null
    if ($ProxyTransport -eq 'shared-ring' -and
        (Test-Path -LiteralPath $proxyDebugLog)) {
        $batchLine = Select-String -Path $proxyDebugLog `
            -Pattern 'SharedRing batches submissions=' |
            Select-Object -Last 1
        if ($null -ne $batchLine -and $batchLine.Line -match
            'submissions=(\d+) requests=(\d+) max=(\d+) completions=(\d+) responses=(\d+) max=(\d+) workers=(\d+) depth=(\d+) buffer_size=(\d+)') {
            $ringStats = [pscustomobject]@{
                SubmissionBatches = [UInt64]$Matches[1]
                SubmittedRequests = [UInt64]$Matches[2]
                MaxSubmissionBatch = [UInt32]$Matches[3]
                CompletionBatches = [UInt64]$Matches[4]
                CompletedResponses = [UInt64]$Matches[5]
                MaxCompletionBatch = [UInt32]$Matches[6]
                Workers = [UInt32]$Matches[7]
                QueueDepth = [UInt32]$Matches[8]
                BufferSize = [UInt32]$Matches[9]
            }
        }
    }

    $report = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        WindowsVersion = [Environment]::OSVersion.VersionString
        WslDistro = $Distro
        FioVersion = ((Invoke-WslRoot 'fio --version') -join ' ').Trim()
        WslKernel = ((Invoke-WslRoot 'uname -a') -join ' ').Trim()
        Partition = "disk $Disk partition $Partition"
        PartitionSizeBytes = $ExpectedSize
        TestSizeMiB = $TestSizeMiB
        RandomRuntimeSeconds = $RandomRuntimeSeconds
        FioIoEngine = $IoEngine
        RequestedQueueDepth = $QueueDepth
        ReadCacheMode = if ($DirectIO) { 'bypassed-by-direct-io' } else { $ReadCacheMode }
        VhdxBaselineIncluded = -not [bool]$SkipVhdxBaseline
        DirectIO = [bool]$DirectIO
        ProxySyncPolicy = $ProxySyncPolicy
        ProxyBuffering = $ProxyBuffering
        ProxyDispatcherThreads = $ProxyDispatcherThreads
        ProxyIOMode = $ProxyIOMode
        ProxyTransport = $ProxyTransport
        RandomWriteEndFsync = -not [bool]$OmitRandomWriteEndFsync
        IoStats = [bool]$IoStats
        RingDepth = if ($ProxyTransport -eq 'shared-ring') { $RingDepth } else { $null }
        MaxTransferLength = $MaxTransferLength
        RingBufferPoolBytes = if ($ProxyTransport -eq 'shared-ring') {
            [UInt64]$RingDepth * [UInt64]$MaxTransferLength
        } else { $null }
        RingStats = $ringStats
        ProxyFua = [bool]$ProxyFua
        ProxyFuaUnlocked = [bool]$ProxyFuaUnlocked
        Workloads = @($Workloads)
        Results = @($allResults)
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $reportPath
    $allResults | Format-Table -AutoSize | Out-Host
    Write-Host "M6 benchmark complete: $reportPath"
}
finally {
    if ($mounted) { try { Invoke-WslRoot "sync; rm -f -- '$proxyFile'; sync; umount '$mountPoint'" | Out-Null } catch {} }
    if ($attached -and $null -ne $physicalDrive) {
        try { & wsl.exe --unmount $physicalDrive | Out-Null } catch {}
    }
    if ($null -ne $process -and -not $process.HasExited) {
        try { Signal-ProxyShutdown } catch {}
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force }
    }
    try { Invoke-WslRoot "rm -rf '$vhdxRoot'" | Out-Null } catch {}
}

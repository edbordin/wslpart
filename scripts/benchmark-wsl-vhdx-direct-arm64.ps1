param(
    [string]$Distro = 'Ubuntu',
    [ValidateRange(16, 4096)]
    [int]$TestSizeMiB = 256,
    [ValidateRange(1, 3600)]
    [int]$RuntimeSeconds = 20,
    [int[]]$QueueDepths = @(1, 8, 16, 32, 64, 128),
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$RunTag = 'direct-vhdx'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifactDir = Join-Path $repoRoot 'artifacts\m6'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

function Invoke-Wsl {
    param([Parameter(Mandatory)][string]$Command, [switch]$AsRoot)
    $arguments = @('-d', $Distro)
    if ($AsRoot) { $arguments += @('-u', 'root') }
    $arguments += @('--', 'bash', '-lc', $Command)
    $output = @(& wsl.exe @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed ($LASTEXITCODE): $Command`n$($output -join "`n")"
    }
    return $output
}

$wslHome = ((Invoke-Wsl 'printf %s "$HOME"') -join '').Trim()
if ($wslHome -notmatch '^/home/[^/]+$') {
    throw "Refusing unexpected WSL home path: $wslHome"
}
$testRoot = "$wslHome/wslpart-m6-vhdx-$RunTag"
$exists = (Invoke-Wsl "if test -e '$testRoot'; then echo EXISTS; else echo ABSENT; fi" -AsRoot) -join ''
if ($exists.Trim() -ne 'ABSENT') {
    throw "Benchmark path already exists; refusing to overwrite it: $testRoot"
}
$testFile = "$testRoot/vhdx-random-read.fio"
$reportPath = Join-Path $artifactDir "vhdx-direct-io_uring-$RunTag.json"
$resultRows = @()
$created = $false

try {
    [void](Invoke-Wsl "mkdir -m 700 '$testRoot'" -AsRoot)
    $created = $true
    $mountInfo = ((Invoke-Wsl "findmnt -T '$testRoot' -n -o TARGET,SOURCE,FSTYPE; df -h '$testRoot' | tail -1" -AsRoot) -join "`n").Trim()
    if ($mountInfo -notmatch '(?m)^/\s+/dev/\S+\s+ext4\s*$') {
        throw "Test path is not on the expected ext4 WSL VHDX root: $mountInfo"
    }
    $fioVersion = ((Invoke-Wsl 'fio --version') -join '').Trim()
    $kernel = ((Invoke-Wsl 'uname -a') -join '').Trim()

    Write-Host "Preparing $TestSizeMiB MiB of allocated test data on WSL ext4 ($testRoot)."
    $prepare = "fio --name=prepare --filename='$testFile' --size=${TestSizeMiB}M " +
        '--ioengine=io_uring --direct=1 --rw=write --bs=1M --iodepth=8 ' +
        '--end_fsync=1 --group_reporting=1 --output-format=json'
    [void](Invoke-Wsl $prepare -AsRoot)

    foreach ($qd in $QueueDepths) {
        if ($qd -lt 1 -or $qd -gt 256) { throw "Invalid queue depth: $qd" }
        Write-Host "VHDX direct random read: QD=$qd, runtime=${RuntimeSeconds}s"
        $fio = "fio --name=randread4k --filename='$testFile' " +
            "--size=${TestSizeMiB}M --ioengine=io_uring --direct=1 " +
            "--rw=randread --bs=4k --iodepth=$qd --runtime=$RuntimeSeconds " +
            '--time_based=1 --invalidate=1 --group_reporting=1 --output-format=json'
        $raw = (Invoke-Wsl $fio -AsRoot) -join "`n"
        $job = ($raw | ConvertFrom-Json).jobs[0]
        $lowerBoundQd = 0.0
        foreach ($depth in $job.iodepth_level.PSObject.Properties) {
            if ($depth.Name -match '^\d+$') {
                $lowerBoundQd += [double]$depth.Name * ([double]$depth.Value / 100.0)
            } elseif ($depth.Name -match '^>=(\d+)$') {
                $lowerBoundQd += [double]$Matches[1] * ([double]$depth.Value / 100.0)
            }
        }
        $percentiles = $job.read.clat_ns.percentile
        $resultRows += [pscustomobject]@{
            QueueDepth = $qd
            ReadIOPS = [math]::Round([double]$job.read.iops, 2)
            ReadMiBPerSec = [math]::Round(([double]$job.read.bw_bytes / 1MB), 2)
            MeanClatUs = [math]::Round(([double]$job.read.clat_ns.mean / 1000.0), 2)
            P50Us = [math]::Round(([double]$percentiles.'50.000000' / 1000.0), 2)
            P95Us = [math]::Round(([double]$percentiles.'95.000000' / 1000.0), 2)
            P99Us = [math]::Round(([double]$percentiles.'99.000000' / 1000.0), 2)
            P999Us = [math]::Round(([double]$percentiles.'99.900000' / 1000.0), 2)
            P9999Us = [math]::Round(([double]$percentiles.'99.990000' / 1000.0), 2)
            RuntimeSeconds = [math]::Round(([double]$job.read.runtime / 1000.0), 3)
            AverageQueueDepthLowerBound = [math]::Round($lowerBoundQd, 2)
            QueueDepthHistogram = $job.iodepth_level
            ContextSwitches = [UInt64]$job.ctx
            DirectIO = $true
            IoEngine = 'io_uring'
        }
    }

    [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        WindowsVersion = [Environment]::OSVersion.VersionString
        WslDistro = $Distro
        WslKernel = $kernel
        FioVersion = $fioVersion
        TestFilesystem = $mountInfo
        TestPath = $testRoot
        TestSizeMiB = $TestSizeMiB
        RuntimeSecondsPerQueueDepth = $RuntimeSeconds
        ReadCacheMode = 'Linux page cache bypassed with O_DIRECT; Windows host/VHDX caching is not explicitly disabled'
        Results = @($resultRows)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
finally {
    if ($created) {
        [void](Invoke-Wsl "rm -rf -- '$testRoot'" -AsRoot)
    }
}

$resultRows | Format-Table QueueDepth, ReadIOPS, ReadMiBPerSec, MeanClatUs, P50Us, P95Us, P99Us, P999Us, P9999Us, AverageQueueDepthLowerBound -AutoSize
Write-Host "Saved VHDX results: $reportPath"

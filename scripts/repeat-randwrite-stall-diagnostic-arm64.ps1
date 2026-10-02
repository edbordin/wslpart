[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$Repeats = 3
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this diagnostic from an elevated PowerShell.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$artifactDir = Join-Path $repoRoot 'artifacts\m6'
$benchmark = Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$eventReports = @()

for ($repeat = 1; $repeat -le $Repeats; $repeat++) {
    $started = Get-Date
    $tag = "retry-diagnostic-$runId-r$repeat"
    Write-Host "Starting instrumented random-write repeat $repeat/$Repeats ($tag)"

    & $benchmark `
        -Distro Ubuntu `
        -Disk 0 `
        -Partition 16 `
        -ExpectedStartSector 3775834112 `
        -ExpectedSize 52427751424 `
        -TestSizeMiB 256 `
        -RandomRuntimeSeconds 20 `
        -QueueDepth 32 `
        -IoEngine io_uring `
        -DirectIO `
        -ProxySyncPolicy guest `
        -ProxyBuffering none `
        -ProxyDispatcherThreads 8 `
        -RingDepth 64 `
        -MaxTransferLength 1048576 `
        -ProxyIOMode overlapped `
        -ProxyTransport shared-ring `
        -Workloads randwrite4k `
        -RunTag $tag `
        -SkipVhdxBaseline `
        -IoStats
    if (-not $?) {
        throw "Benchmark repeat $repeat failed."
    }

    $report = Get-ChildItem -LiteralPath $artifactDir -Filter "*$tag*.json" |
        Where-Object { $_.Name -notmatch '-events\.json$' } |
        Select-Object -First 1
    foreach ($logName in @('proxy.stdout.log', 'proxy.stderr.log',
        'proxy.events.log')) {
        $sourceLog = Join-Path $artifactDir $logName
        if (Test-Path -LiteralPath $sourceLog) {
            $taggedLog = Join-Path $artifactDir (
                "$tag-" + $logName)
            Copy-Item -LiteralPath $sourceLog -Destination $taggedLog
        }
    }
    $proxyDisk = $null
    if (Test-Path -LiteralPath (Join-Path $artifactDir 'proxy.stdout.log')) {
        $proxyOutput = Get-Content (Join-Path $artifactDir 'proxy.stdout.log') -Raw
        if ($proxyOutput -match 'Proxy disk: .*PHYSICALDRIVE(\d+)') {
            $proxyDisk = [int]$Matches[1]
        }
    }

    $events = @()
    if ($null -ne $proxyDisk) {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ProviderName = 'disk'
            Id = 153
            StartTime = $started
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -match "Disk $proxyDisk \(PDO name:"
        } | Select-Object TimeCreated, Id, Message)
    }
    $eventPath = Join-Path $artifactDir "$tag-events.json"
    [pscustomobject]@{
        Repeat = $repeat
        Started = $started.ToString('o')
        Finished = (Get-Date).ToString('o')
        BenchmarkReport = if ($null -ne $report) { $report.Name } else { $null }
        ProxyDiskNumber = $proxyDisk
        Disk153Events = $events
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $eventPath
    $eventReports += $eventPath
    Write-Host "Repeat $repeat Disk 153 events for proxy disk $proxyDisk`: $($events.Count)"
}

Write-Host 'Retry diagnostic event reports:'
$eventReports | ForEach-Object { Write-Host "  $_" }

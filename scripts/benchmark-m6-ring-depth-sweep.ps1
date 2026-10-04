[CmdletBinding()]
param(
    [int]$QueueDepth = 32,
    [ValidatePattern('^\d+([,;]\d+)*$')]
    [string]$RingDepths = '32,64,128',
    [ValidatePattern('^\d+([,;]\d+)*$')]
    [string]$MaxTransferLengths = '1048576',
    [ValidatePattern('^(seqread|randread4k)([,;](seqread|randread4k))*$')]
    [string]$Workloads = 'randread4k',
    [int]$RuntimeSeconds = 10,
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$RunTag = 'ring-depth-sweep'
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this sweep from an elevated PowerShell.'
}

$benchmark = Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1'
$ringValues = @($RingDepths -split '[,;]' |
    ForEach-Object { [int]::Parse($_) })
if (@($ringValues | Where-Object {
    $_ -lt 2 -or $_ -gt 4096 -or 0 -ne ($_ -band ($_ - 1))
}).Count -gt 0) {
    throw 'Ring depths must be powers of two from 2 through 4096.'
}
$transferValues = @($MaxTransferLengths -split '[,;]' |
    ForEach-Object { [int]::Parse($_) })
if (@($transferValues | Where-Object {
    $_ -lt 4096 -or $_ -gt 1048576 -or 0 -ne ($_ % 4096)
}).Count -gt 0) {
    throw 'Max transfer lengths must be 4K-aligned values from 4K through 1M.'
}
$workloadValues = @($Workloads -split '[,;]')
$logPath = Join-Path (Split-Path $PSScriptRoot -Parent) `
    "artifacts\m6\ring-depth-sweep-$RunTag.log"
Start-Transcript -Path $logPath -Force | Out-Null
try {
    foreach ($ringDepth in $ringValues) {
        foreach ($transferLength in $transferValues) {
            Write-Host "Starting SharedRing direct $($workloadValues -join ','): QD=$QueueDepth ring=$ringDepth transfer=$transferLength"
            & $benchmark `
                -SkipVhdxBaseline `
                -Workloads $workloadValues `
                -ProxyTransport shared-ring `
                -ProxySyncPolicy guest `
                -ProxyBuffering none `
                -ProxyIOMode overlapped `
                -ProxyDispatcherThreads 8 `
                -QueueDepth $QueueDepth `
                -IoEngine io_uring `
                -ReadCacheMode cold `
                -DirectIO `
                -RingDepth $ringDepth `
                -MaxTransferLength $transferLength `
                -RunTag "$RunTag-rd$ringDepth-xfer$transferLength" `
                -RandomRuntimeSeconds $RuntimeSeconds
        }
    }
}
finally {
    Stop-Transcript | Out-Null
}

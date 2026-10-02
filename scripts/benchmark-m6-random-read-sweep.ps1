[CmdletBinding()]
param(
    [ValidateSet('legacy', 'shared-ring')]
    [string[]]$Transports = @('legacy', 'shared-ring'),
    [int[]]$QueueDepths = @(1, 4, 8, 16, 32, 64),
    [int]$RingDepth = 64,
    [int]$RuntimeSeconds = 10
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this sweep from an elevated PowerShell.'
}

$benchmark = Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1'
foreach ($transport in $Transports) {
    foreach ($queueDepth in $QueueDepths) {
        Write-Host "Starting direct-I/O randread4k: transport=$transport QD=$queueDepth"
        & $benchmark `
            -SkipVhdxBaseline `
            -Workloads randread4k `
            -ProxyTransport $transport `
            -ProxySyncPolicy guest `
            -ProxyBuffering none `
            -ProxyIOMode overlapped `
            -ProxyDispatcherThreads 8 `
            -QueueDepth $queueDepth `
            -IoEngine io_uring `
            -ReadCacheMode cold `
            -DirectIO `
            -RingDepth $RingDepth `
            -RunTag qdsweep `
            -RandomRuntimeSeconds $RuntimeSeconds
    }
}

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$benchmark = Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1'
$logPath = Join-Path $workspace 'artifacts\m6\matched-qds-elevated-20261002.log'

try {
    '===== START matched-fastest-qd32 =====' |
        Out-File -LiteralPath $logPath -Append -Encoding utf8
    & $benchmark -QueueDepth 32 -ReadCacheMode cold `
        -BufferCount 128 `
        -RunTag matched-fastest-qd32 -DirectIO `
        -ProxySyncPolicy guest -ProxyBuffering none `
        -ProxyDispatcherThreads 8 -ProxyIOMode overlapped `
        -ProxyTransport shared-ring -RingDepth 64 `
        -MaxTransferLength 262144 *>&1 |
        Tee-Object -FilePath $logPath -Append
    if (-not $?) { throw 'QD32 benchmark failed.' }
    '===== DONE matched-fastest-qd32 =====' |
        Out-File -LiteralPath $logPath -Append -Encoding utf8

    '===== START matched-fastest-qd128 =====' |
        Out-File -LiteralPath $logPath -Append -Encoding utf8
    & $benchmark -QueueDepth 128 -ReadCacheMode cold `
        -BufferCount 128 `
        -RunTag matched-fastest-qd128 -DirectIO `
        -ProxySyncPolicy guest -ProxyBuffering none `
        -ProxyDispatcherThreads 8 -ProxyIOMode overlapped `
        -ProxyTransport shared-ring -RingDepth 256 `
        -MaxTransferLength 262144 *>&1 |
        Tee-Object -FilePath $logPath -Append
    if (-not $?) { throw 'QD128 benchmark failed.' }
    '===== DONE matched-fastest-qd128 =====' |
        Out-File -LiteralPath $logPath -Append -Encoding utf8
    exit 0
}
catch {
    $_ | Out-File -LiteralPath $logPath -Append -Encoding utf8
    exit 1
}

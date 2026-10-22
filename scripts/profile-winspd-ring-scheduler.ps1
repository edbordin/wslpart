#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunTag,
    [ValidateSet(1,4,32,128)][int]$QueueDepth = 128,
    [ValidateSet('randread4k','randwrite4k')][string]$Workload = 'randread4k',
    [ValidateRange(5,30)][int]$RuntimeSeconds = 10,
    [ValidateSet('scheduler','sampled')][string]$TraceMode = 'scheduler',
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedDriverHash,
    [switch]$WithoutTrace
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
Set-Location $workspace
$directory = Join-Path $workspace "artifacts/ring-scheduler/$RunTag"
if (Test-Path -LiteralPath $directory) { throw "Run already exists: $directory" }
$null = New-Item -ItemType Directory -Path $directory
$installedHash = (Get-FileHash "$env:SystemRoot/System32/drivers/winspd-arm64.sys").Hash
if ($installedHash -ne $ExpectedDriverHash) { throw 'Unexpected installed driver.' }
$activation = Get-Content artifacts/winspd-patch1-activation-result.json -Raw | ConvertFrom-Json
if ($activation.Status -ne 'TestsPassed' -or $activation.InstalledHash -ne $installedHash) { throw 'Missing successful driver test receipt.' }
Add-Type @'
using System.Runtime.InteropServices;
public static class WinSpdSchedulerPower {
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
}
'@
$previousPower = [WinSpdSchedulerPower]::SetThreadExecutionState([uint32]2147483649)
if ($previousPower -eq 0) { throw 'Cannot hold the system awake.' }
$state = @{ Active = $false; Started = $null; Finished = $null }
$result = [ordered]@{ Status='Running'; DriverHash=$installedHash; QueueDepth=$QueueDepth; Workload=$Workload; Traced=(-not $WithoutTrace); TraceMode=$TraceMode; Started=(Get-Date).ToString('o') }
try {
    # Never cancel a pre-existing recording owned by another tool/user.
    if (-not $WithoutTrace) {
        $recorderStatus = & wpr.exe -status 2>&1
        $statusExit = $LASTEXITCODE
        $recorderStatus | Out-File (Join-Path $directory 'wpr-before.log')
        # This host's WPR reports idle in English and returns success for both
        # idle and active states. Reject any unrecognized/localized status.
        if ($statusExit -ne 0 -or ($recorderStatus -join "`n") -notmatch '(?im)^WPR is not recording\s*$') {
            throw 'An idle WPR recorder could not be confirmed; existing recordings are left untouched.'
        }
    }
    $before = {
        param($Storage,$Name)
        if ($WithoutTrace) { return }
        $profile = if ($TraceMode -eq 'sampled') { 'WinSpdCpu' } else { 'WinSpdScheduler' }
        Copy-Item (Join-Path $PSScriptRoot 'winspd-scheduler.wprp') (Join-Path $directory 'recorded-profile.wprp')
        & wpr.exe -start ((Join-Path $directory 'recorded-profile.wprp')+'!'+$profile) -filemode 2>&1 | Out-File (Join-Path $directory 'wpr-start.log')
        if ($LASTEXITCODE -ne 0) { throw 'Could not start scheduler trace.' }
        $state.Active = $true
        $state.Started = (Get-Date).ToString('o')
    }.GetNewClosure()
    $after = {
        param($Storage,$Name)
        if (-not $state.Active) { return }
        $state.Finished = (Get-Date).ToString('o')
        & wpr.exe -stop (Join-Path $directory 'scheduler.etl') 2>&1 | Out-File (Join-Path $directory 'wpr-stop.log')
        if ($LASTEXITCODE -ne 0) { throw 'Could not finalize scheduler trace.' }
        $state.Active = $false
    }.GetNewClosure()
    & (Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1') -SkipVhdxBaseline -Workloads @($Workload) -QueueDepth $QueueDepth -RandomRuntimeSeconds $RuntimeSeconds -DirectIO -ProxySyncPolicy guest -ProxyBuffering none -ProxyIOMode overlapped -ProxyTransport shared-ring -ProxyDispatcherThreads 8 -RingDepth 256 -BufferCount 128 -MaxTransferLength 262144 -IoStats -RunTag $RunTag -BeforeTimedWorkload $before -AfterTimedWorkload $after
    $reports = @(Get-ChildItem artifacts/m6 -Filter "*-$RunTag-*.json")
    if ($reports.Count -ne 1) { throw 'Expected one benchmark receipt.' }
    Copy-Item -LiteralPath $reports[0].FullName -Destination (Join-Path $directory 'benchmark.json')
    $benchmark = Get-Content (Join-Path $directory 'benchmark.json') -Raw | ConvertFrom-Json
    if ($null -eq $benchmark.RingStats -or $benchmark.RingStats.Error -ne 0 -or
        $benchmark.RingStats.QueuedResponses -ne $benchmark.RingStats.PublishedResponses) {
        throw 'Missing or unsuccessful ring shutdown counters.'
    }
    foreach ($timing in $benchmark.Results) {
        if ($timing.WallSeconds -gt (2*$timing.RuntimeSeconds+10)) { throw 'Host pause detected; exclude this profile.' }
    }
    $result.Status = 'Passed'
}
catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
    throw
}
finally {
    if ($state.Active) {
        & wpr.exe -stop (Join-Path $directory 'incomplete.etl') 2>&1 | Out-File (Join-Path $directory 'wpr-failure-stop.log')
    }
    $null = [WinSpdSchedulerPower]::SetThreadExecutionState($previousPower)
    $result.TraceStart = $state.Started
    $result.TraceStop = $state.Finished
    $result.Finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $directory 'result.json')
}

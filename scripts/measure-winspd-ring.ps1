#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$DbgViewCli,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunTag,
    [ValidateSet(1, 4, 32, 64, 128)][int]$QueueDepth = 1,
    [ValidateSet(1, 8, 32)][int]$PreparationBatchSize = 32,
    [ValidateRange(5, 60)][int]$RuntimeSeconds = 10,
    [ValidateRange(64,16384)][int]$TestSizeMiB = 256,
    [ValidateRange(0,60)][int]$SequentialRuntimeSeconds = 0,
    [ValidateRange(1,256)][int]$FsyncQueueDepth = 1,
    [switch]$IncludeVhdxBaseline,
    [switch]$VerifySequentialData,
    [ValidateSet('vhdx-first','proxy-first')][string]$StorageOrder = 'vhdx-first',
    [switch]$CorrectedBaseline,
    [ValidateSet('initial','coalesced')][string]$Implementation = 'initial',
    [ValidateSet('exploratory','quiet')][string]$MeasurementPhase = 'exploratory',
    [ValidateSet('candidate','final-rundown','latency-profile','dpc-profile','thread-profile','full-baseline','baseline-smoke')][string]$SourceRevision = 'candidate',
    [ValidateSet('seqwrite','seqread','randread4k','randwrite4k','fsync4k')][string[]]$Workloads = @('randread4k','randwrite4k','fsync4k'),
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedDriverHash,
    [ValidateRange(-1,65535)][int]$ExpectedCompletionDpcFlags = -1,
    [ValidateRange(-1,1)][int]$ExpectedPreparationThread = -1,
    [ValidateRange(-1,1)][int]$ExpectedCompletionThread = -1,
    [ValidateRange(-1,4)][int]$ExpectedPreparationThreads = -1,
    [ValidateRange(-1,4)][int]$ExpectedCompletionThreads = -1,
    [ValidateRange(-1,32)][int]$ExpectedCompletionClaimLimit = -1,
    [ValidateRange(-1,1)][int]$ExpectedIoqQueuedSpinLock = -1,
    [ValidateSet(-1,8,12)][int]$ExpectedThreadPriority = -1,
    [ValidateRange(-1,2147483647)][int]$ExpectedMapThresholdBytes = -1,
    [switch]$RequireMappedPayload,
    [switch]$WaitForQuietBlender,
    [switch]$WaitForQuietWslBuild
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
# A task-scoped pause is checked between isolated runs, before opening a disk or
# starting any timed work. Removing the file resumes the comparison.
$pauseFile = Join-Path $workspace 'artifacts/ring-measurements.pause'
$cancelFile = Join-Path $workspace 'artifacts/ring-measurements.cancel'
while (Test-Path -LiteralPath $pauseFile) {
    if (Test-Path -LiteralPath $cancelFile) { throw 'Measurement cancelled between workloads.' }
    Start-Sleep -Seconds 1
}
if (Test-Path -LiteralPath $cancelFile) { throw 'Measurement cancelled between workloads.' }
$taskQuietGate = {
    $quietDeadline = (Get-Date).AddMinutes(10)
    $reportedBusy = $false
    do {
        if (Test-Path -LiteralPath $cancelFile) { throw 'Measurement cancelled while waiting for quiet.' }
        $before = @{}
        Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | ForEach-Object {
            $before[$_.ProcessId] = [double]$_.KernelModeTime + [double]$_.UserModeTime
        }
        if (-not $before.Count) { break }
        $probe = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Seconds 2
        $active = @(Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | Where-Object {
            -not $before.ContainsKey($_.ProcessId) -or
            (([double]$_.KernelModeTime + [double]$_.UserModeTime - $before[$_.ProcessId]) / 10000000 / $probe.Elapsed.TotalSeconds) -gt 0.1
        })
        if (-not $active.Count) { break }
        if (-not $reportedBusy) {
            Write-Output 'Waiting for Blender background CPU activity to settle before timed I/O.'
            $reportedBusy = $true
        }
        if ((Get-Date) -ge $quietDeadline) { throw 'Blender remained active; no timed workload was started.' }
        Start-Sleep -Seconds 5
    } while ($true)
}.GetNewClosure()
if ($WaitForQuietBlender) { & $taskQuietGate }
$taskWslBuildProbe = {
    $processes = @(& wsl.exe -d Ubuntu -- ps -C 'make,ninja,cc1,cc1plus,clang,clang++,ld.lld,ld.bfd,lld,rustc,gcc,g++,aarch64-linux-g' -o pid=,ppid=,comm=,etimes=)
    if ($LASTEXITCODE -notin @(0,1)) { throw 'Could not inspect WSL build activity.' }
    @($processes | Where-Object { $_.Trim() })
}.GetNewClosure()
$taskWslQuietGate = {
    $deadline = (Get-Date).AddMinutes(10)
    $reported = $false
    while (@(& $taskWslBuildProbe).Count) {
        if (Test-Path -LiteralPath $cancelFile) { throw 'Measurement cancelled while waiting for WSL build.' }
        if (-not $reported) { Write-Host 'Waiting for WSL build processes to exit before timed I/O.'; $reported=$true }
        if ((Get-Date) -ge $deadline) { throw 'WSL build remained active; no timed workload started.' }
        Start-Sleep -Seconds 5
    }
}.GetNewClosure()
if ($WaitForQuietWslBuild) { & $taskWslQuietGate }

$directory = Join-Path $workspace "artifacts\ring-measurements\$RunTag"
if (Test-Path -LiteralPath $directory) { throw "Run already exists: $directory" }
if (Get-Process dbgviewcli64a -ErrorAction SilentlyContinue) { throw 'A debug capture is already running.' }
$null = New-Item -ItemType Directory -Path $directory
$cli = (Resolve-Path -LiteralPath $DbgViewCli).Path
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinSpdMeasurementFilter {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
    [DllImport("ntdll.dll")]
    public static extern int RtlAdjustPrivilege(uint privilege,
        [MarshalAs(UnmanagedType.U1)] bool enable,
        [MarshalAs(UnmanagedType.U1)] bool currentThread,
        [MarshalAs(UnmanagedType.U1)] out bool previous);
    [DllImport("ntdll.dll")]
    public static extern int NtSetDebugFilterState(uint component, uint level,
        [MarshalAs(UnmanagedType.U1)] bool enabled);
    [DllImport("ntdll.dll")]
    public static extern int NtQueryDebugFilterState(uint component, uint level);
}
'@
$previousPrivilege = $false
$privilegeStatus = [WinSpdMeasurementFilter]::RtlAdjustPrivilege(20, $true, $false, [ref]$previousPrivilege)
$previousFilter = [WinSpdMeasurementFilter]::NtQueryDebugFilterState(101, 3)
$filterStatus = [WinSpdMeasurementFilter]::NtSetDebugFilterState(101, 3, $true)
if ($privilegeStatus -ne 0 -or $filterStatus -ne 0) { throw 'Cannot enable kernel diagnostic capture.' }
$capture = $null
$previousExecutionState = [uint32]0
$captureState = @{ Process = $null }
$result = [ordered]@{ Status = 'Running'; Error = $null; QueueDepth = $QueueDepth; PreparationBatchSize = $PreparationBatchSize }
$result.CorrectedBaseline = [bool]$CorrectedBaseline
if ($CorrectedBaseline) { $result.PreparationBatchSize = $null }
$result.Implementation = $Implementation
$result.MeasurementPhase = $MeasurementPhase
$result.CaptureMode = 'close-only'
$result.SourceRevision = $SourceRevision
$result.Workloads = $Workloads
$result.TestSizeMiB = $TestSizeMiB
$result.StorageOrder = $StorageOrder
$result.RuntimeSeconds = $RuntimeSeconds
$result.FsyncQueueDepth = $FsyncQueueDepth
try {
    # Idle reusable MSBuild nodes can outlive a completed build.
    if ($MeasurementPhase -eq 'quiet' -and (Get-Process cl,link,winspd-tests-x64 -ErrorAction SilentlyContinue)) {
        throw 'A build or test process is running during the quiet measurement phase.'
    }
    $installedHash = (Get-FileHash -LiteralPath "$env:SystemRoot\System32\drivers\winspd-arm64.sys").Hash
    if ($ExpectedDriverHash -and $installedHash -ne $ExpectedDriverHash) { throw 'Unexpected installed driver.' }
    $receipt = Get-Content (Join-Path $workspace 'artifacts\winspd-patch1-activation-result.json') -Raw | ConvertFrom-Json
    if ($receipt.Status -ne 'TestsPassed' -or $receipt.TestCount -lt 1 -or
        $receipt.InstalledHash -ne $installedHash -or $receipt.BuiltHash -ne $installedHash) {
        throw 'A successful activation/test receipt is required for the installed driver.'
    }
    $result.DriverHash = $installedHash
    $result.ActivationTestCount = $receipt.TestCount
    # Counters accumulate in the driver. Capture their CLOSE dump after fio's
    # timing/CPU windows, so the logger does not compete with the measured work.
    $beforeClose = {
        $captureState.Process = Start-Process -FilePath $cli -WindowStyle Hidden -PassThru -ArgumentList @(
            '--kernel', '--no-win32', '--no-banner', '--duration', '60',
            '--wait-for', '"*WinSpd: histogram name=lock_hold*"',
            '--format', 'text', '--log', ('"' + (Join-Path $directory 'kernel.log') + '"')
        ) -RedirectStandardOutput (Join-Path $directory 'capture.stdout.log') -RedirectStandardError (Join-Path $directory 'capture.stderr.log')
        $null = $captureState.Process.Handle
        Start-Sleep -Seconds 2
    }.GetNewClosure()
    # Hold only this process/thread awake during measurement, without changing
    # the power plan or requesting that the display stay on. Explicit user
    # sleep remains possible and is still rejected by the wall-time guard.
    $previousExecutionState = [WinSpdMeasurementFilter]::SetThreadExecutionState([uint32]2147483649)
    if ($previousExecutionState -eq 0) { throw 'Cannot request temporary system-awake state.' }
    $result.SystemAwakeRequested = $true
    $ambientBefore = @{}
    if ($WaitForQuietBlender) {
        Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | ForEach-Object {
            $ambientBefore[$_.ProcessId] = [double]$_.KernelModeTime + [double]$_.UserModeTime
        }
    }
    $taskAmbient = @{ Observations = [Collections.Generic.List[object]]::new(); WslBuild = [Collections.Generic.List[object]]::new(); Before = @{}; Clock = $null }
    $beforeWorkload = {
        param($Storage, $Workload)
        if ($WaitForQuietWslBuild) { & $taskWslQuietGate }
        if (-not $WaitForQuietBlender) { return }
        & $taskQuietGate
        $taskAmbient.Before = @{}
        Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | ForEach-Object {
            $taskAmbient.Before[$_.ProcessId] = [double]$_.KernelModeTime + [double]$_.UserModeTime
        }
        $taskAmbient.Clock = [Diagnostics.Stopwatch]::StartNew()
    }.GetNewClosure()
    $afterWorkload = {
        param($Storage, $Workload)
        if ($WaitForQuietWslBuild) {
            $activeBuild = @(& $taskWslBuildProbe)
            if ($activeBuild.Count) { $taskAmbient.WslBuild.Add(@{Storage=$Storage;Workload=$Workload;Processes=$activeBuild}) }
        }
        if (-not $WaitForQuietBlender) { return }
        $ticks = [double]0
        Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | ForEach-Object {
            $initial = if ($taskAmbient.Before.ContainsKey($_.ProcessId)) { $taskAmbient.Before[$_.ProcessId] } else { 0 }
            $ticks += [math]::Max(0, [double]$_.KernelModeTime + [double]$_.UserModeTime - $initial)
        }
        $taskAmbient.Observations.Add(@{ Storage=$Storage; Workload=$Workload; BlenderCpuCores=($ticks/10000000/$taskAmbient.Clock.Elapsed.TotalSeconds) })
    }.GetNewClosure()
    $ambientClock = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $PSScriptRoot 'benchmark-m6-arm64.ps1') -SkipVhdxBaseline:(-not $IncludeVhdxBaseline) -StorageOrder $StorageOrder -TestSizeMiB $TestSizeMiB `
        -Workloads $Workloads -QueueDepth $QueueDepth `
        -RandomRuntimeSeconds $RuntimeSeconds -SequentialRuntimeSeconds $SequentialRuntimeSeconds -FsyncQueueDepth $FsyncQueueDepth -TimedFsync -DirectIO -VerifySequentialData:$VerifySequentialData `
        -ProxySyncPolicy guest -ProxyBuffering none -ProxyIOMode overlapped `
        -ProxyTransport shared-ring -ProxyDispatcherThreads 8 -RingDepth 256 `
        -BufferCount 128 -MaxTransferLength 262144 -IoStats -RunTag $RunTag -BeforeProxyShutdown $beforeClose -BeforeTimedWorkload $beforeWorkload -AfterTimedWorkload $afterWorkload
    if ($WaitForQuietBlender) {
        $ambientTicks = [double]0
        Get-CimInstance Win32_Process -Filter "Name='blender.exe'" | ForEach-Object {
            $initial = if ($ambientBefore.ContainsKey($_.ProcessId)) { $ambientBefore[$_.ProcessId] } else { 0 }
            $ambientTicks += [math]::Max(0, [double]$_.KernelModeTime + [double]$_.UserModeTime - $initial)
        }
        $result.AmbientBlenderCpuSeconds = $ambientTicks / 10000000
        $result.AmbientObservationSeconds = $ambientClock.Elapsed.TotalSeconds
        $result.AmbientBlenderCpuCores = $result.AmbientBlenderCpuSeconds / $result.AmbientObservationSeconds
        if ($result.AmbientBlenderCpuCores -gt 0.1) {
            $result.PotentialInterference = $true
            $result.InterferenceNote = 'Blender CPU activity resumed during the workload/capture interval; exclude from the quiet comparison.'
        }
    }
    $result.WorkloadAmbient = @($taskAmbient.Observations.ToArray())
    $result.WslBuildObservations = @($taskAmbient.WslBuild.ToArray())
    if ($result.WslBuildObservations.Count) {
        $result.PotentialInterference = $true
        $result.InterferenceNote = 'WSL compiler/build processes were active at a timed-workload boundary; exclude and repeat.'
    }
    if (@($result.WorkloadAmbient | Where-Object { $_.BlenderCpuCores -gt 0.1 }).Count) {
        $result.PotentialInterference = $true
        $result.InterferenceNote = 'Blender CPU activity overlapped a timed workload; exclude and repeat the pair.'
    }
    $capture = $captureState.Process
    if ($null -eq $capture) { throw 'The benchmark did not reach the capture hook.' }
    $report = @(Get-ChildItem (Join-Path $workspace 'artifacts\m6') -Filter "*-$RunTag-*.json")
    if ($report.Count -ne 1) { throw 'Expected exactly one benchmark report.' }
    Copy-Item -LiteralPath $report[0].FullName -Destination (Join-Path $directory 'benchmark.json')
    $timingReport = Get-Content -LiteralPath $report[0].FullName -Raw | ConvertFrom-Json
    foreach ($timingWorkload in $timingReport.Results) {
        if ($timingWorkload.WallSeconds -gt (2 * $timingWorkload.RuntimeSeconds + 10)) {
            throw 'Benchmark wall time greatly exceeds fio runtime; possible host pause. Exclude and repeat this run.'
        }
    }
    $expectedRows = $Workloads.Count * $(if ($IncludeVhdxBaseline) { 2 } else { 1 })
    if (@($timingReport.Results).Count -ne $expectedRows) { throw 'A storage path did not run every selected workload.' }
    foreach ($job in $timingReport.Results) {
        $expectedQd = if ($job.Workload -eq 'fsync4k') { $FsyncQueueDepth } else { $QueueDepth }
        if ($job.RequestedQueueDepth -ne $expectedQd -or $job.FioOptions -notmatch ('--iodepth='+$expectedQd+'(?:\s|$)')) { throw 'fio workload queue depth mismatch' }
        if ($job.Workload -eq 'fsync4k' -and $job.SyncCalls -le 0) { throw 'No fsync operations measured' }
    }
    foreach ($file in @('proxy.stdout.log','proxy.stderr.log','proxy.events.log')) {
        Copy-Item -LiteralPath (Join-Path $workspace "artifacts\m6\$file") -Destination $directory
    }
    if (-not $capture.WaitForExit(15000)) { throw 'Kernel CLOSE diagnostics were not captured.' }
    if ($capture.ExitCode -ne 0) { throw "Capture failed: $($capture.ExitCode)" }
    $parserArguments = @((Join-Path $directory 'kernel.log'), '--purpose', 'benchmark', '--output', (Join-Path $directory 'kernel-summary.json'))
    if ($CorrectedBaseline) { $parserArguments += '--baseline' }
    & python (Join-Path $PSScriptRoot 'summarize-winspd-ring-metrics.py') @parserArguments
    if ($LASTEXITCODE -ne 0) { throw 'Incomplete kernel metrics.' }
    $metrics = Get-Content (Join-Path $directory 'kernel-summary.json') -Raw | ConvertFrom-Json
    if (@($metrics.sessions).Count -ne 1 -or (-not $CorrectedBaseline -and $metrics.sessions[0].limits.claim -ne $PreparationBatchSize)) {
        throw 'Captured preparation tuning differs from the requested variant.'
    }
    if (-not $metrics.sessions[0].fully_retired -or (-not $CorrectedBaseline -and $metrics.sessions[0].limits.budget_violations -ne 0)) {
        throw 'Kernel ownership/copy-budget diagnostics failed.'
    }
    $result.CompletionPerf = $metrics.sessions[0].completion_perf
    $result.Execution = $metrics.sessions[0].execution
    $result['Mapping'] = $metrics.sessions[0].mapping
    if ($ExpectedMapThresholdBytes -ge 0 -and
        ($null -eq $result.Mapping -or $result.Mapping.threshold -ne $ExpectedMapThresholdBytes)) {
        throw 'Captured mapping threshold differs from the requested variant.'
    }
    if ($RequireMappedPayload -and
        ($null -eq $result.Mapping -or $result.Mapping.mapped -le 0 -or
         $result.Mapping.mapped -ne $result.Mapping.unmapped)) {
        throw 'Mapped payload was not exercised or mapping leases were not fully retired.'
    }
    if (($ExpectedPreparationThread -ge 0 -and
         ($null -eq $result.Execution -or $result.Execution.preparation_thread -ne $ExpectedPreparationThread)) -or
        ($ExpectedCompletionThread -ge 0 -and
         ($null -eq $result.Execution -or $result.Execution.completion_thread -ne $ExpectedCompletionThread)) -or
        ($ExpectedPreparationThreads -ge 0 -and
         ($null -eq $result.Execution -or $result.Execution.preparation_threads -ne $ExpectedPreparationThreads)) -or
        ($ExpectedCompletionThreads -ge 0 -and
         ($null -eq $result.Execution -or $result.Execution.completion_threads -ne $ExpectedCompletionThreads)) -or
        ($ExpectedCompletionClaimLimit -ge 0 -and
         ($null -eq $result.Execution -or $result.Execution.completion_claim_limit -ne $ExpectedCompletionClaimLimit)) -or
        ($ExpectedIoqQueuedSpinLock -ge 0 -and
         ($null -eq $result.Execution -or $null -eq $result.Execution.ioq_queued_spin_lock -or
          $result.Execution.ioq_queued_spin_lock -ne $ExpectedIoqQueuedSpinLock)) -or
        ($ExpectedThreadPriority -ge 0 -and
         ($null -eq $result.Execution -or $null -eq $result.Execution.thread_priority -or
          $result.Execution.thread_priority -ne $ExpectedThreadPriority))) {
        throw 'Captured execution mode differs from the requested thread/work-item configuration.'
    }
    if ($ExpectedCompletionDpcFlags -ge 0 -and
        ($null -eq $result.CompletionPerf -or
         $result.CompletionPerf.applied -ne $ExpectedCompletionDpcFlags -or
         ($ExpectedCompletionDpcFlags -ne 0 -and
          ($result.CompletionPerf.query_status -ne 0 -or $result.CompletionPerf.apply_status -ne 0)))) {
        throw 'Requested completion DPC flags were not applied; do not compare this as an enabled run.'
    }
    $result.Status = 'Measured'
}
catch {
    $result.Status = 'Failed'
    $result.Error = $_.Exception.Message
}
finally {
    $capture = $captureState.Process
    if ($null -ne $capture -and -not $capture.HasExited) {
        & $cli --stop | Out-Null
        if (-not $capture.WaitForExit(10000)) { $result.Error = "$($result.Error) Capture did not stop." }
    }
    if ($previousFilter -in @(0, 1)) {
        [void][WinSpdMeasurementFilter]::NtSetDebugFilterState(101, 3, ($previousFilter -eq 1))
    }
    $unused = $false
    [void][WinSpdMeasurementFilter]::RtlAdjustPrivilege(20, $previousPrivilege, $false, [ref]$unused)
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'result.json')
    if ($previousExecutionState -ne 0) {
        # Finish capture/receipts before releasing the hold. Reset the idle
        # timer once so cleanup/next-job handoff does not trigger immediate
        # idle sleep; restore the original execution state afterward.
        [void][WinSpdMeasurementFilter]::SetThreadExecutionState([uint32]1)
        [void][WinSpdMeasurementFilter]::SetThreadExecutionState($previousExecutionState)
    }
}
if ($result.Status -ne 'Measured') { throw $result.Error }

#Requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][string]$DbgViewCli,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RunTag,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedDriverHash,
    [ValidateSet(32,64,128)][int]$QueueDepth = 32,
    [ValidateRange(5,60)][int]$RuntimeSeconds = 20,
    [ValidateRange(64,16384)][int]$TestSizeMiB = 2048,
    [ValidateSet('vhdx-first','proxy-first')][string]$StorageOrder = 'vhdx-first',
    [ValidateSet('full-baseline','baseline-smoke')][string]$SourceRevision = 'full-baseline'
)
$ErrorActionPreference='Stop'
& "$PSScriptRoot/measure-winspd-ring.ps1" -DbgViewCli $DbgViewCli -RunTag $RunTag `
    -ExpectedDriverHash $ExpectedDriverHash -QueueDepth $QueueDepth `
    -RuntimeSeconds $RuntimeSeconds -SequentialRuntimeSeconds $RuntimeSeconds `
    -TestSizeMiB $TestSizeMiB -FsyncQueueDepth 1 -StorageOrder $StorageOrder `
    -IncludeVhdxBaseline -Workloads @('seqwrite','seqread','randread4k','randwrite4k','fsync4k') `
    -PreparationBatchSize 32 -Implementation coalesced -MeasurementPhase quiet `
    -SourceRevision $SourceRevision -ExpectedCompletionDpcFlags 0 `
    -ExpectedPreparationThread 0 -ExpectedCompletionThread 0 `
    -ExpectedPreparationThreads 0 -ExpectedCompletionThreads 0 `
    -ExpectedCompletionClaimLimit 32 -ExpectedIoqQueuedSpinLock 0 `
    -ExpectedThreadPriority 8 -WaitForQuietBlender -WaitForQuietWslBuild

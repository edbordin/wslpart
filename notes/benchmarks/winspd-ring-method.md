# WinSpd ring evaluation method

The comparison uses the same ARM64 Release WslPart executable, fio 3.41, Windows
installation, WSL kernel and source partition for every variant. Each run records
the installed SYS hash and numeric version, proxy hash and all I/O settings.
Successful driver activation and correctness-test receipts are required before
measurement; a reboot-required result prevents measurement. No reboot is performed.

## Workloads and fixed settings

- Preparation claim limits: 1, 8 and 32. Ready commits remain independently capped
  at eight requests or 256 KiB; preparation copies remain capped at 1 MiB with one
  oversized copy allowed. The 100 microsecond QPC wall-time limit is soft and only
  limits another claim, never abandonment of an owned batch.
- Requested fio queue depths: 1, 4, 32 and 128. Record fio's achieved-depth histogram
  and lower-bound average as well; requested depth alone does not prove occupancy.
- Three ten-second workloads per session: direct random 4 KiB READ, direct random
  4 KiB WRITE with end fsync, and timed 4 KiB WRITE with `fsync=1`. The latter records
  WRITE and sync latencies separately. Filesystem coalescing can make fio sync-call
  counts differ from backend flush counts.
- Shared ring, SQ/CQ depth 256, 128 payload buffers, 256 KiB maximum transfer,
  eight backend dispatcher threads, overlapped Windows I/O, unbuffered source
  handle, guest-controlled flushing and optional backend I/O statistics enabled.
- Disk 0 partition 16 must match start sector 3775834112 and size 52427751424 bytes.
  The script mounts its existing filesystem, uses a unique benchmark file and
  removes that file afterward. It does not format the partition.

## Baseline

`winspd-corrected-baseline.patch` applies to WinSpd commit
`30649abb3f3c7ffdb1d24a2442e8b61149ca47c5`. Its manifest records the patch SHA-256.
It retains the old processing hash, independent buffer freelist, staged producer
and inline CQ completion. It includes the tested scheduler/WAIT/cancellation
prerequisites from the pre-slot checkpoint, corrected zero-count and non-CDB FLUSH
forwarding, a logical-SRB FIFO FLUSH fence, and lock histogram instrumentation.

This is a Release benchmark baseline, not a supported alternative to the final
teardown implementation. It deliberately excludes the new slot ownership model,
generation tokens and separate preparation/completion work items. Both baseline
and refactor must pass the Release tests, including a real `FlushFileBuffers`
operation held in the backend callback to prove completion waits for that callback.
Using the uncorrected old implementation would measure skipped flushing.

## Measurement boundaries

The driver keeps fixed counter/histogram storage during I/O and prints it at
terminal CLOSE. Start kernel capture only after all fio timing and CPU windows,
immediately before graceful proxy shutdown. The capture process consumes CPU, so
running it throughout fio would distort the result. The final report selects only
`MeasurementPhase=quiet`, `CaptureMode=close-only` and
`SourceRevision=final-rundown` refactor receipts, plus the corrected baseline.
Earlier refactor source revisions are excluded even if their capture was quiet.

All binaries are built before that phase, and the elevated job runner serializes
tests, activations and measurements. Earlier runs overlapping builds, or keeping
capture active during fio, remain as exploratory artifacts and are excluded from
the final comparison. Ordinary desktop background activity is not controlled, so
these short runs are a local engineering evaluation, not a laboratory benchmark.

Windows CPU includes guest virtualization and other host processes. Proxy CPU is
reported as a percentage of one core; it can exceed 100%. fio reports guest user
and system CPU separately. Kernel and backend diagnostic totals cover the entire
three-workload session, including setup and teardown; they are not attributed to
an individual workload. Kernel p50/p99 and backend flush percentiles are logarithmic
bin upper bounds. fio latency percentiles come directly from fio's histograms.

Require `accepted == retired`, `active == 0`, `fence == 0`, complete histogram dumps,
the expected preparation tuning and zero copy-budget violations. Backend flush
counts must be positive with zero errors. The backend log excludes its explicit
final owner flush, which occurs after the statistics line.

## Reproduction and artifacts

Build/sign each tuning with `RingPreparationClaimLimit=1`, `8` or `32`; retain an
immutable INF/SYS/CAT/DLL package for each. Use monotonically increasing numeric
driver versions when installing variants. The textual FileVersion contains the
Git hash, so signing validates numeric version resources against INF DriverVer.

From an elevated PowerShell, after successful activation/tests:

```powershell
scripts/measure-winspd-ring.ps1 -DbgViewCli C:\path\dbgviewcli64a.exe `
  -RunTag my-batch32-qd32 -QueueDepth 32 -PreparationBatchSize 32 `
  -Implementation coalesced -MeasurementPhase quiet -SourceRevision final-rundown `
  -ExpectedDriverHash <SHA256>
```

Use `-CorrectedBaseline` for the separately activated baseline. The supplied
DebugView CLI path is an external capture prerequisite. Each run retains benchmark
JSON, kernel log/summary, backend logs and a result receipt beneath
`artifacts/ring-measurements/<RunTag>`.

```powershell
python scripts/report-winspd-ring-benchmarks.py artifacts/ring-measurements `
  --phase quiet --capture-mode close-only --source-revision final-rundown `
  --output-prefix notes/benchmarks/winspd-ring-final
```

The report rejects mismatched fixed settings, incomplete ownership diagnostics,
missing fio sync calls and missing/failed backend flush measurements. It excludes
failed runs and other measurement phases rather than silently folding them into
the comparison. QD1 has three baseline and three default-refactor repeats. These
were measured in separate serialized groups, not interleaved matched pairs; their
ranges expose sensitivity to low-depth scheduling and background activity.

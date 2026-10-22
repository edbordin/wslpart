# Storport completion-DPC redirection comparison - 2026-10-21

Follow-up [kernel worker profiling](winspd-ring-scheduler.md) resolves the default
notification path into Storport DPC/Windows completion work and identifies IOQ
spinlock and timing overhead relevant to dedicated-thread experiments.

The clean post-render comparison supports origin-CPU redirection as a candidate for higher-depth WRITE throughput and lower CPU use, with a READ tail-latency tradeoff. Current-CPU redirection does not show a compelling advantage. The original default policy remains installed; no experimental flag is promoted by this comparison.

All numbers below compare the same ownership-refactored WinSpd driver with different Storport settings. The default-policy control is neither VHDX nor the old pre-refactor transport.

## Main results

At QD128, origin routing improves median READ IOPS by 4.6% and WRITE by 17.6%. Host CPU falls about 7.1 and 3.6 percentage points respectively. READ p99 increases about 15.5%; WRITE p99 is slightly lower. At QD32 throughput is similar, CPU falls about 6-7 percentage points, and p99 is somewhat higher. These are short engineering measurements with only two repeats at QD1/128 and one at QD32, not confidence intervals.

| QD | Workload | Default IOPS | Origin CPU IOPS | Current CPU IOPS | Origin change |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | randread4k | 5,977 | 5,932 | 6,228 | -0.7% |
| 1 | randwrite4k | 8,212 | 9,576 | 9,695 | +16.6% |
| 32 | randread4k | 126,567 | 123,719 | 132,019 | -2.3% |
| 32 | randwrite4k | 144,612 | 144,384 | 147,597 | -0.2% |
| 128 | randread4k | 180,650 | 189,031 | 174,343 | +4.6% |
| 128 | randwrite4k | 185,629 | 218,220 | 189,181 | +17.6% |

| QD | Workload | Default p99 us | Origin CPU p99 us | Current CPU p99 us | Host CPU default / origin / current % |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | randread4k | 259 | 240 | 222 | 9.6 / 8.2 / 8.4 |
| 1 | randwrite4k | 204 | 137 | 135 | 13.6 / 13.0 / 11.9 |
| 32 | randread4k | 391 | 403 | 391 | 44.2 / 38.0 / 43.5 |
| 32 | randwrite4k | 346 | 379 | 342 | 47.7 / 40.5 / 47.6 |
| 128 | randread4k | 979 | 1,130 | 1,098 | 54.6 / 47.5 / 53.8 |
| 128 | randwrite4k | 967 | 946 | 995 | 55.2 / 51.6 / 55.0 |

IOPS and percentile cells are medians of the per-run results. A median of two reported p99 values is not a pooled percentile. QD1 variation is substantial: origin READ spans 5,378-6,486 IOPS; origin WRITE spans 8,750-10,403, while current-CPU WRITE spans 8,615-10,775. Default WRITE p99 spans 140-268 us. The low-depth cells do not establish a universal latency or throughput win.

## What changed inside completion

The following are medians of exact per-session means at QD128, in microseconds:

| Metric | Default READ / WRITE | Origin CPU READ / WRITE | Current CPU READ / WRITE |
| --- | ---: | ---: | ---: |
| Notification-call duration | 3.99 / 4.03 | 0.54 / 0.48 | 3.97 / 3.86 |
| CQ acceptance to notification | 223.15 / 212.05 | 29.87 / 25.09 | 169.45 / 188.35 |
| Tracked miniport lifetime | 362.57 / 317.17 | 229.46 / 155.72 | 358.48 / 294.75 |
| Fio mean completion latency | 706.21 / 686.75 | 675.89 / 584.40 | 731.59 / 673.79 |

Origin routing reduces notification-call duration from roughly 4 us to 0.5 us and the tracked CQ interval from about 212-223 us to 25-30 us. Current-CPU routing retains roughly 4 us notification calls and a much longer CQ interval. This is consistent with the destination of deferred completion processing mattering, rather than there being a free asynchronous completion operation.

The guest-visible gain is much smaller than the reduction inside the miniport worker. For READ, tracked miniport lifetime falls by about 133 us, but fio mean improves by only about 30 us. For WRITE those reductions are about 162 and 102 us. Work can move into Storport DPC/upper-stack processing beyond our notification boundary. These measurements do not correlate each SRB with its guest request or distinguish CPU execution from preemption, so they do not precisely attribute the remaining gap.

## QD1 fsync spot check

| Setting | fsync4k IOPS | Fio sync p99 us | Backend flush mean us |
| --- | ---: | ---: | ---: |
| Default | 317 | 6,914 | 725 |
| Origin CPU | 383 | 5,800 | 614 |
| Current CPU | 358 | 6,521 | 653 |

This is one timed fsync run per mode, with positive backend flush calls and zero errors. Backend flush cost changes materially between runs; the entire throughput difference cannot be credited to completion routing. Fio sync latency is separate from WRITE completion latency. Kernel stage summaries for this workload combine WRITE and FLUSH logical SRBs, while fio IOPS counts writes. Filesystem coalescing and journaling mean backend flush-call counts are not one for one with fio sync calls.

## Validation, interference and final state

The user reported a Blender render during the earlier sweep, then confirmed it had finished before the new `dpc-clean-` runs began at approximately 21:46 on October 20. Earlier DPC performance records remain marked potentially affected and are excluded. The five-second capability probe is also excluded from this main dataset.

The clean dataset has 33 successful twenty-second profiles: 30 READ/WRITE profiles and three QD1 fsync profiles. All fixed settings and proxy hashes match. Each run fully retired accepted SRBs, left active/fence/completion counts zero, recorded zero copy-budget violations and KICK overlaps, and had no SQ-full/buffer-starvation events. Exact stage totals reconcile with tracked kernel lifetime to floating-point precision. Applied flags are checked in both measurement receipts and report collection; a requested but unsupported/failed option cannot count as enabled.

The sweep was not an uninterrupted laboratory run. There were long gaps after completed timed workloads, during result/cleanup handoff; all retained fio timing windows have normal wall/runtime values around twenty seconds. The last default controls completed after those gaps. This limits claims about thermal/background stability even though the reported render was no longer running. The temporary awake hold now covers capture and receipt cleanup as well as fio, resets the idle timer once at handoff and restores the prior execution state. No power-plan or display requirement is changed.

Both enabled modes passed 70 selected Debug tests, including the production legacy lifecycle case and cancellation/reset/teardown races. Every activated Release package passed all 21 applicable cases plus repeated zero-count FLUSH regressions. Seven parser/report tests cover units, inconsistent counts/clocks, incomplete dumps, zero samples, requested versus applied flags and render-interference exclusion. No new ownership state, miniport DPC producer or dedicated thread was introduced.

The original default policy is restored in normal Release `1.0.26293.100`, detailed kernel timing off, SHA-256 `2A612C24623AC50B55E355AAE2482E09E5B52D66F30980F6896B784265617395`. Final audit passed with zero units and zero proxy/capture processes. No reboot was performed. Changes are uncommitted.

Use origin routing as the next candidate when higher-depth WRITE throughput or CPU use is the priority, and evaluate READ p99 against the application's latency target. The data does not justify promoting current-CPU routing or claiming a uniform low-depth improvement. Preparation claim 32 and the independent commit/publication limits remain unchanged; this experiment does not re-optimize application QD.

[CSV](winspd-ring-dpc.csv) and [JSON](winspd-ring-dpc.json) retain all accepted profiles and driver identities. Raw captures/receipts are under `artifacts/ring-measurements/dpc-clean-*`; signed packages are under `artifacts/ring-packages/dpc-Release-{95,96,97,98,99,100}`. The clean-sweep confirmation is retained in `artifacts/ring-dpc-clean-sweep.json`, and the final installation audit in `artifacts/winspd-final-audit-result.json`.

## Experiment

Query StorPortInitializePerfOpts during HwInitialize, retain the supported flag mask, and explicitly apply only the requested completion-routing flags. The query on this host succeeded at PERF_CONFIGURATION_DATA version 8, advertising mask 447 (0x1bf). Both relevant flags are available.

- Mode 0: preserve Storport defaults; query capabilities but do not apply options.
- Mode 1: STOR_PERF_DPC_REDIRECTION (0x1), routing toward the originating CPU.
- Mode 2: STOR_PERF_DPC_REDIRECTION | STOR_PERF_DPC_REDIRECTION_CURRENT_CPU (0x21), routing toward the completing CPU.

This changes Storport's completion routing. It adds no miniport DPC producer, dedicated thread, shared-memory ABI change or new slot owner. Preparation, SQ publication and completion work-item ownership remain as before. Unsupported/failed configuration falls back without failing adapter startup, and diagnostics distinguish requested flags from applied flags. Measurement receipts require successful application for enabled variants.

RingCompletionDpcMode is an optional build property (default 0); detailed timing is enabled independently by RingLatencyDiagnostics=1. Concurrent StartIo, interrupt-message routing, SGL options and other advertised flags are not enabled by this experiment.

## Method

Compare fresh isolated READ/WRITE direct 4 KiB, io_uring workloads at application QD1, 32 and 128. Hold preparation claim 32, ready commit 8, completion claim 32, ring capacity 256, buffers 128, transfer cap 256 KiB and eight backend workers constant. Every fio window is twenty seconds, with capture starting after timing. Use the same proxy binary and optional backend I/O statistics for all variants.

Run default, origin and current modes, then repeat current QD1/QD128 and measure
origin/default QD1/QD128 again in reverse configuration order. Both READ and WRITE
have two observations per configuration at QD1 and QD128, and one at QD32: thirty
READ/WRITE sessions total, plus one QD1 fsync per mode. Build all packages before the measurement phase; serialize
activations, correctness gates and measurements. Ordinary desktop activity
remains uncontrolled, and the modes are grouped rather than fully randomized.
Each measurement holds a temporary system-awake request without changing the
power plan or requesting that the display stay on. The wall-time guard still
rejects explicit sleep or other large timing discontinuities.

Compare fio mean/p99 and IOPS, total host CPU, per-stage exact means, notification-call duration, CQ backlog and callback dispatch. Worker/call timings are wall time, not thread CPU. Kernel metrics include filesystem setup/teardown. Completion routing can move work outside the measured miniport callback, so shorter notification calls alone do not establish an end-to-end improvement.

The first capability probe is five seconds, has source marker latency-profile, and is excluded from the main dpc-profile dataset. Capture/parser checks include successful activation/hash, queried/applied flags, fixed settings, no timing discontinuity, complete metrics, fully retired SRBs and zero copy-budget violations.

Collect the main dataset with:

```powershell
python scripts/report-winspd-ring-latency.py artifacts/ring-measurements `
  --source-revision dpc-profile --run-prefix dpc-clean- `
  --output-prefix notes/benchmarks/winspd-ring-dpc
```

API references: [StorPortInitializePerfOpts](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/nf-storport-storportinitializeperfopts), [PERF_CONFIGURATION_DATA](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/ns-storport-_perf_configuration_data). No host reboot is permitted for this experiment.

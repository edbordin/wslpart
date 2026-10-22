# WinSpd shared-ring evaluation - 2026-10-20

The ownership/rundown refactor passes its selected functional gates. The final-source default improves higher-depth READ/WRITE throughput, with substantially higher host CPU use. QD1 results vary between runs, and QD4 fsync throughput regresses. Performance acceptance remains open pending longer, interleaved measurements and an agreed CPU/latency tradeoff.

The subsequent [latency investigation](winspd-ring-latency.md) separates CQ queue
wait, completion service and Storport notification. It identifies serialized
completion/notification work as a material high-depth delay. This report retains
the original full tuning evaluation; current installation details are in the
latency report and implementation progress.
The [DPC-routing comparison](winspd-ring-dpc-comparison.md) subsequently tests
Storport's completion-routing options against fresh post-render controls.

See the [historical VHDX comparison and tuning guidance](winspd-vhdx-comparison.md)
for a separate comparison against previous VHDX measurements. VHDX is not the
corrected old-ring baseline used in the tables below.

## Validated result

- ARM64 Release driver used for this evaluation: `1.0.26293.78`, SHA-256 `D4EDDBD8E909C1B366115B4C8EDB047E3335436749983393DAB7BE1A3E73A937`. No reboot was performed.
- The pinned final source passed 70 selected Debug tests at claim limit 32: 69 ring cases and one production legacy lifecycle case. Limits 1 and 8 each passed 68 tests; the two excluded partial-commit cases require a claim larger than the eight-request commit group.
- Release limits 1, 8 and 32 each passed all 21 applicable cases, including a real `FlushFileBuffers` operation blocked in the backend callback. Each activation also repeated the two zero-count CDB FLUSH regressions.
- The final gates include forced unprovision with a live backend callback, stale session handles, OPEN-owner changes, reset retirement concurrent with CLOSE, and publication frozen immediately on malformed CQ detection. Unsupported older raw adapter-SPTD legacy fixtures are not counted as passing; the common production-API legacy lifecycle case covers normal legacy READ/WRITE/chunk/FLUSH behavior.
- Final audit found zero provisioned units, zero proxy/capture processes and only the original physical disk. The elevated runner remains available. Audit receipt: `artifacts/winspd-final-audit-result.json`.

## Matched settings, final-source measurements

The tables use only quiet runs with capture started after fio, and only final-rundown refactor source. There are 21 successful sessions and 63 workload observations. Most cells have one ten-second run; baseline QD1 and default QD1 each have three, and default QD128 has two. Baseline and refactor groups were serialized separately rather than interleaved. Ordinary desktop activity was not controlled. These medians and ranges are engineering observations, not confidence intervals. See the [method](winspd-ring-method.md), [CSV](winspd-ring-final.csv) and [JSON](winspd-ring-final.json).

All variants use the same backend binary and underlying I/O settings. The benchmark-only baseline includes real CDB/non-CDB flushing and FIFO ordering; it does not measure skipped backend flushes. Refactor tunings were built from the same final source before measurement. Exact SYS hashes are retained per row and in activation receipts.

| QD | Workload | Baseline IOPS | Default 32 IOPS | Change | Baseline p99 us | Default p99 us | Host CPU baseline/default % |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | randread4k | 7,355 | 7,380 | +0.3% | 206 | 177 | 8.8 / 8.8 |
| 1 | randwrite4k | 9,841 | 10,501 | +6.7% | 157 | 125 | 12.0 / 11.9 |
| 1 | fsync4k | 684 | 719 | +5.1% | 1,729 | 148 | 5.5 / 5.3 |
| 4 | randread4k | 24,374 | 23,419 | -3.9% | 255 | 253 | 16.6 / 14.3 |
| 4 | randwrite4k | 31,156 | 33,526 | +7.6% | 212 | 157 | 16.7 / 14.1 |
| 4 | fsync4k | 1,282 | 1,008 | -21.4% | 1,647 | 1,909 | 7.0 / 5.7 |
| 32 | randread4k | 94,217 | 128,299 | +36.2% | 518 | 362 | 26.9 / 44.2 |
| 32 | randwrite4k | 112,791 | 151,877 | +34.7% | 461 | 317 | 28.7 / 47.5 |
| 32 | fsync4k | 4,105 | 4,191 | +2.1% | 3,916 | 3,883 | 10.3 / 6.5 |
| 128 | randread4k | 138,308 | 185,363 | +34.0% | 1,565 | 979 | 29.0 / 54.6 |
| 128 | randwrite4k | 150,591 | 195,474 | +29.8% | 1,286 | 954 | 27.0 / 56.1 |
| 128 | fsync4k | 13,262 | 13,891 | +4.7% | 3,916 | 2,982 | 9.6 / 8.7 |

For fsync4k, the table above shows WRITE completion latency. The sync latency below is separate and must also be reviewed. Host CPU includes virtualization and background processes; proxy CPU, recorded separately in CSV/JSON, is a percentage of one core.

| QD | Baseline sync p99 us | Default sync p99 us | Baseline/default backend flush mean us |
| ---: | ---: | ---: | ---: |
| 1 | 3,817 | 2,802 | 373 / 370 |
| 4 | 5,800 | 7,438 | 352 / 420 |
| 32 | 17,170 | 16,056 | 562 / 573 |
| 128 | 21,627 | 20,447 | 692 / 658 |

Backend measurements cover the entire session, not just the fsync timing window. Filesystem coalescing means fio sync calls and backend flush calls need not match one for one.

## Tuning and batching

| QD | Workload | Claim 1 IOPS | Claim 8 IOPS | Claim 32 IOPS |
| ---: | --- | ---: | ---: | ---: |
| 1 | randread4k | 5,549 | 6,130 | 7,380 |
| 1 | randwrite4k | 9,505 | 8,167 | 10,501 |
| 1 | fsync4k | 476 | 634 | 719 |
| 4 | randread4k | 21,304 | 21,662 | 23,419 |
| 4 | randwrite4k | 28,041 | 33,573 | 33,526 |
| 4 | fsync4k | 1,115 | 998 | 1,008 |
| 32 | randread4k | 122,858 | 134,731 | 128,299 |
| 32 | randwrite4k | 139,539 | 149,176 | 151,877 |
| 32 | fsync4k | 4,035 | 2,178 | 4,191 |
| 128 | randread4k | 166,645 | 183,939 | 185,363 |
| 128 | randwrite4k | 170,195 | 193,893 | 195,474 |
| 128 | fsync4k | 13,464 | 5,378 | 13,891 |

At QD128, mean preparation claims are 1.00, 2.09 and 2.11 requests for limits 1, 8 and 32. The limit is a ceiling; workers do not wait to accumulate a batch. Whole-session metadata acquisitions per accepted logical SRB are 9.20, 6.52 and 6.58 respectively, versus 6.88 for the corrected baseline. Batching therefore reduces churn against claim-1 operation, but the overall reduction against the old transport is modest.

At QD1 the default uses about 21.98 metadata acquisitions per accepted SRB, versus 19.01 baseline. Wakeup coalescing eliminated the exploratory implementation's redundant callbacks: preparation and publication now each run about once per request. Raising the claim ceiling cannot batch a single outstanding request.

| QD | Baseline lock wait p99 upper us | Default lock wait p99 upper us | Baseline lock hold p99 upper us | Default lock hold p99 upper us |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 0.2 | 0.2 | 0.4 | 0.2 |
| 4 | 0.8 | 0.8 | 0.4 | 0.8 |
| 32 | 3.2 | 6.4 | 0.4 | 0.8 |
| 128 | 3.2 | 12.8 | 0.4 | 1.6 |

These diagnostics aggregate setup, all three workloads and teardown. They cannot isolate contention for one workload. At QD128 the default's p99 lock wait upper bound rises from 3.2 to 12.8 us even though throughput improves; lower acquisition count alone does not prove lower contention.

## Remaining performance questions

- QD1 READ medians are 7,355 baseline versus 7,380 default IOPS (+0.3%). Individual baseline runs range from 5,994 to 7,604, and default runs from 6,503 to 7,525. Default WRITE and fsync medians improve by 6.7% and 5.1%. Earlier candidate runs showed a QD1 READ regression; they are excluded from the final-source table, but reinforce the need for interleaved, longer repeats before claiming low-depth performance acceptance.
- Preparation and completion handoffs still have a cost. A representative final QD1 session records logarithmic p50 upper bounds of 6.4 us pending-to-preparing, 0.4 us preparing-to-ready, 3.2 us ready-to-SQ and 6.4 us CQ-to-completion. These are separate distributions, not additive exact percentiles. The current data does not isolate their causal contribution to end-to-end latency.
- At QD32/128, READ/WRITE throughput improves about 30-36%, while host CPU rises to roughly 44-56%, versus 27-29% baseline. This is a throughput/CPU tradeoff; efficiency acceptance needs a stable matched comparison.
- The single QD4 fsync comparison loses 21.4% throughput and its sync p99 rises from about 5,800 to 7,438 us. Session backend flush mean also rises from 352 to 420 us. Claim-8 fsync runs at QD32/128 have especially high backend flush means (1,281/2,230 us), which confounds tuning comparisons. Do not attribute the entire difference to queueing or dismiss it as noise. Repeat with stable backend flush cost and record the same counters.
- Dedicated threads, DPCs, inline stage bypasses and adaptive low-depth execution have not been introduced. A later scheduling change should preserve the tested ownership model and be measured separately.

## Reproducibility and interpretation

All included runs retire every accepted SRB, leave active/fence counts zero, report zero copy-budget violations and record positive backend flush calls with zero errors. Histogram percentiles are logarithmic bin upper bounds; medians of repeated bounds are summaries, not a new measured percentile. Work-item duration counters time the work section before final handoff, not every instruction of the callback epilogue or CPU time. Requested fio depth and its combined WRITE/sync achieved-depth accounting should not be read as exact simultaneous WRITE occupancy.

The host has 18 logical processors (Snapdragon X2 Elite Extreme X2E94100); the source is the existing ext4 partition on a Samsung 970 EVO Plus 2TB. No partition was formatted. Raw records live under `artifacts/ring-measurements`; signed packages and per-variant activation receipts are under `artifacts/ring-packages`. The [corrected baseline patch](winspd-corrected-baseline.patch) and [manifest](winspd-corrected-baseline.json) are retained beside this report. Changes remain uncommitted.

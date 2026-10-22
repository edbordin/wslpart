# WinSpd work-item baseline and WSL root VHDX - 2026-10-23

**PROVISIONAL - background WSL kernel compilation was discovered during the sweep.**

The observed make process tree started at 2026-10-23 05:47:15 +11:00.
The entire final QD32 pair (`baseline-full-p3-qd32-a1`) is excluded.
The eight retained pairs finished before that observed tree started;
earlier build activity has not been ruled out. Throughput and latency
can also be affected by CPU scheduling and SSD contention. Host-wide
CPU is not evidence of driver CPU cost. These tables support inspection,
not a final configuration decision. The user deferred clean repeats;
raw data, timestamps and the excluded pair remain available.

Compare QD32, QD64 and QD128 on the current validated baseline and the
Ubuntu root filesystem. Both paths use the same Samsung 970 EVO Plus 2 TB
NVMe SSD. The VHDX resides on Windows C:; WinSpd exposes disk 0 partition 16.

Validated 8 paired sessions / 80 workload observations.
Excluded attempts: 2. Three passes rotate QD order:
32/64/128, 128/32/64, 64/128/32. Storage order alternates between sessions.
Retained 20-second measurements per storage/workload cell: QD32: 2, QD64: 3, QD128: 3.

Baseline: Release 1.0.26293.217, preparation/completion work items, ordinary
IOQ locking, preparation/completion claim caps 32, ready commits 8/256 KiB,
SQ publication and CQ consumption batches 32. Userspace uses eight overlapped
workers, guest sync policy, unbuffered source I/O, ring depth 256, 128
buffers and maximum transfer 256 KiB. Default DPC routing. No tracing runs
during timed workloads; basic kernel counters and backend diagnostics remain
enabled. Driver identity: `A61EFDC3077B7AFBE9DFC13C2956B6C7D3FB070FBAB763A4931081C3D1C60445`.

fio uses io_uring and direct I/O. Sequential READ/WRITE uses 1 MiB requests
at the actual selected depth and runs for 20 seconds, rather than the old
single-pass QD1 sequential test. Random READ/WRITE uses 4 KiB requests.
Both paths use unique 2 GiB files; fsync4k uses a 16 MiB working region.
Sequential WRITE flushes on close, random WRITE performs an end fsync.

Linux reports write-back caching for both virtual block devices. Root
mount options include discard; the source partition uses rw,relatime.

fsync4k uses QD1 with fsync after each 4 KiB write. It is an identical
serialized durability test in every suite, not a QD32/64/128 experiment.
The durability table uses all retained observations per storage path.

The source partition is approximately 48.8 GiB, but its existing ext4
filesystem is approximately 15.6 GiB and was about 61% full before testing,
with about 5.8 GiB available. Ubuntu root is ext4 on a 1 TiB VHDX, about
17% full. The working set was reduced from 4 GiB after the free-space guard
rejected an incomplete first attempt. No existing source files were deleted.
This compares the actual deployed storage paths, including filesystem
layout/fullness and VHDX overhead; it does not isolate transport cost alone.

All table values are medians of individual runs, not pooled percentiles.
Latency is fio completion latency in microseconds. MiB/s uses 1,048,576 bytes.
Raw fio JSON, per-run values, hashes and kernel CLOSE diagnostics are retained.

## Sequential READ, 1 MiB

| QD | WinSpd MiB/s | VHDX MiB/s | WinSpd p95 us | VHDX p95 us | WinSpd p99 us | VHDX p99 us |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 2,679.1 | 2,949.9 | 16,613.4 | 12,910.6 | 17,924.1 | 19,497.0 |
| 64 | 2,784.5 | 2,803.0 | 36,438.0 | 32,636.9 | 47,448.1 | 36,438.0 |
| 128 | 2,573.6 | 2,849.0 | 78,118.9 | 84,410.4 | 86,507.5 | 104,333.3 |

## Sequential WRITE, 1 MiB

| QD | WinSpd MiB/s | VHDX MiB/s | WinSpd p95 us | VHDX p95 us | WinSpd p99 us | VHDX p99 us |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 1,632.6 | 1,640.6 | 27,787.3 | 27,394.0 | 61,079.6 | 59,506.7 |
| 64 | 1,541.5 | 1,554.3 | 77,070.3 | 69,730.3 | 100,139.0 | 87,556.1 |
| 128 | 1,571.3 | 1,537.3 | 125,304.8 | 158,335.0 | 147,849.2 | 200,278.0 |

## Random READ, 4 KiB

| QD | WinSpd IOPS | VHDX IOPS | WinSpd p95 us | VHDX p95 us | WinSpd p99 us | VHDX p99 us |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 123,605.3 | 141,831.4 | 340.0 | 315.4 | 415.7 | 393.2 |
| 64 | 158,517.6 | 146,952.3 | 544.8 | 518.1 | 1,011.7 | 585.7 |
| 128 | 182,693.3 | 165,045.5 | 880.6 | 880.6 | 1,056.8 | 2,072.6 |

## Random WRITE, 4 KiB

| QD | WinSpd IOPS | VHDX IOPS | WinSpd p95 us | VHDX p95 us | WinSpd p99 us | VHDX p99 us |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 151,017.0 | 142,764.6 | 276.5 | 259.6 | 342.0 | 303.1 |
| 64 | 188,888.5 | 115,402.3 | 464.9 | 839.7 | 561.2 | 2,703.4 |
| 128 | 187,375.7 | 136,632.2 | 839.7 | 987.1 | 1,003.5 | 3,784.7 |

## Throughput and latency cost of increasing QD

| Storage | Workload | Change | Throughput | p95 | p99 |
| --- | --- | --- | ---: | ---: | ---: |
| winspd-partition | seqwrite | 32 to 64 | -5.6% | +177.4% | +63.9% |
| winspd-partition | seqwrite | 64 to 128 | +1.9% | +62.6% | +47.6% |
| winspd-partition | seqread | 32 to 64 | +3.9% | +119.3% | +164.7% |
| winspd-partition | seqread | 64 to 128 | -7.6% | +114.4% | +82.3% |
| winspd-partition | randread4k | 32 to 64 | +28.2% | +60.2% | +143.3% |
| winspd-partition | randread4k | 64 to 128 | +15.3% | +61.7% | +4.5% |
| winspd-partition | randwrite4k | 32 to 64 | +25.1% | +68.1% | +64.1% |
| winspd-partition | randwrite4k | 64 to 128 | -0.8% | +80.6% | +78.8% |
| wsl-vhdx | seqwrite | 32 to 64 | -5.3% | +154.5% | +47.1% |
| wsl-vhdx | seqwrite | 64 to 128 | -1.1% | +127.1% | +128.7% |
| wsl-vhdx | seqread | 32 to 64 | -5.0% | +152.8% | +86.9% |
| wsl-vhdx | seqread | 64 to 128 | +1.6% | +158.6% | +186.3% |
| wsl-vhdx | randread4k | 32 to 64 | +3.6% | +64.3% | +49.0% |
| wsl-vhdx | randread4k | 64 to 128 | +12.3% | +70.0% | +253.8% |
| wsl-vhdx | randwrite4k | 32 to 64 | -19.2% | +223.5% | +791.9% |
| wsl-vhdx | randwrite4k | 64 to 128 | +18.4% | +17.6% | +40.0% |

## Serialized write-and-fsync, QD1

fsync/s includes time spent writing and syncing; its numerator is completed
fsync operations. Sync latency measures the fsync operation itself, excluding
the preceding WRITE. Do not add write and sync percentiles.

| Storage | Runs | fsync/s | Mean write us | Mean sync us | Sync p95 us | Sync p99 us |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| winspd-partition | 8 | 187.4 | 138.0 | 5,182.0 | 6,619.1 | 9,109.5 |
| wsl-vhdx | 8 | 333.4 | 115.6 | 3,157.9 | 5,636.1 | 7,274.5 |

## CPU use

Windows CPU is GetSystemTimes non-idle percentage across 18 logical CPUs.
This is host-wide activity, including unrelated applications and WSL; it
cannot establish driver CPU cost. Proxy cores is wslpart process CPU-seconds
divided by workload wall time and is process-specific. Neither metric
attributes kernel driver CPU; that requires stack/module profiling.
Guest fio CPU counters cover the fio task and are retained in CSV/JSON.

| Workload | QD | WinSpd Windows CPU % | VHDX Windows CPU % | Proxy cores |
| --- | ---: | ---: | ---: | ---: |
| seqwrite | 32 | 6.65 | 3.81 | 0.29 |
| seqwrite | 64 | 12.97 | 4.05 | 0.52 |
| seqwrite | 128 | 11.37 | 4.56 | 0.72 |
| seqread | 32 | 7.47 | 4.94 | 0.38 |
| seqread | 64 | 15.77 | 4.50 | 0.96 |
| seqread | 128 | 13.54 | 4.41 | 1.10 |
| randread4k | 32 | 42.86 | 13.92 | 3.47 |
| randread4k | 64 | 48.05 | 15.13 | 2.76 |
| randread4k | 128 | 52.70 | 21.66 | 2.74 |
| randwrite4k | 32 | 47.36 | 12.82 | 3.63 |
| randwrite4k | 64 | 52.91 | 36.38 | 2.79 |
| randwrite4k | 128 | 52.86 | 21.66 | 2.51 |
| fsync4k | 1 | 6.80 | 3.60 | 0.15 |

## Variation across retained passes

| Storage | Workload | QD | Throughput min to max | p95 us min to max |
| --- | --- | ---: | ---: | ---: |
| winspd-partition | seqwrite | 32 | 1,561.1 to 1,704.1 | 27,131.9 to 28,442.6 |
| winspd-partition | seqwrite | 64 | 1,487.9 to 1,570.2 | 76,021.8 to 79,167.5 |
| winspd-partition | seqwrite | 128 | 1,465.8 to 1,611.4 | 104,333.3 to 137,363.5 |
| winspd-partition | seqread | 32 | 2,428.3 to 2,930.0 | 13,697.0 to 19,529.7 |
| winspd-partition | seqread | 64 | 2,673.5 to 2,965.3 | 29,753.3 to 40,632.3 |
| winspd-partition | seqread | 128 | 2,474.2 to 2,872.8 | 59,506.7 to 79,167.5 |
| winspd-partition | randread4k | 32 | 123,484.2 to 123,726.4 | 337.9 to 342.0 |
| winspd-partition | randread4k | 64 | 53,613.5 to 189,050.1 | 493.6 to 3,555.3 |
| winspd-partition | randread4k | 128 | 62,324.8 to 186,733.8 | 847.9 to 5,799.9 |
| winspd-partition | randwrite4k | 32 | 149,150.2 to 152,883.7 | 272.4 to 280.6 |
| winspd-partition | randwrite4k | 64 | 57,141.2 to 201,398.9 | 440.3 to 2,932.7 |
| winspd-partition | randwrite4k | 128 | 68,801.8 to 190,354.9 | 839.7 to 4,751.4 |
| wsl-vhdx | seqwrite | 32 | 1,487.8 to 1,793.3 | 22,151.2 to 32,636.9 |
| wsl-vhdx | seqwrite | 64 | 1,514.6 to 1,778.1 | 49,545.2 to 71,827.5 |
| wsl-vhdx | seqwrite | 128 | 1,458.3 to 1,596.5 | 147,849.2 to 170,917.9 |
| wsl-vhdx | seqread | 32 | 2,495.1 to 3,404.8 | 9,633.8 to 16,187.4 |
| wsl-vhdx | seqread | 64 | 2,580.2 to 3,073.1 | 31,064.1 to 40,108.0 |
| wsl-vhdx | seqread | 128 | 2,648.2 to 2,944.1 | 72,876.0 to 85,458.9 |
| wsl-vhdx | randread4k | 32 | 141,408.4 to 142,254.5 | 313.3 to 317.4 |
| wsl-vhdx | randread4k | 64 | 30,263.0 to 153,877.2 | 497.7 to 7,176.2 |
| wsl-vhdx | randread4k | 128 | 71,167.5 to 172,350.1 | 856.1 to 5,079.0 |
| wsl-vhdx | randwrite4k | 32 | 140,202.8 to 145,326.3 | 255.0 to 264.2 |
| wsl-vhdx | randwrite4k | 64 | 28,714.3 to 145,479.2 | 489.5 to 8,093.7 |
| wsl-vhdx | randwrite4k | 128 | 67,392.7 to 141,389.5 | 938.0 to 4,948.0 |

## Integrity and limits

Each pair validates the actual loaded driver/mode, fio job options and
errors, queue-depth distribution, complete SRB retirement, ring request/
response accounting, and successful backend FlushFileBuffers counters.
Backend counters cover all five WinSpd workloads plus setup/cleanup, so
their totals are not attributed exclusively to the fsync4k job.

fio groups achieved depths 64 and above into one histogram bin. The raw
job configuration distinguishes requested QD64/128; the histogram confirms
asynchronous depth rather than an accidental QD1 test. Depth histograms
are normalized by their sample weights: fio can report 200% for the QD1
write+fsync job because sync samples and write samples share the bin.

Blender CPU activity is checked before each workload and measured across
each timed interval. Known overlapping attempts are excluded. Wall
time guards reject host pauses. Other system, SSD cache and thermal
variation remains possible; two or three observations do not establish statistical
significance. WinSpd retains basic diagnostics and event logging, including
flush events, which can add overhead compared with diagnostics disabled.

Neither filesystem was formatted or resized. Only newly created benchmark
files are removed after use. No reboot or kernel execution change is needed.

Excluded attempts:

- `baseline-full-p1-qd32-a1`: Insufficient free space for the unique benchmark file: /mnt/wslpart-m6-proxy
- `baseline-full-p3-qd32-a1`: User reported WSL kernel compilation; observed make/bash tree started 2026-10-23T05:47:15+11:00 and overlaps this pair. Exclude the entire pair.

[CSV](winspd-full-baseline-qd32-64-128.csv) · [JSON](winspd-full-baseline-qd32-64-128.json).
Raw measurements: `artifacts/ring-measurements/baseline-full-*`.
Raw fio: `artifacts/m6/fio-raw-baseline-full-*`.

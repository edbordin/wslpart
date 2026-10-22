# QD32 mapping-threshold sweep - 2026-10-23

Release, work items, ordinary IOQ spinlock, preparation/completion claim 32,
ready commits 8/256 KiB, producer/KICK batch 32, eight overlapped backend workers,
guest sync policy, unbuffered source I/O, ring depth 256, 128 buffers and
256 KiB maximum transfer. Extra latency/origin diagnostics are disabled.
All other selected workload settings match the saved full QD32 baseline:
io_uring, direct I/O, 2 GiB unique files, 20-second jobs, 1 MiB sequential and
4 KiB random requests. fsync4k remains serialized at QD1. No new copy-only or
VHDX control was run, as requested.

Thresholds select by logical SRB length, with eligibility checks and bounce
fallback retained. Threshold zero is the historical copying control. The
mapping-aware userspace/ABI differs from that old control; all sweep variants
use the same executable and DLL. Bounce-buffer capacity remains unchanged.

The completed order was 64, 4, 256 KiB. The planned 16 KiB run was cancelled
between measurements at the user's request after observing that every mapped
lease was 256 KiB. The 4/64 KiB results below had already completed; they are
retained as supporting observations, not evidence that lower cutoffs are useful.
256 KiB is the only eligible size observed in this fio profile, not a hard
minimum of the mapping implementation. Higher cutoffs would disable mapping
with the unchanged 256 KiB maximum transfer. Each completed cutoff received one full suite.
Blender and WSL build quiet gates/boundary observations passed. This reduces
known interference; it does not eliminate SSD/cache/thermal/order variability.
The two retained historical QD32 controls remain provisional because earlier
WSL build activity was not ruled out. Their already-excluded third pair is not
used. Deltas below are descriptive, not a paired causal estimate.

## Overview

Sequential rates are MiB/s, random rates are thousands of IOPS, and fsync is
operations/second. Control cells are medians of the two retained old runs.

| Map threshold | Seq WRITE | Seq READ | Random WRITE kIOPS | Random READ kIOPS | fsync/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Copy control (old) | 1,632.6 | 2,679.1 | 151.0 | 123.6 | 206.6 |
| 4 KiB | 2,017.4 | 3,046.4 | 152.3 | 116.8 | 344.8 |
| 64 KiB | 1,929.5 | 3,203.6 | 152.4 | 117.8 | 211.1 |
| 256 KiB | 1,916.6 | 2,897.5 | 153.7 | 125.4 | 632.8 |

## Latency and comparison

Latency is fio completion latency, except fsync4k which uses the fsync latency.
Percentiles are per-run values; control values are medians of per-run percentiles.
Proxy CPU is process-attributed average cores, not driver-specific CPU.

### seqwrite

| Threshold | MiB/s | vs old | Mean us | p95 us | p99 us | Proxy cores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy (old) | 1,632.6 | +0.0% | 19,590.5 | 27,787.3 | 61,079.6 | 0.291 |
| 4 KiB | 2,017.4 | +23.6% | 15,820.3 | 25,296.9 | 46,399.5 | 0.315 |
| 64 KiB | 1,929.5 | +18.2% | 16,536.7 | 25,559.0 | 56,361.0 | 0.356 |
| 256 KiB | 1,916.6 | +17.4% | 16,653.2 | 26,083.3 | 57,409.5 | 0.362 |

### seqread

| Threshold | MiB/s | vs old | Mean us | p95 us | p99 us | Proxy cores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy (old) | 2,679.1 | +0.0% | 12,040.7 | 16,613.4 | 17,924.1 | 0.378 |
| 4 KiB | 3,046.4 | +13.7% | 10,495.3 | 13,303.8 | 14,483.5 | 0.507 |
| 64 KiB | 3,203.6 | +19.6% | 9,979.5 | 12,386.3 | 13,434.9 | 0.452 |
| 256 KiB | 2,897.5 | +8.1% | 11,035.7 | 13,959.2 | 15,007.7 | 0.442 |

### randread4k

| Threshold | IOPS | vs old | Mean us | p95 us | p99 us | Proxy cores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy (old) | 123,605.3 | +0.0% | 256.2 | 340.0 | 415.7 | 3.468 |
| 4 KiB | 116,825.8 | -5.5% | 271.5 | 354.3 | 460.8 | 3.165 |
| 64 KiB | 117,789.6 | -4.7% | 269.2 | 350.2 | 432.1 | 3.251 |
| 256 KiB | 125,409.8 | +1.5% | 252.5 | 333.8 | 415.7 | 3.421 |

### randwrite4k

| Threshold | IOPS | vs old | Mean us | p95 us | p99 us | Proxy cores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy (old) | 151,017.0 | +0.0% | 209.4 | 276.5 | 342.0 | 3.629 |
| 4 KiB | 152,276.7 | +0.8% | 207.6 | 276.5 | 333.8 | 3.786 |
| 64 KiB | 152,445.6 | +0.9% | 207.2 | 276.5 | 346.1 | 3.661 |
| 256 KiB | 153,726.6 | +1.8% | 205.6 | 276.5 | 346.1 | 3.738 |

### fsync4k

| Threshold | fsync/s | vs old | Mean us | p95 us | p99 us | Proxy cores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Copy (old) | 206.6 | +0.0% | 4,718.8 | 6,094.8 | 8,372.2 | 0.127 |
| 4 KiB | 344.8 | +66.9% | 2,773.3 | 5,668.9 | 6,914.0 | 0.166 |
| 64 KiB | 211.1 | +2.2% | 4,612.1 | 5,668.9 | 7,700.5 | 0.130 |
| 256 KiB | 632.8 | +206.2% | 1,437.8 | 2,211.8 | 3,751.9 | 0.266 |

## Mapping and ownership counters

These counters cover the whole session, including warmup and filesystem traffic.
In every run, mapped bytes equal mapped leases multiplied by 262144. Because
each lease is at most 256 KiB, **every mapped lease was exactly 256 KiB**.
No smaller request mapped even with a 4 KiB cutoff. This profile therefore
cannot locate a copy/mapping crossover below 256 KiB, or establish 256 KiB as
a general implementation minimum. It is the only observed eligible size here.

| Threshold | Map attempts | Mapped | Fallback after attempt | Unmapped | Mapped GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4 KiB | 304,116 | 304,116 | 0 | 304,116 | 74.247 |
| 64 KiB | 308,268 | 308,268 | 0 | 308,268 | 75.261 |
| 256 KiB | 289,113 | 289,113 | 0 | 289,113 | 70.584 |

All sessions retired every accepted SRB and mapped lease. Raw run IDs, hashes,
settings, fio JSON checksums and detailed rows are retained in the adjacent JSON.

## Interpretation

With this profile and the unchanged maximum transfer, 256 KiB is a sensible
mapping cutoff: it includes the observed eligible payloads, and lower cutoffs
did not exercise smaller mappings. A cutoff above 256 KiB would disable mapping.
Choosing among higher cutoffs would require changing the maximum transfer and
workload sizes, which would no longer match the saved baseline configuration.

The 256 KiB run measured sequential WRITE/READ rates 17.4%/8.1% above the saved
control medians. Its WRITE p95/p99 were 26.08/57.41 ms versus 27.79/61.08 ms;
READ p95/p99 were 13.96/15.01 ms versus 16.61/17.92 ms. These are observations
against a historical provisional control, not proof of a causal improvement.
Random READ/WRITE rates were within 2% of that control in the 256 KiB run.

Fsync varied substantially between runs despite no mapped 4 KiB leases.
Do not attribute its apparent improvement to direct mapping of those requests.
The earlier lower-cutoff runs mapped the same observed size class, so their
different rates do not establish an optimal threshold.

## CPU interpretation

The counters do not establish a large, consistent CPU saving. At the 256 KiB
cutoff, process-attributed proxy CPU was:

| Sequential workload | Old proxy cores | Mapped proxy cores | Old CPU s/GiB | Mapped CPU s/GiB |
| --- | ---: | ---: | ---: | ---: |
| WRITE | 0.291 | 0.362 | 0.183 | 0.194 |
| READ | 0.378 | 0.442 | 0.145 | 0.156 |

After normalizing by throughput, proxy CPU per GiB increased about 6% for
WRITE and 8% for READ. These process counters do not include all kernel worker
costs. Host-wide total CPU per GiB was about 9% lower for WRITE and 6% higher
for READ; host-wide kernel CPU per GiB was about 17% lower for WRITE and 1%
lower for READ. Those host counters include unrelated activity and cannot
attribute savings to this driver. The historical-control caveat also applies.
The supported conclusion is improved observed sequential throughput/latency,
with mixed CPU efficiency, rather than a proven broad CPU reduction.

Release `.217` and all saved baseline binaries were restored and hash-verified
after the sweep. Its 21 ring tests and FLUSH checks passed; the 07:51:31 local
audit found zero units and no proxy/capture processes. The expected nonzero
outer sweep exit records the deliberate cancellation before the 16 KiB
measurement, not failure of the three completed measurements.

[CSV](winspd-mapping-threshold-qd32.csv) | [JSON](winspd-mapping-threshold-qd32.json).

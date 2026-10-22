# Dedicated ring thread priority — 2026-10-22

Compare StorThreadPriorityNormal (8) with StorThreadPriorityDelayed (12).
Priority 13 and higher are excluded. One preparation thread and two completion
threads run with the same configured priority; ordinary IOQ locking stays
enabled. The SQ producer remains a Storport work item.

Retained 16 ten-second observations; excluded 0 attempts.
ABBA order is 8, 12, 12, 8, with two observations per cell. Direct 4 KiB
random READ runs at QD1, 32 and 128; WRITE runs at QD128. These are screening
observations, not confidence intervals. Blender quiet-gap/interference and
wall-time checks remain enabled. No tracing runs during timed workloads.

Preparation and completion claim caps are 32, ready commits 8/256 KiB, SQ
publication and KICK batches 32. Userspace has eight overlapped workers, ring
depth 256, 128 buffers, maximum transfer 256 KiB and a 256 MiB test file.
Default DPC routing and basic counters remain enabled. Detailed per-stage
timing is disabled. CLOSE records the requested thread priority and captures
verify that configuration; these are not continuous effective-priority traces.

| Workload | QD | Priority | IOPS | Mean us | p95 us | p99 us | Windows CPU % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| randread4k | 1 | 8 | 6,157.58 | 158.80 | 192.51 | 228.35 | 9.04 |
| randread4k | 1 | 12 | 6,763.73 | 144.95 | 192.51 | 289.28 | 13.23 |
| randread4k | 32 | 8 | 129,347.02 | 245.35 | 327.68 | 395.26 | 45.95 |
| randread4k | 32 | 12 | 128,616.59 | 246.71 | 329.73 | 397.31 | 47.41 |
| randread4k | 128 | 8 | 205,704.18 | 619.71 | 913.41 | 1,097.73 | 54.28 |
| randread4k | 128 | 12 | 201,052.95 | 634.07 | 937.98 | 1,105.92 | 53.91 |
| randwrite4k | 128 | 8 | 223,800.63 | 568.92 | 839.68 | 1,019.90 | 56.20 |
| randwrite4k | 128 | 12 | 222,338.17 | 572.67 | 839.68 | 1,024.00 | 56.81 |

Change at priority 12 relative to priority 8:

| Workload | QD | IOPS | Mean | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| randread4k | 1 | +9.8% | -8.7% | +0.0% | +26.7% |
| randread4k | 32 | -0.6% | +0.6% | +0.6% | +0.5% |
| randread4k | 128 | -2.3% | +2.3% | +2.7% | +0.7% |
| randwrite4k | 128 | -0.7% | +0.7% | +0.0% | +0.4% |

Interpretation: there is no consistent quiet-condition latency improvement.
QD1 READ mean latency improves about 9% and throughput about 10%, but p95
is unchanged and p99 is worse, driven by one higher-tail priority-12 run.
QD32 READ p95/p99 change less than 1%. QD128 READ throughput falls about 2%
and p95 rises about 3%; QD128 WRITE p95 is unchanged. Keep priority 8 as the
default, with priority 12 available for controlled follow-up under CPU load.

Priority-8 opening/closing control ranges:

| Workload | QD | IOPS range | p95 us range | p99 us range |
| --- | ---: | ---: | ---: | ---: |
| randread4k | 1 | 6,112.19 to 6,202.98 | 189.44 to 195.58 | 228.35 to 228.35 |
| randread4k | 32 | 127,353.46 to 131,340.57 | 321.54 to 333.82 | 391.17 to 399.36 |
| randread4k | 128 | 203,848.42 to 207,559.94 | 913.41 to 913.41 | 1,089.54 to 1,105.92 |
| randwrite4k | 128 | 221,292.27 to 226,308.99 | 823.30 to 856.06 | 1,003.52 to 1,036.29 |

These quiet-condition measurements do not establish how much higher thread
priority helps under sustained competing CPU load. Two observations per cell
and control drift limit attribution, particularly at low QD.

Individual per-run results, driver hashes, userspace image hashes, stage
histograms, lock waits and batch counters are retained in CSV/JSON. Table
entries are medians of per-run measurements; percentiles are not pooled.
Kernel counters span discovery/setup/cleanup as well as timed fio. Kernel
histogram percentiles are logarithmic upper bounds. Scheduling priority does
not change IRQL or allow these threads to preempt DPCs.

Priority-12 P2/C2 threads pass 70 selected Debug tests and eight parallel
ownership/cancellation/reset/STOP tests. Every Release activation passes 21
tests plus zero-count FLUSH checks. Final installed Release .217 restores
work items, ordinary locking and the default priority selector 8; its final
audit reports no remaining units or proxy/capture processes. No reboot.

[CSV](winspd-ring-thread-priority.csv) · [JSON](winspd-ring-thread-priority.json) ·
[Build selectors](../winspd-ring-worker-execution.md). Raw measurements:
`artifacts/ring-measurements/priority-p*`; signed packages and PDBs:
`artifacts/ring-packages/priority-*`.

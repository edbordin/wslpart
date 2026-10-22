# Queued IOQ spin lock comparison — 2026-10-22

Switch only IOQ metadata acquisition between ordinary and Windows in-stack
queued spin locks. Queue ownership, critical sections, batching and the
separate transport lifetime lock are unchanged. Both builds retain the same
profiling counters. Default remains ordinary locking.

Retained 28 ten-second observations; excluded 0 attempts.
Default preparation/completion work items are compared at QD1, 32 and 128
for direct 4 KiB random READ and WRITE. A second comparison uses one preparation
thread and two completion threads at QD128 READ. Each comparison uses ABBA
ordering: ordinary, queued, queued, ordinary; two observations per cell.
This is a screening comparison, not a confidence interval.

Preparation and completion claim caps remain 32, ready commits 8/256 KiB,
SQ publication and KICK batches 32. Userspace has eight overlapped workers,
ring depth 256, 128 buffers, maximum transfer 256 KiB and a 256 MiB test file.
Default DPC routing and basic counters stay enabled; detailed per-stage
diagnostics and tracing are disabled. Blender quiet-gap/interference gates
and wall-time guards remain active. Other system noise remains possible.

| Workload | QD | Ordinary IOPS | Queued IOPS | Ordinary p99 us | Queued p99 us |
| --- | ---: | ---: | ---: | ---: | ---: |
| randread4k | 1 | 7,025 | 6,132 | 233 | 260 |
| randread4k | 32 | 144,991 | 145,436 | 344 | 350 |
| randread4k | 128 | 181,836 | 179,264 | 1,028 | 1,008 |
| randwrite4k | 1 | 10,027 | 8,303 | 161 | 180 |
| randwrite4k | 32 | 159,333 | 172,128 | 328 | 315 |
| randwrite4k | 128 | 186,780 | 188,676 | 1,051 | 1,020 |

Guest completion latency p95:

| Execution | Workload | QD | Ordinary p95 us | Queued p95 us | Change |
| --- | --- | ---: | ---: | ---: | ---: |
| work items | randread4k | 1 | 160.77 | 172.03 | +7.0% |
| work items | randread4k | 32 | 296.96 | 303.11 | +2.1% |
| work items | randread4k | 128 | 905.21 | 880.64 | -2.7% |
| work items | randwrite4k | 1 | 111.11 | 121.34 | +9.2% |
| work items | randwrite4k | 32 | 280.58 | 270.85 | -3.5% |
| work items | randwrite4k | 128 | 913.41 | 888.83 | -2.7% |
| P1/C2 threads | randread4k | 128 | 1,058.82 | 1,046.53 | -1.2% |

p95 shows the same broad pattern: approximately 3% lower at QD128 with
work items, about 3% lower for QD32 WRITE, and about 1% lower for threaded
QD128 READ. QD32 READ is about 2% higher. Low-QD observations are higher
with queued locking, subject to the control drift discussed below.

QD128 counters and additional thread comparison:

| Execution | Workload | Lock | IOPS | p99 us | Mean lock wait us | Lock wait p99 upper us | Mean lock hold us | Locks/SRB | Windows CPU % |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| work items | randread4k | ordinary | 181,836.37 | 1,028.10 | 0.62 | 6.40 | 0.18 | 7.02 | 44.22 |
| work items | randread4k | queued | 179,263.98 | 1,007.62 | 0.52 | 3.20 | 0.19 | 7.47 | 44.86 |
| work items | randwrite4k | ordinary | 186,779.99 | 1,050.62 | 0.64 | 6.40 | 0.19 | 6.69 | 43.47 |
| work items | randwrite4k | queued | 188,676.23 | 1,019.90 | 0.55 | 3.20 | 0.19 | 6.93 | 44.39 |
| P1/C2 threads | randread4k | ordinary | 183,133.04 | 1,261.57 | 0.88 | 12.80 | 0.21 | 6.64 | 41.40 |
| P1/C2 threads | randread4k | queued | 190,974.65 | 1,253.38 | 0.63 | 3.20 | 0.20 | 7.23 | 41.97 |

Interpretation:

Queued locking reduces measured acquisition contention, with QD32 work-item
mean waits about one-third lower. At QD128, work-item p99 lock-wait upper
bounds fall from 6.4 to 3.2 us; the thread comparison falls from 12.8 to 3.2 us.
These histogram bounds are not precise p99 ratios.

End-to-end improvements are selective. QD32 WRITE throughput rises about 8%
with p99 about 4% lower. QD128 work-item READ throughput is about 1% lower
and WRITE about 1% higher, with p99 about 2–3% lower. The thread comparison
gains about 4% throughput and lowers mean completion latency about 4%, but
p99 changes less than 1%. Windows CPU utilization has no consistent gain.

QD1 queued observations have lower throughput and higher latency, but opening
and closing ordinary controls also drift substantially. Treat this as a
possible low-contention penalty requiring a focused repeat, not an isolated
causal estimate. Keep ordinary locking as the default; the queued selector
is available for further experiments. Reduced contention does not establish
the IOQ lock as the dominant cause of guest tail latency.

Ordinary work-item control ranges (opening and closing passes):

| Workload | QD | IOPS range | p99 us range |
| --- | ---: | ---: | ---: |
| randread4k | 1 | 6,423 to 7,626 | 232 to 234 |
| randread4k | 32 | 140,756 to 149,226 | 330 to 358 |
| randread4k | 128 | 180,631 to 183,041 | 1,020 to 1,036 |
| randwrite4k | 1 | 8,840 to 11,215 | 131 to 191 |
| randwrite4k | 32 | 157,820 to 160,846 | 322 to 334 |
| randwrite4k | 128 | 186,198 to 187,362 | 1,044 to 1,057 |

Control drift, particularly at low QD, limits causal interpretation of small
differences. ABBA ordering balances a simple linear trend but cannot exclude
thermal, power-management or unrelated workload variation.

Entries are medians of per-run values; p99 values are not pooled percentiles.
Kernel histogram percentiles are logarithmic upper bounds. Kernel counters
include discovery/setup/cleanup as well as timed fio. Lock wait also includes
acquisition/IRQL bookkeeping; the instrumentation has its own overhead and
remains identical in both variants. Do not add overlapping stage percentiles.

Correctness gates: 70 selected Debug tests for ordinary work items, queued
work items and queued P2/C2 threads, plus eight targeted parallel ownership,
cancellation, reset and STOP tests for queued threads. Every activated Release
package passes 21 tests plus zero-count FLUSH callback checks.

[CSV](winspd-queued-spin-lock.csv) · [JSON](winspd-queued-spin-lock.json) ·
[Build selectors](../winspd-ring-worker-execution.md). Raw measurements are
under `artifacts/ring-measurements/queued-lock-*`; signed packages, PDBs and
correctness receipts are under `artifacts/ring-packages/queued-*`.

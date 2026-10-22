# Dedicated kernel thread comparison — 2026-10-21

Preparation and completion independently select work items or one dedicated
Storport system thread. Queue ownership, batch limits, the SQ producer and
default Storport DPC routing are identical across variants. Work items remain
the source default; the final installed control also uses work items.

The comparison does not establish a consistent tail-latency benefit from one
dedicated thread per stage. QD128 READ p99 is higher in every thread variant
than the control median, while throughput changes depend on the workload.
Completion-only QD1 READ p99 changes from 187 to 1,778 us on repetition;
both-thread QD1 READ changes from 194 to 226 us. Control variation and the
small sample count limit attribution. Keep work items as the default.

This tests execution context with one owner per stage. It does not test
multiple completion workers and cannot rule out gains from parallelism.

## Measurements

Retained 40 twenty-second workloads; excluded 3 attempts.
READ/WRITE at QD1/4/32/128 have one initial run per configuration. Low-QD READ
with completion-only/both threads is repeated in the follow-up. The work-item
control is repeated at QD1/128 after the three thread variants; any repaired
cells receive an additional control observation. Tables use
medians of per-run results; medians of p99 values are not pooled percentiles.
These are engineering observations, not confidence intervals.

Detailed latency diagnostics are disabled in all variants. Existing lock,
copy and callback instrumentation remains enabled. Settings are direct I/O,
eight overlapped backend workers, ring depth 256, 128 buffers, 256 KiB maximum
transfer and preparation claim limit 32. No WPR tracing runs during timing.

The first morning sweep is provisional and excluded after Blender CPU activity
was observed. This fresh evening sweep waits for Blender CPU to settle before
each workload and records its CPU use across workload/capture. This does not
establish that all unrelated system activity is absent. Kernel/backend totals
span the unit lifetime, including discovery, file preparation and cleanup;
fio latency covers its timed workload window.

| QD | Workload | Work items IOPS | Completion thread | Both threads | Preparation thread |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | READ | 5,888 | 6,378 | 7,133 | 7,170 |
| 1 | WRITE | 10,018 | 9,299 | 9,134 | 11,824 |
| 4 | READ | 23,718 | 24,176 | 25,887 | 23,620 |
| 4 | WRITE | 36,971 | 37,927 | 34,757 | 30,866 |
| 32 | READ | 137,296 | 122,972 | 133,692 | 147,854 |
| 32 | WRITE | 158,167 | 180,703 | 150,937 | 150,291 |
| 128 | READ | 178,671 | 179,782 | 182,886 | 177,612 |
| 128 | WRITE | 184,946 | 185,829 | 189,454 | 190,634 |

Guest p99 completion latency, in microseconds:

| QD | Workload | Work items | Completion thread | Both threads | Preparation thread |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | READ | 221 | 983 | 210 | 224 |
| 1 | WRITE | 127 | 127 | 148 | 116 |
| 4 | READ | 249 | 249 | 237 | 243 |
| 4 | WRITE | 132 | 153 | 146 | 183 |
| 32 | READ | 369 | 408 | 383 | 346 |
| 32 | WRITE | 326 | 322 | 342 | 322 |
| 128 | READ | 1,042 | 1,090 | 1,122 | 1,090 |
| 128 | WRITE | 1,090 | 1,106 | 1,057 | 1,028 |

QD128 stage and CPU measurements:

| Mode | Workload | Mean guest µs | p99.9 guest µs | Windows CPU % | Lock acquisitions/SRB | Lock wait mean µs | Completion batch size | Callback mean µs | CQ→notify p99 upper µs |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Work items | READ | 715.00 | 2,224.12 | 51.89 | 6.84 | 0.84 | 22.20 | 108.21 | 409.60 |
| Work items | WRITE | 689.17 | 2,146.30 | 46.39 | 6.43 | 0.83 | 24.00 | 106.68 | 819.20 |
| Completion thread | READ | 710.12 | 2,965.50 | 42.31 | 6.71 | 0.88 | 19.53 | 98.24 | 409.60 |
| Completion thread | WRITE | 686.41 | 1,449.98 | 44.52 | 6.15 | 0.91 | 21.26 | 95.80 | 819.20 |
| Both threads | READ | 697.74 | 1,499.14 | 56.07 | 7.08 | 0.93 | 12.55 | 60.36 | 409.60 |
| Both threads | WRITE | 673.25 | 4,423.68 | 45.54 | 6.67 | 0.85 | 21.08 | 92.02 | 819.20 |
| Preparation thread | READ | 718.51 | 2,088.96 | 54.18 | 7.05 | 0.89 | 20.95 | 101.25 | 409.60 |
| Preparation thread | WRITE | 668.79 | 3,457.02 | 54.24 | 6.49 | 0.90 | 23.47 | 102.95 | 819.20 |

CQ→notify is a histogram upper bound ending before the final notification call
returns; it is not guest-visible completion latency. Lock wait is per lock
acquisition. Callback duration is per batch and includes any DPC/interrupt
processing before returning. These measurements overlap and are not additive.

At QD128 READ, mean lock wait is 0.84 us with work items and 0.88–0.93 us
with threads: changing execution context does not remove lock contention.
The CQ-to-notification p99 histogram bound stays 409.6 us for READ and
819.2 us for WRITE in every mode. Both-thread READ callbacks get shorter
but also claim fewer completions per callback. These observations do not
support work-item dispatch overhead as the sole cause of guest latency.

The slow completion-only QD1 READ repeat has backend submit-to-IOCP mean
95 us versus 76 us initially, plus increases in some kernel stage bounds.
These unit-lifetime aggregates cannot explain its 1,778 us guest p99
without correlated per-request tracing; do not sum stage percentiles or
attribute the entire outlier to either the backend or kernel scheduling.

## Control variation

| QD | Workload | Control IOPS range | Control p99 µs range |
| ---: | --- | ---: | ---: |
| 1 | READ | 5,389–6,387 | 204–239 |
| 1 | WRITE | 8,757–11,280 | 116–138 |
| 128 | READ | 172,897–184,445 | 1,012–1,073 |
| 128 | WRITE | 180,895–185,523 | 1,028–1,106 |

## Validation and artifacts

All four execution modes passed 70 selected Debug tests each. Fixed both-thread
Debug .110 additionally passed four focused lifecycle tests before the full
suite. Each activated Release package passed 21 tests and the zero-count
FLUSH checks before measurement. The initial .101 cleanup crash and its fix
are documented in [execution notes](../winspd-ring-worker-execution.md).

[CSV](winspd-ring-threads.csv) and [JSON](winspd-ring-threads.json) retain
per-run identities, tail latency, counters and backend measurements. Raw
captures and ambient CPU observations are under
`artifacts/ring-measurements/thread-clean-*`. Driver/PDB packages and test
receipts are under `artifacts/ring-packages/threads-*`.

Thread modes use normal Storport thread priority without hard affinity;
work-item thread priority and placement are managed by Windows. This tests
the execution policy as implemented, not an isolated dispatch-only cost.

Final installed control: Release `1.0.26293.129`, preparation/completion
selectors both zero. SHA-256:
`A5A1431F1617BB839C912F192EA7837C0C5D59FAB02DEEC069CBE869E8DDBB96`.
Its 21 Release tests passed. Final audit found zero units and zero
proxy/capture processes; the temporary awake hold was released.

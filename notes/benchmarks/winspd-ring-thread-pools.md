# Parallel kernel worker comparison — 2026-10-21

Preparation/completion pool sizes are independently configurable from one to four.
The SQ producer remains a single Storport work item, and KICK remains the only CQ
consumer. Work items remain the default. Pn/Cm means n preparation and m completion
threads, at normal Storport priority without hard affinity.

Retained 53 twenty-second workload observations; excluded 5 attempts.
This is an engineering comparison on a shared workstation. Blender CPU is checked
before timing and measured across each workload/capture interval; observations above
0.1 CPU core are excluded. This does not rule out other system activity.

Controls and candidates use the same concurrency-safe instrumentation and userspace
OPEN fix. These results must not be pooled with the earlier single-writer-instrumentation
comparison. Driver hashes, proxy executable/DLL hashes and exact worker counts are
retained in the raw receipts. Default DPC routing, direct I/O, eight overlapped backend
workers, claim limit 32, 256 KiB maximum transfer, ring depth 256 and 128 buffers are
fixed. Detailed latency diagnostics and WPR tracing are disabled during timing.

DLL rebuilds can change COFF/debug timestamps and CodeView PDB age. The normalized
PE hash ignores only those fields; code, data, resources, layout and PDB GUID/path
remain included. Full DLL hashes are also retained. Earlier receipts were enriched
from matching archived DLLs after verifying their original full-file hashes; timing
and I/O values were unchanged. A changed normalized image rejects the comparison.

The main sweep covers READ/WRITE at QD1/32/128. Thread variants repeat QD1 and QD128
READ; the final work-item control repeats QD1/128 READ/WRITE. Tables use medians of
per-run measurements, including p99; these are not pooled percentiles or confidence
intervals. Individual observations remain in the linked dataset.

## Findings

This wake-all pool implementation does not establish an overall latency gain. At
QD128 READ, median p99 completion latency is 1,004 us for work items, 1,067 us
for P1/C1, 1,130 us for P1/C2, 1,245 us for P1/C4, 1,352 us for P2/C2 and
1,696 us for P4/C4. Keep work items as the default.

Extra preparation workers fragment claims and introduce unsuccessful wakeups.
At QD32 READ, P4/C4 averages 1.04 requests per preparation claim and
2.82 empty preparation claims per accepted SRB. Metadata-lock acquisitions
increase from 8.17 to 18.00 per accepted SRB. Ownership overlap is real, but
batching efficiency and lock contention get worse. The results apply to this
scheduling policy with shared atomic instrumentation and 4 KiB workloads; they
do not establish that all forms of parallel completion processing are ineffective.
Individual stage aggregates do not prove the cause of every guest tail outlier.

## IOPS

| QD | Workload | Work items | P1/C1 | P1/C2 | P1/C4 | P2/C2 | P4/C4 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | READ | 6,539 | 6,112 | 6,251 | 6,954 | 6,692 | 5,319 |
| 1 | WRITE | 9,586 | 9,235 | 11,200 | 11,311 | 8,548 | 7,909 |
| 32 | READ | 133,575 | 131,057 | 139,957 | 123,526 | 120,933 | 81,912 |
| 32 | WRITE | 154,282 | 154,602 | 157,003 | 141,660 | 132,663 | 75,054 |
| 128 | READ | 184,680 | 183,661 | 192,828 | 181,143 | 161,273 | 119,929 |
| 128 | WRITE | 196,907 | 190,224 | 192,395 | 206,712 | 180,146 | 105,666 |

## Guest p99 completion latency (microseconds)

| QD | Workload | Work items | P1/C1 | P1/C2 | P1/C4 | P2/C2 | P4/C4 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | READ | 215 | 258 | 234 | 216 | 203 | 238 |
| 1 | WRITE | 128 | 171 | 119 | 134 | 140 | 157 |
| 32 | READ | 367 | 379 | 367 | 399 | 428 | 578 |
| 32 | WRITE | 326 | 350 | 354 | 371 | 383 | 651 |
| 128 | READ | 1,004 | 1,067 | 1,130 | 1,245 | 1,352 | 1,696 |
| 128 | WRITE | 905 | 1,057 | 1,303 | 987 | 1,221 | 1,794 |

## Control variation

| QD | Workload | IOPS range | Guest p99 us range |
| ---: | --- | ---: | ---: |
| 1 | READ | 6,275 to 6,804 | 214 to 216 |
| 1 | WRITE | 8,533 to 10,639 | 114 to 142 |
| 32 | READ | 121,198 to 145,952 | 342 to 391 |
| 32 | WRITE | 154,282 to 154,282 | 326 to 326 |
| 128 | READ | 182,590 to 186,447 | 954 to 1,044 |
| 128 | WRITE | 192,779 to 197,053 | 897 to 995 |

## QD128 stage measurements

| Mode | Workload | Windows CPU % | Mean lock wait us | Completion batch | Callback mean us | CQ→notify p99 upper us | Peak preparation/completion owned batches |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Work items | READ | 54.83 | 0.67 | 23.52 | 112.30 | 819.20 | 1 / 1 |
| Work items | WRITE | 56.07 | 0.70 | 24.80 | 109.30 | 819.20 | 1 / 1 |
| P1/C1 | READ | 51.41 | 0.76 | 16.95 | 80.56 | 409.60 | 1 / 1 |
| P1/C1 | WRITE | 44.96 | 0.78 | 21.67 | 95.94 | 819.20 | 1 / 1 |
| P1/C2 | READ | 50.07 | 1.02 | 6.71 | 24.81 | 409.60 | 1 / 2 |
| P1/C2 | WRITE | 43.19 | 0.93 | 11.89 | 34.27 | 409.60 | 1 / 2 |
| P1/C4 | READ | 51.43 | 1.19 | 7.35 | 14.49 | 409.60 | 1 / 4 |
| P1/C4 | WRITE | 61.40 | 1.49 | 8.54 | 15.89 | 409.60 | 1 / 4 |
| P2/C2 | READ | 54.38 | 1.79 | 5.87 | 24.96 | 409.60 | 2 / 2 |
| P2/C2 | WRITE | 56.89 | 1.97 | 8.00 | 30.15 | 409.60 | 2 / 2 |
| P4/C4 | READ | 59.95 | 3.48 | 6.45 | 19.25 | 307.20 | 4 / 4 |
| P4/C4 | WRITE | 61.32 | 4.26 | 6.73 | 20.47 | 409.60 | 4 / 4 |

QD128 READ stage p99 histogram upper bounds (microseconds):

| Mode | Pending to preparing | Preparing to ready | Ready to SQ | CQ to notify | Lock wait | Backend submit to IOCP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Work items | 25.60 | 12.80 | 51.20 | 819.20 | 12.80 | 512.00 |
| P1/C1 | 25.60 | 12.80 | 76.80 | 409.60 | 12.80 | 512.00 |
| P1/C2 | 25.60 | 25.60 | 128.00 | 409.60 | 12.80 | 384.00 |
| P1/C4 | 38.40 | 25.60 | 128.00 | 409.60 | 19.20 | 384.00 |
| P2/C2 | 25.60 | 25.60 | 307.20 | 409.60 | 25.60 | 512.00 |
| P4/C4 | 25.60 | 51.20 | 409.60 | 307.20 | 51.20 | 384.00 |

QD32 READ batching and lock churn:

| Mode | Mean preparation claim | Empty prep claims/SRB | Mean completion claim | Empty completion claims/SRB | Lock acquisitions/SRB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Work items | 1.99 | 0.00 | 6.01 | 0.00 | 8.17 |
| P1/C1 | 1.61 | 0.42 | 4.44 | 0.00 | 8.76 |
| P1/C2 | 1.65 | 0.36 | 4.26 | 0.17 | 8.81 |
| P1/C4 | 1.68 | 0.34 | 4.68 | 0.60 | 10.18 |
| P2/C2 | 1.18 | 1.07 | 3.92 | 0.19 | 11.67 |
| P4/C4 | 1.04 | 2.82 | 4.15 | 0.69 | 18.00 |

Peak ownership includes the notification phase, rather than proving simultaneous CPU
execution. Callback timings are per batch; batch sizes can change. CQ→notify ends
before the final notification call returns. Stage/lock distributions overlap, and
their percentiles cannot be summed to reconstruct guest latency. Shared atomic
instrumentation costs are included; this is not an uninstrumented scaling test.
Kernel/backend counters cover the entire unit lifetime, including discovery/setup/cleanup; fio
latencies cover its timed workload window.

## Validation

Debug 2/2 and 4/4 configurations and the rebuilt work-item control pass 70 selected
regression tests each. Eight additional tests force overlapping owned batches and
cover cancellation, reset and STOP in both stages. Each activated Release package
must pass 21 tests and zero-count FLUSH checks before measurement. No shared-memory
ABI or backend FLUSH implementation change is involved. The tightened tests reset
the overlap event after discovery and verify actual READ payload copying; all eight
pass again at both 2/2 and 4/4. Eleven parser/hash tests pass. A long interruption
occurred after the final timed measurements, during the final validation job; every
retained fio wall time is checked against its runtime, and the final job resumes
through test completion, control restoration and teardown audit.

[CSV](winspd-ring-thread-pools.csv) · [JSON](winspd-ring-thread-pools.json) ·
[Execution and rundown](../winspd-ring-worker-execution.md). Raw captures, timing
receipts and exclusions are under `artifacts/ring-measurements/pool-clean-*`;
matching driver/PDB packages and validation receipts are under
`artifacts/ring-packages/pool-*`.

Final installed Release: `1.0.26293.183`, work items for both stages.
SHA-256: `60A61A10A9A09C2F8235ECC132995E997C922F6E2F149FD6D14A0317CA2D6773`. Its 21 Release tests and the final audit pass;
zero units and zero proxy/capture processes remain. No reboot was performed.

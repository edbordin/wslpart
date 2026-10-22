# Smaller completion claims — 2026-10-22

Short screening comparison of 1 or 2 completion threads with claim caps 1 or 8.
Preparation stays on one thread with claim cap 32; ready commit, SQ publication
and CQ consumption limits remain unchanged. The reference uses one completion
thread with claim cap 32. Default work-item execution remains available.

None of the smaller-claim configurations improves guest p99 in this screening.
Claim 1 loses substantial batching efficiency; with one completion thread,
QD128 lock acquisitions increase from 7.09 to 14.28 per SRB. Two threads with
claim 8 preserve reference throughput and reduce the measured CQ-to-notify
histogram bound, but guest p99 remains higher. These observations do not support
32-slot claims as the main latency limiter in these workloads; they do not rule
out other scheduling policies or isolate downstream OS completion time.

Retained 11 ten-second READ observations; excluded 0 attempts.
Only QD32 and QD128 are tested to limit benchmark time. The reference is measured
at the beginning and repeated at QD128 at the end. Candidate cells have one valid
observation each. This is a screening run, not evidence of a small repeatable gain.
Blender CPU gates and workload wall-time checks remain active; other system noise
is possible. No tracing runs during timing. Direct I/O, eight overlapped backend
workers, ring depth 256, 128 buffers and maximum transfer 256 KiB are fixed.

| Completion threads | Claim cap | QD32 IOPS | QD32 p99 us | QD128 IOPS | QD128 p99 us |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 153,824 | 342 | 183,598 | 1,098 |
| 1 | 1 | 132,183 | 375 | 111,580 | 1,319 |
| 2 | 1 | 130,034 | 387 | 143,720 | 1,368 |
| 1 | 8 | 145,979 | 346 | 169,835 | 1,171 |
| 2 | 8 | 137,386 | 383 | 183,399 | 1,286 |

QD128 stage measurements:

| Threads | Cap | Mean claim | CQ to notify p99 upper us | Mean lock wait us | Locks/SRB | Empty completion claims/SRB | Windows CPU % |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 32 | 21.59 | 819.20 | 0.69 | 7.09 | 0.00 | 42.87 |
| 1 | 1 | 1.00 | 1,638.40 | 0.62 | 14.28 | 0.00 | 44.03 |
| 2 | 1 | 1.00 | 819.20 | 1.02 | 11.24 | 0.01 | 42.34 |
| 1 | 8 | 7.66 | 819.20 | 0.70 | 7.85 | 0.00 | 41.04 |
| 2 | 8 | 5.71 | 409.60 | 0.92 | 6.84 | 0.03 | 39.70 |

QD128 reference range: 183,555 to 183,641 IOPS; p99 1,057 to 1,139 us.

Table entries are medians of per-run measurements; p99 values are not pooled
percentiles. CQ-to-notify ends before notification returns. Kernel counters span
discovery/setup/cleanup as well as timed fio; stage percentiles cannot be added.
The CSV/JSON retain actual cap, thread counts, measured batch sizes, empty claims,
driver hashes and full/normalized userspace DLL hashes.

Both claim caps pass 70 selected Debug tests with two completion threads, plus
four targeted parallel completion tests each, covering copying, cancellation,
reset and STOP. Every activated Release package passes 21 tests and zero-count
FLUSH checks. Eleven parser/hash tests pass.

[CSV](winspd-completion-claims.csv) · [JSON](winspd-completion-claims.json) ·
[Build selectors and rundown](../winspd-ring-worker-execution.md). Raw receipts
are under `artifacts/ring-measurements/claim-short-*`; matching driver/PDB and
test receipts are under `artifacts/ring-packages/claim-*`.

Final installed Release is `1.0.26293.198`, work items for both stages and
completion claim cap 32. SHA-256:
`CF5B44D9E93C61B51536C4A9CFDC3C99F2387527153B57FD5B98A33ADBC746C6`.
Its 21 tests and final audit passed, with zero remaining units or proxy/capture
processes. The temporary awake hold is released; no reboot was performed.

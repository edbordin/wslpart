# Shared-ring latency attribution - 2026-10-20

The later [DPC-routing comparison](winspd-ring-dpc-comparison.md) tests deferring
Storport completion processing toward the originating/current CPU. It retains
separate post-render controls and current installation details; the measurements
below describe the earlier default-policy investigation.

The CQ path contributes materially to high-depth latency. The measurements point primarily to serialized completion/notification work, rather than slow payload copying, SQ-full backpressure or a general worker-pool dispatch delay. This identifies a target for further profiling; it does not establish that all guest latency originates in WinSpd or that a scheduling change is already proven safe/faster.

Increasing FIFO capacity and increasing submitted concurrency are different changes. Ring depth stayed 256 and payload buffers stayed 128 in this investigation; only application outstanding depth changed. A larger FIFO does not by itself create a fixed latency penalty. More work can, however, wait behind the finite service rate of the completion path, which is what these measurements show.

## Instrumentation and validation

Optional kernel instrumentation is enabled by building `winspd_sys.vcxproj` with `/p:RingLatencyDiagnostics=1`; its default is zero. It adds fixed per-unit histograms and exact count/total/maximum measurements, without per-request allocation, logging or shared SQ/CQ ABI changes. Kernel timing is QPC wall time, not thread CPU time.

Measured boundaries:

- Accepted/pending to preparation claim, claim to ready, ready to SQ publication, and publication to validated CQ acceptance.
- CQ acceptance to completion claim; claim to each completion callback; callback service including READ copy; service end to batch retirement; retirement to each Storport notification; and notification-call duration.
- Initial worker queue attempt to callback entry for preparation, publication and completion. This includes any BUSY retry handoff, rather than resetting the clock on retry.
- CQ enqueue/claim/retire metadata-lock acquisition, KICK duration/overlap, enqueue-sampled completed-list backlog and sampled shared CQ depth.
- Accepted logical SRB to the start of its final notification, retaining the first accepted timestamp across chunk continuations. Detached retirement timings are copied to worker-owned storage before slots/SRBs can be reused.

The backend's optional `--io-stats` now gives exact totals and logarithmic histograms for Windows I/O submission to IOCP handling. This includes IOCP handling delay and must not be called pure device service time. It does not change backend I/O or flushing behavior.

The instrumented Debug build passed 70 selected tests, including cancellation/reset/rundown races and the common legacy lifecycle case. Instrumented and disabled Release builds each passed all 21 applicable tests plus repeated zero-count FLUSH regressions. Five parser tests cover units, zero samples, mismatched counts/clocks and incomplete extended captures.

## Isolated measurements

There are 21 accepted twenty-second, direct 4 KiB sessions: nine with diagnostics and twelve controls. Each runs only READ or WRITE at QD1, 32 or 128, with preparation claim 32, independent ready commit 8, completion claim 32, eight backend workers, ring depth 256 and 128 payload buffers. Kernel diagnostics still include filesystem setup/teardown, but no longer mix three timed workloads in one histogram.

All included runs fully retired accepted SRBs, left active/fence and diagnostic completion counts zero, and reported zero copy-budget violations. The component totals reconcile with the measured accepted-to-notification lifetime to floating-point precision; percentiles are never added together. One run had 18,828 seconds wall time versus a 20-second fio runtime and was excluded/repeated. An intermediate retry was rejected before I/O because the driver had already changed. The new wall-time guard and the raw exclusion reasons are retained in [JSON](winspd-ring-latency.json); raw values are also in [CSV](winspd-ring-latency.csv).

The table selects the later valid repetition for QD32/128 and the single QD1 run. Values are microseconds per logical SRB, normalized from exact totals. These are local engineering samples, not confidence intervals.

| QD | Workload | Pending + preparation + ready | SQ publication to CQ acceptance | CQ acceptance to notification | Tracked kernel lifetime | Fio mean latency |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | randread4k | 7.8 | 138.1 | 5.1 | 150.9 | 161.8 |
| 1 | randwrite4k | 7.9 | 72.3 | 4.6 | 84.9 | 112.0 |
| 32 | randread4k | 11.9 | 143.4 | 37.8 | 193.2 | 257.7 |
| 32 | randwrite4k | 11.8 | 79.0 | 50.8 | 141.5 | 212.0 |
| 128 | randread4k | 15.8 | 177.3 | 238.2 | 431.2 | 769.5 |
| 128 | randwrite4k | 16.9 | 124.3 | 210.9 | 352.1 | 735.2 |

### What happens after CQ acceptance at QD128

| Component | READ mean us | WRITE mean us |
| --- | ---: | ---: |
| Wait in completed FIFO before claim | 158.56 | 143.60 |
| Wait behind earlier callbacks in claimed batch | 7.62 | 3.83 |
| Completion service / payload copy | 0.34 | 0.09 |
| Wait for remaining batch callbacks and retirement | 7.92 | 3.60 |
| Wait for retirement epilogue and earlier notifications | 63.78 | 59.77 |

The two QD128 repetitions span about 191-238 us READ and 205-211 us WRITE from CQ acceptance to notification. Their p99 logarithmic upper bounds are 410-819 us. Detailed timing adds overhead, but disabled controls also show CQ-to-completion p50 upper bounds of 205 us and p99 upper bounds of 410-819 us; the sustained delay is present without the extra diagnostics.

Completion worker dispatch averages about 9-10 us, with p99 upper bounds of 26-51 us. CQ enqueue/claim/retire metadata-lock acquisition averages about 0.7-1.9 us. KICK overlap counts are zero. Neither dispatch wait nor spinlock wait accounts for most of the mean CQ delay. BUSY deferrals occur frequently on callback continuations; they alone do not prove global worker-pool starvation, since requeuing the same reusable item before its previous callback returns can produce BUSY.

The completion worker claims about 22-26 requests per nonempty batch at QD128. Its work section averages about 112-134 us. Calls to `SpdSrbComplete`, whose Release implementation sets status and calls `StorPortNotification(RequestComplete)`, account for about 81-87% of that section's wall time. One notification call averages about 4.0-4.3 us. While the worker finishes one batch's notifications, later completed requests remain queued. Within a retired batch, a request also waits for preceding notifications. This is measured serialized service/backlog, not a hypothesis that an empty larger FIFO intrinsically adds latency.

READ completion service averages only 0.34-0.38 us and WRITE 0.09-0.10 us at QD128. Raising/lowering the preparation claim ceiling does not directly change the independent completion batch or remove this notification work.

### Other latency and backpressure

None of the accepted runs records SQ-full or buffer-starvation events. Enqueue-sampled completed-list backlog at QD128 averages about 22-30 entries and reaches 128. These are arrival-sampled depths, not time-weighted occupancy. A zero starvation counter is not proof that every slot was always free; the short measured pending/preparation/ready intervals, compared with the much longer CQ interval, are stronger evidence against preparation capacity being the primary mean-latency cause here.

In the later QD128 runs, backend submit-to-IOCP means are about 118 us READ / 58 us WRITE, while SQ-to-CQ means are 177 / 124 us. SQ-to-CQ also includes userspace dispatch, response publication, KICK and publication epilogue. Those intervals overlap backend timing and cannot be added as independent stages.

There is a substantial uninstrumented part of guest latency at high depth. Fio means are about 770 / 735 us, while accepted-to-notification kernel means are about 431 / 352 us; notification calls themselves add only about 4 us. Guest/VMBus/Windows I/O processing before miniport admission and after RequestComplete are outside this instrumented lifetime. The populations/timing windows also differ slightly due to setup and teardown. Do not label the difference entirely as Storport queueing, or assume CQ optimization will remove all of it. Locating that remainder and distinguishing CPU execution from preemption inside notification calls requires correlated system tracing.

## Controls and interpretation

Controls run with detailed kernel timing compiled out but the same backend binary and optional backend statistics. Matched fixed settings and binary identities are checked by the report script. In the latest QD128 pair, diagnostics-on READ/WRITE throughput is about 3%/6% below the subsequent disabled control. Control runs themselves vary across the afternoon/resume boundary, so this is not a clean estimate of instrumentation overhead. Treat detailed timings as a diagnostic profile rather than replacing the [original performance evaluation](winspd-ring-results.md).

The first follow-up target is the serialized Storport completion/notification path and the Windows-to-guest return path, rather than enlarging the FIFO or tuning preparation claim size. A trace of RequestComplete callers/return processing would distinguish actual CPU service from preemption and deferred work. Smaller completion groups or continued draining within a bounded callback are experiments with competing lock/scheduling costs, not established fixes. Ownership, cancellation and rundown guarantees must remain unchanged in any such experiment.

## Reproduction and final state

Build/sign and activate the desired diagnostic variant, run its correctness gate, then use an elevated shell:

```powershell
scripts/measure-winspd-ring.ps1 -DbgViewCli C:\path\dbgviewcli64a.exe `
  -RunTag latency-on-qd128-randread4k-example -QueueDepth 128 `
  -PreparationBatchSize 32 -RuntimeSeconds 20 -Workloads randread4k `
  -Implementation coalesced -MeasurementPhase quiet -SourceRevision latency-profile `
  -ExpectedDriverHash <SHA256>
python scripts/report-winspd-ring-latency.py artifacts/ring-measurements `
  --output-prefix notes/benchmarks/winspd-ring-latency
```

Driver properties, not application QD, enable the optional kernel diagnostics. Capture starts after fio so the logger does not compete with the measured workload. The parser checks histogram/total count and clock consistency and requires all 21 extended metrics when diagnostics are enabled. Retained timings/sums are QPC wall time; no thread-CPU attribution or end-to-end correlation is claimed.

Normal Release `1.0.26293.85` was installed at this checkpoint with detailed kernel timing disabled, SHA-256 `27F53EA7E6411E869C782C994A08E8F1B6E07DACBEEDA1D6AEBCEBFA01BCD42B`. Diagnostic signed packages (`.80` Debug, `.82`/`.84` Release) and disabled controls (`.81`/`.83`/`.85`) are retained under `artifacts/ring-packages/latency-*`. That audit passed with zero units and zero proxy/capture processes. No reboot or normal scheduling-policy change was performed. See the later DPC-routing report for the current installation. Changes remain uncommitted.

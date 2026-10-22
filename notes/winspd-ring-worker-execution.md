# Selecting ring worker execution

Preparation and completion can independently use the existing reusable Storport
work item or a pool of persistent Storport system threads. Queue membership, slot leases,
cancellation and FLUSH fencing are shared between both implementations. The SQ
producer remains a Storport work item, and KICK remains the only CQ consumer.

| MSBuild property | Preprocessor selector | Default |
| --- | --- | ---: |
| `RingPreparationThread` | `SPD_RING_PREPARATION_THREAD` | 0 |
| `RingCompletionThread` | `SPD_RING_COMPLETION_THREAD` | 0 |
| `RingPreparationThreads` | `SPD_RING_PREPARATION_THREADS` | 1 |
| `RingCompletionThreads` | `SPD_RING_COMPLETION_THREADS` | 1 |
| `RingCompletionClaimLimit` | `SPD_RING_COMPLETION_CLAIM_LIMIT` | 32 |
| `IoqQueuedSpinLock` | `SPD_IOQ_QUEUED_SPIN_LOCK` | 0 |
| `RingThreadPriority` | `SPD_RING_THREAD_PRIORITY` | 8 |

`RingThreadPriority` applies to miniport-created preparation and completion
threads. This experiment accepts only 8 (`StorThreadPriorityNormal`) and 12
(`StorThreadPriorityDelayed`); other values are compile errors. It does not
change Storport work-item priorities, SQ producer execution or DPC priority.
CLOSE records the configured `thread_priority`; measurement capture can require
its exact value. The [priority comparison](benchmarks/winspd-ring-thread-priority.md)
shows no consistent p95/p99 gain under quiet conditions, so the default remains 8.
The final installed Release .217 uses work items and ordinary locking; this
priority selector applies only when dedicated threads are enabled.

`IoqQueuedSpinLock=1` selects Windows in-stack queued spin locks for every IOQ
metadata acquisition; 0 retains ordinary spin locks. Each acquisition owns a
caller-stack `KLOCK_QUEUE_HANDLE` until release. The same IOQ lock is never
accessed with both APIs in a build. This selector covers legacy IOQ operations
as well as ring operations; the separate transport lifetime lock is unchanged.
Critical sections, queue membership, cancellation, FLUSH fencing and rundown
rules remain the same. CLOSE records `ioq_queued_spin_lock`, and measurement
capture can require the exact selector. Both modes retain identical counters.
The [queued-lock comparison](benchmarks/winspd-queued-spin-lock.md) measures
both modes with work items and P1/C2 threads. Contention drops, but guest p99
improvements are small or inconsistent. The final installed Release .211 uses
ordinary locking, work items and completion cap 32.

For each singular selector, 0 chooses the work item and 1 chooses the thread pool.
Other values are compile errors. Use both properties explicitly for reproducible
builds:

```powershell
msbuild third_party/winspd/build/VStudio/winspd_sys.vcxproj /t:Rebuild /p:Configuration=Release /p:Platform=ARM64 /p:RingPreparationThread=0 /p:RingCompletionThread=1
```

This selects a preparation work item and a dedicated completion thread. The
four supported combinations are 0/0, 0/1, 1/0 and 1/1. Work items remain the
default comparison control. Enabling either thread raises this driver's SDK
target to `NTDDI_WIN10_FE`, required for the Storport thread APIs; disabled builds
retain their previous target. Thread creation failure fails OPEN with cleanup;
there is no silent fallback to a different execution mode.

Each enabled stage creates one to four threads per open ring, selected by its
plural `Threads` property. Counts are ignored when the corresponding stage uses
work items. For example, add `/p:RingPreparationThread=1
/p:RingCompletionThread=1 /p:RingPreparationThreads=2
/p:RingCompletionThreads=4` for two preparation and four completion threads.
Each thread uses
`StorPortCreateSystemThread` at the selected Normal (8) or Delayed (12) priority,
without hard CPU
affinity. Storport limits miniport-created threads per adapter to the logical
processor count; multiple storage units share that limit. A partial pool creation
failure joins every thread already created and fails OPEN.

Completion claim size is independent of preparation and transport batching.
`RingCompletionClaimLimit` accepts 1 through 32 and bounds the slots owned by
one completion worker per batch. CQ consumption remains batched at 32; SQ
publication and preparation limits are unchanged. CLOSE logs the configured
`completion_claim_limit`, and measurement capture can require its exact value.
The [short smaller-claim comparison](benchmarks/winspd-completion-claims.md)
tests caps 1/8 with one/two completion threads. Neither cap improves guest p99
in that screen. The final installed Release .198 retains work items and cap 32.

Work-item mode retains the existing stage ACTIVE/RERUN state machine. Thread
mode gives each thread its own ACTIVE/RERUN state, auto-reset wake event and
per-activation storage-unit/ring-call references. Scheduling wakes idle threads
and marks running threads for a queue recheck. Workers claim disjoint batches
under the IOQ lock, then copy and complete outside it. Each thread drains its
continuations directly without returning through the system work-item pool.
Idle/blocked stages sleep until an authoritative state transition schedules work.
No polling, spin waiting for payload availability, or additional queue is added.

Preparation retains its independent claim/commit limits and soft per-callback
time budget. Claimed work finishes before the callback returns. The dedicated
thread can start another callback immediately when work remains; it remains
preemptible by Windows at PASSIVE_LEVEL. Completion retains its 32-slot batch.

The thread's owner holds an additional storage-unit reference from creation until
join. Before CREATE returns to OPEN, the start routine references its actual
thread object and signals that initialization finished. Threads remain asleep
until their resources are committed to the ring. Failed OPEN stops and joins its
private threads before freeing resources.

STOP first closes admission/publication through existing terminal reset and waits
for active ring calls. Dormant thread contexts can remain until CLOSE. CLOSE
drains active callbacks, signals each thread to exit, waits on its actual thread
object, and releases its persistent storage-unit reference. This joins actual
termination, rather than relying on a final callback event. Shared mapping, slot
table and diagnostic resources are freed only afterward. The existing trusted
userspace quiescence contract remains required for published buffers.

`SharedRing execution preparation_thread=... completion_thread=...
preparation_threads=... completion_threads=... preparation_parallel=...
completion_parallel=...`
is logged during CLOSE. The metrics parser retains this identity, and benchmark
capture can require the expected selectors alongside the driver hash and routing
flags and exact pool sizes. The parallel fields report the peak number of
simultaneously owned nonempty batches, including final notifications. Histogram,
latency and batch-count updates now support concurrent writers. Fresh controls
must use this same instrumentation, rather than reusing old single-writer runs.
Ordinary benchmark comparisons use detailed latency diagnostics disabled;
basic lock/copy/callback instrumentation remains present in every variant.

The optional Debug tests `+ring_multi_prepare*` and `+ring_multi_completion*`
require at least two threads in the corresponding stage. They hold one worker
at a payload-copy barrier, require a second nonempty batch to own separate slots,
and cover normal retirement, cancellation, reset and STOP. Use the `+` prefix
to select optional tests explicitly. The normal `ioctl_ring_*` suite remains
applicable to work items and all supported pool counts.

Userspace OPEN validation permits an initial SQ backlog bounded by queue depth.
Discovery SRBs may be published between kernel OPEN commit and the caller's
return, especially with immediately runnable threads. The userspace SQ head and
both completion indices must still be untouched. Requiring the initial SQ tail
to be zero incorrectly rejects a correctly established transport.

## Crash during initial validation

The initial both-thread Debug build, revision 101, crashed in the CLOSE performed
by `ioctl_ring_zero_count_flush10_test`. Thread mode correctly omitted retry
work-item allocation, but the old CLOSE code unconditionally called
`IoFreeWorkItem` on the null completion retry item. Preparation had the same
latent cleanup defect. The dump resolves to `nt!IoFreeWorkItem` with a null first
argument, called from `SpdStorageUnitRingClose`.

Both frees now check for allocation, and all other allocation/free pairs were
audited. OPEN cleanup already guarded these optional items. The failed image was
removed and the previously validated Release revision 100 restored and retested
before the fixed thread build was activated. Fixed both-thread revision 110 passed
four focused lifecycle tests followed by all 70 selected Debug tests. Raw dump,
matching binary/PDB, debugger analysis and test receipts are retained under
`artifacts/thread-crash` and `artifacts/ring-packages/threads-Debug-*`.

All four execution modes subsequently passed 70 selected Debug tests each.
The [Release comparison](benchmarks/winspd-ring-threads.md) retains 40 workloads
and excludes three attempts with observed Blender CPU interference. Every
activated Release package passed 21 tests. One dedicated thread per stage did
not demonstrate a consistent tail-latency improvement; work items remain the
default and installed configuration. Final Release `1.0.26293.129` passed its
tests and teardown audit with no remaining units or proxy/capture processes.
That comparison predates the multiple-worker implementation and does not measure
pool scaling. The [parallel-worker comparison](benchmarks/winspd-ring-thread-pools.md)
retains 53 measurements across work items, 1/1, 1/2, 1/4, 2/2 and 4/4. Larger
wake-all pools increase empty claims and lock churn, without an overall latency
gain. Work items remain the default and installed configuration (Release .183).
The tightened ownership tests pass with two and four threads per stage; all
70 selected Debug regressions pass in 2/2, 4/4 and work-item configurations.

See [Storport thread creation](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/nf-storport-storportcreatesystemthread)
and [thread termination](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/nf-storport-storportterminatesystemthread)
for the API contract and adapter thread limit.

# WinSpd shared-memory transport implementation plan

## Purpose and baseline

Establish independently auditable ownership and lifetime semantics, then measure
whether batching and worker separation improve throughput without unacceptable
latency or lock contention.

This plan consolidates the original nine-patch proposal and the subsequent design
review. It is an implementation plan, not a report that the refactor is complete.

Execution status and validation receipts are summarized in the
[implementation progress](winspd-shared-memory-transport-implementation-progress.md).
The [final-source evaluation](benchmarks/winspd-ring-results.md) records passing
functional gates and the remaining performance acceptance questions.

Baseline heads, verified locally during review:

- WinSpd: [`30649abb3f3c7ffdb1d24a2442e8b61149ca47c5`](https://github.com/edbordin/WinSpd/tree/30649abb3f3c7ffdb1d24a2442e8b61149ca47c5)
- WslPart: [`cb3414c5b86aae1182ae055fce2b9986be220060`](https://github.com/edbordin/WslPart/tree/cb3414c5b86aae1182ae055fce2b9986be220060)

WinSpd lives in `third_party/winspd`; WinSpd paths below are relative to that
repository. Preserve the legacy transaction path's structures and behavior.
Keep the shared SQ/CQ ABI, userspace dispatcher protocol, and existing
`RING_WAIT`/`RING_KICK` transport. Preserve WslPart's write gate and existing
`FlushFileBuffers()` backend operation.

## Agreed architecture

```text
Storport HwStartIo
        |
Accept SRB into linked pending FIFO
        |
Batch claim SRBs and matching slots [IOQ metadata lock]
        |
Preparation Storport work item: WRITE/UNMAP copies outside lock
        |
Batch commit to linked ready FIFO [metadata lock]
        |
Existing single producer Storport work item
        |
Drain ready slots and publish shared SQ [metadata lock]
        |
WslPart userspace -> shared CQ -> RING_KICK
        |
Copy descriptors, validate, enqueue completed slots [metadata lock]
        |
Completion Storport work item: READ copies outside lock
        |
Batch retire SRBs and release slots [metadata lock]
        |
SpdSrbComplete outside lock
```

Use one reusable preparation work item, the existing producer work item, and one
reusable completion work item. Each uses an IDLE/ACTIVE/RERUN scheduling mechanism
and holds a storage-unit lifetime reference until its final callback or queued
continuation finishes. Ownership must remain independent of execution context.

Do not introduce dedicated kernel threads, a DPC producer, lock-free internal
queues, per-SRB work-item allocations, multiple preparation/completion workers,
or an ordered-tag/epoch scheduler.

### Scheduling prerequisite found during implementation

Runtime validation on the target machine found that the existing producer's
continuation requeue can return `STOR_STATUS_BUSY` while its Storport callback is
still executing. Treating this as a transport failure prevents even ordinary disk
discovery. New stages must not copy that failure handling unchanged.

Retain the Storport producer and its IDLE/ACTIVE/RERUN authority. Preallocate one
device `IO_WORKITEM` for scheduling handoff when the Storport handle remains busy.
The helper only retries queueing the producer; it does not prepare requests,
publish SQ entries, consume CQ entries, or copy payloads. Each helper invocation
makes one queue attempt and returns or queues a continuation, without a busy-wait.
Do not use this retry path for SQ capacity, free-slot exhaustion, or FLUSH fences.

The helper holds its own storage-unit/callback reference in addition to the
producer state's reference. Transfer the producer reference only on a successful
handoff; preserve references across queued retries; include the helper in STOP and
CLOSE rundown. Add a BUSY-deferral counter and measure scheduling overhead.
Preparation and completion scheduling must likewise handle an occupied Storport
handle safely, with execution authority still restricted to one worker per stage.

API basis: [StorPortQueueWorkItem return values](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/nf-storport-storportqueueworkitem),
[device work-item queueing and reuse](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/system-worker-threads),
and [IoFreeWorkItem lifetime rules](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iofreeworkitem).

## Mandatory ownership invariants

`SPD_IOQ::SpinLock` is the single authority for SRB/slot lifecycle, queue membership,
fence state, and the decision to stop admission, claiming, or publication.
Retain the separate transport lifetime lock for session and WAIT-IRP rundown;
avoid nested acquisition of these locks.

Keep the intrusive SRB `PendingList`. Allocate a fixed table of `BufferCount`
slots, each permanently corresponding to one shared payload buffer, and add:

```c
LIST_ENTRY FreeSlots;
LIST_ENTRY ReadySlots;
LIST_ENTRY CompletedSlots;

typedef struct _SPD_WORK_SLOT
{
    LIST_ENTRY ListEntry;
    SPD_SRB_EXTENSION *Srb;
    UINT64 RequestId;
    SPD_SLOT_STATE State;
    BOOLEAN CancelRequested;
    SPD_IOCTL_TRANSACT_REQ Request;
    SPD_IOCTL_TRANSACT_RSP Response;
    UINT32 DataLength;
} SPD_WORK_SLOT;
```

The table index identifies the buffer; buffers are never allocated independently
of their slots. A FLUSH still leases a slot for transaction ownership but retains
the existing no-payload buffer reference on the wire.

| Slot state | Exclusive owner |
| --- | --- |
| Free | Free list |
| Preparing | Preparation work item |
| Ready | Ready list |
| InFlight | Published userspace transaction |
| CompletionQueued | Completed list |
| Completing | Completion work item |

Published slots in a terminal session remain quarantined until safe reclamation.
Represent this condition explicitly in lifecycle bookkeeping; never label them
Free simply because their SRB has been logically retired.

Extend `SPD_SRB_EXTENSION` with authoritative lifecycle state, current slot
index/pointer, cancellation state, and `ExecutionStarted` or equivalent. Clear
slot-to-SRB references before returning an SRB to Storport. Rundown accounting
must remain valid without dereferencing retired SRB extensions.

- Every slot transition and list mutation occurs under the metadata lock.
- Free, ready, and completed FIFO operations are O(1).
- Preparation/completion workers claim and commit groups under the lock.
- WRITE/UNMAP and READ payload copies occur outside the lock.
- No `SpdSrbComplete()` call occurs while holding the IOQ metadata lock.
- The existing producer alone updates SQ tail; KICK alone consumes CQ and updates
  CQ head.
- A buffer remains unavailable until userspace has finished with it and kernel
  completion copying has ended, or terminal rundown establishes both conditions.
- Every accepted SRB receives exactly one final completion.
- Cancellation and reset support accompany every newly introduced state.

## Request identity and CQ validation

Replace pointer-based shared-memory `Request.Hint` with an opaque slot token:

```text
RequestId = (Generation << 16) | SlotIndex
```

The current maximum of 65,536 slots leaves 48 generation bits. Increment the
generation on every lease, including each multichunk continuation, and reject
exhaustion rather than wrapping. Ensure no token collision within any session
that can receive an old CQ response. CLOSE is terminal for the storage unit;
reset must not create a resumable generation of the same ring session.

KICK copies each shared descriptor into kernel-owned memory before validation.
Under the metadata lock, validate index bounds, generation, InFlight state,
operation kind, buffer ID/no-buffer convention, and expected data length before
changing ownership. Lookup must be O(1); a stale or duplicate response must never
reach an SRB that has retired or been reused.

Advance CQ head only for the validated prefix. An unexpected malformed, duplicate,
or stale CQ entry while running fails and terminalises the transport. Do not
recycle the implicated slot or any other published slot whose ownership remains
uncertain. Wake waiters so userspace can enter its shutdown path.

Expected rejection of KICK after STOP is terminal rundown behavior, not a new
protocol failure. Once terminal, do not resume CQ consumption to reclaim slots;
retain them until safe rundown.

## FLUSH scheduling fence

Use an in-queue fence, not an admission barrier. Continue accepting later SRBs
into the pending FIFO with `SRB_STATUS_PENDING`; ordinary FLUSH ordering does not
return BUSY. Stopped/failed admission and other rejection paths must still return
the appropriate status without taking ownership of rejected SRBs.

Maintain `ActiveSrbs` for non-FLUSH logical SRBs and a separate
`FlushInProgress` fence under the metadata lock:

| Event | Required behavior |
| --- | --- |
| First claim of a non-FLUSH SRB | Set ExecutionStarted; increment ActiveSrbs |
| Multichunk continuation | Preserve ExecutionStarted and active count |
| Final non-FLUSH retirement | Decrement ActiveSrbs exactly once |
| First FLUSH encountered while claiming | End the claim batch before FLUSH; claim no later request |
| FLUSH at pending FIFO head | Claim only when ActiveSrbs is zero |
| FLUSH claim | Set FlushInProgress; do not count FLUSH in ActiveSrbs |
| FLUSH in progress | Claim no following SRB |
| FLUSH retirement | Clear fence and wake preparation if session is running |

Reinsert an already active multichunk continuation at the pending FIFO head.
It remains eligible while a pending FLUSH waits for earlier work. This prevents
FLUSH overtaking unfinished chunks and avoids a fence deadlock. Consecutive
FLUSH requests follow the same claim rule.

A pending FLUSH may be cancelled and unlinked normally. An unpublished claimed
FLUSH may be removed once worker ownership is resolved. A published cancelled
FLUSH retains its fence until validated completion or session quiescence. Fence
bookkeeping must not retain a pointer to a retired SRB. Fence release during
terminal rundown must never restart preparation or publication.

Forward zero-count SYNCHRONIZE CACHE(10/16), including LBA zero, to the backend.
Keep zero-length READ/WRITE behavior separate and validate FLUSH ranges according
to SCSI semantics. Handle `SRB_FUNCTION_FLUSH` and `SRB_FUNCTION_SHUTDOWN` explicitly
without assuming a CDB, a preceding cache flush, or that userspace is already gone.

## Cancellation, terminal reset, and rundown

Distinguish logical cancellation from physical reclamation:

| State | Ordinary cancellation |
| --- | --- |
| Pending | O(1) unlink and retire |
| Preparing | Flag cancellation; preparation owner resolves it |
| Ready | O(1) unlink, release unpublished slot, retire |
| InFlight | Do not reclaim payload; ordinary abort may fail |
| CompletionQueued | Unlink and retire safely, or defer to completion worker |
| Completing | Flag cancellation; completion owner resolves it |

For a published FLUSH, preserve its ordering fence as described above. A cancelled
completion must not accidentally create a multichunk continuation.

Reset of a running ring session is terminal; there is no reset-and-resume path in
this iteration. Reset/STOP/failure must atomically prevent admission, new claims,
and SQ publication, mark outstanding SRBs for abort/reset, and wake WAIT callers.
Worker-owned callbacks resolve their ownership before retirement. Published slots
remain quarantined until safe reclamation, even if logical SRBs retire earlier.
Legacy-path reset behavior remains unchanged.

Three distinct conditions must be tracked:

| Condition | Guarantee |
| --- | --- |
| Kernel quiesced | No preparation, producer, completion, or KICK callback can access ring state; no queued continuation can later do so |
| Userspace quiesced | No callback, dispatcher, or outstanding response-copy operation can access shared buffers |
| Session terminal | No further publications, CQ consumption, or slot reuse is allowed |

Normal shutdown contract:

```text
RING_STOP
  -> mark session Stopping/terminal; prevent claims/publication; wake WAIT
  -> userspace dispatcher drains/stops
  -> userspace joins workers and waits for outstanding response copies
  -> userspace issues terminal RING_CLOSE
  -> kernel finishes callback/work-item rundown
  -> reclaim quarantined slots and release shared-memory resources
```

STOP is not proof of userspace quiescence. It may wait for kernel activity, but
must leave published payload storage valid while userspace stops and joins.
CLOSE is a cooperative assertion of userspace quiescence. For the trusted WslPart
backend, verify that every normal CLOSE path follows worker joins and response-copy
rundown. Do not unmap or free slot metadata until kernel rundown also completes.

Bind ring controls to the referenced file object used for OPEN, as well as the
authorized process. Duplicated handles for that file object identify the same
session; a separately opened adapter handle must not STOP, CLOSE, WAIT or KICK it.
Keep this identity through final unit deletion so an old handle cannot affect a
new session at a reused BTL address, even if generation values restart.

Forced unprovision logically removes the unit but reserves its BTL and GUID until
physical rundown. A separate retiring-unit lookup keeps cooperative CLOSE
reachable while normal discovery and new I/O no longer find that unit. Running
in the mapping's process is not proof of callback quiescence. Defer reclamation
until CLOSE completes or the referenced process becomes signaled. If CLOSE has
already completed, unprovision can release the reservation synchronously.

For abnormal termination, hold a reference to the owner process object, not just
its PID, and confirm process termination before treating userspace as quiescent.
Audit the existing owner-process-termination path and test. The contract assumes
no additional process can access the mapping; permitted additional mappings would
require their own lifetime tracking.

This cooperative contract does not independently prove that arbitrary backend
threads stopped. Hardening against a malicious backend would require enforced
mapping revocation or equivalent isolation and is outside this iteration.

## Patch sequence and acceptance gates

Each patch must remain buildable and include correctness coverage for the states
it introduces. Do not defer safe cancellation, reset, or teardown to patch 8.

### Patch 1: correct FLUSH forwarding

Files: `src/sys/scsi.c`, relevant `src/sys/io.c` handling, SCSI/ring tests.

- Remove the zero-count SYNCHRONIZE CACHE shortcut while preserving zero-length
  READ/WRITE handling.
- Validate FLUSH ranges, including zero count and zero/nonzero LBA cases.
- Test that valid zero-count SYNCHRONIZE CACHE(10/16) reaches the userspace Flush
  callback, including LBA zero, and that backend errors reach the guest.
- Preserve WslPart's existing backend flushing.

Acceptance: successful guest cache flushes execute the corresponding backend
flush. Full preceding-write ordering is established by patch 7.

### Patch 2: establish authoritative ownership and safe rundown

Files: `src/sys/driver.h`, `src/sys/ioq.c`, `src/sys/stgunit.c`; userspace shutdown
paths as needed to establish the existing protocol's CLOSE contract.

- Introduce the slot table and intrusive FIFOs with IOQ metadata-lock authority.
- Convert existing combined execution paths to slot ownership before separating
  workers. Remove redundant shared-path buffer allocation, owner metadata,
  processing hash, and staging structures as their replacements become active.
- Preserve legacy-path structures and behavior.
- Implement cancellation for every introduced state and separate logical SRB
  retirement from published-slot reclamation.
- Implement terminal reset/failure, waiter wakeup, owner-process reference, and
  normal/abnormal rundown accounting immediately.
- Move existing SRB completion calls outside the IOQ lock using safe detached
  retirement bookkeeping.

Acceptance: one authority and owner per slot, no premature reuse or freed SRB
pointer access, exactly-once completion, and safe STOP/CLOSE/reset/process-exit
rundown with the existing execution contexts.

### Patch 3: replace shared request hints

Files: `src/sys/scsi.c`, `src/sys/stgunit.c`, `src/sys/driver.h`.

- Use generation/index tokens on the shared path; preserve legacy hints.
- Validate CQ identity and buffer metadata atomically against authoritative slots.
- Implement terminal protocol-failure handling and validated-prefix CQ advancement.
- Test reuse, duplicate/stale entries, malformed metadata, generation exhaustion,
  and expected post-STOP rejection.

Acceptance: O(1) completion lookup, no stale SRB access, no ownership mutation for
an invalid entry, and no token wrapping.

### Patch 4: implement batched preparation

Files: `src/sys/ioq.c`, `src/sys/stgunit.c`, `src/sys/driver.h`.

- Allocate one reusable preparation Storport work item with IDLE/ACTIVE/RERUN
  scheduling, lifetime references, and rundown from its introduction.
- Claim a batch of pending SRBs and matching free slots under one lock acquisition;
  mark Preparing, then perform WRITE/UNMAP preparation outside the lock.
- Commit ready groups under the lock, resolve cancellation, and schedule the
  producer once per exposed group.
- Keep claim size independent of commit size so early groups become publishable
  before the entire claimed batch finishes.

Initial tuning:

| Parameter | Initial value |
| --- | --- |
| Maximum requests per claim | 32 |
| Maximum estimated preparation-copy bytes per claim | 1 MiB |
| Ready commit group | 8 requests or 256 KiB |
| Target callback CPU time | 100 microseconds, soft |

Allow at least one request exceeding the byte budget. Charge actual estimated
preparation-copy work, not full READ payload sizes. Finish publishing/retiring all
already claimed slots before returning; the time budget determines whether another
batch is claimed. A full batch may exceed the nominal time target.

Do not continuously reschedule when blocked by free-slot exhaustion or, once
introduced, a FLUSH fence. The transition removing the blocker must wake preparation.

Acceptance: batched claims and commits, no per-SRB claim-lock churn, independent
early publication, cancellation/rundown safety, and measured callback duration.
Expect one claim acquisition plus one acquisition per ready commit group in the
normal path, rather than one claim/release cycle per SRB.

### Patch 5: simplify the SQ producer

Files: `src/sys/stgunit.c`.

Retain the existing producer work item and single-producer scheduler. Its path is:

```text
Acquire metadata lock
    Check terminal state and SQ capacity
    Drain a bounded group of ready slots
    Resolve final cancellation checks
    Copy prepared descriptors into SQ
    Transition published slots to InFlight
    Release-store SQ tail
Release metadata lock
Notify userspace
```

The producer performs no payload copying. Remove old preparation-specific staging
and aborted-batch compaction. Preserve full-SQ handling and wakeup when userspace
consumes SQ entries; do not busy-loop on a full ring.

Acceptance: only the producer publishes SQ; preparation can proceed independently;
cancel/reset and tail publication are serialized by the same metadata lock.

**First major milestone:** patches 1-5 include complete ownership, identity,
cancellation, and teardown guarantees. Prove these before adding completion
offloading. The FIFO FLUSH fence and its full ordering acceptance gate follow in
patch 7; this milestone is not yet the final durability/performance result.

### Patch 6: split CQ consumption from completion

Files: `src/sys/stgunit.c`, `src/sys/ioq.c`, `src/sys/driver.h`.

- Keep KICK as the single CQ consumer with its KickActive guard.
- Copy/validate descriptors and batch-transition InFlight to CompletionQueued,
  append to CompletedSlots, advance the validated CQ prefix, and schedule completion.
- KICK performs no READ copies, SRB completions, or slot recycling.
- Add one reusable completion work item with the same scheduling/lifetime rules.
- Claim up to 32 completed slots in one lock acquisition and mark Completing.
- Execute completion/READ copying outside the lock, then batch-retire or continue
  SRBs and release slots under the lock. Call SpdSrbComplete after unlocking.
- For SRB_STATUS_PENDING, release the completed slot and reinsert the already
  accepted SRB at pending FIFO head; do not treat it as a new admission.
- Wake preparation when slots become available.

Acceptance: short KICK path, concurrent preparation/completion, safe copying,
exactly-once retirement, and correct multichunk continuation ownership.

### Patch 7: implement the FIFO FLUSH fence

Files: `src/sys/ioq.c`, `src/sys/scsi.c`, `src/sys/io.c`, `src/sys/driver.h`.

- Implement ActiveSrbs, ExecutionStarted, and FlushInProgress using the exact
  rules above. Continue admitting later SRBs to the pending FIFO.
- End claim batches at FLUSH and wait for earlier logical SRBs, including all
  chunks, to finish. Reopen scheduling only after FLUSH retirement.
- Handle pending/claimed/published FLUSH cancellation without dangling pointers,
  bypassing earlier work, or restarting terminal sessions.
- Route non-CDB FLUSH/SHUTDOWN through explicit preparation/completion handling.
- Audit non-barrier rejection status mapping; SpdScsiPostSrb currently maps failed
  posting to ABORTED and must not conceal distinct rejection conditions.

Acceptance: earlier writes and their chunks finish before backend FLUSH; later
writes cannot pass it; consecutive and cancelled FLUSH requests behave correctly.

### Patch 8: consolidate and audit cancellation/rundown

Files: `src/sys/ioq.c`, `src/sys/stgunit.c`, `src/sys/io.c`, affected WslPart lifecycle
code and tests.

- Consolidate implementations already required in patches 2-7.
- Audit every state, ordinary abort versus reset/STOP, queued continuation, failed
  work-item scheduling, process exit, and CLOSE path.
- Verify terminalisation is atomic against claims/publication and wakes waiters.
- Verify quarantined-slot accounting survives early logical SRB retirement.
- Verify no nested metadata/lifetime locks, payload copies under the metadata lock,
  SRB completions under that lock, or storage access after final rundown.

Acceptance: every accepted SRB completes exactly once, published buffers remain
valid until safe reclamation, and all workers/KICK calls finish before resources
are released. This patch is an audit/consolidation, not the first safety patch.

### Patch 9: instrument and benchmark

Files: `tst/winspd-tests/ring-test.c`, `src/sys/ioq.c`, `src/sys/stgunit.c`, WslPart
benchmark scripts.

Preserve existing lock wait/hold counters. Add bounded, low-overhead measurement
for batch effectiveness and stage latency, including distributions rather than
only accumulated tick totals:

| Metric | Purpose |
| --- | --- |
| Claim batch size and ready commit size | Verify batching and early publication |
| Lock acquisitions per SRB | Quantify metadata lock churn |
| Lock wait/hold p50 and p99 | Identify contention |
| Pending to Preparing | Preparation scheduling latency |
| Preparing to Ready | Preparation/copy cost |
| Ready to SQ publication | Producer scheduling latency |
| CQ receipt to final SRB completion | Completion scheduling/copy cost |
| Work-item duration and reruns | Detect oversized batches and worker-pool churn |
| Backend FLUSH calls and latency | Verify durability and benchmark validity |

Benchmark QD 1, 4, 32, and 128 with preparation claim sizes 1, 8, and 32. Include
direct-I/O WRITE, READ, and corrected fsync4k. Record CPU utilisation, IOPS,
throughput, and tail latency using identical underlying I/O settings.

For fsync4k, compare against the old architecture with patch 1 applied and verified
WRITE/FLUSH ordering. If ordering needs a baseline correction, record it explicitly
and keep scheduling/ownership changes out of that baseline. The untouched old
implementation can skip backend flushing and is not a valid durability baseline.

Acceptance: correctness gates pass; batching effectiveness is measured; meaningful
low-QD latency regressions are explained before accepting performance conclusions.

## Correctness coverage throughout the series

Extend existing preparation-copy, completion-copy, cancellation, compaction,
SQ-full, multichunk, teardown-race, and owner-process-termination tests. Replace
implementation-specific compaction checks with equivalent cancellation/publication
coverage when staging is removed.

Keep ordinary fixtures on the production create/open/start and
shutdown/wait/delete APIs. Restrict manual SQ/CQ and WAIT/KICK sequencing to tests
whose purpose is protocol control or a particular ownership boundary. Keep
negative OPEN/layout validation out of the common startup fixture. Submit guest
SCSI commands through a separate command handle from the dispatcher's
IOCP-associated transport handle. Discovery failure diagnostics must not read a
mapping that a failed dispatcher may already have unmapped.

Retained WAIT IRPs must support external cancellation independently of STOP.
Serialize cancel registration and dequeue so only one path completes each IRP
and releases its lifetime reference. Require a registered, readiness-signalling
owner-exit child test; an unselected helper is not termination coverage. Resolve
this rundown prerequisite before introducing new slot or worker ownership states.

Child-process tests must register their child entry point with a name within the
test registry's length limit and provide a readiness handshake. An exit code of
zero from a process that selected no tests is not evidence of owner rundown.

Use deterministic barriers/hooks for:

- Cancellation before/during claim, preparation, ready insertion, publication,
  CQ consumption, and READ copying.
- Multiple completions during ongoing preparation.
- Mixed READ/WRITE sizes, oversized copies, and cancelled requests in one batch.
- Slot reuse across chunks, duplicate/stale tokens, and invalid kind/buffer/length.
- Full SQ and exhausted slots, including wakeup without continuous rescheduling.
- Earlier multichunk WRITE, FLUSH, and later accepted WRITE held behind the fence.
- Pending and published FLUSH cancellation, consecutive FLUSH requests, and backend
  FLUSH failure.
- Non-CDB FLUSH/SHUTDOWN behavior and zero-count SYNCHRONIZE CACHE(10/16).
- STOP/reset/failure at every ownership boundary and with queued worker reruns.
- Cooperative CLOSE after userspace joins and abnormal owner termination.
- Logical retirement before physical reclamation, proving that quarantined slots
  do not retain retired SRB pointers or become reusable.

Run appropriate driver/userspace builds and deterministic correctness tests at
each patch boundary. Record environmental limits explicitly if kernel execution
or benchmark hardware is unavailable; a build alone does not establish the race
and lifetime guarantees.

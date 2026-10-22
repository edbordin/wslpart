# Shared-memory transport implementation progress

## QD32 mapping cutoff and saved-baseline comparison (2026-10-23)

Matched the earlier full QD32 Release configuration, including disabled extra
diagnostics, 2 GiB files and 20-second workloads. Reused its saved copy control
without another control or VHDX run. The
[cutoff report](benchmarks/winspd-mapping-threshold-qd32.md) records completed
64, 4 and 256 KiB cutoffs. The user cancelled the planned 16 KiB measurement
after the counters established that every mapped lease was 256 KiB in all runs.
This is an observed eligibility result for this fio profile, not a hard minimum
of the API or implementation. Higher cutoffs would disable mapping under the
unchanged 256 KiB transfer cap. All 901,497 mapped leases were released.

The 256 KiB cutoff measured sequential WRITE/READ at 1916.6/2897.5 MiB/s,
versus saved-control medians 1632.6/2679.1. Random I/O was within 2%; p95/p99
and CPU data are retained in the report. The historical control remains
provisional and fsync variation must not be attributed to mapped 4 KiB I/O.

## Optional SRB mapping benchmark-readiness checks (2026-10-23)

The [robustness report](benchmarks/winspd-mapped-payload-robustness.md) records
76 Debug parent regressions, 21 Release ring regressions, FLUSH checks, and
separate-process mapping tests for cancellation, reset, STOP and process death.
Disk-opening traffic is excluded from cancellation barriers, and both the test
control and real Storport abort path use the same post-lock worker wakeups.

Six real-backend sessions completed QD32/64/128 stress and two 256 MiB CRC32C
write/readback checks. All 822,312 mapped leases were released, without a kernel
crash or reboot. Benchmark tooling now checks the mapping threshold, actual
mapping activity and balanced unmapping. Twelve tooling tests passed.

This supports controlled benchmarking with WslPart. It does not resolve the
physical-page lifetime problem for dishonest early CQ/CLOSE assertions. Mapping
remains default-disabled, buffers are unchanged, and the timing results are
not a quiet, paired performance comparison.

Release `.217` and matching baseline binaries were restored and hash-verified;
its 21 ring tests, FLUSH checks and the 07:40:15 local cleanup audit passed.

## Optional SRB mapping happy path verified (2026-10-23)

Added experimental `RingMapThresholdBytes` / `SPD_RING_MAP_THRESHOLD_BYTES`,
default 0 (disabled). Eligible large SRBs use per-slot MDL/user mapping resources;
small, kernel-range, self-originating, unknown-origin or unsuitable requests
retain the bounce buffer. Mapping/unmapping occurs in worker context with
brief backend-process attachment. Ring V5 descriptors carry the optional user
address alongside the slot ID and length; matching kernel/userspace components
are required. Preallocated buffers have not been reduced.

The [happy-path result](benchmarks/winspd-mapped-payload-happy-path.md) verifies
64 MiB written and CRC32C-checked through the real WSL backend, exercising 384
mapped leases and balanced unmapping. A short QD32 comparison also completed
93,297 mapped leases cleanly. Its performance readings are exploratory.

The user requested normal-path verification before additional fault injection.
Kernel-enforced recovery and premature-completion safety remain unfinished;
see the [experiment checkpoint](winspd-srb-user-mapping-experiment.md). The
validated `.217` Release driver and matching userspace binaries are restored,
with 21 baseline ring tests, FLUSH checks and the final cleanup audit passing.

## Full fio baseline retained provisionally (2026-10-23)

Completed three paired passes at QD32/64/128 on the Release `.217` work-item
baseline and the Ubuntu root VHDX, covering sequential READ/WRITE, random 4 KiB
READ/WRITE and serialized write-and-fsync. The
[report](benchmarks/winspd-full-baseline-qd32-64-128.md) is **provisional**:
a WSL kernel build overlapped the final QD32 pair, which is excluded. Eight pairs
and 80 workload observations remain, with two repetitions at QD32 and three at
QD64/128. Earlier compilation activity has not been ruled out. The user deferred
clean repeats; no final configuration or performance conclusion is drawn.

Windows CPU counters are host-wide and cannot establish driver CPU cost.
Proxy CPU is process-specific; fio CPU covers the fio task. Throughput and
latency can also be affected by build contention. Raw fio JSON, timestamps,
hashes and excluded runs are retained for later analysis.

Sequential jobs now use the actual selected QD and run for 20 seconds;
fsync4k explicitly remains QD1. All workloads use direct I/O. A free-space guard
rejected the initial 4 GiB attempt; the paired sweep uses 2 GiB files without
resizing or deleting existing data. Measurement tooling now supports checking
for active WSL compiler/build processes at workload boundaries and waiting for
quiet gaps on future baseline runs. Boundary checks cannot detect every overlap.

The installed driver and execution settings remain unchanged. No reboot was
performed. Benchmark parser checks and the final read-only cleanup audit are
recorded in `artifacts/full-baseline-final-summary.json`.

## Dedicated thread priority comparison completed (2026-10-22)

Added `RingThreadPriority` / `SPD_RING_THREAD_PRIORITY` for dedicated preparation
and completion threads. The selector accepts only Normal (8) and Delayed (12);
13 and higher are excluded. Work-item execution and DPC priority are unchanged.
CLOSE records the configured priority and measurement capture validates it.

Priority-12 P2/C2 threads pass 70 selected Debug tests plus eight targeted
parallel ownership/cancellation/reset/STOP tests. Every activated Release package
passes 21 tests and zero-count FLUSH checks; eleven parser/image tests pass.

The [comparison](benchmarks/winspd-ring-thread-priority.md) retains 16 ten-second
observations with no exclusions, using one preparation and two completion
threads, ordinary locking and unchanged batch limits. READ uses QD1/32/128 and
WRITE QD128, in 8/12/12/8 order. Priority 12 provides no consistent p95/p99
improvement: QD1 READ p95 is unchanged, QD32 changes less than 1%, QD128 READ p95
is about 3% worse and WRITE unchanged. QD1 mean latency improves about 9%, but
p99 is worse due to one higher-tail candidate run. These quiet-condition results
do not establish behavior under sustained CPU contention. Priority 8 remains
the default, with 12 available for follow-up. No priority-13 experiment ran.

Final installed Release is `1.0.26293.217`, work items, ordinary locking and
completion cap 32. SHA-256:
`A61EFDC3077B7AFBE9DFC13C2956B6C7D3FB070FBAB763A4931081C3D1C60445`.
Tests and final audit pass with zero units or proxy/capture processes. No reboot
was performed; changes remain uncommitted. Completion receipt:
`artifacts/priority-final-summary.json`.

## Queued IOQ spin lock comparison completed (2026-10-22)

Added `IoqQueuedSpinLock` / `SPD_IOQ_QUEUED_SPIN_LOCK`, default 0, selecting
ordinary or Windows in-stack queued IOQ locking. Every acquisition owns its
caller-stack handle until release; APIs are never mixed on one lock. Critical
sections, queues, cancellation, FLUSH fencing, batching and transport lifetime
locking remain unchanged. CLOSE records the mode and capture validates it.

Ordinary work items, queued work items and queued P2/C2 threads each pass 70
selected Debug tests. Queued threads also pass eight targeted parallel
ownership/cancellation/reset/STOP tests. Every activated Release package passes
21 tests plus zero-count FLUSH checks. Eleven parser/image identity tests pass.

The [comparison](benchmarks/winspd-queued-spin-lock.md) retains 28 ten-second
observations with no exclusions. Work-item READ/WRITE uses QD1/32/128; P1/C2
threads additionally use QD128 READ. Each comparison uses ordinary/queued/queued/
ordinary ordering, two observations per cell. Queued locking lowers mean and
tail acquisition waits, but end-to-end gains are selective: approximately 8%
more QD32 WRITE throughput and 4% more threaded QD128 READ throughput, with no
consistent guest p99 improvement. Low-QD queued observations are worse, but
opening/closing ordinary controls drift substantially, limiting attribution.
Ordinary locking remains the default; the switch supports further experiments.

Final installed Release is `1.0.26293.211`, ordinary locking, work items and
completion cap 32. SHA-256:
`552EFDE178966874BBE07B39AFBF98DC0E0097DE33CBBFD4149DCD927154B058`.
Tests and final audit pass with zero units or proxy/capture processes. No reboot
was performed. Changes remain uncommitted. Completion receipt:
`artifacts/queued-lock-final-summary.json`.

## Smaller completion claims completed (2026-10-22)

Added `RingCompletionClaimLimit` / `SPD_RING_COMPLETION_CLAIM_LIMIT`, range 1–32,
default 32. Worker arrays, claims and claim-size counters use this cap; KICK
continues consuming CQ batches of 32. Preparation, ready commits and SQ publication
limits are unchanged. CLOSE records the configured cap, and capture validates it.

Claim caps 1 and 8 each passed 70 selected Debug regressions with two completion
threads, plus four targeted completion ownership/cancellation/reset/STOP tests.
Eleven parser/hash tests pass. Every activated Release package passed 21 tests
and zero-count FLUSH checks.

The [short comparison](benchmarks/winspd-completion-claims.md) retains 11
ten-second READ runs at QD32/128, with one preparation thread. It compares one
or two completion threads and caps 1/8 against a one-thread, cap-32 reference,
repeated at QD128. No observations were excluded. QD128 median reference p99 is
1.098 ms; cap 1 gives 1.319/1.368 ms with one/two threads, and cap 8 gives
1.171/1.286 ms. Cap 1 substantially reduces throughput and batching efficiency.
Two threads/cap 8 preserve throughput but do not improve guest p99 in this screen.
Candidate cells have one observation each; these are not confidence intervals.

Final installed Release is `1.0.26293.198`, work items and completion cap 32,
SHA-256 `CF5B44D9E93C61B51536C4A9CFDC3C99F2387527153B57FD5B98A33ADBC746C6`.
Its tests and final teardown audit passed with zero units and proxy/capture
processes. No reboot was performed; changes remain uncommitted. The completion
receipt is `artifacts/completion-claim-final-summary.json`.

## Parallel thread pools completed (2026-10-21)

Added `RingPreparationThreads` / `RingCompletionThreads`, independently selecting
one to four threads when the corresponding thread mode is enabled. Each thread
owns its activation state, wake event and rundown references. Slot claims remain
batched under the IOQ lock; copies and completion notifications can overlap on
different threads. CLOSE joins every pool member, including partial OPEN cleanup.
Concurrent histogram/counter updates and peak overlapping nonempty batches are
recorded. Work-item and one-thread controls must be rebuilt with the same counters.

Two and four threads per stage and the rebuilt work-item control passed all
70 selected Debug regression tests each.
Eight targeted tests force two distinct owned batches and cover preparation and
completion cancellation/reset/STOP. These use tagged disk I/O because untagged
SCSI pass-through can be serialized by Storport before reaching the IOQ. The
partial-commit test now verifies completion of a published prefix while a suffix
is held, rather than assuming a fixed nine-request prefix from one worker.
FLUSH tests gate all preparation claims while constructing their tagged probe.

Validation exposed an existing userspace OPEN race: discovery SRBs can already
advance the kernel SQ tail before OPEN returns. Initial validation now accepts a
bounded SQ backlog with untouched userspace head and completion indices. ARM64
Debug transport builds also disable inherited runtime checks, matching the other
architectures and avoiding unresolved runtime-check helpers. The backend and
shared-memory layout remain unchanged.

The [completed comparison](benchmarks/winspd-ring-thread-pools.md) retains 53
twenty-second READ/WRITE observations across work items, 1/1, 1/2, 1/4, 2/2 and
4/4 at QD1/32/128. Five attempts with observed Blender interference are excluded
and replaced. READ at QD1/128 is repeated for each thread configuration; work-item
controls are repeated at the end and after replacement runs. Full DLL hashes are
retained alongside a normalized image hash that ignores only linker/debug
timestamps and PDB age. Code, data, resources, layout and PDB GUID/path are still
included; all retained observations have the same normalized transport image.

The wake-all pool policy does not establish an overall latency gain. QD128 READ
median p99 is 1.004 ms with work items, 1.067 ms at 1/1, 1.130 ms at 1/2,
1.245 ms at 1/4, 1.352 ms at 2/2 and 1.696 ms at 4/4. At QD32 READ, 4/4
averages 1.04 SRBs per preparation claim and 2.82 empty preparation claims per
accepted SRB; lock acquisitions rise from 8.17 to 18.00 per SRB. Ownership
overlap is verified, but batching fragments and lock contention increases. These
results describe this policy with shared atomic instrumentation and 4 KiB I/O;
they do not rule out other scheduling policies for parallel completion.

The tightened eight ownership tests reset overlap evidence after discovery and
verify READ data copying. They passed again with 2/2 (Debug .181) and 4/4 (.182).
Eleven parser/hash tests pass. Every activated Release package passed 21 tests
and the zero-count FLUSH checks. A long interruption occurred after all timed
measurements, during final validation; retained fio wall times remain bounded.

Final installed Release is `1.0.26293.183`, work items for both stages, SHA-256
`60A61A10A9A09C2F8235ECC132995E997C922F6E2F149FD6D14A0317CA2D6773`.
Its 21 tests and final audit passed with zero units and zero proxy/capture
processes. The temporary awake hold is released. No reboot was performed and
changes remain uncommitted. The completion receipt is
`artifacts/ring-pool-final-summary.json`.

## Dedicated-thread execution selectors (2026-10-21)

Added independent `RingPreparationThread` / `RingCompletionThread` build properties
mapping to `SPD_RING_PREPARATION_THREAD` / `SPD_RING_COMPLETION_THREAD`. Defaults
retain work items. Thread modes reuse the batch callbacks/state machine with an
event wake, hold a persistent storage-unit reference, and join actual thread
termination before CLOSE frees ring storage. The producer and transport ABI are
unchanged. See [execution selection and rundown](winspd-ring-worker-execution.md).

Initial Debug revision 101 crashed because CLOSE freed an unallocated retry work
item in thread mode. The dump confirms `IoFreeWorkItem(NULL)`. Both optional
cleanup calls are guarded; the failed package was removed and the known-good .100
driver restored/retested before activating the correction. Fixed both-thread
revision 110 passed four focused lifecycle tests and 70 selected Debug tests;
preparation-only .111, completion-only .112 and work-item control .113 also passed
70 each. Every activated Release package passed 21 tests and zero-count FLUSH
checks before measurement. Seven parser/report tests also pass.

The [completed comparison](benchmarks/winspd-ring-threads.md) retains 40
twenty-second READ/WRITE measurements at QD1/4/32/128 across all four modes.
The earlier morning sweep is excluded after observed Blender activity. Three
evening attempts are also excluded for measured Blender CPU activity; their raw
results remain available. Repeats show substantial variation, including a
completion-only QD1 READ p99 increase from 187 to 1,778 us. QD128 READ p99 is
higher in all thread variants than the work-item control median. Throughput
changes depend on workload; this does not establish a consistent latency gain.
Keep work items as the default. Multiple workers per stage remain unimplemented
and were not tested by this one-thread-per-stage experiment.

At the end of that single-thread comparison, installed Release was
`1.0.26293.129`, both selectors zero, SHA-256
`A5A1431F1617BB839C912F192EA7837C0C5D59FAB02DEEC069CBE869E8DDBB96`.
Its 21 Release tests passed. Final audit passed with zero storage units and zero
proxy/capture processes. The temporary awake hold was released. No reboot was
performed; changes remain uncommitted. Raw evidence and the completion receipt
are under `artifacts/ring-measurements/thread-clean-*` and
`artifacts/ring-thread-final-summary.json`.

## Kernel worker profiling completed (2026-10-21)

Recorded six zero-loss WPR traces plus three matched untraced controls using the
unchanged default-policy Release .100 driver. Lighter CPU/DPC captures stay within
1.7% of control IOPS; full scheduler tracing perturbs high-depth throughput 7–9%.
Resolved stacks show completion notification entering Storport DPC and Windows/WSL
completion processing before returning. Preparation/producer samples show sizable
IOQ spinlock waits and performance-counter overhead. Outgoing callback stacks show
little mid-callback descheduling; work already migrates across numerous CPUs.

The [profiling report](benchmarks/winspd-ring-scheduler.md) recommends testing one
dedicated completion thread, then completion parallelism as an independent
experiment, while retaining one preparation owner and measuring timing overhead.
The queue ownership model permits these changes; current single-writer metrics
and scheduling/rundown assumptions need explicit changes for multiple workers.
No kernel scheduling implementation changed during profiling. Final audit passed
with zero units and no proxy/capture processes; .100 remains installed.

## Storport DPC-routing comparison completed (2026-10-21)

Added optional `RingCompletionDpcMode`: 0 preserves defaults, 1 requests completion
DPC redirection toward the originating CPU, and 2 additionally selects the current
CPU. HwInitialize queries supported options first and records query/application
status separately from the requested flags. This host supports both modes and
accepted masks 0x1/0x21. Other performance flags and queue ownership are unchanged.

After the user reported a Blender render, the first DPC sweep was marked
potentially affected and excluded. The post-render clean comparison includes 33
successful twenty-second profiles: READ/WRITE at QD1/32/128, repeated at QD1/128,
and one QD1 fsync spot check per setting. Long gaps occurred outside retained fio
timing windows; these remain short local measurements, not a controlled lab run.

Origin-CPU routing at QD128 improves median READ IOPS 4.6% and WRITE 17.6%, with
about 7.1/3.6 percentage points less host CPU. READ p99 is 15.5% higher; WRITE p99
is slightly lower. QD32 throughput is similar with about 6-7 points less CPU and
somewhat higher p99. QD1 varies substantially. Current-CPU routing does not show
a compelling advantage. Backend flush latency varies, so the single fsync result
does not isolate a routing effect.

The notification call falls from about 4 us to 0.5 us at high depth with origin
routing, and CQ acceptance-to-notification falls from about 212-223 us to 25-30 us.
The guest-visible improvement is smaller because completion processing can move
outside the measured miniport lifetime. The [comparison report](benchmarks/winspd-ring-dpc-comparison.md)
and CSV/JSON retain all clean observations, flag status and binary identities.

Both enabled modes passed 70 selected Debug tests. Every activated Release package
passed all 21 applicable tests plus repeated zero-count FLUSH regressions. Seven
parser/report tests pass. All accepted profiles fully retired SRBs with zero final
active/fence/completion counts, copy-budget violations, KICK overlaps or observed
SQ-full/buffer-starvation events. Benchmarks hold a temporary system-awake request
through capture/receipt cleanup, reset the idle timer at handoff, then restore the
previous execution state; the power plan/display settings are unchanged.

Current normal ARM64 Release is `1.0.26293.100`, default policy (mode 0), detailed
kernel timing off, SHA-256
`2A612C24623AC50B55E355AAE2482E09E5B52D66F30980F6896B784265617395`.
The experiment does not promote a default. Final audit passed with zero units and
zero proxy/capture processes; no reboot was performed. Changes are uncommitted.

## Latency instrumentation and CQ audit (2026-10-20)

Optional detailed kernel latency instrumentation is implemented and measured.
The [latency report](benchmarks/winspd-ring-latency.md), CSV and JSON retain 21
isolated twenty-second READ/WRITE sessions at QD1/32/128, including disabled
controls. One host-pause measurement and one retry rejected before I/O are excluded.
The capture script now rejects wall time greatly exceeding fio runtime.

CQ acceptance to notification averages about 191-238 us READ and 205-211 us WRITE
at QD128, versus roughly 5 us at QD1. Worker dispatch averages 9-10 us at QD128;
copy/service averages 0.1-0.4 us. About 81-87% of completion-callback wall time is
inside StorPortNotification(RequestComplete). Completed-list backlog and waiting
for preceding notifications are material delays. No SQ-full or overlapping-KICK
events were recorded. A substantial part of guest latency is outside the tracked
WinSpd lifetime and is not attributed to a specific Windows/guest layer.

The diagnostics add exact totals and per-stage histograms for queue wait, batch
service, retirement, notification, worker dispatch, CQ lock wait and sampled queue
depth. Per-SRB totals reconcile with tracked lifetime; percentiles are not summed.
Backend optional io-stats now separates submit-to-IOCP latency with finer bins.
Detailed kernel timing defaults off; enable with RingLatencyDiagnostics=1 at build.

Instrumented Debug .80 passed 70 selected tests. Instrumented Release .82/.84 and
disabled Release controls .81/.83/.85 each passed all 21 applicable tests and the
repeated zero-count FLUSH regressions. Five parser tests cover units, count/clock
mismatch, incomplete extended captures and zero samples. Scheduling/ownership
policy is unchanged. Next profiling should target notification/return processing,
rather than assuming preparation claim size or FIFO capacity causes the delay.

Normal ARM64 Release at this earlier checkpoint: `1.0.26293.85`, detailed kernel timing off,
SHA-256 `27F53EA7E6411E869C782C994A08E8F1B6E07DACBEEDA1D6AEBCEBFA01BCD42B`.
Final audit passed with zero units and zero proxy/capture processes. No reboot was
performed. Signed diagnostic and control packages remain available; all changes
are uncommitted.

## Implementation and full tuning evaluation (2026-10-20)

The ownership refactor, independent preparation/producer/completion work items,
generation validation, FIFO FLUSH fence and terminal cancellation/reset model are
implemented. Final-source correctness gates, the complete tuning/depth sweep and
cleanup audit passed. Performance acceptance remains open for the CPU/throughput
tradeoff and variable low-depth/fsync results. Historical checkpoints below do not
describe the current installed driver.

ARM64 Release used for this evaluation: `1.0.26293.78`, preparation claim limit 32, SHA-256
`D4EDDBD8E909C1B366115B4C8EDB047E3335436749983393DAB7BE1A3E73A937`.
No reboot was performed. The final audit found zero provisioned units, zero
proxy/capture processes and only the original physical disk. The renewed hidden
admin runner remains available for its authorized 24-hour lifetime.

### Final correctness gates

- Debug default 32 (`1.0.26293.71`): 70 selected tests, comprising 69 ring cases and
  one common production-API legacy lifecycle case.
- Debug claim 1 (`.73`) and claim 8 (`.74`): 68 tests each. Two partial-commit cases
  require a claim larger than the eight-request ready commit group and are excluded.
- Release claim 8 (`.76`), claim 1 (`.77`) and default 32 (`.78`): all 21 applicable
  tests each, followed by both zero-count CDB FLUSH regressions at each activation.
- The real FlushFileBuffers test holds its backend callback and proves the caller
  cannot complete early. CDB-less preparation/status helpers cover FLUSH/SHUTDOWN;
  no host shutdown or reboot was triggered as a test.
- Older raw adapter-SPTD legacy fixtures are unsupported on this platform and are
  not included in these passing counts. The production legacy case covers normal
  READ/WRITE, chunks and FLUSH through the existing legacy transport.

Per-variant receipts and immutable signed packages are retained in
`artifacts/ring-packages/validated-{Debug,Release}-<revision>`. Final installation
and cleanup receipt: `artifacts/winspd-final-audit-result.json`.

### Rundown and session identity

- WAIT/KICK/STOP/CLOSE bind to the referenced OPEN file object. Duplicated handles
  identify the same session; another adapter handle cannot affect it.
- Removed units remain in an adapter retiring table until physical CLOSE or owner
  process termination. Their BTL and GUID remain reserved, and CLOSE can still
  find them after normal discovery and I/O lookup stop finding them.
- Callback quiescence is never inferred from running in the mapping owner's
  process. A completed CLOSE permits synchronous unprovision and address reuse.
- OPEN revalidates the owner under the lifetime lock at final commit. A concurrent
  owner change rolls allocation back rather than publishing the wrong mapping.
- Malformed CQ detection, invalid SQ capacity and generation exhaustion freeze
  shared admission/claim/publication under the metadata lock before broader reset.
  A terminal shared admission returns NO_DEVICE, avoiding disk.sys retry delays.
- Reset owns its detached retirement list until notifications finish. CLOSE blocks
  subsequent resets after draining and waits existing reset owners as well as
  leased slots/callbacks before releasing state. Adapter teardown synchronizes the
  final rundown event signal and lock release before freeing adapter memory.
- Deterministic tests cover forced unprovision during a real backend READ,
  old handles across BTL reuse, OPEN owner changes, failure concurrent with ready
  publication/new admission, and reset retirement concurrent with CLOSE.

### Scheduling and evaluation

Early measurements exposed redundant scheduling: QD1 ran preparation twice and
publication three times per request. Completion now wakes preparation only when
eligible pending work exists; KICK/WAIT wake publication only for ready work. WAIT
can notify already-published SQ entries directly. Workers acknowledge old RERUN
signals before their authoritative locked eligibility check; a later arrival is
seen by that check or raises RERUN again. Continuation counters are recorded before
reference handoff, with no ring access after a successful handoff. Final QD1 has
about one preparation and one producer callback per logical request.

The [final report](benchmarks/winspd-ring-results.md) and its CSV/JSON include 21
successful sessions (63 workload observations), with claim limits 1/8/32 at depths
1/4/32/128. Every included run fully retired its SRBs, left active/fence counts zero,
reported zero copy-budget violations and recorded positive backend flush calls
with zero errors. Only final-rundown refactor source and corrected baseline runs,
with quiet timing windows and capture started after fio, are included.

Default READ/WRITE throughput improves about 30-36% at QD32/128, while host CPU
rises substantially. QD1 READ medians are close (+0.3%), with overlapping run ranges;
this does not establish a low-depth latency win. QD4 fsync loses 21.4% throughput,
with higher backend flush cost. Longer, interleaved repeats with stable backend
cost are needed before performance acceptance. No additional scheduling architecture
was introduced to hide these results.

Measurement tools and reproducible baseline:

- `scripts/measure-winspd-ring.ps1`: checked activation receipt/hash, fio READ,
  WRITE and timed fsync, capture after timing, backend statistics and run receipts.
- `scripts/summarize-winspd-ring-metrics.py`: histogram upper bounds, batch sizes,
  locks per logical SRB, copy budgets and final ownership counts.
- `scripts/report-winspd-ring-benchmarks.py`: rejects mismatched settings and
  missing/failed flushes, selects source/phase/capture boundaries, emits CSV/JSON.
- `notes/benchmarks/winspd-corrected-baseline.patch` and `.json`: reproducible
  benchmark-only baseline on 30649abb, retaining staged publication and inline
  completion with prerequisite fixes, real CDB/non-CDB FLUSH, FIFO ordering and
  lock counters. It is not a supported alternative to the final teardown model.

All activation scripts stop on reboot-required status. Changes are uncommitted.

## Historical checkpoint: FLUSH fence, rundown audit and instrumentation (2026-10-18)

Latest validated Debug driver: `1.0.26291.8`, activated without a reboot, SHA-256
`41FD27DFC71608F34FEFAD38CF68C1D20B8E506FFB5C651E52887FB7C31FE650`.
All 65 selected tests passed (64 ring tests and the production-API legacy lifecycle
test), followed by both FLUSH regressions. This includes STOP during READ copying.
See `artifacts/winspd-audit-validation-result.json` and the audit suite logs.

Status checked 2026-10-20: no further implementation jobs ran after that gate.
The elevated runner expired on 2026-10-19 at 12:48. Remaining work includes the
forced-unprovision/session-identity rundown audit and fixes, Release validation,
and matched corrected-baseline/preparation-batch benchmark sweeps. The audit must
verify cooperative CLOSE can reach a logically removed unit and that an old ring
handle cannot affect a replacement unit at a reused BTL address.

- The shared FIFO fence accepts later SRBs without BUSY. ActiveSrbs counts logical
  non-FLUSH SRBs from first claim through final retirement, including time between
  chunk leases. Continuations go to the FIFO head. A FLUSH cannot claim until
  ActiveSrbs reaches zero; its independent FlushInProgress flag holds subsequent
  claims until safe retirement. No fence pointer survives SRB retirement.
- Pending FLUSH cancellation unlinks normally. Preparing/completing cancellation
  remains with its worker. Ready/CompletionQueued cancellation retires safely.
  Ordinary published abort fails and retains the fence. Terminal reset/STOP
  quarantines a published FLUSH until physical rundown, even after SRB retirement.
- SRB_FUNCTION_FLUSH and SRB_FUNCTION_SHUTDOWN prepare whole-device FLUSH requests
  without accessing a CDB and propagate backend status explicitly. FLUSH forwarding
  also corrects the legacy non-CDB path; its queue/hash structures remain intact.
  Real FlushFileBuffers testing proves a non-CDB FLUSH reaches the backend and
  waits for its callback. CDB-less helper checks cover both functions; host shutdown
  is deliberately not triggered as a runtime test.
- Deterministic fence tests cover an actual logical multichunk WRITE followed by
  FLUSH and an accepted later WRITE, consecutive fences, cancellation before claim,
  during preparation, while ready and while completion-queued, published abort,
  and terminal reset/STOP. A Debug-only control converts a pending tagged READ CDB
  to FLUSH so Storport's untagged pass-through ordering cannot hide IOQ fence bugs.
  Production queueing, ownership, preparation and completion still execute normally.
- The large-I/O fixture advertises a larger transfer, then sets an idle-only Debug
  chunk cap. Tests explicitly verify one logical SRB spans chunks; callback count
  alone was insufficient because disk.sys can split requests before WinSpd sees them.
- Concurrent CLOSE testing proves both callers wait for a preparation owner and
  terminal CLOSE is idempotent. A child exits with a published READ still held by
  a real backend callback; its parent requires process termination and the kernel's
  physical-rundown event. Readiness and exit now have separate timeout budgets,
  and child stdout/stderr are retained for diagnosis.
- Common manual cleanup now cancels its WAIT via production IRP cancellation and
  leaves STOP/CLOSE to the SDK. Cache-enabled disk handles close after teardown,
  avoiding unserviced close-time flushes: fence cases fell from ~18 seconds to
  ~0.1 seconds without changing driver semantics.
- A mixed READ/WRITE/cancellation test includes zero-copy READs and a 2 MiB WRITE
  exceeding the nominal 1 MiB preparation budget. The cancelled request uses SPTD
  because disk.sys can retry an aborted file-I/O SRB as a new admission.
- Fixed histograms record metadata lock wait/hold, pending/preparing/ready/SQ,
  CQ/retirement/SRB completion, FLUSH transport round trips and callback elapsed
  duration. Percentiles are logarithmic upper bounds. QPC measures wall elapsed
  time; the soft 100 microsecond scheduling budget is conservative under preemption.
  Exact batch counts, actual preparation-copy bytes, oversized claims and budget
  violations supplement existing counters. MSBuild Ring* tuning properties expose
  independent claim/commit/copy/time limits; publication/completion remain at 32.

Instrumentation capture passed three controlled tests. It observed a 16-request
claim with two eight-request ready commits, an oversized 2 MiB claim with zero
copy-budget violations, and accepted == retired with active == 0 for all three
units. This is correctness evidence, not a throughput/latency benchmark.
See `artifacts/winspd-instrumentation-kernel.log` and captured-test results.
The 63-test runtime gate is `artifacts/winspd-stage9-*`; earlier fence/rundown
checkpoints and first failed fixture runs are retained separately.

WslPart now optionally measures actual FlushFileBuffers call counts/errors and
latency under --io-stats; its source write gate, handle choices and flush operations
are unchanged. Benchmark tooling adds Windows/proxy/guest CPU, separate fio sync
latencies, timed fsync workloads and driver/proxy identities. Native ARM64 proxy
build passes; matched baseline and preparation-size benchmark sweeps are pending.

A hidden persistent elevated runner is available for this task (24-hour lifetime).
Its session path is in `artifacts/admin-runner-session.txt`; queued JSON jobs invoke
workspace scripts and retain results/stdout/stderr. Administrator access and
nonzero-exit propagation were tested. It never reboots automatically. Signing now
rejects a newly stamped INF beside an older SYS using numeric version resources.
One failed compile briefly caused an old SYS to be reactivated before that check
was added; no test pass was attributed to that stale image.


## Completion offloading checkpoint (2026-10-18)

Patch 6 is implemented and its runtime gate passes. Debug `1.0.26291.2` is
activated, SHA-256
`0AD70B30D49786168F4195FEA3DF62473E922B4C8ED2091ECB09AB70105D135C`.
Activation required no reboot. All 49 Debug ring tests passed, followed by a
separate repeat of both zero-count FLUSH tests. ARM64 Debug/Release driver builds
and x64 Debug/Release DLL/test builds pass.

- KICK snapshots groups of up to 32 CQ descriptors into kernel memory before
  acquiring the metadata lock. It validates the group against authoritative slot
  generations/states, operation and buffer metadata, and appends the valid prefix
  to CompletedSlots. CQ head advances only over that prefix. It performs no READ
  payload copying, SRB completion or slot recycling.
- One reusable completion Storport work item claims up to 32 completed slots with
  one lock acquisition, copies/completes SCSI outside the lock, and retires the
  batch under one acquisition. Storport SRB notifications follow outside the
  lock. Multichunk continuations return to the pending FIFO head without new
  admission. Slot release wakes preparation once per batch.
- Completion has independent IDLE/ACTIVE/RERUN authority, BUSY retry handoff and
  storage-unit/callback references. STOP/CLOSE include the worker and retry helper
  in rundown. Preparation claim tuning no longer changes the producer or
  completion batch limits. Completion run/rerun/BUSY, claim count, maximum claim
  and callback tick counters supplement existing copy/lock measurements.
- CompletionQueued is now an authoritative SRB state. Ordinary cancellation
  unlinks and retires it in O(1); reset and STOP drain it safely. Completing
  cancellation stays with the copy owner until batch retirement.
- Four new tests cover KICK while an earlier READ copy is parked, and ordinary
  cancellation/reset/STOP before completion-worker claim. Existing READ-copy tests
  now explicitly require KICK to return while the copy and SRB remain pending.
- An accepted CQ prefix does not promise successful SRB completion if a later
  malformed descriptor terminalizes the session before asynchronous retirement.
  The prefix test retains exact head advancement and invalid-request failure
  assertions, and requires both requests to finish without timeout.
- Runtime exposed a fixture race: SetupAPI can list a disk interface that PnP has
  already removed before CreateFile. Manual discovery now requires an opened,
  serial-checked LU handle, retries transient disappearance/mismatch, and polls
  PnP while retaining and servicing its WAIT. A polling interval never stops the
  transport. New queued-state cases use distinct GUIDs for each action.

Evidence: `artifacts/winspd-completion-suite.{stdout,stderr}.log`,
`artifacts/winspd-completion-validation-result.json`, preserved activation and
FLUSH logs. The first run stopped during the fixture's stale-interface open;
its logs are preserved under `winspd-completion-first-*`.

Next: implement the FIFO FLUSH fence and active logical-SRB accounting, explicit
non-CDB FLUSH/SHUTDOWN preparation/completion, and their cancellation/ordering
runtime gates. The final ownership audit, mixed/oversized-copy-budget tests,
stage latency/lock histograms and corrected-baseline benchmarks remain pending.
Legacy transaction integration coverage still needs its older adapter-handle
fixture repaired; passing ring tests do not establish that coverage.


## Independent preparation and publication checkpoint (2026-10-18)

Patches 4/5 are implemented and their runtime gate passes. Debug `1.0.26291.1`
is activated, SHA-256
`157EF9060E2051FCFA9B2E33713B4FE6B50A86B6B44CB94654EBCF5066C6CEDF`.
The adapter restarted without a reboot. All 45 Debug ring tests and a separate
repeat of both zero-count FLUSH tests passed. ARM64 Debug/Release driver builds
and x64 Debug/Release DLL/test builds pass.

- A reusable preparation Storport worker has its own IDLE/ACTIVE/RERUN state,
  lifetime reference, callback accounting and preallocated BUSY retry handoff.
  STOP/CLOSE include both stages in rundown and release both worker handles.
- Preparation claims up to 32 requests and 1 MiB of estimated copy work, allowing
  one oversized request. READ payloads do not consume the preparation byte budget.
  Ready commits expose up to eight requests or 256 KiB independently of claims.
  Each claimed batch finishes before yielding; 100 microseconds is a soft limit
  on claiming another batch. Limits are independently build-configurable.
- The existing producer only drains ReadySlots and publishes SQ descriptors.
  Admissions and released slots wake preparation; ready commits wake publication.
  SQ capacity wakes still use WAIT/KICK, without preparation spinning on capacity
  or slot exhaustion.
- Three new tests prove publication/completion while preparation is parked,
  publication of an early group while a claimed suffix remains preparation-owned,
  and terminal reset at that partial-commit boundary. Existing copy cancellation,
  ready cancellation, SQ-full, stale-token and owner-exit tests pass unchanged.
- The generation test previously tracked two slots while its fixture allocated
  the default 128 buffers. Scheduling exposed that mismatch. It now explicitly
  requests two payload slots, retaining its reuse/stale-token assertions without
  assuming allocation order.
- Preparation run/rerun/BUSY, claimed count, commit count, maximum claim and total
  callback ticks supplement the existing lock and copy counters. Performance and
  oversized/mixed-copy-budget evaluation remain for the instrumentation stage.

Runtime evidence: `artifacts/winspd-preparation-suite.{stdout,stderr}.log`,
`artifacts/winspd-preparation-validation-result.json`, and preserved FLUSH logs.
The initial failed run is preserved under `winspd-preparation-first-*` and stopped
at the fixture mismatch. Completion offloading is the next stage; FIFO FLUSH
ordering and explicit non-CDB FLUSH/SHUTDOWN handling are still outstanding.

The sections below are historical checkpoints; their activation statements apply
only to their recorded runtime gate.

## Slot ownership and generation tokens checkpoint (2026-10-17)

Patch 2/3 code is implemented in the working tree, with the existing combined
Storport worker and inline KICK completion retained for this correctness gate.
The latest rundown changes have passed their runtime gate; worker separation is
the next implementation stage.

- A fixed `BufferCount` slot table, free/ready/completed intrusive lists, and SRB
  slot links now use `Ioq->SpinLock`. Shared requests no longer use the legacy
  processing hash/list, independent buffer freelist/owner records, or staging
  allocations. The legacy transaction structures remain available to that path.
- The combined worker claims up to 32 SRBs/slots under one lock, prepares outside
  it, commits ready slots as a group, and publishes their descriptors separately.
  Ready cancellation unlinks/recycles in O(1); preparing/completing cancellation
  stays with the copy owner. Published slots remain quarantined after reset.
- Shared hints are generation/index tokens, incremented on each lease, including
  continuations. Generation exhaustion fails the session instead of wrapping.
  CQ descriptors are copied locally and checked against slot state, generation,
  operation, buffer ID and exact length under the metadata lock before SRB access.
- New tests cover ready cancellation/reset/STOP; generation reuse, stale CQ against
  a reused slot and exhaustion; and invalid generation/index/kind/buffer/length
  following a valid CQ prefix. The new tests use production cancellation/reset
  helpers, with Debug-only gates and fault injection.
- Storage units and mapping owners now hold process-object references. Exit of
  either owner removes the terminal unit. A preallocated removal work item waits
  for the mapping process to become signaled (or an already completed cooperative
  CLOSE) before physical cleanup. It owns the transferred unit reference; adapter
  rundown waits for these callbacks. It is separate from ring callback accounting
  so CLOSE cannot wait on its own cleanup callback.
- Concurrent CLOSE calls serialize through a completion event. Normal unmapping
  targets the referenced mapping process. Adapter lifecycle registration is
  serialized separately, allowing process-notify unregister/rundown to run without
  holding the global resource needed by the notify callback.
- Owner-exit testing now waits for physical rundown completion as well as the
  child readiness/exit handshake. The post/reset Debug observer no longer depends
  on requests appearing in the legacy processing list.

Runtime status: signed Debug `1.0.26289.4` is activated, SHA-256
`A4E35B7FA0471C03E4851BA3E04161BD12884A4F0C880BEAF0AEBE74A4BA7C18`.
ARM64 Debug/Release driver builds and x64 Debug/Release DLL/test builds pass.
The authorized UAC retry succeeded and the adapter restarted without a reboot.
All 42 Debug ring tests passed, including the corrected post/reset observer,
malformed CQ prefix handling, generation reuse/exhaustion, ready-slot ownership,
and owner-exit physical rundown. Both zero-count FLUSH regression tests also
passed on a separate run. The activation result reports `TestsPassed` and matching
built/installed hashes.

Preserved logs are `artifacts/winspd-slot-table-v4-*`. The earlier `.3` build
passed 38 tests before its obsolete Debug observer failed; those historical logs
remain under `artifacts/winspd-slot-table-v3-*`. This runtime gate establishes the
current slot/generation/rundown foundation, not completion of the full refactor:
separate preparation/completion workers, the FIFO FLUSH fence, explicit non-CDB
FLUSH/SHUTDOWN handling, and performance evaluation remain outstanding.

Construction/teardown references:
[process-exit notifications](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/nf-ntddk-pssetcreateprocessnotifyroutine),
[worker-thread waits](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/system-worker-threads).

The sections below record earlier checkpoints. Their active-version statements
are historical; use the checkpoint above for current activation status.

## Patch 1: FLUSH forwarding

Implemented in the WinSpd working tree. Both FLUSH regression tests passed on the
activated Release driver after fixing the existing producer's BUSY scheduling
failure. Patch 2 is underway; its retirement and terminal-reset foundations are
implemented below. The slot table and patches 3-9 remain outstanding.

Changes:

- `src/sys/scsi.c`: forward zero-count SYNCHRONIZE CACHE(10/16), preserving the
  backend's zero-count range representation. Reject starting LBAs outside the
  medium, ranges extending beyond capacity, and unsigned range overflow. Preserve
  zero-count READ/WRITE no-ops.
- `tst/winspd-tests/ring-test.c`: add `ioctl_ring_zero_count_flush10_test` and
  `ioctl_ring_zero_count_flush16_test`. Use a cache-enabled synthetic disk and
  pass-through on its disk LU handle. Verify LBA zero, nonzero LBA, the last block,
  positive-count ranges, invalid ranges, backend error propagation, zero-length
  READ/WRITE, and that guest success waits for a blocked Flush callback to return.
  Existing test fixtures retain their original cache-support setting.
- `scripts/run-winspd-flush-tests.ps1`: run both regression tests with the locally
  built DLL, an administrator check, installed/built driver hash comparison, and
  an artifact log. The script does not install or activate the driver.
- Keep negative OPEN-version validation in its dedicated test. Remove raw shared
  cursor reads from discovery failure diagnostics: a failed dispatcher may have
  already unmapped the ring.
- Fix owner-process test registration, shorten its child entry name to fit tlib's
  63-byte limit, and require a readiness event proving the child parked a WAIT
  before exiting. Previously the child process could exit without running a test.

No WslPart backend behavior, non-CDB FLUSH/SHUTDOWN handling, slot ownership model,
or FLUSH ordering fence has changed. Those follow in the planned series.

Validation performed:

- ARM64 Debug driver build: passed.
- ARM64 Release driver and userspace DLL builds: passed.
- x64 Debug and Release WinSpd DLL/test executable builds: passed.
- Test registration/discovery: both new tests present.
- Git whitespace checks and PowerShell runner syntax checks: passed.
- Activated Release driver: all 20 registered ring tests passed, including the
  two FLUSH tests. Both FLUSH tests passed on a separate repeated run.
- Debug test executable and driver rebuilt; full Debug race/teardown validation
  remains pending, including the corrected owner-exit child test. The UAC request
  for Debug activation was cancelled, so the Release driver remains active.

Build logs are under `artifacts/winspd-refactor-patch1-*.log`. Driver builds used
Windows SDK/WDK 10.0.26100.0 with signing and packaging post-build actions disabled.
Packages were subsequently signed with the existing local WinSpd test certificate
and verified against regenerated catalogs. Release validation used driver version
`1.0.26288.1`, SYS SHA-256
`B5D2758801A52920C736DD1D5278CF018644A032CC77FB912C61B5318BBBD955`.
The installed SYS matched the signed artifact, the adapter restarted successfully,
and the callback-level tests passed. The last successfully activated Debug package uses version
`1.0.26288.4`, SYS SHA-256
`40B4EFD69CE0847385B520880C65875F5C48F4A41AB27531E63D685082428624`.
Installation and adapter restart succeeded without a reboot request.

For an authorised elevated validation session, use the existing release signing
and installation workflow, activate the rebuilt driver (including any required
reboot), then run:

```powershell
.\scripts\run-winspd-flush-tests.ps1 -Configuration Release
```

The installed-file hash check alone does not prove that Windows loaded that image;
complete activation before running the tests. Record the runtime result before
moving to the next patch's correctness gate.

## Prerequisite: producer scheduling handoff

Kernel capture identified the initial discovery failure as
`SharedRing producer continuation queue failed status=3238002700`
(`STOR_STATUS_BUSY`, `0xC100000C`). The old path failed the transport when trying
to requeue an occupied Storport handle. This affected an unchanged wraparound
test as well as the new FLUSH tests.

`src/sys/driver.h` and `src/sys/stgunit.c` now preallocate a device work item for
scheduling retries. The existing Storport producer retains execution and
publication authority. The helper performs one queue attempt per callback,
preserves lifetime references across retries, and participates in CLOSE rundown.
It never retries an SQ/free-slot blocker and never executes payload work. A
`ProducerBusyDeferrals` counter is included in the close diagnostics.

Release results:

- Discovery/wraparound, STOP with WAIT blocked, and STOP with workers active:
  passed after driver activation.
- Full Release ring suite: 20/20 passed; native exit code zero.
- Repeated FLUSH pair: 2/2 passed; native exit code zero.

Logs: `artifacts/winspd-release-ring-suite.stdout.log`,
`artifacts/winspd-flush-tests-Release.stdout.log`, and
`artifacts/winspd-scheduler-validation-result.json`. The initial kernel failure
and userspace debugger trace were also retained under `artifacts`.

The userspace crash was separately traced to `ring_test_log_discovery_timeout()`
reading an unmapped header. Removing that unsafe diagnostic avoids masking the
underlying transport failure with an access violation.

Historical validation outstanding before the next ownership stage:

- Finish the Debug ring suite and the corrected owner-exit child handshake.
- Capture close diagnostics to verify BUSY deferrals and callback rundown counts.
  The counter is implemented; its post-fix runtime values have not yet been captured.
- Update this record with the Debug result before claiming that the forced race
  and owner-termination cases have passed.

Range-semantics reference: the [T10 SBC-3 draft, SYNCHRONIZE CACHE sections](https://t10.org/ftp/t10/document.05/05-344r0.pdf)
defines zero count as extending from the specified LBA through the end of the medium.

## Correcting the ownership test fixtures

The Debug run exposed several assumptions in the existing tests:

- Cancellation waited for completion while keeping the preparation-copy release
  event unsignalled. Worker-owned requests cannot retire until that owner returns.
- `CancelIoEx()` did not invoke the miniport's SRB cancellation helper. A private
  Debug-only control now selects the paused SRB and invokes the production helper.
- Ordinary disk-class READ/WRITE requests retried aborted SRBs and triggered
  timeout resets. Low-level ownership cases now use explicit SCSI pass-through;
  existing end-to-end file-I/O tests remain intact.
- `IOCTL_STORAGE_RESET_DEVICE` returned `ERROR_INVALID_FUNCTION` on this host.
  The private Debug reset control invokes the same IOQ reset helper used by the
  driver's device-reset SRB handler; it does not duplicate reset state transitions.
- READ preparation had no reachable preparation-copy gate. The producer now
  invokes the existing Debug barrier before preparing every request kind.
- Failed assertions signal named release events before process exit, preventing
  parked callbacks from blocking teardown. The owner-exit child is registered
  explicitly and signals readiness before terminating.

On Debug version `1.0.26288.4`, 31 of the 32 ring tests passed, including all five
preparation/read-copy cancellation/reset/STOP cases, batch cancellation, SQ-full
resume, multichunk I/O, and producer concurrency. The final teardown test failed
because the newly registered owner-exit child remained blocked during termination.
Logs are `artifacts/winspd-debug-ring-suite.stdout.log` and its stderr companion.

The retained WAIT IRP had no cancellation routine. Source now registers one and
serializes registration, normal dequeue, and cancellation with the I/O cancel
spinlock. Either path detaches the IRP, completes it outside the lock, and releases
its existing lifetime reference exactly once. The cancellation routine does not
touch payload buffers or take the metadata lock. The explicit WAIT-cancellation
test now requires completion without STOP, rather than falling back to STOP.
See Microsoft's [retained-IRP cancellation requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/using-a-driver-supplied-spin-lock).

The fix builds in ARM64 Debug and Release; x64 Debug and Release DLL/tests also
build. Signed Debug version `1.0.26288.5` has SYS SHA-256
`783BDC4292684DF71EC4838A76D2D737B3DC5C6D3DC534E770637FC7F0F2C741`.
PnP installed its package but reported that activation requires a reboot; the
subsequent adapter restart returned error 50. Runtime validation of this version
has not occurred. The user deferred reboot and will resume validation later.

Resume by activating the installed Debug `1.0.26288.5` package through a reboot,
then run the full Debug ring suite, including the stricter individual WAIT
cancellation assertion and the owner-exit handshake. The latest Debug tests are
built. Do not treat a matching SYS file as proof of the loaded image, and do not
advance to slot ownership until this rundown prerequisite passes.

Slot-table and separate preparation/completion workers are not yet implemented.

## 2026-10-16: rundown verified; patch 2 foundations

Windows rebooted at 01:01 local time. The adapter subsequently reported Debug
`1.0.26288.5`, problem code zero, and the expected installed SYS hash. All 32 Debug
ring tests passed, including independent WAIT cancellation and owner termination.
This resolves the reboot/rundown prerequisite above.

Implemented the first ownership changes without introducing new execution workers:

- Reset detaches pending/processable SRBs into a private retirement FIFO under
  the IOQ lock. `SpdRingSrbRetiring` gives that reset exclusive ownership until
  groups of up to 32 are detached for final completion. Metadata transitions
  remain locked; every `SpdSrbComplete()` in `ioq.c` now executes after unlocking.
- Legacy final transaction completion captures the completed SRB under the lock
  and notifies Storport outside it. Multichunk continuation stays on the existing
  legacy pending path; the processing hash link is cleared on removal.
- Ordinary abort of published shared I/O returns failure and retains the SRB and
  payload ownership until its valid completion. Worker-owned cancellation still
  defers retirement to that worker.
- Bus/device/LU reset now permanently stops a shared IOQ under its metadata lock.
  A separate transport notification marks the ring stopping and cancels WAIT,
  without nesting locks or waiting on a paused copy owner. Legacy reset remains
  resumable. Published payload allocations remain quarantined until CLOSE.
- KICK no longer frees the implicated allocation when completion lookup fails.
  Expected rejection after terminal reset/STOP does not introduce a protocol
  failure. Invalid responses still fail the session and preserve the valid CQ
  prefix only.
- Three new Debug tests cover STOP with 40 published requests, rejection of an
  ordinary published-I/O abort followed by successful normal completion, and a
  published-I/O reset followed by a rejected late CQ and rejected new request.

The activated signed Debug package is `1.0.26289.2`, SHA-256
`2105E182B0698FA5A2C57637A8AF43E0B097C0479F2433093990E3BC1A2D9EDE`.
Activation succeeded without another reboot. All **35 Debug ring tests passed**,
followed by another successful FLUSH pair. ARM64 Debug/Release driver builds pass.
Results are preserved in `artifacts/winspd-ownership-foundations-*`.

Broader legacy-test validation is limited: `ioctl_transact_read_test` failed at
its adapter-level `SpdIoctlScsiInquiry()` setup (`ioctl-test.c:368`), before its
transaction thread or the modified completion routine ran. The ring fixtures
already use disk-LU command handles; the legacy fixtures still use adapter-level
pass-through. Do not describe the legacy transaction tests as passing.

Next: finish patch 2's authoritative slot table, cancellation and published-buffer
lifetime/rundown model before introducing separate preparation/completion workers.
Opaque generation IDs still need implementation; this checkpoint does not claim
the complete ownership milestone or FLUSH ordering fence.

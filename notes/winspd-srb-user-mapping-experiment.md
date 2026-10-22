# SRB user mapping experiment checkpoint - 2026-10-23

## Latest result: benchmark-readiness checks passed

The user subsequently requested robustness work. The mapping tests now use a
separate requester process and cover threshold/fallback selection, read-only
WRITE aliases, READ integrity, multichunk leases, STOP/reset, forced backend
termination, requester termination and cancellation at four ownership boundaries.
The test cancellation control and Storport aborts share post-lock wakeups;
previously the test control omitted the completion wakeup for mapped Ready slots.
An explicit requester-ready handshake excludes disk-opening traffic from stage
barriers. Terminal dispatcher success/cancellation races are accepted explicitly.

Debug `.229` passed 76 parent regressions and FLUSH checks. Release `.230` passed
21 ring regressions and FLUSH checks. Six real WSL backend sessions, including
QD32/64/128 stress and two 256 MiB CRC32C write/readback checks, retired all
822,312 mapped leases (215,564,156,928 mapped bytes). No crash or reboot occurred.
The [robustness report](benchmarks/winspd-mapped-payload-robustness.md) retains
the run IDs, hashes, coverage and limitations. These are correctness stress
results, not a controlled performance comparison.

Release `.217` and all five saved baseline binaries were restored and verified
by hash afterward. The 07:40:15 local final audit passed: 21 baseline ring tests,
FLUSH checks, zero units and no proxy/capture processes.

Mapping remains opt-in/default-disabled with unchanged bounce-buffer capacity.
The malicious/premature-response lifetime limitation discussed below remains
unresolved: this establishes controlled benchmark readiness with WslPart, not
isolation from a dishonest backend or production readiness.

## Earlier result: real WSL happy path verified

The user requested normal-path testing before further fault injection. That
path now works: Debug `.225`, threshold 65536, wrote 64 MiB through the real
WslPart backend and verified all 64 MiB by CRC32C readback. It mapped/unmapped
384 leases covering 96 MiB; other transfers retained copying. The important
eligibility correction was accepting partial MDLs whose page locks belong to
their parent. Real mapped-source flags included MDL_PARTIAL without
MDL_PAGES_LOCKED on the partial descriptor itself. No original MDL is unlocked
or freed by the miniport.

The [happy-path report](benchmarks/winspd-mapped-payload-happy-path.md) records
the data verification and one short QD32 comparison. The mapping run retired
all 93,297 mapped leases, with WRITE/READ around 3100/3107 MiB/s versus
2502/3039 MiB/s for the copy-only prototype. Treat those as exploratory, not
a repeatable performance conclusion: one five-second sample per mode/workload,
mapping first, Debug builds and SSD history can affect the result.

The user-range and known non-backend requester guards remain in the opt-in
implementation; kernel-range and other ineligible buffers continue copying.
Mapping is still default-disabled, and preallocated buffers are unchanged.
The copy-only V5 diagnostic build passed 73 Debug regression tests before the
user narrowed the test scope; the mapping build received normal lifecycle and
real backend/data tests, not full fault-injection coverage.

Release `.217` and its matching V4 userspace binaries were restored afterward.
All 21 baseline ring tests, FLUSH checks and the final audit passed at 07:10:27,
with zero units or proxy/capture processes. Prototype driver-store packages
were removed; source changes and signed packages remain for further work.

The historical recovery discussion below is retained for context. It is not
the current execution status, and recovery hardening is still incomplete.

## Current acceptance policy and diagnostic scope

The user clarified that kernel memory safety is mandatory, while recovery may
force-kill the backend and fail I/O; some edge cases and delayed underlying I/O
cancellation are acceptable. This does not authorize premature reuse of memory.
Neither timeouts nor CQ/CLOSE assertions alone establish safe reuse.

The earlier copy-only origin probe classified real WSL MDLs before enabling
mapping. Optional origin counters distinguish user ranges, kernel ranges,
unavailable metadata and self-originating requests. They never map payloads
when RingMapThresholdBytes is zero; RingMapOriginDiagnostics defaults to zero.
The subsequent stress results above exercise real eligible mappings, while
retaining fallback for ineligible origins. Neither origin classification nor
successful stress proves safety under arbitrary backend I/O.

User mapping still requires the backend process context even if the application
only passes its pointer to ReadFile/WriteFile. The kernel resolves that user VA
when handling the syscall. The kernel worker can briefly attach for mapping and
unmapping; it does not need to remain attached while backend I/O runs. Avoiding
the user VA would require the kernel to submit the source I/O using MDLs itself.

## New acceptance requirement: no dependence on backend good behavior

The user requires kernel-enforced lifetime safety even if userspace misbehaves.
This includes a premature but correctly correlated CQ response, not only backend
crashes and hangs. The initial prototype does **not** satisfy that requirement.

Revoking a user alias prevents later access through that alias. It does not
revoke physical-page references already acquired by another kernel I/O stack
when userspace passed the address to ReadFile/WriteFile. Completing the original
SRB after unmapping can therefore let its caller reuse memory while untracked
backend I/O still reads or writes it. Validating the CQ token does not establish
physical I/O completion. The existing copy buffers provide a useful isolation
boundary that direct SRB mapping removes.

Microsoft documents both the independent page locks associated with separate
[MDLs](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-mmprobeandlockpages)
and the lack of guaranteed cancellation of pending
[I/O](https://learn.microsoft.com/en-us/windows/win32/fileio/canceling-pending-i-o-operations).
[Process termination](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-terminateprocess)
also waits for pending I/O to finish or cancel. These are reasons not to promise
bounded recovery from pointer revocation or a timeout alone.

Meeting this stronger requirement needs a mechanism that independently accounts
for all backend references to mapped pages, or isolation that prevents untracked
I/O using them. Having our kernel path own backend IRP submission/completion is
one architectural direction; it is not implemented here, and arbitrary user
access to mapped SRB pages would still require control over untracked I/O.
Retaining the SRB indefinitely is memory-safe but does not demonstrate recovery.
Do not enable/adopt the current mapping fast path as though this were solved.

Reboot confirmed at 2026-10-23 06:37:48 local; the stuck test process is gone.
Archived Release `.217` was restored after removing only the `.219`/`.220`
prototype driver-store packages (`oem284.inf`, `oem285.inf`), which otherwise
outranked the older package. All 21 Release ring tests and zero-count flush
checks passed. Final audit at 06:46:51 reports zero units and proxy/capture
processes, with the known-good installed hash
`A61EFDC3077B7AFBE9DFC13C2956B6C7D3FB070FBAB763A4931081C3D1C60445`.
The exact authoritative hash is in `artifacts/winspd-final-audit-result.json`.

Status: **experimental, default disabled, paused for recovery design review**.
Reboot and baseline restoration have completed. The following sections
record the pre-reboot experiment; do not treat the prototype as validated.

## What actually passed

Debug drivers `.219` and `.220`, with `RingMapThresholdBytes=65536`, passed the
first new mapped-payload integration test. Its backend callback observed:

| Request length | READ / WRITE payload | WRITE protection |
| ---: | --- | --- |
| 4096 | Existing bounce buffer | Existing behavior |
| 65536 | Direct SRB mapping | User write rejected |
| 131072 | Direct SRB mapping | User write rejected |
| 66048 | Copy fallback | Existing behavior |

READ data and WRITE input patterns passed. This establishes basic feasibility,
not cancellation/rundown correctness or a performance benefit. No mapping
benchmark has run. Preallocated buffers have not been reduced.

Receipts/logs are under `artifacts/ring-packages/priority-Debug-219` and
`priority-Debug-220`, and the original runner's jobs 016/017. The first test
passed on both versions. The following STOP test failed; do not describe `.220`
as validated.

## Failure and recovery

The STOP test released the backend callback and joined the dispatcher, but
waited for the retained original SRB before issuing terminal CLOSE. That is a
circular wait: CLOSE is what releases that retained SRB. The test assertion
then aborted its own process while its self-originated virtual-disk I/O was
still outstanding. Process exit and a subsequent PnP restart are now waiting
for that request. The test process is PID 83008. No crash or reboot was issued
by the agent.

The test was corrected to issue CLOSE after backend rundown and before waiting
for the retained request. A further source guard now requires a successful
StorPortGetRequestInfo V2 result and a known requester PID different from the
backend PID before selecting mapping. Unknown or self-originated I/O stays on
the copy path. This guard is **not yet compiled or runtime tested**. Consequently,
the new mapping tests still need conversion to use a separate requester process;
otherwise their mapping expectations will fail with that guard enabled.

The normal library contract leaves CLOSE to the caller after backend rundown.
Do not move CLOSE into the userspace pump just because its callback threads
have joined: WslPart also drains source IOCP operations after WaitDispatcher.
The original claim that the library itself needed this sequencing fix was too
broad; the immediate mistake was in the new test.

The attempted `.221` build compiled the driver and transport library, then failed
to link the test executable because the stuck process has that file open.
Rebuild after reboot. `.221` packages are not validated or complete.

The most recent admin runner session is in `artifacts/admin-runner-session.txt`.
All existing runners die on reboot; start a new authorized elevated runner.
An earlier runner is waiting on the failed test; another is waiting on PnP
restart. A read-only CDB inspection could not attach to the terminating process.
Do not continue device restart/recovery attempts concurrently after reboot.

## Material design tradeoff

The user correctly identified this failure mode as a possible major downside.
Bounce buffers isolate backend ownership from the original request: reset can
retire an SRB and quarantine the backend payload. Direct mappings remove that
isolation. A stuck backend can retain guest SRBs and delay reset, device removal
or shutdown until backend access has demonstrably ended. Removing a user alias
alone does not stop already-issued backend I/O, whose storage stack can still
reference the same pages.

The source guard and corrected test avoid this particular self-I/O cycle. They
do not establish bounded recovery for an unresponsive backend. Keep the feature
disabled by default. Do not recommend it based only on a small performance gain.
Before adoption, assess whether backend termination and rundown provide acceptable
recovery and whether the gain warrants the changed failure behavior.

## Current source changes

- `RingMapThresholdBytes` / `SPD_RING_MAP_THRESHOLD_BYTES`: zero disables mapping;
  nonzero selects candidates using the logical SRB data length. Mapping also
  requires suitable MDL layout/alignment and the requester-origin guard.
- SharedRing version 5 adds optional `Data.UserAddress` alongside BufferId/Length.
  Zero uses the existing buffer address calculation. Nonzero is the VA mapped
  into the backend process. Completion metadata is checked against the slot,
  including its opaque generation token and mapped address. Rebuild matching
  kernel and userspace components; V4/.217 cannot use V5 DLLs.
- Slots own mapping MDLs and user aliases; map/unmap run in preparation/completion
  contexts outside the metadata lock. WRITE mappings are read-only to userspace.
- Reset retains mapping-lease SRBs. CLOSE cleans them after kernel and user
  rundown. Cancellation of unpublished mapped work defers cleanup to completion
  context. Counters log attempts, successes, fallbacks, unmaps, bytes and timings.
- A mapping-enabled process-exit notification waits for kernel callbacks before
  allowing that address space's exit to continue; final user quiescence is still
  handled by existing owner-process rundown. This also needs targeted testing.

## Resume work

1. Confirm reboot removed the stuck virtual unit and processes. Re-establish the
   admin runner. Keep the known-good `.217` Release package available for restore.
2. Review the new source changes and process-origin guard. Convert mapping tests
   to a separate requester process; ensure assertion cleanup cannot leave a held
   mapping/request cycle. Rebuild into a fresh package.
3. Run threshold/data/read-only/fallback tests, then mapped cancellation, reset,
   STOP/CLOSE, multichunk, stale CQ and owner-exit tests before benchmarking.
   Existing small-request tests do not establish mapped-path lifetime safety.
4. Only then make a short copy/map comparison, respecting background build and
   Blender interference. No performance conclusion is available yet.
5. Restore a validated default-disabled Release configuration and matching DLLs
   when ending the experiment. Do not leave `.220` as a validated final driver.

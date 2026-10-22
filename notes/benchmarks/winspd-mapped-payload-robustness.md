# Mapped SRB benchmark-readiness checks - 2026-10-23

The opt-in mapping path completed the tests and stress runs below without a
kernel crash or reboot. This supports controlled benchmarking with the existing
WslPart backend. It does not establish safety against a backend that falsely
reports completion while another I/O stack still references the mapped pages.
Mapping remains disabled by default; preallocated buffers are unchanged.

## Integration checks

Debug `.229` passed all 76 parent tests (ring plus legacy lifecycle), followed
by zero-count SYNCHRONIZE CACHE checks. Release `.230` passed its 21 ring tests
and FLUSH checks. The 12 Python tooling tests passed. Child-test output also
appears in the raw integration logs; activation receipts count those extra
success lines, so their raw `TestCount` is higher than the parent-test count.

The mapping tests now issue real I/O from a separate process, using production
unit creation, dispatcher startup, disk discovery and shutdown. They cover:

- 4 KiB copying, 64/128 KiB mapping, and unaligned 66048-byte fallback.
- READ data integrity and read-only aliases for WRITE payloads.
- A 128 KiB logical request continuing through eight 16 KiB mapped chunks.
- STOP and terminal reset with a backend callback holding a mapped buffer.
- Forced backend termination without STOP/CLOSE, followed by kernel rundown,
  requester failure and an empty storage-unit list.
- Requester termination while its buffer remains owned by the backend.
- Cancellation in Preparing, Ready, CompletionQueued and Completing states.
- Invalid CQ metadata, including a changed mapped address, failing the session.

The cancellation requester waits until its disk handle is open before the parent
arms a stage barrier. This prevents disk-opening traffic from reaching the gate
before the selected command. The test cancellation control and real Storport
abort path now share post-lock completion/preparation wakeups; the former had
omitted the completion wakeup required to retire a cancelled mapped Ready slot.
STOP with a retained mapped callback reports dispatcher cancellation (995),
or orderly success if Shutdown stops the pump first. Both are expected terminal
results; the retained original I/O must still fail after safe CLOSE.

## Real backend stress

All runs used direct I/O through the existing WSL partition/backend. Each
verification run wrote and CRC32C-verified 256 MiB. Debug QD32/64/128 sessions
each used a 1 GiB file, 15-second sequential READ/WRITE and 10-second random
4 KiB READ/WRITE. Release QD128 used a 1 GiB file, 10-second sequential jobs,
5-second random jobs and serialized fsync4k. Large eligible requests mapped;
small random operations retained copying.

These are correctness stress runs. They were not quiet-gated, randomized or
paired with a copy-only control; their timing is not a performance conclusion.

| Run | QD | Mapped leases | Released leases | Mapped GiB |
| --- | ---: | ---: | ---: | ---: |
| `mapping-robust-v227-verify256` | 32 | 1,536 | 1,536 | 0.375 |
| `mapping-robust-v227-qd32` | 32 | 218,016 | 218,016 | 53.227 |
| `mapping-robust-v227-qd64` | 64 | 224,286 | 224,286 | 54.757 |
| `mapping-robust-v227-qd128` | 128 | 218,019 | 218,019 | 53.227 |
| `mapping-robust-release230-verify256` | 64 | 1,536 | 1,536 | 0.375 |
| `mapping-robust-release230-qd128` | 128 | 158,919 | 158,919 | 38.799 |

Total: **822,312 mapped leases**, all released.

After testing, Release `.217` and all five saved baseline binaries were restored
and verified by hash. Its 21 ring tests and FLUSH checks passed. The final audit
at 07:40:15 local found zero units and no proxy/capture processes. Signed mapping
packages and matching test executables remain under `artifacts/ring-packages/`.

Raw reports, fio JSON paths and driver hashes are retained under
`artifacts/ring-measurements/<run>/`; the adjacent JSON records byte counts.
The benchmark harness now checks the expected threshold, requires nonzero actual
mappings when requested, and rejects unequal map/unmap counts even if all SRBs
were retired. This prevents copy fallback from masquerading as a mapping test.

## Remaining limits

CLOSE still follows backend callback/response/source-I/O rundown. An unsolicited
CLOSE or premature but correlated CQ response is not independently sufficient
to prove arbitrary backend I/O has released physical-page references. Do not
interpret these results as malicious-backend isolation or production readiness.
The same-process/unknown/kernel-origin fallback guards remain in place. Reducing
bounce-buffer capacity requires a separately designed bounded fallback path.

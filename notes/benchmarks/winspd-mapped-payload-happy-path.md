# Mapped SRB payload happy path - 2026-10-23

Normal end-to-end I/O works through WSL, WinSpd and the existing WslPart
overlapped ReadFile/WriteFile backend. The threshold is selected from the
logical SRB data length. This experiment uses 64 KiB; zero disables mapping.
Eligible full-page user ranges map; other requests retain the bounce buffer.

## Data verification

A direct-I/O fio job wrote 64 MiB and verified all 64 MiB by CRC32C readback,
with zero errors. Kernel counters show 384 mapped leases (96 MiB), and all
384 unmapped. Normal SRB retirement and transport shutdown completed.
Other transfers used the retained copy path; this was not an all-mapped test.

WSL supplies partial MDLs whose parent retains the page locks. Requiring the
partial MDL itself to carry MDL_PAGES_LOCKED incorrectly forced fallback.
Accepting locked pages described by a partial MDL fixed that eligibility check.
The original MDL/page locks remain borrowed for the outstanding SRB lifetime.

## Short comparison - exploratory

One five-second run per workload and mode, QD32, 1 MiB fio requests, 256 MiB
working file, direct I/O, 256 KiB maximum SRB transfer, eight backend workers.
Both drivers use work items, ordinary IOQ locking, claim cap 32 and origin
diagnostics. Userspace executable and DLL hashes match between modes.
The mapped driver ran first, followed by the copy-only prototype build.

| Workload | Mode | MiB/s | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| seqwrite | mapping | 3,100 | 10.29 | 13.83 | 15.53 |
| seqwrite | copy | 2,502 | 12.72 | 23.99 | 30.02 |
| seqread | mapping | 3,107 | 10.29 | 13.17 | 14.61 |
| seqread | copy | 3,039 | 10.52 | 13.30 | 15.01 |

The mapped comparison session completed 93,297 mapped leases and unmapped all
93,297. No overlap was detected by the Blender/WSL build boundary checks.
These short runs are insufficient to distinguish a repeatable improvement from
SSD cache, thermal and ordering effects. They do not establish an optimal
threshold or a production performance gain. Host-wide CPU is not driver CPU
attribution; per-process proxy CPU is retained in CSV/JSON.

## State and scope

Preparation creates the user mapping in the backend process context, then
detaches. Completion removes that mapping before retiring/reusing its slot.
The ring V5 descriptor carries the mapped user address as well as slot ID and
length. Small/ineligible requests carry zero for that address and use the
existing permanently mapped buffer. Preallocated buffer sizes are unchanged.

This is a happy-path prototype. Forced-termination, malicious/premature
completion and complete failure recovery are not established for mapped I/O.
The user requested that this work wait until the normal path is demonstrated.
Mapping remains disabled by default; the known-good Release .217 driver and
matching userspace binaries are restored after the experiment.

Raw sessions: `artifacts/ring-measurements/mapping-happy-*`.
[CSV](winspd-mapped-payload-happy-path.csv) | [JSON](winspd-mapped-payload-happy-path.json).

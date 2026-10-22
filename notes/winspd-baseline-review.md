# Shared-ring review baseline

This is the implementation/measurement snapshot before cleanup. The companion
WinSpd branch builds on `30649abb`; this WslPart branch builds on `cb3414c5` and
pins the new WinSpd commit through its submodule. No production enablement or
benchmark-control rerun is implied by publishing the snapshot.

## Start here

- [WinSpd ownership and review map](https://github.com/edbordin/winspd/blob/shared-ring-ownership-baseline/doc/shared-ring-ownership-baseline.md)
- [Implementation plan](winspd-shared-memory-transport-implementation-plan.md)
- [Implementation/validation progress](winspd-shared-memory-transport-implementation-progress.md)
- [Worker execution experiments](winspd-ring-worker-execution.md)
- [Optional SRB mapping and remaining lifetime limitation](winspd-srb-user-mapping-experiment.md)

The WinSpd diff contains ownership/FIFO batching, the independent preparation,
publication and completion stages, generation-token validation, FLUSH ordering,
cancellation/rundown, execution experiments and opt-in mapped SRB payloads.
Ring V5 requires matching kernel/userspace components. Defaults retain work
items, ordinary IOQ locking, claim caps 32 and mapping disabled.

The WslPart diff adds backend I/O/FLUSH timing without replacing
`FlushFileBuffers`, V5 ABI assertions, configurable benchmark workloads and
signing checks, stage-metric parsing, scheduling profiles and reports. The
benchmark path retains guest sync policy and unbuffered overlapped source I/O.

## Evidence

- Fresh default-disabled Debug build `.235`: all 76 parent regressions and
  zero-count FLUSH checks passed, with mapping and extra diagnostics disabled.
  The 12 tooling tests, translation tests, PowerShell syntax checks and WPR XML
  parsing also passed. The final restoration audit at 08:01:59 local passed
  with the original Release `.217` driver, 21 ring tests and no active units.
- [Mapped-path robustness](benchmarks/winspd-mapped-payload-robustness.md):
  76 Debug parent regressions, 21 Release ring tests, FLUSH checks, separate
  requester/backend process tests, two 256 MiB CRC32C checks and 822,312 balanced
  mapping leases in real-backend verification/stress.
- [QD32 mapping cutoff](benchmarks/winspd-mapping-threshold-qd32.md): same full
  baseline settings, three completed cutoffs and another 901,497 balanced leases.
  The remaining 16 KiB measurement was cancelled at the user's request after
  every mapped payload proved to be 256 KiB in this profile.
- [Saved full baseline/VHDX comparison](benchmarks/winspd-full-baseline-qd32-64-128.md):
  historical controls remain provisional because background WSL build activity
  was discovered; the known overlapping pair is excluded.

The 256 KiB cutoff's sequential WRITE/READ measured 1917/2897 MiB/s, versus
saved copy medians 1633/2679 and VHDX medians 1641/2950. Tail latency was
competitive; CPU savings were mixed. These historical, unpaired comparisons
do not establish a causal performance win or an optimal copy/mapping crossover.

**Mapping is still experimental:** forced process termination and ordinary
shutdown are tested, but a dishonest early CQ/CLOSE cannot independently prove
that lower I/O stacks have released mapped physical pages. No malicious-backend
isolation claim is made. Preallocated buffers remain unchanged.

Local signed packages, raw fio captures and machine-specific admin runners stay
under ignored `artifacts/`. The committed reports preserve derived data, source
paths and hashes; replay requires the Windows/WDK/WSL environment and a separately
guarded benchmark target. Local `.sys`/`.lnk` files and fio verification state
are not included. The machine is restored to its validated Release `.217`
driver and matching old userspace binaries after experiments.

## Lightweight checks

```powershell
python -B -m unittest discover -s scripts/tests
git diff --check
git -C third_party/winspd diff --check
```

Driver/integration validation requires an elevated Windows ARM64 session, a
signed WDK build and matching V5 libraries. Production data must not be used as
an unguarded write benchmark target. Kernel tests and performance measurements
are separate stages; no tracing or driver builds run in timed workload windows.

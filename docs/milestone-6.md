# Milestone 6 — benchmark baseline

The first benchmark pass is complete using `fio-3.41` on the native ARM64
WSL installation.

Workloads:

- sequential read and write, 1 MiB blocks;
- 4 KiB random read and write, 20-second timed jobs;
- 4 KiB fsync-heavy write, 16 MiB file, `fsync=1`.

The benchmark compares ordinary WSL distro-filesystem storage with the real
partition through WinSpd. It records throughput, IOPS, wall time, and proxy
process CPU time in:

- [cached results](../artifacts/m6/benchmark.json)
- [Linux-direct results](../artifacts/m6/benchmark-direct.json)

The cached pass uses `direct=0`; the direct pass uses `direct=1` to bypass the
Linux page cache. The selected partition is mounted normally, without `sync`,
for the cached pass.

Correction (2026-10-01): the original benchmark harness placed the purported
VHDX file under `/tmp`. On this WSL installation `/tmp` is `tmpfs`, so the
old VHDX rows in both `benchmark.json` and `benchmark-direct.json` were
RAM-backed and are not VHDX baselines (including the 1,242,762-IOPS direct
random-read result). The harness now places its test file on the distro's
ext4 root filesystem and pre-populates random-read-only test files. Linux
`O_DIRECT` bypasses the guest page cache, but does not explicitly disable
Windows/VHDX host caching.

## Result

Linux caching/coalescing materially changes the write results. Through the
proxy, cached 4 KiB random writes measured about 2439.98 MiB/s, while
Linux-direct 4 KiB random writes measured about 3.71 MiB/s. Fsync-heavy writes
measured about 0.71 MiB/s cached and 1.56 MiB/s direct, reflecting the cost of the
conservative per-write `FlushFileBuffers` path.

The original baseline did not justify changing the safe default. The current
proxy default now retains Windows caching while using guest-requested flushes,
overlapped source I/O, and the explicit flush barrier described below. A
properly sector-aligned Windows `FILE_FLAG_NO_BUFFERING` handle remains an
optional experiment; it must retain the existing bounds, alignment, locking,
and flush guarantees.

A native whole-disk comparison was not attempted because the parent disk is the
live Windows OS disk.

## Sync-policy experiment

An experimental cached run used `--sync-policy guest --buffering cached`.
Compared with the conservative default, it removes Windows write-through and
flushes only when the guest requests them. The proxy results were:

| Workload | Guest-flush policy |
| --- | ---: |
| Sequential write | 1024 MiB/s |
| Sequential read | 1896.30 MiB/s |
| 4K random read | 29.43 MiB/s / 7533 IOPS |
| 4K random write | 2545.95 MiB/s / 651763 IOPS |
| 4K fsync-heavy write | 18.41 MiB/s / 4713 IOPS |

The fsync-heavy result is much better than the conservative 0.71 MiB/s, but
this is a combined policy change rather than an isolated cache-manager test.
The guest-flush policy is now the proxy default; the `always`/cached policy
remains available as a conservative comparison mode.

After the variant runs, the existing real-partition persistence verifier also
passed: the temporary ext4 file survived detach, direct post-close reads, a
new proxy instance, and remount, with its checksum unchanged. This confirms no
filesystem damage from the benchmark sequence, but does not constitute a
crash-consistency test for the relaxed guest policy.

## Windows buffering variants

The clean `always`/`none` run measured 510.98 MiB/s sequential write,
1333.33 MiB/s sequential read, 27.59 MiB/s cached 4K random read, 2662.88
MiB/s cached 4K random write, and 1.08 MiB/s fsync-heavy write. The clean
`guest`/`none` run measured 1361.70 MiB/s, 1954.20 MiB/s, 21.81 MiB/s, 2823.46
MiB/s, and 19.25 MiB/s respectively.

These results suggest Windows buffering is not the main limiter for cached
random I/O. The combined guest/no-buffering result is fastest overall, but it
is not a safe-default recommendation: it changes both write-through behavior
and flush frequency. A persistence and failure-behavior test is required before
considering any policy change.

## WinSpd PR #14

PR #14 was built temporarily for ARM64 and tested only with the fastest
`guest + NO_BUFFERING` policy. It improved this run's 4K random read from
21.81 to 27.83 MiB/s, while sequential throughput changed only slightly,
fsync performance was unchanged, and random write declined from 2823.46 to
2688.15 MiB/s. This is a mixed result, not a basis for claiming a general
throughput improvement. The PR remains interesting for its stated hang/stall
fix and possible read-side concurrency benefit. The normal pinned WinSpd build
has been restored.

## Opt-in FUA experiment

The benchmark harness supports the native FUA mode:

```powershell
.\scripts\benchmark-m6-arm64.ps1 `
  -ProxySyncPolicy guest -ProxyFua -ProxyDispatcherThreads 8
```

`-ProxyFua` forces the proxy's unbuffered overlapped source handles and writes
the report separately from the existing variants. Runtime durability and
performance results are pending installation of the rebuilt ARM64 driver.

The unsafe dual-handle experiment can be selected separately:

```powershell
.\scripts\benchmark-m6-arm64.ps1 `
  -ProxySyncPolicy guest -ProxyFuaUnlocked -ProxyDispatcherThreads 8
```

This intentionally omits `FSCTL_LOCK_VOLUME` and is only appropriate for the
known Windows-unused ext4 test partition.

## Experimental SharedRingV1 transport

WinSpd now contains an experimental driver-owned shared-memory transport
under the existing transaction and storage callback APIs. The initial path
has a fixed aligned submission/completion ring and buffer pool, batched
`WAIT`/`KICK` doorbells, and reuses `SPD_IOCTL_TRANSACT_REQ`,
`SPD_IOCTL_TRANSACT_RSP`, and the existing `SPD_STORAGE_UNIT_INTERFACE`.
Select it with `--transport shared-ring`.

Runtime validation requires installing the matching rebuilt ARM64 driver. The
ring dispatcher uses a fixed userspace worker pool and batches completions.
In ring mode WslPart now associates the source handles with an IOCP and submits
partition reads and writes directly from/to the shared slots; legacy transport
keeps its existing per-operation completion path.

The matched direct-I/O suite's partition random-write value (9.68 IOPS) was an
isolated pathological outlier, not a valid steady-state comparison. Targeted
QD32 repeats with this same guest-flush, unbuffered, overlapped SharedRing
configuration reached 173K IOPS without final end-fsync and 179K IOPS with it.
The outlier coincided with 36 Windows Disk event 153 retries on the synthetic
WinSpd disk; the controlled repeats had no event 153 warnings. Microsoft's
event guidance identifies 153 as a Storport-miniport request timeout. The
evidence points to a transient completion stall/timeout somewhere in the
WinSpd miniport path, but does not yet identify its cause. See the findings log
for exact test results and caveats.

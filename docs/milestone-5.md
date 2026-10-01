# Milestone 5 — usable `wslpart` tool

The ARM64 prototype now exposes a small operational CLI while retaining the
WinSpd-backed storage path.

## Commands

List physical partitions from an elevated PowerShell:

```powershell
.\build\bin\Release\wslpart-ARM64.exe list
```

Attach a partition read-only, which is the default:

```powershell
.\build\bin\Release\wslpart-ARM64.exe attach `
  --disk 0 --partition 16 --expected-start-sector 3775834112
```

For writable use, the source volume must be exclusively lockable:

```powershell
.\build\bin\Release\wslpart-ARM64.exe attach `
  --disk 0 --partition 16 --expected-start-sector 3775834112 --readwrite
```

The process prints the generated `\\.\PHYSICALDRIVE<N>` and the corresponding
command to attach it to WSL with `--bare`. The proxy remains running until WSL
detaches the disk, Ctrl+C is received, or the optional named shutdown event is
signalled.

The WinSpd userspace dispatcher count can be overridden for experiments:

```powershell
.\build\bin\Release\wslpart-ARM64.exe attach `
  --disk 0 --partition 16 --readwrite --dispatcher-threads 2
```

The default is two dispatcher threads for both modes. Ordinary reads and
writes are concurrent in the default overlapped mode; only explicit flushes
close the atomic write gate and take the exclusive flush mutex.

Native FUA can be enabled explicitly for a writable attach:

```powershell
.\build\bin\Release\wslpart-ARM64.exe attach `
  --disk 0 --partition 16 --readwrite --fua
```

Because Windows volume locking restricts access to the file object that owns
the lock, FUA mode uses one locked
`NO_BUFFERING | WRITE_THROUGH | OVERLAPPED` handle for all source I/O.
FUA writes therefore complete with write-through semantics without a separate
`FlushFileBuffers`; explicit flushes still use the same handle.

For the M6 I/O-concurrency experiment, the partition handle can instead use
operation-local overlapped I/O:

```powershell
.\build\bin\Release\wslpart-ARM64.exe attach `
  --disk 0 --partition 16 --readwrite --buffering none `
  --sync-policy guest --io-mode overlapped --dispatcher-threads 8
```

Overlapped reads and ordinary writes may run concurrently. The proxy admits
writes with an atomic gate and in-flight counter rather than a per-request
userspace lock. Explicit flushes serialize through a rare flush mutex, close
the write gate, wait for active writes to drain, and call `FlushFileBuffers`
before reopening the gate. The SRW I/O lock remains only for synchronous
file-pointer mode; the backend no longer performs userspace read-modify-write.

## Safety checks

- Source handles must resolve to a physical disk partition with a GPT or MBR
  partition style.
- Dynamic, Storage Spaces, and other multi-extent volume objects are rejected
  when they do not resolve to a physical disk device number.
- The source partition start and length are retained for reporting, but I/O is
  translated relative to the partition handle: virtual byte 0 is source byte
  0.
- The generated WinSpd disk is identified by its new appearance, unique
  WinSpd serial, and exact capacity, so an older or equal-sized WslPart disk is
  not silently selected.
- Read/write mode locks and dismounts the source before creating the proxy and
  flushes before unlock and close.
- Attaching different source partitions concurrently is supported. Attempting
  to attach the same source twice in read/write mode is rejected by the second
  exclusive volume lock. Read-only duplicates should not be used as writable
  filesystems because Linux would then have multiple independent block-device
  views of the same filesystem.

## Test

Run the elevated CLI/lifecycle smoke test:

```powershell
.\scripts\test-m5-cli-arm64.ps1
```

It creates a read-only proxy for the known test partition, attaches it to WSL,
confirms Linux sees a standalone WslPart disk, detaches it, signals graceful
shutdown, and verifies the process exits successfully.

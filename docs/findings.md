# Investigation findings

This file records observed behaviour and exact versions after each milestone.
Do not replace observations with assumptions.

## 2026-09-29 — baseline and Milestone 1 preparation

### Host

- Host architecture: ARM64 (`ARM64-based PC`, `OSArchitecture: ARM64`)
- WSL guest architecture query was inconclusive through the current PowerShell
  wrapper, but the Windows host architecture is the relevant constraint for
  loading the WinSpd Storport driver.
- Windows product: Windows 10 Home
- Windows version: 2009
- OS build: 28000
- Current directory: repository root
- WSL default distribution: Ubuntu
- WSL default version: 2
- WSL version: 2.7.13.0
- WSL kernel: 6.18.33.2-2
- WSLg: 1.0.73.2
- MSRDC: 1.2.7214
- Direct3D: 1.611.1-815285011
- No `cmake`, `msbuild`, `cl`, `clang`, or `dotnet` command was found on PATH.
- `git` and `wsl.exe` are available. `winget` is available but its default
  Microsoft Store source requires an interactive agreement, so package
  installation was not attempted automatically.
- The WinSpd v1.0B1 release exposes the binary asset
  `winspd-1.0.20357.msi`; its SHA-256 is
  `F1157EEF805DCBEC78A477F2B4EE5ABC0049C8A9329444E5D18CAB01D3604265`.

### WinSpd source

- Repository: https://github.com/winfsp/winspd
- Local checkout: `third_party/winspd`
- Revision: `55c53bc454afbbba38bd1692f52beb77ed59142f`
- Revision date: 2020-12-22 13:01:38 -0800
- The checkout contains `tst/rawdisk/rawdisk.c` and the Visual Studio solution
  under `build/VStudio`.
- The checked-out WinSpd solution and rawdisk project expose Win32 and x64
  configurations only; no ARM64 project configuration is present.
- The v1.0B1 release exposes one MSI asset (`winspd-1.0.20357.msi`) rather than
  a separately identified ARM64 package. Do not assume its x64 driver can load
  on this ARM64 host.
- The stock sample supports Read, Write, Flush, and Unmap. For the initial
  experiment we will run it with writes and Unmap disabled where possible.
- The stock sample creates a partition table only when its backing file starts
  at zero length. The Milestone 2 helper therefore preallocates the file to an
  exact nonzero size before starting the sample.

### Safety status

- No physical disk handle was opened.
- No volume was locked or dismounted.
- No WinSpd device was created.
- No WSL disk was attached.

### 2026-09-29 — ARM64 build prerequisites verified

- Visual Studio Build Tools 2022: 17.14.41 (complete installation).
- MSVC toolset: 14.44.35207; compiler reports version 19.44.35229 for ARM64.
- MSBuild: 17.14.60.43110; ARM64-targeting executable selected.
- Windows SDK: 10.0.26100.0.
- Windows WDK package: 10.1.26100.6584.
- WDK headers include `storport.h`.
- WDK libraries include the ARM64 `storport.lib`.
- The Visual Studio ARM64 developer shell is available with
  `-Arch arm64 -HostArch amd64`; `VSCMD_ARG_TGT_ARCH=arm64` and
  `VSCMD_ARG_HOST_ARCH=x64`. This is an ARM64 target build; the host tool
  process setting is an implementation detail of this VS installation.
- `Inf2Cat.exe`, `signtool.exe`, and `stampinf.exe` are installed. `Inf2Cat`
  is located in the WDK x86 tool directory while the signing/stamping tools
  also have ARM64 copies.
- No driver has been installed and test-signing mode has not been enabled.
- The WDK integration component `Component.Microsoft.Windows.DriverKit.BuildTools`
  is now installed, so MSBuild provides the `WindowsKernelModeDriver10.0`
  platform toolset.
- The ARM64 Spectre runtime component
  `Microsoft.VisualStudio.Component.VC.Runtimes.ARM64.Spectre` is now installed.

### 2026-09-29 — native ARM64 WinSpd build

- Added native ARM64 project configurations for the WinSpd shared library,
  userspace DLL, Storport driver, rawdisk sample, and `devsetup` utility.
- The old project globally defined Windows 7 target macros. For ARM64, the
  driver project now places Windows 10 target macros last so the current WDK
  exposes the required kernel APIs.
- Updated the ARM64 driver allocation compatibility and corrected the catalog
  script's WDK `Inf2Cat` discovery. The installed WDK stores `Inf2Cat.exe`
  under `bin\10.0.26100.0\x86`, not the legacy `bin\x86` location.
- Successful Release ARM64 artifacts:
  - `winspd-ARM64.sys`
  - `winspd-ARM64.dll`
  - `rawdisk-ARM64.exe`
  - `devsetup-ARM64.exe`
  - `winspd-arm64.cat` and `winspd-ARM64.inf`
- `dumpbin /headers` reports `AA64 machine (ARM64)` for the driver, DLL,
  rawdisk sample, and devsetup utility.
- No driver has been installed, no test-signing mode has been enabled, and no
  physical disk handle has been opened.
- The current coding shell is not elevated, so driver installation was not
  attempted. The generated driver is signed with the local WDK test
  certificate; `Get-AuthenticodeSignature` reports an untrusted test root.

### 2026-09-29 — Milestone 3 read-only real partition

- Selected volume: `\\?\Volume{2a2ea915-6b3d-4f9c-9760-7078235ac4d0}`.
- User-provided partition start: sector `3775834112` (byte offset
  `1933227065344`). The proxy validated the discovered partition start against
  this value.
- Windows did not recognize the ext4 filesystem through the DOS Volume GUID
  path (`ERROR_UNRECOGNIZED_VOLUME`). The proxy resolved the GUID with
  `QueryDosDevice` to the underlying `HarddiskVolume` device and opened that
  partition device read-only. It did not open `\\.\PhysicalDrive0` and did not
  add the partition offset to I/O requests.
- Discovered capacity: `52427751424` bytes (48.8 GiB), logical sector size
  512 bytes. The virtual disk capacity matched the partition exactly.
- Windows exposed one synthetic `Virtual WinSpd WslPart` disk as disk 1. The
  parent NVMe disk 0 remained online; the synthetic disk was RAW and was not
  given to Windows filesystem mounting.
- Elevated `wsl.exe --mount \\.\PHYSICALDRIVE1 --bare` succeeded. Linux saw
  `/dev/sdd`, 48.8 GiB, model `WslPart`, with `ext4` directly on the disk and
  no partition child.
- Mounted `/dev/sdd` with `ro,noload`. `blkid` reported UUID
  `02d8d766-a5b7-4b34-a1dd-db6a4571883d`, label `UbuntuA16Root`, and the
  expected filesystem contents were readable.
- No source lock was taken, no writes were implemented or issued, and cleanup
  completed: filesystem unmounted, WSL detached, proxy stopped, and the
  synthetic disk disappeared.

Milestone 3 read-only acceptance criteria are met. The next milestone is
exclusive volume ownership and write/flush support.

### 2026-09-29 — Milestone 4 writable lifecycle and follow-up

- Added opt-in `-w` mode. Read-only remains the default.
- Writable startup acquired `FSCTL_LOCK_VOLUME`, then issued
  `FSCTL_DISMOUNT_VOLUME` while the lock was held. The lock handle remained
  open for the proxy lifetime.
- `FSCTL_ALLOW_EXTENDED_DASD_IO` returned `ERROR_INVALID_PARAMETER` for this
  unrecognized ext4 volume device. It is optional here; the proxy continued
  only for this known unsupported result, while retaining partition-device
  bounds enforcement and explicit request bounds checks.
- WSL mounted `/dev/sdd` read/write. A 4 MiB test file was written with
  `dd conv=fsync`; checksum:
  `a21b7618207370f6824ba78d81c17c812ad3716f1cb110f774823a596d908513`.
- Completed the full cycle: unmount, WSL detach, proxy termination, proxy
  recreation, WSL reattach, remount, checksum verification, test-file removal,
  sync, unmount, detach, and proxy termination.
- The parent NVMe disk remained online throughout. The selected partition was
  not accessed by Windows while the lock was held.

The initial writable lifecycle run reported a matching checksum after proxy
recreation. A later repeatability run, using the same selected partition,
found that the test file disappeared after a filesystem remount even while
the same proxy process remained alive. The repeat used explicit flushes and
`FILE_FLAG_WRITE_THROUGH`; the issue is therefore not accepted as resolved.

The host was clean after each run: no proxy process or synthetic disk
remained, and the parent NVMe disk stayed online. UNMAP remains disabled.
Milestone 4 is not currently accepted as reproducible. The next task is to
isolate the raw partition write path and filesystem state before adding more
lifecycle polish. This does not justify a custom kernel driver.

- A read-only `e2fsck -fn` pass through the proxy completed cleanly afterward:
  `209997/1048576 files`, `2318979/4194304 blocks`. This makes filesystem
  corruption an unlikely explanation for the disappearing test file.
- The follow-up same-attachment remount reproduced the loss, including after
  explicit `FlushFileBuffers` on every write and `FILE_FLAG_WRITE_THROUGH` on
  the writable source handle. The backend needs further instrumentation before
  writable support can be accepted.
- A non-mutating post-close verification was then added around a new 1 MiB
  temporary file. The file was created through the writable proxy, its ext4
  extent was recorded, WSL was detached, and the proxy source handle was
  closed. A separate ARM64 utility reopened the selected partition directly
  read-only at offset `50634752` for `1048576` bytes. The direct SHA-256 matched
  Linux exactly:
  `30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58`.
  This proves the write reached the real partition and survived closure of the
  proxy handle; the earlier in-session readback was not merely the only copy.
- The temporary file was removed and a subsequent read-only `e2fsck` completed
  cleanly. The remaining failure is specifically that a WSL reattachment does
  not reliably expose data that is present when read directly from the source
  partition. The stock file-backed WinSpd control shows the same detach/
  reattach symptom, so this is now being investigated as WSL/Hyper-V guest
  reattachment or cache state rather than source-partition write durability.
- The named-event proxy shutdown path timed out after WSL detach in the direct
  verification harness, so the harness closed the already-detached test proxy
  forcefully. This is a lifecycle issue to fix separately; it did not affect
  the direct post-close read result.
- The proxy debug log shows successful `WriteFile` and `FlushFileBuffers` calls
  for the real partition, and the same-proxy test can remount the filesystem
  within one WSL invocation and read back the matching checksum. Therefore
  real-partition writes do reach the selected partition and are readable again
  before the WSL disk detach boundary.
- A stock file-backed `rawdisk-ARM64.exe` control reproduced the same loss when
  the unchanged WinSpd disk was detached and reattached. The backing image was
  independently inspected with `debugfs` after the failed reattach; the test
  file inode and its extents were present, and `e2fsck -fn` reported no errors.
  This shifts the investigation away from the partition handle and translation
  code toward WSL/Hyper-V disk detach and reattach behavior or stale guest
  block-cache state. A Linux-device-removal wait did not change the result.
- A corrected three-view probe narrowed this further. After the first detach,
  with the stock process stopped so the image could be opened independently,
  `debugfs` showed inode 14, the root-directory entry
  `wslpart-stock-detach.bin`, and extents `8615-9638` in
  `artifacts/m1/m1.rawdisk`. After recreating and reattaching the synthetic
  disk, `debugfs` reading the raw `/dev/sdd` showed the same inode and directory
  entry. However, mounting `/dev/sdd` through ext4 and looking up the same file
  still reported `No such file or directory`. The previous probe that reported
  a missing backing-image file used an incorrect `debugfs` path and was
  discarded. This means the metadata is present both in the image and through
  raw Linux block reads; the inconsistency occurs at or above the normal ext4
  mount/VFS view, not because the directory update failed to reach storage.

- The real-partition cycle harness was then corrected to verify the actual
  reattach path rather than only direct source bytes. It explicitly records the
  reattached mount source, filesystem type, mount options, directory listing,
  checksum, and temporary-file removal result. The first complete
  real-partition cycle passed: the reattached mount was `/dev/sdd`, `ext4`,
  read/write with `sync`; the directory listing showed the existing filesystem
  contents and the new 1 MiB file; the reattach SHA-256 matched the original
  Linux checksum exactly; and `REMOVE_STATUS=0` was reported. The direct
  post-close source read also matched. The parent disk remained online and the
  synthetic disk was removed during cleanup.
- Two older named test files from previous runs were subsequently removed
  through the writable proxy cleanup script. No proxy or synthetic disk remains.
- The proxy now advertises write caching (`CacheSupported = TRUE`) while
  leaving native FUA disabled. In the guest-flush policy, ordinary overlapped
  reads and writes run concurrently; an explicit flush takes the exclusive
  source barrier, waits for active writes, calls `FlushFileBuffers`, and only
  then completes. The proxy performs a final flush while the source remains
  locked before deleting the storage unit and unlocking the partition. UNMAP
  remains disabled.
- After this cache/flush change, two additional complete real-partition cycles
   passed with matching direct and reattached checksums. ARM64 translation tests
   and the ARM64 build also passed. At the time of this observation, the
   verifier still force-closed the already-detached proxy because its named
   shutdown event request used the wrong access mask; that verifier issue was
   corrected in the subsequent lifecycle test below.

### 2026-09-29 — Milestones 1 and 2 completed

- Installed the locally built ARM64 package through the stock `devsetup`
  utility. The `WinSpd` kernel service is running and the installed driver is
  `C:\Windows\System32\drivers\winspd-arm64.sys`.
- Prepared `artifacts\m1\m1.rawdisk` as a 2 GiB file. The stock sample was
  started with `-c 4194304 -l 512`; this explicit block count is required
  because the sample defaults to 512 MiB.
- Windows exposed disk 1 as `Virtual WinSpd RawDisk`, 2 GiB, RAW.
- Elevated `wsl.exe --mount \\.\PHYSICALDRIVE1 --bare` succeeded.
- Linux reported the new device as `/dev/sdd`, 2 GiB, model `RawDisk`, with no
  child partition. Kernel logs showed `WinSpd RawDisk` through SCSI and
  `hv_storvsc`.
- Formatted `/dev/sdd` directly as ext4, mounted it, wrote and synced
  `test.txt`, detached WSL, stopped the sample, recreated the device, and
  reattached it. The file and contents persisted.
- Cleanup completed: WSL is detached and the rawdisk sample is stopped. The
  test backing file and ARM64 WinSpd driver remain installed for follow-up.

Milestone 1 and Milestone 2 success criteria are met. No physical disk or
partition has been opened.

## Decision log

- WinSpd's existing Storport miniport, userspace library, and SCSI path remain
  the kernel/storage implementation. No custom kernel driver is planned
  unless benchmarking or a concrete compatibility limitation justifies one.
- The local WinSpd ARM64 changes are build-portability work intended to become
  an upstream PR for signed ARM64 release artifacts through WinSpd's existing
  pipeline. They are not a new kernel storage design.
- Partition discovery, raw partition access, write support, and locking were
  added only after the stock WinSpd → WSL path was proven.
- The ARM64 path is intentionally native-only: build the WinSpd ARM64 driver,
  WinSpd ARM64 userspace DLL, and ARM64 rawdisk/proxy process. Do not install
  or maintain x86/x64 cross-targets unless a concrete toolchain failure makes
  one necessary.

- A final cache/flush audit was completed on the real partition. The proxy
  advertises `CacheSupported = TRUE` and `FuaSupported = FALSE`, so Linux can
  express durability through explicit flushes rather than a claimed native
  FUA path. The source handle retains normal Windows caching in the default
  policy; ordinary writes do not flush individually, while explicit WinSpd
  flushes take the exclusive barrier and call `FlushFileBuffers`. The Read
  callback also honors WinSpd's flush-before-read flag. Shutdown performs a
  final source flush before unlock.
- The corrected real-partition cycle completed with graceful shutdown rather
  than force termination. The trace contains `wslpart shutdown event received`,
  `wslpart dispatcher stopped`, `wslpart final flush begin`, and
  `wslpart final flush end`; both the WinSpd dispatcher-exit flush and the
  explicit final source flush returned `ok=1`. The reattached ext4 mount and
  checksum verification passed, and the temporary file was removed.
- The earlier shutdown timeout was a verifier bug: it opened the named event
  with `EVENT_QUERY_STATE` instead of `EVENT_MODIFY_STATE`. The verifier now
  requests `SYNCHRONIZE | EVENT_MODIFY_STATE`, so the proxy receives the
  shutdown signal and executes its normal flush, storage-unit removal, volume
  unlock, and close sequence.

### Milestone 5 implementation

- The ARM64 CLI now supports `list` and `attach` commands while retaining the
  original option form for test scripts. `list` reports partition start,
  capacity, logical sector size, physical sector size, style, and partition
  device path. `attach` prints the generated WslPart PhysicalDrive and the
  exact `wsl.exe --mount ... --bare` command.
- Source validation now requires a GPT or MBR partition, a physical disk
  device number, nonzero partition number, and logical-sector-aligned start
  and length. Volume identifiers are additionally checked with
  `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS` and must resolve to exactly one
  extent matching the selected partition. This rejects multi-extent volume
  objects rather than silently treating them as one partition.
- Generated-device discovery snapshots existing WslPart disks before unit
  creation and matches the newly appearing disk by its WinSpd GUID-derived
  serial number and exact capacity. The shared `WslPart` model name is only a
  class marker; multiple equal-sized instances remain distinguishable.
- The native ARM64 build, translation tests, `--help`, and `list` commands
  pass. The elevated `test-m5-cli-arm64.ps1` smoke test passed: the new CLI
  created `\\.\PHYSICALDRIVE1`, WSL reported a standalone 48.8 GiB `WslPart`
  disk, WSL detached it, and the proxy exited with code 0 after its graceful
  shutdown event.

### Milestone 6 baseline benchmark

- The first M6 benchmark used `fio-3.41` from Ubuntu WSL, kernel
  `6.18.33.2-microsoft-standard-WSL2`, cached I/O (`direct=0`), a 256 MiB
  workload file, one job, and 20-second 4K random tests. The fsync-heavy test
  used a 16 MiB file and `fsync=1`. The ordinary-Wsl-VHDX comparison ran on
  the distro root filesystem. A native whole-disk comparison was not attempted
  because the parent disk is the live Windows OS disk.

  | Workload | WSL VHDX | WinSpd partition | Proxy CPU |
  | --- | ---: | ---: | ---: |
  | Sequential write | 15058.82 MiB/s | 277.96 MiB/s | 2.15% |
  | Sequential read | 11130.43 MiB/s | 2015.75 MiB/s | 10.97% |
  | 4K random read | 5140.64 MiB/s / 1,316,004 IOPS | 27.71 MiB/s / 7,095 IOPS | 13.01% |
  | 4K random write | 5164.86 MiB/s / 1,322,203 IOPS | 2439.98 MiB/s / 624,634 IOPS | 4.30% |
  | 4K fsync-heavy write | 1600 MiB/s / 409,600 IOPS | 0.71 MiB/s / 181 IOPS | 6.20% |

- These cached results show that Linux is coalescing ordinary writes: cached
  4K random writes through the proxy are much faster than the fsync-per-write
  workload. The fsync-heavy result exposes the cost of the conservative
  backend `FlushFileBuffers` path. The read results also show that this test
  does not isolate Windows Cache Manager behavior; the next controlled M6
  comparison should use Linux direct I/O and then evaluate a Windows
  `FILE_FLAG_NO_BUFFERING` variant without changing the safe default.
- A second pass used the same workloads with `fio --direct=1`, bypassing the
  Linux page cache. The proxy measured approximately 550.54 MiB/s sequential
  write, 1479.77 MiB/s sequential read, 22.56 MiB/s (5777 IOPS) 4K random
  read, 3.71 MiB/s (950 IOPS) 4K random write, and 1.56 MiB/s (400 IOPS)
  fsync-heavy write. The proxy process used 11.38%, 0%, 16.86%, 11.13%, and
  7.72% of one CPU respectively during those jobs.
- Comparing cached and direct passes confirms that Linux caching/coalescing is
  responsible for most of the apparent cached random-write throughput. The
  direct pass is the appropriate baseline for evaluating whether removing the
  Windows Cache Manager layer improves the uncached path; no `NO_BUFFERING`
  change has been made yet.

### Milestone 6 sync-policy experiment

- An experimental cached pass used `--sync-policy guest --buffering cached`.
  This changes two coupled Windows-side behaviors: it removes
  `FILE_FLAG_WRITE_THROUGH` from the writable source handle and only calls
  `FlushFileBuffers` for guest-requested flush/FUA operations. It is not the
  safe default.
- In that pass, the proxy measured 1024 MiB/s sequential write, 1896.30 MiB/s
  sequential read, 29.43 MiB/s (7533 IOPS) 4K random read, 2545.95 MiB/s
  (651763 IOPS) cached 4K random write, and 18.41 MiB/s (4713 IOPS) for the
  4K `fsync=1` workload. The conservative `always`/cached result for the same
  fsync workload was 0.71 MiB/s (181 IOPS).
- The fsync improvement is substantial, but this experiment does not isolate
  the individual effects of Windows write-through, per-write flushes, and
  guest flush frequency. A later controlled run should separate those knobs
  before changing the production policy.
- The first unbuffered-handle attempt was interrupted by a stale WSL attach
  left when an elevated benchmark window was forcibly closed; it produced no
  performance report. The benchmark harness now bounds each fio job and checks
  proxy liveness, and the WSL VM was reset before retrying.
- A clean `--sync-policy always --buffering none` pass then completed. It
  measured 510.98 MiB/s sequential write, 1333.33 MiB/s sequential read,
  27.59 MiB/s (7064 IOPS) cached 4K random read, 2662.88 MiB/s (681698 IOPS)
  cached 4K random write, and 1.08 MiB/s (278 IOPS) for fsync-heavy writes.
  Compared with the cached Windows-handle baseline, disabling Windows
  buffering improved sequential writes but reduced sequential reads; random
  read was unchanged and fsync performance remained dominated by flush cost.
- A clean combined `--sync-policy guest --buffering none` pass also completed.
  It measured 1361.70 MiB/s sequential write, 1954.20 MiB/s sequential read,
  21.81 MiB/s (5584 IOPS) cached 4K random read, 2823.46 MiB/s (722806 IOPS)
  cached 4K random write, and 19.25 MiB/s (4929 IOPS) fsync-heavy writes.
  This is the fastest combination in these runs, but it relaxes durability
  semantics and should remain experimental until a persistence/crash-safety
  test is completed for it.
- After both buffering experiments, the normal real-partition persistence
  verifier completed successfully. It wrote a temporary ext4 file, verified
  its bytes by direct partition reads after close, reattached the partition,
  remounted it, verified the checksum, and removed the temporary file. No
  WslPart disk or proxy process remained afterward. This validates filesystem
  integrity after the benchmark sequence, but is not a crash test of the
  relaxed guest policy.

### Dispatcher configuration

- The proxy now defaults to two dispatcher threads for both modes. Ordinary
  overlapped reads and writes are concurrent; explicit flushes take the
  exclusive source barrier.
- `wslpart-ARM64.exe` now accepts `--dispatcher-threads N` for positive counts,
  and the M6 benchmark accepts `-ProxyDispatcherThreads N` to pass the value
  through. The ARM64 proxy rebuild and CLI help check passed. No dispatcher
  performance comparison has been run yet with the original synchronous
  partition backend.

### Overlapped partition I/O experiment

- The original backend opened one partition handle without
  `FILE_FLAG_OVERLAPPED`, moved its shared file pointer with `SetFilePointerEx`,
  and serialized reads and writes under an exclusive lock. Extra WinSpd
  dispatcher threads could therefore contend on the same synchronous path.
- The proxy now accepts `--io-mode sync|overlapped`. Overlapped mode opens the
  partition with `FILE_FLAG_OVERLAPPED`, gives each request its own
  `OVERLAPPED` and event, waits for `ERROR_IO_PENDING`, and uses physically
  aligned WinSpd dispatcher buffers for unbuffered I/O. Volume
  lock/dismount/unlock controls use the same completion handling.
- Ordinary overlapped reads and writes are concurrent. Writes share the
  source barrier only while issuing the backing I/O; explicit flushes take
  its exclusive side, which waits for active writes before calling
  `FlushFileBuffers`. The userspace unbuffered read-modify-write path has been
  removed; WinSpd now reports the source physical block length and alignment
  offset in READ CAPACITY(16), and the proxy passes aligned WinSpd buffers to
  the Windows raw handle.
- WinSpd now has a separate FUA capability bit. WslPart leaves FUA disabled
  initially, so Linux expresses durability through explicit flush commands;
  the proxy does not claim native FUA durability yet.
- The ARM64 proxy and translation tests build and pass. Benchmarking the new
  mode requires an elevated process; the current agent process cannot launch a
  UAC child because its inherited environment contains duplicate `PATH`/`Path`
  entries and Windows returns `0xc0000142` during elevated process startup.
- The patched ARM64 Storport driver must be installed before runtime testing;
  an already-installed stock WinSpd driver will not emit the new physical
  block and LALBA fields.

### WinSpd PR #14 experiment

- The pinned WinSpd source did not contain PR #14. The PR changes the
  userspace transaction path to pass an explicit `OVERLAPPED` structure to
  `DeviceIoControl` and wait for completion when necessary, addressing a
  reported hang rather than changing storage caching.
- A temporary ARM64 build of PR #14 was benchmarked using the fastest local
  policy, `--sync-policy guest --buffering none`. Relative to the stock
  WinSpd build in the same harness:

  | Workload | Stock | PR #14 |
  | --- | ---: | ---: |
  | Sequential write | 1361.70 MiB/s | 1398.91 MiB/s |
  | Sequential read | 1954.20 MiB/s | 2048.00 MiB/s |
  | 4K random read | 21.81 MiB/s / 5584 IOPS | 27.83 MiB/s / 7124 IOPS |
  | 4K random write | 2823.46 MiB/s / 722806 IOPS | 2688.15 MiB/s / 688166 IOPS |
  | 4K fsync-heavy write | 19.25 MiB/s / 4929 IOPS | 19.35 MiB/s / 4953 IOPS |

- The result is mixed: random reads improved approximately 28%, sequential
  operations changed only a few percent, fsync was unchanged, and random
  writes fell approximately 5%. One run is not enough to claim a general
  throughput improvement, but PR #14 is a reasonable candidate for reducing
  stalls and improving read-side concurrency. The working tree and ARM64
  binaries were restored to the pinned stock WinSpd build after the test.

### 2026-09-30 — concurrent I/O and physical-sector geometry

- The proxy default is now normal Windows-cached I/O, guest-requested flushes,
  operation-local overlapped source I/O, and two WinSpd dispatcher threads.
  Ordinary reads and writes do not impose submission ordering. Writes take a
  shared source barrier while issuing I/O; explicit flushes take the exclusive
  side, wait for active writes, and call `FlushFileBuffers` before completing.
- Userspace read-modify-write handling was removed. With `--buffering none`,
  the proxy supplies aligned WinSpd request buffers but passes each complete
  logical-sector request directly to the partition handle.
- WinSpd's storage-unit ABI now carries physical block length, physical-block
  alignment offset, and an independent FUA capability bit. READ CAPACITY(16)
  reports the physical/logical ratio and LALBA derived from those fields;
  WslPart advertises `FuaSupported = FALSE` by default and only enables it in
  the explicit FUA experiments.
- The native ARM64 WinSpd driver, userspace proxy, and translation tests built
  successfully. Translation tests passed. The upstream WinSpd test project was
  not built because it has no `Release|ARM64` configuration; no x64 fallback
  was used.
- The first opt-in FUA implementation opened a second
  `FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED`
  handle, but `FSCTL_LOCK_VOLUME` then failed with `ERROR_ACCESS_DENIED`.
  Windows restricts a locked volume to handles for the file object that owns
  the lock. FUA mode now uses one locked
  `FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED`
  handle for all source I/O. FUA writes do not issue a separate
  `FlushFileBuffers`; explicit flushes and shutdown use the same handle. The
  mode forces unbuffered overlapped I/O and is not the default.
- The FUA-capable ARM64 driver, proxy, and translation-test builds completed;
  translation tests passed. Runtime FUA durability and performance on the
  physical partition remain unmeasured until the rebuilt driver is installed.
- The separate `--fua-unlocked` mode now permits the proposed dual-handle
  experiment by intentionally skipping `FSCTL_LOCK_VOLUME`, dismount, and
  unlock. It is restricted to an explicit warning path for the Windows-unused
  ext4 test partition and is not a safe general writable mode.
- The first FUA-unlocked M6 comparison used eight dispatcher threads,
  guest-flush policy, unbuffered overlapped I/O, and the same cached Linux
  workloads as the non-FUA run. Relative to the non-FUA proxy run, FUA-unlocked
  measured approximately -21% sequential write, -13% sequential read, -1%
  4K random write, unchanged 4K random read, and -7% fsync-heavy write. This
  run shows no performance benefit from the dual-handle FUA path; FUA remains
  experimental and opt-in.
- The overlapped write admission path was changed from an SRW shared lock to
  an atomic gate and in-flight counter using `WaitOnAddress`/
  `WakeByAddressAll`. Ordinary reads and writes can therefore proceed without
  taking a userspace lock. A flush serializes through the rare flush mutex,
  closes the write gate, waits for the in-flight count to reach zero, calls
  `FlushFileBuffers` on the backing handle(s), and reopens the gate. The SRW
  I/O lock remains only for synchronous file-pointer mode. The ARM64 proxy and
  translation tests rebuilt successfully and translation tests passed.
- A fresh eight-dispatcher benchmark using the atomic gate measured 1430.17
  MiB/s sequential write, 2461.54 MiB/s sequential read, 24.33 MiB/s 4K
  random read, 2650.67 MiB/s 4K random write, and 17.98 MiB/s fsync-heavy
  4K write. Against the earlier same-configuration run, this was approximately
  -6.7%, -1.0%, +10.1%, -6.9%, and -13.0%, respectively. The accompanying
  WSL VHDX baseline also varied substantially, so the small changes are not
  conclusive; there is no consistent overall gain from the gate change.
- Before SharedRingV1, the overlapped backend still created one event and
  synchronously waited with `GetOverlappedResult` for each backing operation.
  That remains the legacy path. Ring mode now uses an IOCP completion thread
  and submits source reads/writes directly against the shared data slots, so
  ring dispatcher workers are not held by backing-device latency.

### SharedRingV1 transport: initial implementation

- The transport-independent WinSpd dispatch switch is now exposed as
  `SpdStorageUnitProcessRequest`. It accepts the existing
  `SPD_IOCTL_TRANSACT_REQ`, a transport-resolved `DataBuffer`, and produces
  the existing `SPD_IOCTL_TRANSACT_RSP`; the legacy dispatcher uses this same
  path.
- Added the initial SharedRingV1 ABI envelope: `SPD_RING_REQUEST`,
  `SPD_RING_COMPLETION`, `SPD_RING_BUFFER_REF`, and `SPD_RING_HEADER`.
  Existing transaction request/response structures were not modified.
- Added driver-owned shared-section establishment through new ring open/close
  service controls. The mapping contains the header, fixed SQ/CQ regions, and
  an aligned fixed buffer area. The driver validates dimensions, owns the
  section, maps a system view and the owning userspace view, and reclaims the
  system mapping during process-loss cleanup.
- Added batched `WAIT`/`KICK` ring doorbells. The kernel fills SQ entries using
  the existing `SpdSrbExecuteScsiPrepare` path and an authoritative pending
  table; userspace drains those entries into a fixed worker pool, calls the
  common storage-interface dispatcher, and uses a single completion thread to
  batch CQ entries and kick the kernel. Existing deferred callback completion
  is supported through `SpdStorageUnitSendResponse`. WslPart ring mode uses
  an IOCP-backed source path with no userspace bounce buffer.
- Added `SpdStorageUnitOpenSharedRing`/`CloseSharedRing` and a
  `--shared-ring-test` WslPart mode that validates the mapped header and writes
  a userspace heartbeat. `--transport shared-ring` selects the experimental
  request path.
- The ARM64 WinSpd driver, DLL, WslPart proxy, and translation tests build
  successfully; translation tests pass. Runtime mapping validation requires
  installing the newly rebuilt ARM64 driver before running
  `--shared-ring-test`.
- Ring-mode source I/O now uses an IOCP associated with the normal and
  optional FUA handles. Each submitted operation owns a unique OVERLAPPED
  context and uses the shared ring slot as the ReadFile/WriteFile buffer;
  there is no additional WslPart bounce buffer. Completion performs the
  existing response callback, including the existing post-write flush policy.
- The ring runtime now protects deferred-response teardown with an owner and
  transient reference count, so a completion racing dispatcher shutdown
  cannot dereference a freed runtime object. The ARM64 DLL and proxy rebuild
  after this change succeeded and translation tests still passed.
- The driver now keeps immutable SQ/CQ/buffer offsets, counts, and slot size in
  kernel-owned storage. Ring processing no longer trusts those layout fields
  after mapping, since the userspace view is writable. The driver rebuild
  succeeded; the translation test suite now also checks SharedRingV1 layout
  arithmetic and ABI envelope sizes.
- Ring-mode IOCP shutdown is serialized against new submissions with a source
  lock. This prevents a shutdown thread from closing the completion port while
  a ring worker is still submitting a backing operation.
- Driver ring close now stops the storage I/O queue, wakes a blocked WAIT, and
  waits for active WAIT/KICK calls before unmapping the section and freeing the
  authoritative pending table. The ARM64 driver rebuild completed without
  warnings or errors.
- On the latest runtime check, PnP reports `oem8.inf` (the rebuilt
  2026-09-30 package) as the best-ranked installed driver for
  `ROOT\\SCSIADAPTER\\0000`, but the running
  `C:\\Windows\\System32\\drivers\\winspd-arm64.sys` hash still differs
  from the rebuilt SYS. The service has not yet been restarted with the new
  image, so no SharedRingV1 runtime result is claimed.
- Added `scripts/install-winspd-arm64.ps1`, an elevated replacement and
  verification script. It stops WinSpd, removes the selected published
  package, installs the freshly built INF, restarts the service, and compares
  the loaded SYS hash with the build artifact before reporting success. The
  script parses successfully but has not been run from this non-elevated
  session.
- A direct invocation from the current shell was rejected by `#Requires
  -RunAsAdministrator`; a `Start-Process -Verb RunAs` attempt did not change
  the service state. The running service remains `RUNNING` with loaded SYS
  SHA-256 `0F15894F28DFBDC85820816216F49D72D41BE614824A436F43E9C2F45173E1AF`,
  while the rebuilt SYS is now
  `EB80BC5516B2350A515E1B745FBCDC631A09F40C72A525ACBFEB84732F832364` after
  the teardown and prepared-SRB-abort fixes and explicit test signing. The catalog/SYS membership
  verifies with `signtool`, and the ARM64 translation tests pass;
  SharedRingV1 runtime behavior remains unverified.
- Added `scripts/sign-winspd-arm64.ps1` to sign the test ARM64 SYS, regenerate
  the ARM64 catalog with `Inf2Cat`, sign the catalog, and verify catalog
  membership. This avoids the legacy `mkcat.bat` dependency on a developer
  shell's `signtool` PATH and makes rebuild/package preparation reproducible.
- Corrected `SpdStorageUnitRingClose` to wait indefinitely for active ring
  calls; the previous zero timeout only polled `RingIdleEvent`. Also abort
  prepared SRBs when post-prepare ring validation fails. The driver rebuilt
  with zero warnings/errors. The final signed SYS hash is
  `EB80BC5516B2350A515E1B745FBCDC631A09F40C72A525ACBFEB84732F832364`.
  The userspace ARM64 targets rebuilt successfully and the translation tests
  passed again after this change.
- After the goal was resumed, the built/loaded hashes were rechecked and still
  differed. A second attempt to launch the installer through `Start-Process
  -Verb RunAs` was rejected by the execution policy before the elevated
  process started, so it produced no installer output and made no system
  change.

### 2026-09-30 — SharedRingV1 first real-partition runtime

- Environment observed: Windows 10 Home, build 28000, ARM64; WSL 2.7.13.0;
  WSL kernel 6.18.33.2; WinSpd source commit
  `55c53bc454afbbba38bd1692f52beb77ed59142f`; signed ARM64 SYS hash during
  the successful run:
  `D4A48F2B03DA4475B4E1DC73A3227BAF53D4890849F3A01DAA276FDE4B15FB31`.
- The initial real-partition SharedRingV1 run briefly enumerated Disk 1 and
  then surprise-removed it. Diagnostics showed one published request followed
  by zero-kind entries. Root cause was a timeout-status handling bug:
  `STATUS_TIMEOUT` is non-negative, so `NT_SUCCESS(STATUS_TIMEOUT)` evaluated
  true and the ring published an empty request after the pending SRBs were
  drained. The fix explicitly handles `STATUS_TIMEOUT` before `NT_SUCCESS`.
- After that fix, the real ext4 partition opened through its Volume GUID as a
  read-only backing handle and appeared in Windows as:
  `WinSpd WslPart`, Disk 1, 52,427,751,424 bytes. The proxy used
  SharedRingV1, cached Windows I/O, overlapped source I/O, an IOCP completion
  thread, and two ring workers.
- `wsl.exe --mount \\.\PHYSICALDRIVE1 --bare` succeeded. Linux reported:
  `sdd disk 48.8G ext4 WslPart`; there was no `sdd1` and no parent physical
  disk. Linux reported 4096-byte physical blocks, write protection, read cache
  enabled, and no FUA support.
- The filesystem mounted read-only directly from `/dev/sdd` at LBA 0. The
  mount exposed the expected ext4 root and the existing `wslpart-m6.fio` file;
  `df -T` reported `/dev/sdd` as ext4. This is the first end-to-end proof of
  SharedRingV1 request transport plus real-partition reads through WSL.
- The filesystem was unmounted, WSL was detached, the proxy was stopped via
  its named shutdown event, and Windows returned to only the parent Disk 0.
  The final stop log showed `ERROR_OPERATION_ABORTED` (995) from the blocked
  ring wait after the intentional shutdown; no proxy or synthetic disk
  remained.

### 2026-09-30 — SharedRingV1 writable-page fault and final M4 persistence

- The first writable real-partition SharedRingV1 attempt caused a Windows
  `0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL` bugcheck while ext4 was being mounted.
  The dump resolved to `winspd_arm64!SpdSrbExecuteScsiPrepare`, specifically
  the driver-side copy of a WRITE payload into the shared data slot at
  `DISPATCH_LEVEL`. The backing userspace proxy had not yet received that
  request, so this was a ring mapping fault rather than a partition I/O or
  filesystem persistence result.
- The shared section was pagefile-backed and its views were not pinned for
  driver-side DISPATCH_LEVEL access. The driver now creates an MDL for the
  owning process's user view during ring establishment, probes and locks the
  pages for the ring lifetime, and unlocks them before unmapping during
  teardown. The first implementation attempted to pin the kernel view and
  correctly failed with `ERROR_NOACCESS` 998; that was changed to the user
  view, which is accepted by Windows.
- Final ARM64 driver build/package verification succeeded. The loaded driver
  hash matched the rebuilt artifact:
  `FE031078598BD6D026B5118FE5F10086E90FF27759E56EDF4CF3BF6A703DC6E7`.
  The SharedRingV1 mapping smoke test passed with SQ/CQ 64 and 64 pinned
  1-MiB buffers.
- With cached Windows source I/O, guest flush policy, two SharedRingV1
  dispatcher threads, and the normal exclusive writable-volume path, the
  real-partition test completed successfully. It created a 1-MiB temporary
  file, unmounted and detached the proxy, verified the file extent directly
  through the closed partition handle, recreated the proxy, reattached WSL,
  remounted `/dev/sdd` as ext4 at LBA 0, and obtained the same SHA-256:
  `30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58`.
- The final cleanup returned Windows to only the physical parent Disk 0;
  no synthetic WslPart disk or proxy process remained.

### 2026-09-30 — SharedRingV1 process-death stress

- Added `scripts/stress-shared-ring-process-death-arm64.ps1`. It attaches the
  real partition read-only through SharedRingV1, mounts the ext4 filesystem,
  starts a genuine `fio` `libaio` QD32 random-read workload, and force-kills
  only the proxy process while requests are outstanding.
- The driver process-notify path reclaimed the storage unit and Windows
  removed the synthetic WslPart disk without another bugcheck. No proxy
  process remained, the Linux mount was no longer present after cleanup, and
  the parent physical Disk 0 remained online.
- The first harness version used fio's synchronous engine and therefore only
  reached QD1; the corrected run used `libaio` and confirmed the intended
  outstanding-request condition. The forced termination produced no new
  Windows bugcheck.
- WSL has a host-side limitation after this crash-style removal: the former
  `\\.\PHYSICALDRIVE1` attachment can remain registered even after its
  synthetic Windows disk disappears. A normal `wsl --unmount` then fails with
  `Operation not permitted` and recommends `wsl --shutdown`; shutting down
  WSL cleared the stale attachment without touching the partition. Normal
  graceful proxy shutdown does not have this issue.

### 2026-09-30 — SharedRingV1 fastest-policy benchmark attempt

- Added `-SkipVhdxBaseline` to the M6 benchmark harness so repeated transport
  and policy runs can skip the unchanged VHDX comparison. The report records
  whether the baseline was included.
- The proxy-only SharedRingV1 run used the previously fastest measured source
  policy: guest-requested flushes, Windows `NO_BUFFERING`, overlapped source
  I/O, and eight dispatcher threads.
- The run completed sequential write/read and 4K random read, then failed
  during `randwrite4k`: the proxy process disappeared while Linux fio remained
  blocked on `/dev/sdd`. No benchmark JSON was produced, so this is not a
  performance result. It is a new correctness/lifecycle failure specific to
  the SharedRingV1 write path under the fastest no-buffering configuration and
  must be investigated before benchmarking that variant further.

### 2026-10-01 — SharedRingV1 userspace shutdown race investigation

- Windows Application events identified the earlier proxy termination as a
  userspace access violation in `winspd-ARM64.dll`, exception `0xc0000005`,
  module offset `0x4c34`. ARM64 disassembly maps that offset to the final
  `SPD_RING_HEADER` diagnostic read in `SpdStorageUnitRingDispatcherThread`.
- The ring dispatcher cached the shared-header pointer while a console/event
  shutdown callback could concurrently call `SpdStorageUnitShutdown`. The
  driver unprovisions the unit and unmaps the userspace ring view during that
  call, leaving the dispatcher with a stale pointer.
- Fixed the lifecycle ordering in the userspace WinSpd runtime: SharedRing
  shutdown now stops and cancels the ring dispatcher instead of immediately
  unprovisioning it; the dispatcher performs the final unprovision after its
  worker/completion threads have stopped. Removed the post-teardown shared
  header diagnostic dereference.
- The ARM64 DLL, WslPart proxy, and translation tests rebuilt successfully
  after the fix. The mapping smoke test passed under Administrator with SQ/CQ
  64 and 64 pinned 1-MiB buffers.
- A subsequent proxy-only benchmark was started with the same fastest policy,
  but its cleanup became stuck in WSL after the proxy disappeared. It produced
  no new Windows Application crash event and no benchmark JSON; therefore no
  performance result is claimed. The stale WSL/WinSpd attachment remains to be
  cleared before another real-partition run.

### 2026-10-01 — corrected random-read benchmark and ring doorbell counts

- The prior M6 harness used fio `ioengine=sync` with `iodepth=32`; this did not
  exercise 32 outstanding I/Os. Those old QD32 results are not valid queue-depth
  comparisons and should not be used to assess SharedRing performance.
- Updated the harness to use `io_uring` by default, record the requested and
  achieved queue depth, mean and p50/p95/p99/p99.9 completion latency, and fio
  context switches. `-DirectIO` records `DirectIO=true` and asks fio to use
  `O_DIRECT`, bypassing Linux's page cache. Warm-cache buffered reads are now a
  separately labeled mode with a sequential pre-read, rather than an implicit
  and inconsistent cache state.
- Added SharedRing runtime counters for submission/completion batch counts,
  total requests, maximum batch size, worker count, and SQ/CQ/buffer sizes.
  Added `--ring-depth` to WslPart and `-RingDepth` to the benchmark harness.
- A direct-I/O QD32 matched run (Ubuntu on WSL kernel
  `6.18.33.2-microsoft-standard-WSL2`, fio 3.41, Windows build 28000,
  guest flush, Windows `FILE_FLAG_NO_BUFFERING`, overlapped partition I/O,
  eight WinSpd dispatchers, 256-MiB test file) measured:

  | Transport | IOPS | Mean clat | p50 | p95 | p99 | p99.9 |
  |---|---:|---:|---:|---:|---:|---:|
  | Legacy | 61,170 | 520 us | 514 us | 594 us | 668 us | 1,729 us |
  | SharedRingV1 (depth 64) | 67,689 | 471 us | 235 us | 322 us | 424 us | 1,401 us |

  This is a single matched run (+10.7% IOPS), not yet a repeatable performance
  claim. Both fio runs achieved QD32. The SharedRing run counted 1,354,516
  requests in 398,901 submission waits (3.39 requests/wait) and 164,212
  completion kicks (8.25 responses/kick; maximum batch 64). This confirms the
  ring does not ring once per request, but low-queue-depth tests show the
  completion doorbell often has little opportunity to batch.
- A 10-second direct-I/O QD sweep at ring depth 64 produced these single-run
  results (the QD64 `AverageQueueDepth` report field was initially misparsed
  because fio reports that histogram bucket as `>=64`; use requested QD and
  fio's raw depth histogram for that point):

  | fio QD | Legacy IOPS | SharedRing IOPS |
  |---:|---:|---:|
  | 1 | 5,544 | 1,943 |
  | 4 | 20,979 | 8,099 |
  | 8 | 41,675 | 14,906 |
  | 16 | 60,939 | 72,404 |
  | 32 | 61,013 | 97,349 |
  | 64 | 60,811 | 161,695 |

  Early results suggest SharedRing's advantage appears at higher queue depth;
  QD1–QD8 are slower and QD32–QD64 faster in this sweep. The spread and tail
  latency require repeated runs before changing defaults. The harness now
  handles fio's `>=64` bucket when computing achieved depth.
- The 32-slot ring configuration also completed a read-only QD32 test, proving
  `--ring-depth 32` maps correctly. A prior buffered QD32 comparison varied
  widely with cache state (11k–128k IOPS); do not use it for transport or ring
  size conclusions. The controlled direct-I/O sweep bypasses Linux page cache.
- ARM64 build and translation tests passed after adding counters, fio controls,
  and ring-depth configuration. The read-only benchmark runs left only the
  parent physical Disk 0 online; no WslPart proxy remained. No kernel driver
  source changed in this tuning pass.
- An initial direct-I/O QD32 completion-batch sweep (10 seconds per point)
  varied the response cap and wait timeout. These are noisy single runs, but
  showed the expected batching response and exposed timer granularity:

  | Max batch | Wait | IOPS | Responses per kick | Mean clat | p99 clat |
  |---:|---:|---:|---:|---:|---:|
  | 8 | 0 ms | 64,925 | 3.88 | 491 us | 453 us |
  | 8 | 1 ms | 126,468 | 7.97 | 251 us | 514 us |
  | 16 | 0 ms | 68,881 | 4.23 | 462 us | 473 us |
  | 16 | 1 ms | 46,845 | 15.84 | 681 us | 528 us |
  | 32 | 0 ms | 128,718 | 6.16 | 246 us | 610 us |
  | 32 | 1 ms | 77,123 | 31.11 | 412 us | 717 us |
  | 64 | 0 ms | 142,359 | 4.30 | 223 us | 461 us |
  | 64 | 1 ms | 2,009 | 17.19 | 15,890 us | 30,015 us |

  The 1-ms wait for an unfillable 64-response batch incurred approximately
  15-ms-scale clat, consistent with ordinary Windows waitable timeout
  granularity; a millisecond timeout is therefore not safe to implement with
  `SleepConditionVariableSRW`. The runtime was changed to use a high-resolution
  waitable timer plus a completion event when an explicit wait is configured.
  That replacement built; the subsequent UAC-approved direct-I/O tests and
  microsecond refinement are recorded below. The option remains opt-in and
  default wait remains zero.

### 2026-10-01 — sub-millisecond completion coalescing

- Replaced the completion-wait control with microsecond units end-to-end:
  `SpdStorageUnitSetSharedRingCompletionBatch`, the proxy's
  `--ring-completion-wait-us`, and benchmark option
  `-RingCompletionWaitMicroseconds`. The former `--ring-completion-wait-ms`
  remains as a compatibility alias. The high-resolution waitable timer is set
  in 100-ns units. ARM64 build and translation tests pass.
- Corrected the batching condition after review: the completion thread waits
  only while other requests remain in flight. If the just-completed request is
  the only active request (e.g. QD1), it kicks immediately instead of adding
  the configured timeout to every I/O.
- All runs below were fio 3.41 `io_uring`, `--direct=1` (Linux page cache
  bypassed), 4-KiB random reads from the test partition, eight dispatchers,
  overlapped unbuffered source I/O, and ring depth/buffer count 64. QD32 sweeps
  achieved average depth 32.03. `Wait` is the maximum completion coalescing
  wait; no-wait remains the default.
- Initial single-run QD32 wait sweep, batch cap 64, 10 seconds per setting:

  | Max wait | IOPS | Mean clat | Responses/kick |
  |---:|---:|---:|---:|
  | 0 us | 111,986 | 283 us | 3.25 |
  | 10 us | 125,999 | 251 us | 7.83 |
  | 25 us | 55,931 | 569 us | 7.49 |
  | 50 us | 121,747 | 260 us | 7.86 |
  | 100 us | 98,520 | 321 us | 8.08 |

- A differently ordered repeat at 20 seconds per setting remained highly
  variable: 50 us yielded 125,769 IOPS, 0 us 29,505, 100 us 65,420, and 10 us
  73,252. This is too noisy to claim a throughput improvement or choose a
  nonzero default; response aggregation did consistently increase to about
  7.3–7.6 responses/kick for the nonzero waits.
- With the in-flight guard enabled, a short QD1 check showed one response per
  kick at both 0 and 50 us, with no obvious timeout-sized latency floor
  (5,111 vs. 5,846 IOPS; single 10-second runs). At QD32, 0 us measured
  135,571 IOPS (3.47 responses/kick) and 50 us 123,813 IOPS (7.41
  responses/kick), also single runs. Keep zero as the default pending more
  controlled repeats.
- The only Windows disk left online after these read-only runs is the parent
  SSD; the synthetic proxy is detached and no proxy/fio process remains.

### 2026-10-01 — response correlation and ring/transfer-size sweeps

- Inspection of the kernel's RingWait path confirmed the existing opaque hint
  format is `(generation << 32) | pending_slot`, and for data operations the
  shared buffer slot is that same pending slot. Replaced the userspace
  per-response linear scan of every work item under the exclusive runtime lock
  with a bounds-checked direct lookup by the hint's low 32-bit slot. The code
  checks that the item is active and the full generation-tagged hint and
  operation kind match; duplicate active slots and data-slot/token mismatches
  fail closed. No kernel or request/response ABI changes. ARM64 build and
  translation tests pass, and direct-I/O reads completed at ring depths 32, 64
  and 128 without correlation errors.
- Ring-depth tests used QD32, batch cap 32, zero wait, 4-KiB direct random
  reads, and 10 seconds requested runtime. A post-lookup run measured 135,384
  IOPS at depth 32, 65,729 at depth 64, and 62,752 at depth 128. Earlier and
  later runs varied substantially (including some 16–24 second fio drain
  runtimes despite 10 seconds requested), so this is not enough evidence to
  select a ring depth; keep 64 as the established setting for now. One initial
  test correctly rejected batch cap 64 with ring depth 32 (Win32 error 87); the
  benchmark now validates/skips such invalid combinations before attaching.
- Exposed `--max-transfer-length` for controlled tuning, retaining 1 MiB as
  the default. Values must be 4-KiB aligned between 4 KiB and 1 MiB; for
  SharedRing the fixed slot size follows the advertised MaxTransferLength.
  Direct-I/O QD32 tests compared 64 KiB, 256 KiB, and 1 MiB at ring depth 32.
  Random-read results stayed roughly 136k–143k IOPS, with no repeatable win.
  Sequential-read results ranged from about 1.15 to 1.37 GiB/s in the first
  pass, but a repeat included a 66-MiB/s outlier for 64 KiB and reversed which
  size led. Keep 1 MiB as the default; chunk size appears workload- and
  run-sensitive.
- At ring depth 64, changing MaxTransferLength also produced inconsistent
  random-read results (about 39k–134k IOPS across 64 KiB–1 MiB settings and
  repeats). This does not establish that the shared-pool footprint is the
  cause of the earlier ring-depth spread. The benchmark does bypass Linux's
  page cache (`DirectIO=true`); the large run-to-run/drain variation remains a
  measurement issue to investigate before tuning defaults.
- These were read-only fio workloads. After each completed run, only the
  parent physical SSD remained online; no synthetic proxy, fio, or wslpart
  process remained.

### 2026-10-01 — QD128 completion-batch sweep at ring depth 256

- Extended the userspace ring-depth limit from 255 to 256; no kernel-driver
  change was needed. At 1 MiB slots the driver section cap prevents depth 256,
  so this 4-KiB-only sweep used 256-KiB slots: a 64-MiB payload pool plus ring
  metadata. All requests were direct-I/O random reads from the test ext4
  partition; no writes were issued. Build and translation tests passed.
- With QD128, ring depth 256, no completion wait, and eight dispatcher
  workers, one 20-second run per completion batch measured:

  | Batch cap | IOPS | p99 | p99.9 | p99.99 | Actual responses/completion batch |
  |---:|---:|---:|---:|---:|---:|
  | 8 | 206,572 | 954 us | 2,073 us | 5,734 us | 7.9 |
  | 16 | 218,747 | 881 us | 1,352 us | 3,490 us | 15.6 |
  | 32 | 226,428 | 897 us | 1,483 us | 3,359 us | 28.3 |
  | 64 | 223,010 | 946 us | 1,827 us | 3,654 us | 34.0 |
  | 128 | 223,669 | 922 us | 1,810 us | 3,523 us | 37.2 |
  | 256 | 215,538 | 979 us | 1,647 us | 3,916 us | 38.8 |

- Batch 32 was the best single-run result, but batches 16–128 were within
  roughly 3.5% of one another and the ordering was not randomized/repeated.
  Larger configured caps did allow larger observed batches, but did not
  improve throughput. This does not justify increasing the current batch
  setting above 32; repeat with randomized order before treating the small
  differences as meaningful. fio's `iodepth_level` histogram groups all
  depths >=64 together, so the report's computed `AverageQueueDepth=64.06`
  for requested QD128 is only a lower bound, not a valid estimate of the
  actual mean depth. Fix that reporting before relying on it in later sweeps.
- The elevated sweep exited successfully. Afterward the synthetic disk was
  detached, no proxy/fio process remained, and only the parent SSD was online.

### 2026-10-01 — corrected WSL VHDX direct-I/O baseline

- Auditing the old baseline exposed that the benchmark path `/tmp` is mounted
  as `tmpfs` in this WSL instance (`findmnt -T /tmp`: `tmpfs`), not the distro
  VHDX. Thus the old 1,242,762-IOPS result in `benchmark-direct.json` was a
  RAM-backed result and must not be compared with either NVMe or SharedRing.
- Ran a new direct-I/O random-read sweep against a fully written 256-MiB file
  on the WSL distro root (`/dev/sdd`, ext4), with fio 3.41, `io_uring`,
  `O_DIRECT`, 20 seconds per depth, and QD 1/8/16/32/64/128. Measured:

  | fio QD | IOPS | Mean clat | p50 | p99 | p99.9 | p99.99 |
  |---:|---:|---:|---:|---:|---:|---:|
  | 1 | 7,899 | 123 us | 111 us | 272 us | 502 us | 3.19 ms |
  | 8 | 66,742 | 118 us | 111 us | 218 us | 444 us | 3.16 ms |
  | 16 | 109,341 | 145 us | 136 us | 276 us | 424 us | 1.53 ms |
  | 32 | 141,658 | 224 us | 218 us | 379 us | 545 us | 3.19 ms |
  | 64 | 155,638 | 409 us | 395 us | 766 us | 1.53 ms | 3.29 ms |
  | 128 | 92,599 | 1,379 us | 1,384 us | 1.66 ms | 2.90 ms | 24.51 ms |

- This is a real WSL distro-filesystem/VHDX result and is far below the
  impossible-looking tmpfs result. Compared with the SSD's quoted 620K QD32
  random-read ceiling, QD32 achieved about 23%. The QD128 drop and long tail
  need repetition before drawing conclusions. `O_DIRECT` bypasses Linux's
  page cache, but Windows/VHDX host caching was not explicitly disabled; the
  256-MiB working set may still be host-cacheable.
- The benchmark test directory was removed after the run. The parent physical
  SSD remains online; no proxy or fio process remains. The M6 harness now
  allocates its VHDX test directory under the WSL user's home on ext4 instead
  of `/tmp`, and uses a unique path to avoid deleting pre-existing data.
- Rechecked the path after the concern that `~/Documents` might resolve to the
  Windows profile: in this Ubuntu distro `$HOME` is on `/dev/sdd` (`ext4`,
  mount `/`), and `$HOME/Documents` is absent. The matched-suite command log
  shows its VHDX data file directly under a unique directory below `$HOME`, not
  in `Documents`; therefore that suite did not traverse the NTFS `/mnt/c` mount.
  Its fio result JSON files were written under `/tmp`, but those are output
  metadata, not the benchmark data file.

### 2026-10-01 — matched full direct-I/O VHDX vs partition suite

- Ran the full fio suite at QD32 for timed 4-KiB random workloads, using
  `io_uring`, `O_DIRECT`, 256-MiB test files, guest flush policy, overlapped
  unbuffered source I/O, SharedRing depth 64, completion batch 32, and eight
  dispatchers. The VHDX test file was under the WSL user's home on `/dev/sdd`
  ext4; the partition test used a newly generated filename, removed after `sync`
  and before unmount. No existing file was overwritten.

  | Workload | WSL ext4/VHDX | Passed-through partition | Comparison |
  |---|---:|---:|---:|
  | Sequential write | 1,718 MiB/s | 1,590 MiB/s | partition 7% lower |
  | Sequential read | 1,438 MiB/s | 1,455 MiB/s | partition 1% higher |
  | 4-KiB random read, QD32 | 140,135 IOPS | 62,875 IOPS | partition 55% lower |
  | 4-KiB random write, QD32 | 136,291 IOPS | 9.68 IOPS | partition run pathological |
  | 4-KiB fsync write, QD1 | 242 IOPS / 0.95 MiB/s | 2,792 IOPS / 10.91 MiB/s | partition 11.5x higher |

- Random-read p50/p99 latency was 214/481 us on VHDX and 200/432 us on the
  partition, but the partition's mean was 507 us and p99.99 was 5.14 ms versus
  225 us and 1.58 ms on VHDX, indicating worse rare-tail behavior. The
  partition random-write run took 39.4 seconds for a nominal 20-second job,
  with 3.28-second mean completion latency and 17.1-second p95/p99. Fio
  reported no error and the proxy's final flush succeeded, but this is not a
  meaningful steady-state write-performance result; investigate the write
  path/barrier interaction before repeating or drawing conclusions. The
  fsync-heavy result is an observed benchmark result, not by itself proof of
  equivalent durability semantics on both storage stacks.
- The VHDX QD32 direct random-read result is about 23% of the SSD's quoted
  620K-IOPS QD32 ceiling. This is plausible for the virtualized filesystem;
  the earlier 1.24M-IOPS result was from tmpfs and invalid. `O_DIRECT` bypasses
  Linux page cache, but Windows/VHDX host caching remains enabled/unspecified.
- PowerShell completed with exit code 0. The generated VHDX test directory and
  unique partition test file were removed. Only parent Disk 0 remains online;
  no proxy or fio process remains.

### 2026-10-01 — investigation of anomalous random-write result

- The full-suite partition `randwrite4k` result of 9.68 IOPS is not
  representative. It is an extreme outlier: controlled QD32 repeats with the
  same SharedRing/overlapped backend achieved 173,405 IOPS without end-fsync
  and 178,610 IOPS with the harness's final end-fsync. The latter completed
  normally in 20 seconds; its p99 completion latency was 301 us. The end-fsync
  therefore does not reproduce the collapse, and ordinary writes are not
  individually flushed under the configured guest sync policy.
- Windows System event log has 36 Disk event 153 warnings in the original
  anomaly window: 32 at 08:59:47 and one each at 08:59:57, 09:00:07, 09:00:17,
  and 09:00:27. Each says an I/O to **Disk 1**, PDO `\\Device\\0000028d`, was
  retried. The proxy log identifies Disk 1 as the WinSpd virtual disk
  `\\.\\PHYSICALDRIVE1`; no corresponding Disk 0 event 153 was found in that
  window. This correlates the outlier with retries in the virtual Storport/
  WinSpd path, rather than a demonstrated physical-SSD retry. Microsoft's
  storage troubleshooting guidance says Event 153 is logged when a Storport
  miniport times out a request. Since the affected device is the WinSpd virtual
  disk, this is stronger evidence of a miniport-path completion timeout than a
  generic disk warning. The event still does not tell us why the request was
  not completed in time, so the initiating defect remains unconfirmed.
- Source-path review confirms ring requests are dispatched to eight workers;
  reads/writes use overlapped source I/O and complete through the IOCP. The
  submission ring has 64 entries and the test QD is 32, so ordinary ring
  capacity exhaustion is not evident from configuration. The failed run's
  final proxy log reports 3,573,285 requests completed overall, zero dispatcher
  error, and a successful final flush. Aggregate end-of-run counters do not
  reveal whether individual requests were delayed or retried during the
  random-write phase.
- Current status: write throughput and end-fsync both work in controlled
  repeats, but the original 9.68-IOPS anomaly still needs a captured,
  phase-specific trace to identify whether the stall originated in Storport,
  WinSpd completion/queue handling, or transient Windows/device behavior. Do
  not use that single outlier as the partition's performance figure.

### 2026-10-02 — opt-in I/O latency diagnostics

- Added opt-in `--io-stats` proxy telemetry. It records overlapped I/O
  submit-to-IOCP latency buckets, maximum latency, counts over one second,
  maximum outstanding source I/O, and the duration/calls over one millisecond
  for posting a response into WinSpd. It emits one per-request log only for an
  I/O that takes at least one second; ordinary requests are not logged. The
  M6 benchmark harness records whether telemetry was enabled, and
  `scripts/repeat-randwrite-stall-diagnostic-arm64.ps1` is set up for three
  fresh-file QD32 direct-I/O random-write trials with per-trial Disk 153 event
  capture.
- The ARM64 Release build and translation tests pass. The test runner requires
  an elevated PowerShell to lock and expose the physical partition. The first
  `Start-Process -Verb RunAs` attempt failed with `0xc0000142` before UAC;
  launching the explicit Windows PowerShell executable with a correctly quoted
  argument list then succeeded and presented the expected elevation flow.

### 2026-10-02 — instrumented QD32 random-write repeats

- The corrected `Start-Process -Verb RunAs` invocation successfully launched
  the runner as Administrator. Three fresh-file, 20-second QD32 `io_uring`
  `O_DIRECT` random-write tests completed with guest flush policy, unbuffered
  overlapped partition I/O, SharedRing depth 64, completion batch 32, and eight
  WinSpd workers. The source partition was detached after each trial; no
  existing test file was overwritten.

  | Repeat | IOPS | MiB/s | Mean clat | p99 | p99.9 |
  |---:|---:|---:|---:|---:|---:|
  | 1 | 157,324 | 614.55 | 201 us | 301 us | 791 us |
  | 2 | 165,589 | 646.83 | 191 us | 289 us | 412 us |
  | 3 | 145,567 | 568.62 | 217 us | 289 us | 561 us |

- No Disk event 153 was recorded for proxy Disk 1 in any trial window. The
  detailed proxy telemetry was preserved only for the final repeat by the
  initial runner version: 2,911,778 writes submitted and completed,
  `pending-max=32`, no source I/O at or above one second, and maximum
  submit-to-IOCP latency 21,491 us. Response posting into WinSpd exceeded one
  millisecond once (maximum 2,081 us). This doesn't demonstrate a sustained
  lock bottleneck; the telemetry does not measure individual lock-wait time or
  kernel-side RingKick duration.
- The instrumented throughput is lower than the earlier uninstrumented 173K-
  to-179K-IOPS controlled repeats, so instrumentation overhead and run-to-run
  variation remain confounders. Nonetheless, the pathological multi-second
  stall and retry warnings did not recur in these three repetitions. The user
  declined further repeats; no additional benchmark was launched.
- All three event sidecars are under `artifacts/m6/` with prefix
  `retry-diagnostic-20261002-063002-r`. The final repeat's I/O histogram and
  rare slow-request log are in `artifacts/m6/proxy.events.log`.

### 2026-10-02 — SharedRing V2 simplification

- Removed configurable completion batch and wait controls. The completion
  thread now drains the current Done list and issues one RingKick; requests
  completed during that kick accumulate for the next pass. The earlier sweep
  results above remain historical measurements, while the current transport
  has no intentional completion delay.
- Collapsed the open ABI to `QueueDepth` plus `BufferSize`; SQ, CQ, kernel
  pending slots, shared buffers, and userspace work items use the same depth
  and slot number. RingWait accepts a userspace `MaxRequests` credit and fills
  no more requests than that credit, even when kernel slots become available
  before userspace has reclaimed its items.
- Userspace now tracks `FreeCount` and an explicit item-state enum. A slot
  becomes free only after RingKick succeeds. SQ and CQ counters publish once
  per batch. Kernel pending records retain each request's unique token so a
  delayed response cannot match a later use of the same slot. Worker count is
  capped at QueueDepth.
- Corrected READ CAPACITY (16) alignment reporting for non-zero physical
  offsets; a 512-byte offset in a 4096-byte physical block now reports LALBA
  7. Added driver-backed tests for ring open/close and cancellation,
  wraparound, synchronous and asynchronous responses, depth saturation,
  per-slot token reuse, and WAIT credit limits.

### 2026-10-03 — SharedRing V2 QD32 benchmark exposed slot reuse race

- A matched direct-I/O QD32 run used fio 3.41 `io_uring`, a 256-MiB file,
  guest flush policy, unbuffered overlapped source I/O, eight dispatchers,
  262144-byte transfers, and SharedRing depth 64. The legacy pass completed:
  97,451 random-read IOPS (326 us mean completion latency) and 135,760
  random-write IOPS (233 us mean latency). These are single-run measurements.
- The SharedRing pass stopped during test-file preparation before timed fio
  measurements. The proxy reported `SharedRing request token slot already in
  use` at request sequence 1720, slot 4, then stopped with error 13. The
  benchmark's blocked fio could not be canceled normally after the proxy
  stopped; the Ubuntu test distro was terminated to release the mounted test
  partition. No ring performance result is available from this pass.
- The cause was a concurrent WAIT/KICK slot-reuse race. WAIT could begin with
  free slots, block for its first request, then use a slot freed by KICK for a
  later request in that same WAIT. Userspace had not yet reclaimed the matching
  work item. The kernel now snapshots eligible free slots at WAIT entry and
  defers slots freed during that WAIT until the next WAIT. The ARM64 driver
  builds and signs; the signed package is installed and selected for
  `ROOT\SCSIADAPTER\0000` as `oem22.inf`. After reboot and re-enumeration, the
  WinSpd service is running and the installed SYS hash matches the build.

### 2026-10-03 — SharedRing V2 ring tests after driver install

- The first full test attempt passed lifecycle, wraparound, asynchronous
  response, and saturation, then stalled during the wait-credit test's disk
  discovery. The manual test path synchronously queried PhysicalDrive
  properties while it was also the only consumer of ring requests. This could
  block discovery and made later `RING_WAIT` failures misleading.
- Manual discovery now polls SetupAPI for the disk interface and avoids
  synchronous storage queries while manually consuming the ring. The test also
  reports a `RING_WAIT` Win32 error and tears down pending test I/O instead of
  continuing an unbounded loop. All five ring integration tests then passed:
  lifecycle, wraparound, asynchronous response, saturation, and wait credit.
- The clean suite passes, but the post-install QD32 SharedRing rerun still
  fails during the 256-MiB test-file preparation, before timed fio begins. It
  reports a token collision at request sequence 1312, slot 25. The prior
  `WaitAvailable` snapshot therefore does not fully prevent slot reuse. The
  mounted test partition is being detached; no ring performance result is
  available yet. The legacy numbers above remain single-run references.

### 2026-10-03 — SharedRing V2 exact-slot WAIT credits

- Fixed the remaining identity race by extending `RING_WAIT` with a bitmap of
  the exact userspace-free slots. The dispatcher snapshots item states while
  holding its runtime lock and sends that bitmap with `MaxRequests`. The
  kernel validates the bitmap and snapshots only those identities as eligible
  for that WAIT; a slot freed by KICK cannot be substituted unless userspace
  included that slot in its next WAIT bitmap.
- Updated the manual WAIT callers. The wait-credit integration test now offers
  only slot 3, exercising a sparse identity rather than only checking a count.
- The x64 WinSpd test binary and ARM64 driver compile successfully. The ARM64
  driver package was signed, installed as `oem33.inf` version `1.0.26278.0`,
  and activated after reboot; the installed SYS SHA-256 matches the build:
  `48C74589C92327FF6F4CBDA54DB94EF4EFBCAD8B756A6579F4344C22DE10F857`.
- All five ring integration tests pass against that driver: lifecycle,
  wraparound, async response, saturation, and WAIT credit. The older full
  WinSpd suite still encounters its known adapter pass-through failure at
  `ioctl_transact_read_test`; ring-specific tests were run separately.
- Rebuilt the ARM64 WslPart proxy against the enlarged WAIT ABI and reran the
  matched QD32 test on the same ext4 partition after reboot. Both 20-second
  fio workloads completed at average QD 32.03 with no slot collision or
  dispatcher error. SharedRing recorded 6,026,165 submissions and the same
  number of completed responses. Random read measured 136,638 IOPS and
  232.2 us mean latency; random write measured 164,571 IOPS and 192.09 us mean
  latency. These remain single-run results; the earlier legacy references
  were 97,451 random-read IOPS and 135,760 random-write IOPS.

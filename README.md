# wslpart

Expose one existing Windows physical-disk partition to WSL2 as a standalone
synthetic SCSI disk, using WinSpd for the Windows storage stack.

WSL currently attaches whole disks, not individual partitions, and cannot
attach the Windows installation disk. WslPart works around that limitation by
presenting one selected partition as its own disk. See Microsoft's [WSL disk
mounting limitations](https://learn.microsoft.com/en-us/windows/wsl/wsl2-mount-disk#limitations).

The project is being developed in milestones. Milestones 1 through 4 are
complete: the native ARM64 stock WinSpd disk attaches to WSL2, WSL can use a
filesystem directly at virtual disk LBA 0, a real ext4 partition passes
read-only passthrough, and writable persistence survives detach/reattach with
exclusive Windows volume ownership.

## Current status

- WinSpd is a pinned submodule under `third_party/winspd`; its current review
  working tree contains the Shared Ring V3 refactor.
- The host has WSL2 and a native ARM64 C++/WDK build toolchain installed.
- The WinSpd ARM64 Release driver, userspace DLL, rawdisk sample, and
  installation utility build successfully from source.
- The file-backed disk passed the WinSpd → WSL attach test and the
  filesystem-at-LBA-0 persistence test.
- A real ext4 partition passed read-only passthrough.
- Writable mode acquires the expected lock/dismount, rejects out-of-range
  requests, flushes successful writes, and passes detach/reattach verification.
- The Milestone 5 CLI supports `list` and `attach`, validates that the source is
  one contiguous physical GPT/MBR partition, identifies the newly-created
  WinSpd disk by capacity, and has a graceful shutdown test.

See [docs/milestone-5.md](docs/milestone-5.md) for the CLI and safety checks.
- Observations are recorded in [docs/findings.md](docs/findings.md).

## Safety boundary

Read-only is the default. Writable mode requires an exclusive Windows volume
lock and dismount before the proxy is created. The proxy must never expose the
parent physical disk to WSL; UNMAP remains disabled.

## Current: Milestone 6 baseline complete

The cached and Linux-direct M6 baselines are recorded. The default proxy path
uses normal Windows caching, guest-requested flushes, overlapped source I/O,
two dispatcher threads, and no userspace read-modify-write. WinSpd reports the
source physical-block geometry and alignment offset; native FUA remains
disabled by default until independently validated. An opt-in `--fua` mode
uses one locked unbuffered write-through overlapped handle, because Windows
volume locking does not permit a second independent volume handle. UNMAP
remains disabled.

See [docs/milestone-6.md](docs/milestone-6.md) for the workloads and results.

The experimental WinSpd `SharedRingV3` transport can be selected with
`--transport shared-ring`. Legacy per-request IOCTL transport remains the
default while V3 runtime validation is pending.

The native build and translation tests can be repeated with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-arm64.ps1
```

## Milestone 1 quick start

Install the prerequisites listed below, open PowerShell as Administrator, and
run these commands from the repository root:

```powershell
.\scripts\check-prereqs.ps1
.\scripts\prepare-m1-backing-file.ps1 -SizeGiB 2
```

Build or install WinSpd and use its stock `rawdisk-ARM64.exe` sample. The helper
prints the exact command for a preallocated file-backed disk, which avoids the
sample's automatic partition-table creation. Then verify the Windows disk and
WSL attachment manually:

```powershell
Get-Disk
wsl.exe --mount \\.\PHYSICALDRIVE<N> --bare
```

Inside WSL:

```bash
lsblk
dmesg | tail -100
```

Do not continue to the real-partition backend unless a new `/dev/sdX` appears.

## Dependencies

- Windows 10/11 with WSL2 and a kernel that supports `wsl --mount`.
- WinSpd driver/runtime and its userspace development files.
- Visual Studio 2022 Build Tools with the C++ workload, or a compatible MSVC
  installation. The checked-in WinSpd solution is the authoritative build
  path for the current stock sample.
- PowerShell 5+.

WinSpd is forked at <https://github.com/edbordin/winspd>. The current WinSpd
review working tree contains the experimental shared-memory transport and
related ARM64 build changes. Its upstream license and attribution remain
applicable to the submodule; WslPart's own code keeps its separate license and
attribution boundaries explicit.

The longer-term ARM64 driver-release goal remains an upstream pull request to
WinSpd's signing pipeline. A replacement kernel driver remains out of scope
unless measurements show a strong performance or compatibility reason.

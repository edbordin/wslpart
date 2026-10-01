# Milestone 1 — stock WinSpd to WSL

This experiment is intentionally file-backed. It does not exercise the
partition proxy and must pass before any real partition is opened.

## Prerequisites

Run [check-prereqs.ps1](../scripts/check-prereqs.ps1) from an elevated
PowerShell. The current WinSpd source checkout includes the Visual Studio
projects but not a prebuilt driver or runtime. Build/install WinSpd from its
own `build/VStudio/winspd.sln`, or install a compatible WinSpd release.

The stock sample needs the WinSpd driver/runtime installed and an elevated
process when creating an OS-visible disk. This project currently targets the
native ARM64 build only.

## Test A — WSL accepts a stock WinSpd disk

1. Prepare a nonzero backing file:

   ```powershell
   .\scripts\prepare-m1-backing-file.ps1 -SizeGiB 2
   ```

2. Start the stock sample using the printed command, for example:

   ```powershell
   .\third_party\winspd\build\VStudio\testing\build\Release\rawdisk-ARM64.exe `
       -f "...\artifacts\m1\m1.rawdisk" -W 1 -C 1 -U 0
   ```

3. In another elevated PowerShell, record the disks before and after starting
   the sample:

   ```powershell
   Get-Disk | Format-Table Number,OperationalStatus,PartitionStyle,Size,BusType
   ```

4. Identify the newly-created synthetic `\\.\PHYSICALDRIVE<N>` and attach it
   without asking WSL to parse partitions:

   ```powershell
   wsl.exe --mount \\.\PHYSICALDRIVE<N> --bare
   ```

5. In WSL, record:

   ```bash
   lsblk -o NAME,TYPE,SIZE,FSTYPE,MODEL
   dmesg | tail -100
   ```

### Pass condition

A new `/dev/sdX` appears. If WSL rejects the device, stop here and record the
exact Windows error, WSL output, and Linux log. Do not add the partition
backend yet.

On this ARM64 host, this experiment completed with `/dev/sdd` as a 2 GiB
`RawDisk` device and no partition child. The exact observed result is recorded
in [findings.md](findings.md).

### Cleanup

After recording the result:

```powershell
wsl.exe --unmount \\.\PHYSICALDRIVE<N>
```

Stop the stock `rawdisk-ARM64.exe` process with Ctrl-C. Do not remove the
backing file until the next milestone has used it.

## Test B — optional stock sample sanity check

The upstream tutorial also exercises the sample through its named pipe and
`stgtest`. That test is useful for separating WinSpd/sample problems from
WSL problems, but it is not a substitute for Test A.

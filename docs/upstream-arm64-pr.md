# Upstream ARM64 release plan

`wslpart` intentionally uses WinSpd's existing Storport miniport, userspace
library, and SCSI implementation. It does not plan to replace them with a
custom kernel driver.

The local ARM64 work in `third_party/winspd` is a build-portability prototype:

- add ARM64 configurations to the existing Visual Studio projects;
- use the current WDK's ARM64 target settings and allocation API;
- make catalog generation recognize the current WDK tool layout; and
- produce the existing driver, DLL, samples, and installation utility as
  ARM64 artifacts.

This is not a new storage implementation. Once the prototype is stable, the
changes can be proposed upstream as an ARM64 release-build addition so WinSpd
can sign and publish the driver through its existing release pipeline.

Until benchmarking or a concrete WinSpd limitation demonstrates otherwise,
`wslpart` will not grow a replacement Storport miniport.

# Mapping SRB payload pages into the backend process

Research date: 2026-10-23. Documentation and current source review only; no
driver changes, installation, or runtime mapping experiment were performed.

## Finding

Windows provides the components needed to expose an outstanding SRB's payload
pages directly to a userspace backend. This is a feasible direction for WinSpd's
virtual miniport. It is not yet a verified fast path on our machine, and the
documentation does not establish a size at which mapping beats copying.

The backend would receive a new user virtual address aliasing the SRB's physical
pages. It must not receive the SRB's kernel pointer, and the pages need not be
physically contiguous.

## Documented mechanisms

1. [StorPortGetOriginalMdl](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/storport/nf-storport-storportgetoriginalmdl)
   obtains the MDL associated with an SRB, including extended SRBs. Check both
   status and the returned descriptor; unavailable or unsuitable memory must
   use the existing copy path.
2. [IoBuildPartialMdl](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iobuildpartialmdl)
   describes a bounded subrange of an existing locked buffer without copying
   its payload. A slot-owned partial MDL is a candidate for describing one
   chunk while leaving the original descriptor owned by the storage stack.
3. [MmMapLockedPagesSpecifyCache](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-mmmaplockedpagesspecifycache)
   with UserMode creates an address in the current process for MDL-described
   pages. User mappings require IRQL at or below APC_LEVEL, exception handling,
   and are always non-executable. MdlMappingNoWrite can additionally make a
   mapping read-only. An existing system mapping does not rule out a user
   alias; cache attributes must remain consistent with the physical pages.
4. [MmUnmapLockedPages](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-mmunmaplockedpages)
   removes that mapping, also at or below APC_LEVEL and in the process context
   in which it was created.

The mapping/unmapping pages mention the
[HwStorPortProhibitedDDIs rule](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/storport-hwstorportprohibitedddis).
The rule explicitly describes **physical** Storport miniports. WinSpd sets
AdapterInterfaceType to Internal and VirtualDevice to TRUE, matching Microsoft's
[virtual miniport model](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/initialization-of-storage-virtual-miniport-drivers).
That rule therefore does not by itself prohibit this approach in WinSpd.

The original MDL and its page locks remain borrowed. We must not free it or
unlock its pages. A partial MDL does not independently extend the source buffer's
lifetime. [Using MDLs](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/using-mdls)
explains that completing the underlying request permits the stack to release
its MDLs and locked pages. Any private mapping and descriptor must be cleaned
up before final SRB completion.

## Fit with the current implementation

Current READ/WRITE admission obtains a kernel address with
StorPortGetSystemAddress in `src/sys/scsi.c`. Preparation copies WRITE payloads
and completion copies READ payloads. These can become alternate strategies
selected by an explicit per-slot payload mode.

The backend in `src/wslpart/proxy.c` already passes its supplied buffer to
overlapped ReadFile/WriteFile. A correctly aligned mapped pointer is a candidate
for that same interface. The userspace ring dispatcher must first be extended
to resolve a mapped payload reference instead of always deriving an address
from BufferId. File-I/O alignment, asynchronous completion, and any assumptions
in the dispatcher still require runtime verification.

WinSpd already references the ring owner process and briefly attaches to it for
section-view cleanup. Mapping workers could use that process identity, with
short attach/map/detach and attach/unmap/detach sections outside metadata locks.
[KeStackAttachProcess](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-kestackattachprocess)
requires balanced detach and warns against complex operations or I/O while
attached. Backend I/O, waits for backend completion, SRB completion and unrelated
callbacks should remain outside the attached section. A process object reference
alone does not keep a terminating address space usable: mapping must participate
in process-exit/session rundown.

## Required eligibility and lifetime rules

- Resolve the exact SRB/chunk range within the original MDL, checking bounds,
  offsets and supported descriptor layout. Do not assume the original MDL starts
  at the current chunk or that a system virtual address is its original address.
  Initially fall back for layouts or relationships that cannot be established.
- Initially map only full-page-aligned ranges whose pages can safely be exposed.
  Partial MDLs bound byte ranges but do not provide sub-page access protection.
  Unaligned ends can expose bytes outside the requested payload. Keep copying
  for those requests, as well as small requests and UNMAP descriptor conversion.
- WRITE-to-disk mappings can be read-only to the backend; READ-from-disk mappings
  must be writable. Verify both with the actual backend I/O path.
- Finish mapping before Ready/SQ publication. Only fall back to a bounce buffer
  before publication. Keep payload mode fixed for the published transaction.
- Backend completion must mean all asynchronous I/O and buffer access has ended.
  Completion work then unmaps the user alias and releases private MDL resources
  before retiring the SRB or reusing the mapping metadata.
- Cancellation, reset, STOP, malformed CQ failure and process termination must
  retain the original SRB while its pages remain exposed or backend I/O can
  reference them. STOP must not wait for a CLOSE that the backend can issue only
  after STOP returns. Separate stopping publication from deferred mapped-SRB
  retirement and final quiescence.

The last rule changes current reset behavior materially. `SpdIoqReset` currently
can detach and retire an InFlight SRB while quarantining its separate shared
payload slot. That is safe only because the backend is using the bounce buffer.
For direct mappings, quarantining the slot alone is insufficient: completing
the SRB can release the very pages the backend is using. The mapped branch must
defer final SRB completion until safe cleanup. Revoking a user alias alone also
does not establish completion of an already-issued backend I/O operation.

## Slot representation and experiment

Retain the existing fixed buffers initially. Add an explicit Bounce/Mapped mode
and slot-owned bookkeeping for the user address, private partial MDL, length and
mapping lifetime. Keep any mapped address separate from the opaque generation
token used to validate completions. Add a negotiated transport mode/reference;
this requires kernel and userspace changes even if a versioned descriptor can
reuse existing space.

A first experiment should test page-aligned READ/WRITE at several sizes through
the existing preparation and completion workers. Verify data, multichunk offsets,
read-only WRITE mappings, resource-failure fallback, cancellation at each boundary,
terminal reset/STOP/CLOSE and owner-process exit before benchmarking. Measure
map, unmap, process-attachment and total transaction costs against memcpy, plus
CPU, latency tails and resource usage. No threshold is selected from research.

After correctness and a useful crossover are demonstrated, reduce preallocated
bounce-buffer capacity. Large requests that cannot be mapped will need bounded
copy-path chunks; shrinking the buffers must not remove that fallback.

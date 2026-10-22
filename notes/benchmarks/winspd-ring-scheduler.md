# Kernel worker and completion-path profiling — 2026-10-21

The profile supports testing a dedicated completion thread and then completion
parallelism. It does not support adding preparation workers as the first change.
The dominant observed costs are serialized notification/DPC processing on the
completion path, IOQ spinlock contention, and frequent performance-counter reads.
There is little thread descheduling inside the preparation/completion callbacks.

The independent pending/ready/completed queues remain the right ownership model:
these execution-context experiments can preserve slot leases, FIFO fences and
transport ownership. Replacing a work item with a dedicated thread and adding
multiple workers are separate experiments.

## Capture and controls

Nine successful ten-second workloads were captured after Blender finished:
QD1 READ and QD128 READ/WRITE, each with no trace, a CPU/DPC trace, and a full
scheduler trace. There is one observation per cell, so these are profiling
controls, not statistically established latency comparisons.

All runs used the same installed Release driver `1.0.26293.100`, default Storport
routing, preparation claim limit 32, detailed latency diagnostics disabled, eight
overlapped backend workers, direct I/O, ring depth 256, 128 buffers, and maximum
transfer 256 KiB. The always-present lock/copy/callback counters remain enabled;
disabling detailed diagnostics does not remove all timing overhead.

Driver SHA256: `2A612C24623AC50B55E355AAE2482E09E5B52D66F30980F6896B784265617395`.
Proxy SHA256: `CBC959082FC826B38E1193ADC8D19424AC956FB26A34DB1AE03F3185B967DCF8`.
Source: the existing guarded disk 0 / partition 16 benchmark, using unique 256 MiB
files. No driver replacement, reboot or scheduling-policy change was made.

WPR starts after file preparation and immediately before the timed fio invocation.
It stops after timed CPU/wall counters have been read. ETL merge, symbol lookup and
ETLX analysis are outside the measured window; analysis ran after all workloads.
The temporary system-awake request is restored after each run.

| Workload | No trace IOPS / p99 µs | CPU/DPC trace IOPS / p99 µs | Scheduler trace IOPS / p99 µs |
| --- | ---: | ---: | ---: |
| QD1 READ | 6,131 / 281 | 6,235 / 235 | 6,106 / 444 |
| QD128 READ | 179,140 / 1,073 | 176,715 / 1,139 | 162,603 / 1,286 |
| QD128 WRITE | 180,933 / 1,090 | 182,104 / 1,057 | 167,522 / 1,188 |

The lighter trace is within 1.7% of control IOPS in these observations. Full
scheduler tracing reduces high-depth IOPS by 7–9%, so its absolute latency and
callback costs should not be treated as unperturbed measurements. QD1 tails vary
substantially. Six ETLs have zero reported lost events, no truncation, and over
96.9% of CPU samples have stacks. Conversion reports some unmatched stack-walk
events; complete per-request attribution is not available.

## Findings

**Completion notification runs substantial work before returning.** A frequently
sampled default-policy READ stack is:

```text
SpdStorageUnitRingCompletionWorker
  StorPortNotification
    RaidAdapterRequestComplete
      KiInsertQueueDpc / KfLowerIrql
        KiExecuteAllDpcs
          RaidpAdapterDpcRoutine
            RaidUnitCompleteRequest
              IopfCompleteRequest / classpnp
                storvsp / vmbus / hypervisor notification
```

At least 66.8% of READ and 75.8% of WRITE completion-stage CPU samples contain
`StorPortNotification`. These are lower bounds because only the top 200 full
stack patterns are retained. Samples include DPC/interrupt work above the callback,
not just exclusive miniport execution. READ memcpy is the leaf in about 6.5% of
completion-stage samples. This agrees with the earlier detailed counters showing
notification calls dominating completion callback wall time.

**Preparation and publication have substantial lock overhead.** In the lighter
QD128 traces, the following percentages of each stage's samples have the named
function as their executing leaf:

| Stage | Spinlock wait READ / WRITE | Performance-counter read READ / WRITE |
| --- | ---: | ---: |
| Preparation | 39.5% / 34.3% | 34.5% / 34.3% |
| Producer | 39.8% / 37.1% | 29.1% / 29.3% |
| Completion | 5.9% / 5.0% | 15.1% / 12.3% |
| KICK | 38.6% / 42.1% | 17.5% / 15.3% |

Common lock stacks contain `SpdIoqAcquireSpinLock`; the producer frequently reaches
it through `SpdIoqStopped`, and preparation also reaches it while scheduling the
producer. Counter reads appear both in IOQ lock instrumentation and other stage
accounting. These are sampled execution shares, not per-SRB wait times. Timing
work performed while holding the metadata lock can also increase other CPUs'
spin time. Extra workers could aggravate this contention.

**Work already spreads across CPUs.** The lighter QD128 READ trace samples
completion on 15 CPUs and 14 system-worker thread IDs; WRITE samples it on 14 CPUs
and 15 thread IDs. Storport DPC events also span 15/14 CPUs. These counts show
placement over time, not simultaneous execution of multiple completion callbacks:
our single-owner completion-worker state still serializes that stage.

**Descheduling inside callbacks is small.** In the full QD128 READ trace, outgoing
completion-callback stacks account for 158 observed suspensions totaling 0.60 ms
over the roughly ten-second workload. Preparation totals 0.028 ms. WRITE totals
2.41 ms for completion and 0.14 ms for preparation. This uses TraceEvent's
`BlockingStack()` for the outgoing thread, not the incoming-thread stack returned
by `CallStack()`. It excludes time before callback entry and does not count DPC
execution on the same thread as descheduling. It therefore does not prove that
worker dispatch is free.

The earlier [detailed counters](winspd-ring-dpc-comparison.md), from separate
diagnostic builds, put QD128 default completion dispatch near 10 µs, versus about
145 µs waiting in the completed FIFO. A completion callback averages 116–125 µs
and about 25 claimed requests. Those distributions overlap and must not be added
as independent delays. They support a service/queueing bottleneck rather than
long mid-callback thread preemption. Removing repeated work-item dispatch may
still improve service capacity enough to reduce queueing near saturation.

## Recommended experiments

1. Compare one dedicated completion thread with the current completion work item,
   retaining batch size 32, the single CQ consumer and default routing. Let it
   drain additional batches without requeueing a work item, sleep when empty, and
   measure fairness, CPU and end-to-end latency. Start without hard CPU affinity.
2. Test a dedicated preparation thread separately. Keep one preparation owner;
   examine avoidable stopped/queue checks and timing overhead before adding any
   preparation parallelism.
3. If completion notification still limits service, compare two completion
   workers against one, with the same routing. Claim disjoint slot leases under
   the metadata lock and preserve logical-SRB/fence accounting. The current
   single-writer histograms, worker scheduling state and rundown logic must also
   be adapted; queue ownership alone does not make the existing callbacks safe
   for concurrent invocation.
4. Measure the cost of always-on timing instrumentation with an explicit sampled
   or disabled configuration. Preserve the normal counters and correctness tests;
   do not attribute the result of removing instrumentation to threading.

Use QD1/4/32/128 and matched untraced controls for the actual scheduling comparison.
Run CPU profiling separately. The success criterion is guest mean/p99/p99.9
latency with CPU and throughput recorded alongside it; relocating work beyond
our SRB-notification boundary is insufficient.

## Artifacts and reproduction

[CSV](winspd-ring-scheduler.csv) and [JSON](winspd-ring-scheduler.json) retain all
nine observations and profiling statistics. Local raw ETLs, exact summaries,
receipts and logs are under `artifacts/ring-scheduler/<run>/`. `summary.json` is
the authoritative analysis; earlier `scheduler-summary*.json` files from parser
bring-up are superseded. One initial attempt failed before I/O because an idle
WPR status was misinterpreted; subsequent captures corrected that guard.

Capture uses `scripts/profile-winspd-ring-scheduler.ps1` with `-TraceMode sampled`
or `scheduler`; `-WithoutTrace` provides a matched control. It requires elevation,
a matching installed-driver hash and a successful activation/test receipt. The
profile is copied into each new capture directory. An existing WPR recording is
never cancelled by this script.

`scripts/build-winspd-scheduler-analyzer.ps1` builds the analyzer using the installed
Visual Studio TraceEvent/DIA assemblies. Run the resulting `SchedulerSummary.exe`
with three arguments: ETL path, output JSON path, and a symbol path containing the
matching private WinSpd PDB plus Microsoft's public symbol server. Analyze after
benchmarking. Aggregate with:

```powershell
python -B scripts/report-winspd-ring-scheduler.py artifacts/ring-scheduler --output-prefix notes/benchmarks/winspd-ring-scheduler
```

The final audit passed with zero remaining storage units or proxy/capture
processes and the original physical disk only. All nine workloads report zero
transport errors and equal queued/published response counts. The existing 21-test
Release activation receipt still matches the unchanged installed driver.

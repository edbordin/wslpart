# Current ring versus historical VHDX results

The default ring claim limit is 32. QD32 is a reasonable starting point for concurrent throughput-sensitive work, QD1-4 for latency-sensitive work, and QD128 for bulk parallel work where more CPU and about 1 ms p99 are acceptable. These are starting points inferred from this workload, not a measured universal optimum. QD8/16/64 and realistic mixed workloads were not measured in the final sweep.

The subsequent [latency investigation](winspd-ring-latency.md) identifies
serialized CQ completion/Storport notification work as a material high-depth
delay; the FIFO capacity itself was held constant across the depth sweep.

## Historical VHDX comparison

This uses the October 9 direct-I/O, io_uring, 256 MiB VHDX observations at the matching requested depths, alongside the final October 20 ring results. Both random workloads use 4 KiB operations; random WRITE includes an end fsync. Historical VHDX timing is 20 seconds, current ring timing 10 seconds. Dates, runtime and background activity differ, and VHDX is a file-backed filesystem rather than the raw-partition path. This is a historical reference, not a new controlled comparison. CPU efficiency cannot be compared because those historical receipts did not record host CPU.

| QD | Workload | Historical VHDX IOPS | Current ring IOPS | Change | VHDX p99 us | Ring p99 us |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 32 | randread4k | 144,629 | 128,299 | -11.3% | 416 | 362 |
| 32 | randwrite4k | 113,874 | 151,877 | +33.4% | 485 | 317 |
| 128 | randread4k | 171,922 | 185,363 | +7.8% | 979 | 979 |
| 128 | randwrite4k | 143,255 | 195,474 | +36.5% | 1,171 | 954 |

Exact source filenames, timestamps and raw values are in the [comparison CSV](winspd-vhdx-comparison.csv). The QD32 source is the October 9 `matched-fastest-qd32` record, and QD128 is the later `clean-pair-qd128` record. Selection uses these explicit historical paired-run records, not the fastest VHDX observation across all experiments. The October 7 60-second VHDX QD128 run also recorded about 176k READ / 144k WRITE IOPS, consistent with the same broad throughput range. Other historical runs vary considerably, so the deltas above are indicative rather than statistically established gains.

The early September reports with million-IOPS values use older configurations/reporting and do not provide the same comparable direct-I/O/io_uring provenance. They are excluded.

Old fsync4k always used actual `--iodepth=1`, even in reports labeled QD128, and wrote a fixed 16 MiB file. Current timed fsync uses the requested depth. In the two selected historical records VHDX fsync throughput was about 153 and 329 IOPS; current QD1 ring median is 719 IOPS. That is encouraging, but runtime/workload differences and missing historical sync percentiles prevent a controlled durability-latency conclusion. Do not compare old QD1 fsync to current QD128 fsync or mistake old WRITE completion p99 for sync latency. Old WinSpd fsync observations before the FLUSH correction are not valid durability baselines.

## Queue-depth tradeoff with the current default ring

| Requested QD | READ / WRITE IOPS | READ / WRITE p99 us | Host CPU READ / WRITE % |
| ---: | ---: | ---: | ---: |
| 1 | 7,380 / 10,501 | 177 / 125 | 8.8 / 11.9 |
| 4 | 23,419 / 33,526 | 253 / 157 | 14.3 / 14.1 |
| 32 | 128,299 / 151,877 | 362 / 317 | 44.2 / 47.5 |
| 128 | 185,363 / 195,474 | 979 / 954 | 54.6 / 56.1 |

Moving QD32 to QD128 adds about 44% READ and 29% WRITE IOPS, while p99 grows about 2.7x and 3.0x. QD128 therefore favors aggregate throughput over individual request response time. QD1-4 has lower absolute p99 but leaves much of the available parallel throughput unused. An interactive application may naturally have low outstanding depth; do not manufacture concurrent I/O solely to reach the benchmark depth. Application/fio outstanding depth is distinct from the shared ring's 256-entry capacity and 128 payload buffers, which were held constant throughout this sweep.

For an application with a hard latency target, use its measured mixed-workload tail latency to select depth. For example, these homogeneous observations suggest QD32 as a candidate below roughly 0.5 ms p99, and QD1-4 where roughly 0.2 ms is more relevant, but neither is a guarantee under other loads.

## Claim-batch recommendation

Keep claim limit 32, the independent ready commit limit 8 requests / 256 KiB, preparation copy budget 1 MiB and soft next-claim budget 100 us. Claim limit 32 does not wait for 32 requests and does not delay publication until all 32 finish: a worker claims what is eligible, commits smaller groups and finishes everything it owns before returning.

At QD128, claim 8 reaches 184k READ / 194k WRITE IOPS versus claim 32 at 185k / 195k, less than 1% apart. Their mean claims are about 2.09 and 2.11. There is no convincing evidence that 32 beats 8 across workloads, but no measured tail-latency reason to lower the current default either. Claim 1 loses about 10-13% throughput against 32 at QD128 and raises whole-session lock acquisitions per SRB from about 6.58 to 9.20. It is useful as a diagnostic control, not the preferred production default.

Do not infer a large claim-size benefit from the QD1 runs: actual mean claims there are about one for every ceiling, and the separate short runs vary. The claim tuning is currently a driver build setting; application queue depth is a separate control. Backend worker count was held at eight in the final sweep and has not been re-optimized for this refactor.

The [full refactor report](winspd-ring-results.md) includes all batch tunings, sync latency, lock histograms and outstanding performance acceptance questions. No driver setting was changed for this comparison.

"""Validate paired fio runs and compare the work-item baseline with WSL's VHDX."""

import argparse
import csv
import hashlib
import json
import re
import statistics
from pathlib import Path


WORKLOADS = ('seqwrite', 'seqread', 'randread4k', 'randwrite4k', 'fsync4k')
STORAGES = ('winspd-partition', 'wsl-vhdx')
DEPTHS = (32, 64, 128)


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def collect(directory):
    rows, sessions, excluded = [], [], []
    settings = None
    signature_keys = (
        'InstalledDriverHash', 'InstalledDriverNumericVersion', 'ProxyHash',
        'ProxyDllHash', 'ProxyDllImageHash', 'TestSizeMiB', 'RandomRuntimeSeconds',
        'SequentialRuntimeSeconds', 'FsyncQueueDepth', 'FioIoEngine', 'DirectIO',
        'ProxySyncPolicy', 'ProxyBuffering', 'ProxyDispatcherThreads', 'ProxyIOMode',
        'ProxyTransport', 'RingDepth', 'RingBufferCount', 'MaxTransferLength',
        'TimedFsync', 'RandomWriteEndFsync', 'IoStats', 'FioVersion', 'WslKernel',
    )
    for folder in sorted(directory.glob('baseline-full-*')):
        if not (folder / 'result.json').exists():
            continue
        receipt = read_json(folder / 'result.json')
        if receipt.get('SourceRevision') != 'full-baseline':
            continue
        reason = (receipt.get('Error') or receipt['Status']) if receipt['Status'] != 'Measured' else (
            receipt.get('InterferenceNote', 'Concurrent workload') if receipt.get('PotentialInterference') else None)
        if reason:
            excluded.append(dict(run=folder.name, reason=reason))
            continue
        report = read_json(folder / 'benchmark.json')
        signature = {key: report.get(key) for key in signature_keys}
        if settings is None:
            settings = signature
        if signature != settings:
            raise ValueError(f'Underlying settings differ: {folder.name}')
        assert receipt['CaptureMode'] == 'close-only' and receipt['MeasurementPhase'] == 'quiet'
        assert receipt['QueueDepth'] in DEPTHS and report['RequestedQueueDepth'] == receipt['QueueDepth']
        assert report['TestSizeMiB'] == 2048 and report['RandomRuntimeSeconds'] == report['SequentialRuntimeSeconds'] == 20
        assert report['VhdxBaselineIncluded'] and report['DirectIO'] and report['TimedFsync']
        assert report['FioIoEngine'] == 'io_uring' and report['FsyncQueueDepth'] == 1
        assert len(report['Results']) == 10
        assert {(r['Storage'], r['Workload']) for r in report['Results']} == {(s, w) for s in STORAGES for w in WORKLOADS}
        execution = receipt['Execution']
        assert all(execution[key] == 0 for key in ('preparation_thread', 'completion_thread', 'preparation_threads', 'completion_threads', 'ioq_queued_spin_lock'))
        assert execution['completion_claim_limit'] == 32 and execution['thread_priority'] == 8
        assert receipt['CompletionPerf']['applied'] == 0
        assert len(receipt['WorkloadAmbient']) == 10
        assert all(r['BlenderCpuCores'] <= .1 for r in receipt['WorkloadAmbient'])
        kernels = read_json(folder / 'kernel-summary.json')['sessions']
        assert len(kernels) == 1 and kernels[0]['fully_retired'] and kernels[0]['complete_capture']
        kernel = kernels[0]
        assert kernel['limits']['claim'] == 32 and kernel['limits']['budget_violations'] == 0
        stats = report['RingStats']
        assert stats['Error'] == 0 and stats['SubmittedRequests'] == stats['PublishedResponses'] == stats['QueuedResponses']
        flush_log = (folder / 'proxy.events.log').read_text(encoding='utf-8-sig')
        flush = re.findall(r'backend-flush calls=(\d+) errors=(\d+) total-us=(\d+) max-us=(\d+) p50-upper-us=(\d+) p99-upper-us=(\d+)', flush_log)
        assert len(flush) == 1 and int(flush[0][0]) > 0 and int(flush[0][1]) == 0
        assert 'wslpart flush ok=0' not in flush_log
        match = re.fullmatch(r'baseline-full-p(\d+)-qd(\d+)-a(\d+)', folder.name)
        assert match
        session = dict(run=folder.name, pass_number=int(match[1]), qd=receipt['QueueDepth'],
            storage_order=report['StorageOrder'], driver_hash=report['InstalledDriverHash'],
            backend_flush_calls=int(flush[0][0]), backend_flush_errors=int(flush[0][1]),
            backend_flush_total_us=int(flush[0][2]), backend_flush_max_us=int(flush[0][3]),
            backend_flush_p50_upper_us=int(flush[0][4]), backend_flush_p99_upper_us=int(flush[0][5]),
            kernel_accepted=kernel['logical']['accepted'],
            locks_per_srb=kernel['lock_acquisitions_per_accepted_srb'],
            lock_wait_p99_upper_us=kernel['histograms']['lock_wait']['p99_upper_us'])
        sessions.append(session)
        for r in report['Results']:
            raw_path = Path(r['RawFioJson'])
            raw = read_json(raw_path)
            assert len(raw['jobs']) == 1
            job = raw['jobs'][0]
            assert job['error'] == 0
            options = job['job options']
            actual_qd = 1 if r['Workload'] == 'fsync4k' else receipt['QueueDepth']
            assert int(options['iodepth']) == r['RequestedQueueDepth'] == actual_qd
            assert int(options['runtime']) == 20 and options['time_based'] == '1' and options['direct'] == '1'
            assert options['ioengine'] == 'io_uring'
            assert 19.5 <= r['RuntimeSeconds'] <= 25 and r['WallSeconds'] < 50
            assert Path(r['RawFioJson']).exists()
            if r['Storage'] == 'wsl-vhdx':
                assert options['filename'].startswith('/home/') and '/wslpart-m6-vhdx-' in options['filename']
            else:
                assert options['filename'].startswith('/mnt/wslpart-m6-proxy/wslpart-m6-')
            if r['Workload'] == 'fsync4k':
                assert options['fsync'] == '1' and r['SyncCalls'] > 0
            if r['Workload'] == 'seqwrite':
                assert options['fsync_on_close'] == '1'
            direction = 'read' if r['Workload'] in ('seqread', 'randread4k') else 'write'
            fio = job[direction]
            assert fio['total_ios'] > 0
            clat = fio['clat_ns']
            pct = clat['percentile']
            def percentile(p):
                return pct[f'{p:.6f}'] / 1000
            depth = job['iodepth_level']
            weight = sum(depth.values())
            observed_lower_bound = sum(int(key.lstrip('>=')) * value for key, value in depth.items()) / weight if weight else 0
            assert abs(observed_lower_bound - r['AverageQueueDepthLowerBound']) < .02
            if actual_qd == 1:
                assert depth['1'] / weight > .99
            elif actual_qd == 32:
                assert depth['32'] / weight > .9
            else:
                assert depth['>=64'] / weight > .9
            sync = job.get('sync', {})
            sync_lat = sync.get('lat_ns', {})
            sync_pct = sync_lat.get('percentile', {})
            row = dict(run=folder.name, pass_number=session['pass_number'], storage_order=report['StorageOrder'],
                storage=r['Storage'], workload=r['Workload'], profile_qd=receipt['QueueDepth'], actual_qd=actual_qd,
                mib_per_sec=fio['bw_bytes'] / 1048576, iops=fio['iops'], total_ios=fio['total_ios'],
                mean_us=clat['mean'] / 1000, p50_us=percentile(50), p95_us=percentile(95),
                p99_us=percentile(99), p999_us=percentile(99.9), max_us=clat['max'] / 1000,
                runtime_seconds=r['RuntimeSeconds'], wall_seconds=r['WallSeconds'],
                fio_job_start_epoch_ms=job.get('job_start'), fio_report_epoch_ms=raw.get('timestamp_ms'),
                windows_cpu_percent=r['WindowsCpuPercent'], proxy_cpu_percent_one_core=r['ProxyCpuPercent'],
                windows_kernel_cpu_percent=r['WindowsKernelCpuPercent'], windows_user_cpu_percent=r['WindowsUserCpuPercent'],
                fio_user_cpu_percent=job['usr_cpu'], fio_system_cpu_percent=job['sys_cpu'],
                fsync_calls=sync.get('total_ios', 0),
                fsync_iops=sync.get('total_ios', 0) / r['RuntimeSeconds'],
                fsync_mean_us=sync_lat.get('mean', 0) / 1000,
                fsync_p95_us=sync_pct.get('95.000000', 0) / 1000,
                fsync_p99_us=sync_pct.get('99.000000', 0) / 1000,
                observed_qd_lower_bound=observed_lower_bound,
                raw_fio_json=str(raw_path), raw_fio_sha256=sha256(raw_path),
                driver_hash=report['InstalledDriverHash'], proxy_hash=report['ProxyHash'], proxy_dll_hash=report['ProxyDllHash'])
            rows.append(row)
    interference_path = directory.parent / 'full-baseline-interference.json'
    interference = read_json(interference_path) if interference_path.exists() else None
    return dict(status='Provisional' if interference else 'Measured',
        interference=interference, settings=settings, rows=rows, sessions=sessions, excluded=excluded)


def group(data, storage, workload, qd=None):
    return [r for r in data['rows'] if r['storage'] == storage and r['workload'] == workload and (qd is None or r['profile_qd'] == qd)]


def median(rows, key):
    return statistics.median(r[key] for r in rows)


def fmt(value, places=0):
    return f'{value:,.{places}f}'


def change(a, b):
    return (b / a - 1) * 100


def validate_complete(data):
    assert len(data['sessions']) == 9 and len(data['rows']) == 90
    assert {(s['pass_number'], s['qd']) for s in data['sessions']} == {(p, q) for p in (1, 2, 3) for q in DEPTHS}
    for storage in STORAGES:
        for workload in WORKLOADS:
            for qd in DEPTHS:
                assert len(group(data, storage, workload, qd)) == 3


def render(data, stem):
    if not data['rows']:
        return '# Full baseline benchmark\n\nNo completed pairs yet.\n'
    lines = ['# WinSpd work-item baseline and WSL root VHDX - 2026-10-23', '',
        'Compare QD32, QD64 and QD128 on the current validated baseline and the',
        'Ubuntu root filesystem. Both paths use the same Samsung 970 EVO Plus 2 TB',
        'NVMe SSD. The VHDX resides on Windows C:; WinSpd exposes disk 0 partition 16.', '',
        f'Validated {len(data["sessions"])} paired sessions / {len(data["rows"])} workload observations.',
        f'Excluded attempts: {len(data["excluded"])}. Three passes rotate QD order:',
        '32/64/128, 128/32/64, 64/128/32. Storage order alternates between sessions.',
        'Retained 20-second measurements per storage/workload cell: ' + ', '.join(
            f'QD{qd}: {len(group(data, STORAGES[0], WORKLOADS[0], qd))}' for qd in DEPTHS) + '.', '',
        'Baseline: Release 1.0.26293.217, preparation/completion work items, ordinary',
        'IOQ locking, preparation/completion claim caps 32, ready commits 8/256 KiB,',
        'SQ publication and CQ consumption batches 32. Userspace uses eight overlapped',
        'workers, guest sync policy, unbuffered source I/O, ring depth 256, 128',
        'buffers and maximum transfer 256 KiB. Default DPC routing. No tracing runs',
        'during timed workloads; basic kernel counters and backend diagnostics remain',
        'enabled. Driver identity: `' + str(data['settings']['InstalledDriverHash']) + '`.', '',
        'fio uses io_uring and direct I/O. Sequential READ/WRITE uses 1 MiB requests',
        'at the actual selected depth and runs for 20 seconds, rather than the old',
        'single-pass QD1 sequential test. Random READ/WRITE uses 4 KiB requests.',
        'Both paths use unique 2 GiB files; fsync4k uses a 16 MiB working region.',
        'Sequential WRITE flushes on close, random WRITE performs an end fsync.', '',
        'Linux reports write-back caching for both virtual block devices. Root',
        'mount options include discard; the source partition uses rw,relatime.', '',
        'fsync4k uses QD1 with fsync after each 4 KiB write. It is an identical',
        'serialized durability test in every suite, not a QD32/64/128 experiment.',
        'The durability table uses all retained observations per storage path.', '',
        'The source partition is approximately 48.8 GiB, but its existing ext4',
        'filesystem is approximately 15.6 GiB and was about 61% full before testing,',
        'with about 5.8 GiB available. Ubuntu root is ext4 on a 1 TiB VHDX, about',
        '17% full. The working set was reduced from 4 GiB after the free-space guard',
        'rejected an incomplete first attempt. No existing source files were deleted.',
        'This compares the actual deployed storage paths, including filesystem',
        'layout/fullness and VHDX overhead; it does not isolate transport cost alone.', '',
        'All table values are medians of individual runs, not pooled percentiles.',
        'Latency is fio completion latency in microseconds. MiB/s uses 1,048,576 bytes.',
        'Raw fio JSON, per-run values, hashes and kernel CLOSE diagnostics are retained.', '']
    for workload, title, throughput in (
        ('seqread', 'Sequential READ, 1 MiB', 'mib_per_sec'),
        ('seqwrite', 'Sequential WRITE, 1 MiB', 'mib_per_sec'),
        ('randread4k', 'Random READ, 4 KiB', 'iops'),
        ('randwrite4k', 'Random WRITE, 4 KiB', 'iops')):
        unit = 'MiB/s' if throughput == 'mib_per_sec' else 'IOPS'
        lines += ['## ' + title, '',
            f'| QD | WinSpd {unit} | VHDX {unit} | WinSpd p95 us | VHDX p95 us | WinSpd p99 us | VHDX p99 us |',
            '| ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
        for qd in DEPTHS:
            a, b = (group(data, storage, workload, qd) for storage in STORAGES)
            if a and b:
                values = [median(g, key) for key in (throughput, 'p95_us', 'p99_us') for g in (a, b)]
                lines.append(f'| {qd} | ' + ' | '.join(fmt(v, 1) for v in values) + ' |')
        lines += ['']
    lines += ['## Throughput and latency cost of increasing QD', '',
        '| Storage | Workload | Change | Throughput | p95 | p99 |',
        '| --- | --- | --- | ---: | ---: | ---: |']
    for storage in STORAGES:
        for workload in WORKLOADS[:-1]:
            key = 'mib_per_sec' if workload.startswith('seq') else 'iops'
            for low, high in ((32, 64), (64, 128)):
                a, b = (group(data, storage, workload, qd) for qd in (low, high))
                if a and b:
                    values = [change(median(a, field), median(b, field)) for field in (key, 'p95_us', 'p99_us')]
                    lines.append(f'| {storage} | {workload} | {low} to {high} | ' + ' | '.join(f'{v:+.1f}%' for v in values) + ' |')
    lines += ['', '## Serialized write-and-fsync, QD1', '',
        'fsync/s includes time spent writing and syncing; its numerator is completed',
        'fsync operations. Sync latency measures the fsync operation itself, excluding',
        'the preceding WRITE. Do not add write and sync percentiles.', '',
        '| Storage | Runs | fsync/s | Mean write us | Mean sync us | Sync p95 us | Sync p99 us |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for storage in STORAGES:
        g = group(data, storage, 'fsync4k')
        if g:
            values = [median(g, key) for key in ('fsync_iops', 'mean_us', 'fsync_mean_us', 'fsync_p95_us', 'fsync_p99_us')]
            lines.append(f'| {storage} | {len(g)} | ' + ' | '.join(fmt(v, 1) for v in values) + ' |')
    lines += ['', '## CPU use', '',
        'Windows CPU is GetSystemTimes non-idle percentage across 18 logical CPUs.',
        'This is host-wide activity, including unrelated applications and WSL; it',
        'cannot establish driver CPU cost. Proxy cores is wslpart process CPU-seconds',
        'divided by workload wall time and is process-specific. Neither metric',
        'attributes kernel driver CPU; that requires stack/module profiling.',
        'Guest fio CPU counters cover the fio task and are retained in CSV/JSON.', '',
        '| Workload | QD | WinSpd Windows CPU % | VHDX Windows CPU % | Proxy cores |',
        '| --- | ---: | ---: | ---: | ---: |']
    for workload in WORKLOADS:
        for qd in ((None,) if workload == 'fsync4k' else DEPTHS):
            a, b = (group(data, storage, workload, qd) for storage in STORAGES)
            if a and b:
                values = [median(a, 'windows_cpu_percent'), median(b, 'windows_cpu_percent'), median(a, 'proxy_cpu_percent_one_core') / 100]
                lines.append(f'| {workload} | {qd if qd else 1} | ' + ' | '.join(fmt(v, 2) for v in values) + ' |')
    lines += ['', '## Variation across retained passes', '',
        '| Storage | Workload | QD | Throughput min to max | p95 us min to max |',
        '| --- | --- | ---: | ---: | ---: |']
    for storage in STORAGES:
        for workload in WORKLOADS[:-1]:
            key = 'mib_per_sec' if workload.startswith('seq') else 'iops'
            for qd in DEPTHS:
                g = group(data, storage, workload, qd)
                if g:
                    ranges = [fmt(min(r[field] for r in g), 1) + ' to ' + fmt(max(r[field] for r in g), 1) for field in (key, 'p95_us')]
                    lines.append(f'| {storage} | {workload} | {qd} | ' + ' | '.join(ranges) + ' |')
    lines += ['', '## Integrity and limits', '',
        'Each pair validates the actual loaded driver/mode, fio job options and',
        'errors, queue-depth distribution, complete SRB retirement, ring request/',
        'response accounting, and successful backend FlushFileBuffers counters.',
        'Backend counters cover all five WinSpd workloads plus setup/cleanup, so',
        'their totals are not attributed exclusively to the fsync4k job.', '',
        'fio groups achieved depths 64 and above into one histogram bin. The raw',
        'job configuration distinguishes requested QD64/128; the histogram confirms',
        'asynchronous depth rather than an accidental QD1 test. Depth histograms',
        'are normalized by their sample weights: fio can report 200% for the QD1',
        'write+fsync job because sync samples and write samples share the bin.', '',
        'Blender CPU activity is checked before each workload and measured across',
        'each timed interval. Known overlapping attempts are excluded. Wall',
        'time guards reject host pauses. Other system, SSD cache and thermal',
        'variation remains possible; two or three observations do not establish statistical',
        'significance. WinSpd retains basic diagnostics and event logging, including',
        'flush events, which can add overhead compared with diagnostics disabled.', '',
        'Neither filesystem was formatted or resized. Only newly created benchmark',
        'files are removed after use. No reboot or kernel execution change is needed.', '']
    if data.get('status') == 'Provisional':
        lines[2:2] = [
            '**PROVISIONAL - background WSL kernel compilation was discovered during the sweep.**', '',
            'The observed make process tree started at 2026-10-23 05:47:15 +11:00.',
            'The entire final QD32 pair (`baseline-full-p3-qd32-a1`) is excluded.',
            'The eight retained pairs finished before that observed tree started;',
            'earlier build activity has not been ruled out. Throughput and latency',
            'can also be affected by CPU scheduling and SSD contention. Host-wide',
            'CPU is not evidence of driver CPU cost. These tables support inspection,',
            'not a final configuration decision. The user deferred clean repeats;',
            'raw data, timestamps and the excluded pair remain available.', '',
        ]
    if data['excluded']:
        lines += ['Excluded attempts:', '']
        for entry in data['excluded']:
            lines.append('- `' + entry['run'] + '`: ' + str(entry['reason']).replace('\n', ' '))
        lines += ['']
    lines += [f'[CSV]({stem}.csv) · [JSON]({stem}.json).',
        'Raw measurements: `artifacts/ring-measurements/baseline-full-*`.',
        'Raw fio: `artifacts/m6/fio-raw-baseline-full-*`.', '']
    return '\n'.join(lines)


def write_outputs(data, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix('.json').write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    if data['rows']:
        with output.with_suffix('.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(data['rows'][0]))
            writer.writeheader()
            writer.writerows(data['rows'])
    output.with_suffix('.md').write_text(render(data, output.name), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('artifacts/ring-measurements'))
    parser.add_argument('--output', type=Path, default=Path('notes/benchmarks/winspd-full-baseline-qd32-64-128'))
    parser.add_argument('--allow-partial', action='store_true')
    args = parser.parse_args()
    data = collect(args.directory)
    if not args.allow_partial:
        validate_complete(data)
    write_outputs(data, args.output)
    print(json.dumps(dict(sessions=len(data['sessions']), observations=len(data['rows']), excluded=len(data['excluded']))))


if __name__ == '__main__':
    main()

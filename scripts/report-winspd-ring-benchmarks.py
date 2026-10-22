"""Collect only successful ring measurements into comparable CSV and JSON rows."""

import argparse
import csv
import json
import re
from pathlib import Path


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def collect(directory, phase=None, capture_mode=None, source_revision=None):
    rows, excluded = [], []
    settings = None
    compared = (
        "ProxyHash", "RandomRuntimeSeconds", "FioIoEngine", "DirectIO",
        "ProxySyncPolicy", "ProxyBuffering", "ProxyDispatcherThreads",
        "ProxyIOMode", "ProxyTransport", "RingDepth", "RingBufferCount",
        "MaxTransferLength", "TestSizeMiB", "TimedFsync", "IoStats",
    )
    for folder in sorted(directory.iterdir()):
        receipt = folder / "result.json"
        if not receipt.exists():
            excluded.append({"run": folder.name, "reason": "no result yet"})
            continue
        result = read_json(receipt)
        if result["Status"] != "Measured":
            excluded.append({"run": folder.name, "reason": result.get("Error")})
            continue
        if phase and result.get("MeasurementPhase", "exploratory") != phase:
            excluded.append({"run": folder.name, "reason": "different measurement phase"})
            continue
        mode = result.get("CaptureMode", "full-session")
        if capture_mode and mode != capture_mode:
            excluded.append({"run": folder.name, "reason": "different capture mode"})
            continue
        revision = result.get("SourceRevision", "candidate")
        if source_revision and not result.get("CorrectedBaseline") and revision != source_revision:
            excluded.append({"run": folder.name, "reason": "different source revision"})
            continue
        report = read_json(folder / "benchmark.json")
        kernel = read_json(folder / "kernel-summary.json")["sessions"][0]
        signature = {key: report.get(key) for key in compared}
        if settings is None:
            settings = signature
        if signature != settings:
            raise ValueError(f"Underlying benchmark settings differ: {folder.name}")
        if not kernel["complete_capture"] or not kernel["fully_retired"]:
            raise ValueError(f"Invalid ownership/capture diagnostics: {folder.name}")
        flush_log = (folder / "proxy.events.log").read_text(encoding="utf-8-sig")
        flush = re.findall(
            r"backend-flush calls=(\d+) errors=(\d+) total-us=(\d+) max-us=(\d+) p50-upper-us=(\d+) p99-upper-us=(\d+)",
            flush_log,
        )
        if len(flush) != 1 or int(flush[0][0]) == 0 or int(flush[0][1]) != 0:
            raise ValueError(f"Missing or failed backend flush measurements: {folder.name}")
        claim = kernel["batches"].get("preparation_claim", {})
        for workload in report["Results"]:
            if workload["Workload"] == "fsync4k" and not workload["SyncCalls"]:
                raise ValueError(f"No fsync calls recorded: {folder.name}")
            read = workload["Workload"] == "randread4k"
            rows.append({
                "run": folder.name,
                "measurement_phase": result.get("MeasurementPhase", "exploratory"),
                "capture_mode": mode,
                "source_revision": revision,
                "variant": "baseline" if result.get("CorrectedBaseline") else (
                    ("coalesced" if result.get("Implementation") == "coalesced" else "batch")
                    + str(result['PreparationBatchSize'])
                ),
                "qd": result["QueueDepth"],
                "workload": workload["Workload"],
                "iops": workload["ReadIOPS"] if read else workload["WriteIOPS"],
                "p50_us": workload["ReadClatP50Us"] if read else workload["WriteClatP50Us"],
                "p99_us": workload["ReadClatP99Us"] if read else workload["WriteClatP99Us"],
                "p999_us": workload["ReadClatP999Us"] if read else workload["WriteClatP999Us"],
                "sync_p99_us": workload["SyncLatP99Us"],
                "sync_calls": workload["SyncCalls"],
                "actual_qd_lower_bound": workload["AverageQueueDepthLowerBound"],
                "windows_cpu_percent": workload["WindowsCpuPercent"],
                "proxy_cpu_percent_of_one_core": workload["ProxyCpuPercent"],
                "driver_hash": report["InstalledDriverHash"],
                # Kernel and backend diagnostics cover the entire three-workload session.
                "session_mean_claim": claim.get("mean_nonempty_size"),
                "session_locks_per_srb": kernel["lock_acquisitions_per_accepted_srb"],
                "session_lock_wait_p99_upper_us": kernel["histograms"]["lock_wait"]["p99_upper_us"],
                "session_lock_hold_p99_upper_us": kernel["histograms"]["lock_hold"]["p99_upper_us"],
                "session_producer_runs_per_srb": kernel["publication"]["producer_runs"] / kernel["logical"]["accepted"],
                "session_preparation_runs_per_srb": (
                    kernel["preparation"]["runs"] / kernel["logical"]["accepted"] if "preparation" in kernel else None
                ),
                "session_busy_deferrals": sum(
                    kernel.get(stage, {}).get("busy_deferrals", 0)
                    for stage in ("publication", "preparation", "completion")
                ),
                "session_backend_flush_calls": int(flush[0][0]),
                "session_backend_flush_mean_us": int(flush[0][2]) / int(flush[0][0]),
                "session_backend_flush_p99_upper_us": int(flush[0][5]),
            })
    return {"settings": settings, "rows": rows, "excluded": excluded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output-prefix", type=Path, required=True)
    parser.add_argument("--phase", choices=("exploratory", "quiet"))
    parser.add_argument("--capture-mode", choices=("full-session", "close-only"))
    parser.add_argument("--source-revision", choices=("candidate", "final-rundown"))
    args = parser.parse_args()
    data = collect(args.directory, args.phase, args.capture_mode, args.source_revision)
    if not data["rows"]:
        parser.error("No successful measurements")
    args.output_prefix.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    with args.output_prefix.with_suffix(".csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(data["rows"][0]))
        writer.writeheader()
        writer.writerows(data["rows"])


if __name__ == "__main__":
    main()

"""Collect matched tracing controls and sampled/scheduler ETW summaries.

Samples whose stack contains a callback include interrupt/DPC work above it.
The bounded list of retained full stacks only gives a lower bound on inclusive
notification samples; exclusive leaf counters are not truncated for a given key.
"""
import argparse
import csv
import json
from pathlib import Path


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def collect(root):
    rows, excluded = [], []
    driver_hash, settings = None, None
    for folder in sorted(root.iterdir()):
        if not folder.is_dir() or not (folder / "result.json").exists():
            continue
        result = read(folder / "result.json")
        if result["Status"] != "Passed":
            excluded.append({"run": folder.name, "reason": result.get("Error", result["Status"]),
                             "note": result.get("ExclusionNote")})
            continue
        benchmark = read(folder / "benchmark.json")
        if driver_hash is None:
            driver_hash = result["DriverHash"]
        if driver_hash != result["DriverHash"] or driver_hash != benchmark["InstalledDriverHash"]:
            raise ValueError(f"Driver identity changed: {folder.name}")
        current_settings = {k: benchmark[k] for k in (
            "ProxyHash", "Partition", "PartitionSizeBytes", "TestSizeMiB", "FioIoEngine",
            "DirectIO", "ProxySyncPolicy", "ProxyBuffering", "ProxyDispatcherThreads",
            "ProxyIOMode", "ProxyTransport", "RingDepth", "RingBufferCount",
            "MaxTransferLength", "IoStats", "RandomWriteEndFsync")}
        if settings is None:
            settings = current_settings
        if settings != current_settings:
            raise ValueError(f"Underlying I/O settings changed: {folder.name}")
        stats = benchmark["RingStats"]
        if not stats or stats["Error"] or stats["QueuedResponses"] != stats["PublishedResponses"]:
            raise ValueError(f"Unsuccessful transport shutdown: {folder.name}")
        if len(benchmark["Results"]) != 1:
            raise ValueError(f"Expected one timed workload: {folder.name}")
        timing = benchmark["Results"][0]
        if timing["WallSeconds"] > 2 * timing["RuntimeSeconds"] + 10:
            raise ValueError(f"Possible host pause: {folder.name}")
        if timing["RequestedQueueDepth"] != result["QueueDepth"] or timing["Workload"] != result["Workload"]:
            raise ValueError(f"Workload mismatch: {folder.name}")
        direction = "Read" if result["Workload"] == "randread4k" else "Write"
        row = {
            "run": folder.name,
            "trace_mode": result.get("TraceMode", "scheduler") if result["Traced"] else "none",
            "qd": result["QueueDepth"], "workload": result["Workload"],
            "driver_hash": driver_hash, "runtime_s": timing["RuntimeSeconds"],
            "wall_s": timing["WallSeconds"], "iops": timing[direction + "IOPS"],
            "mean_us": timing[direction + "ClatMeanUs"],
            "p99_us": timing[direction + "ClatP99Us"],
            "windows_cpu_percent": timing["WindowsCpuPercent"],
        }
        if result["Traced"]:
            summary = read(folder / "summary.json")
            if summary["events_lost"] or summary["truncated"]:
                raise ValueError(f"Incomplete ETW recording: {folder.name}")
            if summary["samples_with_stack"] < .9 * summary["sample_events"]:
                raise ValueError(f"Insufficient sample stacks: {folder.name}")
            row.update(events_lost=summary["events_lost"], samples=summary["sample_events"],
                       stack_samples=summary["samples_with_stack"])
            for stage in ("preparation", "producer", "completion", "kick"):
                count = summary["stage_samples"].get(stage, 0)
                if not count:
                    raise ValueError(f"Missing resolved {stage} samples: {folder.name}")
                row[stage + "_samples"] = count
                row[stage + "_cpus"] = sum(k.startswith(stage + "/") and v > 0
                    for k, v in summary["stage_cpu_samples"].items())
                row[stage + "_threads"] = sum(k.startswith(stage + "/") and v > 0
                    for k, v in summary["stage_thread_samples"].items())
                for label, leaf in (("spin", "ntoskrnl!KxWaitForSpinLockAndAcquire"),
                                    ("qpc", "ntoskrnl!KeQueryPerformanceCounter"),
                                    ("memcpy", "winspd-arm64!__memcpy_spec_unaligned")):
                    row[stage + "_" + label + "_percent"] = 100 * summary["leaf_samples"].get(stage + "/" + leaf, 0) / count
                retained = [(k, v) for k, v in summary["stage_stacks"].items() if k.startswith(stage + "/")]
                row[stage + "_notification_percent_lower_bound"] = 100 * sum(v for k, v in retained if "storport!StorPortNotification" in k) / count
                row[stage + "_retained_stack_percent"] = 100 * sum(v for _, v in retained) / count
                suspension = summary["callback_off_cpu"].get(stage, {})
                row[stage + "_suspensions"] = suspension.get("count", 0)
                row[stage + "_off_cpu_ms"] = suspension.get("total_ms", 0)
                row[stage + "_off_cpu_p99_us"] = suspension.get("p99_us")
            row["storport_dpc_cpus"] = sum(k.startswith("storport.sys/") for k in summary["dpc"])
            row["storport_dpc_total_ms"] = sum(v["total_ms"] for k, v in summary["dpc"].items() if k.startswith("storport.sys/"))
        rows.append(row)
    return {"settings": settings, "rows": rows, "excluded": excluded}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output-prefix", type=Path, required=True)
    args = parser.parse_args()
    data = collect(args.directory)
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    args.output_prefix.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    keys = list(dict.fromkeys(k for row in data["rows"] for k in row))
    with args.output_prefix.with_suffix(".csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=keys)
        writer.writeheader()
        writer.writerows(data["rows"])
    print(f"Collected {len(data['rows'])} profiles; excluded {len(data['excluded'])} failed attempts")

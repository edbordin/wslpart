"""Compare isolated ring workloads and decompose optional kernel latency metrics.

Totals, not sums of percentiles, support the per-logical-SRB decomposition.
Dispatch/lock-wait distributions overlap pipeline phases and are not added again.
"""

import argparse
import csv
import json
import re
from pathlib import Path


PHASES = (
    "pending", "prepare", "ready", "flight", "cq_queue",
    "completion_batch_wait", "completion_service", "completion_retire_wait",
    "notify_wait",
)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def collect(directory, source_revision="latency-profile", run_prefix="latency-"):
    rows = []
    excluded = []
    settings = None
    for folder in sorted(directory.glob(run_prefix + "*")):
        receipt_path = folder / "result.json"
        if not receipt_path.exists():
            continue
        receipt = read_json(receipt_path)
        if receipt.get("SourceRevision") != source_revision:
            continue
        if receipt["Status"] != "Measured":
            excluded.append({"run": folder.name, "status": receipt["Status"], "reason": receipt.get("Error")})
            continue
        if receipt.get("PotentialInterference"):
            excluded.append({"run": folder.name, "status": "Provisional",
                             "reason": receipt.get("InterferenceNote", "Reported concurrent workload")})
            continue
        if receipt.get("CaptureMode") != "close-only" or receipt.get("MeasurementPhase") != "quiet":
            raise ValueError(f"Invalid measurement boundaries: {folder.name}")
        report = read_json(folder / "benchmark.json")
        signature = {key: report.get(key) for key in (
            "ProxyHash", "ProxyDllImageHash", "RandomRuntimeSeconds", "FioIoEngine", "DirectIO",
            "ProxySyncPolicy", "ProxyBuffering", "ProxyDispatcherThreads",
            "ProxyIOMode", "ProxyTransport", "RingDepth", "RingBufferCount",
            "MaxTransferLength", "TestSizeMiB", "IoStats",
        )}
        if settings is None:
            settings = signature
        if signature != settings or len(report["Results"]) != 1:
            raise ValueError(f"Mismatched settings or multiple workloads: {folder.name}")
        sessions = read_json(folder / "kernel-summary.json")["sessions"]
        if len(sessions) != 1 or not sessions[0]["complete_capture"] or not sessions[0]["fully_retired"]:
            raise ValueError(f"Incomplete ownership/capture: {folder.name}")
        kernel = sessions[0]
        if kernel["limits"]["budget_violations"] or kernel["limits"]["claim"] != 32:
            raise ValueError(f"Unexpected preparation tuning: {folder.name}")
        workload = report["Results"][0]
        if workload["WallSeconds"] > 2 * workload["RuntimeSeconds"] + 10:
            raise ValueError(f"Host pause or inconsistent timing: {folder.name}")
        read = workload["Workload"] == "randread4k"
        diagnostic = kernel.get("latency_diagnostics", {})
        row = {
            "run": folder.name, "diagnostics": bool(diagnostic),
            "qd": receipt["QueueDepth"], "workload": workload["Workload"],
            "driver_hash": report["InstalledDriverHash"],
            "proxy_dll_hash": report.get("ProxyDllHash"),
            "ambient_blender_cpu_cores": receipt.get("AmbientBlenderCpuCores"),
            "iops": workload["ReadIOPS"] if read else workload["WriteIOPS"],
            "fio_mean_us": workload["ReadClatMeanUs"] if read else workload["WriteClatMeanUs"],
            "fio_p95_us": workload.get("ReadClatP95Us") if read else workload.get("WriteClatP95Us"),
            "fio_p99_us": workload["ReadClatP99Us"] if read else workload["WriteClatP99Us"],
            "fio_p999_us": workload.get("ReadClatP999Us") if read else workload.get("WriteClatP999Us"),
            "sync_calls": workload.get("SyncCalls", 0),
            "sync_mean_us": workload.get("SyncLatMeanUs"),
            "sync_p99_us": workload.get("SyncLatP99Us"),
            "windows_cpu_percent": workload["WindowsCpuPercent"],
            "sq_full": kernel["publication"]["sq_full"],
            "buffer_starved": kernel["publication"]["buffer_starved"],
            "cq_to_complete_p50_upper_us": kernel["histograms"]["cq_to_complete"]["p50_upper_us"],
            "cq_to_complete_p99_upper_us": kernel["histograms"]["cq_to_complete"]["p99_upper_us"],
            "completion_runs": kernel["completion"]["runs"],
            "completion_busy_deferrals": kernel["completion"]["busy_deferrals"],
            "completion_continuations": kernel["continuations"]["completion"],
            "completion_mean_claim": kernel["batches"]["completion_claim"]["mean_nonempty_size"],
            "preparation_mean_claim": kernel["batches"]["preparation_claim"]["mean_nonempty_size"],
            "preparation_empty_claims_per_srb": (
                kernel["batches"]["preparation_claim"]["empty"] / kernel["logical"]["accepted"]
                if kernel["logical"]["accepted"] else None
            ),
            "completion_empty_claims_per_srb": (
                kernel["batches"]["completion_claim"]["empty"] / kernel["logical"]["accepted"]
                if kernel["logical"]["accepted"] else None
            ),
            "completion_callback_mean_us": (
                kernel["completion"]["callback_ticks"] * 1_000_000
                / kernel["lock_totals"]["qpc_hz"] / kernel["completion"]["runs"]
            ),
            "preparation_runs": kernel["preparation"]["runs"],
            "preparation_busy_deferrals": kernel["preparation"]["busy_deferrals"],
            "preparation_callback_mean_us": (
                kernel["preparation"]["callback_ticks"] * 1_000_000
                / kernel["lock_totals"]["qpc_hz"] / kernel["preparation"]["runs"]
            ),
            "producer_runs": kernel["publication"]["producer_runs"],
            "producer_busy_deferrals": kernel["publication"]["busy_deferrals"],
        }
        row["lock_acquisitions_per_accepted_srb"] = kernel["lock_acquisitions_per_accepted_srb"]
        acquisitions = kernel["lock_totals"]["acquisitions"]
        for name in ("wait", "hold"):
            row["lock_" + name + "_mean_us"] = (
                kernel["lock_totals"][name + "_ticks"] * 1_000_000
                / kernel["lock_totals"]["qpc_hz"] / acquisitions if acquisitions else None)
        for name in ("pending_to_preparing", "preparing_to_ready", "ready_to_sq", "lock_wait", "lock_hold"):
            for percentile in ("p50", "p99"):
                row[name + "_" + percentile + "_upper_us"] = kernel["histograms"][name][percentile + "_upper_us"]
        execution = kernel.get("execution")
        if source_revision == "thread-profile" and not execution:
            raise ValueError(f"Missing execution-mode identity: {folder.name}")
        if execution:
            row["preparation_thread"] = execution["preparation_thread"]
            row["completion_thread"] = execution["completion_thread"]
            row["preparation_threads"] = execution.get("preparation_threads", execution["preparation_thread"])
            row["completion_threads"] = execution.get("completion_threads", execution["completion_thread"])
            row["preparation_parallel"] = execution.get("preparation_parallel")
            row["completion_parallel"] = execution.get("completion_parallel")
            row["completion_claim_limit"] = execution.get("completion_claim_limit", 32)
            row["ioq_queued_spin_lock"] = execution.get("ioq_queued_spin_lock", 0)
            row["thread_priority"] = execution.get("thread_priority", 8)
        perf = kernel.get("completion_perf")
        if source_revision == "dpc-profile" and (not perf or perf["query_status"] or not diagnostic):
            raise ValueError(f"Missing supported DPC configuration or detailed diagnostics: {folder.name}")
        if perf:
            for key, value in perf.items():
                row["completion_perf_" + key] = value
            if perf["mode"]:
                expected = 1 if perf["mode"] == 1 else 33
                if perf["query_status"] or perf["apply_status"] or perf["applied"] != expected:
                    raise ValueError(f"Requested completion DPC redirection was not applied: {folder.name}")
            elif perf["applied"]:
                raise ValueError(f"Unexpected explicit DPC settings in default control: {folder.name}")
        totals = kernel.get("latency_totals", {})
        if diagnostic:
            if diagnostic["queued_completions"] != 0:
                raise ValueError(f"Leaked diagnostic queue count: {folder.name}")
            logical = totals["lat_kernel_total"]
            samples = logical["count"]
            if not samples or samples > kernel["logical"]["retired"]:
                raise ValueError(f"Invalid completion timing samples: {folder.name}")
            row["timed_logical_srbs"] = samples
            row["kick_calls"] = diagnostic["kick_calls"]
            row["kick_busy"] = diagnostic["kick_busy"]
            for name, metric in totals.items():
                histogram = kernel["histograms"][name]
                if metric["depth"]:
                    for key in ("mean_entries", "p99_upper_entries", "maximum_entries"):
                        row[name + "_" + key] = histogram[key]
                else:
                    for key in ("mean_us", "p50_upper_us", "p99_upper_us", "maximum_us"):
                        row[name + "_" + key] = histogram[key]
                row[name + "_samples"] = metric["count"]
            # Normalize every component's total to the same final logical count,
            # so multichunk operation does not silently distort the sum.
            for phase in PHASES:
                metric = totals["lat_" + phase]
                row[phase + "_us_per_logical_srb"] = metric["total"] * 1_000_000 / metric["qpc_hz"] / samples
            component_sum = sum(row[p + "_us_per_logical_srb"] for p in PHASES)
            row["pipeline_sum_us_per_logical_srb"] = component_sum
            row["accounting_residual_us"] = row["lat_kernel_total_mean_us"] - component_sum
            row["notification_fraction_of_completion_callback_wall_time"] = (
                totals["lat_notify_service"]["total"] / kernel["completion"]["callback_ticks"]
            )
        events = (folder / "proxy.events.log").read_text(encoding="utf-8-sig")
        flushes = re.findall(
            r"backend-flush calls=(\d+) errors=(\d+) total-us=(\d+) max-us=(\d+) p50-upper-us=(\d+) p99-upper-us=(\d+)", events
        )
        if len(flushes) != 1 or not int(flushes[0][0]) or int(flushes[0][1]):
            raise ValueError(f"Missing or failed backend flushes: {folder.name}")
        flush_count, _, flush_total, _, _, flush_p99 = map(int, flushes[0])
        row.update(backend_flush_calls=flush_count, backend_flush_mean_us=flush_total / flush_count,
                   backend_flush_p99_upper_us=flush_p99)
        if workload["Workload"] == "fsync4k" and not row["sync_calls"]:
            raise ValueError(f"No fio sync calls: {folder.name}")
        kind = "read" if read else "write"
        matches = re.findall(
            rf"backend-io kind={kind} calls=(\d+) total-us=(\d+) max-us=(\d+) p50-upper-us=(\d+) p99-upper-us=(\d+)", events
        )
        if len(matches) != 1 or not int(matches[0][0]):
            raise ValueError(f"Missing backend histogram: {folder.name}")
        count, total, maximum, p50, p99 = map(int, matches[0])
        row.update(backend_calls=count, backend_submit_to_iocp_mean_us=total / count,
                   backend_submit_to_iocp_p50_upper_us=p50,
                   backend_submit_to_iocp_p99_upper_us=p99,
                   backend_submit_to_iocp_maximum_us=maximum)
        rows.append(row)
    return {"settings": settings, "rows": rows, "excluded": excluded}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output-prefix", type=Path, required=True)
    parser.add_argument("--source-revision", choices=("latency-profile", "dpc-profile", "thread-profile"), default="latency-profile")
    parser.add_argument("--run-prefix", default="latency-")
    args = parser.parse_args()
    data = collect(args.directory, args.source_revision, args.run_prefix)
    if not data["rows"]:
        parser.error("No successful isolated latency measurements")
    args.output_prefix.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    fields = list(dict.fromkeys(key for row in data["rows"] for key in row))
    with args.output_prefix.with_suffix(".csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(data["rows"])


if __name__ == "__main__":
    main()

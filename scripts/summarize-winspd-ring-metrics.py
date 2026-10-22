"""Convert sequential WinSpd CLOSE diagnostics to JSON; no third-party packages.

Capture one session's CLOSE at a time: the existing diagnostics have no session
identifier and cannot disambiguate interleaved closes. Histogram percentiles are
logarithmic upper bounds, not interpolated measurements. Gate-controlled test
captures must not be presented as performance results.
"""

import argparse
import json
import re
from pathlib import Path


LATENCY_METRICS = (
    "pending", "prepare", "ready", "flight", "cq_queue",
    "completion_batch_wait", "completion_service", "completion_retire_wait",
    "notify_wait", "notify_service", "kernel_total", "cq_notify",
    "completion_enqueue_lock", "completion_claim_lock", "completion_retire_lock",
    "preparation_dispatch", "producer_dispatch", "completion_dispatch", "kick",
    "completion_backlog", "cq_depth",
)


def fields(line):
    result = {}
    for key, value in re.findall(r"(\w+)=([^\s]+)", line):
        result[key] = int(value) if value.isdecimal() else value
    return result


def summarize(path, purpose, baseline=False):
    sessions = []
    current = None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if "WinSpd: SharedRing close " in line:
            current = {
                "sequence": len(sessions) + 1,
                "publication": fields(line),
                "histograms": {},
                "batches": {},
                "latency_totals": {},
            }
            sessions.append(current)
        if current is None:
            continue
        if "WinSpd: latency_total " in line:
            entry = fields(line)
            name = entry.pop("name")
            if name in current["latency_totals"]:
                raise ValueError(f"Repeated latency total {name}")
            current["latency_totals"][name] = entry
        elif "WinSpd: histogram " in line:
            entry = fields(line)
            name = entry.pop("name")
            if name in current["histograms"]:
                raise ValueError(f"Repeated histogram {name}: possibly interleaved CLOSE logs")
            hz = entry["qpc_hz"]
            if hz <= 0:
                raise ValueError("Invalid QPC frequency")
            total = current["latency_totals"].get(name)
            if total and total["count"] != entry["count"]:
                raise ValueError(f"Histogram/total count mismatch: {name}")
            if total and total["qpc_hz"] != hz:
                raise ValueError(f"Histogram/total clock mismatch: {name}")
            if total and total["depth"]:
                entry["p50_upper_entries"] = entry["p50_ticks"]
                entry["p99_upper_entries"] = entry["p99_ticks"]
                entry["maximum_entries"] = total["maximum"]
                entry["mean_entries"] = total["total"] / total["count"] if total["count"] else None
            else:
                entry["p50_upper_us"] = entry["p50_ticks"] * 1_000_000 / hz
                entry["p99_upper_us"] = entry["p99_ticks"] * 1_000_000 / hz
                if total:
                    entry["mean_us"] = total["total"] * 1_000_000 / hz / total["count"] if total["count"] else None
                    entry["maximum_us"] = total["maximum"] * 1_000_000 / hz
            current["histograms"][name] = entry
        elif "WinSpd: batch_histogram " in line:
            entry = fields(line)
            batch = current["batches"].setdefault(entry["name"], {"sizes": {}})
            batch["sizes"][str(entry["size"])] = entry["count"]
        elif "WinSpd: batch_summary " in line:
            entry = fields(line)
            batch = current["batches"].setdefault(entry.pop("name"), {"sizes": {}})
            batch.update(entry)
            batch["mean_nonempty_size"] = (
                batch["requests"] / batch["batches"] if batch["batches"] else None
            )
        else:
            for marker, key in (
                ("SharedRing preparation_limits ", "limits"),
                ("SharedRing preparation ", "preparation"),
                ("SharedRing completion ", "completion"),
                ("SharedRing continuations ", "continuations"),
                ("SharedRing completion_perf ", "completion_perf"),
                ("SharedRing execution ", "execution"),
                ("SharedRing mapping ", "mapping"),
                ("SharedRing mapping-origin ", "map_origin"),
                ("SharedRing latency_diagnostics=", "latency_diagnostics"),
                ("IOQ logical ", "logical"),
                ("IOQ spinlock ", "lock_totals"),
            ):
                if "WinSpd: " + marker in line:
                    current[key] = fields(line)
                    break

    if not sessions:
        raise ValueError("No WinSpd CLOSE diagnostics found")
    for session in sessions:
        logical = session.get("logical", {})
        accepted = logical.get("accepted", 0)
        session["lock_acquisitions_per_accepted_srb"] = (
            logical["lock_acquisitions"] / accepted if accepted else None
        )
        required = ("lock_wait", "lock_hold") if baseline else (
            "lock_wait", "lock_hold", "pending_to_preparing", "cq_to_complete"
        )
        session["complete_capture"] = all(
            name in session["histograms"]
            for name in required
        ) and (baseline or "limits" in session) and "logical" in session
        if session.get("latency_diagnostics", {}).get("latency_diagnostics") == 1:
            session["complete_capture"] = session["complete_capture"] and all(
                "lat_" + name in session["latency_totals"]
                and "lat_" + name in session["histograms"]
                for name in LATENCY_METRICS
            )
        session["fully_retired"] = (
            "accepted" in logical
            and logical["accepted"] == logical.get("retired")
            and logical.get("active") == 0
            and logical.get("fence") == 0
        )
        mapping = session.get("mapping")
        if mapping is not None:
            session["mappings_retired"] = (
                "mapped" in mapping and mapping["mapped"] == mapping.get("unmapped")
            )
            session["fully_retired"] = session["fully_retired"] and session["mappings_retired"]
    return {
        "source": str(path.resolve()),
        "purpose": purpose,
        "corrected_baseline": baseline,
        "percentiles": "logarithmic bin upper bounds",
        "grouping": "sequential CLOSE records; concurrent CLOSE captures unsupported",
        "sessions": sessions,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--purpose", choices=("correctness", "benchmark"), default="correctness")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", action="store_true", help="Expect baseline lock/logical counters only")
    args = parser.parse_args()
    result = summarize(args.capture, args.purpose, args.baseline)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if not all(session["complete_capture"] for session in result["sessions"]):
        parser.exit(1, "Incomplete CLOSE diagnostics; inspect JSON before using results.\n")


if __name__ == "__main__":
    main()

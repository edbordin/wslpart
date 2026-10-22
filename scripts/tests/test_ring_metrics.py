"""Check diagnostic units and reject incomplete or inconsistent captures."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "summarize-winspd-ring-metrics.py"
SPEC = importlib.util.spec_from_file_location("ring_metrics", SCRIPT)
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)

CAPTURE = """WinSpd: SharedRing close depth=256 buffers=128 producer_runs=1
WinSpd: latency_total name=lat_cq_queue count=2 total=300 maximum=200 qpc_hz=10000000 depth=0
WinSpd: histogram name=lat_cq_queue count=2 p50_ticks=128 p99_ticks=256 qpc_hz=10000000
WinSpd: latency_total name=lat_completion_backlog count=2 total=6 maximum=4 qpc_hz=10000000 depth=1
WinSpd: histogram name=lat_completion_backlog count=2 p50_ticks=2 p99_ticks=4 qpc_hz=10000000
WinSpd: histogram name=lock_wait count=2 p50_ticks=1 p99_ticks=2 qpc_hz=10000000
WinSpd: histogram name=lock_hold count=2 p50_ticks=1 p99_ticks=2 qpc_hz=10000000
WinSpd: histogram name=pending_to_preparing count=2 p50_ticks=1 p99_ticks=2 qpc_hz=10000000
WinSpd: histogram name=cq_to_complete count=2 p50_ticks=1 p99_ticks=2 qpc_hz=10000000
WinSpd: SharedRing preparation_limits claim=32 budget_violations=0
WinSpd: IOQ logical accepted=2 retired=2 active=0 fence=0 lock_acquisitions=4
"""


class RingMetricsTest(unittest.TestCase):
    def parse(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.log"
            path.write_text(text, encoding="utf-8")
            return METRICS.summarize(path, "correctness")["sessions"][0]

    def test_elapsed_ticks_and_entry_counts_have_distinct_units(self):
        session = self.parse(CAPTURE)
        self.assertTrue(session["complete_capture"])
        self.assertTrue(session["fully_retired"])
        timing = session["histograms"]["lat_cq_queue"]
        self.assertEqual(timing["mean_us"], 15)
        self.assertEqual(timing["maximum_us"], 20)
        backlog = session["histograms"]["lat_completion_backlog"]
        self.assertEqual(backlog["mean_entries"], 3)
        self.assertEqual(backlog["maximum_entries"], 4)
        self.assertNotIn("p99_upper_us", backlog)

    def test_count_mismatch_is_rejected(self):
        text = CAPTURE.replace("name=lat_cq_queue count=2 p50", "name=lat_cq_queue count=3 p50")
        with self.assertRaisesRegex(ValueError, "count mismatch"):
            self.parse(text)

    def test_mapping_leaks_fail_retirement_even_when_srbs_retired(self):
        text = CAPTURE + "WinSpd: SharedRing mapping threshold=65536 attempts=4 mapped=3 fallback=1 unmapped=2 bytes=196608 mdl_flags=b1\n"
        session = self.parse(text)
        self.assertEqual(session["mapping"]["mapped"], 3)
        self.assertFalse(session["mappings_retired"])
        self.assertFalse(session["fully_retired"])
        session = self.parse(text.replace("unmapped=2", "unmapped=3"))
        self.assertTrue(session["mappings_retired"])
        self.assertTrue(session["fully_retired"])

    def test_clock_mismatch_is_rejected(self):
        text = CAPTURE.replace("total=300 maximum=200 qpc_hz=10000000", "total=300 maximum=200 qpc_hz=1000")
        with self.assertRaisesRegex(ValueError, "clock mismatch"):
            self.parse(text)

    def test_partial_extended_dump_is_incomplete(self):
        session = self.parse(CAPTURE + "WinSpd: SharedRing latency_diagnostics=1 kick_calls=2 kick_busy=0 queued_completions=0\n")
        self.assertFalse(session["complete_capture"])

    def test_zero_samples_do_not_create_a_mean(self):
        text = CAPTURE.replace("name=lat_cq_queue count=2", "name=lat_cq_queue count=0")
        session = self.parse(text)
        self.assertIsNone(session["histograms"]["lat_cq_queue"]["mean_us"])

    def test_perf_request_does_not_imply_successful_application(self):
        text = CAPTURE + "WinSpd: SharedRing completion_perf mode=1 version=8 query_status=0 apply_status=2 supported=0 requested=1 applied=0\n"
        perf = self.parse(text)["completion_perf"]
        self.assertEqual(perf["requested"], 1)
        self.assertEqual(perf["applied"], 0)
        self.assertEqual(perf["apply_status"], 2)

    def test_parallel_worker_identity_and_observed_overlap_are_retained(self):
        text = CAPTURE + (
            "WinSpd: SharedRing execution preparation_thread=1 completion_thread=1 "
            "preparation_threads=2 completion_threads=4 preparation_parallel=2 completion_parallel=3 completion_claim_limit=8\n"
        )
        execution = self.parse(text)["execution"]
        self.assertEqual(execution["preparation_threads"], 2)
        self.assertEqual(execution["completion_threads"], 4)
        self.assertEqual(execution["preparation_parallel"], 2)
        self.assertEqual(execution["completion_parallel"], 3)
        self.assertEqual(execution["completion_claim_limit"], 8)

    def test_report_excludes_reported_interference_before_using_metrics(self):
        script = SCRIPT.parent / "report-winspd-ring-latency.py"
        spec = importlib.util.spec_from_file_location("ring_latency_report", script)
        report = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(report)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "dpc-render-run"
            folder.mkdir()
            (folder / "result.json").write_text(json.dumps({
                "Status": "Measured", "SourceRevision": "dpc-profile",
                "PotentialInterference": True, "InterferenceNote": "Concurrent render",
            }), encoding="utf-8")
            result = report.collect(Path(directory), "dpc-profile", "dpc-")
            self.assertEqual(result["rows"], [])
            self.assertEqual(result["excluded"][0]["status"], "Provisional")


if __name__ == "__main__":
    unittest.main()

import gzip
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


class SummaryImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            "summary_import", Path(__file__).parent / "files/import-results.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "records").mkdir()
        (self.root / "raw").mkdir()
        self.record = {
            "run_id": "run-1", "scenario": "s2-vm-go", "stack": "go",
            "profile": "race", "warmup": False, "duration_s": 900, "rps": 20,
            "tls_terminated_at": "vm", "tls_version": "1.2", "tls_resumption": True,
            "http_version": "1.1", "connection_reuse": False, "vus": 3000,
            "payload_bytes": 1024, "endpoint": "/payload",
            "client_source_ips": ["10.0.1.4", "10.0.1.5"],
            "image_reference": "registry.invalid/wtt/go-server:test",
            "image_digest": "sha256:test",
            "server_metadata": {
                "runtime_version": "go1.27.1",
                "os": 'NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.22\n',
                "os_source": "/etc/os-release",
                "upstream_runtime_image": "gcr.io/distroless/static:latest",
                "upstream_runtime_digest": "sha256:base",
                "tls_runtime": "Go crypto/tls",
                "tls_runtime_version": "go1.27.1",
            },
            "race": {"elapsed_ms": 56341.39, "configured_iterations": 1000000,
                     "vus": 3000, "max_duration_s": 900},
            "k6": {"counters": {"data_sent_bytes": 1234, "data_received_bytes": 5678,
                               "http_reqs": 100}},
        }
        with gzip.open(self.root / "raw/cell.json.gz", "wt") as raw:
            raw.write(json.dumps({"type": "Metric"}) + "\n")
            raw.write(json.dumps({"type": "Point", "data": {
                "time": "2026-09-13T07:59:40.123456789Z", "value": 1}}) + "\n")

    def records(self, skip=False):
        (self.root / "records/cell.json").write_text(json.dumps(self.record))
        return list(self.module.summary_records([self.root], skip))

    def test_race_uses_recorded_elapsed_not_safety_cap_or_iteration_mean(self):
        summary = self.records()[0]
        self.assertEqual(summary["fields"]["elapsed_ms"], 56341.39)
        self.assertEqual(summary["fields"]["data_sent_bytes"], 1234)
        self.assertEqual(summary["fields"]["data_received_bytes"], 5678)
        self.assertEqual(summary["tags"]["duration_source"], "race.elapsed_ms")
        self.assertEqual(summary["fields"]["tls_terminated_at"], "vm")
        self.assertTrue(summary["fields"]["tls_resumption_configured"])
        self.assertEqual(summary["fields"]["configured_vus"], 3000)
        self.assertEqual(summary["fields"]["configured_iterations"], 1000000)
        self.assertEqual(summary["fields"]["client_source_ips"], "10.0.1.4,10.0.1.5")
        self.assertEqual(summary["fields"]["image_reference"], "registry.invalid/wtt/go-server:test")
        self.assertEqual(summary["fields"]["image_digest"], "sha256:test")
        self.assertEqual(summary["fields"]["server_os"], self.record["server_metadata"]["os"])
        self.assertEqual(summary["fields"]["server_os_source"], "/etc/os-release")
        self.assertEqual(summary["fields"]["server_tls_runtime"], "Go crypto/tls")
        self.assertEqual(summary["timestamp_ns"] % 1_000_000_000, 123456789)
        self.assertEqual(self.records(), [summary])

    def test_nonrace_reconstructs_actual_duration_from_count_and_rate(self):
        self.record["race"] = None
        self.record["profile"] = "flat"
        summary = self.records()[0]
        self.assertEqual(summary["fields"]["elapsed_ms"], 5000)
        self.assertEqual(summary["tags"]["duration_source"], "http_reqs/rps")

    def test_friendly_name_and_execution_index_are_preserved(self):
        self.record.update(run_name="Fresh TLS discovery", execution_index=2)
        tags = self.records()[0]["tags"]
        self.assertEqual(tags["wtt_run_name"], "Fresh TLS discovery")
        self.assertEqual(tags["wtt_execution_index"], "2")

    def test_legacy_records_do_not_gain_new_identity_tags(self):
        tags = self.records()[0]["tags"]
        self.assertNotIn("wtt_run_name", tags)
        self.assertNotIn("wtt_execution_index", tags)

    def test_invalid_execution_identity_is_rejected(self):
        for key, values in (("run_name", ("", "bad\nname", None)),
                            ("execution_index", (0, -1, 1.5, True, "2"))):
            for value in values:
                with self.subTest(key=key, value=value), patch.dict(self.record, {key: value}):
                    with self.assertRaisesRegex(ValueError, "Invalid"):
                        self.records()
    def test_no_measured_duration_does_not_use_configured_limit(self):
        self.record["race"] = None
        self.record["rps"] = 0
        self.assertNotIn("elapsed_ms", self.records()[0]["fields"])

    def test_missing_optional_configuration_is_not_invented(self):
        self.record.pop("endpoint")
        self.record.pop("client_source_ips")
        self.record.pop("tls_resumption")
        fields = self.records()[0]["fields"]
        self.assertNotIn("endpoint", fields)
        self.assertNotIn("client_source_ips", fields)
        self.assertNotIn("tls_resumption_configured", fields)

    def test_skip_warmup(self):
        self.record["warmup"] = True
        self.assertEqual(self.records(skip=True), [])

    def test_legacy_os_evidence_is_not_inferred_from_image(self):
        self.record["server_metadata"].pop("os_source")
        self.record["server_metadata"]["os"] = "linux"
        fields = self.records()[0]["fields"]
        self.assertEqual(fields["server_os"], "linux")
        self.assertNotIn("server_os_source", fields)
        self.record["server_metadata"].pop("os")
        self.assertNotIn("server_os", self.records()[0]["fields"])

    def test_unavailable_os_is_preserved_without_inference(self):
        self.record["server_metadata"]["os"] = "unexposed-by-runtime"
        self.record["server_metadata"]["os_source"] = "unexposed-by-runtime"
        self.assertEqual(self.records()[0]["fields"]["server_os"], "unexposed-by-runtime")

    def test_invalid_os_evidence_is_rejected(self):
        for key in ("os", "os_source"):
            for value in ((None, 123) if key == "os" else ("", None, 123)):
                with self.subTest(key=key, value=value):
                    metadata = dict(self.record["server_metadata"], **{key: value})
                    with patch.dict(self.record, server_metadata=metadata):
                        with self.assertRaisesRegex(ValueError, "Invalid server_metadata"):
                            self.records()

    def test_empty_os_release_is_preserved(self):
        self.record["server_metadata"]["os"] = ""
        self.assertEqual(self.records()[0]["fields"]["server_os"], "")

    def test_invalid_summary_is_rejected(self):
        self.record["race"]["elapsed_ms"] = float("nan")
        with self.assertRaisesRegex(ValueError, "Invalid"):
            self.records()

    def test_missing_raw_timestamp_is_rejected(self):
        (self.root / "raw/cell.json.gz").unlink()
        with self.assertRaisesRegex(ValueError, "Missing raw timestamp"):
            self.records()

    def test_summaries_only_invokes_writer_without_raw_import(self):
        env = {"INFLUX_URL": "unused", "INFLUX_TOKEN": "unused", "INFLUX_ORG": "test", "INFLUX_BUCKET": "test"}
        with patch.dict(os.environ, env), \
                patch("sys.argv", ["import-results.py", "--results-dir", str(self.root),
                                   "--summaries-only", "--skip-warmup"]), \
                patch.object(self.module, "write_summaries") as write, \
                patch.object(self.module, "ProcessPoolExecutor") as pool:
            self.module.main()
            write.assert_called_once_with(
                [self.root], {"url": "unused", "token": "unused", "org": "test", "bucket": "test"}, True)
            pool.assert_not_called()

    def test_main_imports_summaries_before_raw_points(self):
        events = []
        env = {"INFLUX_URL": "unused", "INFLUX_TOKEN": "unused", "INFLUX_ORG": "test", "INFLUX_BUCKET": "test"}
        with patch.dict(os.environ, env), \
                patch("sys.argv", ["import-results.py", "--results-dir", str(self.root)]), \
                patch.object(self.module, "write_summaries",
                             side_effect=lambda *_: events.append("summary")), \
                patch.object(self.module, "raw_files",
                             side_effect=lambda _: events.append("raw") or []):
            self.module.main()

        self.assertEqual(events, ["summary", "raw"])


if __name__ == "__main__":
    unittest.main()

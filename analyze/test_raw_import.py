import gzip
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch


class Point:
    def __init__(self, measurement):
        self.measurement, self.tags, self.fields = measurement, {}, {}

    def tag(self, key, value):
        self.tags[key] = value
        return self

    def field(self, key, value):
        self.fields[key] = value
        return self

    def time(self, value, precision):
        self.timestamp = value
        return self


class RawImportTests(unittest.TestCase):
    def test_execution_indexes_preserve_three_cells_and_reject_mismatched_tags(self):
        spec = importlib.util.spec_from_file_location("importer", Path(__file__).parent / "files/import-results.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        client = MagicMock()
        client.__enter__.return_value = client
        fake = SimpleNamespace(InfluxDBClient=lambda **kwargs: client, Point=Point,
                               WritePrecision=SimpleNamespace(NS="ns"))
        with tempfile.TemporaryDirectory() as directory, patch.dict("sys.modules", {
            "influxdb_client": fake,
            "influxdb_client.client.write_api": SimpleNamespace(SYNCHRONOUS=None),
        }):
            root = Path(directory)
            (root / "records").mkdir()
            (root / "raw").mkdir()
            config = {"url": "unused", "token": "unused", "org": "test", "bucket": "test"}
            for index in (1, 2, 3):
                record = {"run_id": "run", "run_name": "Linear discovery", "execution_index": index,
                          "scenario": "vm", "stack": "net11", "profile": "linear"}
                (root / f"records/cell-{index}.json").write_text(json.dumps(record))
                path = root / f"raw/cell-{index}.json.gz"
                with gzip.open(path, "wt") as raw:
                    raw.write(json.dumps({"type": "Point", "metric": "http_reqs", "data": {
                        "time": "2026-09-18T00:00:00Z", "value": 1,
                        "tags": {"wtt_run_id": "run", "wtt_profile": "linear"},
                    }}) + "\n")
                module.write_raw_file(path, index, 3, config, False)
            points = [call.kwargs["record"][0] for call in client.write_api.return_value.write.call_args_list]
            self.assertEqual([point.tags["wtt_execution_index"] for point in points], ["1", "2", "3"])
            self.assertTrue(all(point.tags["wtt_run_name"] == "Linear discovery" for point in points))
            with gzip.open(path, "wt") as raw:
                raw.write(json.dumps({"type": "Point", "metric": "http_reqs", "data": {
                    "time": "2026-09-18T00:00:00Z", "value": 1, "tags": {"wtt_execution_index": "1"},
                }}) + "\n")
            with self.assertRaisesRegex(ValueError, "metadata disagree"):
                module.write_raw_file(path, 3, 3, config, False)

    def test_progress_reports_point_total_every_100000_and_at_completion(self):
        spec = importlib.util.spec_from_file_location("importer", Path(__file__).parent / "files/import-results.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        client = MagicMock()
        client.__enter__.return_value = client
        fake = SimpleNamespace(InfluxDBClient=lambda **kwargs: client, Point=Point,
                               WritePrecision=SimpleNamespace(NS="ns"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "records").mkdir()
            (root / "raw").mkdir()
            (root / "records/cell.json").write_text(json.dumps({
                "run_id": "run", "scenario": "go", "stack": "go", "profile": "race", "warmup": False,
            }))
            path = root / "raw/cell.json.gz"
            point = json.dumps({"type": "Point", "metric": "http_reqs", "data": {
                "time": "2026-09-13T00:00:00.123456789Z", "value": 1, "tags": {"wtt_run_id": "run"},
            }}) + "\n"
            with gzip.open(path, "wt") as raw:
                raw.write(json.dumps({"type": "Metric", "metric": "http_reqs"}) + "\n")
                for _ in range(100001):
                    raw.write(point)
            with patch.dict("sys.modules", {
                "influxdb_client": fake,
                "influxdb_client.client.write_api": SimpleNamespace(SYNCHRONOUS=None),
            }), patch.object(module, "progress") as progress:
                module.write_raw_file(path, 2, 3, {"url": "unused", "token": "unused",
                                                  "org": "test", "bucket": "test"}, False)
            messages = [call.args[0] for call in progress.call_args_list]
            self.assertEqual([m for m in messages if "WTT_PROGRESS=raw-points " in m], [
                "WTT_PROGRESS=raw-points file=2/3 imported=100000/100001 name=cell.json.gz",
            ])
            self.assertIn("current=2 total=3 points=100001", messages[1])
            self.assertIn("imported=100001/100001", messages[-1])

    def test_dashboard_measurements_use_legacy_point_identity(self):
        spec = importlib.util.spec_from_file_location("importer", Path(__file__).parent / "files/import-results.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stored, written = {}, []

        class Client:
            def __init__(self, **kwargs):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def write_api(self, **kwargs):
                return self
            def write(self, record, **kwargs):
                for point in record if isinstance(record, list) else [record]:
                    key = (point.measurement, tuple(sorted(point.tags.items())), point.timestamp)
                    stored[key] = point
                    written.append(point)

        fake = SimpleNamespace(InfluxDBClient=Client, Point=Point, WritePrecision=SimpleNamespace(NS="ns"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "records").mkdir()
            (root / "raw").mkdir()
            record = {
                "run_id": "run", "scenario": "go", "stack": "go", "profile": "race",
                "warmup": False, "race": {"elapsed_ms": 1000.0, "complete": True},
                "tls_terminated_at": "pod", "tls_version": "1.2", "tls_resumption": True,
                "http_version": "1.1", "connection_reuse": False, "vus": 1000,
                "iterations": 1000000, "duration_s": 900, "payload_bytes": 1024,
                "endpoint": "/payload", "client_source_ips": ["10.0.1.4"],
                "k6": {"counters": {"data_sent_bytes": 8, "data_received_bytes": 0}},
            }
            (root / "records/cell.json").write_text(json.dumps(record))
            path = root / "raw/cell.json.gz"
            tags = {"wtt_run_id": "run", "wtt_scenario": "go", "wtt_stack": "go", "wtt_profile": "race"}
            with gzip.open(path, "wt") as raw:
                for value in (3, 5):
                    raw.write(json.dumps({"type": "Point", "metric": "data_sent",
                                          "data": {"time": "2026-09-13T00:00:00.123456789Z",
                                                   "value": value, "tags": tags}}) + "\n")
            legacy = Point("k6_raw").tag("metric", "data_sent").field("value", 5.0)
            for key, value in tags.items():
                legacy.tag(key, value)
            legacy.time(module.timestamp_ns("2026-09-13T00:00:00.123456789Z"), "ns")
            Client().write(legacy)
            with patch.dict("sys.modules", {
                "influxdb_client": fake,
                "influxdb_client.client.write_api": SimpleNamespace(SYNCHRONOUS=None),
            }):
                config = {"url": "unused", "token": "unused", "org": "test", "bucket": "test"}
                module.write_raw_file(path, 1, 1, config, False)
                module.write_summaries([root], config, False)
                size = len(stored)
                module.write_raw_file(path, 1, 1, config, False)
                module.write_summaries([root], config, False)
                self.assertEqual(len(stored), size)
                record["warmup"] = True
                (root / "records/cell.json").write_text(json.dumps(record))
                writes = len(written)
                module.write_raw_file(path, 1, 1, config, True)
                module.write_summaries([root], config, True)
                self.assertEqual(len(written), writes)
            points = [p for p in stored.values() if p.measurement == "k6_raw"]
            self.assertEqual(len(points), 1)
            self.assertEqual(points[0].fields["value"], 5)
            self.assertEqual(points[0].tags, {"metric": "data_sent", **tags})
            self.assertNotIn("wtt_sample", points[0].tags)
            summary = next(p for p in stored.values() if p.measurement == "wtt_k6_summary")
            self.assertEqual(summary.fields["tls_terminated_at"], "pod")
            self.assertEqual(summary.fields["configured_vus"], 1000)
            self.assertEqual(summary.fields["client_source_ips"], "10.0.1.4")
            self.assertEqual({p.measurement for p in written}, {"k6_raw", "wtt_k6_summary"})
            summary = next(p for p in stored.values() if p.measurement == "wtt_k6_summary")
            self.assertEqual(summary.fields["data_sent_bytes"], 8)
            self.assertEqual(summary.fields["elapsed_ms"], 1000)


if __name__ == "__main__":
    unittest.main()

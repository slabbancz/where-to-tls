import json
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


K6 = shutil.which("k6")
K6_DIR = Path(__file__).resolve().parent


@unittest.skipUnless(K6, "requires k6")
class RaceProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        shutil.copy2(K6_DIR / "main.js", self.work / "main.js")

    def write_config(self, *, iterations=2, vus=1, max_duration=30):
        config = {
            "targetUrl": "http://127.0.0.1:1",
            "endpoint": "/",
            "payloadBytes": None,
            "profile": "race",
            "raceIterations": iterations,
            "raceVUs": vus,
            "durationSeconds": max_duration,
            "connectionReuse": False,
            "runId": "test",
            "scenario": "s2-vm-go",
            "stack": "go",
            "tlsTerminatedAt": "pod",
            "tlsVersion": "none",
            "tlsResumption": False,
            "httpVersion": "1.1",
            "clientSourceIPs": ["127.0.0.1"],
            "imageReference": "registry.invalid/wtt/go-server:test",
            "imageDigest": "sha256:test",
            "serverMetadata": {
                "runtime_version": "go1.27.1",
                "tls_runtime": "Go crypto/tls",
                "tls_runtime_version": "go1.27.1",
            },
            "recordPath": str(self.work / "record.json"),
            "dashboardEnabled": False,
            "dashboardIntervalSeconds": 1,
        }
        (self.work / "config.json").write_text(json.dumps(config))

    def run_k6(self, *args):
        return subprocess.run(
            [K6, *args, "main.js"],
            cwd=self.work,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_race_inspection_has_fixed_shared_iterations(self):
        self.write_config(iterations=1_000_000, vus=1_000, max_duration=900)
        result = self.run_k6("inspect", "--execution-requirements")
        self.assertEqual(result.returncode, 0, result.stderr)
        options = json.loads(result.stdout)
        race = options["scenarios"]["race"]
        self.assertEqual(race["executor"], "shared-iterations")
        self.assertEqual(race["vus"], 1000)
        self.assertEqual(race["iterations"], 1_000_000)
        self.assertEqual(race["maxDuration"], "15m0s")
        self.assertEqual(race["gracefulStop"], "0s")
        self.assertTrue(options["noConnectionReuse"])
        self.assertTrue(options["noVUConnectionReuse"])
        self.assertEqual(options["tags"]["wtt_offered_rps"], "none")
        self.assertIn("HTTP/2 negotiated", (K6_DIR / "main.js").read_text())

    def test_race_record_marks_a_completed_run(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]

        class Handler(SimpleHTTPRequestHandler):
            def log_message(self, _format, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        server_thread = threading.Thread(target=server.serve_forever)
        server_thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server_thread.join)
        self.addCleanup(server.shutdown)

        self.write_config()
        config_path = self.work / "config.json"
        config = json.loads(config_path.read_text())
        config["targetUrl"] = f"http://127.0.0.1:{port}"
        config_path.write_text(json.dumps(config))
        result = self.run_k6("run", "--local-ips=127.0.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)

        record = json.loads((self.work / "record.json").read_text())
        self.assertEqual(record["race"]["configured_iterations"], 2)
        self.assertEqual(record["race"]["vus"], 1)
        self.assertEqual(record["race"]["max_duration_s"], 30)
        self.assertEqual(record["race"]["completed_iterations"], 2)
        self.assertEqual(record["race"]["successful_requests"], 2)
        self.assertEqual(record["race"]["failed_requests"], 0)
        self.assertTrue(record["race"]["complete"])
        self.assertTrue(record["race"]["eligible_for_finish_time_ranking"])
        self.assertGreater(record["race"]["elapsed_ms"], 0)
        self.assertEqual(record["image_reference"], "registry.invalid/wtt/go-server:test")
        self.assertEqual(record["image_digest"], "sha256:test")
        self.assertEqual(record["server_metadata"]["tls_runtime"], "Go crypto/tls")

    def test_runner_has_race_validation_and_no_race_warmup(self):
        runner = (K6_DIR / "bench-runner.sh").read_text()
        self.assertIn('.name == "race"', runner)
        self.assertIn('(has("maxVUs") | not)', runner)
        self.assertIn('select($profile.name != "race")', runner)
        self.assertIn("raceIterations:", runner)


if __name__ == "__main__":
    unittest.main()

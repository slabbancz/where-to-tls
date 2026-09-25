"""Compile plans and summaries locally without cloud calls or load generation."""
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
K6 = Path(__file__).parent


class RunNamingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {
            "runName": "Linear TLS fresh discovery",
            "runId": "20260918T140202Z-linear_tls_fresh_discovery-s2-vm-net",
            "target": {"hostname": "example.test", "ip": "127.0.0.1", "port": 8080,
                       "tls": False, "tlsVersion": "none"},
            "workload": {"scenario": "s2-vm-net", "stack": "net10", "tlsTerminatedAt": "vm",
                         "imageReference": "fixture", "imageDigest": "sha256:fixture"},
            "k6": {"options": {"quiet": True, "verbose": False, "summaryMode": "full"},
                   "dashboard": {"enabled": True, "intervalSeconds": 1}},
            "matrix": {
                "endpoints": [{"path": "/payload", "payloadBytes": 1024}],
                "httpVersions": ["1.1"], "tlsResumption": [False], "connectionReuse": [False],
                "profiles": [
                    {"name": "linear", "start": 100, "end": 6000, "sampling": 10,
                     "windowSeconds": 60, "preAllocatedVUs": pre, "maxVUs": maximum}
                    for pre, maximum in [(100, 500), (500, 1000), (1000, 5000)]
                ],
                "warmupSeconds": 0, "repeats": 1,
            },
        }
        functions = (K6 / "bench-runner.sh").read_text().split("\nphase validate\n")[0]
        self.runner = self.root / "plan.sh"
        self.runner.write_text(functions + """
require_config --config "$1"
tls_enabled=false
hostname=example.test
port=8080
scenario=s2-vm-net
stack=net10
tls_terminated_at=vm
tls_version=none
tls_group=none
run_id=$(jq -r .runId "$config")
image_reference=fixture
image_digest=sha256:fixture
records_dir=/results/records
reports_dir=/results/reports
timeseries_dir=/results/timeseries
raw_dir=/results/raw
client_source_ips_json='["127.0.0.1"]'
dashboard_enabled=true
dashboard_interval=1
execution_plan
""")

    def compile(self):
        path = self.root / "config.json"
        path.write_text(json.dumps(self.config))
        return subprocess.run(["bash", str(self.runner), str(path)], capture_output=True, text=True)

    def plan(self):
        result = self.compile()
        self.assertEqual(result.returncode, 0, result.stderr)
        return [row.split("\t") for row in result.stdout.splitlines()]

    def test_three_linear_profiles_have_unique_paths_and_retained_settings(self):
        rows = self.plan()
        self.assertEqual(len(rows), 3)
        for column in (5, 6, 7, 8):
            self.assertEqual(len({row[column] for row in rows}), 3)
        for index, (row, profile) in enumerate(zip(rows, self.config["matrix"]["profiles"]), 1):
            config = json.loads(base64.b64decode(row[9]))
            self.assertEqual(config["runName"], self.config["runName"])
            self.assertEqual(config["executionIndex"], index)
            self.assertEqual(row[10], str(index))
            self.assertEqual(config["preAllocatedVUs"], profile["preAllocatedVUs"])
            self.assertEqual(config["maxVUs"], profile["maxVUs"])
            self.assertEqual(config["peakRate"], 6000)
            self.assertTrue(row[5].endswith(f"-{index}.json"), row[5])
            self.assertTrue(row[8].endswith(f"-{index}.json.gz"), row[8])
            self.assertIn("-rps6000-", row[5])
            self.assertNotIn("null", row[5])

    def test_indexes_are_unique_across_the_entire_matrix(self):
        matrix = self.config["matrix"]
        matrix["endpoints"].append({"path": "/payload", "payloadBytes": 65536})
        matrix["httpVersions"] = ["1.1", "2"]
        matrix["tlsResumption"] = [False, True]
        matrix["connectionReuse"] = [False, True]
        matrix["warmupSeconds"] = 5
        matrix["repeats"] = 2
        rows = self.plan()
        self.assertEqual(len(rows), 144)
        self.assertEqual([int(row[10]) for row in rows], list(range(1, 145)))
        for column in (5, 6, 7, 8):
            self.assertEqual(len({row[column] for row in rows}), 144)
        self.assertEqual(sum(row[3] == "true" for row in rows), 48)

    def test_other_profiles_have_correct_rate_labels_and_indexes(self):
        self.config["matrix"]["profiles"] = [
            {"name": "flat", "rate": 20, "windowSeconds": 10, "preAllocatedVUs": 2},
            {"name": "sine", "offset": 20, "amplitude": 10, "cycles": 1,
             "sampling": 10, "windowSeconds": 10, "preAllocatedVUs": 2},
            {"name": "exponential", "start": 10, "end": 40, "sampling": 10,
             "windowSeconds": 10, "preAllocatedVUs": 2},
            {"name": "race", "iterations": 100, "vus": 10, "maxDurationSeconds": 10},
        ]
        rows = self.plan()
        for row, expected in zip(rows, ("-rps20-", "-rps30-", "-rps40-", "-iters100-vus10-")):
            self.assertIn(expected, row[5])

    def test_run_name_validation(self):
        for value in (None, "", " \t", 123, "bad\nname", "bad\x7fname"):
            with self.subTest(value=value):
                self.config["runName"] = value
                result = self.compile()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("runName", result.stderr)

    def test_k6_tags_and_summary_keep_identity(self):
        config = json.loads(base64.b64decode(self.plan()[1][9]))
        script = "\n".join(line for line in (K6 / "main.js").read_text().splitlines()
                           if not line.startswith("import "))
        script = script.replace("export default function", "function request").replace("export ", "")
        result = subprocess.run(
            ["node", "-e", f"const open = () => {json.dumps(json.dumps(config))};\n" + script +
             "\nconsole.log(JSON.stringify({tags:options.tags,records:handleSummary({metrics:{}})}));"],
            check=True, capture_output=True, text=True)
        value = json.loads(result.stdout)
        self.assertEqual(value["tags"]["wtt_run_name"], self.config["runName"])
        self.assertEqual(value["tags"]["wtt_execution_index"], "2")
        record = json.loads(value["records"][config["recordPath"]])
        self.assertEqual(record["run_name"], self.config["runName"])
        self.assertEqual(record["execution_index"], 2)

    def test_prepare_replaces_git_hash_with_safe_friendly_name(self):
        prepare = (ROOT / "scripts/bench-prepare.sh").read_text().split("\nrepository_root=")[0]
        path = self.root / "prepare.sh"
        path.write_text(prepare + '\nprintf "%s\\n" "$run_id"\n')
        spec = self.root / "bench.yaml"
        for name, slug in [("Fresh TLS discovery", "fresh_tls_discovery"),
                           ('Fresh / "TLS" & ramp', "fresh_tls_ramp")]:
            with self.subTest(name=name):
                config = copy.deepcopy(self.config)
                config["runName"] = name
                spec.write_text(json.dumps(config))
                result = subprocess.run(["bash", str(path), str(spec)], check=True,
                                        capture_output=True, text=True,
                                        env=dict(os.environ, SCENARIO="s2-vm-net"))
                self.assertRegex(result.stdout.strip(), rf"^\d{{8}}T\d{{6}}Z-{slug}-s2-vm-net$")
        for name in ("", "a" * 128, "---"):
            self.config["runName"] = name
            spec.write_text(json.dumps(self.config))
            result = subprocess.run(["bash", str(path), str(spec)], capture_output=True, text=True,
                                    env=dict(os.environ, SCENARIO="s2-vm-net"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runName", result.stderr)

    def test_all_authored_yamls_have_run_names(self):
        for path in (ROOT / "bench").glob("*.yaml"):
            with self.subTest(path=path.name):
                parsed = subprocess.run(["dasel", "query", "--in", "yaml", "--out", "json", "--root"],
                                        input=path.read_text(), capture_output=True, text=True, check=True)
                self.assertTrue(json.loads(parsed.stdout)["runName"].strip())


if __name__ == "__main__":
    unittest.main()

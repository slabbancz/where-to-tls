#!/usr/bin/env python3
import argparse
import gzip
import json
import math
import os
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock

def progress(message: str) -> None:
    with progress.lock:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        print(f"WTT_TIMESTAMP={timestamp} {message}", file=sys.stderr, flush=True)


progress.lock = Lock()


def require_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def raw_files(results_dirs: list[Path]) -> list[Path]:
    return sorted({
        path
        for results_dir in results_dirs
        for path in results_dir.rglob("*.json.gz")
        if path.parent.name == "raw"
    })


def timestamp_ns(value: str) -> int:
    seconds, separator, fraction = value.removesuffix("Z").partition(".")
    epoch_seconds = int(datetime.fromisoformat(f"{seconds}+00:00").timestamp())
    nanoseconds = int(((fraction if separator else "") + "000000000")[:9])
    return epoch_seconds * 1_000_000_000 + nanoseconds


def tls_group_metadata(record: dict) -> dict[str, str]:
    source = record.get("key_exchange_group_source", "unverified-legacy")
    group = record.get("key_exchange_group", "unavailable")
    configured = record.get("key_exchange_group_configured", "unavailable")
    version = record.get("tls_version", "unavailable")
    if source == "openssl-preflight":
        evidence = record.get("tls_group_evidence") or {}
        if (version not in ("1.2", "1.3") or group not in ("P-256", "X25519")
                or configured != group or evidence.get("group") != group
                or evidence.get("tls_version") != version
                or evidence.get("source") != source
                or evidence.get("scope") != "client-facing-preflight"
                or not all(evidence.get(key) for key in ("target", "hostname", "checked_at"))):
            raise ValueError("Invalid TLS group preflight evidence or configured/negotiated group mismatch")
    elif source == "not-applicable":
        if version != "none" or group != "none" or configured != "none":
            raise ValueError("Invalid plaintext TLS group metadata")
    elif source != "unverified-legacy":
        raise ValueError(f"Unknown TLS group evidence source: {source}")
    return {
        "key_exchange_group": group,
        "key_exchange_group_configured": configured,
        "key_exchange_group_source": source,
        "tls_group_comparison_key": f"{version}/{group}" if source == "openssl-preflight"
                                    else "none" if source == "not-applicable" else "unverified",
    }


def require_comparable_tls_groups(records: list[dict]) -> str:
    keys = {tls_group_metadata(record)["tls_group_comparison_key"] for record in records}
    if not keys or "unverified" in keys or len(keys) != 1:
        raise ValueError("Invalid comparison: mixed or unverified TLS versions/key-exchange groups")
    return next(iter(keys))


def execution_tags(record: dict) -> dict[str, str]:
    tags = {}
    if "run_name" in record:
        name = record["run_name"]
        if (not isinstance(name, str) or not name.strip()
                or any(ord(char) < 32 or ord(char) == 127 for char in name)):
            raise ValueError("Invalid run_name in benchmark record")
        tags["wtt_run_name"] = name
    if "execution_index" in record:
        index = record["execution_index"]
        if type(index) is not int or index < 1:
            raise ValueError("Invalid execution_index in benchmark record")
        tags["wtt_execution_index"] = str(index)
    return tags


def summary_records(results_dirs: list[Path], skip_warmup: bool):
    paths = sorted({path for root in results_dirs for path in root.rglob("records/*.json")})
    for path in paths:
        record = json.loads(path.read_text())
        if skip_warmup and record.get("warmup", False):
            continue
        raw_path = path.parent.parent / "raw" / (path.stem + ".json.gz")
        if not raw_path.is_file():
            raise ValueError(f"Missing raw timestamp source for {path}: {raw_path}")
        first = None
        with gzip.open(raw_path, "rt", encoding="utf-8") as raw:
            for line in raw:
                point = json.loads(line)
                if point.get("type") == "Point":
                    first = point["data"]
                    break
        if first is None:
            raise ValueError(f"No raw points to timestamp summary: {path}")
        counters = record.get("k6", {}).get("counters", {})
        fields = {key: float(counters[key]) for key in
                  ("data_sent_bytes", "data_received_bytes") if key in counters}
        fields.update(tls_group_metadata(record))
        for key in ("tls_terminated_at", "tls_version", "http_version", "endpoint"):
            if key in record:
                fields[key] = str(record[key])
        for key in ("image_reference", "image_digest"):
            if key in record:
                if not isinstance(record[key], str) or not record[key]:
                    raise ValueError(f"Invalid {key} in {path}")
                fields[key] = record[key]
        server_metadata = record.get("server_metadata")
        if server_metadata is not None:
            if not isinstance(server_metadata, dict):
                raise ValueError(f"Invalid server_metadata in {path}")
            for key in (
                "runtime_version",
                "upstream_runtime_image",
                "upstream_runtime_digest",
                "tls_runtime",
                "tls_runtime_version",
            ):
                value = server_metadata.get(key)
                if not isinstance(value, str) or not value:
                    raise ValueError(f"Missing server_metadata.{key} in {path}")
                fields[f"server_{key}"] = value
            for key in ("os", "os_source"):
                if key in server_metadata:
                    value = server_metadata[key]
                    if not isinstance(value, str) or (key == "os_source" and not value):
                        raise ValueError(f"Invalid server_metadata.{key} in {path}")
                    fields[f"server_{key}"] = value
            if "os_source" in server_metadata and "os" not in server_metadata:
                raise ValueError(f"Missing server_metadata.os in {path}")
            if "server_gc" in server_metadata:
                if not isinstance(server_metadata["server_gc"], bool):
                    raise ValueError(f"Invalid server_metadata.server_gc in {path}")
                fields["server_gc"] = server_metadata["server_gc"]
        for key in ("tls_resumption", "connection_reuse"):
            if key in record:
                fields[f"{key}_configured" if key == "tls_resumption" else key] = bool(record[key])
        race = record.get("race") or {}
        config_values = {
            "configured_vus": race.get("vus", record.get("vus")),
            "configured_iterations": race.get("configured_iterations", record.get("iterations")),
            "max_duration_s": race.get("max_duration_s", record.get("duration_s")),
            "payload_bytes": record.get("payload_bytes"),
            "configured_rate": record.get("rate"),
            "configured_peak_rate": record.get("peak_rate"),
        }
        for key, value in config_values.items():
            if value is not None:
                fields[key] = float(value) if key in ("configured_rate", "configured_peak_rate") else int(value)
        if "client_source_ips" in record:
            fields["client_source_ips"] = ",".join(record["client_source_ips"])
        elapsed = race.get("elapsed_ms")
        duration_source = "race.elapsed_ms"
        if elapsed is None and record.get("rps", 0) > 0 and "http_reqs" in counters:
            # Legacy non-race records retain the count/rate, but not testRunDurationMs.
            elapsed = counters["http_reqs"] / record["rps"] * 1000
            duration_source = "http_reqs/rps"
        if elapsed is not None:
            fields["elapsed_ms"] = float(elapsed)
        if any(isinstance(v, (int, float)) and (not math.isfinite(v) or v < 0)
               for v in fields.values()):
            raise ValueError(f"Invalid or missing summary measurements: {path}")
        yield {
            "tags": {
                **execution_tags(record),
                "wtt_run_id": record["run_id"],
                "wtt_scenario": record["scenario"],
                "wtt_stack": record["stack"],
                "wtt_profile": record["profile"],
                "cell": path.stem,
                "warmup": str(record.get("warmup", False)).lower(),
                "duration_source": duration_source if elapsed is not None else "unavailable",
            },
            "fields": fields,
            "timestamp_ns": timestamp_ns(first["time"]),
        }


def write_summaries(results_dirs: list[Path], client_config: dict[str, str], skip_warmup: bool):
    from influxdb_client import InfluxDBClient, Point, WritePrecision
    from influxdb_client.client.write_api import SYNCHRONOUS

    with InfluxDBClient(url=client_config["url"], token=client_config["token"],
                        org=client_config["org"]) as client:
        write_api = client.write_api(write_options=SYNCHRONOUS)
        for record in summary_records(results_dirs, skip_warmup):
            point = Point("wtt_k6_summary")
            for key, value in record["tags"].items():
                point.tag(key, value)
            for key, value in record["fields"].items():
                point.field(key, value)
            write_api.write(bucket=client_config["bucket"],
                            record=point.time(record["timestamp_ns"], WritePrecision.NS))
    progress("WTT_PROGRESS=summary-import-complete")


def write_raw_file(
    path: Path,
    file_index: int,
    file_count: int,
    client_config: dict[str, str],
    skip_warmup: bool,
) -> None:
    from influxdb_client import InfluxDBClient, Point, WritePrecision
    from influxdb_client.client.write_api import SYNCHRONOUS

    cell = path.name.removesuffix(".json.gz")
    record_path = path.parent.parent / "records" / (cell + ".json")
    if not record_path.is_file():
        raise ValueError(f"Cell record required for trustworthy workload/phase metadata: {record_path}")
    summary = json.loads(record_path.read_text())
    group_metadata = tls_group_metadata(summary)
    warmup = str(summary.get("warmup", "unavailable")).lower()
    if skip_warmup and warmup == "true":
        progress(f"WTT_IMPORT_SKIPPED=warmup cell={cell}")
        return
    record_tags = {
        **execution_tags(summary),
        "wtt_run_id": summary["run_id"], "wtt_scenario": summary["scenario"],
        "wtt_stack": summary["stack"], "wtt_profile": summary["profile"],
    }
    if group_metadata["key_exchange_group_source"] != "unverified-legacy":
        record_tags.update({
            "wtt_tls_group_configured": group_metadata["key_exchange_group_configured"],
            "wtt_tls_group_verified": group_metadata["key_exchange_group"],
            "wtt_tls_group_evidence": group_metadata["key_exchange_group_source"],
        })
    progress(f"WTT_PROGRESS=raw-count file={file_index}/{file_count} name={path.name}")
    with gzip.open(path, "rt", encoding="utf-8") as raw:
        total_points = sum(1 for line in raw if json.loads(line).get("type") == "Point")
    if total_points == 0:
        raise ValueError(f"No raw observations in {path}")
    progress(f"WTT_PROGRESS=raw-file current={file_index} total={file_count} points={total_points} file={path.name}")
    imported = 0
    batch: list[Point] = []
    with InfluxDBClient(
        url=client_config["url"],
        token=client_config["token"],
        org=client_config["org"],
        timeout=120000,
    ) as client:
        write_api = client.write_api(write_options=SYNCHRONOUS)
        with gzip.open(path, "rt", encoding="utf-8") as raw:
            for line in raw:
                record = json.loads(line)
                if record.get("type") != "Point":
                    continue

                data = record["data"]
                tags = data.get("tags") or {}
                for key in record_tags:
                    if key in tags and str(tags[key]) != record_tags[key]:
                        raise ValueError(f"Raw/record metadata disagree for {key} in {path}")
                    if key.startswith("wtt_tls_group_") or key in ("wtt_run_name", "wtt_execution_index"):
                        tags[key] = record_tags[key]
                timestamp = timestamp_ns(data["time"])
                point = Point("k6_raw").tag("metric", record["metric"]).field("value", float(data["value"]))
                for key, value in tags.items():
                    point.tag(key, str(value))
                batch.append(point.time(timestamp, WritePrecision.NS))
                imported += 1
                if len(batch) == 25000:
                    write_api.write(
                        bucket=client_config["bucket"],
                        org=client_config["org"],
                        record=batch,
                    )
                    if imported % 100000 == 0:
                        progress(f"WTT_PROGRESS=raw-points file={file_index}/{file_count} imported={imported}/{total_points} name={path.name}")
                    batch.clear()

        if batch:
            write_api.write(
                bucket=client_config["bucket"],
                org=client_config["org"],
                record=batch,
            )
    progress(
        f"WTT_PROGRESS=raw-file-complete current={file_index} total={file_count} "
        f"imported={imported}/{total_points} file={path.name}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results-dir", action="append", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--check-tls-comparison", action="store_true",
                        help="locally reject mixed/unverified groups in selected records; do not import")
    parser.add_argument("--summaries-only", action="store_true",
                        help="backfill run totals and elapsed times without reimporting raw points")
    parser.add_argument(
        "--skip-warmup",
        action="store_true",
        help="exclude raw points tagged warmup=true",
    )
    args = parser.parse_args()
    if args.check_tls_comparison:
        records = [json.loads(path.read_text())
                   for root in args.results_dir for path in root.rglob("records/*.json")]
        if args.skip_warmup:
            records = [record for record in records if not record.get("warmup", False)]
        print(require_comparable_tls_groups(records))
        return
    if args.workers < 1:
        parser.error("--workers must be a positive integer")

    client_config = {
        "url": require_environment("INFLUX_URL"),
        "token": require_environment("INFLUX_TOKEN"),
        "org": require_environment("INFLUX_ORG"),
        "bucket": require_environment("INFLUX_BUCKET"),
    }
    if args.summaries_only:
        write_summaries(args.results_dir, client_config, args.skip_warmup)
        return
    write_summaries(args.results_dir, client_config, args.skip_warmup)
    files = raw_files(args.results_dir)
    progress(
        f"WTT_PROGRESS=raw-files total={len(files)} workers={args.workers} "
        f"skip_warmup={str(args.skip_warmup).lower()}"
    )
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = [
            executor.submit(
                write_raw_file,
                path,
                index,
                len(files),
                client_config,
                args.skip_warmup,
            )
            for index, path in enumerate(files, start=1)
        ]
        for future in as_completed(futures):
            future.result()
    progress("WTT_PROGRESS=raw-import-complete")

if __name__ == "__main__":
    main()

import csv
import io
import json
import time
import urllib.error
import urllib.parse
import urllib.request

from .common import artifact_run_id, flux_regex, flux_time
from .config import EXECUTION_KEYS, STATISTICS, SUMMARY_METADATA_FIELDS, TLS_BYTE_METRICS


class Influx:
    def __init__(self, url, org, token, timeout):
        self.url = url.rstrip("/")
        self.org = org
        self.token = token
        self.timeout = timeout

    def query(self, flux, label):
        started = time.monotonic()
        print(f"QUERY START {label}", flush=True)
        request = urllib.request.Request(
            self.url + "/api/v2/query?" + urllib.parse.urlencode({"org": self.org}),
            data=flux.encode(),
            headers={
                "Authorization": "Token " + self.token,
                "Content-Type": "application/vnd.flux",
                "Accept": "application/csv",
            },
        )
        try:
            text = urllib.request.urlopen(
                request,
                timeout=self.timeout,
            ).read().decode()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"Influx query failed ({error.code}): {detail}") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise RuntimeError(f"Influx query failed: {error}") from error
        header = None
        rows = []
        for row in csv.reader(io.StringIO(text)):
            if not row or row[0].startswith("#"):
                continue
            if row[:2] == ["", "result"]:
                header = row
            elif header is not None:
                rows.append(dict(zip(header, row)))
        duration = time.monotonic() - started
        print(
            f"QUERY DONE {label} duration={duration:.2f}s rows={len(rows)}",
            flush=True,
        )
        return rows


def metadata_query(run_ids, source_start, source_stop, bucket):
    fields = [
        "elapsed_ms",
        "tls_version",
        "key_exchange_group",
        "key_exchange_group_source",
    ]
    return f'''from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(source_start)}, stop: {flux_time(source_stop)})
  |> filter(fn: (r) => r._measurement == "wtt_k6_summary" and r.wtt_run_id =~ /{flux_regex(run_ids)}/ and r.warmup == "false")
  |> filter(fn: (r) => contains(value: r._field, set: {json.dumps(fields)}))
  |> pivot(
      rowKey: ["_time", "wtt_run_id", "wtt_scenario", "wtt_stack", "wtt_profile", "cell", "wtt_execution_index"],
      columnKey: ["_field"],
      valueColumn: "_value",
    )
  |> keep(columns: ["wtt_run_id", "wtt_scenario", "wtt_stack", "wtt_profile", "wtt_execution_index", "cell", "tls_version", "key_exchange_group", "key_exchange_group_source"])
  |> group()
  |> sort(columns: ["wtt_run_id", "wtt_execution_index"])
'''


def scenario_metadata_query(
    run_ids, source_start, source_stop, bucket, include_byte_counters=False,
):
    fields = list(SUMMARY_METADATA_FIELDS)
    if include_byte_counters:
        fields.extend(field for field, _ in TLS_BYTE_METRICS.values())
    return f'''from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(source_start)}, stop: {flux_time(source_stop)})
  |> filter(fn: (r) => r._measurement == "wtt_k6_summary" and r.wtt_run_id =~ /{flux_regex(run_ids)}/ and r.warmup == "false")
  |> filter(fn: (r) => contains(value: r._field, set: {json.dumps(fields)}))
  |> keep(columns: {json.dumps(EXECUTION_KEYS + ["cell", "_field", "_value"])})
'''


def origin_query(comparison, bucket):
    run_ids = [
        artifact_run_id(reference)
        for runs in comparison["stacks"].values()
        for reference in runs.values()
    ]
    keys = json.dumps(EXECUTION_KEYS)
    return f'''from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(comparison["source_start"])}, stop: {flux_time(comparison["source_stop"])})
  |> filter(fn: (r) => r._measurement == "k6_raw" and r._field == "value" and r.metric == "http_reqs")
  |> filter(fn: (r) => r.wtt_run_id =~ /{flux_regex(run_ids)}/ and r.wtt_tls_group_verified == {json.dumps(comparison["tls_group"])})
  |> group(columns: {keys})
  |> first()
  |> keep(columns: {json.dumps(EXECUTION_KEYS + ["_time"])})
  |> group()
  |> sort(columns: ["wtt_run_id", "wtt_execution_index"])
'''


def exact_run_filter(comparison, run_id, run_info):
    return (
        f'r.wtt_run_id == {json.dumps(run_id)} and '
        f'r.wtt_scenario == {json.dumps(run_info["scenario"])} and '
        f'r.wtt_stack == {json.dumps(run_info["stack"])} and '
        f'r.wtt_tls_group_verified == {json.dumps(comparison["tls_group"])}'
    )


def aggregate_time_series_query(
    comparison,
    run_id,
    run_info,
    metric,
    aggregate,
    bucket,
    tls_positive,
    separate_executions=False,
):
    run_filter = exact_run_filter(comparison, run_id, run_info)
    positive = (
        "  |> filter(fn: (r) => r._value > 0.0)\n"
        if tls_positive else ""
    )
    source_range = (
        f'  |> range(start: {flux_time(comparison["source_start"])}, '
        f'stop: {flux_time(comparison["source_stop"])})\n'
    )
    if aggregate == "mean" and not separate_executions:
        offset_ns = run_info["origin_ns"] % 1_000_000_000
        keys = json.dumps(["wtt_run_id", "wtt_scenario", "wtt_stack"])
        aggregation = (
            f"  |> group(columns: {keys})\n"
            f'  |> aggregateWindow(every: 1s, offset: {offset_ns}ns, '
            'fn: mean, createEmpty: false, timeSrc: "_start")\n'
            '  |> keep(columns: ["wtt_run_id", "wtt_scenario", '
            '"wtt_stack", "_time", "_value"])\n'
        )
    else:
        keys = json.dumps(EXECUTION_KEYS)
        aggregation = (
            f"  |> group(columns: {keys})\n"
            f"  |> aggregateWindow(every: 1s, fn: {aggregate}, "
            "createEmpty: false)\n"
            f"  |> keep(columns: {json.dumps(EXECUTION_KEYS + ['_time', '_value'])})\n"
        )
    return (
        f'from(bucket: {json.dumps(bucket)})\n'
        + source_range
        + f'  |> filter(fn: (r) => r._measurement == "k6_raw" and '
        f'r._field == "value" and r.metric == {json.dumps(metric)})\n'
        + f"  |> filter(fn: (r) => {run_filter})\n"
        + positive
        + aggregation
    )


def percentile_query(
    comparison,
    run_id,
    run_info,
    metric,
    bucket,
    rate,
    tls_positive,
):
    keys = json.dumps(EXECUTION_KEYS)
    value_filter = (
        "  |> filter(fn: (r) => r._value > 0.0)\n"
        if tls_positive else ""
    )
    run_filter = exact_run_filter(comparison, run_id, run_info)
    base = f'''base = from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(comparison["source_start"])}, stop: {flux_time(comparison["source_stop"])})
  |> filter(fn: (r) => r._measurement == "k6_raw" and r._field == "value" and r.metric == {json.dumps(metric)})
  |> filter(fn: (r) => {run_filter})
{value_filter}  |> group(columns: {keys})
'''
    if rate:
        base += (
            '  |> aggregateWindow(every: 1s, fn: sum, createEmpty: false)\n'
            f'  |> group(columns: {keys})\n'
        )
    branches = []
    names = []
    for statistic, quantile in STATISTICS:
        name = statistic.lower()
        names.append(name)
        branches.append(
            f'{name} = base\n'
            f'  |> quantile(q: {quantile:.2f}, method: "estimate_tdigest")\n'
            f'  |> map(fn: (r) => ({{r with statistic: "{statistic}"}}))\n'
        )
    return (
        base + "\n" + "\n".join(branches)
        + f'\nunion(tables: [{", ".join(names)}])\n'
        + f'  |> keep(columns: {json.dumps(EXECUTION_KEYS + ["statistic", "_value"])})\n'
        + '  |> group()\n'
        + '  |> sort(columns: ["wtt_run_id", "wtt_profile", "wtt_execution_index", "statistic"])\n'
    )


def failure_rate_query(comparison, run_id, run_info, bucket):
    keys = EXECUTION_KEYS
    metric_keys = keys + ["metric"]
    run_filter = exact_run_filter(comparison, run_id, run_info)
    return f'''from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(comparison["source_start"])}, stop: {flux_time(comparison["source_stop"])})
  |> filter(fn: (r) => r._measurement == "k6_raw" and r._field == "value")
  |> filter(fn: (r) => r.metric == "http_req_failed" or r.metric == "http_reqs")
  |> filter(fn: (r) => {run_filter})
  |> group(columns: {json.dumps(metric_keys)})
  |> sum(column: "_value")
  |> group(columns: {json.dumps(keys)})
  |> pivot(rowKey: {json.dumps(keys)}, columnKey: ["metric"], valueColumn: "_value")
  |> keep(columns: {json.dumps(keys + ["http_req_failed", "http_reqs"])})
  |> group()
  |> sort(columns: ["wtt_run_id", "wtt_profile", "wtt_execution_index"])
'''


def supplied_execution_filter(executions):
    clauses = []
    for execution in executions:
        clauses.append(
            "("
            + " and ".join(
                (
                    f'r.wtt_run_id == {json.dumps(execution["run_id"])}',
                    f'r.wtt_scenario == {json.dumps(execution["scenario_tag"])}',
                    f'r.wtt_stack == {json.dumps(execution["stack_tag"])}',
                    f'r.wtt_profile == {json.dumps(execution["profile_tag"])}',
                    f'r.wtt_execution_index == {json.dumps(str(execution["execution_index"]))}',
                )
            )
            + ")"
        )
    if not clauses:
        raise ValueError("At least one execution is required")
    return " or ".join(clauses)


def pooled_percentile_query(group, executions, metric, bucket, tls_positive):
    execution_filter = supplied_execution_filter(executions)
    positive = (
        "  |> filter(fn: (r) => r._value > 0.0)\n"
        if tls_positive else ""
    )
    branches = []
    names = []
    for statistic, quantile in STATISTICS:
        if statistic == "P01":
            continue
        name = statistic.lower()
        names.append(name)
        branches.append(
            f'{name} = base\n'
            f'  |> quantile(q: {quantile:.2f}, method: "estimate_tdigest")\n'
            f'  |> map(fn: (r) => ({{statistic: "{statistic}", _value: r._value}}))\n'
        )
    return f'''base = from(bucket: {json.dumps(bucket)})
  |> range(start: {flux_time(group["source_start"])}, stop: {flux_time(group["source_stop"])})
  |> filter(fn: (r) => r._measurement == "k6_raw" and r._field == "value" and r.metric == {json.dumps(metric)})
  |> filter(fn: (r) => {execution_filter})
{positive}  |> group()

{chr(10).join(branches)}
union(tables: [{", ".join(names)}])
  |> group()
  |> sort(columns: ["statistic"])
'''

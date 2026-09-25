from .common import exact_count, finite_number, profile_slot, timestamp_ns
from .config import PROFILE_ROWS, STATISTICS, TLS_BYTE_METRICS
from .runs import run_family


def elapsed_bucket_ns(timestamp, origin_ns):
    delta = timestamp_ns(timestamp) - origin_ns
    if delta >= 0:
        return (delta // 1_000_000_000) * 1_000_000_000
    return -((-delta) // 1_000_000_000) * 1_000_000_000


def parse_aggregate_rows(rows, stack, run_info, family, profile_row=None):
    buckets = {}
    for row in rows:
        if row.get("_time", "") == "" or row.get("_value", "") == "":
            continue
        repeat = None
        origin_ns = run_info["origin_ns"]
        if profile_row is not None:
            execution = int(row["wtt_execution_index"])
            actual_profile, repeat = profile_slot(
                family, row["wtt_profile"], execution,
            )
            if actual_profile != profile_row:
                continue
            origin_ns = run_info["executions"][
                (row["wtt_profile"], execution)
            ]
        elapsed_ns = elapsed_bucket_ns(row["_time"], origin_ns)
        if elapsed_ns < 0:
            continue
        buckets.setdefault((repeat, elapsed_ns), []).append(
            finite_number(row["_value"], f"{stack}@{row['_time']}")
        )
    if not buckets:
        raise ValueError(
            f"No aggregate time-series values for {stack}"
            + (f"/{profile_row}" if profile_row else "")
        )
    result = {}
    repeats = sorted({key[0] for key in buckets}, key=lambda value: value or -1)
    for repeat in repeats:
        segment = 0
        previous = None
        for selected_repeat, elapsed_ns in sorted(buckets):
            if selected_repeat != repeat:
                continue
            if previous is not None and elapsed_ns - previous > 60_000_000_000:
                segment += 1
            values = buckets[(repeat, elapsed_ns)]
            result.setdefault((stack, repeat, str(segment)), []).append(
                (elapsed_ns / 1_000_000_000.0, sum(values) / len(values))
            )
            previous = elapsed_ns
    return result


def parse_percentiles(rows, family, runs):
    run_to_stack = {run_id: stack for stack, run_id in runs.items()}
    result = {}
    for row in rows:
        run_id = row.get("wtt_run_id")
        if run_id not in run_to_stack:
            continue
        execution = int(row["wtt_execution_index"])
        profile_row, repeat = profile_slot(
            family,
            row["wtt_profile"],
            execution,
        )
        key = (
            profile_row,
            row["statistic"],
            run_to_stack[run_id],
            repeat,
        )
        if key in result:
            raise ValueError(f"Duplicate percentile identity: {key}")
        result[key] = finite_number(row["_value"], str(key))
    expected = {
        (profile, statistic, stack, repeat)
        for profile in PROFILE_ROWS[family]
        for statistic, _ in STATISTICS
        for stack in runs
        for repeat in range(3)
    }
    missing = expected - set(result)
    if missing:
        raise ValueError(
            "Missing percentile values: "
            + ", ".join(str(item) for item in sorted(missing))
        )
    return result


def parse_failure_rates(rows, family, runs):
    run_to_stack = {run_id: stack for stack, run_id in runs.items()}
    result = {}
    for row in rows:
        run_id = row.get("wtt_run_id")
        if run_id not in run_to_stack:
            continue
        execution = int(row["wtt_execution_index"])
        profile_row, repeat = profile_slot(
            family,
            row["wtt_profile"],
            execution,
        )
        key = (profile_row, run_to_stack[run_id], repeat)
        if key in result:
            raise ValueError(f"Duplicate failure-rate identity: {key}")
        failed = exact_count(row.get("http_req_failed", ""), f"{key}/failed")
        requests = exact_count(row.get("http_reqs", ""), f"{key}/requests")
        if requests == 0:
            raise ValueError(f"Zero completed requests for {key}")
        if failed > requests:
            raise ValueError(
                f"Failed requests exceed completed requests for {key}: "
                f"{failed} > {requests}"
            )
        result[key] = {
            "failed": failed,
            "requests": requests,
            "rate": failed / requests * 100.0,
        }
    expected = {
        (profile, stack, repeat)
        for profile in PROFILE_ROWS[family]
        for stack in runs
        for repeat in range(3)
    }
    missing = expected - set(result)
    if missing:
        raise ValueError(
            "Missing failure-rate values: "
            + ", ".join(str(item) for item in sorted(missing))
        )
    return result


def parse_pooled_percentiles(rows, context):
    values = {}
    for row in rows:
        statistic = row.get("statistic", "")
        if statistic not in ("P50", "P90", "P99"):
            continue
        if statistic in values:
            raise ValueError(
                f"Duplicate pooled percentile for {context}/{statistic}"
            )
        value = finite_number(row.get("_value", ""), f"{context}/{statistic}")
        if value < 0:
            raise ValueError(
                f"Negative pooled percentile for {context}/{statistic}: {value}"
            )
        values[statistic] = value
    missing = {"P50", "P90", "P99"} - set(values)
    if missing:
        raise ValueError(
            f"Missing pooled percentiles for {context}: {sorted(missing)}"
        )
    return values


def execution_elapsed_seconds(execution, context):
    value = finite_number(
        execution.get("elapsed_ms", ""),
        f"{context}/elapsed_ms",
    )
    if value <= 0:
        raise ValueError(f"Non-positive elapsed time for {context}: {value}")
    return value / 1000.0


def pooled_byte_values(executions, context):
    if len(executions) != 3 or {execution["repeat"] for execution in executions} != {0, 1, 2}:
        raise ValueError(f"Byte charts require three Profile Runs for {context}")
    requests = sum(execution["byte_counters"]["requests"] for execution in executions)
    if requests <= 0:
        raise ValueError(f"Zero recorded requests for byte chart: {context}")
    result = {"request_count": requests}
    for metric in TLS_BYTE_METRICS:
        total = sum(execution["byte_counters"][metric] for execution in executions)
        result[f"{metric}_bytes"] = total
        result[f"{metric}_bytes_per_request"] = total / requests
    return result


def build_scenario_percentile_row(
    scenario,
    stack,
    family,
    executions,
    http_percentiles,
    tls_percentiles,
):
    result = {
        "scenario": scenario,
        "stack": stack,
        "http_p50": http_percentiles["P50"],
        "http_p90": http_percentiles["P90"],
        "http_p99": http_percentiles["P99"],
        "tls_p50": tls_percentiles["P50"],
        "tls_p90": tls_percentiles["P90"],
        "tls_p99": tls_percentiles["P99"],
    }
    if family == "race":
        completion_runs_s = [
            execution_elapsed_seconds(
                execution,
                f"{scenario}/{stack}/{family}",
            )
            for execution in executions
        ]
        if len(completion_runs_s) != 3:
            raise ValueError(
                f"Expected three elapsed values for "
                f"{scenario}/{stack}/{family}, found {len(completion_runs_s)}"
            )
        result["completion_runs_s"] = completion_runs_s
    return result

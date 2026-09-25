from datetime import datetime, timezone
import math
from pathlib import Path
import re


def flux_alternation(values):
    return "(" + "|".join(re.escape(value) for value in values) + ")"


def flux_regex(values):
    return "^" + flux_alternation(values) + "$"


def artifact_run_id(reference):
    run_id = reference.rsplit(":", 1)[-1]
    if not re.fullmatch(
        r"\d{8}T\d{6}Z-blog_tls_(baseline|linear_peak|race)-[a-z0-9-]+",
        run_id,
    ):
        raise ValueError(f"Unsupported benchmark Run ID: {run_id}")
    return run_id


def timestamp_ns(value):
    match = re.fullmatch(
        r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z",
        value,
    )
    if not match:
        raise ValueError(f"Invalid RFC3339 timestamp: {value}")
    seconds = int(
        datetime.fromisoformat(match.group(1) + "+00:00")
        .astimezone(timezone.utc)
        .timestamp()
    )
    fraction = (match.group(2) or "").ljust(9, "0")
    return seconds * 1_000_000_000 + int(fraction or "0")


def flux_time(value):
    timestamp_ns(value)
    return value


def finite_number(value, context):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"Non-finite value for {context}: {value}")
    return number


def exact_count(value, context):
    number = finite_number(value, context)
    if number < 0 or not number.is_integer():
        raise ValueError(f"Invalid request count for {context}: {value}")
    return int(number)


def profile_slot(family, profile, execution):
    if family == "baseline":
        mapping = {
            ("linear", 1): ("Linear", 0),
            ("linear", 4): ("Linear", 1),
            ("linear", 7): ("Linear", 2),
            ("flat", 2): ("Flat", 0),
            ("flat", 5): ("Flat", 1),
            ("flat", 8): ("Flat", 2),
            ("sine", 3): ("Sine", 0),
            ("sine", 6): ("Sine", 1),
            ("sine", 9): ("Sine", 2),
        }
    elif family == "linear":
        mapping = {
            ("linear", 1): ("Fixed 100 VUs", 0),
            ("linear", 3): ("Fixed 100 VUs", 1),
            ("linear", 5): ("Fixed 100 VUs", 2),
            ("linear", 2): ("Expandable to 1,000 VUs", 0),
            ("linear", 4): ("Expandable to 1,000 VUs", 1),
            ("linear", 6): ("Expandable to 1,000 VUs", 2),
        }
    else:
        mapping = {
            ("race", execution): (
                ("10 VUs", "100 VUs", "1,000 VUs")[(execution - 1) % 3],
                (execution - 1) // 3,
            )
            for execution in range(1, 10)
        }
    key = (profile, execution)
    if key not in mapping:
        raise ValueError(f"Unexpected {family} execution: {profile}-{execution}")
    return mapping[key]


def split_selections(selections):
    return list(dict.fromkeys(
        name.strip()
        for selection in selections
        for name in selection.split(",")
    ))


def read_token_file(path):
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise ValueError(
            f"Cannot read default Influx token file {path}: {error}; "
            "pass --token or --token-file"
        ) from error
    matches = [
        line.split("=", 1)[1]
        for line in lines
        if line.startswith("INFLUX_TOKEN=")
    ]
    if len(matches) != 1 or not matches[0]:
        raise ValueError(
            f"{path} must contain exactly one non-empty INFLUX_TOKEN entry"
        )
    return matches[0]

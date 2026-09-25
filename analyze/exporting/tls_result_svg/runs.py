import re

from .common import artifact_run_id, exact_count, finite_number, profile_slot, timestamp_ns
from .config import (
    FAMILIES,
    PROFILE_SLUGS,
    STACK_ORDER,
    STACK_PREFIXES,
    TLS_BYTE_METRICS,
    TLS_CONFIGURATIONS,
)


def ordered_stacks(comparison):
    return [stack for stack in STACK_ORDER if stack in comparison["stacks"]]


def family_runs(comparison, family):
    return {
        stack: artifact_run_id(comparison["stacks"][stack][family])
        for stack in ordered_stacks(comparison)
        if family in comparison["stacks"][stack]
    }


def expected_executions(family):
    if family == "baseline":
        return {
            ("linear", 1), ("flat", 2), ("sine", 3),
            ("linear", 4), ("flat", 5), ("sine", 6),
            ("linear", 7), ("flat", 8), ("sine", 9),
        }
    if family == "linear":
        return {("linear", execution) for execution in range(1, 7)}
    return {("race", execution) for execution in range(1, 10)}


def validate_metadata(comparison, rows):
    by_run = {}
    for row in rows:
        by_run.setdefault(row["wtt_run_id"], []).append(row)
    run_to_stack = {}
    for stack in ordered_stacks(comparison):
        for family, reference in comparison["stacks"][stack].items():
            run_id = artifact_run_id(reference)
            selected = by_run.get(run_id, [])
            expected_count = len(expected_executions(family))
            if len(selected) != expected_count:
                raise ValueError(
                    f"{run_id} has {len(selected)} summary rows; "
                    f"expected {expected_count}"
                )
            actual = {
                (row["wtt_profile"], int(row["wtt_execution_index"]))
                for row in selected
            }
            if actual != expected_executions(family):
                raise ValueError(
                    f"{run_id} execution set differs: expected "
                    f"{sorted(expected_executions(family))}, got {sorted(actual)}"
                )
            for row in selected:
                if row.get("tls_version") != comparison["tls_version"]:
                    raise ValueError(f"{run_id} has unexpected TLS version")
                if row.get("key_exchange_group") != comparison["tls_group"]:
                    raise ValueError(f"{run_id} has unexpected TLS group")
                if row.get("key_exchange_group_source") != "openssl-preflight":
                    raise ValueError(f"{run_id} lacks verified TLS-group evidence")
                if not row.get("wtt_stack", "").startswith(STACK_PREFIXES[stack]):
                    raise ValueError(
                        f"{run_id} stack {row.get('wtt_stack')} does not match {stack}"
                    )
                if row.get("wtt_scenario") != comparison["identities"][run_id]["scenario"]:
                    raise ValueError(f"{run_id} has unexpected scenario")
            run_to_stack[run_id] = stack
    return run_to_stack


def run_family(run_id):
    family = re.search(r"-blog_tls_(baseline|linear_peak|race)-", run_id).group(1)
    return "linear" if family == "linear_peak" else family


def build_comparisons(run_ids, rows, source_start, source_stop):
    by_run = {}
    for row in rows:
        by_run.setdefault(row["wtt_run_id"], []).append(row)
    groups = {}
    for run_id in run_ids:
        selected = by_run.get(run_id)
        if not selected:
            raise ValueError(f"No summary metadata for supplied Run ID: {run_id}")
        identities = {
            tuple(row.get(key, "") for key in (
                "wtt_scenario", "wtt_stack", "tls_version", "key_exchange_group",
            ))
            for row in selected
        }
        if len(identities) != 1:
            raise ValueError(f"Inconsistent scenario/stack/TLS metadata for {run_id}")
        raw_scenario, raw_stack, version, group = identities.pop()
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", raw_scenario):
            raise ValueError(f"Invalid scenario for {run_id}: {raw_scenario!r}")
        if version not in ("1.2", "1.3") or group not in ("P-256", "X25519"):
            raise ValueError(f"Unsupported TLS metadata for {run_id}: {version}/{group}")
        stacks = [
            stack for stack in STACK_ORDER
            if raw_stack.startswith(STACK_PREFIXES[stack])
        ]
        if len(stacks) != 1:
            raise ValueError(f"Unsupported stack for {run_id}: {raw_stack}")
        # Stored scenario tags include the stack suffix (for example s2-vm-go).
        scenario = raw_scenario.removesuffix("-" + STACK_PREFIXES[stacks[0]])
        comparison = groups.setdefault((scenario, version, group), {
            "scenario": scenario,
            "tls_version": version,
            "tls_group": group,
            "source_start": source_start,
            "source_stop": source_stop,
            "stacks": {},
            "identities": {},
        })
        runs = comparison["stacks"].setdefault(stacks[0], {})
        family = run_family(run_id)
        if family in runs:
            raise ValueError(
                f"Two supplied runs occupy {scenario}/{version}/{group}/"
                f"{stacks[0]}/{family}: {runs[family]}, {run_id}. "
                "Export these run sets separately."
            )
        runs[family] = run_id
        comparison["identities"][run_id] = {
            "scenario": raw_scenario,
            "stack": raw_stack,
        }
    for comparison in groups.values():
        comparison["id"] = (
            f'{comparison["scenario"]}-tls{comparison["tls_version"].replace(".", "")}'
            f'-{comparison["tls_group"].lower()}'
        )
        validate_metadata(comparison, rows)
    return list(groups.values())


def parse_origins(comparison, rows):
    expected = {
        artifact_run_id(reference)
        for runs in comparison["stacks"].values()
        for reference in runs.values()
    }
    origins = {}
    for row in rows:
        run_id = row.get("wtt_run_id")
        if run_id not in expected:
            continue
        identity = comparison["identities"][run_id]
        if row["wtt_scenario"] != identity["scenario"] or row["wtt_stack"] != identity["stack"]:
            raise ValueError(f"Raw origin does not match summary identity for {run_id}")
        execution = int(row["wtt_execution_index"])
        execution_key = (row["wtt_profile"], execution)
        entry = origins.setdefault(run_id, {
            "origin_ns": None,
            "scenario": row["wtt_scenario"],
            "stack": row["wtt_stack"],
            "executions": {},
        })
        if execution_key in entry["executions"]:
            raise ValueError(f"Duplicate execution origin for {run_id}/{execution_key}")
        origin_ns = timestamp_ns(row["_time"])
        entry["executions"][execution_key] = origin_ns
        if entry["origin_ns"] is None or origin_ns < entry["origin_ns"]:
            entry["origin_ns"] = origin_ns
    missing = expected - set(origins)
    if missing:
        raise ValueError(f"Missing raw origins for Run IDs: {sorted(missing)}")
    for run_id, entry in origins.items():
        family = run_family(run_id)
        if set(entry["executions"]) != expected_executions(family):
            raise ValueError(
                f"{run_id} raw execution origins differ: expected "
                f"{sorted(expected_executions(family))}, got "
                f"{sorted(entry['executions'])}"
            )
    return origins


def stack_identity(raw_stack):
    matches = [
        stack for stack in STACK_ORDER
        if raw_stack.startswith(STACK_PREFIXES[stack])
    ]
    if len(matches) != 1:
        raise ValueError(f"Unsupported stack: {raw_stack}")
    return matches[0]


def scenario_base(raw_scenario, stack):
    suffix = "-" + STACK_PREFIXES[stack]
    if not raw_scenario.endswith(suffix):
        raise ValueError(
            f"Scenario {raw_scenario!r} does not end with stack suffix {suffix!r}"
        )
    return raw_scenario.removesuffix(suffix)


def build_summary_cells(run_ids, rows):
    by_run = {}
    for row in rows:
        by_run.setdefault(row["wtt_run_id"], []).append(row)
    scenario_order = []
    cells = {}
    common_compatibility_fields = (
        "http_version",
        "endpoint",
        "payload_bytes",
        "connection_reuse",
        "tls_resumption_configured",
        "configured_vus",
        "max_duration_s",
        "configured_rate",
        "configured_peak_rate",
    )
    for run_id in run_ids:
        selected = by_run.get(run_id, [])
        if not selected:
            raise ValueError(f"No summary metadata for supplied Run ID: {run_id}")
        family = run_family(run_id)
        if {
            (row["wtt_profile"], int(row["wtt_execution_index"]))
            for row in selected
        } != expected_executions(family):
            raise ValueError(f"{run_id} does not contain the expected executions")
        for row in selected:
            if row.get("key_exchange_group_source") != "openssl-preflight":
                raise ValueError(f"{run_id} lacks verified TLS-group evidence")
            if row.get("tls_version") not in ("1.2", "1.3"):
                raise ValueError(f"{run_id} has unsupported TLS version")
            if row.get("key_exchange_group") not in ("P-256", "X25519"):
                raise ValueError(f"{run_id} has unsupported TLS group")
            required_fields = (
                "elapsed_ms",
                "http_version",
                "endpoint",
                "payload_bytes",
                "connection_reuse",
                "tls_resumption_configured",
            )
            missing_fields = [
                field for field in required_fields
                if row.get(field, "") == ""
            ]
            if family == "race":
                missing_fields.extend(
                    field for field in (
                        "configured_vus",
                        "configured_iterations",
                        "max_duration_s",
                    )
                    if row.get(field, "") == ""
                )
            if missing_fields:
                raise ValueError(
                    f"{run_id} lacks scenario comparison metadata: "
                    f"{sorted(set(missing_fields))}"
                )
            stack = stack_identity(row["wtt_stack"])
            scenario = scenario_base(row["wtt_scenario"], stack)
            if scenario not in scenario_order:
                scenario_order.append(scenario)
            profile, repeat = profile_slot(
                family,
                row["wtt_profile"],
                int(row["wtt_execution_index"]),
            )
            compatibility_fields = (
                common_compatibility_fields
                + (("configured_iterations",) if family == "race" else ())
            )
            compatibility = tuple(
                (field, row.get(field, ""))
                for field in compatibility_fields
            )
            key = (
                row.get("tls_version", ""),
                row.get("key_exchange_group", ""),
                family,
                profile,
                compatibility,
            )
            cell = cells.setdefault(key, {
                "tls_version": row.get("tls_version", ""),
                "tls_group": row.get("key_exchange_group", ""),
                "family": family,
                "profile": profile,
                "profile_slug": PROFILE_SLUGS[profile],
                "compatibility": dict(compatibility),
                "executions": {},
            })
            identity = (scenario, stack, repeat)
            if identity in cell["executions"]:
                raise ValueError(
                    f"Duplicate scenario summary execution for "
                    f"{scenario}/{stack}/{profile}/Profile Run {repeat + 1}"
                )
            execution = {
                "run_id": run_id,
                "scenario": scenario,
                "scenario_tag": row["wtt_scenario"],
                "stack": stack,
                "stack_tag": row["wtt_stack"],
                "family": family,
                "profile": profile,
                "profile_tag": row["wtt_profile"],
                "repeat": repeat,
                "execution_index": int(row["wtt_execution_index"]),
                "elapsed_ms": row.get("elapsed_ms", ""),
            }
            cell["executions"][identity] = execution
    return scenario_order, list(cells.values())


def build_scenario_summary_groups(run_ids, rows, source_start, source_stop):
    scenario_order, cells = build_summary_cells(run_ids, rows)
    grouped = {}
    for cell in cells:
        scenarios = [
            scenario for scenario in scenario_order
            if any(key[0] == scenario for key in cell["executions"])
        ]
        if len(scenarios) < 2:
            raise ValueError(
                f"{cell['family']}/{cell['profile']} has only one scenario; "
                "scenario summaries require at least two"
            )
        stack_sets = {}
        for scenario in scenarios:
            stack_sets[scenario] = {
                stack for selected_scenario, stack, _ in cell["executions"]
                if selected_scenario == scenario
            }
        expected_stacks = stack_sets[scenarios[0]]
        for scenario in scenarios[1:]:
            if stack_sets[scenario] != expected_stacks:
                raise ValueError(
                    f"Stack sets differ for {cell['family']}/{cell['profile']}: "
                    f"{stack_sets}"
                )
        for scenario in scenarios:
            for stack in expected_stacks:
                repeats = {
                    repeat for selected_scenario, selected_stack, repeat
                    in cell["executions"]
                    if selected_scenario == scenario and selected_stack == stack
                }
                if repeats != {0, 1, 2}:
                    raise ValueError(
                        f"Incomplete Profile Runs for "
                        f"{scenario}/{stack}/{cell['family']}/{cell['profile']}: "
                        f"{sorted(repeat + 1 for repeat in repeats)}"
                    )
        cell["scenarios"] = scenarios
        cell["stacks"] = [
            stack for stack in STACK_ORDER if stack in expected_stacks
        ]
        group_key = (cell["tls_version"], cell["tls_group"])
        group = grouped.setdefault(group_key, {
            "tls_version": cell["tls_version"],
            "tls_group": cell["tls_group"],
            "source_start": source_start,
            "source_stop": source_stop,
            "scenario_order": [],
            "cells": [],
            "run_ids": set(),
        })
        for scenario in scenarios:
            if scenario not in group["scenario_order"]:
                group["scenario_order"].append(scenario)
        group["cells"].append(cell)
        group["run_ids"].update(
            execution["run_id"] for execution in cell["executions"].values()
        )
    result = []
    for group in grouped.values():
        cell_names = [
            (cell["family"], cell["profile"]) for cell in group["cells"]
        ]
        if len(cell_names) != len(set(cell_names)):
            raise ValueError(
                f"Incompatible configurations create duplicate profile cells: "
                f"{cell_names}"
            )
        expected_scenarios = group["cells"][0]["scenarios"]
        for cell in group["cells"][1:]:
            if cell["scenarios"] != expected_scenarios:
                raise ValueError(
                    f"Scenario sets differ across profiles for "
                    f"TLS {group['tls_version']}/{group['tls_group']}"
                )
        references = sorted(group["run_ids"])
        tls_slug = group["tls_version"].replace(".", "")
        group_slug = group["tls_group"].lower()
        group["id"] = f"scenario-summary-tls{tls_slug}-{group_slug}"
        group["run_ids"] = references
        group["cells"].sort(
            key=lambda cell: (
                FAMILIES.index(cell["family"]),
                tuple(PROFILE_SLUGS).index(cell["profile"]),
            )
        )
        result.append(group)
    return result


def build_tls_comparison(run_ids, rows, source_start, source_stop):
    scenario_order, source_cells = build_summary_cells(run_ids, rows)
    records = {
        (row["wtt_run_id"], int(row["wtt_execution_index"])): row
        for row in rows
    }
    profiles = {}
    run_identities = {}
    pair_stacks = {}
    for source_cell in source_cells:
        key = (source_cell["family"], source_cell["profile"])
        cell = profiles.setdefault(key, {
            "family": source_cell["family"],
            "profile": source_cell["profile"],
            "profile_slug": source_cell["profile_slug"],
            "compatibility": source_cell["compatibility"],
            "configurations": {},
        })
        if cell["compatibility"] != source_cell["compatibility"]:
            differences = [
                field for field, value in cell["compatibility"].items()
                if source_cell["compatibility"][field] != value
            ]
            raise ValueError(
                f"Incompatible TLS comparison settings for "
                f"{key[0]}/{key[1]}: {', '.join(differences)}"
            )
        configuration = (source_cell["tls_version"], source_cell["tls_group"])
        if configuration in cell["configurations"]:
            raise ValueError(f"Duplicate TLS configuration for {key}: {configuration}")
        cell["configurations"][configuration] = source_cell
        pairs = {(scenario, stack) for scenario, stack, _ in source_cell["executions"]}
        for scenario, stack in pairs:
            repeats = {
                repeat for selected_scenario, selected_stack, repeat
                in source_cell["executions"]
                if (selected_scenario, selected_stack) == (scenario, stack)
            }
            if repeats != {0, 1, 2}:
                raise ValueError(
                    f"Incomplete Profile Runs for {scenario}/{stack}/"
                    f"{key[0]}/{key[1]}/TLS {'/'.join(configuration)}"
                )
        for execution in source_cell["executions"].values():
            run_id = execution["run_id"]
            identity = (execution["scenario_tag"], execution["stack_tag"], configuration)
            if run_identities.setdefault(run_id, identity) != identity:
                raise ValueError(f"Inconsistent scenario/stack/TLS metadata for {run_id}")
            pair = (key, execution["scenario"], execution["stack"])
            if pair_stacks.setdefault(pair, execution["stack_tag"]) != execution["stack_tag"]:
                raise ValueError(f"Incompatible runtime stack tags for TLS comparison: {pair}")
            elapsed = finite_number(execution["elapsed_ms"], f"{run_id}/elapsed_ms")
            if elapsed <= 0:
                raise ValueError(f"Non-positive elapsed time for {run_id}: {elapsed}")
            if key == ("baseline", "Flat"):
                record = records[run_id, execution["execution_index"]]
                context = f"{run_id}/execution {execution['execution_index']}"
                fields = {
                    "requests": "configured_iterations",
                    **{metric: field for metric, (field, _) in TLS_BYTE_METRICS.items()},
                }
                counters = {}
                for name, field in fields.items():
                    if record.get(field, "") == "":
                        raise ValueError(f"Missing byte-chart counter {field} for {context}")
                    counters[name] = exact_count(record[field], f"{context}/{field}")
                if counters["requests"] == 0:
                    raise ValueError(f"Zero recorded requests for byte chart: {context}")
                execution["byte_counters"] = counters
    cells = sorted(
        profiles.values(),
        key=lambda cell: (
            FAMILIES.index(cell["family"]),
            tuple(PROFILE_SLUGS).index(cell["profile"]),
        ),
    )
    for cell in cells:
        pairs = {
            (scenario, stack)
            for source_cell in cell["configurations"].values()
            for scenario, stack, _ in source_cell["executions"]
        }
        cell["pairs"] = [
            (scenario, stack)
            for scenario in scenario_order
            for stack in STACK_ORDER
            if (scenario, stack) in pairs
        ]
        cell["configurations"] = {
            configuration: cell["configurations"][configuration]
            for configuration in TLS_CONFIGURATIONS
            if configuration in cell["configurations"]
        }
    references = sorted(run_ids)
    return {
        "id": "tls-comparison",
        "run_ids": references,
        "source_start": source_start,
        "source_stop": source_stop,
        "cells": cells,
    }


def parse_scenario_metadata_rows(rows):
    identity_fields = (
        "wtt_run_id",
        "wtt_scenario",
        "wtt_stack",
        "wtt_profile",
        "wtt_execution_index",
        "cell",
    )
    records = {}
    for row in rows:
        key = tuple(row.get(field, "") for field in identity_fields)
        if any(value == "" for value in key):
            raise ValueError(f"Incomplete scenario metadata identity: {row}")
        record = records.setdefault(
            key,
            dict(zip(identity_fields, key)),
        )
        field = row.get("_field", "")
        if not field:
            raise ValueError(f"Scenario metadata row lacks _field: {row}")
        if field in record:
            raise ValueError(
                f"Duplicate scenario metadata field {field} for {key}"
            )
        record[field] = row.get("_value", "")
    return list(records.values())

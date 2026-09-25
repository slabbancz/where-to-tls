import json
import re
import xml.etree.ElementTree as ET

from .bars import render_bars, render_failure_bars
from .config import (
    BAR_CHARTS, FAILURE_CHARTS, SUMMARY_METRICS, TIME_SERIES, TLS_BYTE_METRICS,
    TLS_CONFIGURATIONS,
)
from .datasets import (
    execution_elapsed_seconds,
    parse_aggregate_rows,
    parse_failure_rates,
    parse_percentiles,
    parse_pooled_percentiles,
    pooled_byte_values,
)
from .influx import (aggregate_time_series_query, failure_rate_query, origin_query,
                     percentile_query, pooled_percentile_query)
from .runs import family_runs, parse_origins
from .scenario_tables import (
    render_race_completion_bars,
    render_scenario_percentile_ranges,
)
from .svg import write_svg
from .timelines import render_race_rps_small_multiples, render_time_series
from .tls_charts import (
    TLS_BYTE_SCENARIO_CHART_LAYOUT,
    TLS_CHART_LAYOUT,
    TLS_SCENARIO_CHART_LAYOUT,
    render_tls_byte_bars,
    render_tls_completion_bars,
    render_tls_percentile_ranges,
)


def chart_names():
    return [
        config["filename"] for config in TIME_SERIES
    ] + [
        config[2] for config in BAR_CHARTS
    ] + [
        config[1] for config in FAILURE_CHARTS
    ]


def chart_specs():
    metrics = {
        "http_reqs": "rps",
        "vus": "active-vus",
        "http_req_connecting": "tcp",
        "http_req_tls_handshaking": "tls",
        "http_req_duration": "http",
    }
    specs = {
        config["filename"]: (config["family"], "timeline", metrics[config["metric"]])
        for config in TIME_SERIES
    }
    specs.update({
        filename: (family, "bars", metrics[metric])
        for family, metric, filename, *_ in BAR_CHARTS
    })
    specs.update({
        filename: (family, "bars", "failure-rate")
        for family, filename, *_ in FAILURE_CHARTS
    })
    return specs


def select_charts(selections, export_types, families):
    specs = chart_specs()
    known = set(specs) | {name.removesuffix(".svg") for name in specs}
    known.update(spec[2] for spec in specs.values())
    unknown = set(selections) - known
    if unknown:
        raise ValueError(f"Unknown charts: {sorted(unknown)}; use --list-charts")
    selected = [
        name for name, (family, form, metric) in specs.items()
        if family in families and form in export_types
        and (not selections or any(
            choice in (name, name.removesuffix(".svg"), metric)
            for choice in selections
        ))
    ]
    unmatched = [
        choice for choice in selections
        if not any(
            choice in (name, name.removesuffix(".svg"), specs[name][2])
            for name in selected
        )
    ]
    if unmatched:
        raise ValueError(
            f"Selected charts do not match supplied workload families "
            f"and export types: {unmatched}"
        )
    if not selected:
        raise ValueError("No charts match the supplied Run IDs and export types")
    return selected


def reusable_svg(target, run_ids, **expected_metadata):
    metadata = ET.parse(target).getroot().find("{http://www.w3.org/2000/svg}metadata")
    provenance = json.loads(metadata.text) if metadata is not None else {}
    if not isinstance(provenance, dict):
        raise ValueError(f"Invalid SVG provenance in {target}: expected an object")
    recorded_runs = provenance.get("run_ids", [])
    if isinstance(recorded_runs, dict):
        recorded_runs = list(recorded_runs.values())
    if not isinstance(recorded_runs, list) or any(
        not isinstance(run_id, str) for run_id in recorded_runs
    ):
        raise ValueError(f"Invalid Run IDs in SVG provenance: {target}")
    if set(recorded_runs) == set(run_ids) and all(
        provenance.get(key) == value for key, value in expected_metadata.items()
    ):
        return True
    print(f"REGENERATE {target}: source Run IDs or chart configuration changed", flush=True)
    return False


def export(
    comparison,
    influx,
    bucket,
    output_root,
    selected_charts,
    skip_existing,
    scale_mode,
):
    origins = validate_sources(comparison, influx, bucket)
    output = output_root / comparison["id"]
    generated = []
    for config in TIME_SERIES:
        if config["filename"] not in selected_charts:
            continue
        target = output / config["filename"]
        runs = family_runs(comparison, config["family"])
        if skip_existing and target.is_file() and reusable_svg(target, runs.values()):
            print(f"SKIP {target}", flush=True)
            generated.append(target)
            continue
        stacks = list(runs)
        segments = {}
        for stack in stacks:
            run_id = runs[stack]
            query = aggregate_time_series_query(
                comparison,
                run_id,
                origins[run_id],
                config["metric"],
                config["aggregate"],
                bucket,
                config.get("tls_positive", False),
                separate_executions=config.get("profile_row") is not None,
            )
            rows = influx.query(
                query,
                f'{config["filename"]} stack={stack}',
            )
            stack_segments = parse_aggregate_rows(
                rows,
                stack,
                origins[run_id],
                config["family"],
                config.get("profile_row"),
            )
            overlap = set(segments) & set(stack_segments)
            if overlap:
                raise ValueError(f"Duplicate timeline segments: {sorted(overlap)}")
            segments.update(stack_segments)
        if config["family"] == "race" and config["metric"] == "http_reqs":
            content = render_race_rps_small_multiples(
                config, comparison, stacks, segments,
            )
        else:
            content = render_time_series(
                config, comparison, stacks, segments, scale_mode,
            )
        write_svg(target, content)
        generated.append(target)
        print(f"WROTE {target}", flush=True)
    percentile_cache = {}
    for (
        family,
        metric,
        filename,
        title,
        unit,
        rate,
        tls_positive,
        profile,
    ) in BAR_CHARTS:
        if filename not in selected_charts:
            continue
        target = output / filename
        runs = family_runs(comparison, family)
        if skip_existing and target.is_file() and reusable_svg(target, runs.values()):
            print(f"SKIP {target}", flush=True)
            generated.append(target)
            continue
        stacks = list(runs)
        cache_key = (family, metric)
        if cache_key not in percentile_cache:
            rows = []
            for stack in stacks:
                run_id = runs[stack]
                rows.extend(
                    influx.query(
                        percentile_query(
                            comparison,
                            run_id,
                            origins[run_id],
                            metric,
                            bucket,
                            rate,
                            tls_positive,
                        ),
                        f"{family}/{metric} percentiles stack={stack}",
                    )
                )
            percentile_cache[cache_key] = parse_percentiles(rows, family, runs)
        values = percentile_cache[cache_key]
        write_svg(
            target,
            render_bars(
                family,
                profile,
                title,
                unit,
                comparison,
                stacks,
                values,
                scale_mode,
            ),
        )
        generated.append(target)
        print(f"WROTE {target}", flush=True)
    failure_cache = {}
    for family, filename, title, profile in FAILURE_CHARTS:
        if filename not in selected_charts:
            continue
        target = output / filename
        runs = family_runs(comparison, family)
        if skip_existing and target.is_file() and reusable_svg(target, runs.values()):
            print(f"SKIP {target}", flush=True)
            generated.append(target)
            continue
        stacks = list(runs)
        if family not in failure_cache:
            rows = []
            for stack in stacks:
                run_id = runs[stack]
                rows.extend(
                    influx.query(
                        failure_rate_query(
                            comparison,
                            run_id,
                            origins[run_id],
                            bucket,
                        ),
                        f"{family}/failure-rate stack={stack}",
                    )
                )
            failure_cache[family] = parse_failure_rates(rows, family, runs)
        write_svg(
            target,
            render_failure_bars(
                family,
                profile,
                title,
                comparison,
                stacks,
                failure_cache[family],
            ),
        )
        generated.append(target)
        print(f"WROTE {target}", flush=True)
    expected = set(selected_charts)
    actual = {path.name for path in generated}
    if actual != expected or len(generated) != len(expected):
        raise ValueError(
            f"Expected {len(expected)} SVGs, generated "
            f"{len(generated)}: {sorted(actual)}"
        )
    return generated


def validate_sources(comparison, influx, bucket):
    origins = parse_origins(
        comparison,
        influx.query(origin_query(comparison, bucket), "Run ID origins"),
    )
    print(
        f"VALID {comparison['id']} runs={len(origins)} "
        f"tls={comparison['tls_version']}/{comparison['tls_group']}",
        flush=True,
    )
    return origins


def scenario_summary_filename(cell):
    return (
        f"scenario-summary-{cell['family']}-"
        f"{cell['profile_slug']}.svg"
    )


def scenario_percentile_filename(cell, metric):
    return (
        f"scenario-percentiles-{metric}-{cell['family']}-"
        f"{cell['profile_slug']}.svg"
    )


def scenario_completion_filename(cell):
    return (
        f"scenario-completion-{cell['family']}-"
        f"{cell['profile_slug']}.svg"
    )


def cell_executions(cell, scenario, stack):
    executions = [
        execution for (selected_scenario, selected_stack, _), execution
        in cell["executions"].items()
        if selected_scenario == scenario and selected_stack == stack
    ]
    executions.sort(key=lambda execution: execution["repeat"])
    if [execution["repeat"] for execution in executions] != [0, 1, 2]:
        raise ValueError(
            f"Incomplete executions for "
            f"{scenario}/{stack}/{cell['family']}/{cell['profile']}"
        )
    return executions


def pooled_summary_values(influx, group, executions, metric, bucket, context):
    measurement, _, positive = SUMMARY_METRICS[metric]
    values = parse_pooled_percentiles(
        influx.query(
            pooled_percentile_query(group, executions, measurement, bucket, positive),
            f"{context}/{metric.upper()} percentiles",
        ),
        f"{context}/{metric.upper()}",
    )
    return {
        f"{metric}_{statistic.lower()}": value
        for statistic, value in values.items()
    }


def remove_obsolete_summary(path):
    if path.is_file():
        path.unlink()
        print(f"REMOVE {path}", flush=True)


def export_scenario_summaries(
    groups,
    influx,
    bucket,
    output_root,
    skip_existing,
    scale_mode,
):
    generated = []
    for group in groups:
        output = output_root / group["id"]
        race_completion_axis_values = [
            execution_elapsed_seconds(
                execution,
                f"{execution['scenario']}/{execution['stack']}/race",
            )
            for cell in group["cells"]
            if cell["family"] == "race"
            for execution in cell["executions"].values()
        ]
        expected = {
            scenario_percentile_filename(cell, metric)
            for cell in group["cells"] for metric in SUMMARY_METRICS
        } | {
            scenario_completion_filename(cell)
            for cell in group["cells"]
            if cell["family"] == "race"
        }
        expected_count = len(group["cells"]) * len(SUMMARY_METRICS) + sum(
            cell["family"] == "race" for cell in group["cells"]
        )
        if len(expected) != expected_count:
            raise ValueError(
                f"Duplicate scenario summary filenames in {group['id']}"
            )
        actual = set()
        for cell in group["cells"]:
            percentile_names = {
                scenario_percentile_filename(cell, metric): metric
                for metric in SUMMARY_METRICS
            }
            targets = {filename: output / filename for filename in percentile_names}
            completion_name = scenario_completion_filename(cell)
            if cell["family"] == "race":
                targets[completion_name] = output / completion_name
            pending = {}
            for filename, target in targets.items():
                if (
                    skip_existing and target.is_file()
                    and reusable_svg(target, group["run_ids"])
                ):
                    print(f"SKIP {target}", flush=True)
                    generated.append(target)
                    actual.add(filename)
                else:
                    pending[filename] = target
            if not pending:
                remove_obsolete_summary(output / scenario_summary_filename(cell))
                remove_obsolete_summary(
                    output / f"scenario-percentiles-{cell['family']}-{cell['profile_slug']}.svg"
                )
                continue
            rows = []
            for scenario in cell["scenarios"]:
                for stack in cell["stacks"]:
                    executions = cell_executions(cell, scenario, stack)
                    context = (
                        f"{scenario}/{stack}/{cell['family']}/"
                        f"{cell['profile']}"
                    )
                    row = {"scenario": scenario, "stack": stack}
                    for filename, metric in percentile_names.items():
                        if filename in pending:
                            row.update(pooled_summary_values(
                                influx, group, executions, metric, bucket,
                                f"scenario-summary {context}",
                            ))
                    if completion_name in pending:
                        row["completion_runs_s"] = [
                            execution_elapsed_seconds(execution, context)
                            for execution in executions
                        ]
                    rows.append(row)
            contents = {}
            for filename in pending:
                contents[filename] = (
                    render_scenario_percentile_ranges(
                        group, cell, rows, scale_mode, percentile_names[filename],
                    ) if filename in percentile_names else
                    render_race_completion_bars(group, cell, rows, race_completion_axis_values)
                )
            for filename, target in pending.items():
                write_svg(target, contents[filename])
                generated.append(target)
                actual.add(filename)
                print(f"WROTE {target}", flush=True)
            remove_obsolete_summary(output / scenario_summary_filename(cell))
            remove_obsolete_summary(
                output / f"scenario-percentiles-{cell['family']}-{cell['profile_slug']}.svg"
            )
        if actual != expected:
            raise ValueError(
                f"Expected {len(expected)} scenario summary SVGs for "
                f"{group['id']}, generated {len(actual)}: {sorted(actual)}"
            )
    return generated


def validate_scenario_summary_groups(groups):
    for group in groups:
        print(
            f"VALID {group['id']} scenarios={len(group['scenario_order'])} "
            f"profiles={len(group['cells'])} "
            f"tls={group['tls_version']}/{group['tls_group']}",
            flush=True,
        )


def tls_configuration_executions(cell, scenario, stack, configuration):
    source_cell = cell["configurations"].get(configuration)
    if source_cell is None or (scenario, stack, 0) not in source_cell["executions"]:
        return []
    return cell_executions(source_cell, scenario, stack)


def tls_scenario_slug(scenario):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", scenario):
        raise ValueError(f"Invalid scenario for TLS comparison filename: {scenario!r}")
    return scenario


def tls_percentile_filename(cell, metric, scenario):
    return (
        f"tls-percentiles-{metric}-{cell['family']}-"
        f"{cell['profile_slug']}-{tls_scenario_slug(scenario)}.svg"
    )


def tls_byte_filename(cell, metric, scenario):
    return (
        f"tls-bytes-{metric}-{cell['family']}-"
        f"{cell['profile_slug']}-{tls_scenario_slug(scenario)}.svg"
    )


def tls_scenario_run_ids(cell, scenario):
    return sorted({
        execution["run_id"]
        for source_cell in cell["configurations"].values()
        for execution in source_cell["executions"].values()
        if execution["scenario"] == scenario
    })


def validate_tls_comparison(comparison):
    for cell in comparison["cells"]:
        for scenario, stack in cell["pairs"]:
            present, missing = [], []
            for configuration in TLS_CONFIGURATIONS:
                target = (
                    present if tls_configuration_executions(
                        cell, scenario, stack, configuration,
                    ) else missing
                )
                target.append("/".join(configuration))
            print(
                f"VALID {scenario}/{stack}/{cell['family']}/{cell['profile']} "
                f"available={','.join(present)} missing={','.join(missing) or 'none'}",
                flush=True,
            )


def export_tls_comparison(
    comparison, influx, bucket, output_root, skip_existing, scale_mode="logarithmic",
):
    output = output_root / comparison["id"]
    generated = []
    race_axis_values = [
        execution_elapsed_seconds(execution, f"{execution['run_id']}/race")
        for cell in comparison["cells"] if cell["family"] == "race"
        for source_cell in cell["configurations"].values()
        for execution in source_cell["executions"].values()
    ]
    for cell in comparison["cells"]:
        scenarios = list(dict.fromkeys(scenario for scenario, _ in cell["pairs"]))
        percentile_names = {
            tls_percentile_filename(cell, metric, scenario): (metric, scenario)
            for scenario in scenarios for metric in SUMMARY_METRICS
        }
        scenario_run_ids = {
            scenario: tls_scenario_run_ids(cell, scenario)
            for scenario in scenarios
        }
        obsolete = output / f"tls-percentiles-{cell['family']}-{cell['profile_slug']}.svg"
        obsolete_percentiles = [
            output / f"tls-percentiles-{metric}-{cell['family']}-{cell['profile_slug']}.svg"
            for metric in SUMMARY_METRICS
        ]
        completion_name = f"tls-completion-race-{cell['profile_slug']}.svg"
        byte_names = {
            tls_byte_filename(cell, metric, scenario): (metric, scenario)
            for scenario in scenarios for metric in TLS_BYTE_METRICS
        } if (cell["family"], cell["profile"]) == ("baseline", "Flat") else {}
        obsolete_bytes = [
            output / f"tls-bytes-{metric}-baseline-flat.svg"
            for metric in TLS_BYTE_METRICS
        ] if byte_names else []
        filenames = list(percentile_names) + list(byte_names)
        if cell["family"] == "race":
            filenames.append(completion_name)
        pending = []
        for filename in filenames:
            target = output / filename
            if skip_existing and target.is_file():
                expected_scale = scale_mode if filename in percentile_names else "linear"
                expected_metadata = {"layout": TLS_CHART_LAYOUT, "scale": expected_scale}
                if filename in percentile_names:
                    metric, scenario = percentile_names[filename]
                    expected_metadata.update({
                        "layout": TLS_SCENARIO_CHART_LAYOUT,
                        "percentile_metric": metric,
                        "scenario": scenario,
                    })
                    run_ids = scenario_run_ids[scenario]
                elif filename in byte_names:
                    metric, scenario = byte_names[filename]
                    expected_metadata.update({
                        "layout": TLS_BYTE_SCENARIO_CHART_LAYOUT,
                        "byte_metric": metric,
                        "scenario": scenario,
                    })
                    run_ids = scenario_run_ids[scenario]
                else:
                    run_ids = comparison["run_ids"]
                if reusable_svg(target, run_ids, **expected_metadata):
                    print(f"SKIP {target}", flush=True)
                    generated.append(target)
                    continue
            pending.append(filename)
        if not pending:
            remove_obsolete_summary(obsolete)
            for target in obsolete_percentiles + obsolete_bytes:
                remove_obsolete_summary(target)
            continue
        rows = []
        for scenario, stack in cell["pairs"]:
            for version, group in TLS_CONFIGURATIONS:
                executions = tls_configuration_executions(
                    cell, scenario, stack, (version, group),
                )
                row = {
                    "scenario": scenario,
                    "stack": stack,
                    "tls_version": version,
                    "tls_group": group,
                    "available": bool(executions),
                    "executions": executions,
                }
                if executions:
                    context = (
                        f"{scenario}/{stack}/{cell['family']}/{cell['profile']}/"
                        f"TLS {version}/{group}"
                    )
                    for filename, (metric, selected_scenario) in percentile_names.items():
                        if filename in pending and scenario == selected_scenario:
                            row.update(pooled_summary_values(
                                influx, comparison, executions, metric, bucket,
                                f"TLS comparison {context}",
                            ))
                    if cell["family"] == "race":
                        row["completion_runs_s"] = [
                            execution_elapsed_seconds(execution, context)
                            for execution in executions
                        ]
                    if any(
                        filename in pending and selected_scenario == scenario
                        for filename, (_, selected_scenario) in byte_names.items()
                    ):
                        row.update(pooled_byte_values(executions, context))
                rows.append(row)
        contents = {}
        for filename in pending:
            if filename in percentile_names:
                metric, scenario = percentile_names[filename]
                scenario_cell = {
                    **cell,
                    "scenario": scenario,
                    "pairs": [pair for pair in cell["pairs"] if pair[0] == scenario],
                }
                scenario_comparison = {
                    **comparison, "run_ids": scenario_run_ids[scenario],
                }
                contents[filename] = render_tls_percentile_ranges(
                    scenario_comparison, scenario_cell,
                    [row for row in rows if row["scenario"] == scenario],
                    scale_mode, metric,
                )
            elif filename in byte_names:
                metric, scenario = byte_names[filename]
                scenario_cell = {
                    **cell,
                    "scenario": scenario,
                    "pairs": [pair for pair in cell["pairs"] if pair[0] == scenario],
                }
                scenario_comparison = {
                    **comparison, "run_ids": scenario_run_ids[scenario],
                }
                contents[filename] = render_tls_byte_bars(
                    scenario_comparison, scenario_cell,
                    [row for row in rows if row["scenario"] == scenario],
                    metric,
                )
            else:
                contents[filename] = render_tls_completion_bars(
                    comparison, cell, rows, race_axis_values,
                )
        for filename in pending:
            target = output / filename
            write_svg(target, contents[filename])
            generated.append(target)
            print(f"WROTE {target}", flush=True)
        remove_obsolete_summary(obsolete)
        for target in obsolete_percentiles + obsolete_bytes:
            remove_obsolete_summary(target)
    return generated

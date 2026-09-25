import argparse
from datetime import datetime, timezone
from pathlib import Path

from .common import artifact_run_id, read_token_file, split_selections, timestamp_ns
from .config import DEFAULT_OUTPUT, DEFAULT_TOKEN_FILE
from .exporter import (
    chart_specs,
    export,
    export_scenario_summaries,
    export_tls_comparison,
    select_charts,
    validate_scenario_summary_groups,
    validate_sources,
    validate_tls_comparison,
)
from .influx import Influx, metadata_query, scenario_metadata_query
from .runs import (
    build_comparisons,
    build_scenario_summary_groups,
    build_tls_comparison,
    parse_scenario_metadata_rows,
    run_family,
)


def main():
    parser = argparse.ArgumentParser(
        description="Export selected charts directly from supplied Run IDs. "
        "Scenario and TLS groups are read from summary metadata, never a manifest.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--run-ids", "--run-id",
        dest="run_ids",
        action="append",
        metavar="ID[,ID...]",
        help="exact Run IDs or full artifact references, comma-separated or repeated",
    )
    parser.add_argument(
        "--output-root", type=Path, default=DEFAULT_OUTPUT,
        help="output directory; uses stable scenario/TLS folder names without "
        "run-set hashes, and tls-comparison/ for --tls-comparison",
    )
    parser.add_argument(
        "--url",
        default="http://localhost:8086",
        help="InfluxDB URL",
    )
    parser.add_argument("--org", default="where-to-tls", help="InfluxDB organization")
    parser.add_argument("--token", help="InfluxDB token; overrides --token-file")
    parser.add_argument(
        "--token-file",
        type=Path,
        default=DEFAULT_TOKEN_FILE,
        help="file containing INFLUX_TOKEN used when --token is omitted",
    )
    parser.add_argument("--query-timeout", type=int, default=600,
                        help="timeout in seconds per query")
    parser.add_argument("--source-start",
                        help="UTC RFC3339 lower bound; defaults to earliest Run ID's UTC day")
    parser.add_argument("--source-stop",
                        help="UTC RFC3339 exclusive upper bound; defaults to script start time")
    parser.add_argument(
        "--charts", "--chart",
        dest="charts",
        action="append",
        metavar="NAME[,NAME...]",
        help="rps, active-vus, tcp, tls, http, failure-rate, or exact chart filenames; "
        "comma-separated or repeated; defaults to all charts for supplied families",
    )
    parser.add_argument(
        "--export-types", "--export-type",
        dest="export_types",
        action="append",
        metavar="timeline,bars",
        help="chart forms, comma-separated or repeated; defaults to timeline,bars",
    )
    parser.add_argument(
        "--scale",
        choices=("logarithmic", "linear"),
        default="logarithmic",
        help="value scale for percentile charts and TCP/TLS/HTTP timing timelines; "
        "race completion and byte-counter bars always use linear axes",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--comparison",
        action="store_true",
        help="pool Profile Runs and export separate HTTP and TLS percentile SVGs "
        "per profile, plus race completion charts, comparing scenarios",
    )
    modes.add_argument(
        "--tls-comparison",
        action="store_true",
        help="compare TLS 1.2/1.3 and P-256/X25519 in four-row blocks "
        "per stack: separate HTTP and TLS percentile SVGs per scenario and workload profile "
        "with P50-P90 bands and P90-P99 tails and exact values, plus three race completion bars "
        "per configuration. Baseline Flat also exports client bytes sent/received "
        "per request charts per scenario using summed byte counters divided by summed recorded requests "
        "over three repeats (including failed requests); requires saved summary byte counters. "
        "Missing supplied configurations are N/A",
    )
    parser.add_argument(
        "--skip-existing",
        action="store_true",
        help="reuse well-formed SVGs with matching source Run IDs; "
        "TLS comparison also checks chart layout and scale",
    )
    parser.add_argument(
        "--list-charts",
        action="store_true",
        help="list chart filenames and exit",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="validate supplied-run metadata without rendering; detailed mode "
        "also checks raw Run ID origins; --tls-comparison reports configuration coverage",
    )
    parser.add_argument(
        "--bucket",
        default="k6",
        help="InfluxDB bucket",
    )
    args = parser.parse_args()
    if args.list_charts:
        for name, (family, form, metric) in chart_specs().items():
            print(f"{name}\tchart={metric}\ttype={form}\tfamily={family}")
        return
    if not args.run_ids:
        parser.error("--run-ids is required; no runs are selected automatically")
    if (args.comparison or args.tls_comparison) and (args.charts or args.export_types):
        mode = "--comparison" if args.comparison else "--tls-comparison"
        parser.error(
            f"--charts and --export-types cannot be used with {mode}"
        )
    for name in ("url", "org", "bucket"):
        if not getattr(args, name):
            parser.error(f"--{name} must not be empty")
    if args.query_timeout < 1:
        parser.error("--query-timeout must be positive")
    try:
        run_ids = list(dict.fromkeys(
            artifact_run_id(reference) for reference in split_selections(args.run_ids)
        ))
        families = {run_family(run_id) for run_id in run_ids}
        export_types = split_selections(args.export_types or ["timeline,bars"])
        if set(export_types) - {"timeline", "bars"}:
            raise ValueError("--export-types accepts timeline,bars")
        selected_charts = select_charts(
            split_selections(args.charts or []), export_types, families,
        )
        earliest = min(datetime.strptime(run_id[:16], "%Y%m%dT%H%M%SZ")
                       for run_id in run_ids)
        source_start = args.source_start or earliest.strftime("%Y-%m-%dT00:00:00Z")
        source_stop = args.source_stop or datetime.now(timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        if timestamp_ns(source_start) >= timestamp_ns(source_stop):
            raise ValueError("--source-start must precede --source-stop")
    except ValueError as error:
        parser.error(str(error))
    if args.token is None:
        try:
            args.token = read_token_file(args.token_file)
        except ValueError as error:
            parser.error(str(error))
    elif not args.token:
        parser.error("--token must not be empty")
    influx = Influx(args.url, args.org, args.token, args.query_timeout)
    if args.comparison or args.tls_comparison:
        label = "TLS comparison" if args.tls_comparison else "scenario summary"
        metadata = parse_scenario_metadata_rows(
            influx.query(
                scenario_metadata_query(
                    run_ids,
                    source_start,
                    source_stop,
                    args.bucket,
                    include_byte_counters=args.tls_comparison,
                ),
                f"{label} metadata runs={len(run_ids)}",
            )
        )
        if args.tls_comparison:
            try:
                comparison = build_tls_comparison(
                    run_ids, metadata, source_start, source_stop,
                )
            except ValueError as error:
                parser.error(f"Invalid TLS comparison: {error}")
            if args.validate_only:
                validate_tls_comparison(comparison)
            else:
                export_tls_comparison(
                    comparison, influx, args.bucket, args.output_root, args.skip_existing,
                    args.scale,
                )
            return
        try:
            groups = build_scenario_summary_groups(
                run_ids,
                metadata,
                source_start,
                source_stop,
            )
        except ValueError as error:
            parser.error(f"Invalid scenario summary: {error}")
        if args.validate_only:
            validate_scenario_summary_groups(groups)
        else:
            export_scenario_summaries(
                groups,
                influx,
                args.bucket,
                args.output_root,
                args.skip_existing,
                args.scale,
            )
        return
    metadata = influx.query(
        metadata_query(run_ids, source_start, source_stop, args.bucket),
        f"summary metadata runs={len(run_ids)}",
    )
    comparisons = build_comparisons(run_ids, metadata, source_start, source_stop)
    specs = chart_specs()
    for comparison in comparisons:
        available_families = {
            family for runs in comparison["stacks"].values() for family in runs
        }
        charts = [
            name for name in selected_charts
            if specs[name][0] in available_families
        ]
        if not charts:
            print(f"SKIP {comparison['id']}: no selected charts for its families", flush=True)
            continue
        print(
            f"EXPORT {comparison['id']} "
            f"runs={sum(len(runs) for runs in comparison['stacks'].values())} "
            f"charts={len(charts)}",
            flush=True,
        )
        if args.validate_only:
            validate_sources(comparison, influx, args.bucket)
        else:
            export(
                comparison,
                influx,
                args.bucket,
                args.output_root,
                charts,
                args.skip_existing,
                args.scale,
            )

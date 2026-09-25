import html
import json
import textwrap

from .config import (
    ADAPTIVE_STYLE, FAMILY_LABELS, STACK_COLORS, STACK_LABELS, SUMMARY_METRICS,
    TLS_BYTE_METRICS, TLS_CONFIGURATIONS,
)
from .scenario_tables import SCENARIO_PERCENTILE_MAX_MS, format_completion
from .svg import format_axis_tick, format_bar_value, percentile_range_marks, svg_text, value_axis

TLS_CHART_LAYOUT = "tls-comparison-charts-v1"
TLS_SCENARIO_CHART_LAYOUT = "tls-comparison-charts-v2-scenarios"
TLS_BYTE_CHART_LAYOUT = "tls-byte-counters-v1"
TLS_BYTE_SCENARIO_CHART_LAYOUT = "tls-byte-counters-v2-scenarios"


def render_tls_percentile_ranges(comparison, cell, rows, scale_mode, metric):
    if metric not in SUMMARY_METRICS:
        raise ValueError(f"Unsupported summary metric: {metric}")
    return render_tls_chart(
        comparison, cell, rows, scale_mode, completion=False, metric=metric,
    )


def render_tls_completion_bars(comparison, cell, rows, axis_values):
    if cell["family"] != "race":
        raise ValueError("TLS completion charts require a race profile")
    return render_tls_chart(
        comparison, cell, rows, "linear", completion=True, axis_values=axis_values,
    )


def render_tls_byte_bars(comparison, cell, rows, metric):
    if (cell["family"], cell["profile"]) != ("baseline", "Flat"):
        raise ValueError("TLS byte charts require the Baseline Flat profile")
    if metric not in TLS_BYTE_METRICS:
        raise ValueError(f"Unsupported TLS byte metric: {metric}")
    return render_tls_chart(
        comparison, cell, rows, "linear", completion=False, byte_metric=metric,
    )


def render_tls_chart(
    comparison, cell, rows, scale_mode, completion, axis_values=None, metric=None,
    byte_metric=None,
):
    expected = [
        (scenario, stack, version, group)
        for scenario, stack in cell["pairs"]
        for version, group in TLS_CONFIGURATIONS
    ]
    actual = [
        (row["scenario"], row["stack"], row["tls_version"], row["tls_group"])
        for row in rows
    ]
    if not expected or actual != expected:
        raise ValueError("TLS charts require four ordered configuration rows per pair")
    byte_chart = byte_metric is not None
    if byte_chart:
        panels = [(byte_metric, TLS_BYTE_METRICS[byte_metric][1] + " per request")]
        value_keys = [
            f"{byte_metric}_bytes_per_request", f"{byte_metric}_bytes", "request_count",
        ]
        detail = "Sum of client byte counters / sum of recorded HTTP requests across Profile Runs 1-3; linear scale."
        legend = "Includes TLS and HTTP stream bytes and failed requests; excludes TCP/IP headers and retransmitted packets."
        visualization = "one horizontal bytes-per-request bar per TLS configuration"
        axis_values = [
            row[f"{byte_metric}_bytes_per_request"] for row in rows if row["available"]
        ]
    elif completion:
        panels = [("completion", "Race completion")]
        value_keys = ["completion_runs_s"]
        detail = "Three Profile Runs shown separately; light to dark = Run 1, Run 2, Run 3."
        legend = "Shared linear seconds axis across all supplied race profiles and TLS configurations."
        visualization = "three horizontal completion bars per TLS configuration"
        values = [
            value for row in rows if row["available"]
            for value in row["completion_runs_s"]
        ]
        if not axis_values or any(value not in axis_values for value in values):
            raise ValueError("TLS completion axis does not cover every row value")
    else:
        panels = [(metric, SUMMARY_METRICS[metric][1])]
        value_keys = [
            f"{prefix}_{statistic}" for prefix, _ in panels
            for statistic in ("p50", "p90", "p99")
        ]
        samples = "positive TLS handshake samples" if metric == "tls" else "HTTP response-time samples"
        detail = f"Profile Runs 1-3 pooled within each configuration; {samples}; {scale_mode} scale."
        legend = (
            "Thick band: P50-P90; thin tail: P90-P99. "
            "Axis capped at 1,000 ms; values above the cap remain in the value columns."
        )
        visualization = "P50 marker, P50-to-P90 band, P90-to-P99 tail"
    title = f"TLS comparison - {FAMILY_LABELS[cell['family']]} - {cell['profile']}"
    if byte_chart:
        title = f"TLS comparison - {TLS_BYTE_METRICS[byte_metric][1]} per request - Baseline - Flat"
        if "scenario" in cell:
            title += f" - {cell['scenario']}"
    elif not completion:
        title = f"TLS comparison - {metric.upper()} percentiles - {FAMILY_LABELS[cell['family']]} - {cell['profile']}"
        if "scenario" in cell:
            title += f" - {cell['scenario']}"
    provenance = {
        "mode": "tls-comparison",
        "layout": (
            TLS_BYTE_SCENARIO_CHART_LAYOUT if byte_chart and "scenario" in cell else
            TLS_BYTE_CHART_LAYOUT if byte_chart else
            TLS_SCENARIO_CHART_LAYOUT if "scenario" in cell else TLS_CHART_LAYOUT
        ),
        "visualization": visualization,
        "metric": panels[0][1] if byte_chart else (
            "race completion" if completion else f"{metric.upper()} percentiles"
        ),
        "family": cell["family"],
        "profile": cell["profile"],
        "source_start": comparison["source_start"],
        "source_stop": comparison["source_stop"],
        "run_ids": comparison["run_ids"],
        "compatibility": cell["compatibility"],
        "scale": scale_mode,
        "configuration_order": [
            {"tls_version": version, "tls_group": group}
            for version, group in TLS_CONFIGURATIONS
        ],
        "pooling": {
            "profile_runs": [1, 2, 3],
            "http_percentiles": "quantiles over pooled raw http_req_duration samples",
            "tls_percentiles": "quantiles over pooled positive http_req_tls_handshaking samples",
            "quantile_method": "estimate_tdigest",
            "race_completion": "three execution elapsed_ms values shown separately, not paired across configurations",
        },
        "missing": "N/A means this configuration was not supplied for this topology/stack/profile",
        "rows": [
            {
                key: row[key]
                for key in (
                    "scenario", "stack", "tls_version", "tls_group", "available",
                    "executions", *value_keys,
                )
                if key in row
            }
            for row in rows
        ],
    }
    if "scenario" in cell:
        provenance["scenario"] = cell["scenario"]
    if byte_chart:
        provenance["byte_metric"] = byte_metric
        provenance["axis_max_bytes_per_request"] = value_axis(axis_values, "linear")["ticks"][-1]
        provenance["pooling"] = {
            "profile_runs": [1, 2, 3],
            "formula": "sum(byte counters) / sum(recorded HTTP requests)",
            "source_measurement": "wtt_k6_summary",
            "numerator_field": TLS_BYTE_METRICS[byte_metric][0],
            "denominator_field": "configured_iterations",
            "denominator_source": (
                "For baseline runs the importer stores record.iterations, the actual k6 "
                "http_reqs count including failures, in configured_iterations; "
                "this is not the configured arrival-rate target."
            ),
            "units": "bytes/request",
            "scope": legend,
            "interpretation": (
                "Traffic counters support comparison of transfer sizes; "
                "they do not identify individual TLS handshake messages."
            ),
        }
    elif completion:
        provenance["completion_axis"] = legend
        provenance["completion_axis_max_s"] = value_axis(axis_values, "linear")["ticks"][-1]
    else:
        provenance["percentile_metric"] = metric
        provenance["axis_max_ms"] = SCENARIO_PERCENTILE_MAX_MS
        provenance["overflow"] = (
            "values above axis_max_ms are clipped at the plot boundary; "
            "exact values remain in the P50/P90/P99 columns"
        )
    width, left, right = 1900, 310, 420
    plot_width = width - left - right
    labels = [
        textwrap.wrap(f"{scenario} - {STACK_LABELS[stack]}", width=110)
        for scenario, stack in cell["pairs"]
    ]
    row_height = 48 if completion else 32
    block_heights = [len(lines) * 20 + 14 + 4 * row_height + 12 for lines in labels]
    body_height = sum(block_heights)
    top, panel_header, panel_gap, bottom = 120, 46, 60, 75
    panel_height = panel_header + body_height
    height = top + len(panels) * panel_height + (len(panels) - 1) * panel_gap + bottom
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        f"<metadata>{html.escape(json.dumps(provenance, sort_keys=True))}</metadata>",
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(title + " - " + provenance["metric"])}</title>',
        f'<desc id="desc">{html.escape(detail + " " + legend + " " + provenance["missing"])}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        svg_text(30, 35, title, 24, weight=700),
        svg_text(30, 64, detail, 13, css_class="theme-muted"),
        svg_text(30, 86, legend, 13, css_class="theme-muted"),
    ]
    for panel_index, (prefix, label) in enumerate(panels):
        panel_top = top + panel_index * (panel_height + panel_gap)
        plot_top = panel_top + panel_header
        plot_bottom = plot_top + body_height
        if completion or byte_chart:
            axis = value_axis(axis_values, "linear")
            x = lambda value: left + axis["position"](value) * plot_width
            columns = (
                [("Bytes / request", f"{byte_metric}_bytes_per_request"),
                 ("Total bytes", f"{byte_metric}_bytes"), ("Requests", "request_count")]
                if byte_chart else
                [(f"Run {repeat + 1}", repeat) for repeat in range(3)]
            )
        else:
            values = [
                min(row[f"{prefix}_{statistic}"], SCENARIO_PERCENTILE_MAX_MS)
                for row in rows if row["available"]
                for statistic in ("p50", "p90", "p99")
            ]
            values.append(SCENARIO_PERCENTILE_MAX_MS)
            if scale_mode == "logarithmic":
                values.append(1.0)
            axis = value_axis(values, scale_mode)
            x = lambda value: left + axis["position"](
                min(value, SCENARIO_PERCENTILE_MAX_MS)
            ) * plot_width
            columns = [(statistic.upper(), f"{prefix}_{statistic}") for statistic in ("p50", "p90", "p99")]
        parts.append(svg_text(30, panel_top + 27, label, 16, weight=700))
        for index, (label, _) in enumerate(columns):
            parts.append(svg_text(
                width - 315 + index * 130, panel_top + 27, label, 11,
                anchor="end", weight=700,
            ))
        parts.append(
            f'<rect class="theme-plot theme-border" x="{left}" y="{plot_top}" '
            f'width="{plot_width}" height="{body_height}" fill="#f8fafc" stroke="#cbd5e1"/>'
        )
        for tick in axis["ticks"]:
            xx = x(tick)
            parts.append(
                f'<line class="theme-grid" x1="{xx:.2f}" y1="{plot_top}" '
                f'x2="{xx:.2f}" y2="{plot_bottom}" stroke="#e2e8f0"/>'
            )
            tick_label = (
                f"{tick:,.0f}" if byte_chart else
                format_completion(tick) if completion else format_axis_tick(tick, "ms", scale_mode)
            )
            parts.append(svg_text(
                xx, plot_top - 10, tick_label, 10, anchor="middle", css_class="theme-muted",
            ))
        group_top = plot_top
        for pair_index, (_, stack) in enumerate(cell["pairs"]):
            header_height = len(labels[pair_index]) * 20 + 14
            parts.append(
                f'<rect class="theme-bg" x="30" y="{group_top}" width="{width - 60}" '
                f'height="{header_height}" fill="#ffffff"/>'
            )
            parts.append(
                f'<rect x="30" y="{group_top}" width="4" height="{header_height}" '
                f'fill="{STACK_COLORS[stack][1]}"/>'
            )
            for line_index, line in enumerate(labels[pair_index]):
                parts.append(svg_text(45, group_top + 22 + line_index * 20, line, 13, weight=700))
            for configuration_index in range(4):
                row = rows[pair_index * 4 + configuration_index]
                row_top = group_top + header_height + configuration_index * row_height
                y = row_top + row_height / 2
                parts.append(svg_text(
                    left - 12, y + 4, f"TLS {row['tls_version']} / {row['tls_group']}",
                    12, anchor="end",
                ))
                if row["available"]:
                    color = STACK_COLORS[stack][1]
                    if byte_chart:
                        value = row[f"{prefix}_bytes_per_request"]
                        parts.append(
                            f'<rect class="byte-bar" x="{left}" y="{y - 7:.2f}" '
                            f'width="{x(value) - left:.2f}" height="14" rx="3" fill="{color}">'
                            f'<title>{value:,.2f} bytes/request; '
                            f'{row[f"{prefix}_bytes"]:,} bytes / '
                            f'{row["request_count"]:,} requests</title></rect>'
                        )
                    elif completion:
                        for repeat, value in enumerate(row["completion_runs_s"]):
                            parts.append(
                                f'<rect class="completion-bar" x="{left}" '
                                f'y="{row_top + 5 + repeat * 13}" '
                                f'width="{x(value) - left:.2f}" height="9" rx="3" '
                                f'fill="{STACK_COLORS[stack][repeat]}">'
                                f'<title>Profile Run {repeat + 1}: '
                                f'{html.escape(format_completion(value))}</title></rect>'
                            )
                    else:
                        parts.extend(percentile_range_marks(
                            x, y, row[f"{prefix}_p50"], row[f"{prefix}_p90"],
                            row[f"{prefix}_p99"], color,
                            f"{row['scenario']}/{stack}/TLS {row['tls_version']}/{row['tls_group']}/{prefix}",
                        ))
                for index, (_, key) in enumerate(columns):
                    if not row["available"]:
                        value = "N/A"
                    elif byte_chart:
                        value = (
                            f"{row[key]:,.2f}" if key.endswith("_per_request")
                            else f"{row[key]:,}"
                        )
                    elif completion:
                        value = format_completion(row["completion_runs_s"][key])
                    else:
                        value = format_bar_value(row[key], "ms")
                    parts.append(svg_text(
                        width - 315 + index * 130, y + 4, value, 11,
                        anchor="end", css_class="theme-muted",
                    ))
            group_top += block_heights[pair_index]
        parts.append(svg_text(
            left + plot_width / 2, plot_bottom + 28,
            "Bytes per request (linear)" if byte_chart else (
                "Seconds (linear)" if completion else f"Milliseconds ({scale_mode})"
            ),
            11, anchor="middle", css_class="theme-muted",
        ))
    parts.append(svg_text(
        30, height - 18, provenance["missing"] + ".", 12, css_class="theme-muted",
    ))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"

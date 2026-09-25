import html
import json

from .config import (
    ADAPTIVE_STYLE,
    FAMILY_LABELS,
    STACK_COLORS,
    STACK_LABELS,
    SUMMARY_METRICS,
)
from .svg import (
    format_axis_tick,
    format_bar_value,
    percentile_range_marks,
    svg_text,
    value_axis,
)

SCENARIO_PERCENTILE_MAX_MS = 1000.0


def format_completion(value):
    if value >= 100:
        number = f"{value:,.0f}"
    elif value >= 10:
        number = f"{value:,.1f}".rstrip("0").rstrip(".")
    else:
        number = f"{value:,.2f}".rstrip("0").rstrip(".")
    return f"{number} s"


def scenario_summary_provenance(group, cell):
    executions = sorted(
        cell["executions"].values(),
        key=lambda item: (
            cell["scenarios"].index(item["scenario"]),
            cell["stacks"].index(item["stack"]),
            item["repeat"],
        ),
    )
    return {
        "mode": "pooled-scenario-summary",
        "tls_version": group["tls_version"],
        "tls_group": group["tls_group"],
        "family": cell["family"],
        "profile": cell["profile"],
        "source_start": group["source_start"],
        "source_stop": group["source_stop"],
        "run_ids": group["run_ids"],
        "compatibility": cell["compatibility"],
        "pooling": {
            "profile_runs": [1, 2, 3],
            "http_percentiles": "quantiles over pooled raw http_req_duration samples",
            "tls_percentiles": (
                "quantiles over pooled positive "
                "http_req_tls_handshaking samples"
            ),
            "race_completion": "three execution elapsed_ms values shown separately",
        },
        "executions": executions,
    }


def render_race_completion_bars(group, cell, rows, axis_values):
    if cell["family"] != "race":
        raise ValueError("Race completion charts require a race profile")
    width = 1900
    left, right, top, bottom = 320, 350, 125, 55
    group_height = 48
    bar_height, bar_gap = 9, 4
    plot_width = width - left - right
    height = top + bottom + len(rows) * group_height
    cell_values = [
        value
        for row in rows
        for value in row["completion_runs_s"]
    ]
    if any(value not in axis_values for value in cell_values):
        raise ValueError("Race completion axis does not cover every cell value")
    axis = value_axis(axis_values, "linear")
    x = lambda value: left + axis["position"](value) * plot_width
    title = f"Race completion - {cell['profile']}"
    subtitle = (
        f"TLS {group['tls_version']} - {group['tls_group']} - "
        "three Profile Runs shown separately"
    )
    provenance = scenario_summary_provenance(group, cell)
    provenance["visualization"] = (
        "three horizontal completion bars per scenario and stack"
    )
    provenance["completion_axis"] = (
        "shared linear scale across all race VU profiles in this TLS cell"
    )
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}" role="img" '
        'aria-labelledby="title desc">',
        f"<metadata>{html.escape(json.dumps(provenance, sort_keys=True))}</metadata>",
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(title)}</title>',
        f'<desc id="desc">{html.escape(subtitle)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" '
        'rx="12" fill="#ffffff"/>',
        svg_text(30, 35, title, 24, weight=700),
        svg_text(
            30,
            63,
            subtitle,
            13,
            fill="#64748b",
            css_class="theme-muted",
        ),
    ]
    value_columns = (
        (0, "Run 1", width - 245),
        (1, "Run 2", width - 145),
        (2, "Run 3", width - 45),
    )
    for _, label, column_x in value_columns:
        parts.append(
            svg_text(
                column_x,
                top - 17,
                label,
                11,
                anchor="end",
                weight=700,
            )
        )
    plot_bottom = top + len(rows) * group_height
    parts.append(
        f'<rect class="theme-plot theme-border" x="{left}" y="{top}" '
        f'width="{plot_width}" height="{len(rows) * group_height}" '
        'fill="#f8fafc" stroke="#cbd5e1"/>'
    )
    for tick in axis["ticks"]:
        xx = x(tick)
        parts.append(
            f'<line class="theme-grid" x1="{xx:.2f}" y1="{top}" '
            f'x2="{xx:.2f}" y2="{plot_bottom}" stroke="#e2e8f0"/>'
        )
        parts.append(
            svg_text(
                xx,
                top - 17,
                format_completion(tick),
                10,
                anchor="middle",
                fill="#64748b",
                css_class="theme-muted",
            )
        )
    for row_index, row in enumerate(rows):
        group_top = top + row_index * group_height + 4
        parts.append(
            svg_text(
                left - 12,
                group_top + 22,
                f"{row['scenario']} - {STACK_LABELS[row['stack']]}",
                11,
                anchor="end",
                weight=600,
            )
        )
        for repeat, value in enumerate(row["completion_runs_s"]):
            y = group_top + repeat * (bar_height + bar_gap)
            parts.append(
                f'<rect x="{left}" y="{y}" '
                f'width="{axis["position"](value) * plot_width:.2f}" '
                f'height="{bar_height}" rx="3" '
                f'fill="{STACK_COLORS[row["stack"]][repeat]}">'
                f'<title>Profile Run {repeat + 1}: '
                f'{html.escape(format_completion(value))}</title></rect>'
            )
        for repeat, _, column_x in value_columns:
            parts.append(
                svg_text(
                    column_x,
                    group_top + 22,
                    format_completion(row["completion_runs_s"][repeat]),
                    10,
                    anchor="end",
                    fill="#64748b",
                    css_class="theme-muted",
                )
            )
    parts.append(
        svg_text(
            left + plot_width / 2,
            plot_bottom + 28,
            "Seconds",
            11,
            anchor="middle",
            fill="#64748b",
            css_class="theme-muted",
        )
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def render_scenario_percentile_ranges(group, cell, rows, scale_mode, metric):
    if metric not in SUMMARY_METRICS:
        raise ValueError(f"Unsupported summary metric: {metric}")
    metric_label = SUMMARY_METRICS[metric][1]
    width = 2200
    left, right, top, bottom = 320, 500, 125, 55
    row_height, panel_header = 36, 46
    plot_width = width - left - right
    panel_height = panel_header + len(rows) * row_height
    height = top + bottom + panel_height
    family_label = FAMILY_LABELS[cell["family"]]
    title = f"Scenario {metric.upper()} percentiles - {family_label} - {cell['profile']}"
    subtitle = (
        f"TLS {group['tls_version']} - {group['tls_group']} - "
        f"Profile Runs 1-3 pooled - {scale_mode} scale - "
        "1,000 ms axis maximum"
    )
    provenance = scenario_summary_provenance(group, cell)
    provenance["percentile_metric"] = metric
    provenance["metric"] = metric_label
    provenance["visualization"] = (
        "P50 marker, P50-to-P90 band, P90-to-P99 tail"
    )
    provenance["scale"] = scale_mode
    provenance["axis_max_ms"] = SCENARIO_PERCENTILE_MAX_MS
    provenance["overflow"] = (
        "values above axis_max_ms are clipped at the plot boundary; "
        "exact values remain in the P50/P90/P99 columns"
    )
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
        f'height="{height}" viewBox="0 0 {width} {height}" role="img" '
        'aria-labelledby="title desc">',
        f"<metadata>{html.escape(json.dumps(provenance, sort_keys=True))}</metadata>",
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(title)}</title>',
        f'<desc id="desc">{html.escape(subtitle)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" '
        'rx="12" fill="#ffffff"/>',
        svg_text(30, 35, title, 24, weight=700),
        svg_text(
            30,
            63,
            subtitle,
            13,
            fill="#64748b",
            css_class="theme-muted",
        ),
    ]
    for prefix, label in ((metric, metric_label),):
        panel_top = top
        plot_top = panel_top + panel_header
        plot_bottom = plot_top + len(rows) * row_height
        values = [
            row[f"{prefix}_{statistic}"]
            for row in rows
            for statistic in ("p50", "p90", "p99")
        ]
        axis_values = [min(value, SCENARIO_PERCENTILE_MAX_MS) for value in values]
        if scale_mode == "logarithmic":
            axis_values.append(1.0)
        axis_values.append(SCENARIO_PERCENTILE_MAX_MS)
        axis = value_axis(axis_values, scale_mode)
        x = lambda value: left + axis["position"](
            min(value, SCENARIO_PERCENTILE_MAX_MS)
        ) * plot_width
        parts.append(svg_text(30, panel_top + 27, label, 16, weight=700))
        value_columns = (
            ("p50", "P50", width - 385),
            ("p90", "P90", width - 235),
            ("p99", "P99", width - 85),
        )
        for _, statistic, column_x in value_columns:
            parts.append(
                svg_text(
                    column_x,
                    panel_top + 27,
                    statistic,
                    11,
                    anchor="end",
                    weight=700,
                )
            )
        parts.append(
            f'<rect class="theme-plot theme-border" x="{left}" '
            f'y="{plot_top}" width="{plot_width}" '
            f'height="{len(rows) * row_height}" fill="#f8fafc" '
            'stroke="#cbd5e1"/>'
        )
        for tick in axis["ticks"]:
            xx = x(tick)
            parts.append(
                f'<line class="theme-grid" x1="{xx:.2f}" y1="{plot_top}" '
                f'x2="{xx:.2f}" y2="{plot_bottom}" stroke="#e2e8f0"/>'
            )
            parts.append(
                svg_text(
                    xx,
                    plot_top - 10,
                    format_axis_tick(tick, "ms", scale_mode),
                    10,
                    fill="#64748b",
                    anchor="middle",
                    css_class="theme-muted",
                )
            )
        for row_index, row in enumerate(rows):
            y = plot_top + row_index * row_height + row_height / 2
            p50 = row[f"{prefix}_p50"]
            p90 = row[f"{prefix}_p90"]
            p99 = row[f"{prefix}_p99"]
            color = STACK_COLORS[row["stack"]][1]
            parts.append(
                svg_text(
                    left - 12,
                    y + 4,
                    f"{row['scenario']} - {STACK_LABELS[row['stack']]}",
                    11,
                    anchor="end",
                    weight=600,
                )
            )
            parts.extend(percentile_range_marks(
                x, y, p50, p90, p99, color,
                f"{row['scenario']}/{row['stack']}/{prefix}",
            ))
            for statistic, _, column_x in value_columns:
                parts.append(
                    svg_text(
                        column_x,
                        y + 4,
                        format_bar_value(row[f"{prefix}_{statistic}"], "ms"),
                        10,
                        anchor="end",
                        fill="#64748b",
                        css_class="theme-muted",
                    )
                )
        parts.append(
            svg_text(
                left + plot_width / 2,
                plot_bottom + 28,
                f"Milliseconds ({scale_mode})",
                11,
                anchor="middle",
                fill="#64748b",
                css_class="theme-muted",
            )
        )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"

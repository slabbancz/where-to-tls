import html
import math

from .config import ADAPTIVE_STYLE, STACK_COLORS, STACK_LABELS
from .svg import (format_axis_tick, nice_step, subtitle, svg_provenance, svg_text,
                  unit_label, value_axis)


def render_time_series(config, comparison, stacks, segments, scale_mode):
    width, height = 1800, 620
    left, right, top, bottom = 105, 35, 92, 112
    plot_width = width - left - right
    plot_height = height - top - bottom
    max_x = max(point[0] for points in segments.values() for point in points)
    chart_scale = (
        scale_mode if config.get("log_scale", False) else "linear"
    )
    axis = value_axis(
        (point[1] for points in segments.values() for point in points),
        chart_scale,
    )
    x_step = nice_step(max(max_x, 1) / 8)
    x_max = max(x_step, math.ceil(max_x / x_step) * x_step)
    x = lambda value: left + value / x_max * plot_width
    y = lambda value: top + plot_height * (1 - axis["position"](value))
    detail = subtitle(
        comparison,
        separate_profile_runs=config.get("profile_row") is not None,
    ) + f" · {chart_scale} Y scale"
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        svg_provenance(comparison, config["family"]),
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(config["title"])}</title>',
        f'<desc id="desc">{html.escape(detail)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        svg_text(left, 34, config["title"], 24, weight=700),
        svg_text(left, 61, detail, 13, fill="#64748b",
                 css_class="theme-muted"),
        f'<rect class="theme-plot theme-border" x="{left}" y="{top}" width="{plot_width}" height="{plot_height}" fill="#f8fafc" stroke="#cbd5e1"/>',
    ]
    for value in axis["ticks"]:
        yy = y(value)
        parts.append(
            f'<line class="theme-grid" x1="{left}" y1="{yy:.2f}" '
            f'x2="{width - right}" y2="{yy:.2f}" stroke="#e2e8f0"/>'
        )
        parts.append(
            svg_text(left - 12, yy + 4,
                     format_axis_tick(value, config["unit"], chart_scale),
                     11, fill="#64748b", anchor="end", css_class="theme-muted")
        )
    tick = 0.0
    while tick <= x_max + x_step / 10:
        xx = x(tick)
        parts.append(
            f'<line class="theme-grid" x1="{xx:.2f}" y1="{top}" '
            f'x2="{xx:.2f}" y2="{top + plot_height}" stroke="#e2e8f0"/>'
        )
        parts.append(
            svg_text(xx, top + plot_height + 24, f"{tick:.0f}s", 11,
                     fill="#64748b", anchor="middle", css_class="theme-muted")
        )
        tick += x_step
    for stack in stacks:
        for (segment_stack, repeat, _), points in sorted(
            segments.items(),
            key=lambda item: (item[0][0], item[0][1] if item[0][1] is not None else -1, item[0][2]),
        ):
            if segment_stack != stack:
                continue
            color = STACK_COLORS[stack][1 if repeat is None else repeat]
            commands = " ".join(
                f'{"M" if index == 0 else "L"} {x(px):.2f} {y(py):.2f}'
                for index, (px, py) in enumerate(points)
            )
            if config["filled"]:
                area = (
                    commands
                    + f" L {x(points[-1][0]):.2f} {y(0):.2f}"
                    + f" L {x(points[0][0]):.2f} {y(0):.2f} Z"
                )
                parts.append(
                    f'<path d="{area}" fill="{color}" opacity="0.10"/>'
                )
            parts.append(
                f'<path d="{commands}" fill="none" stroke="{color}" '
                'stroke-width="2.5" stroke-linejoin="round" '
                'stroke-linecap="round"/>'
            )
    legend_x = left
    legend_y = height - 42
    for index, stack in enumerate(stacks):
        xx = legend_x + index * 210
        color = STACK_COLORS[stack][1]
        parts.append(
            f'<line x1="{xx}" y1="{legend_y - 5}" x2="{xx + 28}" '
            f'y2="{legend_y - 5}" stroke="{color}" stroke-width="4"/>'
        )
        parts.append(svg_text(xx + 38, legend_y, STACK_LABELS[stack], 13))
    if config.get("profile_row") is not None:
        parts.append(
            svg_text(
                left + len(stacks) * 210,
                legend_y,
                "Profile Run 1 light · Run 2 normal · Run 3 dark",
                13,
                fill="#64748b",
                css_class="theme-muted",
            )
        )
    parts.append(
        svg_text(
            25,
            top + plot_height / 2,
            f'{unit_label(config["unit"])} ({chart_scale})',
            12,
            fill="#64748b",
            anchor="middle",
            css_class="theme-muted",
        ).replace(
            f'x="25.00" y="{top + plot_height / 2:.2f}"',
            f'transform="translate(25 {top + plot_height / 2:.2f}) rotate(-90)" x="0.00" y="0.00"',
        )
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def render_race_rps_small_multiples(config, comparison, stacks, segments):
    repeats = range(3)
    for stack in stacks:
        for repeat in repeats:
            if not any(
                segment_stack == stack and segment_repeat == repeat
                for segment_stack, segment_repeat, _ in segments
            ):
                raise ValueError(
                    f"Missing race RPS series for {stack}/Profile Run {repeat + 1}"
                )
    width = 1800
    left, right, top, bottom = 105, 35, 105, 75
    panel_height, panel_gap = 285, 55
    height = top + bottom + 3 * panel_height + 2 * panel_gap
    plot_width = width - left - right
    all_points = [
        point for points in segments.values() for point in points
    ]
    max_x = max(point[0] for point in all_points)
    axis = value_axis((point[1] for point in all_points), "linear")
    x_step = nice_step(max(max_x, 1) / 8)
    x_max = max(x_step, math.ceil(max_x / x_step) * x_step)
    x = lambda value: left + value / x_max * plot_width
    detail = (
        subtitle(comparison, separate_profile_runs=True)
        + " · separate Profile Run panels · linear Y scale"
    )
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        svg_provenance(comparison, "race"),
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(config["title"])}</title>',
        f'<desc id="desc">{html.escape(detail)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        svg_text(left, 34, config["title"], 24, weight=700),
        svg_text(left, 61, detail, 13, fill="#64748b",
                 css_class="theme-muted"),
    ]
    for repeat in repeats:
        panel_top = top + repeat * (panel_height + panel_gap)
        panel_bottom = panel_top + panel_height
        y = lambda value: panel_top + panel_height * (
            1 - axis["position"](value)
        )
        parts.append(
            svg_text(left, panel_top - 12, f"Profile Run {repeat + 1}",
                     15, weight=700)
        )
        parts.append(
            f'<rect class="theme-plot theme-border" x="{left}" y="{panel_top}" '
            f'width="{plot_width}" height="{panel_height}" fill="#f8fafc" '
            'stroke="#cbd5e1"/>'
        )
        for value in axis["ticks"]:
            yy = y(value)
            parts.append(
                f'<line class="theme-grid" x1="{left}" y1="{yy:.2f}" '
                f'x2="{width - right}" y2="{yy:.2f}" stroke="#e2e8f0"/>'
            )
            parts.append(
                svg_text(
                    left - 12,
                    yy + 4,
                    format_axis_tick(value, "rate", "linear"),
                    10,
                    fill="#64748b",
                    anchor="end",
                    css_class="theme-muted",
                )
            )
        tick = 0.0
        while tick <= x_max + x_step / 10:
            xx = x(tick)
            parts.append(
                f'<line class="theme-grid" x1="{xx:.2f}" y1="{panel_top}" '
                f'x2="{xx:.2f}" y2="{panel_bottom}" stroke="#e2e8f0"/>'
            )
            parts.append(
                svg_text(xx, panel_bottom + 20, f"{tick:.0f}s", 10,
                         fill="#64748b", anchor="middle",
                         css_class="theme-muted")
            )
            tick += x_step
        for stack in stacks:
            color = STACK_COLORS[stack][1]
            for (segment_stack, segment_repeat, _), points in sorted(
                segments.items()
            ):
                if segment_stack != stack or segment_repeat != repeat:
                    continue
                commands = " ".join(
                    f'{"M" if index == 0 else "L"} {x(px):.2f} {y(py):.2f}'
                    for index, (px, py) in enumerate(points)
                )
                area = (
                    commands
                    + f" L {x(points[-1][0]):.2f} {y(0):.2f}"
                    + f" L {x(points[0][0]):.2f} {y(0):.2f} Z"
                )
                parts.append(
                    f'<path d="{area}" fill="{color}" opacity="0.08"/>'
                )
                parts.append(
                    f'<path d="{commands}" fill="none" stroke="{color}" '
                    'stroke-width="2.5" stroke-linejoin="round" '
                    'stroke-linecap="round"/>'
                )
    legend_y = height - 27
    for index, stack in enumerate(stacks):
        xx = left + index * 210
        color = STACK_COLORS[stack][1]
        parts.append(
            f'<line x1="{xx}" y1="{legend_y - 5}" x2="{xx + 28}" '
            f'y2="{legend_y - 5}" stroke="{color}" stroke-width="4"/>'
        )
        parts.append(svg_text(xx + 38, legend_y, STACK_LABELS[stack], 13))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"

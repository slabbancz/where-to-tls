import html

from .config import ADAPTIVE_STYLE, PROFILE_ROWS, STACK_COLORS, STACK_LABELS, STATISTICS
from .svg import (format_axis_tick, format_bar_value, format_failure_rate,
                  subtitle, svg_provenance, svg_text, unit_label, value_axis)


def render_bars(
    family,
    profile,
    title,
    unit,
    comparison,
    stacks,
    values,
    scale_mode,
):
    description = (
        subtitle(comparison, timeline=False)
        + f" · {scale_mode} value scale"
    )
    if unit == "rate":
        description = description.replace(
            "underlying samples", "populated 1-second request-rate windows"
        )
    width = 1800
    top, bottom, label_width, right = 155, 55, 350, 40
    bar_height, bar_gap = 15, 5
    section_header, section_gap = 36, 24
    statistic_header, statistic_gap = 25, 12
    sections = (profile,)
    statistic_height = (
        statistic_header
        + len(stacks) * 3 * (bar_height + bar_gap)
    )
    section_height = (
        section_header
        + len(STATISTICS) * statistic_height
        + (len(STATISTICS) - 1) * statistic_gap
    )
    height = (
        top + bottom + len(sections) * section_height
        + max(0, len(sections) - 1) * section_gap
    )
    plot_left = label_width
    plot_width = width - plot_left - right
    axis = value_axis(
        values.values(), scale_mode, pad_lower_decade=scale_mode == "logarithmic",
    )
    value_x = lambda value: plot_left + axis["position"](value) * plot_width
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        svg_provenance(comparison, family),
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(title)}</title>',
        f'<desc id="desc">{html.escape(description)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        svg_text(40, 34, title, 24, weight=700),
        svg_text(40, 61, description, 13, fill="#64748b",
                 css_class="theme-muted"),
    ]
    legend_y = 95
    for index, stack in enumerate(stacks):
        xx = 40 + index * 180
        color = STACK_COLORS[stack][1]
        parts.append(
            f'<rect x="{xx}" y="{legend_y - 13}" width="18" height="18" '
            f'rx="3" fill="{color}"/>'
        )
        parts.append(svg_text(xx + 27, legend_y + 1, STACK_LABELS[stack], 12))
    shade_x = 40 + max(760, len(stacks) * 180)
    parts.append(
        svg_text(
            shade_x,
            legend_y + 1,
            "Within each stack: Profile Run 1 light · Run 2 normal · Run 3 dark",
            12,
            fill="#64748b",
            css_class="theme-muted",
        )
    )
    tick_positions = [
        (tick, value_x(tick)) for tick in axis["ticks"]
    ]
    for tick, xx in tick_positions:
        parts.append(
            svg_text(xx, top - 20, format_axis_tick(tick, unit, scale_mode), 10,
                     fill="#64748b", anchor="middle", css_class="theme-muted")
        )
    y_cursor = top
    for section in sections:
        section_bottom = y_cursor + section_height
        parts.append(
            f'<rect class="theme-plot theme-border" x="30" y="{y_cursor}" '
            f'width="{width - 60}" height="{section_height}" fill="#f8fafc" '
            'stroke="#cbd5e1"/>'
        )
        for _, xx in tick_positions:
            parts.append(
                f'<line class="theme-grid" x1="{xx:.2f}" y1="{y_cursor}" '
                f'x2="{xx:.2f}" y2="{section_bottom}" stroke="#e2e8f0"/>'
            )
        parts.append(
            svg_text(45, y_cursor + 23, section, 15, weight=700)
        )
        y_cursor += section_header
        for statistic_index, (statistic, _) in enumerate(STATISTICS):
            statistic_bottom = y_cursor + statistic_height
            parts.append(
                f'<line class="theme-border" x1="40" y1="{y_cursor}" '
                f'x2="{width - 40}" y2="{y_cursor}" stroke="#cbd5e1"/>'
            )
            parts.append(
                svg_text(45, y_cursor + 18, statistic, 12, weight=700)
            )
            y_cursor += statistic_header
            for stack in stacks:
                for repeat in range(3):
                    value = values[(section, statistic, stack, repeat)]
                    bar_width = axis["position"](value) * plot_width
                    display_width = 52.0 if value == 0 else bar_width
                    yy = y_cursor
                    color = STACK_COLORS[stack][repeat]
                    label = (
                        f"{STACK_LABELS[stack]} · Profile Run {repeat + 1}"
                    )
                    exact = (
                        f"{section}, {statistic}, {STACK_LABELS[stack]}, "
                        f"Profile Run {repeat + 1}: {value:.6g} "
                        f"{unit_label(unit)}"
                    )
                    parts.append(
                        svg_text(plot_left - 12, yy + bar_height - 3, label, 10,
                                 fill="#64748b", anchor="end",
                                 css_class="theme-muted")
                    )
                    parts.append(
                        f'<rect x="{plot_left:.2f}" y="{yy:.2f}" '
                        f'width="{display_width:.2f}" height="{bar_height}" '
                        f'rx="3" fill="{color}"><title>'
                        f'{html.escape(exact)}</title></rect>'
                    )
                    value_label = format_bar_value(value, unit)
                    parts.append(
                        svg_text(
                            plot_left + display_width / 2,
                            yy + bar_height - 3,
                            value_label,
                            9,
                            fill="#111827" if repeat == 0 else "#ffffff",
                            anchor="middle",
                            weight=700,
                            css_class="",
                        )
                    )
                    y_cursor += bar_height + bar_gap
            y_cursor = statistic_bottom
            if statistic_index < len(STATISTICS) - 1:
                y_cursor += statistic_gap
        y_cursor = section_bottom + section_gap
    parts.append(svg_text(
        plot_left + plot_width / 2, height - 18,
        f"{unit_label(unit)} ({scale_mode})", 12,
        fill="#64748b", anchor="middle", css_class="theme-muted",
    ))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def render_failure_bars(
    family,
    profile,
    title,
    comparison,
    stacks,
    values,
):
    width = 1800
    top, bottom, plot_left, right = 150, 55, 350, 40
    bar_height, bar_gap, panel_header = 18, 6, 38
    row_count = len(stacks) * 3
    panel_height = panel_header + row_count * (bar_height + bar_gap)
    height = top + panel_height + bottom
    plot_width = width - plot_left - right
    rates = [
        values[(profile, stack, repeat)]["rate"]
        for stack in stacks
        for repeat in range(3)
    ]
    axis = value_axis(rates, "linear")
    value_x = lambda value: plot_left + axis["position"](value) * plot_width
    description = (
        subtitle(comparison, timeline=False)
        + " · failed requests / completed HTTP requests"
    )
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        svg_provenance(comparison, family),
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(title)}</title>',
        f'<desc id="desc">{html.escape(description)}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        svg_text(40, 34, title, 24, weight=700),
        svg_text(40, 61, description, 13, fill="#64748b",
                 css_class="theme-muted"),
    ]
    legend_y = 95
    for index, stack in enumerate(stacks):
        xx = 40 + index * 180
        parts.append(
            f'<rect x="{xx}" y="{legend_y - 13}" width="18" height="18" '
            f'rx="3" fill="{STACK_COLORS[stack][1]}"/>'
        )
        parts.append(svg_text(xx + 27, legend_y + 1, STACK_LABELS[stack], 12))
    parts.append(
        svg_text(
            40 + max(760, len(stacks) * 180),
            legend_y + 1,
            "Profile Run 1 light · Run 2 normal · Run 3 dark",
            12,
            fill="#64748b",
            css_class="theme-muted",
        )
    )
    panel_bottom = top + panel_height
    parts.append(
        f'<rect class="theme-plot theme-border" x="30" y="{top}" '
        f'width="{width - 60}" height="{panel_height}" fill="#f8fafc" '
        'stroke="#cbd5e1"/>'
    )
    for tick in axis["ticks"]:
        xx = value_x(tick)
        parts.append(
            f'<line class="theme-grid" x1="{xx:.2f}" y1="{top}" '
            f'x2="{xx:.2f}" y2="{panel_bottom}" stroke="#e2e8f0"/>'
        )
        parts.append(
            svg_text(xx, top - 16, format_failure_rate(tick), 10,
                     fill="#64748b", anchor="middle",
                     css_class="theme-muted")
        )
    parts.append(svg_text(45, top + 24, profile, 15, weight=700))
    y_cursor = top + panel_header
    for stack in stacks:
        for repeat in range(3):
            item = values[(profile, stack, repeat)]
            rate = item["rate"]
            bar_width = axis["position"](rate) * plot_width
            yy = y_cursor
            label = (
                f"{format_failure_rate(rate)} "
                f"({item['failed']:,}/{item['requests']:,})"
            )
            left_label = f"{STACK_LABELS[stack]} · Profile Run {repeat + 1}"
            parts.append(
                svg_text(plot_left - 12, yy + bar_height - 4, left_label, 11,
                         fill="#64748b", anchor="end",
                         css_class="theme-muted")
            )
            if rate == 0:
                parts.append(
                    f'<line x1="{plot_left}" y1="{yy}" x2="{plot_left}" '
                    f'y2="{yy + bar_height}" stroke="{STACK_COLORS[stack][repeat]}" '
                    'stroke-width="4"/>'
                )
            else:
                parts.append(
                    f'<rect x="{plot_left}" y="{yy}" width="{bar_width:.2f}" '
                    f'height="{bar_height}" rx="3" '
                    f'fill="{STACK_COLORS[stack][repeat]}"/>'
                )
            estimated_label_width = len(label) * 6.5
            if bar_width >= estimated_label_width + 18:
                label_x = plot_left + bar_width / 2
                anchor = "middle"
                fill = "#111827" if repeat == 0 else "#ffffff"
                css_class = ""
            else:
                label_x = plot_left + bar_width + 9
                anchor = "start"
                fill = "#111827"
                css_class = "theme-text"
            parts.append(
                svg_text(label_x, yy + bar_height - 4, label, 10,
                         fill=fill, anchor=anchor, weight=700,
                         css_class=css_class)
            )
            y_cursor += bar_height + bar_gap
    parts.append(
        svg_text(
            plot_left + plot_width / 2,
            height - 18,
            "Failed HTTP requests (%)",
            12,
            fill="#64748b",
            anchor="middle",
            css_class="theme-muted",
        )
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"

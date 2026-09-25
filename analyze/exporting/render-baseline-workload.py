#!/usr/bin/env python3

import csv
from datetime import datetime, timedelta
import html
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEV = Path(__file__).resolve().parents[3]

if (SCRIPT_DIR / "data/workload").is_dir():
    SOURCE = SCRIPT_DIR / "data/workload"
elif (DEV / "lightroastedblog/content/posts/brewing-secure-connections/data/workload").is_dir():
    SOURCE = DEV / "lightroastedblog/content/posts/brewing-secure-connections/data/workload"
else:
    SOURCE = SCRIPT_DIR / "data/workload"

if (DEV / "lightroastedblog/content/posts/brewing-secure-connections/charts/workload").is_dir():
    OUTPUT = DEV / "lightroastedblog/content/posts/brewing-secure-connections/charts/workload"
else:
    OUTPUT = SCRIPT_DIR / "charts/workload"

CHARTS = {
    "baseline": {
        "title": "Achieved request rate [1s]",
        "description": "Nine sequential baseline executions showing linear, flat, and sine request-rate profiles.",
        "maximum": 3200,
        "tick": 500,
        "unit": "rate",
    },
    "baseline-vu": {
        "title": "Active VUs",
        "description": "Active virtual users for nine sequential linear, flat, and sine baseline executions.",
        "maximum": 80,
        "tick": 10,
        "unit": "vus",
    },
    "linear": {
        "title": "Achieved request rate [1s]",
        "description": "Six sequential high-pressure linear-ramp executions using fixed and expandable VU profiles.",
        "maximum": 6000,
        "tick": 1000,
        "unit": "rate",
    },
    "linear-vu": {
        "title": "Active VUs",
        "description": "Active virtual users for six sequential high-pressure linear-ramp executions.",
        "maximum": 1100,
        "tick": 200,
        "unit": "vus",
    },
    "race": {
        "title": "Achieved request rate [1s]",
        "description": "Nine sequential fixed-work race executions using pools of 10, 100, and 1,000 VUs.",
        "maximum": 6000,
        "tick": 1000,
        "unit": "rate",
    },
    "race-vu": {
        "title": "Allocated VUs",
        "description": "Allocated virtual users for nine sequential fixed-work race executions.",
        "maximum": 1200,
        "tick": 200,
        "unit": "vus",
    },
}

PROFILE_COLORS = {
    "linear": ("#fb923c", "#f97316", "#c2410c"),
    "flat": ("#4ade80", "#16a34a", "#15803d"),
    "sine": ("#60a5fa", "#2563eb", "#1d4ed8"),
    "expandable": ("#60a5fa", "#2563eb", "#1d4ed8"),
    "race-10": ("#4ade80", "#16a34a", "#15803d"),
    "race-100": ("#fb923c", "#f97316", "#c2410c"),
    "race-1000": ("#60a5fa", "#2563eb", "#1d4ed8"),
}


def value_number(value):
    value = value.strip()
    if value == "No samples":
        return None
    parts = value.replace(",", "").split()
    number = parts[0]
    multiplier = 1
    if number.endswith("K"):
        number = number[:-1]
        multiplier = 1000
    elif number.endswith("M"):
        number = number[:-1]
        multiplier = 1_000_000
    elif len(parts) > 1 and parts[1] == "K":
        multiplier = 1000
    elif len(parts) > 1 and parts[1] == "M":
        multiplier = 1_000_000
    return float(number) * multiplier


def load(source):
    with source.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    result = []
    for column in rows[0]:
        if column == "Time":
            continue
        name = column.rsplit(" | ", 1)[-1]
        points = []
        for row in rows:
            value = value_number(row[column])
            if value is not None:
                points.append(
                    (datetime.strptime(row["Time"], "%Y-%m-%d %H:%M:%S"), value)
                )
        result.append({"label": column, "name": name, "points": points})
    return result


def svg_text(
    x, y, value, size, fill, anchor="start", weight=400, css_class=None
):
    class_attribute = f' class="{css_class}"' if css_class else ""
    return (
        f'<text{class_attribute} x="{x:.2f}" y="{y:.2f}" fill="{fill}" '
        f'font-family="Inter,system-ui,sans-serif" font-size="{size}" '
        f'font-weight="{weight}" text-anchor="{anchor}">{html.escape(value)}</text>'
    )


ADAPTIVE_STYLE = """<style>
  .theme-bg { fill: #ffffff; }
  .theme-plot { fill: #f8fafc; }
  .theme-text { fill: #111827; }
  .theme-muted { fill: #64748b; }
  .theme-grid { stroke: #e2e8f0; }
  @media (prefers-color-scheme: dark) {
    .theme-bg { fill: #1f2227; }
    .theme-plot { fill: #202328; }
    .theme-text { fill: #d8d9da; }
    .theme-muted { fill: #a8abb2; }
    .theme-grid { stroke: #34383f; }
  }
</style>"""


def path(points, x, y):
    return " ".join(
        f'{"M" if index == 0 else "L"} {x(time):.2f} {y(value):.2f}'
        for index, (time, value) in enumerate(points)
    )


def profile_color(chart, name):
    profile, execution_text = name.rsplit("-", 1)
    execution = int(execution_text)
    if chart.startswith("baseline"):
        color = profile
        repeat = (execution - 1) // 3
    elif chart.startswith("linear"):
        color = "linear" if execution % 2 else "expandable"
        repeat = (execution - 1) // 2
    else:
        race_pool = (10, 100, 1000)[(execution - 1) % 3]
        color = f"race-{race_pool}"
        repeat = (execution - 1) // 3
    return PROFILE_COLORS[color][repeat]


def legend_order(chart, item):
    profile, execution_text = item["name"].rsplit("-", 1)
    execution = int(execution_text)
    if chart.startswith("baseline"):
        return (
            {"linear": 0, "flat": 1, "sine": 2}[profile],
            (execution - 1) // 3,
        )
    if chart.startswith("linear"):
        return (0 if execution % 2 else 1, (execution - 1) // 2)
    return ((execution - 1) % 3, (execution - 1) // 3)


def value_label(value, unit):
    if unit == "vus":
        return f"{int(value):,} VUs"
    if value == 0:
        return "0 req/s"
    if value >= 1000:
        return f"{value / 1000:.2f}K req/s"
    return f"{int(value)} req/s"


def render(chart, series, target, config):
    width, height = 1800, 500
    left, right, top, bottom = 92, 28, 76, 146
    plot_width = width - left - right
    plot_height = height - top - bottom
    first = min(item["points"][0][0] for item in series)
    last = max(item["points"][-1][0] for item in series)
    span = (last - first).total_seconds()
    x = lambda timestamp: left + (
        (timestamp - first).total_seconds() / span
    ) * plot_width
    y = lambda value: top + plot_height * (1 - value / config["maximum"])
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        ADAPTIVE_STYLE,
        f'<title id="title">{html.escape(config["title"])}</title>',
        f'<desc id="desc">{html.escape(config["description"])}</desc>',
        f'<rect class="theme-bg" width="{width}" height="{height}" rx="12" fill="#ffffff"/>',
        f'<rect class="theme-plot" x="{left}" y="{top}" width="{plot_width}" height="{plot_height}" fill="#f8fafc"/>',
        svg_text(
            18,
            30,
            config["title"],
            16,
            "#111827",
            weight=600,
            css_class="theme-text",
        ),
    ]
    value = 0
    while value <= config["maximum"]:
        yy = y(value)
        parts.append(
            f'<line class="theme-grid" x1="{left}" y1="{yy:.2f}" '
            f'x2="{width - right}" y2="{yy:.2f}" stroke="#e2e8f0"/>'
        )
        parts.append(
            svg_text(
                left - 10,
                yy + 4,
                value_label(value, config["unit"]),
                11,
                "#64748b",
                anchor="end",
                css_class="theme-muted",
            )
        )
        value += config["tick"]
    for tick in range(0, int(span) + 1, 30):
        xx = left + tick / span * plot_width
        parts.append(
            f'<line class="theme-grid" x1="{xx:.2f}" y1="{top}" '
            f'x2="{xx:.2f}" y2="{top + plot_height}" stroke="#e2e8f0"/>'
        )
        label = (first + timedelta(seconds=tick)).strftime("%H:%M:%S")
        parts.append(
            svg_text(
                xx,
                top + plot_height + 20,
                label,
                10,
                "#64748b",
                anchor="middle",
                css_class="theme-muted",
            )
        )
    for item in series:
        points = item["points"]
        color = profile_color(chart, item["name"])
        area = (
            path(points, x, y)
            + f" L {x(points[-1][0]):.2f} {y(0):.2f}"
            + f" L {x(points[0][0]):.2f} {y(0):.2f} Z"
        )
        parts.append(f'<path d="{area}" fill="{color}" opacity="0.08"/>')
        parts.append(
            f'<path d="{path(points, x, y)}" fill="none" stroke="{color}" '
            'stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"/>'
        )
    legend_y = top + plot_height + 52
    for index, item in enumerate(sorted(series, key=lambda item: legend_order(chart, item))):
        color = profile_color(chart, item["name"])
        row, column = divmod(index, 3)
        xx = left + column * 547
        yy = legend_y + row * 24
        parts.append(
            f'<line x1="{xx}" y1="{yy - 4}" x2="{xx + 22}" y2="{yy - 4}" '
            f'stroke="{color}" stroke-width="3"/>'
        )
        parts.append(
            svg_text(
                xx + 30,
                yy,
                item["label"],
                8,
                "#64748b",
                css_class="theme-muted",
            )
        )
    parts.append("</svg>")
    target.write_text("\n".join(parts) + "\n")


for chart, config in CHARTS.items():
    data = load(SOURCE / f"{chart}.csv")
    render(
        chart,
        data,
        OUTPUT / f"{chart}-workload-timeline-filled.svg",
        config,
    )

import html
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

from .config import ADAPTIVE_STYLE
from .runs import family_runs


def svg_text(x, y, value, size, fill="#111827", anchor="start",
             weight=400, css_class="theme-text"):
    return (
        f'<text class="{css_class}" x="{x:.2f}" y="{y:.2f}" '
        f'fill="{fill}" font-family="Inter,system-ui,sans-serif" '
        f'font-size="{size}" font-weight="{weight}" text-anchor="{anchor}">'
        f'{html.escape(str(value))}</text>'
    )


def format_value(value, unit):
    if unit == "rate":
        if value >= 1000:
            return f"{value / 1000:.1f}k"
        return f"{value:.0f}"
    if unit == "vus":
        return f"{value:,.0f}"
    if value >= 100:
        return f"{value:.0f}"
    if value >= 10:
        return f"{value:.1f}"
    return f"{value:.2f}"


def unit_label(unit):
    return {"rate": "Requests/s", "vus": "Virtual users", "ms": "Milliseconds"}[unit]


def nice_step(value):
    if value <= 0:
        return 1.0
    exponent = math.floor(math.log10(value))
    fraction = value / (10 ** exponent)
    if fraction <= 1:
        nice = 1
    elif fraction <= 2:
        nice = 2
    elif fraction <= 5:
        nice = 5
    else:
        nice = 10
    return nice * (10 ** exponent)


def scale(maximum, tick_count=6):
    if maximum <= 0:
        return 1.0, 0.2
    step = nice_step(maximum / tick_count)
    upper = math.ceil(maximum / step) * step
    return upper, step


def value_axis(values, mode, tick_count=6, pad_lower_decade=False):
    values = list(values)
    if not values:
        raise ValueError("Cannot scale an empty value set")
    if any(value < 0 for value in values):
        raise ValueError(f"{mode} axes do not support negative values")
    if mode == "linear":
        upper, step = scale(max(values), tick_count)
        ticks = []
        value = 0.0
        while value <= upper + step / 10:
            ticks.append(value)
            value += step
        return {
            "mode": mode,
            "ticks": ticks,
            "position": lambda value: value / upper,
        }
    positives = [value for value in values if value > 0]
    if not positives:
        return {
            "mode": mode,
            "ticks": [0.0],
            "position": lambda value: 0.0,
        }
    lower_exponent = (
        math.floor(math.log10(min(positives)))
        - (1 if pad_lower_decade else 0)
    )
    upper_exponent = math.ceil(math.log10(max(positives)))
    if upper_exponent <= lower_exponent:
        upper_exponent = lower_exponent + 1
    exponents = list(range(lower_exponent, upper_exponent + 1))
    has_zero = any(value == 0 for value in values)
    zero_gap = 0.08 if has_zero else 0.0
    log_span = upper_exponent - lower_exponent

    def position(value):
        if value == 0:
            if not has_zero:
                raise ValueError("Unexpected zero on positive logarithmic axis")
            return 0.0
        return zero_gap + (1.0 - zero_gap) * (
            (math.log10(value) - lower_exponent) / log_span
        )

    return {
        "mode": mode,
        "ticks": ([0.0] if has_zero else [])
        + [10.0 ** exponent for exponent in exponents],
        "position": position,
    }


def format_axis_tick(value, unit, mode):
    if value == 0:
        return "0"
    if mode == "logarithmic":
        if value >= 1000:
            return f"{value / 1000:g}k"
        return f"{value:g}"
    return format_value(value, unit)


def format_bar_value(value, unit):
    if unit == "rate":
        if value >= 100:
            number = f"{value:,.0f}"
        elif value >= 1:
            number = f"{value:,.1f}".rstrip("0").rstrip(".")
        else:
            number = f"{value:.3f}".rstrip("0").rstrip(".")
        return f"{number} req/s"
    if value >= 100:
        number = f"{value:,.0f}"
    elif value >= 1:
        number = f"{value:,.2f}".rstrip("0").rstrip(".")
    else:
        number = f"{value:.6f}".rstrip("0").rstrip(".")
    return f"{number or '0'} ms"


def format_failure_rate(value):
    if value == 0:
        return "0%"
    if value >= 10:
        number = f"{value:.1f}"
    elif value >= 1:
        number = f"{value:.2f}"
    elif value >= 0.1:
        number = f"{value:.3f}"
    else:
        number = f"{value:.6f}"
    return number.rstrip("0").rstrip(".") + "%"


def percentile_range_marks(x, y, p50, p90, p99, color, context):
    if not p50 <= p90 <= p99:
        raise ValueError(
            f"Non-monotonic pooled percentiles for {context}: "
            f"{p50}, {p90}, {p99}"
        )
    parts = [
        f'<line x1="{x(p50):.2f}" y1="{y:.2f}" '
        f'x2="{x(p90):.2f}" y2="{y:.2f}" '
        f'stroke="{color}" stroke-width="10" stroke-linecap="round"/>',
        f'<line x1="{x(p90):.2f}" y1="{y:.2f}" '
        f'x2="{x(p99):.2f}" y2="{y:.2f}" '
        f'stroke="{color}" stroke-width="3" stroke-linecap="round"/>',
    ]
    for statistic, value, radius in (
        ("P50", p50, 6),
        ("P90", p90, 5),
        ("P99", p99, 5),
    ):
        parts.append(
            f'<circle cx="{x(value):.2f}" cy="{y:.2f}" r="{radius}" '
            f'fill="{color}"><title>{statistic}: '
            f'{html.escape(format_bar_value(value, "ms"))}'
            '</title></circle>'
        )
    return parts


def subtitle(comparison, timeline=True, separate_profile_runs=False):
    if timeline and separate_profile_runs:
        detail = "1-second windows · each Profile Run aligned to its own start"
    elif timeline:
        detail = "1-second windows · whole Run ID timeline"
    else:
        detail = "per Profile Run · underlying samples"
    return (
        f'{comparison["scenario"]} · TLS {comparison["tls_version"]} · '
        f'{comparison["tls_group"]} · '
        + detail
    )


def svg_provenance(comparison, family):
    return "<metadata>" + html.escape(json.dumps({
        "scenario": comparison["scenario"],
        "tls_version": comparison["tls_version"],
        "tls_group": comparison["tls_group"],
        "run_ids": family_runs(comparison, family),
        "source_start": comparison["source_start"],
        "source_stop": comparison["source_stop"],
    })) + "</metadata>"


def write_svg(path, content):
    ET.fromstring(content)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content)
    temporary.replace(path)

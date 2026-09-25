from pathlib import Path


REPO = Path(__file__).resolve().parents[3]

LIGHTROASTED_ARTICLE = REPO.parent / "lightroastedblog/content/posts/brewing-secure-connections"
if LIGHTROASTED_ARTICLE.is_dir():
    ARTICLE = LIGHTROASTED_ARTICLE
elif (REPO / "blog/content/posts/brewing-secure-connections").is_dir():
    ARTICLE = REPO / "blog/content/posts/brewing-secure-connections"
else:
    ARTICLE = LIGHTROASTED_ARTICLE

DEFAULT_OUTPUT = ARTICLE / "charts"

DEFAULT_TOKEN_FILE = REPO / "analyze/podman/.env"

STACK_ORDER = ("dotnet", "java", "go", "rust")

TLS_CONFIGURATIONS = (
    ("1.2", "P-256"),
    ("1.2", "X25519"),
    ("1.3", "P-256"),
    ("1.3", "X25519"),
)

SUMMARY_METRICS = {
    "http": ("http_req_duration", "HTTP response time", False),
    "tls": ("http_req_tls_handshaking", "TLS handshake time", True),
}

TLS_BYTE_METRICS = {
    "sent": ("data_sent_bytes", "Client bytes sent"),
    "received": ("data_received_bytes", "Client bytes received"),
}

STACK_LABELS = {
    "dotnet": ".NET",
    "java": "Java",
    "go": "golang",
    "rust": "Rust",
}

STACK_PREFIXES = {
    "dotnet": "net",
    "java": "java",
    "go": "go",
    "rust": "rust",
}

STACK_COLORS = {
    "dotnet": ("#8b7cf6", "#6d4aff", "#4c2cb3"),
    "java": ("#ffb36b", "#e76f00", "#a94800"),
    "go": ("#62d6ee", "#00add8", "#007d9c"),
    "rust": ("#fca5a5", "#ef4444", "#b91c1c"),
}

FAMILIES = ("baseline", "linear", "race")

STATISTICS = (("P01", 0.01), ("P50", 0.50), ("P90", 0.90), ("P99", 0.99))

EXECUTION_KEYS = [
    "wtt_run_id",
    "wtt_scenario",
    "wtt_stack",
    "wtt_profile",
    "wtt_execution_index",
]

PROFILE_ROWS = {
    "baseline": ("Linear", "Flat", "Sine"),
    "linear": ("Fixed 100 VUs", "Expandable to 1,000 VUs"),
    "race": ("10 VUs", "100 VUs", "1,000 VUs"),
}

RACE_PROFILE_SLUGS = {
    "10 VUs": "10-vus",
    "100 VUs": "100-vus",
    "1,000 VUs": "1000-vus",
}

PROFILE_SLUGS = {
    "Linear": "linear",
    "Flat": "flat",
    "Sine": "sine",
    "Fixed 100 VUs": "fixed-100-vus",
    "Expandable to 1,000 VUs": "expandable-1000-vus",
    **RACE_PROFILE_SLUGS,
}

FAMILY_LABELS = {
    "baseline": "Baseline",
    "linear": "High-pressure linear",
    "race": "Fixed-work race",
}

TIME_SERIES = (
    {
        "family": "baseline",
        "filename": "baseline-rps-timeline.svg",
        "panel": "Achieved request rate vs elapsed time [$resolution]",
        "title": "Baseline achieved request rate",
        "unit": "rate",
        "filled": True,
        "metric": "http_reqs",
        "aggregate": "sum",
    },
    {
        "family": "baseline",
        "filename": "baseline-tls-mean-timeline.svg",
        "panel": "TLS handshake time ${timing_stat} vs elapsed time [$resolution]",
        "title": "Baseline TLS handshake time - Mean (per 1-second window)",
        "unit": "ms",
        "filled": False,
        "metric": "http_req_tls_handshaking",
        "aggregate": "mean",
        "log_scale": True,
    },
    {
        "family": "baseline",
        "filename": "baseline-http-mean-timeline.svg",
        "title": "Baseline HTTP response time - Mean (per 1-second window)",
        "unit": "ms",
        "filled": False,
        "metric": "http_req_duration",
        "aggregate": "mean",
        "log_scale": True,
    },
    {
        "family": "linear",
        "filename": "linear-rps-timeline.svg",
        "panel": "Achieved request rate vs elapsed time [$resolution]",
        "title": "High-pressure linear achieved request rate",
        "unit": "rate",
        "filled": True,
        "metric": "http_reqs",
        "aggregate": "sum",
    },
    {
        "family": "linear",
        "filename": "linear-active-vus-timeline.svg",
        "panel": "Active VUs vs elapsed time [$resolution]",
        "title": "High-pressure linear active VUs",
        "unit": "vus",
        "filled": True,
        "metric": "vus",
        "aggregate": "max",
    },
    {
        "family": "linear",
        "filename": "linear-tcp-mean-timeline.svg",
        "panel": "TCP connecting ${timing_stat} [$resolution]",
        "title": "High-pressure linear TCP connection time - Mean (per 1-second window)",
        "unit": "ms",
        "filled": False,
        "metric": "http_req_connecting",
        "aggregate": "mean",
        "log_scale": True,
    },
    {
        "family": "linear",
        "filename": "linear-tls-mean-timeline.svg",
        "panel": "TLS handshake time ${timing_stat} vs elapsed time [$resolution]",
        "title": "High-pressure linear TLS handshake time - Mean (per 1-second window)",
        "unit": "ms",
        "filled": False,
        "metric": "http_req_tls_handshaking",
        "aggregate": "mean",
        "log_scale": True,
    },
    {
        "family": "linear",
        "filename": "linear-http-mean-timeline.svg",
        "title": "High-pressure linear HTTP response time - Mean (per 1-second window)",
        "unit": "ms",
        "filled": False,
        "metric": "http_req_duration",
        "aggregate": "mean",
        "log_scale": True,
    },
) + tuple(
    {
        "family": "race",
        "profile_row": profile,
        "filename": f"race-{metric['slug']}-{slug}-timeline.svg",
        "title": f"Fixed-work race {profile} - {metric['title']}",
        "unit": metric["unit"],
        "filled": metric["filled"],
        "metric": metric["metric"],
        "aggregate": metric["aggregate"],
        "tls_positive": metric.get("tls_positive", False),
        "log_scale": metric.get("log_scale", False),
    }
    for profile, slug in RACE_PROFILE_SLUGS.items()
    for metric in (
        {
            "slug": "rps",
            "title": "achieved request rate",
            "unit": "rate",
            "filled": True,
            "metric": "http_reqs",
            "aggregate": "sum",
        },
        {
            "slug": "tcp-mean",
            "title": "TCP connection time - Mean (per 1-second window)",
            "unit": "ms",
            "filled": False,
            "metric": "http_req_connecting",
            "aggregate": "mean",
            "log_scale": True,
        },
        {
            "slug": "tls-mean",
            "title": "TLS handshake time - Mean (per 1-second window)",
            "unit": "ms",
            "filled": False,
            "metric": "http_req_tls_handshaking",
            "aggregate": "mean",
            "log_scale": True,
        },
        {
            "slug": "http-mean",
            "title": "HTTP response time - Mean (per 1-second window)",
            "unit": "ms",
            "filled": False,
            "metric": "http_req_duration",
            "aggregate": "mean",
            "log_scale": True,
        },
    )
)

BAR_METRICS = {
    "baseline": (
        ("http_req_duration", "http", "HTTP response-time", "ms", False, False),
        ("http_req_tls_handshaking", "tls", "TLS handshake-time", "ms", False, True),
    ),
    "linear": (
        ("http_req_duration", "http", "HTTP response-time", "ms", False, False),
        ("http_req_tls_handshaking", "tls", "TLS handshake-time", "ms", False, True),
    ),
    "race": (
        ("http_reqs", "rps", "request-rate", "rate", True, False),
        ("http_req_duration", "http", "HTTP response-time", "ms", False, False),
        ("http_req_tls_handshaking", "tls", "TLS handshake-time", "ms", False, True),
    ),
}

BAR_CHARTS = tuple(
    (
        family,
        metric,
        f"{family}-{metric_slug}-{PROFILE_SLUGS[profile]}-percentiles.svg",
        f"{FAMILY_LABELS[family]} · {profile} - {metric_title} percentiles",
        unit,
        rate,
        tls_positive,
        profile,
    )
    for family in FAMILIES
    for metric, metric_slug, metric_title, unit, rate, tls_positive
    in BAR_METRICS[family]
    for profile in PROFILE_ROWS[family]
)

FAILURE_CHARTS = tuple(
    (
        family,
        f"{family}-failure-rate-{PROFILE_SLUGS[profile]}.svg",
        f"{FAMILY_LABELS[family]} · {profile} - HTTP failure rate",
        profile,
    )
    for family in FAMILIES
    for profile in PROFILE_ROWS[family]
)

SUMMARY_METADATA_FIELDS = (
    "elapsed_ms",
    "tls_version",
    "key_exchange_group",
    "key_exchange_group_source",
    "http_version",
    "endpoint",
    "payload_bytes",
    "connection_reuse",
    "tls_resumption_configured",
    "configured_vus",
    "configured_iterations",
    "max_duration_s",
    "configured_rate",
    "configured_peak_rate",
)

ADAPTIVE_STYLE = """<style>
  .theme-bg { fill: #ffffff; }
  .theme-plot { fill: #f8fafc; }
  .theme-text { fill: #111827; }
  .theme-muted { fill: #64748b; }
  .theme-grid { stroke: #e2e8f0; }
  .theme-border { stroke: #cbd5e1; }
  @media (prefers-color-scheme: dark) {
    .theme-bg { fill: #1f2227; }
    .theme-plot { fill: #202328; }
    .theme-text { fill: #d8d9da; }
    .theme-muted { fill: #a8abb2; }
    .theme-grid { stroke: #34383f; }
    .theme-border { stroke: #454a52; }
  }
</style>"""

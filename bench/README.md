# Benchmark Harness

The benchmark harness drives automated k6 load tests from a dedicated client VMSS instance inside the private Azure virtual network (`wtt-perf-client-snet`).

Testing runs exclusively across the private subnet to ensure measurement accuracy without public internet jitter, bandwidth bottlenecks, or external NAT interference.

---

## Benchmark Scenarios

Preconfigured benchmark workload definitions:

| Spec File | Profile Family | Description |
| --- | --- | --- |
| `bench/blog-tls-base.yaml` | Steady Baseline | Arrival-rate runs: Linear (100–3,000 req/s), Flat (1,000 req/s), Sine (0–2,500 req/s). |
| `bench/blog-tls-linear-peak.yaml` | High-Pressure Linear | Linear ramp up to 6,000 req/s evaluated under fixed (100 VUs) and expandable (1,000 VUs) pools. |
| `bench/blog-tls-race.yaml` | Fixed-Work Race | Fixed volume of 100,000 requests distributed across 10, 100, and 1,000 concurrent VUs. |
| `bench/benchmark.template.yaml` | Template | Template for custom request rates, endpoints, and duration ceilings. |

---

## Running Benchmarks

### Single Scenario Run

Execute a single benchmark run from the client VMSS:

```bash
make scenario SCENARIO=s4-k8s-pod-go \
  BENCH_CONFIG=bench/blog-tls-base.yaml \
  TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

### Sequential Multi-Scenario Matrix

Run the same workload sequentially across multiple topologies:

```bash
make scenarios SCENARIOS="s2-vm-go s4-k8s-pod-go s5-traefik-passthrough-go s6-traefik-terminate-go" \
  BENCH_CONFIG=bench/blog-tls-race.yaml \
  TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

---

## Harness Guarantees & Methodology

- **Fresh Connections:** Every iteration opens a brand-new TCP and TLS handshake (`noConnectionReuse: true`, `noVUConnectionReuse: true`) to measure connection establishment costs under churn.
- **Strict Certificate Validation:** The k6 client validates the full server certificate chain on every handshake against the private run CA.
- **Preflight Verification:** Before load begins, an OpenSSL preflight probe verifies that the endpoint negotiates the configured TLS protocol version and key agreement group (`P-256` or `X25519`), rejecting mismatched targets.
- **Warmup Isolation:** Configured warmup periods are excluded from performance percentiles and timelines.
- **Artifacts:** Raw metrics, summary JSON, and HTML reports are compressed and stored locally in `results/<run-id>/` and pushed as OCI artifacts to ACR (`<registry>/wtt/benchmark-results:<run-id>`).

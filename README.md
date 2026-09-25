# where-to-tls

A performance benchmark answering one architectural question: **where should TLS be terminated, and what does each choice actually cost?**

The same server implementations (.NET, Java, Go, Rust, and Windows IIS) are placed behind progressively deeper network topologies — direct bare VM, Kubernetes Service to pod, Traefik Gateway API passthrough, and Traefik ingress termination — driven by an identical, connection-churning k6 load profile.

---

## Topologies Under Test

All tests originate from a dedicated client load-generator VMSS (`Standard_D8s_v7`) across an Azure private network:

```
| Topology ID | Name | Termination Point | Data Path |
| --- | --- | --- | --- |
| `s1-iis-netfx` | Windows IIS | Host IIS | Azure LB → Windows VMSS → IIS (.NET Framework 4.8) |
| `s2-vm-<stack>` | Direct VM | Application Container | Azure LB → Linux VMSS → Container (.NET / Java / Go / Rust) |
| `s4-k8s-pod-<stack>` | Kubernetes Pod | Application Pod | Azure LB → Service Load Balancer → Pod |
| `s5-traefik-passthrough-<stack>` | Traefik Passthrough | Application Pod | Azure LB → Gateway API (Traefik L4 SNI Passthrough) → Pod |
| `s6-traefik-terminate-<stack>` | Traefik Termination | Traefik Ingress | Azure LB → Gateway API (Traefik TLS Termination) → Upstream TLS → Pod |
| `c0-*`, `c2-*`, `c4-*` | Plaintext Controls | Application / Service | Basic infra/debug tooling scenarios  |
---

## Workload Profiles & Parameters

The benchmark deliberately stresses **connection setup and teardown**, avoiding keep-alive connection pooling:
- **Connection Policy:** Fresh TCP and TLS handshake per iteration (`noConnectionReuse: true`, `noVUConnectionReuse: true`).
- **Payload:** 1 HTTP GET request returning a 1,024-byte payload per connection.
- **Certificate Verification:** Full client-side certificate validation on every handshake using ECDSA P-256 certificates.

### Load Profiles

1. **Steady Baseline (`bench/blog-tls-base.yaml`):**
   - **Linear:** 100 to 3,000 requests/s over 60s.
   - **Flat:** Steady 1,000 requests/s over 60s.
   - **Sine:** 0 to 2,500 requests/s over two 60s cycles.
2. **High-Pressure Linear Ramp (`bench/blog-tls-linear-peak.yaml`):**
   - 100 to 6,000 requests/s ramp over 90s, evaluated under two concurrency ceilings:
     - Fixed pool of 100 Virtual Users (VUs).
     - Expandable pool up to 1,000 VUs.
3. **Fixed-Work Race (`bench/blog-tls-race.yaml`):**
   - Fixed total volume of 100,000 requests distributed across concurrent VU pools:
     - 10 VUs (low concurrency, sequential serialization).
     - 100 VUs (moderate concurrency).
     - 1,000 VUs (high concurrency, heavy connection churn).

### Crypto Matrix

- **Protocols:** TLS 1.2 vs. TLS 1.3 (`TLS_VERSION=1.2|1.3`).
- **Key Exchange Groups:** `P-256` vs. `X25519` (`TLS_GROUP=P-256|X25519`).
- **Cipher Suites:** Pinned `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256` (TLS 1.2) and `TLS_AES_128_GCM_SHA256` (TLS 1.3).
- **Java Crypto Providers:** Native BoringSSL (`JAVA_TLS_PROVIDER=boringssl`) vs. default OpenJDK SunJSSE (`JAVA_TLS_PROVIDER=jdk`).
- **Base Images:** Debian/Ubuntu (`IMAGE_BASE=deb`) vs. Alpine musl (`IMAGE_BASE=alpine`).

---

## Repository Layout

```
├── analyze/              # Analysis infrastructure (InfluxDB v2, Grafana, Dashboards, Exporter)
│   ├── chart/            # Helm chart for deploying the analysis stack to Kubernetes
│   ├── dashboards/       # Grafana dashboard definitions
│   ├── exporting/        # Standalone SVG chart export scripts and workload datasets
│   ├── files/            # Grafana provisioning configs and Influx import scripts
│   └── podman/           # Rootless Podman compose setup for local analysis
├── bench/                # k6 benchmark definitions and workload scenarios
├── charts/               # Vendored Helm charts for Kubernetes cluster bootstrapping
│   ├── apps/             # Application deployment templates and scenario values
│   └── vendor/           # Pinned upstream charts (Cilium, Traefik, Prometheus, etc.)
├── docs/                 # Architecture and network lifecycle sequence diagrams (.drawio)
├── iac/                  # Infrastructure as Code (OpenTofu / Terraform)
│   ├── azure/            # Azure root modules (VMSS, networking, ACR, Key Vault)
│   └── bootstrap/        # Cloud-init and node bootstrap scripts
├── scripts/              # Cluster configuration, deployment, and diagnostic capture scripts
│   └── debug/            # Passive socket state and packet capture collectors
└── src/                  # Workload implementations (.NET 10/11, Java Netty, Go, Rust, IIS)
```

---

## Prerequisites

- **OpenTofu** ≥ 1.6 (or Terraform ≥ 1.5)
- **Azure CLI** (`az`) logged into your target subscription
- **kubectl** & **Helm** 3+
- **Podman** (for local image builds and offline analysis)
- **k6** ≥ 2.2.0

---

## Getting Started

### 1. Provision Infrastructure

Configure your Azure environment:

```bash
cd iac/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your Azure subscription and location
```

Provision the target scenario infrastructure:

```bash
make apply SCENARIO=s4-k8s-pod-go
```

### 2. Build and Deploy Workloads

Build immutable container images and push them to your Azure Container Registry:

```bash
# Build images for all stacks (deb or alpine base)
make images TAG=dev IMAGE_BASE=deb

# Deploy a specific scenario
make deploy SCENARIO=s4-k8s-pod-go TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

### 3. Run Benchmark Workloads

Execute a single scenario run from the client load generator:

```bash
make scenario SCENARIO=s4-k8s-pod-go \
  BENCH_CONFIG=bench/blog-tls-base.yaml \
  TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

Or run a matrix across multiple scenarios sequentially:

```bash
make scenarios SCENARIOS="s4-k8s-pod-net s4-k8s-pod-java s4-k8s-pod-go s4-k8s-pod-rust" \
  BENCH_CONFIG=bench/blog-tls-race.yaml \
  TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

---

## Analysis & Visualizations

Results are stored in InfluxDB (v2) and visualized via Grafana dashboards.

### Local Analysis (Podman Compose)

```bash
# List available OCI result artifacts in your ACR
make analyze-list

# Start local InfluxDB & Grafana with OCI artifacts
make analyze-up-oci IMPORT_ARTIFACT_IMAGES="<acr>/wtt/benchmark-results:<tag1> <acr>/wtt/benchmark-results:<tag2>"

# Access dashboards
# Grafana:  http://localhost:3000 (admin / adminadmin)
# InfluxDB: http://localhost:8086

# Stop the stack
make analyze-down
```

### Kubernetes Analysis Deployment

```bash
# Deploy analysis stack to the cluster control plane
make analyze-pod IMPORT_ARTIFACT_IMAGES="<acr>/wtt/benchmark-results:<tag>" IMPORT_SKIP_WARMUP=true

# Port-forward to local ports
make analyze-forward        # Grafana -> localhost:3000
make analyze-influx-forward # InfluxDB -> localhost:8086
```

### Generating Publication Charts

The standalone exporter generates SVG charts directly from InfluxDB run IDs:

```bash
python3 analyze/exporting/export-tls-result-svgs.py \
  --run-ids <run-id-1>,<run-id-2> \
  --tls-comparison \
  --scale logarithmic
```

---

## Connection Diagnostics

For deep investigation into socket retention, port exhaustion, and TLS teardown behavior, `scripts/debug/` provides passive, paired socket collectors:

```bash
# On the client VMSS:
sudo ./scripts/debug/client.sh --peer-ip <private-LB-IP> --port 8443 --duration 120 --name-suffix test

# On the server VMSS:
sudo ./scripts/debug/server.sh --peer-ip <client-IP> --port 8443 --duration 120 --name-suffix test
```

These scripts sample TCP socket states (`TIME-WAIT`, `ESTABLISHED`, `CLOSE-WAIT`), queue lengths, and capture packet traces without altering application configuration.

---

## Research Publication

The full benchmark methodology, latency percentiles, and detailed findings are published in the companion research blog:
- **Repository:** [`lightroastedblog`](https://github.com/slabbancz/lightroastedblog)
- **Live Site:** [https://slabbancz.github.io/lightroastedblog/](https://slabbancz.github.io/lightroastedblog/)

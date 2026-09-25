# Benchmark Analysis Stack

Offline Grafana and InfluxDB (v2) stack for analyzing k6 benchmark results.

Supports two deployment targets:

- **Local Podman Compose** (for local development and offline inspection)
- **Kubernetes Pod** (runs on the control plane via Helm chart)

---

## 1. Local Podman Compose

### Configuration

Copy `analyze/podman/.env.example` to `analyze/podman/.env`:

```bash
cp analyze/podman/.env.example analyze/podman/.env
```

Example `analyze/podman/.env`:

```env
# Credentials
INFLUX_ADMIN_USER=admin
INFLUX_ADMIN_PASSWORD=replace-with-a-long-random-api-token
INFLUX_ORG=where-to-tls
INFLUX_BUCKET=k6
INFLUX_TOKEN=replace-with-a-long-random-api-token
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=replace-with-a-long-random-api-token
GRAFANA_QUERY_TIMEOUT_SECONDS=120
GRAFANA_MAX_CONNS_PER_HOST=4

# Importer: Option A - Local Directory
IMPORT_RESULTS_DIR=/results
COMPOSE_RESULTS_DIR=/path/to/where-to-tls/results
IMPORT_SKIP_WARMUP=true
IMPORT_WORKERS=16

# Importer: Option B - OCI Artifacts (leave above empty if using OCI)
# IMPORT_RESULTS_DIR=
# IMPORT_ARTIFACT_IMAGES="wttperfacr.azurecr.io/wtt/benchmark-results:tag1 wttperfacr.azurecr.io/wtt/benchmark-results:tag2"
```

### Commands

```bash
# List available OCI result artifacts in ACR
make analyze-list
make analyze-list ANALYZE_LIST_LIMIT=50

# Start with local directory results
make analyze-up

# Or start with OCI registry artifacts
make analyze-up-oci IMPORT_ARTIFACT_IMAGES="<acr>/wtt/benchmark-results:<tag1> <acr>/wtt/benchmark-results:<tag2>"

# Stop the stack
make analyze-down
```

- **Grafana:** [http://localhost:3000](http://localhost:3000) (admin / configured password)
- **InfluxDB:** [http://localhost:8086](http://localhost:8086)

---

## 2. Kubernetes Deployment (Helm)

Deploys InfluxDB and Grafana to the Kubernetes control plane via `analyze/chart`.

### Prerequisites

Create the credentials secret in namespace `wtt`:

```bash
kubectl -n wtt create secret generic wtt-analyze-credentials \
  --from-literal=influx-admin-user=admin \
  --from-literal=influx-admin-password=adminadmin \
  --from-literal=influx-token=replace-with-a-long-random-api-token \
  --from-literal=grafana-admin-user=admin \
  --from-literal=grafana-admin-password=adminadmin
```

### Deploy

```bash
# Deploy with OCI artifact import
make analyze-pod \
  IMPORT_ARTIFACT_IMAGES="<acr>/wtt/benchmark-results:<tag>" \
  IMPORT_SKIP_WARMUP=true

# Port-forward to access locally
make analyze-forward          # Grafana -> http://localhost:3000
make analyze-influx-forward   # InfluxDB -> http://localhost:8086
```

---

## 3. Dashboards & Exports

- **Dashboard JSONs:** Stored in `analyze/dashboards/` and provisioned automatically.
  - `k6-live.json`: Live metrics and per-run timelines.
  - `k6-comparison.json`: Cross-scenario and cross-stack comparisons.
  - `k6-run-catalog.json`: Filterable catalog of imported runs with copyable SVG export commands.
- **Dashboard Builders & Tests:** Live in `.local/dashboards/`.
- **SVG Exporter:** Script lives in `analyze/exporting/export-tls-result-svgs.py`.

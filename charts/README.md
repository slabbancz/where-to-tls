# Helm Charts

Offline, air-gapped Helm chart management. All components are installed locally without `helm repo add`.

---

## Chart Directory Structure

- `charts/apps/`: Application chart deploying the workload pods (.NET, Java, Go, Rust) and configuring Gateway API / Service routing.
  - Scenario value presets live in `charts/apps/scenarios/<scenario>.yaml`.
- `charts/vendor/`: Vendored cluster infrastructure charts:
  - `gateway-api-experimental/`: Gateway API v1.6.1 Experimental CRDs (including `TLSRoute` and `BackendTLSPolicy`).
  - `cilium/`: Cilium CNI v1.20.1.
  - `traefik/`: Traefik v3.7.13 (chart v41.5.0) Gateway API implementation.
  - `kube-prometheus-stack/`: Prometheus Operator and node-exporter (downloaded via `./charts/fetch-charts.sh`).
  - `pyroscope/`: Continuous profiling and Alloy eBPF agent (downloaded via `./charts/fetch-charts.sh`).

---

## Deployment & Configuration

### Cluster Bootstrap

Bootstrap cluster networking and Gateway API:

```bash
make cluster-configure
```

To install metrics monitoring and eBPF profiling:

```bash
./charts/fetch-charts.sh
make cluster-monitoring
make cluster-monitoring-forward # Grafana on http://localhost:3001
```

### Deploying a Scenario

Deploy a specific benchmark scenario:

```bash
make deploy SCENARIO=s4-k8s-pod-go TAG=dev TLS_VERSION=1.3 TLS_GROUP=X25519
```

Supported deployment parameters:
- `TLS_VERSION`: `1.2` (default) or `1.3`.
- `TLS_GROUP`: `P-256` (default) or `X25519`.
- `JAVA_TLS_PROVIDER`: `boringssl` (default) or `jdk`.
- `PAYLOAD_PREALLOCATE`: `true` (default) or `false`.
- `TLS_HANDSHAKE_TIMEOUT_SECONDS`: Handshake deadline (default `5`).
- `HTTP_REQUEST_TIMEOUT_SECONDS`: Request deadline (default `10`).

### Offline Template Rendering

Render manifests locally without deploying:

```bash
helm template wtt-workload charts/apps \
  -f charts/apps/scenarios/s6-traefik-terminate-go.yaml \
  --set-string workload-go.config.tls.version=1.3 \
  --set-string workload-go.config.tls.group=X25519 \
  --set-string routing.tlsVersion=1.3 \
  --set-string routing.tlsGroup=X25519
```

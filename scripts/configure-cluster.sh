#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG_PATH="${1:-${REPOSITORY_ROOT}/results/kubeconfig}"
CONTROL_PLANE_IP_RESOLVER="${2:-}"

export KUBECONFIG="${KUBECONFIG_PATH}"

fail() {
  echo "FATAL: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file is missing: $1"
}

require_directory() {
  [[ -d "$1" ]] || fail "Required directory is missing: $1"
}

wait_for_condition() {
  local description="$1"
  local timeout_seconds="$2"
  local check_function="$3"
  local elapsed=0

  until "${check_function}"; do
    if (( elapsed >= timeout_seconds )); then
      fail "Timed out after ${timeout_seconds}s waiting for ${description}"
    fi
    echo "==> Waiting for ${description} (${elapsed}s/${timeout_seconds}s)..."
    sleep 5
    ((elapsed += 5))
  done
}

nodes_are_initialized() {
  local taints
  taints="$(kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"\n"}{end}{end}')"
  ! grep -Fxq "node.cloudprovider.kubernetes.io/uninitialized" <<<"${taints}"
}

gateway_class_is_accepted() {
  [[ "$(kubectl get gatewayclass traefik \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' \
    2>/dev/null)" == "True" ]]
}

for command in kubectl helm; do
  command -v "${command}" >/dev/null 2>&1 || fail "Required operator command is unavailable: ${command}"
done

require_file "${KUBECONFIG}"
require_file "${REPOSITORY_ROOT}/charts/vendor/gateway-api-experimental/experimental-install.yaml"
require_directory "${REPOSITORY_ROOT}/charts/vendor/cilium"
require_directory "${REPOSITORY_ROOT}/charts/vendor/traefik"
require_directory "${REPOSITORY_ROOT}/charts/vendor/cloud-provider-azure"
require_file "${REPOSITORY_ROOT}/charts/vendor/cilium-values.yaml"
require_file "${REPOSITORY_ROOT}/charts/vendor/traefik-values.yaml"
require_file "${REPOSITORY_ROOT}/charts/vendor/cloud-provider-azure-values.yaml"
[[ -n "${CONTROL_PLANE_IP_RESOLVER}" ]] ||
  fail "A control-plane IP resolver is required"
require_file "${CONTROL_PLANE_IP_RESOLVER}"

kubectl version >/dev/null

echo "==> Installing Gateway API experimental CRDs from vendored files..."
kubectl apply --server-side --force-conflicts \
  -f "${REPOSITORY_ROOT}/charts/vendor/gateway-api-experimental/experimental-install.yaml"

CONTROL_PLANE_IP=$(bash "${CONTROL_PLANE_IP_RESOLVER}" "${REPOSITORY_ROOT}")
echo "==> Resolved control-plane private IP: ${CONTROL_PLANE_IP}"

echo "==> Installing Cilium from its vendored chart..."
helm upgrade --install cilium "${REPOSITORY_ROOT}/charts/vendor/cilium" \
  --namespace kube-system \
  --values "${REPOSITORY_ROOT}/charts/vendor/cilium-values.yaml" \
  --set-string "k8sServiceHost=${CONTROL_PLANE_IP}"
  # --wait \
  # --timeout 10m

echo "==> Installing cloud-provider-azure from its vendored chart..."
helm upgrade --install cloud-provider-azure \
  "${REPOSITORY_ROOT}/charts/vendor/cloud-provider-azure" \
  --namespace kube-system \
  --values "${REPOSITORY_ROOT}/charts/vendor/cloud-provider-azure-values.yaml"
  # --wait \
  # --timeout 10m
kubectl -n kube-system rollout status deployment/cloud-controller-manager --timeout=180s

echo "==> Installing Traefik from its vendored chart..."
helm upgrade --install traefik "${REPOSITORY_ROOT}/charts/vendor/traefik" \
  --namespace traefik \
  --create-namespace \
  --values "${REPOSITORY_ROOT}/charts/vendor/traefik-values.yaml"
  # --wait \
  # --timeout 10m

echo "==> Gate 1/4: checking node readiness..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
wait_for_condition \
  "cloud provider to initialize every node" \
  300 \
  nodes_are_initialized

echo "==> Gate 2/4: checking Cilium rollout and kube-proxy replacement..."
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
KUBE_PROXY_REPLACEMENT="$(kubectl -n kube-system get configmap cilium-config -o jsonpath='{.data.kube-proxy-replacement}' 2>/dev/null || true)"
[[ "${KUBE_PROXY_REPLACEMENT}" == "true" ]] ||
  fail "Cilium kube-proxy replacement is '${KUBE_PROXY_REPLACEMENT:-unset}', expected 'true'"

echo "==> Gate 3/4: checking required CRDs..."
for crd in \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io \
  tlsroutes.gateway.networking.k8s.io \
  tlsoptions.traefik.io; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=120s
done

echo "==> Gate 4/4: checking Traefik GatewayClass..."
wait_for_condition \
  "GatewayClass/traefik Accepted=True" \
  180 \
  gateway_class_is_accepted

echo "==> Cluster configuration succeeded."

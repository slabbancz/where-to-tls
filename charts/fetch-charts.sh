#!/usr/bin/env bash
# fetch-charts.sh - refresh the pinned vendored Helm charts.
#
# Charts are unpacked directories in charts/vendor/, not .tgz archives. The
# core cluster charts are committed for offline provisioning. kube-prometheus-
# stack and Pyroscope are downloaded from pinned release assets but
# intentionally ignored; Helm still installs them locally with no
# 'helm repo add' or deployment-time chart download.
#
# This script is the only thing here that touches the network, and it is run
# deliberately when a chart version is bumped - never as part of a deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${SCRIPT_DIR}/vendor"

CILIUM_VERSION="1.20.1"
CILIUM_REPO="https://helm.cilium.io/"
TRAEFIK_VERSION="41.5.0"
TRAEFIK_REPO="https://traefik.github.io/charts"
CLOUD_PROVIDER_AZURE_VERSION="1.36.0"
CLOUD_PROVIDER_AZURE_REPO="https://raw.githubusercontent.com/kubernetes-sigs/cloud-provider-azure/master/helm/repo"
GATEWAY_API_VERSION="v1.6.1"
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
KUBE_PROMETHEUS_STACK_VERSION="91.4.1"
KUBE_PROMETHEUS_STACK_URL="https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}/kube-prometheus-stack-${KUBE_PROMETHEUS_STACK_VERSION}.tgz"
PYROSCOPE_VERSION="2.3.1"
PYROSCOPE_APP_VERSION="2.3.1"
PYROSCOPE_URL="https://github.com/grafana/helm-charts/releases/download/pyroscope-${PYROSCOPE_VERSION}/pyroscope-${PYROSCOPE_VERSION}.tgz"

mkdir -p "${VENDOR_DIR}"
TMP_DIR="${SCRIPT_DIR}/.tmp-fetch-charts"
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

vendor_chart() {
  local name="$1" repo="$2" version="$3"

  echo "==> ${name} v${version}"
  helm pull "${name}" --repo "${repo}" --version "${version}" --destination "${TMP_DIR}"
  tar -xzf "${TMP_DIR}/${name}-${version}.tgz" -C "${TMP_DIR}"

  # Swap in only after a successful pull, so a failure never leaves a
  # half-written chart behind.
  rm -rf "${VENDOR_DIR}/${name}"
  mv "${TMP_DIR}/${name}" "${VENDOR_DIR}/${name}"

  local pinned
  pinned="$(awk '/^version:/{print $2; exit}' "${VENDOR_DIR}/${name}/Chart.yaml")"
  if [[ "${pinned}" != "${version}" ]]; then
    echo "ERROR: ${name} Chart.yaml reports ${pinned}, expected ${version}" >&2
    exit 1
  fi
}

vendor_gateway_crds() {
  local version="$1" url="$2"
  echo "==> gateway-api experimental CRDs ${version}"
  local dest_dir="${VENDOR_DIR}/gateway-api-experimental"
  mkdir -p "${dest_dir}"
  curl -fsSL -L "${url}" -o "${TMP_DIR}/experimental-install.yaml"
  mv "${TMP_DIR}/experimental-install.yaml" "${dest_dir}/experimental-install.yaml"
}

download_chart_release() {
  local name="$1" version="$2" url="$3"
  local archive="${TMP_DIR}/${name}-${version}.tgz"

  echo "==> ${name} v${version}"
  curl -fsSL -L "${url}" -o "${archive}"
  tar -xzf "${archive}" -C "${TMP_DIR}"

  rm -rf "${VENDOR_DIR}/${name}"
  mv "${TMP_DIR}/${name}" "${VENDOR_DIR}/${name}"

  local pinned
  pinned="$(awk '/^version:/{print $2; exit}' "${VENDOR_DIR}/${name}/Chart.yaml")"
  if [[ "${pinned}" != "${version}" ]]; then
    echo "ERROR: ${name} Chart.yaml reports ${pinned}, expected ${version}" >&2
    exit 1
  fi
}

vendor_chart cilium "${CILIUM_REPO}" "${CILIUM_VERSION}"
vendor_chart traefik "${TRAEFIK_REPO}" "${TRAEFIK_VERSION}"
vendor_chart cloud-provider-azure "${CLOUD_PROVIDER_AZURE_REPO}" "${CLOUD_PROVIDER_AZURE_VERSION}"
vendor_gateway_crds "${GATEWAY_API_VERSION}" "${GATEWAY_API_URL}"
download_chart_release kube-prometheus-stack \
  "${KUBE_PROMETHEUS_STACK_VERSION}" "${KUBE_PROMETHEUS_STACK_URL}"
download_chart_release pyroscope \
  "${PYROSCOPE_VERSION}" "${PYROSCOPE_URL}"

pyroscope_app_version="$(awk '/^appVersion:/{print $2; exit}' "${VENDOR_DIR}/pyroscope/Chart.yaml")"
if [[ "${pyroscope_app_version}" != "${PYROSCOPE_APP_VERSION}" ]]; then
  echo "ERROR: pyroscope Chart.yaml reports appVersion ${pyroscope_app_version}, expected ${PYROSCOPE_APP_VERSION}" >&2
  exit 1
fi

echo "==> Vendored charts in ${VENDOR_DIR}:"
for d in "${VENDOR_DIR}"/*/; do
  [[ -f "${d}Chart.yaml" ]] || continue
  printf '    %-10s %s\n' \
    "$(awk '/^name:/{print $2; exit}' "${d}Chart.yaml")" \
    "$(awk '/^version:/{print $2; exit}' "${d}Chart.yaml")"
done

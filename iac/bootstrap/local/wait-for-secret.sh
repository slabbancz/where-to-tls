#!/usr/bin/env bash
set -euo pipefail

vault_name="${1:?Key Vault name is required}"
secret_name="${2:?secret name is required}"
timeout_seconds="${3:-300}"
minimum_updated_at="${4:-}"
poll_interval_seconds="${5:-5}"
deadline=$((SECONDS + timeout_seconds))

command -v az >/dev/null 2>&1 || {
  echo "FATAL: Azure CLI is required to wait for Key Vault secret ${secret_name}" >&2
  exit 1
}

while true; do
  secret_updated_at=$(az keyvault secret show \
    --vault-name "${vault_name}" \
    --name "${secret_name}" \
    --query attributes.updated \
    --output tsv 2>/dev/null || true)

  if [[ -n "${secret_updated_at}" ]]; then
    if [[ -z "${minimum_updated_at}" ]] ||
      (( $(date -u -d "${secret_updated_at}" +%s) >= $(date -u -d "${minimum_updated_at}" +%s) )); then
      exit 0
    fi
  fi

  if ((SECONDS >= deadline)); then
    echo "FATAL: Key Vault secret ${secret_name} was not refreshed after ${timeout_seconds} seconds" >&2
    az keyvault secret show \
      --vault-name "${vault_name}" \
      --name "${secret_name}" \
      --query '{id:id, updated:attributes.updated}' \
      --output tsv
    exit 1
  fi
  sleep "${poll_interval_seconds}"
done

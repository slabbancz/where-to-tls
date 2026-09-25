#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env
secret_name="${1:?secret name is required}"

for attempt in $(seq 1 120); do
  token=$(/opt/wtt/bootstrap/cloud/get-identity-token.sh https://vault.azure.net 2>/dev/null || true)
  if [[ -n "${token}" ]]; then
    value=$(curl -fsS \
      -H "Authorization: Bearer ${token}" \
      "https://${AZURE_KEY_VAULT_NAME}.vault.azure.net/secrets/${secret_name}?api-version=7.4" |
      jq -er '.value' 2>/dev/null || true)
    if [[ -n "${value}" ]]; then
      printf '%s\n' "${value}"
      exit 0
    fi
  fi
  sleep 10
done

echo "FATAL: secret '${secret_name}' was not available after 1200 seconds" >&2
exit 1

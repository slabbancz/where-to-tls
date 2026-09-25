#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env
secret_name="${1:?secret name is required}"
secret_value=$(cat)
body=$(jq -n --arg value "${secret_value}" '{value: $value}')

for attempt in $(seq 1 30); do
  token=$(/opt/wtt/bootstrap/cloud/get-identity-token.sh https://vault.azure.net 2>/dev/null || true)
  if [[ -n "${token}" ]] && curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${body}" \
    "https://${AZURE_KEY_VAULT_NAME}.vault.azure.net/secrets/${secret_name}?api-version=7.4" \
    >/dev/null; then
    exit 0
  fi
  sleep 5
done

echo "FATAL: failed to publish secret '${secret_name}' after 150 seconds" >&2
exit 1

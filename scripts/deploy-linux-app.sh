#!/usr/bin/env bash
set -euo pipefail

resource_group="${1:?Resource group is required}"
vmss_name="${2:?VMSS name is required}"
image="${3:?Container image is required}"
tls_enabled="${4:?TLS enabled flag is required}"
tls_version="${5:?TLS version is required}"
payload_preallocate="${6:?Payload preallocation flag is required}"
tls_handshake_timeout_seconds="${7:-5}"
http_request_timeout_seconds="${8:-10}"
tls_group="${9:-P-256}"
java_tls_provider="${10:-boringssl}"
[[ "${tls_group}" == P-256 || "${tls_group}" == X25519 ]] ||
  { echo "FATAL: TLS group must be P-256 or X25519" >&2; exit 1; }
[[ "${java_tls_provider}" == boringssl || "${java_tls_provider}" == jdk ]] ||
  { echo "FATAL: Java TLS provider must be boringssl or jdk" >&2; exit 1; }

for timeout in "${tls_handshake_timeout_seconds}" "${http_request_timeout_seconds}"; do
  [[ "${timeout}" =~ ^[1-9][0-9]*$ ]] && ((timeout <= 300)) ||
    { echo "FATAL: timeout seconds must be an integer from 1 through 300" >&2; exit 1; }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote_script="${script_dir}/../iac/bootstrap/node/configure-linux-app.sh"

output=$(az vmss run-command invoke \
  --resource-group "${resource_group}" \
  --name "${vmss_name}" \
  --instance-id 0 \
  --command-id RunShellScript \
  --scripts "@${remote_script}" \
  --parameters "${image}" "${tls_enabled}" "${tls_version}" "${payload_preallocate}" \
    "${tls_handshake_timeout_seconds}" "${http_request_timeout_seconds}" "${tls_group}" \
    "${java_tls_provider}" \
  --query 'value[].message' \
  --output tsv)
printf '%s\n' "${output}"
grep -q 'WTT_LINUX_DEPLOY_OK=1' <<< "${output}" ||
  { echo "FATAL: Linux VMSS deployment did not complete successfully" >&2; exit 1; }

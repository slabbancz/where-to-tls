#!/usr/bin/env bash
set -euo pipefail

config_path="${1:?resolved benchmark JSON path is required}"
[[ $# -eq 1 && -f "${config_path}" ]] || {
  echo "FATAL: resolved benchmark JSON is required" >&2
  exit 2
}
jq -e '.runId and .target.ip and .workload.imageDigest' "${config_path}" >/dev/null || {
  echo "FATAL: invalid resolved benchmark JSON" >&2
  exit 2
}

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
download_dir=$(mktemp -d)
trap 'rm -rf "${download_dir}"' EXIT

resource_group=$(tofu -chdir="${repository_root}/iac/azure" output -raw resource_group_name)
client_vmss=$(tofu -chdir="${repository_root}/iac/azure" output -raw client_vmss_name)
registry=$(tofu -chdir="${repository_root}/iac/azure" output -raw acr_login_server)
key_vault_name=$(tofu -chdir="${repository_root}/iac/azure" output -raw key_vault_name)
run_id=$(jq -er '.runId' "${config_path}")
remote_prefix="/tmp/wtt-benchmark-${run_id}"

result_ref=$(az vmss run-command invoke \
  --resource-group "${resource_group}" --name "${client_vmss}" --instance-id 0 \
  --command-id RunShellScript \
  --scripts 'grep -o "WTT_RESULT_REF=[^[:space:]]*" "$1.log" | tail -1' \
  --parameters "${remote_prefix}" \
  --query 'value[].message' --output tsv |
  grep -o 'WTT_RESULT_REF=[^[:space:]]*' |
  sed 's/^WTT_RESULT_REF=//' | tail -1 | tr -d '\r')
[[ -n "${result_ref}" ]] || {
  echo "FATAL: client did not return a result reference" >&2
  exit 1
}

docker_config=$(az keyvault secret show \
  --vault-name "${key_vault_name}" \
  --name acr-push-dockerconfigjson \
  --query value --output tsv)
username=$(jq -er --arg registry "${registry}" '.auths[$registry].username' <<<"${docker_config}")
password=$(jq -er --arg registry "${registry}" '.auths[$registry].password' <<<"${docker_config}")
printf '%s' "${password}" | oras login "${registry}" --username "${username}" --password-stdin
oras pull "${result_ref}" --output "${download_dir}"
archive=$(find "${download_dir}" -maxdepth 1 -name '*.tar.gz' -type f -print -quit)
[[ -n "${archive}" ]] || {
  echo "FATAL: result artifact contained no archive" >&2
  exit 1
}
tar -xzf "${archive}" -C "${repository_root}/results"
printf 'Benchmark downloaded: %s\n' "${result_ref}"

#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
run_id="${1:?run ID is required}"
registry="${2:?ACR login server is required}"
run_dir="/opt/wtt/benchmark-results/${run_id}"
[[ -d "${run_dir}" ]] || { echo "FATAL: benchmark completed without a result directory" >&2; exit 1; }

archive="/tmp/${run_id}.tar.gz"
tar -czf "${archive}" -C "$(dirname "${run_dir}")" "$(basename "${run_dir}")"
docker_config=$(/opt/wtt/bootstrap/cloud/get-secret.sh acr-push-dockerconfigjson)
username=$(jq -er --arg registry "${registry}" '.auths[$registry].username' <<<"${docker_config}")
password=$(jq -er --arg registry "${registry}" '.auths[$registry].password' <<<"${docker_config}")
printf '%s' "${password}" | oras login "${registry}" --username "${username}" --password-stdin
result_ref="${registry}/wtt/benchmark-results:${run_id}"
(cd /tmp && oras push "${result_ref}" "$(basename "${archive}"):application/gzip")
printf 'WTT_RESULT_REF=%s\n' "${result_ref}"

#!/usr/bin/env bash
set -euo pipefail

config_input="${1:?resolved benchmark JSON path is required}"
[[ $# -eq 1 ]] || { echo "FATAL: resolved benchmark JSON is required" >&2; exit 2; }
config_path=
if [[ "${config_input}" == "-" ]]; then
  config_path=$(mktemp)
  cat > "${config_path}"
  trap 'rm -f "${config_path}"' EXIT
else
  config_path="${config_input}"
fi
[[ -f "${config_path}" ]] || { echo "FATAL: resolved benchmark JSON is required" >&2; exit 2; }
jq -e '.runId and .target.ip and .workload.imageDigest' "${config_path}" >/dev/null ||
  { echo "FATAL: invalid resolved benchmark JSON" >&2; exit 2; }

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

resource_group=$(tofu -chdir="${repository_root}/iac/azure" output -raw resource_group_name)
client_vmss=$(tofu -chdir="${repository_root}/iac/azure" output -raw client_vmss_name)
run_id=$(jq -er '.runId' "${config_path}")
[[ -n "${client_vmss}" && "${client_vmss}" != null ]] ||
  { echo "FATAL: benchmark client VMSS is unavailable" >&2; exit 1; }

config_base64url=$(base64 -w 0 "${config_path}" | tr '+/' '-_' | tr -d '=')
remote_prefix="/tmp/wtt-benchmark-${run_id}"
remote_launch_script=$(cat <<'REMOTE_LAUNCH'
status="$2.status"
log="$2.log"
pid_file="$2.pid"
printf "RUNNING\\n" > "$status"
nohup setsid bash -c '
  status="$1"
  log="$2"
  config="$3"
  /opt/wtt/bootstrap/k6/bench-entry.sh "$config" > "$log" 2>&1
  rc=$?
  printf "%s\\n" "$rc" > "$status"
' _ "$status" "$log" "$1" </dev/null >/dev/null 2>&1 &
pid=$!
printf "%s\\n" "$pid" > "$pid_file"
printf "WTT_BENCH_STARTED_PID=%s\\n" "$pid"
REMOTE_LAUNCH
)

az vmss run-command invoke \
  --resource-group "${resource_group}" --name "${client_vmss}" --instance-id 0 \
  --command-id RunShellScript \
  --scripts "${remote_launch_script}" \
  --parameters "${config_base64url}" "${remote_prefix}" \
  --query 'value[].message' --output tsv

printf '%s Benchmark started on %s; polling every 60 seconds.\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${client_vmss}"

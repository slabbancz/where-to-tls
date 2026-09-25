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

resource_group=$(tofu -chdir="${repository_root}/iac/azure" output -raw resource_group_name)
client_vmss=$(tofu -chdir="${repository_root}/iac/azure" output -raw client_vmss_name)
run_id=$(jq -er '.runId' "${config_path}")
remote_prefix="/tmp/wtt-benchmark-${run_id}"

printf 'Polling %s every 60 seconds.\n' "${client_vmss}"
while :; do
  status_output=$(az vmss run-command invoke \
    --resource-group "${resource_group}" --name "${client_vmss}" --instance-id 0 \
    --command-id RunShellScript \
    --scripts '
      status=$(cat "$1.status" 2>/dev/null || printf "RUNNING")
      if [ "$status" = RUNNING ]; then
        now=$(date +%s)
        log_mtime=$(stat -c %Y "$1.log" 2>/dev/null || printf 0)
        log_age=$((now - log_mtime))
        if [ "$log_mtime" -eq 0 ] || [ "$log_age" -gt 300 ]; then
          if dmesg 2>/dev/null | grep -qiE "out of memory|oom-killer|killed process.*k6"; then
            printf "WTT_BENCH_STATUS=OOM_KILLED\\n"
            printf "WTT_BENCH_ERROR=k6 was killed by the kernel OOM killer\\n"
          else
            printf "WTT_BENCH_STATUS=STALE\\n"
            printf "WTT_BENCH_ERROR=benchmark log is missing or stale (age=%s seconds)\\n" "$log_age"
          fi
        else
          printf "WTT_BENCH_STATUS=RUNNING\\n"
        fi
      else
        printf "WTT_BENCH_STATUS=%s\\n" "$status"
      fi
      phase=$(grep -o "WTT_PHASE=[^[:space:]]*" "$1.log" 2>/dev/null | tail -1 || true)
      [ -n "$phase" ] && printf "WTT_BENCH_PHASE=%s\\n" "$phase"
    ' \
    --parameters "${remote_prefix}" \
    --query 'value[].message' --output tsv)
  status=$(printf '%s\n' "${status_output}" |
    grep -o 'WTT_BENCH_STATUS=[^[:space:]]*' |
    sed 's/^WTT_BENCH_STATUS=//' |
    tail -1 | tr -d '[:space:]\r' || true)
  [[ -n "${status}" ]] || status=RUNNING
  phase=$(printf '%s\n' "${status_output}" |
    grep -o 'WTT_BENCH_PHASE=[^[:space:]]*' |
    sed 's/^WTT_BENCH_PHASE=//' |
    tail -1 | tr -d '\r' || true)
  if [[ -n "${phase}" ]]; then
    printf '%s Benchmark status: %s (%s)\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${status}" "${phase}"
  else
    printf '%s Benchmark status: %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "${status}"
  fi
  case "${status}" in
    0) break ;;
    RUNNING) sleep 60 ;;
    *)
      echo "FATAL: remote benchmark status is ${status}" >&2
      az vmss run-command invoke \
        --resource-group "${resource_group}" --name "${client_vmss}" --instance-id 0 \
        --command-id RunShellScript \
        --scripts 'tail -40 "$1.log" 2>/dev/null || true' \
        --parameters "${remote_prefix}" \
        --query 'value[].message' --output tsv >&2 || true
      exit 1
      ;;
  esac
done
printf 'Benchmark complete on %s.\n' "${client_vmss}"

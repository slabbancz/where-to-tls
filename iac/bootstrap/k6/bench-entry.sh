#!/usr/bin/env bash
set -euo pipefail

config_base64url="${1:?URL-safe Base64 benchmark configuration is required}"
[[ $# -eq 1 ]] || { echo "FATAL: exactly one benchmark configuration argument is required" >&2; exit 2; }

echo "WTT_PHASE=lock"
lock_file="${WTT_BENCHMARK_LOCK_FILE:-/var/lock/wtt-benchmark.lock}"
lock_pid_file="${lock_file}.pid"
exec 9>"${lock_file}"
if ! flock -n 9; then
  owner_pid=$(cat "${lock_pid_file}" 2>/dev/null || printf 'unknown')
  echo "FATAL: benchmark client is busy (active PID: ${owner_pid})" >&2
  exit 1
fi

config_path=
cleanup() { rm -f "${config_path}" "${lock_pid_file}"; }
trap cleanup EXIT
printf '%s\n' "$$" > "${lock_pid_file}"

echo "WTT_PHASE=initialize"
if ! cloud-init status --wait; then
  echo "WARN: cloud-init completed with errors; continuing with explicit benchmark setup" >&2
fi
source /etc/wtt/bootstrap.env
export HOME=/root

echo "WTT_PHASE=transform"
config_path=$(mktemp)
padding=$(( (4 - ${#config_base64url} % 4) % 4 ))
config_base64url="${config_base64url//-/+}"
config_base64url="${config_base64url//_/\/}"
case "${padding}" in
  1) config_base64url+="=" ;;
  2) config_base64url+="==" ;;
  3) config_base64url+="===" ;;
esac
printf '%s' "${config_base64url}" | base64 --decode > "${config_path}"
jq -e '.target.ip and .target.hostname and .runId' "${config_path}" >/dev/null ||
  { echo "FATAL: invalid resolved benchmark configuration" >&2; exit 2; }

target_ip=$(jq -r '.target.ip' "${config_path}")
target_hostname=$(jq -r '.target.hostname' "${config_path}")
hosts_file=$(mktemp)
awk -v hostname="${target_hostname}" '$2 != hostname { print }' /etc/hosts > "${hosts_file}"
printf '%s %s\n' "${target_ip}" "${target_hostname}" >> "${hosts_file}"
install -m 0644 "${hosts_file}" /etc/hosts
rm -f "${hosts_file}"

echo "WTT_PHASE=execute"
/opt/wtt/bootstrap/k6/bench-runner.sh --config "${config_path}"

echo "WTT_PHASE=publish"
/opt/wtt/bootstrap/k6/bench-publish.sh "$(jq -r '.runId' "${config_path}")" "${AZURE_ACR_LOGIN_SERVER:?ACR login server is missing from client bootstrap}"

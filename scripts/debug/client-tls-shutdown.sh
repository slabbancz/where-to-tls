#!/usr/bin/env bash
set -euo pipefail

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: sudo bash scripts/debug/client-tls-shutdown.sh --hostname <TLS-hostname> --peer-ip <IPv4> [options]

Run on the client VMSS only, AFTER both full-packet collectors report ready.
Generates diagnostic traffic; never publishes results or changes deployments.
Uses trusted TLS 1.2, pinned ECDSA/AES128-GCM cipher, HTTP/2, fresh connections,
and /payload?bytes=1024. The deployed server must already have resumption OFF.
Each request has a 10s total timeout, including TCP/TLS setup and response.

  --port <port>             TLS listener/LB port (8443).
  --rate <RPS>              Constant arrival rate (20; max 2000).
  --duration <seconds>      Offered-load window (20; max 120), plus up to 30s drain.
  --preallocated-vus <n>    Initial VU pool (200; max 1000).
  --max-vus <n>             Maximum VU pool (1000).
  --exhaustion              Use client-tls-exhaustion.js: fixed 2000 RPS, 60s,
                            200 initial / 1000 maximum VUs. Cannot combine
                            with explicit rate/duration/VU options.
  --exhaustion-four-ips     Use client-tls-exhaustion-four-ips.js with the
                            same fixed load and exactly four client source IPs
                            from /etc/wtt/client-source-ips. Cannot combine
                            with --exhaustion or explicit rate/duration/VU options.
  --label <label>           Safe evidence label (shutdown).
  --output <directory>     New evidence directory; never overwrite.
  --help                   Print help.

Requires root, k6, jq, flock, and coreutils. No tools are installed.
Outputs TLS SESSION SECRETS to tls.keys (root-only). PCAP + keys permit
decryption in BOTH directions. Never commit or publish these secrets.
Nonzero exit preserves evidence; inspect k6.log and manifest.txt.
EOF
}

hostname=
peer_ip=
port=8443
rate=20
duration=20
preallocated_vus=200
max_vus=1000
label=shutdown
output=
exhaustion=false
exhaustion_four_ips=false
load_options_explicit=false
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --exhaustion) exhaustion=true; shift ;;
    --exhaustion-four-ips) exhaustion_four_ips=true; shift ;;
    --hostname|--peer-ip|--port|--rate|--duration|--preallocated-vus|--max-vus|--label|--output)
      (($# >= 2)) && [[ -n "$2" ]] || fatal "$1 requires a value"
      case "$1" in
        --hostname) hostname="$2" ;;
        --peer-ip) peer_ip="$2" ;;
        --port) port="$2" ;;
        --rate) rate="$2"; load_options_explicit=true ;;
        --duration) duration="$2"; load_options_explicit=true ;;
        --preallocated-vus) preallocated_vus="$2"; load_options_explicit=true ;;
        --max-vus) max_vus="$2"; load_options_explicit=true ;;
        --label) label="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2 ;;
    *) fatal "unknown option: $1" ;;
  esac
done

workload_script=client-tls-shutdown.js
if [[ "${exhaustion}" == true || "${exhaustion_four_ips}" == true ]]; then
  [[ "${exhaustion}" != true || "${exhaustion_four_ips}" != true ]] ||
    fatal "--exhaustion and --exhaustion-four-ips cannot be combined"
  [[ "${load_options_explicit}" == false ]] ||
    fatal "exhaustion modes have fixed load settings; omit rate/duration/VU options"
  rate=2000
  duration=60
  preallocated_vus=200
  max_vus=1000
  if [[ "${exhaustion_four_ips}" == true ]]; then
    workload_script=client-tls-exhaustion-four-ips.js
  else
    workload_script=client-tls-exhaustion.js
  fi
fi

[[ "${hostname}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
  fatal "--hostname requires a TLS hostname, not a URL"
[[ "${peer_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fatal "--peer-ip requires an IPv4 address"
IFS=. read -r -a octets <<<"${peer_ip}"
for octet in "${octets[@]}"; do
  ((10#${octet} <= 255)) || fatal "invalid IPv4 address"
done
printf -v peer_ip '%d.%d.%d.%d' "$((10#${octets[0]}))" "$((10#${octets[1]}))" "$((10#${octets[2]}))" "$((10#${octets[3]}))"
positive_integer() {
  [[ "$2" =~ ^[1-9][0-9]{0,9}$ ]] && (($2 <= $3)) ||
    fatal "$1 must be an integer from 1 through $3 (no leading zeros)"
}
positive_integer --port "${port}" 65535
positive_integer --rate "${rate}" 2000
positive_integer --duration "${duration}" 120
positive_integer --preallocated-vus "${preallocated_vus}" 1000
positive_integer --max-vus "${max_vus}" 1000
((max_vus >= preallocated_vus)) || fatal "--max-vus must be at least --preallocated-vus"
[[ "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fatal "--label must be a safe 1-64-character label"
((EUID == 0)) || fatal "run as root on the client node"
for tool in k6 jq flock date mkdir readlink cp grep chmod env; do
  command -v "${tool}" >/dev/null || fatal "required tool missing: ${tool}"
done

client_source_ips_csv=
if [[ "${exhaustion_four_ips}" == true ]]; then
  readonly source_ips_file="/etc/wtt/client-source-ips"
  [[ -r "${source_ips_file}" ]] ||
    fatal "client source IP inventory is missing: ${source_ips_file}"
  mapfile -t client_source_ips < "${source_ips_file}"
  ((${#client_source_ips[@]} == 4)) ||
    fatal "client source IP inventory must contain exactly four addresses"

  declare -A seen_source_ips=()
  for source_ip in "${client_source_ips[@]}"; do
    [[ "${source_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
      fatal "client source IP inventory contains an invalid IPv4 address"
    IFS=. read -r -a octets <<<"${source_ip}"
    for octet in "${octets[@]}"; do
      ((10#${octet} <= 255)) ||
        fatal "client source IP inventory contains an invalid IPv4 address"
    done
    [[ -z "${seen_source_ips[${source_ip}]:-}" ]] ||
      fatal "client source IP inventory contains a duplicate address"
    seen_source_ips["${source_ip}"]=1
  done
  client_source_ips_csv=$(IFS=,; printf '%s' "${client_source_ips[*]}")
fi

umask 077
lock_file="${WTT_BENCHMARK_LOCK_FILE:-/var/lock/wtt-benchmark.lock}"
exec 9>"${lock_file}"
flock -n 9 || fatal "benchmark client is busy; do not overlap diagnostic and benchmark traffic"
output="${output:-/var/tmp/wtt-tls-${label}-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -- "${output}" || fatal "cannot create new output directory: ${output}"
output=$(readlink -f "${output}")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cleanup() {
  local status=$?
  trap - EXIT
  printf 'exit_status=%s\nfinished_utc=%s\n' "${status}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "${output}/manifest.txt"
  printf 'WTT_TLS_DIAGNOSTIC_OUTPUT=%s\n' "${output}" >&2
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'diagnostic_only=true\nstarted_utc=%s\nlabel=%s\nkeylog=tls.keys\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${label}" > "${output}/manifest.txt"
k6 version > "${output}/k6-version.txt"
cp "${script_dir}/client-tls-shutdown.js" "${output}/client-tls-shutdown.js"
if [[ "${exhaustion}" == true || "${exhaustion_four_ips}" == true ]]; then
  cp "${script_dir}/${workload_script}" "${output}/${workload_script}"
fi
if [[ "${exhaustion_four_ips}" == true ]]; then
  printf 'client_source_ips=%s\n' "${client_source_ips_csv}" >> "${output}/manifest.txt"
fi
printf 'workload_script=%s\n' "${workload_script}" >> "${output}/manifest.txt"
jq -n --arg hostname "${hostname}" --arg ip "${peer_ip}" --arg label "${label}" \
  --argjson port "${port}" --argjson rate "${rate}" --argjson duration "${duration}" \
  --argjson preallocated "${preallocated_vus}" --argjson max "${max_vus}" \
  '{hostname:$hostname,peerIp:$ip,port:$port,label:$label,rate:$rate,duration:$duration,
    preAllocatedVUs:$preallocated,maxVUs:$max}' > "${output}/config.json"
printf '{}\n' > "${output}/k6-options.json"
: > "${output}/tls.keys"
chmod 600 "${output}/tls.keys"
printf 'WARN: TLS session keys will be retained in %s/tls.keys; do not publish them\n' "${output}" >&2
printf 'WTT_TLS_DIAGNOSTIC_START output=%s\n' "${output}"

# Ignore ambient k6 settings, including live outputs and certificate bypasses.
# Explicit config/JS/CLI settings define this diagnostic; trust uses the host CA store.
k6_args=(run)
if [[ -n "${client_source_ips_csv}" ]]; then
  k6_args+=(--local-ips="${client_source_ips_csv}")
fi
k6_args+=(
  --config "${output}/k6-options.json"
  --no-usage-report
  --out "json=${output}/raw.jsonl"
  --summary-export "${output}/summary.json"
  "${output}/${workload_script}"
)
if env -i PATH="${PATH}" HOME=/root SSLKEYLOGFILE="${output}/tls.keys" \
  WTT_SHUTDOWN_CONFIG="${output}/config.json" \
  k6 "${k6_args[@]}" > "${output}/k6.log" 2>&1; then
  printf 'k6_exit_status=0\n' >> "${output}/manifest.txt"
else
  status=$?
  printf 'k6_exit_status=%s\n' "${status}" >> "${output}/manifest.txt"
  printf 'ERROR: k6 exited %s; inspect %s/k6.log; evidence preserved\n' "${status}" "${output}" >&2
  exit "${status}"
fi
grep -q '^CLIENT_RANDOM ' "${output}/tls.keys" ||
  fatal "no TLS 1.2 session keys recorded; this run cannot establish decrypted shutdown evidence"
printf 'tls12_keys_present=true\n' >> "${output}/manifest.txt"
printf 'WTT_TLS_DIAGNOSTIC_COMPLETE output=%s\n' "${output}"

#!/usr/bin/env bash
set -euo pipefail

readonly K6_SCRIPT="$(dirname "$0")/main.js"
readonly K6_CONFIG="$(dirname "$0")/config.json"
readonly K6_OPTIONS_CONFIG="$(dirname "$0")/options.json"
readonly CLIENT_SOURCE_IPS_FILE="/etc/wtt/client-source-ips"

fail() {
  echo "FATAL: $*" >&2
  exit 2
}

phase() {
  printf '\033[38;5;208mWTT_PHASE=%s\033[0m\n' "$1"
}

require_config() {
  [[ "${1:-}" == "--config" && -n "${2:-}" && $# -eq 2 ]] ||
    fail "usage: $0 --config <path>"

  config=$2
  jq -e '.runName | type == "string" and test("\\S") and (test("[\\x00-\\x1f\\x7f]") | not)' "${config}" >/dev/null ||
    fail "runName must be a nonblank single-line string"
  jq -e '(.matrix.repeats | type == "number" and . >= 1 and floor == .)' "${config}" >/dev/null ||
    fail "matrix.repeats must be a positive integer; warm-up alone is not a benchmark result"

  jq -e '
    (.runId | type == "string" and length > 0) and
    (.target.hostname | type == "string" and length > 0) and
    (.target.ip | type == "string" and length > 0) and
    (.target.port | type == "number" and . > 0 and . <= 65535) and
    (.target.tls | type == "boolean") and
    (if .target.tls then .target.tlsVersion | IN("1.2", "1.3")
     else .target.tlsVersion == "none"
     end) and
    (if .target.tls then (.target.tlsGroup // "P-256") | IN("P-256", "X25519")
     else (.target.tlsGroup // "none") == "none" end) and
    ((has("tlsGroup") | not) or .tlsGroup == (.target.tlsGroup // (if .target.tls then "P-256" else "none" end))) and
    (.workload.scenario | type == "string" and length > 0) and
    (.workload.stack | type == "string" and length > 0) and
    (.workload.tlsTerminatedAt | type == "string" and length > 0) and
    (.workload.imageReference | type == "string" and length > 0) and
    (.workload.imageDigest | type == "string" and length > 0) and
    (.k6.options.quiet | type == "boolean") and
    (.k6.options.verbose | type == "boolean") and
    (.k6.options.summaryMode | IN("compact", "full", "disabled")) and
    (.k6.dashboard.enabled | type == "boolean") and
    (.k6.dashboard.intervalSeconds | type == "number" and . > 0) and
    (.matrix.endpoints | type == "array" and length > 0) and
    (.matrix | has("tlsGroups") | not) and
    all(.matrix.endpoints[];
      . as $endpoint |
      ($endpoint.path | IN("/ping", "/payload")) and
      (if $endpoint | has("payloadBytes")
       then ($endpoint.payloadBytes | type == "number" and . > 0)
       else true
       end)
    ) and
    (.matrix.httpVersions | type == "array" and length > 0) and
    all(.matrix.httpVersions[]; IN("1.1", "2")) and
    (.matrix.tlsResumption | type == "array" and length > 0) and
    all(.matrix.tlsResumption[]; type == "boolean") and
    ((.matrix.connectionReuse // [true]) | type == "array" and length > 0) and
    all((.matrix.connectionReuse // [true])[]; type == "boolean") and
    (.matrix.profiles | type == "array" and length > 0) and
    all(.matrix.profiles[];
      if .name == "race" then
        (has("preAllocatedVUs") | not) and
        (has("maxVUs") | not)
      elif has("maxVUs") then
        .preAllocatedVUs as $preallocated |
        (.maxVUs | type == "number" and . > 0 and floor == . and . >= $preallocated)
      else true end
    ) and
    all(.matrix.profiles[];
      (.name == "flat" and (.rate | type == "number" and . > 0) and
        (.windowSeconds | type == "number" and . > 0) and
        (.preAllocatedVUs | type == "number" and . > 0 and floor == .)) or
      (.name == "race" and
        (.iterations | type == "number" and . > 0 and floor == .) and
        (.vus | type == "number" and . > 0 and floor == .) and
        (.maxDurationSeconds | type == "number" and . > 0 and floor == .)) or
      (.name == "sine" and (.amplitude | type == "number" and . > 0) and (.offset | type == "number") and (.cycles | type == "number" and . > 0) and (.sampling | type == "number" and . >= 2 and floor == .) and
        (.windowSeconds | type == "number" and . > 0) and
        (.preAllocatedVUs | type == "number" and . > 0 and floor == .)) or
      ((.name == "linear" or .name == "exponential") and (.start | type == "number" and . > 0) and (.end | type == "number" and . > 0) and (.sampling | type == "number" and . >= 2 and floor == .) and
        (.windowSeconds | type == "number" and . > 0) and
        (.preAllocatedVUs | type == "number" and . > 0 and floor == .))) and
    (.matrix.warmupSeconds | type == "number" and . >= 0) and
    (.matrix.repeats | type == "number" and . >= 1 and floor == .)
  ' "${config}" >/dev/null || fail "invalid benchmark configuration"
}

load_config() {
  run_id=$(jq -r '.runId' "${config}")
  hostname=$(jq -r '.target.hostname' "${config}")
  port=$(jq -r '.target.port' "${config}")
  tls_enabled=$(jq -r '.target.tls' "${config}")
  tls_version=$(jq -r '.target.tlsVersion' "${config}")
  tls_group=$(jq -r 'if .target.tls then .target.tlsGroup // "P-256" else "none" end' "${config}")
  target_ip=$(jq -r '.target.ip' "${config}")
  scenario=$(jq -r '.workload.scenario' "${config}")
  stack=$(jq -r '.workload.stack' "${config}")
  tls_terminated_at=$(jq -r '.workload.tlsTerminatedAt' "${config}")
  image_reference=$(jq -r '.workload.imageReference' "${config}")
  image_digest=$(jq -r '.workload.imageDigest' "${config}")
  dashboard_enabled=$(jq -r '.k6.dashboard.enabled' "${config}")
  dashboard_interval=$(jq -r '.k6.dashboard.intervalSeconds' "${config}")
  jq '.k6.options' "${config}" > "${K6_OPTIONS_CONFIG}"

  [[ -r /etc/wtt/bootstrap.env ]] || fail "client bootstrap environment is missing"
  # This file is created by trusted cloud-init and includes the expected IP count.
  source /etc/wtt/bootstrap.env
  [[ "${WTT_CLIENT_SOURCE_IP_COUNT:-}" =~ ^[1-9][0-9]*$ ]] ||
    fail "client source IP count is invalid"
  [[ -r "${CLIENT_SOURCE_IPS_FILE}" ]] ||
    fail "client source IP inventory is missing; run configure-client-source-ips.sh"
  mapfile -t client_source_ips < <(grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "${CLIENT_SOURCE_IPS_FILE}")
  ((${#client_source_ips[@]} == WTT_CLIENT_SOURCE_IP_COUNT)) ||
    fail "client source IP inventory has ${#client_source_ips[@]} entries; expected ${WTT_CLIENT_SOURCE_IP_COUNT}"
  client_source_ips_csv=$(IFS=,; printf '%s' "${client_source_ips[*]}")
  client_source_ips_json=$(printf '%s\n' "${client_source_ips[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')

  result_root="/opt/wtt/benchmark-results/${run_id}"
  records_dir="${result_root}/records"
  reports_dir="${result_root}/reports"
  timeseries_dir="${result_root}/timeseries"
  raw_dir="${result_root}/raw"
  [[ ! -e "${result_root}" ]] ||
    fail "result directory already exists for runId '${run_id}'"
  mkdir -p "${records_dir}" "${raw_dir}"

  if [[ "${dashboard_enabled}" == true ]]; then
    mkdir -p "${reports_dir}" "${timeseries_dir}"
  fi
}

execution_plan() {
  jq -r \
    --arg target_url "$([[ "${tls_enabled}" == true ]] && echo https || echo http)://${hostname}:${port}" \
    --arg scenario "${scenario}" \
    --arg stack "${stack}" \
    --arg termination "${tls_terminated_at}" \
    --arg tls_version "${tls_version}" \
    --arg tls_group "${tls_group}" \
    --arg run_id "${run_id}" \
    --arg image_reference "${image_reference}" \
    --arg image_digest "${image_digest}" \
    --arg records_dir "${records_dir}" \
    --arg reports_dir "${reports_dir}" \
    --arg timeseries_dir "${timeseries_dir}" \
    --arg raw_dir "${raw_dir}" \
    --argjson client_source_ips "${client_source_ips_json}" \
    --argjson dashboard_enabled "${dashboard_enabled}" \
    --argjson dashboard_interval "${dashboard_interval}" '
    .runName as $run_name |
    [.matrix as $matrix |
    $matrix.endpoints[] as $endpoint |
    $matrix.httpVersions[] as $http_version |
    $matrix.tlsResumption[] as $resumption |
    ($matrix.connectionReuse // [true])[] as $connection_reuse |
    (
      (if $matrix.warmupSeconds > 0 then
        $matrix.profiles[] as $profile |
        select($profile.name != "race") |
        {
          endpoint: $endpoint,
          httpVersion: $http_version,
          resumption: $resumption,
          connectionReuse: $connection_reuse,
          profile: $profile
        } + {
          durationSeconds: $matrix.warmupSeconds,
          warmup: true,
          repeat: 0
        }
      else empty end),
      (
        range(1; $matrix.repeats + 1) as $repeat |
        $matrix.profiles[] as $profile |
        {
          endpoint: $endpoint,
          httpVersion: $http_version,
          resumption: $resumption,
          connectionReuse: $connection_reuse,
          profile: $profile
        } + {
          durationSeconds: (if $profile.name == "race" then $profile.maxDurationSeconds else $profile.windowSeconds end),
          warmup: false,
          repeat: $repeat
        }
      )
    )] | to_entries[] |
    (.key + 1) as $execution_index |
    .value as $run |
    ($run.endpoint.path | ltrimstr("/")) as $endpoint_name |
    (if $run.warmup then "warmup" else "r\($run.repeat)" end) as $phase |
    ((if $run.profile.name == "race"
     then "\($scenario)-race-iters\($run.profile.iterations)-vus\($run.profile.vus)-\($endpoint_name)-\($phase)-http\($run.httpVersion)-reuse\($run.connectionReuse)"
     else "\($scenario)-\($run.profile.name)-rps\((if $run.profile.name == "flat" then $run.profile.rate elif $run.profile.name == "sine" then $run.profile.offset + $run.profile.amplitude else $run.profile.end end))-\($endpoint_name)-\($phase)-http\($run.httpVersion)-reuse\($run.connectionReuse)"
     end) + "-\($execution_index)") as $tag |
    {
      profile: $run.profile.name,
      endpoint: $run.endpoint.path,
      repeat: $run.repeat,
      warmup: $run.warmup,
      record: "\($records_dir)/\($tag).json",
      report: "\($reports_dir)/\($tag).html",
      timeseries: "\($timeseries_dir)/\($tag).ndjson",
      raw: "\($raw_dir)/\($tag).json.gz",
      config: {
        targetUrl: $target_url,
        scenario: $scenario,
        stack: $stack,
        tlsTerminatedAt: $termination,
        tlsVersion: $tls_version,
        tlsGroup: $tls_group,
        endpoint: $run.endpoint.path,
        payloadBytes: ($run.endpoint.payloadBytes // null),
        httpVersion: $run.httpVersion,
        tlsResumption: $run.resumption,
        connectionReuse: $run.connectionReuse,
        profile: $run.profile.name,
        rate: (if $run.profile.name == "flat" then $run.profile.rate else 0 end),
        peakRate: (if $run.profile.name == "flat" then 0 else ($run.profile.end // ($run.profile.offset + $run.profile.amplitude)) end),
        amplitude: ($run.profile.amplitude // 0),
        offset: ($run.profile.offset // 0),
        cycles: ($run.profile.cycles // 0),
        start: ($run.profile.start // 0),
        end: ($run.profile.end // 0),
        sampling: ($run.profile.sampling // 0),
        raceIterations: ($run.profile.iterations // 0),
        raceVUs: ($run.profile.vus // 0),
        durationSeconds: $run.durationSeconds,
        preAllocatedVUs: ($run.profile.preAllocatedVUs // $run.profile.vus),
        maxVUs: ($run.profile.maxVUs // $run.profile.preAllocatedVUs // $run.profile.vus),
        warmup: $run.warmup,
        runId: $run_id,
        runName: $run_name,
        executionIndex: $execution_index,
        imageReference: $image_reference,
        imageDigest: $image_digest,
        clientSourceIPs: $client_source_ips,
        recordPath: "\($records_dir)/\($tag).json",
        dashboardEnabled: $dashboard_enabled,
        dashboardIntervalSeconds: $dashboard_interval
      }
    } |
    [.profile, .endpoint, (.repeat | tostring), (.warmup | tostring), ($run.durationSeconds | tostring), .record, .report, .timeseries, .raw, (.config | @base64), ($execution_index | tostring)] |
    @tsv
  ' "${config}"
}

verify_tls_group() {
  tls_group_evidence=null
  server_metadata=null
  local output observed order opposite status meta_url meta
  local -a curl_tls_options=()
  if [[ "${tls_enabled}" != true ]]; then
    meta_url="http://${hostname}:${port}/meta"
  else
    meta_url="https://${hostname}:${port}/meta"
  fi
  if [[ "${tls_enabled}" == true ]]; then
  local -a protocol=(-tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256)
  [[ "${tls_version}" != 1.3 ]] || protocol=(-tls1_3)
  # Offer both groups in both orders. A correctly pinned server must negotiate
  # the configured key-exchange group regardless of client preference order.
  for order in P-256:X25519 X25519:P-256; do
    output=$(timeout 15 openssl s_client -connect "${target_ip}:${port}" \
      -servername "${hostname}" -verify_return_error -verify_hostname "${hostname}" \
      "${protocol[@]}" -groups "${order}" -brief </dev/null 2>&1) ||
      fail "TLS group preflight handshake failed (TLS ${tls_version}, offered ${order})"
    grep -Fq "Protocol version: TLSv${tls_version}" <<<"${output}" ||
      fail "TLS group preflight did not expose the requested protocol"
    observed=$(sed -nE 's/^(Server|Peer) Temp Key: (.*)$/\2/p' <<<"${output}")
    case "${observed}" in
      "ECDH, prime256v1, 256 bits"|"ECDH, secp256r1, 256 bits"|"ECDH, P-256, 256 bits") observed=P-256 ;;
      "X25519, 253 bits"|"X25519, 255 bits"|"X25519, 256 bits") observed=X25519 ;;
      *) fail "TLS group preflight cannot verify the negotiated group" ;;
    esac
    [[ "${observed}" == "${tls_group}" ]] ||
      fail "TLS group mismatch: configured ${tls_group}, negotiated ${observed}"
  done
  # For P-256, also verify that an X25519-only client offer is rejected.
  if [[ "${tls_group}" == P-256 ]]; then
    opposite=X25519
    status=0
    output=$(timeout 15 openssl s_client -connect "${target_ip}:${port}" -servername "${hostname}" \
      "${protocol[@]}" -groups "${opposite}" -brief </dev/null 2>&1) || status=$?
    [[ "${status}" == 1 ]] &&
      grep -Eq 'alert (handshake failure|insufficient security)|SSL alert number (40|71)' <<<"${output}" ||
      fail "TLS group restriction probe did not reject the other group with a TLS handshake alert"
  fi

  curl_tls_options=(--resolve "${hostname}:${port}:${target_ip}" --tlsv"${tls_version}" --tls-max "${tls_version}")
  [[ "${tls_version}" != 1.2 ]] || curl_tls_options+=(--ciphers ECDHE-ECDSA-AES128-GCM-SHA256)
  case "${tls_group}" in
    P-256) curl_tls_options+=(--curves prime256v1) ;;
    X25519) curl_tls_options+=(--curves X25519:prime256v1) ;;
  esac
  meta=$(curl --fail --silent --show-error --noproxy '*' --max-time 15 \
    "${curl_tls_options[@]}" "${meta_url}") || fail "TLS metadata preflight failed"
  if [[ "${tls_terminated_at}" != traefik ]]; then
    jq -e --arg group "${tls_group}" --arg version "${tls_version}" '
      .tls_terminated_here == true and .tls_version == $version and
      (.key_exchange_group == $group or .key_exchange_group == "unexposed-by-runtime")
    ' <<<"${meta}" >/dev/null || fail "live server metadata disagrees with TLS preflight"
  fi
  tls_group_evidence=$(jq -cn --arg group "${tls_group}" --arg version "${tls_version}" \
    --arg target "${target_ip}:${port}" --arg hostname "${hostname}" \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{source:"openssl-preflight", group:$group, tls_version:$version, target:$target,
      hostname:$hostname, checked_at:$checked_at, scope:"client-facing-preflight"}')
  else
    meta=$(curl --fail --silent --show-error --noproxy '*' --max-time 15 \
      --resolve "${hostname}:${port}:${target_ip}" "${meta_url}") ||
      fail "plaintext metadata preflight failed"
  fi
  jq -e '
    type == "object" and
    (.runtime_version | type == "string" and length > 0) and
    (.tls_runtime | type == "string" and length > 0) and
    (.tls_runtime_version | type == "string" and length > 0)
  ' <<<"${meta}" >/dev/null || fail "server metadata omitted runtime or TLS provider evidence"
  server_metadata="${meta}"
}

run_k6() {
  local report=$1
  local timeseries=$2
  local raw_points=$3

  if [[ "${dashboard_enabled}" == true ]]; then
    K6_WEB_DASHBOARD=true \
    K6_WEB_DASHBOARD_PORT=-1 \
    K6_WEB_DASHBOARD_PERIOD="${dashboard_interval}s" \
    K6_WEB_DASHBOARD_EXPORT="${report}" \
    K6_WEB_DASHBOARD_RECORD="${timeseries}" \
    k6 run --local-ips="${client_source_ips_csv}" --config "${K6_OPTIONS_CONFIG}" --out "json=${raw_points}" "${K6_SCRIPT}"
  else
    k6 run --local-ips="${client_source_ips_csv}" --config "${K6_OPTIONS_CONFIG}" --out "json=${raw_points}" "${K6_SCRIPT}"
  fi
}


phase validate
require_config "$@"
phase prepare
load_config

plan_file=$(mktemp)
trap 'rm -f "${plan_file}"' EXIT
execution_plan > "${plan_file}"

phase plan
while IFS=$'\t' read -r profile endpoint repeat warmup duration record report timeseries raw_points k6_config execution_index; do
  printf '\033[38;5;208mWTT_PLAN execution=%s profile=%s endpoint=%s repeat=%s warmup=%s duration=%ss\033[0m\n' \
    "${execution_index}" "${profile}" "${endpoint}" "${repeat}" "${warmup}" "${duration}"
done < "${plan_file}"

phase execute
while IFS=$'\t' read -r profile endpoint repeat warmup duration record report timeseries raw_points k6_config execution_index; do
  printf '\033[38;5;208mWTT_PHASE=cell execution=%s profile=%s endpoint=%s repeat=%s warmup=%s\033[0m\n' \
    "${execution_index}" "${profile}" "${endpoint}" "${repeat}" "${warmup}"
  printf '%s' "${k6_config}" | base64 --decode > "${K6_CONFIG}"
  verify_tls_group
  verified_config=$(jq --argjson evidence "${tls_group_evidence}" \
    --argjson server_metadata "${server_metadata}" \
    '. + {tlsGroupEvidence: $evidence, serverMetadata: $server_metadata}' "${K6_CONFIG}")
  printf '%s\n' "${verified_config}" > "${K6_CONFIG}"
  run_k6 "${report}" "${timeseries}" "${raw_points}"
  [[ -f "${record}" ]] && cat "${record}" >> "${result_root}/raw.jsonl"
done < "${plan_file}"

phase complete
printf 'WTT_RUN_DIRECTORY=%s\n' "${result_root}"

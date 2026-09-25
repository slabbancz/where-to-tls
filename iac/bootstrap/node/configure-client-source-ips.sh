#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FATAL: %s\n' "$*" >&2
  exit 1
}

readonly bootstrap_env="/etc/wtt/bootstrap.env"
[[ -r "${bootstrap_env}" ]] ||
  fail "client bootstrap environment is missing"
# Cloud-init owns this root-written file. Loading it here also makes the
# systemd service independent of a caller's exported environment.
source "${bootstrap_env}"

readonly metadata_url="http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01"
readonly source_ips_file="/etc/wtt/client-source-ips"
readonly expected_count="${WTT_CLIENT_SOURCE_IP_COUNT:?WTT_CLIENT_SOURCE_IP_COUNT is required}"

[[ "${expected_count}" =~ ^[1-9][0-9]*$ ]] ||
  fail "WTT_CLIENT_SOURCE_IP_COUNT must be a positive integer"

metadata=$(curl --fail --silent --show-error --noproxy '*' \
  --header Metadata:true "${metadata_url}") ||
  fail "Azure instance metadata network query failed"

mapfile -t source_ips < <(
  jq -er '
    (if type == "array" then . else .interface end) as $interfaces |
    [$interfaces[]?.ipv4.ipAddress[]?.privateIpAddress] |
    unique |
    .[] |
    select(test("^(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(\\.(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}$"))
  ' <<<"${metadata}"
)

((${#source_ips[@]} == expected_count)) ||
  fail "Azure metadata contains ${#source_ips[@]} source IPs; expected ${expected_count}"

default_route=$(ip -4 route show default | head -n 1)
default_device=$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}' <<<"${default_route}")
[[ -n "${default_device}" ]] ||
  fail "could not determine the default IPv4 interface"

primary_cidr=$(ip -o -4 addr show dev "${default_device}" scope global |
  awk 'NR == 1 { print $4 }')
prefix_length=${primary_cidr#*/}
[[ "${primary_cidr}" == */* && "${prefix_length}" =~ ^[0-9]+$ ]] ||
  fail "could not determine the primary IPv4 prefix on ${default_device}"

for source_ip in "${source_ips[@]}"; do
  if ! ip -o -4 addr show dev "${default_device}" |
    awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${source_ip}"; then
    ip address add "${source_ip}/${prefix_length}" dev "${default_device}" ||
      fail "could not configure ${source_ip}/${prefix_length} on ${default_device}"
  fi
done

install -d -m 0755 /etc/wtt
printf '%s\n' "${source_ips[@]}" > "${source_ips_file}"
chmod 0644 "${source_ips_file}"

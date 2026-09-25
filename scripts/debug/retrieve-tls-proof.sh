#!/usr/bin/env bash
set -euo pipefail

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: scripts/debug/retrieve-tls-proof.sh --label <label> [options]

Retrieves a matched full-packet/TLS-key diagnostic proof bundle through the
private ACR. It stages the server capture, combines it with the client capture
and client k6 key log, publishes a dedicated private OCI artifact, then pulls
it into the local ignored results/ directory.

  --label <label>              Capture label, e.g. java-proof-01.
  --resource-group <name>      Azure resource group (from OpenTofu output).
  --client-vmss <name>         Client VMSS (from OpenTofu output).
  --server-vmss <name>         Standalone Linux app VMSS (from OpenTofu output).
  --registry <host>            ACR login server (from OpenTofu output).
  --download-only              Pull and verify an already-published proof artifact.
  --keep-remote-staging        Retain the server-only OCI staging tag.
  --help                       Print help.

Expected remote paths:
  /var/tmp/wtt-server-<label>
  /var/tmp/wtt-client-<label>
  /var/tmp/wtt-tls-<label>/tls.keys

The label must be unique. This artifact contains TLS session secrets, so it is
not a normal benchmark result and must remain private. The local archive,
directory, PCAPs, key log, and decoded outputs are all ignored by Git.
EOF
}

label=
resource_group=
client_vmss=
server_vmss=
registry=
keep_remote_staging=false
download_only=false
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --label|--resource-group|--client-vmss|--server-vmss|--registry)
      (($# >= 2)) && [[ -n "$2" ]] || fatal "$1 requires a value"
      case "$1" in
        --label) label="$2" ;;
        --resource-group) resource_group="$2" ;;
        --client-vmss) client_vmss="$2" ;;
        --server-vmss) server_vmss="$2" ;;
        --registry) registry="$2" ;;
      esac
      shift 2 ;;
    --keep-remote-staging) keep_remote_staging=true; shift ;;
    --download-only) download_only=true; shift ;;
    *) fatal "unknown option: $1" ;;
  esac
done

[[ "${label}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
  fatal "--label must be a safe 1-64-character label"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
auth_file="${repository_root}/analyze/podman/auth.json"
for tool in az tofu oras tar jq find mktemp cp sha256sum chmod; do
  command -v "${tool}" >/dev/null || fatal "required tool missing: ${tool}"
done
[[ -r "${auth_file}" ]] ||
  fatal "missing ${auth_file}; run 'make podman-login' first"

read_output() {
  local name=$1 value=$2
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
  else
    tofu -chdir="${repository_root}/iac/azure" output -raw "${name}"
  fi
}
resource_group=$(read_output resource_group_name "${resource_group}")
client_vmss=$(read_output client_vmss_name "${client_vmss}")
server_vmss=$(read_output linux_app_vmss_name "${server_vmss}")
registry=$(read_output acr_login_server "${registry}")
[[ -n "${resource_group}" && -n "${client_vmss}" && -n "${server_vmss}" && -n "${registry}" ]] ||
  fatal "Azure resource group, VMSS names, and ACR registry must be non-empty"
for value in "${resource_group}" "${client_vmss}" "${server_vmss}"; do
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
    fatal "Azure resource and VMSS names may contain only letters, digits, dots, underscores, and hyphens"
done
[[ "${registry}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] ||
  fatal "ACR registry must be a hostname"

server_capture="/var/tmp/wtt-server-${label}"
client_capture="/var/tmp/wtt-client-${label}"
tls_workload="/var/tmp/wtt-tls-${label}"
server_tag="tls-proof-${label}-server"
proof_tag="tls-proof-${label}"
server_ref="${registry}/wtt/benchmark-results:${server_tag}"
proof_ref="${registry}/wtt/benchmark-results:${proof_tag}"
local_archive="${repository_root}/results/tls-proof-${label}.tar"
local_output="${repository_root}/results/tls-proof-${label}"
[[ ! -e "${local_archive}" ]] || fatal "local archive already exists: ${local_archive}"
[[ ! -e "${local_output}" ]] || fatal "local output already exists: ${local_output}"
[[ "${download_only}" == false || "${keep_remote_staging}" == false ]] ||
  fatal "--keep-remote-staging cannot be used with --download-only"

run_command() {
  local vmss=$1 script=$2
  az vmss run-command invoke \
    --resource-group "${resource_group}" --name "${vmss}" --instance-id 0 \
    --command-id RunShellScript --scripts "${script}" \
    --query 'value[].message' --output tsv
}

if [[ "${download_only}" == false ]]; then
printf 'WTT_TLS_PROOF_PHASE=validate-server label=%s\n' "${label}"
run_command "${server_vmss}" "set -eu
test -d '${server_capture}'
test -s '${server_capture}/full.pcap'
grep -qx 'capture_mode=full' '${server_capture}/manifest.txt'
grep -qx 'packet_limit_reached=false' '${server_capture}/manifest.txt'
grep -qx 'packets_dropped_by_kernel=0' '${server_capture}/manifest.txt'
printf '%s\n' WTT_TLS_PROOF_SERVER_VALID"

printf 'WTT_TLS_PROOF_PHASE=validate-client label=%s\n' "${label}"
run_command "${client_vmss}" "set -eu
test -d '${client_capture}'
test -s '${client_capture}/full.pcap'
grep -qx 'capture_mode=full' '${client_capture}/manifest.txt'
grep -qx 'packet_limit_reached=false' '${client_capture}/manifest.txt'
grep -qx 'packets_dropped_by_kernel=0' '${client_capture}/manifest.txt'
test -d '${tls_workload}'
test -s '${tls_workload}/tls.keys'
grep -qx 'tls12_keys_present=true' '${tls_workload}/manifest.txt'
grep -qx 'k6_exit_status=0' '${tls_workload}/manifest.txt'
printf '%s\n' WTT_TLS_PROOF_CLIENT_VALID"

printf 'WTT_TLS_PROOF_PHASE=stage-server ref=%s\n' "${server_ref}"
run_command "${server_vmss}" "set -eu
export HOME=/root
capture='${server_capture}'
archive='/tmp/${server_tag}.tar.gz'
registry='${registry}'
tag='${server_tag}'
if ! command -v oras >/dev/null 2>&1; then
  curl -fsSL https://github.com/oras-project/oras/releases/download/v1.3.0/oras_1.3.0_linux_amd64.tar.gz | tar -xz -C /tmp oras
  PATH=/tmp:\$PATH
  export PATH
fi
tar -czf \"\$archive\" -C \"\$(dirname \"\$capture\")\" \"\$(basename \"\$capture\")\"
config=\$(/opt/wtt/bootstrap/cloud/get-secret.sh acr-push-dockerconfigjson)
username=\$(printf %s \"\$config\" | jq -er --arg registry \"\$registry\" '.auths[\$registry].username')
password=\$(printf %s \"\$config\" | jq -er --arg registry \"\$registry\" '.auths[\$registry].password')
printf %s \"\$password\" | oras login \"\$registry\" --username \"\$username\" --password-stdin
(cd /tmp && oras push \"\$registry/wtt/benchmark-results:\$tag\" \"\$(basename \"\$archive\"):application/gzip\")
printf 'WTT_TLS_PROOF_SERVER_REF=%s/wtt/benchmark-results:%s\n' \"\$registry\" \"\$tag\""

printf 'WTT_TLS_PROOF_PHASE=combine-client ref=%s\n' "${proof_ref}"
run_command "${client_vmss}" "set -eu
export HOME=/root
registry='${registry}'
server_ref='${server_ref}'
client_capture='${client_capture}'
tls_workload='${tls_workload}'
tag='${proof_tag}'
combined='/tmp/${proof_tag}'
download='/tmp/${proof_tag}-server'
archive='/tmp/${proof_tag}.tar.gz'
test ! -e \"\$combined\" || { echo \"FATAL: staging directory already exists: \$combined\" >&2; exit 1; }
test ! -e \"\$download\" || { echo \"FATAL: staging directory already exists: \$download\" >&2; exit 1; }
mkdir -p \"\$combined\" \"\$download\"
config=\$(/opt/wtt/bootstrap/cloud/get-secret.sh acr-push-dockerconfigjson)
username=\$(printf %s \"\$config\" | jq -er --arg registry \"\$registry\" '.auths[\$registry].username')
password=\$(printf %s \"\$config\" | jq -er --arg registry \"\$registry\" '.auths[\$registry].password')
printf %s \"\$password\" | oras login \"\$registry\" --username \"\$username\" --password-stdin
oras pull \"\$server_ref\" --output \"\$download\"
server_archive=\$(find \"\$download\" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
test -n \"\$server_archive\"
tar -tzf \"\$server_archive\" >/dev/null
tar -xzf \"\$server_archive\" -C \"\$combined\"
cp -a \"\$client_capture\" \"\$combined/\"
cp -a \"\$tls_workload\" \"\$combined/\"
chmod -R go-rwx \"\$combined\"
tar -czf \"\$archive\" -C /tmp \"\$tag\"
(cd /tmp && oras push \"\$registry/wtt/benchmark-results:\$tag\" \"\$(basename \"\$archive\"):application/gzip\")
printf 'WTT_TLS_PROOF_REF=%s/wtt/benchmark-results:%s\n' \"\$registry\" \"\$tag\""

if [[ "${keep_remote_staging}" == false ]]; then
  printf 'WTT_TLS_PROOF_PHASE=cleanup-server-staging ref=%s\n' "${server_ref}"
  az acr repository delete --name "${registry%%.*}" \
    --image "wtt/benchmark-results:${server_tag}" --yes >/dev/null
fi
fi

printf 'WTT_TLS_PROOF_PHASE=download ref=%s\n' "${proof_ref}"
download_dir=$(mktemp -d)
trap 'rm -rf "${download_dir}"' EXIT
oras pull --registry-config "${auth_file}" "${proof_ref}" --output "${download_dir}"
remote_archive=$(find "${download_dir}" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
[[ -n "${remote_archive}" ]] || fatal "proof artifact contains no archive"
tar -tzf "${remote_archive}" >/dev/null
mkdir -p "${repository_root}/results"
cp "${remote_archive}" "${local_archive}"
chmod 600 "${local_archive}"
tar -xzf "${local_archive}" -C "${repository_root}/results"
chmod -R go-rwx "${local_output}"

key_file="${local_output}/wtt-tls-${label}/tls.keys"
[[ -s "${key_file}" ]] || fatal "proof bundle has no TLS key log"
[[ "$(stat -c %a "${key_file}")" == 600 ]] ||
  fatal "unexpected key-log permissions: $(stat -c %a "${key_file}")"
for pcap in "${local_output}/wtt-client-${label}/full.pcap" "${local_output}/wtt-server-${label}/full.pcap"; do
  [[ -s "${pcap}" ]] || fatal "proof bundle missing/empty PCAP: ${pcap}"
done

printf 'WTT_TLS_PROOF_ARCHIVE=%s\n' "${local_archive}"
printf 'WTT_TLS_PROOF_SHA256=%s\n' "$(sha256sum "${local_archive}" | awk '{print $1}')"
printf 'WTT_TLS_PROOF_EXTRACTED=%s\n' "${local_output}"
printf 'WTT_TLS_PROOF_REF=%s\n' "${proof_ref}"

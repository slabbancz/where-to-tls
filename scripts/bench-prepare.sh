#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FATAL: $*" >&2
  exit 2
}

spec_path="${1:?benchmark configuration path is required}"
[[ $# -eq 1 && -f "${spec_path}" ]] ||
  { echo "FATAL: benchmark configuration does not exist: ${spec_path}" >&2; exit 2; }
scenario="${SCENARIO:?SCENARIO environment variable is required}"
spec=$(dasel query --in yaml --out json --root < "${spec_path}")
jq -e '.runName | type == "string" and test("\\S") and (test("[\\x00-\\x1f\\x7f]") | not)' <<<"${spec}" >/dev/null ||
  fail "runName must be a nonblank single-line string"
jq -e '.matrix and (has("scenario") | not)' <<<"${spec}" >/dev/null ||
  { echo "FATAL: invalid benchmark configuration" >&2; exit 2; }
run_slug=$(jq -r '.runName | ascii_downcase | gsub("[^a-z0-9_.-]+"; "_") | gsub("^[._-]+|[._-]+$"; "")' <<<"${spec}")
[[ -n "${run_slug}" ]] || fail "runName must contain an ASCII letter or digit for the result tag"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${run_slug}-${scenario}"
(( ${#run_id} <= 128 )) || fail "runName is too long: the generated result tag exceeds 128 characters"

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/kubectl-read.sh"

resource_group=$(tofu -chdir="${repository_root}/iac/azure" output -raw resource_group_name)
metadata=$(tofu -chdir="${repository_root}/iac/azure" output -json scenarios |
  jq -ce --arg scenario "${scenario}" '.[$scenario] // error("unknown deployment scenario")') ||
  fail "benchmark scenario '${scenario}' is not a deployed topology"

case "${scenario}" in
  s4-k8s-pod-*|s5-traefik-passthrough-*|s6-traefik-terminate-*|c4-k8s-pod-*)
    kubeconfig_path="${repository_root}/results/kubeconfig"
    release="wtt-workload"
    [[ -f "${kubeconfig_path}" ]] ||
      fail "Kubernetes kubeconfig is unavailable at ${kubeconfig_path}; run make apply first"

    case "${scenario}" in
      s4-k8s-pod-*|c4-k8s-pod-*)
        target_ip=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get service "${release}" \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        [[ -n "${target_ip}" ]] ||
          fail "Kubernetes Service ${release} does not have a load balancer IP"
        ;;
      s5-traefik-passthrough-*|s6-traefik-terminate-*)
        target_ip=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get gateway "${release}-gateway" \
          -o jsonpath='{.status.addresses[0].value}')
        [[ -n "${target_ip}" ]] ||
          fail "Kubernetes Gateway ${release}-gateway does not have a client-facing address"
        ;;
    esac

    deployment=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get configmap "${release}-config" -o json |
      jq -ce '.data["config.json"] | fromjson') ||
      fail "Kubernetes workload configuration is unavailable for ${release}"

    image_status=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get pods \
      -l "app.kubernetes.io/instance=${release},app.kubernetes.io/name=workload" \
      -o json | jq -er '
        [.items[]
         | select(.status.phase == "Running") as $pod
         | $pod.status.containerStatuses[]?
         | select(.name == "server" and .ready)
         | {
             imageReference: ($pod.spec.containers[] | select(.name == "server") | .image),
             imageID: .imageID
           }]
        | first // error("no ready server pod image status")') ||
      fail "Kubernetes workload ${release} has no ready server pod"
    image_id=$(jq -er '.imageID' <<<"${image_status}")
    image_reference=$(jq -er '.imageReference' <<<"${image_status}")
    digest="${image_id##*@}"
    [[ "${digest}" == sha256:* ]] ||
      fail "Kubernetes workload ${release} returned an invalid image ID: ${image_id}"

    port=$(jq -er 'if .tls.enabled then .tls.port else .plaintextPort end' <<<"${deployment}")
    tls_enabled=$(jq -r '.tls.enabled' <<<"${deployment}")
    tls_version=$(jq -er 'if .tls.enabled then .tls.version else "none" end' <<<"${deployment}")
    tls_group=$(jq -er 'if .tls.enabled then .tls.group // "P-256" else "none" end' <<<"${deployment}")
    if [[ "${scenario}" == s6-traefik-terminate-* ]]; then
      gateway=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get gateway "${release}-gateway" -o json)
      port=$(jq -er '.spec.listeners[] | select(.name == "https-terminate") | .port' <<<"${gateway}")
      tls_option=$(kubectl_read --kubeconfig "${kubeconfig_path}" -n wtt get tlsoption default -o json)
      tls_enabled=true
      tls_version=$(jq -er '
        .spec | select(.minVersion == .maxVersion) | .minVersion |
        if . == "VersionTLS12" then "1.2" elif . == "VersionTLS13" then "1.3"
        else error("unsupported Traefik TLS version") end' <<<"${tls_option}")
      tls_group=$(jq -er '
        .spec.curvePreferences |
        if . == ["CurveP256"] then "P-256" elif . == ["X25519"] then "X25519"
        else error("Traefik must restrict exactly one supported TLS group") end' <<<"${tls_option}")
    fi
    ;;
  s1-iis-netfx)
    server_vmss=$(tofu -chdir="${repository_root}/iac/azure" output -raw windows_iis_vmss_name)
    target_ip=$(tofu -chdir="${repository_root}/iac/azure" output -raw load_balancer_ip)
    [[ -n "${server_vmss}" && "${server_vmss}" != null && -n "${target_ip}" && "${target_ip}" != null ]] ||
      fail "Windows server or load balancer is unavailable"
    deployment_output=$(az vmss run-command invoke \
      --resource-group "${resource_group}" --name "${server_vmss}" --instance-id 0 \
      --command-id RunPowerShellScript \
      --scripts 'Write-Output ("WTT_DEPLOYMENT_JSON=" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content -Raw C:\wtt\deployment.json))))' \
      --query 'value[].message' --output tsv)
    deployment=$(grep -o 'WTT_DEPLOYMENT_JSON=[^[:space:]]*' <<<"${deployment_output}" |
      tail -1 | cut -d= -f2- | base64 --decode)
    digest=$(jq -er '.imageDigest' <<<"${deployment}")
    image_reference=$(jq -r '.image // "not-containerized"' <<<"${deployment}")
    port=$(jq -er '.activePort' <<<"${deployment}")
    tls_enabled=$(jq -r '.tlsEnabled' <<<"${deployment}")
    tls_version=$(jq -er '.tlsVersion' <<<"${deployment}")
    tls_group=$(jq -er '.tlsGroup' <<<"${deployment}")
    ;;
  *)
    server_vmss=$(tofu -chdir="${repository_root}/iac/azure" output -raw linux_app_vmss_name)
    target_ip=$(tofu -chdir="${repository_root}/iac/azure" output -raw load_balancer_ip)
    [[ -n "${server_vmss}" && "${server_vmss}" != null && -n "${target_ip}" && "${target_ip}" != null ]] ||
      fail "standalone server or load balancer is unavailable"

    deployment_output=$(az vmss run-command invoke \
      --resource-group "${resource_group}" --name "${server_vmss}" --instance-id 0 \
      --command-id RunShellScript \
      --scripts 'printf WTT_DEPLOYMENT_JSON=; base64 -w 0 /etc/wtt/deployment.json' \
      --query 'value[].message' --output tsv)
    deployment=$(grep -o 'WTT_DEPLOYMENT_JSON=[^[:space:]]*' <<<"${deployment_output}" |
      tail -1 | cut -d= -f2- | base64 --decode)

    digest=$(jq -er '.imageDigest' <<<"${deployment}")
    image_reference=$(jq -er '.image' <<<"${deployment}")
    port=$(jq -er '.activePort' <<<"${deployment}")
    tls_enabled=$(jq -r '.tlsEnabled' <<<"${deployment}")
    tls_version=$(jq -er '.tlsVersion' <<<"${deployment}")
    tls_group=$(jq -er 'if .tlsEnabled then .tlsGroup // "P-256" else "none" end' <<<"${deployment}")
    ;;
esac

jq -e --arg group "${tls_group}" '
  (has("tlsGroup") | not) or .tlsGroup == $group
' <<<"${spec}" >/dev/null || fail "benchmark tlsGroup differs from deployed client-facing group"
[[ "${tls_group}" == P-256 || "${tls_group}" == X25519 || ( "${tls_group}" == none && "${tls_enabled}" == false ) ]] ||
  fail "deployment has an unsupported TLS group"

jq -cn \
  --argjson spec "${spec}" \
  --arg scenario "${scenario}" \
  --arg ip "${target_ip}" \
  --arg run_id "${run_id}" \
  --arg digest "${digest}" \
  --arg image_reference "${image_reference}" \
  --arg hostname "$(jq -r '.hostname' <<<"${metadata}")" \
  --arg stack "$(jq -r '.stack' <<<"${metadata}")" \
  --arg termination "$(jq -r '.tls_terminated_at' <<<"${metadata}")" \
  --argjson port "${port}" \
  --argjson tls_enabled "${tls_enabled}" \
  --arg tls_version "${tls_version}" \
  --arg tls_group "${tls_group}" \
  '$spec + {runId: $run_id, target: {hostname: $hostname, ip: $ip, port: $port, tls: $tls_enabled, tlsVersion: $tls_version, tlsGroup: $tls_group}, workload: {scenario: $scenario, stack: $stack, tlsTerminatedAt: $termination, imageReference: $image_reference, imageDigest: $digest}}'

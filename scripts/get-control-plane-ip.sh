#!/usr/bin/env bash
set -euo pipefail

repository_root="${1:?repository root is required}"
iac_directory="${repository_root}/iac/azure"

resource_group_name=$(tofu -chdir="${iac_directory}" output -raw resource_group_name)
control_plane_vmss_name=$(tofu -chdir="${iac_directory}" output -raw control_plane_vmss_name)

control_plane_ip=$(
  az vmss nic list \
    --resource-group "${resource_group_name}" \
    --vmss-name "${control_plane_vmss_name}" \
    --query '[0].ipConfigurations[0].privateIPAddress' \
    --output tsv
)

[[ -n "${control_plane_ip}" ]] || {
  echo "FATAL: Unable to resolve the Azure control-plane private IP" >&2
  exit 1
}

printf '%s\n' "${control_plane_ip}"

#!/usr/bin/env bash
set -euo pipefail

registry="${1:?ACR login server is required}"
tag="${2:?Immutable artifact tag is required}"

[[ "${tag}" != "latest" ]] ||
  { echo "FATAL: latest is not an allowed artifact tag" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
registry_name="${registry%.azurecr.io}"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

dotnet publish "${script_dir}/netfx48-server.csproj" \
  --configuration Release \
  --output "${work_dir}/publish"

mkdir -p "${work_dir}/package/bin"
cp "${work_dir}/publish/NetFx48Server.dll" "${work_dir}/package/bin/"
cp "${script_dir}/web.config" "${work_dir}/package/"

(cd "${work_dir}/package" && zip -q -r "${work_dir}/netfx48-server.zip" .)

token=$(az acr login \
  --name "${registry_name}" \
  --expose-token \
  --query accessToken \
  --output tsv)
printf '%s' "${token}" |
  oras login "${registry}" \
    --username 00000000-0000-0000-0000-000000000000 \
    --password-stdin

(
  cd "${work_dir}"
  oras push \
    --artifact-type application/vnd.wtt.netfx48.package.v1 \
    "${registry}/wtt/netfx48-server:${tag}" \
    "netfx48-server.zip:application/zip"
)

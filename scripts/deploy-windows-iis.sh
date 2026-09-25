#!/usr/bin/env bash
set -euo pipefail

resource_group="${1:?Resource group is required}"
vmss_name="${2:?VMSS name is required}"
registry="${3:?ACR login server is required}"
tag="${4:?Artifact tag is required}"
key_vault_name="${5:?Key Vault name is required}"
tls_version="${6:?TLS version is required}"
payload_preallocate="${7:?Payload preallocation flag is required}"
tls_group="${8:-P-256}"
[[ "${tls_version}" == 1.2 ]] ||
  { echo "FATAL: netfx48 supports TLS 1.2 only" >&2; exit 1; }
[[ "${tls_group}" == P-256 || "${tls_group}" == X25519 ]] ||
  { echo "FATAL: TLS group must be P-256 or X25519" >&2; exit 1; }

# Set up cloud-specific paths and an isolated temporary certificate workspace.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
remote_script="${script_dir}/../iac/bootstrap/cloud/azure/configure-windows-iis.ps1"
common_script="${script_dir}/../iac/bootstrap/node/configure-windows-iis.ps1"
registry_name="${registry%.azurecr.io}"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT

# Retrieve the shared PEM certificate and create a passwordless PFX for IIS.
az keyvault secret show \
  --vault-name "${key_vault_name}" \
  --name wtt-server-cert \
  --query value \
  --output tsv > "${work_dir}/tls.crt"
az keyvault secret show \
  --vault-name "${key_vault_name}" \
  --name wtt-server-key \
  --query value \
  --output tsv > "${work_dir}/tls.key"
chmod 0600 "${work_dir}/tls.crt" "${work_dir}/tls.key"

cat > "${work_dir}/create-pfx.ps1" <<'POWERSHELL'
$ErrorActionPreference = "Stop"
$certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
    "/work/tls.crt",
    "/work/tls.key"
)
$pfx = $certificate.Export(
    [Security.Cryptography.X509Certificates.X509ContentType]::Pfx,
    ""
)
[IO.File]::WriteAllBytes("/work/tls.pfx", $pfx)
POWERSHELL
podman run --rm \
  --volume "${work_dir}:/work:Z" \
  mcr.microsoft.com/powershell \
  pwsh -NoProfile -File /work/create-pfx.ps1
base64 -w 0 "${work_dir}/tls.pfx" > "${work_dir}/tls.pfx.base64"
az keyvault secret set \
  --vault-name "${key_vault_name}" \
  --name wtt-server-pfx \
  --file "${work_dir}/tls.pfx.base64" \
  --encoding utf-8 \
  --output none

# Publish the cloud-neutral IIS bootstrap as a versioned OCI artifact in ACR.
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
  cd "$(dirname "${common_script}")"
  oras push \
    --artifact-type application/vnd.wtt.windows-iis-bootstrap.v1 \
    "${registry}/wtt/windows-iis-bootstrap:${tag}" \
    "configure-windows-iis.ps1:application/vnd.microsoft.powershell"
)

# Invoke the Azure adapter on VMSS instance 0 and require its success sentinel.
output=$(az vmss run-command invoke \
  --resource-group "${resource_group}" \
  --name "${vmss_name}" \
  --instance-id 0 \
  --command-id RunPowerShellScript \
  --scripts "@${remote_script}" \
  --parameters \
    "KeyVaultName=${key_vault_name}" \
    "Registry=${registry}" \
    "ArtifactRepository=wtt/netfx48-server" \
    "ArtifactTag=${tag}" \
    "CommonScriptRepository=wtt/windows-iis-bootstrap" \
    "TlsVersion=${tls_version}" \
    "TlsGroup=${tls_group}" \
    "PayloadPreallocate=${payload_preallocate}" \
  --query 'value[].message' \
  --output tsv)
printf '%s\n' "${output}"
grep -q 'WTT_WINDOWS_DEPLOY_OK=1' <<< "${output}" ||
  { echo "FATAL: Windows VMSS deployment did not complete successfully" >&2; exit 1; }

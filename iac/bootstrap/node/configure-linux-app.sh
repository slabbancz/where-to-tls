#!/usr/bin/env bash
set -euo pipefail

image="${1:?Container image is required}"
tls_enabled="${2:?TLS enabled flag is required}"
tls_version="${3:?TLS version is required}"
payload_preallocate="${4:?Payload preallocation flag is required}"
tls_handshake_timeout_seconds="${5:?TLS handshake timeout seconds is required}"
http_request_timeout_seconds="${6:?HTTP request timeout seconds is required}"
tls_group="${7:-P-256}"
java_tls_provider="${8:-boringssl}"

# Validate deployment inputs before reading secrets or changing the host.
[[ "${tls_group}" == P-256 || "${tls_group}" == X25519 ]] ||
  { echo "FATAL: TLS group must be P-256 or X25519" >&2; exit 1; }
[[ "${java_tls_provider}" == boringssl || "${java_tls_provider}" == jdk ]] ||
  { echo "FATAL: Java TLS provider must be boringssl or jdk" >&2; exit 1; }
[[ "${tls_enabled}" == "true" || "${tls_enabled}" == "false" ]] ||
  { echo "FATAL: TLS enabled must be true or false" >&2; exit 1; }
[[ "${tls_version}" == "1.2" || "${tls_version}" == "1.3" ]] ||
  { echo "FATAL: TLS version must be 1.2 or 1.3" >&2; exit 1; }
[[ "${payload_preallocate}" == "true" || "${payload_preallocate}" == "false" ]] ||
  { echo "FATAL: payload preallocation must be true or false" >&2; exit 1; }
for timeout in "${tls_handshake_timeout_seconds}" "${http_request_timeout_seconds}"; do
  [[ "${timeout}" =~ ^[1-9][0-9]*$ ]] && ((timeout <= 300)) ||
    { echo "FATAL: timeout seconds must be an integer from 1 through 300" >&2; exit 1; }
done

source /etc/wtt/bootstrap.env

is_java=false
case "${image}" in
  */java-netty-server:*) is_java=true ;;
esac
if [[ "${is_java}" == true && "${java_tls_provider}" == jdk && "${tls_group}" == X25519 ]]; then
  echo "FATAL: Java JDK/JSSE cannot exact-pin X25519 with the P-256 ECDSA server certificate; use JAVA_TLS_PROVIDER=boringssl for X25519 or TLS_GROUP=P-256 for JAVA_TLS_PROVIDER=jdk" >&2
  exit 1
fi

# Wait for first-boot setup, then materialize the runtime server configuration.
if ! cloud-init status --wait; then
  echo "WARN: cloud-init completed with errors; continuing with explicit runtime deployment" >&2
  journalctl --boot \
    --unit cloud-init-local \
    --unit cloud-init \
    --unit cloud-config \
    --unit cloud-final \
    --priority err..alert \
    --no-pager \
    --output short-iso >&2 || true
fi
mkdir -p /etc/wtt

if [[ "${tls_enabled}" == "true" ]]; then
  mkdir -p /etc/wtt/tls
  /opt/wtt/bootstrap/cloud/get-secret.sh wtt-server-cert > /etc/wtt/tls/tls.crt
  /opt/wtt/bootstrap/cloud/get-secret.sh wtt-server-key > /etc/wtt/tls/tls.key
  chmod 0644 /etc/wtt/tls/tls.crt
  chmod 0644 /etc/wtt/tls/tls.key

  jq -n \
    --arg version "${tls_version}" \
    --arg group "${tls_group}" \
    --arg provider "${java_tls_provider}" \
    --argjson is_java "${is_java}" \
    --argjson tls_handshake_timeout_seconds "${tls_handshake_timeout_seconds}" \
    --argjson http_request_timeout_seconds "${http_request_timeout_seconds}" \
    --argjson preallocate "${payload_preallocate}" \
    '{
      plaintextPort: 8080,
      tls: ({
        enabled: true,
        port: 8443,
        version: $version,
        group: $group,
        certFile: "/etc/wtt/tls/tls.crt",
        keyFile: "/etc/wtt/tls/tls.key",
        resumption: false
      } + (if $is_java then {provider: $provider} else {} end)),
      payload: {preallocate: $preallocate},
      timeouts: {
        tlsHandshakeSeconds: $tls_handshake_timeout_seconds,
        httpRequestSeconds: $http_request_timeout_seconds
      }
    }' > /etc/wtt/config.json
else
  jq -n \
    --argjson preallocate "${payload_preallocate}" \
    --argjson tls_handshake_timeout_seconds "${tls_handshake_timeout_seconds}" \
    --argjson http_request_timeout_seconds "${http_request_timeout_seconds}" \
    '{
      plaintextPort: 8080,
      tls: {enabled: false},
      payload: {preallocate: $preallocate},
      timeouts: {
        tlsHandshakeSeconds: $tls_handshake_timeout_seconds,
        httpRequestSeconds: $http_request_timeout_seconds
      }
    }' \
    > /etc/wtt/config.json
fi

chmod 0644 /etc/wtt/config.json

# Pull the requested image with the VM identity's repository-scoped ACR token.
docker_config=$(/opt/wtt/bootstrap/cloud/get-secret.sh acr-pull-dockerconfigjson)
registry=$(jq -r '.auths | keys[0]' <<<"${docker_config}")
username=$(jq -r --arg registry "${registry}" '.auths[$registry].username' <<<"${docker_config}")
password=$(jq -r --arg registry "${registry}" '.auths[$registry].password' <<<"${docker_config}")

[[ "${image}" == "${registry}/"* ]] ||
  { echo "FATAL: image ${image} is not hosted by configured registry ${registry}" >&2; exit 1; }

printf '%s' "${password}" |
  podman login "${registry}" --username "${username}" --password-stdin
podman pull "${image}"
image_digest=$(
  podman image inspect --format '{{index .RepoDigests 0}}' "${image}" |
    sed 's/^.*@//'
)
[[ "${image_digest}" == sha256:* ]] ||
  { echo "FATAL: unable to resolve immutable digest for ${image}" >&2; exit 1; }

jq -n \
  --arg image "${image}" \
  --arg digest "${image_digest}" \
  --arg version "${tls_version}" \
  --arg group "${tls_group}" \
  --argjson tls_enabled "${tls_enabled}" \
  --argjson tls_handshake_timeout_seconds "${tls_handshake_timeout_seconds}" \
  --argjson http_request_timeout_seconds "${http_request_timeout_seconds}" \
  '{
    image: $image,
    imageDigest: $digest,
    tlsEnabled: $tls_enabled,
    tlsVersion: (if $tls_enabled then $version else "none" end),
    tlsGroup: (if $tls_enabled then $group else "none" end),
    plaintextPort: 8080,
    tlsPort: 8443,
    activePort: (if $tls_enabled then 8443 else 8080 end),
    tlsHandshakeTimeoutSeconds: $tls_handshake_timeout_seconds,
    httpRequestTimeoutSeconds: $http_request_timeout_seconds
  }' > /etc/wtt/deployment.json
chmod 0644 /etc/wtt/deployment.json

# Create a restartable host-network service using the generated configuration.
cat > /etc/systemd/system/wtt-app.service <<EOF
[Unit]
Description=Where-To-TLS benchmark server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm --force wtt-app
ExecStart=/usr/bin/podman run --name wtt-app --network host --cpu-shares=3500 --env WTT_TLS_GROUP=${tls_group} --volume /etc/wtt/config.json:/etc/wtt/config.json:ro --volume /etc/wtt/tls:/etc/wtt/tls:ro ${image}
ExecStop=/usr/bin/podman stop --time 10 wtt-app
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/wtt/tls
systemctl daemon-reload
systemctl enable wtt-app.service
systemctl restart wtt-app.service

# Do not report deployment success until the active listener responds. TLS
# metadata is connection-specific, so query it over HTTPS when TLS is enabled.
if [[ "${tls_enabled}" == "true" ]]; then
  health_url="https://127.0.0.1:8443/healthz"
  meta_url="https://127.0.0.1:8443/meta"
  curl_options=(--insecure --http1.1 --tlsv"${tls_version}" --tls-max "${tls_version}")
  [[ "${tls_version}" != 1.2 ]] || curl_options+=(--ciphers ECDHE-ECDSA-AES128-GCM-SHA256)
  case "${tls_group}" in
    P-256) curl_options+=(--curves prime256v1) ;;
    X25519) curl_options+=(--curves X25519:prime256v1) ;;
  esac
else
  health_url="http://127.0.0.1:8080/healthz"
  meta_url="http://127.0.0.1:8080/meta"
  curl_options=()
fi

for _ in $(seq 1 30); do
  if curl --fail --silent "${curl_options[@]}" "${health_url}" >/dev/null; then
    printf 'WTT_HEALTHZ=%s\n' "$(curl --fail --silent "${curl_options[@]}" "${health_url}")"
    printf 'WTT_META=%s\n' "$(curl --fail --silent "${curl_options[@]}" "${meta_url}")"
    echo "WTT_LINUX_DEPLOY_OK=1"
    exit 0
  fi
  sleep 2
done

systemctl status wtt-app.service --no-pager --full >&2
exit 1

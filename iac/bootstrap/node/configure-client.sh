#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env

update-ca-certificates

install -d -m 0755 /etc/sysctl.d
# Extend socket port range so the client can establish many concurrent connections
cat > /etc/sysctl.d/90-wtt-fresh-connection.conf <<'EOF'
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl --system
/opt/wtt/bootstrap/node/configure-client-source-ips.sh
systemctl daemon-reload
systemctl enable wtt-client-source-ips.service

mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://dl.k6.io/key.gpg |
  gpg --dearmor -o /etc/apt/keyrings/k6-archive-keyring.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  > /etc/apt/sources.list.d/k6.list
apt-get update -y
apt-get install -y k6

oras_version="1.3.0"
curl -fsSL \
  "https://github.com/oras-project/oras/releases/download/v${oras_version}/oras_${oras_version}_linux_amd64.tar.gz" |
  tar -xz -C /usr/local/bin oras

for scenario in \
  s1-iis-netfx s2-vm-net s2-vm-java s2-vm-go s2-vm-rust \
  s4-k8s-pod-net s4-k8s-pod-java s4-k8s-pod-go s4-k8s-pod-rust \
  s5-traefik-passthrough-net s5-traefik-passthrough-java s5-traefik-passthrough-go s5-traefik-passthrough-rust \
  s6-traefik-terminate-net s6-traefik-terminate-java s6-traefik-terminate-go s6-traefik-terminate-rust \
  c2-vm-net-plain c2-vm-java-plain c2-vm-go-plain c2-vm-rust-plain \
  c4-k8s-pod-net-plain c4-k8s-pod-java-plain c4-k8s-pod-go-plain c4-k8s-pod-rust-plain; do
  printf '%s %s.%s\n' "${LOAD_BALANCER_IP}" "${scenario}" "${DNS_ZONE}" >> /etc/hosts
done

#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env

packages=(kubelet="${KUBERNETES_VERSION}-*" kubeadm="${KUBERNETES_VERSION}-*")
if [[ "${INSTALL_KUBECTL:-false}" == "true" ]]; then
  packages+=(kubectl="${KUBERNETES_VERSION}-*")
fi

mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPOSITORY_VERSION}/deb/Release.key" |
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_REPOSITORY_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y "${packages[@]}"
apt-mark hold kubelet kubeadm
if [[ "${INSTALL_KUBECTL:-false}" == "true" ]]; then
  apt-mark hold kubectl
fi

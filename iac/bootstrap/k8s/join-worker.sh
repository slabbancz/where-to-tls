#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env

/opt/wtt/bootstrap/k8s/configure-os.sh
/opt/wtt/bootstrap/k8s/install-containerd.sh
/opt/wtt/bootstrap/k8s/install-kubernetes.sh
/opt/wtt/bootstrap/cloud/configure-cloud-provider.sh

provider_id=$(/opt/wtt/bootstrap/cloud/get-provider-id.sh)
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--cloud-provider=external --provider-id=${provider_id} ${NODE_LABEL_ARGUMENT} ${NODE_TAINT_ARGUMENT}
EOF
systemctl daemon-reload

for attempt in $(seq 1 120); do
  join_command=$(/opt/wtt/bootstrap/cloud/get-secret.sh k8s-join-command)
  if [[ "${join_command}" == *kubeadm* ]] &&
    ${join_command} --node-name="$(hostname)"; then
    exit 0
  fi

  kubeadm reset -f
  echo "Waiting for a valid cluster join command (${attempt}/120)..."
  sleep 10
done

echo "FATAL: unable to join the cluster after 1200 seconds" >&2
exit 1

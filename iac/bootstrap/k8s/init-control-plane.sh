#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env

/opt/wtt/bootstrap/k8s/configure-os.sh
/opt/wtt/bootstrap/k8s/install-containerd.sh
/opt/wtt/bootstrap/k8s/install-kubernetes.sh
systemctl stop kubelet
/opt/wtt/bootstrap/k8s/mount-control-plane-state.sh
/opt/wtt/bootstrap/cloud/configure-cloud-provider.sh

provider_id=$(/opt/wtt/bootstrap/cloud/get-provider-id.sh)
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--cloud-provider=external --provider-id=${provider_id} --node-labels=wtt/pool=cp
EOF
systemctl daemon-reload

primary_ip=$(hostname -I | awk '{print $1}')
extra_sans="${primary_ip}"
if [[ -n "${EXTERNAL_API_IP:-}" ]]; then
  extra_sans="${extra_sans},${EXTERNAL_API_IP}"
fi

if [[ -f /etc/kubernetes/admin.conf && -d /var/lib/etcd/member ]]; then
  systemctl restart containerd kubelet
else
  kubeadm init \
    --patches=/opt/wtt/bootstrap/patches \
    --skip-phases=addon/kube-proxy \
    --pod-network-cidr="${POD_CIDR}" \
    --apiserver-advertise-address="${primary_ip}" \
    --apiserver-cert-extra-sans="${extra_sans}" \
    --node-name="$(hostname)"
fi

mkdir -p /root/.kube "/home/${ADMIN_USERNAME}/.kube"
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf "/home/${ADMIN_USERNAME}/.kube/config"
chown -R "${ADMIN_USERNAME}:${ADMIN_USERNAME}" "/home/${ADMIN_USERNAME}/.kube"

for _ in $(seq 1 60); do
  kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf >/dev/null 2>&1 && break
  sleep 3
done
kubectl get nodes --kubeconfig=/etc/kubernetes/admin.conf >/dev/null

kubeadm token create --print-join-command |
  /opt/wtt/bootstrap/cloud/publish-secret.sh k8s-join-command

if [[ -n "${EXTERNAL_API_IP:-}" && "${EXTERNAL_API_PORT:-0}" != "0" ]]; then
  sed "s|server: https://.*:6443|server: https://${EXTERNAL_API_IP}:${EXTERNAL_API_PORT}|" \
    /etc/kubernetes/admin.conf |
    /opt/wtt/bootstrap/cloud/publish-secret.sh k8s-kubeconfig
else
  /opt/wtt/bootstrap/cloud/publish-secret.sh k8s-kubeconfig < /etc/kubernetes/admin.conf
fi

if [[ -x /opt/wtt/bootstrap/post-bootstrap.sh ]]; then
  /opt/wtt/bootstrap/post-bootstrap.sh
fi

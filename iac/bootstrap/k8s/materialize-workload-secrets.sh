#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG=/etc/kubernetes/admin.conf
export KUBECONFIG

kubectl create namespace wtt --dry-run=client -o yaml | kubectl apply -f -

docker_config=$(/opt/wtt/bootstrap/cloud/get-secret.sh acr-pull-dockerconfigjson)
certificate=$(/opt/wtt/bootstrap/cloud/get-secret.sh wtt-server-cert)
private_key=$(/opt/wtt/bootstrap/cloud/get-secret.sh wtt-server-key)
ca_certificate=$(/opt/wtt/bootstrap/cloud/get-secret.sh ca-cert-pem)

mkdir -p /opt/wtt/tls
printf '%s\n' "${certificate}" > /opt/wtt/tls/tls.crt
printf '%s\n' "${private_key}" > /opt/wtt/tls/tls.key
printf '%s\n' "${ca_certificate}" > /opt/wtt/tls/ca.crt
chmod 0600 /opt/wtt/tls/tls.key

for namespace in default wtt; do
  kubectl create secret generic acr-pull-secret \
    --from-literal=.dockerconfigjson="${docker_config}" \
    --type=kubernetes.io/dockerconfigjson \
    --namespace="${namespace}" \
    --dry-run=client -o yaml |
    kubectl apply -f -

  kubectl create secret generic wtt-tls-secret \
    --type=kubernetes.io/tls \
    --from-file=tls.crt=/opt/wtt/tls/tls.crt \
    --from-file=tls.key=/opt/wtt/tls/tls.key \
    --from-file=ca.crt=/opt/wtt/tls/ca.crt \
    --namespace="${namespace}" \
    --dry-run=client -o yaml |
    kubectl apply -f -

  kubectl create configmap wtt-ca \
    --from-file=ca.crt=/opt/wtt/tls/ca.crt \
    --namespace="${namespace}" \
    --dry-run=client -o yaml |
    kubectl apply -f -
done

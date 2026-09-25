#!/usr/bin/env bash
set -euo pipefail

if [[ "${SSH_ENABLED:-false}" == "true" ]]; then
  /opt/wtt/bootstrap/node/configure-linux-ssh.sh "${ADMIN_USERNAME}"
fi
modprobe overlay
modprobe br_netfilter
sysctl --system

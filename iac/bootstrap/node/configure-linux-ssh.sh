#!/usr/bin/env bash
set -euo pipefail

admin_username="${1:?admin username is required}"
drop_in_directory=/etc/ssh/sshd_config.d

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
install -d -m 0755 "${drop_in_directory}"
cat > "${drop_in_directory}/10-wtt.conf" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ${admin_username}
EOF

sshd -t
systemctl enable --now ssh

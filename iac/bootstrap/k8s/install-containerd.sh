#!/usr/bin/env bash
set -euo pipefail

apt-get update -y
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
systemctl enable --now containerd

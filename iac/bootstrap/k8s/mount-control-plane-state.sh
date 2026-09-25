#!/usr/bin/env bash
set -euo pipefail

source /etc/wtt/bootstrap.env

device="${CONTROL_PLANE_STATE_DEVICE:?Cloud bootstrap must set CONTROL_PLANE_STATE_DEVICE}"
mount_root="/var/lib/wtt-control-plane"

for _ in $(seq 1 60); do
  [[ -b "${device}" ]] && break
  sleep 2
done
[[ -b "${device}" ]] || {
  echo "FATAL: control-plane state disk ${device} was not available" >&2
  exit 1
}

if ! blkid "${device}" >/dev/null 2>&1; then
  mkfs.ext4 -F -L wtt-k8s-state "${device}"
fi

uuid=$(blkid -s UUID -o value "${device}")
mkdir -p "${mount_root}"
grep -q "UUID=${uuid} ${mount_root} " /etc/fstab ||
  printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "${uuid}" "${mount_root}" >> /etc/fstab
mountpoint -q "${mount_root}" || mount "${mount_root}"

for mapping in \
  "etc-kubernetes:/etc/kubernetes" \
  "var-lib-etcd:/var/lib/etcd" \
  "var-lib-kubelet:/var/lib/kubelet"; do
  source_path="${mount_root}/${mapping%%:*}"
  target_path="${mapping#*:}"
  mkdir -p "${source_path}" "${target_path}"
  grep -qF "${source_path} ${target_path} none bind 0 0" /etc/fstab ||
    printf '%s %s none bind 0 0\n' "${source_path}" "${target_path}" >> /etc/fstab
  mountpoint -q "${target_path}" || mount --bind "${source_path}" "${target_path}"
done

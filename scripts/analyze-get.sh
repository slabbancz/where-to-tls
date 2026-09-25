#!/usr/bin/env bash
set -euo pipefail

(( $# > 0 )) || { echo "FATAL: at least one OCI artifact reference is required" >&2; exit 2; }
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
auth_file="${repository_root}/analyze/podman/auth.json"

[[ -r "${auth_file}" ]] ||
  { echo "FATAL: missing ${auth_file}; run 'make podman-login' first" >&2; exit 1; }
command -v oras >/dev/null ||
  { echo "FATAL: oras is required to download benchmark artifacts" >&2; exit 1; }

download_dir=$(mktemp -d)
trap 'rm -rf "${download_dir}"' EXIT

for artifact in "$@"; do
  artifact_dir="${download_dir}/$RANDOM"
  mkdir -p "${artifact_dir}"
  oras pull --registry-config "${auth_file}" "${artifact}" --output "${artifact_dir}"
  archive=$(find "${artifact_dir}" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
  [[ -n "${archive}" ]] ||
    { echo "FATAL: result artifact contains no archive: ${artifact}" >&2; exit 1; }

  record=$(tar -tzf "${archive}" | awk -F/ 'NF && !root { root = $1 } END { print root }')
  [[ "${record}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    { echo "FATAL: artifact has an invalid result directory: ${artifact}" >&2; exit 1; }
  tar -tzf "${archive}" |
    awk -v root="${record}" '
      $0 != root "/" && index($0, root "/") != 1 { invalid = 1 }
      END { exit invalid }
    ' ||
    { echo "FATAL: artifact archive does not contain only record '${record}'" >&2; exit 1; }

  destination="${repository_root}/results/${record}"
  [[ ! -e "${destination}" ]] ||
    { echo "FATAL: destination already exists: ${destination}" >&2; exit 1; }
  mkdir -p "${repository_root}/results"
  tar -xzf "${archive}" -C "${repository_root}/results"
  printf 'WTT_ANALYZE_RECORD=%s artifact=%s\n' "${destination}" "${artifact}"
done

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/debug/copypaste.sh

Prints a shell payload for creating the four-IP TLS diagnostic files in the
current directory. Run this script locally, copy its output, then paste it into
an existing SSH session. Existing remote files are not replaced.

Example:
  ./scripts/debug/copypaste.sh
EOF
}

[[ $# -eq 0 ]] || {
  usage
  exit 2
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
files=(
  client.sh
  server.sh
  capture-network.sh
  client-tls-shutdown.sh
  client-tls-shutdown.js
  client-tls-exhaustion-four-ips.js
)

for file in "${files[@]}"; do
  [[ -f "${script_dir}/${file}" ]] || {
    printf 'FATAL: required file is missing: %s\n' "${script_dir}/${file}" >&2
    exit 1
  }
done

printf '%s\n' 'set -euo pipefail'
printf '%s\n' 'umask 077'
printf '%s\n' 'for file in client.sh server.sh capture-network.sh client-tls-shutdown.sh client-tls-shutdown.js client-tls-exhaustion-four-ips.js; do'
printf '%s\n' '  [[ ! -e "${file}" ]] || { printf "FATAL: refusing to overwrite %s\n" "${file}" >&2; exit 1; }'
printf '%s\n' 'done'

for file in "${files[@]}"; do
  printf 'base64 --decode > %q <<%q\n' "${file}" 'WTT_COPYPASTE_FILE'
  base64 -w 0 "${script_dir}/${file}"
  printf '\n%s\n' 'WTT_COPYPASTE_FILE'
  case "${file}" in
    *.sh) printf 'chmod 700 %q\n' "${file}" ;;
  esac
done
printf '%s\n' "printf 'WTT_COPYPASTE_READY: copied ${#files[@]} files to %s\\n' \"\$(pwd)\""
printf '%s\n' "printf 'WTT_COPYPASTE_READY: copied ${#files[@]} files to %s\\n' \"\$(pwd)\""

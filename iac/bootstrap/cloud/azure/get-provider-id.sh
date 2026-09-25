#!/usr/bin/env bash
set -euo pipefail

resource_id=$(
  curl -fsS \
    -H Metadata:true \
    "http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2025-04-07&format=text"
)

[[ -n "${resource_id}" ]] || {
  echo "FATAL: Azure IMDS returned an empty VM resource ID" >&2
  exit 1
}

printf 'azure://%s\n' "${resource_id}"

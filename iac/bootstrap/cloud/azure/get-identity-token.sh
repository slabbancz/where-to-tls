#!/usr/bin/env bash
set -euo pipefail

resource="${1:?resource URI is required}"
encoded_resource=$(printf '%s' "${resource}" | jq -sRr @uri)

curl -fsS \
  -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${encoded_resource}" |
  jq -er '.access_token'

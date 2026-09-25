#!/usr/bin/env bash

kubectl_read() {
  local attempts="${WTT_KUBECTL_READ_ATTEMPTS:-5}"
  local delay_seconds="${WTT_KUBECTL_READ_DELAY_SECONDS:-5}"
  local request_timeout="${WTT_KUBECTL_READ_REQUEST_TIMEOUT:-15s}"
  local attempt output status

  [[ "${attempts}" =~ ^[1-9][0-9]*$ ]] ||
    { echo "FATAL: WTT_KUBECTL_READ_ATTEMPTS must be a positive integer" >&2; return 2; }
  [[ "${delay_seconds}" =~ ^[0-9]+$ ]] ||
    { echo "FATAL: WTT_KUBECTL_READ_DELAY_SECONDS must be a non-negative integer" >&2; return 2; }

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if output=$(kubectl --request-timeout="${request_timeout}" "$@" 2>&1); then
      printf '%s' "${output}"
      return 0
    else
      status=$?
    fi

    case "${output}" in
      *"Unable to connect to the server"*|*"i/o timeout"*|*"TLS handshake timeout"*|\
      *"connection refused"*|*"connection reset by peer"*|*"context deadline exceeded"*|\
      *"the server is currently unable to handle the request"*|*"Service Unavailable"*|\
      *"Too Many Requests"*|*"unexpected EOF"*)
        ;;
      *)
        printf '%s\n' "${output}" >&2
        return "${status}"
        ;;
    esac

    if ((attempt == attempts)); then
      printf '%s\n' "${output}" >&2
      echo "FATAL: Kubernetes API read failed after ${attempts} attempts" >&2
      return "${status}"
    fi

    echo "WARN: Kubernetes API read failed transiently; retrying in ${delay_seconds}s (${attempt}/${attempts})" >&2
    sleep "${delay_seconds}"
  done
}

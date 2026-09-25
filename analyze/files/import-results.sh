#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--skip-warmup] (--results-dir <path> | --artifact-dir <path> | --artifact-image <reference>)" >&2
  echo "Or set exactly one of IMPORT_RESULTS_DIR, IMPORT_ARTIFACT_DIR, IMPORT_ARTIFACT_IMAGE, or IMPORT_ARTIFACT_IMAGES." >&2
  echo "Requires INFLUX_URL, INFLUX_ORG, INFLUX_BUCKET, and INFLUX_TOKEN." >&2
  exit 2
}

: "${INFLUX_URL:?INFLUX_URL is required}"
: "${INFLUX_ORG:?INFLUX_ORG is required}"
: "${INFLUX_BUCKET:?INFLUX_BUCKET is required}"
: "${INFLUX_TOKEN:?INFLUX_TOKEN is required}"

import_workers="${IMPORT_WORKERS:-16}"
case "${import_workers}" in
  '' | *[!0-9]* | 0)
    echo "FATAL: IMPORT_WORKERS must be a positive integer" >&2
    exit 2
    ;;
esac

skip_warmup="${IMPORT_SKIP_WARMUP:-false}"
case "${skip_warmup}" in
  true | false) ;;
  *)
    echo "FATAL: IMPORT_SKIP_WARMUP must be exactly true or false" >&2
    exit 2
    ;;
esac

input_dirs=()
artifact_dirs=()
artifact_images=()
while (($#)); do
  case "$1" in
    --results-dir) input_dirs+=("${2:?--results-dir requires a path}"); shift 2 ;;
    --artifact-dir) artifact_dirs+=("${2:?--artifact-dir requires a path}"); shift 2 ;;
    --artifact-image) artifact_images+=("${2:?--artifact-image requires a reference}"); shift 2 ;;
    --skip-warmup) skip_warmup=true; shift ;;
    *) usage ;;
  esac
done

if (( ${#input_dirs[@]} + ${#artifact_dirs[@]} + ${#artifact_images[@]} == 0 )); then
  [[ -n "${IMPORT_RESULTS_DIR:-}" ]] && input_dirs+=("${IMPORT_RESULTS_DIR}")
  [[ -n "${IMPORT_ARTIFACT_DIR:-}" ]] && artifact_dirs+=("${IMPORT_ARTIFACT_DIR}")
  [[ -n "${IMPORT_ARTIFACT_IMAGE:-}" ]] && artifact_images+=("${IMPORT_ARTIFACT_IMAGE}")
  if [[ -n "${IMPORT_ARTIFACT_IMAGES:-}" ]]; then
    artifact_image_values=${IMPORT_ARTIFACT_IMAGES//$'\n'/ }
    read -r -a configured_artifact_images <<<"${artifact_image_values}"
    artifact_images+=("${configured_artifact_images[@]}")
  fi
fi

if (( (${#input_dirs[@]} > 0) + (${#artifact_dirs[@]} > 0) + (${#artifact_images[@]} > 0) > 1 )); then
  echo "FATAL: configure exactly one result input source" >&2
  exit 2
fi
(( ${#input_dirs[@]} + ${#artifact_dirs[@]} + ${#artifact_images[@]} > 0 )) || usage

temporary_dir=$(mktemp -d)
trap 'rm -rf "${temporary_dir}"' EXIT

artifact_digest() {
  local artifact_image="$1"
  local descriptor

  descriptor=$(oras manifest fetch "${oras_args[@]}" --descriptor "${artifact_image}")
  printf '%s' "${descriptor}" |
    sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

artifact_was_imported() {
  local digest="$1"
  local query

  query=$(cat <<EOF
from(bucket: "${INFLUX_BUCKET}")
  |> range(start: 1970-01-01T00:00:00Z)
  |> filter(fn: (r) => r._measurement == "wtt_import_artifact" and r.manifest_digest == "${digest}" and r.schema_version == "raw-v1" and r.skip_warmup == "${skip_warmup}")
  |> last()
EOF
)

  curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Token ${INFLUX_TOKEN}" \
    --header 'Content-Type: application/vnd.flux' \
    --data "${query}" \
    "${INFLUX_URL}/api/v2/query?org=${INFLUX_ORG}" |
    grep -qF "${digest}"
}

record_artifact_import() {
  local artifact_image="$1"
  local digest="$2"
  local escaped_image

  escaped_image=$(printf '%s' "${artifact_image}" | sed 's/[ ,=\\]/\\&/g')
  curl --fail --silent --show-error \
    --request POST \
    --header "Authorization: Token ${INFLUX_TOKEN}" \
    --data-binary "wtt_import_artifact,manifest_digest=${digest},artifact_image=${escaped_image},schema_version=raw-v1,skip_warmup=${skip_warmup} completed=true" \
    "${INFLUX_URL}/api/v2/write?org=${INFLUX_ORG}&bucket=${INFLUX_BUCKET}&precision=s"
}

# Fetch OCI result artifacts when the runtime does not support image volumes.
oras_args=()
[[ -n "${ORAS_REGISTRY_CONFIG:-}" ]] && oras_args+=(--registry-config "${ORAS_REGISTRY_CONFIG}")
imported_artifact_images=()
imported_artifact_digests=()
artifact_pull_args="${temporary_dir}/artifact-pulls.args"
for artifact_image in "${artifact_images[@]}"; do
  digest=$(artifact_digest "${artifact_image}")
  [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]] || {
    echo "FATAL: unable to resolve a valid manifest digest for ${artifact_image}" >&2
    exit 1
  }
  if artifact_was_imported "${digest}"; then
    echo "WTT_IMPORT_SKIPPED=already-imported artifact=${artifact_image} digest=${digest}" >&2
    continue
  fi

  artifact_dir="${temporary_dir}/artifact-${#artifact_dirs[@]}"
  mkdir -p "${artifact_dir}"
  printf '%s\0%s\0' "${artifact_image}" "${artifact_dir}" >>"${artifact_pull_args}"
  artifact_dirs+=("${artifact_dir}")
  imported_artifact_images+=("${artifact_image}")
  imported_artifact_digests+=("${digest}")
done

if [[ -s "${artifact_pull_args}" ]]; then
  xargs -0 -r -P "${import_workers}" -n 2 \
    bash -c '
      set -euo pipefail
      artifact_image="$1"
      artifact_dir="$2"
      oras_args=()
      [[ -n "${ORAS_REGISTRY_CONFIG:-}" ]] && oras_args+=(--registry-config "${ORAS_REGISTRY_CONFIG}")
      oras pull "${oras_args[@]}" "${artifact_image}" --output "${artifact_dir}"
    ' _ <"${artifact_pull_args}"
fi

# OCI result archives are either staged by ORAS or supplied from a local volume.
for artifact_dir in "${artifact_dirs[@]}"; do
  archive=$(find "${artifact_dir}" -type f -name '*.tar.gz' -print -quit)
  [[ -n "${archive}" ]] || { echo "FATAL: ${artifact_dir} contains no result archive" >&2; exit 1; }
  extract_dir="${temporary_dir}/$(basename "${artifact_dir}")"
  mkdir -p "${extract_dir}"
  tar -xzf "${archive}" -C "${extract_dir}"
  input_dirs+=("${extract_dir}")
done

python_args=()
for input_dir in "${input_dirs[@]}"; do
  python_args+=(--results-dir "${input_dir}")
done

if (( ${#python_args[@]} == 0 )); then
  echo "WTT_IMPORT_SKIPPED=all-requested-artifacts-already-imported" >&2
  exit 0
fi

if [[ "${skip_warmup}" == true ]]; then
  python_args+=(--skip-warmup)
fi

python3 /scripts/import-results.py --workers "${import_workers}" "${python_args[@]}"

for index in "${!imported_artifact_images[@]}"; do
  record_artifact_import "${imported_artifact_images[index]}" "${imported_artifact_digests[index]}"
  artifact_image="${imported_artifact_images[index]}"
  digest="${imported_artifact_digests[index]}"
  echo "WTT_IMPORT_RECORDED=artifact=${artifact_image} digest=${digest}" >&2
done

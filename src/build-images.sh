#!/usr/bin/env bash
set -euo pipefail

# Build and push script for where-to-tls server container images
# Conforms to docs/CONTRACT.md §4:
# - Images are built locally with podman and pushed to ACR.
# - ACR authentication uses short-lived token: az acr login --expose-token.
# - 'latest' tag is forbidden; immutable git-SHA required.
# - No .NET FW image (runs on IIS on a VM).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY=""
TAG=""
BUILD_ONLY=false
PUSH=false
DOTNET_AOT=false
IMAGE_BASE=deb

readonly GO_RUNTIME_IMAGE="gcr.io/distroless/static:latest"

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-base)
      IMAGE_BASE="${2:?--image-base requires alpine or deb}"
      shift 2
      ;;
    --dotnet-aot)
      DOTNET_AOT="${2:?--dotnet-aot requires true or false}"
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    --push)
      PUSH=true
      shift
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    *)
      if [[ -z "${REGISTRY}" ]]; then
        REGISTRY="$1"
      elif [[ -z "${TAG}" ]]; then
        TAG="$1"
      elif [[ "$1" == "--push" || "$1" == "true" ]]; then
        PUSH=true
      fi
      shift
      ;;
  esac
done

case "${DOTNET_AOT}" in
  true|false) ;;
  *) echo "ERROR: --dotnet-aot must be true or false." >&2; exit 1 ;;
esac

case "${IMAGE_BASE}" in
  alpine)
    DOTNET_IMAGEBASE=alpine
    JAVA_IMAGEBASE=alpine
    GO_IMAGEBASE=alpine
    RUST_IMAGEBASE=alpine
    ;;
  deb)
    DOTNET_IMAGEBASE=resolute
    JAVA_IMAGEBASE=resolute
    GO_IMAGEBASE=trixie
    RUST_IMAGEBASE=trixie
    ;;
  *) echo "ERROR: --image-base must be alpine or deb." >&2; exit 1 ;;
esac

readonly NET10_JIT_RUNTIME_IMAGE="mcr.microsoft.com/dotnet/aspnet:10.0-${DOTNET_IMAGEBASE}"
readonly NET10_AOT_RUNTIME_IMAGE="mcr.microsoft.com/dotnet/runtime-deps:10.0-${DOTNET_IMAGEBASE}"
readonly NET11_JIT_RUNTIME_IMAGE="mcr.microsoft.com/dotnet/aspnet:11.0-${DOTNET_IMAGEBASE}"
readonly NET11_AOT_RUNTIME_IMAGE="mcr.microsoft.com/dotnet/runtime-deps:11.0-${DOTNET_IMAGEBASE}"
readonly JAVA_RUNTIME_IMAGE="docker.io/library/eclipse-temurin:25.0.4_7-jre-${JAVA_IMAGEBASE}"
case "${RUST_IMAGEBASE}" in
  alpine) readonly RUST_RUNTIME_IMAGE="docker.io/library/alpine:3.24.2" ;;
  trixie) readonly RUST_RUNTIME_IMAGE="docker.io/library/debian:trixie-slim" ;;
esac

resolve_runtime_image() {
  local image="${1:?runtime image is required}" reference digest

  podman pull --quiet "${image}" >/dev/null
  reference=$(podman image inspect --format '{{index .RepoDigests 0}}' "${image}")
  digest="${reference##*@}"
  [[ "${digest}" == sha256:* ]] ||
    { echo "ERROR: could not resolve immutable digest for upstream runtime image ${image}" >&2; exit 1; }
  runtime_build_args=(
    --build-arg "UPSTREAM_RUNTIME_IMAGE=${image}"
    --build-arg "UPSTREAM_RUNTIME_DIGEST=${digest}"
  )
}

# Podman is the required tool per Contract §4
if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman is required to build images (Contract §4). Install podman or ensure it is in PATH." >&2
  exit 1
fi

if [[ -z "${REGISTRY}" ]]; then
  REGISTRY="wtt"
fi
REGISTRY="${REGISTRY%/}"

# Determine git-SHA tag if not provided
if [[ -z "${TAG}" ]]; then
  TAG="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "")"
fi

# Contract §4: 'latest' is strictly forbidden
if [[ -z "${TAG}" || "${TAG}" == "latest" ]]; then
  echo "ERROR: Contract §4 forbids 'latest' tag. Immutable git-SHA required (got: '${TAG}')." >&2
  exit 1
fi

# Determine full registry host and image names per Contract §4
if [[ "${REGISTRY}" == *"."* ]]; then
  REGISTRY_HOST="${REGISTRY}"
  REGISTRY_NAME="${REGISTRY%.azurecr.io}"
  GO_IMAGE="${REGISTRY_HOST}/wtt/go-server:${TAG}"
  NET10_IMAGE="${REGISTRY_HOST}/wtt/net10-server:${TAG}"
  NET11_IMAGE="${REGISTRY_HOST}/wtt/net11-server:${TAG}"
  JAVA_NETTY_IMAGE="${REGISTRY_HOST}/wtt/java-netty-server:${TAG}"
  RUST_IMAGE="${REGISTRY_HOST}/wtt/rust-server:${TAG}"
else
  REGISTRY_HOST="${REGISTRY}"
  REGISTRY_NAME="${REGISTRY}"
  GO_IMAGE="${REGISTRY}/go-server:${TAG}"
  NET10_IMAGE="${REGISTRY}/net10-server:${TAG}"
  NET11_IMAGE="${REGISTRY}/net11-server:${TAG}"
  JAVA_NETTY_IMAGE="${REGISTRY}/java-netty-server:${TAG}"
  RUST_IMAGE="${REGISTRY}/rust-server:${TAG}"
fi

echo "=== Building Go server image: ${GO_IMAGE} (base: ${GO_IMAGEBASE}) ==="
resolve_runtime_image "${GO_RUNTIME_IMAGE}"
podman build \
  "${runtime_build_args[@]}" \
  --build-arg "IMAGEBASE=${GO_IMAGEBASE}" \
  -t "${GO_IMAGE}" \
  -f "${SCRIPT_DIR}/go-server/Dockerfile" \
  "${SCRIPT_DIR}/go-server"

echo "=== Building .NET 10 server image: ${NET10_IMAGE} (base: ${DOTNET_IMAGEBASE}, Native AOT: ${DOTNET_AOT}) ==="
net10_runtime_image="${NET10_JIT_RUNTIME_IMAGE}"
[[ "${DOTNET_AOT}" == true ]] && net10_runtime_image="${NET10_AOT_RUNTIME_IMAGE}"
resolve_runtime_image "${net10_runtime_image}"
podman build \
  "${runtime_build_args[@]}" \
  --build-arg "IMAGEBASE=${DOTNET_IMAGEBASE}" \
  --build-arg "DOTNET_AOT=${DOTNET_AOT}" \
  -t "${NET10_IMAGE}" \
  -f "${SCRIPT_DIR}/dotnet10-server/Dockerfile" \
  "${SCRIPT_DIR}/dotnet10-server"

echo "=== Building .NET 11 server image: ${NET11_IMAGE} (base: ${DOTNET_IMAGEBASE}, Native AOT: ${DOTNET_AOT}) ==="
net11_runtime_image="${NET11_JIT_RUNTIME_IMAGE}"
[[ "${DOTNET_AOT}" == true ]] && net11_runtime_image="${NET11_AOT_RUNTIME_IMAGE}"
resolve_runtime_image "${net11_runtime_image}"
podman build \
  "${runtime_build_args[@]}" \
  --build-arg "IMAGEBASE=${DOTNET_IMAGEBASE}" \
  --build-arg "DOTNET_AOT=${DOTNET_AOT}" \
  -t "${NET11_IMAGE}" \
  -f "${SCRIPT_DIR}/dotnet11-server/Dockerfile" \
  "${SCRIPT_DIR}"

echo "=== Building Java Netty server image: ${JAVA_NETTY_IMAGE} (base: ${JAVA_IMAGEBASE}) ==="
resolve_runtime_image "${JAVA_RUNTIME_IMAGE}"
podman build \
  "${runtime_build_args[@]}" \
  --build-arg "IMAGEBASE=${JAVA_IMAGEBASE}" \
  -t "${JAVA_NETTY_IMAGE}" \
  -f "${SCRIPT_DIR}/java-netty-server/Dockerfile" \
  "${SCRIPT_DIR}/java-netty-server"

echo "=== Building Rust server image: ${RUST_IMAGE} (base: ${RUST_IMAGEBASE}) ==="
resolve_runtime_image "${RUST_RUNTIME_IMAGE}"
podman build \
  "${runtime_build_args[@]}" \
  --build-arg "IMAGEBASE=${RUST_IMAGEBASE}" \
  -t "${RUST_IMAGE}" \
  -f "${SCRIPT_DIR}/rust-server/Dockerfile" \
  "${SCRIPT_DIR}/rust-server"

echo "Images built successfully:"
echo "  - ${GO_IMAGE}"
echo "  - ${NET10_IMAGE}"
echo "  - ${NET11_IMAGE}"
echo "  - ${JAVA_NETTY_IMAGE}"
echo "  - ${RUST_IMAGE}"

# If --build-only requested or registry is local 'wtt', exit without push
if [[ "${BUILD_ONLY}" == "true" || "${REGISTRY}" == "wtt" ]]; then
  exit 0
fi

# Contract §4: Authenticate to ACR via short-lived token
echo "=== Authenticating podman to ACR (${REGISTRY_HOST}) ==="
TOKEN=$(az acr login --name "${REGISTRY_NAME}" --expose-token --query accessToken -o tsv)
echo "${TOKEN}" | podman login "${REGISTRY_HOST}" \
  --username 00000000-0000-0000-0000-000000000000 --password-stdin

echo "=== Pushing Go server image to ACR: ${GO_IMAGE} ==="
podman push --compression-format gzip --force-compression "${GO_IMAGE}"
GO_DIGEST=$(podman inspect --format '{{.Digest}}' "${GO_IMAGE}" 2>/dev/null || echo "unknown")
echo "  image_digest (go-server): ${GO_DIGEST}"

echo "=== Pushing .NET 10 server image to ACR: ${NET10_IMAGE} ==="
podman push --compression-format gzip --force-compression "${NET10_IMAGE}"
NET10_DIGEST=$(podman inspect --format '{{.Digest}}' "${NET10_IMAGE}" 2>/dev/null || echo "unknown")
echo "  image_digest (net10-server): ${NET10_DIGEST}"

echo "=== Pushing .NET 11 server image: ${NET11_IMAGE} ==="
podman push --compression-format gzip --force-compression "${NET11_IMAGE}"
NET11_DIGEST=$(podman inspect --format '{{.Digest}}' "${NET11_IMAGE}" 2>/dev/null || echo "unknown")
echo "  image_digest (net11-server): ${NET11_DIGEST}"

echo "=== Pushing Java Netty server image to ACR: ${JAVA_NETTY_IMAGE} ==="
podman push --compression-format gzip --force-compression "${JAVA_NETTY_IMAGE}"
JAVA_NETTY_DIGEST=$(podman inspect --format '{{.Digest}}' "${JAVA_NETTY_IMAGE}" 2>/dev/null || echo "unknown")
echo "  image_digest (java-netty-server): ${JAVA_NETTY_DIGEST}"

echo "=== Pushing Rust server image to ACR: ${RUST_IMAGE} ==="
podman push --compression-format gzip --force-compression "${RUST_IMAGE}"
RUST_DIGEST=$(podman inspect --format '{{.Digest}}' "${RUST_IMAGE}" 2>/dev/null || echo "unknown")
echo "  image_digest (rust-server): ${RUST_DIGEST}"

echo "Build and push completed successfully."

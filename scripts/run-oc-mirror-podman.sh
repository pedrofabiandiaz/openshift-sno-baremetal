#!/usr/bin/env bash
# Run oc-mirror inside Podman on macOS (or any host) using Linux/amd64 binaries.
#
# Prerequisites: podman machine running; pull secret from cloud.redhat.com (JSON).
#
# Usage:
#   ./scripts/run-oc-mirror-podman.sh --build          # build image only
#   ./scripts/run-oc-mirror-podman.sh [--rebuild] [--config|-c imageset.yaml] ...
#   Default: uses existing localhost/oc-mirror-worker:latest (no rebuild). Missing image is built once.
#   --rebuild: podman build before run (e.g. after Containerfile changes).
#   ./scripts/run-oc-mirror-podman.sh -- \
#     oc-mirror --v2 --config /workspace/imageset-rhoai.yaml file:///mirror
#
# Primary use: oc-mirror --v2 --dry-run against a v2alpha1 ImageSet YAML to resolve catalog SHAs
# (no layer pulls). Pick the file with --config or CONFIG= (default: imageset-rhoai.yaml).
# Paths must be under the repo root (e.g. imageset-platform.yaml, subdir/foo.yaml).
#
# Default run is --dry-run. Full mirror to disk:
#   OC_MIRROR_DRY_RUN=0 PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh
#
# Or mirror-to-disk with defaults (config + output dir under repo):
#   PULL_SECRET=~/pull-secret.json ./scripts/run-oc-mirror-podman.sh
#
# The wrapper always runs oc-mirror with --v2. ImageSet YAML must use
# apiVersion: mirror.openshift.io/v2alpha1 (see imageset-rhoai.yaml).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${OC_MIRROR_IMAGE:-localhost/oc-mirror-worker:latest}"
CONTAINERFILE="${REPO_ROOT}/containers/oc-mirror/Containerfile"

PULL_SECRET="${PULL_SECRET:-${HOME}/pull-secret.json}"
MIRROR_OUT="${MIRROR_OUT:-${REPO_ROOT}/mirror-output}"
CONFIG="${CONFIG:-imageset-rhoai.yaml}"
# Default 1: pass --dry-run (SHAs / planning only). Set to 0 for a real mirror-to-disk.
OC_MIRROR_DRY_RUN="${OC_MIRROR_DRY_RUN:-1}"

# Print the command executed inside the container (quoted for safe copy-paste).
print_container_command() {
  echo "Running in container:" >&2
  printf '  ' >&2
  printf '%q ' "$@" >&2
  echo >&2
}

usage() {
  sed -n '1,55p' "$0" | sed -n '/^# /s/^# //p'
  exit "${1:-0}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage 0
fi

BUILD_ONLY=0
REBUILD=0
if [[ "${1:-}" == "--build" ]]; then
  BUILD_ONLY=1
  shift || true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      if [[ -z "${2:-}" ]]; then
        echo "usage: $0 [--build] [--rebuild] [--config|-c <path-under-repo>] ..." >&2
        exit 1
      fi
      CONFIG="$2"
      shift 2
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

normalize_config_path() {
  local cfg="$1"
  if [[ "${cfg}" == /* ]]; then
    if [[ "${cfg}" == "${REPO_ROOT}"/* ]]; then
      CONFIG="${cfg#"${REPO_ROOT}/"}"
    else
      echo "ImageSet file must be under ${REPO_ROOT} (got: ${cfg})" >&2
      exit 1
    fi
  else
    CONFIG="${cfg}"
  fi
}

normalize_config_path "${CONFIG}"

if [[ ! -f "${CONTAINERFILE}" ]]; then
  echo "Containerfile not found: ${CONTAINERFILE}" >&2
  exit 1
fi

build_image() {
  podman build --platform linux/amd64 -f "${CONTAINERFILE}" -t "${IMAGE_NAME}" "${REPO_ROOT}"
}

if [[ "${BUILD_ONLY}" -eq 1 ]]; then
  echo "Building ${IMAGE_NAME} (linux/amd64)..."
  build_image
  echo "Build complete: ${IMAGE_NAME}"
  exit 0
fi

if [[ "${REBUILD}" -eq 1 ]] || ! podman image exists "${IMAGE_NAME}" 2>/dev/null; then
  if [[ "${REBUILD}" -eq 1 ]]; then
    echo "Rebuilding ${IMAGE_NAME} (linux/amd64)..."
  else
    echo "Image ${IMAGE_NAME} not found; building (linux/amd64)..."
  fi
  build_image
else
  echo "Using existing image ${IMAGE_NAME} (pass --rebuild to rebuild from Containerfile)."
fi

if [[ ! -f "${PULL_SECRET}" ]]; then
  echo "Pull secret not found: ${PULL_SECRET}" >&2
  echo "Set PULL_SECRET to your cloud.redhat.com pull-secret JSON file." >&2
  exit 1
fi

if [[ ! -f "${REPO_ROOT}/${CONFIG}" ]]; then
  echo "ImageSet config not found: ${REPO_ROOT}/${CONFIG}" >&2
  exit 1
fi

mkdir -p "${MIRROR_OUT}"

RUN_ARGS=(
  run --rm -it
  --platform linux/amd64
  --security-opt label=disable
  -v "${REPO_ROOT}:/workspace:Z"
  -v "${MIRROR_OUT}:/mirror:Z"
  -v "${PULL_SECRET}:/run/secrets/pull-secret:ro,Z"
  # list/describe/init have no --authfile; they read ~/.docker/config.json (HOME=/tmp).
  -v "${PULL_SECRET}:/tmp/.docker/config.json:ro,Z"
  -e "HOME=/tmp"
  -w /workspace
  "${IMAGE_NAME}"
)

if [[ "${1:-}" == "--" ]]; then
  shift
  if [[ $# -lt 1 ]]; then
    echo "Pass a command after --. E.g. mirror: oc-mirror --v2 --help. For 'list': do not pass --v1/--v2 (oc-mirror list operators ...)." >&2
    exit 1
  fi
  print_container_command "$@"
  exec podman "${RUN_ARGS[@]}" "$@"
fi

# Default: mirror to disk using CONFIG (oc-mirror v2 only)
DRY_FLAG=()
if [[ "${OC_MIRROR_DRY_RUN}" != "0" ]]; then
  DRY_FLAG=(--dry-run)
fi

print_container_command oc-mirror --v2 "${DRY_FLAG[@]}" --authfile /run/secrets/pull-secret --config "/workspace/${CONFIG}" "file:///mirror"
exec podman "${RUN_ARGS[@]}" \
  oc-mirror --v2 "${DRY_FLAG[@]}" --authfile /run/secrets/pull-secret --config "/workspace/${CONFIG}" "file:///mirror"

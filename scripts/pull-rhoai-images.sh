#!/usr/bin/env bash
#
# Pull all images listed in rhoai-imagelist.txt (one docker:// reference per line)
# using skopeo into a local OCI directory layout.
#
# Usage:
#   ./pull-rhoai-images.sh [IMAGE_LIST_FILE] [OUTPUT_DIR]
#
# Requires: skopeo, credentials in auth file (e.g. ~/.docker/config.json or --authfile)
# Optional: PULL_AUTHFILE env var for skopeo --authfile (e.g. path to pull secret)
#

set -euo pipefail

# Defaults: first arg = image list file, second = output directory
IMAGE_LIST_FILE="${1:-rhoai-imagelist.txt}"
OUTPUT_DIR="${2:-./rhoai-images}"

if [[ ! -f "$IMAGE_LIST_FILE" ]]; then
  echo "Usage: $0 IMAGE_LIST_FILE [OUTPUT_DIR]" >&2
  echo "Example: $0 rhoai-imagelist.txt ./rhoai-images" >&2
  echo "Error: Image list file not found: $IMAGE_LIST_FILE" >&2
  exit 1
fi

if ! command -v skopeo &>/dev/null; then
  echo "Error: skopeo is required. Install it (e.g. dnf install skopeo, brew install skopeo)." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
IMAGE_LIST_FILE="$(realpath "$IMAGE_LIST_FILE")"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"

# Optional auth file for pulling (Red Hat pull secret or docker config)
SKOPEO_AUTH=()
if [[ -n "${PULL_AUTHFILE:-}" && -f "$PULL_AUTHFILE" ]]; then
  SKOPEO_AUTH=(--authfile "$PULL_AUTHFILE")
fi

# Read image refs: one per line, strip docker:// for display/safe_name, keep full ref for skopeo
# Lines are: docker://registry/repo@sha256:digest (blank lines and # comments ignored)
get_images() {
  grep -v '^[[:space:]]*$' "$IMAGE_LIST_FILE" | grep -v '^[[:space:]]*#' | sed 's|^docker://||' || true
}

# Sanitize image reference to a safe directory name (no /, :, @)
# e.g. registry.redhat.io/rhoai/odh-mlflow-operator-rhel9@sha256:abc... -> registry.redhat.io-rhoai-odh-mlflow-operator-rhel9-sha256-abc (digest truncated to 12 chars)
safe_dir_name() {
  local ref="$1"
  local name
  name="${ref//\//-}"
  name="${name//@/-}"
  name="${name//:/-}"
  # Shorten sha256 digest in dir name to 12 chars to avoid very long paths
  if [[ "$name" =~ (-sha256-)([a-f0-9]{64})$ ]]; then
    name="${name%${BASH_REMATCH[0]}}${BASH_REMATCH[1]}${BASH_REMATCH[2]:0:12}"
  fi
  echo "$name"
}

# Pull a single image with skopeo to dir: layout
# $1 = pull spec (with or without docker:// prefix)
pull_one() {
  local raw_spec="$1"
  local pull_spec="${raw_spec#docker://}"
  local safe_name
  safe_name="$(safe_dir_name "$pull_spec")"
  local dest_dir="${OUTPUT_DIR}/${safe_name}"

  if [[ -d "$dest_dir" ]]; then
    echo "[SKIP] $pull_spec (already exists)" >&2
    return 0
  fi

  echo "[PULL] $pull_spec -> $dest_dir" >&2
  if skopeo copy "${SKOPEO_AUTH[@]}" --preserve-digests --all "docker://${pull_spec}" "dir:${dest_dir}"; then
    echo "[OK]   $pull_spec" >&2
  else
    echo "[FAIL] $pull_spec" >&2
    return 1
  fi
}

mapfile -t ALL_IMAGES < <(get_images)

if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
  echo "Error: No images found in $IMAGE_LIST_FILE. Check file format (one docker:// ref per line)." >&2
  exit 1
fi

echo "Found ${#ALL_IMAGES[@]} image(s) in $IMAGE_LIST_FILE. Output: $OUTPUT_DIR" >&2
FAILED=0
for spec in "${ALL_IMAGES[@]}"; do
  [[ -z "$spec" ]] && continue
  pull_one "$spec" || ((FAILED++)) || true
done

if [[ $FAILED -gt 0 ]]; then
  echo "Done with $FAILED failed pull(s)." >&2
  exit 1
fi
echo "All images pulled to $OUTPUT_DIR" >&2

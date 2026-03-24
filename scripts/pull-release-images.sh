#!/usr/bin/env bash
#
# Pull all images listed in an OpenShift release-info file (e.g. 4_20_9-release-info.txt)
# using skopeo into a local OCI directory layout.
#
# Usage:
#   ./pull-release-images.sh [RELEASE_INFO_FILE] [OUTPUT_DIR]
#
# Requires: skopeo, credentials in auth file (e.g. ~/.docker/config.json or --authfile)
# Optional: PULL_AUTHFILE env var for skopeo --authfile (e.g. path to pull secret)
#

set -euo pipefail

# Defaults: first arg = release info file, second = output directory
RELEASE_INFO_FILE="${1:-}"
OUTPUT_DIR="${2:-./ocp-release-images}"

if [[ -z "$RELEASE_INFO_FILE" ]]; then
  echo "Usage: $0 RELEASE_INFO_FILE [OUTPUT_DIR]" >&2
  echo "Example: $0 4_20_9-release-info.txt ./ocp-release-images" >&2
  exit 1
fi

if [[ ! -f "$RELEASE_INFO_FILE" ]]; then
  echo "Error: Release info file not found: $RELEASE_INFO_FILE" >&2
  exit 1
fi

if ! command -v skopeo &>/dev/null; then
  echo "Error: skopeo is required. Install it (e.g. dnf install skopeo, brew install skopeo)." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
RELEASE_INFO_FILE="$(realpath "$RELEASE_INFO_FILE")"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"

# Optional auth file for pulling (Red Hat pull secret or docker config)
SKOPEO_AUTH=()
if [[ -n "${PULL_AUTHFILE:-}" && -f "$PULL_AUTHFILE" ]]; then
  SKOPEO_AUTH=(--authfile "$PULL_AUTHFILE")
fi

# Extract "Pull From:" line (release image) if present
get_release_image() {
  awk '/^Pull From:[[:space:]]/ { print $3; exit }' "$RELEASE_INFO_FILE"
}

# Extract all pull specs from the "Images:" section (lines with quay.io/ or registry.*/)
get_component_images() {
  awk '
    /^Images:/          { in_images = 1; next }
    in_images && /^[[:space:]]+[^[:space:]]+[[:space:]]+quay\.io\//  { print $NF; next }
    in_images && /^[[:space:]]+[^[:space:]]+[[:space:]]+registry\./   { print $NF; next }
    in_images && /^[[:space:]]*$/ { next }
    in_images && ! /quay\.io\// && ! /registry\./ { next }
  ' "$RELEASE_INFO_FILE"
}

# Sanitize image reference to a safe directory name (no /, :, @)
# e.g. quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:abc... -> quay.io-openshift-release-dev-ocp-v4.0-art-dev-sha256-abc (digest truncated to 12 chars)
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
pull_one() {
  local pull_spec="$1"
  local safe_name
  safe_name="$(safe_dir_name "$pull_spec")"
  local dest_dir="${OUTPUT_DIR}/${safe_name}"

  if [[ -d "$dest_dir" ]]; then
    echo "[SKIP] $pull_spec (already exists)" >&2
    return 0
  fi

  echo "[PULL] $pull_spec -> $dest_dir" >&2
  if skopeo copy "${SKOPEO_AUTH[@]}" --all "docker://${pull_spec}" "dir:${dest_dir}"; then
    echo "[OK]   $pull_spec" >&2
  else
    echo "[FAIL] $pull_spec" >&2
    return 1
  fi
}

# Collect all images (release + component list)
RELEASE_IMAGE="$(get_release_image)" || true
mapfile -t COMPONENT_IMAGES < <(get_component_images || true)

ALL_IMAGES=()
[[ -n "${RELEASE_IMAGE:-}" ]] && ALL_IMAGES+=("$RELEASE_IMAGE")
ALL_IMAGES+=("${COMPONENT_IMAGES[@]}")

if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
  echo "Error: No images found in $RELEASE_INFO_FILE. Check file format." >&2
  exit 1
fi

echo "Found ${#ALL_IMAGES[@]} image(s) in $RELEASE_INFO_FILE. Output: $OUTPUT_DIR" >&2
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

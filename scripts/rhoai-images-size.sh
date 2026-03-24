#!/usr/bin/env bash
#
# Calculate the total size (compressed, as stored in the registry) of all images
# listed in rhoai-imagelist.txt using skopeo inspect. Does not download image data.
#
# Usage:
#   ./rhoai-images-size.sh [IMAGE_LIST_FILE]
#
# Optional: PULL_AUTHFILE env var for skopeo (e.g. path to pull secret for registry.redhat.io)
# Requires: skopeo, jq
#

set -euo pipefail

IMAGE_LIST_FILE="${1:-rhoai-imagelist.txt}"

if [[ ! -f "$IMAGE_LIST_FILE" ]]; then
  echo "Usage: $0 IMAGE_LIST_FILE" >&2
  echo "Example: $0 rhoai-imagelist.txt" >&2
  echo "Error: File not found: $IMAGE_LIST_FILE" >&2
  exit 1
fi

for cmd in skopeo jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required." >&2
    exit 1
  fi
done

SKOPEO_AUTH=()
if [[ -n "${PULL_AUTHFILE:-}" && -f "$PULL_AUTHFILE" ]]; then
  SKOPEO_AUTH=(--authfile "$PULL_AUTHFILE")
fi

# Read image refs (strip docker://, skip empty and comments)
get_images() {
  grep -v '^[[:space:]]*$' "$IMAGE_LIST_FILE" | grep -v '^[[:space:]]*#' | sed 's|^docker://||' || true
}

# Get repo part of ref (registry/path without @sha256:digest)
repo_from_ref() {
  echo "${1%%@*}"
}

# Get size in bytes for one image ref using raw manifest (config.size + sum(layers[].size))
# Handles manifest list by resolving to first platform (amd64/linux if present, else first)
get_image_size_bytes() {
  local ref="$1"
  local raw
  local size

  raw=$(skopeo inspect "${SKOPEO_AUTH[@]}" --raw "docker://${ref}" 2>/dev/null) || return 1

  # Manifest list (multi-arch): resolve to a single manifest
  if echo "$raw" | jq -e '.manifests' >/dev/null 2>&1; then
    local digest
    local repo
    repo="$(repo_from_ref "$ref")"
    # Prefer amd64/linux
    digest=$(echo "$raw" | jq -r '
      (.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux")) // .manifests[0]
      | .digest
    ')
    [[ -z "$digest" || "$digest" == "null" ]] && digest=$(echo "$raw" | jq -r '.manifests[0].digest')
    ref="${repo}@${digest}"
    raw=$(skopeo inspect "${SKOPEO_AUTH[@]}" --raw "docker://${ref}" 2>/dev/null) || return 1
  fi

  # Single manifest: config.size + sum(layers[].size)
  size=$(echo "$raw" | jq -r '
    (if .config then .config.size else 0 end) + ([.layers[]? | .size // 0] | add)
  ')
  if [[ -z "$size" || "$size" == "null" ]]; then
    return 1
  fi
  echo "$size"
}

# Format bytes as GB (2 decimal places)
bytes_to_gb() {
  local bytes="$1"
  echo "$bytes" | awk '{ printf "%.2f", $0 / 1024 / 1024 / 1024 }'
}

TOTAL_BYTES=0
FAILED=0
declare -a SIZES
declare -a REFS
count=0

echo "Inspecting images (no download)..." >&2
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  size_b=$(get_image_size_bytes "$ref" 2>/dev/null) || {
    echo "[FAIL] $ref" >&2
    ((FAILED++)) || true
    continue
  }
  REFS+=("$ref")
  SIZES+=("$size_b")
  TOTAL_BYTES=$((TOTAL_BYTES + size_b))
  ((count++)) || true
done < <(get_images)

if [[ $count -eq 0 ]]; then
  echo "No images could be inspected. Check PULL_AUTHFILE for registry.redhat.io." >&2
  exit 1
fi

# Per-image report (short ref: last two path components or full if short)
echo ""
echo "Size per image (GB):"
echo "--------------------"
for i in "${!REFS[@]}"; do
  ref="${REFS[$i]}"
  size_b="${SIZES[$i]}"
  gb=$(bytes_to_gb "$size_b")
  # Shorten ref for display: keep registry and last path component
  short="${ref#*//}"
  if [[ "$short" == */*/* ]]; then
    short="${short%%/*}/${short##*/}"
  fi
  printf "%10s GB  %s\n" "$gb" "$short"
done

echo "--------------------"
TOTAL_GB=$(bytes_to_gb "$TOTAL_BYTES")
printf "%10s GB  TOTAL (%d images)\n" "$TOTAL_GB" "$count"

if [[ $FAILED -gt 0 ]]; then
  echo "" >&2
  echo "$FAILED image(s) could not be inspected (auth or network)." >&2
  exit 1
fi

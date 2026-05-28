#!/usr/bin/env bash
#
# Report images from a list file that are not yet present in an internal mirror registry.
# Each upstream reference is rewritten using per-registry mirror env vars, then checked with
# skopeo inspect (no image data is downloaded).
#
# Usage:
#   ./scripts/check-mirrored-images.sh [IMAGE_LIST_FILE]
#   ./scripts/check-mirrored-images.sh -o missing.txt imagesetconfigs/images-2026-05-14-rhoai.txt
#
# Registry mirrors (set the ones you use; unmapped registries are checked as-is):
#   MIRROR_REGISTRY_REDHAT_IO=artifactory.example.com/registry.redhat.io
#   MIRROR_QUAY_IO=artifactory.example.com/quay.io
#   MIRROR_NVCR_IO=artifactory.example.com/nvcr.io
#   MIRROR_REGISTRY_ACCESS_REDHAT_COM=artifactory.example.com/registry.access.redhat.com
#   MIRROR_REGISTRY_CONNECT_REDHAT_COM=artifactory.example.com/registry.connect.redhat.com
#
# Env name rule: MIRROR_<HOST> with dots and hyphens replaced by underscores, uppercased.
#   registry.redhat.io  -> MIRROR_REGISTRY_REDHAT_IO
#
# Alternative bulk mapping:
#   REGISTRY_MIRRORS='registry.redhat.io=mirror.example/rh,quay.io=mirror.example/quay'
#
# Optional:
#   INSPECT_AUTHFILE or PULL_AUTHFILE  path to docker config / pull secret for skopeo --authfile
#   SKOPEO_TLS_VERIFY=0              pass --tls-verify=false to skopeo inspect
#   CHECK_JOBS=4                     parallel skopeo workers (default 1; set >1 to enable)
#   CHECK_VERBOSE=1                  log present/missing per image to stderr
#
# Output:
#   Upstream references that are missing from the mirror (stdout), one per line.
#   Summary on stderr. Exit 1 if any image is missing; exit 2 if a registry host has no mirror map.
#
# Requires: skopeo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_LIST_FILE="${REPO_ROOT}/imagesetconfigs/images-2026-05-14-rhoai.txt"
OUTPUT_FILE=""
CHECK_JOBS="${CHECK_JOBS:-1}"
CHECK_VERBOSE="${CHECK_VERBOSE:-0}"

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage 0
      ;;
    -o|--output)
      [[ -n "${2:-}" ]] || { echo "Error: -o requires a file path" >&2; exit 1; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      IMAGE_LIST_FILE="$1"
      shift
      ;;
  esac
done

if [[ ! -f "$IMAGE_LIST_FILE" ]]; then
  echo "Error: image list not found: $IMAGE_LIST_FILE" >&2
  usage 1
fi

if ! command -v skopeo &>/dev/null; then
  echo "Error: skopeo is required (e.g. dnf install skopeo, brew install skopeo)." >&2
  exit 1
fi

SKOPEO_AUTH=()
AUTHFILE="${INSPECT_AUTHFILE:-${PULL_AUTHFILE:-}}"
if [[ -n "$AUTHFILE" && -f "$AUTHFILE" ]]; then
  SKOPEO_AUTH=(--authfile "$AUTHFILE")
fi

SKOPEO_TLS=()
if [[ "${SKOPEO_TLS_VERIFY:-1}" == "0" ]]; then
  SKOPEO_TLS=(--tls-verify=false)
fi

MIRROR_MAP_FILE="$(mktemp)"
MISSING_FILE="$(mktemp)"
PRESENT_FILE="$(mktemp)"
trap 'rm -f "$MIRROR_MAP_FILE" "$MISSING_FILE" "$PRESENT_FILE"' EXIT

# MIRROR_REGISTRY_REDHAT_IO -> registry.redhat.io
mirror_env_name() {
  local host="$1"
  local key
  key="$(printf '%s' "$host" | tr '[:lower:]' '[:upper:]' | tr '.-' '__')"
  printf 'MIRROR_%s' "$key"
}

load_mirror_map() {
  : >"$MIRROR_MAP_FILE"
  local csv="${REGISTRY_MIRRORS:-}"
  if [[ -n "$csv" ]]; then
    local pair src dst
    local IFS=,
    for pair in $csv; do
      pair="${pair#"${pair%%[![:space:]]*}"}"
      pair="${pair%"${pair##*[![:space:]]}"}"
      [[ -z "$pair" || "$pair" != *"="* ]] && continue
      src="${pair%%=*}"
      dst="${pair#*=}"
      src="${src#"${src%%[![:space:]]*}"}"
      src="${src%"${src##*[![:space:]]}"}"
      dst="${dst#"${dst%%[![:space:]]*}"}"
      dst="${dst%"${dst##*[![:space:]]}"}"
      dst="${dst%/}"
      printf '%s=%s\n' "$src" "$dst" >>"$MIRROR_MAP_FILE"
    done
  fi

  local host env_name target
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    if grep -q "^${host}=" "$MIRROR_MAP_FILE" 2>/dev/null; then
      continue
    fi
    env_name="$(mirror_env_name "$host")"
    target="${!env_name-}"
    if [[ -n "$target" ]]; then
      target="${target%/}"
      printf '%s=%s\n' "$host" "$target" >>"$MIRROR_MAP_FILE"
    fi
  done < <(list_registry_hosts)
}

list_registry_hosts() {
  get_images | while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    echo "${ref%%/*}"
  done | sort -u
}

mirror_target_for_host() {
  local host="$1"
  local line
  line="$(grep -m1 "^${host}=" "$MIRROR_MAP_FILE" 2>/dev/null || true)"
  if [[ -n "$line" ]]; then
    echo "${line#*=}"
    return 0
  fi
  return 1
}

map_ref_to_mirror() {
  local ref="$1"
  local host rest mirror
  host="${ref%%/*}"
  if [[ "$host" == "$ref" || "$host" != *.* ]]; then
    echo "$ref"
    return 0
  fi
  rest="${ref#*/}"
  if ! mirror="$(mirror_target_for_host "$host")"; then
    echo "$ref"
    return 1
  fi
  if [[ -n "$rest" ]]; then
    echo "${mirror}/${rest}"
  else
    echo "${mirror}"
  fi
}

get_images() {
  grep -v '^[[:space:]]*$' "$IMAGE_LIST_FILE" \
    | grep -v '^[[:space:]]*#' \
    | sed 's|^docker://||' || true
}

load_mirror_map

UNMAPPED_HOSTS=()
while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  if ! mirror_target_for_host "$host" >/dev/null 2>&1; then
    UNMAPPED_HOSTS+=("$host")
  fi
done < <(list_registry_hosts)

if [[ ${#UNMAPPED_HOSTS[@]} -gt 0 ]]; then
  echo "Warning: no mirror env for registry host(s):" >&2
  for host in "${UNMAPPED_HOSTS[@]}"; do
    echo "  $(mirror_env_name "$host")=<internal-host[/path]>  (for ${host})" >&2
  done
  echo "Those refs will be inspected without host rewrite." >&2
fi

inspect_one() {
  local upstream="$1"
  local mirrored mapped=1
  mirrored="$(map_ref_to_mirror "$upstream")" || mapped=0
  if skopeo inspect --no-tags "${SKOPEO_AUTH[@]}" "${SKOPEO_TLS[@]}" "docker://${mirrored}" >/dev/null 2>&1; then
    if [[ "$CHECK_VERBOSE" == "1" ]]; then
      echo "[OK]   ${upstream} -> ${mirrored}" >&2
    fi
    printf '%s\n' "$upstream" >>"$PRESENT_FILE"
    return 0
  fi
  if [[ "$CHECK_VERBOSE" == "1" ]]; then
    echo "[MISS] ${upstream} -> ${mirrored}" >&2
  fi
  printf '%s\n' "$upstream" >>"$MISSING_FILE"
  return 1
}

mapfile -t ALL_IMAGES < <(get_images)
TOTAL=${#ALL_IMAGES[@]}
if [[ $TOTAL -eq 0 ]]; then
  echo "Error: no images in $IMAGE_LIST_FILE" >&2
  exit 1
fi

echo "Checking ${TOTAL} image(s) from ${IMAGE_LIST_FILE} (jobs=${CHECK_JOBS})..." >&2

if [[ "$CHECK_JOBS" -le 1 ]]; then
  for ref in "${ALL_IMAGES[@]}"; do
    [[ -z "$ref" ]] && continue
    inspect_one "$ref" || true
  done
else
  for ref in "${ALL_IMAGES[@]}"; do
    [[ -z "$ref" ]] && continue
    while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$CHECK_JOBS" ]]; do
      sleep 0.1
    done
    inspect_one "$ref" &
  done
  wait || true
fi

MISSING_COUNT=0
PRESENT_COUNT=0
[[ -f "$MISSING_FILE" ]] && MISSING_COUNT=$(wc -l <"$MISSING_FILE" | tr -d ' ')
[[ -f "$PRESENT_FILE" ]] && PRESENT_COUNT=$(wc -l <"$PRESENT_FILE" | tr -d ' ')

sort -u "$MISSING_FILE" -o "$MISSING_FILE"

if [[ -n "$OUTPUT_FILE" ]]; then
  cp "$MISSING_FILE" "$OUTPUT_FILE"
  echo "Wrote ${MISSING_COUNT} missing image(s) to ${OUTPUT_FILE}" >&2
else
  cat "$MISSING_FILE"
fi

echo "Summary: ${PRESENT_COUNT} present, ${MISSING_COUNT} missing (of ${TOTAL})" >&2

if [[ ${#UNMAPPED_HOSTS[@]} -gt 0 ]]; then
  exit 2
fi
if [[ "$MISSING_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0

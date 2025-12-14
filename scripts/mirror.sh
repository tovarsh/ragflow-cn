#!/usr/bin/env bash
set -euo pipefail

IMAGES_JSON="$1"
REG="$2"   # e.g. ccr.ccs.tencentyun.com
NS="$3"    # e.g. comintern

# ========== Helpers ==========

# Extract tag from image reference.
# Supports:
#   - name:tag
#   - registry/ns/name:tag
# If it's digest form (name@sha256:...), we label it as "digest" and keep a stable tag-like value.
get_tag () {
  local src="$1"
  if [[ "$src" == *@* ]]; then
    # digest reference, normalize to a tag-like suffix
    echo "digest-$(echo "${src#*@}" | tr ':' '-')"
    return 0
  fi
  if [[ "$src" == *:* ]]; then
    echo "${src##*:}"
    return 0
  fi
  # no tag, default latest
  echo "latest"
}

# Base name rule (your preferred default):
# Keep ONLY the last segment as repo name, drop registry/namespace.
# e.g. ghcr.io/hkuds/lightrag -> lightrag
map_dest_repo_name_only () {
  local src="$1"

  local ref="$src"
  ref="${ref%@*}"   # drop digest
  ref="${ref%%:*}"  # drop tag

  echo "${ref##*/}"
}

# Flatten rule (fallback on conflict):
# Drop registry if present, keep remaining path, replace '/' with '-'
# e.g. ghcr.io/hkuds/lightrag -> hkuds-lightrag
# e.g. infiniflow/ragflow -> infiniflow-ragflow
map_dest_repo_flatten () {
  local src="$1"

  local ref="$src"
  ref="${ref%@*}"   # drop digest
  ref="${ref%%:*}"  # drop tag

  local no_reg="$ref"
  if [[ "$ref" == *"/"*"/"* ]]; then
    local first="${ref%%/*}"
    local rest="${ref#*/}"
    if [[ "$first" == *"."* || "$first" == *":"* ]]; then
      no_reg="$rest"
    fi
  fi

  echo "$no_reg" | sed 's|/|-|g'
}

digest_of () {
  # return manifest digest; empty if not found
  skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null || true
}

# ========== Stage 1: Read sources ==========
mapfile -t SOURCES < <(jq -r '.[]' "$IMAGES_JSON" | sed '/^\s*$/d')
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
  echo "[ERROR] No images found in $IMAGES_JSON"
  exit 1
fi

# ========== Stage 2: Detect conflicts under name-only mapping ==========
# conflict key = "<repo_name_only>:<tag>"
declare -A FIRST_SRC_FOR_KEY
declare -A NEED_FLATTEN_FOR_KEY

for SRC in "${SOURCES[@]}"; do
  REPO_NAME="$(map_dest_repo_name_only "$SRC")"
  TAG="$(get_tag "$SRC")"
  KEY="${REPO_NAME}:${TAG}"

  if [[ -z "${FIRST_SRC_FOR_KEY[$KEY]+x}" ]]; then
    FIRST_SRC_FOR_KEY[$KEY]="$SRC"
  else
    if [[ "${FIRST_SRC_FOR_KEY[$KEY]}" != "$SRC" ]]; then
      NEED_FLATTEN_FOR_KEY[$KEY]=1
    fi
  fi
done

# Print conflicts summary (if any)
CONFLICT_COUNT=0
for k in "${!NEED_FLATTEN_FOR_KEY[@]}"; do
  ((CONFLICT_COUNT++)) || true
done
if [[ "$CONFLICT_COUNT" -gt 0 ]]; then
  echo "[WARN] Detected $CONFLICT_COUNT conflict(s) under name-only mapping."
  echo "[WARN] For conflicted repo:tag, will FALLBACK to flatten mapping to avoid overwrite."
  for k in "${!NEED_FLATTEN_FOR_KEY[@]}"; do
    echo "  - conflict: $k (e.g. ${FIRST_SRC_FOR_KEY[$k]} vs others)"
  done
fi

# ========== Stage 3: Mirror ==========
for SRC in "${SOURCES[@]}"; do
  REPO_NAME_ONLY="$(map_dest_repo_name_only "$SRC")"
  TAG="$(get_tag "$SRC")"
  KEY="${REPO_NAME_ONLY}:${TAG}"

  # choose mapping: name-only by default; flatten only for conflicted keys
  if [[ -n "${NEED_FLATTEN_FOR_KEY[$KEY]+x}" ]]; then
    REPO="$(map_dest_repo_flatten "$SRC")"
    echo "[INFO] Fallback to flatten mapping for conflict key=$KEY : $SRC -> repo=$REPO"
  else
    REPO="$REPO_NAME_ONLY"
  fi

  DST="${REG}/${NS}/${REPO}:${TAG}"

  SDIG="$(digest_of "$SRC")"
  DDIG="$(digest_of "$DST")"

  if [[ -n "$SDIG" && "$SDIG" == "$DDIG" ]]; then
    echo "[SKIP] $SRC -> $DST (digest same: $SDIG)"
    continue
  fi

  echo "[COPY] $SRC -> $DST"
  skopeo copy --multi-arch all "docker://$SRC" "docker://$DST"
done

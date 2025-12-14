#!/usr/bin/env bash
set -euo pipefail

# ====== 可通过环境变量覆盖 ======
REG="${MIRROR_REGISTRY:-ccr.ccs.tencentyun.com}"
NS="${MIRROR_NAMESPACE:-comintern}"
IMAGES_JSON="${MIRROR_IMAGES_JSON:-upstream/images.json}"

# buildx 优先（true/false）
USE_BUILDX="${MIRROR_USE_BUILDX:-true}"

# docker pull 的平台（空表示默认；你也可以设 linux/amd64）
PULL_PLATFORM="${MIRROR_PULL_PLATFORM:-}"

# 遇到失败是否继续（true/false）
CONTINUE_ON_ERROR="${MIRROR_CONTINUE_ON_ERROR:-true}"

# 额外：跳过包含这些关键字的镜像（逗号分隔，可为空）
SKIP_CONTAINS="${MIRROR_SKIP_CONTAINS:-}"

# 日志（默认 stdout/stderr 由 nohup 重定向；这里也会在脚本内打时间戳）
# =================================

ts() { date '+%F %T'; }

log() { echo "[$(ts)] $*"; }

die() { log "[FATAL] $*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

should_skip() {
  local src="$1"
  [[ -z "$SKIP_CONTAINS" ]] && return 1
  IFS=',' read -ra parts <<< "$SKIP_CONTAINS"
  for p in "${parts[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -z "$p" ]] && continue
    if [[ "$src" == *"$p"* ]]; then
      return 0
    fi
  done
  return 1
}

repo_name_only() {
  local src="$1"
  local ref="${src%%@*}"        # drop digest
  local name="${ref%%:*}"       # drop tag
  echo "${name##*/}"            # keep last segment only
}

tag_of() {
  local src="$1"
  if [[ "$src" == *@sha256:* ]]; then
    # digest reference -> make a stable tag-like value
    local dig="${src#*@sha256:}"
    echo "digest-${dig:0:12}"
    return
  fi
  if [[ "$src" == *:* ]]; then
    echo "${src##*:}"
    return
  fi
  echo "latest"
}

dst_of() {
  local src="$1"
  local repo tag
  repo="$(repo_name_only "$src")"
  tag="$(tag_of "$src")"
  echo "${REG}/${NS}/${repo}:${tag}"
}

try_buildx() {
  local src="$1" dst="$2"
  log "[BUILDX] $src -> $dst"
  docker buildx imagetools create --tag "$dst" "$src"
}

try_docker_fallback() {
  local src="$1" dst="$2"
  log "[FALLBACK] docker pull/tag/push: $src -> $dst"
  if [[ -n "$PULL_PLATFORM" ]]; then
    docker pull --platform="$PULL_PLATFORM" "$src"
  else
    docker pull "$src"
  fi
  docker tag "$src" "$dst"
  docker push "$dst"
}

main() {
  need docker
  need jq

  [[ -f "$IMAGES_JSON" ]] || die "images json not found: $IMAGES_JSON"

  # buildx 可选
  if [[ "$USE_BUILDX" == "true" ]]; then
    if ! docker buildx version >/dev/null 2>&1; then
      log "[WARN] buildx not available; will fallback to docker pull/tag/push only"
      USE_BUILDX="false"
    fi
  fi

  local total
  total="$(jq length "$IMAGES_JSON")"
  log "[INFO] Start mirror: REG=$REG NS=$NS images=$total use_buildx=$USE_BUILDX pull_platform=${PULL_PLATFORM:-default}"
  log "[INFO] images_json=$IMAGES_JSON"

  local i=0
  jq -r '.[]' "$IMAGES_JSON" | while read -r src; do
    i=$((i+1))
    [[ -z "$src" ]] && continue

    if should_skip "$src"; then
      log "[SKIP] ($i/$total) $src (matched MIRROR_SKIP_CONTAINS)"
      continue
    fi

    local dst
    dst="$(dst_of "$src")"

    log "[COPY] ($i/$total) $src -> $dst"

    set +e
    if [[ "$USE_BUILDX" == "true" ]]; then
      try_buildx "$src" "$dst"
      rc=$?
      if [[ $rc -ne 0 ]]; then
        log "[WARN] buildx failed rc=$rc for $src; fallback to docker"
        try_docker_fallback "$src" "$dst"
        rc=$?
      fi
    else
      try_docker_fallback "$src" "$dst"
      rc=$?
    fi
    set -e

    if [[ $rc -ne 0 ]]; then
      log "[ERROR] failed rc=$rc: $src -> $dst"
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        exit $rc
      fi
    else
      log "[OK] $src -> $dst"
    fi
  done

  log "[DONE] Mirror finished."
}

main "$@"

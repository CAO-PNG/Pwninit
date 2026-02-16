#!/usr/bin/env bash
set -euo pipefail

clibc_docker_cache_dir() {
  local aio_root="${GLIBC_AIO_DIR:-$HOME/CTF_PWN/tools/glibc-all-in-one}"
  printf '%s\n' "${CLIBC_DOCKER_CACHE_DIR:-$aio_root/Docker_Download}"
}

clibc_prepare_cache_dir_docker() {
  local preferred="$1"
  local fallback_name="$2"

  if mkdir -p -- "$preferred" 2>/dev/null; then
    local probe="$preferred/.clibc-write-test.$$"
    if touch -- "$probe" >/dev/null 2>&1; then
      rm -f -- "$probe"
      printf '%s\n' "$preferred"
      return 0
    fi
  fi

  local fallback="/tmp/clibc-cache/$fallback_name"
  mkdir -p -- "$fallback" || clibc_die "Cannot create fallback cache dir: $fallback"
  local fallback_probe="$fallback/.clibc-write-test.$$"
  if touch -- "$fallback_probe" >/dev/null 2>&1; then
    rm -f -- "$fallback_probe"
    clibc_warn "Cannot write cache dir '$preferred', fallback to '$fallback'"
    printf '%s\n' "$fallback"
    return 0
  fi

  clibc_die "Cannot create writable cache dir: preferred='$preferred' fallback='$fallback'"
}

# 参数:
#   $1 local_libs
#   $2 dockerfile_path
#   $3 build_context (可选；默认 dockerfile 所在目录)
clibc_mode_docker() {
  local local_libs="$1"
  local dockerfile="$2"
  local context="${3:-}"

  clibc_require_cmd docker mktemp

  dockerfile="$(clibc_realpath "$dockerfile")"
  [[ -f "$dockerfile" ]] || clibc_die "Docker mode: Dockerfile not found: $dockerfile"

  if [[ -n "$context" ]]; then
    context="$(clibc_realpath "$context")"
  else
    context="$(dirname -- "$dockerfile")"
  fi
  [[ -d "$context" ]] || clibc_die "Docker mode: build context not found: $context"

  local cache_root
  cache_root="$(clibc_prepare_cache_dir_docker "$(clibc_docker_cache_dir)" "Docker_Download")"
  clibc_log "Docker library cache: $cache_root"

  local image_id
  clibc_log "Building image from Dockerfile: $dockerfile"
  clibc_debug "docker context: $context"
  if clibc_is_debug; then
    local iidfile
    iidfile="$(mktemp /tmp/clibc-docker-iid.XXXXXX)"
    clibc_debug "docker build --progress=plain --iidfile $iidfile -f $dockerfile $context"
    if ! docker build --progress=plain --iidfile "$iidfile" -f "$dockerfile" "$context"; then
      rm -f -- "$iidfile"
      clibc_die "Docker mode: docker build failed (interrupted or build error)"
    fi
    image_id="$(cat -- "$iidfile" 2>/dev/null || true)"
    rm -f -- "$iidfile"
  else
    image_id="$(docker build -q -f "$dockerfile" "$context")" || clibc_die "Docker mode: docker build failed"
  fi
  [[ -n "$image_id" ]] || clibc_die "Docker mode: empty image id from docker build"
  clibc_debug "docker image id: $image_id"

  local image_key cache_dir cache_rootfs cache_ready
  image_key="${image_id#sha256:}"
  cache_dir="$cache_root/$image_key"
  cache_rootfs="$cache_dir/rootfs"
  cache_ready="$cache_dir/.ready"

  if [[ -f "$cache_ready" && -d "$cache_rootfs" ]]; then
    clibc_log "Using cached Docker libraries: $cache_dir"
    cp -a -- "$cache_rootfs"/. "$local_libs"/
    clibc_mode_d "$local_libs" "$local_libs"
    SELECTED_VERSION="Dockerfile Mode ($(basename -- "$dockerfile"))"
    return 0
  fi

  local cid tmp rootfs
  clibc_debug "Creating container from image: $image_id"
  cid="$(
    docker create "$image_id" 2>/dev/null ||
      docker create "$image_id" sh -c 'true' 2>/dev/null ||
      docker create "$image_id" /bin/true 2>/dev/null
  )" || clibc_die "Docker mode: docker create failed"
  clibc_debug "container id: $cid"
  tmp="$(mktemp -d /tmp/clibc-docker.XXXXXX)"
  rootfs="$tmp/rootfs"
  mkdir -p -- "$rootfs"

  local copied=0
  local p dest
  for p in /lib /lib64 /usr/lib /usr/lib64 /usr/lib32; do
    dest="$rootfs$p"
    mkdir -p -- "$(dirname -- "$dest")"
    clibc_debug "docker cp $cid:$p -> $dest"
    if docker cp "$cid:$p" "$dest" >/dev/null 2>&1; then
      copied=1
      clibc_debug "copied path: $p"
    else
      clibc_debug "path missing in container: $p"
    fi
  done

  docker rm -f "$cid" >/dev/null 2>&1 || true

  [[ "$copied" -eq 1 ]] || {
    rm -rf -- "$tmp"
    clibc_die "Docker mode: no library directories copied from container"
  }

  rm -rf -- "$cache_dir"
  mkdir -p -- "$cache_rootfs"
  cp -a -- "$rootfs"/. "$cache_rootfs"/
  touch -- "$cache_ready"

  clibc_log "Copying Docker libraries into $local_libs ..."
  cp -a -- "$cache_rootfs"/. "$local_libs"/
  rm -rf -- "$tmp"

  clibc_mode_d "$local_libs" "$local_libs"
  SELECTED_VERSION="Dockerfile Mode ($(basename -- "$dockerfile"))"
}

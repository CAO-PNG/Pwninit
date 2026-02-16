#!/usr/bin/env bash
set -euo pipefail

CLIBC_UBUNTU_MAIN_POOL_URL="${CLIBC_UBUNTU_MAIN_POOL_URL:-https://archive.ubuntu.com/ubuntu/pool/main/g/glibc}"
CLIBC_UBUNTU_DDEB_POOL_URL="${CLIBC_UBUNTU_DDEB_POOL_URL:-https://ddebs.ubuntu.com/pool/main/g/glibc}"

clibc_is_http_url() {
  [[ "$1" == http://* || "$1" == https://* ]]
}

clibc_is_ubuntu_official_url() {
  [[ "$1" =~ ^https?://([A-Za-z0-9.-]+\.)?ubuntu\.com/ ]]
}

clibc_effective_proxy() {
  local url="${1:-https://}"
  local proxy=""

  if [[ "$url" == https://* ]]; then
    proxy="${CLIBC_HTTPS_PROXY:-${CLIBC_PROXY:-${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}"
  else
    proxy="${CLIBC_HTTP_PROXY:-${CLIBC_PROXY:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}"
  fi

  printf '%s\n' "$proxy"
}

clibc_ubuntu_cache_dir() {
  local aio_root="${GLIBC_AIO_DIR:-$HOME/CTF_PWN/tools/glibc-all-in-one}"
  printf '%s\n' "${CLIBC_UBUNTU_CACHE_DIR:-$aio_root/Ubuntu_Download}"
}

clibc_prepare_cache_dir_ubuntu() {
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

clibc_download_file() {
  local url="$1"
  local out="$2"
  local proxy
  proxy="$(clibc_effective_proxy "$url")"

  local -a proxy_args=()
  if [[ -n "$proxy" ]]; then
    proxy_args=(--proxy "$proxy")
  fi

  if command -v curl >/dev/null 2>&1; then
    if clibc_is_debug; then
      clibc_debug "curl -fL --retry 2 --connect-timeout 15 ${proxy_args[*]} --output $out $url"
      curl -fL --retry 2 --connect-timeout 15 --verbose "${proxy_args[@]}" --output "$out" "$url"
    else
      curl -fL --retry 2 --connect-timeout 15 "${proxy_args[@]}" --output "$out" "$url"
    fi
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$proxy" ]]; then
      if [[ "$url" == https://* ]]; then
        clibc_is_debug && clibc_debug "wget --proxy=on -e https_proxy=$proxy -O $out $url"
        wget --proxy=on -e "https_proxy=$proxy" $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") "$out" "$url"
      else
        clibc_is_debug && clibc_debug "wget --proxy=on -e http_proxy=$proxy -O $out $url"
        wget --proxy=on -e "http_proxy=$proxy" $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") "$out" "$url"
      fi
    else
      clibc_is_debug && clibc_debug "wget -O $out $url"
      wget $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") "$out" "$url"
    fi
    return $?
  fi
  clibc_die "Ubuntu mode requires curl or wget to download packages"
}

clibc_download_text() {
  local url="$1"
  local proxy
  proxy="$(clibc_effective_proxy "$url")"

  local -a proxy_args=()
  if [[ -n "$proxy" ]]; then
    proxy_args=(--proxy "$proxy")
  fi

  if command -v curl >/dev/null 2>&1; then
    if clibc_is_debug; then
      clibc_debug "curl -fsSL --retry 2 --connect-timeout 15 ${proxy_args[*]} $url"
      curl -fsSL --retry 2 --connect-timeout 15 --verbose "${proxy_args[@]}" "$url"
    else
      curl -fsSL --retry 2 --connect-timeout 15 "${proxy_args[@]}" "$url"
    fi
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    if [[ -n "$proxy" ]]; then
      if [[ "$url" == https://* ]]; then
        clibc_is_debug && clibc_debug "wget --proxy=on -e https_proxy=$proxy -O - $url"
        wget --proxy=on -e "https_proxy=$proxy" $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") - "$url"
      else
        clibc_is_debug && clibc_debug "wget --proxy=on -e http_proxy=$proxy -O - $url"
        wget --proxy=on -e "http_proxy=$proxy" $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") - "$url"
      fi
    else
      clibc_is_debug && clibc_debug "wget -O - $url"
      wget $([[ -n "${CLIBC_DEBUG:-}" && "${CLIBC_DEBUG:-0}" != "0" ]] && echo "-O" || echo "-qO") - "$url"
    fi
    return $?
  fi
  clibc_die "Ubuntu mode requires curl or wget"
}

clibc_trim_trailing_slash() {
  local s="$1"
  while [[ "$s" == */ ]]; do
    s="${s%/}"
  done
  printf '%s\n' "$s"
}

clibc_ubuntu_pick_file() {
  local base_url="$1"
  local pkg_name="$2"
  local ver="$3"
  local deb_arch="$4"
  local ext="$5"

  local html raw_names name real_ver
  html="$(clibc_download_text "$base_url/")" || return 1
  raw_names="$(
    grep -oE "${pkg_name}_[^\"'<>[:space:]]+_${deb_arch}\\.${ext}" <<<"$html" |
      sort -u || true
  )"
  [[ -n "$raw_names" ]] || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    real_ver="${name#${pkg_name}_}"
    real_ver="${real_ver%_${deb_arch}.${ext}}"
    if [[ "$real_ver" == "$ver" || "$real_ver" == "$ver"* ]]; then
      printf '%s\n' "$name"
    fi
  done <<<"$raw_names" |
    sort -V |
    tail -n 1
}

clibc_ubuntu_resolve_version_refs() {
  local ver="$1"
  local deb_arch="$2"

  local main_pool ddeb_pool
  main_pool="$(clibc_trim_trailing_slash "$CLIBC_UBUNTU_MAIN_POOL_URL")"
  ddeb_pool="$(clibc_trim_trailing_slash "$CLIBC_UBUNTU_DDEB_POOL_URL")"
  clibc_debug "resolve version refs: ver=$ver arch=$deb_arch"
  clibc_debug "main pool: $main_pool"
  clibc_debug "ddeb pool: $ddeb_pool"

  local -a refs=()
  local file

  file="$(clibc_ubuntu_pick_file "$main_pool" "libc6" "$ver" "$deb_arch" "deb" || true)"
  [[ -n "$file" ]] && refs+=("$main_pool/$file")

  file="$(clibc_ubuntu_pick_file "$main_pool" "libc6-dbg" "$ver" "$deb_arch" "deb" || true)"
  [[ -n "$file" ]] && refs+=("$main_pool/$file")

  file="$(clibc_ubuntu_pick_file "$ddeb_pool" "libc6-dbgsym" "$ver" "$deb_arch" "ddeb" || true)"
  [[ -n "$file" ]] && refs+=("$ddeb_pool/$file")

  if [[ "${#refs[@]}" -eq 0 ]]; then
    clibc_die "Ubuntu mode: cannot resolve version prefix '$ver' for arch '$deb_arch'. Try full version (e.g. 2.39-0ubuntu8.6) or direct deb URL/path."
  fi
  clibc_debug "resolved refs: ${refs[*]}"

  printf '%s\n' "${refs[@]}"
}

# 参数:
#   $1 local_libs
#   $2 deb_arch (amd64/i386)
#   $3... refs: ver 或 deb url/path 列表
clibc_mode_ubuntu() {
  local local_libs="$1"
  local deb_arch="$2"
  shift 2

  clibc_require_cmd dpkg-deb mktemp grep sort tail

  local -a refs=()
  if [[ $# -eq 1 ]] && ! clibc_is_http_url "$1" && [[ ! -f "$1" ]]; then
    local ver="$1"
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && refs+=("$ref")
    done < <(clibc_ubuntu_resolve_version_refs "$ver" "$deb_arch")
  else
    refs=("$@")
  fi
  clibc_debug "ubuntu mode refs count: ${#refs[@]}"

  local proxy_for_log
  proxy_for_log="$(clibc_effective_proxy "https://archive.ubuntu.com")"
  if [[ -n "$proxy_for_log" ]]; then
    clibc_log "Ubuntu mode proxy enabled: $proxy_for_log"
  fi

  local cache_dir
  cache_dir="$(clibc_prepare_cache_dir_ubuntu "$(clibc_ubuntu_cache_dir)" "Ubuntu_Download")"
  clibc_log "Ubuntu package cache: $cache_dir"

  local tmp pkg_dir ext_dir
  tmp="$(mktemp -d /tmp/clibc-ubuntu.XXXXXX)"
  pkg_dir="$tmp/pkgs"
  ext_dir="$tmp/extract"
  mkdir -p -- "$pkg_dir" "$ext_dir"

  local extracted_count=0
  local ref pkg cached_pkg tmp_pkg
  for ref in "${refs[@]}"; do
    pkg=""
    if clibc_is_http_url "$ref"; then
      clibc_is_ubuntu_official_url "$ref" || clibc_die "Ubuntu mode only allows ubuntu.com URLs: $ref"
      cached_pkg="$cache_dir/$(basename -- "${ref%%\?*}")"
      if [[ -f "$cached_pkg" ]] && dpkg-deb -I "$cached_pkg" >/dev/null 2>&1; then
        clibc_log "Using cached Ubuntu package: $cached_pkg"
      else
        clibc_log "Downloading Ubuntu package: $ref"
        if ! clibc_download_file "$ref" "$cached_pkg"; then
          clibc_warn "Download to cache failed: $cached_pkg"
          tmp_pkg="$pkg_dir/$(basename -- "${ref%%\?*}")"
          clibc_warn "Retry download to temp: $tmp_pkg"
          if ! clibc_download_file "$ref" "$tmp_pkg"; then
            clibc_warn "Download failed: $ref"
            rm -f -- "$tmp_pkg"
            continue
          fi
          pkg="$tmp_pkg"
          rm -f -- "$cached_pkg" 2>/dev/null || true
        else
          pkg="$cached_pkg"
        fi
      fi
      if [[ -z "${pkg:-}" ]]; then
        pkg="$cached_pkg"
      fi
    else
      [[ -f "$ref" ]] || {
        clibc_warn "Skip missing package path: $ref"
        continue
      }
      pkg="$(clibc_realpath "$ref")"

      cached_pkg="$cache_dir/$(basename -- "$pkg")"
      if [[ -f "$cached_pkg" ]] && dpkg-deb -I "$cached_pkg" >/dev/null 2>&1; then
        clibc_log "Using cached Ubuntu package: $cached_pkg"
        pkg="$cached_pkg"
      elif [[ "$pkg" != "$cached_pkg" ]]; then
        clibc_debug "Copy local package to cache: $pkg -> $cached_pkg"
        if cp -f -- "$pkg" "$cached_pkg"; then
          pkg="$cached_pkg"
        else
          clibc_warn "Copy local package to cache failed, use source directly: $pkg"
        fi
      fi
    fi

    if ! dpkg-deb -I "$pkg" >/dev/null 2>&1; then
      clibc_warn "Skip invalid deb package: $pkg"
      continue
    fi

    clibc_log "Extracting package: $pkg"
    dpkg-deb -x "$pkg" "$ext_dir" >/dev/null 2>&1 || {
      clibc_warn "Skip package extraction failure: $pkg"
      continue
    }
    extracted_count=$((extracted_count + 1))
  done

  [[ "$extracted_count" -gt 0 ]] || {
    rm -rf -- "$tmp"
    clibc_die "Ubuntu mode: no valid package extracted"
  }

  clibc_log "Copying extracted files into $local_libs ..."
  cp -a -- "$ext_dir"/. "$local_libs"/
  rm -rf -- "$tmp"

  clibc_mode_d "$local_libs" "$local_libs"
  SELECTED_VERSION="Ubuntu Package Mode"
}

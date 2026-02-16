#!/usr/bin/env bash
set -euo pipefail

clibc_patch_binary() {
  local bin="$1" ld="$2" rpath="$3"

  clibc_log "--------------------------------------"
  clibc_log "Target: $bin"
  clibc_log "LD:     $ld"
  clibc_log "RPATH:  $rpath"
  clibc_log "--------------------------------------"

  patchelf --set-interpreter "$ld" --force-rpath --set-rpath "$rpath" "$bin"
}

clibc_fix_libc_symlink() {
  local libs_dir="$1"
  local libc_file="$2"

  local libc_name
  libc_name="$(basename -- "$libc_file")"

  # 已经叫 libc.so.6：不要 rm/ln，否则很容易搞成 libc.so.6 -> libc.so.6
  if [[ "$libc_name" == "libc.so.6" ]]; then
    clibc_log "libc is already libc.so.6; skip symlink fix."
    return 0
  fi

  rm -f -- "$libs_dir/libc.so.6"
  ln -sf -- "$libc_name" "$libs_dir/libc.so.6"
  clibc_log "Fixed link: libs/libc.so.6 -> $libc_name"
}

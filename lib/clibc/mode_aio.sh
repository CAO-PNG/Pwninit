#!/usr/bin/env bash
set -euo pipefail

clibc_mode_aio() {
  local arch_dir="$1"
  local default_ld="$2"
  local ver="$3"

  local aio="${GLIBC_AIO_DIR:-$HOME/CTF_PWN/tools/glibc-all-in-one}"
  local libs_dir="$aio/libs"
  local list_file="$aio/list"

  [[ -d "$aio" ]] || clibc_die "AIO directory not found: $aio"
  [[ -f "$list_file" ]] || clibc_die "AIO list not found: $list_file"

  SELECTED_VERSION="$(grep -F -- "$ver" "$list_file" | grep "_$arch_dir" | head -n 1 || true)"
  [[ -n "$SELECTED_VERSION" ]] || clibc_die "Version '$ver' ($arch_dir) not found in glibc-all-in-one list"

  RPATH_DIR="$libs_dir/$SELECTED_VERSION"
  LD_FILE="$RPATH_DIR/$default_ld"
  LIBC_FILE="$RPATH_DIR/libc.so.6"

  if [[ ! -d "$RPATH_DIR" ]]; then
    [[ -x "$aio/download" ]] || clibc_die "AIO download helper not executable: $aio/download"
    clibc_log "Downloading $SELECTED_VERSION ..."
    (cd "$aio" && ./download "$SELECTED_VERSION")
  fi

  [[ -f "$LD_FILE" && -f "$LIBC_FILE" ]] || clibc_die "AIO missing files: ld='$LD_FILE' libc='$LIBC_FILE'"
}

#!/usr/bin/env bash
set -euo pipefail

# 安全拷贝：如果源和目标是同一文件，则跳过，避免 cp 返回非 0 导致脚本退出
clibc_cp_into_dir() {
  local src="$1"
  local dir="$2"

  [[ -e "$src" ]] || clibc_die "L mode: missing file: $src"

  local src_real dest dest_real
  src_real="$(clibc_realpath "$src")"
  dest="$dir/$(basename -- "$src")"

  # 如果目标已存在，也取 realpath；否则 dest_real 为空
  if [[ -e "$dest" ]]; then
    dest_real="$(clibc_realpath "$dest")"
  else
    dest_real=""
  fi

  if [[ -n "$dest_real" && "$src_real" == "$dest_real" ]]; then
    clibc_log "Skip copy (same file): $src_real"
    return 0
  fi

  # -L: 如果 src 是符号链接，复制其目标内容，但保留用户给定的文件名
  cp -fL -- "$src" "$dest"
}

# L 模式：local_libs + ld + libc + ext...
# 输出全局：LD_FILE, LIBC_FILE, RPATH_DIR, SELECTED_VERSION
clibc_mode_l() {
  local local_libs="$1"
  local ld_src="$2"
  local libc_src="$3"
  shift 3
  local -a ext=("$@")

  clibc_cp_into_dir "$ld_src" "$local_libs"
  clibc_cp_into_dir "$libc_src" "$local_libs"

  local f
  for f in "${ext[@]}"; do
    clibc_cp_into_dir "$f" "$local_libs"
  done

  LD_FILE="$local_libs/$(basename -- "$ld_src")"
  LIBC_FILE="$local_libs/$(basename -- "$libc_src")"
  RPATH_DIR="\$ORIGIN/libs"
  SELECTED_VERSION="Manual L Mode"
}

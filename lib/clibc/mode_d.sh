#!/usr/bin/env bash
set -euo pipefail

clibc_find_first_elf_by_name() {
  local base_dir="$1"
  local kind="$2"
  local f mime

  while IFS= read -r -d '' f; do
    mime="$(file -Lb -- "$f" || true)"
    case "$kind" in
      ld)
        if [[ "$mime" == *"ELF "* && "$mime" == *"shared object"* ]]; then
          printf '%s\n' "$f"
          return 0
        fi
        ;;
      libc)
        if [[ "$mime" == *"ELF "* && "$mime" == *"shared object"* ]]; then
          printf '%s\n' "$f"
          return 0
        fi
        ;;
      *)
        return 1
        ;;
    esac
  done < <(
    if [[ "$kind" == "ld" ]]; then
      find "$base_dir" \( -type f -o -type l \) \
        \( -name 'ld-*.so*' -o -name 'ld-linux*.so*' \) -print0 2>/dev/null
    else
      find "$base_dir" \( -type f -o -type l \) \
        \( -name 'libc.so.6' -o -name 'libc-*.so*' \) -print0 2>/dev/null
    fi
  )

  return 1
}

clibc_mode_d_build_rpath() {
  local local_libs="$1"
  local ld_file="$2"
  local libc_file="$3"

  local rpath="\$ORIGIN/libs"
  local rel dir candidate

  for candidate in "$ld_file" "$libc_file"; do
    [[ "$candidate" == "$local_libs"/* ]] || continue
    rel="${candidate#"$local_libs"/}"
    dir="$(dirname -- "$rel")"
    [[ "$dir" == "." ]] && continue
    candidate="\$ORIGIN/libs/$dir"
    case ":$rpath:" in
      *":$candidate:"*) ;;
      *) rpath="${rpath}:$candidate" ;;
    esac
  done

  printf '%s\n' "$rpath"
}

# 输出全局：LD_FILE, LIBC_FILE, RPATH_DIR, SELECTED_VERSION
clibc_mode_d() {
  local local_libs="$1"
  local src_dir
  src_dir="$(clibc_realpath "$2")"
  [[ -d "$src_dir" ]] || clibc_die "D mode: not a directory: $src_dir"

  clibc_log "Scanning directory: $src_dir"

  if [[ "$src_dir" != "$(clibc_realpath "$local_libs")" ]]; then
    clibc_log "Copying libraries to $local_libs ..."
    cp -a -- "$src_dir"/. "$local_libs"/
  fi

  # 找 ld/libc：支持普通文件和符号链接；避免 pipefail 导致静默退出
  LD_FILE="$(clibc_find_first_elf_by_name "$local_libs" ld || true)"
  LIBC_FILE="$(clibc_find_first_elf_by_name "$local_libs" libc || true)"

  [[ -n "$LD_FILE" && -n "$LIBC_FILE" ]] || {
    clibc_die "D mode: Could not find valid ld/libc in $local_libs (ld='$LD_FILE', libc='$LIBC_FILE')"
  }

  RPATH_DIR="$(clibc_mode_d_build_rpath "$local_libs" "$LD_FILE" "$LIBC_FILE")"
  SELECTED_VERSION="Directory Scan ($src_dir)"
}

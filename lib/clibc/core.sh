#!/usr/bin/env bash
set -euo pipefail

# 项目根从入口传入；也允许外部覆写（比如安装后）
: "${CLIBC_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"

# 可选配置（优先级：default < user < CLIBC_CONF）
CLIBC_CONF_DEFAULT="$CLIBC_ROOT/etc/clibc.conf"
CLIBC_CONF_USER="${XDG_CONFIG_HOME:-$HOME/.config}/clibc/config"
if [[ -f "$CLIBC_CONF_DEFAULT" ]]; then
  # shellcheck source=/dev/null
  source "$CLIBC_CONF_DEFAULT"
fi
if [[ -f "$CLIBC_CONF_USER" ]]; then
  # shellcheck source=/dev/null
  source "$CLIBC_CONF_USER"
fi
if [[ -n "${CLIBC_CONF:-}" ]]; then
  if [[ ! -f "$CLIBC_CONF" ]]; then
    printf '[-] CLIBC_CONF points to missing file: %s\n' "$CLIBC_CONF" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CLIBC_CONF"
fi

# 加载模块
# shellcheck source=/dev/null
source "$CLIBC_ROOT/lib/clibc/log.sh"
source "$CLIBC_ROOT/lib/clibc/fs.sh"
source "$CLIBC_ROOT/lib/clibc/backup.sh"
source "$CLIBC_ROOT/lib/clibc/detect.sh"
source "$CLIBC_ROOT/lib/clibc/mode_d.sh"
source "$CLIBC_ROOT/lib/clibc/mode_l.sh"
source "$CLIBC_ROOT/lib/clibc/mode_ubuntu.sh"
source "$CLIBC_ROOT/lib/clibc/mode_docker.sh"
source "$CLIBC_ROOT/lib/clibc/mode_aio.sh"
source "$CLIBC_ROOT/lib/clibc/patch.sh"
source "$CLIBC_ROOT/lib/clibc/verify.sh"

clibc_usage() {
  cat <<'EOF'
Usage:
  clibc --debug <bin> <mode_or_ver> ...
  clibc -L|--list
  clibc <bin> -L|--list
  clibc <bin> <ver>                                   # AIO 模式（保留原有）
  clibc <bin> -M|--manual <libs_dir>                  # 原 D 模式
  clibc <bin> -W|--two <ld> <libc> [ext...]           # 原 L 模式
  clibc <bin> -U|--ubuntu <ver|deb_url|deb_path> [...] # Ubuntu 包提取并扫描
  clibc <bin> -D|--docker <dockerfile_path> [context] # Dockerfile 提取并扫描

Env:
  GLIBC_AIO_DIR   # glibc-all-in-one 根目录（默认: ~/CTF_PWN/tools/glibc-all-in-one）
  CLIBC_PROXY / CLIBC_HTTPS_PROXY / CLIBC_HTTP_PROXY  # Ubuntu 模式下载代理，可覆盖系统代理
  CLIBC_UBUNTU_CACHE_DIR  # Ubuntu 包缓存目录（默认: \$GLIBC_AIO_DIR/Ubuntu_Download）
  CLIBC_DOCKER_CACHE_DIR  # Docker 库缓存目录（默认: \$GLIBC_AIO_DIR/Docker_Download）
  CLIBC_DEBUG=1  # 输出构建/下载调试信息
  CLIBC_CONF  # 指定额外配置文件（会覆盖默认与 ~/.config/clibc/config）

Examples:
  clibc ./pwn -M ./libs
  clibc ./pwn --manual ./libs
  clibc ./pwn -W ./ld-linux-x86-64.so.2 ./libc.so.6
  clibc ./pwn -U 2.35-0ubuntu3.8
  clibc ./pwn -U https://archive.ubuntu.com/ubuntu/pool/main/g/glibc/libc6_2.35-0ubuntu3.8_amd64.deb
  clibc ./pwn -D ./Dockerfile .
EOF
}

clibc_is_list_flag() {
  local s="${1:-}"
  [[ "$s" == "-L" || "$s" == "--list" || "$s" == "-h" || "$s" == "--help" ]]
}

# 这些变量作为“模块间传递结果”的全局输出
# LD_FILE, LIBC_FILE, RPATH_DIR, SELECTED_VERSION

clibc_main() {
  if [[ $# -eq 0 ]]; then
    clibc_usage
    return 1
  fi

  if [[ "${1:-}" == "--debug" ]]; then
    export CLIBC_DEBUG=1
    shift
  fi

  if clibc_is_list_flag "$1"; then
    clibc_usage
    return 0
  fi

  if [[ $# -lt 2 ]]; then
    clibc_usage
    return 1
  fi

  local binary="$1"
  local mode_or_ver="$2"
  shift 2

  if [[ "$mode_or_ver" == "--debug" ]]; then
    export CLIBC_DEBUG=1
    [[ $# -gt 0 ]] || clibc_die "--debug requires a mode/version after it"
    mode_or_ver="$1"
    shift
  fi

  if clibc_is_list_flag "$mode_or_ver"; then
    clibc_usage
    return 0
  fi

  if [[ "$mode_or_ver" == "D" || "$mode_or_ver" == "L" ]]; then
    clibc_die "Legacy mode '$mode_or_ver' removed. Use --manual/-M or --two/-W."
  fi

  clibc_require_cmd file patchelf ldd realpath find grep head cp ln rm mkdir
  clibc_ensure_elf "$binary"

  clibc_backup_restore "$binary"

  local arch_dir default_ld deb_arch
  clibc_detect_arch "$binary" arch_dir default_ld
  case "$arch_dir" in
    amd64 | i386) deb_arch="$arch_dir" ;;
    *) deb_arch="$arch_dir" ;;
  esac

  local binary_real binary_dir local_libs
  binary_real="$(clibc_realpath "$binary")"
  binary_dir="$(dirname -- "$binary_real")"
  local_libs="$binary_dir/libs"
  mkdir -p -- "$local_libs"
  clibc_debug "binary=$binary_real"
  clibc_debug "mode_or_ver=$mode_or_ver"
  clibc_debug "local_libs=$local_libs"

  # 清空“输出”
  LD_FILE=""
  LIBC_FILE=""
  RPATH_DIR=""
  SELECTED_VERSION=""
  local mode_kind=""

  case "$mode_or_ver" in
    -M|--manual)
      [[ $# -eq 1 ]] || clibc_die "--manual/-M requires exactly one argument: <libs_dir>"
      clibc_mode_d "$local_libs" "$1"
      mode_kind="manual"
      ;;
    -W|--two)
      [[ $# -ge 2 ]] || clibc_die "--two/-W requires <ld> <libc> [ext...]"
      clibc_mode_l "$local_libs" "$@"
      mode_kind="two"
      ;;
    -U|--ubuntu)
      [[ $# -ge 1 ]] || clibc_die "--ubuntu/-U requires <ver|deb_url|deb_path> [...]"
      clibc_mode_ubuntu "$local_libs" "$deb_arch" "$@"
      mode_kind="ubuntu"
      ;;
    -D|--docker)
      [[ $# -ge 1 && $# -le 2 ]] || clibc_die "--docker/-D requires <dockerfile_path> [context]"
      clibc_mode_docker "$local_libs" "$1" "${2:-}"
      mode_kind="docker"
      ;;
    --*|-*)
      clibc_die "Unknown option: $mode_or_ver (use --list to view all commands)"
      ;;
    *)
      local ver="$mode_or_ver"
      clibc_mode_aio "$arch_dir" "$default_ld" "$ver"
      mode_kind="aio"
      ;;
  esac

  [[ -n "$LD_FILE" && -n "$LIBC_FILE" && -n "$RPATH_DIR" ]] || {
    clibc_die "Could not resolve ld/libc/rpath (ld='$LD_FILE', libc='$LIBC_FILE', rpath='$RPATH_DIR')"
  }
  [[ -f "$LD_FILE" ]] || clibc_die "Resolved ld is not a file: $LD_FILE"
  [[ -e "$LIBC_FILE" ]] || clibc_die "Resolved libc does not exist: $LIBC_FILE"
  if [[ "$RPATH_DIR" != \$ORIGIN/* ]]; then
    [[ -d "$RPATH_DIR" ]] || clibc_die "Resolved rpath directory does not exist: $RPATH_DIR"
  fi

  clibc_patch_binary "$binary" "$LD_FILE" "$RPATH_DIR"

  if [[ "$mode_kind" != "aio" ]]; then
    clibc_fix_libc_symlink "$local_libs" "$LIBC_FILE"
  fi

  clibc_verify_ldd "$binary" "$SELECTED_VERSION"
}

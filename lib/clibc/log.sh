#!/usr/bin/env bash
set -euo pipefail

clibc_log() { printf '[*] %s\n' "$*"; }
clibc_warn() { printf '[!] %s\n' "$*" >&2; }
clibc_is_debug() {
  case "${CLIBC_DEBUG:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}
clibc_debug() {
  if clibc_is_debug; then
    printf '[D] %s\n' "$*"
  fi
}
clibc_die() {
  printf '[-] %s\n' "$*" >&2
  exit 1
}

clibc_require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || clibc_die "Missing command: $c"
  done
}

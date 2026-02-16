#!/usr/bin/env bash
set -euo pipefail

# clibc_detect_arch <bin> <out_arch_var> <out_default_ld_var>
clibc_detect_arch() {
  local bin="$1"
  local out_arch="$2"
  local out_ld="$3"

  local info
  info="$(file -b -- "$bin")"

  if [[ "$info" == *"ELF 32-bit"* ]]; then
    printf -v "$out_arch" '%s' "i386"
    printf -v "$out_ld" '%s' "ld-linux.so.2"
  elif [[ "$info" == *"ELF 64-bit"* ]]; then
    printf -v "$out_arch" '%s' "amd64"
    printf -v "$out_ld" '%s' "ld-linux-x86-64.so.2"
  else
    clibc_die "Unsupported ELF: $info"
  fi
}

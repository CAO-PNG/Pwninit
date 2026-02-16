#!/usr/bin/env bash
set -euo pipefail

clibc_realpath() {
  realpath -- "$1"
}

clibc_ensure_elf() {
  [[ -f "$1" ]] || clibc_die "No such file: $1"
  local info
  info="$(file -b -- "$1")"
  [[ "$info" == *"ELF "* ]] || clibc_die "Not an ELF: $1"
}

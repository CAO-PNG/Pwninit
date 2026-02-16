#!/usr/bin/env bash
set -euo pipefail

clibc_verify_ldd() {
  local bin="$1"
  local sel="${2:-}"
  local out

  if ! out="$(ldd "$bin" 2>&1)"; then
    clibc_warn "ldd failed for $bin; patched file may still be usable with manual loader execution."
    printf '%s\n' "$out" >&2
    return 0
  fi

  if grep -q "not found" <<<"$out"; then
    clibc_warn "Some dependencies are still missing!"
    grep "not found" <<<"$out" || true
    return 0
  fi

  clibc_log "Success: Patched successfully${sel:+ with $sel}"
}

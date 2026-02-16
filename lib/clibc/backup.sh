#!/usr/bin/env bash
set -euo pipefail

clibc_backup_restore() {
  local bin="$1"
  local bak="${bin}.bak"
  if [[ ! -f "$bak" ]]; then
    clibc_log "Creating backup: $bak"
    cp -- "$bin" "$bak"
  else
    clibc_log "Restoring from backup: $bak"
    cp -f -- "$bak" "$bin"
  fi
}

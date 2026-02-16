#!/usr/bin/env bash
set -euo pipefail

: "${PWNINIT_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
: "${CLIBC_ROOT:=$PWNINIT_ROOT}"

# shellcheck source=/dev/null
source "$PWNINIT_ROOT/lib/clibc/core.sh"

PWNINIT_BLUE='\033[0;34m'
PWNINIT_GREEN='\033[0;32m'
PWNINIT_YELLOW='\033[1;33m'
PWNINIT_RED='\033[0;31m'
PWNINIT_NC='\033[0m'

pwninit_info() { printf "${PWNINIT_BLUE}[*] %s${PWNINIT_NC}\n" "$*"; }
pwninit_ok() { printf "${PWNINIT_GREEN}[+] %s${PWNINIT_NC}\n" "$*"; }
pwninit_warn() { printf "${PWNINIT_YELLOW}[!] %s${PWNINIT_NC}\n" "$*" >&2; }
pwninit_die() {
  printf "${PWNINIT_RED}[-] %s${PWNINIT_NC}\n" "$*" >&2
  exit 1
}

pwninit_usage() {
  cat <<'EOF'
Usage:
  pwninit [options] <binary> [clibc_args...]

Options:
  --debug            Enable verbose clibc debug logs
  --skip-venv-check  Skip Python virtualenv check
  --skip-checksec    Skip checksec step
  --skip-exp         Do not create exp.py
  --force-exp        Overwrite exp.py if it already exists
  --only-init        Run init steps only (ignore clibc_args)
  --only-libc        Run clibc patch steps only (requires clibc_args)
  -h, --help         Show this help

clibc_args:
  -M|--manual <libs_dir>
  -W|--two <ld> <libc> [ext...]
  -U|--ubuntu <ver|deb_url|deb_path> [...]
  -D|--docker <dockerfile_path> [context]
  <ver> (glibc-all-in-one mode)

Examples:
  pwninit ./pwn
  pwninit ./pwn -U 2.39
  pwninit --skip-venv-check ./pwn -M ./libs
  pwninit --only-libc ./pwn -W ./ld-linux-x86-64.so.2 ./libc.so.6
  pwninit --debug --only-libc ./pwn -D ./Dockerfile
EOF
}

pwninit_check_venv() {
  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    pwninit_info "Virtualenv: $(basename -- "$VIRTUAL_ENV")"
    return 0
  fi
  pwninit_warn "Not in virtualenv, continue anyway."
  pwninit_warn "Tip: activate your env if you need pwntools/checksec from that env."
  return 0
}

pwninit_run_checksec() {
  local binary="$1"
  local py=""
  local checksec_bin=""
  local pwn_bin=""

  pwninit_info "checksec: $binary"
  printf '==================================\n'

  # 优先使用当前虚拟环境里的二进制，避免误用全局 pyenv 环境
  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/checksec" ]]; then
    checksec_bin="${VIRTUAL_ENV}/bin/checksec"
  elif command -v checksec >/dev/null 2>&1; then
    checksec_bin="$(command -v checksec)"
  fi

  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/pwn" ]]; then
    pwn_bin="${VIRTUAL_ENV}/bin/pwn"
  elif command -v pwn >/dev/null 2>&1; then
    pwn_bin="$(command -v pwn)"
  fi

  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python3" ]]; then
    py="${VIRTUAL_ENV}/bin/python3"
  elif [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python" ]]; then
    py="${VIRTUAL_ENV}/bin/python"
  elif command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    py="$(command -v python)"
  fi

  if [[ -n "$checksec_bin" ]]; then
    "$checksec_bin" "$binary" || pwninit_warn "checksec returned non-zero"
  elif [[ -n "$pwn_bin" ]]; then
    "$pwn_bin" checksec "$binary" || pwninit_warn "pwn checksec returned non-zero"
  else
    if [[ -n "$py" ]] && "$py" -c "import pwnlib" >/dev/null 2>&1; then
      if ! "$py" -m pwnlib.commandline.checksec "$binary"; then
        # 最后兜底：直接用 pwntools API 输出 checksec 字段
        "$py" -c 'import sys; from pwn import ELF; print(ELF(sys.argv[1]).checksec())' "$binary" \
          || pwninit_warn "Python pwntools checksec fallback returned non-zero"
      fi
    else
      pwninit_warn "checksec not found (tried venv/global checksec, pwn, and python pwnlib)."
    fi
  fi
  printf '==================================\n'
}

pwninit_detect_pwntools_arch() {
  local binary="$1"
  local info
  info="$(file -b -- "$binary")"
  if [[ "$info" == *"ELF 32-bit"* ]]; then
    printf '%s\n' "i386"
  elif [[ "$info" == *"ELF 64-bit"* ]]; then
    printf '%s\n' "amd64"
  else
    printf '%s\n' "amd64"
  fi
}

pwninit_generate_exp() {
  local binary="$1"
  local force="$2"
  local output="exp.py"
  local arch
  arch="$(pwninit_detect_pwntools_arch "$binary")"

  if [[ -f "$output" && "$force" -ne 1 ]]; then
    pwninit_warn "exp.py already exists, skipped (use --force-exp to overwrite)."
    return 0
  fi

  cat >"$output" <<EOF
#!/usr/bin/env python3
from pwn import *

context(os="linux", arch="${arch}", log_level="debug")
binary = "${binary}"
elf = ELF(binary)
libc = elf.libc

if args.REMOTE:
    io = remote("127.0.0.1", 8080)
else:
    io = process(binary)

def exp():
    pass

if __name__ == "__main__":
    exp()
    io.interactive()
EOF

  chmod +x -- "$output"
  pwninit_ok "Generated exp.py"
}

pwninit_main() {
  local skip_venv_check=0
  local skip_checksec=0
  local skip_exp=0
  local force_exp=0
  local debug_mode=0
  local only_init=0
  local only_libc=0
  local binary=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        pwninit_usage
        return 0
        ;;
      --skip-venv-check)
        skip_venv_check=1
        shift
        ;;
      --debug)
        debug_mode=1
        shift
        ;;
      --skip-checksec)
        skip_checksec=1
        shift
        ;;
      --skip-exp)
        skip_exp=1
        shift
        ;;
      --force-exp)
        force_exp=1
        shift
        ;;
      --only-init)
        only_init=1
        shift
        ;;
      --only-libc)
        only_libc=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        pwninit_die "Unknown option before binary: $1"
        ;;
      *)
        binary="$1"
        shift
        break
        ;;
    esac
  done

  [[ -n "$binary" ]] || {
    pwninit_usage
    return 1
  }

  [[ "$only_init" -eq 1 && "$only_libc" -eq 1 ]] && pwninit_die "--only-init and --only-libc cannot be used together."
  [[ -f "$binary" ]] || pwninit_die "Binary not found: $binary"
  if [[ "$debug_mode" -eq 1 ]]; then
    export CLIBC_DEBUG=1
    pwninit_info "Debug enabled (CLIBC_DEBUG=1)"
  fi

  local -a libc_args=("$@")
  if [[ "$only_libc" -eq 1 && "${#libc_args[@]}" -eq 0 ]]; then
    pwninit_die "--only-libc requires clibc_args"
  fi

  if [[ "$only_libc" -ne 1 ]]; then
    if [[ "$skip_venv_check" -ne 1 ]]; then
      pwninit_check_venv
    fi

    chmod +x -- "$binary"
    pwninit_ok "Set executable: $binary"

    if [[ "$skip_checksec" -ne 1 ]]; then
      pwninit_run_checksec "$binary"
    fi
    if [[ "$skip_exp" -ne 1 ]]; then
      pwninit_generate_exp "$binary" "$force_exp"
    fi
  fi

  if [[ "$only_init" -ne 1 && "${#libc_args[@]}" -gt 0 ]]; then
    pwninit_info "Running clibc flow: ${libc_args[*]}"
    clibc_main "$binary" "${libc_args[@]}"
  elif [[ "$only_init" -eq 1 ]]; then
    pwninit_info "Init only mode, clibc skipped."
  fi

  pwninit_ok "Done."
}

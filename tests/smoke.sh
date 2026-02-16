#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLIBC_BIN="$ROOT/bin/clibc"
PWNINIT_BIN="$ROOT/bin/pwninit"

PASS_COUNT=0
SKIP_COUNT=0

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
skip() { printf '[~] %s\n' "$*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
fail() {
  printf '[-] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
  done
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  [[ "$expected" == "$actual" ]] || fail "$msg (expected='$expected', actual='$actual')"
}

assert_file_exists() {
  local path="$1"
  local msg="$2"
  [[ -e "$path" ]] || fail "$msg (missing '$path')"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  grep -Fq -- "$needle" <<<"$haystack" || fail "$msg (missing '$needle')"
}

detect_host_libs() {
  local out
  out="$(ldd /bin/true 2>/dev/null || true)"

  HOST_LIBC="$(printf '%s\n' "$out" | awk '/libc\.so\.6 =>/ { print $3; exit }')"
  HOST_LD="$(printf '%s\n' "$out" | awk '/ld-linux/ { for (i = 1; i <= NF; i++) if ($i ~ /^\//) { print $i; exit } }')"

  if [[ -z "${HOST_LD:-}" ]]; then
    HOST_LD="$(patchelf --print-interpreter /bin/true 2>/dev/null || true)"
  fi

  [[ -n "${HOST_LIBC:-}" ]] || fail "could not detect host libc from ldd /bin/true"
  [[ -n "${HOST_LD:-}" ]] || fail "could not detect host ld from ldd/patchelf"
  assert_file_exists "$HOST_LIBC" "detected host libc is invalid"
  assert_file_exists "$HOST_LD" "detected host ld is invalid"
}

detect_binary_arch() {
  local info
  info="$(file -b -- /bin/true)"
  if [[ "$info" == *"ELF 32-bit"* ]]; then
    AIO_ARCH_DIR="i386"
    AIO_DEFAULT_LD="ld-linux.so.2"
  elif [[ "$info" == *"ELF 64-bit"* ]]; then
    AIO_ARCH_DIR="amd64"
    AIO_DEFAULT_LD="ld-linux-x86-64.so.2"
  else
    fail "unsupported host arch for test: $info"
  fi
}

test_two_mode() {
  local case_dir="$WORK_DIR/l_mode"
  local src_dir="$case_dir/src"
  local bin="$case_dir/true_l"

  mkdir -p -- "$src_dir"
  cp -- /bin/true "$bin"

  ln -s -- "$HOST_LD" "$src_dir/custom-ld.so"
  ln -s -- "$HOST_LIBC" "$src_dir/custom-libc.so"

  "$CLIBC_BIN" "$bin" -W "$src_dir/custom-ld.so" "$src_dir/custom-libc.so"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"

  assert_eq "$case_dir/libs/custom-ld.so" "$interp" "L mode interpreter mismatch"
  assert_eq "\$ORIGIN/libs" "$rpath" "L mode rpath mismatch"
  assert_file_exists "$case_dir/libs/libc.so.6" "L mode libc symlink/file missing"

  "$bin" >/dev/null
  ok "two mode (-W/--two)"
}

test_manual_mode() {
  local case_dir="$WORK_DIR/d_mode"
  local src_dir="$case_dir/src"
  local bin="$case_dir/true_d"
  local ld_name

  mkdir -p -- "$src_dir"
  cp -- /bin/true "$bin"

  ld_name="$(basename -- "$HOST_LD")"
  ln -s -- "$HOST_LD" "$src_dir/$ld_name"
  ln -s -- "$HOST_LIBC" "$src_dir/libc.so.6"

  "$CLIBC_BIN" "$bin" --manual "$src_dir"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"

  assert_eq "$case_dir/libs/$ld_name" "$interp" "D mode interpreter mismatch"
  assert_eq "\$ORIGIN/libs" "$rpath" "D mode rpath mismatch"
  assert_file_exists "$case_dir/libs/libc.so.6" "D mode libc.so.6 missing"

  "$bin" >/dev/null
  ok "manual mode (-M/--manual)"
}

test_ubuntu_mode() {
  command -v dpkg-deb >/dev/null 2>&1 || {
    skip "ubuntu mode (dpkg-deb missing)"
    return 0
  }

  local case_dir="$WORK_DIR/ubuntu_mode"
  local pkg_root="$case_dir/pkg"
  local deb_file="$case_dir/libc6-test.deb"
  local bin="$case_dir/true_ubuntu"
  local arch

  mkdir -p -- "$pkg_root/DEBIAN" "$pkg_root/usr/lib" "$case_dir"
  cp -- /bin/true "$bin"

  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  cat >"$pkg_root/DEBIAN/control" <<EOF
Package: libc6-test
Version: 0.0.1
Section: libs
Priority: optional
Architecture: $arch
Maintainer: clibc-test <test@example.com>
Description: local test package for clibc ubuntu mode
EOF

  cp -fL -- "$HOST_LD" "$pkg_root/usr/lib/$(basename -- "$HOST_LD")"
  cp -fL -- "$HOST_LIBC" "$pkg_root/usr/lib/libc.so.6"
  dpkg-deb --build "$pkg_root" "$deb_file" >/dev/null

  "$CLIBC_BIN" "$bin" --ubuntu "$deb_file"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"

  assert_eq "$case_dir/libs/usr/lib/$(basename -- "$HOST_LD")" "$interp" "Ubuntu mode interpreter mismatch"
  assert_contains "$rpath" "\$ORIGIN/libs" "Ubuntu mode rpath missing libs root"
  assert_contains "$rpath" "\$ORIGIN/libs/usr/lib" "Ubuntu mode rpath missing extracted subdir"

  "$bin" >/dev/null
  ok "ubuntu mode (-U/--ubuntu)"
}

test_aio_mode() {
  local case_dir="$WORK_DIR/aio_mode"
  local aio_dir="$case_dir/aio"
  local bin="$case_dir/true_aio"
  local ver="testglibc"
  local selected="${ver}_${AIO_ARCH_DIR}"

  mkdir -p -- "$aio_dir/libs/$selected" "$case_dir"
  cp -- /bin/true "$bin"
  printf '%s\n' "$selected" >"$aio_dir/list"

  cp -fL -- "$HOST_LD" "$aio_dir/libs/$selected/$AIO_DEFAULT_LD"
  cp -fL -- "$HOST_LIBC" "$aio_dir/libs/$selected/libc.so.6"

  GLIBC_AIO_DIR="$aio_dir" "$CLIBC_BIN" "$bin" "$ver"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"

  assert_eq "$aio_dir/libs/$selected/$AIO_DEFAULT_LD" "$interp" "AIO mode interpreter mismatch"
  assert_eq "$aio_dir/libs/$selected" "$rpath" "AIO mode rpath mismatch"

  "$bin" >/dev/null
  ok "AIO mode (legacy positional version)"
}

test_list_mode() {
  local out
  out="$("$CLIBC_BIN" --list)"
  assert_contains "$out" "--manual" "list output missing manual mode"
  assert_contains "$out" "--two" "list output missing two mode"
  assert_contains "$out" "--ubuntu" "list output missing ubuntu mode"
  assert_contains "$out" "--docker" "list output missing docker mode"
  assert_contains "$out" "<ver>" "list output missing aio mode"
  ok "list mode (-L/--list)"
}

test_legacy_mode_rejected() {
  local case_dir="$WORK_DIR/legacy_reject"
  local src_dir="$case_dir/src"
  local bin="$case_dir/true_legacy"
  local err_file="$case_dir/err.txt"

  mkdir -p -- "$src_dir"
  cp -- /bin/true "$bin"
  ln -s -- "$HOST_LD" "$src_dir/ld-linux-x86-64.so.2" 2>/dev/null || true
  ln -s -- "$HOST_LIBC" "$src_dir/libc.so.6"

  if "$CLIBC_BIN" "$bin" D "$src_dir" >/dev/null 2>"$err_file"; then
    fail "legacy mode D should be rejected"
  fi

  grep -Fq "Legacy mode" "$err_file" || fail "legacy mode rejection message mismatch"
  ok "legacy mode rejection (D/L)"
}

test_docker_mode_optional() {
  if [[ "${CLIBC_TEST_DOCKER:-0}" != "1" ]]; then
    skip "docker mode (set CLIBC_TEST_DOCKER=1 to enable)"
    return 0
  fi
  command -v docker >/dev/null 2>&1 || {
    skip "docker mode (docker command missing)"
    return 0
  }
  if ! docker info >/dev/null 2>&1; then
    skip "docker mode (docker daemon unavailable)"
    return 0
  fi

  local case_dir="$WORK_DIR/docker_mode"
  local ctx="$case_dir/context"
  local dockerfile="$ctx/Dockerfile"
  local bin="$case_dir/true_docker"
  local ld_name

  mkdir -p -- "$ctx/lib" "$ctx/bin" "$case_dir"
  cp -- /bin/true "$bin"
  cp -fL -- /bin/true "$ctx/bin/true"

  ld_name="$(basename -- "$HOST_LD")"
  cp -fL -- "$HOST_LD" "$ctx/lib/$ld_name"
  cp -fL -- "$HOST_LIBC" "$ctx/lib/libc.so.6"

  cat >"$dockerfile" <<'EOF'
FROM scratch
COPY bin/true /bin/true
COPY lib/ /lib/
CMD ["/bin/true"]
EOF

  "$CLIBC_BIN" "$bin" --docker "$dockerfile" "$ctx"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"

  assert_eq "$case_dir/libs/lib/$ld_name" "$interp" "Docker mode interpreter mismatch"
  assert_eq "\$ORIGIN/libs" "$rpath" "Docker mode rpath mismatch"

  "$bin" >/dev/null
  ok "docker mode (-D/--docker)"
}

test_pwninit_integration() {
  local case_dir="$WORK_DIR/pwninit_mode"
  local src_dir="$case_dir/src"
  local bin="$case_dir/true_pwninit"
  local ld_name

  mkdir -p -- "$src_dir" "$case_dir"
  cp -- /bin/true "$bin"
  ld_name="$(basename -- "$HOST_LD")"
  ln -s -- "$HOST_LD" "$src_dir/$ld_name"
  ln -s -- "$HOST_LIBC" "$src_dir/libc.so.6"

  (
    cd "$case_dir"
    "$PWNINIT_BIN" --skip-venv-check --skip-checksec --force-exp ./true_pwninit -M ./src
  )

  assert_file_exists "$case_dir/exp.py" "pwninit did not generate exp.py"
  assert_file_exists "$case_dir/true_pwninit.bak" "pwninit did not create backup"

  local interp rpath
  interp="$(patchelf --print-interpreter "$bin")"
  rpath="$(patchelf --print-rpath "$bin")"
  assert_eq "$case_dir/libs/$ld_name" "$interp" "pwninit+clibc interpreter mismatch"
  assert_eq "\$ORIGIN/libs" "$rpath" "pwninit+clibc rpath mismatch"

  "$bin" >/dev/null
  ok "pwninit integration"
}

main() {
  require_cmd bash file ldd patchelf awk grep cp ln rm mktemp
  [[ -x "$CLIBC_BIN" ]] || fail "entrypoint not executable: $CLIBC_BIN"
  [[ -x "$PWNINIT_BIN" ]] || fail "entrypoint not executable: $PWNINIT_BIN"

  detect_host_libs
  detect_binary_arch

  WORK_DIR="$(mktemp -d /tmp/clibc-smoke.XXXXXX)"
  trap '[[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf -- "$WORK_DIR"' EXIT

  log "workdir: $WORK_DIR"
  log "host ld: $HOST_LD"
  log "host libc: $HOST_LIBC"

  test_list_mode
  test_two_mode
  test_manual_mode
  test_ubuntu_mode
  test_legacy_mode_rejected
  test_docker_mode_optional
  test_aio_mode
  test_pwninit_integration

  printf '\n[+] Tests passed: %d, skipped: %d\n' "$PASS_COUNT" "$SKIP_COUNT"
}

main "$@"

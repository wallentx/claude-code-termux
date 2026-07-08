#!/usr/bin/env bash
# Run binary-only Termux compatibility checks for the Claude launcher.
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

NETWORK=0
AUTH_PROBE=0
SKIP_BUILD=0
SKIP_SHELLCHECK=0
PAYLOAD="./claude.glibc"
LAUNCHER="./claude"
FAILED=0

if [[ -t 1 ]]; then
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  CYAN="\033[36m"
  DIM="\033[2m"
  RESET="\033[0m"
else
  GREEN="" RED="" YELLOW="" CYAN="" DIM="" RESET=""
fi

info() { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok() { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
warn() { printf '%b\n' " ${YELLOW}[SKIP]${RESET} $*"; }
fail() { printf '%b\n' " ${RED}[FAIL]${RESET} $*" >&2; FAILED=1; }
die() { printf '%b\n' " ${RED}[ERR]${RESET} $*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
Usage: .github/scripts/compat-test.sh [options]

Runs the local binary-only compatibility test workflow. Static checks run on
any host. Runtime launcher smokes run only on native Termux aarch64.

Options:
  --network          Probe Anthropic and Claude auth hosts over IPv4 with curl
  --auth-probe       Try a bounded invalid-code auth exchange to catch DNS timeouts
  --skip-build       Do not rebuild ./claude before smoke tests
  --skip-shellcheck  Skip ShellCheck even when installed
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK=1
      ;;
    --auth-probe)
      AUTH_PROBE=1
      NETWORK=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --skip-shellcheck)
      SKIP_SHELLCHECK=1
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

run_check() {
  local label=$1
  shift

  info "$label"
  if "$@"; then
    ok "$label"
  else
    fail "$label"
  fi
}

capture_check() {
  local label=$1
  local output=""
  shift

  info "$label"
  if output="$("$@" 2>&1)"; then
    ok "$label: $output"
  else
    fail "$label: $output"
  fi
}

silent_check() {
  local label=$1
  shift

  info "$label"
  if "$@" >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label"
  fi
}

is_termux_runtime() {
  [[ -n "${TERMUX_VERSION:-}" && -n "${PREFIX:-}" && "$(uname -m)" == "aarch64" ]]
}

check_interpreter() {
  local interp=""

  [[ -s "$PAYLOAD" ]] || {
    printf 'missing payload: %s\n' "$PAYLOAD" >&2
    return 1
  }

  command -v readelf >/dev/null 2>&1 || {
    printf 'readelf is required for ELF interpreter checks\n' >&2
    return 1
  }

  interp="$(readelf -l "$PAYLOAD" 2>/dev/null |
    awk -F': ' '/Requesting program interpreter/ { gsub(/]$/, "", $2); print $2 }')"
  [[ "$interp" == "/lib/ld-linux-aarch64.so.1" ]] || {
    printf 'unexpected interpreter: %s\n' "${interp:-missing}" >&2
    return 1
  }
}

check_guarded_command() {
  local command=$1
  local output=""
  local status=0

  output="$("$LAUNCHER" "$command" 2>&1)" || status=$?
  [[ "$status" -eq 2 ]] || {
    printf 'expected exit 2, got %s\n%s\n' "$status" "$output" >&2
    return 1
  }
  [[ "$output" == *"Refusing to run"* ]] || {
    printf 'guard message missing\n%s\n' "$output" >&2
    return 1
  }
}

check_direct_payload_note() {
  local status=0

  "$PAYLOAD" --version >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    warn "Direct payload execution succeeded; launcher tests will still run"
  else
    ok "Direct payload execution is blocked as expected on Termux"
  fi
}

curl_head_ipv4() {
  local url=$1
  local code=""

  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required for network probes\n' >&2
    return 1
  }

  code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 -I "$url")" ||
    return 1
  [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]] || {
    printf 'unexpected HTTP code for %s: %s\n' "$url" "$code" >&2
    return 1
  }
}

auth_probe() {
  local tmp_root="${TMPDIR:-}"
  local log_file=""
  local status=0

  command -v timeout >/dev/null 2>&1 || {
    printf 'timeout is required for auth probe\n' >&2
    return 1
  }
  if [[ -z "$tmp_root" && -n "${PREFIX:-}" ]]; then
    tmp_root="$PREFIX/tmp"
  fi
  if [[ -z "$tmp_root" ]]; then
    tmp_root="."
  fi
  mkdir -p "$tmp_root"
  log_file="$(mktemp "${tmp_root%/}/claude-auth-probe.XXXXXX")"

  set +e
  printf 'invalid-code\n' |
    timeout 35 "$LAUNCHER" auth login --claudeai >"$log_file" 2>&1
  status=$?
  set -e

  if grep -Eq 'ETIMEOUT|getaddrinfo|Unable to connect' "$log_file"; then
    printf 'auth probe hit network/DNS failure:\n' >&2
    sed -n '1,120p' "$log_file" >&2
    rm -f "$log_file"
    return 1
  fi

  if grep -Eq 'Invalid code|invalid' "$log_file"; then
    rm -f "$log_file"
    return 0
  fi

  printf 'auth probe ended with status %s and no invalid-code marker:\n' "$status" >&2
  sed -n '1,120p' "$log_file" >&2
  rm -f "$log_file"
  return 1
}

info "Running portable shell checks"
run_check "Bash syntax" bash -n build.sh install.sh .github/scripts/compat-test.sh .github/scripts/release-check.sh .github/scripts/package-release.sh

if [[ "$SKIP_SHELLCHECK" -eq 0 && -x "$(command -v shellcheck || true)" ]]; then
  run_check "ShellCheck" shellcheck build.sh install.sh .github/scripts/compat-test.sh .github/scripts/release-check.sh .github/scripts/package-release.sh
else
  warn "ShellCheck not installed or skipped"
fi

run_check "Release metadata probe" .github/scripts/release-check.sh --quiet

if ! is_termux_runtime; then
  warn "Not native Termux aarch64; skipping launcher runtime smokes"
  [[ "$FAILED" -eq 0 ]] || exit 1
  exit 0
fi

info "Running Termux binary compatibility checks"
run_check "Installer dry run" ./install.sh --dry-run

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  run_check "Build launcher" ./build.sh
fi

run_check "Payload ELF interpreter" check_interpreter
check_direct_payload_note
capture_check "Launcher version" "$LAUNCHER" --version
silent_check "Launcher help" "$LAUNCHER" --help
silent_check "Auth help" "$LAUNCHER" auth --help
silent_check "Auth login help" "$LAUNCHER" auth login --help
run_check "Guard update command" check_guarded_command update
run_check "Guard upgrade command" check_guarded_command upgrade
run_check "Guard install command" check_guarded_command install
run_check "Local release comparison" .github/scripts/release-check.sh --quiet

if [[ "$NETWORK" -eq 1 ]]; then
  run_check "IPv4 API reachability" curl_head_ipv4 https://api.anthropic.com/
  run_check "IPv4 platform reachability" curl_head_ipv4 https://platform.claude.com/
else
  warn "Network probes skipped; pass --network to enable"
fi

if [[ "$AUTH_PROBE" -eq 1 ]]; then
  run_check "Invalid-code auth DNS probe" auth_probe
else
  warn "Auth DNS probe skipped; pass --auth-probe to enable"
fi

[[ "$FAILED" -eq 0 ]] || exit 1
ok "Compatibility checks complete"

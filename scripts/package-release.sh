#!/usr/bin/env bash
# Build a source-free release artifact from the upstream binary payload.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-latest}"
DIST_DIR="${DIST_DIR:-dist}"
PACKAGE_PREFIX="claude-termux"
PACKAGE_FILES=(claude claude.glibc)

if [[ -t 1 ]]; then
  GREEN="\033[32m"
  RED="\033[31m"
  CYAN="\033[36m"
  DIM="\033[2m"
  RESET="\033[0m"
else
  GREEN="" RED="" CYAN="" DIM="" RESET=""
fi

info() { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok() { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
die() { printf '%b\n' " ${RED}[ERR]${RESET} $*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
Usage: scripts/package-release.sh [latest|VERSION]

Runs build.sh, runs compatibility checks, and writes:
  dist/claude-termux-aarch64.tar.gz
  dist/claude-termux-aarch64.tar.gz.sha256

The upstream payload and generated launcher stay untracked.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 0
fi

case "$VERSION" in
  latest|stable|[0-9]*.[0-9]*.[0-9]*)
    ;;
  *)
    die "Invalid version target: $VERSION"
    ;;
esac

command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
command -v tar >/dev/null 2>&1 || die "tar is required."

info "Building launcher"
./build.sh "$VERSION" --force-download

ACTUAL_VERSION="$(./claude --version 2>/dev/null | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?).*/\1/')" ||
  die "Unable to read built Claude version."
[[ -n "$ACTUAL_VERSION" ]] || die "Unable to parse built Claude version."

info "Running compatibility checks"
scripts/compat-test.sh --skip-build --network

mkdir -p "$DIST_DIR"
ARCHIVE="${DIST_DIR%/}/${PACKAGE_PREFIX}-aarch64.tar.gz"

info "Writing $ARCHIVE"
tar -czf "$ARCHIVE" "${PACKAGE_FILES[@]}"
sha256sum "$ARCHIVE" >"${ARCHIVE}.sha256"

ok "Packaged $ARCHIVE"

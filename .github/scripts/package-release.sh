#!/usr/bin/env bash
# Build a source-free release artifact from the upstream binary payload.
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

VERSION="${1:-latest}"
DIST_DIR="${DIST_DIR:-dist}"
PACKAGE_PREFIX="claude-termux"
PACKAGE_FILES=(claude claude.glibc claude-termux-update)

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
Usage: .github/scripts/package-release.sh [latest|VERSION]

Runs build.sh, runs compatibility checks, and writes:
  dist/claude-termux-aarch64.tar.gz
  dist/claude-termux-aarch64.tar.gz.sha256
  dist/release.env

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
mkdir -p "$DIST_DIR"
BUILD_VERSION_FILE="${DIST_DIR%/}/.build-version"
trap 'rm -f "$BUILD_VERSION_FILE"' EXIT
BUILD_ARGS=("$VERSION" --force-download)
if [[ -z "${TERMUX_VERSION:-}" || -z "${PREFIX:-}" || "$(uname -m)" != "aarch64" ]]; then
  BUILD_ARGS+=(--cross-compile)
fi
CLAUDE_TERMUX_BUILD_VERSION_OUTPUT="$BUILD_VERSION_FILE" ./build.sh "${BUILD_ARGS[@]}"

ACTUAL_VERSION="$(<"$BUILD_VERSION_FILE")"
[[ -n "$ACTUAL_VERSION" ]] || die "Unable to parse built Claude version."

if [[ -n "${TERMUX_VERSION:-}" && -n "${PREFIX:-}" && "$(uname -m)" == "aarch64" ]]; then
  RUNTIME_VERSION="$(./claude --version 2>/dev/null | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?).*/\1/')" ||
    die "Unable to read built Claude version."
  [[ "$RUNTIME_VERSION" == "$ACTUAL_VERSION" ]] ||
    die "Built version $RUNTIME_VERSION does not match downloaded version $ACTUAL_VERSION."
fi

info "Running compatibility checks"
.github/scripts/compat-test.sh --artifacts --skip-build

ARCHIVE="${DIST_DIR%/}/${PACKAGE_PREFIX}-aarch64.tar.gz"
CHECKSUM_FILE="${ARCHIVE}.sha256"
RELEASE_TAG="v${ACTUAL_VERSION}-termux"
RELEASE_ENV="${DIST_DIR%/}/release.env"

info "Writing $ARCHIVE"
tar -czf "$ARCHIVE" "${PACKAGE_FILES[@]}"
(
  cd "$(dirname "$ARCHIVE")"
  sha256sum "$(basename "$ARCHIVE")" >"$(basename "$CHECKSUM_FILE")"
)

cat >"$RELEASE_ENV" <<EOF
actual_version=$ACTUAL_VERSION
release_tag=$RELEASE_TAG
archive=$(basename "$ARCHIVE")
checksum_file=$(basename "$CHECKSUM_FILE")
EOF

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'actual_version=%s\n' "$ACTUAL_VERSION"
    printf 'release_tag=%s\n' "$RELEASE_TAG"
    printf 'archive=%s\n' "$(basename "$ARCHIVE")"
    printf 'checksum_file=%s\n' "$(basename "$CHECKSUM_FILE")"
  } >>"$GITHUB_OUTPUT"
fi

ok "Packaged $ARCHIVE for $RELEASE_TAG"

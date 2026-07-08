#!/usr/bin/env bash
# Install the latest Claude Termux release artifact into $PREFIX/bin.
set -Eeuo pipefail

REPO="${CLAUDE_TERMUX_REPO:-wallentx/claude-code-termux}"
ASSET="${CLAUDE_TERMUX_ASSET:-claude-termux-aarch64.tar.gz}"
BASE_URL="${CLAUDE_TERMUX_BASE_URL:-https://github.com/$REPO/releases/latest/download}"
URL="${CLAUDE_TERMUX_URL:-$BASE_URL/$ASSET}"
CHECKSUM_URL="${CLAUDE_TERMUX_CHECKSUM_URL:-$URL.sha256}"
DRY_RUN=0

if [[ -t 1 ]]; then
  BOLD="\033[1m"
  GREEN="\033[32m"
  RED="\033[31m"
  CYAN="\033[36m"
  DIM="\033[2m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" RED="" CYAN="" DIM="" RESET=""
fi

info() { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok() { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
die() { printf '%b\n' " ${RED}[ERR]${RESET} $*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
Usage: ./install.sh

Downloads the latest Claude Termux release artifact from GitHub and installs:
  $PREFIX/bin/claude
  $PREFIX/bin/claude.glibc

Options:
  --dry-run                     Check local prerequisites without downloading

Environment:
  CLAUDE_TERMUX_REPO          GitHub repo, default wallentx/claude-code-termux
  CLAUDE_TERMUX_URL           Override release tarball URL
  CLAUDE_TERMUX_CHECKSUM_URL  Override tarball sha256 URL
  CLAUDE_TERMUX_SKIP_VERIFY=1 Skip installed `claude --version` verification
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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

if [[ -z "${TERMUX_VERSION:-}" || -z "${PREFIX:-}" ]]; then
  die "This installer is only for native Termux."
fi

[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64."
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar >/dev/null 2>&1 || die "tar is required."
command -v install >/dev/null 2>&1 || die "install is required."

GLIBC_LOADER="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
CA_BUNDLE="${PREFIX}/etc/tls/cert.pem"
[[ -x "$GLIBC_LOADER" ]] || die "Missing Termux glibc loader: $GLIBC_LOADER. Install glibc-repo and glibc."
[[ -r "$CA_BUNDLE" ]] || die "Missing Termux CA bundle: $CA_BUNDLE. Install ca-certificates."
if [[ ! -r "${PREFIX}/etc/resolv.conf" ]]; then
  info "Resolver config missing: ${PREFIX}/etc/resolv.conf. The launcher will use its local DNS proxy fallback."
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  ok "Installer dry run passed"
  info "Release URL: $URL"
  exit 0
fi

TMP_ROOT="${TMPDIR:-$PREFIX/tmp}"
ARCHIVE="${TMP_ROOT%/}/$ASSET"
CHECKSUM_FILE="${ARCHIVE}.sha256"
EXTRACT_DIR="${TMP_ROOT%/}/.claude-termux-install.$$"
INSTALL_BIN_DIR="${PREFIX}/bin"
CLAUDE_BAK=""
PAYLOAD_BAK=""
INSTALL_SUCCESS=0

cleanup() {
  rm -rf "$EXTRACT_DIR"
  if [[ "$INSTALL_SUCCESS" -eq 1 ]]; then
    [[ -n "$CLAUDE_BAK" && -f "$CLAUDE_BAK" ]] && rm -f "$CLAUDE_BAK"
    [[ -n "$PAYLOAD_BAK" && -f "$PAYLOAD_BAK" ]] && rm -f "$PAYLOAD_BAK"
    return
  fi

  [[ -f "$INSTALL_BIN_DIR/claude" ]] && rm -f "$INSTALL_BIN_DIR/claude"
  [[ -f "$INSTALL_BIN_DIR/claude.glibc" ]] && rm -f "$INSTALL_BIN_DIR/claude.glibc"
  [[ -n "$CLAUDE_BAK" && -f "$CLAUDE_BAK" ]] && mv -f "$CLAUDE_BAK" "$INSTALL_BIN_DIR/claude"
  [[ -n "$PAYLOAD_BAK" && -f "$PAYLOAD_BAK" ]] && mv -f "$PAYLOAD_BAK" "$INSTALL_BIN_DIR/claude.glibc"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT" "$EXTRACT_DIR" "$INSTALL_BIN_DIR"

info "Downloading $URL"
curl -fL --retry 3 --retry-delay 2 -o "$ARCHIVE" "$URL"

if command -v sha256sum >/dev/null 2>&1; then
  info "Downloading checksum"
  if curl -fL --retry 3 --retry-delay 2 -o "$CHECKSUM_FILE" "$CHECKSUM_URL"; then
    (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$CHECKSUM_FILE")")
    ok "Checksum verified"
  else
    info "Checksum unavailable; continuing without checksum verification"
  fi
fi

info "Extracting release artifact"
tar -xzf "$ARCHIVE" -C "$EXTRACT_DIR" claude claude.glibc
[[ -x "$EXTRACT_DIR/claude" ]] || die "Artifact missing executable: claude"
[[ -s "$EXTRACT_DIR/claude.glibc" ]] || die "Artifact missing payload: claude.glibc"

if [[ -f "$INSTALL_BIN_DIR/claude" ]]; then
  CLAUDE_BAK="$INSTALL_BIN_DIR/claude.bak.$$"
  mv -f "$INSTALL_BIN_DIR/claude" "$CLAUDE_BAK"
fi
if [[ -f "$INSTALL_BIN_DIR/claude.glibc" ]]; then
  PAYLOAD_BAK="$INSTALL_BIN_DIR/claude.glibc.bak.$$"
  mv -f "$INSTALL_BIN_DIR/claude.glibc" "$PAYLOAD_BAK"
fi

install -m 0755 "$EXTRACT_DIR/claude" "$INSTALL_BIN_DIR/claude"
install -m 0755 "$EXTRACT_DIR/claude.glibc" "$INSTALL_BIN_DIR/claude.glibc"
ok "Installed Claude Termux to $INSTALL_BIN_DIR"

if [[ "${CLAUDE_TERMUX_SKIP_VERIFY:-0}" != "1" ]]; then
  info "Running installed smoke test: claude --version"
  VERSION="$("$INSTALL_BIN_DIR/claude" --version)"
  ok "Claude online: $VERSION"
fi

INSTALL_SUCCESS=1
cleanup
trap - EXIT

printf '\n%b\n' "${GREEN}${BOLD}Installation complete.${RESET}"
info "Run: ${BOLD}claude${RESET}"

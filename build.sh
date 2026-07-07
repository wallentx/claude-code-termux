#!/usr/bin/env bash
# Build the native Termux launcher around the upstream Claude Linux arm64 payload.
set -Eeuo pipefail

cd "$(dirname "$0")"

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

DOWNLOAD_BASE_URL="${CLAUDE_DOWNLOAD_BASE_URL:-https://downloads.claude.ai/claude-code-releases}"
DOWNLOAD_PLATFORM="linux-arm64"
DOWNLOAD_TARGET="latest"
FORCE_DOWNLOAD=0
NO_DOWNLOAD=0
DOWNLOADER=""

show_help() {
  cat <<'EOF'
Usage: ./build.sh [latest|stable|VERSION] [options]

Downloads/verifies the upstream linux-arm64 Claude payload when needed, runs an
optional payload patch hook, then builds ./claude as a native Termux launcher
for ./claude.glibc.

If this checkout still has the upstream payload at ./claude and no
./claude.glibc, build.sh renames that payload to ./claude.glibc first.

Options:
  --force-download           Replace ./claude.glibc with a fresh upstream download
  --no-download              Require an existing local payload

Environment:
  CC                         C compiler override
  CLAUDE_DOWNLOAD_BASE_URL    Override upstream release base URL
  CLAUDE_TERMUX_SKIP_SMOKE=1 Skip ./claude --version smoke test
EOF
}

select_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    die "Either curl or wget is required."
  fi
}

download_file() {
  local url=$1
  local dest=${2:-}

  if [[ "$DOWNLOADER" == "curl" ]]; then
    if [[ -n "$dest" ]]; then
      curl -fsSL -o "$dest" "$url"
    else
      curl -fsSL "$url"
    fi
    return
  fi

  if [[ -n "$dest" ]]; then
    wget -q -O "$dest" "$url"
  else
    wget -q -O - "$url"
  fi
}

get_checksum_from_manifest() {
  local json=$1
  local platform=$2

  json=$(printf '%s' "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
  if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

download_upstream_payload() {
  local target=$1
  local version=$target
  local manifest_json=""
  local checksum=""
  local tmp_root="${TMPDIR:-${PREFIX:-}/tmp}"
  local tmp_bin=""
  local actual=""
  local interp=""

  select_downloader
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."

  if [[ "$target" == "stable" || "$target" == "latest" ]]; then
    info "Resolving latest upstream Claude Code version"
    version="$(download_file "$DOWNLOAD_BASE_URL/latest" | tr -d '[:space:]')"
  fi

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$ ]] ||
    die "Failed to resolve a valid Claude Code version."

  info "Fetching upstream manifest for $version"
  manifest_json="$(download_file "$DOWNLOAD_BASE_URL/$version/manifest.json")"

  if command -v jq >/dev/null 2>&1; then
    checksum="$(printf '%s' "$manifest_json" | jq -r ".platforms[\"$DOWNLOAD_PLATFORM\"].checksum // empty")"
  else
    checksum="$(get_checksum_from_manifest "$manifest_json" "$DOWNLOAD_PLATFORM")"
  fi
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] ||
    die "Platform $DOWNLOAD_PLATFORM not found in upstream manifest."

  mkdir -p "$tmp_root"
  tmp_bin="$(mktemp "${tmp_root%/}/claude-upstream.XXXXXX")"
  trap '[[ -n "${tmp_bin:-}" && -f "$tmp_bin" ]] && rm -f "$tmp_bin"' EXIT

  info "Downloading upstream $DOWNLOAD_PLATFORM payload"
  download_file "$DOWNLOAD_BASE_URL/$version/$DOWNLOAD_PLATFORM/claude" "$tmp_bin"

  actual="$(sha256sum "$tmp_bin" | awk '{print $1}')"
  [[ "$actual" == "$checksum" ]] || die "Checksum verification failed."

  if command -v readelf >/dev/null 2>&1; then
    interp="$(readelf -l "$tmp_bin" 2>/dev/null |
      awk -F': ' '/Requesting program interpreter/ { gsub(/]$/, "", $2); print $2; exit }')"
    [[ "$interp" == "/lib/ld-linux-aarch64.so.1" ]] ||
      die "Downloaded binary has unexpected interpreter: ${interp:-unknown}"
  fi

  chmod 0755 "$tmp_bin"
  mv -f "$tmp_bin" "claude.glibc"
  tmp_bin=""
  trap - EXIT
  ok "Downloaded upstream Claude Code $version"
}

is_upstream_payload() {
  local candidate=$1
  local desc=""
  local interp=""

  [[ -f "$candidate" ]] || return 1

  if desc="$(file "$candidate" 2>/dev/null)" &&
    [[ "$desc" == *"interpreter /lib/ld-linux-aarch64.so.1"* ]]; then
    return 0
  fi

  interp="$(readelf -l "$candidate" 2>/dev/null |
    awk -F': ' '/Requesting program interpreter/ { gsub(/]$/, "", $2); print $2; exit }')"
  [[ "$interp" == "/lib/ld-linux-aarch64.so.1" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    --force-download)
      FORCE_DOWNLOAD=1
      NO_DOWNLOAD=0
      ;;
    --no-download)
      NO_DOWNLOAD=1
      FORCE_DOWNLOAD=0
      ;;
    latest|stable|[0-9]*.[0-9]*.[0-9]*)
      DOWNLOAD_TARGET="$1"
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "${TERMUX_VERSION:-}" == "" || "${PREFIX:-}" == "" ]]; then
  die "This build script is intended for native Termux."
fi

[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64."
[[ -f "lib/claude_helper.c" ]] || die "Missing lib/claude_helper.c."

if [[ "$FORCE_DOWNLOAD" -eq 1 ]]; then
  download_upstream_payload "$DOWNLOAD_TARGET"
elif [[ ! -f "claude.glibc" && "$NO_DOWNLOAD" -eq 0 ]]; then
  download_upstream_payload "$DOWNLOAD_TARGET"
elif [[ ! -f "claude.glibc" ]]; then
  if is_upstream_payload "claude"; then
    info "Moving upstream payload: claude -> claude.glibc"
    mv "claude" "claude.glibc"
  else
    die "Missing claude.glibc. Run ./build.sh without --no-download, or place the upstream Linux arm64 Claude binary at ./claude.glibc."
  fi
fi

[[ -s "claude.glibc" ]] || die "claude.glibc is empty."
chmod 0755 "claude.glibc"

if [[ -x "scripts/patch-payload.sh" ]]; then
  info "Running payload patch hook"
  scripts/patch-payload.sh "claude.glibc"
fi

GLIBC_LOADER="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
CA_BUNDLE="${PREFIX}/etc/tls/cert.pem"
[[ -x "$GLIBC_LOADER" ]] || die "Missing Termux glibc loader: $GLIBC_LOADER. Install glibc-repo and glibc."
[[ -r "$CA_BUNDLE" ]] || die "Missing Termux CA bundle: $CA_BUNDLE. Install ca-certificates."
if [[ ! -r "${PREFIX}/etc/resolv.conf" ]]; then
  info "Resolver config missing: ${PREFIX}/etc/resolv.conf. DNS may fail until resolv-conf is installed."
fi

CC_BIN="${CC:-}"
if [[ -z "$CC_BIN" ]]; then
  if command -v clang >/dev/null 2>&1; then
    CC_BIN="$(command -v clang)"
  elif command -v cc >/dev/null 2>&1; then
    CC_BIN="$(command -v cc)"
  else
    die "No C compiler found. Install clang."
  fi
fi

info "Compiling native Termux launcher with $CC_BIN"
"$CC_BIN" -std=c11 -Wall -Wextra -O2 -o "claude" "lib/claude_helper.c"
chmod 0755 "claude"
ok "Built ./claude launcher"

if [[ "${CLAUDE_TERMUX_SKIP_SMOKE:-0}" != "1" ]]; then
  info "Running smoke test: ./claude --version"
  VERSION="$(./claude --version)"
  ok "Claude online: $VERSION"
fi

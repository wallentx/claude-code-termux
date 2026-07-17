#!/usr/bin/env bash
# Exercise updater replacement and rollback with local fixture artifacts.
set -Eeuo pipefail

cd "$(dirname "$0")/../.."

[[ -n "${TERMUX_VERSION:-}" && -n "${PREFIX:-}" && "$(uname -m)" == "aarch64" ]] || {
  printf 'Updater fixture test requires native Termux aarch64.\n' >&2
  exit 1
}
[[ -x ./claude-termux-update ]] || {
  printf 'Missing updater: ./claude-termux-update\n' >&2
  exit 1
}

TMP_ROOT="${TMPDIR:-$PREFIX/tmp}"
TEST_ROOT="$(mktemp -d "${TMP_ROOT%/}/claude-updater-test.XXXXXX")"
INSTALL_DIR="$TEST_ROOT/install"
ARTIFACT_DIR="$TEST_ROOT/artifact"
ARCHIVE="$TEST_ROOT/claude-termux-aarch64.tar.gz"
CHECKSUM_FILE="$ARCHIVE.sha256"
trap 'rm -rf "$TEST_ROOT"' EXIT

write_executable() {
  local path=$1
  local body=$2

  printf '#!/system/bin/sh\n%s\n' "$body" >"$path"
  chmod 0755 "$path"
}

build_fixture() {
  local launcher_body=$1
  local payload_body=$2
  local include_updater=${3:-1}

  rm -rf "$ARTIFACT_DIR"
  mkdir -p "$ARTIFACT_DIR"
  write_executable "$ARTIFACT_DIR/claude" "$launcher_body"
  write_executable "$ARTIFACT_DIR/claude.glibc" "$payload_body"
  if [[ "$include_updater" -eq 1 ]]; then
    cp ./claude-termux-update "$ARTIFACT_DIR/claude-termux-update"
    chmod 0755 "$ARTIFACT_DIR/claude-termux-update"
    tar -czf "$ARCHIVE" -C "$ARTIFACT_DIR" \
      claude claude.glibc claude-termux-update
  else
    tar -czf "$ARCHIVE" -C "$ARTIFACT_DIR" claude claude.glibc
  fi
  (
    cd "$TEST_ROOT"
    sha256sum "$(basename "$ARCHIVE")" >"$(basename "$CHECKSUM_FILE")"
  )
}

run_fixture_update() {
  CLAUDE_TERMUX_URL="file://$ARCHIVE" \
    CLAUDE_TERMUX_CHECKSUM_URL="file://$CHECKSUM_FILE" \
    CLAUDE_TERMUX_INSTALL_DIR="$INSTALL_DIR" \
    "$INSTALL_DIR/claude-termux-update" update
}

mkdir -p "$INSTALL_DIR"
write_executable "$INSTALL_DIR/claude" 'printf "old launcher\\n"'
write_executable "$INSTALL_DIR/claude.glibc" 'printf "old payload\\n"'
cp ./claude-termux-update "$INSTALL_DIR/claude-termux-update"
chmod 0755 "$INSTALL_DIR/claude-termux-update"

build_fixture 'printf "fixture-1\\n"' 'printf "payload-1\\n"'
run_fixture_update >/dev/null
[[ "$("$INSTALL_DIR/claude")" == "fixture-1" ]]
[[ "$("$INSTALL_DIR/claude.glibc")" == "payload-1" ]]

build_fixture 'printf "legacy launcher\\n"' 'printf "payload-legacy\\n"' 0
run_fixture_update >/dev/null
[[ "$("$INSTALL_DIR/claude")" == "fixture-1" ]]
[[ "$("$INSTALL_DIR/claude.glibc")" == "payload-legacy" ]]
[[ -x "$INSTALL_DIR/claude-termux-update" ]]

build_fixture 'exit 23' 'printf "payload-bad\\n"'
if run_fixture_update >/dev/null 2>&1; then
  printf 'Updater accepted a launcher that failed its smoke test.\n' >&2
  exit 1
fi
[[ "$("$INSTALL_DIR/claude")" == "fixture-1" ]]
[[ "$("$INSTALL_DIR/claude.glibc")" == "payload-legacy" ]]

printf 'Updater transaction and rollback checks passed.\n'

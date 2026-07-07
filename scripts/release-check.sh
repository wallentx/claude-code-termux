#!/usr/bin/env bash
# Check upstream Claude Code release tags and binary metadata without downloading the payload.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

DOWNLOAD_BASE_URL="${CLAUDE_DOWNLOAD_BASE_URL:-https://downloads.claude.ai/claude-code-releases}"
DOWNLOAD_PLATFORM="${CLAUDE_DOWNLOAD_PLATFORM:-linux-arm64}"
UPSTREAM_GIT_URL="${CLAUDE_UPSTREAM_GIT_URL:-https://github.com/anthropics/claude-code.git}"
UPSTREAM_TAG_GLOB="${CLAUDE_UPSTREAM_TAG_GLOB:-v*}"
TERMUX_TAG_GLOB="${CLAUDE_TERMUX_TAG_GLOB:-v*-termux}"
LOCAL_BINARY="./claude"
REMOTE_ONLY=0
JSON=0
QUIET=0
FAIL_ON_UPDATE=0
DOWNLOADER=""

if [[ -t 1 ]]; then
  GREEN="\033[32m"
  RED="\033[31m"
  CYAN="\033[36m"
  DIM="\033[2m"
  RESET="\033[0m"
else
  GREEN="" RED="" CYAN="" DIM="" RESET=""
fi

info() {
  [[ "$QUIET" -eq 1 || "$JSON" -eq 1 ]] && return 0
  printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"
}

ok() {
  [[ "$QUIET" -eq 1 || "$JSON" -eq 1 ]] && return 0
  printf '%b\n' " ${GREEN}[OK]${RESET} $*"
}

die() {
  printf '%b\n' " ${RED}[ERR]${RESET} $*" >&2
  exit 1
}

show_help() {
  cat <<'EOF'
Usage: scripts/release-check.sh [options]

Checks upstream Claude Code tags, verifies matching linux-arm64 payload metadata,
and compares with the latest Termux release tag. If no local tag is available,
it falls back to the local launcher version.

Options:
  --remote-only       Do not run a local Claude binary
  --binary PATH       Local Claude launcher to query with --version
  --json              Print machine-readable JSON
  --quiet             Suppress human status lines
  --fail-on-update    Exit 2 when no Termux release exists or upstream is newer
  -h, --help          Show this help

Environment:
  CLAUDE_DOWNLOAD_BASE_URL     Override release metadata base URL
  CLAUDE_DOWNLOAD_PLATFORM     Override platform key; default linux-arm64
  CLAUDE_UPSTREAM_GIT_URL      Override upstream tag source
  CLAUDE_UPSTREAM_TAG_GLOB     Override upstream tag glob; default v*
  CLAUDE_TERMUX_TAG_GLOB       Override tracked release tag glob; default v*-termux
  CLAUDE_TERMUX_LOCAL_VERSION  Override local version detection
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-only)
      REMOTE_ONLY=1
      ;;
    --binary)
      [[ -n "${2:-}" ]] || die "--binary requires a path."
      LOCAL_BINARY="$2"
      shift
      ;;
    --binary=*)
      LOCAL_BINARY="${1#*=}"
      ;;
    --json)
      JSON=1
      ;;
    --quiet)
      QUIET=1
      ;;
    --fail-on-update)
      FAIL_ON_UPDATE=1
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

  if [[ "$DOWNLOADER" == "curl" ]]; then
    curl -fsSL "$url"
  else
    wget -q -O - "$url"
  fi
}

compact_json() {
  tr -d '\n\r\t' | sed 's/ \+/ /g'
}

json_string_field() {
  local json=$1
  local key=$2

  if [[ $json =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

json_platform_string_field() {
  local json=$1
  local platform=$2
  local key=$3
  local block=""

  if [[ $json =~ \"$platform\"[[:space:]]*:[[:space:]]*\{([^}]*)\} ]]; then
    block="${BASH_REMATCH[1]}"
    json_string_field "$block" "$key"
    return
  fi

  return 1
}

json_platform_number_field() {
  local json=$1
  local platform=$2
  local key=$3
  local block=""

  if [[ $json =~ \"$platform\"[[:space:]]*:[[:space:]]*\{([^}]*)\} ]]; then
    block="${BASH_REMATCH[1]}"
    if [[ $block =~ \"$key\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  fi

  return 1
}

normalize_version() {
  local version=${1#v}

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || return 1
  printf '%s\n' "$version"
}

compare_identifiers() {
  local left=$1
  local right=$2

  if [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ ]]; then
    if ((10#$left > 10#$right)); then
      printf '1\n'
    elif ((10#$left < 10#$right)); then
      printf -- '-1\n'
    else
      printf '0\n'
    fi
    return
  fi

  if [[ "$left" =~ ^[0-9]+$ ]]; then
    printf -- '-1\n'
    return
  fi

  if [[ "$right" =~ ^[0-9]+$ ]]; then
    printf '1\n'
    return
  fi

  if [[ "$left" > "$right" ]]; then
    printf '1\n'
  elif [[ "$left" < "$right" ]]; then
    printf -- '-1\n'
  else
    printf '0\n'
  fi
}

compare_semver() {
  local left
  local right
  local left_core
  local right_core
  local left_pre=""
  local right_pre=""
  local left_parts
  local right_parts
  local left_ids
  local right_ids
  local max_ids=0
  local cmp=0

  left="$(normalize_version "$1")" || return 1
  right="$(normalize_version "$2")" || return 1

  left_core="${left%%-*}"
  right_core="${right%%-*}"
  [[ "$left" == *-* ]] && left_pre="${left#*-}"
  [[ "$right" == *-* ]] && right_pre="${right#*-}"

  IFS=. read -r -a left_parts <<< "$left_core"
  IFS=. read -r -a right_parts <<< "$right_core"
  for idx in 0 1 2; do
    if ((10#${left_parts[$idx]} > 10#${right_parts[$idx]})); then
      printf '1\n'
      return 0
    fi
    if ((10#${left_parts[$idx]} < 10#${right_parts[$idx]})); then
      printf -- '-1\n'
      return 0
    fi
  done

  if [[ -z "$left_pre" && -n "$right_pre" ]]; then
    printf '1\n'
    return 0
  fi
  if [[ -n "$left_pre" && -z "$right_pre" ]]; then
    printf -- '-1\n'
    return 0
  fi
  if [[ -z "$left_pre" && -z "$right_pre" ]]; then
    printf '0\n'
    return 0
  fi

  IFS=. read -r -a left_ids <<< "$left_pre"
  IFS=. read -r -a right_ids <<< "$right_pre"
  max_ids=${#left_ids[@]}
  (( ${#right_ids[@]} > max_ids )) && max_ids=${#right_ids[@]}

  for ((idx = 0; idx < max_ids; idx++)); do
    if [[ -z "${left_ids[$idx]+set}" ]]; then
      printf -- '-1\n'
      return 0
    fi
    if [[ -z "${right_ids[$idx]+set}" ]]; then
      printf '1\n'
      return 0
    fi

    cmp="$(compare_identifiers "${left_ids[$idx]}" "${right_ids[$idx]}")"
    if [[ "$cmp" != "0" ]]; then
      printf '%s\n' "$cmp"
      return 0
    fi
  done

  printf '0\n'
}

tag_to_version() {
  local tag=${1#refs/tags/}

  if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)-termux$ ]]; then
    normalize_version "${BASH_REMATCH[1]}"
    return
  fi

  return 1
}

upstream_tag_to_version() {
  local tag=${1#refs/tags/}

  if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)$ ]]; then
    normalize_version "${BASH_REMATCH[1]}"
    return
  fi

  return 1
}

detect_upstream_release() {
  local line=""
  local ref=""
  local tag=""
  local version=""
  local best_tag=""
  local best_version=""
  local cmp=""

  command -v git >/dev/null 2>&1 || die "git is required for upstream tag detection."

  while IFS= read -r line; do
    ref="${line##*$'\t'}"
    tag="${ref#refs/tags/}"
    [[ "$tag" == *^{} ]] && continue
    # shellcheck disable=SC2053
    [[ "$tag" == $UPSTREAM_TAG_GLOB ]] || continue
    version="$(upstream_tag_to_version "$tag")" || continue
    if [[ -z "$best_version" ]]; then
      best_version="$version"
      best_tag="$tag"
      continue
    fi

    cmp="$(compare_semver "$version" "$best_version")" || continue
    if [[ "$cmp" == "1" ]]; then
      best_version="$version"
      best_tag="$tag"
    fi
  done < <(git ls-remote --tags "$UPSTREAM_GIT_URL")

  [[ -n "$best_version" ]] || die "No matching upstream release tags found at $UPSTREAM_GIT_URL."
  printf '%s|%s\n' "$best_version" "$best_tag"
}

detect_tag_release() {
  local tag=""
  local version=""
  local best_tag=""
  local best_version=""
  local cmp=""

  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --git-dir >/dev/null 2>&1 || return 1

  while IFS= read -r tag; do
    version="$(tag_to_version "$tag")" || continue
    if [[ -z "$best_version" ]]; then
      best_version="$version"
      best_tag="$tag"
      continue
    fi

    cmp="$(compare_semver "$version" "$best_version")" || continue
    if [[ "$cmp" == "1" ]]; then
      best_version="$version"
      best_tag="$tag"
    fi
  done < <(git tag --list "$TERMUX_TAG_GLOB")

  [[ -n "$best_version" ]] || return 1
  printf '%s|tag|%s\n' "$best_version" "$best_tag"
}

detect_local_release() {
  local output=""
  local release=""

  if [[ -n "${CLAUDE_TERMUX_LOCAL_VERSION:-}" ]]; then
    printf '%s|env|\n' "$(normalize_version "$CLAUDE_TERMUX_LOCAL_VERSION")"
    return
  fi

  if release="$(detect_tag_release)"; then
    printf '%s\n' "$release"
    return
  fi

  if [[ -x "$LOCAL_BINARY" ]]; then
    output="$("$LOCAL_BINARY" --version 2>/dev/null)" || output=""
    if [[ "$output" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
      printf '%s|binary|\n' "$(normalize_version "${BASH_REMATCH[1]}")"
      return
    fi
  fi

  return 1
}

json_escape() {
  local value=$1

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  printf '%s' "$value"
}

print_json() {
  printf '{'
  printf '"base_url":"%s",' "$(json_escape "$DOWNLOAD_BASE_URL")"
  printf '"upstream_git_url":"%s",' "$(json_escape "$UPSTREAM_GIT_URL")"
  printf '"platform":"%s",' "$(json_escape "$DOWNLOAD_PLATFORM")"
  printf '"latest":"%s",' "$(json_escape "$latest")"
  printf '"upstream_tag":"%s",' "$(json_escape "$upstream_tag")"
  printf '"manifest_version":"%s",' "$(json_escape "$manifest_version")"
  printf '"commit":"%s",' "$(json_escape "$commit")"
  printf '"build_date":"%s",' "$(json_escape "$build_date")"
  printf '"binary":"%s",' "$(json_escape "$binary")"
  printf '"checksum":"%s",' "$(json_escape "$checksum")"
  printf '"size":%s,' "$size"
  if [[ -n "$local_version" ]]; then
    printf '"local_version":"%s",' "$(json_escape "$local_version")"
  else
    printf '"local_version":null,'
  fi
  if [[ -n "$local_source" ]]; then
    printf '"local_source":"%s",' "$(json_escape "$local_source")"
  else
    printf '"local_source":null,'
  fi
  if [[ -n "$local_tag" ]]; then
    printf '"local_tag":"%s",' "$(json_escape "$local_tag")"
  else
    printf '"local_tag":null,'
  fi
  printf '"status":"%s"' "$(json_escape "$status")"
  printf '}\n'
}

select_downloader

info "Resolving latest upstream Claude Code tag"
upstream_release="$(detect_upstream_release)"
IFS='|' read -r latest upstream_tag <<< "$upstream_release"

info "Fetching manifest for $latest"
manifest_json="$(download_file "$DOWNLOAD_BASE_URL/$latest/manifest.json" | compact_json)"

if command -v jq >/dev/null 2>&1; then
  manifest_version="$(printf '%s' "$manifest_json" | jq -r '.version // empty')"
  commit="$(printf '%s' "$manifest_json" | jq -r '.commit // empty')"
  build_date="$(printf '%s' "$manifest_json" | jq -r '.buildDate // empty')"
  binary="$(printf '%s' "$manifest_json" | jq -r ".platforms[\"$DOWNLOAD_PLATFORM\"].binary // empty")"
  checksum="$(printf '%s' "$manifest_json" | jq -r ".platforms[\"$DOWNLOAD_PLATFORM\"].checksum // empty")"
  size="$(printf '%s' "$manifest_json" | jq -r ".platforms[\"$DOWNLOAD_PLATFORM\"].size // empty")"
else
  manifest_version="$(json_string_field "$manifest_json" "version" || true)"
  commit="$(json_string_field "$manifest_json" "commit" || true)"
  build_date="$(json_string_field "$manifest_json" "buildDate" || true)"
  binary="$(json_platform_string_field "$manifest_json" "$DOWNLOAD_PLATFORM" "binary" || true)"
  checksum="$(json_platform_string_field "$manifest_json" "$DOWNLOAD_PLATFORM" "checksum" || true)"
  size="$(json_platform_number_field "$manifest_json" "$DOWNLOAD_PLATFORM" "size" || true)"
fi

[[ "$manifest_version" == "$latest" ]] ||
  die "Manifest version mismatch: latest=$latest manifest=${manifest_version:-missing}"
[[ -n "$binary" ]] || die "Manifest missing binary for $DOWNLOAD_PLATFORM."
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] ||
  die "Manifest checksum is missing or invalid for $DOWNLOAD_PLATFORM."
[[ "$size" =~ ^[0-9]+$ && "$size" -gt 0 ]] ||
  die "Manifest size is missing or invalid for $DOWNLOAD_PLATFORM."

local_version=""
local_source=""
local_tag=""
status="remote_ok"
if [[ "$REMOTE_ONLY" -eq 0 ]]; then
  if local_release="$(detect_local_release)"; then
    IFS='|' read -r local_version local_source local_tag <<< "$local_release"
    cmp="$(compare_semver "$local_version" "$latest")"
    case "$cmp" in
      -1)
        status="update_available"
        ;;
      0)
        status="up_to_date"
        ;;
      1)
        status="local_ahead"
        ;;
      *)
        die "Unexpected version comparison result: $cmp"
        ;;
    esac
  else
    status="no_termux_release"
  fi
fi

if [[ "$JSON" -eq 1 ]]; then
  print_json
else
  ok "Latest upstream: $latest"
  printf 'upstream_tag=%s\n' "$upstream_tag"
  printf 'platform=%s\n' "$DOWNLOAD_PLATFORM"
  printf 'binary=%s\n' "$binary"
  printf 'checksum=%s\n' "$checksum"
  printf 'size=%s\n' "$size"
  [[ -n "$commit" ]] && printf 'commit=%s\n' "$commit"
  [[ -n "$build_date" ]] && printf 'build_date=%s\n' "$build_date"
  [[ -n "$local_version" ]] && printf 'local=%s\n' "$local_version"
  [[ -n "$local_source" ]] && printf 'local_source=%s\n' "$local_source"
  [[ -n "$local_tag" ]] && printf 'local_tag=%s\n' "$local_tag"
  printf 'status=%s\n' "$status"
fi

if [[ "$FAIL_ON_UPDATE" -eq 1 &&
  ( "$status" == "update_available" || "$status" == "no_termux_release" ) ]]; then
  exit 2
fi

exit 0

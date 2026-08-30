#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR=${BUILD_DIR:-"$PROJECT_ROOT/build"}
WORK_DIR=${WORK_DIR:-"$BUILD_DIR/work"}
OUT_DIR=${OUT_DIR:-"$BUILD_DIR/out"}
SYSTEM_SOURCE_DIR=${SYSTEM_SOURCE_DIR:-"$WORK_DIR/system-source"}
CONFIG_FILE=${CONFIG_FILE:-"$PROJECT_ROOT/config/build.env"}

if [[ -r "$CONFIG_FILE" ]]; then
  # build.env is maintained in this repository and contains assignments only.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

: "${UBUNTU_SUITE:=jammy}"
: "${UBUNTU_MIRROR:=http://archive.ubuntu.com/ubuntu}"
: "${UBUNTU_SECURITY_MIRROR:=http://security.ubuntu.com/ubuntu}"
: "${IMAGE_SIZE_MIB:=6144}"
: "${IMAGE_NAME:=micro-ubuntu-full.img}"
: "${IMAGE_GZIP_NAME:=micro-ubuntu-full.img.gz}"
: "${COMPACT_ISO_NAME:=micro-ubuntu-bootstrap.iso}"
: "${WIFI_ISO_NAME:=micro-ubuntu-wifi-installer.iso}"
: "${COMPACT_ISO_MAX_MIB:=32}"
: "${SOURCE_DATE_EPOCH:=1704067200}"

RAW_IMAGE="$OUT_DIR/$IMAGE_NAME"
COMPRESSED_IMAGE="$OUT_DIR/$IMAGE_GZIP_NAME"
COMPACT_ISO="$OUT_DIR/$COMPACT_ISO_NAME"
WIFI_ISO="$OUT_DIR/$WIFI_ISO_NAME"
CHECKSUM_FILE="$OUT_DIR/SHA256SUMS"

log() {
  printf '\n[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    local message=$*
    message=${message//'%'/'%25'}
    message=${message//$'\r'/'%0D'}
    message=${message//$'\n'/'%0A'}
    printf '::error::%s\n' "$message"
  fi
  exit 1
}

report_command_error() {
  local status=$?
  local source_file=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
  local source_line=${BASH_LINENO[0]:-1}
  local failed_command=${BASH_COMMAND:-unknown}
  # GitHub annotation escaping. The normal stderr line remains useful locally.
  failed_command=${failed_command//'%'/'%25'}
  failed_command=${failed_command//$'\r'/'%0D'}
  failed_command=${failed_command//$'\n'/'%0A'}
  printf 'Command failed (exit %s) at %s:%s: %s\n' \
    "$status" "$source_file" "$source_line" "$failed_command" >&2
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    printf '::error file=%s,line=%s::Command failed with exit %s: %s\n' \
      "$source_file" "$source_line" "$status" "$failed_command"
  fi
  return "$status"
}

enable_error_report() {
  trap report_command_error ERR
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'this build step must run as root (use sudo -E)'
}

require_commands() {
  local command_name missing=0
  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf 'Missing required command: %s\n' "$command_name" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || die 'install the missing build dependencies listed in README.md'
}

ensure_dirs() {
  mkdir -p "$WORK_DIR" "$OUT_DIR"
}

partition_path() {
  local disk=$1 number=$2
  case "$disk" in
    *[0-9]) printf '%sp%s\n' "$disk" "$number" ;;
    *) printf '%s%s\n' "$disk" "$number" ;;
  esac
}

wait_for_path() {
  local path=$1 attempts=${2:-30}
  local count
  for ((count=1; count<=attempts; count++)); do
    [[ -e "$path" ]] && return 0
    command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=2 >/dev/null 2>&1 || true
    sleep 1
  done
  return 1
}

safe_umount() {
  local path=$1
  if mountpoint -q "$path" 2>/dev/null; then
    # --rbind /dev also brings along pts, shm, mqueue, and other nested
    # mounts. Recursive unmounting is required before the loop can detach.
    umount --recursive "$path"
  fi
}

validate_sha256() {
  [[ ${1:-} =~ ^[0-9a-fA-F]{64}$ ]]
}

validate_image_url() {
  local url=${1:-}
  [[ $url == https://* ]] || return 1
  [[ $url != *OWNER/REPOSITORY* ]] || return 1
  [[ $url != *example.invalid* ]] || return 1
  [[ $url != *[[:space:]]* ]] || return 1
  # release.env is POSIX shell; reject quoting/metacharacters rather than
  # attempting to escape an arbitrary URL into that trusted build artifact.
  local safe_url_pattern='^https://[A-Za-z0-9._~:/?#@!%+=,&-]+$'
  [[ $url =~ $safe_url_pattern ]] || return 1
}

write_checksums() {
  ensure_dirs
  local file base
  : > "$CHECKSUM_FILE"
  for file in "$COMPRESSED_IMAGE" "$COMPACT_ISO" "$WIFI_ISO"; do
    [[ -f "$file" ]] || continue
    base=$(basename "$file")
    (cd "$OUT_DIR" && sha256sum "$base") >> "$CHECKSUM_FILE"
  done
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes\n' "$1"
}

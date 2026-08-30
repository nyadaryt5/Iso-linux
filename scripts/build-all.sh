#!/usr/bin/env bash
# Ordered release build: normal image, compact ISO, Wi-Fi ISO, verification.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
require_root
ensure_dirs

if [[ -z ${IMAGE_URL:-} && -n ${GITHUB_REPOSITORY:-} ]]; then
  if [[ -n ${RELEASE_TAG:-} ]]; then
    IMAGE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}/${IMAGE_GZIP_NAME}"
  else
    IMAGE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/${IMAGE_GZIP_NAME}"
  fi
  export IMAGE_URL
fi
validate_image_url "${IMAGE_URL:-}" || die \
  'set IMAGE_URL to the immutable HTTPS URL where micro-ubuntu-full.img.gz will be published'

if [[ ${SKIP_HOST_CHECK:-0} != 1 ]]; then
  "$SCRIPT_DIR/check-build-host.sh"
fi

# Source tests do not require generated artifacts and should fail quickly.
"$PROJECT_ROOT/tests/run-static-tests.sh"

"$SCRIPT_DIR/build-normal-image.sh"
"$SCRIPT_DIR/build-iso.sh" compact
"$SCRIPT_DIR/build-iso.sh" wifi
write_checksums

if [[ ${SKIP_QEMU_TESTS:-0} != 1 ]]; then
  "$PROJECT_ROOT/tests/test-qemu.sh"
fi

summary="$OUT_DIR/BUILD-SUMMARY.md"
{
  echo '# MicroUbuntu build summary'
  echo
  echo "Ubuntu base: $UBUNTU_SUITE"
  echo "Image URL embedded in compact ISO: $IMAGE_URL"
  echo
  echo '## Deliverables'
  echo
  echo '| File | Size (bytes) | SHA-256 |'
  echo '|---|---:|---|'
  for file in "$COMPRESSED_IMAGE" "$COMPACT_ISO" "$WIFI_ISO"; do
    printf '| `%s` | %s | `%s` |\n' \
      "$(basename "$file")" "$(stat -c %s "$file")" "$(sha256sum "$file" | awk '{print $1}')"
  done
  echo
  echo '## QEMU tests'
  echo
  if [[ -s "$OUT_DIR/qemu-results.txt" ]]; then
    sed 's/^/- /' "$OUT_DIR/qemu-results.txt"
  else
    echo '- QEMU tests were skipped.'
  fi
  echo
  echo 'Physical HP laptop testing was not performed by this workflow.'
} > "$summary"

log "All build stages completed. Summary: $summary"

#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
installer="$project_root/src/initramfs/usr/bin/normal-install"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

MICRO_INSTALL_LIBRARY_ONLY=1
export MICRO_INSTALL_LIBRARY_ONLY
# shellcheck source=src/initramfs/usr/bin/normal-install
. "$installer"

fail() { echo "installer unit test failed: $*" >&2; exit 1; }

is_valid_hash 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  || fail 'valid SHA-256 rejected'
is_valid_hash xyz || :
is_valid_hash xyz && fail 'invalid SHA-256 accepted'
[ "$(parent_disk /dev/sda10)" = /dev/sda ] || fail 'sda parent parsing'
[ "$(parent_disk /dev/vda3)" = /dev/vda ] || fail 'vda parent parsing'
[ "$(parent_disk /dev/nvme0n1p3)" = /dev/nvme0n1 ] || fail 'NVMe parent parsing'
[ "$(parent_disk /dev/mmcblk0p3)" = /dev/mmcblk0 ] || fail 'MMC parent parsing'
confirmation_allows_write INSTALL || fail 'exact confirmation rejected'
confirmation_allows_write install && fail 'lowercase confirmation accepted'
confirmation_allows_write 'INSTALL ' && fail 'confirmation with trailing whitespace accepted'

printf 'known payload\n' > "$temporary/payload"
gzip -c "$temporary/payload" > "$temporary/payload.gz"
correct=$(sha256sum "$temporary/payload.gz" | awk '{print $1}')
verify_local_payload "$temporary/payload.gz" "$correct" || fail 'correct payload hash rejected'
if verify_local_payload "$temporary/payload.gz" \
  0000000000000000000000000000000000000000000000000000000000000000; then
  fail 'wrong payload hash accepted'
fi

echo 'Installer function tests passed.'

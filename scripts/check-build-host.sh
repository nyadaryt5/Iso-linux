#!/usr/bin/env bash
# Fail early unless the host can perform every privileged disk operation used
# by the image builder. All operations target a newly-created disposable file.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
enable_error_report
require_root
require_commands losetup sfdisk mkfs.ext4 mkfs.vfat mount umount mountpoint \
  grub-install df truncate sha256sum
ensure_dirs

available=$(df --output=avail -B1 "$BUILD_DIR" | tail -n 1 | tr -d ' ')
required=$((25 * 1024 * 1024 * 1024))
printf 'Build filesystem: %s\n' "$(df -hP "$BUILD_DIR" | tail -n 1)"
printf 'Available bytes: %s (minimum: %s)\n' "$available" "$required"
(( available >= required )) || die 'at least 25 GiB of free space is required before building'

probe_dir=$(mktemp -d "$WORK_DIR/host-probe.XXXXXX")
probe_image="$probe_dir/probe.img"
probe_mount="$probe_dir/root"
probe_efi="$probe_mount/boot/efi"
loop=
cleanup() {
  local status=$?
  set +e
  safe_umount "$probe_efi"
  safe_umount "$probe_mount"
  [[ -z ${loop:-} ]] || losetup -d "$loop" 2>/dev/null || true
  rm -rf "$probe_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

truncate -s 256M "$probe_image"
sfdisk "$probe_image" >/dev/null <<'EOF'
label: gpt
size=2M, type=21686148-6449-6E6F-744E-656564454649, name="BIOS boot"
size=64M, type=U, name="EFI System"
type=L, name="root"
EOF
loop=$(losetup --find --show --partscan "$probe_image")
p1=$(partition_path "$loop" 1)
p2=$(partition_path "$loop" 2)
p3=$(partition_path "$loop" 3)
wait_for_path "$p1" || die 'loop partition scanning did not expose partition 1'
wait_for_path "$p2" || die 'loop partition scanning did not expose partition 2'
wait_for_path "$p3" || die 'loop partition scanning did not expose partition 3'
mkfs.vfat -F 32 "$p2" >/dev/null
mkfs.ext4 -F "$p3" >/dev/null
mkdir -p "$probe_mount"
mount "$p3" "$probe_mount"
mkdir -p "$probe_efi"
mount "$p2" "$probe_efi"

grub-install --target=i386-pc --boot-directory="$probe_mount/boot" --recheck "$loop" >/dev/null
grub-install --target=x86_64-efi --efi-directory="$probe_efi" \
  --boot-directory="$probe_mount/boot" --bootloader-id=MicroUbuntuProbe \
  --removable --no-nvram --no-uefi-secure-boot --recheck >/dev/null
[[ -s "$probe_efi/EFI/BOOT/BOOTX64.EFI" ]] || die 'UEFI removable loader probe failed'

printf 'Host capability probe passed: losetup, partition scanning, sfdisk, mkfs, mount, BIOS GRUB, and UEFI GRUB work.\n'

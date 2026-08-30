#!/usr/bin/env bash
# Build compact or Wi-Fi-capable initramfs from the packages in the normal image.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
enable_error_report

require_root
require_commands cpio gzip depmod modinfo readelf python3 rsync sha256sum
ensure_dirs

PROFILE=${1:-}
case "$PROFILE" in compact|wifi) ;; *) die 'usage: build-initramfs.sh compact|wifi' ;; esac
[[ -s "$RAW_IMAGE" ]] || die "normal raw image not found: $RAW_IMAGE"
[[ -s "$COMPRESSED_IMAGE" ]] || die "compressed normal image not found: $COMPRESSED_IMAGE"

if [[ $PROFILE == compact ]]; then
  validate_image_url "${IMAGE_URL:-}" || die \
    'IMAGE_URL must be a configured HTTPS release-asset URL (no OWNER/REPOSITORY placeholder)'
fi

MOUNT_DIR="$SYSTEM_SOURCE_DIR"
STAGING="$WORK_DIR/initramfs-$PROFILE"
INITRAMFS_OUT="$WORK_DIR/initramfs-$PROFILE.gz"
KERNEL_OUT="$WORK_DIR/vmlinuz-$PROFILE"

[[ -r "$MOUNT_DIR/kernel-version" ]] || die \
  "installed-system source cache is missing: $MOUNT_DIR (rebuild the normal image)"
rm -rf "$STAGING" "$INITRAMFS_OUT" "$KERNEL_OUT"
mkdir -p "$STAGING"

kernel_file=$(find "$MOUNT_DIR/boot" -maxdepth 1 -type f -name 'vmlinuz-*-generic' | sort -V | tail -n 1)
[[ -n $kernel_file ]] || die 'no generic Ubuntu kernel found in the normal image'
KERNEL_VERSION=${kernel_file##*/vmlinuz-}
[[ -d "$MOUNT_DIR/lib/modules/$KERNEL_VERSION" ]] || die "modules for $KERNEL_VERSION are missing"
cp "$kernel_file" "$KERNEL_OUT"
printf '%s\n' "$KERNEL_VERSION" > "$WORK_DIR/kernel-version-$PROFILE"
log "Building $PROFILE initramfs with Ubuntu kernel $KERNEL_VERSION"

mkdir -p "$STAGING"/{bin,sbin,dev,etc/micro-ubuntu,etc/ssl/certs,proc,sys,run,tmp,root,usr/bin,usr/sbin,lib/modules,lib/firmware}
busybox_source=
for candidate in "$MOUNT_DIR/bin/busybox" "$MOUNT_DIR/usr/bin/busybox"; do
  [[ -x $candidate ]] && busybox_source=$candidate && break
done
[[ -n $busybox_source ]] || die 'busybox-static is missing from the normal image'
cp -L "$busybox_source" "$STAGING/bin/busybox"
chmod 0755 "$STAGING/bin/busybox"

# Keep hard requirements limited to commands used by the production paths.
# Other useful applets receive links when enabled by Ubuntu's BusyBox build.
required_applets=(
  sh ash awk blockdev cat chmod clear cp cttyhack cut dd echo grep gzip hostname
  ip ls mdev mkdir mkfifo mknod modprobe mount reboot rm sed setsid sha256sum
  sleep sort stat stty sync tail tee tr udhcpc umount uname wget
)
optional_applets=(
  basename date dirname dmesg env find head kill ln lsmod mv nl od poweroff ps
  pwd readlink rmdir test touch uniq wc
)
applet_list=$($STAGING/bin/busybox --list)
$STAGING/bin/busybox sh -c 'set -o pipefail' \
  || die 'BusyBox ash lacks pipefail; safe streamed installation is unavailable'
for applet in "${required_applets[@]}"; do
  grep -qx "$applet" <<<"$applet_list" || die "required BusyBox applet is unavailable: $applet"
done
for applet in "${required_applets[@]}" "${optional_applets[@]}"; do
  grep -qx "$applet" <<<"$applet_list" || continue
  case "$applet" in
    modprobe|mdev) link_dir=sbin ;;
    *) link_dir=bin ;;
  esac
  ln -s /bin/busybox "$STAGING/$link_dir/$applet"
done
# mdev is installed for per-event hotplug only; PID 1 never runs mdev -s.

rsync -aH "$PROJECT_ROOT/src/initramfs/" "$STAGING/"
chmod 0755 "$STAGING/init" "$STAGING/etc/udhcpc.script" "$STAGING/usr/bin/"*
cp "$MOUNT_DIR/etc/ssl/certs/ca-certificates.crt" "$STAGING/etc/ssl/certs/"
: > "$STAGING/etc/resolv.conf"
cat > "$STAGING/etc/os-release" <<'EOF'
NAME="MicroUbuntu"
ID=microubuntu
ID_LIKE=ubuntu
PRETTY_NAME="MicroUbuntu temporary RAM session"
EOF

image_hash=$(sha256sum "$COMPRESSED_IMAGE" | awk '{print $1}')
raw_bytes=$(stat -c %s "$RAW_IMAGE")
validate_sha256 "$image_hash" || die 'could not calculate compressed-image SHA-256'
{
  printf "IMAGE_URL='%s'\n" "${IMAGE_URL:-}"
  printf "IMAGE_SHA256='%s'\n" "$image_hash"
  printf "IMAGE_RAW_BYTES='%s'\n" "$raw_bytes"
  printf "IMAGE_FILE_NAME='%s'\n" "$IMAGE_GZIP_NAME"
} > "$STAGING/etc/micro-ubuntu/release.env"
chmod 0444 "$STAGING/etc/micro-ubuntu/release.env"

base_modules=(
  atkbd i8042 serio_raw hid hid_generic usbhid
  ahci ata_piix nvme mmc_block sdhci sdhci_pci usb_storage uas
  xhci_pci ehci_pci ohci_pci uhci_hcd sr_mod cdrom isofs
  virtio_pci virtio_blk virtio_net
  e1000 e1000e igb igc r8169 tg3 bnx2 atl1c alx sky2 forcedeth
)
wifi_modules=(
  ext4 vfat nls_cp437 nls_iso8859_1
  cfg80211 mac80211 rfkill
  iwlwifi iwldvm iwlmvm
  ath9k ath9k_htc ath10k_pci ath10k_usb ath11k_pci
  brcmfmac b43 bcma ssb
  rtw88_pci rtw88_usb rtw88_8723de rtw88_8723du rtw88_8821ce
  rtw88_8822be rtw88_8822ce rtw89_pci rtw89_8852ae rtw89_8852be
  btusb bluetooth
)
modules=("${base_modules[@]}")
[[ $PROFILE == wifi ]] && modules+=("${wifi_modules[@]}")
python3 "$SCRIPT_DIR/copy_modules.py" --root "$MOUNT_DIR" --dest "$STAGING" \
  --kernel "$KERNEL_VERSION" "${modules[@]}"
depmod -b "$STAGING" "$KERNEL_VERSION"

if [[ $PROFILE == wifi ]]; then
  command_paths=()
  for command_name in iw rfkill wpa_supplicant wpa_cli wpa_passphrase; do
    command_path=
    for prefix in /usr/bin /usr/sbin /bin /sbin; do
      if [[ -x "$MOUNT_DIR$prefix/$command_name" ]]; then
        command_path="$prefix/$command_name"
        break
      fi
    done
    [[ -n $command_path ]] || die "Wi-Fi userspace command missing: $command_name"
    command_paths+=("$command_path")
  done
  python3 "$SCRIPT_DIR/copy_elf.py" --root "$MOUNT_DIR" --dest "$STAGING" "${command_paths[@]}"

  # Include redistributable Ubuntu linux-firmware families for the requested
  # open drivers. copy_modules.py already copied exact declared firmware; these
  # globs cover DMI/board-specific and wildcard requests too. The broad 'intel'
  # and 'mrvl' trees (SOF/AVS/i915/IPU3 and old Marvell) are intentionally
  # excluded: they are not needed by the target laptop Wi-Fi families and
  # would otherwise push the Wi-Fi ISO over GitHub's 2 GiB release limit.
  firmware_patterns=(
    'iwlwifi-*.ucode' 'ath9k_htc' 'ath10k' 'ath11k' 'brcm' 'cypress'
    'rtw88' 'rtw89' 'rtlwifi' 'rtl_nic' 'rtl_bt' 'mediatek'
    'regulatory.db' 'regulatory.db.p7s'
  )
  for pattern in "${firmware_patterns[@]}"; do
    while IFS= read -r -d '' firmware_path; do
      relative=${firmware_path#"$MOUNT_DIR/"}
      if [[ -d $firmware_path ]]; then
        mkdir -p "$STAGING/$relative"
        rsync -aH "$firmware_path/" "$STAGING/$relative/"
      else
        mkdir -p "$STAGING/$(dirname "$relative")"
        cp -a "$firmware_path" "$STAGING/$relative"
      fi
    done < <(find "$MOUNT_DIR/lib/firmware" -maxdepth 1 -name "$pattern" -print0 2>/dev/null)
  done
fi

# Device nodes make console startup robust even before devtmpfs is available.
mknod -m 0600 "$STAGING/dev/console" c 5 1
mknod -m 0666 "$STAGING/dev/null" c 1 3
mknod -m 0620 "$STAGING/dev/tty0" c 4 0
mknod -m 0620 "$STAGING/dev/tty1" c 4 1
mknod -m 0620 "$STAGING/dev/ttyS0" c 4 64

# Deterministic archive metadata keeps checksums stable for identical package inputs.
find "$STAGING" -xdev -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
(
  cd "$STAGING"
  find . -xdev -print0 | LC_ALL=C sort -z \
    | cpio --null --create --format=newc --owner=0:0 2>"$WORK_DIR/cpio-$PROFILE.log" \
    | gzip -9 -n > "$INITRAMFS_OUT"
)
gzip -t "$INITRAMFS_OUT"
find "$STAGING" -xdev -printf '%P\n' | LC_ALL=C sort > "$WORK_DIR/initramfs-$PROFILE.manifest"

initrd_bytes=$(stat -c %s "$INITRAMFS_OUT")
log "$PROFILE initramfs complete: $INITRAMFS_OUT ($(human_size "$initrd_bytes"))"

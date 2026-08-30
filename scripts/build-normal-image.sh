#!/usr/bin/env bash
# Build a persistent Ubuntu terminal image with BIOS and UEFI boot support.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
enable_error_report

require_root
require_commands debootstrap sgdisk losetup mkfs.ext4 mkfs.vfat mount umount mountpoint \
  chroot blkid readelf python3 gzip sha256sum rsync flock
ensure_dirs

LOCK_FILE="$BUILD_DIR/.normal-image.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || die 'another normal-image build is already running'

ROOT_MOUNT="$WORK_DIR/normal-root"
LOOP_DEVICE=
ROOT_PART=
EFI_PART=

cleanup() {
  local status=$?
  set +e
  if [[ -n ${ROOT_MOUNT:-} ]]; then
    for path in run dev/pts dev sys proc boot/efi; do
      safe_umount "$ROOT_MOUNT/$path"
    done
    safe_umount "$ROOT_MOUNT"
  fi
  if [[ -n ${LOOP_DEVICE:-} ]]; then
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
  fi
  if (( status != 0 )); then
    printf 'Normal-image build failed with status %s; mounts and loop devices were cleaned up.\n' "$status" >&2
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

log "Creating sparse ${IMAGE_SIZE_MIB} MiB raw image"
rm -rf "$ROOT_MOUNT"
mkdir -p "$ROOT_MOUNT"
rm -f "$RAW_IMAGE" "$COMPRESSED_IMAGE"
truncate -s "${IMAGE_SIZE_MIB}M" "$RAW_IMAGE"

# GPT layout: BIOS boot partition, EFI System Partition, Ubuntu root.
sgdisk --zap-all "$RAW_IMAGE" >/dev/null
sgdisk \
  --new=1:2048:+2M --typecode=1:ef02 --change-name=1:'BIOS boot' \
  --new=2:0:+256M --typecode=2:ef00 --change-name=2:'EFI System' \
  --new=3:0:0 --typecode=3:8300 --change-name=3:'MicroUbuntu root' \
  "$RAW_IMAGE" >/dev/null
sgdisk --verify "$RAW_IMAGE"

LOOP_DEVICE=$(losetup --find --show --partscan "$RAW_IMAGE")
EFI_PART=$(partition_path "$LOOP_DEVICE" 2)
ROOT_PART=$(partition_path "$LOOP_DEVICE" 3)
wait_for_path "$EFI_PART" || die "EFI partition $EFI_PART did not appear"
wait_for_path "$ROOT_PART" || die "root partition $ROOT_PART did not appear"

mkfs.vfat -F 32 -n MICROEFI "$EFI_PART" >/dev/null
mkfs.ext4 -F -L MICROROOT -m 1 "$ROOT_PART" >/dev/null
mount "$ROOT_PART" "$ROOT_MOUNT"
mkdir -p "$ROOT_MOUNT/boot/efi"
mount "$EFI_PART" "$ROOT_MOUNT/boot/efi"

log "Bootstrapping Ubuntu ${UBUNTU_SUITE}"
debootstrap --arch=amd64 --variant=minbase \
  --include=ca-certificates,gnupg "$UBUNTU_SUITE" "$ROOT_MOUNT" "$UBUNTU_MIRROR"

cat > "$ROOT_MOUNT/etc/apt/sources.list" <<EOF
# Official Ubuntu archives used by MicroUbuntu.
deb $UBUNTU_MIRROR $UBUNTU_SUITE main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_SUITE-updates main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_SUITE-backports main restricted universe multiverse
deb $UBUNTU_SECURITY_MIRROR $UBUNTU_SUITE-security main restricted universe multiverse
EOF
printf 'micro-ubuntu\n' > "$ROOT_MOUNT/etc/hostname"
cat > "$ROOT_MOUNT/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 micro-ubuntu
::1 localhost ip6-localhost ip6-loopback
EOF
cat > "$ROOT_MOUNT/etc/fstab" <<EOF
UUID=$(blkid -s UUID -o value "$ROOT_PART") / ext4 defaults,noatime 0 1
UUID=$(blkid -s UUID -o value "$EFI_PART") /boot/efi vfat umask=0077 0 1
EOF
printf 'Etc/UTC\n' > "$ROOT_MOUNT/etc/timezone"

# Make package installation safe in a chroot: services are enabled but never
# started against the GitHub runner's kernel.
cat > "$ROOT_MOUNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOT_MOUNT/usr/sbin/policy-rc.d"
cp -L /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf"
mount -t proc proc "$ROOT_MOUNT/proc"
mount -t sysfs sysfs "$ROOT_MOUNT/sys"
mount --rbind /dev "$ROOT_MOUNT/dev"
mount --make-rslave "$ROOT_MOUNT/dev"
mount -t tmpfs tmpfs "$ROOT_MOUNT/run"

export DEBIAN_FRONTEND=noninteractive
chroot "$ROOT_MOUNT" debconf-set-selections <<'EOF'
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices multiselect
keyboard-configuration keyboard-configuration/layoutcode string us
EOF

log 'Installing the terminal system, kernel, bootloaders, networking, firmware, and developer tools'
chroot "$ROOT_MOUNT" apt-get update
chroot "$ROOT_MOUNT" apt-get install -y --no-install-recommends \
  ubuntu-minimal systemd-sysv dbus kmod udev initramfs-tools linux-generic \
  grub2-common grub-pc-bin grub-efi-amd64-bin efibootmgr \
  network-manager netplan.io wpasupplicant iw rfkill wireless-regdb linux-firmware \
  busybox-static sudo python3 python3-venv python3-pip build-essential \
  git curl wget ca-certificates openssh-client rsync jq less nano locales tzdata \
  pciutils usbutils iproute2 iputils-ping ethtool

chroot "$ROOT_MOUNT" locale-gen en_US.UTF-8
cat > "$ROOT_MOUNT/etc/default/locale" <<'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

log 'Installing MicroUbuntu applications and persistent policy defaults'
rsync -aH "$PROJECT_ROOT/src/normal/" "$ROOT_MOUNT/"
find "$ROOT_MOUNT/usr/local/bin" "$ROOT_MOUNT/usr/local/sbin" -type f -exec chmod 0755 {} +
chmod 0644 "$ROOT_MOUNT/etc/micro-ubuntu/ai.conf"

for group in sudo audio video plugdev netdev; do
  chroot "$ROOT_MOUNT" groupadd --force "$group"
done
if ! chroot "$ROOT_MOUNT" id micro >/dev/null 2>&1; then
  chroot "$ROOT_MOUNT" useradd --create-home --shell /bin/bash \
    --groups sudo,audio,video,plugdev,netdev micro
fi
chroot "$ROOT_MOUNT" passwd --lock root
chroot "$ROOT_MOUNT" passwd --lock micro
micro_uid=$(chroot "$ROOT_MOUNT" id -u micro)
micro_gid=$(chroot "$ROOT_MOUNT" id -g micro)

install -d -m 2775 -o "$micro_uid" -g "$micro_gid" \
  "$ROOT_MOUNT/var/lib/micro-ubuntu" \
  "$ROOT_MOUNT/var/lib/micro-ubuntu/models" \
  "$ROOT_MOUNT/var/lib/micro-ubuntu/browser" \
  "$ROOT_MOUNT/var/lib/micro-ubuntu/hermes" \
  "$ROOT_MOUNT/var/lib/micro-ubuntu/settings"
touch "$ROOT_MOUNT/var/lib/micro-ubuntu/needs-password"
chown "$micro_uid:$micro_gid" "$ROOT_MOUNT/var/lib/micro-ubuntu/needs-password"
chroot "$ROOT_MOUNT" netplan generate

# One local-console autologin is used solely to reach the first-login chooser.
# The finalizer removes this override and the temporary passwordless sudo rule
# immediately after the user sets a password.
mkdir -p "$ROOT_MOUNT/etc/systemd/system/getty@tty1.service.d" "$ROOT_MOUNT/etc/sudoers.d"
cat > "$ROOT_MOUNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin micro --noclear %I $TERM
EOF
cat > "$ROOT_MOUNT/etc/sudoers.d/90-micro-firstboot" <<'EOF'
micro ALL=(root) NOPASSWD: /usr/local/sbin/micro-firstboot-finalize, /usr/local/bin/gui-builder
EOF
chmod 0440 "$ROOT_MOUNT/etc/sudoers.d/90-micro-firstboot"

chroot "$ROOT_MOUNT" systemctl enable NetworkManager.service
chroot "$ROOT_MOUNT" systemctl enable micro-ubuntu-ready.service
chroot "$ROOT_MOUNT" systemctl set-default multi-user.target

cat > "$ROOT_MOUNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR=MicroUbuntu
GRUB_CMDLINE_LINUX_DEFAULT="quiet console=ttyS0,115200n8 console=tty0"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_OS_PROBER=true
EOF

log 'Installing GRUB for legacy BIOS and amd64 UEFI'
chroot "$ROOT_MOUNT" update-initramfs -u -k all
chroot "$ROOT_MOUNT" grub-install --target=i386-pc --boot-directory=/boot --recheck "$LOOP_DEVICE"
chroot "$ROOT_MOUNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=MicroUbuntu --removable --no-nvram --no-uefi-secure-boot --recheck
chroot "$ROOT_MOUNT" update-grub
[[ -f "$ROOT_MOUNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || die 'removable-media UEFI loader was not installed'
grep -q '^menuentry ' "$ROOT_MOUNT/boot/grub/grub.cfg" || die 'installed-system GRUB menu is empty'

chroot "$ROOT_MOUNT" dpkg-query -W -f='${Package}\t${Version}\n' \
  | sort > "$OUT_DIR/micro-ubuntu-package-manifest.txt"

# Cache only the installed-system files needed to assemble initramfs images.
# This avoids detaching and repeatedly remounting the raw image read-only;
# hosted-runner loop partition nodes can be stale briefly after reattachment.
log 'Caching kernel, modules, firmware, BusyBox, and Wi-Fi runtime libraries'
rm -rf "$SYSTEM_SOURCE_DIR"
mkdir -p "$SYSTEM_SOURCE_DIR"/{boot,bin,etc/ssl/certs,lib/modules,lib/firmware,usr/bin,usr/sbin}
kernel_file=$(find "$ROOT_MOUNT/boot" -maxdepth 1 -type f -name 'vmlinuz-*-generic' | sort -V | tail -n 1)
[[ -n $kernel_file ]] || die 'no generic kernel was installed'
kernel_version=${kernel_file##*/vmlinuz-}
cp "$kernel_file" "$SYSTEM_SOURCE_DIR/boot/"
printf '%s\n' "$kernel_version" > "$SYSTEM_SOURCE_DIR/kernel-version"
rsync -aH "$ROOT_MOUNT/lib/modules/$kernel_version/" \
  "$SYSTEM_SOURCE_DIR/lib/modules/$kernel_version/"
rsync -aH "$ROOT_MOUNT/lib/firmware/" "$SYSTEM_SOURCE_DIR/lib/firmware/"
cp "$ROOT_MOUNT/etc/ssl/certs/ca-certificates.crt" "$SYSTEM_SOURCE_DIR/etc/ssl/certs/"
for busybox_path in "$ROOT_MOUNT/bin/busybox" "$ROOT_MOUNT/usr/bin/busybox"; do
  if [[ -x $busybox_path ]]; then
    cp -L "$busybox_path" "$SYSTEM_SOURCE_DIR/bin/busybox"
    break
  fi
done
[[ -x "$SYSTEM_SOURCE_DIR/bin/busybox" ]] || die 'busybox-static was not installed'
wifi_runtime_paths=()
for command_name in iw rfkill wpa_supplicant wpa_cli wpa_passphrase; do
  command_path=
  for prefix in /usr/bin /usr/sbin /bin /sbin; do
    if [[ -x "$ROOT_MOUNT$prefix/$command_name" ]]; then
      command_path="$prefix/$command_name"
      break
    fi
  done
  [[ -n $command_path ]] || die "Wi-Fi command was not installed: $command_name"
  wifi_runtime_paths+=("$command_path")
done
python3 "$SCRIPT_DIR/copy_elf.py" --root "$ROOT_MOUNT" --dest "$SYSTEM_SOURCE_DIR" \
  "${wifi_runtime_paths[@]}"

# Keep apt itself functional while removing only regenerable build residue.
chroot "$ROOT_MOUNT" apt-get clean
rm -rf "$ROOT_MOUNT/var/lib/apt/lists/"* "$ROOT_MOUNT/tmp/"* "$ROOT_MOUNT/var/tmp/"*
# Documentation and manual pages are regenerable and add hundreds of MiB to
# the compressed image; keep the appliance lean without touching package state.
rm -rf "$ROOT_MOUNT/usr/share/doc" "$ROOT_MOUNT/usr/share/man" \
  "$ROOT_MOUNT/usr/share/info" "$ROOT_MOUNT/var/cache/apt/"*
rm -f "$ROOT_MOUNT/usr/sbin/policy-rc.d"
rm -f "$ROOT_MOUNT/etc/resolv.conf"
ln -s ../run/NetworkManager/resolv.conf "$ROOT_MOUNT/etc/resolv.conf"
: > "$ROOT_MOUNT/etc/machine-id"
rm -f "$ROOT_MOUNT/var/lib/dbus/machine-id"
sync

# Unmount before compression and suppress cleanup attempts for detached state.
for path in run dev/pts dev sys proc boot/efi; do safe_umount "$ROOT_MOUNT/$path"; done
safe_umount "$ROOT_MOUNT"
losetup -d "$LOOP_DEVICE"
LOOP_DEVICE=

log 'Compressing the sparse raw image with gzip (maximum ratio)'
if command -v pigz >/dev/null 2>&1; then
  pigz -9 -n -c "$RAW_IMAGE" > "$COMPRESSED_IMAGE"
else
  gzip -9 -n -c "$RAW_IMAGE" > "$COMPRESSED_IMAGE"
fi
gzip -t "$COMPRESSED_IMAGE"

raw_bytes=$(stat -c %s "$RAW_IMAGE")
gzip_bytes=$(stat -c %s "$COMPRESSED_IMAGE")
sha256sum "$COMPRESSED_IMAGE" > "$OUT_DIR/$IMAGE_GZIP_NAME.sha256"
log "Normal image complete: $RAW_IMAGE ($(human_size "$raw_bytes"))"
log "Compressed asset: $COMPRESSED_IMAGE ($(human_size "$gzip_bytes"))"

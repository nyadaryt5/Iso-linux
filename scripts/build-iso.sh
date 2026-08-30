#!/usr/bin/env bash
# Assemble BIOS/UEFI hybrid installer media with exactly two GRUB entries.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
enable_error_report

require_root
require_commands grub-mkrescue xorriso cp sha256sum awk grep
ensure_dirs

PROFILE=${1:-}
case "$PROFILE" in compact|wifi) ;; *) die 'usage: build-iso.sh compact|wifi' ;; esac
[[ -s "$RAW_IMAGE" && -s "$COMPRESSED_IMAGE" ]] || die 'build the normal image first'

"$SCRIPT_DIR/build-initramfs.sh" "$PROFILE"
ISO_ROOT="$WORK_DIR/iso-$PROFILE"
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT/boot/grub" "$ISO_ROOT/.disk" "$ISO_ROOT/install"
cp "$WORK_DIR/vmlinuz-$PROFILE" "$ISO_ROOT/boot/vmlinuz"
cp "$WORK_DIR/initramfs-$PROFILE.gz" "$ISO_ROOT/boot/initrd.gz"
printf 'MicroUbuntu %s installer media\n' "$PROFILE" > "$ISO_ROOT/.disk/micro-ubuntu"

if [[ $PROFILE == compact ]]; then
  output=$COMPACT_ISO
  volume=MICROUBUNTU_BOOT
  install_argument=network
else
  output=$WIFI_ISO
  volume=MICROUBUNTU_WIFI
  install_argument=bundled
  cp --reflink=auto "$COMPRESSED_IMAGE" "$ISO_ROOT/install/$IMAGE_GZIP_NAME"
fi

cat > "$ISO_ROOT/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
set timeout_style=menu

# Serial is available for automated diagnostics, but tty0 is deliberately the
# final Linux console so physical laptops never require a serial connection.
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial

menuentry 'MicroUbuntu - Temporary session' --id=temporary {
    linux /boot/vmlinuz rdinit=/init ro console=ttyS0,115200n8 console=tty0 nomodeset micro.profile=$PROFILE
    initrd /boot/initrd.gz
}
menuentry 'MicroUbuntu - Normal installation (Ubuntu terminal system)' --id=normal-install {
    linux /boot/vmlinuz rdinit=/init ro console=ttyS0,115200n8 console=tty0 nomodeset micro.profile=$PROFILE install=$install_argument
    initrd /boot/initrd.gz
}
EOF

menu_count=$(grep -c '^[[:space:]]*menuentry ' "$ISO_ROOT/boot/grub/grub.cfg")
[[ $menu_count -eq 2 ]] || die "generated GRUB configuration has $menu_count menu entries"
grep -Fq "menuentry 'MicroUbuntu - Temporary session'" "$ISO_ROOT/boot/grub/grub.cfg"
grep -Fq "menuentry 'MicroUbuntu - Normal installation (Ubuntu terminal system)'" "$ISO_ROOT/boot/grub/grub.cfg"

rm -f "$output"
log "Creating $PROFILE BIOS/UEFI hybrid ISO"
grub-mkrescue -o "$output" "$ISO_ROOT" -- \
  -volid "$volume" -iso-level 3 -full-iso9660-filenames
[[ -s "$output" ]] || die 'grub-mkrescue did not produce an ISO'

report="$WORK_DIR/el-torito-$PROFILE.txt"
xorriso -indev "$output" -report_el_torito plain > "$report" 2>&1
grep -Eq 'BIOS|platform_id[[:space:]]+0x00' "$report" || die 'ISO has no BIOS El Torito entry'
grep -Eq 'UEFI|platform_id[[:space:]]+0xef' "$report" || die 'ISO has no UEFI El Torito entry'
xorriso -indev "$output" -report_system_area plain > "$WORK_DIR/system-area-$PROFILE.txt" 2>&1

iso_bytes=$(stat -c %s "$output")
if [[ $PROFILE == compact ]]; then
  max_bytes=$((COMPACT_ISO_MAX_MIB * 1024 * 1024))
  (( iso_bytes <= max_bytes )) || die \
    "compact ISO is $(human_size "$iso_bytes"), above the ${COMPACT_ISO_MAX_MIB} MiB safety ceiling"
fi
sha256sum "$output" > "$OUT_DIR/$(basename "$output").sha256"
write_checksums
log "$PROFILE ISO complete: $output ($(human_size "$iso_bytes"))"

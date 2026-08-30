#!/usr/bin/env bash
# Boot and safety tests. Every writable QEMU disk is a disposable regular file.
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/common.sh
source "$PROJECT_ROOT/scripts/lib/common.sh"
enable_error_report
require_commands qemu-system-x86_64 xorriso sha256sum timeout grep
[[ -s "$COMPACT_ISO" && -s "$WIFI_ISO" ]] || die 'both ISOs must exist before QEMU tests'
[[ -s "$CHECKSUM_FILE" ]] || die 'SHA256SUMS is missing'

TEMP=$(mktemp -d "$WORK_DIR/qemu-tests.XXXXXX")
RESULTS="$OUT_DIR/qemu-results.txt"
: > "$RESULTS"
PIDS=()
cleanup() {
  local status=$?
  set +e
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TEMP"
  exit "$status"
}
trap cleanup EXIT INT TERM

(cd "$OUT_DIR" && sha256sum --check SHA256SUMS)
echo 'SHA256SUMS: PASS' >> "$RESULTS"

inspect_iso() {
  local iso=$1 name=$2 extract_dir="$TEMP/extract-$2"
  mkdir -p "$extract_dir"
  xorriso -osirrox on -indev "$iso" \
    -extract /boot/grub/grub.cfg "$extract_dir/grub.cfg" >/dev/null 2>&1
  local count
  count=$(grep -c '^[[:space:]]*menuentry ' "$extract_dir/grub.cfg")
  [[ $count -eq 2 ]] || die "$name has $count GRUB menu entries"
  grep -Fq "menuentry 'MicroUbuntu - Temporary session'" "$extract_dir/grub.cfg"
  grep -Fq "menuentry 'MicroUbuntu - Normal installation (Ubuntu terminal system)'" "$extract_dir/grub.cfg"
  grep -Fq 'console=tty0' "$extract_dir/grub.cfg"
  echo "$name GRUB entries: PASS (exactly two)" >> "$RESULTS"
}
inspect_iso "$COMPACT_ISO" compact
inspect_iso "$WIFI_ISO" wifi

assert_clean_log() {
  local log_file=$1
  if grep -Eqi 'Kernel panic|Attempted to kill init' "$log_file"; then
    tail -n 100 "$log_file" >&2
    die "panic signature found in $log_file"
  fi
}

run_until_marker() {
  local marker=$1 log_file=$2
  shift 2
  : > "$log_file"
  qemu-system-x86_64 \
    -machine pc,accel=tcg -cpu max -m 2048 -no-reboot -no-shutdown \
    -display none -serial stdio -monitor none "$@" >"$log_file" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  local found=0
  for _ in $(seq 1 90); do
    if grep -Fq "$marker" "$log_file"; then found=1; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
  done
  sleep 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  PIDS=("${PIDS[@]/$pid}")
  assert_clean_log "$log_file"
  if [[ $found -ne 1 ]]; then
    tail -n 120 "$log_file" >&2
    diagnostic=$(tail -c 2400 "$log_file" | tr '\r\n' ' ')
    die "QEMU did not reach $marker in $(basename "$log_file"). Log tail: $diagnostic"
  fi
}

for pair in "compact:$COMPACT_ISO" "wifi:$WIFI_ISO"; do
  name=${pair%%:*}
  iso=${pair#*:}
  run_until_marker MICROUBUNTU_MENU_READY "$TEMP/$name-bios.log" \
    -boot d -cdrom "$iso"
  echo "$name BIOS boot/menu: PASS" >> "$RESULTS"
done

ovmf_code=
ovmf_vars=
for pair in \
  '/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd' \
  '/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd'; do
  code=${pair%%:*}
  vars=${pair#*:}
  if [[ -r $code && -r $vars ]]; then
    ovmf_code=$code
    ovmf_vars=$vars
    break
  fi
done
if [[ -n $ovmf_code ]]; then
  for pair in "compact:$COMPACT_ISO" "wifi:$WIFI_ISO"; do
    name=${pair%%:*}
    iso=${pair#*:}
    vars_copy="$TEMP/$name-uefi-vars.fd"
    cp "$ovmf_vars" "$vars_copy"
    run_until_marker MICROUBUNTU_MENU_READY "$TEMP/$name-uefi.log" \
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code" \
      -drive "if=pflash,format=raw,unit=1,file=$vars_copy" \
      -boot d -cdrom "$iso"
    echo "$name UEFI boot/menu: PASS" >> "$RESULTS"
  done
else
  echo 'UEFI ISO boot: SKIPPED (OVMF code/variables not installed)' >> "$RESULTS"
fi

# Boot the installed raw image through each bootloader in snapshot mode, so
# first-boot services cannot modify the build artifact.
run_until_marker MICROUBUNTU_INSTALLED_READY "$TEMP/installed-bios.log" \
  -boot c -drive "file=$RAW_IMAGE,format=raw,if=virtio,snapshot=on"
echo 'installed raw image BIOS boot: PASS' >> "$RESULTS"
if [[ -n $ovmf_code ]]; then
  installed_vars="$TEMP/installed-uefi-vars.fd"
  cp "$ovmf_vars" "$installed_vars"
  run_until_marker MICROUBUNTU_INSTALLED_READY "$TEMP/installed-uefi.log" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code" \
    -drive "if=pflash,format=raw,unit=1,file=$installed_vars" \
    -boot c -drive "file=$RAW_IMAGE,format=raw,if=virtio,snapshot=on"
  echo 'installed raw image UEFI boot: PASS' >> "$RESULTS"
else
  echo 'installed raw image UEFI boot: SKIPPED (OVMF code/variables not installed)' >> "$RESULTS"
fi

# Extract one direct-boot kernel/initramfs pair from each profile. Direct boot
# selects deterministic installer self-tests without changing release GRUB.
for pair in "compact:$COMPACT_ISO" "wifi:$WIFI_ISO"; do
  name=${pair%%:*}
  iso=${pair#*:}
  mkdir -p "$TEMP/$name"
  xorriso -osirrox on -indev "$iso" \
    -extract /boot/vmlinuz "$TEMP/$name/vmlinuz" \
    -extract /boot/initrd.gz "$TEMP/$name/initrd.gz" >/dev/null 2>&1
done

run_installer_test() {
  local test_name=$1 profile=$2 marker=$3
  local disk="$TEMP/$test_name.disk" log_file="$TEMP/$test_name.log"
  truncate -s 96M "$disk"
  local before after
  before=$(sha256sum "$disk" | awk '{print $1}')
  run_until_marker "$marker" "$log_file" \
    -kernel "$TEMP/$profile/vmlinuz" -initrd "$TEMP/$profile/initrd.gz" \
    -append "rdinit=/init console=tty0 console=ttyS0,115200n8 micro.profile=$profile micro.test=$test_name" \
    -drive "file=$disk,format=raw,if=virtio,cache=unsafe"
  after=$(sha256sum "$disk" | awk '{print $1}')
  if [[ $test_name == cancel || $test_name == bad-checksum ]]; then
    [[ $before == "$after" ]] || die "$test_name modified its disposable disk"
  fi
  echo "installer $test_name: PASS" >> "$RESULTS"
}

run_installer_test cancel compact MICRO_TEST_CANCEL_OK
run_installer_test bad-checksum compact MICRO_TEST_CHECKSUM_OK
run_installer_test write compact MICRO_TEST_WRITE_OK
run_installer_test wifi-failure wifi MICRO_TEST_WIFI_RETRY_OK

cat "$RESULTS"

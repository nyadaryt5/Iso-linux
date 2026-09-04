# MicroUbuntu

MicroUbuntu builds a persistent, terminal-first Ubuntu system and two amd64 installer ISOs. The build is reproducible from source in this repository; generated disk images are release/workflow artifacts rather than source files.

## Deliverables

| Artifact | Purpose | Typical size |
|---|---|---:|
| `micro-ubuntu-bootstrap.iso` | Compact Ethernet/network bootstrap. It carries only an Ubuntu GA kernel, BusyBox, common wired/storage modules, and the verified streaming installer. | Target: about 20 MiB; enforced maximum: 32 MiB |
| `micro-ubuntu-wifi-installer.iso` | Larger installer with the compressed normal image, Wi-Fi tools, common open drivers, and Ubuntu firmware. | Hundreds of MiB or more |
| `micro-ubuntu-full.img.gz` | Gzip-compressed **raw GPT disk image** installed by either ISO. It is not QCOW2. | Build-dependent |
| `SHA256SUMS` | SHA-256 for every published ISO and compressed image. | Small text file |

Both ISOs support legacy BIOS and amd64 UEFI and contain exactly these two GRUB entries:

1. `MicroUbuntu - Temporary session`
2. `MicroUbuntu - Normal installation (Ubuntu terminal system)`

The images currently use Ubuntu 22.04 LTS (`jammy`) and its 5.15 GA kernel, chosen for broad compatibility with older laptops. The removable-media UEFI loader is not Secure Boot signed; disable Secure Boot before booting it.

GitHub publishes release assets with a hard 2 GiB per-file limit, so the Wi-Fi ISO (which bundles the compressed raw image) is capped at `WIFI_ISO_MAX_MIB` (default 2040 MiB). The build fails with a clear message if the cap is exceeded instead of failing silently during release upload.

## What each boot option does

### Temporary session

The first entry starts a terminal session entirely from the initramfs. It mounts no disk and writes no disk. PID 1 keeps a menu/recovery loop alive even after a shell or command fails. `tty0` remains the physical controlling console; serial output is mirrored only for automated QEMU diagnostics. Early boot uses devtmpfs, explicitly initializes console/keyboard/block/network support, and never performs an unbounded `mdev -s` scan.

### Normal installation — destructive warning

> **Warning:** normal installation erases the selected whole disk, including all partitions and data.

The installer lists only supported whole disks (`/dev/sda`, `/dev/vda`, `/dev/nvme0n1`, `/dev/mmcblk0`, and similar names), excludes detected installer media, shows a numbered selection, repeats the selected device, and writes only after the user types exactly `INSTALL`.

The compact ISO requires working Internet, normally over Ethernet. Its release-asset URL and expected SHA-256 are embedded at build time; it never asks the booted user to type an image URL. To avoid writing unverified network data, it downloads and hashes the complete compressed stream once, then downloads it again while streaming gzip decompression to the selected disk and checks the second stream too.

The Wi-Fi ISO bundles `micro-ubuntu-full.img.gz`, verifies it before opening a target disk, and can work offline. Its setup screen can unblock Wi-Fi, scan with `iw`, select an SSID, read the password without echo, associate with `wpa_supplicant`, obtain DHCP, and return to a retry menu after failure. A successful connection is saved as a mode-0600 NetworkManager profile in the installed system.

After writing and `sync`, the installer asks the user to remove the installer media. It reboots only when the user then types exactly `REBOOT`.

## Wi-Fi hardware coverage

The larger initramfs includes dependency closures for, and firmware declared by, these open Linux driver families:

- Intel `iwlwifi` (`iwldvm` and `iwlmvm`)
- Qualcomm/Atheros `ath9k`, `ath9k_htc`, `ath10k`, and `ath11k`
- Broadcom/Cypress `brcmfmac`
- legacy open Broadcom `b43`, `bcma`, and `ssb`
- Realtek USB `r8188eu` support for RTL8188EU/ETV/FTV-class 802.11n dongles, including ZEB-USB150WF1 / RTL8188FTV on Ubuntu 22.04's 5.15 kernel
- Realtek `rtw88` and `rtw89`
- common Bluetooth USB support and Intel/Realtek/Broadcom Bluetooth firmware

The build additionally copies the corresponding redistributable files from Ubuntu's `linux-firmware` package. Proprietary Broadcom `wl` is deliberately not included. Some old `b43` adapters require separately licensed firmware that Ubuntu cannot redistribute in `linux-firmware`; those devices may need Ethernet or a supported USB Wi-Fi adapter for installation. A Broadcom USB Bluetooth device does not prove that the laptop's Wi-Fi chipset is Broadcom.

No finite installer can cover every adapter revision. Check `dmesg`, `lspci -nn`, `lsusb`, and `rfkill` from the temporary session when reporting unsupported hardware.

## Flashing with EtchDroid

1. Download **one ISO** and `SHA256SUMS` from the same GitHub Release. Use the compact ISO for wired Internet or the Wi-Fi ISO when laptop Wi-Fi support is needed.
2. Verify the file before flashing (instructions below).
3. Connect a USB drive to the Android device with a reliable USB-OTG adapter. Everything on that USB drive will be erased.
4. Open EtchDroid and choose **Write raw image or ISO**.
5. Select `micro-ubuntu-bootstrap.iso` or `micro-ubuntu-wifi-installer.iso` from Android storage.
6. Select the external USB drive carefully—never select storage containing data you need—and approve the write.
7. Wait for EtchDroid to report completion, then safely eject the USB drive.
8. On an HP laptop, insert the drive, disable Secure Boot, power on, press **Esc**, then use **F9 Boot Device Options** and select the USB entry. Prefer the UEFI entry; legacy BIOS is also supported.

Do not extract the ISO and do not flash `micro-ubuntu-full.img.gz` as the installer USB. The compressed raw image is an installer payload, not the two-entry boot ISO.

## Verifying downloads

Keep `SHA256SUMS` in the same directory as the downloads.

Linux:

```bash
sha256sum --check SHA256SUMS
```

To check only one file:

```bash
grep 'micro-ubuntu-wifi-installer.iso$' SHA256SUMS | sha256sum --check -
```

Android terminal environments such as Termux can run the same `sha256sum` commands. A mismatch means the download must not be flashed.

## Installed terminal system

The raw image has GPT partitions for BIOS GRUB, a FAT32 EFI System Partition, and an ext4 root. It contains Ubuntu/systemd, apt, NetworkManager, the `micro` user with sudo access, the GA kernel, Python, build tools, Git, curl, wget, CA certificates, the SSH client, rsync, jq, Wi-Fi tools, and firmware.

To stay under GitHub's 2 GiB per-asset release limit, the image ships with `linux-image-generic` (kernel plus base and extra modules) but without the `linux-headers-generic` metapackage, and `linux-firmware` is trimmed to the common laptop families listed above plus Intel/AMD GPU and Realtek NIC basics. On the installed system, kernel headers and the full firmware set are one command away: `sudo apt-get install linux-headers-generic linux-firmware`.

A one-time local-console autologin reaches the first-login chooser. It shows exactly:

1. Terminal-based system
2. Build graphical interface
3. Decide later

The user then sets a password; successful password setup removes both one-time autologin and its narrowly scoped passwordless-sudo rule.

MicroAI, MicroHermes, Browser Agent, provider settings, local-model configuration, and model/browser/Hermes state live in persistent storage. API keys are read into memory and are not written by the tools. `AI_RUN_AS_ROOT=0` is the immutable default. Privileged AI commands remain blocked until the local user runs `micro-power enable` and types exactly `ENABLE POWER MODE`; each proposed command still requires `EXECUTE`.

A GUI is intentionally absent initially:

```bash
sudo gui-builder --light   # Xorg, Openbox, Xterm, LightDM
sudo gui-builder --full    # Ubuntu Desktop Minimal
```

The next boot changes to `graphical.target` only after package installation and display-manager checks succeed. An AI-originated GUI build is subject to the same explicit power-mode gate.

## Building locally

Use a Linux amd64 host with at least 25 GiB free and passwordless/root access to loop devices and mounts. On Ubuntu 24.04, install:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  debootstrap gdisk dosfstools e2fsprogs util-linux kmod cpio gzip pigz \
  rsync xorriso grub2-common grub-pc-bin grub-efi-amd64-bin mtools \
  qemu-system-x86 ovmf binutils file python3 shellcheck
```

Set the immutable/public location where the compressed raw image will be published, then build:

```bash
export IMAGE_URL='https://github.com/YOUR-OWNER/YOUR-REPOSITORY/releases/download/v1.0.0/micro-ubuntu-full.img.gz'
make test
make check-host
sudo -E make all
```

`IMAGE_URL` is a build-time release setting, not a boot-time prompt. The build fails if it is empty, non-HTTPS, or still contains `OWNER/REPOSITORY`. Outputs are placed in `build/out/`. Cleanup traps unmount filesystems and detach loop devices on success and failure.

## GitHub Actions

Open **Actions → Build MicroUbuntu images → Run workflow**. An optional `image_url` can select an already planned immutable release URL. Otherwise normal branch builds embed this repository's `releases/latest/download/...` URL, while `v*` tag builds embed that tag's URL.

The workflow:

1. prints and reclaims runner disk space, then requires at least 25 GiB free;
2. proves that loop attachment, partition scanning, formatting, mounting, and BIOS/UEFI `grub-install` work on a disposable probe image;
3. builds the normal terminal image first;
4. builds the compact and Wi-Fi initramfs/ISOs;
5. checks shell/Python syntax, menu entries, checksums, BIOS boot, UEFI boot with OVMF, cancellation, bad-checksum rejection, a disposable-disk write, and the Wi-Fi retry path;
6. uploads both ISOs, the compressed raw image, `SHA256SUMS`, package manifest, and test summary;
7. publishes those files as GitHub Release assets for `v*` tags.

For a workflow run, download the `micro-ubuntu-amd64-<commit>` artifact from the run page. On a tagged release, use the Release assets instead.

## Test status and limitations

QEMU results are written to `build/out/qemu-results.txt` and the Actions job summary. BIOS and UEFI results are reported separately. Installer safety tests attach only newly created disposable QEMU disks; they never select the runner root disk.

This repository does **not** claim physical testing on any particular HP laptop. QEMU verifies boot structure and software behavior, not every BIOS quirk, keyboard, GPU, Wi-Fi revision, radio switch, or firmware combination. Physical-hardware results should be reported separately with exact laptop model and PCI/USB IDs.

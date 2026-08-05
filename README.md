# VyOS for Radxa ROCK 5B

Unofficial VyOS rolling image for the **Radxa ROCK 5B**, built by combining:

- the VyOS ARM64 userspace and configuration system;
- an Armbian ROCK 5B kernel, firmware, modules, and boot chain;
- ROCK 5B-specific first-boot networking helpers.

> [!WARNING]
> This is an unofficial community build. It is not produced, supported, or endorsed by the VyOS project or Radxa. Rolling releases may contain regressions and should be tested before production use.

## What works

- ROCK 5B boot through the Armbian boot chain
- HDMI and serial console
- Realtek RTL8125 Ethernet through the `r8169` driver
- Predictable wired interface name `eth0`
- Automatic wired WAN setup on the first boot:
  - DHCP on the detected Ethernet interface
  - default-route distance `1`
  - SSH enabled
- Optional wireless AP and DHCP setup through the included helper script
- Optional modem setup through the included modem helper script

The first-boot Ethernet setup starts after VyOS has completed its normal boot configuration. It saves the Ethernet and SSH settings to `/config/config.boot`, starts the persistent VyOS DHCP client, and disables its own first-boot timer after success.

## Download a ready-to-use image

Open the repository's **Releases** page and download:

```text
vyos-rock5b-fresh.img.xz
SHA256SUMS
```

Verify the download on Linux:

```bash
sha256sum -c SHA256SUMS
```

The uncompressed image is approximately 6 GB. Use a target drive larger than the image; an 8 GB or larger SD card, eMMC module, NVMe SSD, or USB drive is recommended.

## Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is available for Linux, Windows, and macOS.

1. Start balenaEtcher.
2. Select `vyos-rock5b-fresh.img.xz` directly. Manual extraction is normally not required.
3. Select the SD card, eMMC module, SSD, or USB drive.
4. Click **Flash**.
5. Wait for flashing and verification to finish.

> [!CAUTION]
> Flashing destroys all data on the selected target drive. Verify the destination carefully.

## Flash from Linux with `dd`

### Option A: write the compressed image directly

Replace `/dev/sdX` with the complete target device, not a partition such as `/dev/sdX1`.

```bash
sudo umount /dev/sdX?* 2>/dev/null || true
xz -dc vyos-rock5b-fresh.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### Option B: extract first, then write

This may be faster on slower computers because decompression and writing do not occur simultaneously.

```bash
xz -dk vyos-rock5b-fresh.img.xz
sudo umount /dev/sdX?* 2>/dev/null || true
sudo dd if=vyos-rock5b-fresh.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Safely eject the drive when finished:

```bash
sudo eject /dev/sdX
```

## First boot

1. Connect the ROCK 5B Ethernet port to a network that provides DHCP.
2. Insert or attach the flashed boot drive.
3. Power on the ROCK 5B.
4. Allow approximately 60–90 seconds for first-boot configuration.
5. Find the assigned address in your router or DHCP server.
6. Connect over SSH:

```bash
ssh vyos@192.168.1.100
```

Replace the example address with the address assigned to your ROCK 5B.

Check Ethernet locally from the HDMI or serial console:

```bash
ip -4 -br addr show eth0
```

First-boot diagnostics:

```bash
cat /config/dhcp-wan-firstboot-wrapper.log
cat /config/dhcp-wan-ssh-setup.log
systemctl status dhclient@eth0.service --no-pager -l
```

The first-boot marker is:

```text
/config/.dhcp-wan-ssh-firstboot-done
```

## Optional helper scripts

The image includes helper scripts in `/home/vyos`.

### Configure a wireless access point

```bash
/home/vyos/ap-dhcp-wan-setup.sh
```

This is separate from the automatic wired DHCP/SSH setup. Run it only when an access point, DHCP server, DNS forwarding, and NAT are required.

### Configure a modem

```bash
sudo /home/vyos/modem-connect.sh
```

Modem support depends on the modem, transport, drivers, firmware, carrier, and APN.

## Supported wireless cards and modems

### Wi-Fi adapters (for the optional access point script)

`ap-dhcp-wan-setup.sh` does not hard-code a specific chipset. It enumerates every `phy` under `/sys/class/ieee80211`, reads each one's supported interface modes directly from the kernel (`iw phy <phy> info`), and only offers devices that report **AP (access-point) mode** support. Any Wi-Fi adapter with a Linux `mac80211`-based driver that advertises AP mode should work automatically, without needing to be listed anywhere.

**Known to work well on ROCK 5B:**

- **M.2/PCIe, onboard-style cards** — MediaTek MT7921-class and Realtek RTL8852-class M.2 Wi-Fi 6 (802.11ax) modules, as commonly bundled with ROCK 5B kits (e.g. AP6275P-type modules). These typically expose both 2.4GHz and 5GHz AP-capable radios and are detected automatically.
- **USB adapters** — MediaTek MT7612U-based USB dongles (802.11ac, dual-band, AP-capable) have been tested and work reliably. Most `mt76`-driven and `rtl88xxau`-driven USB adapters that support AP mode should work the same way.

**Generally not usable for the AP script:**

- Adapters whose driver only supports client/station mode (no AP mode in `mac80211`) — the script will list them but exclude them from the selectable AP device list.
- Some cheap Realtek RTL8188-class USB dongles have unreliable or missing AP-mode support depending on driver version.

If a card is not detected at all, first check `ip link show` / `iw dev` to confirm Linux sees the radio, and `dmesg` for driver load errors.

### Cellular modems (for the optional modem script)

`modem-connect.sh` supports PCIe- and USB-attached modems through ModemManager (QMI/MBIM) as well as a raw AT/RNDIS fallback path. It auto-detects the transport and backend rather than requiring a fixed modem list.

**Tested and confirmed working:**

- **Fibocom FM350-GL** (PCIe or USB, `mtk_t7xx` driver) — including automatic FCC unlock over the AT port.

**Expected to work (same backend/driver family, not individually verified on this image):**

- **Quectel RM505Q** (PCIe/USB, QMI/MBIM)
- **Intel-based modems using the XMM7560 chipset** (USB, MBIM)
- Most other QMI- or MBIM-capable modems supported by ModemManager, since the script talks to the modem through ModemManager rather than a chipset-specific driver path.

Modem support in practice also depends on the SIM carrier, APN settings, and regional firmware/band locking — a modem being electrically and driver-wise supported does not guarantee a given carrier will connect without additional APN configuration.

## Build the image with GitHub Actions

The repository includes the workflow:

```text
.github/workflows/build-vyos-rock5b.yml
```

### Build from the GitHub website

1. Fork or clone this repository.
2. Open **Actions**.
3. Select **Build VyOS Rock5B Image (Rolling + Armbian)**.
4. Click **Run workflow** and select the `rolling` branch.
5. Wait for the workflow to finish.
6. Download the `vyos-rock5b-image` artifact from the completed run.

### Build with GitHub CLI

Install and authenticate GitHub CLI, then run:

```bash
gh auth login
gh workflow run build-vyos-rock5b.yml --repo OWNER/vyos-build --ref rolling
sleep 5
gh run list --repo OWNER/vyos-build --workflow=build-vyos-rock5b.yml --limit 1
```

Watch the run using the displayed run ID:

```bash
gh run watch RUN_ID --repo OWNER/vyos-build --exit-status
```

Download the completed artifact:

```bash
mkdir -p ~/Downloads/vyos-rock5b-RUN_ID
gh run download RUN_ID --repo OWNER/vyos-build --dir ~/Downloads/vyos-rock5b-RUN_ID
```

The compressed image is normally located at:

```text
~/Downloads/vyos-rock5b-RUN_ID/vyos-rock5b-image/vyos-rock5b-fresh.img.xz
```

Replace `OWNER` with your GitHub username and `RUN_ID` with the actual workflow run ID.

## Build design

The image is assembled from two main components:

1. **Armbian ROCK 5B base** — bootloader, TF-A/U-Boot chain, device tree, Linux kernel, modules, and firmware.
2. **VyOS ARM64 root filesystem** — VyOS userspace, configuration system, services, and CLI.

The build process keeps the Armbian-compatible physical image and boot chain, merges the VyOS root filesystem with the ROCK 5B kernel components, injects the default configuration and helper scripts, and creates a flashable disk image.

## Create a GitHub Release

Generate a checksum for the compressed image:

```bash
cd /path/to/vyos-rock5b-image
sha256sum vyos-rock5b-fresh.img.xz > SHA256SUMS
```

Create a release and upload the compressed image and checksum:

```bash
gh release create v2026.08.05-rock5b \
  vyos-rock5b-fresh.img.xz \
  SHA256SUMS \
  --repo frogro/vyos-build \
  --target rolling \
  --title "VyOS Rolling for ROCK 5B - 2026-08-05" \
  --notes "Unofficial VyOS rolling image for the Radxa ROCK 5B. See the README for flashing and first-boot instructions."
```

To add or replace an asset on an existing release:

```bash
gh release upload v2026.08.05-rock5b vyos-rock5b-fresh.img.xz SHA256SUMS --repo frogro/vyos-build --clobber
```

GitHub Release assets must each be smaller than 2 GiB. The raw `vyos-rock5b-fresh.img` is approximately 6 GB and therefore cannot be uploaded as one normal GitHub Release asset. Publish the compressed `.img.xz` file instead. If it is also 2 GiB or larger, it must be split into parts or hosted elsewhere.

## Updating from upstream

This repository contains ROCK 5B-specific changes on top of VyOS build sources. Review upstream changes before syncing or rebasing, especially modifications involving:

- ARM64 image generation;
- boot and root filesystem assembly;
- systemd and first-boot services;
- interface naming;
- VyOS configuration migration.

Always keep a backup branch or tag before a major upstream synchronization.

## License and trademarks

The repository contains or builds software from multiple upstream projects. Their respective licenses remain in effect. Review the license and copyright files included in the repository and generated image.

VyOS is a trademark of Sentrium S.L. Radxa and ROCK 5B are associated with Radxa Computer Co., Ltd. This project is an independent community effort.

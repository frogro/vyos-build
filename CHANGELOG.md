# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v2026.08.08-rock5b] - 2026-08-08

Updated ROCK 5B build with the DWC3/USB3 host fix and the latest tested networking helpers.

### Changed

- Updated the Armbian ROCK 5B boot/kernel base to `7.1.7-edge-rockchip64`.
- Switched the build workflow default base-layer release to `armbian-rock5b-dwc3-fix`.
- Added checksum verification for the downloaded Armbian base image during the GitHub Actions build.
- Updated `ap-dhcp-wan-setup.sh` to reproduce the known-good AP/DHCP/DNS/firewall configuration and keep Ethernet as the preferred WAN.
- Updated `modem-connect.sh` to the tested v5.3 ROCK 5B variant with native FM350 USB/RNDIS `eth1`, Ethernet metric preference, WWAN metric 200 fallback, event-driven recovery, and FM350-specific ModemManager isolation.
- Updated `set-locales.sh` so persistent `C.UTF-8` system locale handling is also applied when no VyOS configuration changes are required.

### Fixed

- Restored xHCI/DWC3 USB3 host support on the ROCK 5B; SuperSpeed devices can enumerate at 5 Gbit/s instead of falling back to the EHCI USB2 path.
- Prevented legacy `wwanusb0` rename state from taking ownership of the FM350 RNDIS interface on the ROCK 5B.
- Prevented the WWAN failover monitor from interrupting an already running modem reconnect/registration attempt.
- Prevented ModemManager from probing the FM350 while it is managed through the dedicated USB AT/RNDIS backend, without disabling ModemManager support for other modem types.
- Added explicit AP DNS forwarding and forward-chain rules matching the tested stable `config.boot` layout.

### Build

- The workflow now verifies the Armbian base-layer `SHA256SUMS`.
- The workflow now generates and uploads `SHA256SUMS` together with `vyos-rock5b-fresh.img.xz`.
- Release image SHA256 is recorded in the release `SHA256SUMS` asset.

## [armbian-rock5b-dwc3-fix] - 2026-08-08

Updated base-layer release; not a flashable VyOS image on its own.

### Changed

- Updated the ROCK 5B Armbian edge kernel from `7.1.3-edge-rockchip64` to `7.1.7-edge-rockchip64`.
- Added the DWC3 dual-role/host fix required for xHCI USB3 SuperSpeed host operation on the tested ROCK 5B USB3 path.
- Added a `SHA256SUMS` release asset for integrity verification.


## [v2026.08.09-rock5b] - 2026-08-09

Updated ROCK 5B community image with improved 5 GHz Wi-Fi configuration, USB modem handling, and first-boot networking.

### Wireless AP
- Changed the preferred 5 GHz AP mode from experimental 802.11ax to the proven 802.11ac path.
- Added explicit 80 MHz VHT configuration for 5 GHz:
  - HT40+
  - VHT80
  - automatic 80 MHz center-channel mapping
  - short GI 80
- Added the `5GHz Fast / 802.11ac / 80MHz` profile to the interactive AP setup.
- Verified on `wlan0` with channel 36 / 80 MHz and negotiated VHT client links up to 780 Mbit/s with NSS2.
- 2.4 GHz Wi-Fi 6 / 802.11ax support remains available when supported by the selected adapter.
- Wireless adapter selection and persistent MAC binding remain supported.

### FM350 / WWAN
- FM350-GL USB/RNDIS remains supported as the cellular fallback WAN.
- FM350 RNDIS interfaces are excluded from normal Ethernet-WAN auto-detection.
- FCC unlock and AT/RNDIS connection handling remain integrated with the modem startup workflow.
- Ethernet WAN remains preferred when available; cellular WAN can be used as fallback.

### Networking
- Preserved Photobooth AP, DHCP, DNS forwarding, SSH and NAT setup.
- AP setup continues to work when no Ethernet carrier is present.
- Ethernet WAN can be added later by reconnecting a cable and rerunning the setup.

### Image
- ROCK 5B flashable image built from the `rolling` branch.
- SHA256 checksum is supplied with the release assets.
## [v2026.08.07-rock5b] - 2026-08-07

Updated community build with improved modem handling, locale initialization, and image security.

### Changed

- Updated the VyOS Rolling ARM64 userspace used for the ROCK 5B image.
- Updated the VyOS build environment to kernel package `6.18.41-1`.
- Converted the ROCK 5B helper scripts to consistent English output and prompts.
- Improved `set-locales.sh` with configurable timezone, keyboard layout, wireless regulatory domain, DNS, and NTP servers.
- Persisted the `C.UTF-8` locale for system services to prevent Perl locale warnings during early boot.
- Improved the default image injection logic in `inject-defaults.sh`.
- Improved FM350-GL detection and connection handling for both PCIe and USB transports.
- Added a dedicated AT/RNDIS path for FM350-GL operation over USB without relying on ModemManager for the data connection.
- Improved Ethernet WAN preference with WWAN fallback routing.

### Fixed

- Fixed stale FM350 FCC-unlock and AT-port runtime state after USB modem re-enumeration.
- Improved automatic FM350 recovery after USB disconnects and modem reboots.
- Fixed duplicate or stale DNS and NTP settings when rerunning the locale setup helper.
- Fixed `set-locales.sh` behavior when the requested configuration is already active.
- Removed embedded SSH host keys from the generated image so every installed system can generate its own host identity.
- Reduced locale-related warnings during VyOS boot services.

### Security

- SSH private host keys are no longer included in the distributed image.
- Each installed system generates its own SSH host keys.

### Build

- Built successfully from the VyOS Rolling ARM64 repository after publication of the `6.18.41-1` ARM64 kernel packages.
- The ROCK 5B continues to boot with the Armbian `7.1.3-edge-rockchip64` kernel supplied by the ROCK 5B boot layer; the VyOS kernel package in the root filesystem is separate.
- Release image SHA256:
  `511a266f1498efa15c5502b14392db89366425a8603bf9294f72ad541738b0a3`


## [v2026.08.05-rock5b] - 2026-08-05

Initial public release.

### Added

- Flashable image combining the Armbian ROCK 5B boot chain, Linux kernel, modules, and firmware with a freshly built VyOS ARM64 root filesystem.
- Deterministic Ethernet interface naming as `eth0` through `net.ifnames=0`.
- Automatic first-boot wired WAN setup:
  - dynamic `hw-id` binding of `eth0` to the board's actual MAC address;
  - DHCP on `eth0` with default-route distance `1`;
  - SSH enabled;
  - verification that an IPv4 address is retained and SSH is listening.
- Two-stage first-boot design:
  - a `vyos`-user configuration phase applies `configure`, `commit`, and `save`;
  - a separate root-owned systemd phase starts and verifies the persistent DHCP client after the configuration session has finished.
- Retry-capable `rock5b-dhcp-wan-firstboot.timer`, starting 60 seconds after boot and retrying every 30 seconds until setup succeeds.
- Automatic disabling of the first-boot timer after successful Ethernet and SSH setup.
- Required `vyos` user shell initialization files (`.bashrc`, `.profile`, and `.bash_logout`) for proper interactive VyOS CLI sessions.
- Optional wireless access point helper (`ap-dhcp-wan-setup.sh`) with automatic AP-capable adapter detection, DHCP server configuration, DNS forwarding, Ethernet WAN support, and NAT.
- Optional cellular modem helper (`modem-connect.sh`) supporting PCIe and USB modems through ModemManager using QMI or MBIM, plus an AT/RNDIS fallback.
- Automatic FCC unlock support for the Fibocom FM350-GL.
- GitHub Actions workflow (`build-vyos-rock5b.yml`) for reproducible native ARM64 builds.
- Release checksum file (`SHA256SUMS`).
- Project documentation covering ready-made images, flashing, first boot, SSH access, helper scripts, supported hardware, and source builds.

### Fixed

- Ethernet no longer remains administratively down after boot.
- The DHCP lease is no longer released immediately after the first-boot configuration session ends.
- The persistent DHCP client is no longer terminated as a child of a temporary configuration service.
- `configure` and `commit` no longer fail because of missing `vyattacfg` group context or missing shell initialization files.
- SSH is no longer terminated by a conflicting manual restart after VyOS has started its own `ssh@default.service` instance.
- `/config/config.boot` no longer silently loses its Ethernet configuration during first boot.
- The first-boot setup no longer depends on a single attempt at a guessed boot stage.
- The first-boot systemd service now exits cleanly without an `Invalid command: [0]` error.

### Security

- Documented the default image credentials and added instructions to change the password immediately after first login.
- Recommended SSH key authentication for ongoing administration.
- Avoided redistributing third-party logo artwork in the repository.

## [armbian-rock5b] - 2026-08-02

Base-layer release; not a flashable VyOS image on its own.

### Added

- Armbian edge kernel 7.1.3 for ROCK 5B (`rockchip64`, `trixie`), used as the boot-chain and kernel source for the main VyOS image build.

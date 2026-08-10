# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [v2026.08.10-rock5b-r2] - 2026-08-10

### Release

- Published a new flashable VyOS rolling image for the Radxa ROCK 5B.
- Image source commit: `16223795` (`Update ROCK 5B networking to modem v5.18 and add WiFi firmware`).
- GitHub Actions build run: `31418029665`.
- VyOS image version: `1.5-rolling-202608101821`.
- Release assets:
  - `vyos-rock5b-fresh.img.xz`
  - `SHA256SUMS`
- Image SHA-256: `02bfe73fb05752c9fed2868215d7ae4eb4b1fc3282a8bcae7cfc85de5ce6ca0d`.
- Build, XZ integrity and generated SHA-256 checksum were verified before release.

### ROCK 5B networking

- Updated `modem-connect.sh` from v5.17 to v5.18.
- Fixed ModemManager static-bearer initialization ordering: bearer IPv4, prefix, MTU and WWAN fallback route are applied before strict bound data-path validation.
- Normalized ModemManager WWAN runtime default routes to metric 200 without replacing the preferred wired default route.
- Added dynamic AP return-traffic firewall binding for the active WWAN interface when the `PHOTOBOOTH-WAN-IN` chain exists.
- Kept RM505Q-AE ghost-bearer, stuck-control-plane and always-connected recovery logic.
- Updated `ap-dhcp-wan-setup.sh` from v8.2 to v8.3 and explicitly bound the VyOS wireless interface to the selected physical PHY.
- Kept the existing Armbian firmware as the ROCK 5B base and added the network firmware supplement after the Armbian/VyOS merge.
- Added a ROCK-specific missing-only network firmware supplement pinned to upstream `linux-firmware` release `20260622`.
- Supplement covers MediaTek Wi-Fi 6/6E/7, Realtek `rtw88`/`rtw89` and Bluetooth/NIC firmware, plus Intel `iwlwifi` and Bluetooth firmware.
- The existing Armbian image remains the kernel, module and boot-chain source; no Armbian image rebuild is required.

### Verified on hardware

- Fresh boot verified on the Radxa ROCK 5B without manually installing additional firmware.
- MediaTek MT7922 PCIe Wi-Fi initialized with `mt7921e`; required MT7922 Wi-Fi and Bluetooth firmware is present in the image.
- `Photobooth` access point verified on `phy0` / `wlan0` at 5 GHz, channel 36, VHT80/802.11ac.
- VyOS `physical-device 'phy0'` binding verified with AP setup v8.3.
- DHCP verified with a real WLAN client receiving an address from `10.3.141.51-10.3.141.250`.
- AP-to-Ethernet NAT and Internet access verified from a WLAN client.
- Quectel RM505Q-AE PCIe/MHI connection verified through ModemManager with `modem-connect.sh` v5.18.
- RM505Q-AE runtime IPv4 configuration and bound `wwan0` data-path validation completed without manual route or address repair.
- WWAN NAT rule 160 and dynamic `PHOTOBOOTH-WAN-IN` firewall forward rule 11 were verified on `wwan0`.
- Ethernet remained preferred with metric 20 while WWAN remained available as fallback with metric 200.
- Physical Ethernet disconnect successfully failed over WLAN-client Internet traffic to the RM505Q-AE/WWAN connection.
- Reconnecting Ethernet automatically restored Ethernet as the preferred default route while keeping WWAN available as fallback.

## [v2026.08.10-rock5b] - 2026-08-10

### Release

- Published a new flashable VyOS rolling image for the Radxa ROCK 5B.
- Image source commit: `5a79b3ef` (`Update ROCK 5B modem handling to v5.17`).
- GitHub Actions build run: `31342781433`.
- Build completed successfully using the rolling VyOS build and the Armbian-based ROCK 5B kernel/boot integration.
- Release assets:
  - `vyos-rock5b-fresh.img.xz`
  - `SHA256SUMS`
- Image SHA-256: `d25698df4d0c045943795608ae3ac6c3e07a89c32b9f3f8d4b10e82889a67f04`.
- This release includes the cellular/WWAN rolling updates from 2026-08-09 and 2026-08-10.

### Cellular highlights

- Fibocom FM350-GL USB/RNDIS boot, health monitoring and staged recovery improvements.
- FM350 USB generation tracking prevents restoration of stale PDP/RNDIS address and gateway state after USB re-enumeration.
- Dynamic FM350 Linux WWAN routes use fallback metric 200.
- Quectel RM505Q-AE PCIe/MHI support through ModemManager was extended with bearer validation, ghost-bearer recovery and stuck-control-plane recovery.
- RM505Q always-connected recovery now correctly treats completed systemd `active (exited)` oneshot services with `MainPID=0` as idle.
- RM505Q regression testing verified automatic Bearer/8 -> Bearer/9 recovery in approximately 6 seconds after an explicit ModemManager disconnect.
- Persistent VyOS WWAN routes use distance 200 and runtime Linux WWAN fallback routes use metric 200.

## [Rolling update 2026-08-10] - 2026-08-10

### Cellular / WWAN

- Updated `modem-connect.sh` from v5.9 to v5.17.
- Unified WWAN fallback priority: persistent VyOS WWAN routes use distance 200 and dynamic Linux WWAN routes use metric 200, while the wired WAN remains preferred.
- Persistent WWAN route validation now checks the configured VyOS distance so stale distance-10 configurations are corrected.
- Added improved RM505Q-AE PCIe/MHI handling through ModemManager, including registration/state recovery and usable-bearer validation.
- Existing ModemManager bearers are reused only when the bearer is usable and its bound WWAN data path is alive.
- Added detection and recovery of ghost/stale bearers where ModemManager reports a connected bearer but the bound data path is dead.
- Ghost-bearer teardown now immediately creates a fresh bearer in the same service invocation, protected by a one-time reconnect re-entry guard.
- Added staged handling for stuck `connecting` / `disconnecting` states and MBIM `Protocol.NotOpened` failures.
- Preserved the dedicated staged FM350 USB/RNDIS recovery path and removed obsolete FM350 recovery artifacts when another modem type is selected.
- Corrected FM350 runtime-repair fallback so Linux WWAN routes use `WWAN_ROUTE_METRIC` rather than the persistent-route distance value.
- Fixed the ModemManager always-connected guard for systemd `Type=oneshot` services with `RemainAfterExit=yes`: `active (exited)` with `MainPID=0` is now treated as completed/idle rather than as an active recovery transaction.

### Validation

- RM505Q-AE fast reconnect regression test passed with `modem-connect.service` and `modem-unlock.service` both deliberately in `active (exited)`, `MainPID=0`.
- An explicit ModemManager disconnect changed Bearer/8 to Bearer/9 and restored the connection in approximately 6 seconds.
- Recovery was triggered by the intended `Always-connected policy`, rather than waiting for the slower data-path fallback.
- The recovered `wwan0` data path passed bound ICMP testing and the final Linux default route used metric 200.
- Persistent VyOS WWAN routing was verified with distance 200.
- `modem-connect.sh` passes `bash -n` syntax validation.

## [Rolling update 2026-08-09] - 2026-08-09

### FM350-GL / WWAN

- Updated `modem-connect.sh` from v5.3 to v5.9.
- Added state-based FM350 USB/RNDIS boot readiness detection.
- Added real data-path validation on `eth1` instead of relying only on interface, IPv4 and route state.
- Added health monitoring for `rndis_host` / `NETDEV WATCHDOG` transmit-queue stalls.
- Added staged FM350 recovery: `rndis_host` rebind first, controlled modem/radio reconnect only if required.
- Prevented stale RNDIS IP/gateway state from being restored after FM350 USB re-enumeration.
- Added automatic detection of FM350 USB device-generation changes.
- Separated persistent VyOS NAT configuration from dynamic FM350 IPv4, gateway and default-route runtime state.
- Prevented redundant VyOS boot-time commits when the persistent WWAN configuration is already active.
- Added VyOS router/bootstrap and configuration-lock awareness.
- Kept cellular fallback routing consistently at metric 200.
- Improved coordination between modem unlock, modem connect, recovery and WAN failover services.
- Verified automatic FM350 startup after reboot with `eth1` online, reachable gateway and working external data path.

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

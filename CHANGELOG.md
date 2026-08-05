# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v2026.08.05-rock5b] - 2026-08-05

Initial public release.

### Added

- Flashable image combining the Armbian ROCK 5B boot chain, Linux kernel, modules, and firmware with a freshly built VyOS ARM64 root filesystem.
- Deterministic Ethernet interface naming as `eth0` through `net.ifnames=0`.
- Automatic first-boot wired WAN setup:
  - dynamic `hw-id` binding of `eth0` to the board's actual MAC address;
  - DHCP on `eth0` with default-route distance `1`;
  - SSH enabled;
  - automatic verification that an IPv4 address is retained and SSH is listening.
- Two-stage first-boot design:
  - a `vyos`-user configuration phase applies `configure`, `commit`, and `save`;
  - a separate root-owned systemd phase starts and verifies the persistent DHCP client after the configuration session has finished.
- Retry-capable `rock5b-dhcp-wan-firstboot.timer`, starting 60 seconds after boot and retrying every 30 seconds until setup succeeds.
- Automatic disabling of the first-boot timer after successful Ethernet and SSH setup.
- Required `vyos` user shell initialization files (`.bashrc`, `.profile`, and `.bash_logout`) for proper interactive VyOS CLI sessions.
- Optional wireless access point helper (`ap-dhcp-wan-setup.sh`) with automatic AP-capable adapter detection, DHCP server configuration, DNS forwarding, Ethernet WAN support, and NAT.
- Optional cellular modem helper (`modem-connect.sh`) supporting PCIe and USB modems through ModemManager using QMI or MBIM, plus an AT/RNDIS fallback.
- Automatic FCC unlock support for the Fibocom FM350-GL.
- GitHub Actions workflow (`build-vyos-rock5b.yml`) for reproducible builds on a native ARM64 runner.
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

## [armbian-rock5b] - 2026-08-02

Base-layer release; not a flashable VyOS image on its own.

### Added

- Armbian edge kernel 7.1.3 for ROCK 5B (`rockchip64`, `trixie`), used as the boot-chain and kernel source for the main VyOS image build.

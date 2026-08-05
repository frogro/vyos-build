# VyOS Rolling for Radxa ROCK 5B v1.0.0

Initial public release of the unofficial VyOS Rolling image for the Radxa ROCK 5B.

## Highlights

- Flashable ARM64 image for the Radxa ROCK 5B
- Armbian ROCK 5B boot chain, kernel, modules, and firmware
- Freshly built VyOS ARM64 userspace and configuration system
- Deterministic Ethernet interface name `eth0`
- Automatic wired DHCP configuration on first boot
- Dynamic binding to the board's actual Ethernet MAC address
- Default-route distance `1`
- SSH enabled automatically
- Persistent DHCP client with retry-capable first-boot service
- HDMI and serial console support
- Optional wireless access point helper
- Optional LTE/5G modem helper
- Fibocom FM350-GL support with automatic FCC unlock
- Reproducible GitHub Actions build workflow

## Default Login

```text
Username: vyos
Password: vyos
```

Change the default password immediately after the first login.

## Release Assets

- `vyos-rock5b-fresh.img.xz`
- `SHA256SUMS`

The compressed image can be flashed directly with balenaEtcher or written from Linux using `xz` and `dd`.

## First Boot

1. Connect Ethernet to a network that provides DHCP.
2. Flash and attach the image.
3. Power on the ROCK 5B.
4. Wait approximately 60–90 seconds.
5. Find the assigned address in your router or DHCP server.
6. Connect with:

```bash
ssh vyos@DEVICE_IP
```

## Important Notes

- This is a VyOS rolling image and may contain regressions.
- Test carefully before production use.
- Wireless AP and modem setup are optional and are not enabled automatically.
- This is an independent community build and is not produced, supported, sponsored, or endorsed by VyOS, Sentrium S.L., Radxa, or Radxa Computer Co., Ltd.

## Documentation

- [README](https://github.com/frogro/vyos-build/blob/rolling/README.md)
- [Full changelog](https://github.com/frogro/vyos-build/blob/rolling/CHANGELOG.md)

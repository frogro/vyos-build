## VyOS Rolling for Radxa ROCK 5B

Initial public release of this unofficial community image for the Radxa ROCK 5B.

### Highlights

- Flashable ARM64 image using the Armbian ROCK 5B boot chain
- Freshly built VyOS ARM64 userspace
- Automatic Ethernet DHCP setup on first boot
- Dynamic MAC-based binding of `eth0`
- Default-route distance `1`
- SSH enabled automatically
- Persistent DHCP client with retry-capable first-boot service
- HDMI and serial console
- Optional wireless AP helper
- Optional LTE/5G modem helper
- Fibocom FM350-GL FCC unlock support

### Default login

```text
Username: vyos
Password: vyos
```

Change the default password immediately after the first login.

### Release assets

- `vyos-rock5b-fresh.img.xz`
- `SHA256SUMS`

The compressed image can be flashed directly with balenaEtcher or written from Linux with `xz` and `dd`.

### Documentation

See the repository [README](https://github.com/frogro/vyos-build/blob/rolling/README.md) for flashing, first-boot, SSH, access-point, modem, and source-build instructions.

See the complete [CHANGELOG](https://github.com/frogro/vyos-build/blob/rolling/CHANGELOG.md) for technical details.

> This is an independent community build. It is not produced, supported, sponsored, or endorsed by VyOS, Sentrium S.L., Radxa, or Radxa Computer Co., Ltd.

# Armbian ROCK 5B Edge Kernel Base - DWC3/USB3 Host Fix

This release contains the Armbian ROCK 5B base image used by the VyOS ROCK 5B build workflow.
It is a build dependency and is not a complete VyOS image.

## Base image

- ROCK 5B / rockchip64
- Debian trixie userspace
- Armbian edge kernel `7.1.7-edge-rockchip64`

## DWC3 / USB3 fix

- Enables the ROCK 5B DWC3 controllers in host-capable dual-role configuration instead of forcing the affected controllers into gadget-only mode.
- Restores xHCI host controllers and USB 3.0 SuperSpeed operation on the ROCK 5B USB3 path.
- Verified on the ROCK 5B with xHCI buses reporting `5000M` and a Fibocom FM350-GL RNDIS modem enumerating at SuperSpeed.

## Integrity

The release includes `SHA256SUMS`. Verify the downloaded image with:

```bash
sha256sum -c SHA256SUMS
```

# Armbian ROCK 5B Base Layer

Base-layer release used by the main VyOS ROCK 5B image build.

> This is not a complete or directly flashable VyOS image on its own.

## Included

- Armbian ROCK 5B boot chain
- TF-A and U-Boot components
- ROCK 5B device tree
- Armbian edge kernel 7.1.3
- Kernel modules and firmware
- `rockchip64` / `trixie` base components used by the merge workflow

## Purpose

This release provides the board-specific boot and kernel layer that the GitHub Actions workflow combines with a freshly built VyOS ARM64 root filesystem.

For a ready-to-use system, download the latest main ROCK 5B release instead:

- [VyOS ROCK 5B releases](https://github.com/frogro/vyos-build/releases)

## Important Notes

- Not intended for direct end-user installation
- Not a complete VyOS image
- Intended as a build dependency and reproducibility asset
- Independent community work; no official endorsement is claimed

# Install this package into the repository

Run from the ThinkPad:

```bash
cd /mnt/datenplatte/vyos-build-arm64/vyos-build
cp -a ~/Downloads/vyos-rock5b-github-package/. .
git status --short
git diff -- README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md TRADEMARKS.md RELEASE-NOTES-v2026.08.05-rock5b.md
git add README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md TRADEMARKS.md RELEASE-NOTES-v2026.08.05-rock5b.md docs/images/rock5b-banner.png .github
git commit -m "Prepare professional ROCK 5B project documentation and release metadata"
git push fork rolling
```

Create the release checksum:

```bash
cd ~/Downloads/vyos-rock5b-31027611824/vyos-rock5b-image
sha256sum vyos-rock5b-fresh.img.xz > SHA256SUMS
```

Create the GitHub release:

```bash
gh release create v2026.08.05-rock5b vyos-rock5b-fresh.img.xz SHA256SUMS --repo frogro/vyos-build --target rolling --title "VyOS Rolling for ROCK 5B - 2026-08-05" --notes-file /mnt/datenplatte/vyos-build-arm64/vyos-build/RELEASE-NOTES-v2026.08.05-rock5b.md
```

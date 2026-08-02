#!/bin/bash
set -euo pipefail

# Merge Armbian (Rock 5B, edge kernel) modules/firmware/boot-chain
# in ein frisch gebautes VyOS-Rootfs (aus vyos/vyos-build, generic-arm64).
#
# Voraussetzungen: xz-utils, parted, rsync, util-linux
#
# Aufruf:
#   sudo ./merge-vyos-rock5b.sh \
#       'Armbian_..._Rock-5b_..._minimal.img.xz' \
#       vyos-rootfs-arm64-fresh.tar.gz \
#       output-dir

ARMBIAN_XZ="${1:?Armbian .img.xz fehlt}"
VYOS_TAR="${2:?VyOS-Rootfs-Tar fehlt}"
OUTDIR="${3:?Output-Verzeichnis fehlt}"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausführen." >&2
    exit 1
fi

WORK="$(mktemp -d)"
ARMBIAN_IMG="${WORK}/armbian.img"
ARMBIAN_MNT="${WORK}/armbian-root"
VYOS_ROOT="${WORK}/vyos-root"
LOOPDEV=""

cleanup() {
    set +e
    mountpoint -q "${ARMBIAN_MNT}" && umount "${ARMBIAN_MNT}"
    [[ -n "${LOOPDEV}" ]] && losetup -d "${LOOPDEV}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "==> Armbian-Image entpacken (das dauert etwas)"
xz -dk -c "${ARMBIAN_XZ}" > "${ARMBIAN_IMG}"

echo "==> Armbian-Image mounten"
LOOPDEV="$(losetup -f)"
losetup -P "${LOOPDEV}" "${ARMBIAN_IMG}"
partprobe "${LOOPDEV}" 2>/dev/null || true
sleep 1

ROOTPART="$(lsblk -ln -o NAME,FSTYPE "${LOOPDEV}" | awk '$2=="ext4"{print $1}' | tail -1)"
if [[ -z "${ROOTPART}" ]]; then
    echo "Konnte Rootfs-Partition nicht automatisch finden. lsblk-Ausgabe:" >&2
    lsblk "${LOOPDEV}"
    exit 1
fi

mkdir -p "${ARMBIAN_MNT}"
mount "/dev/${ROOTPART}" "${ARMBIAN_MNT}"

KVER="$(basename "$(find "${ARMBIAN_MNT}/usr/lib/modules" -maxdepth 1 -mindepth 1 -type d | head -1)")"
if [[ -z "${KVER}" ]]; then
    echo "Konnte Armbian-Kernelversion nicht ermitteln. Inhalt von /usr/lib/modules:" >&2
    ls "${ARMBIAN_MNT}/usr/lib/modules" || true
    exit 1
fi
echo "==> Gefundene Armbian-Kernelversion: ${KVER}"

echo "==> VyOS-Rootfs entpacken"
mkdir -p "${VYOS_ROOT}"
tar xzf "${VYOS_TAR}" -C "${VYOS_ROOT}"

echo "==> Vorhandene VyOS-eigene Kernelmodul-Verzeichnisse dynamisch entfernen"
# Statt einer hartcodierten Versionsnummer: alles unter usr/lib/modules und
# lib/modules entfernen, das NICHT der Armbian-Kernelversion entspricht.
# Das macht das Skript unabhaengig davon, welche VyOS-Kernelversion das
# jeweils aktuelle Rolling-Release gerade mitbringt.
for MODDIR in "${VYOS_ROOT}/usr/lib/modules" "${VYOS_ROOT}/lib/modules"; do
    [[ -d "${MODDIR}" ]] || continue
    find "${MODDIR}" -mindepth 1 -maxdepth 1 -type d ! -name "${KVER}" -print -exec rm -rf {} + \
        | sed 's/^/    entferne: /'
done

echo "==> Armbian-Module kopieren"
mkdir -p "${VYOS_ROOT}/usr/lib/modules"
rsync -a "${ARMBIAN_MNT}/usr/lib/modules/${KVER}" "${VYOS_ROOT}/usr/lib/modules/"

echo "==> Armbian-Firmware übernehmen (VyOS-Firmware komplett ersetzen, keine Merge-Konflikte)"
rm -rf "${VYOS_ROOT}/usr/lib/firmware"
mkdir -p "${VYOS_ROOT}/usr/lib/firmware"
rsync -a "${ARMBIAN_MNT}/usr/lib/firmware/" "${VYOS_ROOT}/usr/lib/firmware/"

echo "==> Armbian /boot übernehmen (extlinux.conf, Kernel-Image, initrd, DTBs)"
echo "    -> U-Boot bootet per distro_boot/extlinux von hier, MUSS von Armbian sein"
rm -rf "${VYOS_ROOT}/boot"
mkdir -p "${VYOS_ROOT}/boot"
rsync -a "${ARMBIAN_MNT}/boot/" "${VYOS_ROOT}/boot/"

mkdir -p "${OUTDIR}/boot-chain"
rsync -a "${ARMBIAN_MNT}/boot/" "${OUTDIR}/boot-chain/"

echo "==> persistence.conf (VyOS-Live-Mechanik, hier nicht gebraucht) entfernen"
rm -f "${VYOS_ROOT}/persistence.conf" 2>/dev/null || true

echo "==> fertiges Rootfs packen"
mkdir -p "${OUTDIR}"
tar czf "${OUTDIR}/vyos-rootfs-rock5b-merged.tar.gz" -C "${VYOS_ROOT}" .

echo ""
echo "==> Fertig."
echo "    Merged Rootfs:  ${OUTDIR}/vyos-rootfs-rock5b-merged.tar.gz"
echo "    Boot-Dateien:   ${OUTDIR}/boot-chain/"

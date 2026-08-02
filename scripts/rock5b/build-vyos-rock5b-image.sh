#!/bin/bash
set -euo pipefail

ARMBIAN_XZ="${1:?Armbian .img.xz fehlt}"
MERGED_TAR="${2:?merged VyOS-Rootfs-Tar fehlt (aus merge-vyos-rock5b.sh)}"
OUT_IMG="${3:?Ziel-Image-Pfad fehlt}"
EXTRA_GB="${EXTRA_GB:-4}"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausführen." >&2
    exit 1
fi

WORK="$(mktemp -d)"
IMG="${WORK}/rock5b.img"
MNT="${WORK}/rootfs-mnt"
LOOPDEV=""

cleanup() {
    set +e
    mountpoint -q "${MNT}" && umount "${MNT}"
    [[ -n "${LOOPDEV}" ]] && losetup -d "${LOOPDEV}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "==> Armbian-Image entpacken"
xz -dk -c "${ARMBIAN_XZ}" > "${IMG}"

echo "==> Image um ${EXTRA_GB}G vergrößern (Platz für VyOS-Rootfs)"
truncate -s "+${EXTRA_GB}G" "${IMG}"

echo "==> Partitionstabelle einlesen"
LOOPDEV="$(losetup -f)"
losetup -P "${LOOPDEV}" "${IMG}"
partprobe "${LOOPDEV}" 2>/dev/null || true
sleep 1

echo "==> GPT-Backup-Header ans neue Ende der Disk verschieben"
sgdisk -e "${LOOPDEV}"
losetup -d "${LOOPDEV}"
LOOPDEV="$(losetup -f)"
losetup -P "${LOOPDEV}" "${IMG}"
partprobe "${LOOPDEV}" 2>/dev/null || true
sleep 1

parted -s "${LOOPDEV}" print

LASTPART_NUM="$(parted -s "${LOOPDEV}" print | awk '/^ *[0-9]+/{n=$1} END{print n}')"
echo "==> Rootfs-Partition (Nummer ${LASTPART_NUM}) auf volle Imagegröße ausdehnen"
parted -s "${LOOPDEV}" resizepart "${LASTPART_NUM}" 100%

losetup -d "${LOOPDEV}"
LOOPDEV="$(losetup -f)"
losetup -P "${LOOPDEV}" "${IMG}"
partprobe "${LOOPDEV}" 2>/dev/null || true
sleep 1

ROOTPART="${LOOPDEV}p${LASTPART_NUM}"
echo "==> Dateisystemcheck + Vergrößerung ${ROOTPART}"
e2fsck -f -y "${ROOTPART}" || true
resize2fs "${ROOTPART}"

echo "==> Rootfs-Partition mounten"
mkdir -p "${MNT}"
mount "${ROOTPART}" "${MNT}"

echo "==> Alten Armbian-Rootfs-Inhalt löschen"
find "${MNT}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "==> VyOS-Rootfs (gemerged) einspielen"
tar xzf "${MERGED_TAR}" -C "${MNT}"

sync
umount "${MNT}"
losetup -d "${LOOPDEV}"
LOOPDEV=""

echo "==> fertiges Image verschieben nach ${OUT_IMG}"
mkdir -p "$(dirname "${OUT_IMG}")"
mv "${IMG}" "${OUT_IMG}"

echo "==> Fertig: ${OUT_IMG}"

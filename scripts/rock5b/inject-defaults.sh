#!/bin/bash
set -euo pipefail

# Spielt Standard-config.boot, armbianEnv.txt-Anpassungen und die
# Erst-Boot-Skripte (AP/Locales) in ein bereits gemergtes VyOS-Rootfs ein.
#
# Aufruf:
#   sudo ./inject-defaults.sh <merged-rootfs-dir> <script-dir>
#
# <merged-rootfs-dir>: entpacktes, gemergtes Rootfs (VOR dem erneuten tar czf)
# <script-dir>: dieses scripts/rock5b/first-boot/ Verzeichnis

MERGED_ROOT="${1:?Pfad zum entpackten, gemergten Rootfs fehlt}"
SCRIPT_DIR="${2:?Pfad zu first-boot/ fehlt}"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo ausführen." >&2
    exit 1
fi

echo "==> Standard-config.boot einspielen"
mkdir -p "${MERGED_ROOT}/config"
cp "${SCRIPT_DIR}/config.boot.default" "${MERGED_ROOT}/config/config.boot"

echo "==> armbianEnv.txt anpassen (net.ifnames=0 + Bluetooth-Blacklist)"
ENV_FILE="${MERGED_ROOT}/boot/armbianEnv.txt"
if [[ -f "${ENV_FILE}" ]]; then
    if grep -q '^extraargs=' "${ENV_FILE}"; then
        sed -i 's/^extraargs=.*/extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0/' "${ENV_FILE}"
    else
        echo 'extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0' >> "${ENV_FILE}"
    fi
else
    echo "WARNUNG: ${ENV_FILE} nicht gefunden, überspringe." >&2
fi

echo "==> Erst-Boot-Skripte (AP, Locales) ins Home-Verzeichnis von 'vyos' kopieren"
mkdir -p "${MERGED_ROOT}/home/vyos"
cp "${SCRIPT_DIR}/ap-dhcp-wan-setup.sh" "${MERGED_ROOT}/home/vyos/"
cp "${SCRIPT_DIR}/set-locales.sh" "${MERGED_ROOT}/home/vyos/"
[[ -f "${SCRIPT_DIR}/modem-connect.sh" ]] && cp "${SCRIPT_DIR}/modem-connect.sh" "${MERGED_ROOT}/home/vyos/"
chmod +x "${MERGED_ROOT}/home/vyos/ap-dhcp-wan-setup.sh" "${MERGED_ROOT}/home/vyos/set-locales.sh"
[[ -f "${MERGED_ROOT}/home/vyos/modem-connect.sh" ]] && chmod +x "${MERGED_ROOT}/home/vyos/modem-connect.sh"

echo "==> Fertig. Standard-Login: vyos / vyos (bitte nach erstem Login aendern)"

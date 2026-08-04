#!/bin/bash
set -euo pipefail

# Spielt Standard-config.boot, armbianEnv.txt-Anpassungen, die
# Erst-Boot-Skripte (AP/Locales/Modem), die noetigen Home-Dotfiles
# (fuer eine funktionierende interaktive VyOS-CLI) sowie einen
# systemd-Dienst, der eth0 zuverlaessig hochfaehrt, in ein bereits
# gemergtes VyOS-Rootfs ein.
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

echo "==> Erst-Boot-Skripte (AP, Locales, Modem) ins Home-Verzeichnis von 'vyos' kopieren"
mkdir -p "${MERGED_ROOT}/home/vyos"
cp "${SCRIPT_DIR}/ap-dhcp-wan-setup.sh" "${MERGED_ROOT}/home/vyos/"
cp "${SCRIPT_DIR}/set-locales.sh" "${MERGED_ROOT}/home/vyos/"
[[ -f "${SCRIPT_DIR}/modem-connect.sh" ]] && cp "${SCRIPT_DIR}/modem-connect.sh" "${MERGED_ROOT}/home/vyos/"
chmod +x "${MERGED_ROOT}/home/vyos/ap-dhcp-wan-setup.sh" "${MERGED_ROOT}/home/vyos/set-locales.sh"
[[ -f "${MERGED_ROOT}/home/vyos/modem-connect.sh" ]] && chmod +x "${MERGED_ROOT}/home/vyos/modem-connect.sh"

echo "==> Home-Dotfiles (.bashrc, .profile, .bash_logout) einspielen"
echo "    -> Ohne diese startet die interaktive VyOS-CLI (configure/commit/...) nicht korrekt,"
echo "       da unser gemergtes Rootfs nie durch den offiziellen VyOS-ISO-Installer lief."
if [[ -d "${SCRIPT_DIR}/home-dotfiles" ]]; then
    cp "${SCRIPT_DIR}/home-dotfiles/.bashrc" "${MERGED_ROOT}/home/vyos/.bashrc"
    cp "${SCRIPT_DIR}/home-dotfiles/.profile" "${MERGED_ROOT}/home/vyos/.profile"
    cp "${SCRIPT_DIR}/home-dotfiles/.bash_logout" "${MERGED_ROOT}/home/vyos/.bash_logout"
    # .bash_profile/.bash_login wuerden .profile fuer Login-Shells verdraengen - sicherstellen, dass sie fehlen
    rm -f "${MERGED_ROOT}/home/vyos/.bash_profile" "${MERGED_ROOT}/home/vyos/.bash_login"
else
    echo "WARNUNG: ${SCRIPT_DIR}/home-dotfiles nicht gefunden, Dotfiles NICHT eingespielt!" >&2
fi

echo "==> Eigentuemer der Home-Verzeichnis-Dateien auf vyos:users setzen"
chown -R 1000:100 "${MERGED_ROOT}/home/vyos" 2>/dev/null || chown -R vyos:users "${MERGED_ROOT}/home/vyos" 2>/dev/null || true

echo "==> systemd-Dienst anlegen: eth0 zuverlaessig bei jedem Boot hochfahren"
echo "    -> Workaround, da VyOS/dieses Image eth0 trotz 'address dhcp' nicht"
echo "       automatisch administrativ hochfaehrt."
mkdir -p "${MERGED_ROOT}/etc/systemd/system"
cat > "${MERGED_ROOT}/etc/systemd/system/eth0-force-up.service" << 'UNIT'
[Unit]
Description=Force eth0 up (Workaround fuer VyOS/Rock5B Boot-Bug)
After=vyos-router.service
Wants=vyos-router.service

[Service]
Type=oneshot
ExecStart=/sbin/ip link set eth0 up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
echo "==> Eigenen systemd-Dienst fuer dynamische eth0-hw-id-Bindung anlegen"
echo "    -> VyOS' eigener vyos-postconfig-bootup.script-Hook greift in unserem"
echo "       gemergten Setup nicht zuverlaessig, daher eigener systemd-Dienst"
echo "       nach dem bewaehrten eth0-force-up.service-Muster."
mkdir -p "${MERGED_ROOT}/usr/local/sbin"
cp "${SCRIPT_DIR}/rock5b-eth0-firstboot.sh" "${MERGED_ROOT}/usr/local/sbin/rock5b-eth0-firstboot.sh"
chmod +x "${MERGED_ROOT}/usr/local/sbin/rock5b-eth0-firstboot.sh"

cat > "${MERGED_ROOT}/etc/systemd/system/rock5b-eth0-firstboot.service" << 'UNIT2'
[Unit]
Description=Rock5B eth0 hw-id dynamisch beim ersten Boot binden
After=vyos-router.service eth0-force-up.service
Wants=vyos-router.service

[Service]
Type=oneshot
Environment=HOME=/root
Environment=USER=root
Environment=LOGNAME=root
Environment=TERM=linux
ExecStart=/usr/local/sbin/rock5b-eth0-firstboot.sh
RemainAfterExit=yes
TimeoutStartSec=120
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT2

mkdir -p "${MERGED_ROOT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/rock5b-eth0-firstboot.service \
    "${MERGED_ROOT}/etc/systemd/system/multi-user.target.wants/rock5b-eth0-firstboot.service"

mkdir -p "${MERGED_ROOT}/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/eth0-force-up.service \
    "${MERGED_ROOT}/etc/systemd/system/multi-user.target.wants/eth0-force-up.service"

echo "==> persistence.conf (VyOS-Live-Mechanik, hier nicht gebraucht) entfernen"
rm -f "${MERGED_ROOT}/persistence.conf" 2>/dev/null || true

echo "==> Fertig."

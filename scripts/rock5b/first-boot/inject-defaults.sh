#!/bin/bash
set -euo pipefail

# Injiziert die Rock5B-First-Boot-Grundkonfiguration in ein bereits
# gemergtes VyOS-Rootfs.
#
# Aufruf:
#   sudo ./inject-defaults.sh <merged-rootfs-dir> <first-boot-script-dir>

MERGED_ROOT="${1:?Pfad zum gemergten Rootfs fehlt}"
SCRIPT_DIR="${2:?Pfad zum first-boot-Verzeichnis fehlt}"

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }
[[ -d "$MERGED_ROOT" ]] || { echo "Rootfs nicht gefunden: $MERGED_ROOT" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/config.boot.default" ]] || { echo "config.boot.default fehlt." >&2; exit 1; }
[[ -f "$SCRIPT_DIR/rock5b-eth0-firstboot.sh" ]] || { echo "rock5b-eth0-firstboot.sh fehlt." >&2; exit 1; }

echo "==> config.boot.default einspielen"
mkdir -p "$MERGED_ROOT/config"
if [[ -f "$MERGED_ROOT/config/config.boot" ]]; then
    cp -a "$MERGED_ROOT/config/config.boot" "$MERGED_ROOT/config/config.boot.before-inject"
fi
install -m 0644 "$SCRIPT_DIR/config.boot.default" "$MERGED_ROOT/config/config.boot"

echo "==> armbianEnv.txt: net.ifnames=0 setzen"
ENV_FILE="$MERGED_ROOT/boot/armbianEnv.txt"
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^extraargs=' "$ENV_FILE"; then
        sed -i 's/^extraargs=.*/extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0/' "$ENV_FILE"
    else
        printf '%s\n' 'extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0' >> "$ENV_FILE"
    fi
else
    echo "WARNUNG: $ENV_FILE fehlt." >&2
fi

echo "==> Benutzer-Skripte und Dotfiles kopieren"
mkdir -p "$MERGED_ROOT/home/vyos"
for f in ap-dhcp-wan-setup.sh set-locales.sh modem-connect.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] || continue
    install -m 0755 "$SCRIPT_DIR/$f" "$MERGED_ROOT/home/vyos/$f"
done

if [[ -d "$SCRIPT_DIR/home-dotfiles" ]]; then
    for f in .bashrc .profile .bash_logout; do
        [[ -f "$SCRIPT_DIR/home-dotfiles/$f" ]] || continue
        install -m 0644 "$SCRIPT_DIR/home-dotfiles/$f" "$MERGED_ROOT/home/vyos/$f"
    done
    rm -f "$MERGED_ROOT/home/vyos/.bash_profile" "$MERGED_ROOT/home/vyos/.bash_login"
fi

# Eigentümer vom vorhandenen Home-Verzeichnis übernehmen, statt feste UID/GID anzunehmen.
for f in ap-dhcp-wan-setup.sh set-locales.sh modem-connect.sh .bashrc .profile .bash_logout; do
    [[ -e "$MERGED_ROOT/home/vyos/$f" ]] || continue
    chown --reference="$MERGED_ROOT/home/vyos" "$MERGED_ROOT/home/vyos/$f"
done

echo "==> First-Boot-Skript installieren"
install -D -m 0755 "$SCRIPT_DIR/rock5b-eth0-firstboot.sh" \
    "$MERGED_ROOT/usr/local/sbin/rock5b-eth0-firstboot.sh"

echo "==> eth0-force-up.service installieren"
install -d "$MERGED_ROOT/etc/systemd/system"
cat > "$MERGED_ROOT/etc/systemd/system/eth0-force-up.service" <<'UNIT'
[Unit]
Description=Rock5B eth0 vor VyOS-First-Boot-Konfiguration hochsetzen
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=/sys/class/net/eth0

[Service]
Type=oneshot
ExecStart=/sbin/ip link set eth0 up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

echo "==> rock5b-eth0-firstboot.service installieren"
cat > "$MERGED_ROOT/etc/systemd/system/rock5b-eth0-firstboot.service" <<'UNIT'
[Unit]
Description=Rock5B eth0, DHCP und SSH beim ersten Boot einrichten
After=vyos-router.service eth0-force-up.service
Wants=vyos-router.service eth0-force-up.service
ConditionPathExists=!/config/.rock5b-eth0-firstboot-done

[Service]
Type=oneshot
Environment=HOME=/root
Environment=USER=root
Environment=LOGNAME=root
Environment=TERM=linux
ExecStartPre=/bin/sleep 20
ExecStart=/usr/local/sbin/rock5b-eth0-firstboot.sh
TimeoutStartSec=240
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Dienste für den ersten Boot aktivieren"
install -d "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/eth0-force-up.service \
    "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/eth0-force-up.service"
ln -sfn /etc/systemd/system/rock5b-eth0-firstboot.service \
    "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/rock5b-eth0-firstboot.service"

echo "==> Alte Marker und unpassende Live-Konfiguration entfernen"
rm -f "$MERGED_ROOT/config/.rock5b-eth0-firstboot-done"
rm -f "$MERGED_ROOT/persistence.conf" 2>/dev/null || true

echo "==> Fertig: eth0/DHCP/SSH-First-Boot-Mechanik injiziert"

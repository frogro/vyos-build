#!/bin/bash
set -euo pipefail

# Aufruf:
# sudo ./inject-defaults.sh <merged-rootfs-dir> <first-boot-script-dir>

MERGED_ROOT="${1:?Pfad zum gemergten Rootfs fehlt}"
SCRIPT_DIR="${2:?Pfad zum first-boot-Verzeichnis fehlt}"

[[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen." >&2; exit 1; }
[[ -d "$MERGED_ROOT" ]] || { echo "Rootfs fehlt: $MERGED_ROOT" >&2; exit 1; }

for REQUIRED in config.boot.default rock5b-eth0-firstboot.sh vyos-postconfig-bootup.script; do
    [[ -f "$SCRIPT_DIR/$REQUIRED" ]] || {
        echo "Pflichtdatei fehlt: $SCRIPT_DIR/$REQUIRED" >&2
        exit 1
    }
done

echo "==> config.boot.default installieren"
install -d "$MERGED_ROOT/config"
if [[ -f "$MERGED_ROOT/config/config.boot" ]]; then
    cp -a "$MERGED_ROOT/config/config.boot" \
        "$MERGED_ROOT/config/config.boot.before-inject"
fi
install -m 0644 "$SCRIPT_DIR/config.boot.default" \
    "$MERGED_ROOT/config/config.boot"

echo "==> net.ifnames=0 setzen"
ENV_FILE="$MERGED_ROOT/boot/armbianEnv.txt"
if [[ -f "$ENV_FILE" ]]; then
    if grep -q '^extraargs=' "$ENV_FILE"; then
        sed -i \
          's/^extraargs=.*/extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0/' \
          "$ENV_FILE"
    else
        printf '%s\n' \
          'extraargs=cma=256M modprobe.blacklist=btusb,btmtk net.ifnames=0' \
          >> "$ENV_FILE"
    fi
else
    echo "WARNUNG: $ENV_FILE fehlt." >&2
fi

echo "==> Hilfsskripte kopieren"
install -d "$MERGED_ROOT/home/vyos"
for F in ap-dhcp-wan-setup.sh set-locales.sh modem-connect.sh; do
    [[ -f "$SCRIPT_DIR/$F" ]] || continue
    install -m 0755 "$SCRIPT_DIR/$F" "$MERGED_ROOT/home/vyos/$F"
done

if [[ -d "$SCRIPT_DIR/home-dotfiles" ]]; then
    for F in .bashrc .profile .bash_logout; do
        [[ -f "$SCRIPT_DIR/home-dotfiles/$F" ]] || continue
        install -m 0644 "$SCRIPT_DIR/home-dotfiles/$F" \
            "$MERGED_ROOT/home/vyos/$F"
    done
    rm -f "$MERGED_ROOT/home/vyos/.bash_profile" \
          "$MERGED_ROOT/home/vyos/.bash_login"
fi

for F in ap-dhcp-wan-setup.sh set-locales.sh modem-connect.sh \
         .bashrc .profile .bash_logout; do
    [[ -e "$MERGED_ROOT/home/vyos/$F" ]] || continue
    chown --reference="$MERGED_ROOT/home/vyos" \
        "$MERGED_ROOT/home/vyos/$F"
done

echo "==> Alte systemd-First-Boot-Lösung vollständig entfernen"
rm -f "$MERGED_ROOT/etc/systemd/system/rock5b-eth0-firstboot.service"
rm -f "$MERGED_ROOT/etc/systemd/system/eth0-force-up.service"
rm -f "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/rock5b-eth0-firstboot.service"
rm -f "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/eth0-force-up.service"
rm -f "$MERGED_ROOT/config/.rock5b-eth0-firstboot-done"

echo "==> Worker installieren"
install -D -m 0755 "$SCRIPT_DIR/rock5b-eth0-firstboot.sh" \
    "$MERGED_ROOT/usr/local/sbin/rock5b-eth0-firstboot.sh"

echo "==> offiziellen VyOS-Postconfig-Hook installieren"
install -D -m 0775 "$SCRIPT_DIR/vyos-postconfig-bootup.script" \
    "$MERGED_ROOT/config/scripts/vyos-postconfig-bootup.script"

# vyattacfg-GID aus dem Ziel-Rootfs ermitteln.
VYATTACFG_GID="$(awk -F: '$1=="vyattacfg" {print $3; exit}' \
    "$MERGED_ROOT/etc/group" 2>/dev/null || true)"

if [[ -n "$VYATTACFG_GID" ]]; then
    chown 0:"$VYATTACFG_GID" \
        "$MERGED_ROOT/config/scripts/vyos-postconfig-bootup.script"
else
    echo "WARNUNG: Gruppe vyattacfg im Ziel-Rootfs nicht gefunden." >&2
    chown root:root \
        "$MERGED_ROOT/config/scripts/vyos-postconfig-bootup.script"
fi

chown root:root "$MERGED_ROOT/usr/local/sbin/rock5b-eth0-firstboot.sh"

rm -f "$MERGED_ROOT/persistence.conf" 2>/dev/null || true

echo "==> Fertig: Postconfig-First-Boot für eth0/DHCP/SSH installiert"

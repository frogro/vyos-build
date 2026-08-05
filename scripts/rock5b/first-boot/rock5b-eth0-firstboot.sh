#!/bin/vbash
# Rock 5B: eth0 per DHCP und SSH einmalig nach vollständig angewendeter
# VyOS-Bootkonfiguration einrichten.
#
# Aufruf erfolgt durch:
# /config/scripts/vyos-postconfig-bootup.script

set -o pipefail

MARKER="/config/.rock5b-eth0-firstboot-done"
LOG="/config/rock5b-eth0-firstboot.log"
IFACE="${IFACE:-eth0}"

log() {
    printf '%s %s\n' "$(date -Is)" "rock5b-eth0-firstboot: $*" | tee -a "$LOG"
}

fail() {
    log "FEHLER: $*"
    exit 1
}

[ -e "$MARKER" ] && exit 0

# VyOS-Konfigurationsbefehle benötigen die Gruppe vyattacfg.
if [ "$(id -gn)" != "vyattacfg" ]; then
    exec sg vyattacfg -c "/bin/vbash $(readlink -f "$0")"
fi

log "Start nach VyOS-Postconfig"

MAC=""
for _ in $(seq 1 60); do
    if [ -r "/sys/class/net/${IFACE}/address" ]; then
        MAC="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/${IFACE}/address")"
        if printf '%s\n' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
           && [ "$MAC" != "00:00:00:00:00:00" ]; then
            break
        fi
    fi
    sleep 1
done

printf '%s\n' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
    || fail "Keine gültige MAC-Adresse für ${IFACE}"
log "Erkannt: ${IFACE}, MAC ${MAC}"

sudo /sbin/ip link set "$IFACE" up 2>/dev/null || true

[ -r /opt/vyatta/etc/functions/script-template ] \
    || fail "VyOS script-template fehlt"

if ! (
    source /opt/vyatta/etc/functions/script-template
    configure

    set interfaces ethernet "$IFACE" hw-id "$MAC"
    set interfaces ethernet "$IFACE" description 'WAN-LAN-DHCP'
    set interfaces ethernet "$IFACE" address 'dhcp'
    set interfaces ethernet "$IFACE" dhcp-options default-route-distance '1'
    set service ssh

    if ! commit; then
        discard
        exit 1
    fi

    if ! save; then
        discard
        exit 1
    fi
); then
    fail "VyOS commit/save fehlgeschlagen"
fi

log "Konfiguration gespeichert"

IP_OK=0
for _ in $(seq 1 60); do
    if ip -4 -br address show dev "$IFACE" 2>/dev/null \
        | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'; then
        IP_OK=1
        break
    fi
    sleep 2
done

[ "$IP_OK" -eq 1 ] || fail "${IFACE} erhielt keine IPv4-Adresse"
IPV4="$(ip -4 -br address show dev "$IFACE" | awk '{print $3; exit}')"

# Commit sollte SSH starten. Nur wenn Port 22 noch nicht lauscht,
# vorhandene Unit starten, niemals neu starten.
if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$'; then
    for UNIT in ssh@default.service ssh.service sshd.service; do
        if systemctl cat "$UNIT" >/dev/null 2>&1; then
            sudo systemctl start "$UNIT" 2>>"$LOG" || true
            break
        fi
    done
fi

SSH_OK=0
for _ in $(seq 1 30); do
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$'; then
        SSH_OK=1
        break
    fi
    sleep 1
done

[ "$SSH_OK" -eq 1 ] || fail "SSH lauscht nicht auf TCP-Port 22"

touch "$MARKER"
chmod 600 "$MARKER"
log "FERTIG: ${IFACE}=${IPV4}, SSH Port 22 aktiv"
exit 0

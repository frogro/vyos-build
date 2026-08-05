#!/bin/vbash
# Rock 5B: eth0 + DHCP + SSH beim ersten Boot zuverlässig einrichten.
# Wird durch rock5b-eth0-firstboot.service gestartet.

set -o pipefail

MARKER="/config/.rock5b-eth0-firstboot-done"
LOG="/config/rock5b-eth0-firstboot.log"
IFACE="eth0"
WAIT_IFACE=60
WAIT_RUNTIME=90
WAIT_NETWORK=60

log() {
    printf '%s %s\n' "$(date -Is)" "rock5b-eth0-firstboot: $*" | tee -a "$LOG"
}

fail() {
    log "FEHLER: $*"
    exit 1
}

[ -e "$MARKER" ] && exit 0

log "Start"

# eth0 muss durch net.ifnames=0 bereits existieren.
MAC=""
for _ in $(seq 1 "$WAIT_IFACE"); do
    if [ -r "/sys/class/net/${IFACE}/address" ]; then
        MAC="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/${IFACE}/address")"
        case "$MAC" in
            ""|00:00:00:00:00:00) ;;
            *) break ;;
        esac
    fi
    sleep 1
done

printf '%s\n' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || fail "Keine gültige MAC für ${IFACE} erkannt"
log "Erkannt: ${IFACE}, MAC ${MAC}"

# Rock5B-Merge-Workaround: Interface vor der VyOS-Konfiguration administrativ hochsetzen.
ip link set "$IFACE" up 2>/dev/null || true

# Auf eine benutzbare VyOS-Konfigurationslaufzeit warten.
RUNTIME_OK=0
for _ in $(seq 1 "$WAIT_RUNTIME"); do
    if systemctl is-active --quiet vyos-router.service 2>/dev/null \
       && [ -r /opt/vyatta/etc/functions/script-template ] \
       && [ -d /run/vyatta ]; then
        RUNTIME_OK=1
        break
    fi
    sleep 1
done
[ "$RUNTIME_OK" -eq 1 ] || fail "VyOS-Konfigurationslaufzeit wurde nicht rechtzeitig bereit"

# Commit/Save in einer Subshell, damit das Beenden der Config-Session
# nicht das restliche First-Boot-Skript beendet.
(
    source /opt/vyatta/etc/functions/script-template
    configure

    # Vorhandenen unvollständigen Block sauber ergänzen/ersetzen.
    set interfaces ethernet "$IFACE" hw-id "$MAC"
    set interfaces ethernet "$IFACE" description 'WAN-LAN-DHCP'
    set interfaces ethernet "$IFACE" address 'dhcp'
    set interfaces ethernet "$IFACE" dhcp-options default-route-distance '1'

    # SSH dauerhaft in der VyOS-Konfiguration aktivieren.
    set service ssh
    set service ssh port '22'

    if ! commit; then
        discard
        exit 1
    fi

    if ! save; then
        discard
        exit 1
    fi
) || fail "VyOS commit/save fehlgeschlagen"

log "VyOS-Konfiguration gespeichert"

# Der Commit schreibt die SSH-Konfiguration, startet den Dienst in diesem
# gemergten Image aber nicht immer beim ersten Boot. Deshalb gezielt starten.
SSH_UNIT=""
for unit in ssh@default.service ssh.service sshd.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        SSH_UNIT="$unit"
        break
    fi
done

if [ -n "$SSH_UNIT" ]; then
    systemctl start "$SSH_UNIT" || fail "SSH-Dienst ${SSH_UNIT} konnte nicht gestartet werden"
    log "SSH-Dienst gestartet: ${SSH_UNIT}"
else
    fail "Kein passender SSH-systemd-Dienst gefunden"
fi

# Auf DHCP-Adresse und tatsächlich offenen SSH-Port warten.
IP_OK=0
SSH_OK=0
for _ in $(seq 1 "$WAIT_NETWORK"); do
    ip -4 -br address show dev "$IFACE" 2>/dev/null | grep -qE "${IFACE}[[:space:]]+UP[[:space:]]+[^[:space:]]*[0-9]+\." && IP_OK=1
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])22$' && SSH_OK=1
    [ "$IP_OK" -eq 1 ] && [ "$SSH_OK" -eq 1 ] && break
    sleep 1
done

[ "$IP_OK" -eq 1 ] || fail "${IFACE} erhielt keine IPv4-Adresse"
[ "$SSH_OK" -eq 1 ] || fail "SSH lauscht nicht auf TCP-Port 22"

touch "$MARKER"
chmod 600 "$MARKER"
log "FERTIG: ${IFACE} mit DHCP aktiv und SSH auf Port 22 erreichbar"
exit 0

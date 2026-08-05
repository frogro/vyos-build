#!/bin/vbash
# Configure only wired DHCP WAN and SSH in VyOS.
# No AP, DHCP server, DNS forwarding, NAT, or modem configuration.

set -o pipefail

WIRED_IF="${WIRED_IF:-auto}"
ROUTE_DISTANCE="${ROUTE_DISTANCE:-1}"
LOG="/config/dhcp-wan-ssh-setup.log"
IFACE_FILE="/config/.dhcp-wan-interface"

log() {
    printf '%s %s\n' "$(date -Is)" "dhcp-wan-ssh-setup: $*" | tee -a "$LOG"
}

fail() {
    log "FEHLER: $*"
    builtin exit 1
}

for ARG in "$@"; do
    case "$ARG" in
        --auto) ;;
        --interface=*) WIRED_IF="${ARG#*=}" ;;
        --distance=*) ROUTE_DISTANCE="${ARG#*=}" ;;
        -h|--help)
            echo "dhcp-wan-ssh-setup.sh [--auto] [--interface=eth0] [--distance=1]"
            builtin exit 0
            ;;
        *) fail "Unbekannter Parameter: $ARG" ;;
    esac
done

detect_wired_interface() {
    local CANDIDATE

    for CANDIDATE in /sys/class/net/eth* /sys/class/net/en*; do
        [ -e "$CANDIDATE" ] || continue
        CANDIDATE="${CANDIDATE##*/}"
        [ -e "/sys/class/net/$CANDIDATE/device" ] || continue
        [ -r "/sys/class/net/$CANDIDATE/address" ] || continue
        printf '%s\n' "$CANDIDATE"
        return 0
    done

    return 1
}

if [ "$WIRED_IF" = "auto" ]; then
    WIRED_IF="$(detect_wired_interface || true)"
fi

[ -n "$WIRED_IF" ] || fail "Keine kabelgebundene Ethernet-Schnittstelle erkannt"
[ -e "/sys/class/net/$WIRED_IF" ] || fail "Interface $WIRED_IF existiert nicht"

MAC="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$WIRED_IF/address" 2>/dev/null)"
printf '%s\n' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' ||
    fail "Ungueltige MAC-Adresse fuer $WIRED_IF: ${MAC:-leer}"

case "$ROUTE_DISTANCE" in
    ''|*[!0-9]*) fail "Ungueltige Routendistanz: $ROUTE_DISTANCE" ;;
esac

printf '%s\n' "$WIRED_IF" > "$IFACE_FILE"
chmod 600 "$IFACE_FILE"

log "Erkannt: Interface=$WIRED_IF MAC=$MAC DHCP-Distanz=$ROUTE_DISTANCE"

sudo /sbin/ip link set "$WIRED_IF" up 2>/dev/null || true

[ -r /opt/vyatta/etc/functions/script-template ] ||
    fail "VyOS script-template fehlt"

source /opt/vyatta/etc/functions/script-template
configure

set interfaces ethernet "$WIRED_IF" hw-id "$MAC"
set interfaces ethernet "$WIRED_IF" description 'WAN-LAN-DHCP'
set interfaces ethernet "$WIRED_IF" address 'dhcp'
set interfaces ethernet "$WIRED_IF" dhcp-options default-route-distance "$ROUTE_DISTANCE"
set service ssh

CHANGES="$(compare 2>/dev/null || true)"

if [ -n "$CHANGES" ]; then
    if ! commit; then
        discard
        fail "commit fehlgeschlagen"
    fi

    if ! save; then
        discard
        fail "save fehlgeschlagen"
    fi

    log "VyOS-Konfiguration gespeichert"
else
    discard 2>/dev/null || true
    log "Gewuenschte VyOS-Konfiguration war bereits vorhanden"
fi

log "Konfigurationsphase abgeschlossen"

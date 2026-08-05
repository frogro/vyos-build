#!/bin/vbash
set -o pipefail
AUTO=0
WIRED_IF="${WIRED_IF:-auto}"
ROUTE_DISTANCE="${ROUTE_DISTANCE:-1}"
LOG="/config/dhcp-wan-ssh-setup.log"
MARKER="/config/.dhcp-wan-ssh-firstboot-done"
log(){ printf '%s %s\n' "$(date -Is)" "dhcp-wan-ssh-setup: $*" | tee -a "$LOG"; }
die(){ log "FEHLER: $*"; exit 1; }
for ARG in "$@"; do case "$ARG" in --auto) AUTO=1;; --interface=*) WIRED_IF="${ARG#*=}";; --distance=*) ROUTE_DISTANCE="${ARG#*=}";; --force) rm -f "$MARKER";; -h|--help) echo 'dhcp-wan-ssh-setup.sh [--auto] [--interface=eth0] [--distance=1] [--force]'; exit 0;; *) die "Unbekannter Parameter: $ARG";; esac; done
[ "$AUTO" -eq 1 ] && [ -e "$MARKER" ] && exit 0

detect_wired_interface(){
  local IFACE
  IFACE="$(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null | sed -n "s/^set interfaces ethernet \([^ ]*\).*/\1/p" | while read -r C; do [ -e "/sys/class/net/$C" ] || continue; printf '%s\n' "$C"; break; done)"
  [ -n "$IFACE" ] && { printf '%s\n' "$IFACE"; return 0; }
  for IFACE in /sys/class/net/*; do
    IFACE="${IFACE##*/}"
    case "$IFACE" in lo|wlan*|wl*|wwan*|usb*|br*|bond*|dummy*|pim*|tun*|tap*|vti*|vrf*) continue;; esac
    [ -e "/sys/class/net/$IFACE/device" ] || continue
    [ -r "/sys/class/net/$IFACE/address" ] || continue
    case "$IFACE" in eth*|en*|end*) printf '%s\n' "$IFACE"; return 0;; esac
  done
  return 1
}

[ "$WIRED_IF" = auto ] && WIRED_IF="$(detect_wired_interface || true)"
[ -n "$WIRED_IF" ] || die "Keine kabelgebundene Ethernet-Schnittstelle erkannt"
[ -e "/sys/class/net/$WIRED_IF" ] || die "Interface $WIRED_IF existiert nicht"
MAC="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$WIRED_IF/address" 2>/dev/null)"
printf '%s\n' "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || die "Ungültige MAC-Adresse für $WIRED_IF"
case "$ROUTE_DISTANCE" in ''|*[!0-9]*) die "Ungültige Routendistanz: $ROUTE_DISTANCE";; esac
log "Erkannt: Interface=$WIRED_IF MAC=$MAC DHCP-Distanz=$ROUTE_DISTANCE"
sudo /sbin/ip link set "$WIRED_IF" up 2>/dev/null || true
[ -r /opt/vyatta/etc/functions/script-template ] || die "VyOS script-template fehlt"
source /opt/vyatta/etc/functions/script-template
configure
set interfaces ethernet "$WIRED_IF" hw-id "$MAC"
set interfaces ethernet "$WIRED_IF" description 'WAN-LAN-DHCP'
set interfaces ethernet "$WIRED_IF" address 'dhcp'
set interfaces ethernet "$WIRED_IF" dhcp-options default-route-distance "$ROUTE_DISTANCE"
set service ssh
if ! commit; then discard; die "commit fehlgeschlagen"; fi
if ! save; then discard; die "save fehlgeschlagen"; fi
log "VyOS-Konfiguration gespeichert"
if [ "$AUTO" -eq 1 ]; then
  IPV4=""
  for _ in $(seq 1 60); do IPV4="$(ip -4 -br address show dev "$WIRED_IF" 2>/dev/null | awk '{print $3; exit}')"; [ -n "$IPV4" ] && break; sleep 2; done
  [ -n "$IPV4" ] && log "$WIRED_IF erhielt IPv4 $IPV4" || log "WARNUNG: $WIRED_IF erhielt noch keine IPv4-Adresse; Konfiguration bleibt gespeichert"
  touch "$MARKER"; chmod 600 "$MARKER"
fi
log "FERTIG: $WIRED_IF auf DHCP, Routendistanz $ROUTE_DISTANCE, SSH aktiviert"

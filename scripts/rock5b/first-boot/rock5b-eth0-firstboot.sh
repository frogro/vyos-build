#!/bin/vbash
# Wird von einem eigenen systemd-Dienst (rock5b-eth0-firstboot.service)
# nach vyos-router.service ausgefuehrt.
#
# Zweck: eth0 einmalig, beim allerersten Boot, dynamisch mit der
# tatsaechlich erkannten MAC-Adresse dieses spezifischen Boards binden.
# Board-unabhaengig: identisch fuer jedes Rock5B-Board, MAC wird zur
# Laufzeit ermittelt.

# In die vyattacfg-Gruppe wechseln, falls noch nicht dort - genau das
# Muster, das modem-connect.sh bereits erfolgreich nutzt. systemd startet
# uns sonst als root/root ohne vyattacfg-Gruppenkontext, was die
# VyOS-Konfigurationssitzung stoeren kann.
if [ "$(id -g -n)" != "vyattacfg" ]; then
    printf -v _vyos_cmd "%q " /bin/vbash "$(readlink -f "$0")" "$@"
    exec sg vyattacfg -c "$_vyos_cmd"
fi

MARKER="/config/.rock5b-eth0-firstboot-done"
LOG="/config/rock5b-eth0-firstboot.log"

[ -e "$MARKER" ] && exit 0

echo "$(date -Is) rock5b-eth0-firstboot: Start" >> "$LOG"

MAC=""
for i in $(seq 1 60); do
    if [ -e /sys/class/net/eth0/address ]; then
        MAC="$(cat /sys/class/net/eth0/address)"
        [ -n "$MAC" ] && [ "$MAC" != "00:00:00:00:00:00" ] && break
    fi
    sleep 1
done

if [ -z "$MAC" ] || [ "$MAC" = "00:00:00:00:00:00" ]; then
    echo "$(date -Is) rock5b-eth0-firstboot: Konnte MAC von eth0 nicht ermitteln, breche ab." >> "$LOG"
    exit 1
fi

echo "$(date -Is) rock5b-eth0-firstboot: Erkannte MAC $MAC" >> "$LOG"

# Auf vyos-configd, vyos-hostsd und funktionierende Hostname-Aufloesung
# warten (verhindert "Failed to generate committed config" bei zu
# frueher Ausfuehrung). Bis zu 60s, mit klarem Abbruch statt stillem
# Weiterlaufen bei Timeout.
READY=0
for i in $(seq 1 60); do
    if systemctl is-active --quiet vyos-configd 2>/dev/null \
       && systemctl is-active --quiet vyos-hostsd 2>/dev/null \
       && getent hosts "$(hostname)" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "$READY" -ne 1 ]; then
    echo "$(date -Is) rock5b-eth0-firstboot: vyos-configd/vyos-hostsd/Hostname-Aufloesung nach 60s nicht bereit, breche ab." >> "$LOG"
    echo "$(date -Is) rock5b-eth0-firstboot: systemd wird beim naechsten Boot erneut versuchen (kein Marker gesetzt)." >> "$LOG"
    exit 1
fi
echo "$(date -Is) rock5b-eth0-firstboot: vyos-configd/vyos-hostsd/Hostname-Aufloesung bereit" >> "$LOG"

source /opt/vyatta/etc/functions/script-template
configure

set interfaces ethernet eth0 hw-id "$MAC"
set interfaces ethernet eth0 description 'WAN-LAN-DHCP'
set interfaces ethernet eth0 address 'dhcp'
set interfaces ethernet eth0 dhcp-options default-route-distance '1'
set service ssh port '22'

if ! commit; then
    echo "$(date -Is) rock5b-eth0-firstboot: commit fehlgeschlagen" >> "$LOG"
    discard
    exit 1
fi

if ! save; then
    echo "$(date -Is) rock5b-eth0-firstboot: save fehlgeschlagen" >> "$LOG"
    discard
    exit 1
fi

echo "$(date -Is) rock5b-eth0-firstboot: commit+save erfolgreich, MAC=$MAC" >> "$LOG"
touch "$MARKER"
exit

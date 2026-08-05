#!/bin/vbash
# Wird von einem eigenen systemd-Dienst (rock5b-eth0-firstboot.service)
# NACH multi-user.target ausgefuehrt - also erst, wenn das System als
# vollstaendig gebootet gilt. Genau der Zeitpunkt, zu dem ein manuell per
# SSH/Konsole ausgefuehrtes Setup-Skript zuverlaessig funktioniert.
#
# Frueher wurde versucht, exakt auf vyos-configd/vyos-hostsd/dbus/polkit
# zu warten - das war fragil (falsche/wechselnde Dienstnamen fuehrten
# zu Timeout, ohne dass ueberhaupt ein Configure-Versuch stattfand).
# Einfacher und robuster: spaet genug starten (systemd-Ordering +
# Sicherheitsabstand), dann EINMAL sauber versuchen - Punkt.
#
# Zweck: eth0 einmalig, beim allerersten Boot, dynamisch mit der
# tatsaechlich erkannten MAC-Adresse dieses spezifischen Boards binden.
# Board-unabhaengig: identisch fuer jedes Rock5B-Board, MAC wird zur
# Laufzeit ermittelt.

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

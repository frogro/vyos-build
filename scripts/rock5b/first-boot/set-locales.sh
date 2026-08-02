#!/bin/vbash
source /opt/vyatta/etc/functions/script-template

DEFAULT_TZ="Europe/Berlin"
DEFAULT_KEYBOARD="de"
DEFAULT_WIFI_COUNTRY="de"
DEFAULT_DNS1="1.1.1.1"
DEFAULT_DNS2="9.9.9.9"
DEFAULT_NTP1="162.159.200.1"
DEFAULT_NTP2="162.159.200.123"

ask_default() {
    local prompt="$1"
    local default="$2"
    local answer=""
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-j}"
    local answer=""
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
    case "$answer" in
        j|J|ja|JA|y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$(id -u)" -eq 0 ]; then
    echo "Bitte als Benutzer vyos starten, nicht direkt als root."
    exit 1
fi

echo "=== VyOS Standort-, Zeit- und WLAN-Grundeinstellung ==="
echo "Achtung: Beim Commit kann der WLAN-AP kurz neu starten und SSH abbrechen."
echo

TZ_VALUE="$(ask_default "Zeitzone" "$DEFAULT_TZ")"
KEYBOARD_VALUE="$(ask_default "Konsolen-Tastaturlayout" "$DEFAULT_KEYBOARD")"
WIFI_COUNTRY_VALUE="$(ask_default "WLAN-Ländercode" "$DEFAULT_WIFI_COUNTRY")"
DNS1="$(ask_default "Primärer DNS-Server" "$DEFAULT_DNS1")"
DNS2="$(ask_default "Sekundärer DNS-Server" "$DEFAULT_DNS2")"
NTP1="$(ask_default "Primärer NTP-Server" "$DEFAULT_NTP1")"
NTP2="$(ask_default "Sekundärer NTP-Server" "$DEFAULT_NTP2")"

echo
echo "Zeitzone: $TZ_VALUE"
echo "Tastatur: $KEYBOARD_VALUE"
echo "WLAN-Land: $WIFI_COUNTRY_VALUE"
echo "DNS: $DNS1, $DNS2"
echo "NTP: $NTP1, $NTP2"
echo

if ! ask_yes_no "Übernehmen?" "j"; then
    echo "Abgebrochen."
    exit 0
fi

configure

delete system name-server eth5 2>/dev/null || true

set system time-zone "$TZ_VALUE" 2>/dev/null || true
set system option keyboard-layout "$KEYBOARD_VALUE" 2>/dev/null || true
set system wireless country-code "$WIFI_COUNTRY_VALUE" 2>/dev/null || true
set system name-server "$DNS1" 2>/dev/null || true
set system name-server "$DNS2" 2>/dev/null || true

set service ntp server "$NTP1" 2>/dev/null || true
set service ntp server "$NTP2" 2>/dev/null || true

echo
echo "=== Vorgesehene Änderungen ==="
compare
echo

if ! ask_yes_no "Commit und Save ausführen? Der AP kann kurz ausfallen." "j"; then
    discard
    exit
fi

if ! commit; then
    echo "Commit fehlgeschlagen; nichts gespeichert."
    discard
    exit 1
fi

if ! save; then
    echo "Save fehlgeschlagen."
    exit 1
fi

exit

echo
echo "Konfiguration gespeichert. Starte Chrony neu..."
sudo systemctl restart chrony
sleep 5
sudo chronyc makestep >/dev/null 2>&1 || true

echo
echo "=== Zeitstatus ==="
date
timedatectl status | sed -n '1,8p'
echo
echo "=== NTP-Quellen ==="
chronyc sources -v || true
echo
echo "Fertig."

#!/bin/vbash
#
# modem-connect.sh
# Universal modem setup for VyOS on ROCK 5B.
#
# Supports ModemManager, native QMI/MBIM, FM350 USB AT/RNDIS, DHCP-style
# modem interfaces, modem-specific FCC unlock, PCIe/USB/Thunderbolt discovery,
# wired-WAN preference, WWAN fallback routing, NAT, recovery, and autostart.
#
# Project: https://github.com/frogro/vyos-build
#
set -o pipefail
if [ "$(id -g -n)" != "vyattacfg" ]; then printf -v _vyos_cmd "%q " /bin/vbash "$(readlink -f "$0")" "$@"; exec sg vyattacfg -c "$_vyos_cmd"; fi

APN_CACHE="${APN_CACHE:-/etc/modem-apn.conf}"
MUX_CACHE="${MUX_CACHE:-/etc/modem-multiplex-mode.conf}"
BACKEND_CACHE="${BACKEND_CACHE:-/etc/modem-backend-mode.conf}"
ROUTE_CACHE="${ROUTE_CACHE:-/etc/modem-route.conf}"
NATIVE_STATE_DIR="${NATIVE_STATE_DIR:-/var/lib/modem-connect}"
DEFAULT_APN="${DEFAULT_APN:-internet}"
BACKEND_MODE="${BACKEND_MODE:-auto}"
BACKEND_POLICY="${BACKEND_POLICY:-}"
BACKEND_EXPLICIT=0
TRANSPORT_MODE="${TRANSPORT_MODE:-auto}"
MULTIPLEX_MODE="${MULTIPLEX_MODE:-auto}"
MODEM_REQUEST="${MODEM_REQUEST:-}"
MODEM_DEVICE_ID_REQUEST="${MODEM_DEVICE_ID_REQUEST:-}"
MODEM_EQUIPMENT_ID_REQUEST="${MODEM_EQUIPMENT_ID_REQUEST:-}"
CONTROL_DEVICE_REQUEST="${CONTROL_DEVICE_REQUEST:-}"
NET_IF_REQUEST="${NET_IF_REQUEST:-}"
WIRED_WAN="${WIRED_WAN:-auto}"
AP_IF="${AP_IF:-auto}"
AP_IF_CACHE="${AP_IF_CACHE:-/etc/photobooth-ap-interface.conf}"
AP_GATEWAY="${AP_GATEWAY:-10.3.141.50}"
AP_NET="${AP_NET:-10.3.141.0/24}"
WIRED_ROUTE_DISTANCE="${WIRED_ROUTE_DISTANCE:-1}"
WWAN_ROUTE_DISTANCE="${WWAN_ROUTE_DISTANCE:-10}"
WWAN_NAT_RULE="${WWAN_NAT_RULE:-160}"
WIRED_NAT_RULE="${WIRED_NAT_RULE:-100}"
SELF_PATH="$(readlink -f "$0")"
SERVICE_PATH="/etc/systemd/system/modem-connect.service"
UNLOCK_SERVICE_PATH="/etc/systemd/system/modem-unlock.service"
FM350_RECOVERY_SERVICE_PATH="/etc/systemd/system/modem-connect-recover.service"
FM350_UDEV_RULE="/etc/udev/rules.d/80-fm350-rndis-recover.rules"
FM350_LINK_FILE="/etc/systemd/network/10-fm350-rndis.link"
FM350_STABLE_IF="${FM350_STABLE_IF:-wwanusb0}"
UNLOCK_STATE_DIR="${UNLOCK_STATE_DIR:-/run/modem-connect}"
FM350_RECOVERY_LOCK="${FM350_RECOVERY_LOCK:-/run/modem-connect/fm350-recovery.lock}"
FM350_AT_CACHE="${FM350_AT_CACHE:-/run/modem-connect/fm350-at-port.conf}"
CONFIG_FILE="${CONFIG_FILE:-/etc/modem-connect.conf}"
FCC_VENDOR_HASH="${FCC_VENDOR_HASH:-3df8c719}"
ACTION="install"
APN_ARG=""
PROBE_ONLY=0
NO_SAVE_BACKEND=0
SERVICE_RUN=0
UNLOCK_ONLY=0
RECOVER_ONLY=0
AUTO_REPAIR=1
FM350_AVAILABLE=0
FM350_TRANSPORT=""
FM350_SYS=""
FM350_USB_ID=""
FM350_AT_DEV=""
FM350_RNDIS_IF=""
FM350_IMEI=""
FM350_PDP_IP=""
FM350_CID="${FM350_CID:-1}"
FM350_REGISTRATION_ATTEMPTS="${FM350_REGISTRATION_ATTEMPTS:-60}"
FM350_REGISTRATION_RESET_WAIT="${FM350_REGISTRATION_RESET_WAIT:-5}"
FM350_REGISTRATION_RESET_DONE=0
FM350_REGISTRATION_FAILURE=""
MODEM_TRANSPORT="unknown"

LEGACY_UNLOCK_SERVICE="/etc/systemd/system/fm350-unlock.service"
LEGACY_UNLOCK_SCRIPT_CANDIDATES="/usr/local/sbin/fm350-unlock.sh /home/vyos/fm350-unlock.sh"
LEGACY_APN_CACHE="/etc/fm350-apn.conf"

THUNDERBOLT_MODULES_FILE="${THUNDERBOLT_MODULES_FILE:-/etc/modules-load.d/thunderbolt.conf}"
THUNDERBOLT_UDEV_RULE="${THUNDERBOLT_UDEV_RULE:-/etc/udev/rules.d/99-thunderbolt-auto-authorize.rules}"
MODEM_DISCOVERY_WAIT="${MODEM_DISCOVERY_WAIT:-120}"
VYOS_CONFIG_WAIT="${VYOS_CONFIG_WAIT:-120}"
VYOS_BOOT_SETTLE="${VYOS_BOOT_SETTLE:-3}"
VYOS_COMMIT_RETRIES="${VYOS_COMMIT_RETRIES:-6}"
VYOS_COMMIT_RETRY_DELAY="${VYOS_COMMIT_RETRY_DELAY:-10}"

log() { echo "[MODEM] $*"; }
warn() { echo "[MODEM] WARNING: $*" >&2; }
die() { echo "[MODEM] ERROR: $*" >&2; builtin exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_cached_ap() {
  local candidate=""
  [ -r "$AP_IF_CACHE" ] || return 1
  candidate="$(sed -n "s/^AP_IF=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" "$AP_IF_CACHE" | head -1)"
  [ -n "$candidate" ] || return 1
  [[ "$candidate" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || return 1
  if [ "$SERVICE_RUN" -eq 1 ] || ip link show "$candidate" >/dev/null 2>&1; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

detect_ap_by_ip() {
  ip -o -4 addr show 2>/dev/null | awk -v ip="$AP_GATEWAY" '
    {
      split($4, a, "/")
      if (a[1] == ip) {
        print $2
        exit
      }
    }'
}

detect_ap() {
  local candidate=""
  candidate="$(detect_cached_ap 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate="$(detect_ap_by_ip)"
  [ -n "$candidate" ] || return 1
  printf '%s' "$candidate"
}

usage() {
  cat <<USAGE
Usage: sudo $0 [OPTIONS]

Options:
  --probe                    Probe available modem/backend modes without connecting
  --backend MODE            auto, auto-native, mm, qmi, mbim, at-rndis or dhcp
  --apn APN                  Set APN without prompting
  --transport MODE          auto, pcie or usb; default: automatic detection
  --modem INDEX              Use a specific current ModemManager index
  --device-id ID              Select modem by ModemManager device ID
  --equipment-id ID           Persistently select modem by IMEI/equipment ID
  --control-device PFAD      Set QMI/MBIM control device explicitly
  --net-if IFACE             Set data interface explicitly
  --multiplex MODE          auto, none or default; ModemManager only
  --wired-wan IFACE          Wired WAN: auto, none or Interface; Standard: auto
  --ap-if IFACE              AP interface; default: cache/IP detection
  --ap-net CIDR              AP network for NAT (Standard: $AP_NET)
  --no-save-backend          Do not save the successful backend per modem
  --no-auto-repair            Do not automatically rebind MHI after a multiplex error
  --unlock-only               Run only the detected modem-specific unlock (internal/diagnostic)
  --recover                   Check the FM350 USB path after a udev event and repair only when required
  --uninstall                Remove services, caches, and self-managed VyOS rules
  -h, --help                 Hilfe show

Backend-Hinweise:
  auto        Gespeichertes successfules Backend use; ohne Cache ModemManager.
              Retry the known ModemManager multiplex error with multiplex=none.
  auto-native Also try AT-RNDIS/QMI/MBIM/DHCP fallbacks after a failure.
  mm          ModemManager only.
  qmi         qmicli direkt. Suitable for QMI-Control-Ports wie cdc-wdmX or wwanXqmiY.
  mbim        mbimcli direkt. Suitable for MBIM-Control-Ports wie cdc-wdmX or wwanXmbimY.
  at-rndis    FM350 USB/RNDIS mit dynamischem AT-Port und Data interface.
  dhcp        For ECM/NCM/RNDIS or router-mode modems; the APN is not set.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --probe) PROBE_ONLY=1; shift ;;
    --backend) [ "$#" -ge 2 ] || die "Missing value for --backend is missing"; BACKEND_MODE="$2"; BACKEND_EXPLICIT=1; shift 2 ;;
    --transport) [ "$#" -ge 2 ] || die "Missing value for --transport is missing"; TRANSPORT_MODE="$2"; shift 2 ;;
    --apn) [ "$#" -ge 2 ] || die "Missing value for --apn is missing"; APN_ARG="$2"; shift 2 ;;
    --modem) [ "$#" -ge 2 ] || die "Missing value for --modem is missing"; MODEM_REQUEST="$2"; shift 2 ;;
    --device-id) [ "$#" -ge 2 ] || die "Missing value for --device-id is missing"; MODEM_DEVICE_ID_REQUEST="$2"; shift 2 ;;
    --equipment-id) [ "$#" -ge 2 ] || die "Missing value for --equipment-id is missing"; MODEM_EQUIPMENT_ID_REQUEST="$2"; shift 2 ;;
    --control-device) [ "$#" -ge 2 ] || die "Missing value for --control-device is missing"; CONTROL_DEVICE_REQUEST="$2"; shift 2 ;;
    --net-if) [ "$#" -ge 2 ] || die "Missing value for --net-if is missing"; NET_IF_REQUEST="$2"; shift 2 ;;
    --multiplex) [ "$#" -ge 2 ] || die "Missing value for --multiplex is missing"; MULTIPLEX_MODE="$2"; shift 2 ;;
    --wired-wan) [ "$#" -ge 2 ] || die "Missing value for --wired-wan is missing"; WIRED_WAN="$2"; shift 2 ;;
    --ap-if) [ "$#" -ge 2 ] || die "Missing value for --ap-if is missing"; AP_IF="$2"; shift 2 ;;
    --ap-net) [ "$#" -ge 2 ] || die "Missing value for --ap-net is missing"; AP_NET="$2"; shift 2 ;;
    --no-save-backend) NO_SAVE_BACKEND=1; shift ;;
    --no-auto-repair) AUTO_REPAIR=0; shift ;;
    --service-run) SERVICE_RUN=1; shift ;;
    --unlock-only) UNLOCK_ONLY=1; shift ;;
    --recover) RECOVER_ONLY=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage; builtin exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

config_get() {
  local key="$1"
  [ -s "$CONFIG_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$CONFIG_FILE" | head -1
}

if [ "$SERVICE_RUN" -eq 1 ]; then
  [ -s "$CONFIG_FILE" ] || die "Autostart configuration is missing: $CONFIG_FILE"
  APN_ARG="$(config_get APN)"
  MODEM_DEVICE_ID_REQUEST="$(config_get MODEM_DEVICE_ID)"
  MODEM_EQUIPMENT_ID_REQUEST="$(config_get MODEM_EQUIPMENT_ID)"
  SAVED_BACKEND_POLICY="$(config_get BACKEND_POLICY)"
  SAVED_MULTIPLEX="$(config_get MULTIPLEX)"
  SAVED_AP_NET="$(config_get AP_NET)"
  SAVED_WIRED_WAN="$(config_get WIRED_WAN)"
  SAVED_FM350_STABLE_IF="$(config_get FM350_STABLE_IF)"
  case "$SAVED_WIRED_WAN" in
    auto|none) WIRED_WAN="$SAVED_WIRED_WAN" ;;
    "") ;;
    *) [[ "$SAVED_WIRED_WAN" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] && WIRED_WAN="$SAVED_WIRED_WAN" ;;
  esac
  if [[ "$SAVED_FM350_STABLE_IF" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; then
    FM350_STABLE_IF="$SAVED_FM350_STABLE_IF"
  fi
  BACKEND_MODE="${SAVED_BACKEND_POLICY:-auto}"
  [ -n "$SAVED_MULTIPLEX" ] && MULTIPLEX_MODE="$SAVED_MULTIPLEX"
  [ -n "$SAVED_AP_NET" ] && AP_NET="$SAVED_AP_NET"
fi
BACKEND_POLICY="${BACKEND_POLICY:-$BACKEND_MODE}"

case "$BACKEND_MODE" in auto|auto-native|mm|qmi|mbim|at-rndis|dhcp) ;; *) die "--backend muss auto, auto-native, mm, qmi, mbim, at-rndis or dhcp sein" ;; esac
case "$TRANSPORT_MODE" in auto|pcie|usb) ;; *) die "--transport muss auto, pcie or usb sein" ;; esac
case "$MULTIPLEX_MODE" in auto|none|default) ;; *) die "--multiplex muss auto, none or default sein" ;; esac
case "$WIRED_WAN" in auto|none) ;; *) [[ "$WIRED_WAN" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "--wired-wan muss auto, none or ein gueltiger Interfacename sein" ;; esac
case "$AP_NET" in */*) ;; *) die "--ap-net muss CIDR enthalten" ;; esac
[ "$EUID" -eq 0 ] || die "Please run with sudo"

need_cmd ip
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd readlink
need_cmd systemctl
need_cmd timeout
need_cmd udevadm
need_cmd modprobe
need_cmd python3

if [ "$UNLOCK_ONLY" -eq 1 ] || [ "$RECOVER_ONLY" -eq 1 ]; then
  AP_IF=""
else
  if [ "$AP_IF" = auto ]; then
    AP_IF="$(detect_ap 2>/dev/null || true)"
  fi
  [ -n "$AP_IF" ] || AP_IF="wlan0"
  log "AP interface for NAT/detection: $AP_IF"
fi

if [ "$SERVICE_RUN" -eq 0 ] && [ "$RECOVER_ONLY" -eq 0 ]; then
  systemctl stop modem-connect.service >/dev/null 2>&1 || true
  systemctl stop modem-unlock.service >/dev/null 2>&1 || true
fi

mmcli_timed() {
  local seconds="$1"
  shift
  timeout --signal=TERM --kill-after=5s "$seconds" mmcli "$@"
}

kv_get() {
  local key="$1"
  awk -F':' -v want="$key" '
    {
      k=$1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == want) {
        sub(/^[^:]*:[[:space:]]*/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        gsub(/^\047|\047$/, "", $0)
        gsub(/^"|"$/, "", $0)
        print $0
        exit
      }
    }
  '
}

safe_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

cache_read() {
  local file="$1" key="$2"
  [ -s "$file" ] || return 0
  awk -v key="$key" '$1 == key {print $2; exit}' "$file"
}

cache_write() {
  local file="$1" key="$2" value="$3" tmp="${file}.tmp"
  mkdir -p "$(dirname "$file")"
  if [ -s "$file" ]; then
    awk -v key="$key" '$1 != key' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s %s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
}

cleanup_legacy() {
  local removed=0 f
  if [ -f "$LEGACY_UNLOCK_SERVICE" ]; then
    systemctl disable --now fm350-unlock.service 2>/dev/null || true
    rm -f "$LEGACY_UNLOCK_SERVICE"
    removed=1
  fi
  for f in $LEGACY_UNLOCK_SCRIPT_CANDIDATES; do
    [ -f "$f" ] || continue
    rm -f "$f"
    removed=1
  done
  [ -f "$LEGACY_APN_CACHE" ] && rm -f "$LEGACY_APN_CACHE" && removed=1
  [ "$removed" -eq 1 ] && systemctl daemon-reload
}

stop_native_sessions() {
  local f dev cid handle session
  for f in "$NATIVE_STATE_DIR"/*.qmi; do
    [ -f "$f" ] || continue
    dev="$(awk -F= '$1=="DEV" {print $2}' "$f")"
    cid="$(awk -F= '$1=="CID" {print $2}' "$f")"
    handle="$(awk -F= '$1=="HANDLE" {print $2}' "$f")"
    if [ -n "$dev" ] && [ -n "$handle" ] && have_cmd qmicli; then
      if [ -n "$cid" ]; then
        qmicli -d "$dev" --device-open-qmi --client-cid="$cid" --wds-stop-network="$handle" >/dev/null 2>&1 || true
      else
        qmicli -d "$dev" --device-open-qmi --wds-stop-network="$handle" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$f"
  done
  for f in "$NATIVE_STATE_DIR"/*.mbim; do
    [ -f "$f" ] || continue
    dev="$(awk -F= '$1=="DEV" {print $2}' "$f")"
    session="$(awk -F= '$1=="SESSION" {print $2}' "$f")"
    [ -n "$session" ] || session=0
    [ -n "$dev" ] && have_cmd mbimcli && mbimcli -d "$dev" --disconnect="$session" >/dev/null 2>&1 || true
    rm -f "$f"
  done
}

remove_managed_vyos_config() {
  local old_gateway="" helper result commit_rc="" save_rc=""
  [ -r /opt/vyatta/etc/functions/script-template ] || return 0
  [ -s "$ROUTE_CACHE" ] && old_gateway="$(awk -F= '$1=="GATEWAY" {print $2; exit}' "$ROUTE_CACHE")"

  mkdir -p "$UNLOCK_STATE_DIR"
  helper="$UNLOCK_STATE_DIR/vyos-remove-$$.sh"
  result="$UNLOCK_STATE_DIR/vyos-remove-result-$$"
  rm -f "$helper" "$result"

  cat > "$helper" <<'EOF'
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure
EOF
  printf 'delete nat source rule %q 2>/dev/null || true\n' "$WIRED_NAT_RULE" >> "$helper"
  printf 'delete nat source rule %q 2>/dev/null || true\n' "$WWAN_NAT_RULE" >> "$helper"
  [ -n "$old_gateway" ] && printf 'delete protocols static route 0.0.0.0/0 next-hop %q 2>/dev/null || true\n' "$old_gateway" >> "$helper"
  cat >> "$helper" <<EOF
commit
COMMIT_RC=\$?
save
SAVE_RC=\$?
printf 'COMMIT_RC=%s\\nSAVE_RC=%s\\n' "\$COMMIT_RC" "\$SAVE_RC" > $(printf '%q' "$result")
discard 2>/dev/null || true
exit
EOF
  chmod 0700 "$helper"
  /bin/vbash "$helper" >/dev/null 2>&1 || true
  commit_rc="$(sed -n 's/^COMMIT_RC=//p' "$result" 2>/dev/null | head -1)"
  save_rc="$(sed -n 's/^SAVE_RC=//p' "$result" 2>/dev/null | head -1)"
  rm -f "$helper" "$result"

  if [ "$save_rc" != 0 ]; then
    warn "VyOS rules may have been removed, but the configuration could not be saved (commit=${commit_rc:-?}, save=${save_rc:-?})"
  fi
  return 0
}

uninstall_all() {
  log "Deinstalliere modem-connect..."
  systemctl disable --now modem-connect.service modem-unlock.service modem-connect-recover.service 2>/dev/null || true
  stop_native_sessions
  rm -f "$SERVICE_PATH" "$UNLOCK_SERVICE_PATH" "$FM350_RECOVERY_SERVICE_PATH" "$FM350_UDEV_RULE" "$FM350_LINK_FILE"
  cleanup_legacy
  remove_managed_vyos_config
  rm -f "$APN_CACHE" "$MUX_CACHE" "$BACKEND_CACHE" "$ROUTE_CACHE" "$CONFIG_FILE"
  rm -rf "$NATIVE_STATE_DIR" "$UNLOCK_STATE_DIR"
  systemctl daemon-reload
  log "connections-/Unlock-Service, Caches, native Sitzungen und selbst verwaltete VyOS-Regeln entfernt."
  builtin exit 0
}

[ "$ACTION" = "uninstall" ] && uninstall_all
cleanup_legacy

ensure_modem_device_discovery() {
  local auth devname state

  log "Configuring integrated PCIe/USB/Thunderbolt modem detection..."

  # Die eigentliche Port-Erkennung ist for PCIe, USB und Thunderbolt gleich:
  # Kernel bindet den passenden driver, ModemManager erkennt dessen Ports.
  if modprobe --show-depends thunderbolt >/dev/null 2>&1; then
    mkdir -p /etc/modules-load.d /etc/udev/rules.d
    printf '%s\n' thunderbolt > "$THUNDERBOLT_MODULES_FILE"
    chmod 0644 "$THUNDERBOLT_MODULES_FILE"

    cat > "$THUNDERBOLT_UDEV_RULE" <<'EOF'
# Von modem-connect-universal-v5.9 verwaltet.
# Autorisiert jedes externe Thunderbolt-/USB4-device automatisch.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
ACTION=="change", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
EOF
    chmod 0644 "$THUNDERBOLT_UDEV_RULE"

    if systemctl is-active --quiet bolt.service 2>/dev/null; then
      warn "bolt.service is active; Thunderbolt is also authorized by udev"
    fi

    modprobe thunderbolt 2>/dev/null || true
    udevadm control --reload-rules

    for auth in /sys/bus/thunderbolt/devices/*/authorized; do
      [ -e "$auth" ] || continue
      devname="$(basename "$(dirname "$auth")")"
      case "$devname" in *-0) continue ;; esac
      state="$(cat "$auth" 2>/dev/null || true)"
      if [ "$state" = 0 ]; then
        log "Authorizing Thunderbolt device $devname..."
        printf '1\n' > "$auth" 2>/dev/null || warn "Thunderbolt-device $devname could not be authorized"
      fi
    done
  fi

  # Namen wie wwan0, wwan1, Modem/0 or Modem/1 vorausgesetzt.
  udevadm settle --timeout=20 2>/dev/null || true
}


wait_for_vyos_config_runtime() {
  local i
  [ "$SERVICE_RUN" -eq 1 ] || return 0

  for i in $(seq 1 "$VYOS_CONFIG_WAIT"); do
    if systemctl is-active --quiet vyos-router.service && [ -d /run/vyatta/config ]; then
      log "VyOS configuration runtime is ready; waiting ${VYOS_BOOT_SETTLE}s for boot commits to finish..."
      sleep "$VYOS_BOOT_SETTLE"
      return 0
    fi
    [ "$i" -eq 1 ] && log "Waiting for the VyOS configuration runtime..."
    sleep 1
  done

  die "VyOS configuration runtime is not ready after ${VYOS_CONFIG_WAIT}s not ready (/run/vyatta/config is missing)"
}

load_known_drivers() {
  local line pciaddr sysdev modalias mod dev vid
  log "Checking PCI-Modem-Devices for missing driver bindings..."
  if have_cmd lspci; then
    while read -r line; do
      [ -n "$line" ] || continue
      pciaddr="$(echo "$line" | awk '{print $1}')"
      sysdev="/sys/bus/pci/devices/${pciaddr}"
      [ -d "$sysdev" ] || continue
      if [ ! -e "$sysdev/driver" ]; then
        modalias="$(cat "$sysdev/modalias" 2>/dev/null || true)"
        mod=""
        [ -n "$modalias" ] && mod="$(modprobe --resolve-alias "$modalias" 2>/dev/null | head -1 || true)"
        if [ -n "$mod" ]; then
          log "  $line: lade driver $mod..."
          modprobe "$mod" 2>/dev/null || true
          sleep 2
        fi
      fi
    done < <(lspci -Dnn | grep -iE "modem|wwan|wireless controller|unassigned class.*(SDX|WWAN|modem)" || true)
  fi

  log "Checking known USB modem vendors..."
  for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] || continue
    vid="$(cat "$dev/idVendor" 2>/dev/null)"
    case "$vid" in 2c7c|2cb7|1199|1bc7|1546|0e8d|12d1) ;; *) continue ;; esac
    [ -e "$dev/driver" ] && continue
    modalias="$(cat "$dev/modalias" 2>/dev/null || true)"
    mod=""
    [ -n "$modalias" ] && mod="$(modprobe --resolve-alias "$modalias" 2>/dev/null | head -1 || true)"
    [ -n "$mod" ] && modprobe "$mod" 2>/dev/null || true
  done
}


fm350_path_belongs() {
  local path="$1" base
  [ -n "$FM350_SYS" ] && [ -n "$path" ] || return 1
  base="$(readlink -f "$FM350_SYS" 2>/dev/null || true)"
  path="$(readlink -f "$path" 2>/dev/null || true)"
  [ -n "$base" ] && [ -n "$path" ] || return 1
  case "$path" in "$base"|"$base"/*|"$base":*) return 0 ;; *) return 1 ;; esac
}

fm350_find_rndis_iface() {
  local n path driver
  FM350_RNDIS_IF=""
  for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    n="$(basename "$path")"
    [ "$n" = lo ] && continue
    fm350_path_belongs "$path/device" || continue
    driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    if [ "$driver" = rndis_host ]; then
      FM350_RNDIS_IF="$n"
      return 0
    fi
  done
  return 1
}

fm350_set_usb_power() {
  [ "$FM350_TRANSPORT" = usb ] || return 0
  [ -e "$FM350_SYS/power/control" ] && printf 'on\n' > "$FM350_SYS/power/control" 2>/dev/null || true
  [ -e "$FM350_SYS/power/autosuspend_delay_ms" ] && printf '%s\n' -1 > "$FM350_SYS/power/autosuspend_delay_ms" 2>/dev/null || true
}

# startet die connection nach einer USB-Neuanmeldung automatisch neu.
fm350_install_rndis_recovery() {
  local current mac
  [ "$FM350_TRANSPORT" = usb ] || return 0
  fm350_find_rndis_iface || return 0
  current="$FM350_RNDIS_IF"
  mac="$(cat "/sys/class/net/$current/address" 2>/dev/null || true)"
  [ -n "$mac" ] || return 0

  mkdir -p "$(dirname "$FM350_LINK_FILE")" "$(dirname "$FM350_UDEV_RULE")"
  cat > "$FM350_LINK_FILE" <<EOF
[Match]
MACAddress=$mac
Driver=rndis_host

[Link]
NamePolicy=
Name=$FM350_STABLE_IF
EOF
  chmod 0644 "$FM350_LINK_FILE"

  # von udev gestartet will be.
  cat > "$FM350_RECOVERY_SERVICE_PATH" <<EOF
[Unit]
Description=FM350-RNDIS check after boot or USB re-enumeration and repair when required
After=vyos-router.service modem-connect.service systemd-udev-settle.service
Wants=modem-connect.service
Requires=vyos-router.service
ConditionPathExists=$CONFIG_FILE
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=${SELF_PATH} --recover
TimeoutStartSec=900
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$FM350_RECOVERY_SERVICE_PATH"

  cat > "$FM350_UDEV_RULE" <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="7126", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="7127", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="add", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7126", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="add", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7127", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="change", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7126", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="change", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7127", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="move", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7126", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
ACTION=="move", SUBSYSTEM=="net", ATTRS{idVendor}=="0e8d", ATTRS{idProduct}=="7127", TAG+="systemd", ENV{SYSTEMD_WANTS}+="modem-connect-recover.service"
EOF
  chmod 0644 "$FM350_UDEV_RULE"

  systemctl daemon-reload
  systemctl enable modem-connect-recover.service >/dev/null 2>&1 || true
  udevadm control --reload-rules 2>/dev/null || true

  if [ "$current" != "$FM350_STABLE_IF" ] && ! ip link show "$FM350_STABLE_IF" >/dev/null 2>&1; then
    ip link set dev "$current" down 2>/dev/null || true
    if ip link set dev "$current" name "$FM350_STABLE_IF" 2>/dev/null; then
      FM350_RNDIS_IF="$FM350_STABLE_IF"
      ip link set dev "$FM350_RNDIS_IF" up 2>/dev/null || true
      log "FM350-RNDIS-Interface dauerhaft auf $FM350_RNDIS_IF festgelegt."
    else
      ip link set dev "$current" up 2>/dev/null || true
      warn "Current FM350 interface $current could not be renamed to $FM350_STABLE_IF immediately; the .link file will apply after the next USB reset/boot."
    fi
  elif ip link show "$FM350_STABLE_IF" >/dev/null 2>&1; then
    if fm350_path_belongs "/sys/class/net/$FM350_STABLE_IF/device"; then
      FM350_RNDIS_IF="$FM350_STABLE_IF"
    else
      warn "Stabiler FM350-Name $FM350_STABLE_IF is already used by another interface; temporarily using $current."
    fi
  fi
}

detect_fm350_transport() {
  local d usb="" pcie="" vendor product
  FM350_AVAILABLE=0
  FM350_TRANSPORT=""
  FM350_SYS=""
  FM350_USB_ID=""
  FM350_RNDIS_IF=""

  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    vendor="$(cat "$d/idVendor" 2>/dev/null || true)"
    product="$(cat "$d/idProduct" 2>/dev/null || true)"
    [ "$vendor" = 0e8d ] || continue
    case "$product" in 7126|7127) usb="$(readlink -f "$d")"; FM350_USB_ID="0e8d:$product"; break ;; esac
  done
  for d in /sys/bus/pci/devices/*; do
    [ -f "$d/vendor" ] && [ -f "$d/device" ] || continue
    [ "$(cat "$d/vendor" 2>/dev/null)" = 0x14c3 ] || continue
    [ "$(cat "$d/device" 2>/dev/null)" = 0x4d75 ] || continue
    pcie="$(readlink -f "$d")"
    break
  done

  case "$TRANSPORT_MODE" in
    pcie) [ -n "$pcie" ] || return 1; FM350_TRANSPORT=pcie; FM350_SYS="$pcie" ;;
    usb)  [ -n "$usb" ] || return 1; FM350_TRANSPORT=usb; FM350_SYS="$usb" ;;
    auto)
      if [ -n "$pcie" ]; then
        FM350_TRANSPORT=pcie; FM350_SYS="$pcie"
        [ -n "$usb" ] && warn "FM350 was detected over both PCIe and USB; auto prefers PCIe"
      elif [ -n "$usb" ]; then
        FM350_TRANSPORT=usb; FM350_SYS="$usb"
      else
        return 1
      fi
      ;;
  esac

  FM350_AVAILABLE=1
  MODEM_TRANSPORT="$FM350_TRANSPORT"
  MODEM_MODEL="Fibocom FM350-GL"
  MODEM_DEVICE="$FM350_SYS"
  if [ "$FM350_TRANSPORT" = pcie ]; then
    MODEM_PCI_ID="14c3:4d75"
    MODEM_DRIVER="$(basename "$(readlink -f "$FM350_SYS/driver" 2>/dev/null)" 2>/dev/null || true)"
    MODEM_DEVICE_ID="fm350-pcie-$(basename "$FM350_SYS")"
  else
    MODEM_PCI_ID="$FM350_USB_ID"
    MODEM_DRIVER="usb"
    MODEM_DEVICE_ID="fm350-usb-${FM350_USB_ID//:/-}-$(basename "$FM350_SYS")"
    fm350_set_usb_power
    udevadm settle --timeout=20 2>/dev/null || true
    fm350_find_rndis_iface || true
    [ -n "$FM350_RNDIS_IF" ] && fm350_install_rndis_recovery
  fi
  MODEM_KEY="$MODEM_DEVICE_ID"
  log "FM350-transport automatically detected: $FM350_TRANSPORT, device $(basename "$FM350_SYS")${FM350_RNDIS_IF:+, RNDIS $FM350_RNDIS_IF}"
  return 0
}

fm350_recovery_detect_usb_iface() {
  local d vendor product
  FM350_AVAILABLE=0
  FM350_TRANSPORT=""
  FM350_SYS=""
  FM350_USB_ID=""
  FM350_RNDIS_IF=""
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    vendor="$(cat "$d/idVendor" 2>/dev/null || true)"
    product="$(cat "$d/idProduct" 2>/dev/null || true)"
    [ "$vendor" = 0e8d ] || continue
    case "$product" in
      7126|7127)
        FM350_AVAILABLE=1
        FM350_TRANSPORT=usb
        FM350_SYS="$(readlink -f "$d")"
        FM350_USB_ID="0e8d:$product"
        break
        ;;
    esac
  done
  [ "$FM350_AVAILABLE" -eq 1 ] || return 1
  fm350_set_usb_power
  fm350_find_rndis_iface
}

fm350_recovery_path_ok() {
  local iface="$1" ip4 route_line
  [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1 || return 1
  ip4="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  [ -n "$ip4" ] || return 1

  # zweite Default-Route for WWAN. Eine forced routensuche plus gebundener Ping
  route_line="$(ip -4 route get 1.1.1.1 oif "$iface" 2>/dev/null | head -1 || true)"
  [ -n "$route_line" ] || return 1
  /bin/ping -n -I "$iface" -c 3 -W 2 1.1.1.1 >/dev/null 2>&1
}

fm350_recover_after_usb_event() (
  local state substate step saved_if iface found=0
  log "FM350 recovery started: boot/udev trigger; checking USB device, RNDIS port, IP, route, and data path."
  mkdir -p "$(dirname "$FM350_RECOVERY_LOCK")"
  if ! mkdir "$FM350_RECOVERY_LOCK" 2>/dev/null; then
    log "FM350 recovery is already running; ignoring the additional event."
    exit 0
  fi
  trap 'rmdir "$FM350_RECOVERY_LOCK" 2>/dev/null || true' EXIT

  saved_if="$(config_get FM350_STABLE_IF)"
  if [[ "$saved_if" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; then FM350_STABLE_IF="$saved_if"; fi

  for step in $(seq 1 90); do
    state="$(systemctl show modem-connect.service -p ActiveState --value 2>/dev/null || true)"
    substate="$(systemctl show modem-connect.service -p SubState --value 2>/dev/null || true)"
    case "$state:$substate" in
      activating:*|deactivating:*) [ "$step" -eq 1 ] && log "The normal modem connection service is still running; recovery is waiting."; sleep 1 ;;
      *) break ;;
    esac
  done
  state="$(systemctl show modem-connect.service -p ActiveState --value 2>/dev/null || true)"
  substate="$(systemctl show modem-connect.service -p SubState --value 2>/dev/null || true)"
  case "$state:$substate" in
    activating:*|deactivating:*) warn "The normal connection service is still transitioning after 90 seconds; recovery will not run in parallel."; exit 0 ;;
  esac

  ensure_modem_device_discovery
  load_known_drivers
  for step in $(seq 1 120); do
    if fm350_recovery_detect_usb_iface >/dev/null 2>&1; then found=1; break; fi
    [ $((step % 10)) -ne 0 ] || log "FM350 recovery is waiting for the complete USB/RNDIS device ($step/120s)."
    sleep 1
  done
  [ "$found" -eq 1 ] || { warn "The FM350 USB device was not fully detected with an RNDIS interface within 120 seconds"; exit 1; }
  iface="$FM350_RNDIS_IF"

  if fm350_recovery_path_ok "$iface"; then
    log "FM350-Recovery: $iface has an IP address and a working bound data path; no restart is required."
    exit 0
  fi

  warn "FM350-Recovery: Data path through $iface is not working; unlock and connection will be rebuilt in a controlled manner."
  rm -f "$FM350_AT_CACHE" "$UNLOCK_STATE_DIR"/*.fm350-fcc.ok
  systemctl reset-failed modem-unlock.service modem-connect.service 2>/dev/null || true
  systemctl restart modem-unlock.service || { warn "modem-unlock.service could not be restarted"; exit 1; }
  systemctl restart modem-connect.service || { warn "modem-connect.service could not be restarted"; exit 1; }

  for step in $(seq 1 120); do
    fm350_recovery_detect_usb_iface >/dev/null 2>&1 || true
    iface="$FM350_RNDIS_IF"
    if [ -n "$iface" ] && fm350_recovery_path_ok "$iface"; then
      log "FM350-Recovery successful: Data path through $iface restored."
      exit 0
    fi
    [ $((step % 10)) -ne 0 ] || log "FM350-Recovery wartet auf restoreden Datenpfad ($step/120s)."
    sleep 1
  done
  warn "FM350-Recovery finished, but the data path through ${iface:-unknown} ist is still impaired"
  exit 1
)

fm350_serial_raw() {
  local dev="$1" command="$2" seconds="${3:-8}"
  python3 - "$dev" "$command" "$seconds" <<'PY'
import os, sys, time, select, termios

dev, command, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
fd = None
try:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[4] = termios.B115200
    attrs[5] = termios.B115200
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    os.write(fd, (command + "\r").encode("ascii", "replace"))
    deadline = time.monotonic() + seconds
    buf = b""
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], min(0.25, max(0.0, deadline-time.monotonic())))
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if not chunk:
            continue
        buf += chunk
        text = buf.decode(errors="replace").replace("\r", "")
        lines = [line.strip() for line in text.split("\n") if line.strip()]
        if any(line == "OK" or line == "ERROR" or line.startswith("+CME ERROR") for line in lines):
            break
    text = buf.decode(errors="replace").replace("\r", "")
    seen = []
    for line in text.split("\n"):
        line = line.strip()
        if line and (not seen or seen[-1] != line):
            seen.append(line)
    print("\n".join(seen))
    if not buf:
        sys.exit(2)
finally:
    if fd is not None:
        os.close(fd)
PY
}

fm350_probe_at_device() {
  local dev="$1" out
  [ -c "$dev" ] || return 1
  out="$(fm350_serial_raw "$dev" ATI 5 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -qi 'FM350-GL'
}

fm350_find_at_port() {
  local dev path step cached tried=" "
  [ "$FM350_AVAILABLE" -eq 1 ] || return 1

  if [ -n "$FM350_AT_DEV" ] && [ -c "$FM350_AT_DEV" ]; then
    AT_PORT="$(basename "$FM350_AT_DEV")"
    return 0
  fi

  if [ "$FM350_TRANSPORT" = usb ]; then
    timeout --signal=TERM --kill-after=5s 30s systemctl stop ModemManager.service >/dev/null 2>&1 || true
  fi

  # Der Unlock-Dienst schreibt den gefundenen Port nach /run. Der nachfolgende
  cached="$(sed -n 's/^AT_DEV=//p' "$FM350_AT_CACHE" 2>/dev/null | head -1)"
  if [ -n "$cached" ] && [ -c "$cached" ]; then
    if [ "$FM350_TRANSPORT" = pcie ]; then
      path="/sys/class/wwan/$(basename "$cached")/device"
    else
      path="/sys/class/tty/$(basename "$cached")/device"
    fi
    if fm350_path_belongs "$path" && fm350_probe_at_device "$cached"; then
      FM350_AT_DEV="$cached"
      AT_PORT="$(basename "$FM350_AT_DEV")"
      log "FM350-AT-Port loaded from runtime cache: $FM350_AT_DEV"
      return 0
    fi
  fi

  for step in $(seq 1 45); do
    if [ "$FM350_TRANSPORT" = pcie ]; then
      if [ -n "$AT_PORT" ] && [ -c "/dev/$AT_PORT" ] && fm350_probe_at_device "/dev/$AT_PORT"; then FM350_AT_DEV="/dev/$AT_PORT"; break; fi
      for dev in /dev/wwan*at*; do
        [ -c "$dev" ] || continue
        path="/sys/class/wwan/$(basename "$dev")/device"
        fm350_path_belongs "$path" || continue
        if fm350_probe_at_device "$dev"; then FM350_AT_DEV="$dev"; break 2; fi
      done
    else
      for dev in /dev/ttyUSB3 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB4 /dev/ttyUSB5 /dev/ttyUSB6 /dev/ttyUSB0 /dev/ttyUSB*; do
        [ -c "$dev" ] || continue
        case "$tried" in *" $dev "*) continue ;; esac
        tried="${tried}${dev} "
        path="/sys/class/tty/$(basename "$dev")/device"
        fm350_path_belongs "$path" || continue
        if fm350_probe_at_device "$dev"; then FM350_AT_DEV="$dev"; break 2; fi
      done
    fi
    [ $((step % 5)) -ne 0 ] || log "Waiting for the FM350 AT port ($((step*2))/90 Sekunden)"
    sleep 2
  done
  [ -n "$FM350_AT_DEV" ] || return 1
  AT_PORT="$(basename "$FM350_AT_DEV")"
  mkdir -p "$(dirname "$FM350_AT_CACHE")"
  printf 'AT_DEV=%s\n' "$FM350_AT_DEV" > "$FM350_AT_CACHE"
  chmod 600 "$FM350_AT_CACHE"
  log "FM350-AT port detected: $FM350_AT_DEV"
  return 0
}

fm350_at_cmd() {
  local command="$1" seconds="${2:-8}" output line
  [ -n "$FM350_AT_DEV" ] || fm350_find_at_port || return 1
  output="$(fm350_serial_raw "$FM350_AT_DEV" "$command" "$seconds" 2>&1)" || true
  while IFS= read -r line; do [ -n "$line" ] && log "AT[$FM350_AT_DEV] < $line"; done <<< "$output"
  printf '%s\n' "$output"
}

fm350_query_identity() {
  local out imei
  [ -n "$FM350_AT_DEV" ] || fm350_find_at_port || return 1
  out="$(fm350_at_cmd 'AT+CGSN' 6 || true)"
  imei="$(printf '%s\n' "$out" | grep -Eo '(^|[^0-9])[0-9]{15}([^0-9]|$)' | grep -Eo '[0-9]{15}' | head -1)"
  if [ -n "$imei" ]; then
    FM350_IMEI="$imei"
    MODEM_EQUIPMENT_ID="$imei"
    MODEM_KEY="$imei"
  fi
  return 0
}

start_mm() {
  have_cmd mmcli || return 1
  if ! systemctl is-active --quiet ModemManager; then
    systemctl enable --now ModemManager >/dev/null 2>&1 || return 1
    sleep 3
  fi
}

MODEM=""
MINFO=""
MODEM_DEVICE_ID=""
MODEM_EQUIPMENT_ID=""
MODEM_DEVICE=""
MODEM_DRIVER=""
MODEM_MODEL=""
MODEM_PCI_ID=""
MODEM_UNLOCK_KIND="none"
MODEM_KEY="unknown"
PRIMARY_PORT=""
QMI_PORT=""
MBIM_PORT=""
AT_PORT=""
NET_PORTS=""
declare -a ALL_MODEM_IDS

mm_port_list() {
  local type="$1"
  printf '%s\n' "$MINFO" | sed -n "s/^[^:]*ports\\.value\\[[0-9]\\+\\][[:space:]]*:[[:space:]]*\\([^[:space:]]\\+\\)[[:space:]]*(${type}).*/\\1/p"
}

discover_mm_modem() {
  local -a ids infos models device_ids equipment_ids primary_ports
  local id info model did eid pport choice selected_index i
  start_mm || return 1
  mapfile -t ids < <(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]\+\).*#\1#p')
  if [ "${#ids[@]}" -eq 0 ]; then
    log "Waiting up to ${MODEM_DISCOVERY_WAIT}s for dynamic modem/port detection..."
    for _ in $(seq 1 "$MODEM_DISCOVERY_WAIT"); do
      sleep 1
      mapfile -t ids < <(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]\+\).*#\1#p')
      [ "${#ids[@]}" -gt 0 ] && break
    done
  fi
  [ "${#ids[@]}" -gt 0 ] || return 1

  ALL_MODEM_IDS=("${ids[@]}")
  for id in "${ids[@]}"; do
    info="$(mmcli -m "$id" -K 2>/dev/null || true)"
    infos+=("$info")
    model="$(printf '%s\n' "$info" | kv_get modem.generic.model)"
    did="$(printf '%s\n' "$info" | kv_get modem.generic.device-identifier)"
    [ -n "$did" ] || did="$(printf '%s\n' "$info" | kv_get modem.generic.device-id)"
    # IMEI/equipment ID is significantly more stable for persistent selection.
    eid="$(printf '%s\n' "$info" | kv_get modem.generic.equipment-identifier)"
    [ -n "$eid" ] || eid="$(printf '%s\n' "$info" | kv_get modem.3gpp.imei)"
    pport="$(printf '%s\n' "$info" | kv_get modem.generic.primary-port)"
    models+=("${model:-unknown}")
    device_ids+=("$did")
    equipment_ids+=("$eid")
    primary_ports+=("${pport:-unknown}")
  done

  selected_index=""
  if [ -n "$MODEM_EQUIPMENT_ID_REQUEST" ]; then
    for i in "${!ids[@]}"; do
      [ "${equipment_ids[$i]}" = "$MODEM_EQUIPMENT_ID_REQUEST" ] && selected_index="$i" && break
    done
    if [ -z "$selected_index" ] && [ "${#ids[@]}" -eq 1 ]; then
      warn "The saved equipment ID was not detected; using the only detected modem and updating the cache."
      selected_index=0
    fi
    [ -n "$selected_index" ] || return 1
  elif [ -n "$MODEM_DEVICE_ID_REQUEST" ]; then
    for i in "${!ids[@]}"; do
      [ "${device_ids[$i]}" = "$MODEM_DEVICE_ID_REQUEST" ] && selected_index="$i" && break
    done
    if [ -z "$selected_index" ] && [ "${#ids[@]}" -eq 1 ]; then
      warn "The ModemManager device ID changed; using the only detected modem and migrating to IMEI/equipment ID."
      selected_index=0
    fi
    [ -n "$selected_index" ] || return 1
  elif [ -n "$MODEM_REQUEST" ]; then
    for i in "${!ids[@]}"; do
      [ "${ids[$i]}" = "$MODEM_REQUEST" ] && selected_index="$i" && break
    done
    [ -n "$selected_index" ] || return 1
  elif [ "$SERVICE_RUN" -eq 0 ] && [ -t 0 ]; then
    echo ""
    echo "Gefundene Modems:"
    for i in "${!ids[@]}"; do
      printf '  %s) Modem/%s  %-22s  Port %-14s  IMEI/Equipment %s  MM-ID %s\n' "$((i+1))" "${ids[$i]}" "${models[$i]}" "${primary_ports[$i]}" "${equipment_ids[$i]:-unknown}" "${device_ids[$i]:-unknown}"
    done
    if [ "${#ids[@]}" -gt 1 ]; then
      read -rp "Select modem [1]: " choice
      choice="${choice:-1}"
      [[ "$choice" =~ ^[0-9]+$ ]] || return 1
      selected_index=$((choice-1))
      [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "${#ids[@]}" ] || return 1
    else
      selected_index=0
    fi
  else
    selected_index=0
  fi

  MODEM="${ids[$selected_index]}"
  MINFO="${infos[$selected_index]}"
  MODEM_DEVICE_ID="${device_ids[$selected_index]}"
  MODEM_EQUIPMENT_ID="${equipment_ids[$selected_index]}"
  MODEM_MODEL="${models[$selected_index]}"
  PRIMARY_PORT="${primary_ports[$selected_index]}"
  MODEM_DEVICE="$(printf '%s\n' "$MINFO" | kv_get modem.generic.device)"
  QMI_PORT="$(mm_port_list qmi | head -1)"
  MBIM_PORT="$(mm_port_list mbim | head -1)"
  AT_PORT="$(mm_port_list at | head -1)"
  NET_PORTS="$(mm_port_list net)"
  MODEM_DRIVER=""
  MODEM_PCI_ID=""
  if [ -n "$MODEM_DEVICE" ] && [ -e "$MODEM_DEVICE/driver" ]; then
    MODEM_DRIVER="$(basename "$(readlink -f "$MODEM_DEVICE/driver")" 2>/dev/null || true)"
  fi
  if [ -n "$MODEM_DEVICE" ] && [ -r "$MODEM_DEVICE/vendor" ] && [ -r "$MODEM_DEVICE/device" ]; then
    MODEM_PCI_ID="$(cat "$MODEM_DEVICE/vendor" 2>/dev/null | sed s/^0x//):$(cat "$MODEM_DEVICE/device" 2>/dev/null | sed s/^0x//)"
  fi
  MODEM_KEY="${MODEM_EQUIPMENT_ID:-${MODEM_DEVICE_ID:-${MODEM_DEVICE:-modem-${MODEM}}}}"
  case "$(readlink -f "$MODEM_DEVICE" 2>/dev/null || true)" in
    */usb*/*) MODEM_TRANSPORT=usb ;;
    */pci*/*) MODEM_TRANSPORT=pcie ;;
    *) MODEM_TRANSPORT=unknown ;;
  esac
  return 0
}

scan_control_device() {
  local protocol="$1" dev
  if [ -n "$CONTROL_DEVICE_REQUEST" ]; then
    [ -e "$CONTROL_DEVICE_REQUEST" ] && printf '%s\n' "$CONTROL_DEVICE_REQUEST"
    return
  fi
  if [ "$protocol" = qmi ] && [ -n "$QMI_PORT" ] && [ -e "/dev/$QMI_PORT" ]; then
    printf '/dev/%s\n' "$QMI_PORT"
    return
  fi
  if [ "$protocol" = mbim ] && [ -n "$MBIM_PORT" ] && [ -e "/dev/$MBIM_PORT" ]; then
    printf '/dev/%s\n' "$MBIM_PORT"
    return
  fi
  if [ "$protocol" = qmi ]; then
    for dev in /dev/wwan*qmi* /dev/cdc-wdm*; do
      [ -e "$dev" ] || continue
      if have_cmd qmicli && qmicli -d "$dev" --device-open-proxy --device-open-qmi --get-service-version-info >/dev/null 2>&1; then
        printf '%s\n' "$dev"
        return
      fi
    done
  else
    for dev in /dev/wwan*mbim* /dev/cdc-wdm*; do
      [ -e "$dev" ] || continue
      if have_cmd mbimcli && mbimcli -d "$dev" --device-open-proxy --query-device-caps >/dev/null 2>&1; then
        printf '%s\n' "$dev"
        return
      fi
    done
  fi
}

net_driver() {
  local iface="$1"
  if have_cmd ethtool; then
    ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}'
  fi
}

select_net_iface() {
  local protocol="$1" ctrl="$2" candidate driver base result
  if [ -n "$NET_IF_REQUEST" ]; then
    ip link show "$NET_IF_REQUEST" >/dev/null 2>&1 && printf '%s\n' "$NET_IF_REQUEST"
    return
  fi
  if [ -n "$NET_PORTS" ]; then
    if [ "$protocol" = qmi ]; then
      candidate="$(printf '%s\n' "$NET_PORTS" | grep '^mhi_hwip' | head -1)"
      [ -n "$candidate" ] || candidate="$(printf '%s\n' "$NET_PORTS" | grep '^wwan' | head -1)"
      [ -n "$candidate" ] || candidate="$(printf '%s\n' "$NET_PORTS" | head -1)"
    else
      candidate="$(printf '%s\n' "$NET_PORTS" | grep '^wwan' | head -1)"
      [ -n "$candidate" ] || candidate="$(printf '%s\n' "$NET_PORTS" | grep '^mhi_hwip' | head -1)"
      [ -n "$candidate" ] || candidate="$(printf '%s\n' "$NET_PORTS" | head -1)"
    fi
    [ -n "$candidate" ] && ip link show "$candidate" >/dev/null 2>&1 && printf '%s\n' "$candidate" && return
  fi
  if [ "$protocol" = qmi ] && have_cmd qmicli && [ -n "$ctrl" ]; then
    result="$(qmicli -d "$ctrl" --device-open-proxy --get-wwan-iface 2>/dev/null | sed -n "s/.*WWAN iface: '\([^']*\)'.*/\1/p" | head -1)"
    [ -n "$result" ] && ip link show "$result" >/dev/null 2>&1 && printf '%s\n' "$result" && return
  fi
  base="$(basename "$ctrl")"
  for candidate in /sys/class/usbmisc/"$base"/device/net/* /sys/class/wwan/"$base"/device/net/*; do
    [ -d "$candidate" ] || continue
    printf '%s\n' "$(basename "$candidate")"
    return
  done
  for candidate in $(ls /sys/class/net 2>/dev/null); do
    [ "$candidate" = lo ] && continue
    [ "$candidate" = "$AP_IF" ] && continue
    driver="$(net_driver "$candidate")"
    case "$protocol:$driver" in
      qmi:qmi_wwan|qmi:mhi_net|mbim:cdc_mbim|mbim:mhi_net) printf '%s\n' "$candidate"; return ;;
    esac
  done
}

find_dhcp_modem_iface() {
  local iface driver
  if [ -n "$NET_IF_REQUEST" ]; then
    ip link show "$NET_IF_REQUEST" >/dev/null 2>&1 && printf '%s\n' "$NET_IF_REQUEST"
    return
  fi
  while read -r iface; do
    [ -n "$iface" ] || continue
    [ "$iface" = lo ] && continue
    [ "$iface" = "$AP_IF" ] && continue
    driver="$(net_driver "$iface")"
    case "$driver" in cdc_ether|cdc_ncm|huawei_cdc_ncm|rndis_host|rndis_wlan|cdc_mbim) printf '%s\n' "$iface"; return ;; esac
  done < <(ls /sys/class/net 2>/dev/null)
}

probe_backends() {
  local qdev mdev dif driver
  echo ""
  echo "=== Modem-/Backend-Pruefung ==="
  if [ "$FM350_AVAILABLE" -eq 1 ]; then echo "Transport: ${MODEM_TRANSPORT:-unknown} (FM350 detected)"; else echo "Transport: ${MODEM_TRANSPORT:-unknown}"; fi
  if [ -n "$MODEM" ]; then
    echo "ModemManager: JA (Modem/$MODEM, Modell ${MODEM_MODEL:-unknown}, primary port ${PRIMARY_PORT:-unknown})"
  else
    echo "ModemManager: NO (no managed modem found)"
  fi
  qdev="$(scan_control_device qmi | head -1)"
  if [ -n "$qdev" ]; then
    echo "Native QMI: JA ($qdev)"
  elif have_cmd qmicli; then
    echo "Native QMI: no working QMI control port detected"
  else
    echo "Native QMI: qmicli is missing"
  fi
  mdev="$(scan_control_device mbim | head -1)"
  if [ -n "$mdev" ]; then
    echo "Native MBIM: JA ($mdev)"
  elif have_cmd mbimcli; then
    echo "Native MBIM: no working MBIM control port detected"
  else
    echo "Native MBIM: mbimcli is missing"
  fi
  if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ]; then
    fm350_find_rndis_iface || true
    if [ -n "$FM350_RNDIS_IF" ]; then echo "FM350 AT-RNDIS: JA ($FM350_RNDIS_IF, rndis_host)"; else echo "FM350 AT-RNDIS: NO"; fi
  fi
  dif="$(find_dhcp_modem_iface | head -1)"
  if [ -n "$dif" ]; then
    driver="$(net_driver "$dif")"
    echo "Ethernet/DHCP: JA ($dif, driver ${driver:-unknown})"
  else
    echo "Ethernet/DHCP: no typical ECM/NCM/RNDIS interface detected"
  fi
  echo ""
  echo "Recommendation: use auto for normal operation; use qmi/mbim only as an intentional alternative or for diagnostics."
}

fm350_unlock() {
  local raw chal resp out attempt
  [ "$FM350_AVAILABLE" -eq 1 ] || [ "$MODEM_DRIVER" = mtk_t7xx ] || return 0
  if [ "$FM350_AVAILABLE" -ne 1 ]; then
    FM350_AVAILABLE=1
    FM350_TRANSPORT=pcie
    MODEM_TRANSPORT=pcie
    FM350_SYS="$MODEM_DEVICE"
  fi
  fm350_find_at_port || { warn "FM350 detected, but no responsive AT port was found"; return 1; }
  fm350_query_identity || true
  log "FM350 through $FM350_TRANSPORT detected - running FCC unlock through $FM350_AT_DEV aus."
  for attempt in 1 2 3 4 5; do
    raw="$(fm350_at_cmd 'AT+GTFCCLOCKGEN' 10 || true)"
    chal="$(printf '%s\n' "$raw" | grep -io '0x[0-9a-f]\+' | head -1)"
    if [ -z "$chal" ]; then
      out="$(fm350_at_cmd 'AT+GTFCCLOCKVER?' 6 || true)"
      if printf '%s\n' "$out" | grep -q '+GTFCCLOCKVER: 1'; then
        log "FM350-FCC-Unlock war bereits aktiv."
        return 0
      fi
      sleep 1
      continue
    fi
    resp="$(python3 - "$chal" "$FCC_VENDOR_HASH" <<'PY'
import hashlib, sys
challenge = int(sys.argv[1], 16)
vendor = sys.argv[2]
payload = bytes.fromhex(f"{challenge:08x}" + vendor[:8])
print(int(hashlib.sha256(payload).hexdigest()[:8], 16))
PY
)"
    out="$(fm350_at_cmd "AT+GTFCCLOCKVER=$resp" 12 || true)"
    if printf '%s\n' "$out" | grep -q '+GTFCCLOCKVER: 1'; then
      log "FM350-FCC unlock successful."
      return 0
    fi
    sleep 1
  done
  warn "FM350-FCC unlock was not confirmed"
  return 1
}

detect_modem_unlock_kind() {
  if [ "$FM350_AVAILABLE" -eq 1 ]; then printf '%s\n' fm350-fcc; return 0; fi
  case "$MODEM_DRIVER:$MODEM_PCI_ID:$MODEM_MODEL" in
    mtk_t7xx:*) printf '%s\n' fm350-fcc ;;
    iosm:8086:7560:*|iosm:*:*8086:7560*) printf '%s\n' xmm7560-fcc ;;
    *) printf '%s\n' none ;;
  esac
}

unlock_marker_path() {
  mkdir -p "$UNLOCK_STATE_DIR"
  printf '%s/%s.%s.ok\n' "$UNLOCK_STATE_DIR" "$(safe_key "$MODEM_KEY")" "$(safe_key "$MODEM_UNLOCK_KIND")"
}

xmm7560_unlock() {
  local state power atdev target_equipment target_device old_equipment_request old_device_request
  local line n set_out cfun_out unlock_ok=0 marker step

  MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
  state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
  power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"
  if [ "$power" = on ]; then
    log "Intel XMM7560/L850/L860 is already in radio state ON; no additional FCC unlock is required."
    return 0
  fi

  AT_PORT="$(mm_port_list at | grep 'at1$' | head -1)"
  [ -n "$AT_PORT" ] || AT_PORT="$(mm_port_list at | tail -1)"
  [ -n "$AT_PORT" ] && [ -e "/dev/$AT_PORT" ] || { warn "XMM7560 detected, but no AT port is available for FCC unlock"; return 1; }
  atdev="/dev/$AT_PORT"
  target_equipment="$MODEM_EQUIPMENT_ID"
  target_device="$MODEM_DEVICE_ID"
  old_equipment_request="$MODEM_EQUIPMENT_ID_REQUEST"
  old_device_request="$MODEM_DEVICE_ID_REQUEST"

  log "Intel XMM7560/L850/L860 detected; running temporary FCC unlock through $atdev aus."
  timeout --signal=TERM --kill-after=5s 40s systemctl stop ModemManager.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet ModemManager.service; then
    warn "ModemManager could not be stopped cleanly for the XMM7560 unlock"
    systemctl start ModemManager.service >/dev/null 2>&1 || true
    return 1
  fi
  sleep 2

  if stty -F "$atdev" 115200 raw -echo -hupcl 2>/dev/null && exec 8<>"$atdev"; then
    xmm_atcmd() {
      local command="$1" text=""
      printf '%s\r' "$command" >&8
      for n in $(seq 1 20); do
        if IFS= read -r -t 1 line <&8; then
          line="$(printf '%s' "$line" | tr -d '\r')"
          [ -n "$line" ] && text="${text}${line}\n"
          echo "$line" | grep -qE '^(OK|ERROR|\+CME ERROR)' && break
        fi
      done
      printf '%b' "$text"
    }
    set_out="$(xmm_atcmd 'at@nvm:fix_cat_fcclock.fcclock_mode=0')"
    printf '%s\n' "$set_out"
    cfun_out="$(xmm_atcmd 'AT+CFUN=1')"
    printf '%s\n' "$cfun_out"
    if printf '%s\n' "$set_out" | grep -qx 'OK' && printf '%s\n' "$cfun_out" | grep -qx 'OK'; then
      unlock_ok=1
    fi
    exec 8>&-
    unset -f xmm_atcmd 2>/dev/null || true
  else
    warn "AT port $atdev could not be opened"
  fi

  systemctl start ModemManager.service >/dev/null 2>&1 || { warn "ModemManager could not be started after the XMM7560 unlock"; return 1; }
  [ "$unlock_ok" -eq 1 ] || { warn "XMM7560-FCC-Unlock was not confirmed by the modem"; return 1; }

  sleep 3
  MODEM_REQUEST=""
  MODEM_EQUIPMENT_ID_REQUEST="$target_equipment"
  MODEM_DEVICE_ID_REQUEST="$target_device"
  discover_mm_modem || { MODEM_EQUIPMENT_ID_REQUEST="$old_equipment_request"; MODEM_DEVICE_ID_REQUEST="$old_device_request"; warn "XMM7560 was not detected again after unlock"; return 1; }

  for step in $(seq 1 30); do
    MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
    state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
    power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"
    if [ "$power" = on ]; then
      log "XMM7560-FCC-Unlock confirmed: state ${state:-unknown}, radio ON."
      return 0
    fi
    sleep 1
  done
  warn "XMM7560 blieb nach dem Unlock im radiozustand ${power:-unknown}"
  return 1
}

perform_modem_unlock() {
  local marker power
  MODEM_UNLOCK_KIND="$(detect_modem_unlock_kind)"
  if [ "$MODEM_UNLOCK_KIND" = fm350-fcc ] && [ "$FM350_AVAILABLE" -eq 1 ]; then
    fm350_find_at_port || return 1
    fm350_query_identity || true
  fi
  marker="$(unlock_marker_path)"
  case "$MODEM_UNLOCK_KIND" in
    fm350-fcc)
      if [ -s "$marker" ]; then
        log "FM350-FCC-Unlock was already confirmed during this boot."
        return 0
      fi
      fm350_unlock || return 1
      printf 'KIND=%s\nMODEM_KEY=%s\n' "$MODEM_UNLOCK_KIND" "$MODEM_KEY" > "$marker"
      ;;
    xmm7560-fcc)
      MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
      power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"
      if [ -s "$marker" ] && [ "$power" = on ]; then
        log "XMM7560-FCC-Unlock was already confirmed during this boot."
        return 0
      fi
      xmm7560_unlock || return 1
      printf 'KIND=%s\nMODEM_KEY=%s\n' "$MODEM_UNLOCK_KIND" "$MODEM_KEY" > "$marker"
      ;;
    none)
      log "No additional FCC unlock is defined for this modem."
      ;;
    *)
      warn "Unbekannter Unlock-Typ: $MODEM_UNLOCK_KIND"
      return 1
      ;;
  esac
  chmod 600 "$marker" 2>/dev/null || true
  return 0
}

choose_apn() {
  if [ -n "$APN_ARG" ]; then
    APN="$APN_ARG"
  elif [ -s "$APN_CACHE" ]; then
    CACHED_APN="$(cat "$APN_CACHE")"
    if [ -t 0 ]; then
      read -rp "APN [$CACHED_APN] (Enter behaelt den Wert): " APN_INPUT
      APN="${APN_INPUT:-$CACHED_APN}"
    else
      APN="$CACHED_APN"
    fi
  else
    if [ -t 0 ]; then
      read -rp "APN [$DEFAULT_APN] (Enter behaelt den Wert): " APN_INPUT
      APN="${APN_INPUT:-$DEFAULT_APN}"
    else
      APN="$DEFAULT_APN"
    fi
  fi
  [ -n "$APN" ] || die "APN ist leer"
  printf '%s\n' "$APN" > "$APN_CACHE"
  chmod 600 "$APN_CACHE"
}

run_dhcp() {
  local iface="$1"
  ip link set "$iface" up
  ip addr flush dev "$iface" scope global 2>/dev/null || true
  if have_cmd dhclient; then
    dhclient -4 -1 "$iface"
  elif have_cmd udhcpc; then
    udhcpc -n -q -i "$iface"
  else
    die "DHCP erforderlich, but weder dhclient noch udhcpc ist installiert"
  fi
}

netmask_to_prefix() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    print(ipaddress.IPv4Network("0.0.0.0/" + sys.argv[1]).prefixlen)
except Exception:
    print("")
PY
}

NET_IF=""
IP_METHOD=""
IP=""
PREFIX=""
GATEWAY=""
MTU=""
BACKEND_USED=""
CONNECTED_BEARER=""
WWAN_CONNECTED=0
WIRED_CANDIDATE_AVAILABLE=0
WIRED_WAN_REQUEST="$WIRED_WAN"

early_wired_wan_candidate() {
  local candidate="$1" driver=""
  [ -n "$candidate" ] || return 1
  [ "$candidate" != "$AP_IF" ] && [ "$candidate" != lo ] || return 1
  ip link show "$candidate" >/dev/null 2>&1 || return 1
  case "$candidate" in eth*|en*) ;; *) return 1 ;; esac
  [ ! -e "/sys/class/net/$candidate/master" ] || return 1
  driver="$(net_driver "$candidate")"
  [ -n "$driver" ] || driver="$(basename "$(readlink -f "/sys/class/net/$candidate/device/driver" 2>/dev/null)" 2>/dev/null || true)"
  case "$driver" in rndis_host|rndis_wlan|cdc_ether|cdc_ncm|huawei_cdc_ncm|cdc_mbim|qmi_wwan|mhi_net|iosm) return 1 ;; esac
  return 0
}

detect_wired_wan_early() {
  local candidate path
  while read -r candidate; do
    early_wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); break}}')
  while read -r candidate; do
    early_wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
  done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}')
  if command -v /opt/vyatta/bin/vyatta-op-cmd-wrapper >/dev/null 2>&1; then
    while read -r candidate; do
      early_wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
    done < <(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null | awk '/^set interfaces ethernet [^ ]+ address / {gsub(/\047/,"",$4); print $4}' | awk '!seen[$0]++')
  fi
  for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    candidate="$(basename "$path")"
    early_wired_wan_candidate "$candidate" || continue
    [ "$(cat "$path/carrier" 2>/dev/null || true)" = 1 ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

prepare_wired_wan_early() {
  local ip4="" route=""
  WIRED_WAN_REQUEST="$WIRED_WAN"
  case "$WIRED_WAN" in
    auto) WIRED_WAN="$(detect_wired_wan_early 2>/dev/null || true)" ;;
    none) WIRED_WAN="" ;;
  esac
  [ "$WIRED_WAN_REQUEST" = auto ] && [ -n "$WIRED_WAN" ] && WIRED_WAN_REQUEST="$WIRED_WAN"
  [ -n "$WIRED_WAN" ] || { log "No wired WAN was detected/requested; continuing with cellular."; return 0; }
  if ! early_wired_wan_candidate "$WIRED_WAN"; then
    warn "Wired WAN $WIRED_WAN is not a usable standalone Ethernet interface; skipping Ethernet."
    WIRED_WAN=""
    return 0
  fi
  WIRED_CANDIDATE_AVAILABLE=1
  ip4="$(ip -4 -o addr show dev "$WIRED_WAN" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  route="$(ip -4 route show default dev "$WIRED_WAN" 2>/dev/null | head -1 || true)"
  if [ -n "$ip4" ] && [ -n "$route" ]; then
    log "Wired WAN is already operational: $WIRED_WAN, IPv4 $ip4, Route $route"
  else
    log "Wired WAN queued: $WIRED_WAN; DHCP, route distance, and NAT will be configured in the shared VyOS configuration session."
  fi
  return 0
}

bearer_ids() {
  local modem_id="${1:-$MODEM}"
  mmcli -m "$modem_id" -K 2>/dev/null | sed -n 's#^[^:]*bearers\.value\[[0-9]\+\][[:space:]]*:[[:space:]]*.*/Bearer/\([0-9]\+\).*#\1#p' | sort -nr
}

clean_modem_bearers() {
  local modem_id="$1" id
  mmcli_timed 20 -m "$modem_id" --simple-disconnect >/dev/null 2>&1 || true
  while read -r id; do
    [ -n "$id" ] || continue
    mmcli_timed 15 -m "$modem_id" --delete-bearer="/org/freedesktop/ModemManager1/Bearer/$id" >/dev/null 2>&1 || true
  done < <(bearer_ids "$modem_id")
}

disconnect_other_modems() {
  local id
  for id in "${ALL_MODEM_IDS[@]}"; do
    [ "$id" = "$MODEM" ] && continue
    clean_modem_bearers "$id"
  done
}

find_connected_bearer() {
  local id info connected bapn first=""
  while read -r id; do
    [ -n "$id" ] || continue
    info="$(mmcli -b "$id" -K 2>/dev/null || true)"
    connected="$(printf '%s\n' "$info" | kv_get bearer.status.connected)"
    [ "$connected" = yes ] || continue
    bapn="$(printf '%s\n' "$info" | kv_get bearer.properties.apn)"
    [ -n "$first" ] || first="$id"
    [ "$bapn" = "$APN" ] && { printf '%s\n' "$id"; return 0; }
  done < <(bearer_ids)
  [ -n "$first" ] && printf '%s\n' "$first"
}

delete_disconnected_bearers() {
  local id info connected
  while read -r id; do
    [ -n "$id" ] || continue
    info="$(mmcli -b "$id" -K 2>/dev/null || true)"
    connected="$(printf '%s\n' "$info" | kv_get bearer.status.connected)"
    [ "$connected" = yes ] && continue
    mmcli_timed 15 -m "$MODEM" --delete-bearer="/org/freedesktop/ModemManager1/Bearer/$id" >/dev/null 2>&1 || true
  done < <(bearer_ids)
}

mm_prefers_multiplex_none() {
  case "$MODEM_MODEL" in
    *RM505Q*|*RM500Q*|*RM520N*) return 0 ;;
  esac
  if echo "$PRIMARY_PORT" | grep -q 'qmi' && printf '%s\n' "$NET_PORTS" | grep -q '^mhi_hwip'; then
    return 0
  fi
  return 1
}

restart_mm_and_rediscover() {
  local target_equipment="$MODEM_EQUIPMENT_ID" target_device="$MODEM_DEVICE_ID"
  systemctl restart ModemManager >/dev/null 2>&1 || return 1
  sleep 4
  MODEM_REQUEST=""
  MODEM_EQUIPMENT_ID_REQUEST="$target_equipment"
  MODEM_DEVICE_ID_REQUEST="$target_device"
  discover_mm_modem || return 1
  return 0
}

auto_repair_mhi_once() {
  local target_equipment="$MODEM_EQUIPMENT_ID" target_device="$MODEM_DEVICE_ID"
  local bdf driver_dir state repair_ok=0

  [ "$AUTO_REPAIR" -eq 1 ] || return 1
  [ "$MODEM_DRIVER" = "mhi-pci-generic" ] || return 1
  [ -n "$MODEM_DEVICE" ] || return 1

  bdf="$(basename "$MODEM_DEVICE")"
  driver_dir="/sys/bus/pci/drivers/mhi-pci-generic"
  [ -e "$driver_dir/$bdf" ] || return 1

  warn "Multiplex state is blocked; running full RM505Q recovery for $bdf aus."

  # Wichtige Reihenfolge for das RM505Q:
  # Bearer bereinigen -> Disable -> Modem-Reset -> ModemManager stoppen
  mmcli_timed 20 -m "$MODEM" --simple-disconnect >/dev/null 2>&1 || true
  clean_modem_bearers "$MODEM"
  mmcli_timed 20 -m "$MODEM" --disable >/dev/null 2>&1 || true

  log "Resetting the RM505Q before the MHI rebind ..."
  mmcli_timed 30 -m "$MODEM" --reset >/dev/null 2>&1 || \
    warn "ModemManager reset was not confirmed; recovery will continue."
  sleep 5

  # ModemManager darf hier bewusst gestoppt will be. modem-connect.service
  systemctl stop ModemManager >/dev/null 2>&1 || true
  sleep 2

  if [ -e "$driver_dir/$bdf" ] && printf '%s' "$bdf" > "$driver_dir/unbind"; then
    sleep 4
    if printf '%s' "$bdf" > "$driver_dir/bind"; then
      repair_ok=1
    else
      warn "MHI bind for $bdf failed"
    fi
  else
    warn "MHI unbind for $bdf failed or device is no longer bound to the driver"
  fi

  have_cmd udevadm && udevadm settle || true
  [ "$repair_ok" -eq 1 ] && sleep 8

  systemctl restart ModemManager >/dev/null 2>&1 || return 1
  sleep 5
  [ "$repair_ok" -eq 1 ] || return 1

  MODEM_REQUEST=""
  MODEM_EQUIPMENT_ID_REQUEST="$target_equipment"
  MODEM_DEVICE_ID_REQUEST="$target_device"
  discover_mm_modem || return 1

  log "Detected after recovery: Modem/$MODEM, primary port ${PRIMARY_PORT:-unknown}, MM-ID ${MODEM_DEVICE_ID:-unknown}"

  mmcli_timed 30 -m "$MODEM" --enable >/dev/null 2>&1 || true
  for step in $(seq 1 30); do
    MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
    state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
    case "$state" in registered|connected) break ;; esac
    [ "$step" -eq 1 ] || [ $((step % 5)) -ne 0 ] || \
      log "Waiting for registration after RM505Q recovery: ${state:-unknown} ($((step*2))/60 Sekunden)"
    sleep 2
  done

  case "$state" in
    registered|connected) ;;
    *)
      warn "RM505Q was not registered after recovery: ${state:-unknown}"
      return 1
      ;;
  esac

  if echo "${PRIMARY_PORT:-}" | grep -q 'qmi'; then
    warn "RM505Q remains in the QMI primary-port state after full recovery (${PRIMARY_PORT})."
    return 1
  fi

  return 0
}
connect_mm() {
  local state power ready enable_output enable_status
  local cached_mux first_mode second_mode success_mode connect_output connect_status props current_info current_state binfo step
  [ -n "$MODEM" ] || return 1
  start_mm || return 1

  MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
  state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
  power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"

  case "$state" in
    disabled|failed|unknown|"")
      log "ModemManager: enabling modem/$MODEM (state ${state:-unknown}, radio ${power:-unknown})."
      enable_output="$(mmcli_timed 45 -m "$MODEM" --enable 2>&1)"
      enable_status=$?
      [ -n "$enable_output" ] && printf '%s\n' "$enable_output"
      if [ "$enable_status" -ne 0 ]; then
        sleep 2
        MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
        state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
        power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"
        case "$state" in
          enabled|registered|connected) warn "ModemManager --enable reported rc=$enable_status, Modem ist but bereits $state; fahre fort." ;;
          *) warn "ModemManager could not enable the modem: state ${state:-unknown}, radio ${power:-unknown}, rc=$enable_status"; return 1 ;;
        esac
      fi
      ;;
  esac

  ready=0
  for step in $(seq 1 90); do
    MINFO="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
    state="$(printf '%s\n' "$MINFO" | kv_get modem.generic.state)"
    power="$(printf '%s\n' "$MINFO" | kv_get modem.generic.power-state)"
    case "$state" in
      enabled|registered|connected) ready=1; break ;;
      failed) warn "ModemManager: Modem ist in den Fehlerzustand gewechselt"; return 1 ;;
    esac
    [ "$step" -eq 1 ] || [ $((step % 10)) -ne 0 ] || log "Waiting for a connection-ready modem state: ${state:-unknown}, radio ${power:-unknown} (${step}/90s)"
    sleep 1
  done
  [ "$ready" -eq 1 ] || { warn "ModemManager: modem did not become connection-ready (state ${state:-unknown}, radio ${power:-unknown})"; return 1; }
  log "ModemManager: modem is connection-ready (state $state, radio ${power:-unknown}); simple-connect will handle registration."

  disconnect_other_modems
  clean_modem_bearers "$MODEM"
  CONNECTED_BEARER=""

  mm_attempt() {
    local mode="$1" poll
    props="apn=${APN},ip-type=ipv4"
    [ "$mode" = none ] && props="${props},multiplex=none"
    log "ModemManager-connectionsversuch: multiplex=$mode"
    connect_output="$(mmcli_timed 120 -m "$MODEM" --simple-connect="$props" 2>&1)"
    connect_status=$?
    [ -n "$connect_output" ] && printf '%s\n' "$connect_output"

    for poll in $(seq 1 40); do
      CONNECTED_BEARER="$(find_connected_bearer || true)"
      current_info="$(mmcli -m "$MODEM" -K 2>/dev/null || true)"
      current_state="$(printf '%s\n' "$current_info" | kv_get modem.generic.state)"
      if [ -n "$CONNECTED_BEARER" ]; then
        if [ "$connect_status" -ne 0 ]; then
          warn "mmcli reported rc=$connect_status, but Bearer/$CONNECTED_BEARER is active; treating the connection as successful."
        fi
        return 0
      fi
      case "$current_state" in
        failed) break ;;
      esac
      [ "$poll" -eq 1 ] || [ $((poll % 10)) -ne 0 ] || log "Waiting for an active bearer: Modemzustand ${current_state:-unknown} (${poll}/40s)"
      sleep 1
    done
    warn "ModemManager-connection failed: rc=$connect_status, state ${current_state:-unknown}, no active bearer"
    return 1
  }

  delete_disconnected_bearers
  success_mode=""

  try_mm_mode() {
    local mode="$1"
    if mm_attempt "$mode"; then
      success_mode="$mode"
      return 0
    fi
    if [ "$mode" = none ] && echo "$connect_output" | grep -q "Cannot disable multiplex support"; then
      if auto_repair_mhi_once; then
        clean_modem_bearers "$MODEM"
        CONNECTED_BEARER=""
        if mm_attempt none; then
          success_mode=none
          return 0
        fi
      fi
    fi
    return 1
  }

  if [ "$MULTIPLEX_MODE" = none ]; then
    try_mm_mode none || true
  elif [ "$MULTIPLEX_MODE" = default ]; then
    try_mm_mode default || true
  else
    cached_mux="$(cache_read "$MUX_CACHE" "$MODEM_KEY")"
    case "$cached_mux" in
      none|default) first_mode="$cached_mux" ;;
      *) if mm_prefers_multiplex_none; then first_mode=none; else first_mode=default; fi ;;
    esac
    second_mode=""
    if [ "$first_mode" = default ]; then
      second_mode=none
    elif ! mm_prefers_multiplex_none; then
      second_mode=default
    fi

    if ! try_mm_mode "$first_mode"; then
      if [ "$first_mode" = default ] && echo "$connect_output" | grep -q "Cannot disable multiplex support"; then
        log "Bekannter Multiplexfehler; starte ModemManager vor dem none-Versuch neu."
        restart_mm_and_rediscover || true
        second_mode=none
      fi
      [ -n "$second_mode" ] && try_mm_mode "$second_mode" || true
    fi
  fi

  [ -n "$success_mode" ] || return 1
  cache_write "$MUX_CACHE" "$MODEM_KEY" "$success_mode"

  if [ -z "$CONNECTED_BEARER" ]; then
    for step in $(seq 1 20); do CONNECTED_BEARER="$(find_connected_bearer || true)"; [ -n "$CONNECTED_BEARER" ] && break; sleep 1; done
  fi
  [ -n "$CONNECTED_BEARER" ] || return 1
  binfo="$(mmcli -b "$CONNECTED_BEARER" -K)"
  NET_IF="$(printf '%s\n' "$binfo" | kv_get bearer.status.interface)"
  IP_METHOD="$(printf '%s\n' "$binfo" | kv_get bearer.ipv4-config.method)"
  IP="$(printf '%s\n' "$binfo" | kv_get bearer.ipv4-config.address)"
  PREFIX="$(printf '%s\n' "$binfo" | kv_get bearer.ipv4-config.prefix)"
  GATEWAY="$(printf '%s\n' "$binfo" | kv_get bearer.ipv4-config.gateway)"
  MTU="$(printf '%s\n' "$binfo" | kv_get bearer.ipv4-config.mtu)"
  [ -n "$NET_IF" ] && [ "$NET_IF" != -- ] || return 1
  case "$IP_METHOD" in
    static)
      [ -n "$IP" ] && [ "$IP" != -- ] && [ -n "$PREFIX" ] && [ "$PREFIX" != -- ] || return 1
      ip link set "$NET_IF" up
      ip addr flush dev "$NET_IF" scope global 2>/dev/null || true
      ip addr add "$IP/$PREFIX" dev "$NET_IF"
      [ -n "$MTU" ] && [ "$MTU" != -- ] && ip link set dev "$NET_IF" mtu "$MTU" 2>/dev/null || true
      ;;
    dhcp) run_dhcp "$NET_IF" ;;
    ppp) : ;;
    *) warn "Unbekannte IPv4-Methode des Bearers: ${IP_METHOD:-leer}"; return 1 ;;
  esac
  if [ "$IP_METHOD" = dhcp ]; then
    IP="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    PREFIX="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[2]}')"
    GATEWAY="$(ip -4 route show default dev "$NET_IF" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  BACKEND_USED=mm
  return 0
}
stop_mm_for_native() {
  if [ -n "$MODEM" ] && have_cmd mmcli; then
    mmcli -m "$MODEM" --simple-disconnect >/dev/null 2>&1 || true
  fi
  systemctl stop ModemManager >/dev/null 2>&1 || true
  sleep 2
}

connect_qmi_native() {
  local dev out cid handle settings mask statefile
  have_cmd qmicli || return 1
  dev="$(scan_control_device qmi | head -1)"
  [ -n "$dev" ] || { warn "No QMI control device detected"; return 1; }
  [ "$MODEM_KEY" = unknown ] && MODEM_KEY="qmi-$(basename "$dev")"
  NET_IF="$(select_net_iface qmi "$dev" | head -1)"
  [ -n "$NET_IF" ] || { warn "No data interface detected for $dev detected; use --net-if"; return 1; }
  stop_mm_for_native
  qmicli -d "$dev" --device-open-qmi --dms-set-operating-mode=online >/dev/null 2>&1 || true
  qmicli -d "$dev" --device-open-qmi --set-expected-data-format=raw-ip >/dev/null 2>&1 || true
  out=""
  for _ in 1 2 3; do
    out="$(qmicli -d "$dev" --device-open-qmi --wds-start-network="apn=$APN,ip-type=4" --client-no-release-cid 2>&1)" && break
    sleep 3
  done
  echo "$out"
  echo "$out" | grep -qiE 'Network started|Packet data handle' || return 1
  handle="$(echo "$out" | sed -n "s/.*Packet data handle: '\([^']*\)'.*/\1/p" | head -1)"
  cid="$(echo "$out" | sed -n "s/.*CID: '\([^']*\)'.*/\1/p" | tail -1)"
  [ -n "$cid" ] || { warn "QMI-connection started, but the WDS CID could not be determined"; return 1; }
  settings="$(qmicli -d "$dev" --device-open-qmi --client-cid="$cid" --client-no-release-cid --wds-get-current-settings 2>&1)"
  echo "$settings"
  IP="$(echo "$settings" | sed -n "s/.*IPv4 address: '\([^']*\)'.*/\1/p" | head -1)"
  mask="$(echo "$settings" | sed -n "s/.*IPv4 subnet mask: '\([^']*\)'.*/\1/p" | head -1)"
  GATEWAY="$(echo "$settings" | sed -n "s/.*IPv4 gateway address: '\([^']*\)'.*/\1/p" | head -1)"
  MTU="$(echo "$settings" | sed -n "s/.*MTU: '\([^']*\)'.*/\1/p" | head -1)"
  PREFIX=""
  [ -n "$mask" ] && PREFIX="$(netmask_to_prefix "$mask")"
  if [ -n "$IP" ] && [ -n "$PREFIX" ] && [ -n "$GATEWAY" ]; then
    IP_METHOD=static
    ip link set "$NET_IF" up
    ip addr flush dev "$NET_IF" scope global 2>/dev/null || true
    ip addr add "$IP/$PREFIX" dev "$NET_IF"
    [ -n "$MTU" ] && ip link set dev "$NET_IF" mtu "$MTU" 2>/dev/null || true
  else
    IP_METHOD=dhcp
    run_dhcp "$NET_IF"
    IP="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    PREFIX="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[2]}')"
    GATEWAY="$(ip -4 route show default dev "$NET_IF" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  mkdir -p "$NATIVE_STATE_DIR"
  statefile="$NATIVE_STATE_DIR/$(safe_key "$MODEM_KEY").qmi"
  cat > "$statefile" <<EOF
DEV=$dev
CID=$cid
HANDLE=$handle
INTERFACE=$NET_IF
EOF
  chmod 600 "$statefile"
  BACKEND_USED=qmi
  return 0
}

connect_mbim_native() {
  local dev out cfg cidr statefile
  have_cmd mbimcli || return 1
  dev="$(scan_control_device mbim | head -1)"
  [ -n "$dev" ] || { warn "No MBIM control device detected"; return 1; }
  [ "$MODEM_KEY" = unknown ] && MODEM_KEY="mbim-$(basename "$dev")"
  NET_IF="$(select_net_iface mbim "$dev" | head -1)"
  [ -n "$NET_IF" ] || { warn "No data interface detected for $dev detected; use --net-if"; return 1; }
  stop_mm_for_native
  mbimcli -d "$dev" --set-radio-state=on >/dev/null 2>&1 || true
  mbimcli -d "$dev" --attach-packet-service >/dev/null 2>&1 || true
  out="$(mbimcli -d "$dev" --connect="session-id=0,access-string=$APN,ip-type=ipv4" 2>&1)"
  echo "$out"
  echo "$out" | grep -qiE 'activated|successfully|connected' || return 1
  cfg="$(mbimcli -d "$dev" --query-ip-configuration=0 2>&1)"
  echo "$cfg"
  cidr="$(echo "$cfg" | sed -n "s/.*IP \[[0-9]\+\]: '\([^']*\)'.*/\1/p" | head -1)"
  if echo "$cidr" | grep -q '/'; then
    IP="${cidr%/*}"
    PREFIX="${cidr#*/}"
  else
    IP="$(echo "$cfg" | sed -n "s/.*IPv4 address[^']*'\([^']*\)'.*/\1/p" | head -1)"
    PREFIX="$(echo "$cfg" | sed -n "s/.*IPv4 prefix[^']*'\([^']*\)'.*/\1/p" | head -1)"
  fi
  GATEWAY="$(echo "$cfg" | sed -n "s/.*Gateway[^']*'\([^']*\)'.*/\1/p" | head -1)"
  MTU="$(echo "$cfg" | sed -n "s/.*MTU[^']*'\([^']*\)'.*/\1/p" | head -1)"
  if [ -n "$IP" ] && [ -n "$PREFIX" ] && [ -n "$GATEWAY" ]; then
    IP_METHOD=static
    ip link set "$NET_IF" up
    ip addr flush dev "$NET_IF" scope global 2>/dev/null || true
    ip addr add "$IP/$PREFIX" dev "$NET_IF"
    [ -n "$MTU" ] && ip link set dev "$NET_IF" mtu "$MTU" 2>/dev/null || true
  else
    IP_METHOD=dhcp
    run_dhcp "$NET_IF"
    IP="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    PREFIX="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[2]}')"
    GATEWAY="$(ip -4 route show default dev "$NET_IF" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  fi
  mkdir -p "$NATIVE_STATE_DIR"
  statefile="$NATIVE_STATE_DIR/$(safe_key "$MODEM_KEY").mbim"
  cat > "$statefile" <<EOF
DEV=$dev
SESSION=0
INTERFACE=$NET_IF
EOF
  chmod 600 "$statefile"
  BACKEND_USED=mbim
  return 0
}


fm350_controlled_radio_reset() {
  local out marker iface
  [ "$FM350_TRANSPORT" = usb ] || { warn "Controlled FM350 radio reset is supported only for USB/AT-RNDIS."; return 1; }
  if [ "$FM350_REGISTRATION_RESET_DONE" -eq 1 ]; then
    warn "A controlled FM350 radio reset has already been performed during this run; no additional reset will be attempted."
    return 1
  fi
  FM350_REGISTRATION_RESET_DONE=1

  warn "FM350 registration/data path is stuck; performing one controlled radio reset."
  iface="$FM350_RNDIS_IF"
  if [ -z "$iface" ]; then fm350_find_rndis_iface || true; iface="$FM350_RNDIS_IF"; fi

  out="$(fm350_at_cmd "AT+CGACT=0,$FM350_CID" 10 || true)"
  printf '%s\n' "$out" | grep -qx 'OK' || log "FM350-PDP detach was not confirmed; the radio reset will continue."
  out="$(fm350_at_cmd 'AT+CGATT=0' 10 || true)"
  printf '%s\n' "$out" | grep -qx 'OK' || log "FM350-Packet-service detach was not confirmed; the radio reset will continue."
  out="$(fm350_at_cmd 'AT+CFUN=0' 20 || true)"
  if ! printf '%s\n' "$out" | grep -qx 'OK'; then
    warn "FM350 did not confirm AT+CFUN=0; aborting controlled radio reset."
    return 1
  fi

  # unangetastet und will be nach successfuler connection normal verifiziert.
  if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then
    ip -4 addr flush dev "$iface" scope global 2>/dev/null || true
    ip -4 route flush dev "$iface" 2>/dev/null || true
  fi
  rm -f "$FM350_AT_CACHE" "$UNLOCK_STATE_DIR"/*.fm350-fcc.ok
  FM350_AT_DEV=""
  AT_PORT=""
  FM350_PDP_IP=""
  sleep "$FM350_REGISTRATION_RESET_WAIT"

  fm350_set_usb_power
  udevadm settle --timeout=20 2>/dev/null || true
  fm350_find_rndis_iface || { warn "FM350-RNDIS interface is missing after the radio reset."; return 1; }
  fm350_find_at_port || { warn "FM350-AT port was not detected again after the radio reset."; return 1; }
  fm350_unlock || { warn "FM350-FCC unlock failed after the radio reset."; return 1; }
  MODEM_UNLOCK_KIND=fm350-fcc
  marker="$(unlock_marker_path)"
  printf 'KIND=%s\nMODEM_KEY=%s\n' "$MODEM_UNLOCK_KIND" "$MODEM_KEY" > "$marker"
  chmod 600 "$marker" 2>/dev/null || true

  out="$(fm350_at_cmd 'AT+CFUN=1' 20 || true)"
  if ! printf '%s\n' "$out" | grep -qx 'OK'; then
    warn "FM350 did not confirm AT+CFUN=1 after the radio reset."
    return 1
  fi
  sleep 3
  log "Controlled FM350 radio reset completed; registration will be checked again."
  return 0
}

fm350_wait_registration_once() {
  local out stat step cpin cme
  FM350_REGISTRATION_FAILURE=""
  fm350_at_cmd 'AT+CFUN=1' 12 >/dev/null || true
  for step in $(seq 1 60); do
    out="$(fm350_at_cmd 'AT+CPIN?' 6 || true)"
    if printf '%s\n' "$out" | grep -q '+CPIN: READY'; then
      break
    fi
    cpin="$(printf '%s\n' "$out" | sed -n 's/.*+CPIN: *//p' | tail -1)"
    cme="$(printf '%s\n' "$out" | sed -n 's/.*+CME ERROR: *\([0-9][0-9]*\).*/\1/p' | tail -1)"
    case "$cme" in
      10) FM350_REGISTRATION_FAILURE=sim; warn "FM350 does not detect a SIM card (CME ERROR 10). Ethernet remains active."; return 1 ;;
      13) FM350_REGISTRATION_FAILURE=sim; warn "FM350 reports a SIM error (CME ERROR 13). Ethernet remains active."; return 1 ;;
    esac
    case "$cpin" in
      *PIN*|*PUK*) FM350_REGISTRATION_FAILURE=sim; warn "FM350-SIM requires unlocking: ${cpin:-unknown}. Ethernet remains active."; return 1 ;;
    esac
    [ $((step % 5)) -ne 0 ] || log "Waiting for FM350 SIM readiness, CPIN=${cpin:-CME-${cme:-unknown}}"
    sleep 2
  done
  if ! printf '%s\n' "$out" | grep -q '+CPIN: READY'; then
    FM350_REGISTRATION_FAILURE=sim
    warn "FM350-SIM did not become ready; Ethernet remains active."
    return 1
  fi

  stat=""
  for step in $(seq 1 "$FM350_REGISTRATION_ATTEMPTS"); do
    out="$(fm350_at_cmd 'AT+CEREG?' 6 || true)"
    stat="$(printf '%s\n' "$out" | sed -n 's/.*+CEREG: [0-9]\+,\([0-9]\+\).*/\1/p' | tail -1)"
    [ -n "$stat" ] || stat="$(printf '%s\n' "$out" | sed -n 's/.*+CEREG: \([0-9]\+\).*/\1/p' | tail -1)"
    case "$stat" in 1|5) break ;; esac
    [ $((step % 5)) -ne 0 ] || log "Waiting for FM350 cellular registration, CEREG=${stat:-unknown}"
    sleep 2
  done
  case "${stat:-}" in
    1|5) ;;
    *) FM350_REGISTRATION_FAILURE=registration; warn "FM350 was not registered on the cellular network (CEREG=${stat:-unknown})."; return 1 ;;
  esac

  fm350_at_cmd 'AT+CGATT=1' 20 >/dev/null || true
  for step in $(seq 1 20); do
    out="$(fm350_at_cmd 'AT+CGATT?' 6 || true)"
    printf '%s\n' "$out" | grep -q '+CGATT: 1' && return 0
    sleep 2
  done
  FM350_REGISTRATION_FAILURE=attach
  warn "FM350 packet service is not attached."
  return 1
}

fm350_wait_registration() {
  if fm350_wait_registration_once; then return 0; fi
  case "$FM350_REGISTRATION_FAILURE" in
    registration|attach)
      if [ "$FM350_TRANSPORT" = usb ] && [ "$FM350_REGISTRATION_RESET_DONE" -eq 0 ]; then
        warn "Normal FM350 registration failed; attempting a controlled radio reset."
        fm350_controlled_radio_reset || { warn "Controlled FM350 radio reset failed; Ethernet remains active."; return 1; }
        if fm350_wait_registration_once; then
          log "FM350-Registration succeeded after the controlled radio reset."
          return 0
        fi
        warn "FM350-Registrierung blieb auch nach dem kontrollierten radioreset erfolglos; Ethernet remains active."
      fi
      ;;
  esac
  return 1
}

fm350_get_pdp_ip() {
  local out
  out="$(fm350_at_cmd "AT+CGPADDR=$FM350_CID" 8 || true)"
  FM350_PDP_IP="$(printf '%s\n' "$out" | sed -n "s/.*+CGPADDR: $FM350_CID,\"\([0-9.]\+\)\".*/\1/p" | head -1)"
  [ -n "$FM350_PDP_IP" ] || FM350_PDP_IP="$(printf '%s\n' "$out" | sed -n "s/.*+CGPADDR: $FM350_CID,\([0-9.]\+\).*/\1/p" | head -1)"
  [ -n "$FM350_PDP_IP" ] && [ "$FM350_PDP_IP" != 0.0.0.0 ]
}

fm350_activate_pdp() {
  local attempt
  FM350_PDP_IP=""
  for attempt in 1 2; do
    fm350_at_cmd "AT+CGDCONT=$FM350_CID,\"IP\",\"$APN\"" 10 >/dev/null || true
    fm350_at_cmd 'AT+CGATT=1' 20 >/dev/null || true
    fm350_at_cmd "AT+CGACT=1,$FM350_CID" 45 >/dev/null || true
    sleep 3
    if fm350_get_pdp_ip; then return 0; fi

    if [ "$attempt" -eq 1 ]; then
      if [ "$FM350_REGISTRATION_RESET_DONE" -eq 0 ]; then
        warn "FM350-PDP activation returned no IPv4 address; attempting a controlled radio reset."
        fm350_controlled_radio_reset || return 1
        fm350_wait_registration_once || { warn "FM350-Registration failed after the PDP radio reset."; return 1; }
      else
        warn "FM350-PDP-Aufbau lieferte none IPv4; The radio reset was already performed; retrying PDP activation once without another reset."
      fi
    fi
  done
  return 1
}

connect_fm350_at_rndis() {
  [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ] || { warn "at-rndis requires an FM350 connected over USB"; return 1; }
  stop_mm_for_native
  fm350_set_usb_power
  udevadm settle --timeout=20 2>/dev/null || true
  fm350_find_rndis_iface || { warn "No FM350 rndis_host interface detected"; return 1; }
  fm350_find_at_port || { warn "No FM350 AT port detected"; return 1; }
  fm350_wait_registration || return 1
  fm350_activate_pdp || { warn "FM350-PDP context could not be activated"; return 1; }
  NET_IF="$FM350_RNDIS_IF"
  IP_METHOD=static
  IP="$FM350_PDP_IP"
  PREFIX=24
  GATEWAY="${IP%.*}.1"
  MTU=1500
  ip link set "$NET_IF" up
  ip addr flush dev "$NET_IF" scope global 2>/dev/null || true
  ip addr add "$IP/$PREFIX" dev "$NET_IF"
  ip link set dev "$NET_IF" mtu "$MTU" 2>/dev/null || true
  MODEM_TRANSPORT=usb
  BACKEND_USED=at-rndis
  log "FM350 USB/AT-RNDIS aktiv: $NET_IF, $IP/$PREFIX, Gateway $GATEWAY"
  return 0
}

connect_dhcp_native() {
  NET_IF="$(find_dhcp_modem_iface | head -1)"
  [ -n "$NET_IF" ] || { warn "No ECM/NCM/RNDIS/DHCP modem interface detected; use --net-if"; return 1; }
  [ "$MODEM_KEY" = unknown ] && MODEM_KEY="dhcp-$NET_IF"
  stop_mm_for_native
  run_dhcp "$NET_IF" || return 1
  IP_METHOD=dhcp
  IP="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
  PREFIX="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[2]}')"
  GATEWAY="$(ip -4 route show default dev "$NET_IF" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  [ -n "$IP" ] || return 1
  BACKEND_USED=dhcp
  return 0
}

if [ "$RECOVER_ONLY" -eq 1 ]; then
  fm350_recover_after_usb_event
  builtin exit $?
fi

if [ "$UNLOCK_ONLY" -eq 0 ]; then
  prepare_wired_wan_early || true
fi

ensure_modem_device_discovery
load_known_drivers
detect_fm350_transport || true
MM_AVAILABLE=0
if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ] && [ -n "$FM350_RNDIS_IF" ]; then
  log "FM350 USB/RNDIS detected; ModemManager detection is skipped for this transport."
else
  discover_mm_modem && MM_AVAILABLE=1
fi
if [ "$MM_AVAILABLE" -eq 1 ]; then
  log "Selected: Modem/$MODEM ${MODEM_MODEL:-unknown}; Equipment-ID ${MODEM_EQUIPMENT_ID:-unknown}; MM-ID ${MODEM_DEVICE_ID:-unknown}; driver ${MODEM_DRIVER:-unknown}; PCI-ID ${MODEM_PCI_ID:-unknown}; primary port ${PRIMARY_PORT:-unknown}"
fi
MODEM_UNLOCK_OK=1
if [ "$MM_AVAILABLE" -eq 1 ] || [ "$FM350_AVAILABLE" -eq 1 ]; then
  if ! perform_modem_unlock; then
    MODEM_UNLOCK_OK=0
    if [ "$WIRED_CANDIDATE_AVAILABLE" -eq 1 ]; then
      warn "Modem-specific FCC unlock failed; wired WAN will still be configured independently."
    else
      die "Modem-specific FCC unlock failed"
    fi
  fi
fi

if [ "$UNLOCK_ONLY" -eq 1 ]; then
  [ "$MM_AVAILABLE" -eq 1 ] || [ "$FM350_AVAILABLE" -eq 1 ] || die "No modem detected for unlock"
  log "Unlock-Lauf abgeschlossen: Typ $MODEM_UNLOCK_KIND, Transport ${MODEM_TRANSPORT:-unknown}, Modem ${MODEM_EQUIPMENT_ID:-$MODEM_DEVICE_ID}."
  builtin exit 0
fi

if [ "$PROBE_ONLY" -eq 1 ]; then
  probe_backends
  builtin exit 0
fi

choose_apn

if [ "$BACKEND_MODE" = auto ] || [ "$BACKEND_MODE" = auto-native ]; then
  if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ]; then
    fm350_find_rndis_iface || true
  fi
  if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ] && [ -n "$FM350_RNDIS_IF" ]; then
    SELECTED_BACKEND=at-rndis
  elif [ "$SERVICE_RUN" -eq 0 ]; then
    SELECTED_BACKEND=mm
  else
    CACHED_BACKEND="$(cache_read "$BACKEND_CACHE" "$MODEM_KEY")"
    case "$CACHED_BACKEND" in
      at-rndis) SELECTED_BACKEND=mm ;;
      mm|qmi|mbim|dhcp) SELECTED_BACKEND="$CACHED_BACKEND" ;;
      *) SELECTED_BACKEND=mm ;;
    esac
  fi
else
  SELECTED_BACKEND="$BACKEND_MODE"
fi

try_backend() {
  local backend="$1"
  log "Using backend: $backend"
  case "$backend" in
    mm) connect_mm ;;
    qmi) connect_qmi_native ;;
    mbim) connect_mbim_native ;;
    at-rndis) connect_fm350_at_rndis ;;
    dhcp) connect_dhcp_native ;;
    *) return 1 ;;
  esac
}

SUCCESS=0
if [ "$MODEM_UNLOCK_OK" -eq 1 ] && try_backend "$SELECTED_BACKEND"; then
  SUCCESS=1
elif [ "$MODEM_UNLOCK_OK" -eq 1 ] && [ "$BACKEND_MODE" = auto ] && [ "$SELECTED_BACKEND" != mm ]; then
  if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ] && [ "$SELECTED_BACKEND" = at-rndis ]; then
    warn "FM350 USB/AT-RNDIS failed; no unsuitable ModemManager fallback will be attempted for the same USB composition."
  else
    warn "Saved backend $SELECTED_BACKEND failed; trying ModemManager"
    start_mm || true
    discover_mm_modem || true
    [ -n "$MODEM" ] && try_backend mm && SUCCESS=1
  fi
elif [ "$MODEM_UNLOCK_OK" -eq 1 ] && [ "$BACKEND_MODE" = auto-native ]; then
  for fallback in at-rndis mm qmi mbim dhcp; do
    [ "$fallback" = "$SELECTED_BACKEND" ] && continue
    if [ "$FM350_AVAILABLE" -eq 1 ] && [ "$FM350_TRANSPORT" = usb ] && [ "$fallback" = mm ]; then
      continue
    fi
    start_mm >/dev/null 2>&1 || true
    discover_mm_modem >/dev/null 2>&1 || true
    if try_backend "$fallback"; then SUCCESS=1; break; fi
  done
fi

if [ "$SUCCESS" -eq 1 ]; then
  WWAN_CONNECTED=1
  [ -n "$NET_IF" ] || die "No data interface was obtained"
  ip link show "$NET_IF" >/dev/null 2>&1 || die "Data interface $NET_IF does not exist"
  if [ "$IP_METHOD" != ppp ]; then
    [ -n "$IP" ] || IP="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
    [ -n "$PREFIX" ] || PREFIX="$(ip -4 -o addr show dev "$NET_IF" scope global | awk 'NR==1 {split($4,a,"/"); print a[2]}')"
    [ -n "$GATEWAY" ] || GATEWAY="$(ip -4 route show default dev "$NET_IF" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
    [ -n "$IP" ] || die "$BACKEND_USED did not configure an IPv4 address on $NET_IF eingerichtet"
    [ -n "$GATEWAY" ] || die "$BACKEND_USED did not provide an IPv4 gateway for $NET_IF geliefert"
  fi
  if [ "$NO_SAVE_BACKEND" -eq 0 ]; then cache_write "$BACKEND_CACHE" "$MODEM_KEY" "$BACKEND_USED"; fi
  log "connection aktiv: Backend $BACKEND_USED, Interface $NET_IF, IPv4 ${IP:-PPP}/${PREFIX:-}, Gateway ${GATEWAY:-interface-route}"
else
  if [ "$WIRED_CANDIDATE_AVAILABLE" -eq 1 ]; then
    BACKEND_USED=none
    warn "WWAN is currently unavailable; installation will continue with queued wired WAN $WIRED_WAN fortgesetzt."
  else
    die "No selected backend could establish a connection and no wired WAN was detected/requested"
  fi
fi




write_persistent_config() {
  local saved_mux="auto"
  if [ "$BACKEND_USED" = mm ]; then
    saved_mux="$(cache_read "$MUX_CACHE" "$MODEM_KEY")"
    case "$saved_mux" in none|default) ;; *) saved_mux=auto ;; esac
  fi
  cat > "$CONFIG_FILE" <<EOF
APN=$APN
BACKEND_POLICY=$BACKEND_POLICY
TRANSPORT=$MODEM_TRANSPORT
MODEM_DEVICE_ID=$MODEM_DEVICE_ID
MODEM_EQUIPMENT_ID=$MODEM_EQUIPMENT_ID
MODEM_PCI_ID=$MODEM_PCI_ID
BACKEND=$BACKEND_USED
MULTIPLEX=$saved_mux
AP_NET=$AP_NET
WIRED_WAN=$WIRED_WAN_REQUEST
UNLOCK_KIND=$MODEM_UNLOCK_KIND
FM350_USB_ID=$FM350_USB_ID
FM350_STABLE_IF=$FM350_STABLE_IF
EOF
  chmod 600 "$CONFIG_FILE"
}

write_unlock_service_unit() {
  cat > "$UNLOCK_SERVICE_PATH" <<EOF
[Unit]
Description=Run modem-specific FCC unlock before the WWAN connection
After=systemd-modules-load.service systemd-udev-trigger.service ModemManager.service
Wants=ModemManager.service
Before=modem-connect.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=${SELF_PATH} --service-run --unlock-only
RemainAfterExit=yes
TimeoutStartSec=240
Restart=on-failure
RestartSec=15
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF
}

write_service_unit() {
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Automatically connect the modem and configure the VyOS WWAN fallback
After=vyos-router.service systemd-modules-load.service systemd-udev-trigger.service ModemManager.service modem-unlock.service network.target
Requires=vyos-router.service modem-unlock.service
Wants=ModemManager.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=${SELF_PATH} --service-run
RemainAfterExit=yes
TimeoutStartSec=600
Restart=on-failure
RestartSec=20
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable modem-unlock.service modem-connect.service >/dev/null 2>&1
}

# Determine wired WAN. Modem and tethering interfaces are intentionally excluded.
wired_wan_candidate() {
  local candidate="$1" driver=""
  [ -n "$candidate" ] || return 1
  [ "$candidate" != "$NET_IF" ] && [ "$candidate" != "$AP_IF" ] && [ "$candidate" != lo ] || return 1
  ip link show "$candidate" >/dev/null 2>&1 || return 1
  case "$candidate" in eth*|en*) ;; *) return 1 ;; esac
  [ ! -e "/sys/class/net/$candidate/master" ] || return 1
  driver="$(net_driver "$candidate")"
  [ -n "$driver" ] || driver="$(basename "$(readlink -f "/sys/class/net/$candidate/device/driver" 2>/dev/null)" 2>/dev/null || true)"
  case "$driver" in rndis_host|rndis_wlan|cdc_ether|cdc_ncm|huawei_cdc_ncm|cdc_mbim|qmi_wwan|mhi_net|iosm) return 1 ;; esac
  return 0
}

detect_wired_wan() {
  local candidate path
  while read -r candidate; do
    wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); break}}')

  while read -r candidate; do
    wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
  done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}')

  if command -v /opt/vyatta/bin/vyatta-op-cmd-wrapper >/dev/null 2>&1; then
    while read -r candidate; do
      wired_wan_candidate "$candidate" && { printf '%s' "$candidate"; return 0; }
    done < <(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null | awk '/^set interfaces ethernet [^ ]+ address / {gsub(/\047/,"",$4); print $4}' | awk '!seen[$0]++')
  fi

  for path in /sys/class/net/*; do
    [ -e "$path" ] || continue
    candidate="$(basename "$path")"
    wired_wan_candidate "$candidate" || continue
    [ "$(cat "$path/carrier" 2>/dev/null || true)" = 1 ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

if [ -z "${WIRED_WAN_REQUEST:-}" ]; then WIRED_WAN_REQUEST="$WIRED_WAN"; fi
case "$WIRED_WAN" in
  auto) WIRED_WAN="$(detect_wired_wan 2>/dev/null || true)" ;;
  none) WIRED_WAN="" ;;
esac
[ "$WIRED_WAN_REQUEST" = auto ] && [ -n "$WIRED_WAN" ] && WIRED_WAN_REQUEST="$WIRED_WAN"

OLD_GATEWAY=""
[ -s "$ROUTE_CACHE" ] && OLD_GATEWAY="$(awk -F= '$1=="GATEWAY" {print $2; exit}' "$ROUTE_CACHE")"

[ -r /opt/vyatta/etc/functions/script-template ] || die "VyOS script-template is missing"
wait_for_vyos_config_runtime
ACTIVE_BEFORE="$(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null || true)"

WIRED_CONFIGURED=0
WIRED_USE_DHCP=0
WIRED_ADD_DHCP=0
if [ -n "$WIRED_WAN" ]; then
  if ! wired_wan_candidate "$WIRED_WAN"; then
    warn "Wired WAN $WIRED_WAN is not a usable standalone Ethernet interface; Ethernet fallback is skipped."
    WIRED_WAN=""
  else
    WIRED_CONFIGURED=1
    if printf '%s\n' "$ACTIVE_BEFORE" | grep -qE "^set interfaces ethernet ${WIRED_WAN} address '?dhcp'?$"; then
      WIRED_USE_DHCP=1
    elif printf '%s\n' "$ACTIVE_BEFORE" | grep -qE "^set interfaces ethernet ${WIRED_WAN} address "; then
      log "Wired WAN $WIRED_WAN uses an existing static address; only NAT will be added."
    else
      WIRED_USE_DHCP=1
      WIRED_ADD_DHCP=1
      log "Wired WAN $WIRED_WAN is not addressed yet; DHCP will be added."
    fi
  fi
fi

# Shellfunktion stehen, deren Body schon vor "source script-template" geparst wurde.
# Ein separates top-level-vbash-Hilfsskript ist hier zugleich die sauberste Garantie,
mkdir -p "$UNLOCK_STATE_DIR"
VYOS_CONFIG_HELPER="$UNLOCK_STATE_DIR/vyos-apply-$$.sh"
VYOS_CONFIG_RESULT="$UNLOCK_STATE_DIR/vyos-apply-result-$$"
rm -f "$VYOS_CONFIG_HELPER" "$VYOS_CONFIG_RESULT"

cat > "$VYOS_CONFIG_HELPER" <<'EOF'
#!/bin/vbash
source /opt/vyatta/etc/functions/script-template
configure
EOF

printf 'delete nat source rule %q 2>/dev/null || true\n' "$WIRED_NAT_RULE" >> "$VYOS_CONFIG_HELPER"
if [ "$WIRED_CONFIGURED" -eq 1 ]; then
  [ "$WIRED_ADD_DHCP" -eq 1 ] && printf 'set interfaces ethernet %q address dhcp\n' "$WIRED_WAN" >> "$VYOS_CONFIG_HELPER"
  if [ "$WIRED_USE_DHCP" -eq 1 ]; then
    printf 'delete interfaces ethernet %q dhcp-options default-route-distance 2>/dev/null || true\n' "$WIRED_WAN" >> "$VYOS_CONFIG_HELPER"
    printf 'set interfaces ethernet %q dhcp-options default-route-distance %q\n' "$WIRED_WAN" "$WIRED_ROUTE_DISTANCE" >> "$VYOS_CONFIG_HELPER"
  fi
  printf 'set nat source rule %q description %q\n' "$WIRED_NAT_RULE" 'AP-NET-to-WIRED-WAN' >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q outbound-interface name %q\n' "$WIRED_NAT_RULE" "$WIRED_WAN" >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q source address %q\n' "$WIRED_NAT_RULE" "$AP_NET" >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q translation address masquerade\n' "$WIRED_NAT_RULE" >> "$VYOS_CONFIG_HELPER"
fi

printf 'delete nat source rule %q 2>/dev/null || true\n' "$WWAN_NAT_RULE" >> "$VYOS_CONFIG_HELPER"
if [ "$WWAN_CONNECTED" -eq 1 ]; then
  printf 'set nat source rule %q description %q\n' "$WWAN_NAT_RULE" 'AP-NET-to-WWAN' >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q outbound-interface name %q\n' "$WWAN_NAT_RULE" "$NET_IF" >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q source address %q\n' "$WWAN_NAT_RULE" "$AP_NET" >> "$VYOS_CONFIG_HELPER"
  printf 'set nat source rule %q translation address masquerade\n' "$WWAN_NAT_RULE" >> "$VYOS_CONFIG_HELPER"
fi

if [ -n "$OLD_GATEWAY" ] && { [ "$WWAN_CONNECTED" -eq 0 ] || [ "$OLD_GATEWAY" != "$GATEWAY" ]; }; then
  printf 'delete protocols static route 0.0.0.0/0 next-hop %q 2>/dev/null || true\n' "$OLD_GATEWAY" >> "$VYOS_CONFIG_HELPER"
fi
if [ "$WWAN_CONNECTED" -eq 1 ]; then
  if [ "$IP_METHOD" = ppp ]; then
    printf 'set protocols static route 0.0.0.0/0 interface %q\n' "$NET_IF" >> "$VYOS_CONFIG_HELPER"
    printf 'set protocols static route 0.0.0.0/0 interface %q distance %q\n' "$NET_IF" "$WWAN_ROUTE_DISTANCE" >> "$VYOS_CONFIG_HELPER"
  else
    printf 'delete protocols static route 0.0.0.0/0 next-hop %q 2>/dev/null || true\n' "$GATEWAY" >> "$VYOS_CONFIG_HELPER"
    printf 'set protocols static route 0.0.0.0/0 next-hop %q interface %q\n' "$GATEWAY" "$NET_IF" >> "$VYOS_CONFIG_HELPER"
    printf 'set protocols static route 0.0.0.0/0 next-hop %q distance %q\n' "$GATEWAY" "$WWAN_ROUTE_DISTANCE" >> "$VYOS_CONFIG_HELPER"
  fi
fi

cat >> "$VYOS_CONFIG_HELPER" <<EOF
commit
COMMIT_RC=\$?
save
SAVE_RC=\$?
printf 'COMMIT_RC=%s\\nSAVE_RC=%s\\n' "\$COMMIT_RC" "\$SAVE_RC" > $(printf '%q' "$VYOS_CONFIG_RESULT")
discard 2>/dev/null || true
exit
EOF
chmod 0700 "$VYOS_CONFIG_HELPER"

vyos_desired_config_active() {
  local active_cfg nat_ok=1 route_cfg_ok=1 wired_ok=1
  active_cfg="$(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null || true)"
  if [ "$WWAN_CONNECTED" -eq 1 ]; then
    nat_ok=0
    route_cfg_ok=0
    printf '%s\n' "$active_cfg" | grep -F "set nat source rule $WWAN_NAT_RULE outbound-interface name" | grep -Fq "$NET_IF" && nat_ok=1
    if [ "$IP_METHOD" = ppp ]; then
      printf '%s\n' "$active_cfg" | grep -F "set protocols static route 0.0.0.0/0 interface" | grep -Fq "$NET_IF" && route_cfg_ok=1
    elif printf '%s\n' "$active_cfg" | grep -Fq "set protocols static route 0.0.0.0/0 next-hop $GATEWAY"; then
      route_cfg_ok=1
    fi
  else
    printf '%s\n' "$active_cfg" | grep -Fq "set nat source rule $WWAN_NAT_RULE " && nat_ok=0
    [ -n "$OLD_GATEWAY" ] && printf '%s\n' "$active_cfg" | grep -Fq "set protocols static route 0.0.0.0/0 next-hop $OLD_GATEWAY" && route_cfg_ok=0
  fi
  if [ "$WIRED_CONFIGURED" -eq 1 ]; then
    wired_ok=0
    printf '%s\n' "$active_cfg" | grep -F "set nat source rule $WIRED_NAT_RULE outbound-interface name" | grep -Fq "$WIRED_WAN" && wired_ok=1
  fi
  [ "$nat_ok" -eq 1 ] && [ "$route_cfg_ok" -eq 1 ] && [ "$wired_ok" -eq 1 ]
}

COMMIT_OK=0
for COMMIT_ATTEMPT in $(seq 1 "$VYOS_COMMIT_RETRIES"); do
  log "VyOS-Commit-Versuch $COMMIT_ATTEMPT/$VYOS_COMMIT_RETRIES"
  rm -f "$VYOS_CONFIG_RESULT"
  /bin/vbash "$VYOS_CONFIG_HELPER" || true
  COMMIT_RC="$(sed -n 's/^COMMIT_RC=//p' "$VYOS_CONFIG_RESULT" 2>/dev/null | head -1)"
  SAVE_RC="$(sed -n 's/^SAVE_RC=//p' "$VYOS_CONFIG_RESULT" 2>/dev/null | head -1)"

  if [ "$COMMIT_RC" = 0 ] && [ "$SAVE_RC" = 0 ]; then
    COMMIT_OK=1
    break
  fi
  if [ "$SAVE_RC" = 0 ] && vyos_desired_config_active; then
    COMMIT_OK=1
    log "The requested configuration was already active and saved; no additional commit is required."
    break
  fi

  warn "VyOS configuration attempt failed: commit=${COMMIT_RC:-no status} save=${SAVE_RC:-no status}"
  [ "$COMMIT_ATTEMPT" -lt "$VYOS_COMMIT_RETRIES" ] && sleep "$VYOS_COMMIT_RETRY_DELAY"
done
rm -f "$VYOS_CONFIG_HELPER" "$VYOS_CONFIG_RESULT"

[ "$COMMIT_OK" -eq 1 ] || die "VyOS configuration could not be committed and saved after $VYOS_COMMIT_RETRIES attempts."

CONFIG_ACTIVE=0
for VERIFY_ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
  ACTIVE_CFG="$(/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands 2>/dev/null || true)"
  NAT_OK=1; ROUTE_CFG_OK=1; WIRED_OK=1
  if [ "$WWAN_CONNECTED" -eq 1 ]; then
    NAT_OK=0; ROUTE_CFG_OK=0
    printf '%s\n' "$ACTIVE_CFG" | grep -F "set nat source rule $WWAN_NAT_RULE outbound-interface name" | grep -Fq "$NET_IF" && NAT_OK=1
    if [ "$IP_METHOD" = ppp ]; then
      printf '%s\n' "$ACTIVE_CFG" | grep -F "set protocols static route 0.0.0.0/0 interface" | grep -Fq "$NET_IF" && ROUTE_CFG_OK=1
    elif printf '%s\n' "$ACTIVE_CFG" | grep -Fq "set protocols static route 0.0.0.0/0 next-hop $GATEWAY"; then ROUTE_CFG_OK=1; fi
  fi
  if [ "$WIRED_CONFIGURED" -eq 1 ]; then
    WIRED_OK=0
    printf '%s\n' "$ACTIVE_CFG" | grep -F "set nat source rule $WIRED_NAT_RULE outbound-interface name" | grep -Fq "$WIRED_WAN" && WIRED_OK=1
  fi
  if [ "$NAT_OK" -eq 1 ] && [ "$ROUTE_CFG_OK" -eq 1 ] && [ "$WIRED_OK" -eq 1 ]; then CONFIG_ACTIVE=1; break; fi
  [ "$VERIFY_ATTEMPT" -eq 1 ] && warn "Commit succeeded; waiting for the active configuration (WWAN-NAT=$NAT_OK WWAN-Route-Konfig=$ROUTE_CFG_OK WIRED=$WIRED_OK)."
  sleep 2
done
[ "$CONFIG_ACTIVE" -eq 1 ] || die "The committed configuration is not fully visible."

if [ "$WWAN_CONNECTED" -eq 1 ]; then
  DATA_PLANE_OK=0
  for DATA_TEST_ATTEMPT in 1 2 3 4; do
    ROUTE_LINE="$(ip -4 route get 1.1.1.1 oif "$NET_IF" 2>/dev/null | head -1 || true)"
    if /bin/ping -I "$NET_IF" -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then DATA_PLANE_OK=1; break; fi
    warn "WWAN data-path test $DATA_TEST_ATTEMPT/4 failed; forced route: ${ROUTE_LINE:-none}"
    sleep 4
  done
  if [ "$DATA_PLANE_OK" -ne 1 ]; then
    warn "The WWAN route exists, but the data path is not working."
    if [ "$BACKEND_USED" = mm ] && [ -n "${MODEM:-}" ]; then clean_modem_bearers "$MODEM"; fi
    if [ "$WIRED_CONFIGURED" -eq 0 ]; then builtin exit 1; fi
    WWAN_CONNECTED=0
    BACKEND_USED=none
  else
    log "Data path through $NET_IF successfully verified after the VyOS commit."
  fi
fi

if [ "$WIRED_CONFIGURED" -eq 1 ]; then
  WIRED_IP="$(ip -4 -o addr show dev "$WIRED_WAN" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
  WIRED_ROUTE="$(ip -4 route show default dev "$WIRED_WAN" 2>/dev/null | head -1 || true)"
  if [ -n "$WIRED_IP" ] && [ -n "$WIRED_ROUTE" ]; then
    log "Wired WAN operational: $WIRED_WAN, IPv4 $WIRED_IP, Route $WIRED_ROUTE"
  else
    warn "Wired WAN $WIRED_WAN is configured but does not currently have a complete lease/default route."
  fi
fi

cat > "$ROUTE_CACHE" <<EOF
GATEWAY=${GATEWAY:-}
INTERFACE=${NET_IF:-}
BACKEND=$BACKEND_USED
EOF
chmod 600 "$ROUTE_CACHE"

write_persistent_config
write_unlock_service_unit
write_service_unit

if [ "$WIRED_CONFIGURED" -eq 1 ]; then
  if [ "$WWAN_CONNECTED" -eq 1 ]; then
    log "Wired WAN active: $WIRED_WAN, Distanz $WIRED_ROUTE_DISTANCE; WWAN $NET_IF remains the fallback with distance $WWAN_ROUTE_DISTANCE."
  else
    log "Wired WAN active: $WIRED_WAN; WWAN is currently unavailable (for example, no SIM or no registration)."
  fi
else
  log "No wired WAN is configured; WWAN is the only Internet path."
fi
if [ "$WWAN_CONNECTED" -eq 1 ]; then
  log "PASS: Ethernet=${WIRED_WAN:-none}, WWAN-Transport $MODEM_TRANSPORT, Backend $BACKEND_USED, Interface $NET_IF."
else
  log "PASS: Ethernet=$WIRED_WAN active; WWAN is not connected, but configuration and autostart were installed."
fi
log "Autostart enabled: modem-unlock.service -> modem-connect.service; selection/APN saved in $CONFIG_FILE."
ip -4 route show default
builtin exit 0


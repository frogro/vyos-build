#!/bin/bash
set -euo pipefail

MERGED_ROOT="${1:?Path to the merged root filesystem is missing}"
SCRIPT_DIR="${2:?Path to the first-boot directory is missing}"

[[ $EUID -eq 0 ]] || {
    echo "Run this script as root." >&2
    exit 1
}

[[ -d "$MERGED_ROOT" ]] || {
    echo "Root filesystem not found: $MERGED_ROOT" >&2
    exit 1
}

for REQUIRED in \
    config.boot.default \
    dhcp-wan-ssh-setup.sh \
    rock5b-dhcp-wan-firstboot-wrapper.sh \
    rock5b-dhcp-wan-firstboot.service \
    rock5b-dhcp-wan-firstboot.timer \
    vyos-postconfig-bootup.script; do
    [[ -f "$SCRIPT_DIR/$REQUIRED" ]] || {
        echo "Required file is missing: $SCRIPT_DIR/$REQUIRED" >&2
        exit 1
    }
done

# Use a UTF-8 locale that is present in the minimal VyOS root filesystem.
# Setting this during image creation prevents Perl locale warnings during the
# very first vyos-router boot, before set-locales.sh can be run interactively.
install -d -m 0755 \
    "$MERGED_ROOT/etc/default" \
    "$MERGED_ROOT/etc/systemd/system.conf.d"

cat > "$MERGED_ROOT/etc/default/locale" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

cat > "$MERGED_ROOT/etc/environment" <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

cat > "$MERGED_ROOT/etc/systemd/system.conf.d/10-rock5b-locale.conf" <<'EOF'
[Manager]
DefaultEnvironment=LANG=C.UTF-8 LC_ALL=C.UTF-8
EOF

chmod 0644 \
    "$MERGED_ROOT/etc/default/locale" \
    "$MERGED_ROOT/etc/environment" \
    "$MERGED_ROOT/etc/systemd/system.conf.d/10-rock5b-locale.conf"

# Host keys must be unique per installed system. Remove any keys inherited
# from a build root so OpenSSH/VyOS can generate fresh keys on first boot.
rm -f "$MERGED_ROOT"/etc/ssh/ssh_host_*_key
rm -f "$MERGED_ROOT"/etc/ssh/ssh_host_*_key.pub

install -d "$MERGED_ROOT/config"
if [[ -f "$MERGED_ROOT/config/config.boot" ]]; then
    cp -a \
        "$MERGED_ROOT/config/config.boot" \
        "$MERGED_ROOT/config/config.boot.before-inject"
fi
install -m 0644 \
    "$SCRIPT_DIR/config.boot.default" \
    "$MERGED_ROOT/config/config.boot"

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
fi

install -d "$MERGED_ROOT/home/vyos"

for F in \
    ap-dhcp-wan-setup.sh \
    dhcp-wan-ssh-setup.sh \
    set-locales.sh \
    modem-connect.sh; do
    [[ -f "$SCRIPT_DIR/$F" ]] || continue
    install -m 0755 "$SCRIPT_DIR/$F" "$MERGED_ROOT/home/vyos/$F"
done

if [[ -d "$SCRIPT_DIR/home-dotfiles" ]]; then
    for F in .bashrc .profile .bash_logout; do
        [[ -f "$SCRIPT_DIR/home-dotfiles/$F" ]] || continue
        install -m 0644 \
            "$SCRIPT_DIR/home-dotfiles/$F" \
            "$MERGED_ROOT/home/vyos/$F"
    done
    rm -f \
        "$MERGED_ROOT/home/vyos/.bash_profile" \
        "$MERGED_ROOT/home/vyos/.bash_login"
fi

for F in \
    ap-dhcp-wan-setup.sh \
    dhcp-wan-ssh-setup.sh \
    set-locales.sh \
    modem-connect.sh \
    .bashrc \
    .profile \
    .bash_logout; do
    [[ -e "$MERGED_ROOT/home/vyos/$F" ]] || continue
    chown --reference="$MERGED_ROOT/home/vyos" "$MERGED_ROOT/home/vyos/$F"
done

# Remove every previous first-boot implementation.
rm -f "$MERGED_ROOT/usr/local/sbin/rock5b-eth0-firstboot.sh"
rm -f "$MERGED_ROOT/etc/systemd/system/rock5b-eth0-firstboot.service"
rm -f "$MERGED_ROOT/etc/systemd/system/eth0-force-up.service"
rm -f "$MERGED_ROOT/etc/systemd/system/rock5b-dhcp-wan-ssh-firstboot.service"
rm -f "$MERGED_ROOT/etc/systemd/system/rock5b-dhcp-wan-ssh-firstboot.timer"
rm -f "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/rock5b-eth0-firstboot.service"
rm -f "$MERGED_ROOT/etc/systemd/system/multi-user.target.wants/eth0-force-up.service"
rm -f "$MERGED_ROOT/etc/systemd/system/timers.target.wants/rock5b-dhcp-wan-ssh-firstboot.timer"
rm -f "$MERGED_ROOT/config/.rock5b-eth0-firstboot-done"
rm -f "$MERGED_ROOT/config/.dhcp-wan-ssh-firstboot-done"
rm -f "$MERGED_ROOT/config/.dhcp-wan-interface"

# Install the current two-stage implementation.
install -D -m 0755 \
    "$SCRIPT_DIR/rock5b-dhcp-wan-firstboot-wrapper.sh" \
    "$MERGED_ROOT/usr/local/sbin/rock5b-dhcp-wan-firstboot-wrapper.sh"
chown root:root \
    "$MERGED_ROOT/usr/local/sbin/rock5b-dhcp-wan-firstboot-wrapper.sh"

install -D -m 0644 \
    "$SCRIPT_DIR/rock5b-dhcp-wan-firstboot.service" \
    "$MERGED_ROOT/etc/systemd/system/rock5b-dhcp-wan-firstboot.service"
install -D -m 0644 \
    "$SCRIPT_DIR/rock5b-dhcp-wan-firstboot.timer" \
    "$MERGED_ROOT/etc/systemd/system/rock5b-dhcp-wan-firstboot.timer"

install -d "$MERGED_ROOT/etc/systemd/system/timers.target.wants"
ln -sfn \
    ../rock5b-dhcp-wan-firstboot.timer \
    "$MERGED_ROOT/etc/systemd/system/timers.target.wants/rock5b-dhcp-wan-firstboot.timer"

# Replace the old custom post-configuration hook with a no-op hook.
VYATTACFG_GID="$(
    awk -F: '$1=="vyattacfg" {print $3; exit}' \
        "$MERGED_ROOT/etc/group" 2>/dev/null || true
)"

for TARGET in \
    "$MERGED_ROOT/opt/vyatta/etc/config/scripts/vyos-postconfig-bootup.script" \
    "$MERGED_ROOT/config/scripts/vyos-postconfig-bootup.script"; do
    install -D -m 0750 \
        "$SCRIPT_DIR/vyos-postconfig-bootup.script" \
        "$TARGET"
    if [[ -n "$VYATTACFG_GID" ]]; then
        chown 0:"$VYATTACFG_GID" "$TARGET"
    else
        chown root:root "$TARGET"
    fi
done

# Fail the build if the expected first-boot components were not installed.
grep -q \
    'Unit=rock5b-dhcp-wan-firstboot.service' \
    "$MERGED_ROOT/etc/systemd/system/rock5b-dhcp-wan-firstboot.timer"
grep -q \
    'dhclient@' \
    "$MERGED_ROOT/usr/local/sbin/rock5b-dhcp-wan-firstboot-wrapper.sh"
test -L \
    "$MERGED_ROOT/etc/systemd/system/timers.target.wants/rock5b-dhcp-wan-firstboot.timer"
grep -qx \
    'LANG=C.UTF-8' \
    "$MERGED_ROOT/etc/default/locale"
grep -qx \
    'LC_ALL=C.UTF-8' \
    "$MERGED_ROOT/etc/default/locale"

rm -f "$MERGED_ROOT/persistence.conf" 2>/dev/null || true

echo "Done: defaults, C.UTF-8 locale, and two-stage DHCP WAN/SSH first boot installed."

#!/usr/bin/env bash
# Smart Score Pi Bootstrap
# Run on a fresh Raspberry Pi OS Lite 64-bit (Trixie / Debian 13)
#
#   curl -fsSL https://raw.githubusercontent.com/paolinellih/smart-score-pi-image/main/setup.sh | sudo bash
#
# Takes ~15 min on a Pi 4 (npm compiles native modules).
# After completion, run: sudo reboot

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GH_TOKEN="${1:-}"
[[ -z "$GH_TOKEN" ]] && fail "Usage: curl ... | sudo bash -s -- GITHUB_DEPLOY_TOKEN"
REPO_URL="https://${GH_TOKEN}@github.com/paolinellih/smart-score-middleware.git"
NODE_VERSION=22
APP_USER="raspberrypi"
APP_DIR="/home/${APP_USER}/smart-score-middleware"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;32m[Smart Score]\033[0m $*"; }
fail() { echo -e "\033[1;31m[FAIL]\033[0m $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && fail "Run as root: curl ... | sudo bash"
[[ $(uname -m) != "aarch64" ]] && fail "Requires 64-bit ARM (Raspberry Pi 4 or 5)"

# ── Hostname (unique per Pi: smart-score-pi-XXXX using last 4 hex of MAC) ────
log "Setting unique hostname..."
_mac=$(cat /sys/class/net/eth0/address 2>/dev/null \
     || cat /sys/class/net/wlan0/address 2>/dev/null \
     || echo "00:00:00:de:ad:00")
MAC_SUFFIX=$(printf '%s' "$_mac" | tr -d ':\n' | tail -c 4 | tr 'a-f' 'A-F')
HOSTNAME="smart-score-pi-${MAC_SUFFIX}"

hostnamectl set-hostname "$HOSTNAME"
if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts
else
  echo "127.0.1.1	${HOSTNAME}" >> /etc/hosts
fi
log "Hostname → ${HOSTNAME}"

# ── System packages ────────────────────────────────────────────────────────────
log "Installing system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl ca-certificates \
  bluetooth bluez \
  iptables rfkill \
  libcap2-bin \
  labwc seatd \
  chromium \
  fonts-liberation \
  avahi-daemon

# ── Bluetooth / BLE ────────────────────────────────────────────────────────────
log "Unblocking Bluetooth and WiFi..."
rfkill unblock all
systemctl enable bluetooth
systemctl start bluetooth || true

# ── Node.js 22 LTS ────────────────────────────────────────────────────────────
log "Installing Node.js ${NODE_VERSION} LTS..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
node --version
npm --version

# ── Node capabilities (BLE + port 80) ─────────────────────────────────────────
log "Setting Node.js capabilities..."
# cap_net_raw  = BLE (noble)   cap_net_bind_service = listen on port 80 (captive portal)
setcap 'cap_net_raw,cap_net_bind_service=+ep' "$(which node)"
# hcitool: fast BLE connections (2s vs 40s without this)
setcap 'cap_net_raw,cap_net_admin+eip' /usr/bin/hcitool || true

# ── NetworkManager polkit rule ─────────────────────────────────────────────────
log "Configuring NetworkManager polkit..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-smartscore-nm.rules << 'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        subject.user === "raspberrypi") {
        return polkit.Result.YES;
    }
});
POLKIT

# ── Clone & build middleware ───────────────────────────────────────────────────
log "Cloning smart-score-middleware..."
rm -rf "$APP_DIR"
sudo -u "$APP_USER" git clone "$REPO_URL" "$APP_DIR"

log "Running npm install (5-10 min — compiling native modules)..."
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && npm install"

log "Building middleware..."
sudo -u "$APP_USER" bash -c "cd '$APP_DIR' && npm run build"

# ── Systemd service ────────────────────────────────────────────────────────────
log "Installing smart-score.service..."
cat > /etc/systemd/system/smart-score.service << SERVICE
[Unit]
Description=Smart Score Middleware
After=network-online.target bluetooth.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/node dist/server/index.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable smart-score.service
systemctl start smart-score.service

# ── Kiosk display: autologin → labwc → Chromium ───────────────────────────────
log "Configuring kiosk display (labwc + Chromium)..."

# Autologin on tty1 (labwc is launched from .bash_profile)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${APP_USER} --noclear %I \$TERM
AUTOLOGIN

# .bash_profile: start labwc on tty1 (cage doesn't work on Trixie)
BASH_PROFILE="/home/${APP_USER}/.bash_profile"
if ! grep -q "labwc" "$BASH_PROFILE" 2>/dev/null; then
  cat >> "$BASH_PROFILE" << 'PROFILE'
if [ "$(tty)" = "/dev/tty1" ]; then
    exec labwc
fi
PROFILE
  chown "${APP_USER}:${APP_USER}" "$BASH_PROFILE"
fi

# labwc autostart: wait for middleware, then launch Chromium kiosk
LAB_CFG="/home/${APP_USER}/.config/labwc"
mkdir -p "$LAB_CFG"
cat > "$LAB_CFG/autostart" << 'AUTOSTART'
#!/bin/sh
until curl -sf http://localhost:3000/api/health > /dev/null 2>&1; do sleep 2; done
chromium \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --ozone-platform=wayland \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  http://localhost:3000 &
AUTOSTART
chmod +x "$LAB_CFG/autostart"
chown -R "${APP_USER}:${APP_USER}" "/home/${APP_USER}/.config"

# seatd: required for Wayland display access on Pi OS Lite
systemctl enable seatd
systemctl start seatd || true
usermod -aG _seatd "$APP_USER" || true

# ── Boot: suppress rainbow splash ─────────────────────────────────────────────
log "Configuring boot display..."
CONFIG_TXT="/boot/firmware/config.txt"
CMDLINE_TXT="/boot/firmware/cmdline.txt"
[ -f "$CONFIG_TXT" ] && grep -q "disable_splash" "$CONFIG_TXT" || \
  echo "disable_splash=1" >> "$CONFIG_TXT"
if [ -f "$CMDLINE_TXT" ] && ! grep -q "quiet" "$CMDLINE_TXT"; then
  sed -i 's/$/ quiet splash loglevel=0 logo.nologo vt.global_cursor_default=0/' "$CMDLINE_TXT"
fi

log ""
log "╔══════════════════════════════════════════════╗"
log "║  Smart Score setup complete!                 ║"
log "║                                              ║"
log "║  Reboot to start everything:                 ║"
log "║    sudo reboot                               ║"
log "║                                              ║"
log "║  After reboot, provisioner connects at:      ║"
log "║    http://${HOSTNAME}.local:3000             ║"
log "╚══════════════════════════════════════════════╝"
log ""

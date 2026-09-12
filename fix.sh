#!/usr/bin/env bash
# Smart Score Pi - quick fix script
# curl -fsSL https://raw.githubusercontent.com/paolinellih/smart-score-pi-image/main/fix.sh | bash

set -euo pipefail

# 1. Permanent static IP on eth0 for direct laptop cable access
echo "→ Setting permanent eth0 IP 169.254.100.2..."
nmcli con show "direct-laptop" &>/dev/null && nmcli con delete "direct-laptop" || true
nmcli con add type ethernet ifname eth0 con-name "direct-laptop" \
  ipv4.method manual ipv4.addresses "169.254.100.2/16" \
  connection.autoconnect yes
nmcli con up "direct-laptop" || true

# 2. Add laptop SSH key to authorized_keys
echo "→ Adding SSH key..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH8QSRL5UPJdQlgVYmRR8WA3h+9MLV0IvOQWPzFkbozU tinit@TINIT"
grep -qF "$KEY" ~/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# 3. Fix labwc autostart: --app instead of --kiosk (cursor + home key fix)
echo "→ Fixing labwc autostart..."
AUTOSTART="$HOME/.config/labwc/autostart"
mkdir -p "$HOME/.config/labwc"
cat > "$AUTOSTART" << 'AUTOSTART_EOF'
#!/bin/sh
until curl -sf http://localhost:3000/api/health > /dev/null 2>&1; do sleep 2; done
chromium \
  --app=http://localhost:3000 \
  --start-fullscreen \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --ozone-platform=wayland \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --disable-restore-session-state &
AUTOSTART_EOF
chmod +x "$AUTOSTART"

# 4. Fix labwc rc.xml: cursor hides after 3s idle
echo "→ Fixing labwc cursor config..."
cat > "$HOME/.config/labwc/rc.xml" << 'RC_EOF'
<?xml version="1.0"?>
<openbox_config>
  <core><gap>0</gap></core>
  <mouse>
    <cursorHideWhenIdle>yes</cursorHideWhenIdle>
    <cursorHideTimeout>3000</cursorHideTimeout>
  </mouse>
</openbox_config>
RC_EOF

# 5. Disable WiFi power saving (stops connection drops)
echo "→ Disabling WiFi power saving..."
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/wifi-powersave.conf > /dev/null << 'NM_EOF'
[connection]
wifi.powersave = 2
NM_EOF
sudo nmcli radio wifi on
sudo iwconfig wlan0 power off 2>/dev/null || true

echo ""
echo "✓ All fixes applied. Run: sudo reboot"

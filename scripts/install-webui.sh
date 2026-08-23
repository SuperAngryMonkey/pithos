#!/bin/bash
# Pithos web UI installer.
# Sets up the Flask app at /opt/pithos/ and a systemd service on port 8080.
# Safe to re-run; replaces existing install.

set -euo pipefail

REPO_RAW="${PITHOS_REPO_RAW:-https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main}"
INSTALL_DIR="/opt/pithos"
PORT="${PORT:-8080}"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

echo "[*] Pithos web UI installer"
echo

# Verify the CLI tools exist (they're called by the web UI)
if [[ ! -x /usr/local/sbin/pithos-new ]]; then
    echo "ERROR: /usr/local/sbin/pithos-new not found." >&2
    echo "       Run scripts/install.sh first." >&2
    exit 1
fi

# Stop and clean any previous install
if systemctl is-active --quiet pithos 2>/dev/null; then
    echo "[*] Stopping existing pithos service..."
    systemctl stop pithos
fi
# Clean up the old name if it was used during early development
systemctl stop ts-clone-webui 2>/dev/null || true
systemctl disable ts-clone-webui 2>/dev/null || true
rm -f /etc/systemd/system/ts-clone-webui.service
rm -rf /opt/ts-clone-webui

# Try local checkout first, fall back to curl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_APP="$(dirname "$SCRIPT_DIR")/webui/app.py"

mkdir -p "$INSTALL_DIR"

echo "[*] Installing Python dependencies..."
apt-get update -qq
apt-get install -y -qq python3-flask

echo "[*] Installing Flask app..."
if [[ -f "$LOCAL_APP" ]]; then
    cp "$LOCAL_APP" "$INSTALL_DIR/app.py"
    echo "    [+] $INSTALL_DIR/app.py (from local checkout)"
else
    curl -fsSL "$REPO_RAW/webui/app.py" -o "$INSTALL_DIR/app.py"
    echo "    [+] $INSTALL_DIR/app.py (from repo)"
fi
chmod +x "$INSTALL_DIR/app.py"

echo "[*] Writing systemd unit..."
cat > /etc/systemd/system/pithos.service <<UNIT_EOF
[Unit]
Description=Pithos - Tailscale LXC provisioner web UI
After=network-online.target

[Service]
Type=simple
User=root
Environment=PORT=${PORT}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable --now pithos.service
sleep 2

if ! systemctl is-active --quiet pithos; then
    echo "ERROR: pithos service failed to start" >&2
    journalctl -u pithos -n 20 --no-pager
    exit 1
fi

LAN_IP=$(ip -4 addr show vmbr0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
[[ -z "$LAN_IP" ]] && LAN_IP="<your-host-ip>"

echo
echo "[✓] Pithos web UI running."
echo
echo "Access:  http://${LAN_IP}:${PORT}/"
echo
echo "Service: systemctl status pithos"
echo "Logs:    journalctl -u pithos -f"

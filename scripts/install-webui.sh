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
# BASH_SOURCE is unset when the script is piped into bash, which under set -u
# aborts before anything runs. Fall back to $0, then to empty.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
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

# --- credential ----------------------------------------------------------
# Pithos can create and destroy guests as root, so it must not be reachable
# without a password. Generate one unless the operator already made an auth
# file; PITHOS_NO_AUTH=1 opts out deliberately for an isolated lab.
AUTH_FILE="${AUTH_FILE:-/root/.pithos/auth}"
GENERATED_PASS=""
if [[ -f "$AUTH_FILE" ]]; then
    echo "[*] Existing credential at $AUTH_FILE - leaving it alone."
elif [[ "${PITHOS_NO_AUTH:-0}" == "1" ]]; then
    echo "[!] PITHOS_NO_AUTH=1 - installing with NO authentication."
    echo "[!] Anything that can reach this port can provision as root."
else
    GENERATED_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
    HASH=$(python3 -c "from werkzeug.security import generate_password_hash as g; import sys; print(g(sys.argv[1]))" "$GENERATED_PASS")
    mkdir -p "$(dirname "$AUTH_FILE")" && chmod 700 "$(dirname "$AUTH_FILE")"
    printf 'admin:%s\n' "$HASH" > "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    # Also drop it where it can be recovered: on a fresh host the install
    # output scrolls, and only the hash is kept in the auth file.
    printf 'admin\n%s\n' "$GENERATED_PASS" > /root/.pithos/initial-password
    chmod 600 /root/.pithos/initial-password
    echo "[*] Generated an admin credential."
fi

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
if [[ -n "$GENERATED_PASS" ]]; then
    echo "Sign in:  admin / $GENERATED_PASS"
    echo
    echo
    echo "          Also saved to /root/.pithos/initial-password"
    echo "          (root-only). Delete it once you have stored it."
    echo "          To change the password: delete $AUTH_FILE and re-run."
    echo
fi
echo "Service: systemctl status pithos"
echo "Logs:    journalctl -u pithos -f"

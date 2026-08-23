#!/bin/bash
# pithos-uninstall
# Cleanly removes Pithos from a Proxmox host.
# Asks before destroying the template and OAuth credentials.

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

echo "Pithos uninstall"
echo "===================="
echo

# Stop and remove the web UI service
if systemctl is-active --quiet pithos 2>/dev/null; then
    echo "[*] Stopping pithos service..."
    systemctl stop pithos
fi
if [[ -f /etc/systemd/system/pithos.service ]]; then
    systemctl disable pithos 2>/dev/null || true
    rm -f /etc/systemd/system/pithos.service
    echo "[*] Removed systemd unit"
fi

# Clean up legacy service name if present
if systemctl list-unit-files 2>/dev/null | grep -q ts-clone-webui; then
    systemctl stop ts-clone-webui 2>/dev/null || true
    systemctl disable ts-clone-webui 2>/dev/null || true
    rm -f /etc/systemd/system/ts-clone-webui.service
    rm -rf /opt/ts-clone-webui
    echo "[*] Removed legacy ts-clone-webui service"
fi

systemctl daemon-reload

# Remove Flask app
if [[ -d /opt/pithos ]]; then
    rm -rf /opt/pithos
    echo "[*] Removed /opt/pithos"
fi

# Remove CLI scripts
for s in pithos-build-template pithos-new pithos-preflight pithos-uninstall; do
    if [[ -e /usr/local/sbin/$s ]]; then
        rm -f /usr/local/sbin/$s
        echo "[*] Removed /usr/local/sbin/$s"
    fi
done

# Legacy script names
for s in build-tailscale-template.sh new-tailscale-ct.sh; do
    if [[ -e /usr/local/sbin/$s ]]; then
        rm -f /usr/local/sbin/$s
        echo "[*] Removed legacy /usr/local/sbin/$s"
    fi
done

# Ask about the template
if pct status "$TEMPLATE_VMID" &>/dev/null; then
    echo
    read -r -p "Destroy LXC template VMID $TEMPLATE_VMID? [y/N] " ans
    if [[ "$ans" =~ ^[yY] ]]; then
        # Stop first if it's somehow running
        pct stop "$TEMPLATE_VMID" 2>/dev/null || true
        pct destroy "$TEMPLATE_VMID" --purge
        echo "[*] Destroyed template VMID $TEMPLATE_VMID"
    else
        echo "[!] Template VMID $TEMPLATE_VMID kept."
    fi
fi

# Ask about OAuth credentials
if [[ -f /root/.tailscale/oauth ]]; then
    echo
    read -r -p "Remove OAuth credentials at /root/.tailscale/oauth? [y/N] " ans
    if [[ "$ans" =~ ^[yY] ]]; then
        shred -u /root/.tailscale/oauth 2>/dev/null || rm -f /root/.tailscale/oauth
        rmdir /root/.tailscale 2>/dev/null || true
        echo "[*] Removed OAuth credentials"
    else
        echo "[!] OAuth credentials kept at /root/.tailscale/oauth"
    fi
fi

echo
echo "[OK] Pithos uninstalled."
echo
echo "Note: Cloned containers (VMID 200+) are NOT removed by this script."
echo "      List them with: pct list"
echo "      They continue to run and stay on the tailnet."

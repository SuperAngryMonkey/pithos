#!/bin/bash
# pithos-rejoin
# Mints a fresh Tailscale auth key and injects it into a container,
# then triggers the firstboot service to bring up Tailscale with new identity.
#
# Run on the destination host after a transfer with fresh-identity mode.
#
# Usage: pithos-rejoin <vmid>

set -euo pipefail

OAUTH_FILE="${OAUTH_FILE:-/root/.tailscale/oauth}"
TAG="${TAG:-tag:lxc}"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: pithos-rejoin <vmid>" >&2
    exit 1
fi

VMID="$1"

if [[ ! -e "$OAUTH_FILE" ]]; then
    echo "ERROR: OAuth credentials not found at $OAUTH_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$OAUTH_FILE"

if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
    echo "ERROR: OAuth file missing TS_OAUTH_CLIENT_ID or TS_OAUTH_CLIENT_SECRET" >&2
    exit 1
fi

# Verify container exists and is stopped
if ! pct status "$VMID" &>/dev/null; then
    echo "ERROR: VMID $VMID not found" >&2
    exit 1
fi

STATE=$(pct status "$VMID" | awk '{print $2}')
WAS_RUNNING=0
if [[ "$STATE" == "running" ]]; then
    WAS_RUNNING=1
    echo "[*] Stopping VMID $VMID to inject key..."
    pct stop "$VMID"
fi

# Get OAuth access token
echo "[*] Requesting OAuth access token..."
TOKEN=$(curl -fsS \
    -d "client_id=${TS_OAUTH_CLIENT_ID}" \
    -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    https://api.tailscale.com/api/v2/oauth/token \
    | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: Failed to get OAuth access token" >&2
    [[ $WAS_RUNNING -eq 1 ]] && pct start "$VMID" || true
    exit 1
fi

# Mint a single-use auth key
echo "[*] Minting auth key for $TAG..."
AUTHKEY=$(curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"${TAG}\"]}}},\"expirySeconds\":600}" \
    "https://api.tailscale.com/api/v2/tailnet/-/keys" \
    | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)

if [[ -z "$AUTHKEY" ]]; then
    echo "ERROR: Failed to mint auth key (check tag permissions)" >&2
    [[ $WAS_RUNNING -eq 1 ]] && pct start "$VMID" || true
    exit 1
fi

# Start container temporarily to inject the key
echo "[*] Injecting auth key into VMID $VMID..."
pct start "$VMID"
sleep 3

# Wait for container to be responsive
for i in {1..15}; do
    if pct exec "$VMID" -- true 2>/dev/null; then
        break
    fi
    sleep 1
done

# Inject the key
pct exec "$VMID" -- bash -c "
    mkdir -p /etc/tailscale
    echo '$AUTHKEY' > /etc/tailscale/authkey
    chmod 600 /etc/tailscale/authkey
    systemctl enable tailscale-firstboot.service 2>/dev/null || true
"

# Trigger firstboot now (rather than waiting for next reboot)
echo "[*] Triggering firstboot service..."
pct exec "$VMID" -- bash -c "
    systemctl start tailscale-firstboot.service || true
    sleep 5
    tailscale status 2>/dev/null | head -3 || true
"

echo "[OK] Rejoin complete for VMID $VMID"

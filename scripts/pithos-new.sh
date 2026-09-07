#!/bin/bash
# pithos-new
# Clones the Pithos template, mints a fresh OAuth-based auth key,
# injects it into the new container, and triggers the firstboot service.
#
# Usage: pithos-new <new-vmid> <hostname> [--storage <name>] [--template <vmid>] [--no-onboot]
#
# Examples:
#   pithos-new 201 lab-lxc-01
#   pithos-new 202 db-cache --storage local-zfs
#
# Override defaults via env vars:
#   TEMPLATE_VMID=9001 TAG=tag:prod pithos-new 201 prod-lxc-01
#   STORAGE=data-nvme pithos-new 203 fast-app

set -euo pipefail

TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
OAUTH_FILE="${OAUTH_FILE:-/root/.tailscale/oauth}"
TAG="${TAG:-tag:lxc}"
STORAGE="${STORAGE:-local-lvm}"
# Start the container when the host boots. On by default.
ONBOOT="${ONBOOT:-1}"
# Network bridge for the clone. Empty means inherit the template's.
BRIDGE="${BRIDGE:-}"
NETWORK_WAIT_RETRIES="${NETWORK_WAIT_RETRIES:-150}"

usage() {
    cat >&2 <<USAGE
Usage: pithos-new <new-vmid> <hostname> [--storage <name>] [--template <vmid>] [--no-onboot]

Arguments:
  new-vmid    VMID for the new container (e.g., 201)
  hostname    Hostname for the new container (used as Tailscale hostname)

Options:
  --storage <name>   Proxmox storage backend to use (default: local-lvm)

Environment overrides:
  TEMPLATE_VMID   VMID of the template (default: 9000)
  OAUTH_FILE      Path to OAuth credentials (default: /root/.tailscale/oauth)
  TAG             Tailscale tag for the device (default: tag:lxc)
  STORAGE         Same as --storage flag (flag takes precedence)

List available storage on this host:
  pvesm status -content rootdir
USAGE
    exit 1
}

# Parse positional args + flags
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage)
            STORAGE="$2"
            shift 2
            ;;
        --template)
            TEMPLATE_VMID="$2"
            shift 2
            ;;
        --bridge)
            BRIDGE="$2"
            shift 2
            ;;
        --bridge=*)
            BRIDGE="${1#--bridge=}"
            shift
            ;;
        --template=*)
            TEMPLATE_VMID="${1#--template=}"
            shift
            ;;
        --onboot)
            ONBOOT=1
            shift
            ;;
        --no-onboot)
            ONBOOT=0
            shift
            ;;
        --storage=*)
            STORAGE="${1#--storage=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
    usage
fi

NEW_VMID="${POSITIONAL[0]}"
NEW_HOST="${POSITIONAL[1]}"

# Validate hostname
if ! [[ "$NEW_HOST" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "ERROR: Hostname must only contain letters, numbers, and hyphens." >&2
    exit 1
fi

# Validate VMID
if ! [[ "$NEW_VMID" =~ ^[0-9]+$ ]] || (( NEW_VMID < 100 )); then
    echo "ERROR: VMID must be a number >= 100." >&2
    exit 1
fi

# Validate storage exists and supports rootdir content
if ! pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
    echo "ERROR: Storage '$STORAGE' not found or does not support container content (rootdir)." >&2
    echo >&2
    echo "Available storage backends supporting containers:" >&2
    pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {printf "  - %s (%s, %s)\n", $1, $2, $3}' >&2 || echo "  (none found)" >&2
    exit 1
fi

# Verify OAuth credentials
if [[ ! -r "$OAUTH_FILE" ]]; then
    echo "ERROR: Cannot read OAuth file $OAUTH_FILE" >&2
    echo "       See README.md, Step 1, for OAuth setup." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$OAUTH_FILE"

if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
    echo "ERROR: TS_OAUTH_CLIENT_ID or TS_OAUTH_CLIENT_SECRET missing in $OAUTH_FILE" >&2
    exit 1
fi

# Verify template exists
if ! pct status "$TEMPLATE_VMID" &>/dev/null; then
    echo "ERROR: Template VMID $TEMPLATE_VMID not found." >&2
    echo "       Run pithos-build-template first." >&2
    exit 1
fi

# Mint a fresh single-use auth key
echo "[*] Requesting OAuth access token..."
ACCESS_TOKEN=$(curl -fsS \
    -d "client_id=${TS_OAUTH_CLIENT_ID}" \
    -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    https://api.tailscale.com/api/v2/oauth/token \
    | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: Failed to get OAuth access token. Check your credentials." >&2
    exit 1
fi

echo "[*] Minting single-use auth key for $TAG..."
TS_KEY=$(curl -fsS \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{
        \"capabilities\": {
            \"devices\": {
                \"create\": {
                    \"reusable\": false,
                    \"ephemeral\": false,
                    \"preauthorized\": true,
                    \"tags\": [\"${TAG}\"]
                }
            }
        },
        \"expirySeconds\": 600
    }" \
    "https://api.tailscale.com/api/v2/tailnet/-/keys" \
    | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)

if [[ -z "$TS_KEY" ]]; then
    echo "ERROR: Failed to mint auth key." >&2
    echo "       Check that '$TAG' is in your tailnet's tagOwners and that your" >&2
    echo "       OAuth client is authorized for it." >&2
    exit 1
fi

# Clone
echo "[*] Cloning $TEMPLATE_VMID -> $NEW_VMID ($NEW_HOST) on storage '$STORAGE'..."
pct clone "$TEMPLATE_VMID" "$NEW_VMID" --hostname "$NEW_HOST" --storage "$STORAGE" --full 1

# Start on host boot. Defaults to on: a container that silently stays down
# after a power cut is almost never what anyone wants.
if [[ -n "$BRIDGE" ]]; then
    # Clones inherit the template's bridge, which on a host with a public
    # bridge would put the container straight on the internet.
    echo "[*] Attaching to bridge $BRIDGE"
    pct set "$NEW_VMID" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1"
fi

pct set "$NEW_VMID" --onboot "$ONBOOT"
if [[ "$ONBOOT" == "1" ]]; then
    echo "[*] onboot enabled - will start automatically after a host reboot"
else
    echo "[!] onboot DISABLED - this container will NOT start after a host reboot"
fi

echo "[*] Starting container..."
pct start "$NEW_VMID"

echo "[*] Waiting for network..."
NET_OK=0
for ((i=1; i<=NETWORK_WAIT_RETRIES; i++)); do
    if pct exec "$NEW_VMID" -- getent hosts api.tailscale.com >/dev/null 2>&1; then
        NET_OK=1
        break
    fi
    sleep 2
done
if [[ $NET_OK -eq 0 ]]; then
    echo "WARNING: Network slow to come up; continuing anyway." >&2
fi

echo "[*] Injecting auth key..."
echo "$TS_KEY" | pct exec "$NEW_VMID" -- tee /etc/tailscale/authkey >/dev/null
pct exec "$NEW_VMID" -- chmod 600 /etc/tailscale/authkey

echo "[*] Triggering Tailscale join..."
pct exec "$NEW_VMID" -- systemctl start tailscale-firstboot.service

sleep 4
echo
echo "[OK] $NEW_HOST should be on the tailnet."
echo "     Verify: pct exec $NEW_VMID -- tailscale status"

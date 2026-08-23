#!/bin/bash
# pithos-build-template
# Builds a Debian 12 LXC template with Tailscale pre-installed.
# Cloned containers auto-join the tailnet on first boot via OAuth-minted keys.
#
# Run on a Proxmox VE host as root.
#
# Override defaults via env vars or flags:
#   STORAGE=local-zfs BRIDGE=vmbr1 VMID=9001 pithos-build-template
#   pithos-build-template --storage local-zfs --bridge vmbr1

set -euo pipefail

VMID="${VMID:-9000}"
HOSTNAME="${TEMPLATE_HOSTNAME:-pithos-tmpl}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_GB="${DISK_GB:-4}"
MEMORY_MB="${MEMORY_MB:-512}"
CORES="${CORES:-1}"
NETWORK_WAIT_RETRIES="${NETWORK_WAIT_RETRIES:-150}"

usage() {
    cat >&2 <<USAGE
Usage: pithos-build-template [options]

Options:
  --vmid <n>          VMID for the template (default: 9000)
  --storage <name>    Proxmox storage for the template (default: local-lvm)
  --bridge <name>     Network bridge for the template (default: vmbr0)
  --template-storage  Storage where pveam templates live (default: local)
  -h, --help          Show this help

Environment overrides (same as flags):
  VMID, STORAGE, BRIDGE, TEMPLATE_STORAGE,
  DISK_GB (default: 4), MEMORY_MB (default: 512), CORES (default: 1)

List available resources before running:
  pvesm status -content rootdir          # storage backends
  ip -o link show type bridge            # network bridges
  pveam list local | grep debian-12      # downloaded templates

USAGE
    exit 1
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)             VMID="$2"; shift 2 ;;
        --vmid=*)           VMID="${1#--vmid=}"; shift ;;
        --storage)          STORAGE="$2"; shift 2 ;;
        --storage=*)        STORAGE="${1#--storage=}"; shift ;;
        --bridge)           BRIDGE="$2"; shift 2 ;;
        --bridge=*)         BRIDGE="${1#--bridge=}"; shift ;;
        --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
        -h|--help)          usage ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

echo "[*] Pithos template builder"
echo "    VMID=$VMID  STORAGE=$STORAGE  BRIDGE=$BRIDGE  DISK=${DISK_GB}G"
echo

# Validate storage exists and supports rootdir
if ! pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
    echo "ERROR: Storage '$STORAGE' not found or does not support container content (rootdir)." >&2
    echo >&2
    echo "Available storage backends:" >&2
    pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {printf "  - %s (%s)\n", $1, $2}' >&2 || echo "  (none found)" >&2
    exit 1
fi

# Validate bridge exists
if ! ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -qx "$BRIDGE"; then
    echo "ERROR: Bridge '$BRIDGE' not found." >&2
    echo >&2
    echo "Available bridges:" >&2
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print "  - " $2}' >&2 || echo "  (none found)" >&2
    exit 1
fi

# Find the latest debian-12-standard template
echo "[*] Updating pveam template list..."
pveam update >/dev/null

LATEST=$(pveam available --section system 2>/dev/null | awk '$2 ~ /debian-12-standard/ {print $2}' | sort -V | tail -n1)
if [[ -z "$LATEST" ]]; then
    LATEST=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-12/ {print $2}' | sort -V | tail -n1)
fi
if [[ -z "$LATEST" ]]; then
    echo "ERROR: No debian-12 template found in pveam." >&2
    echo "       Run: pveam update && pveam available --section system | grep debian-12" >&2
    exit 1
fi
echo "[*] Using Debian template: $LATEST"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$LATEST"; then
    echo "[*] Downloading $LATEST..."
    pveam download "$TEMPLATE_STORAGE" "$LATEST"
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${LATEST}"

# Bail if VMID is in use
if pct status "$VMID" &>/dev/null; then
    echo "ERROR: VMID $VMID already exists." >&2
    echo "       Destroy it (pct destroy $VMID --purge) or use --vmid <other>." >&2
    exit 1
fi

# Create the unprivileged LXC
echo "[*] Creating unprivileged LXC $VMID..."
pct create "$VMID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap 512 \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 \
    --onboot 0 \
    --start 0

# TUN device passthrough — required for Tailscale in unprivileged LXC
echo "[*] Adding TUN device passthrough..."
cat >> "/etc/pve/lxc/${VMID}.conf" <<TUN_EOF
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN_EOF

# Boot and wait for network
echo "[*] Starting container..."
pct start "$VMID"

echo "[*] Waiting for DHCP + DNS (up to $((NETWORK_WAIT_RETRIES * 2))s)..."
NETWORK_READY=0
for ((i=1; i<=NETWORK_WAIT_RETRIES; i++)); do
    if pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
        echo "    Network ready after $((i*2))s"
        NETWORK_READY=1
        break
    fi
    sleep 2
done
if [[ $NETWORK_READY -eq 0 ]]; then
    echo "ERROR: Network never came up within timeout." >&2
    echo "       Check: pct exec $VMID -- ip addr show eth0" >&2
    echo "       Check: pct exec $VMID -- journalctl -u networking" >&2
    exit 1
fi

# Provision Tailscale + the firstboot service inside the container
echo "[*] Installing packages and Tailscale..."
pct exec "$VMID" -- bash -euo pipefail <<'INNER_EOF'
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl sudo gnupg ca-certificates

# Tailscale official repo for Bookworm
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    -o /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale

# Enable on boot but don't start now (no auth key yet)
systemctl enable tailscaled

# Set up the firstboot auto-join service
mkdir -p /etc/tailscale

cat > /usr/local/sbin/tailscale-firstboot.sh <<'FB_EOF'
#!/bin/bash
set -euo pipefail
KEYFILE="/etc/tailscale/authkey"
LOG="/var/log/tailscale-firstboot.log"
exec >>"$LOG" 2>&1
echo "=== $(date -u) tailscale-firstboot starting ==="

if [[ ! -s "$KEYFILE" ]]; then
    echo "No auth key at $KEYFILE — skipping."
    exit 0
fi

for i in {1..30}; do
    tailscale status --json >/dev/null 2>&1 && break
    sleep 1
done

AUTHKEY=$(tr -d '[:space:]' < "$KEYFILE")
HN=$(hostname)

EXTRAS=""
if [[ -f /etc/tailscale/up-extras ]]; then
    EXTRAS=$(grep -v '^[[:space:]]*#' /etc/tailscale/up-extras | tr '\n' ' ')
fi

echo "Bringing up tailscale as $HN with extras: $EXTRAS"
tailscale up \
    --auth-key="$AUTHKEY" \
    --hostname="$HN" \
    --ssh \
    --accept-routes \
    $EXTRAS

shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"

systemctl disable tailscale-firstboot.service
echo "=== done ==="
FB_EOF
chmod +x /usr/local/sbin/tailscale-firstboot.sh

cat > /etc/systemd/system/tailscale-firstboot.service <<'UNIT_EOF'
[Unit]
Description=Tailscale first-boot auto-join
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
ConditionPathExists=/etc/tailscale/authkey

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl enable tailscale-firstboot.service

# Cleanup so clones get fresh identity
apt-get clean
rm -rf /var/lib/apt/lists/*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "pithos-template built $(date -u)" > /etc/pithos-template-version
INNER_EOF

# Stop and convert
echo "[*] Stopping container..."
pct stop "$VMID"

echo "[*] Converting to template..."
pct template "$VMID"

echo
echo "[OK] Pithos template VMID $VMID is ready on storage '$STORAGE'."
echo "     Spin up clones with: pithos-new <new-vmid> <hostname>"
echo "     Or via web UI:       http://<this-host>:8080/"

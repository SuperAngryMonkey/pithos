#!/bin/bash
# pithos-transfer
# Cold-migrate an LXC container from this Proxmox host to another over Tailscale.
#
# Usage:
#   pithos-transfer <vmid> <dest-fqdn> [--storage <name>] [--preserve-identity]
#
# Examples:
#   pithos-transfer 200 proxmox.tailnet-example.ts.net
#   pithos-transfer 201 proxmox.tailnet-example.ts.net --storage local-zfs
#   pithos-transfer 202 proxmox.tailnet-example.ts.net --preserve-identity
#
# Behavior:
#   1. Stops the source container (if running)
#   2. vzdumps it to a temporary file
#   3. SCPs the dump to the destination's /var/lib/vz/dump
#   4. SSHs to destination and runs pct restore on chosen storage
#   5. If --preserve-identity NOT set (default): runs pithos-rejoin on dest
#      to mint a fresh OAuth key and re-join tailnet with new identity
#   6. Starts the container on the destination
#   7. Writes a JSON audit log entry
#   8. Cleans up local dump file (keeps source container stopped for user review)
#
# The source container is NEVER destroyed. After verification, the user runs:
#   pct destroy <vmid> --purge

set -euo pipefail

LOG_DIR="/var/log/pithos"
LOG_FILE="${LOG_DIR}/transfer.log"
DEFAULT_STORAGE="local-lvm"

usage() {
    cat >&2 <<USAGE
Usage: pithos-transfer <vmid> <dest-fqdn> [options]

Arguments:
  vmid          Source LXC VMID on this host
  dest-fqdn     Tailscale FQDN of destination Proxmox host
                (e.g., proxmox.tailnet-example.ts.net)

Options:
  --storage <name>      Storage backend on destination (default: local-lvm)
  --preserve-identity   Keep the same Tailscale machine key (advanced)
  -h, --help            Show this help

The default behavior is "fresh identity" — the container joins the tailnet
on the destination with a new auth key (new Tailscale IP). Use
--preserve-identity to keep the same machine key (same IP, but be careful
not to start the source after — see docs/v0.2-design.md).
USAGE
    exit 1
}

# ---- Parse args ----
PRESERVE_IDENTITY=0
DEST_STORAGE="$DEFAULT_STORAGE"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage)            DEST_STORAGE="$2"; shift 2 ;;
        --storage=*)          DEST_STORAGE="${1#--storage=}"; shift ;;
        --preserve-identity)  PRESERVE_IDENTITY=1; shift ;;
        -h|--help)            usage ;;
        --*)                  echo "ERROR: Unknown option: $1" >&2; usage ;;
        *)                    POSITIONAL+=("$1"); shift ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
    usage
fi

VMID="${POSITIONAL[0]}"
DEST_FQDN="${POSITIONAL[1]}"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# ---- Setup logging ----
mkdir -p "$LOG_DIR"
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_EPOCH=$(date +%s)

log_audit() {
    local status="$1"
    local dest_vmid="${2:-null}"
    local error="${3:-}"
    local end_epoch=$(date +%s)
    local duration=$((end_epoch - START_EPOCH))
    local size_bytes="${TRANSFER_SIZE:-null}"

    # Build JSON entry
    local error_json=""
    if [[ -n "$error" ]]; then
        error_json=",\"error\":\"$(echo "$error" | sed 's/"/\\"/g')\""
    fi

    local dest_vmid_json="null"
    if [[ "$dest_vmid" != "null" ]]; then
        dest_vmid_json="$dest_vmid"
    fi

    local identity="fresh"
    if [[ $PRESERVE_IDENTITY -eq 1 ]]; then
        identity="preserve"
    fi

    cat >> "$LOG_FILE" <<JSON
{"ts":"$START_TIME","src_vmid":$VMID,"src_hostname":"$SRC_HOSTNAME","dest_host":"$DEST_FQDN","dest_vmid":$dest_vmid_json,"identity":"$identity","storage":"$DEST_STORAGE","size_bytes":$size_bytes,"duration_seconds":$duration,"status":"$status"$error_json}
JSON
}

# ---- Validate source container ----
echo "[*] Validating source container..."

if ! pct status "$VMID" &>/dev/null; then
    echo "ERROR: Source VMID $VMID not found." >&2
    log_audit "failed" "null" "Source VMID not found"
    exit 1
fi

# Get source hostname for the audit log
SRC_HOSTNAME=$(pct config "$VMID" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
if [[ -z "$SRC_HOSTNAME" ]]; then
    SRC_HOSTNAME="unknown"
fi

# Check it's not a template
if pct config "$VMID" 2>/dev/null | grep -q "^template:.*1"; then
    echo "ERROR: VMID $VMID is a template, not a container." >&2
    log_audit "failed" "null" "VMID is a template"
    exit 1
fi

SRC_STATE=$(pct status "$VMID" | awk '{print $2}')
echo "    VMID=$VMID  hostname=$SRC_HOSTNAME  state=$SRC_STATE"

# ---- Validate destination reachability ----
echo "[*] Testing SSH to destination..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
         root@"$DEST_FQDN" "echo ok" >/dev/null 2>&1; then
    echo "ERROR: Cannot SSH to root@$DEST_FQDN" >&2
    echo "       Check Tailscale ACL allows SSH between Proxmox hosts." >&2
    log_audit "failed" "null" "SSH to destination failed"
    exit 1
fi

# Verify destination has Pithos installed
if ! ssh -o BatchMode=yes root@"$DEST_FQDN" "command -v pithos-new" >/dev/null 2>&1; then
    echo "ERROR: Destination does not have Pithos installed." >&2
    echo "       Install Pithos on $DEST_FQDN first." >&2
    log_audit "failed" "null" "Destination missing Pithos"
    exit 1
fi

# Validate destination storage exists and supports rootdir
echo "[*] Validating destination storage '$DEST_STORAGE'..."
if ! ssh -o BatchMode=yes root@"$DEST_FQDN" \
        "pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print \$1}' | grep -qx '$DEST_STORAGE'"; then
    echo "ERROR: Storage '$DEST_STORAGE' not available on destination." >&2
    echo "       Available on $DEST_FQDN:" >&2
    ssh -o BatchMode=yes root@"$DEST_FQDN" \
        "pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {printf \"  - %s (%s)\\n\", \$1, \$2}'" >&2 || true
    log_audit "failed" "null" "Destination storage not available"
    exit 1
fi

# Find next free VMID on destination
echo "[*] Finding free VMID on destination..."
DEST_VMID=$(ssh -o BatchMode=yes root@"$DEST_FQDN" 'bash -s' <<'REMOTE'
used=""
for cmd in "pct list" "qm list"; do
    used="$used $($cmd 2>/dev/null | awk 'NR>1 {print $1}')"
done
v=200
while echo " $used " | grep -q " $v "; do
    v=$((v+1))
done
echo "$v"
REMOTE
)
echo "    Will land as VMID $DEST_VMID on $DEST_FQDN"

# ---- Stop source container if running ----
if [[ "$SRC_STATE" == "running" ]]; then
    echo "[*] Stopping source container $VMID..."
    pct stop "$VMID"
fi

# ---- Optionally wipe Tailscale state for fresh identity ----
if [[ $PRESERVE_IDENTITY -eq 0 ]]; then
    echo "[*] Wiping Tailscale state (fresh identity mode)..."
    # Start temporarily to clear state, then stop
    pct start "$VMID"
    sleep 3
    pct exec "$VMID" -- bash -c '
        systemctl stop tailscaled 2>/dev/null || true
        rm -rf /var/lib/tailscale/* 2>/dev/null || true
        # Re-arm firstboot so it joins again when key gets injected
        systemctl enable tailscale-firstboot.service 2>/dev/null || true
    ' || echo "    (warning: state wipe may be incomplete)"
    pct stop "$VMID"
fi

# ---- vzdump source container ----
echo "[*] Running vzdump on source..."
DUMP_DIR="/var/lib/vz/dump"
mkdir -p "$DUMP_DIR"

# Clean any old dump file for this VMID
rm -f "$DUMP_DIR/vzdump-lxc-${VMID}-pithos-transfer.tar.zst"

# vzdump with zstd, mode stop (already stopped)
if ! vzdump "$VMID" --mode stop --compress zstd --dumpdir "$DUMP_DIR" 2>&1 | grep -v '^INFO:' || true; then
    echo "    (vzdump completed with some non-fatal messages)"
fi

# Find the dump file
DUMP_FILE=$(ls -t "$DUMP_DIR"/vzdump-lxc-"$VMID"-*.tar.zst 2>/dev/null | head -1)
if [[ -z "$DUMP_FILE" || ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: vzdump output file not found." >&2
    log_audit "failed" "null" "vzdump output missing"
    # Try to restart source if it was running
    [[ "$SRC_STATE" == "running" ]] && pct start "$VMID" || true
    exit 1
fi

# Rename to a predictable name
TRANSFER_FILE="$DUMP_DIR/vzdump-lxc-${VMID}-pithos-transfer.tar.zst"
mv "$DUMP_FILE" "$TRANSFER_FILE"

TRANSFER_SIZE=$(stat -c %s "$TRANSFER_FILE")
SIZE_MB=$((TRANSFER_SIZE / 1024 / 1024))
echo "    Dump size: ${SIZE_MB}MB"

# ---- SCP to destination ----
REMOTE_FILE="/var/lib/vz/dump/vzdump-lxc-${VMID}-pithos-transfer.tar.zst"
echo "[*] Transferring to $DEST_FQDN..."

# Make sure remote dump dir exists
ssh -o BatchMode=yes root@"$DEST_FQDN" "mkdir -p /var/lib/vz/dump" || {
    echo "ERROR: Cannot create remote dump directory." >&2
    log_audit "failed" "null" "Remote mkdir failed"
    rm -f "$TRANSFER_FILE"
    [[ "$SRC_STATE" == "running" ]] && pct start "$VMID" || true
    exit 1
}

if ! scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
         "$TRANSFER_FILE" "root@$DEST_FQDN:$REMOTE_FILE"; then
    echo "ERROR: SCP transfer failed." >&2
    log_audit "failed" "null" "SCP failed"
    rm -f "$TRANSFER_FILE"
    # Cleanup partial file on destination
    ssh -o BatchMode=yes root@"$DEST_FQDN" "rm -f $REMOTE_FILE" 2>/dev/null || true
    [[ "$SRC_STATE" == "running" ]] && pct start "$VMID" || true
    exit 1
fi

# ---- Restore on destination ----
echo "[*] Restoring on destination as VMID $DEST_VMID..."
if ! ssh -o BatchMode=yes root@"$DEST_FQDN" \
        "pct restore $DEST_VMID $REMOTE_FILE --storage $DEST_STORAGE 2>&1"; then
    echo "ERROR: pct restore failed on destination." >&2
    log_audit "failed" "null" "pct restore failed"
    rm -f "$TRANSFER_FILE"
    ssh -o BatchMode=yes root@"$DEST_FQDN" "rm -f $REMOTE_FILE" 2>/dev/null || true
    [[ "$SRC_STATE" == "running" ]] && pct start "$VMID" || true
    exit 1
fi

# Cleanup remote dump file (no longer needed)
ssh -o BatchMode=yes root@"$DEST_FQDN" "rm -f $REMOTE_FILE" 2>/dev/null || true

# ---- Inject auth key for fresh identity mode ----
if [[ $PRESERVE_IDENTITY -eq 0 ]]; then
    echo "[*] Triggering pithos-rejoin on destination..."
    if ! ssh -o BatchMode=yes root@"$DEST_FQDN" "pithos-rejoin $DEST_VMID"; then
        echo "WARNING: pithos-rejoin failed. Container restored but may not join tailnet automatically." >&2
        echo "         You can re-run manually: ssh root@$DEST_FQDN pithos-rejoin $DEST_VMID" >&2
    fi
fi

# ---- Start the container on destination ----
echo "[*] Starting container on destination..."
if ! ssh -o BatchMode=yes root@"$DEST_FQDN" "pct start $DEST_VMID"; then
    echo "WARNING: pct start failed on destination." >&2
    log_audit "partial" "$DEST_VMID" "Restored but failed to start"
    rm -f "$TRANSFER_FILE"
    exit 1
fi

# ---- If preserving identity, ensure source won't auto-start ----
if [[ $PRESERVE_IDENTITY -eq 1 ]]; then
    pct set "$VMID" -onboot 0 2>/dev/null || true
fi

# ---- Cleanup local dump ----
rm -f "$TRANSFER_FILE"

# ---- Done ----
log_audit "success" "$DEST_VMID"

echo
echo "[OK] Transfer complete."
echo "     Source VMID $VMID on this host (stopped)"
echo "     Destination VMID $DEST_VMID on $DEST_FQDN (running)"
echo "     Identity: $([ $PRESERVE_IDENTITY -eq 1 ] && echo 'preserved' || echo 'fresh')"
echo
echo "Verify on destination:"
echo "  ssh root@$DEST_FQDN 'pct exec $DEST_VMID -- tailscale status'"
echo
echo "When ready to destroy source:"
echo "  pct destroy $VMID --purge"

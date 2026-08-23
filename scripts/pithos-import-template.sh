#!/bin/bash
# pithos-import-template
# Downloads a pre-built Pithos-ready LXC template from GitHub Releases
# and restores it as a Proxmox template at the configured VMID.
#
# Usage: pithos-import-template [--vmid <n>] [--storage <name>] [--url <url>]
#
# Defaults:
#   VMID:    9000
#   Storage: local-lvm
#   URL:     https://github.com/SuperAngryMonkey/pithos/releases/latest/download/pithos-template.tar.zst

set -euo pipefail

VMID="${VMID:-9000}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
URL="${URL:-https://github.com/SuperAngryMonkey/pithos/releases/latest/download/pithos-template.tar.zst}"

usage() {
    cat >&2 <<USAGE
Usage: pithos-import-template [options]

Options:
  --vmid <n>           Target VMID for the imported template (default: 9000)
  --storage <name>     Proxmox storage for the template's rootfs (default: local-lvm)
  --template-storage   Storage where the .tar.zst gets staged (default: local)
  --url <url>          Override the download URL (default: latest GitHub release)
  -h, --help           Show this help

Environment overrides (same as flags):
  VMID, STORAGE, TEMPLATE_STORAGE, URL
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
        --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
        --url)              URL="$2"; shift 2 ;;
        --url=*)            URL="${1#--url=}"; shift ;;
        -h|--help)          usage ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

echo "[*] Pithos template importer"
echo "    VMID=$VMID  STORAGE=$STORAGE  URL=$URL"
echo

# Bail if VMID is in use
if pct status "$VMID" &>/dev/null; then
    echo "ERROR: VMID $VMID already exists." >&2
    echo "       Destroy it (pct destroy $VMID --purge) or use --vmid <other>." >&2
    exit 1
fi

# Validate storage exists and supports rootdir
if ! pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
    echo "ERROR: Storage '$STORAGE' not found or does not support container content (rootdir)." >&2
    echo >&2
    echo "Available storage backends:" >&2
    pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {printf "  - %s (%s)\n", $1, $2}' >&2 || echo "  (none found)" >&2
    exit 1
fi

# Find the dump storage path
DUMP_PATH=$(pvesh get /storage/"$TEMPLATE_STORAGE" --output-format json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('path','/var/lib/vz'))" 2>/dev/null || echo "/var/lib/vz")
DUMP_DIR="${DUMP_PATH}/dump"
mkdir -p "$DUMP_DIR"

LOCAL_FILE="${DUMP_DIR}/pithos-template-import.tar.zst"

# Download
echo "[*] Downloading template from $URL"
echo "    -> $LOCAL_FILE"
if ! curl -fL --progress-bar "$URL" -o "$LOCAL_FILE"; then
    echo "ERROR: Download failed." >&2
    echo "       Check the URL and your internet connection." >&2
    rm -f "$LOCAL_FILE"
    exit 1
fi

SIZE_MB=$(du -m "$LOCAL_FILE" | cut -f1)
echo "[*] Downloaded ${SIZE_MB}MB"

# Restore as template
echo "[*] Restoring as VMID $VMID on storage '$STORAGE'..."
if ! pct restore "$VMID" "$LOCAL_FILE" --storage "$STORAGE"; then
    echo "ERROR: pct restore failed." >&2
    rm -f "$LOCAL_FILE"
    exit 1
fi

# Convert to template
echo "[*] Converting VMID $VMID to template..."
pct template "$VMID"

# Cleanup
rm -f "$LOCAL_FILE"

echo
echo "[OK] Pithos template VMID $VMID is ready."
echo "     Pithos can now clone from it."
echo "     If the web UI is showing 'No Template Found', refresh the page."

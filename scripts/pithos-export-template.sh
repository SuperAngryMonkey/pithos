#!/bin/bash
# pithos-export-template
# Exports an existing Pithos-ready LXC template as a .tar.zst file
# suitable for uploading to GitHub Releases.
#
# Use this on a host where you have a working pithos-build-template result
# to create a portable artifact other users can import.
#
# Usage: pithos-export-template [--vmid <n>] [--output <path>]

set -euo pipefail

VMID="${VMID:-9000}"
OUTPUT="${OUTPUT:-./pithos-template.tar.zst}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

usage() {
    cat >&2 <<USAGE
Usage: pithos-export-template [options]

Options:
  --vmid <n>          VMID of the template to export (default: 9000)
  --output <path>     Output file path (default: ./pithos-template.tar.zst)
  -h, --help          Show this help

The output file can be uploaded to GitHub Releases for users to import
with pithos-import-template.
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)    VMID="$2"; shift 2 ;;
        --vmid=*)  VMID="${1#--vmid=}"; shift ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --output=*) OUTPUT="${1#--output=}"; shift ;;
        -h|--help) usage ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# Verify template exists and is actually a template
if ! pct status "$VMID" &>/dev/null; then
    echo "ERROR: VMID $VMID not found." >&2
    exit 1
fi

if ! pct config "$VMID" | grep -q "^template:.*1"; then
    echo "ERROR: VMID $VMID is not a template (template flag not set)." >&2
    echo "       Use 'pct template $VMID' first if it's just a stopped container." >&2
    exit 1
fi

echo "[*] Pithos template exporter"
echo "    VMID=$VMID  OUTPUT=$OUTPUT"
echo

# Find dump dir
DUMP_PATH=$(pvesh get /storage/"$TEMPLATE_STORAGE" --output-format json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('path','/var/lib/vz'))" 2>/dev/null || echo "/var/lib/vz")
DUMP_DIR="${DUMP_PATH}/dump"
mkdir -p "$DUMP_DIR"

# vzdump with zstd compression
echo "[*] Running vzdump (this can take a minute)..."
vzdump "$VMID" \
    --mode stop \
    --compress zstd \
    --dumpdir "$DUMP_DIR"

# Find the file vzdump just created
LATEST=$(ls -t "$DUMP_DIR"/vzdump-lxc-"$VMID"-*.tar.zst 2>/dev/null | head -1)
if [[ -z "$LATEST" ]]; then
    echo "ERROR: vzdump finished but no .tar.zst found in $DUMP_DIR" >&2
    exit 1
fi

# Move to output path
mkdir -p "$(dirname "$OUTPUT")"
mv "$LATEST" "$OUTPUT"

SIZE_MB=$(du -m "$OUTPUT" | cut -f1)
echo
echo "[OK] Exported template to: $OUTPUT"
echo "     Size: ${SIZE_MB}MB"
echo
echo "Next steps:"
echo "  1. Upload to GitHub Releases as 'pithos-template.tar.zst'"
echo "     gh release upload <version-tag> $OUTPUT"
echo "  2. Users can then import with: pithos-import-template"

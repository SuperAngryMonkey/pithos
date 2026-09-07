#!/bin/bash
# pithos-new-vm - clone a VM template and join it to the tailnet.
#
# The LXC path (pithos-new) clones with pct and injects the Tailscale key with
# pct exec. Neither works for a VM: this clones with qm and hands the key over
# through a cloud-init drive, which Cloudbase-Init (Windows) or cloud-init
# (Linux) consumes on first boot.
set -euo pipefail

TEMPLATE_VMID="${TEMPLATE_VMID:-}"
STORAGE="${STORAGE:-}"
ONBOOT="${ONBOOT:-1}"
BRIDGE="${BRIDGE:-}"   # empty = inherit the template's bridge
OAUTH_FILE="${OAUTH_FILE:-/root/.tailscale/oauth}"
TAG="${TAG:-tag:lxc}"
CIUSER="${CIUSER:-pithos}"
CIPASS="${CIPASS:-ChangeMe1!}"
SNIPPET_STORE="${SNIPPET_STORE:-local}"
SNIPPET_DIR="${SNIPPET_DIR:-/var/lib/vz/snippets}"
KEY_TTL="${KEY_TTL:-1800}"

usage() {
    cat >&2 <<USAGE
Usage: pithos-new-vm <new-vmid> <hostname> --template <vmid> [--storage <name>] [--no-onboot]

  --template <vmid>   VM template to clone (required)
  --storage <name>    target storage for the full clone
  --no-onboot         do not start the VM when the host boots

Env: TEMPLATE_VMID STORAGE ONBOOT TAG CIUSER CIPASS OAUTH_FILE KEY_TTL
USAGE
    exit 1
}

NEW_VMID=""; NEW_HOST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --template)   TEMPLATE_VMID="$2"; shift 2 ;;
        --template=*) TEMPLATE_VMID="${1#--template=}"; shift ;;
        --bridge)     BRIDGE="$2"; shift 2 ;;
        --bridge=*)   BRIDGE="${1#--bridge=}"; shift ;;
        --storage)    STORAGE="$2"; shift 2 ;;
        --storage=*)  STORAGE="${1#--storage=}"; shift ;;
        --onboot)     ONBOOT=1; shift ;;
        --no-onboot)  ONBOOT=0; shift ;;
        -h|--help)    usage ;;
        -*)           echo "Unknown option: $1" >&2; usage ;;
        *)
            if   [[ -z "$NEW_VMID" ]]; then NEW_VMID="$1"
            elif [[ -z "$NEW_HOST" ]]; then NEW_HOST="$1"
            else echo "Unexpected argument: $1" >&2; usage
            fi
            shift ;;
    esac
done

[[ -n "$NEW_VMID" && -n "$NEW_HOST" ]] || usage
[[ -n "$TEMPLATE_VMID" ]] || { echo "ERROR: --template is required" >&2; usage; }
[[ "$NEW_VMID" =~ ^[0-9]+$ ]] || { echo "ERROR: vmid must be numeric" >&2; exit 1; }
[[ "$NEW_HOST" =~ ^[a-zA-Z0-9-]+$ ]] || { echo "ERROR: hostname must be alphanumeric/hyphen" >&2; exit 1; }

# Refuse to clobber anything that already exists, VM or container.
if qm config "$NEW_VMID" >/dev/null 2>&1 || pct config "$NEW_VMID" >/dev/null 2>&1; then
    echo "ERROR: VMID $NEW_VMID already exists" >&2; exit 1
fi
qm config "$TEMPLATE_VMID" >/dev/null 2>&1 || { echo "ERROR: template $TEMPLATE_VMID not found" >&2; exit 1; }
qm config "$TEMPLATE_VMID" | grep -q '^template: *1' || { echo "ERROR: VMID $TEMPLATE_VMID is not a template" >&2; exit 1; }

# ---- Tailscale auth key -------------------------------------------------
# Single-use, short-lived, pre-authorized. Minted per clone: a key baked into a
# template would let any copy of the image join the tailnet.
[[ -f "$OAUTH_FILE" ]] || { echo "ERROR: no OAuth credentials at $OAUTH_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$OAUTH_FILE"

echo "[*] Requesting Tailscale auth key..."
TOKEN=$(curl -fsS -d "client_id=${TS_OAUTH_CLIENT_ID}" \
             -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
             -d "grant_type=client_credentials" \
             https://api.tailscale.com/api/v2/oauth/token \
        | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)
[[ -n "$TOKEN" ]] || { echo "ERROR: could not get an OAuth token" >&2; exit 1; }

TS_KEY=$(curl -fsS -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -X POST -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"${TAG}\"]}}},\"expirySeconds\":${KEY_TTL}}" \
    "https://api.tailscale.com/api/v2/tailnet/-/keys" \
    | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)
[[ -n "$TS_KEY" ]] || { echo "ERROR: could not mint an auth key" >&2; exit 1; }
echo "[*] Key minted (expires in ${KEY_TTL}s, single use)"

# ---- cloud-init user-data ----------------------------------------------
# Windows templates run Cloudbase-Init, which executes user-data beginning with
# #ps1_sysnative as PowerShell. Order matters: join the tailnet first, then
# rename, then restart - Windows only applies a rename on restart, and the
# tailnet session survives it because the service runs unattended.
mkdir -p "$SNIPPET_DIR"
SNIPPET="${SNIPPET_DIR}/pithos-${NEW_HOST}.yml"
cat > "$SNIPPET" <<YAML
#ps1_sysnative
\$ts = 'C:\Program Files\Tailscale\tailscale.exe'
Start-Sleep -Seconds 20
& \$ts up --authkey=${TS_KEY} --hostname=${NEW_HOST} --unattended --accept-dns=false
& \$ts status | Out-File C:\pithos-join.log -Encoding ASCII
Rename-Computer -NewName '${NEW_HOST}' -Force -ErrorAction SilentlyContinue
Restart-Computer -Force
YAML
chmod 600 "$SNIPPET"
echo "[*] user-data written: $SNIPPET"

# ---- clone --------------------------------------------------------------
echo "[*] Cloning $TEMPLATE_VMID -> $NEW_VMID ($NEW_HOST)..."
CLONE_ARGS=(--name "$NEW_HOST" --full)
[[ -n "$STORAGE" ]] && CLONE_ARGS+=(--storage "$STORAGE")
qm clone "$TEMPLATE_VMID" "$NEW_VMID" "${CLONE_ARGS[@]}"

if [[ -n "$BRIDGE" ]]; then
    echo "[*] Attaching to bridge $BRIDGE"
    qm set "$NEW_VMID" --net0 "virtio,bridge=${BRIDGE}" >/dev/null
fi

qm set "$NEW_VMID" \
    --ciuser "$CIUSER" --cipassword "$CIPASS" \
    --ipconfig0 ip=dhcp \
    --cicustom "user=${SNIPPET_STORE}:snippets/$(basename "$SNIPPET")" \
    --onboot "$ONBOOT" >/dev/null

if [[ "$ONBOOT" == "1" ]]; then
    echo "[*] onboot enabled - will start automatically after a host restart"
else
    echo "[!] onboot DISABLED - will NOT start after a host restart"
fi

# ---- start and wait -----------------------------------------------------
echo "[*] Starting VM..."
qm start "$NEW_VMID"

echo "[*] Waiting for the guest agent (first boot, then a restart for the rename)..."
JOINED=""
for i in $(seq 1 40); do
    if qm agent "$NEW_VMID" ping >/dev/null 2>&1; then
        NAME=$(qm guest exec "$NEW_VMID" --timeout 20 -- cmd /c hostname 2>/dev/null \
               | grep -oE '"out-data" : "[^"]+' | cut -d'"' -f4 | tr -d '\\rn ')
        if [[ "${NAME,,}" == "${NEW_HOST,,}" ]]; then JOINED="yes"; break; fi
    fi
    sleep 15
done

echo
if [[ -n "$JOINED" ]]; then
    echo "[OK] $NEW_HOST (VMID $NEW_VMID) is up, renamed and on the tailnet."
else
    echo "[!] $NEW_HOST (VMID $NEW_VMID) was created and started, but did not report"
    echo "    its new name within ~10 minutes. It restarts once during provisioning,"
    echo "    so give it a little longer, then check C:\\pithos-join.log inside it."
fi
echo "    Auth key was single-use and expires in ${KEY_TTL}s."
echo "    user-data (contains the key) is at: $SNIPPET"

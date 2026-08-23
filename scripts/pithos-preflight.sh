#!/bin/bash
# pithos-preflight
# Validates Proxmox host readiness for Pithos install/use.
# Run before pithos-build-template to catch issues early.
#
# Exit codes:
#   0 = ready (no issues)
#   1 = warnings only (install will likely work but check the warnings)
#   2 = errors (install will fail until fixed)

set -uo pipefail

OAUTH_FILE="${OAUTH_FILE:-/root/.tailscale/oauth}"
TAG="${TAG:-tag:lxc}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"

ERRORS=0
WARNINGS=0

# Color output (only if terminal)
if [[ -t 1 ]]; then
    G="\033[0;32m"   # green
    Y="\033[0;33m"   # yellow
    R="\033[0;31m"   # red
    B="\033[0;36m"   # cyan
    N="\033[0m"      # reset
else
    G="" Y="" R="" B="" N=""
fi

ok()    { echo -e "[${G}✓${N}] $1"; }
warn()  { echo -e "[${Y}!${N}] WARN: $1"; WARNINGS=$((WARNINGS+1)); }
err()   { echo -e "[${R}✗${N}] FAIL: $1"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "    ${B}$1${N}"; }

echo "Pithos preflight check"
echo "=========================="
echo

# ===== Proxmox VE =====
if command -v pveversion >/dev/null 2>&1; then
    PVE_VER=$(pveversion | awk -F'/' '{print $2}' | head -1)
    ok "Proxmox VE detected ($PVE_VER)"
else
    err "Not running on a Proxmox VE host (no pveversion command)"
    info "Pithos only runs on Proxmox VE."
fi

if ! command -v pct >/dev/null 2>&1; then
    err "pct command not found"
fi
if ! command -v pveam >/dev/null 2>&1; then
    err "pveam command not found"
fi
if ! command -v pvesm >/dev/null 2>&1; then
    err "pvesm command not found"
fi

# ===== Network / DNS =====
if getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "DNS resolution working (deb.debian.org)"
else
    err "Cannot resolve deb.debian.org — DNS or internet issue"
    info "Containers need this for Debian package installation."
fi

if getent hosts api.tailscale.com >/dev/null 2>&1; then
    ok "Tailscale API reachable (api.tailscale.com)"
else
    err "Cannot resolve api.tailscale.com"
    info "Pithos needs this to mint auth keys."
fi

if getent hosts pkgs.tailscale.com >/dev/null 2>&1; then
    ok "Tailscale package repo reachable"
else
    warn "Cannot resolve pkgs.tailscale.com — template build will fail"
fi

# ===== Bridge =====
if command -v ip >/dev/null 2>&1; then
    BRIDGES=$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')
    if [[ -z "$BRIDGES" ]]; then
        err "No bridge interfaces found"
        info "Need at least one Proxmox bridge (typically vmbr0)."
    else
        if echo "$BRIDGES" | tr ' ' '\n' | grep -qx "$BRIDGE"; then
            ok "Bridge '$BRIDGE' exists"
        else
            warn "Default bridge '$BRIDGE' not found"
            info "Available bridges: $BRIDGES"
            info "Override with: export BRIDGE=<name>"
        fi
    fi
fi

# ===== Storage =====
if command -v pvesm >/dev/null 2>&1; then
    STORAGES=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')
    if [[ -z "$STORAGES" ]]; then
        err "No storage backends support container content (rootdir)"
        info "Enable container content on a storage backend in Proxmox:"
        info "  Datacenter -> Storage -> Edit -> Content -> Check 'Container'"
    else
        if echo "$STORAGES" | tr ' ' '\n' | grep -qx "$STORAGE"; then
            ok "Storage '$STORAGE' available for containers"
            OTHERS=$(echo "$STORAGES" | tr ' ' '\n' | grep -v "^$STORAGE$" | tr '\n' ' ')
            [[ -n "$OTHERS" ]] && info "Also available: $OTHERS"
        else
            warn "Default storage '$STORAGE' not found"
            info "Available: $STORAGES"
            info "Override with: export STORAGE=<name>"
        fi
    fi
fi

# ===== Disk space =====
ROOT_AVAIL_GB=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
if [[ -n "$ROOT_AVAIL_GB" ]] && (( ROOT_AVAIL_GB >= 8 )); then
    ok "Disk space on /: ${ROOT_AVAIL_GB}G available"
elif [[ -n "$ROOT_AVAIL_GB" ]]; then
    warn "Low disk space on /: ${ROOT_AVAIL_GB}G available (recommend 8G+ for template + clones)"
fi

# ===== Debian template downloaded =====
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DEB_TEMPLATE=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/ {print $1}' | head -1)
if [[ -n "$DEB_TEMPLATE" ]]; then
    TPL_NAME=$(basename "$DEB_TEMPLATE")
    ok "Debian 12 template downloaded ($TPL_NAME)"
else
    warn "Debian 12 template not downloaded"
    info "Run: pveam update && pveam download $TEMPLATE_STORAGE debian-12-standard"
fi

# ===== Template VMID conflict =====
if pct status "$TEMPLATE_VMID" &>/dev/null; then
    if pct config "$TEMPLATE_VMID" 2>/dev/null | grep -q "^template:.*1"; then
        ok "Template VMID $TEMPLATE_VMID already exists (looks like a built template)"
    else
        warn "VMID $TEMPLATE_VMID exists but is not a template"
        info "Either destroy it (pct destroy $TEMPLATE_VMID --purge) or use TEMPLATE_VMID=<other>"
    fi
else
    ok "Template VMID $TEMPLATE_VMID available"
fi

# ===== Tailscale on host =====
if command -v tailscale >/dev/null 2>&1; then
    TS_VER=$(tailscale version 2>/dev/null | head -1)
    ok "Tailscale CLI installed ($TS_VER)"
    if tailscale status >/dev/null 2>&1; then
        TS_SELF=$(tailscale status --self --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo "?")
        ok "Tailscale running on host (this host: $TS_SELF)"
    else
        warn "Tailscale installed but not running / not authenticated"
        info "Host doesn't need Tailscale for Pithos to work,"
        info "but it's recommended for accessing the web UI over tailnet."
    fi
else
    info "Tailscale not installed on host (containers will still get it from the template)"
fi

# ===== OAuth credentials =====
if [[ ! -e "$OAUTH_FILE" ]]; then
    err "OAuth credentials file not found at $OAUTH_FILE"
    info "Create the file with your Tailscale OAuth client credentials."
    info "See README.md 'Prerequisites' section for setup steps."
elif [[ ! -r "$OAUTH_FILE" ]]; then
    err "OAuth file exists but is not readable: $OAUTH_FILE"
    info "Should be: chmod 600 $OAUTH_FILE (root-only)"
else
    PERMS=$(stat -c "%a" "$OAUTH_FILE" 2>/dev/null || stat -f "%Lp" "$OAUTH_FILE" 2>/dev/null)
    if [[ "$PERMS" == "600" ]]; then
        ok "OAuth file exists with proper permissions (600)"
    else
        warn "OAuth file permissions are $PERMS (should be 600)"
        info "Fix: chmod 600 $OAUTH_FILE"
    fi

    # shellcheck disable=SC1090
    source "$OAUTH_FILE" 2>/dev/null
    if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
        err "OAuth file missing TS_OAUTH_CLIENT_ID or TS_OAUTH_CLIENT_SECRET"
    elif [[ "$TS_OAUTH_CLIENT_ID" =~ ^(PASTE_|YOUR_|REPLACE_|\.\.\.|XXX|<.+>)$ ]] || \
         [[ "$TS_OAUTH_CLIENT_SECRET" =~ ^(PASTE_|YOUR_|REPLACE_|\.\.\.|XXX|<.+>) ]] || \
         [[ "$TS_OAUTH_CLIENT_ID" == *PASTE_YOUR* ]] || \
         [[ "$TS_OAUTH_CLIENT_SECRET" == *PASTE_YOUR* ]] || \
         [[ "$TS_OAUTH_CLIENT_ID" == "YOUR_CLIENT_ID_HERE" ]] || \
         [[ "$TS_OAUTH_CLIENT_SECRET" == "YOUR_CLIENT_SECRET_HERE" ]]; then
        err "OAuth file contains placeholder values, not real credentials"
        info "You appear to have copied the README template literally."
        info "Generate YOUR OWN OAuth client in the Tailscale admin console:"
        info "  https://login.tailscale.com/admin/settings/oauth"
        info "See docs/security.md for why these credentials are unique-per-tailnet."
    else
        # Test the credentials
        TOKEN=$(curl -fsS \
            -d "client_id=${TS_OAUTH_CLIENT_ID}" \
            -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
            -d "grant_type=client_credentials" \
            https://api.tailscale.com/api/v2/oauth/token 2>/dev/null \
            | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)
        if [[ -n "$TOKEN" ]]; then
            ok "OAuth credentials valid (got access token)"

            # Try to mint a test key to validate tag authorization
            TEST_KEY=$(curl -fsS \
                -H "Authorization: Bearer ${TOKEN}" \
                -H "Content-Type: application/json" \
                -X POST \
                -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":true,\"preauthorized\":true,\"tags\":[\"${TAG}\"]}}},\"expirySeconds\":60}" \
                "https://api.tailscale.com/api/v2/tailnet/-/keys" 2>/dev/null \
                | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)
            if [[ -n "$TEST_KEY" ]]; then
                ok "Tag '$TAG' authorized for this OAuth client"
            else
                err "Cannot mint auth key with tag '$TAG'"
                info "Check that:"
                info "  1. '$TAG' is in your tailnet's tagOwners"
                info "  2. The OAuth client is authorized for '$TAG'"
                info "  3. The OAuth client has 'Auth Keys: Write' scope"
            fi
        else
            err "OAuth credentials invalid (could not get access token)"
            info "Check the client ID and secret in $OAUTH_FILE"
        fi
    fi
fi

# ===== Summary =====
echo
echo "=========================="
if (( ERRORS > 0 )); then
    echo -e "${R}STATUS: NOT READY${N} ($ERRORS errors, $WARNINGS warnings)"
    echo "Fix the errors above, then re-run pithos-preflight."
    exit 2
elif (( WARNINGS > 0 )); then
    echo -e "${Y}STATUS: READY WITH WARNINGS${N} ($WARNINGS warnings)"
    echo "Install will likely work, but address the warnings if possible."
    exit 1
else
    echo -e "${G}STATUS: READY${N}"
    echo "Run: pithos-build-template"
    exit 0
fi

#!/bin/bash
# Pithos bootstrap - one command on a fresh Proxmox host.
#
#   curl -fsSL https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main/bootstrap.sh | bash
#
# Fetches the repo, installs the CLI, the Windows template assets and the web
# UI, and generates an admin credential. Safe to re-run.
set -euo pipefail

REPO="${PITHOS_REPO:-https://github.com/SuperAngryMonkey/pithos}"
BRANCH="${PITHOS_BRANCH:-main}"
DEST="${PITHOS_DEST:-/opt/pithos-src}"

echo "=== Pithos bootstrap ==="

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
command -v pct >/dev/null || { echo "ERROR: no pct - this is not a Proxmox VE host." >&2; exit 1; }

echo "[*] Checking packages..."
MISSING=()
command -v git         >/dev/null || MISSING+=(git)
command -v genisoimage >/dev/null || MISSING+=(genisoimage)
python3 -c "import flask" 2>/dev/null || MISSING+=(python3-flask)
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "    installing: ${MISSING[*]}"
    apt-get update -qq
    apt-get install -y -qq "${MISSING[@]}" || {
        echo "ERROR: package install failed. On PVE the Debian repos are" >&2
        echo "       sometimes disabled in /etc/apt/sources.list.d/debian.sources" >&2
        echo "       (Enabled: false) - enable them and re-run." >&2
        exit 1; }
fi

echo "[*] Fetching $REPO ($BRANCH)..."
if [[ -d "$DEST/.git" ]]; then
    git -C "$DEST" fetch --quiet origin "$BRANCH"
    git -C "$DEST" reset --hard --quiet "origin/$BRANCH"
elif [[ -e "$DEST" ]]; then
    # Deliberately refuse rather than delete: this path is user-supplied and
    # an installer should never remove something it did not create.
    echo "ERROR: $DEST exists but is not a git checkout." >&2
    echo "       Move it aside, or set PITHOS_DEST to another path." >&2
    exit 1
else
    git clone --quiet --branch "$BRANCH" --depth 1 "$REPO" "$DEST"
fi
echo "    $(git -C "$DEST" describe --tags --always)"

echo "[*] Installing CLI and template assets..."
bash "$DEST/scripts/install.sh"

echo "[*] Installing web UI..."
bash "$DEST/scripts/install-webui.sh"

# Repeat the important bits last: on a fresh host the package install and
# clone output scrolls the URL and password off the screen.
LAN_IP=$(ip -4 addr show vmbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
[[ -z "$LAN_IP" ]] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$LAN_IP" ]] && LAN_IP="<this-host>"

echo
echo "================================================================"
echo "  Pithos is running:  http://${LAN_IP}:8080/"
if [[ -f /root/.pithos/initial-password ]]; then
    echo "  Sign in:            $(sed -n 1p /root/.pithos/initial-password) / $(sed -n 2p /root/.pithos/initial-password)"
    echo "                      (also in /root/.pithos/initial-password)"
fi
echo "================================================================"

cat <<'NEXT'

=== Next ===

  1. Tailscale credentials, so new guests join your tailnet automatically:

       mkdir -p /root/.tailscale && chmod 700 /root/.tailscale
       nano /root/.tailscale/oauth      # two lines:
                                        #   TS_OAUTH_CLIENT_ID=...
                                        #   TS_OAUTH_CLIENT_SECRET=...
       chmod 600 /root/.tailscale/oauth

     Create the client at login.tailscale.com/admin/settings/oauth with the
     devices:write scope, and make sure tag:lxc is in your ACL's tagOwners.
     See docs/other-tailnets.md.

  2. A template to clone from:

       pithos-build-template              # Debian LXC
       pithos-build-windows --variant 2019 --iso local:iso/<your.iso>

  3. Open the web UI on port 8080 and sign in with the credential above.

NEXT

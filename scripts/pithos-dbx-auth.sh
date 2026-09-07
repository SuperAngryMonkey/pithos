#!/bin/bash
# pithos-dbx-auth - one-time Dropbox authorisation for unattended uploads.
#
# Generated tokens expire in a few hours, which is useless for scheduled work.
# This runs the OAuth code flow with token_access_type=offline, which returns a
# refresh token that does not expire. The host then mints short-lived access
# tokens from it as needed, with no further interaction.
set -euo pipefail

CRED="${DROPBOX_CRED:-/root/.dropbox-oauth}"

read -rp "Dropbox app key: " APP_KEY
read -rsp "Dropbox app secret: " APP_SECRET; echo
[[ -n "$APP_KEY" && -n "$APP_SECRET" ]] || { echo "ERROR: both are required" >&2; exit 1; }

cat <<URL

Open this in a browser, approve, and copy the code it shows:

  https://www.dropbox.com/oauth2/authorize?client_id=${APP_KEY}&token_access_type=offline&response_type=code

URL
read -rp "Authorisation code: " CODE
[[ -n "$CODE" ]] || { echo "ERROR: no code" >&2; exit 1; }

echo "[*] Exchanging code for a refresh token..."
RESP=$(curl -sS -X POST https://api.dropboxapi.com/oauth2/token \
    -d grant_type=authorization_code -d "code=${CODE}" \
    -u "${APP_KEY}:${APP_SECRET}")

REFRESH=$(echo "$RESP" | grep -oE '"refresh_token": *"[^"]+"' | cut -d'"' -f4)
[[ -n "$REFRESH" ]] || {
    echo "ERROR: no refresh token returned. Dropbox said:" >&2
    echo "$RESP" | head -c 300 >&2; echo >&2
    echo "Codes are single-use and expire quickly - generate a fresh one." >&2
    exit 1; }

umask 077
cat > "$CRED" <<CREDS
DROPBOX_APP_KEY=${APP_KEY}
DROPBOX_APP_SECRET=${APP_SECRET}
DROPBOX_REFRESH_TOKEN=${REFRESH}
CREDS
chmod 600 "$CRED"

echo
echo "[OK] Saved to $CRED (root only)."
echo "     This does not expire. Uploads now work unattended."
echo "     Revoke any short-lived token you were using."

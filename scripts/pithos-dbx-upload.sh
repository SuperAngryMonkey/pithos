#!/bin/bash
# Upload large files straight to Dropbox from this host.
# Files over 150MB need a chunked upload session, which is most of this script.
#
# Token: put it in /root/.dropbox-token (chmod 600). Never pass it on the
# command line - it would land in shell history and the process list.
set -euo pipefail

TOKEN_FILE="${TOKEN_FILE:-/root/.dropbox-token}"
DEST_DIR="${DEST_DIR:-/Dean-James}"
CHUNK=$((100 * 1024 * 1024))   # 100MB

# Prefer the refresh-token credential: it does not expire, so scheduled work
# keeps working. Fall back to a static token file for a one-off.
CRED="${DROPBOX_CRED:-/root/.dropbox-oauth}"
TOKEN=""
if [[ -f "$CRED" ]]; then
    # shellcheck disable=SC1090
    . "$CRED"
    TOKEN=$(curl -sS -X POST https://api.dropboxapi.com/oauth2/token \
        -d grant_type=refresh_token -d "refresh_token=${DROPBOX_REFRESH_TOKEN}" \
        -u "${DROPBOX_APP_KEY}:${DROPBOX_APP_SECRET}" \
        | grep -oE '"access_token": *"[^"]+"' | cut -d'"' -f4)
    [[ -n "$TOKEN" ]] || { echo "ERROR: could not refresh access token." >&2
        echo "       Re-run pithos-dbx-auth if the app was revoked." >&2; exit 1; }
elif [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
fi
[[ -n "$TOKEN" ]] || { echo "ERROR: no Dropbox credential. Run pithos-dbx-auth." >&2; exit 1; }

upload() {
    local src="$1" name dest size offset session
    name=$(basename "$src")
    dest="${DEST_DIR}/${name}"
    size=$(stat -c%s "$src")
    echo "[*] $name ($(numfmt --to=iec "$size"))"

    session=$(curl -sS -X POST https://content.dropboxapi.com/2/files/upload_session/start \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Dropbox-API-Arg: {\"close\":false}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @/dev/null | grep -oE '"session_id": *"[^"]+"' | cut -d'"' -f4)
    [[ -n "$session" ]] || { echo "    !! could not start session (bad token?)" >&2; return 1; }

    offset=0
    while [[ $offset -lt $size ]]; do
        dd if="$src" bs=1M skip=$((offset / 1048576)) count=$((CHUNK / 1048576)) 2>/dev/null | \
        curl -sS -X POST https://content.dropboxapi.com/2/files/upload_session/append_v2 \
            -H "Authorization: Bearer ${TOKEN}" \
            -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"${session}\",\"offset\":${offset}},\"close\":false}" \
            -H "Content-Type: application/octet-stream" --data-binary @- >/dev/null
        offset=$((offset + CHUNK))
        [[ $offset -gt $size ]] && offset=$size
        printf "\r    %s%%" $((offset * 100 / size))
    done
    echo

    curl -sS -X POST https://content.dropboxapi.com/2/files/upload_session/finish \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Dropbox-API-Arg: {\"cursor\":{\"session_id\":\"${session}\",\"offset\":${size}},\"commit\":{\"path\":\"${dest}\",\"mode\":\"overwrite\",\"autorename\":false,\"mute\":false}}" \
        -H "Content-Type: application/octet-stream" --data-binary @/dev/null \
        | grep -qE '"path_display"' && echo "    -> $dest" || { echo "    !! finish failed" >&2; return 1; }
}

for f in "$@"; do
    [[ -f "$f" ]] || { echo "!! not a file: $f" >&2; continue; }
    upload "$f" || echo "!! failed: $f" >&2
done

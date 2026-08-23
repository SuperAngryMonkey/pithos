# Troubleshooting

Common issues and how to fix them.

---

## "Network never came up" during template build

The build script waits up to 5 minutes for DHCP + DNS to come up inside the container. If it times out, something is wrong with the network.

### Check if the container got an IP at all

```bash
pct exec 9000 -- ip addr show eth0
```

If you see `inet 10.x.y.z/24`, DHCP worked. The wait probably failed on DNS — check `/etc/resolv.conf`:

```bash
pct exec 9000 -- cat /etc/resolv.conf
pct exec 9000 -- getent hosts deb.debian.org
```

If `/etc/resolv.conf` is empty or has bad servers, DHCP isn't pushing DNS. You can force it via the LXC config:

```bash
pct stop 9000
pct set 9000 -nameserver "1.1.1.1 8.8.8.8"
pct start 9000
```

If you see no IPv4 address, DHCP failed. Continue below.

### DHCP fails — pool exhaustion or static-IP overlap

If your DHCP scope overlaps with statically-assigned IPs, the DHCP server may probe each candidate IP via ICMP before offering. If a static device responds, the offer is withdrawn and the next IP is tried. With many static-IP devices in the scope range, initial DHCP for a fresh MAC can take minutes (or fail entirely).

**Diagnosis:** Look at the DHCP server's log. On FortiGate:
```
diagnose debug enable
diagnose debug application dhcps -1
```

Then trigger DHCP from a fresh container. You'll see lines like:
```
[debug]Sending ICMP echo-request to 192.0.2.165
[debug]Received ICMP echo-reply from 192.0.2.165
[warn]Abandoning IP address 192.0.2.165: pinged before offer
```

Each "Abandoning" line is an IP being offered to the FortiGate but rejected because something already has it.

**Fix:** Move the DHCP scope to a clean range that doesn't overlap any static-IP devices. Or add reservations for every static device so the DHCP server knows they're taken.

### Container has IP but DNS times out

Could be:
- Resolver can't be reached (firewall blocking 53/udp out)
- Wrong DNS pushed by DHCP

Quick fix:
```bash
pct exec 9000 -- bash -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
pct exec 9000 -- getent hosts deb.debian.org
```

Permanent fix in the build script: add `--nameserver "1.1.1.1 8.8.8.8"` to the `pct create` invocation in `pithos-build-template`.

---

## Container joins tailnet but Tailscale SSH says "access controls don't allow anyone to access this device"

You skipped the SSH grant in your tailnet ACL. Add to your policy file:

```hujson
"ssh": [
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["tag:lxc"],
    "users":  ["root", "autogroup:nonroot"],
  },
],
```

The container is on the tailnet either way — only `tailscale ssh` is gated by this rule.

---

## `tailscale up --accept-routes` on the Proxmox host breaks LAN access

**Symptom:** After `tailscale up --accept-routes` on the Proxmox host, you can reach it via Tailscale (100.x.y.z) but no longer via LAN (192.168.x.y or 10.x.y.z). Other devices on the same LAN can't ping it. The web UI is unreachable from LAN.

**Cause:** Some other tailnet peer is advertising the host's own LAN subnet (e.g., another Proxmox box configured as a subnet router). Your host accepted that route, so its kernel now tries to route LAN-bound traffic through Tailscale, which doesn't have a path back.

**Fix:**
```bash
tailscale set --accept-routes=false
```

Or bring Tailscale up without that flag in the first place:
```bash
tailscale up --reset --auth-key=... --hostname=proxlab --ssh
# (no --accept-routes)
```

Cloned containers can use `--accept-routes` safely — only the host has this problem because it's also acting as an L2 endpoint on the affected subnet.

---

## OAuth client credentials not working

**Symptom:** `pithos-new` fails with "Failed to get OAuth access token" or "Failed to mint auth key".

### Check the credentials are loaded

```bash
source /root/.tailscale/oauth
echo "ID length: ${#TS_OAUTH_CLIENT_ID}"
echo "Secret length: ${#TS_OAUTH_CLIENT_SECRET}"
```

Both should be > 10 characters. If either is 0, the file is malformed.

### Test the OAuth flow manually

```bash
source /root/.tailscale/oauth
curl -fsS \
    -d "client_id=${TS_OAUTH_CLIENT_ID}" \
    -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials" \
    https://api.tailscale.com/api/v2/oauth/token
```

You should get JSON containing `"access_token":"..."`. If not, the credentials are wrong or revoked.

### "Tag not allowed"

If you can get an access token but minting a key fails, your OAuth client may not be authorized for `tag:lxc`. Check the OAuth client's allowed tags in the admin console (**Settings → Trust credentials → click your credential**).

Also verify `tag:lxc` is in your tailnet's `tagOwners`:
```hujson
"tagOwners": {
  "tag:lxc": ["autogroup:admin"],
},
```

---

## VMID 9000 already exists when running `pithos-build-template`

The build script refuses to overwrite an existing VMID. You have three options:

### Destroy the old one and rebuild

```bash
pct stop 9000 2>/dev/null
pct destroy 9000 --purge
pithos-build-template
```

### Use a different VMID

```bash
VMID=9001 pithos-build-template
```

But then your `pithos-new` clones will fail because they default to template VMID 9000. Override per-clone:
```bash
TEMPLATE_VMID=9001 pithos-new 200 my-host
```

Or edit `/usr/local/sbin/pithos-new` and change the default.

### Reuse the existing template if it already has Pithos in it

Skip the build step entirely. Just verify:
```bash
pct exec 9000 -- cat /etc/pithos-template-version 2>/dev/null
pct exec 9000 -- systemctl is-enabled tailscale-firstboot 2>/dev/null
```

If both work, the existing VMID 9000 is already a Pithos template.

---

## Web UI is up but cloning fails immediately

Check the Flask logs:
```bash
journalctl -u pithos -n 50 --no-pager
```

Most likely causes:
- `/usr/local/sbin/pithos-new` is missing or not executable
- OAuth credentials are wrong (see above)
- Template VMID is wrong or doesn't exist

---

## Cloned container exists but isn't on the tailnet

Check the firstboot log inside the container:
```bash
pct exec <vmid> -- cat /var/log/tailscale-firstboot.log
```

You'll see what `tailscale up` did. Common errors:
- `auth key not provided` — the key file wasn't injected. Check `pithos-new` output.
- `auth key expired` — keys are 10-minute TTL. If clones take longer than that, increase `expirySeconds` in `pithos-new`.
- `tag not allowed` — see OAuth troubleshooting above.

To re-trigger the join manually:
```bash
# On the Proxmox host, mint a new key and inject it
source /root/.tailscale/oauth
ACCESS_TOKEN=$(curl -fsS -d "client_id=${TS_OAUTH_CLIENT_ID}" -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" -d "grant_type=client_credentials" https://api.tailscale.com/api/v2/oauth/token | grep -oE '"access_token":"[^"]+"' | cut -d'"' -f4)
TS_KEY=$(curl -fsS -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" -X POST -d '{"capabilities":{"devices":{"create":{"reusable":false,"ephemeral":false,"preauthorized":true,"tags":["tag:lxc"]}}},"expirySeconds":600}' "https://api.tailscale.com/api/v2/tailnet/-/keys" | grep -oE '"key":"[^"]+"' | cut -d'"' -f4)

echo "$TS_KEY" | pct exec <vmid> -- tee /etc/tailscale/authkey >/dev/null
pct exec <vmid> -- chmod 600 /etc/tailscale/authkey
pct exec <vmid> -- systemctl start tailscale-firstboot.service
```

---

## Proxmox 9 / Trixie host: enterprise repo 401 errors when installing Tailscale on the host

If you're installing Tailscale on the Proxmox host itself (not just in containers), `apt-get update` may fail with 401 errors from `enterprise.proxmox.com` because you don't have a paid subscription.

Disable the enterprise repos and add the no-subscription one:

```bash
# Disable enterprise repos (they use the new .sources format in PVE 9)
sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources
sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/ceph.sources

# Add the free no-subscription repo
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve trixie pve-no-subscription
EOF

apt-get update
```

Now `apt-get install tailscale` (after adding the Tailscale repo per the install instructions) will work.

---

## Still stuck?

Open an issue at [github.com/SuperAngryMonkey/pithos/issues](https://github.com/SuperAngryMonkey/pithos/issues). Include:

- Proxmox VE version (`pveversion`)
- Output of the failing command
- Relevant logs (`journalctl -u pithos`, `/var/log/tailscale-firstboot.log` from the affected container)
- Your network topology (DHCP server, LAN subnet, Tailscale tailnet name)

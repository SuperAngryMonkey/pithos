# 🍱 Pithos

**One-click Tailscale-connected LXC containers on Proxmox.**

Pithos is a small self-hosted web UI that runs on your Proxmox host. Open a browser, type a hostname, click a button — 30 seconds later you have a fresh LXC container that's already on your Tailscale tailnet, tagged, and reachable via Tailscale SSH from any of your devices.

No more `pct create` arguments. No more SSH keys to copy. No more `tailscale up` ceremony per container. Containers, sealed, portable. Like the bowls.

```
┌─────────────────────────────────────────────────────────────┐
│  PITHOS                                       12:34:56  │
│  LXC PROVISIONER // proxlab                       ●  OK     │
├─────────────────────────────────────────────────────────────┤
│  CONTAINERS  │  VMS  │  TAILNET PEERS  │  NEXT VMID         │
│      9       │   4   │       23        │     205            │
├─────────────────────────────────────────────────────────────┤
│  [HOSTNAME] [VMID] [CORES] [MEMORY] [DISK]                  │
│  [ROOT PASSWORD (optional)                ]                 │
│  [ CLONE & JOIN TAILNET ]                                   │
├─────────────────────────────────────────────────────────────┤
│  PROVISIONING CONSOLE                          STREAMING    │
│  [*] Requesting OAuth access token...                       │
│  [*] Minting single-use auth key for tag:lxc...             │
│  [*] Cloning 9000 -> 205 (lab-lxc-01)...                    │
│  [✓] All done. lab-lxc-01 should be on the tailnet.         │
└─────────────────────────────────────────────────────────────┘
```

---

## Install

On a Proxmox VE host, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main/bootstrap.sh | bash
```

That installs the CLI, the Windows template assets and the web UI, generates an
admin credential and prints it once. Safe to re-run to update.

Then add Tailscale OAuth credentials and build a template - the installer
prints both steps when it finishes.

## What this gives you

- **A pre-built LXC template** with Tailscale baked in, configured for unprivileged operation with TUN passthrough.
- **A web UI** with live streaming output that runs on your Proxmox host (port 8080).
- **A CLI tool** (`pithos-new`) for scripted/CI use that does the same thing.
- **First-boot auto-join**: cloned containers join your tailnet automatically using a fresh OAuth-minted single-use key. The key is wiped from the container after use.
- **No standing credentials** in the template. Every clone gets a fresh 10-minute auth key.

---

## Prerequisites — read this first

Pithos is a thin wrapper around Tailscale + Proxmox. Both need some upfront configuration before installing Pithos itself. Allow ~15 minutes the first time, mostly waiting for downloads.

### 1. A working Proxmox VE host

- Proxmox VE 8.x or 9.x (Debian 12 Bookworm or 13 Trixie host)
- Storage backend (`local-lvm`, `local-zfs`, or directory)
- Network bridge (`vmbr0` is the default)
- Internet access from the host
- Root SSH or web console access

### 2. The Debian 12 LXC template downloaded

Pithos builds its golden template from `debian-12-standard`. **Download it before installing Pithos** — it can take a minute or two depending on your connection.

```bash
pveam update
pveam download local debian-12-standard_12.12-1_amd64.tar.zst
```

Verify it landed:

```bash
pveam list local | grep debian-12
```

You should see the template listed. If you skip this step, the Pithos build script will try to download it for you, but doing it ahead of time means a clean separation if anything fails.

### 3. A Tailscale account

If you don't have one: https://login.tailscale.com/start. Free tier handles up to 100 devices. You need admin access to your tailnet.

### 4. A `tag:lxc` defined in your tailnet policy

Pithos tags every container it creates with `tag:lxc`. You need to declare this tag in your tailnet's ACL policy file before tag-using auth keys will work.

In the [Tailscale admin console](https://login.tailscale.com/admin/acls/file), find or add a `tagOwners` block:

```hujson
{
  "tagOwners": {
    "tag:lxc": ["autogroup:admin"],
  },
  // ...rest of your policy file
}
```

This says: "the tag `lxc` exists; admins of the tailnet are authorized to apply it." You're an admin, so this lets your OAuth client (next step) mint keys carrying `tag:lxc`.

Save the policy. You can also create the tag through the GUI: **Access controls → Tags → Create tag → name: `lxc`, owners: `autogroup:admin`**.

### 5. (Optional but recommended) An ACL grant for `tag:lxc`

If your tailnet uses a default-deny ACL, add a grant so your devices can reach the containers:

```hujson
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:lxc"],
      "ip":  ["*"],
    },
  ],
}
```

If you have the default open ACL (`{"action": "accept", "src": ["*"], "dst": ["*:*"]}` or equivalent), this is already covered.

### 6. (Optional but recommended) A Tailscale SSH grant

To allow `tailscale ssh root@container-name` from your Mac/PC:

```hujson
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:lxc"],
      "users":  ["root", "autogroup:nonroot"],
    },
  ],
}
```

Without this, containers join the tailnet fine but you'll see a warning when running `tailscale status` inside them: *"Tailscale SSH enabled, but access controls don't allow anyone to access this device."*

### 7. A Tailscale OAuth client

This is what lets Pithos mint fresh auth keys on demand without storing a long-lived secret. **You only do this once.**

1. Go to **[Tailnet Settings → Trust credentials](https://login.tailscale.com/admin/settings/trust-credentials)**
2. Click **Generate credential**
3. Choose **OAuth** as the credential type
4. Configure:
   - **Description**: `Pithos provisioner` (or whatever's helpful for future-you)
   - **Scopes**: enable **only** `Auth Keys: Write`. Leave everything else unchecked. Least privilege.
   - **Tags**: `tag:lxc` — restricts the client so it can only mint keys for `tag:lxc` devices. Critical for blast-radius reasons.
5. Click **Generate credential**
6. **Copy both the Client ID and the Client Secret immediately.** The secret is shown exactly once. If you close the dialog without copying it, you must revoke and regenerate.

You'll paste these into a config file on the Proxmox host in the next section.

---

## Installation

Run all of this on the Proxmox host as root.

### Step 1 — Stash the OAuth credentials

```bash
mkdir -p /root/.tailscale
chmod 700 /root/.tailscale
cat > /root/.tailscale/oauth <<'EOF'
TS_OAUTH_CLIENT_ID=PASTE_YOUR_CLIENT_ID_HERE
TS_OAUTH_CLIENT_SECRET=PASTE_YOUR_CLIENT_SECRET_HERE
EOF
chmod 600 /root/.tailscale/oauth
```

Verify:

```bash
ls -la /root/.tailscale/oauth
# should show: -rw------- 1 root root ...
```

### Step 2 — Install the Pithos tooling

```bash
curl -fsSL https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main/scripts/install.sh | bash
```

This installs:
- `/usr/local/sbin/pithos-build-template` — one-time template builder
- `/usr/local/sbin/pithos-new` — per-clone provisioner

If you'd rather not curl-bash from the internet, clone the repo and run the install script locally:

```bash
git clone https://github.com/SuperAngryMonkey/pithos
cd pithos
./scripts/install.sh
```

### Step 3 — Build the golden template

```bash
pithos-build-template
```

This takes 2–4 minutes. It will:
- Create an unprivileged LXC at VMID 9000
- Add TUN device passthrough to the container's config
- Install Tailscale + dependencies inside the container
- Set up the firstboot systemd unit
- Wipe the container's `machine-id` so clones get fresh identity
- Convert the LXC to a Proxmox template

Override defaults via env vars if needed:

```bash
STORAGE=local-zfs BRIDGE=vmbr1 VMID=9001 pithos-build-template
```

### Step 4 — Install the web UI

```bash
curl -fsSL https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main/scripts/install-webui.sh | bash
```

Or from the cloned repo:

```bash
./scripts/install-webui.sh
```

This installs Flask, drops the app in `/opt/pithos/`, and starts a systemd service on port 8080.

### Step 5 — Open the UI

```bash
# Get your access URL
echo "http://$(ip -4 addr show vmbr0 | awk '/inet / {print $2}' | cut -d/ -f1):8080/"
```

Open that URL in any browser on your LAN or tailnet. You should see the Pithos dashboard.

---

## Usage

### Web UI

Fill in the form, click **Clone & Join Tailnet**, watch the live console output. Container appears in your Tailscale admin console (`https://login.tailscale.com/admin/machines`) within seconds of the firstboot service running.

Form fields:
- **Hostname** (required) — letters, numbers, hyphens only. Becomes the Tailscale hostname.
- **VMID** — leave blank to auto-pick the next free starting at 200.
- **CPU cores / Memory MB / Disk GB** — leave blank for template defaults (1 / 512 / 4).
- **Root password** — leave blank for none. Tailscale SSH still works regardless.

### CLI

Same thing, scriptable:

```bash
pithos-new <vmid> <hostname>

# Examples
pithos-new 201 lab-lxc-01
pithos-new 202 webserver
```

The CLI doesn't take resource overrides — it inherits template defaults (1 CPU, 512MB RAM, 4GB disk). For custom sizing, use the web UI or apply `pct set` and `pct resize` after the clone.

### MCP (Claude Code / Claude Desktop)

Provision from an AI client instead of the browser or shell. The `mcp/` directory ships a stdio MCP server that wraps the same provisioning path, exposing three tools — `pithos_host_status`, `pithos_list_containers`, and `pithos_provision` (dry-run by default; no destroy tool). It's an HTTP client to this web app, so it runs no `pct` / SSH itself.

See [`mcp/README.md`](mcp/README.md) for setup and [`docs/mcp.md`](docs/mcp.md) for the design.

### Verifying

After a clone:

```bash
# Check the container is running and on the tailnet
pct exec <vmid> -- tailscale status
pct exec <vmid> -- tailscale ip -4

# SSH into it from your Mac via Tailscale
tailscale ssh root@<hostname>
```

---

## Configuration

Every setting below is an environment variable on the `pithos` systemd service, and every one is optional — with none of them set, the app behaves exactly as it did before these options existed. Set them per host, according to what that host is.

The clean way to set them is a systemd drop-in, so upgrades that replace `app.py` never touch your config:

```bash
mkdir -p /etc/systemd/system/pithos.service.d
cat > /etc/systemd/system/pithos.service.d/local.conf <<'EOF'
[Service]
Environment=PITHOS_DEFAULT_STORAGE=local-zfs
Environment=PITHOS_HIDE_STORAGES=scratch
EOF
systemctl daemon-reload && systemctl restart pithos
```

### Access control

| Variable | Default | What it does |
|---|---|---|
| `PITHOS_AUTH_FILE` | `/root/.pithos/auth` | Path to the HTTP Basic Auth file. One line, `username:werkzeug-hash`. **File present** → every route requires auth. **Absent** → unauthenticated, with a startup warning. **Malformed** → fails closed. |
| `PITHOS_ALLOW_SOURCES` | *(unset)* | Comma-separated CIDR allow list. Requests from any other source address get `403` before auth runs. Unset means no source restriction. |
| `PITHOS_BIND` | `0.0.0.0` | Listen address. Pin to a tailscale or LAN interface address to stop the app listening on other interfaces. |
| `PORT` | `8080` | Listen port. Change it when something else already owns 8080 on the host. |

Create an auth file with:

```bash
mkdir -p /root/.pithos
python3 -c "from werkzeug.security import generate_password_hash as g; \
    import getpass; print('admin:' + g(getpass.getpass()))" > /root/.pithos/auth
chmod 600 /root/.pithos/auth
```

The file is re-read when it changes, so rotating a password needs no restart.

### Storage

| Variable | Default | What it does |
|---|---|---|
| `PITHOS_DEFAULT_STORAGE` | `local-lvm` | Default storage backend for provisioning. ZFS-backed hosts have no `local-lvm` and **must** set this. |
| `PITHOS_HIDE_STORAGES` | *(unset)* | Comma-separated backends to keep out of the provisioning picker — scratch or non-redundant disks that should never receive a container. The default storage is never hidden, even if listed, so a host always has a valid target. |

### Performance

| Variable | Default | What it does |
|---|---|---|
| `PITHOS_CACHE_TTL` | `30` | Seconds before cached inventory and host metrics are refreshed. Expired data is served immediately while a background thread refreshes it, so requests never block on `pct`. Clone and transfer bust the cache on completion. |
| `PITHOS_DISK_CACHE_TTL` | `600` | Seconds before cached SMART disk data is refreshed. Longer than the inventory TTL because `smartctl` is slow and drive health moves slowly. |

And in the MCP client's environment (see [`mcp/README.md`](mcp/README.md)):

| Variable | Default | What it does |
|---|---|---|
| `PITHOS_URL` | *(required)* | Base URL of the web app the MCP talks to, e.g. `http://100.64.0.5:8080`. |
| `PITHOS_USER` / `PITHOS_PASS` | *(unset)* | Basic Auth credentials, when the target host has an auth file. Leave unset against an un-authed host. |
| `PITHOS_READ_TIMEOUT` | `45` | Seconds to wait on read calls. Raise it for slow hosts with many containers. |

### Worked examples

**A host behind a perimeter firewall, LVM storage** — nothing to set. Defaults are correct.

**A host on a private LAN, reachable over the tailnet, with auth on:**

```ini
[Service]
Environment=PITHOS_ALLOW_SOURCES=127.0.0.0/8,10.0.0.0/24,100.64.0.0/10
```

**A host with a public IP, ZFS storage, a scratch disk, and 8080 already taken:**

```ini
[Service]
Environment=PORT=8081
Environment=PITHOS_ALLOW_SOURCES=127.0.0.0/8,10.10.10.0/24,100.64.0.0/10
Environment=PITHOS_DEFAULT_STORAGE=local-zfs
Environment=PITHOS_HIDE_STORAGES=scratch
```

Pair that with an auth file and a host firewall rule for the port. See [`docs/security.md`](docs/security.md) for how the layers stack.



---

## Troubleshooting

### "Network never came up" during build

The build script waits up to 5 minutes for DHCP + DNS to come up inside the container. If your DHCP scope overlaps with statically-assigned IPs, the DHCP server may have to probe many candidates before finding a free one. See [`docs/troubleshooting.md`](docs/troubleshooting.md) for diagnosis steps.

Quick fix: confirm your DHCP scope on the LAN doesn't overlap your static-IP range.

### Container joins tailnet but Tailscale SSH says "access controls don't allow anyone to access this device"

You skipped step 6 in the prerequisites — add the SSH grant to your tailnet ACL.

### `tailscale up --accept-routes` on the Proxmox host breaks LAN access

This is a known footgun. If another tailnet peer is advertising the host's own LAN subnet (e.g., another Proxmox box acting as a subnet router), the host accepts the route and starts trying to reach LAN clients via Tailscale instead of directly.

Symptoms: tailnet works, LAN ping/SSH from same-subnet devices breaks.

Fix: don't use `--accept-routes` when bringing up Tailscale on the Proxmox host itself, or run `tailscale set --accept-routes=false`. Cloned containers can use `--accept-routes` safely — only the host has this problem.

### OAuth client credentials lost or rotated

Update `/root/.tailscale/oauth` with the new values. No need to rebuild the template or restart anything else; the clone script reads the file fresh on every run.

---

## Architecture

```
┌──────────────────┐            ┌──────────────────────────────┐
│   Web Browser    │  HTTP      │  Proxmox Host                │
│   on tailnet/LAN │ ─────────→ │                              │
└──────────────────┘            │  ┌────────────────────────┐  │
                                │  │ pithos (Flask)     │  │
                                │  │ /opt/pithos/app.py │  │
                                │  └──────────┬─────────────┘  │
                                │             │                │
                                │             ▼                │
                                │  ┌────────────────────────┐  │
                                │  │ pithos-new         │  │
                                │  │ (bash, OAuth + pct)    │  │
                                │  └──────────┬─────────────┘  │
                                │             │                │
                                │             ▼                │
                                │  ┌────────────────────────┐  │
                                │  │ pct clone 9000 → 200   │  │
                                │  │ inject auth key        │  │
                                │  │ start firstboot.svc    │  │
                                │  └──────────┬─────────────┘  │
                                └─────────────┼────────────────┘
                                              │
                                              ▼
                                     ┌────────────────────┐
                                     │ Tailscale tailnet  │
                                     │ tag:lxc devices    │
                                     └────────────────────┘
```

See [`docs/architecture.md`](docs/architecture.md) for the deep dive.

---

## Repository layout

```
pithos/
├── README.md                    # this file
├── LICENSE                      # MIT
├── scripts/
│   ├── install.sh               # installs the build + clone scripts to /usr/local/sbin
│   ├── install-webui.sh         # installs the Flask app + systemd unit
│   ├── pithos-build-template.sh
│   └── pithos-new.sh
├── webui/
│   └── app.py                   # the Flask app
├── mcp/                         # MCP server — provision LXCs from Claude Code / Desktop
│   ├── pithos_mcp.py        # stdio MCP server (FastMCP)
│   ├── check_mcp.py             # standalone handshake self-test
│   └── README.md                # MCP quickstart
└── docs/
    ├── architecture.md
    ├── troubleshooting.md
    └── tailscale-setup.md       # screenshots of the OAuth client setup
```

---

## License

MIT. See [`LICENSE`](LICENSE).

---

## Contributing

Issues and PRs welcome. Tested on Proxmox VE 9.0.x with Tailscale 1.96.4. If you find it works (or breaks) on other versions, open an issue.

Built by [@SuperAngryMonkey](https://github.com/SuperAngryMonkey). 🐒

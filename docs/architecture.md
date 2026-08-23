# Architecture

How Pithos actually works under the hood.

---

## Components

### On the Proxmox host

| Path | Purpose |
|---|---|
| `/usr/local/sbin/pithos-build-template` | One-time setup. Builds the golden Debian 12 LXC template at VMID 9000 with Tailscale pre-installed. |
| `/usr/local/sbin/pithos-new` | Per-clone runtime. Mints an OAuth-based auth key, clones the template, injects the key, triggers firstboot. |
| `/opt/pithos/app.py` | The Flask web UI. Wraps `pithos-new` and provides live SSE streaming. |
| `/etc/systemd/system/pithos.service` | Systemd unit that runs the Flask app on port 8080. |
| `/root/.tailscale/oauth` | OAuth client credentials (chmod 600, root-only). |

### Inside the template (VMID 9000)

| Path | Purpose |
|---|---|
| `/usr/local/sbin/tailscale-firstboot.sh` | Oneshot script that reads `/etc/tailscale/authkey`, runs `tailscale up`, shreds the key. |
| `/etc/systemd/system/tailscale-firstboot.service` | Systemd unit that calls the firstboot script if `/etc/tailscale/authkey` exists. |
| `/etc/pithos-template-version` | Build timestamp marker. |

The template is converted to a true Proxmox template via `pct template 9000`, so it can't be started directly. Only cloned.

---

## End-to-end clone flow

When a user clicks **Clone & Join Tailnet** in the web UI (or runs `pithos-new <vmid> <hostname>`):

```
                                    ┌──────────────────────┐
                                    │   Pithos Flask   │
                                    │  /opt/pithos/    │
                                    └──────────┬───────────┘
                                               │ exec
                                               ▼
                                    ┌──────────────────────┐
                                    │  pithos-new      │
                                    │  (bash)              │
                                    └──────────┬───────────┘
                                               │
              ┌────────────────────────────────┤
              │                                │
              ▼                                ▼
   ┌──────────────────────┐         ┌──────────────────────┐
   │ POST oauth/token     │         │ pct clone 9000 → 200 │
   │ → access_token       │         │ pct start 200        │
   └──────────┬───────────┘         └──────────┬───────────┘
              │                                │
              ▼                                │
   ┌──────────────────────┐                    │
   │ POST tailnet/-/keys  │                    │
   │ → auth_key (10 min)  │                    │
   └──────────┬───────────┘                    │
              │                                │
              └────────────┬───────────────────┘
                           │
                           ▼
               ┌──────────────────────┐
               │ pct exec 200 -- tee  │
               │ /etc/tailscale/      │
               │ authkey < key        │
               └──────────┬───────────┘
                          │
                          ▼
               ┌──────────────────────┐
               │ pct exec 200 --      │
               │ systemctl start      │
               │ tailscale-firstboot  │
               └──────────┬───────────┘
                          │
                          ▼ (inside container)
               ┌──────────────────────┐
               │ tailscale up         │
               │   --auth-key=...     │
               │   --hostname=...     │
               │   --ssh              │
               │   --accept-routes    │
               └──────────┬───────────┘
                          │
                          ▼
               ┌──────────────────────┐
               │ shred /etc/tailscale │
               │      /authkey        │
               │ systemctl disable    │
               │  tailscale-firstboot │
               └──────────────────────┘
```

The whole sequence takes ~30 seconds in normal conditions.

---

## Why the design choices

### Why OAuth and not a static auth key?

Static auth keys in Tailscale have a 90-day maximum lifetime. If you bake one into your template, it expires every quarter and you have to rotate it.

OAuth client credentials don't expire. Pithos uses the OAuth client to mint a fresh **single-use, 10-minute, pre-authorized, tagged** auth key for every clone. The key never lives anywhere except briefly on the container being created, and it's shredded after use. The OAuth secret itself is the only long-lived credential, and it's restricted to `tag:lxc` so the blast radius is contained.

### Why a firstboot service inside the template?

We could just run `tailscale up` from `pithos-new` via `pct exec`. But:

1. **Race conditions.** The container's network needs to be up, `tailscaled` needs to be initialized, and the script timing inside `pct exec` has to line up with all of that.
2. **State.** A systemd oneshot tracks success/failure cleanly, logs to `/var/log/tailscale-firstboot.log`, and self-disables after running.
3. **Rebuildability.** If a clone fails to join the tailnet (network blip, transient issue), you can re-trigger by writing a new key to `/etc/tailscale/authkey` and `systemctl start tailscale-firstboot.service`. Same path as initial join.

### Why TUN device passthrough?

Tailscale needs `/dev/net/tun` to create the WireGuard interface. In an unprivileged LXC, the device isn't exposed by default. Two lines added to the LXC config solve it:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

The first allows the container to access the TUN char device (major 10, minor 200). The second bind-mounts the host's `/dev/net/tun` into the container's namespace.

Without these, `tailscaled` starts but logs "operation not permitted" when it tries to open the TUN device. Cloned containers inherit these lines via Proxmox's standard clone behavior.

### Why wipe the machine-id?

Debian generates `/etc/machine-id` on first boot if it's empty. By truncating it before converting to a template, we ensure each clone gets a unique machine-id on first boot — which downstream affects systemd-networkd, journalctl, and anything else that uses machine-id to identify the system.

```bash
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
```

The DBus machine-id is symlinked to the systemd one for consistency.

### Why linked clones?

`pct clone` defaults to linked clones on snapshot-capable storage (LVM-thin, ZFS). Linked clones share the read-only base layer with the template and only allocate disk for changes. Spinning up 50 containers from a 4GB template uses ~4GB on disk, not 200GB.

Tradeoff: you can't delete the template while clones exist, or the clones break. If you want fully independent clones, use `pct clone --full`.

### Why Flask and not something modern?

Flask is in Debian's standard repos, has no compile dependencies, and the entire app fits in one file. Adding FastAPI, Express, or anything trendier would mean introducing a runtime, a package manager, and more moving parts for a tool that just shells out to bash scripts. KISS.

---

## What runs as root, and why

The Flask app runs as root. This is a deliberate compromise:

- `pct`, `pct exec`, `pct clone`, `pct set` are all root-only.
- Granting a non-root user `sudo` rights to those commands works but adds setup complexity (sudoers config, `Defaults!cmd_alias` boilerplate).
- For a homelab tool reachable only from your tailnet/LAN, the threat model doesn't justify the additional complexity.

For a multi-tenant or shared-infrastructure deployment, you'd want:
- Run Flask as a dedicated user (e.g., `pithos`).
- Sudoers entries allowing that user to run only the Pithos scripts as root.
- Optionally an authentication proxy (Caddy + Tailscale auth, oauth2-proxy, etc.) in front of the web UI.

These changes are out of scope for the default install but are reasonable extensions.

---

## What's exposed where

| Surface | Exposure |
|---|---|
| Web UI port 8080 | Bound to `0.0.0.0`, reachable from anywhere that can route to the host. |
| OAuth credentials | `/root/.tailscale/oauth`, chmod 600, root-only on host. |
| Generated auth keys | Briefly in transit between Tailscale API and the new container. Lives on the container at `/etc/tailscale/authkey` (chmod 600) for ~5 seconds before being shredded. |
| Tailnet | The container appears tagged `tag:lxc` immediately after firstboot. ACLs control what it can reach. |

The web UI is **not** exposed to the public internet unless you take additional steps:
- It does not enable Tailscale Funnel.
- It does not configure port forwarding.
- It does not bind to a public IP unless your Proxmox host has one.

If your Proxmox host happens to be on a public IP (rare but possible), port 8080 would be reachable from the internet. Use `iptables` or your firewall to restrict it, or change the Flask `app.run(host=...)` line to bind to a specific internal IP.

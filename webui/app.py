#!/usr/bin/env python3
"""Pithos v0.7.1 - LXC and VM provisioner + host-to-host transfer.

v0.2.2: optional HTTP Basic Auth covering every route (see AUTH_FILE below).
v0.2.3: parallel inventory gathering + stale-while-revalidate cache, so the
dashboard and /api/* stay fast on slow hosts.
v0.2.4: template + storage-backend checks cached too; every dashboard load is
now subprocess-free on the request path once warm.
v0.2.5: PITHOS_BIND env selects the listen address (default 0.0.0.0) so an
instance can be pinned to the tailscale or LAN interface only.
v0.2.6: PITHOS_ALLOW_SOURCES (admin-selectable, per host) refuses requests
from outside a CIDR allow list -- for hosts exposed to the internet.
v0.2.7: PITHOS_DEFAULT_STORAGE selects the default storage backend, and
PITHOS_HIDE_STORAGES hides backends from the picker (e.g. scratch disks),
both admin-selectable per host.
v0.2.8: SMART disk health at /api/disks (NVMe + SATA), cached separately via
PITHOS_DISK_CACHE_TTL.
v0.3.0: renamed from Tupperware to Pithos (see docs/rename.md). TUPPERWARE_*
env vars still read as a deprecated fallback.
v0.3.1: onboot is set explicitly on provisioning (default on) and surfaced in
the inventory, so containers restart after a power loss.
v0.4.0: template choice - templates are enumerated (LXC and VM), exposed at
/api/templates, and selectable in the clone form. VM templates are listed but
not yet provisionable.
v0.5.0: VM provisioning. Cloning a VM template runs pithos-new-vm (qm clone
plus a cloud-init drive) instead of pithos-new (pct clone plus pct exec).
v0.6.0: network bridge selection. Bridges are enumerated and flagged public
or private, so a clone is placed deliberately instead of inheriting the
template's - which on a host with a public bridge put guests on the internet.
v0.7.0: mesh view. PITHOS_PEERS lists other Pithos hosts and the dashboard
shows a resource card per host. Peers are contacted over the tailnet only -
an address outside 100.64.0.0/10 is refused at startup.
v0.7.1: per-peer mesh credentials (user:pass@host:port), so a host that
keeps its own credential does not force the mesh onto one shared password.
"""
import subprocess
import re
import ipaddress
import socket
import base64
import urllib.request
import urllib.error
import os
import json
import time
import hmac
import threading
from concurrent.futures import ThreadPoolExecutor
from flask import Flask, render_template_string, request, Response, stream_with_context, jsonify
from werkzeug.security import check_password_hash


def _env(name, default=None):
    """Read PITHOS_<name>, falling back to the pre-0.3.0 TUPPERWARE_<name>.

    The fallback keeps hosts installed before the rename working until their
    systemd drop-ins are migrated; see docs/rename.md."""
    return os.environ.get("PITHOS_" + name,
                          os.environ.get("TUPPERWARE_" + name, default))


app = Flask(__name__)

CLONE_SCRIPT = "/usr/local/sbin/pithos-new"
CLONE_VM_SCRIPT = "/usr/local/sbin/pithos-new-vm"
TRANSFER_SCRIPT = "/usr/local/sbin/pithos-transfer"
DEFAULT_STORAGE = _env("DEFAULT_STORAGE", "local-lvm")
# Admin-selectable per host: comma-separated storage names to keep out of the
# provisioning picker (e.g. non-redundant scratch disks). Unset = show all.
# The default storage is never hidden, even if listed, so provisioning cannot
# be left with no valid target.
# Mesh: peers to show alongside this host. Comma-separated host or host:port.
# Must be tailnet addresses - see _parse_peers.
MESH_USER = _env("MESH_USER", "") or _env("PEER_USER", "")
MESH_PASS = _env("MESH_PASS", "") or _env("PEER_PASS", "")
MESH_CACHE_TTL = float(_env("MESH_CACHE_TTL", "20"))
HIDE_STORAGES = {
    s.strip() for s in _env("HIDE_STORAGES", "").split(",") if s.strip()
}
TEMPLATE_VMID = int(os.environ.get("TEMPLATE_VMID", "9000"))
OAUTH_FILE = "/root/.tailscale/oauth"
TRANSFER_LOG = "/var/log/pithos/transfer.log"
SAMPLE_TEMPLATE_URL = "https://github.com/SuperAngryMonkey/pithos/releases/latest/download/pithos-template.tar.zst"

# Cache for prox-hosts (60s TTL)
_PROX_HOSTS_CACHE = {"ts": 0, "data": None}

# --- HTTP Basic Auth (v0.2.2) -------------------------------------------
# Opt-in: create AUTH_FILE containing a single line "username:werkzeug-hash".
# Generate the line with:
#   python3 -c "from werkzeug.security import generate_password_hash as g; \
#       import getpass; print('admin:' + g(getpass.getpass()))"
# When the file exists, EVERY route (HTML UI, /api/*, /clone-stream,
# /transfer-stream) requires Basic auth. When it is absent the app runs
# unauthenticated (pre-v0.2.2 behavior) and logs a warning at startup.
AUTH_FILE = _env("AUTH_FILE", "/root/.pithos/auth")
_AUTH_CACHE = {"mtime": None, "cred": None}


# --- Source scoping (v0.2.6) --------------------------------------------
# Admin-selectable, per host: set PITHOS_ALLOW_SOURCES to a comma-
# separated CIDR list (e.g. "127.0.0.0/8,10.0.0.0/24,100.64.0.0/10") and
# every request from any other source address is refused with 403, before
# auth runs. Unset (default) = no restriction. Intended for hosts exposed
# to the internet; hosts behind a perimeter firewall can leave it unset.
# A malformed CIDR fails at startup (loudly) rather than running open.
_raw_sources = _env("ALLOW_SOURCES", "").strip()
ALLOW_SOURCES = (
    [ipaddress.ip_network(s.strip(), strict=False) for s in _raw_sources.split(",") if s.strip()]
    if _raw_sources else None
)


def _source_allowed(addr):
    if ALLOW_SOURCES is None:
        return True
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in net for net in ALLOW_SOURCES)


def _load_auth():
    """Return (username, pwhash), or None when auth is not configured.

    A malformed or unreadable auth file yields ("", "") so requests are
    refused (fail closed) rather than silently unauthenticated.
    """
    try:
        st = os.stat(AUTH_FILE)
    except OSError:
        return None
    if _AUTH_CACHE["mtime"] != st.st_mtime:
        try:
            with open(AUTH_FILE) as f:
                line = f.read().strip()
            user, _, pwhash = line.partition(":")
            if user and pwhash:
                _AUTH_CACHE.update(mtime=st.st_mtime, cred=(user, pwhash))
            else:
                app.logger.error(
                    "pithos: %s is malformed (want user:hash); refusing all requests",
                    AUTH_FILE,
                )
                _AUTH_CACHE.update(mtime=st.st_mtime, cred=("", ""))
        except OSError as e:
            app.logger.error(
                "pithos: cannot read %s (%s); refusing all requests", AUTH_FILE, e
            )
            _AUTH_CACHE.update(mtime=None, cred=("", ""))
    return _AUTH_CACHE["cred"]


@app.before_request
def _require_auth():
    if not _source_allowed(request.remote_addr or ""):
        return Response("Forbidden.\n", 403)
    cred = _load_auth()
    if cred is None:
        return None  # auth not configured; open (pre-v0.2.2 behavior)
    auth = request.authorization
    if (
        auth is not None
        and auth.type == "basic"
        and hmac.compare_digest(auth.username or "", cred[0])
        and cred[1]
        and check_password_hash(cred[1], auth.password or "")
    ):
        return None
    return Response(
        "Authentication required.\n",
        401,
        {"WWW-Authenticate": 'Basic realm="pithos"'},
    )


def _template_exists_uncached():
    try:
        subprocess.check_output(["pct", "status", str(TEMPLATE_VMID)], stderr=subprocess.DEVNULL, text=True, timeout=5)
    except Exception:
        return False
    try:
        out = subprocess.check_output(["pct", "config", str(TEMPLATE_VMID)], text=True, timeout=5)
        for line in out.split("\n"):
            if line.startswith("template:"):
                return line.split(":", 1)[1].strip() == "1"
    except Exception:
        pass
    return False




def _is_private(ip):
    """RFC1918 / CGNAT / link-local. Anything else is publicly routable."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return True
    # Some Python versions do not treat CGNAT as private; tailnet addresses
    # live there and are emphatically not public.
    if a in ipaddress.ip_network("100.64.0.0/10"):
        return True
    return a.is_private or a.is_loopback or a.is_link_local



# --- Mesh (v0.7.0) --------------------------------------------------------
# Peers are other Pithos hosts. Traffic to them goes over the tailnet ONLY:
# a peer address must resolve into 100.64.0.0/10 or it is refused at startup.
# That keeps host-to-host traffic on an authenticated, encrypted transport and
# off any public interface.
TAILNET = ipaddress.ip_network("100.64.0.0/10")
MESH_TIMEOUT = float(_env("MESH_TIMEOUT", "6"))


def _peer_is_tailnet(host):
    """True only if every address the name resolves to sits in the tailnet."""
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET)
    except Exception:
        return False
    addrs = {i[4][0] for i in infos}
    if not addrs:
        return False
    return all(ipaddress.ip_address(a) in TAILNET for a in addrs)


def _parse_peers():
    """PITHOS_PEERS: comma-separated host or host:port entries.

    Non-tailnet peers are dropped with a logged error rather than silently
    contacted over another path.
    """
    raw = _env("PEERS", "").strip()
    peers = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        # Optional per-peer credentials: user:pass@host:port. A host that keeps
        # its own credential (an internet-facing node, say) should not force the
        # whole mesh onto one shared password.
        creds, sep, hostpart = item.rpartition("@")
        if not sep:
            hostpart, creds = item, ""
        user, _, pw = creds.partition(":")
        host, _, port = hostpart.partition(":")
        if not _peer_is_tailnet(host):
            app.logger.error(
                "pithos: peer %r is not a tailnet address - refusing to use it. "
                "Peers must resolve into 100.64.0.0/10.", host)
            continue
        peers.append({"host": host, "port": int(port) if port else 8080,
                      "user": user or MESH_USER, "pass": pw or MESH_PASS})
    return peers


PEERS = _parse_peers()


def _peer_status(peer):
    """Fetch one peer's /api/status. Never raises: a down peer is a card that
    says so, not a broken dashboard."""
    url = "http://%s:%d/api/status" % (peer["host"], peer["port"])
    card = {"host": peer["host"], "port": peer["port"], "url": url,
            "reachable": False, "error": ""}
    try:
        req = urllib.request.Request(url)
        u = peer.get("user") or MESH_USER
        pw = peer.get("pass") or MESH_PASS
        if u:
            tok = base64.b64encode(("%s:%s" % (u, pw)).encode()).decode()
            req.add_header("Authorization", "Basic " + tok)
        with urllib.request.urlopen(req, timeout=MESH_TIMEOUT) as r:
            card.update(json.loads(r.read().decode()))
            card["reachable"] = True
    except urllib.error.HTTPError as e:
        card["error"] = "HTTP %s%s" % (e.code, " - check mesh credentials" if e.code == 401 else "")
    except Exception as e:
        card["error"] = str(e)[:120]
    return card


def _mesh_uncached():
    """This host first, then each peer. Reported in configuration order."""
    cards = []
    me = dict(host_metrics())
    me.update({"host": me.get("hostname", "this host"), "reachable": True,
               "self": True, "error": ""})
    cards.append(me)
    if PEERS:
        with ThreadPoolExecutor(max_workers=min(8, len(PEERS))) as ex:
            cards.extend(ex.map(_peer_status, PEERS))
    return cards


def mesh_status():
    return _swr("mesh", _mesh_uncached, ttl=MESH_CACHE_TTL)

def _list_bridges_uncached():
    """Bridges on this host, with their address and whether it is public.

    Clones inherit the template's bridge unless told otherwise, which on a host
    with a public bridge means a new guest can land straight on the internet.
    Surfacing 'public' lets the picker warn rather than silently do that.
    """
    out = []
    seen = {}
    # Only real bridges. "ip addr show type bridge" is not reliably filtered on
    # every iproute2 build, so take the link list as authoritative.
    try:
        allb = subprocess.check_output(
            ["ip", "-o", "link", "show", "type", "bridge"], text=True, timeout=5)
        for line in allb.strip().split("\n"):
            if ":" not in line:
                continue
            nm = line.split(":")[1].strip().split("@")[0]
            # Skip the per-guest firewall bridges Proxmox creates.
            if nm and not nm.startswith(("fwbr", "fwln", "fwpr", "tap", "veth")):
                seen[nm] = ""
    except Exception:
        pass

    try:
        raw = subprocess.check_output(["ip", "-4", "-o", "addr", "show"], text=True, timeout=5)
        for line in raw.strip().split("\n"):
            parts = line.split()
            if len(parts) >= 4 and parts[1] in seen and not seen[parts[1]]:
                seen[parts[1]] = parts[3]
    except Exception:
        pass

    for name in sorted(seen):
        cidr = seen[name]
        ip = cidr.split("/")[0] if cidr else ""
        out.append({"name": name, "cidr": cidr,
                    "public": bool(ip) and not _is_private(ip)})
    return out


def list_bridges():
    return _swr("bridges", _list_bridges_uncached)

def _list_templates_uncached():
    """Every template on this host, LXC and VM, newest VMID last.

    kind is 'lxc' or 'vm' and decides which clone path provisioning uses:
    pct clone + pct exec for lxc, qm clone + cloud-init for vm.
    """
    out = []

    try:
        raw = subprocess.check_output(["pct", "list"], text=True, timeout=5)
        for line in raw.strip().split("\n")[1:]:
            parts = line.split(None, 3)
            if len(parts) < 3:
                continue
            vmid = parts[0]
            cfg = parse_pct_config(vmid)
            if cfg.get("template") != "1":
                continue
            out.append({"vmid": vmid, "kind": "lxc",
                        "name": cfg.get("hostname", parts[2]),
                        "os": "debian", "notes": cfg.get("description", "")[:120]})
    except Exception:
        pass

    try:
        raw = subprocess.check_output(["qm", "list"], text=True, timeout=10)
        for line in raw.strip().split("\n")[1:]:
            parts = line.split()
            if len(parts) < 2:
                continue
            vmid = parts[0]
            try:
                cfg = subprocess.check_output(["qm", "config", vmid], text=True, timeout=10)
            except Exception:
                continue
            conf = {}
            for ln in cfg.split("\n"):
                if ":" in ln:
                    k, v = ln.split(":", 1)
                    conf[k.strip()] = v.strip()
            if conf.get("template") != "1":
                continue
            out.append({"vmid": vmid, "kind": "vm",
                        "name": conf.get("name", parts[1]),
                        "os": conf.get("ostype", "?"),
                        "notes": conf.get("description", "")[:120]})
    except Exception:
        pass

    return sorted(out, key=lambda t: int(t["vmid"]))


def list_templates():
    return _swr("templates", _list_templates_uncached)

def next_free_vmid(start=200):
    used = set()
    for cmd in (["pct", "list"], ["qm", "list"]):
        try:
            out = subprocess.check_output(cmd, text=True, timeout=5)
            for line in out.strip().split("\n")[1:]:
                parts = line.split()
                if parts:
                    try: used.add(int(parts[0]))
                    except ValueError: pass
        except Exception: pass
    v = start
    while v in used: v += 1
    return v


def _list_storage_backends_uncached():
    backends = []
    try:
        out = subprocess.check_output(["pvesm", "status", "-content", "rootdir"], text=True, timeout=5)
        for line in out.strip().split("\n")[1:]:
            parts = line.split()
            if len(parts) >= 2:
                if parts[0] in HIDE_STORAGES and parts[0] != DEFAULT_STORAGE:
                    continue
                backends.append({"name": parts[0], "type": parts[1], "active": parts[2] if len(parts) > 2 else "?"})
    except Exception: pass
    return backends



# --- Inventory cache (v0.2.3) -------------------------------------------
# The dashboard and /api/* inventory calls shell out to pct/qm/tailscale
# many times; on slow hosts that meant 30s+ per request. Results are cached
# for CACHE_TTL seconds and, once expired, refreshed in a background thread
# while the stale copy is served (stale-while-revalidate) -- so after the
# first warm-up every response is instant.
CACHE_TTL = float(_env("CACHE_TTL", "30"))
_CACHE_LOCK = threading.Lock()
_CACHES = {}


def _swr(name, fn, ttl=None):
    ttl = CACHE_TTL if ttl is None else ttl
    now = time.time()
    with _CACHE_LOCK:
        c = _CACHES.setdefault(name, {"ts": 0.0, "data": None, "refreshing": False})
        if c["data"] is not None and (now - c["ts"] < ttl or c["refreshing"]):
            return c["data"]
        c["refreshing"] = True
        stale = c["data"]
    if stale is not None:
        threading.Thread(target=_swr_refresh, args=(name, fn), daemon=True).start()
        return stale
    return _swr_refresh(name, fn)  # cold start: compute synchronously


def _swr_refresh(name, fn):
    try:
        data = fn()
    except Exception:
        with _CACHE_LOCK:
            _CACHES[name]["refreshing"] = False
        raise
    with _CACHE_LOCK:
        _CACHES[name].update(ts=time.time(), data=data, refreshing=False)
    return data


def bust_inventory_cache():
    """Force fresh data on the next read (called after clone/transfer)."""
    with _CACHE_LOCK:
        for c in _CACHES.values():
            c["ts"] = 0.0


def template_exists():
    return _swr("template", _template_exists_uncached)


def list_storage_backends():
    return _swr("storages", _list_storage_backends_uncached)


def _host_metrics_uncached():
    try: ct_count = len(subprocess.check_output(["pct", "list"], text=True).strip().split("\n")) - 1
    except Exception: ct_count = "?"
    try: vm_count = len(subprocess.check_output(["qm", "list"], text=True).strip().split("\n")) - 1
    except Exception: vm_count = "?"
    try:
        ts_data = json.loads(subprocess.check_output(["tailscale", "status", "--json"], text=True, timeout=3))
        ts_self = ts_data.get("Self", {}).get("HostName", "?")
        ts_peers = len(ts_data.get("Peer", {}))
    except Exception:
        ts_self = "offline"; ts_peers = "?"
    try: hostname = subprocess.check_output(["hostname"], text=True).strip()
    except Exception: hostname = "proxmox"
    # Resource figures, for the mesh cards and any capacity check.
    cores = 0
    mem_total = mem_avail = 0
    try:
        cores = os.cpu_count() or 0
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1]) * 1024
                elif line.startswith("MemAvailable:"):
                    mem_avail = int(line.split()[1]) * 1024
    except Exception:
        pass

    load1 = 0.0
    try:
        load1 = os.getloadavg()[0]
    except Exception:
        pass

    # Free space on the default storage - the one provisioning actually uses.
    store_total = store_avail = 0
    try:
        out = subprocess.check_output(["pvesm", "status"], text=True, timeout=10)
        for line in out.strip().split("\n")[1:]:
            f = line.split()
            if len(f) >= 6 and f[0] == DEFAULT_STORAGE:
                store_total = int(f[3]) * 1024
                store_avail = int(f[5]) * 1024
                break
    except Exception:
        pass

    return {"ct_count": ct_count, "vm_count": vm_count, "ts_self": ts_self, "ts_peers": ts_peers,
            "hostname": hostname, "next_vmid": next_free_vmid(),
            "cores": cores, "load1": round(load1, 2),
            "mem_total": mem_total, "mem_avail": mem_avail,
            "store_name": DEFAULT_STORAGE,
            "store_total": store_total, "store_avail": store_avail}


def host_metrics():
    return _swr("metrics", _host_metrics_uncached)


def parse_pct_config(vmid):
    cfg = {}
    try:
        out = subprocess.check_output(["pct", "config", str(vmid)], text=True, timeout=5)
        for line in out.strip().split("\n"):
            if ":" in line:
                k, _, v = line.partition(":")
                cfg[k.strip()] = v.strip()
    except Exception: pass
    return cfg


def container_ip(vmid):
    try:
        out = subprocess.check_output(["pct", "exec", str(vmid), "--", "hostname", "-I"],
                                      text=True, timeout=3, stderr=subprocess.DEVNULL)
        ips = out.strip().split()
        for ip in ips:
            if not ip.startswith("100."): return ip
        return ips[0] if ips else ""
    except Exception: return ""


def container_tailnet_ip(vmid):
    try:
        out = subprocess.check_output(["pct", "exec", str(vmid), "--", "tailscale", "ip", "-4"],
                                      text=True, timeout=3, stderr=subprocess.DEVNULL)
        return out.strip().split("\n")[0] if out.strip() else ""
    except Exception: return ""


def container_storage(cfg):
    rootfs = cfg.get("rootfs", "")
    return rootfs.split(":", 1)[0] if ":" in rootfs else ""


def _gather_container(parts):
    vmid, status, name = parts
    try:
        cfg = parse_pct_config(vmid)
        if cfg.get("template") == "1":
            return None
        desc = cfg.get("description", "").replace("%0A", "\n").replace("%20", " ")
        rootfs = cfg.get("rootfs", "")
        disk_size = ""
        m = re.search(r"size=(\S+)", rootfs)
        if m: disk_size = m.group(1)
        lan_ip = container_ip(vmid) if status == "running" else ""
        ts_ip = container_tailnet_ip(vmid) if status == "running" else ""
        return {
            "vmid": vmid, "name": name, "status": status,
            "cores": cfg.get("cores", "?"), "memory": cfg.get("memory", "?"),
            "disk": disk_size, "storage": container_storage(cfg),
            "lan_ip": lan_ip, "ts_ip": ts_ip,
            "description": desc, "tags": cfg.get("tags", ""),
            "onboot": cfg.get("onboot", "0") == "1",
        }
    except Exception:
        return None


def _list_containers_uncached():
    rows = []
    try:
        out = subprocess.check_output(["pct", "list"], text=True, timeout=5)
        for line in out.strip().split("\n")[1:]:
            parts = line.split(None, 3)
            if len(parts) < 3: continue
            rows.append((parts[0], parts[1], parts[2]))
    except Exception:
        return []
    if not rows:
        return []
    with ThreadPoolExecutor(max_workers=min(8, len(rows))) as ex:
        results = list(ex.map(_gather_container, rows))
    return [r for r in results if r is not None]


def list_containers():
    return _swr("containers", _list_containers_uncached)


def get_oauth_token():
    """Get an OAuth access token from credentials file."""
    if not os.path.exists(OAUTH_FILE): return None
    creds = {}
    with open(OAUTH_FILE) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                creds[k.strip()] = v.strip().strip('"').strip("'")
    cid = creds.get("TS_OAUTH_CLIENT_ID"); csec = creds.get("TS_OAUTH_CLIENT_SECRET")
    if not cid or not csec: return None
    try:
        r = subprocess.run([
            "curl", "-fsS",
            "-d", f"client_id={cid}",
            "-d", f"client_secret={csec}",
            "-d", "grant_type=client_credentials",
            "https://api.tailscale.com/api/v2/oauth/token"
        ], capture_output=True, text=True, timeout=10)
        if r.returncode != 0: return None
        data = json.loads(r.stdout)
        return data.get("access_token")
    except Exception: return None


def list_prox_hosts():
    """Return list of Tailscale devices tagged tag:prox-host, excluding self."""
    now = time.time()
    if _PROX_HOSTS_CACHE["data"] is not None and (now - _PROX_HOSTS_CACHE["ts"]) < 60:
        return _PROX_HOSTS_CACHE["data"]

    token = get_oauth_token()
    if not token: return []

    try:
        # Query the tailnet devices endpoint
        r = subprocess.run([
            "curl", "-fsS",
            "-H", f"Authorization: Bearer {token}",
            "https://api.tailscale.com/api/v2/tailnet/-/devices"
        ], capture_output=True, text=True, timeout=10)
        if r.returncode != 0: return []
        data = json.loads(r.stdout)
    except Exception:
        return []

    # Get self FQDN to exclude
    try:
        self_data = json.loads(subprocess.check_output(["tailscale", "status", "--json"], text=True, timeout=3))
        self_fqdn = self_data.get("Self", {}).get("DNSName", "").rstrip(".")
    except Exception:
        self_fqdn = ""

    hosts = []
    for d in data.get("devices", []):
        tags = d.get("tags", []) or []
        if "tag:prox-host" not in tags: continue
        fqdn = d.get("name", "").rstrip(".")
        if fqdn == self_fqdn: continue
        hosts.append({
            "name": d.get("hostname", fqdn.split(".")[0]),
            "fqdn": fqdn,
            "ip": (d.get("addresses") or [""])[0],
            "online": (now - _parse_iso(d.get("lastSeen", ""))) < 300 if d.get("lastSeen") else False,
        })

    _PROX_HOSTS_CACHE["ts"] = now
    _PROX_HOSTS_CACHE["data"] = hosts
    return hosts


def _parse_iso(s):
    if not s: return 0
    try:
        # Tailscale uses ISO 8601 with Z suffix
        from datetime import datetime
        s = s.replace("Z", "+00:00")
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return 0


def get_dest_storage(dest_fqdn):
    """SSH to a destination prox-host and list its storage backends."""
    if not re.match(r"^[a-zA-Z0-9\.\-]+$", dest_fqdn): return []
    try:
        r = subprocess.run([
            "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            f"root@{dest_fqdn}",
            "pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1\":\"$2}'"
        ], capture_output=True, text=True, timeout=10)
        if r.returncode != 0: return []
        backends = []
        for line in r.stdout.strip().split("\n"):
            if ":" in line:
                name, _, typ = line.partition(":")
                backends.append({"name": name.strip(), "type": typ.strip()})
        return backends
    except Exception: return []


def transfer_history(limit=10):
    """Read last N transfer log entries from JSON log file."""
    if not os.path.exists(TRANSFER_LOG): return []
    entries = []
    try:
        with open(TRANSFER_LOG) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                try: entries.append(json.loads(line))
                except Exception: pass
    except Exception: pass
    return list(reversed(entries))[:limit]


SHARED_STYLE = r"""
:root[data-theme="light"]{
  /* Matches Clio's light theme. The dark palette's neons are unreadable on a
     light background, so accents are re-picked rather than reused. */
  --c1:#faf9f7;--c2:#efedea;--c3:#e8e5e0;
  --acc:#0a6b8a;--acc2:#c2410c;--acc3:#15803d;--danger:#c2410c;
  --txt:#26262c;--txt2:#6b6b76;--txt3:#8a8a94;
  --border:1px solid #dcd9d4;--border-strong:1px solid #cfcbc4;
  --border-subtle:1px solid #e8e5e0;
}
:root{--c1:#0a0a0f;--c2:#0f0f1a;--c3:#14141f;--acc:#00d4ff;--acc2:#ff6b35;--acc3:#00ff88;--danger:#ff3366;--txt:#e8e8f0;--txt2:#8888aa;--txt3:#4444aa;--fmono:'IBM Plex Mono',monospace;--fdisplay:'Bebas Neue',sans-serif;--border:1px solid rgba(0,212,255,0.12);--border-strong:1px solid rgba(0,212,255,0.2);--border-subtle:1px solid rgba(255,255,255,0.05);}
*{box-sizing:border-box;margin:0;padding:0;}
html,body{height:100%;background:var(--c1);color:var(--txt);font-family:var(--fmono);font-size:12px;}
body{padding:20px;max-width:1400px;margin:0 auto;}
.hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px;padding-bottom:12px;border-bottom:var(--border-strong);}
.hdr-left{display:flex;align-items:baseline;gap:16px;}
.hdr-right{display:flex;align-items:center;gap:20px;}
.logo{font-family:var(--fdisplay);font-size:42px;letter-spacing:4px;color:var(--acc);line-height:1;}
.subtitle{font-size:10px;color:var(--txt2);letter-spacing:2px;text-transform:uppercase;}
.clock{font-size:16px;color:var(--txt2);letter-spacing:2px;}
.themebtn{background:none;border:var(--border);color:var(--txt2);font-family:var(--fmono);font-size:9px;letter-spacing:1px;padding:4px 9px;cursor:pointer;}.themebtn:hover{color:var(--txt);border:var(--border-strong);}.status-dot{width:8px;height:8px;border-radius:50%;background:var(--acc3);box-shadow:0 0 8px var(--acc3);animation:pulse 2s infinite;}
.status-dot.warn{background:var(--acc2);box-shadow:0 0 8px var(--acc2);}
.status-txt{font-size:10px;color:var(--acc3);letter-spacing:1px;}
.status-txt.warn{color:var(--acc2);}
@keyframes pulse{0%,100%{opacity:1;}50%{opacity:0.4;}}
.panel{background:var(--c2);border:var(--border);padding:16px;margin-bottom:16px;}
.panel-hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;padding-bottom:8px;border-bottom:var(--border-subtle);}
.panel-title{font-size:9px;letter-spacing:3px;text-transform:uppercase;color:var(--txt2);}
.panel-badge{font-size:9px;padding:2px 8px;border:1px solid;letter-spacing:1px;}
.panel-badge.live{color:var(--acc3);border-color:var(--acc3);}
.panel-badge.warn{color:var(--acc2);border-color:var(--acc2);}
.panel-badge.err{color:var(--danger);border-color:var(--danger);}
.panel-badge.idle{color:var(--txt3);border-color:var(--txt3);}
.btn{background:transparent;border:1px solid var(--acc);color:var(--acc);font-family:var(--fmono);font-size:11px;padding:12px 28px;cursor:pointer;letter-spacing:3px;text-transform:uppercase;}
.btn:hover{background:rgba(0,212,255,0.1);}
.btn:disabled{opacity:0.4;cursor:not-allowed;}
.btn-small{padding:6px 14px;font-size:9px;letter-spacing:2px;}
.btn-xfer{padding:4px 10px;font-size:9px;letter-spacing:1px;border-color:var(--acc2);color:var(--acc2);}
.btn-xfer:hover{background:rgba(255,107,53,0.1);}
.form-input{background:var(--c3);border:var(--border);color:var(--txt);font-family:var(--fmono);font-size:11px;padding:10px 14px;outline:none;width:100%;}
.form-input:focus{border-color:var(--acc);}
.form-select{background:var(--c3);border:var(--border);color:var(--txt);font-family:var(--fmono);font-size:11px;padding:10px 14px;outline:none;appearance:none;cursor:pointer;width:100%;}
.form-label{font-size:9px;color:var(--txt2);letter-spacing:2px;text-transform:uppercase;display:block;margin-bottom:6px;}
.console{background:#000;border:var(--border);padding:14px;min-height:200px;max-height:480px;overflow-y:auto;font-family:var(--fmono);font-size:11px;line-height:1.5;white-space:pre-wrap;word-wrap:break-word;}
.console .ok{color:var(--acc3);} .console .info{color:var(--acc);} .console .warn{color:var(--acc2);} .console .err{color:var(--danger);} .console .dim{color:var(--txt3);}
.console-empty{color:var(--txt3);font-style:italic;}
"""


# Setup page (template not found) — same as v0.1.5
SETUP_PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><script>(function(){try{var s=localStorage.getItem("pithos-theme");document.documentElement.setAttribute("data-theme",s||(matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"));}catch(e){}})();</script><title>PITHOS SETUP</title>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Bebas+Neue&display=swap" rel="stylesheet">
<style>""" + SHARED_STYLE + r""" .setup-banner{background:var(--c2);border:1px solid var(--acc2);padding:24px;margin-bottom:20px;} .setup-title{font-family:var(--fdisplay);font-size:28px;letter-spacing:3px;color:var(--acc2);margin-bottom:8px;}</style></head><body>
<div class="hdr"><div class="hdr-left"><div class="logo">PITHOS</div><div class="subtitle">SETUP REQUIRED // {{ hostname }}</div></div><div class="hdr-right"><div class="status-dot warn"></div><div class="status-txt warn">SETUP REQUIRED</div></div></div>
<div class="setup-banner"><div class="setup-title">NO TEMPLATE FOUND</div><div>Pithos needs an LXC template at VMID {{ template_vmid }}.</div></div>
<div class="panel"><div class="panel-title">RUN ONE OF:</div><pre style="color:var(--acc3);font-size:13px;padding:12px;">pithos-import-template   # easiest, ~2 min
pithos-build-template    # build from scratch, ~4 min</pre></div></body></html>"""


INDEX = r"""<!doctype html><html><head><meta charset="utf-8"><script>(function(){try{var s=localStorage.getItem("pithos-theme");document.documentElement.setAttribute("data-theme",s||(matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"));}catch(e){}})();</script><title>PITHOS</title>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=Bebas+Neue&display=swap" rel="stylesheet">
<style>""" + SHARED_STYLE + r"""
.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:16px;}
.metric{background:var(--c2);border:var(--border);padding:16px;position:relative;overflow:hidden;}
.metric::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;}
.metric.blue::before{background:var(--acc);} .metric.orange::before{background:var(--acc2);} .metric.green::before{background:var(--acc3);}
.metric-label{font-size:9px;color:var(--txt2);letter-spacing:2px;text-transform:uppercase;margin-bottom:8px;}
.metric-val{font-family:var(--fdisplay);font-size:36px;letter-spacing:2px;line-height:1;}
.metric.blue .metric-val{color:var(--acc);} .metric.orange .metric-val{color:var(--acc2);} .metric.green .metric-val{color:var(--acc3);}
.metric-sub{font-size:9px;color:var(--txt3);margin-top:4px;}
.form-grid{display:grid;grid-template-columns:2fr 1fr 1fr 1fr 1fr;gap:12px;}
.form-grid.row2{grid-template-columns:1fr 1fr 1fr;margin-top:12px;}
.btn-row{margin-top:16px;display:flex;gap:8px;}
.inv-table{width:100%;border-collapse:collapse;font-size:11px;}
.inv-table th{text-align:left;padding:8px 10px;font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--txt2);border-bottom:var(--border);font-weight:normal;}
.inv-table td{padding:10px;border-bottom:var(--border-subtle);vertical-align:top;}
.inv-vmid{color:var(--acc);font-weight:500;}
.inv-name{color:var(--txt);font-weight:500;}
.inv-status{display:inline-block;padding:2px 8px;border:1px solid;font-size:9px;letter-spacing:1px;}
.inv-status.running{color:var(--acc3);border-color:var(--acc3);}
.inv-status.stopped{color:var(--txt3);border-color:var(--txt3);}
.inv-ip{font-size:10px;color:var(--txt2);}
.inv-ip-ts{color:var(--acc);}
.inv-storage{font-size:10px;color:var(--txt2);}
.inv-notes{color:var(--txt2);font-size:10px;font-style:italic;max-width:240px;}
.inv-empty{text-align:center;color:var(--txt3);font-style:italic;padding:30px;}
.modal-bg{display:none;position:fixed;inset:0;background:rgba(0,0,0,0.85);z-index:100;align-items:center;justify-content:center;}
.modal-bg.open{display:flex;}
.modal{background:var(--c2);border:var(--border-strong);padding:24px;width:500px;max-width:90vw;}
.modal-title{font-family:var(--fdisplay);font-size:24px;letter-spacing:3px;color:var(--acc2);margin-bottom:4px;}
.modal-sub{font-size:10px;color:var(--txt2);letter-spacing:1px;margin-bottom:16px;}
.modal-field{margin-bottom:14px;}
.radio-row{display:flex;gap:8px;}
.radio-opt{flex:1;background:var(--c3);border:var(--border);padding:10px;cursor:pointer;font-size:10px;}
.radio-opt.selected{border-color:var(--acc2);color:var(--acc2);}
.modal-actions{display:flex;gap:8px;margin-top:18px;}
.btn-cancel{border-color:var(--txt3);color:var(--txt3);}
.btn-cancel:hover{background:rgba(255,255,255,0.05);}
.btn-go{border-color:var(--acc2);color:var(--acc2);}
.btn-go:hover{background:rgba(255,107,53,0.1);}
.hist-table{width:100%;border-collapse:collapse;font-size:10px;}
.hist-table th{text-align:left;padding:6px 8px;font-size:9px;letter-spacing:2px;text-transform:uppercase;color:var(--txt2);border-bottom:var(--border);font-weight:normal;}
.hist-table td{padding:8px;border-bottom:var(--border-subtle);}
.hist-status.success{color:var(--acc3);} .hist-status.failed{color:var(--danger);} .hist-status.partial{color:var(--acc2);}
</style></head><body>
<div class="hdr"><div class="hdr-left"><div class="logo">PITHOS</div><div class="subtitle">LXC PROVISIONER // {{ m.hostname }}</div></div>
<div class="hdr-right"><button class="themebtn" id="tt" type="button" title="Switch light/dark">THEME</button><div class="clock" id="clock">--:--:--</div><div class="status-dot"></div><div class="status-txt">OPERATIONAL</div></div></div>

<div class="metrics">
  <div class="metric blue"><div class="metric-label">CONTAINERS</div><div class="metric-val">{{ m.ct_count }}</div><div class="metric-sub">LXC on host</div></div>
  <div class="metric orange"><div class="metric-label">VMS</div><div class="metric-val">{{ m.vm_count }}</div><div class="metric-sub">QEMU on host</div></div>
  <div class="metric green"><div class="metric-label">TAILNET PEERS</div><div class="metric-val">{{ m.ts_peers }}</div><div class="metric-sub">visible from {{ m.ts_self }}</div></div>
  <div class="metric blue"><div class="metric-label">NEXT VMID</div><div class="metric-val">{{ m.next_vmid }}</div><div class="metric-sub">auto-pick</div></div>
</div>

<div class="panel">
  <div class="panel-hdr"><div class="panel-title">MESH</div>
    <div class="panel-badge idle">{{ mesh|length }} HOST{{ '' if mesh|length == 1 else 'S' }}</div></div>
  <div class="metrics">
  {% for h in mesh %}
    <div class="metric {{ 'green' if h.reachable else 'orange' }}">
      <div class="metric-label">{{ h.hostname or h.host }}{% if h.self %} (THIS){% endif %}</div>
      {% if h.reachable %}
        <div class="metric-val">{{ h.ct_count }}/{{ h.vm_count }}</div>
        <div class="metric-sub">
          CT/VM &middot; {{ h.cores }} cores &middot; load {{ h.load1 }}<br>
          {% if h.mem_total %}RAM {{ (h.mem_avail / 1073741824)|round(1) }} of {{ (h.mem_total / 1073741824)|round(1) }} GB free<br>{% endif %}
          {% if h.store_total %}{{ h.store_name }} {{ (h.store_avail / 1073741824)|round(0)|int }} of {{ (h.store_total / 1073741824)|round(0)|int }} GB free{% endif %}
        </div>
      {% else %}
        <div class="metric-val">--</div>
        <div class="metric-sub">unreachable<br>{{ h.error }}</div>
      {% endif %}
    </div>
  {% endfor %}
  </div>
</div>

<div class="panel"><div class="panel-hdr"><div class="panel-title">CLONE PARAMETERS</div><div class="panel-badge idle" id="form-status">READY</div></div>
<form id="clone-form">
  <div class="form-grid">
    <div><label class="form-label">HOSTNAME</label><input class="form-input" type="text" name="hostname" required placeholder="lab-lxc-01" pattern="[a-zA-Z0-9\-]+" autofocus></div>
    <div><label class="form-label">VMID</label><input class="form-input" type="number" name="vmid" placeholder="{{ m.next_vmid }}"></div>
    <div><label class="form-label">CORES</label><input class="form-input" type="number" name="cores" placeholder="1"></div>
    <div><label class="form-label">MEMORY MB</label><input class="form-input" type="number" name="memory" placeholder="512"></div>
    <div><label class="form-label">DISK GB</label><input class="form-input" type="number" name="disk" placeholder="4"></div>
  </div>
  <div class="form-grid row2">
    <div><label class="form-label">TEMPLATE</label><select class="form-select" name="template">
      {% for t in templates %}
      <option value="{{ t.vmid }}"{% if t.vmid == default_template %} selected{% endif %}>
        {{ t.vmid }} - {{ t.name }} ({{ t.kind }}{% if t.kind != 'lxc' %} - {{ t.os }}{% endif %})
      </option>
      {% endfor %}
    </select></div>
    <div><label class="form-label">NETWORK</label><select class="form-select" name="bridge">
      {% for b in bridges %}
      <option value="{{ b.name }}"{% if not b.public and loop.first %} selected{% endif %}>
        {{ b.name }}{% if b.cidr %} ({{ b.cidr }}){% endif %}{% if b.public %} - PUBLIC{% endif %}
      </option>
      {% endfor %}
    </select></div>
    <div><label class="form-label">STORAGE BACKEND</label><select class="form-select" name="storage">
      {% for s in storages %}<option value="{{ s.name }}"{% if s.name == default_storage %} selected{% endif %}>{{ s.name }} ({{ s.type }})</option>{% endfor %}
    </select></div>
    <div><label class="form-label">ROOT PASSWORD (OPTIONAL)</label><input class="form-input" type="password" name="rootpw" placeholder="leave blank for tailscale ssh only" autocomplete="new-password"></div>
  </div>
  <div class="form-grid row2">
    <div><label class="form-label">START AT BOOT</label>
      <label style="display:flex;align-items:center;gap:8px;padding-top:6px">
        <input type="checkbox" name="onboot" value="1" checked>
        <span style="font-size:12px;opacity:.8">start automatically when the host powers on</span>
      </label>
    </div>
  </div>
  <div class="btn-row"><button class="btn" type="submit" id="submit-btn">CLONE &amp; JOIN TAILNET</button></div>
</form></div>

<div class="panel"><div class="panel-hdr"><div class="panel-title">PROVISIONING CONSOLE</div><div class="panel-badge idle" id="console-status">IDLE</div></div>
<div class="console" id="console"><div class="console-empty">Awaiting request...</div></div></div>

<div class="panel"><div class="panel-hdr"><div class="panel-title">INVENTORY &mdash; {{ containers|length }} CONTAINER{{ '' if containers|length == 1 else 'S' }}</div>
<button class="btn btn-small" type="button" onclick="window.location.reload()">REFRESH</button></div>
{% if containers %}<table class="inv-table"><thead><tr>
<th>VMID</th><th>HOSTNAME</th><th>STATUS</th><th>CPU/MEM/DISK</th><th>STORAGE</th><th>NETWORK</th><th>NOTES</th><th></th>
</tr></thead><tbody>
{% for c in containers %}<tr>
<td class="inv-vmid">{{ c.vmid }}</td>
<td class="inv-name">{{ c.name }}</td>
<td><span class="inv-status {{ c.status }}">{{ c.status }}</span>{% if not c.onboot %} <span class="inv-status stopped" title="This container will NOT start after a host reboot">NO BOOT</span>{% endif %}</td>
<td>{{ c.cores }}c / {{ c.memory }}MB / {{ c.disk }}</td>
<td class="inv-storage">{{ c.storage or '—' }}</td>
<td class="inv-ip">{% if c.lan_ip %}{{ c.lan_ip }}<br>{% endif %}{% if c.ts_ip %}<span class="inv-ip-ts">{{ c.ts_ip }}</span>{% endif %}</td>
<td class="inv-notes">{{ c.description or '—' }}</td>
<td><button class="btn btn-xfer" type="button" onclick="openTransfer('{{ c.vmid }}','{{ c.name }}')">TRANSFER</button></td>
</tr>{% endfor %}
</tbody></table>{% else %}<div class="inv-empty">No containers found.</div>{% endif %}</div>

<div class="panel"><div class="panel-hdr"><div class="panel-title">TRANSFER HISTORY (LAST 10)</div></div>
{% if history %}<table class="hist-table"><thead><tr>
<th>WHEN</th><th>SOURCE</th><th>DESTINATION</th><th>IDENTITY</th><th>SIZE</th><th>DURATION</th><th>STATUS</th>
</tr></thead><tbody>
{% for h in history %}<tr>
<td>{{ h.ts }}</td>
<td>{{ h.src_vmid }} ({{ h.src_hostname }})</td>
<td>{{ h.dest_host }}{% if h.dest_vmid %} → {{ h.dest_vmid }}{% endif %}</td>
<td>{{ h.identity }}</td>
<td>{% if h.size_bytes %}{{ (h.size_bytes/1024/1024)|round(1) }}MB{% else %}—{% endif %}</td>
<td>{{ h.duration_seconds }}s</td>
<td class="hist-status {{ h.status }}">{{ h.status|upper }}</td>
</tr>{% endfor %}
</tbody></table>{% else %}<div class="inv-empty">No transfers recorded yet.</div>{% endif %}</div>

<!-- Transfer modal -->
<div class="modal-bg" id="xfer-modal"><div class="modal">
<div class="modal-title">TRANSFER CONTAINER</div>
<div class="modal-sub" id="xfer-src">VMID — (—)</div>
<div class="modal-field"><label class="form-label">DESTINATION HOST</label>
<select class="form-select" id="xfer-dest" onchange="loadDestStorage()"><option value="">Loading...</option></select></div>
<div class="modal-field"><label class="form-label">DESTINATION STORAGE</label>
<select class="form-select" id="xfer-storage"><option value="">Select destination first</option></select></div>
<div class="modal-field"><label class="form-label">IDENTITY</label>
<div class="radio-row">
<div class="radio-opt selected" id="id-fresh" onclick="selectIdentity('fresh')">FRESH<br><span style="color:var(--txt3);">new tailnet IP</span></div>
<div class="radio-opt" id="id-preserve" onclick="selectIdentity('preserve')">PRESERVE<br><span style="color:var(--txt3);">same machine key</span></div>
</div></div>
<div class="modal-actions">
<button class="btn btn-cancel" type="button" onclick="closeTransfer()">CANCEL</button>
<button class="btn btn-go" type="button" id="xfer-go" onclick="startTransfer()">TRANSFER</button>
</div></div></div>

<script>
const NL = String.fromCharCode(10);
let xferVmid = '', xferName = '', xferIdentity = 'fresh';

document.getElementById('tt').addEventListener('click',function(){
  var r=document.documentElement,
      next=r.getAttribute('data-theme')==='light'?'dark':'light';
  r.setAttribute('data-theme',next);
  try{localStorage.setItem('pithos-theme',next);}catch(e){}
});
function tick(){var d=new Date(),p=n=>String(n).padStart(2,'0');document.getElementById('clock').textContent=p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());}
setInterval(tick,1000);tick();

function setStatus(el,cls,text){el.className='panel-badge '+cls;el.textContent=text;}
function appendLine(text,cls){var c=document.getElementById('console');if(c.querySelector('.console-empty'))c.innerHTML='';var s=document.createElement('span');s.className=cls||'';s.textContent=text+NL;c.appendChild(s);c.scrollTop=c.scrollHeight;}
function classifyLine(line){if(/\[OK\]|All done|success/i.test(line))return 'ok';if(/ERROR|failed|exception/i.test(line))return 'err';if(/WARN|warning/i.test(line))return 'warn';if(/^\[\*\]/.test(line))return 'info';return 'dim';}

document.getElementById('clone-form').addEventListener('submit',async function(e){
  e.preventDefault();
  var consoleEl=document.getElementById('console');consoleEl.innerHTML='';
  var submitBtn=document.getElementById('submit-btn');submitBtn.disabled=true;
  setStatus(document.getElementById('form-status'),'warn','BUSY');
  setStatus(document.getElementById('console-status'),'live','STREAMING');
  var fd=new FormData(e.target),params=new URLSearchParams();
  fd.forEach((v,k)=>params.append(k,v));
  try{
    var resp=await fetch('/clone-stream',{method:'POST',body:params});
    if(!resp.ok||!resp.body)throw new Error('Stream init failed');
    var reader=resp.body.getReader(),decoder=new TextDecoder(),buffer='';
    while(true){var ch=await reader.read();if(ch.done)break;buffer+=decoder.decode(ch.value,{stream:true});var nl;while((nl=buffer.indexOf(NL))>=0){var ln=buffer.slice(0,nl);buffer=buffer.slice(nl+1);if(ln.length)appendLine(ln,classifyLine(ln));}}
    if(buffer.length)appendLine(buffer,classifyLine(buffer));
    setStatus(document.getElementById('form-status'),'live','COMPLETE');
    setStatus(document.getElementById('console-status'),'live','DONE');
  }catch(err){appendLine('[!] '+err.message,'err');setStatus(document.getElementById('form-status'),'err','FAILED');setStatus(document.getElementById('console-status'),'err','ERROR');}
  finally{submitBtn.disabled=false;}
});

async function openTransfer(vmid,name){
  xferVmid=vmid;xferName=name;xferIdentity='fresh';
  document.getElementById('xfer-src').textContent='VMID '+vmid+' ('+name+')';
  selectIdentity('fresh');
  document.getElementById('xfer-modal').classList.add('open');
  // Load destination hosts
  var sel=document.getElementById('xfer-dest');sel.innerHTML='<option value="">Loading...</option>';
  try{
    var r=await fetch('/api/prox-hosts');var data=await r.json();
    if(!data.hosts||!data.hosts.length){sel.innerHTML='<option value="">No prox-hosts found (tag your hosts tag:prox-host)</option>';return;}
    sel.innerHTML='<option value="">-- Choose destination --</option>';
    data.hosts.forEach(h=>{var o=document.createElement('option');o.value=h.fqdn;o.textContent=h.name+' ('+h.fqdn+')'+(h.online?'':' [offline]');sel.appendChild(o);});
  }catch(e){sel.innerHTML='<option value="">Error loading hosts</option>';}
}

function closeTransfer(){document.getElementById('xfer-modal').classList.remove('open');}

function selectIdentity(id){xferIdentity=id;document.getElementById('id-fresh').classList.toggle('selected',id==='fresh');document.getElementById('id-preserve').classList.toggle('selected',id==='preserve');}

async function loadDestStorage(){
  var dest=document.getElementById('xfer-dest').value;
  var sel=document.getElementById('xfer-storage');sel.innerHTML='<option value="">Loading...</option>';
  if(!dest){sel.innerHTML='<option value="">Select destination first</option>';return;}
  try{
    var r=await fetch('/api/dest-storage?dest='+encodeURIComponent(dest));var data=await r.json();
    if(!data.storages||!data.storages.length){sel.innerHTML='<option value="">No storage found</option>';return;}
    sel.innerHTML='';
    data.storages.forEach(s=>{var o=document.createElement('option');o.value=s.name;o.textContent=s.name+' ('+s.type+')';sel.appendChild(o);});
  }catch(e){sel.innerHTML='<option value="">Error</option>';}
}

async function startTransfer(){
  var dest=document.getElementById('xfer-dest').value;var storage=document.getElementById('xfer-storage').value;
  if(!dest||!storage){alert('Pick destination and storage');return;}
  closeTransfer();
  var consoleEl=document.getElementById('console');consoleEl.innerHTML='';
  setStatus(document.getElementById('console-status'),'live','STREAMING');
  appendLine('[*] Starting transfer of VMID '+xferVmid+' to '+dest,'info');
  var params=new URLSearchParams();params.append('vmid',xferVmid);params.append('dest',dest);params.append('storage',storage);params.append('identity',xferIdentity);
  try{
    var resp=await fetch('/transfer-stream',{method:'POST',body:params});
    if(!resp.ok||!resp.body)throw new Error('Stream init failed');
    var reader=resp.body.getReader(),decoder=new TextDecoder(),buffer='';
    while(true){var ch=await reader.read();if(ch.done)break;buffer+=decoder.decode(ch.value,{stream:true});var nl;while((nl=buffer.indexOf(NL))>=0){var ln=buffer.slice(0,nl);buffer=buffer.slice(nl+1);if(ln.length)appendLine(ln,classifyLine(ln));}}
    if(buffer.length)appendLine(buffer,classifyLine(buffer));
    setStatus(document.getElementById('console-status'),'live','DONE');
  }catch(err){appendLine('[!] '+err.message,'err');setStatus(document.getElementById('console-status'),'err','ERROR');}
}
</script></body></html>"""


@app.route("/")
def index():
    if not template_exists():
        try: hostname = subprocess.check_output(["hostname"], text=True).strip()
        except Exception: hostname = "proxmox"
        return render_template_string(SETUP_PAGE, hostname=hostname, template_vmid=TEMPLATE_VMID)
    return render_template_string(INDEX,
        m=host_metrics(), containers=list_containers(),
        storages=list_storage_backends(), default_storage=DEFAULT_STORAGE,
        templates=list_templates(), default_template=str(TEMPLATE_VMID),
        bridges=list_bridges(),
        mesh=mesh_status(),
        history=transfer_history())


@app.route("/api/prox-hosts")
def api_prox_hosts():
    return jsonify({"hosts": list_prox_hosts()})


@app.route("/api/dest-storage")
def api_dest_storage():
    dest = request.args.get("dest", "")
    return jsonify({"storages": get_dest_storage(dest)})


@app.route("/api/status")
def api_status():
    """Read-only host status as JSON (for the Pithos MCP / scripted clients)."""
    return jsonify({
        **host_metrics(),
        "storages": list_storage_backends(),
        "default_storage": DEFAULT_STORAGE,
        "template_ready": template_exists(),
    })


@app.route("/api/containers")
def api_containers():
    """Read-only container inventory as JSON (for the Pithos MCP / scripted clients)."""
    return jsonify({"containers": list_containers()})


@app.route("/api/disks")
def api_disks():
    """SMART health for the host's physical disks (MCP / scripted clients)."""
    return jsonify({"disks": list_disks()})


@app.route("/api/templates")
def api_templates():
    """Templates available on this host, LXC and VM (MCP / scripted clients)."""
    return jsonify({"templates": list_templates()})


@app.route("/api/bridges")
def api_bridges():
    """Network bridges on this host, flagged public or private."""
    return jsonify({"bridges": list_bridges()})


@app.route("/api/mesh")
def api_mesh():
    """This host plus every configured peer, with resources. Peers are
    contacted over the tailnet only."""
    return jsonify({"mesh": mesh_status()})


@app.route("/clone-stream", methods=["POST"])
def clone_stream():
    if not template_exists():
        return Response("[!] No template at VMID " + str(TEMPLATE_VMID) + "\n", mimetype="text/plain")
    hostname = request.form.get("hostname", "").strip()
    if not re.match(r"^[a-zA-Z0-9-]+$", hostname):
        return Response("[!] Invalid hostname.\n", mimetype="text/plain")
    vmid = request.form.get("vmid", "").strip() or str(next_free_vmid())
    try: vmid_int = int(vmid)
    except ValueError: return Response("[!] Invalid VMID.\n", mimetype="text/plain")
    cores = request.form.get("cores", "").strip()
    memory = request.form.get("memory", "").strip()
    disk = request.form.get("disk", "").strip()
    rootpw = request.form.get("rootpw", "")
    storage = request.form.get("storage", "").strip() or DEFAULT_STORAGE
    # Unchecked checkboxes are simply absent from the form post.
    onboot = "1" if request.form.get("onboot") else "0"
    template = request.form.get("template", "").strip() or str(TEMPLATE_VMID)
    # Never trust the form: the picker disables VM templates, but a crafted post
    # could still send one, and pct clone would fail in a confusing way.
    _known = {t["vmid"]: t for t in list_templates()}
    if template not in _known:
        return Response("[!] Unknown template " + template + "\n", mimetype="text/plain")
    _kind = _known[template]["kind"]

    bridge = request.form.get("bridge", "").strip()
    if bridge:
        if bridge not in {b["name"] for b in list_bridges()}:
            return Response("[!] Unknown bridge " + bridge + "\n", mimetype="text/plain")
    if not re.match(r"^[a-zA-Z0-9_\-]+$", storage):
        return Response("[!] Invalid storage.\n", mimetype="text/plain")

    def generate():
        yield "[*] Cloning " + hostname + " as VMID " + str(vmid_int) + "\n"
        try:
            _script = CLONE_SCRIPT if _kind == "lxc" else CLONE_VM_SCRIPT
            proc = subprocess.Popen([_script, str(vmid_int), hostname, "--storage", storage,
                                     "--onboot" if onboot == "1" else "--no-onboot",
                                     "--template", template]
                                    + (["--bridge", bridge] if bridge else []),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(proc.stdout.readline, ""): yield line
            proc.wait()
            if proc.returncode != 0:
                yield "[!] Clone failed (exit " + str(proc.returncode) + ")\n"; return
            if cores or memory:
                args = ["pct", "set", str(vmid_int)]
                if cores: args += ["-cores", cores]
                if memory: args += ["-memory", memory]
                yield "[*] Applying CPU/memory overrides...\n"
                r = subprocess.run(args, capture_output=True, text=True)
                if r.stdout: yield r.stdout
                if r.stderr: yield r.stderr
            if disk and int(disk) > 4:
                yield "[*] Resizing rootfs to " + disk + "G...\n"
                r = subprocess.run(["pct", "resize", str(vmid_int), "rootfs", disk + "G"], capture_output=True, text=True)
                if r.stdout: yield r.stdout
            if rootpw:
                yield "[*] Setting root password...\n"
                subprocess.run(["pct", "exec", str(vmid_int), "--", "bash", "-c", "echo 'root:" + rootpw + "' | chpasswd"],
                               capture_output=True, text=True)
            bust_inventory_cache()
            yield "\n[OK] All done.\n"
        except Exception as e:
            yield "\n[!] Exception: " + str(e) + "\n"

    return Response(stream_with_context(generate()), mimetype="text/plain")


@app.route("/transfer-stream", methods=["POST"])
def transfer_stream():
    vmid = request.form.get("vmid", "").strip()
    dest = request.form.get("dest", "").strip()
    storage = request.form.get("storage", "").strip()
    identity = request.form.get("identity", "fresh").strip()

    if not vmid.isdigit():
        return Response("[!] Invalid VMID.\n", mimetype="text/plain")
    if not re.match(r"^[a-zA-Z0-9\.\-]+$", dest):
        return Response("[!] Invalid destination.\n", mimetype="text/plain")
    if not re.match(r"^[a-zA-Z0-9_\-]+$", storage):
        return Response("[!] Invalid storage.\n", mimetype="text/plain")

    def generate():
        args = [TRANSFER_SCRIPT, vmid, dest, "--storage", storage]
        if identity == "preserve": args.append("--preserve-identity")
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(proc.stdout.readline, ""): yield line
            proc.wait()
            if proc.returncode != 0:
                yield "[!] Transfer exited with code " + str(proc.returncode) + "\n"
            else:
                bust_inventory_cache()
                yield "\n[OK] Transfer complete.\n"
        except Exception as e:
            yield "\n[!] Exception: " + str(e) + "\n"

    return Response(stream_with_context(generate()), mimetype="text/plain")



# --- Disk health (v0.2.8) -----------------------------------------------
# SMART data for the host's physical disks. smartctl is slow and the data
# moves slowly, so this gets its own long TTL on the same SWR cache.
DISK_CACHE_TTL = float(_env("DISK_CACHE_TTL", "600"))

# Vendor-specific SATA attribute IDs that carry a normalized life-left value
# (100 = new, counts down). NVMe reports percentage_used directly instead.
_WEAR_IDS = (231, 202, 177, 233, 173)
# ID alone is not enough: 233 is Media_Wearout_Indicator on Intel but
# NAND_GiB_Written on SanDisk. Require the name to look like a life gauge,
# and reject anything that is plainly a byte/block counter.
_WEAR_NAMES = ("wear_leveling", "ssd_life_left", "media_wearout",
               "percent_life", "remaining_life", "lifetime_remain",
               "percent_lifetime")
_WEAR_NOT = ("written", "gib", "lba", "read", "erase_count", "host")


def _physical_disks():
    """Real disks only - no zvols, loop, or device-mapper entries."""
    try:
        out = subprocess.check_output(
            ["lsblk", "-dn", "-o", "NAME,TYPE"], text=True, timeout=10)
    except Exception:
        return []
    names = []
    for line in out.strip().split("\n"):
        parts = line.split()
        if len(parts) == 2 and parts[1] == "disk":
            if parts[0].startswith(("zd", "loop", "dm-", "sr")):
                continue
            names.append("/dev/" + parts[0])
    return names


def _smart(dev):
    """smartctl JSON for one device. Non-zero exit is normal (bit flags), so
    parse stdout regardless and only treat unparseable output as failure."""
    try:
        p = subprocess.run(["smartctl", "--json=c", "-H", "-A", "-i", dev],
                           capture_output=True, text=True, timeout=40)
        return json.loads(p.stdout)
    except Exception:
        return None


def _disk_from_smart(dev, j):
    d = {"device": dev, "model": j.get("model_name", "?"),
         "serial": j.get("serial_number", ""), "kind": "sata",
         "capacity_gb": None, "power_on_hours": None, "used_pct": None,
         "written_tb": None, "reallocated": None, "temp_c": None,
         "spare_pct": None, "healthy": None, "wear_source": None}
    cap = (j.get("user_capacity") or {}).get("bytes")
    if cap:
        d["capacity_gb"] = round(cap / 1e9)
    st = j.get("smart_status")
    if isinstance(st, dict) and "passed" in st:
        d["healthy"] = bool(st["passed"])
    t = (j.get("temperature") or {}).get("current")
    if isinstance(t, int):
        d["temp_c"] = t
    return d


def _fill_nvme(d, j):
    log = j.get("nvme_smart_health_information_log") or {}
    if not log:
        return
    d["kind"] = "nvme"
    if "percentage_used" in log:
        d["used_pct"] = log["percentage_used"]
        d["wear_source"] = "nvme percentage_used"
    d["power_on_hours"] = log.get("power_on_hours")
    d["spare_pct"] = log.get("available_spare")
    duw = log.get("data_units_written")
    if duw:
        # 1 data unit = 1000 x 512-byte blocks
        d["written_tb"] = round(duw * 512000 / 1e12, 1)


def _fill_sata(d, j):
    tbl = ((j.get("ata_smart_attributes") or {}).get("table")) or []
    if not tbl:
        return
    by_id = {a.get("id"): a for a in tbl}
    a9 = by_id.get(9)
    if a9:
        d["power_on_hours"] = (a9.get("raw") or {}).get("value")
    a5 = by_id.get(5)
    if a5:
        d["reallocated"] = (a5.get("raw") or {}).get("value")
    for wid in _WEAR_IDS:
        a = by_id.get(wid)
        if not a or not isinstance(a.get("value"), int):
            continue
        nm = (a.get("name") or "").lower()
        if not any(w in nm for w in _WEAR_NAMES):
            continue
        if any(w in nm for w in _WEAR_NOT):
            continue
        d["used_pct"] = max(0, 100 - a["value"])
        d["wear_source"] = "attr %d %s" % (wid, a.get("name", ""))
        break


def _sata_written_tb(d, j):
    """Lifetime writes: attr 241 is LBAs on most drives, GiB on some SanDisk."""
    tbl = ((j.get("ata_smart_attributes") or {}).get("table")) or []
    for a in tbl:
        if a.get("id") != 241:
            continue
        raw = (a.get("raw") or {}).get("value")
        if not raw:
            return
        name = (a.get("name") or "").lower()
        if "gib" in name:
            d["written_tb"] = round(raw * 1.073741824 / 1000, 1)
        else:
            d["written_tb"] = round(raw * 512 / 1e12, 1)
        return


def _gather_disk(dev):
    j = _smart(dev)
    if not j:
        return {"device": dev, "model": "?", "error": "smartctl unavailable"}
    d = _disk_from_smart(dev, j)
    _fill_nvme(d, j)
    if d["kind"] != "nvme":
        _fill_sata(d, j)
        _sata_written_tb(d, j)
    # Vendor-neutral wear signal: full-capacity writes. Meaningful even when
    # the drive exposes no life-left attribute (compare against its rated TBW).
    if d.get("written_tb") and d.get("capacity_gb"):
        d["drive_writes"] = round(d["written_tb"] * 1000 / d["capacity_gb"], 1)
    else:
        d["drive_writes"] = None
    return d


def _disks_uncached():
    devs = _physical_disks()
    if not devs:
        return []
    with ThreadPoolExecutor(max_workers=min(8, len(devs))) as ex:
        return list(ex.map(_gather_disk, devs))


def list_disks():
    return _swr("disks", _disks_uncached, ttl=DISK_CACHE_TTL)

if __name__ == "__main__":
    if _load_auth() is None:
        app.logger.warning(
            "pithos: no auth file at %s - web UI is UNAUTHENTICATED "
            "(create it to require HTTP Basic Auth on all routes)",
            AUTH_FILE,
        )
    # Warm the inventory caches so the first request is already fast.
    threading.Thread(target=lambda: (host_metrics(), list_containers(), template_exists(), list_storage_backends()), daemon=True).start()
    app.run(host=_env("BIND", "0.0.0.0"),
            port=int(os.environ.get("PORT", 8080)), threaded=True)

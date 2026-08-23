# Pithos MCP

A local **stdio** MCP server that lets Claude Code provision Tailscale-joined
LXCs on proxlab through Pithos — no copy-pasting `pithos-new` commands.

It's a thin HTTP client over the Pithos Flask app. It does **not** run `pct`
or SSH anything itself; every action goes through the same tested endpoints the
web UI uses. Nothing new is exposed to the internet — the MCP runs on your Mac
and talks to the web app over the tailnet/LAN at whatever
`PITHOS_URL` points to (e.g. `http://192.0.2.9:8080` — placeholder).

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `pithos_host_status` | read | Counts, tailnet peers, next free VMID, storage backends, template readiness |
| `pithos_list_containers` | read | Inventory of LXCs on proxlab |
| `pithos_provision` | write | Clone the golden template + join tailnet. **`dry_run=True` by default** |

No destroy tool by design.

## Prerequisite: deploy the read-only API routes

This MCP needs two JSON routes added to `webui/app.py` in this repo
(`/api/status`, `/api/containers`). Deploy the updated app to proxlab and
restart the service:

```bash
scp webui/app.py root@192.0.2.9:/opt/pithos/app.py
ssh root@192.0.2.9 systemctl restart pithos
# verify:
curl -s http://192.0.2.9:8080/api/status | head
```

## Install

```bash
cd /path/to/projects/pithos/mcp
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Register with Claude Code

```bash
claude mcp add pithos -- \
  /path/to/projects/pithos/mcp/.venv/bin/python \
  /path/to/projects/pithos/mcp/pithos_mcp.py
```

If your Mac isn't on the same LAN as proxlab, point it at the tailnet address:

```bash
claude mcp add pithos \
  --env PITHOS_URL=http://100.x.y.z:8080 -- \
  /path/to/projects/pithos/mcp/.venv/bin/python \
  /path/to/projects/pithos/mcp/pithos_mcp.py
```

Then in Claude Code: `/mcp` to confirm `pithos` is connected.

## Usage (from Claude Code)

- "What's the pithos host status?" → `pithos_host_status`
- "List the LXCs on proxlab." → `pithos_list_containers`
- "Spin up an LXC called `lab-redis` with 2 cores and 1GB." → `pithos_provision`
  runs a **dry run** first and shows the plan (VMID, storage, sizing).
- "Looks good, create it." → same call with `dry_run=false`.

## Config

| Env | Default | Notes |
|---|---|---|
| `PITHOS_URL` | _(required)_ | LAN IP of the web app, e.g. `http://192.0.2.9:8080` (placeholder); use tailnet IP/MagicDNS if remote |
| `PITHOS_TIMEOUT` | `600` | Provision timeout (s). Clone + network wait can take a few minutes |

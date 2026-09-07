# Pithos — handoff

Everything you need to run Pithos on your own Proxmox host, in the order you
will need it.

## What it is

A small web UI that runs **on** your Proxmox host. You pick a template, type a
hostname, click a button, and a few seconds later there is a container — or a
few minutes later, a Windows VM — already on your Tailscale tailnet.

It clones templates. It does not replace the Proxmox UI, and it does not manage
anything it did not create.

## Install

As root, on the Proxmox host:

```bash
curl -fsSL https://raw.githubusercontent.com/SuperAngryMonkey/pithos/main/bootstrap.sh | bash
```

It checks the host is really Proxmox, installs what is missing, fetches the
code, and finishes by printing the URL and a generated admin password. The
password is also written to `/root/.pithos/initial-password` because installer
output scrolls.

Re-running it updates in place and leaves your credential alone.

## Then, in order

**1. Tailscale credentials** — only if you want guests joining a tailnet
automatically. Skip it and everything else still works; guests simply are not
joined.

Create an OAuth client with the `devices:write` scope, then:

```bash
mkdir -p /root/.tailscale && chmod 700 /root/.tailscale
nano /root/.tailscale/oauth
#   TS_OAUTH_CLIENT_ID=...
#   TS_OAUTH_CLIENT_SECRET=...
chmod 600 /root/.tailscale/oauth
```

Your ACL must list the tag Pithos asks for — `tag:lxc` unless you change it —
under `tagOwners`. If it does not, key creation fails with *"requested tags are
invalid or not permitted"*. That reads like a Pithos bug and is not one. It is
the most common first failure.

**2. A template.** Pithos clones; it does not install from scratch.

```bash
pithos-build-template                                    # Debian LXC, ~4 min
pithos-build-windows --variant 2019 --iso local:iso/<yours>
pithos-build-windows --seal <vmid>                       # when the build finishes
```

Windows needs your own ISO and the virtio-win ISO in the same storage. Seal
**promptly** after the build — a Windows 11 template left running for hours
picks up a background Windows Update that blocks sysprep.

**3. Provision.** Open the web UI, pick template, network and storage, give it a
hostname, go.

## Things worth knowing before you hit something

- **Bridges marked PUBLIC** carry a routable address. A guest placed there is on
  the internet. Choose a private bridge unless you mean it.
- **New guests start with the host.** Anything showing **NO BOOT** will not.
- **Windows templates hold no Tailscale identity.** Tailscale is installed but
  never authenticated, so a clone joins nothing unless Pithos gives it a key or
  you run `tailscale up` yourself.
- **Windows VMs restart once** at the end of provisioning, to apply the
  hostname. That is expected, not a failure.
- **Templates are not distributed.** You build them from your own media; the
  licensing is yours.

## When something goes wrong

```bash
systemctl status pithos          # is it running
journalctl -u pithos -f          # what it is doing
```

Inside a Windows build: `C:\pithos-build.log`.
Lost the password: `/root/.pithos/initial-password`, unless you deleted it.

## More

- `docs/windows-templates.md` — the Windows pipeline, and why each step is
  there. Every item on that list was a failure before it was a fix.
- `docs/other-tailnets.md` — running against a different tailnet.
- The **HELP** tab in the UI covers the same ground while you are looking at it.

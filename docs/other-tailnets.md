# Running Pithos against a different tailnet

Nothing in a Pithos template is tied to a particular tailnet. Tailscale is
installed but deliberately left **unauthenticated**, so the same template works
for anyone — what differs is the credential used to join, and that lives on the
Proxmox host, not in the image.

This matters when handing templates to someone with their own tailnet.

## The short version

| | Yours | Theirs |
|---|---|---|
| Template | unchanged | unchanged |
| OAuth credential | `/root/.tailscale/oauth` on your host | theirs, on their host |
| Tag | `tag:lxc` | whatever their ACL defines |

## Path A — no Pithos, join by hand

If they are only cloning the template in the Proxmox UI:

1. Clone the template and start it.
2. Log in as the template's local admin.
3. Join their tailnet:

   ```
   "C:\Program Files\Tailscale\tailscale.exe" up --unattended
   ```

   That prints a URL to authorize in a browser against **their** account. Or,
   with an auth key from their admin console:

   ```
   "C:\Program Files\Tailscale\tailscale.exe" up --authkey=tskey-auth-... --unattended
   ```

`--unattended` matters: without it Tailscale only runs while a user is logged
in, so a headless VM drops off the tailnet at sign-out.

## Path B — Pithos provisions into their tailnet

Pithos mints a fresh single-use key per clone from an OAuth client. To point it
at a different tailnet, replace the credential on their Proxmox host.

### 1. Create an OAuth client in their tailnet

Admin console → Settings → OAuth clients → Generate. It needs the
**`devices:write`** scope (Pithos calls `POST /api/v2/tailnet/-/keys`), and the
client must be allowed to use the tag the keys are issued for.

### 2. Allow the client to own that tag

In their ACL:

```json
"tagOwners": {
  "tag:lxc": ["autogroup:admin"]
}
```

The tag Pithos requests must exist here, or key creation fails with
*"requested tags ... are invalid or not permitted"*. This is the single most
common failure, and it is an ACL problem rather than a Pithos one.

### 3. Write the credential on their host

```
mkdir -p /root/.tailscale
cat > /root/.tailscale/oauth <<'EOF'
TS_OAUTH_CLIENT_ID=<their client id>
TS_OAUTH_CLIENT_SECRET=<their client secret>
EOF
chmod 600 /root/.tailscale/oauth
```

Same path and format as here. Both provisioners read it, and `OAUTH_FILE`
overrides the location if needed.

### 4. Set the tag if it differs

`tag:lxc` is the default. If their ACL uses something else, set it per host:

```
# /etc/systemd/system/pithos.service.d/tailnet.conf
[Service]
Environment=TAG=tag:whatever
```

Note that `[Service]` header — a drop-in without it is silently ignored.

### 5. Check it

Provision one guest and confirm it appears in **their** admin console. If key
minting fails, the cause is almost always the tag not being listed in
`tagOwners` for that client.

## Things worth knowing

- Keys minted per clone are single-use, short-lived and pre-authorized. Without
  pre-authorization a device joins but sits unapproved until an admin acts.
- Keys never enter the template. They arrive per clone, via `pct exec` for
  containers or a cloud-init drive for VMs.
- The mesh is separate. `PITHOS_PEERS` requires peers on the *same* tailnet as
  the host, since addresses must resolve into `100.64.0.0/10`. Two people's
  tailnets do not mesh together — each runs its own.
- An OAuth client scoped only to a container tag cannot bring a *host* onto the
  tailnet; joining a new Proxmox node is still an interactive login.

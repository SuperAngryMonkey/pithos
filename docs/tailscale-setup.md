# Tailscale Setup Walkthrough

This is the long-form version of the Tailscale prerequisites in the [main README](../README.md). If you've never set up Tailscale tags or OAuth clients before, follow this end-to-end.

Estimated time: 10 minutes.

---

## Step 1 — Sign up for Tailscale

Free tier: https://login.tailscale.com/start

Sign in with Google, Microsoft, GitHub, or Apple. The first device to log in becomes the start of your tailnet.

You need **admin** access. If you're the only user, you're automatically admin.

---

## Step 2 — Create the `tag:lxc` tag

Tags in Tailscale are identifiers you can apply to non-user devices (servers, containers, IoT). They're declared in your tailnet's policy file under `tagOwners`.

### Via GUI

1. Go to **[Access controls → Tags](https://login.tailscale.com/admin/acls/tags)**
2. Click **+ Create tag**
3. Fill in:
   - **Name**: `lxc` (Tailscale prepends `tag:` automatically — type just `lxc`)
   - **Owners**: `autogroup:admin`
4. Click **Save**

### Via JSON editor

If you prefer editing the policy directly: **Access controls → JSON editor**, find or add:

```hujson
"tagOwners": {
  "tag:lxc": ["autogroup:admin"],
},
```

Save the policy. The tag is now available for OAuth clients and devices to claim.

---

## Step 3 — Create an ACL grant for `tag:lxc`

If your tailnet has the default open ACL (everything talks to everything), skip this step — it's already covered.

If you've tightened your ACLs, you need to allow your devices to reach `tag:lxc` containers:

```hujson
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["tag:lxc"],
    "ip":  ["*"],
  },
],
```

Add to your policy file. This says: "any user in this tailnet can connect to any tag:lxc device on any port."

---

## Step 4 — (Recommended) Create a Tailscale SSH grant

Pithos enables Tailscale SSH on every cloned container. To actually use it (`tailscale ssh root@hostname`), add an SSH grant:

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

Without this, you'll see a warning when running `tailscale status` inside containers:

> Tailscale SSH enabled, but access controls don't allow anyone to access this device. Ask your admin to update your tailnet's ACLs to allow access.

The container is on the tailnet either way — only `tailscale ssh` is gated by this rule.

---

## Step 5 — Create the OAuth client

This is the one piece that lets Pithos mint fresh auth keys without storing a long-lived secret on the Proxmox host.

### Where to find it

In the admin console:

1. Go to **Settings** (top right, gear icon)
2. In the left sidebar, find **Tailnet Settings** section
3. Click **Trust credentials**
4. Click the **+ Generate credential** button (top right)

### Step 1 of the dialog: Settings

- **Description**: `Pithos provisioner` (or anything that helps future-you remember what this is)
- **Tags**: `tag:lxc` — this is the safety boundary. The credential can only mint keys for `tag:lxc` devices, nothing else. **Do not skip this.**

Click **Continue**.

### Step 2 of the dialog: Scopes

You're presented with a long list of permission categories. Almost all should stay unchecked.

**Check ONLY this:**

Under the **Keys** section:
- ☑ **Auth Keys: Write**

Leave everything else unchecked. Specifically, you do NOT need:
- Auth Keys: Read
- API Access Tokens
- OAuth Keys
- DNS, Policy File, Users, Services, Devices, etc.

Click **Generate credential**.

### Step 3 — Copy the secret immediately

You'll see a dialog showing:

- **Client ID**: short string starting with `k...`
- **Client secret**: long string starting with `tskey-client-...`

**Copy both NOW.** The secret is shown exactly once. If you close this dialog without copying, you have to revoke and regenerate.

Paste them somewhere safe temporarily — you'll put them on the Proxmox host in the next section.

---

## Step 6 — Save credentials on the Proxmox host

SSH or web-shell into the Proxmox host as root, then:

```bash
mkdir -p /root/.tailscale
chmod 700 /root/.tailscale
cat > /root/.tailscale/oauth <<'EOF'
TS_OAUTH_CLIENT_ID=PASTE_YOUR_CLIENT_ID_HERE
TS_OAUTH_CLIENT_SECRET=PASTE_YOUR_CLIENT_SECRET_HERE
EOF
chmod 600 /root/.tailscale/oauth
```

Replace the placeholders with the values you copied from the dialog.

Verify:

```bash
ls -la /root/.tailscale/oauth
# Should show: -rw------- 1 root root <size> <date> /root/.tailscale/oauth

cat /root/.tailscale/oauth
# Should show your two values
```

---

## You're done

Tailscale is now configured to accept Pithos's automated container provisioning. You can now proceed with the Pithos install (back to the [main README](../README.md), Step 2 onward).

---

## Operational notes

**OAuth credentials never expire.** Unlike auth keys (which are 90-day max), OAuth client credentials are durable. You only need to rotate them if you suspect they've leaked or you want to revoke access.

**Each minted auth key is single-use, 10-minute TTL, and tagged.** Pithos mints a fresh key for every container clone. The key is wiped from the container after `tailscale up` succeeds. No long-lived auth material lives on your containers.

**Least privilege.** The OAuth client only has `Auth Keys: Write` scope and is restricted to `tag:lxc`. If the secret leaks, the worst an attacker can do is spin up tag:lxc devices on your tailnet. Your tailnet ACLs constrain what those devices can reach.

**Rotation.** If you ever need to rotate: generate a new OAuth client, update `/root/.tailscale/oauth` on the Proxmox host, then revoke the old client in the admin console. No code changes, no service restarts.

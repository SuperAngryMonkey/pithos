# Where images go, and how to get them

Proxmox keeps **two different kinds** of image in two different places, and
mixing them up is the usual first stumble.

| | Used for | Lives in | Referred to as |
|---|---|---|---|
| **Container template** | LXC (Debian) | `/var/lib/vz/template/cache/` | `local:vztmpl/...` |
| **ISO image** | VMs (Windows) | `/var/lib/vz/template/iso/` | `local:iso/...` |

A Windows ISO in the container-template folder will not appear anywhere useful,
and vice versa.

## Debian containers — nothing to download

`pithos-build-template` fetches the image itself. It runs `pveam update`, picks
the newest `debian-12-standard`, downloads it if it is not already there, and
builds the template.

```bash
pithos-build-template
```

That is the whole procedure. About four minutes.

To look at what is available or already downloaded:

```bash
pveam update
pveam available --section system | grep debian
pveam list local
```

## Windows — you supply the ISO

Two files are needed, both in the **ISO** storage.

### 1. virtio-win (required)

Windows cannot see a VirtIO disk without it, and Setup will stop with no drives
listed. It is free and redistributable:

```bash
cd /var/lib/vz/template/iso
wget https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso \
     -O virtio-win.iso
```

### 2. A Windows ISO (yours)

Licensing is yours. Sources:

- **Server 2019 / 2022 / 2025 evaluation** — free 180-day, from the Microsoft
  Evaluation Center. Fine for building and testing.
- **Windows 11** — free download from Microsoft's Windows 11 download page.
- **Volume licence media** — from your own VLSC/Admin Center account if you have
  one. Do not use someone else's copy; VL media is licensed to an organisation.

Getting it onto the host, any of:

**Proxmox web UI** — Datacenter → your node → `local` → ISO Images → Upload.
Simplest if the file is already on your workstation.

**Download straight to the host**, which avoids a round trip through your
machine:

```bash
cd /var/lib/vz/template/iso
wget -O win2019.iso 'https://...'
```

The UI also has *Download from URL* on the same screen, which does the same
thing with a progress bar.

**From another machine over SSH:**

```bash
scp Windows.iso root@your-proxmox:/var/lib/vz/template/iso/
```

### Check they registered

```bash
pvesm list local --content iso
```

Anything listed there can be passed to the builder:

```bash
pithos-build-windows --variant 2019 --iso local:iso/win2019.iso
```

## If you use a different storage

The paths above assume the default `local` storage. If your ISOs live elsewhere,
the volume id changes accordingly (`mystorage:iso/win2019.iso`), and the storage
must have **ISO image** enabled in its content types — Datacenter → Storage →
select → Content.

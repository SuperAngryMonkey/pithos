# Building a Windows template

Pithos does not ship Windows images. They are 10GB+ and they contain licensed
Microsoft software, so what ships is the recipe: answer files that make Windows
install itself, and a script that drives the process.

You supply the ISO. Licensing stays yours.

## What you need

- A Proxmox host with `genisoimage` (`apt install genisoimage`)
- A Windows ISO in your ISO storage — Server 2019, Server 2025, or Windows 11
- The **virtio-win** ISO, from
  <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>,
  in the same storage. Without it Windows cannot see a VirtIO disk and Setup
  stops with no drives listed.

## Build

```bash
pithos-build-windows --variant 2019 \
  --iso local:iso/SW_DVD9_Win_Server_STD_CORE_2019_1809.ISO
```

Then walk away. Windows partitions the disk, installs, skips OOBE entirely,
creates a local admin, logs in, and installs the QEMU guest agent, Tailscale
(unauthenticated) and Cloudbase-Init. Typically 20-40 minutes; slower on
spinning disks.

The generated admin password is printed once at the start. Save it.

## Seal

Once the guest agent responds:

```bash
pithos-build-windows --seal 9001
```

That strips Store apps, clears Tailscale state, and runs sysprep. The VM powers
itself off on success. Then:

```bash
qm set 9001 --delete ide0 --delete ide1 --delete ide2
qm set 9001 --ide2 local-lvm:cloudinit --boot order=scsi0
qm template 9001
```

It now appears in the Pithos clone form.

## Why each step exists

Every one of these was a failure before it was a fix:

- **The keypress.** Windows UEFI media waits for a key at *"Press any key to
  boot from CD"*. Miss it and the VM falls through to the empty disk and reports
  no bootable device. The script sends the key for you.
- **Driver injection.** `autounattend.xml` side-loads `vioscsi` during setup, so
  the disk is visible without anyone clicking *Load driver*.
- **`International-Core-WinPE`.** Without this component Setup still shows the
  language page even with a valid answer file.
- **Exact edition names.** Server media uses internal names like
  `Windows Server 2019 SERVERSTANDARD`, not the friendly ones. Read yours with
  `wiminfo /path/sources/install.wim` if you adapt this.
- **No product key on evaluation or VL media.** Supplying one makes Setup fail.
- **Store app removal before sysprep.** A package provisioned but not installed
  (or the reverse) produces *"Sysprep was not able to validate your Windows
  installation"*. Windows Update causes this by refreshing Store apps mid-build.
- **`SkipRearm`.** Each `sysprep /generalize` consumes an activation rearm, and
  after about three you get `0xc004d307` and cannot seal at all.
- **Tailscale state cleared.** Otherwise every clone inherits one node identity
  and they fight over it.
- **`TS_UNATTENDEDMODE=always`.** Without it Tailscale only runs while a user is
  logged in, so a headless clone silently leaves the tailnet.

## Tailscale

Installed but **not authenticated**. The template holds no identity and joins
nothing on its own. Clones provisioned through Pithos get a fresh single-use key
each; clones made by hand join only if someone runs `tailscale up`.

If you do not want it at all:
`Get-Service Tailscale | Set-Service -StartupType Disabled`.

## Adapting to another Windows version

Copy a directory under `templates/windows/`, then change two things in
`autounattend.xml`: the driver paths (`vioscsi\2k19\amd64` →  your version's
folder, as named on the virtio-win ISO) and the edition name. That is genuinely
all that differed between 2019, 2025 and Windows 11.

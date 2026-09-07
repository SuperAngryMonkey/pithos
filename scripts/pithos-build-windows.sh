#!/bin/bash
# pithos-build-windows - build a Windows golden template from an ISO.
#
# You supply the Windows ISO (licensing is yours); this does the rest:
# creates the VM with VirtIO + UEFI, builds the answer-file CD, boots it, and
# lets Windows install itself unattended. Seal it afterwards with --seal.
set -euo pipefail

VARIANT=""; ISO=""; VMID=""; STORAGE=""; BRIDGE=""; SEAL=""
VIRTIO="${VIRTIO:-}"
ASSETS="${ASSETS:-/usr/local/share/pithos/windows}"
MEMORY="${MEMORY:-8192}"; CORES="${CORES:-4}"; DISK="${DISK:-80}"

usage() {
    cat >&2 <<USAGE
Usage:
  pithos-build-windows --variant <2019|2025|win11> --iso <path-or-volid> [options]
  pithos-build-windows --seal <vmid>

Options:
  --vmid <n>        VMID for the template (default: next free from 9001)
  --storage <name>  storage for the disk (default: host default)
  --bridge <name>   network bridge (default: vmbr0)
  --virtio <volid>  virtio-win ISO (default: newest virtio-win* in local:iso)
  --seal <vmid>     strip Store apps, sysprep and shut down, ready to template

Variants differ only in driver path and edition name; everything else is shared.
Windows media and licensing are yours to supply.
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant) VARIANT="$2"; shift 2 ;;
        --iso)     ISO="$2"; shift 2 ;;
        --vmid)    VMID="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --bridge)  BRIDGE="$2"; shift 2 ;;
        --virtio)  VIRTIO="$2"; shift 2 ;;
        --seal)    SEAL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ---- seal mode ----------------------------------------------------------
if [[ -n "$SEAL" ]]; then
    qm config "$SEAL" >/dev/null 2>&1 || { echo "ERROR: VM $SEAL not found" >&2; exit 1; }
    qm agent "$SEAL" ping >/dev/null 2>&1 || {
        echo "ERROR: no guest agent on $SEAL - is the build finished?" >&2; exit 1; }

    echo "[*] Stripping Store apps (mismatched packages are what break sysprep)..."
    qm guest exec "$SEAL" --timeout 900 -- powershell -NoProfile -ExecutionPolicy Bypass \
        -Command "\$s=(Get-Volume | Where-Object {\$_.DriveType -eq 'CD-ROM' -and \$_.DriveLetter} | ForEach-Object { \$_.DriveLetter + ':\strip-appx.ps1' } | Where-Object {Test-Path \$_} | Select-Object -First 1); if(\$s){& \$s | Out-Null}" >/dev/null 2>&1 || true

    echo "[*] Clearing Tailscale state so clones cannot share an identity..."
    qm guest exec "$SEAL" --timeout 60 -- cmd /c \
        "net stop Tailscale & rd /s /q C:\ProgramData\Tailscale & powercfg /h off" >/dev/null 2>&1 || true

    echo "[*] Sysprep (with SkipRearm, so rebuilding does not exhaust activation rearms)..."
    qm guest exec "$SEAL" --timeout 30 -- cmd /c \
        "copy /y F:\sysprep-unattend.xml C:\sysprep-unattend.xml & start /b C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /mode:vm /unattend:C:\sysprep-unattend.xml" >/dev/null 2>&1 || true

    echo "[*] Waiting for shutdown (sysprep powers off only on success)..."
    for i in $(seq 1 40); do
        [[ "$(qm status "$SEAL" | awk '{print $2}')" == "stopped" ]] && {
            echo
            echo "[OK] Sealed. Now:"
            echo "     qm set $SEAL --delete ide0 --delete ide1 --delete ide2"
            echo "     qm set $SEAL --ide2 <storage>:cloudinit --boot order=scsi0"
            echo "     qm template $SEAL"
            exit 0; }
        sleep 15
    done
    echo "[!] Still running after 10 minutes. Check the console:" >&2
    echo "    C:\\Windows\\System32\\Sysprep\\Panther\\setuperr.log" >&2
    exit 1
fi

# ---- build mode ---------------------------------------------------------
[[ -n "$VARIANT" && -n "$ISO" ]] || usage
case "$VARIANT" in 2019|2025|win11) ;; *) echo "ERROR: variant must be 2019, 2025 or win11" >&2; exit 1 ;; esac

SRC="${ASSETS}/${VARIANT}"
[[ -d "$SRC" ]] || { echo "ERROR: assets not found at $SRC" >&2; exit 1; }
command -v genisoimage >/dev/null || { echo "ERROR: genisoimage missing (apt install genisoimage)" >&2; exit 1; }

# VMID: 9001+ keeps templates clear of guest numbering.
if [[ -z "$VMID" ]]; then
    VMID=9001
    while qm config "$VMID" >/dev/null 2>&1 || pct config "$VMID" >/dev/null 2>&1; do VMID=$((VMID+1)); done
fi
qm config "$VMID" >/dev/null 2>&1 && { echo "ERROR: VMID $VMID already exists" >&2; exit 1; }

# virtio-win: newest one in the ISO store unless told otherwise.
if [[ -z "$VIRTIO" ]]; then
    VIRTIO=$(pvesm list local --content iso 2>/dev/null | awk '/virtio-win/{print $1}' | sort -V | tail -1)
fi
[[ -n "$VIRTIO" ]] || { echo "ERROR: no virtio-win ISO found. Download it from" >&2
    echo "  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" >&2
    echo "  into your ISO storage, or pass --virtio <volid>." >&2; exit 1; }

# Admin password for the built template. Generated, never shipped in the repo.
ADMIN_PASS="${ADMIN_PASS:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 16)Aa1!}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$SRC"/* "$WORK"/
sed -i "s|__PITHOS_ADMIN_PASSWORD__|${ADMIN_PASS}|g" "$WORK/autounattend.xml"
grep -q "__PITHOS_ADMIN_PASSWORD__" "$WORK/autounattend.xml" && {
    echo "ERROR: password placeholder was not substituted" >&2; exit 1; }

CFG_ISO="pithos-${VARIANT}-cfg-${VMID}.iso"
genisoimage -quiet -o "/var/lib/vz/template/iso/${CFG_ISO}" -V PITHOSCFG -J -r \
    -input-charset utf-8 "$WORK"/autounattend.xml "$WORK"/build.cmd \
    "$WORK"/strip-appx.ps1 "$WORK"/sysprep.cmd "$WORK"/sysprep-unattend.xml \
    "$WORK"/cloudbase-init.conf
echo "[*] Answer-file CD: local:iso/${CFG_ISO}"

# ---- create the VM ------------------------------------------------------
# q35 + OVMF + virtio-scsi-single + virtio net + guest agent. Ballooning off:
# it interacts badly with Windows in a template.
CREATE=(qm create "$VMID" --name "win${VARIANT}-tmpl" --machine q35 --bios ovmf
        --cpu x86-64-v2-AES --sockets 1 --cores "$CORES" --memory "$MEMORY" --balloon 0
        --scsihw virtio-scsi-single --agent enabled=1 --onboot 0
        --boot "order=ide2;scsi0")

# Proxmox has no win2019/2022/2025 ostype; win10 covers 2019, win11 the rest.
[[ "$VARIANT" == "2019" ]] && CREATE+=(--ostype win10) || CREATE+=(--ostype win11)

[[ -n "$STORAGE" ]] && ST="$STORAGE" || ST=$(pvesm status -content images 2>/dev/null | awk 'NR==2{print $1}')
[[ -n "$ST" ]] || { echo "ERROR: no image storage found; pass --storage" >&2; exit 1; }
CREATE+=(--scsi0 "${ST}:${DISK},discard=on,ssd=1,iothread=1"
         --efidisk0 "${ST}:1,efitype=4m,pre-enrolled-keys=1"
         --net0 "virtio,bridge=${BRIDGE:-vmbr0}"
         --ide2 "${ISO},media=cdrom"
         --ide0 "${VIRTIO},media=cdrom"
         --ide1 "local:iso/${CFG_ISO},media=cdrom")

# Windows 11 refuses to install without a TPM.
[[ "$VARIANT" == "win11" ]] && CREATE+=(--tpmstate0 "${ST}:1,version=v2.0")

"${CREATE[@]}" >/dev/null
echo "[*] Created VM $VMID (win${VARIANT}-tmpl) on $ST"

# Windows UEFI media waits for a keypress at "Press any key to boot from CD".
# Without one it falls through to the empty disk and finds nothing bootable.
qm start "$VMID"
for i in 1 2 3; do sleep 4; qm sendkey "$VMID" ret 2>/dev/null || true; done

cat <<DONE

[*] Installing. Nothing else to do - Windows partitions, installs, skips OOBE,
    logs in and runs the build script by itself. Roughly 20-40 minutes
    depending on disk speed.

    Watch:   Proxmox UI -> $VMID -> Console
    Log:     C:\\pithos-build.log inside the VM

    Admin:   pithos / $ADMIN_PASS
             ^ generated for this build. Save it now.

    When the guest agent responds, seal it:
        pithos-build-windows --seal $VMID
DONE

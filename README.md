# Proxmox VE Anti Detection (DKMS-like Auto-Patching)

[中文版](README_CN.md)

A DKMS-like mechanism for automatically patching `pve-qemu-kvm` with anti-detection modifications.
Every time `pve-qemu-kvm` is installed or upgraded via apt, the patch is automatically applied — similar to how DKMS rebuilds kernel modules on kernel updates.

## What It Does

The patch modifies QEMU at **source level** to remove or disguise common VM fingerprints:

| Category | Original | Patched |
|----------|----------|---------|
| Device strings | `QEMU *` | `ASUS *` |
| ACPI OEM ID | `BOCHS` | `INTEL` |
| ACPI Creator ID | `BXPC` | `PTL` |
| SMBIOS defaults | `QEMU`, `Standard PC` | `ASUS`, `M4A88TD-M` |
| SMBIOS VM flag | `0x14` (VM) | `0x08` (Desktop) |
| HDA audio vendor | `0x1af4` (Red Hat) | `0x8086` (Intel) |
| EDID vendor | `RHT` (Red Hat) | `LEN` (Lenovo) |
| vmgenid | Enabled | Disabled |
| ACPI debug AML | Enabled | Disabled |
| fw_cfg ACPI DSDT | Present | Removed |
| USB strings | `QEMU` | `ASUS` |
| RNDIS vendor | `0x1234` | `0x8086` |
| SMBIOS chassis type | `0x01` (Other, hardcoded) | configurable, defaults to `0x03` (Desktop) |

## Quick Start

### Build and install the .deb package (on PVE host)

```bash
apt install git build-essential devscripts debhelper
git clone https://github.com/HikaruChang/proxmox-ve-anti-detection-dkms.git
cd proxmox-ve-anti-detection-dkms
dpkg-buildpackage -us -uc -b
dpkg -i ../pve-qemu-anti-detection_*_all.deb
```

### Initial patched build

```bash
pve-qemu-anti-detection install
```

> **China mainland users:** The default Proxmox git server (`git.proxmox.com`) is extremely slow from China.
> Use `--cn` to switch to GitHub mirrors:
> ```bash
> pve-qemu-anti-detection --cn install
> ```
> Or set it permanently in `/etc/pve-qemu-anti-detection.conf`:
> ```bash
> USE_CN_MIRROR=1
> ```

This will:
1. Clone the `pve-qemu` source matching your installed version
2. Apply the anti-detection patch
3. Build the patched `pve-qemu-kvm` .deb (~30-60 minutes)
4. Install the patched package
5. Hold `pve-qemu-kvm` to prevent apt from overwriting it

### Automatic rebuild on upgrade

When `pve-qemu-kvm` is updated by apt (e.g., if you remove the hold), the APT hook will
automatically detect the change and start a background rebuild via systemd.

### Commands

| Command | Description |
|---------|-------------|
| `pve-qemu-anti-detection install [version]` | Initial setup: fetch, patch, build, install |
| `pve-qemu-anti-detection rebuild` | Rebuild current version with latest patches |
| `pve-qemu-anti-detection upgrade` | Check for updates, upgrade, and re-patch |
| `pve-qemu-anti-detection status` | Show current patching status |
| `pve-qemu-anti-detection hold` | Hold pve-qemu-kvm (prevent apt overwrite) |
| `pve-qemu-anti-detection unhold` | Remove hold |
| `pve-qemu-anti-detection log` | View build log |

**Global flags** (place before the command):

| Flag | Description |
|------|-------------|
| `--cn` / `--china` | Use GitHub mirrors for faster downloads from China mainland |

## VM Configuration

The patch works at source level, so **most anti-detection is automatic** without any VM args.
However, Windows VMs need extra configuration for optimal performance.

### Linux VMs

No special `args` needed. Just set realistic SMBIOS info.

> ⚠️ **Do NOT add `kvm=off` or `hypervisor=off`** — this disables KVM paravirtualization and causes **5–30% performance loss**.

Example (`/etc/pve/qemu-server/<vmid>.conf`):
```
cpu: host
smbios1: uuid=...,manufacturer=SFAgSW5jLg==,product=UHJvTGlhbnQgREwzODAgR2VuMTA=,version=VTMw,serial=...,sku=...,family=...,base64=1
```

### Windows VMs

Windows VMs need `kvm=off` to hide the KVM CPUID leaf, combined with **Hyper-V enlightenments** to fully compensate for the lost KVM paravirtualization:

```
args: -cpu host,kvm=off,+kvm_pv_unhalt,+kvm_pv_eoi,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,hv_vendor_id=intel
cpu: host
smbios1: uuid=...,manufacturer=SFAgSW5jLg==,product=UHJvTGlhbnQgREwzODAgR2VuMTA=,version=VTMw,serial=...,sku=...,family=...,base64=1
```

Key points:
- **`kvm=off`** — Hides the entire KVM CPUID leaf (`KVMKVMKVM` signature + feature bits). Anti-cheat software cannot see KVM.
- **`hv_*` enlightenments** — Provide equivalent paravirt performance to replace hidden KVM features. `hv_time` replaces kvm-clock, `hv_vapic` replaces PV EOI, etc. **Net performance impact: ~0%.**
- **`hv_vendor_id=intel`** — Changes Hyper-V CPUID vendor string from `Microsoft Hv` to `intel`. Anti-cheat sees Hyper-V (common on physical Windows machines with VBS/HVCI/WSL2) but not `Microsoft Hv`.
- **Do NOT use `hypervisor=off`** — This clears the CPUID hypervisor bit, which also disables Hyper-V enlightenments, causing Windows to fall back to unoptimized code paths.

### SMBIOS Configuration

Use PVE's `smbios1` option with `base64=1` to set realistic hardware info:

```bash
# Example: set SMBIOS to a Lenovo ThinkCentre M720t
qm set <vmid> -smbios1 "uuid=$(cat /proc/sys/kernel/random/uuid),manufacturer=$(echo -n 'LENOVO' | base64),product=$(echo -n '10SQS0EE00' | base64),version=$(echo -n 'ThinkCentre M720t' | base64),serial=$(echo -n 'YOUR_SERIAL' | base64),sku=$(echo -n 'LENOVO_MT_10SQ_BU_Think_FM_ThinkCentre M720t' | base64),family=$(echo -n 'ThinkCentre M720t' | base64),base64=1"
```

> **Tip:** Use your host's real SMBIOS info (`dmidecode -t 1`) for maximum realism. Give each VM a different serial number.

### Full host SMBIOS passthrough (recommended)

PVE's `smbios1` only covers **Type 1** (system information). Every other table is
filled in by QEMU defaults, and those defaults are exactly what gives the VM away —
in particular this patch's `smbios_set_defaults("ASUS", ...)` populates the
**manufacturer of Types 2/3/4/17 with ASUS**, producing a self-contradicting
"Lenovo system in an ASUS chassis" that is *easier* to spot than leaving it alone.

This script reads the real values straight off the host and builds the full
`-smbios` argument list:

```bash
D=/sys/class/dmi/id
SM="-smbios 'type=0,vendor=$(cat $D/bios_vendor),version=$(cat $D/bios_version),date=$(cat $D/bios_date),release=$(dmidecode -s bios-revision),uefi=on'"
SM="$SM -smbios 'type=1,serial=$(cat $D/product_serial),sku=$(cat $D/product_sku)'"
SM="$SM -smbios 'type=2,manufacturer=$(cat $D/board_vendor),product=$(cat $D/board_name),version=$(cat $D/board_version),serial=$(cat $D/board_serial)'"
SM="$SM -smbios 'type=3,manufacturer=$(cat $D/chassis_vendor),version=,serial=$(cat $D/chassis_serial),asset=$(cat $D/chassis_asset_tag),chassis-type=$(cat $D/chassis_type)'"
SM="$SM -smbios 'type=4,sock_pfx=CPU,manufacturer=$(dmidecode -t 4 | awk -F': ' '/^\tManufacturer:/{print $2; exit}'),version=$(dmidecode -t 4 | awk -F': ' '/^\tVersion:/{print $2; exit}')'"
SM="$SM -smbios 'type=17,loc_pfx=DIMM,manufacturer=$(dmidecode -t 17 | awk -F': ' '/^\tManufacturer:/{print $2; exit}')'"
SM="$SM -smbios 'type=11$(dmidecode -t 11 | sed -n 's/^\t*String [0-9]*: //p' | while read -r x; do printf ',value=%s' "$x"; done)'"

qm set <vmid> --args "$SM"          # append if the VM already has args
```

> ⚠️ **`chassis-type=` requires this patch.** An unpatched QEMU fails with
> `Invalid parameter 'chassis-type'` and **refuses to start the VM**. Run
> `pve-qemu-anti-detection install/upgrade` first, then add the parameter.

**Fields you must set explicitly:** `manufacturer` for types 2/3/4/17 and
`version` for types 1/2/3/4. Leave any of them empty and `smbios_set_defaults()`
fills in the patch default (ASUS). The empty `type=3,version=` is deliberate —
an empty string is what displaces `ASUS-PC`.

#### Measured result

On a Lenovo ThinkCentre M720t desktop host, values seen by the guest (Linux, read from
`/sys/class/dmi/id/*` through qemu-guest-agent):

| Field | Before | After | Host |
|-------|--------|-------|------|
| `bios_vendor` | `EFI Development Kit II / OVMF` | `LENOVO` | `LENOVO` |
| `bios_version` | `3.20230228-4` | `M1UKT49A` | `M1UKT49A` |
| `bios_date` | `06/06/2023` | `03/15/2024` | `03/15/2024` |
| `board_vendor` / `board_name` | empty / empty | `LENOVO` / `3132` | same |
| `board_version` / `board_serial` | empty / empty | `SDK0J40709 WIN` / `LXXXXXXXXXX` | same |
| `chassis_vendor` | `ASUS` | `LENOVO` | `LENOVO` |
| `chassis_type` | `1` (Other) | `6` (Mini Tower) | `6` |
| `chassis_asset_tag` | empty | `no asset tag` | `no asset tag` |
| `product_serial` | custom | `MJ0XXXXX` | `MJ0XXXXX` |

> This also confirms that **`-smbios type=0` overrides OVMF's own firmware
> identity** — the earlier claim that "OVMF firmware strings cannot be changed"
> was inaccurate.

## Anti-Cheat Compatibility

### What This Patch Covers

| Detection Vector | Status |
|-----------------|--------|
| SMBIOS strings (manufacturer, product, etc.) | ✅ Patched (defaults + user SMBIOS) |
| ACPI table OEM/Creator IDs | ✅ Patched (BOCHS→INTEL, BXPC→PTL) |
| Device name strings (SCSI, IDE, NVMe, USB, etc.) | ✅ Patched (QEMU→ASUS) |
| EDID monitor vendor | ✅ Patched (RHT→LEN) |
| SMBIOS VM flag (Type 0) | ✅ Patched (VM bit is never advertised) |
| SMBIOS chassis type (Type 3) | ✅ Configurable (`chassis-type=N`), no longer hardcoded to `Other` |
| BIOS vendor/version (Type 0) | ✅ Verified — `-smbios type=0` overrides OVMF's own `EFI Development Kit II / OVMF` |
| Baseboard info (Type 2) | ✅ Verified — left unset the guest sees blanks, which no real machine has |
| HDA audio PCI vendor | ✅ Patched (0x1af4→0x8086) |
| KVM CPUID signature | ✅ Hidden via `kvm=off` arg (Windows) / kept for paravirt (Linux) |
| Hyper-V CPUID vendor string | ✅ Via `hv_vendor_id=intel` arg |

### What This Patch Does NOT Cover

| Detection Vector | Reason |
|-----------------|--------|
| VirtIO PCI vendor ID (`0x1af4`) | Cannot change — guest VirtIO drivers match by vendor/device ID. Changing breaks boot. |
| CPUID hypervisor bit (leaf 1, bit 31) | Can disable with `hypervisor=off`, but this kills Hyper-V enlightenments and performance. |
| Hardware timing side-channels (RDTSC/RDTSCP) | Requires host kernel patch: [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) |
| EFI System Table `FirmwareVendor` (`EDK II`) | Requires rebuilding `pve-edk2-firmware` with a different `PcdFirmwareVendor`. Only reachable from kernel-mode code. |
| WMI hardware sensor queries (Win32_Fan, CIM_Sensor, etc.) | VMs lack physical sensor data. In theory a custom SSDT with thermal zone / `_FAN` objects could be injected via `-acpitable`; **unverified**. |
| VirtIO driver names in guest | Guest-side — not controllable from QEMU. |

### Anti-Cheat & DRM Status

| Software | Type | Status | Notes |
|----------|------|--------|-------|
| Mhyprot | Anti-Cheat | ✅ Bypass | |
| Anti Cheat Expert (ACE) | Anti-Cheat | ✅ Bypass | |
| Easy Anti Cheat (EAC) | Anti-Cheat | ⚠️ Basic only | Deep mode may detect VirtIO PCI or timing |
| nProtect GameGuard (NP) | Anti-Cheat | ✅ Bypass | |
| Vanguard | Anti-Cheat | ❌ Not supported | Kernel-level detection, checks timing + hardware deeply |
| Gepard Shield | Anti-Cheat | ⚠️ Conditional | Requires [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) host kernel patch |
| Denuvo | DRM | ✅ Bypass | VM detection is basic string/SMBIOS checks |
| VMProtect | DRM | ✅ Bypass | |
| Themida | DRM | ✅ Bypass | |
| VProtect | DRM | ✅ Bypass | |
| Enigma Protector | DRM | ✅ Bypass | |
| Safengine Shielden | DRM | ✅ Bypass | |

> **Summary:** This patch defeats **basic VM detection** used by most DRM/anti-tamper software (Denuvo, VMProtect, Themida, etc.) and some anti-cheat systems. It does **NOT** reliably bypass kernel-level anti-cheat like Vanguard or EAC's deep detection mode.

## Performance Notes

| Configuration | Linux VM Impact | Windows VM Impact |
|--------------|----------------|-------------------|
| Patched QEMU only (recommended for Linux) | **~0%** — full KVM paravirt | N/A |
| + `kvm=off` + `hv_*` (recommended for Windows) | N/A | **~0%** — Hyper-V enlightenments replace KVM paravirt |
| + `kvm=off` without `hv_*` | **-5~15%** (up to -30% under heavy I/O) | **-5~15%** |
| + `hypervisor=off` | **-5~15%** | **-10~30%** (loses Hyper-V enlightenments) |

> **Recommendation:** Linux VMs: no extra args needed. Windows VMs: use `kvm=off` + full `hv_*` enlightenments (see [Windows VMs](#windows-vms) section).

## Custom Patches

Place your `.patch` files in `/usr/src/pve-qemu-anti-detection/patches/`, then run:

```bash
pve-qemu-anti-detection rebuild
```

## Configuration

Edit `/etc/pve-qemu-anti-detection.conf` to customize:

```bash
# PVE QEMU source git repository
PVE_QEMU_GIT="git://git.proxmox.com/git/pve-qemu.git"

# Number of parallel build jobs (0 = auto-detect)
BUILD_JOBS=0

# Auto-rebuild on pve-qemu-kvm update (yes/no)
AUTO_REBUILD="yes"

# China mainland mirror mode (use GitHub mirrors)
USE_CN_MIRROR=0
```

## How It Works

```
apt upgrade
    │
    ▼
pve-qemu-kvm updated
    │
    ▼
APT DPkg::Post-Invoke hook fires
    │
    ▼
pve-qemu-anti-detection hook
  - detects version mismatch
  - starts systemd rebuild service
    │
    ▼
Background rebuild:
  1. Clone pve-qemu source
  2. Apply anti-detection patches
  3. Build patched .deb
  4. Install patched package
  5. Hold package
```

## File Locations

| Path | Description |
|------|-------------|
| `/usr/bin/pve-qemu-anti-detection` | Main management script |
| `/usr/src/pve-qemu-anti-detection/patches/` | Patch files |
| `/etc/pve-qemu-anti-detection.conf` | Configuration |
| `/etc/apt/apt.conf.d/99-pve-qemu-anti-detection` | APT hook |
| `/lib/systemd/system/pve-qemu-anti-detection-rebuild.service` | Systemd service |
| `/var/lib/pve-qemu-anti-detection/` | Build directory and state |
| `/var/log/pve-qemu-anti-detection.log` | Build log |

## Acknowledgements

Inspired by and built upon:

- [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) by [@zhaodice](https://github.com/zhaodice) — The original QEMU anti-detection patch
- [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) by [@WCharacter](https://github.com/WCharacter) — Host kernel patch for timing side-channel

## License

[GPL-2.0](LICENSE)

The patch under `patches/` modifies QEMU source code, which is licensed under
GPL-2.0, and is derived from [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection)
by [@zhaodice](https://github.com/zhaodice).

---

## Author

**Hikaru** (i@rua.moe)

## Donate

If this project helped you, consider buying me a coffee ☕

**ETH / ERC-20:** `0xdb61B2aD59bdF2A066B7fC9F00f86c3EBc4856B4`

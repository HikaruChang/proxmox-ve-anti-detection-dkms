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
| EDID vendor | `RHT` (Red Hat) | `DEL` (Dell) |
| vmgenid | Enabled | Disabled |
| ACPI debug AML | Enabled | Disabled |
| fw_cfg ACPI DSDT | Present | Removed |
| USB strings | `QEMU` | `ASUS` |
| RNDIS vendor | `0x1234` | `0x8086` |

## Quick Start

### Build and install the .deb package (on PVE host)

```bash
apt install git build-essential devscripts debhelper
git clone https://github.com/HikaruChang/proxmox-ve-anti-detection-dkms.git
cd proxmox-ve-anti-detection-dkms
dpkg-buildpackage -us -uc -b
dpkg -i ../pve-qemu-anti-detection_1.0.0-1_all.deb
```

### Initial patched build

```bash
pve-qemu-anti-detection install
```

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
# Example: set SMBIOS to HP ProLiant DL380 Gen10
qm set <vmid> -smbios1 "uuid=$(cat /proc/sys/kernel/random/uuid),manufacturer=$(echo -n 'HP Inc.' | base64),product=$(echo -n 'ProLiant DL380 Gen10' | base64),version=$(echo -n 'U30' | base64),serial=$(echo -n 'YOUR_SERIAL' | base64),sku=$(echo -n 'ProLiant DL380 Gen10' | base64),family=$(echo -n 'ProLiant' | base64),base64=1"
```

> **Tip:** Use your host's real SMBIOS info (`dmidecode -t 1`) for maximum realism. Give each VM a different serial number.

## Anti-Cheat Compatibility

### What This Patch Covers

| Detection Vector | Status |
|-----------------|--------|
| SMBIOS strings (manufacturer, product, etc.) | ✅ Patched (defaults + user SMBIOS) |
| ACPI table OEM/Creator IDs | ✅ Patched (BOCHS→INTEL, BXPC→PTL) |
| Device name strings (SCSI, IDE, NVMe, USB, etc.) | ✅ Patched (QEMU→ASUS) |
| EDID monitor vendor | ✅ Patched (RHT→DEL) |
| SMBIOS VM type flag (Type 3 Chassis) | ✅ Patched (0x14→0x08) |
| HDA audio PCI vendor | ✅ Patched (0x1af4→0x8086) |
| KVM CPUID signature | ✅ Hidden via `kvm=off` arg (Windows) / kept for paravirt (Linux) |
| Hyper-V CPUID vendor string | ✅ Via `hv_vendor_id=intel` arg |

### What This Patch Does NOT Cover

| Detection Vector | Reason |
|-----------------|--------|
| VirtIO PCI vendor ID (`0x1af4`) | Cannot change — guest VirtIO drivers match by vendor/device ID. Changing breaks boot. |
| CPUID hypervisor bit (leaf 1, bit 31) | Can disable with `hypervisor=off`, but this kills Hyper-V enlightenments and performance. |
| Hardware timing side-channels (RDTSC/RDTSCP) | Requires host kernel patch: [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) |
| OVMF firmware strings | Cannot change — firmware is a separate binary not covered by this QEMU patch. |
| WMI hardware sensor queries (Win32_Fan, CIM_Sensor, etc.) | No solution — VMs lack physical sensor data. |
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

## Legacy Build Instructions

For manual build on older PVE versions, see [readme-8.1.5-3.md](readme-8.1.5-3.md).

---

## Author

**Hikaru** (i@rua.moe)

## Donate

If this project helped you, consider buying me a coffee ☕

**ETH / ERC-20:** `0xdb61B2aD59bdF2A066B7fC9F00f86c3EBc4856B4`

# Proxmox VE 反虚拟机检测（类 DKMS 自动补丁）

[English](README.md)

一个类似 DKMS 的机制，自动为 `pve-qemu-kvm` 打上反检测补丁。
每次通过 apt 安装或升级 `pve-qemu-kvm` 时，补丁会自动应用 —— 类似 DKMS 在内核更新时自动重建内核模块。

## 补丁内容

补丁在 **QEMU 源码层面** 修改或隐藏常见的虚拟机指纹：

| 类别 | 原始值 | 修改后 |
|------|--------|--------|
| 设备名称字符串 | `QEMU *` | `ASUS *` |
| ACPI OEM ID | `BOCHS` | `INTEL` |
| ACPI Creator ID | `BXPC` | `PTL` |
| SMBIOS 默认值 | `QEMU`, `Standard PC` | `ASUS`, `M4A88TD-M` |
| SMBIOS 虚拟机标志 | `0x14`（虚拟机） | `0x08`（桌面） |
| KVM CPUID 签名 | `KVMKVMKVM` | `GenuineIntel` |
| HDA 音频 PCI 厂商 | `0x1af4`（Red Hat） | `0x8086`（Intel） |
| EDID 显示器厂商 | `RHT`（Red Hat） | `DEL`（Dell） |
| vmgenid | 启用 | 禁用 |
| ACPI 调试 AML | 启用 | 禁用 |
| fw_cfg ACPI DSDT | 存在 | 移除 |
| USB 字符串 | `QEMU` | `ASUS` |
| RNDIS 厂商 ID | `0x1234` | `0x8086` |

## 快速开始

### 构建并安装 .deb 包（在 PVE 宿主机上）

```bash
apt install git build-essential devscripts debhelper
git clone https://github.com/HikaruChang/proxmox-ve-anti-detection-dkms.git
cd proxmox-ve-anti-detection-dkms
dpkg-buildpackage -us -uc -b
dpkg -i ../pve-qemu-anti-detection_1.0.0-1_all.deb
```

### 首次构建补丁版 QEMU

```bash
pve-qemu-anti-detection install
```

执行流程：
1. 克隆与当前安装版本匹配的 `pve-qemu` 源码
2. 应用反检测补丁
3. 构建补丁版 `pve-qemu-kvm` .deb（约 30-60 分钟）
4. 安装补丁包
5. 锁定 `pve-qemu-kvm` 版本，防止 apt 覆盖

### 自动重建

当 apt 更新 `pve-qemu-kvm` 时（例如取消锁定后），APT 钩子会自动检测版本变更并通过 systemd 在后台启动重建。

### 命令列表

| 命令 | 说明 |
|------|------|
| `pve-qemu-anti-detection install [version]` | 首次设置：获取源码、打补丁、构建、安装 |
| `pve-qemu-anti-detection rebuild` | 使用最新补丁重建当前版本 |
| `pve-qemu-anti-detection upgrade` | 检查更新、升级并重新打补丁 |
| `pve-qemu-anti-detection status` | 显示当前补丁状态 |
| `pve-qemu-anti-detection hold` | 锁定 pve-qemu-kvm（防止 apt 覆盖） |
| `pve-qemu-anti-detection unhold` | 取消锁定 |
| `pve-qemu-anti-detection log` | 查看构建日志 |

## 虚拟机配置

补丁在源码层面生效，**大部分反检测是自动的**，不需要任何 VM 参数。
但 Windows 虚拟机需要额外配置以获得最佳性能。

### Linux 虚拟机

不需要特殊的 `args` 参数。只需设置逼真的 SMBIOS 信息。

> ⚠️ **不要添加 `kvm=off` 或 `hypervisor=off`** —— 这会禁用 KVM 半虚拟化，导致 **5–30% 的性能损失**。

示例（`/etc/pve/qemu-server/<vmid>.conf`）：
```
cpu: host
smbios1: uuid=...,manufacturer=SFAgSW5jLg==,product=UHJvTGlhbnQgREwzODAgR2VuMTA=,version=VTMw,serial=...,sku=...,family=...,base64=1
```

### Windows 虚拟机

Windows 虚拟机需要启用 **Hyper-V enlightenments** 以获得良好性能，并使用 `hv_vendor_id` 伪装 hypervisor 厂商：

```
args: -cpu host,+kvm_pv_unhalt,+kvm_pv_eoi,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,hv_vendor_id=intel
cpu: host
smbios1: uuid=...,manufacturer=SFAgSW5jLg==,product=UHJvTGlhbnQgREwzODAgR2VuMTA=,version=VTMw,serial=...,sku=...,family=...,base64=1
```

要点：
- **`hv_vendor_id=intel`** —— 将 Hyper-V CPUID 厂商字符串从 `Microsoft Hv` 改为 `intel`，隐藏 hypervisor 身份。
- **`hv_*` enlightenments** —— 启用 Windows 专属的 KVM 半虚拟化优化（定时器、自旋锁、VAPIC 等）。移除这些会导致严重的性能下降。
- **不要使用 `kvm=off`** —— 补丁已在源码层面处理 KVM CPUID。添加 `kvm=off` 会禁用所有 KVM 半虚拟化功能，影响性能。
- **不要使用 `hypervisor=off`** —— 这会清除 CPUID hypervisor 位，同时也会禁用 Hyper-V enlightenments，导致 Windows 回退到未优化的代码路径。

### SMBIOS 配置

使用 PVE 的 `smbios1` 选项配合 `base64=1` 设置逼真的硬件信息：

```bash
# 示例：设置 SMBIOS 为 HP ProLiant DL380 Gen10
qm set <vmid> -smbios1 "uuid=$(cat /proc/sys/kernel/random/uuid),manufacturer=$(echo -n 'HP Inc.' | base64),product=$(echo -n 'ProLiant DL380 Gen10' | base64),version=$(echo -n 'U30' | base64),serial=$(echo -n 'YOUR_SERIAL' | base64),sku=$(echo -n 'ProLiant DL380 Gen10' | base64),family=$(echo -n 'ProLiant' | base64),base64=1"
```

> **提示：** 使用宿主机的真实 SMBIOS 信息（`dmidecode -t 1`）效果最佳。给每个虚拟机设置不同的序列号。

## 反作弊兼容性

### 本补丁覆盖的检测项

| 检测向量 | 状态 |
|----------|------|
| SMBIOS 字符串（制造商、产品名等） | ✅ 已修补（默认值 + 用户 SMBIOS） |
| ACPI 表 OEM/Creator ID | ✅ 已修补（BOCHS→INTEL, BXPC→PTL） |
| 设备名称字符串（SCSI、IDE、NVMe、USB 等） | ✅ 已修补（QEMU→ASUS） |
| EDID 显示器厂商 | ✅ 已修补（RHT→DEL） |
| SMBIOS 虚拟机类型标志（Type 3 机箱） | ✅ 已修补（0x14→0x08） |
| HDA 音频 PCI 厂商 | ✅ 已修补（0x1af4→0x8086） |
| KVM CPUID 签名 | ✅ 已修补（KVMKVMKVM→GenuineIntel） |
| Hyper-V CPUID 厂商字符串 | ✅ 通过 `hv_vendor_id=intel` 参数 |

### 本补丁未覆盖的检测项

| 检测向量 | 原因 |
|----------|------|
| VirtIO PCI 厂商 ID（`0x1af4`） | 无法修改 —— 客户机 VirtIO 驱动通过厂商/设备 ID 匹配。修改会导致无法启动。 |
| CPUID hypervisor 位（leaf 1, bit 31） | 可通过 `hypervisor=off` 禁用，但这会杀死 Hyper-V enlightenments 和性能。 |
| 硬件时序侧信道（RDTSC/RDTSCP） | 需要宿主机内核补丁：[RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) |
| OVMF 固件字符串 | 无法修改 —— 固件是独立的二进制文件，不在此 QEMU 补丁范围内。 |
| WMI 硬件传感器查询（Win32_Fan、CIM_Sensor 等） | 无解决方案 —— 虚拟机缺少物理传感器数据。 |
| 客户机内的 VirtIO 驱动名称 | 客户机侧 —— 无法从 QEMU 控制。 |

### 反作弊软件状态

| 反作弊软件 | 状态 | 备注 |
|-----------|------|------|
| Mhyprot | ✅ 可绕过 | |
| Anti Cheat Expert (ACE) | ✅ 可绕过 | |
| Easy Anti Cheat (EAC) | ⚠️ 仅基础模式 | 深度模式可能检测 VirtIO PCI 或时序 |
| nProtect GameGuard (NP) | ✅ 可绕过 | |
| Vanguard | ❌ 不支持 | 内核级检测，深度检查时序和硬件 |
| Gepard Shield | ⚠️ 有条件 | 需要 [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) 宿主机内核补丁 |

> **总结：** 本补丁可以击败大多数软件使用的 **基础虚拟机检测**（VMProtect、Themida 等）和部分反作弊系统。**无法** 可靠绕过 Vanguard 或 EAC 深度检测模式等内核级反作弊。

## 性能说明

| 配置 | Linux 虚拟机影响 | Windows 虚拟机影响 |
|------|-----------------|-------------------|
| 仅补丁 QEMU（Linux 推荐） | **~0%** —— 无可测量开销 | 不适用 |
| + `hv_vendor_id=intel` + `hv_*`（Windows 推荐） | 不适用 | **~0%** —— Hyper-V enlightenments 保留 |
| + `kvm=off` | **-5~15%**（重 I/O 负载下最高 -30%） | **-5~15%** |
| + `hypervisor=off` | **-5~15%** | **-10~30%**（失去 Hyper-V enlightenments） |
| + `kvm=off` + `hypervisor=off` | **-10~30%** | **-15~40%** |

> **建议：** 使用默认配置（不加 `kvm=off`，不加 `hypervisor=off`）。源码级补丁无需性能代价即可处理检测。

## 自定义补丁

将你的 `.patch` 文件放入 `/usr/src/pve-qemu-anti-detection/patches/`，然后运行：

```bash
pve-qemu-anti-detection rebuild
```

## 配置文件

编辑 `/etc/pve-qemu-anti-detection.conf` 进行自定义：

```bash
# PVE QEMU 源码 git 仓库
PVE_QEMU_GIT="git://git.proxmox.com/git/pve-qemu.git"

# 并行构建任务数（0 = 自动检测）
BUILD_JOBS=0

# pve-qemu-kvm 更新时自动重建（yes/no）
AUTO_REBUILD="yes"
```

## 工作原理

```
apt upgrade
    │
    ▼
pve-qemu-kvm 被更新
    │
    ▼
APT DPkg::Post-Invoke 钩子触发
    │
    ▼
pve-qemu-anti-detection 钩子
  - 检测到版本不匹配
  - 启动 systemd 重建服务
    │
    ▼
后台重建：
  1. 克隆 pve-qemu 源码
  2. 应用反检测补丁
  3. 构建补丁版 .deb
  4. 安装补丁包
  5. 锁定版本
```

## 文件位置

| 路径 | 说明 |
|------|------|
| `/usr/bin/pve-qemu-anti-detection` | 主管理脚本 |
| `/usr/src/pve-qemu-anti-detection/patches/` | 补丁文件 |
| `/etc/pve-qemu-anti-detection.conf` | 配置文件 |
| `/etc/apt/apt.conf.d/99-pve-qemu-anti-detection` | APT 钩子 |
| `/lib/systemd/system/pve-qemu-anti-detection-rebuild.service` | Systemd 服务 |
| `/var/lib/pve-qemu-anti-detection/` | 构建目录和状态 |
| `/var/log/pve-qemu-anti-detection.log` | 构建日志 |

## 相关项目

- [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) —— 独立 QEMU 反检测（非 PVE）
- [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) —— 宿主机内核补丁，解决时序侧信道

## 旧版构建说明

旧版 PVE 手动构建方法，参见 [readme-8.1.5-3.md](readme-8.1.5-3.md)。

---

## 作者

**Hikaru** (i@rua.moe)

## 捐助

如果这个项目对你有帮助，考虑请我喝杯咖啡 ☕

**ETH / ERC-20：** `0xdb61B2aD59bdF2A066B7fC9F00f86c3EBc4856B4`

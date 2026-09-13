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
| HDA 音频 PCI 厂商 | `0x1af4`（Red Hat） | `0x8086`（Intel） |
| EDID 显示器厂商 | `RHT`（Red Hat） | `LEN`（Lenovo） |
| vmgenid | 启用 | 禁用 |
| ACPI 调试 AML | 启用 | 禁用 |
| fw_cfg ACPI DSDT | 存在 | 移除 |
| USB 字符串 | `QEMU` | `ASUS` |
| RNDIS 厂商 ID | `0x1234` | `0x8086` |
| SMBIOS 机箱类型 | `0x01`（Other，写死） | 可配置，默认 `0x03`（Desktop） |

## 快速开始

### 构建并安装 .deb 包（在 PVE 宿主机上）

```bash
apt install git build-essential devscripts debhelper
git clone https://github.com/HikaruChang/proxmox-ve-anti-detection-dkms.git
cd proxmox-ve-anti-detection-dkms
dpkg-buildpackage -us -uc -b
dpkg -i ../pve-qemu-anti-detection_*_all.deb
```

### 首次构建补丁版 QEMU

```bash
pve-qemu-anti-detection install
```

> **中国大陆用户：** 默认的 Proxmox git 服务器（`git.proxmox.com`）在国内下载极慢。
> 使用 `--cn` 切换到 GitHub 镜像加速下载：
> ```bash
> pve-qemu-anti-detection --cn install
> ```
> 也可以写入配置文件永久生效：
> ```bash
> echo 'USE_CN_MIRROR=1' >> /etc/pve-qemu-anti-detection.conf
> ```

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

**全局选项**（放在命令前面）：

| 选项 | 说明 |
|------|------|
| `--cn` / `--china` | 使用 GitHub 镜像加速下载（中国大陆推荐） |

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

Windows 虚拟机需要 `kvm=off` 隐藏 KVM CPUID 叶，同时配合 **Hyper-V enlightenments** 完全补偿失去的 KVM 半虚拟化性能：

```
args: -cpu host,kvm=off,+kvm_pv_unhalt,+kvm_pv_eoi,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,hv_vendor_id=intel
cpu: host
smbios1: uuid=...,manufacturer=SFAgSW5jLg==,product=UHJvTGlhbnQgREwzODAgR2VuMTA=,version=VTMw,serial=...,sku=...,family=...,base64=1
```

要点：
- **`kvm=off`** —— 隐藏整个 KVM CPUID 叶（`KVMKVMKVM` 签名 + 功能位）。反作弊软件无法看到 KVM。
- **`hv_*` enlightenments** —— 提供等效的半虚拟化性能来替代隐藏的 KVM 功能。`hv_time` 替代 kvm-clock，`hv_vapic` 替代 PV EOI 等。**净性能影响：~0%。**
- **`hv_vendor_id=intel`** —— 将 Hyper-V CPUID 厂商字符串从 `Microsoft Hv` 改为 `intel`。反作弊软件看到的是 Hyper-V（物理 Windows 机器上 VBS/HVCI/WSL2 也常见），而非 `Microsoft Hv`。
- **不要使用 `hypervisor=off`** —— 这会清除 CPUID hypervisor 位，同时也会禁用 Hyper-V enlightenments，导致 Windows 回退到未优化的代码路径。

### SMBIOS 配置

使用 PVE 的 `smbios1` 选项配合 `base64=1` 设置逼真的硬件信息：

```bash
# 示例：设置 SMBIOS 为 Lenovo ThinkCentre M720t
qm set <vmid> -smbios1 "uuid=$(cat /proc/sys/kernel/random/uuid),manufacturer=$(echo -n 'LENOVO' | base64),product=$(echo -n '10SQS0EE00' | base64),version=$(echo -n 'ThinkCentre M720t' | base64),serial=$(echo -n 'YOUR_SERIAL' | base64),sku=$(echo -n 'LENOVO_MT_10SQ_BU_Think_FM_ThinkCentre M720t' | base64),family=$(echo -n 'ThinkCentre M720t' | base64),base64=1"
```

> **提示：** 使用宿主机的真实 SMBIOS 信息（`dmidecode -t 1`）效果最佳。给每个虚拟机设置不同的序列号。

### 宿主机 SMBIOS 完整透传（推荐）

PVE 的 `smbios1` 只能设置 **Type 1**（系统信息）。其余的表 QEMU 会用默认值填充，
而默认值正是破绽的来源 —— 尤其是补丁里的 `smbios_set_defaults("ASUS", ...)`
会把 **Type 2/3/4/17 的厂商全部填成 ASUS**，造出「Lenovo 系统装在 ASUS 机箱里」
这种自相矛盾的组合，比不改还容易被识破。

以下脚本直接从宿主机读取真实值，生成完整的 `-smbios` 参数：

```bash
D=/sys/class/dmi/id
SM="-smbios 'type=0,vendor=$(cat $D/bios_vendor),version=$(cat $D/bios_version),date=$(cat $D/bios_date),release=$(dmidecode -s bios-revision),uefi=on'"
SM="$SM -smbios 'type=1,serial=$(cat $D/product_serial),sku=$(cat $D/product_sku)'"
SM="$SM -smbios 'type=2,manufacturer=$(cat $D/board_vendor),product=$(cat $D/board_name),version=$(cat $D/board_version),serial=$(cat $D/board_serial)'"
SM="$SM -smbios 'type=3,manufacturer=$(cat $D/chassis_vendor),version=,serial=$(cat $D/chassis_serial),asset=$(cat $D/chassis_asset_tag),chassis-type=$(cat $D/chassis_type)'"
SM="$SM -smbios 'type=4,sock_pfx=CPU,manufacturer=$(dmidecode -t 4 | awk -F': ' '/^\tManufacturer:/{print $2; exit}'),version=$(dmidecode -t 4 | awk -F': ' '/^\tVersion:/{print $2; exit}')'"
SM="$SM -smbios 'type=17,loc_pfx=DIMM,manufacturer=$(dmidecode -t 17 | awk -F': ' '/^\tManufacturer:/{print $2; exit}')'"
SM="$SM -smbios 'type=11$(dmidecode -t 11 | sed -n 's/^\t*String [0-9]*: //p' | while read -r x; do printf ',value=%s' "$x"; done)'"

qm set <vmid> --args "$SM"          # 若已有 args，记得追加而非覆盖
```

> ⚠️ **`chassis-type=` 需要本补丁**。未打补丁的 QEMU 会报
> `Invalid parameter 'chassis-type'` 并**拒绝启动虚拟机**。先完成
> `pve-qemu-anti-detection install/upgrade` 再加这个参数。

**必须显式设置的字段**：`type=2/3/4/17` 的 `manufacturer`、`type=1/2/3/4` 的 `version`。
这些字段一旦留空，`smbios_set_defaults()` 就会填进补丁的默认值（ASUS）。
`type=3,version=` 留空是刻意的 —— 用空串顶掉 `ASUS-PC`。

#### 实测效果

在一台 Lenovo ThinkCentre M720t 台式机宿主机上，客体（Linux，经 qemu-guest-agent 读取
`/sys/class/dmi/id/*`）的变化：

| 字段 | 配置前 | 配置后 | 宿主真实值 |
|------|--------|--------|-----------|
| `bios_vendor` | `EFI Development Kit II / OVMF` | `LENOVO` | `LENOVO` |
| `bios_version` | `3.20230228-4` | `M1UKT49A` | `M1UKT49A` |
| `bios_date` | `06/06/2023` | `03/15/2024` | `03/15/2024` |
| `board_vendor` / `board_name` | 空 / 空 | `LENOVO` / `3132` | 同左 |
| `board_version` / `board_serial` | 空 / 空 | `SDK0J40709 WIN` / `LXXXXXXXXXX` | 同左 |
| `chassis_vendor` | `ASUS` | `LENOVO` | `LENOVO` |
| `chassis_type` | `1`（Other） | `6`（Mini Tower） | `6` |
| `chassis_asset_tag` | 空 | `no asset tag` | `no asset tag` |
| `product_serial` | 自定义 | `MJ0XXXXX` | `MJ0XXXXX` |

> 这也证实了 **`-smbios type=0` 会覆盖 OVMF 自带的固件标识** ——
> 早期版本文档中「OVMF 固件字符串无法修改」的说法并不准确。

## 反作弊兼容性

### 本补丁覆盖的检测项

| 检测向量 | 状态 |
|----------|------|
| SMBIOS 字符串（制造商、产品名等） | ✅ 已修补（默认值 + 用户 SMBIOS） |
| ACPI 表 OEM/Creator ID | ✅ 已修补（BOCHS→INTEL, BXPC→PTL） |
| 设备名称字符串（SCSI、IDE、NVMe、USB 等） | ✅ 已修补（QEMU→ASUS） |
| EDID 显示器厂商 | ✅ 已修补（RHT→LEN） |
| SMBIOS 虚拟机标志位（Type 0） | ✅ 已修补（VM 位永不置位） |
| SMBIOS 机箱类型（Type 3） | ✅ 可配置（`chassis-type=N`），不再写死 `Other` |
| BIOS 厂商/版本（Type 0） | ✅ 已验证 —— `-smbios type=0` 覆盖 OVMF 自带的 `EFI Development Kit II / OVMF` |
| 主板信息（Type 2） | ✅ 已验证 —— 不设置时客体显示为空，真机不可能 |
| HDA 音频 PCI 厂商 | ✅ 已修补（0x1af4→0x8086） |
| KVM CPUID 签名 | ✅ 通过 `kvm=off` 参数隐藏（Windows）/ 保留用于半虚拟化（Linux） |
| Hyper-V CPUID 厂商字符串 | ✅ 通过 `hv_vendor_id=intel` 参数 |

### 本补丁未覆盖的检测项

| 检测向量 | 原因 |
|----------|------|
| VirtIO PCI 厂商 ID（`0x1af4`） | 无法修改 —— 客户机 VirtIO 驱动通过厂商/设备 ID 匹配。修改会导致无法启动。 |
| CPUID hypervisor 位（leaf 1, bit 31） | 可通过 `hypervisor=off` 禁用，但这会杀死 Hyper-V enlightenments 和性能。 |
| 硬件时序侧信道（RDTSC/RDTSCP） | 需要宿主机内核补丁：[RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) |
| EFI System Table 的 `FirmwareVendor`（`EDK II`） | 需重建 `pve-edk2-firmware` 修改 `PcdFirmwareVendor`。仅内核态驱动可读到。 |
| WMI 硬件传感器查询（Win32_Fan、CIM_Sensor 等） | 虚拟机缺少物理传感器数据。理论上可用 `-acpitable` 注入带 thermal zone / `_FAN` 对象的自定义 SSDT，**未验证**。 |
| 客户机内的 VirtIO 驱动名称 | 客户机侧 —— 无法从 QEMU 控制。 |

### 反作弊与 DRM 状态

| 软件 | 类型 | 状态 | 备注 |
|------|------|------|------|
| Mhyprot | 反作弊 | ✅ 可绕过 | |
| Anti Cheat Expert (ACE) | 反作弊 | ✅ 可绕过 | |
| Easy Anti Cheat (EAC) | 反作弊 | ⚠️ 仅基础模式 | 深度模式可能检测 VirtIO PCI 或时序 |
| nProtect GameGuard (NP) | 反作弊 | ✅ 可绕过 | |
| Vanguard | 反作弊 | ❌ 不支持 | 内核级检测，深度检查时序和硬件 |
| Gepard Shield | 反作弊 | ⚠️ 有条件 | 需要 [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) 宿主机内核补丁 |
| Denuvo | DRM | ✅ 可绕过 | 虚拟机检测仅为基础字符串/SMBIOS 检查 |
| VMProtect | DRM | ✅ 可绕过 | |
| Themida | DRM | ✅ 可绕过 | |
| VProtect | DRM | ✅ 可绕过 | |
| Enigma Protector | DRM | ✅ 可绕过 | |
| Safengine Shielden | DRM | ✅ 可绕过 | |

> **总结：** 本补丁可以击败大多数 DRM/反篡改软件（Denuvo、VMProtect、Themida 等）使用的 **基础虚拟机检测** 和部分反作弊系统。**无法** 可靠绕过 Vanguard 或 EAC 深度检测模式等内核级反作弊。

## 性能说明

| 配置 | Linux 虚拟机影响 | Windows 虚拟机影响 |
|------|-----------------|-------------------|
| 仅补丁 QEMU（Linux 推荐） | **~0%** —— 完整 KVM 半虚拟化 | 不适用 |
| + `kvm=off` + `hv_*`（Windows 推荐） | 不适用 | **~0%** —— Hyper-V enlightenments 替代 KVM 半虚拟化 |
| + `kvm=off` 不加 `hv_*` | **-5~15%**（重 I/O 负载下最高 -30%） | **-5~15%** |
| + `hypervisor=off` | **-5~15%** | **-10~30%**（失去 Hyper-V enlightenments） |

> **建议：** Linux 虚拟机：无需额外参数。Windows 虚拟机：使用 `kvm=off` + 完整的 `hv_*` enlightenments（参见 [Windows 虚拟机](#windows-虚拟机) 章节）。

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

# 中国大陆镜像模式（使用 GitHub 镜像加速下载）
USE_CN_MIRROR=0
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

## 致谢

灵感源自：

- [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) by [@zhaodice](https://github.com/zhaodice) —— 原始 QEMU 反检测补丁
- [RDTSC-KVM-Handler](https://github.com/WCharacter/RDTSC-KVM-Handler) by [@WCharacter](https://github.com/WCharacter) —— 宿主机内核补丁，解决时序侧信道

## 许可证

[GPL-2.0](LICENSE)

`patches/` 下的补丁修改的是 QEMU 源码（GPL-2.0 授权），并派生自
[@zhaodice](https://github.com/zhaodice) 的
[qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection)。

---

## 作者

**Hikaru** (i@rua.moe)

## 捐助

如果这个项目对你有帮助，考虑请我喝杯咖啡 ☕

**ETH / ERC-20：** `0xdb61B2aD59bdF2A066B7fC9F00f86c3EBc4856B4`

# op-ib

基于 **OpenWrt / ImmortalWrt / iStoreOS** 官方 ImageBuilder 组装的 x86-64 与 NanoPi 固件仓库。

本仓库独立维护，构建、发布与配置均不跟随上游仓库；上游项目仅作为 ImageBuilder 来源与参考，并在下方鸣谢。

> 请勿用于商业用途。

## 特性

- **三上游**：OpenWrt、ImmortalWrt、iStoreOS 均可构建 x86-64 固件；NanoPi 系列使用 OpenWrt
- **默认配置**：管理地址 `10.1.1.2/24`，强制 `proto=static`；上游未生成 LAN 或只给了 DHCP 时首次开机自动补全网桥与静态地址，主机名使用各上游默认
- **ttyd 网页终端**：`http://10.1.1.2:7681`，免登录直接进入 root shell（仅建议在可信 LAN 使用）
- **现代 LuCI**：纯 JS 界面、Vantage 主题，首次开机初始化中文环境、国内 NTP 与镜像源
- **插件**：HomeProxy、Nikki、Honk / dae（eBPF 透明代理）、FlowCone（eBPF FullCone NAT）、WireGuard、ZeroTier、SQM（CAKE / FQ_Codel）、NATMap-T、Bandix、AP-Modem、ARP 绑定、AirConnect、DDNS、UPnP、3cat
- **底层优化**：BBR 拥塞控制；网卡上线时自动拉满 RX/TX Ring Buffer；zram-swap
- **Full-Cone NAT**：FlowCone 提供 UDP Full-Cone；ImmortalWrt 额外启用 firewall4 fullcone（非 UDP/TCP），两者按协议分工
- **固件格式**：同时产出 `img.gz`（sysupgrade / combined-efi）与 `iso`（`image.iso`、`image-efi.iso`）
- **X86 驱动**：Intel、Realtek 2.5G、Mellanox 10G/25G、VirtIO / VMXNet3 及 Intel 核显（i915 DRM）
- **NanoPi**：支持 R2S / R2C / R3S / R4S，适配 PWM 温控风扇驱动
- USB 网络共享相关包默认在 `profiles/packages.common` 中注释，需要时自行取消注释

## 支持设备与产物

| 设备 | Target/Subtarget | Profile | 产物前缀 |
| :--- | :--- | :--- | :--- |
| **X86** | `x86/64` | `generic` | `openwrt-` / `immortalwrt-` / `istoreos-` |
| **NanoPi R2S** | `rockchip/armv8` | `friendlyarm_nanopi-r2s` | `openwrt-` |
| **NanoPi R2C** | `rockchip/armv8` | `friendlyarm_nanopi-r2c` | `openwrt-` |
| **NanoPi R3S** | `rockchip/armv8` | `friendlyarm_nanopi-r3s` | `openwrt-` |
| **NanoPi R4S** | `rockchip/armv8` | `friendlyarm_nanopi-r4s` | `openwrt-` |

产物命名示例：

```text
openwrt-x86-64-25.12.6-2026-11-04-squashfs-combined-efi.img.gz
openwrt-x86-64-25.12.6-2026-11-04-ext4-combined-efi.img.gz
openwrt-x86-64-25.12.6-2026-11-04-image.iso
openwrt-x86-64-25.12.6-2026-11-04-image-efi.iso

immortalwrt-x86-64-25.12.2-2026-11-04-squashfs-combined-efi.img.gz
immortalwrt-x86-64-25.12.2-2026-11-04-image-efi.iso

istoreos-x86-64-snapshot-2026-11-04-squashfs-combined-efi.img.gz
istoreos-x86-64-snapshot-2026-11-04-image-efi.iso
```

## 构建入口

| 入口 | 上游 | 说明 |
| :--- | :--- | :--- |
| `X86-OpenWrt.yml` | OpenWrt | x86-64 |
| `X86-ImmortalWrt.yml` | ImmortalWrt | x86-64 |
| `X86-iStoreOS.yml` | iStoreOS | x86-64，滚动源，版本标识 `snapshot` |
| `R2S-OpenWrt.yml` / `R2C-OpenWrt.yml` / `R3S-OpenWrt.yml` / `R4S-OpenWrt.yml` | OpenWrt | NanoPi |
| `OpenWrt-Matrix.yml` | 可选 | 统一矩阵入口，手动选择 `upstream` 与 `targets` |

定时任务每 3 天运行一次，并错开时间（UTC）：

- OpenWrt：02:00
- ImmortalWrt：06:00
- iStoreOS：10:00

每次构建从对应上游源解析当时可用的包版本，不锁定插件版本。

## 本地构建

需要 Linux（或 WSL / 容器）+ bash，依赖 `curl tar zstd make git sed awk findutils`；构建 ISO 还需 `genisoimage`（提供 `mkisofs`）。

```bash
# OpenWrt
bash scripts/build.sh x86 64 generic packages.x86_64 25.12 openwrt

# ImmortalWrt
bash scripts/build.sh x86 64 generic packages.x86_64 25.12.2 immortalwrt

# iStoreOS（滚动源，版本固定为 snapshot）
bash scripts/build.sh x86 64 generic packages.x86_64 snapshot istoreos

# NanoPi R4S（OpenWrt）
bash scripts/build.sh rockchip armv8 friendlyarm_nanopi-r4s packages.rockchip 25.12 openwrt
```

产物写入 `artifact/`，中间目录为 `build_<upstream>_<target>_<subtarget>_<profile>/`。

## 发布与清理

- Release tag：`openwrt-<version>`、`immortalwrt-<version>`、`istoreos-snapshot`
- `Cleanup-Release-Assets.yml`：每个 tag 只保留最新 3 次构建的资产（每周一及手动触发）
- `Cleaning.yml`：清理旧的 Release、artifacts 与 workflow 日志

## 目录结构

```text
profiles/                 包清单（packages.common / packages.x86_64 / packages.rockchip）
files/                    镜像 overlay（uci-defaults、rc.local、sysctl、hotplug）
scripts/build.sh          唯一构建入口
.github/workflows/        设备入口、统一矩阵、清理任务
```

## 上游与鸣谢

本项目能够构建，依赖以下上游项目与社区：

| 上游 | 用途 |
| :--- | :--- |
| [OpenWrt](https://github.com/openwrt/openwrt) | 官方 ImageBuilder、软件包与 LuCI |
| [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) | ImageBuilder 与软件包 |
| [iStoreOS](https://github.com/istoreos/istoreos) | ImageBuilder 与软件包（KoolCenter 分发） |
| [QiuSimons/YAOF](https://github.com/QiuSimons/YAOF) | 本仓库的起点与早期构建脚本参考 |
| [QiuSimons/OpenWrt-Add](https://github.com/QiuSimons/OpenWrt-Add) | 第三方签名 APK 源与 `fuck` 工具 |

同时感谢以下社区维护者与项目：

- [coolsnowwolf](https://github.com/coolsnowwolf)
- [Lienol](https://github.com/Lienol)
- [NoTengoBattery](https://github.com/NoTengoBattery)
- [tty228](https://github.com/tty228)
- [destan19](https://github.com/destan19)
- [jerrykuku](https://github.com/jerrykuku)
- [lisaac](https://github.com/lisaac)
- [rufengsuixing](https://github.com/rufengsuixing)
- [ElonH](https://github.com/ElonH)
- [NateLol](https://github.com/NateLol)
- [kiddin9](https://github.com/kiddin9)
- [AmadeusGhost](https://github.com/AmadeusGhost)
- [1715173329](https://github.com/1715173329)
- [vernesong](https://github.com/vernesong)

## 许可证

见 [LICENSE](LICENSE)。

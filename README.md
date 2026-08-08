# gh-action-imagebuilder

![GitHub license](https://img.shields.io/github/license/MinimaxFlora/gh-action-imagebuilder?style=flat-square)
![GitHub stars](https://img.shields.io/github/stars/MinimaxFlora/gh-action-imagebuilder?style=flat-square)
![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00A98F?style=flat-square&logo=openwrt&logoColor=white)

GitHub Composite Action：**从 OpenWrt 官方直接下载 ImageBuilder**（无需 Docker）构建定制化
OpenWrt 固件。自动检测 24.x / 25.x 最新稳定版，支持预设默认管理 IP、root 密码、rootfs 空间、
PPPoE 拨号、ZeroWrt 系统标识、彩色 SSH 登录横幅以及第三方插件。

## 功能特性

- 📦 **免 Docker** — 直接从 [downloads.openwrt.org](https://downloads.openwrt.org/releases/)
  官方下载 `openwrt-imagebuilder` 压缩包，解压后直接在 runner 上 `make image`
- 🔄 **自动检测版本** — 设置 `24` 或 `25`，自动检测 OpenWrt 官方最新稳定版
  （如 v24.10.8 / v25.12.5），**无需手动维护版本号**
- 🖥️ **支持的架构**：`x86-64`、`x86-generic`、`x86-geode`、`x86-legacy`、`rockchip-armv8`
- 🌐 **默认管理 IP** — 通过 `uci-defaults` 在首次启动自动写入
- 🔑 **root 密码** — 可选设置固件 root 密码（首次启动生效）；留空保持默认空密码
- 🔌 **PPPoE** — 从 secrets 读取账号密码自动配置拨号；不填则 WAN 保持 DHCP
- 🖥️ **ZeroWrt 系统标识** — 自动写入 `DISTRIB_DESCRIPTION=ZeroWrt-日期`、
  `DISTRIB_REVISION=By MinimaxFlora`、`os-release=ZeroWrt 标准版`，主机名设为 `ZeroWrt`
- 🎨 **彩色 SSH 登录横幅** — 内置 SSRIP 彩色 banner（`files/etc/banner`，
  参考 immortalwrt-mt798x 原版），SSH 登录即显示
- 📦 **第三方插件** — 从 [Extras_Paclages](https://github.com/MinimaxFlora/Extras_Paclages)
  自动导入：24.x → `ipk` 分支，25.x → `apk` 分支，按架构分类直接存放
  `.ipk` / `.apk` 插件包（兼容旧的 `.run` 自解压包，有 `.run` 时自动解压）

## 使用

在你的仓库 workflow 中引用：

```yaml
name: Build OpenWrt Firmware

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Build firmware
        id: build
        uses: MinimaxFlora/gh-action-imagebuilder@v7.3
        with:
          arch: x86-64            # 设备架构
          version: 25             # 24 或 25（自动检测官方最新版）
          profile: generic        # 设备 PROFILE
          rootfs_partsize: 2048   # 软件包空间（MB）
          lan_ip: 192.168.1.1     # 默认管理 IP
          root_password: ${{ secrets.ROOT_PASSWORD }}   # 可选：root 密码（留空则不设置）
          packages: luci-app-openclash luci-app-passwall   # 额外插件（空格分隔）

      - name: Upload firmware
        uses: MinimaxFlora/action-gh-release@v1.0
        with:
          files: ${{ steps.build.outputs.firmware_dir }}/**/*.img.gz
```

## 输入参数

| 参数 | 必填 | 默认值 | 说明 |
| ---- | ---- | ------ | ---- |
| `arch` | ✅ | `x86-64` | 目标设备架构：`x86-64` / `x86-generic` / `x86-geode` / `x86-legacy` / `rockchip-armv8` |
| `version` | ❌ | `24` | `24` 或 `25`（自动检测官方最新稳定版），也支持精确版本如 `24.10.8` |
| `profile` | ❌ | `generic` | 设备 PROFILE（如 `friendlyarm_nanopi-r4s`） |
| `rootfs_partsize` | ❌ | `2048` | 软件包分区大小（MB） |
| `lan_ip` | ❌ | `192.168.1.1` | 默认管理 IP（写入 uci-defaults） |
| `root_password` | ❌ | *(空)* | 固件 root 密码（首次启动生效）；留空保持默认空密码 |
| `packages` | ❌ | *(空)* | 额外插件，**空格分隔** |

## Secrets（密钥）

| Secret | 必填 | 说明 |
| ------ | ---- | ---- |
| `PPPOE_ACCOUNT` | ❌ | 宽带账号；**与 `PPPOE_PASSWORD` 同时设置才启用 PPPoE 拨号**，否则 WAN 保持 DHCP |
| `PPPOE_PASSWORD` | ❌ | 宽带密码 |

## 输出

| 输出 | 说明 |
| ---- | ---- |
| `firmware_dir` | 固件输出目录（`<workspace>/.imagebuilder/.../bin/targets`） |

## 首次启动自动配置（files/etc/uci-defaults/99-custom.sh）

构建时使用仓库内静态模板 + 占位符替换生成，设备**首次开机**自动执行：

- 默认管理 IP（`uci set network.lan.ipaddr`）
- root 密码（可选，`passwd root`）
- PPPoE 拨号（可选）
- 所有网口可访问网页终端 / SSH
- ZeroWrt 系统标识（openwrt_release / os-release）
- 主机名 `ZeroWrt`

## 第三方插件（Extras_Paclages）

插件仓库 [Extras_Paclages](https://github.com/MinimaxFlora/Extras_Paclages) 按分支 + 架构组织：

```
apk (25.x) / ipk (24.x)
├── x86_64/              # x86-64 架构 → 直接放 .ipk / .apk 插件包
├── aarch64_generic/     # rockchip armv8（如 nanopi R4S 等）
└── aarch64_cortex-a53/  # 其他 aarch64 设备
```

构建时自动导入与目标架构匹配的文件夹：

| 架构（arch 参数） | 导入文件夹 |
| ---------------- | ---------- |
| `x86-64` 等 x86 系 | `x86_64/` |
| `rockchip-armv8` | `aarch64_generic/` |

> 兼容性：分支内若存在 `.run` 自解压包，会自动解压（`--noexec` 只解压不执行脚本），
> 产物直接平铺在 `packages/` 根目录。

## 工作原理

1. 根据 `version` 自动检测 OpenWrt 官方最新稳定版（抓取 `downloads.openwrt.org/releases/` 目录）
2. 从官方下载对应架构的 `openwrt-imagebuilder-<版本>-<架构>.Linux-x86_64.tar.zst`
3. 解压 ImageBuilder
4. 复制静态文件：`files/etc/banner`（SSH 横幅）、`files/etc/uci-defaults/99-custom.sh`（占位符模板）
5. 克隆 Extras_Paclages 对应分支（24.x → `ipk`，25.x → `apk`）
6. 把架构同名文件夹内的 `.ipk` / `.apk` 包直接**移动**进 `packages/`（有 `.run` 则自动解压）
7. 25.x 自动生成 `packages.adb` 索引并关闭签名校验
8. `make image PROFILE=... PACKAGES=... FILES=... ROOTFS_PARTSIZE=...`

> 说明：ImageBuilder 直接从 OpenWrt 官方下载，官方发布新版本后无需任何手动维护，
> 自动检测并构建最新固件。

## 开发与测试

```bash
bash -n entrypoint.sh                       # 语法检查
# 本地模拟：
INPUT_ARCH=x86-64 INPUT_VERSION=25 \
GITHUB_WORKSPACE=/tmp/ws GITHUB_ACTION_PATH=$PWD \
bash entrypoint.sh
```

## 许可

[MIT](LICENSE)

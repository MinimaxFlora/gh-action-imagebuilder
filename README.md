# gh-action-imagebuilder

![GitHub license](https://img.shields.io/github/license/MinimaxFlora/gh-action-imagebuilder?style=flat-square)
![GitHub stars](https://img.shields.io/github/stars/MinimaxFlora/gh-action-imagebuilder?style=flat-square)
![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00A98F?style=flat-square&logo=openwrt&logoColor=white)
![Release](https://img.shields.io/badge/版本-v7.9-56d4dd?style=flat-square)

GitHub Composite Action：**从 OpenWrt 官方直接下载 ImageBuilder**（无需 Docker）构建定制化
OpenWrt 固件。自动检测 24.x / 25.x 最新稳定版，支持 Web 服务器选择、LuCI 主题定制、
预设默认管理 IP、root 密码、rootfs 空间、PPPoE 拨号、ZeroWrt 系统标识、
彩色 SSH 登录横幅以及第三方插件。

## 功能特性

- 📦 **免 Docker** — 直接从 [downloads.openwrt.org](https://downloads.openwrt.org/releases/)
  官方下载 `openwrt-imagebuilder` 压缩包，解压后直接在 runner 上 `make image`
- 🔄 **自动检测版本** — 设置 `24` 或 `25`，自动检测 OpenWrt 官方最新稳定版
  （如 v24.10.8 / v25.12.5），**无需手动维护版本号**
- 🖥️ **支持的架构**：`x86-64`、`x86-generic`、`x86-geode`、`x86-legacy`、`rockchip-armv8`
- 🌐 **Web 服务器可选** — `uhttpd`（默认，装 `luci`）或 `nginx`（装 `luci-nginx`
  并首启自动写入 nginx uci 配置）
- 🎨 **LuCI 主题可选** — 独立主题选项，6 个预设（`argon` / `kucat` / `aurora` / `design` / `shadcn` / `fluent`），
  默认 `argon`，自动映射对应主题包
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
- 🎨 **美化构建输出** — 彩色 ANSI banner + 构建参数面板 + 步骤日志高亮，
  自动显示版本号与作者信息

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
        uses: MinimaxFlora/gh-action-imagebuilder@v7.9
        with:
          arch: x86-64            # 设备架构
          version: 25             # 24 或 25（自动检测官方最新版）
          profile: generic        # 设备 PROFILE
          rootfs_partsize: 2048   # 软件包空间（MB）
          lan_ip: 192.168.1.1     # 默认管理 IP
          web_server: uhttpd      # uhttpd（默认）或 nginx
          theme: argon              # LuCI 主题预设：argon(默认)/kucat/aurora/design/shadcn/fluent
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
| `web_server` | ❌ | `uhttpd` | Web 服务器：`uhttpd`（默认，装 luci）或 `nginx`（装 luci-nginx + 首启 nginx 配置） |
| `theme` | ❌ | `argon` | LuCI 主题预设：`argon`（默认）/ `kucat` / `aurora` / `design` / `shadcn` / `fluent`，不设置或无效值默认 argon |
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

## Web 服务器选择（web_server）

| 值 | 安装包 | 首启配置 |
| -- | ------ | ------- |
| `uhttpd`（默认） | `luci` | 无（系统默认 uhttpd） |
| `nginx` | `luci-nginx` | 自动写入 nginx uci 配置：监听 80 / `[::]:80`，`conf.d/*.locations` 包含，关闭 access_log，`service nginx restart` |

> 💡 **自动切换**：`packages` 中包含 `quickfile`（如 `luci-app-quickfile` / `quickfile` /
> `luci-i18n-quickfile-zh-cn`）时，QuickFile 依赖 nginx，即使 `web_server` 选了 `uhttpd`
> 也会**自动切换为 nginx**，无需手动指定。

选 `nginx` 时，`99-custom.sh` 首启自动执行：

```sh
uci set nginx.global.uci_enable='true'
uci del nginx._lan
uci del nginx._redirect2ssl
uci add nginx server
uci rename nginx.@server[0]='_lan'
uci set nginx._lan.server_name='_lan'
uci add_list nginx._lan.listen='80 default_server'
uci add_list nginx._lan.listen='[::]:80 default_server'
uci add_list nginx._lan.include='conf.d/*.locations'
uci set nginx._lan.access_log='off; # logd openwrt'
uci commit nginx
service nginx restart
```

## LuCI 主题选择（theme）

仅支持以下预设（大小写不敏感，默认 `argon`，不设置或无效值回退 argon）：

| 预设值 | 安装包 |
| ------ | ------ |
| `argon`（默认） | `luci-theme-argon luci-i18n-argon-config-zh-cn` |
| `kucat` | `luci-theme-kucat luci-i18n-kucat-config-zh-cn` |
| `aurora` | `luci-theme-aurora luci-i18n-aurora-config-zh-cn` |
| `design` | `luci-theme-design` |
| `shadcn` | `luci-theme-shadcn` |
| `fluent` | `luci-theme-fluent luci-i18n-fluent-zh-cn` |

用法：`theme: argon` / `theme: kucat` / `theme: aurora` / `theme: design` / `theme: shadcn` / `theme: fluent`

## 首次启动自动配置（files/etc/uci-defaults/99-custom.sh）

构建时使用仓库内静态模板 + 占位符替换生成，设备**首次开机**自动执行：

- 默认管理 IP（`uci set network.lan.ipaddr`）
- root 密码（可选，`passwd root`）
- PPPoE 拨号（可选）
- nginx 配置（可选，web_server=nginx 时）
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
8. 组装软件包列表（默认包 + Web 服务器 + 主题 + 用户包）
9. `make image PROFILE=... PACKAGES=... FILES=... ROOTFS_PARTSIZE=...`

## 版本说明

- 通过 Git tag 管理版本（当前 `v7.9`），Firmware-Build 仓库引用 `@v7.9`
- 版本号在构建输出中自动显示（取自 `GITHUB_ACTION_REF`）

## License

MIT

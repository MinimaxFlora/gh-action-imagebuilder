# gh-action-imagebuilder

![GitHub release (latest by date)](https://img.shields.io/github/v/release/MomoFlora/gh-action-imagebuilder?style=flat-square)
![GitHub license](https://img.shields.io/github/license/MomoFlora/gh-action-imagebuilder?style=flat-square)

GitHub Composite Action：**直接下载 ImageBuilder 压缩包**（无需 Docker）构建定制化
OpenWrt 固件。自动检测本仓库最新 v24.x / v25.x release，支持预设默认管理 IP、
rootfs 空间大小、PPPoE 拨号以及第三方插件。

## 功能特性

- 📦 **免 Docker** — 从本仓库 release 下载官方 `openwrt-imagebuilder` 压缩包，
  解压后直接在 runner 上 `make image`，省去容器映射问题
- 🔄 **自动检测版本** — 设置 `24` 或 `25`，自动检测仓库最新 `v24.*` / `v25.*`
  release tag（如 v24.10.8 / v25.12.5）
- 🖥️ **支持的架构**（对应仓库 release 里的压缩包）：
  `x86-64`、`x86-generic`、`x86-geode`、`x86-legacy`、`rockchip-armv8`
- 🌐 **默认管理 IP** — 通过 `uci-defaults` 在首次启动自动写入
- 🔌 **PPPoE** — 从 secrets 读取账号密码自动配置拨号；不填则 WAN 保持 DHCP
- 📦 **第三方插件** — 从 [Extras_Paclages](https://github.com/MomoFlora/Extras_Paclages)
  自动导入（24.x → `ipk` 分支，25.x → `apk` 分支），支持 `.run` / `.ipk` / `.apk`

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
        uses: MomoFlora/gh-action-imagebuilder@master
        with:
          arch: x86-64            # 设备架构
          version: 25             # 24 或 25（自动检测最新 tag）
          profile: generic        # 设备 PROFILE
          rootfs_partsize: 2048   # 软件包空间（MB）
          lan_ip: 192.168.1.1     # 默认管理 IP
          packages: luci-app-openclash luci-app-passwall   # 额外插件（空格分隔）

      - name: Upload firmware
        uses: softprops/action-gh-release@v3
        with:
          files: ${{ steps.build.outputs.firmware_dir }}/**/*.img.gz
```

## 输入参数

| 参数 | 必填 | 默认值 | 说明 |
| ---- | ---- | ------ | ---- |
| `arch` | ✅ | `x86-64` | 目标设备架构：`x86-64` / `x86-generic` / `x86-geode` / `x86-legacy` / `rockchip-armv8` |
| `version` | ❌ | `24` | `24` 或 `25`（自动检测仓库最新 v24.* / v25.* tag），也支持精确版本如 `24.10.8` |
| `profile` | ❌ | `generic` | 设备 PROFILE（如 `friendlyarm_nanopi-r4s`） |
| `rootfs_partsize` | ❌ | `2048` | 软件包分区大小（MB） |
| `lan_ip` | ❌ | `192.168.1.1` | 默认管理 IP（写入 uci-defaults） |
| `pppoe_account` | ❌ | *(空)* | 宽带账号（建议走 secrets）；留空 WAN 保持 DHCP |
| `pppoe_password` | ❌ | *(空)* | 宽带密码（建议走 secrets） |
| `packages` | ❌ | *(空)* | 额外插件，**空格分隔** |

## 输出

| 输出 | 说明 |
| ---- | ---- |
| `firmware_dir` | 固件输出目录（`<workspace>/.imagebuilder/.../bin/targets`） |

## 工作原理

1. 根据 `version` 自动检测本仓库最新 release tag（v24.* / v25.*）
2. 从该 release 下载对应架构的 `openwrt-imagebuilder-<版本>-<架构>.Linux-x86_64.tar.zst`
3. 解压 ImageBuilder，写入 uci-defaults（LAN IP / PPPoE）
4. 克隆 Extras_Paclages 对应分支，导入第三方插件到 `packages/`
5. `.run` 自动解包；25.x 自动生成 `packages.adb` 索引并关闭签名校验
6. `make image PROFILE=... PACKAGES=... FILES=... ROOTFS_PARTSIZE=...`

> 说明：release 资产由本仓库维护（官方 downloads.openwrt.org 预打包），
> 因此构建不依赖 Docker，也不需要运行时拉取大镜像。

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

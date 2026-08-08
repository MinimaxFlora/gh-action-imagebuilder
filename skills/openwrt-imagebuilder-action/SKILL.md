---
name: openwrt-imagebuilder-action
description: "MinimaxFlora/gh-action-imagebuilder 固件构建 action：机制、输入参数、OpenClash 内核内置与 tag/release 维护流程"
---

# OpenWrt ImageBuilder Action（gh-action-imagebuilder）

仓库: https://github.com/MinimaxFlora/gh-action-imagebuilder
作用: GitHub Composite Action，免 Docker，从 OpenWrt 官方直下 ImageBuilder 构建定制化固件。
Firmware-Build 仓库通过 `uses: MinimaxFlora/gh-action-imagebuilder@v7.3` 调用它。

## 核心机制

### 版本 → 包格式（互斥）
- `version` 输入（'24' 或 '25'）决定插件源分支和包扩展名：
  - 24.x → SRC_BRANCH=`ipk` → EXPECTED_EXT=`.ipk`（Extras_Paclages 的 ipk 分支）
  - 25.x → SRC_BRANCH=`apk` → EXPECTED_EXT=`.apk`（apk 分支）
- 架构文件夹（PKG_FOLDER）内容直接 `mv` 进 packages/，有 `.run` 自解压包才用 `--noexec` 解压
- 25.x 需手动生成 `packages.adb` EC 签名索引（官方 mkndx 在 25.12 ImageBuilder 静默失败，issue #23154）

### inputs（action.yml）
| 参数 | 默认 | 说明 |
|---|---|---|
| arch | x86-64 | x86-64 / x86-generic / x86-geode / x86-legacy / rockchip-armv8 |
| version | 24 | '24'/'25' 自动检测最新 tag，也接受精确版如 24.10.8 |
| profile | generic | make image PROFILE=...，如 friendlyarm_nanopi-r4s |
| rootfs_partsize | 2048 | rootfs 分区 MB |
| lan_ip | 192.168.1.1 | 默认管理 IP（uci-defaults 写入） |
| packages | (空) | 额外软件包，空格分隔，如 'luci-app-openclash luci-app-passwall' |
| pppoe_account / pppoe_password | (空) | 都填则 WAN 配 PPPoE，否则 DHCP |
| root_password | (空) | root 密码（首次开机 uci-defaults 设置） |

输出: `firmware_dir` → `<workspace>/.imagebuilder/bin/targets`

### 静态文件（照 banner 模式）
- `files/etc/banner` — SSRIP 彩色横幅
- `files/etc/uci-defaults/99-custom.sh` — 模板+占位符（LAN IP/PPPoE/root 密码/ttyd/dropbear/ZeroWrt 标识/主机名/腾讯云换源/Extras_Paclages 源写入）
- 源配置只写源列表**不执行 update**（首次开机网络未就绪）
- 密钥按版本 cp：25→`files/etc/apk/keys/key-build.pem`，24→`files/etc/opkg/keys/key-build.pub`

### DEFAULT_PACKAGES
`-dnsmasq -apk-mbedtls -libustream-mbedtls dnsmasq-full apk-openssl libustream-openssl luci luci-compat ip-full kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn luci-i18n-ttyd-zh-cn`

## OpenClash 内核自动内置（6.5 节）
PACKAGES 含 `luci-app-openclash` 时：
- mkdir `files/etc/openclash/core`，按架构下载 mihomo 内核：
  - x86-64 → `.../core/master/meta/clash-linux-amd64-v1.tar.gz`（**注意 arm64 不是 -v1**）
  - rockchip → `.../core/master/meta/clash-linux-arm64.tar.gz`
- `wget -qO- URL | tar xOvz > files/etc/openclash/core/clash_meta` + chmod +x
- 下载 GeoIP.dat / GeoSite.dat（Loyalsoldier/v2ray-rules-dat latest）到 files/etc/openclash/

## 代码风格约定
- 段落注释：`# ----` 分隔线 + 标题 + 说明
- 日志统一 `>>` 前缀，warning 用 `::warning::`
- if/then/else/fi 判断，不用 `&&` 链式（用户明确要求风格统一）

## 维护流程
1. 本地 clone: `/tmp/gh-action-imagebuilder`（master）
2. 改完 entrypoint.sh → `bash -n` 验证 → 提交（身份 `MinimaxFlora <zj18139624826@gmail.com>`）→ push
3. 更新 tag（Firmware-Build 引用 @v7.3）:
   ```
   git push origin --delete refs/tags/v7.3
   git tag -f -a v7.3 -m "..." <sha> && git push origin v7.3
   ```
4. 更新 Release（**注意：之前 v7.3 release 曾是 draft 状态导致页面看不到**）:
   - 用 Python + /tmp/gh_token.txt 调 API PATCH `releases/{id}`，`draft: false`
   - body 用文件写入避免 bash 吞反引号（python3 -c 里嵌 yaml 代码块会被 bash 展开 → 用 write 工具写 body 文件再读）

## 版本历史
- v7.0/7.1/7.2: 免 Docker / 版本→格式检测 / 插件 mv + .run 解压 / apk 索引
- v7.3 (ef59789): luci-compat + OpenClash 内核内置 + 风格统一

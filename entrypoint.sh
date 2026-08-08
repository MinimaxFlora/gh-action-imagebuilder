#!/usr/bin/env bash
# =============================================================================
#  Build OpenWrt firmware with a downloaded ImageBuilder tarball
# -----------------------------------------------------------------------------
#  No Docker involved: the official openwrt-imagebuilder tarball is downloaded
#  from this repository's release assets and built directly on the runner.
#
#  Steps:
#    1.  Validate inputs
#    2.  Resolve the OpenWrt release version (auto-detect latest v24.x / v25.x tag)
#    3.  Download & extract the ImageBuilder tarball
#    4.  Prepare the workspace (files / packages)
#    5.  Generate first-boot uci-defaults (LAN IP / PPPoE)
#    6.  Import third-party packages (.run / .ipk / .apk) into packages/
#    7.  Assemble the package list (defaults + user packages)
#    8.  make image
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Inputs (injected as environment variables by action.yml)
# -----------------------------------------------------------------------------
ARCH="${INPUT_ARCH:-x86-64}"
VERSION="${INPUT_VERSION:-24}"                  # 24 / 25 (series) or exact X.Y.Z
PROFILE="${INPUT_PROFILE:-generic}"
ROOTFS_PARTSIZE="${INPUT_ROOTFS_PARTSIZE:-2048}"
LAN_IP="${INPUT_LAN_IP:-192.168.1.1}"
PPPOE_ACCOUNT="${INPUT_PPPOE_ACCOUNT:-}"
PPPOE_PASSWORD="${INPUT_PPPOE_PASSWORD:-}"
USER_PACKAGES="${INPUT_PACKAGES:-}"

WORKSPACE="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
ACTION_PATH="${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"

# OpenWrt 官方下载源
OPENWRT_DL="https://downloads.openwrt.org/releases"

# 架构别名（其余架构直接用原名）
declare -A IB_ARCH=(
  [x86]="x86-64"
  [rockchip]="rockchip-armv8"
)
IB_PREFIX="${IB_ARCH[$ARCH]:-$ARCH}"

# ImageBuilder 官方目录：IB_PREFIX -> target/subtarget
# 官方 URL 形如 .../targets/<target>/<subtarget>/openwrt-imagebuilder-<ver>-<target>-<subtarget>.Linux-x86_64.tar.zst
declare -A IB_TARGET=(
  [x86-64]="x86/64"
  [x86-generic]="x86/generic"
  [x86-geode]="x86/geode"
  [x86-legacy]="x86/legacy"
  [rockchip-armv8]="rockchip/armv8"
)
IB_SUBDIR="${IB_TARGET[$IB_PREFIX]:-$IB_PREFIX}"

# 第三方插件仓库内的架构文件夹名
declare -A PKG_DIR=(
  [x86]="x86_64"
  [x86-64]="x86_64"
  [x86-generic]="x86_64"
  [x86-geode]="x86_64"
  [x86-legacy]="x86_64"
  [rockchip]="aarch64_generic"                # nanopi 等均为 aarch64
  [rockchip-armv8]="aarch64_generic"
)
PKG_FOLDER="${PKG_DIR[$ARCH]:-$ARCH}"

echo "===================================================="
echo "  OpenWrt ImageBuilder Action"
echo "===================================================="
echo "  arch        : ${ARCH} -> ${IB_PREFIX}"
echo "  version     : ${VERSION}"
echo "  profile     : ${PROFILE}"
echo "  rootfs size : ${ROOTFS_PARTSIZE} MB"
echo "  lan ip      : ${LAN_IP}"
echo "  pppoe       : $([[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]] && echo yes || echo no)"
echo "===================================================="

# -----------------------------------------------------------------------------
# 2. Resolve the OpenWrt release version
#    24 / 25 -> 自动检测 OpenWrt 官方最新 v24.* / v25.* 稳定版
#    X.Y.Z   -> 固定版本
# -----------------------------------------------------------------------------
detect_latest() {
  local series="$1"   # 24 或 25
  curl -s --connect-timeout 15 "${OPENWRT_DL}/" \
    | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
    | grep -oE "${series}\.[0-9]+\.[0-9]+" \
    | sort -V | tail -1
}

if [[ "${VERSION}" =~ ^(24|25)$ ]]; then
  echo ">> 自动检测 OpenWrt v${VERSION}.* 系列最新稳定版..."
  LATEST="$(detect_latest "${VERSION}")"
  if [[ -n "${LATEST}" ]]; then
    VERSION="${LATEST}"
    echo ">> 检测到最新版本: ${VERSION}"
  else
    echo "::error::未检测到 OpenWrt v${VERSION}.* 系列版本，请检查官方源 ${OPENWRT_DL}/"
    exit 1
  fi
fi

# 第三方插件分支：24.x -> ipk，25.x -> apk
if [[ "${VERSION}" == 25* ]]; then
  SRC_BRANCH="apk"
else
  SRC_BRANCH="ipk"
fi

# -----------------------------------------------------------------------------
# 3. Download & extract the ImageBuilder tarball from openwrt.org
# -----------------------------------------------------------------------------
TARBALL="openwrt-imagebuilder-${VERSION}-${IB_PREFIX}.Linux-x86_64.tar.zst"
URL="${OPENWRT_DL}/${VERSION}/targets/${IB_SUBDIR}/${TARBALL}"

IB_DIR="${WORKSPACE}/.imagebuilder"
rm -rf "${IB_DIR}"
mkdir -p "${IB_DIR}/files/etc/uci-defaults"

echo ">> 下载 ImageBuilder: ${URL}"
curl -fL --connect-timeout 20 -o "${IB_DIR}/imagebuilder.tar.zst" "${URL}"

echo ">> 解压 ImageBuilder..."
tar --zstd -xf "${IB_DIR}/imagebuilder.tar.zst" -C "${IB_DIR}"
rm -f "${IB_DIR}/imagebuilder.tar.zst"

IB_ROOT="$(find "${IB_DIR}" -maxdepth 1 -type d -name 'openwrt-imagebuilder-*' | head -1)"
if [[ -z "${IB_ROOT}" ]]; then
  echo "::error::ImageBuilder 解压失败，未找到 openwrt-imagebuilder-* 目录"
  exit 1
fi
echo ">> ImageBuilder 目录: ${IB_ROOT}"

# 第三方软件包目录必须 = ImageBuilder 的 PACKAGE_DIR（Makefile: PACKAGE_DIR:=$(TOPDIR)/packages），
# 即 ${IB_ROOT}/packages。若放到 IB_DIR/packages（IB_ROOT 的兄弟目录），
# make image 完全读不到，apk/opkg 会报 "unable to select packages"。
PKG_DIR_PATH="${IB_ROOT}/packages"
mkdir -p "${PKG_DIR_PATH}"

# runner 用户接管目录权限（tar 内 owner 为 1000）
sudo chown -R "$(id -u):$(id -g)" "${IB_ROOT}" "${IB_DIR}/files" "${PKG_DIR_PATH}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. First-boot uci-defaults (LAN IP / PPPoE / 系统配置)
# -----------------------------------------------------------------------------
UCI_SCRIPT="${IB_DIR}/files/etc/uci-defaults/99-custom.sh"

# 可选片段：默认管理地址（多行字符串，heredoc 展开时保留真实换行）
LAN_BLOCK=""
if [[ -n "${LAN_IP}" ]]; then
  LAN_BLOCK="uci set network.lan.ipaddr='${LAN_IP}'
uci set network.lan.netmask='255.255.255.0'"
fi

# 可选片段：PPPoE 拨号
PPPOE_BLOCK=""
if [[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]]; then
  PPPOE_BLOCK="uci set network.wan.proto='pppoe'
uci set network.wan.username='${PPPOE_ACCOUNT}'
uci set network.wan.password='${PPPOE_PASSWORD}'"
fi

# ANSI 转义（SSH 横幅用）
ESC=$'\033'

# 一次性生成完整 uci-defaults 脚本（可选片段为空时自动跳过）
cat > "${UCI_SCRIPT}" <<EOF
#!/bin/sh
# Generated by gh-action-imagebuilder

${LAN_BLOCK}

${PPPOE_BLOCK}

uci commit network

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置系统标识（ZeroWrt 版本信息）
FILE_PATH="/etc/openwrt_release"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='ZeroWrt-\$(date +%Y%m%d)'/g" "\$FILE_PATH"
sed -i "s/DISTRIB_REVISION='[^']*'/DISTRIB_REVISION=' By MinimaxFlora'/g" "\$FILE_PATH"
sed -i "s|^OPENWRT_RELEASE=\".*\"|OPENWRT_RELEASE=\"ZeroWrt 标准版 @R\$(date +%Y%m%d) BY MinimaxFlora\"|" /usr/lib/os-release

# 设置主机名
uci set system.@system[0].hostname='ZeroWrt'
uci commit system

# 设置 SSH 登录横幅（ANSI 彩色，首次启动生成）
cat > /etc/banner <<'BANNER'
${ESC}[1;34m
${ESC}[1;34m███████╗███████╗██████╗ ██████╗ ██╗ ██╗██████╗ ████████╗${ESC}[0m
${ESC}[1;36m╚══███╔╝██╔════╝██╔══██╗██╔═══██╗██║ ██║██╔══██╗╚══██╔══╝${ESC}[0m
${ESC}[1;36m ███╔╝ █████╗ ██████╔╝██║ ██║██║ █╗ ██║██████╔╝ ██║${ESC}[0m
${ESC}[1;33m ███╔╝ ██╔══╝ ██╔══██╗██║ ██║██║███╗██║██╔══██╗ ██║${ESC}[0m
${ESC}[1;33m███████╗███████╗██║ ██║╚██████╔╝╚███╔███╔╝██║ ██║ ██║${ESC}[0m
${ESC}[1;33m╚══════╝╚══════╝╚═╝ ╚═╝ ╚═════╝ ╚══╝╚══╝ ╚═╝ ╚═╝ ╚═╝${ESC}[0m
${ESC}[1;33m Open Source · Tailored Experience · High Performance${ESC}[0m
${ESC}[0;37m────────────────────────────────────────────────────────────${ESC}[0m
BANNER

exit 0
EOF
chmod +x "${UCI_SCRIPT}"

if [[ -n "${LAN_IP}" ]]; then
  echo ">> 已写入默认管理地址 ${LAN_IP}"
fi
if [[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]]; then
  echo ">> 已写入 PPPoE 拨号配置"
fi
echo ">> 已写入 SSH 登录横幅 /etc/banner"

# -----------------------------------------------------------------------------
# 5. Import third-party packages into packages/
#    克隆 Extras_Paclages 对应分支，把架构同名文件夹（如 x86_64）内的文件
#    移动进 packages/ 根目录；再检测 packages/ 全部内容：
#    有 .run 则执行解压，否则无需处理直接使用
# -----------------------------------------------------------------------------
git clone --depth=1 --branch "${SRC_BRANCH}" \
  "https://github.com/MinimaxFlora/Extras_Paclages.git" "${IB_DIR}/pkg-repo" 2>/dev/null || true

SRC_ARCH_DIR="${IB_DIR}/pkg-repo/${PKG_FOLDER}"
if [ -d "${SRC_ARCH_DIR}" ]; then
  mv -f "${SRC_ARCH_DIR}"/* "${PKG_DIR_PATH}/" 2>/dev/null || true
  echo ">> 已移动 ${PKG_FOLDER} 架构第三方软件包 (${SRC_BRANCH} 分支) 到 packages/:"
  ls -1 "${PKG_DIR_PATH}" | sed 's/^/     - /' || true
else
  echo "::warning::Extras_Paclages ${SRC_BRANCH} 分支中未找到 ${PKG_FOLDER} 架构目录"
fi

# ---- 包格式由版本决定：24.x -> ipk，25.x -> apk（互斥，不会同时出现）----
EXPECTED_EXT=".${SRC_BRANCH}"

# ---- 检测 packages/ 目录下全部内容：.run / 期望格式包 ----
shopt -s nullglob
RUN_FILES=( "${PKG_DIR_PATH}"/*.run )
PKG_FILES=( "${PKG_DIR_PATH}"/*"${EXPECTED_EXT}" )
shopt -u nullglob

echo ">> packages/ 内容检测: ${#RUN_FILES[@]} 个 .run | ${#PKG_FILES[@]} 个 ${EXPECTED_EXT}"

# ---- 有 .run 才执行解压；否则文件已就位，直接使用 ----
if (( ${#RUN_FILES[@]} > 0 )); then
  echo ">> 检测到 .run 安装包，开始解压..."
  for f in "${RUN_FILES[@]}"; do
    chmod +x "$f"
    if "$f" --noexec --keep --target "${PKG_DIR_PATH}/" >/dev/null 2>&1; then
      rm -f "$f"
      echo ">> 已解压: ${f##*/}"
    else
      echo "::warning::解包失败: ${f}"
    fi
  done

  # 解压后重新扫描：解压出的 .ipk/.apk 同样参与后续处理（apk 索引生成）
  # 注：真实 .run 内容平铺在目标目录（packages/ 根），不会出现子目录
  shopt -s nullglob
  PKG_FILES=( "${PKG_DIR_PATH}"/*"${EXPECTED_EXT}" )
  shopt -u nullglob
else
  echo ">> 未检测到 .run，无需解压，${EXPECTED_EXT} 包直接使用"
fi

# -----------------------------------------------------------------------------
# 6. Assemble the package list
# -----------------------------------------------------------------------------
DEFAULT_PACKAGES=(
  "-dnsmasq"
  "dnsmasq-full"
  "luci"
  "ip-full"
  "kmod-tun"
  "kmod-inet-diag"
  "kmod-nft-tproxy"
  "luci-i18n-base-zh-cn"
  "luci-i18n-firewall-zh-cn"
  "luci-i18n-package-manager-zh-cn"
  "luci-i18n-ttyd-zh-cn"
)
PACKAGES="${DEFAULT_PACKAGES[*]}"
if [[ -n "${USER_PACKAGES}" ]]; then
  PACKAGES="${PACKAGES} ${USER_PACKAGES}"
fi
echo ">> 最终软件包列表:"
echo "    ${PACKAGES}"

# -----------------------------------------------------------------------------
# 7. OpenWrt 25.x (apk)：生成 packages.adb 索引并关闭签名校验
#    25.12 ImageBuilder 内部 mkndx 静默失败（官方 issue #23154），
#    必须手动生成，否则 apk 报 "unable to select packages"。
# -----------------------------------------------------------------------------
if [[ "${EXPECTED_EXT}" == ".apk" ]] && (( ${#PKG_FILES[@]} > 0 )); then
  echo ">> 检测到 ${#PKG_FILES[@]} 个第三方 .apk 包，准备 apk 索引..."
  # ImageBuilder 自带 host apk 工具
  APK_BIN="${IB_ROOT}/staging_dir/host/bin/apk"
  if [ ! -x "$APK_BIN" ]; then
    APK_BIN="$(command -v apk 2>/dev/null || true)"
  fi
  if [ -n "$APK_BIN" ] && [ -x "$APK_BIN" ]; then
    # 关闭签名校验（25.x .config 默认 CONFIG_SIGNATURE_CHECK=y）
    if [ -f "${IB_ROOT}/.config" ]; then
      sed -i 's/^CONFIG_SIGNATURE_CHECK=.*/CONFIG_SIGNATURE_CHECK=/' "${IB_ROOT}/.config" 2>/dev/null || true
      echo ">> 已关闭 CONFIG_SIGNATURE_CHECK"
    fi
    # 手动生成未签名索引
    if (cd "${PKG_DIR_PATH}" && "$APK_BIN" mkndx --allow-untrusted --output packages.adb *.apk) >/dev/null 2>&1; then
      echo ">> 已生成 packages/packages.adb（未签名索引）"
    else
      echo "::warning::apk 索引生成失败，第三方包可能无法安装"
    fi
  else
    echo "::warning::未找到 apk 工具，跳过索引生成"
  fi
fi

# -----------------------------------------------------------------------------
# 8. Build the firmware
# -----------------------------------------------------------------------------
cd "${IB_ROOT}"
make image \
  PROFILE="${PROFILE}" \
  PACKAGES="${PACKAGES}" \
  FILES="${IB_DIR}/files" \
  ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}"

echo "================================================"
echo "  Build completed successfully"
echo "================================================"

# -----------------------------------------------------------------------------
# 9. Expose outputs
# -----------------------------------------------------------------------------
FIRMWARE_DIR="${IB_ROOT}/bin/targets"
echo "firmware_dir=${FIRMWARE_DIR}" >> "${GITHUB_OUTPUT}"

echo ">> 固件输出目录: ${FIRMWARE_DIR}"
find "${FIRMWARE_DIR}" -type f \( -name "*.bin" -o -name "*.img*" -o -name "*.gz" -o -name "*.tar" -o -name "*.iso" -o -name "*.qcow2" -o -name "*.vmdk" -o -name "*.manifest" \) 2>/dev/null | sed 's/^/     /' || true

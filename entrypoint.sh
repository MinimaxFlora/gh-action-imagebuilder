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
# 0. ANSI colors + action info
# -----------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_GREEN='\033[32m'
C_CYAN='\033[36m'
C_YELLOW='\033[33m'
C_MAGENTA='\033[35m'
C_RED='\033[31m'
C_BG_BLUE='\033[44m'

ACTION_NAME="gh-action-imagebuilder"
ACTION_AUTHOR="MinimaxFlora"
ACTION_REF="${GITHUB_ACTION_REF:-refs/heads/main}"
ACTION_VERSION="${ACTION_REF##*/}"          # refs/tags/v7.3 -> v7.3
[[ "${ACTION_VERSION}" == "main" ]] && ACTION_VERSION="dev"

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
ROOT_PASSWORD="${INPUT_ROOT_PASSWORD:-}"
USER_PACKAGES="${INPUT_PACKAGES:-}"
WEB_SERVER="${INPUT_WEB_SERVER:-uhttpd}"          # uhttpd / nginx
THEME="${INPUT_THEME:-luci-theme-argon luci-i18n-argon-config-zh-cn}"

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

echo ""
echo -e "  ${C_CYAN}${C_BOLD}◆ OpenWrt ImageBuilder${C_RESET}"
echo -e "  ${C_DIM}${ACTION_NAME} · v${ACTION_VERSION} · ${ACTION_AUTHOR}${C_RESET}"
echo ""
echo -e "  ${C_GREEN}${C_BOLD}构建参数${C_RESET}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s\n" "架构" "${ARCH} → ${IB_PREFIX}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s\n" "版本" "${VERSION}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s\n" "profile" "${PROFILE}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s MB\n" "rootfs" "${ROOTFS_PARTSIZE}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s\n" "LAN IP" "${LAN_IP}"
printf "  ${C_YELLOW}%-10s${C_RESET} %s\n" "PPPoE" "$([[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]] && echo yes || echo no)"
echo ""

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
  echo -e "${C_CYAN}>>${C_RESET} 自动检测 OpenWrt v${VERSION}.* 系列最新稳定版..."
  LATEST="$(detect_latest "${VERSION}")"
  if [[ -n "${LATEST}" ]]; then
    VERSION="${LATEST}"
    echo -e "${C_CYAN}>>${C_RESET} 检测到最新版本: ${VERSION}"
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

echo -e "${C_CYAN}>>${C_RESET} 下载 ImageBuilder: ${URL}"
curl -fL --connect-timeout 20 -o "${IB_DIR}/imagebuilder.tar.zst" "${URL}"

echo -e "${C_CYAN}>>${C_RESET} 解压 ImageBuilder..."
tar --zstd -xf "${IB_DIR}/imagebuilder.tar.zst" -C "${IB_DIR}"
rm -f "${IB_DIR}/imagebuilder.tar.zst"

IB_ROOT="$(find "${IB_DIR}" -maxdepth 1 -type d -name 'openwrt-imagebuilder-*' | head -1)"
if [[ -z "${IB_ROOT}" ]]; then
  echo "::error::ImageBuilder 解压失败，未找到 openwrt-imagebuilder-* 目录"
  exit 1
fi
echo -e "${C_CYAN}>>${C_RESET} ImageBuilder 目录: ${IB_ROOT}"

# 第三方软件包目录必须 = ImageBuilder 的 PACKAGE_DIR（Makefile: PACKAGE_DIR:=$(TOPDIR)/packages），
# 即 ${IB_ROOT}/packages。若放到 IB_DIR/packages（IB_ROOT 的兄弟目录），
# make image 完全读不到，apk/opkg 会报 "unable to select packages"。
PKG_DIR_PATH="${IB_ROOT}/packages"
mkdir -p "${PKG_DIR_PATH}"

# runner 用户接管目录权限（tar 内 owner 为 1000）
sudo chown -R "$(id -u):$(id -g)" "${IB_ROOT}" "${IB_DIR}/files" "${PKG_DIR_PATH}" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. First-boot uci-defaults (LAN IP / PPPoE / root 密码) + SSH 登录横幅
#    使用仓库内静态模板：files/etc/uci-defaults/99-custom.sh（占位符替换）
#    与静态横幅：files/etc/banner（参考 immortalwrt-mt798x 原版）
# -----------------------------------------------------------------------------

# 可选片段：默认管理地址
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

# 可选片段：root 密码（为空则不设置，保持默认空密码）
ROOT_PW_BLOCK=""
if [[ -n "${ROOT_PASSWORD}" ]]; then
  ROOT_PW_SAFE="$(printf '%s' "${ROOT_PASSWORD}" | sed "s/'/'\\''/g")"
  ROOT_PW_BLOCK="ROOT_PASSWORD='${ROOT_PW_SAFE}'
(echo \"\$ROOT_PASSWORD\"; sleep 1; echo \"\$ROOT_PASSWORD\") | passwd root"
fi

# 可选片段：nginx Web 服务器（WEB_SERVER=nginx 时启用，否则留空）
NGINX_BLOCK=""
if [[ "${WEB_SERVER}" == "nginx" ]]; then
  NGINX_BLOCK="# nginx
uci set nginx.global.uci_enable='true'
uci del nginx._lan
uci del nginx._redirect2ssl
uci add nginx server
uci rename nginx.@server[0]='_lan'
uci set nginx._lan.server_name='_lan'
uci add_list nginx._lan.listen='80 default_server'
uci add_list nginx._lan.listen='[::]:80 default_server'
#uci add_list nginx._lan.include='restrict_locally'
uci add_list nginx._lan.include='conf.d/*.locations'
uci set nginx._lan.access_log='off; # logd openwrt'
uci commit nginx
service nginx restart"
fi

# 从模板生成 99-custom.sh（Python 做占位符替换，避免多行 sed 转义问题）
UCI_SCRIPT="${IB_DIR}/files/etc/uci-defaults/99-custom.sh"
python3 - "${ACTION_PATH}/files/etc/uci-defaults/99-custom.sh" "${UCI_SCRIPT}" \
  "${LAN_BLOCK}" "${PPPOE_BLOCK}" "${ROOT_PW_BLOCK}" "${NGINX_BLOCK}" <<'PYEOF'
import sys
tmpl, out, lan, pppoe, rootpw, nginx = sys.argv[1:7]
content = open(tmpl, encoding='utf-8').read()
content = content.replace('__LAN_BLOCK__', lan)
content = content.replace('__PPPOE_BLOCK__', pppoe)
content = content.replace('__ROOT_PW_BLOCK__', rootpw)
content = content.replace('__NGINX_BLOCK__', nginx)
open(out, 'w', encoding='utf-8').write(content)
PYEOF
chmod +x "${UCI_SCRIPT}"

# SSH 登录横幅：静态文件直接复制进 files/etc/banner
cp -f "${ACTION_PATH}/files/etc/banner" "${IB_DIR}/files/etc/banner"

# 签名密钥：按版本 cp 到 ImageBuilder 的 files 对应位置（源在仓库 files/ 下，与 banner 同模式）
if [[ "${SRC_BRANCH}" == "apk" ]]; then
  mkdir -p "${IB_DIR}/files/etc/apk/keys"
  cp -f "${ACTION_PATH}/files/etc/apk/keys/key-build.pem" "${IB_DIR}/files/etc/apk/keys/key-build.pem"
  echo -e "${C_CYAN}>>${C_RESET} 已预置 apk 签名密钥 (25.x): /etc/apk/keys/key-build.pem"
else
  mkdir -p "${IB_DIR}/files/etc/opkg/keys"
  cp -f "${ACTION_PATH}/files/etc/opkg/keys/key-build.pub" "${IB_DIR}/files/etc/opkg/keys/key-build.pub"
  echo -e "${C_CYAN}>>${C_RESET} 已预置 ipk 签名密钥 (24.x): /etc/opkg/keys/key-build.pub"
fi

if [[ -n "${LAN_IP}" ]]; then
  echo -e "${C_CYAN}>>${C_RESET} 已写入默认管理地址 ${LAN_IP}"
fi
if [[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]]; then
  echo -e "${C_CYAN}>>${C_RESET} 已写入 PPPoE 拨号配置"
fi
if [[ -n "${ROOT_PASSWORD}" ]]; then
  echo -e "${C_CYAN}>>${C_RESET} 已写入 root 密码（首次启动生效）"
fi
echo -e "${C_CYAN}>>${C_RESET} 已写入 SSH 登录横幅 /etc/banner"

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
  echo -e "${C_CYAN}>>${C_RESET} 已移动 ${PKG_FOLDER} 架构第三方软件包 (${SRC_BRANCH} 分支) 到 packages/:"
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

echo -e "${C_CYAN}>>${C_RESET} packages/ 内容检测: ${#RUN_FILES[@]} 个 .run | ${#PKG_FILES[@]} 个 ${EXPECTED_EXT}"

# ---- 有 .run 才执行解压；否则文件已就位，直接使用 ----
if (( ${#RUN_FILES[@]} > 0 )); then
  echo -e "${C_CYAN}>>${C_RESET} 检测到 .run 安装包，开始解压..."
  for f in "${RUN_FILES[@]}"; do
    chmod +x "$f"
    if "$f" --noexec --keep --target "${PKG_DIR_PATH}/" >/dev/null 2>&1; then
      rm -f "$f"
      echo -e "${C_CYAN}>>${C_RESET} 已解压: ${f##*/}"
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
  echo -e "${C_CYAN}>>${C_RESET} 未检测到 .run，无需解压，${EXPECTED_EXT} 包直接使用"
fi

# -----------------------------------------------------------------------------
# 6. Assemble the package list
#    - Web server: uhttpd(默认) -> luci；nginx -> luci-nginx
#    - 主题单独配置（默认 luci-theme-argon + 中文设置包）
# -----------------------------------------------------------------------------
# 基础默认包（不含 luci，由 WEB_SERVER 决定）
DEFAULT_PACKAGES=(
  "-dnsmasq"
  "-apk-mbedtls"
  "-libustream-mbedtls"
  "dnsmasq-full"
  "apk-openssl"
  "libustream-openssl"
  "luci-compat"
  "ip-full"
  "kmod-tun"
  "kmod-inet-diag"
  "kmod-nft-tproxy"
  "kmod-nft-socket"
  "luci-i18n-base-zh-cn"
  "luci-i18n-firewall-zh-cn"
  "luci-i18n-package-manager-zh-cn"
  "luci-i18n-ttyd-zh-cn"
)

# Web 服务器：uhttpd -> luci；nginx -> luci-nginx
if [[ "${WEB_SERVER}" == "nginx" ]]; then
  DEFAULT_PACKAGES+=( "luci-nginx" )
else
  DEFAULT_PACKAGES+=( "luci" )
fi

# 主题（单独选项，默认 argon；留空则跳过）
if [[ -n "${THEME}" ]]; then
  DEFAULT_PACKAGES+=( ${THEME} )
fi

PACKAGES="${DEFAULT_PACKAGES[*]}"
if [[ -n "${USER_PACKAGES}" ]]; then
  PACKAGES="${PACKAGES} ${USER_PACKAGES}"
fi
echo -e "${C_CYAN}>>${C_RESET} 最终软件包列表:"
echo "    ${PACKAGES}"

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# 6.5 若选择了 luci-app-openclash，则内置 mihomo 内核 + GeoIP/GeoSite 规则数据
# -----------------------------------------------------------------------------
if echo "${PACKAGES}" | grep -q "luci-app-openclash"; then
  echo -e "${C_CYAN}>>${C_RESET} 已选择 luci-app-openclash，内置 OpenClash 内核与规则数据"
  mkdir -p "${IB_DIR}/files/etc/openclash/core"

  # 按架构选择 mihomo 内核
  META_URL=""
  case "${ARCH}" in
    x86-*)
      META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
      ;;
    rockchip-*)
      META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
      ;;
    *)
      echo "::warning::不支持的架构 ${ARCH}，跳过 OpenClash 内核下载"
      ;;
  esac

  if [[ -n "${META_URL}" ]]; then
    echo -e "${C_CYAN}>>${C_RESET} 下载 mihomo 内核..."
    if wget -qO- "${META_URL}" | tar xOvz > "${IB_DIR}/files/etc/openclash/core/clash_meta" 2>/dev/null; then
      chmod +x "${IB_DIR}/files/etc/openclash/core/clash_meta"
      echo -e "${C_CYAN}>>${C_RESET} 内核: $(wc -c < "${IB_DIR}/files/etc/openclash/core/clash_meta") 字节"
    else
      echo "::warning::OpenClash 内核下载失败"
    fi
  fi

  # 下载 GeoIP / GeoSite 规则数据
  echo -e "${C_CYAN}>>${C_RESET} 下载 GeoIP / GeoSite 规则数据..."
  if wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "${IB_DIR}/files/etc/openclash/GeoIP.dat"; then
    echo -e "${C_CYAN}>>${C_RESET} GeoIP.dat: $(wc -c < "${IB_DIR}/files/etc/openclash/GeoIP.dat") 字节"
  else
    echo "::warning::GeoIP.dat 下载失败"
  fi
  if wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "${IB_DIR}/files/etc/openclash/GeoSite.dat"; then
    echo -e "${C_CYAN}>>${C_RESET} GeoSite.dat: $(wc -c < "${IB_DIR}/files/etc/openclash/GeoSite.dat") 字节"
  else
    echo "::warning::GeoSite.dat 下载失败"
  fi
fi

# -----------------------------------------------------------------------------
# 7. OpenWrt 25.x (apk)：生成 packages.adb 索引并关闭签名校验
#    25.12 ImageBuilder 内部 mkndx 静默失败（官方 issue #23154），
#    必须手动生成，否则 apk 报 "unable to select packages"。
# -----------------------------------------------------------------------------
if [[ "${EXPECTED_EXT}" == ".apk" ]] && (( ${#PKG_FILES[@]} > 0 )); then
  echo -e "${C_CYAN}>>${C_RESET} 检测到 ${#PKG_FILES[@]} 个第三方 .apk 包，准备 apk 索引..."
  # ImageBuilder 自带 host apk 工具
  APK_BIN="${IB_ROOT}/staging_dir/host/bin/apk"
  if [ ! -x "$APK_BIN" ]; then
    APK_BIN="$(command -v apk 2>/dev/null || true)"
  fi
  if [ -n "$APK_BIN" ] && [ -x "$APK_BIN" ]; then
    # 关闭签名校验（25.x .config 默认 CONFIG_SIGNATURE_CHECK=y）
    if [ -f "${IB_ROOT}/.config" ]; then
      sed -i 's/^CONFIG_SIGNATURE_CHECK=.*/CONFIG_SIGNATURE_CHECK=/' "${IB_ROOT}/.config" 2>/dev/null || true
      echo -e "${C_CYAN}>>${C_RESET} 已关闭 CONFIG_SIGNATURE_CHECK"
    fi
    # 手动生成未签名索引
    if (cd "${PKG_DIR_PATH}" && "$APK_BIN" mkndx --allow-untrusted --output packages.adb *.apk) >/dev/null 2>&1; then
      echo -e "${C_CYAN}>>${C_RESET} 已生成 packages/packages.adb（未签名索引）"
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

echo ""
echo -e "  ${C_GREEN}${C_BOLD}✅ Build completed successfully${C_RESET}"
echo -e "  ${C_DIM}${ACTION_NAME} · v${ACTION_VERSION} · ${ACTION_AUTHOR}${C_RESET}"
echo ""

# -----------------------------------------------------------------------------
# 9. Expose outputs
# -----------------------------------------------------------------------------
FIRMWARE_DIR="${IB_ROOT}/bin/targets"
echo "firmware_dir=${FIRMWARE_DIR}" >> "${GITHUB_OUTPUT}"

echo -e "${C_CYAN}>>${C_RESET} 固件输出目录: ${FIRMWARE_DIR}"
find "${FIRMWARE_DIR}" -type f \( -name "*.bin" -o -name "*.img*" -o -name "*.gz" -o -name "*.tar" -o -name "*.iso" -o -name "*.qcow2" -o -name "*.vmdk" -o -name "*.manifest" \) 2>/dev/null | sed 's/^/     /' || true

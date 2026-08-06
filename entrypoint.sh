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
REPO="MomoFlora/gh-action-imagebuilder"

# 架构别名（其余架构直接用原名，对应仓库 release 里的资产名）
declare -A IB_ARCH=(
  [x86]="x86-64"
  [rockchip]="rockchip-armv8"
)
IB_PREFIX="${IB_ARCH[$ARCH]:-$ARCH}"

# 第三方插件仓库内的架构文件夹名
declare -A PKG_DIR=(
  [x86]="x86_64"
  [rockchip]="aarch64_generic"                  # nanopi 等均为 aarch64
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
# 1b. Install build dependencies (ImageBuilder needs these on the runner)
# -----------------------------------------------------------------------------
echo ">> 安装构建依赖..."
sudo apt-get update -qq || true
sudo apt-get install -y -qq \
  build-essential file libncurses-dev zlib1g-dev gawk git \
  gettext libssl-dev xsltproc rsync wget unzip \
  python3 python3-setuptools \
  zstd || { echo "::warning::部分依赖安装失败，继续尝试构建"; }

# -----------------------------------------------------------------------------
# 2. Resolve the OpenWrt release version
#    24 / 25 -> 自动检测本仓库最新 v24.* / v25.* release tag
#    X.Y.Z   -> 固定版本
# -----------------------------------------------------------------------------
detect_latest() {
  local series="$1"   # 24 或 25
  curl -s --connect-timeout 15 \
    "https://api.github.com/repos/${REPO}/releases?per_page=100" -o /tmp/rel.json || true
  SERIES="${series}" python3 - <<'PYEOF'
import json, os, re
series = os.environ["SERIES"]
try:
    d = json.load(open("/tmp/rel.json"))
except Exception:
    print(""); raise SystemExit
vers = []
pat = re.compile(r'^v(' + series + r'\.\d+\.\d+)$')
for r in d:
    m = pat.match(r.get("tag_name", ""))
    if m:
        vers.append(m.group(1))
vers.sort(key=lambda v: [int(x) for x in v.split(".")])
print(vers[-1] if vers else "")
PYEOF
}

if [[ "${VERSION}" =~ ^(24|25)$ ]]; then
  echo ">> 自动检测 v${VERSION}.* 系列最新 release tag..."
  LATEST="$(detect_latest "${VERSION}")"
  if [[ -n "${LATEST}" ]]; then
    VERSION="${LATEST}"
    echo ">> 检测到最新版本: ${VERSION}"
  else
    echo "::error::未检测到 v${VERSION}.* 系列 release tag，请先在 ${REPO} 创建对应 release"
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
# 3. Download & extract the ImageBuilder tarball from this repo's release
# -----------------------------------------------------------------------------
TARBALL="openwrt-imagebuilder-${VERSION}-${IB_PREFIX}.Linux-x86_64.tar.zst"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL}"

IB_DIR="${WORKSPACE}/.imagebuilder"
rm -rf "${IB_DIR}"
mkdir -p "${IB_DIR}/files/etc/uci-defaults" "${IB_DIR}/packages"

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

# runner 用户接管目录权限（tar 内 owner 为 1000）
sudo chown -R "$(id -u):$(id -g)" "${IB_ROOT}" "${IB_DIR}/files" "${IB_DIR}/packages" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. First-boot uci-defaults (LAN IP / PPPoE)
# -----------------------------------------------------------------------------
UCI_SCRIPT="${IB_DIR}/files/etc/uci-defaults/99-custom.sh"
cat > "${UCI_SCRIPT}" <<EOF
#!/bin/sh
# Generated by gh-action-imagebuilder
EOF

if [[ -n "${LAN_IP}" ]]; then
  cat >> "${UCI_SCRIPT}" <<EOF
uci set network.lan.ipaddr='${LAN_IP}'
uci set network.lan.netmask='255.255.255.0'
EOF
  echo ">> 已写入默认管理地址 ${LAN_IP}"
fi

if [[ -n "${PPPOE_ACCOUNT}" && -n "${PPPOE_PASSWORD}" ]]; then
  cat >> "${UCI_SCRIPT}" <<EOF
uci set network.wan.proto='pppoe'
uci set network.wan.username='${PPPOE_ACCOUNT}'
uci set network.wan.password='${PPPOE_PASSWORD}'
EOF
  echo ">> 已写入 PPPoE 拨号配置"
fi

cat >> "${UCI_SCRIPT}" <<EOF
uci commit network

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by MomoFlora"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='\$NEW_DESCRIPTION'/" "\$FILE_PATH"

exit 0
EOF
chmod +x "${UCI_SCRIPT}"

# -----------------------------------------------------------------------------
# 5. Import third-party packages into packages/
#    分支内为 .run 自解压安装包（或直接的 .ipk/.apk），直接复制到 packages/ 根目录
# -----------------------------------------------------------------------------
git clone --depth=1 --branch "${SRC_BRANCH}" \
  "https://github.com/MomoFlora/Extras_Paclages.git" "${IB_DIR}/pkg-repo" 2>/dev/null || true

SRC_ARCH_DIR="${IB_DIR}/pkg-repo/${PKG_FOLDER}"
if [ -d "${SRC_ARCH_DIR}" ]; then
  cp -f "${SRC_ARCH_DIR}"/* "${IB_DIR}/packages/" 2>/dev/null || true
  echo ">> 已导入 ${PKG_FOLDER} 架构第三方软件包 (${SRC_BRANCH} 分支):"
  ls -1 "${IB_DIR}/packages" | sed 's/^/     - /' || true
else
  echo "::warning::Extras_Paclages ${SRC_BRANCH} 分支中未找到 ${PKG_FOLDER} 架构目录"
fi

# ---- 解包 .run 自解压安装包（makeself --noexec 只解压，不执行 install.sh）----
if ls "${IB_DIR}"/packages/*.run >/dev/null 2>&1; then
  echo ">> 解包第三方 .run 安装包..."
  for f in "${IB_DIR}"/packages/*.run; do
    chmod +x "$f"
    if "$f" --noexec --keep --target "${IB_DIR}/packages/" >/dev/null 2>&1; then
      rm -f "$f"
      echo ">> 已解包: ${f##*/}"
    else
      echo "::warning::解包失败: ${f}"
    fi
  done
fi

# 修复 apk 文件名与包内版本不一致的问题：
# 上游 .apk 包内版本用波浪号（26.218.16504~0aec5b1），文件名却是点号（26.218.16504.0aec5b1.apk），
# apk 按文件名匹配包时对不上，报 "package mentioned in index not found"。
for f in "${IB_DIR}"/packages/*.apk; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  new=$(printf "%s" "$base" | sed -E "s/-([0-9]+(\\.[0-9]+)+)\\.([0-9a-f]{6,})(-r[0-9]+)?\\.apk$/-\\1~\\3\\4.apk/")
  if [ "$new" != "$base" ]; then
    mv -f "$f" "${IB_DIR}/packages/$new"
    echo ">> 修正文件名: $base -> $new"
  fi
done

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
# 7. Build the firmware
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
# 8. Expose outputs
# -----------------------------------------------------------------------------
FIRMWARE_DIR="${IB_ROOT}/bin/targets"
echo "firmware_dir=${FIRMWARE_DIR}" >> "${GITHUB_OUTPUT}"

echo ">> 固件输出目录: ${FIRMWARE_DIR}"
find "${FIRMWARE_DIR}" -type f \( -name "*.bin" -o -name "*.img*" -o -name "*.gz" -o -name "*.tar" -o -name "*.iso" -o -name "*.qcow2" -o -name "*.vmdk" -o -name "*.manifest" \) 2>/dev/null | sed 's/^/     /' || true

#!/bin/sh
# JZPanel 一键安装脚本（install.sh，V2 引导）—— POSIX sh，永不含 Docker/发行版逻辑。
# 职责：验 root → 认架构 → 确保下载器 → 拉 jz-installer（版本化路径 + sidecar sha256）
#       → gunzip → 校验 sha256 → exec。见 docs/installer-v2-design.md §5。
#
# 用法：curl -fsSL https://download.jzpanel.com/install.sh | sh
#   可传参：... | sh -s -- install --docker=static --proxy http://127.0.0.1:7890

set -eu

INSTALLER_VERSION="2.0.0"
# 大文件跳 jsDelivr；bootstrap 只拉 jz-installer(~5MB)，可用 jsDelivr/GitHub 兜底
SOURCES="https://download.jzpanel.com https://cdn.jsdelivr.net/gh/jzpanel/download@main https://raw.githubusercontent.com/jzpanel/download/main"
LOG="/tmp/jzpanel_install.log"

log()  { printf '%s\n' "$*" | tee -a "$LOG"; }
die()  { log "[ERROR] $*"; exit 1; }

# 1. root
[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo）"

# 2. 架构
MACH="$(uname -m)"
case "$MACH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "不支持的 CPU 架构：$MACH（仅 amd64/arm64）" ;;
esac
log "[INFO] 架构: $MACH → $ARCH"

# 3. 下载器
if command -v curl >/dev/null 2>&1; then
  DL_CMD="curl -fsSL --connect-timeout 15 -o"
  # 老系统 TLS 兼容：失败再退让（下方逐源尝试时不加 -k，安全靠 sha256）
elif command -v wget >/dev/null 2>&1; then
  DL_CMD="wget -q -O"
else
  die "未找到 curl 或 wget"
fi

REL="installer/${INSTALLER_VERSION}/jz-installer-linux-${ARCH}.gz"
TMP_GZ="$(mktemp /tmp/jz-installer.XXXXXX.gz)"
TMP_BIN="$(mktemp /tmp/jz-installer.XXXXXX)"
SUM=""

fetch() { # fetch <url> <out>
  # shellcheck disable=SC2086
  $DL_CMD "$2" "$1" 2>>"$LOG"
}

# 4. 逐源拉 .gz 与 sidecar .sha256
download_installer() {
  for BASE in $SOURCES; do
    URL="${BASE}/${REL}"
    log "[INFO] 尝试下载安装器: $BASE"
    if fetch "$URL" "$TMP_GZ" && [ -s "$TMP_GZ" ]; then
      # sidecar sha256（同名 .sha256）；拿不到不阻断，但强烈建议存在
      if fetch "${URL}.sha256" "${TMP_GZ}.sha256" 2>/dev/null; then
        SUM="$(awk '{print $1; exit}' "${TMP_GZ}.sha256" 2>/dev/null || true)"
      fi
      return 0
    fi
  done
  return 1
}

# 老系统（如 CentOS 7 自带 2014 CA 包）缺新根证书，会导致对现代 HTTPS 站点 TLS 校验失败。
# 全部源失败时尝试更新系统 CA 证书再重试一次。
refresh_ca() {
  log "[INFO] 下载失败，尝试更新系统 CA 证书（老系统证书过期常见）..."
  if command -v yum >/dev/null 2>&1; then
    yum -y update ca-certificates >/dev/null 2>&1 || yum -y install ca-certificates >/dev/null 2>&1
    update-ca-trust extract >/dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get -y update >/dev/null 2>&1
    apt-get -y install --only-upgrade ca-certificates >/dev/null 2>&1 || apt-get -y install ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates >/dev/null 2>&1
    update-ca-certificates >/dev/null 2>&1
  fi
}

if ! download_installer; then
  refresh_ca
  download_installer || die "所有源均无法下载安装器，请检查网络（国内可设代理）"
fi

# 5. 校验 sha256（有 sidecar 才校验）
if [ -n "$SUM" ] && command -v sha256sum >/dev/null 2>&1; then
  ACT="$(sha256sum "$TMP_GZ" | awk '{print $1}')"
  [ "$ACT" = "$SUM" ] || die "安装器 sha256 校验失败（期望 $SUM 实际 $ACT）"
  log "[OK] 安装器校验通过"
else
  log "[WARN] 跳过 sha256 校验（无 sidecar 或无 sha256sum）"
fi

# 6. 解压
if command -v gunzip >/dev/null 2>&1; then
  gunzip -c "$TMP_GZ" > "$TMP_BIN"
elif command -v zcat >/dev/null 2>&1; then
  zcat "$TMP_GZ" > "$TMP_BIN"
else
  die "缺少 gunzip/zcat 无法解压"
fi
chmod +x "$TMP_BIN"
rm -f "$TMP_GZ" "${TMP_GZ}.sha256"

# 7. 执行（默认 install，透传参数）
if [ "$#" -eq 0 ]; then
  set -- install
fi
log "[INFO] 启动 jz-installer $*"
exec "$TMP_BIN" "$@"

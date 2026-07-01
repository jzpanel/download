#!/bin/bash
#==============================================================================
# 极致面板 一键安装脚本
# 用法: bash <(curl -fsSL https://download.jzpanel.com/install.sh)
#   备用(国内加速): bash <(curl -fsSL https://cdn.jsdelivr.net/gh/jzpanel/download@main/install.sh)
#   备用(国外直连): bash <(curl -fsSL https://raw.githubusercontent.com/jzpanel/download/main/install.sh)
#
# 支持系统: 所有主流 Linux 发行版（基于 apt / dnf / yum 包管理器）
#           包括: Ubuntu 20.04+  Debian 10+  CentOS 7+  Rocky Linux 8+
#                 AlmaLinux 8+  Alibaba Cloud Linux 3+  Anolis OS 8+  RHEL 8+ 等
# 支持架构: x86_64 (amd64)  aarch64 (arm64)
#==============================================================================

# set -eu：严格模式，未定义变量报错，命令失败退出
# 不用 pipefail，管道退出码用最后一个命令，避免 SIGPIPE 误退
set -eu

# ── 颜色 ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 核心配置 ─────────────────────────────────────────────────
PANEL_PORT="8888"
SERVICE_NAME="panel"
INSTALL_DIR="/www"
PANEL_DIR="${INSTALL_DIR}/server/panel"
OFFICIAL_API="https://jzpanel.com/api/v1/panel/releases/latest"
OSS_BASE="https://download.jzpanel.com"
# 下载源基址：依次故障切换（主 OSS → 国内 jsDelivr 加速 → 国外 GitHub 直连）。
# 三源的目录/文件相对路径完全一致，切换只换前缀。
# 仓库：github.com/jzpanel/download（main 分支，提交式文件托管）
DOWNLOAD_BASES=(
    "https://download.jzpanel.com"
    "https://cdn.jsdelivr.net/gh/jzpanel/download@main"
    "https://raw.githubusercontent.com/jzpanel/download/main"
)
# 日志先写 /tmp，目录创建后追加写到面板日志目录
INSTALL_LOG="/tmp/jzpanel_install.log"
PANEL_LOG=""   # 安装完成后设置为 ${PANEL_DIR}/logs/install.log

# ── 运行时全局变量（提前初始化，防止 set -u 误报 unbound variable）
INIT_PASSWORD=""
PANEL_VERSION="unknown"
BIN_SUFFIX="amd64"
OS=""
OS_VER=""
SERVER_IP=""
TMP_BIN=""            # 临时下载文件，EXIT trap 负责清理
DOCKER_SCRIPT=""      # 临时 docker 安装脚本，EXIT trap 负责清理
ELAPSED_MIN=0         # 安装总耗时（分）
ELAPSED_SEC=0         # 安装总耗时（秒）

# ── 工具函数 ─────────────────────────────────────────────────
_log()  { echo "$*" >> "$INSTALL_LOG"; }
info()  { local msg="$*"; echo -e "${BLUE}[INFO]${NC}  ${msg}"; _log "[INFO]  ${msg}"; }
ok()    { local msg="$*"; echo -e "${GREEN}[OK]${NC}    ${msg}"; _log "[OK]    ${msg}"; }
warn()  { local msg="$*"; echo -e "${YELLOW}[WARN]${NC}  ${msg}"; _log "[WARN]  ${msg}"; }
die()   { local msg="$*"; echo -e "${RED}[ERROR]${NC} ${msg}" >&2; _log "[ERROR] ${msg}"; exit 1; }
step()  { local msg="$*"; echo -e "\n${BOLD}${CYAN}▶ ${msg}${NC}"; _log ""; _log "▶ ${msg}"; }

# ── EXIT trap：统一清理所有临时文件 ──────────────────────────
# 不在函数内设置 trap（避免覆盖全局 EXIT trap）
_cleanup() {
    [ -n "$TMP_BIN"       ] && rm -f "$TMP_BIN"       2>/dev/null || true
    [ -n "$DOCKER_SCRIPT" ] && rm -f "$DOCKER_SCRIPT" 2>/dev/null || true
}
trap _cleanup EXIT

# ── 多源下载（主 OSS → 国内加速 → 国外直连，任一成功即停）─────────
# _fetch_file  下载相对路径文件到 out，依次尝试所有下载源
#   参数: relpath  out_file
_fetch_file() {
    local relpath="$1" out="$2"
    local base url
    for base in "${DOWNLOAD_BASES[@]}"; do
        url="${base}/${relpath}"
        info "下载: ${url}"
        if curl -fL --connect-timeout 30 --max-time 600 --progress-bar -o "$out" "$url"; then
            return 0
        fi
        rm -f "$out" 2>/dev/null || true
        warn "该源不可用，尝试下一个下载源..."
    done
    return 1
}

# _fetch_text  抓取相对路径的小文本（sha256 / json），成功 echo 到 stdout
#   参数: relpath
_fetch_text() {
    local relpath="$1"
    local base url data
    for base in "${DOWNLOAD_BASES[@]}"; do
        url="${base}/${relpath}"
        data=$(curl -fsSL --connect-timeout 10 --max-time 20 "$url" 2>/dev/null || true)
        if [ -n "$data" ]; then
            printf '%s' "$data"
            return 0
        fi
    done
    return 1
}

# ── 生成随机密码（12位，A-Z a-z 0-9 混合）────────────────────
gen_password() {
    local pwd=""

    # 方案1：openssl rand -base64（输出 Base64 字符，过滤后 A-Za-z0-9）
    # 不用 -hex 因为十六进制只有 16 种字符（0-9a-f），熵不够
    if command -v openssl &>/dev/null; then
        # base64 输出约 44 字符，过滤 +/= 后取前 12 位
        pwd=$(openssl rand -base64 16 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-12 || true)
    fi

    # 方案2：dd 读 urandom 后 base64（一次读固定字节再处理，不在传输中截断）
    if [ -z "$pwd" ] || [ "${#pwd}" -lt 12 ]; then
        if [ -r /dev/urandom ]; then
            local raw
            raw=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 2>/dev/null || true)
            pwd=$(echo "$raw" | tr -dc 'A-Za-z0-9' | cut -c1-12 || true)
        fi
    fi

    # 方案3：date + PID 兜底（弱随机，最后手段，不依赖任何外部工具）
    # 不用 sha256sum（精简系统可能没有），直接拼接截取
    if [ -z "$pwd" ] || [ "${#pwd}" -lt 12 ]; then
        local t s
        t=$(date +%s 2>/dev/null || echo "0")
        s="${$}${t}"
        # 直接截取 PID+时间戳的前 12 位字符，不够就补固定前缀
        pwd="Jz${s}"
        pwd=$(echo "$pwd" | cut -c1-12)
        # 若仍不足 12 位则补齐（极端情况）
        while [ "${#pwd}" -lt 12 ]; do pwd="${pwd}x"; done
    fi

    echo "$pwd"
}

# ── banner（仅显示，不做任何检查）────────────────────────────
banner() {
    echo -e "${GREEN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║         极致面板  ·  一键安装            ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  安装日志: ${INSTALL_LOG}"
    echo ""
}

# ═══════════════════════════════════════════════════
# 1. 前置检查
# ═══════════════════════════════════════════════════
check_root() {
    # root 检查最先执行，非 root 立即退出，不显示横幅
    [ "$EUID" -eq 0 ] || die "请用 root 账号运行。切换方式: sudo -i"
}

detect_os() {
    [ -f /etc/os-release ] || die "无法检测操作系统（缺少 /etc/os-release）"
    # shellcheck source=/dev/null
    . /etc/os-release
    OS="${ID:-unknown}"
    OS_VER="${VERSION_ID:-0}"
    # 用 printf 而不是 echo -e 避免 PRETTY_NAME 含 \n 等转义字符被解析
    info "操作系统: $(printf '%s' "${PRETTY_NAME:-${OS} ${OS_VER}}")"
}

check_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  BIN_SUFFIX="amd64" ;;
        aarch64) BIN_SUFFIX="arm64" ;;
        *) die "不支持的 CPU 架构: ${arch}（仅支持 x86_64 / aarch64）" ;;
    esac
    info "CPU 架构: ${arch} → 使用 ${BIN_SUFFIX} 版本"
}

check_resources() {
    local mem_mb install_disk

    mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}') || mem_mb=9999
    # awk 在空输入时输出空字符串，补充默认值防止后续数字比较报错
    mem_mb="${mem_mb:-9999}"

    # 向上遍历父目录，直到找到已存在（已挂载）的分区
    # 解决首次安装时 /www 还不存在导致 df 报错的问题
    local check_path="$INSTALL_DIR"
    while [ ! -d "$check_path" ] && [ "$check_path" != "/" ]; do
        check_path=$(dirname "$check_path")
    done
    # df 失败时兜底为 9999（跳过检查，不因无法获取磁盘信息而中断安装）
    install_disk=$(df -m "$check_path" 2>/dev/null | awk 'NR==2{print $4}') || install_disk=9999
    install_disk="${install_disk:-9999}"

    [ "$mem_mb"       -lt 512  ] && warn "内存仅 ${mem_mb}MB，建议 1GB 以上，可能影响稳定性"
    [ "$install_disk" -lt 5120 ] && die  "安装目录所在分区可用空间不足 5GB（当前 ${install_disk}MB，分区: ${check_path}）"
    info "资源: 内存 ${mem_mb}MB  安装分区可用 ${install_disk}MB"
}

check_already_installed() {
    [ -f "${PANEL_DIR}/bin/panel" ] || return 0

    local svc_status
    svc_status=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "未运行")

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠  检测到面板已安装                                    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  安装目录: ${PANEL_DIR}"
    echo -e "  服务状态: ${svc_status}"
    echo ""
    echo -e "  ${BOLD}选项:${NC}"
    echo -e "    1) 升级/重装面板程序（保留配置文件和数据库，密码不变）"
    echo -e "    2) 退出"
    echo ""
    read -rp "  请选择 [1/2，默认2]: " choice
    case "${choice:-2}" in
        1)
            info "继续重装，停止服务中..."
            systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
            ;;
        *)
            info "已取消"
            exit 0
            ;;
    esac
    echo ""
}

# ═══════════════════════════════════════════════════
# 2. 安装系统依赖
# ═══════════════════════════════════════════════════
install_deps() {
    step "安装系统依赖"
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        info "更新软件包列表..."
        apt-get update -qq 2>&1 | tee -a "$INSTALL_LOG" \
            || die "apt-get update 失败，请检查网络或软件源配置"
        info "安装依赖包..."
        apt-get install -y curl wget tar gzip zip unzip ca-certificates 2>&1 | tee -a "$INSTALL_LOG" \
            || die "依赖安装失败（curl/wget/tar/zip），请查看日志: ${INSTALL_LOG}"
    elif command -v dnf &>/dev/null; then
        info "安装依赖包..."
        dnf install -y curl wget tar gzip zip unzip ca-certificates 2>&1 | tee -a "$INSTALL_LOG" \
            || die "依赖安装失败（dnf），请查看日志: ${INSTALL_LOG}"
    elif command -v yum &>/dev/null; then
        info "安装依赖包..."
        yum install -y curl wget tar gzip zip unzip ca-certificates 2>&1 | tee -a "$INSTALL_LOG" \
            || die "依赖安装失败（yum），请查看日志: ${INSTALL_LOG}"
    elif command -v zypper &>/dev/null; then
        info "安装依赖包..."
        zypper install -y curl wget tar gzip zip unzip ca-certificates 2>&1 | tee -a "$INSTALL_LOG" \
            || die "依赖安装失败（zypper），请查看日志: ${INSTALL_LOG}"
    else
        warn "未识别包管理器，跳过依赖安装（如安装失败请手动安装 curl/wget/tar）"
    fi
    ok "依赖安装完成"
}

# ═══════════════════════════════════════════════════
# 3. 安装 Docker
# ═══════════════════════════════════════════════════

# Docker 最低版本要求（Compose V2 需要 20.10+）
DOCKER_MIN_MAJOR=20
DOCKER_MIN_MINOR=10

_docker_version_ok() {
    local ver_str
    ver_str=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    local major minor
    major=$(echo "$ver_str" | cut -d. -f1)
    minor=$(echo "$ver_str" | cut -d. -f2)
    [ "${major:-0}" -gt  "$DOCKER_MIN_MAJOR" ] && return 0
    [ "${major:-0}" -eq  "$DOCKER_MIN_MAJOR" ] && \
    [ "${minor:-0}" -ge  "$DOCKER_MIN_MINOR" ] && return 0
    return 1
}

# _try_docker_official  尝试用官方脚本安装，成功返回 0
# 官方脚本能处理：centos/rhel/fedora/ubuntu/debian/opensuse 等主流发行版
# 对于不认识的发行版会直接报错退出，由后续镜像源兜底
_try_docker_official() {
    info "尝试官方安装脚本 (get.docker.com)..."
    local script="/tmp/get-docker-$$.sh"
    DOCKER_SCRIPT="$script"
    info "下载官方安装脚本..."
    if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$script" "https://get.docker.com"; then
        rm -f "$script"; DOCKER_SCRIPT=""
        return 1
    fi

    info "执行官方安装脚本..."
    # 不传任何额外参数，让官方脚本自行检测发行版
    # 官方脚本不认识的（如 alinux/anolis 等）会报 Unsupported distribution 并退出
    # 此时 rc 非 0，install_docker 会继续尝试镜像源方式
    sh "$script" 2>&1 | tee -a "$INSTALL_LOG"
    local rc=${PIPESTATUS[0]}
    rm -f "$script"; DOCKER_SCRIPT=""
    return $rc
}

# _fix_sshd_if_broken  检测 sshd 是否因 OpenSSL 版本不兼容而损坏，如损坏则立即修复
# RHEL/AlmaLinux 系安装 docker-ce 时，openssl-libs 会升级，导致旧 sshd 与新 OpenSSL 不兼容
# 必须在 dnf install docker-ce 之后立即调用，防止当前 SSH 连接断开
_fix_sshd_if_broken() {
    command -v dnf &>/dev/null || return 0   # 非 dnf 系统不需要
    sshd -t >> "$INSTALL_LOG" 2>&1 && return 0   # sshd 正常，不需要修复
    info "检测到 SSH 与 OpenSSL 版本不兼容，立即修复（防止断连）..."
    dnf update openssh openssh-server openssh-clients -y 2>&1 | tee -a "$INSTALL_LOG" || true
    systemctl start sshd >> "$INSTALL_LOG" 2>&1 || true
    ok "SSH 服务已修复"
}

# _try_docker_pkg  通过系统包管理器从指定镜像源安装
# 参数: source_label  base_url（不含系统子路径）
_try_docker_pkg() {
    local label="$1"
    local base="$2"
    info "尝试 ${label} 镜像源..."

    if command -v apt-get &>/dev/null; then
        # ── Debian 系 ──────────────────────────────────────
        apt-get install -y apt-transport-https gnupg lsb-release 2>&1 | tee -a "$INSTALL_LOG" || true

        # 确定上游发行版 ID（用于拼 GPG/repo URL）
        # 衍生版（Kali/Mint/Pop 等）用 $ID_LIKE 找上游
        local deb_os="${OS:-debian}"
        local id_like="${ID_LIKE:-}"
        case "$deb_os" in
            ubuntu|debian) : ;;
            *)
                case "$id_like" in
                    *ubuntu*) deb_os="ubuntu" ;;
                    *)        deb_os="debian" ;;
                esac
                ;;
        esac

        # 确定 codename（衍生版 lsb_release -cs 可能返回自己的 codename，镜像源没有）
        # detect_os 已经 source 了 /etc/os-release，VERSION_CODENAME/UBUNTU_CODENAME 已在全局
        local codename=""
        # 优先用 VERSION_CODENAME（debian/ubuntu 均有）
        codename="${VERSION_CODENAME:-}"
        # 再试 UBUNTU_CODENAME（Ubuntu 22.04+ 的 /etc/os-release 里有此字段）
        if [ -z "$codename" ]; then
            codename="${UBUNTU_CODENAME:-}"
        fi
        # 仍为空时用 lsb_release（最后手段）
        if [ -z "$codename" ]; then
            codename=$(lsb_release -cs 2>/dev/null || true)
        fi
        # 兜底
        [ -z "$codename" ] && codename="bookworm"

        info "导入 Docker GPG 密钥（${deb_os}）..."
        local gpg_ok=0
        local tmp_gpg="/tmp/docker-gpg-$$.asc"
        if curl -fsSL --connect-timeout 15 -o "$tmp_gpg" "${base}/${deb_os}/gpg" 2>>"$INSTALL_LOG"; then
            gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg < "$tmp_gpg" \
                2>>"$INSTALL_LOG" && gpg_ok=1
        fi
        rm -f "$tmp_gpg"
        [ "$gpg_ok" -eq 1 ] || return 1
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] ${base}/${deb_os} ${codename} stable" > /etc/apt/sources.list.d/docker.list
        info "更新软件包列表..."
        apt-get update 2>&1 | tee -a "$INSTALL_LOG" || return 1
        info "安装 Docker 包..."
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
            2>&1 | tee -a "$INSTALL_LOG" || return 1

    elif command -v dnf &>/dev/null; then
        # ── RHEL 系（dnf）─────────────────────────────────
        # 核心问题：docker-ce.repo 里用了 $releasever，dnf 会把它替换成系统版本号。
        # Docker 只发布了 centos/7 和 centos/8 两个路径，RHEL9/ACL4/Anolis23 等
        # 系统的 $releasever 不是 7/8，导致路径 404。
        #
        # 解法：不用 dnf config-manager 下载 .repo 文件，而是直接手写 repo 文件，
        # baseurl 写死为 centos/8（固定路径，不含 $releasever 变量）。
        # centos/8 的包对所有 RHEL 8/9 兼容系统（ACL3/ACL4/Rocky/Alma/Anolis 等）都可用。
        # Fedora 有独立路径，但 Fedora 用官方脚本安装通常能成功，不走此分支。
        info "写入 Docker 软件仓库配置..."

        # 先验证镜像源可达，再写 repo 文件
        local repo_written=0
        local gpg_url=""
        if curl -fsSL --connect-timeout 8 --max-time 15 \
               -o /dev/null "${base}/centos/gpg" 2>/dev/null; then
            gpg_url="${base}/centos/gpg"
        else
            gpg_url="https://download.docker.com/linux/centos/gpg"
        fi

        # 写入 repo 文件：baseurl 固定为 centos/8，不含任何 $releasever
        cat > /etc/yum.repos.d/docker-ce.repo << REPO
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=${base}/centos/8/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=${gpg_url}

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo \$basearch
baseurl=${base}/centos/8/debug-\$basearch/stable
enabled=0
gpgcheck=1
gpgkey=${gpg_url}

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=${base}/centos/8/source/stable
enabled=0
gpgcheck=1
gpgkey=${gpg_url}
REPO
        if [ $? -eq 0 ]; then
            repo_written=1
            info "已写入 Docker repo（${label}/centos/8，固定路径不受系统版本影响）"
        fi

        [ "$repo_written" -eq 1 ] || return 1

        info "安装 Docker 包..."
        dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
            2>&1 | tee -a "$INSTALL_LOG" || return 1
        _fix_sshd_if_broken

    elif command -v yum &>/dev/null; then
        # ── RHEL 系（yum）─────────────────────────────────
        # yum 主要对应 CentOS 7，releasever=7，centos/7 路径存在，不需要覆盖
        yum install -y yum-utils 2>&1 | tee -a "$INSTALL_LOG" || true
        info "添加 Docker 软件仓库..."
        local repo_added=0
        local repo_url rpath
        for rpath in centos rhel fedora; do
            repo_url="${base}/${rpath}/docker-ce.repo"
            if curl -fsSL --connect-timeout 8 --max-time 15 -o /dev/null "$repo_url" 2>/dev/null; then
                info "使用 ${label}/${rpath} 仓库..."
                if yum-config-manager --add-repo "$repo_url" 2>&1 | tee -a "$INSTALL_LOG"; then
                    repo_added=1
                    break
                fi
            fi
        done
        [ "$repo_added" -eq 1 ] || return 1
        info "安装 Docker 包..."
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
            2>&1 | tee -a "$INSTALL_LOG" || return 1
        _fix_sshd_if_broken

    else
        return 1
    fi
    return 0
}

install_docker() {
    step "检查 / 安装 Docker"

    if command -v docker &>/dev/null; then
        ok "Docker 已安装: $(docker --version 2>/dev/null)"
        if ! _docker_version_ok; then
            warn "Docker 版本低于 ${DOCKER_MIN_MAJOR}.${DOCKER_MIN_MINOR}，建议升级"
        fi
        if ! systemctl is-active --quiet docker 2>/dev/null; then
            info "Docker 未运行，正在启动..."
            systemctl start  docker >> "$INSTALL_LOG" 2>&1
            systemctl enable docker >> "$INSTALL_LOG" 2>&1 || true
        fi
        return 0
    fi

    info "未检测到 Docker，开始安装（多源自动重试）..."

    # 清理旧的 docker-ce repo 文件（防止上次安装失败后的残留干扰 dnf 元数据刷新）
    rm -f /etc/yum.repos.d/docker-ce.repo \
          /etc/yum.repos.d/docker-ce-stable.repo \
          /etc/apt/sources.list.d/docker.list \
          2>/dev/null || true

    # 依次尝试多个来源，第一个成功就停止
    # 不做"预先可达性检测"——预检和实际下载的网络行为可能不一致
    local installed=0

    # 来源1：官方脚本（境外服务器首选）
    if _try_docker_official && command -v docker &>/dev/null; then
        installed=1
    fi

    # 来源2：阿里云（国内首选）
    if [ "$installed" -eq 0 ]; then
        if _try_docker_pkg "阿里云" "https://mirrors.aliyun.com/docker-ce/linux"; then
            command -v docker &>/dev/null && installed=1
        fi
    fi

    # 来源3：腾讯云（国内备用）
    if [ "$installed" -eq 0 ]; then
        if _try_docker_pkg "腾讯云" "https://mirrors.tencent.com/docker-ce/linux"; then
            command -v docker &>/dev/null && installed=1
        fi
    fi

    # 安装后强验证：docker 命令必须存在且有版本输出
    if [ "$installed" -eq 0 ] || ! command -v docker &>/dev/null; then
        die "Docker 安装失败（已尝试官方/阿里云/腾讯云三个来源），请查看日志: ${INSTALL_LOG}"
    fi

    local docker_ver
    docker_ver=$(docker --version 2>/dev/null)
    [ -z "$docker_ver" ] && die "Docker 安装异常：命令存在但无版本输出，请查看日志: ${INSTALL_LOG}"

    systemctl start  docker 2>&1 | tee -a "$INSTALL_LOG" || die "Docker 启动失败"
    systemctl enable docker >> "$INSTALL_LOG" 2>&1 || true

    # 等待 daemon 就绪
    local docker_wait=0
    while [ "$docker_wait" -lt 15 ]; do
        docker info >> "$INSTALL_LOG" 2>&1 && break
        sleep 1; docker_wait=$((docker_wait + 1))
    done
    [ "$docker_wait" -ge 15 ] && warn "Docker daemon 启动较慢，若后续失败请检查: systemctl status docker"

    ok "Docker 安装完成: ${docker_ver}"
}

# ═══════════════════════════════════════════════════
# 4. 配置 Docker daemon（仅补充日志限制，不写镜像加速）
# ═══════════════════════════════════════════════════
configure_docker() {
    step "配置 Docker daemon"
    mkdir -p /etc/docker

    if [ -f /etc/docker/daemon.json ]; then
        # daemon.json 已存在：检查是否有日志限制
        local content
        content=$(cat /etc/docker/daemon.json 2>/dev/null || true)
        if echo "$content" | grep -q '"max-size"' 2>/dev/null; then
            ok "daemon.json 已有日志限制，保留原有配置"
        else
            # 有 daemon.json 但无日志限制：不自动修改（避免破坏用户现有配置）
            # 面板启动后会通过 API 合并配置，这里只提示
            warn "检测到已有 /etc/docker/daemon.json，建议手动添加日志限制（防止日志占满磁盘）:"
            warn '  "log-driver": "json-file", "log-opts": {"max-size": "100m", "max-file": "3"}'
        fi
        return 0
    fi

    # daemon.json 不存在：直接写入标准配置
    cat > /etc/docker/daemon.json << 'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
JSON

    systemctl restart docker >> "$INSTALL_LOG" 2>&1 \
        && ok "Docker daemon 配置完成，已重载" \
        || warn "Docker restart 失败，配置将在下次重启后生效"
}


# ═══════════════════════════════════════════════════
# 5. 系统优化
# ═══════════════════════════════════════════════════
tune_system() {
    step "系统优化"

    # 文件描述符上限（Docker + Nginx 高并发需要，默认 1024 不够）
    local cur_hard
    cur_hard=$(ulimit -Hn 2>/dev/null || echo "0")
    # ulimit 可能返回 "unlimited"，需要先过滤再做数字比较
    if [ "$cur_hard" != "unlimited" ] && [ "${cur_hard:-0}" -lt 65536 ] 2>/dev/null; then
        if ! grep -q "nofile 65536" /etc/security/limits.conf 2>/dev/null; then
            {
                echo ""
                echo "# jzpanel: 提高文件描述符上限"
                echo "* soft nofile 65536"
                echo "* hard nofile 65536"
            } >> /etc/security/limits.conf
        fi
    fi

    # 内核 IP 转发（Docker 网络必需）
    sysctl -w net.ipv4.ip_forward=1 >> "$INSTALL_LOG" 2>&1 || true
    if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    else
        sed -i 's/^net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward = 1/' \
            /etc/sysctl.conf 2>/dev/null || true
    fi

    ok "系统参数优化完成"
}

# ═══════════════════════════════════════════════════
# 6. 创建目录结构 + www 用户
# ═══════════════════════════════════════════════════
create_dirs() {
    step "创建目录结构"

    mkdir -p "${INSTALL_DIR}"/{wwwroot,wwwlogs,backup,logs,ssl}
    mkdir -p "${INSTALL_DIR}/backup"/{website,database,panel}
    mkdir -p "${INSTALL_DIR}/server"/{panel,compose,nginx,apache,php}
    mkdir -p "${PANEL_DIR}"/{bin,config,data,logs}

    # 设置面板日志路径（目录已创建，后续步骤可以写入）
    PANEL_LOG="${PANEL_DIR}/logs/install.log"

    # www 用户（PHP/Nginx 容器内运行用户，尽量固定 UID 1000）
    if ! id www &>/dev/null; then
        useradd -r -u 1000 -s /sbin/nologin -d "${INSTALL_DIR}/wwwroot" www 2>/dev/null \
        || adduser -S -u 1000 -D -H -s /sbin/nologin www 2>/dev/null \
        || useradd -r -s /sbin/nologin -d "${INSTALL_DIR}/wwwroot" www 2>/dev/null \
        || warn "www 用户创建失败（UID 1000 可能已被占用），跳过"
    fi
    chown -R www:www "${INSTALL_DIR}/wwwroot" 2>/dev/null || true
    chmod 755 "${INSTALL_DIR}/wwwroot"

    # 把之前写到 /tmp 的日志追加到面板日志目录（追加而非覆盖，保留旧安装历史）
    # 注意：只在首次创建目录时追加，后续 show_result 不再重复追加
    cat "$INSTALL_LOG" >> "$PANEL_LOG" 2>/dev/null || true
    # 切换日志写入目标到面板目录（后续 _log 调用追加到 PANEL_LOG）
    INSTALL_LOG="$PANEL_LOG"

    ok "目录结构创建完成"
}

# ═══════════════════════════════════════════════════
# 7. 下载面板二进制
# ═══════════════════════════════════════════════════
download_panel() {
    step "下载面板程序"

    # 7.1 获取版本号（官网 API 优先 → 下载源 latest.json 兜底 → 最终兜底 1.0.0）
    info "查询最新版本..."
    local json latest_ver
    json=$(curl -fsSL --connect-timeout 10 --max-time 20 \
           "$OFFICIAL_API" 2>>"$INSTALL_LOG" || true)
    latest_ver=$(echo "$json" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    if [ -z "$latest_ver" ]; then
        info "官网版本接口不可用，尝试从下载源读取 latest.json..."
        json=$(_fetch_text "latest.json" || true)
        latest_ver=$(echo "$json" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
    fi
    if [ -z "$latest_ver" ]; then
        warn "无法获取版本信息，使用兜底版本 1.0.0"
        latest_ver="1.0.0"
    fi

    PANEL_VERSION="$latest_ver"
    info "目标版本: v${PANEL_VERSION}"

    # 7.2 下载二进制（gzip 压缩包，多源故障切换：主 OSS → 国内 jsDelivr → 国外 GitHub）
    #     压缩以适配 jsDelivr 单文件 50MB 限制；下载后本地 gunzip 还原。
    local relgz="releases/${PANEL_VERSION}/panel-linux-${BIN_SUFFIX}.gz"
    local tmp_gz="/tmp/panel_install_$$.gz"
    TMP_BIN="/tmp/panel_install_$$"   # 解压后的二进制，EXIT trap 负责清理
    _fetch_file "$relgz" "$tmp_gz" \
        || { rm -f "$tmp_gz"; die "面板下载失败（已尝试全部下载源），请检查网络。路径: ${relgz}"; }

    # 7.3 SHA256 校验（校验下载的 .gz；hash 必须 64 位十六进制，取不到则跳过而不中止）
    info "校验文件完整性..."
    local expected actual
    expected=$(_fetch_text "${relgz}.sha256" | awk '{print $1}' || true)
    if [ -n "$expected" ] && [ "${#expected}" -eq 64 ]; then
        actual=""
        if command -v sha256sum &>/dev/null; then
            actual=$(sha256sum "$tmp_gz" 2>/dev/null | awk '{print $1}' || true)
        elif command -v openssl &>/dev/null; then
            actual=$(openssl dgst -sha256 "$tmp_gz" 2>/dev/null | awk '{print $NF}' || true)
        fi
        if [ -z "$actual" ]; then
            warn "本机无 sha256sum/openssl，跳过完整性校验"
        elif [ "$actual" = "$expected" ]; then
            ok "SHA256 校验通过"
        else
            rm -f "$tmp_gz"
            die "SHA256 校验失败（期望 ${expected:0:16}...，实际 ${actual:0:16}...），文件可能已损坏"
        fi
    else
        warn "校验文件不可用（hash 长度: ${#expected}），跳过校验"
    fi

    # 7.4 解压 gzip → 二进制（gzip 由 install_deps 已装）
    info "解压面板程序..."
    if ! gzip -dc "$tmp_gz" > "$TMP_BIN" 2>/dev/null; then
        rm -f "$tmp_gz" "$TMP_BIN"; TMP_BIN=""
        die "解压失败（gzip 未安装或文件损坏）"
    fi
    rm -f "$tmp_gz"

    # 7.5 安装到目标路径
    mv "$TMP_BIN" "${PANEL_DIR}/bin/panel"
    TMP_BIN=""   # 已移动，清除 EXIT trap 目标
    chmod +x "${PANEL_DIR}/bin/panel"
    ok "面板 v${PANEL_VERSION} 下载完成"
}

# ═══════════════════════════════════════════════════
# 8. 生成配置文件
# ═══════════════════════════════════════════════════
create_config() {
    step "生成配置文件"

    # 重装时保留已有 config.yaml（保持端口、JWT secret、路径配置不变）
    if [ -f "${PANEL_DIR}/config/config.yaml" ]; then
        info "检测到已有配置文件，保留不覆盖（重装不影响原有配置）"
        ok "配置文件检查完成"
        return 0
    fi

    # JWT secret 生成：openssl -hex 不用管道截断，直接输出到变量
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32 2>/dev/null \
              || dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -A n -t x1 | tr -dc '0-9a-f' | cut -c1-64 \
              || echo "jzpanel_changeme_$(date +%s)_${$}")

    cat > "${PANEL_DIR}/config/config.yaml" << YAML
app:
  port: "${PANEL_PORT}"
  debug: false
  name: "极致面板"

database:
  path: "${PANEL_DIR}/data/panel.db"

jwt:
  secret: "${jwt_secret}"
  expire_hour: 5

paths:
  base: "${INSTALL_DIR}"
YAML
    # 配置文件含 JWT secret，限制为 root-only
    chmod 600 "${PANEL_DIR}/config/config.yaml"
    ok "配置文件生成完成"
}

# ═══════════════════════════════════════════════════
# 9. 写初始密码文件
# ═══════════════════════════════════════════════════
write_init_password() {
    local pwd_file="${PANEL_DIR}/data/.init_password"

    # 数据库已存在说明是重装，密码已由用户设置，不重置
    if [ -f "${PANEL_DIR}/data/panel.db" ]; then
        info "数据库已存在，跳过初始密码（重装不重置密码）"
        INIT_PASSWORD="重装保留原密码，请使用原密码登录"
        return 0
    fi

    # data 目录由 create_dirs 保证存在
    echo "$INIT_PASSWORD" > "$pwd_file"
    chmod 600 "$pwd_file"
    info "初始密码已写入 ${pwd_file}（权限 600，面板读取后自动删除）"
}

# ═══════════════════════════════════════════════════
# 10. 创建 systemd 服务
# ═══════════════════════════════════════════════════
create_service() {
    step "创建系统服务"

    local pwd_file="${PANEL_DIR}/data/.init_password"

    # PANEL_INIT_PASSWORD_FILE：告知面板密码文件路径
    # 面板首次初始化数据库时读取，读取后立即 os.Remove 删除
    # 数据库已存在时此变量完全不生效
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE
[Unit]
Description=JZPanel Server
Documentation=https://jzpanel.com/docs
After=network.target docker.service
Wants=docker.service
# 不限制启动重试次数（首次启动慢或瞬时失败时，让 Restart=always 持续拉起，不被 systemd 熔断）
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_DIR}/bin/panel
Environment=PANEL_INIT_PASSWORD_FILE=${pwd_file}
Restart=always
RestartSec=3
# 首次启动需建数据库 + 联网拉取应用商店包，给足启动时间，避免被 systemd 误判超时
TimeoutStartSec=0
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    ok "系统服务创建完成"
}

# ═══════════════════════════════════════════════════
# 11. 配置防火墙
# ═══════════════════════════════════════════════════
configure_firewall() {
    step "配置防火墙"

    # 获取当前 SSH 端口（先从 sshd_config 读，再从 ss 兜底，最终默认 22）
    local ssh_port=""
    # 方法1：从 sshd_config 读（最可靠，兼容所有实现包括 dropbear）
    if [ -f /etc/ssh/sshd_config ]; then
        ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null \
                   | awk '{print $2}' | head -1 | tr -d '[:space:]')
    fi
    # 方法2：从 ss 检测当前监听（兜底，处理 sshd_config 未配置 Port 行的情况）
    if [ -z "$ssh_port" ]; then
        ssh_port=$(ss -tlnp 2>/dev/null | awk '{print $4}' | grep -oE ':[0-9]+$' | \
                   tr -d ':' | sort -n | uniq | while read -r p; do
                       ss -tlnp 2>/dev/null | grep ":${p}" | grep -q 'sshd\|dropbear' && echo "$p" && break
                   done 2>/dev/null | head -1)
    fi
    # 默认兜底
    [ -z "$ssh_port" ] && ssh_port="22"

    # ── firewalld（AlmaLinux / CentOS / RHEL / Rocky）────────────────
    if command -v firewall-cmd &>/dev/null; then
        # 无论是否运行，先确保启动（RHEL 系列默认安装了 firewalld 但没有运行）
        if ! systemctl is-active --quiet firewalld 2>/dev/null; then
            info "启动 firewalld（首次安装自动开启）..."
            systemctl enable firewalld >> "$INSTALL_LOG" 2>&1 || true
            systemctl start  firewalld >> "$INSTALL_LOG" 2>&1 || true
            sleep 1
        fi

        if systemctl is-active --quiet firewalld 2>/dev/null; then
            # 先确保 SSH 端口放行（防止锁死）
            firewall-cmd --permanent --add-port="${ssh_port}/tcp" >> "$INSTALL_LOG" 2>&1 || true
            # 开放面板端口
            firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >> "$INSTALL_LOG" 2>&1
            firewall-cmd --reload >> "$INSTALL_LOG" 2>&1 \
                && ok "firewalld: 已开放端口 ${PANEL_PORT}（SSH ${ssh_port} 同时放行）" \
                || warn "firewalld reload 失败，规则已写入，重启后生效"
        else
            warn "firewalld 启动失败，请手动配置"
        fi
        return

    # ── ufw（Ubuntu / Debian）────────────────────────────────────────
    elif command -v ufw &>/dev/null; then
        # ufw 无论是否激活，先把关键端口加入规则（添加规则不需要 ufw 已激活）
        # 这样 ufw enable 时这些端口已在 allow 列表，不会被锁
        ufw allow "${ssh_port}/tcp"   >> "$INSTALL_LOG" 2>&1 || true
        ufw allow "${PANEL_PORT}/tcp" >> "$INSTALL_LOG" 2>&1

        if ufw status 2>/dev/null | grep -qi "active"; then
            ufw reload >> "$INSTALL_LOG" 2>&1 || true
            ok "ufw: 已开放端口 ${PANEL_PORT}"
        else
            # ufw 存在但未激活：添加好规则后启用
            # --force 跳过交互确认，SSH 端口已经加入 allow，不会断连
            ufw --force enable >> "$INSTALL_LOG" 2>&1 \
                && ok "ufw: 已启用并开放端口 ${PANEL_PORT}（SSH ${ssh_port} 同时放行）" \
                || warn "ufw 启用失败，请手动执行: ufw allow ${PANEL_PORT}/tcp && ufw enable"
        fi
        return
    fi

    # ── 没有防火墙工具 ────────────────────────────────────────────────
    warn "未检测到防火墙工具（如使用云服务器，请在控制台安全组手动开放 TCP ${PANEL_PORT} 端口）"
}

# ═══════════════════════════════════════════════════
# 安装 jz 管理工具
# ═══════════════════════════════════════════════════
install_jz_tool() {
    step "安装 jz 管理工具"

    # 从下载源获取 jz 脚本（多源故障切换，方便单独更新 jz 而不需要重装面板）
    local tmp_jz="/tmp/jz_install_$$"

    if _fetch_file "jz" "$tmp_jz"; then
        mv "$tmp_jz" /usr/local/bin/jz
        chmod +x /usr/local/bin/jz
        ok "jz 管理工具已安装（输入 jz 打开管理菜单）"
    else
        # 下载失败：不阻塞安装，jz 是可选工具
        rm -f "$tmp_jz" 2>/dev/null || true
        warn "jz 管理工具下载失败（可手动安装，不影响面板使用）"
        warn "手动安装: curl -fsSL https://download.jzpanel.com/jz -o /usr/local/bin/jz && chmod +x /usr/local/bin/jz"
    fi
}

# ═══════════════════════════════════════════════════
# 12. 启动面板并等待就绪
# ═══════════════════════════════════════════════════
start_panel() {
    step "启动面板服务"

    systemctl enable "${SERVICE_NAME}" >> "$INSTALL_LOG" 2>&1 || true

    # 首次启动较慢（建数据库 + 联网拉取应用商店包），且 Type=simple 的
    # `systemctl start` 在进程 fork 后即返回，偶发因时序返回非 0。
    # 因此不用 start 的即时返回值判定成败——发起启动后改为轮询真实状态。
    # 配合 service 的 Restart=always，瞬时失败会被自动拉起。
    systemctl start "${SERVICE_NAME}" >> "$INSTALL_LOG" 2>&1 || true

    # 等待面板就绪：优先 HTTP 接口能响应；退而求其次进程处于 active。
    # 最多 90 秒（覆盖首次建库 + 拉取 1.0.x 应用包 + 慢网络）。
    info "等待面板就绪（首次启动需初始化，请稍候）..."
    local elapsed=0 max=90 ready=0 last_restart=0
    while [ "$elapsed" -lt "$max" ]; do
        # HTTP 根路径能响应 = 完全就绪
        if curl -sf --connect-timeout 2 --max-time 3 \
               "http://127.0.0.1:${PANEL_PORT}/" -o /dev/null 2>/dev/null; then
            ready=1
            break
        fi

        local state
        state=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo unknown)
        if [ "$state" = "failed" ]; then
            # 进程退出且未被自动拉起：主动补一次重启（间隔≥10s，避免狂刷）
            if [ "$((elapsed - last_restart))" -ge 10 ]; then
                warn "面板进程未就绪，尝试重新启动..."
                systemctl restart "${SERVICE_NAME}" >> "$INSTALL_LOG" 2>&1 || true
                last_restart=$elapsed
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$ready" -eq 1 ]; then
        ok "面板就绪（${elapsed} 秒）"
    elif systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        # 进程在跑但 HTTP 还没响应：首次启动初始化未完成，属正常，不报错
        warn "面板进程运行中，HTTP 接口尚未响应（首次启动初始化中，通常稍后即可访问）"
        warn "如长时间无法访问，请执行: journalctl -u ${SERVICE_NAME} -n 50"
    else
        # 真正失败：打印诊断日志帮助定位，而不是只甩一句"失败"
        warn "面板服务未能在 ${max} 秒内就绪，最近日志如下："
        journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || true
        die "面板服务启动失败，请将上方日志反馈给我们；可手动重试: systemctl restart ${SERVICE_NAME}"
    fi
}

# ═══════════════════════════════════════════════════
# 13. 获取公网 IP
# ═══════════════════════════════════════════════════
get_server_ip() {
    SERVER_IP=$(
        curl -sf --connect-timeout 4 --max-time 6 ifconfig.me   2>/dev/null ||
        curl -sf --connect-timeout 4 --max-time 6 icanhazip.com 2>/dev/null ||
        curl -sf --connect-timeout 4 --max-time 6 ipinfo.io/ip  2>/dev/null ||
        hostname -I 2>/dev/null | awk '{print $1}'              ||
        echo "YOUR_SERVER_IP"
    )
    SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')
}

# ═══════════════════════════════════════════════════
# 14. 显示安装结果
# ═══════════════════════════════════════════════════
show_result() {
    get_server_ip

    # 把安装结果写入日志（密码单独处理，重装不记录"保留原密码"误导信息）
    {
        echo ""
        echo "======== 安装结果 ========"
        echo "完成时间: $(date)"
        echo "面板地址: http://${SERVER_IP}:${PANEL_PORT}"
        echo "登录账号: admin"
        if [ "$INIT_PASSWORD" = "重装保留原密码，请使用原密码登录" ]; then
            echo "登录密码: 重装保留，请用原密码登录"
        else
            echo "初始密码: ${INIT_PASSWORD}"
        fi
        echo "面板版本: v${PANEL_VERSION}"
        echo "=========================="
    } >> "$INSTALL_LOG"

    # 同步到面板日志目录（INSTALL_LOG 已切换到 PANEL_LOG，直接写入，无需再追加）
    # 仅在目录创建前出现异常导致 PANEL_LOG 为空时兜底
    if [ -n "$PANEL_LOG" ] && [ "$INSTALL_LOG" != "$PANEL_LOG" ]; then
        cat "$INSTALL_LOG" >> "$PANEL_LOG" 2>/dev/null || true
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                 🎉  安装完成！                           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}面板地址${NC}    http://${SERVER_IP}:${PANEL_PORT}"
    echo -e "  ${BOLD}登录账号${NC}    admin"
    if [ "$INIT_PASSWORD" = "重装保留原密码，请使用原密码登录" ]; then
        echo -e "  ${BOLD}登录密码${NC}    ${YELLOW}（重装保留原密码，请使用原密码登录）${NC}"
    else
        echo -e "  ${BOLD}初始密码${NC}    ${YELLOW}${BOLD}${INIT_PASSWORD}${NC}"
    fi
    echo -e "  ${BOLD}面板版本${NC}    v${PANEL_VERSION}"
    echo -e "  ${BOLD}安装耗时${NC}    ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}⚠  请立即登录并修改密码！${NC}"
    echo -e "  ${YELLOW}⚠  如使用云服务器，请确认安全组已开放 TCP ${PANEL_PORT} 端口。${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BLUE}常用命令:${NC}"
    echo -e "    ${BOLD}jz${NC}                  打开管理工具箱（重置密码/修改端口等）"
    echo -e "    查看状态  systemctl status  ${SERVICE_NAME}"
    echo -e "    查看日志  journalctl -u     ${SERVICE_NAME} -f"
    echo -e "    重启面板  systemctl restart ${SERVICE_NAME}"
    echo -e "    停止面板  systemctl stop    ${SERVICE_NAME}"
    echo ""
    echo -e "  ${BLUE}安装路径:${NC}  ${PANEL_DIR}"
    if [ -n "$PANEL_LOG" ]; then
        echo -e "  ${BLUE}安装日志:${NC}  ${PANEL_LOG}（含初始密码）"
    else
        echo -e "  ${BLUE}安装日志:${NC}  ${INSTALL_LOG}（含初始密码）"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════
# 卸载
# ═══════════════════════════════════════════════════
uninstall() {
    echo -e "${YELLOW}开始卸载极致面板...${NC}"

    local panel_exists=0
    [ -f "${PANEL_DIR}/bin/panel" ] && panel_exists=1
    systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null && panel_exists=1

    if [ "$panel_exists" -eq 0 ]; then
        echo "未检测到已安装的极致面板，无需卸载。"
        exit 0
    fi

    # 先停止服务（不删服务文件，取消时可以恢复）
    systemctl stop    "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    echo ""
    echo "  选择卸载方式："
    echo "    1) 只删面板程序（保留网站文件 /www/wwwroot）"
    echo "       注意：面板数据库和配置也会被删除，重装后需重新设置"
    echo "    2) 删除全部（面板程序 + 数据库 + 网站文件 + 所有数据）"
    echo "    3) 取消（恢复面板服务）"
    echo ""
    read -rp "  请选择 [1/2/3，默认3]: " answer

    case "${answer:-3}" in
        1)
            # 删除面板程序、配置、数据库；保留用户网站文件
            rm -rf "${PANEL_DIR}/bin"
            rm -rf "${PANEL_DIR}/config"
            rm -rf "${PANEL_DIR}/data"
            rm -rf "${PANEL_DIR}/logs"
            rm -f  "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload
            echo -e "${GREEN}面板程序和数据库已删除，网站文件保留在: ${INSTALL_DIR}/wwwroot${NC}"
            echo -e "${YELLOW}注意: 重装面板后需要重新配置（原有网站记录、应用记录等已清除）${NC}"
            ;;
        2)
            read -rp "  ⚠  此操作删除 ${INSTALL_DIR} 下所有数据（含网站文件），不可恢复！输入 yes 确认: " confirm
            if [ "${confirm:-}" = "yes" ]; then
                # 先删数据，最后删服务文件（顺序保证：若 rm 中途失败，服务文件还在，状态可知）
                rm -rf "${INSTALL_DIR}"
                rm -f  "/etc/systemd/system/${SERVICE_NAME}.service"
                systemctl daemon-reload
                echo -e "${GREEN}所有数据已删除${NC}"
            else
                echo "已取消，恢复面板服务..."
                systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
                systemctl start  "${SERVICE_NAME}" 2>/dev/null || true
                echo "面板服务已恢复"
            fi
            ;;
        *)
            echo "已取消，恢复面板服务..."
            systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
            systemctl start  "${SERVICE_NAME}" 2>/dev/null || true
            echo "面板服务已恢复"
            exit 0
            ;;
    esac

    echo -e "${GREEN}卸载完成${NC}"
}

# ═══════════════════════════════════════════════════
# 主流程
# ═══════════════════════════════════════════════════
main() {
    # 初始化日志文件（最先执行）
    mkdir -p "$(dirname "$INSTALL_LOG")"
    {
        echo "========================================"
        echo "极致面板安装开始: $(date)"
        echo "========================================"
    } >> "$INSTALL_LOG"

    # root 检查最先（在 banner 和卸载之前）
    check_root

    # 卸载模式（root 检查后、banner 前）
    if [ "${1:-}" = "uninstall" ]; then
        uninstall
        exit 0
    fi

    banner

    # 记录开始时间，用于计算总耗时
    local start_ts
    start_ts=$(date +%s 2>/dev/null || echo 0)

    # 生成初始密码（banner 后立即生成，后续所有步骤共用同一个值）
    INIT_PASSWORD=$(gen_password)

    step "前置检查"
    detect_os
    check_arch
    check_resources
    check_already_installed
    ok "前置检查通过"

    install_deps
    install_docker
    configure_docker
    tune_system
    create_dirs        # 创建目录并设置 PANEL_LOG
    download_panel
    create_config
    write_init_password
    create_service
    configure_firewall
    start_panel
    install_jz_tool     # 安装 jz 管理工具
    # 计算总耗时
    local end_ts
    end_ts=$(date +%s 2>/dev/null || echo "$start_ts")
    ELAPSED_MIN=$(( (end_ts - start_ts) / 60 ))
    ELAPSED_SEC=$(( (end_ts - start_ts) % 60 ))
    _log "安装总耗时: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
    show_result
}

main "$@"

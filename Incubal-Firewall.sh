#!/usr/bin/env bash
# ============================================================================
# Incubal-Firewall deployment script
#
# Usage:
#   sudo bash Incubal-Firewall.sh
#   sudo bash Incubal-Firewall.sh --iface eth0 --countries CN --rules default --yes
#   sudo bash Incubal-Firewall.sh --status
#   sudo bash Incubal-Firewall.sh --uninstall
# ============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.0.5"
readonly PROJECT_NAME="Incubal-Firewall"
readonly DEFAULT_RELEASE_URL="https://github.com/0xdabiaoge/Incubal-Firewall/releases/latest/download"
readonly INSTALL_DIR="/opt/incubal-firewall"
readonly BIN_PATH="${INSTALL_DIR}/rfw"
readonly MANAGER_PATH="${INSTALL_DIR}/Incubal-Firewall.sh"
readonly SOURCE_PATH_FILE="${INSTALL_DIR}/source-script.path"
readonly SHORTCUT_PATH="/usr/local/bin/incudalrfw"
readonly SERVICE_NAME="rfw"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly BPF_PIN_PATH="/sys/fs/bpf/rfw_port_access_log"

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

ACTION="install"
IFACE=""
RULES=""
COUNTRIES=""
ALLOW_ONLY_COUNTRIES=""
BLOCK_ALL_FROM=""
LOG_PORT_ACCESS="false"
YES="false"
RELEASE_URL="$DEFAULT_RELEASE_URL"
RFW_ARGS=()
STATS_PORT=""
STATS_IP=""
STATS_GROUP_BY_PORT="false"
STATS_INTERVAL="2"
SUMMARY_RULES=""
SUMMARY_GEO=""
SUMMARY_LOG="关闭"

log() { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1" >&2; }
step() { echo -e "\n${CYAN}[▶]${NC} ${BOLD}$1${NC}"; }

divider() {
    echo -e "${DIM}────────────────────────────────────────────────────${NC}"
}

usage() {
    cat <<EOF
${PROJECT_NAME} 部署脚本 v${SCRIPT_VERSION}

简介:
  ${PROJECT_NAME} 用于在 Linux 服务器上部署和管理 RFW eBPF/XDP 防火墙。
  直接运行脚本会进入交互式主菜单；携带参数运行时可用于自动化部署、服务管理、
  阻断统计、日志查看和实时监控。

基本用法:
  sudo bash Incubal-Firewall.sh [选项]

交互式菜单:
  用途: 进入图形化文字菜单，适合手动部署、查看状态、查看阻断统计和卸载。
  sudo bash Incubal-Firewall.sh

一、部署命令
  1. 自动选择网卡，使用默认规则屏蔽 CN 流量:
     用途: 常见防护配置，默认屏蔽 Email / HTTP / SOCKS5 / FET-Strict / WireGuard。
     说明: --yes 表示跳过交互确认，适合复制到服务器直接执行。
     命令:
       sudo bash Incubal-Firewall.sh --countries CN --rules default --log-port-access --yes

  2. 指定网卡 eth0，并使用默认规则屏蔽 CN 流量:
     用途: 服务器有多张网卡时，明确指定 XDP 绑定到哪张网卡。
     参数: --iface 后面填写网卡名，可用 ip link 查看。
     命令:
       sudo bash Incubal-Firewall.sh --iface eth0 --countries CN --rules default --log-port-access --yes

  3. 阻止指定国家的所有入站流量:
     用途: 不做协议识别，直接阻断指定国家来源的全部入站流量。
     参数: --block-all-from 后面填写国家代码，多个国家用英文逗号分隔。
     命令:
       sudo bash Incubal-Firewall.sh --iface eth0 --block-all-from CN,RU --log-port-access --yes

  4. 白名单模式，只允许指定国家访问:
     用途: 只服务少量地区用户时使用，未在白名单内的国家会被阻断。
     参数: --allow-only-countries 后面填写允许访问的国家代码。
     命令:
       sudo bash Incubal-Firewall.sh --iface eth0 --allow-only-countries US,JP,KR --rules all --log-port-access --yes

  5. 全局协议过滤，不限制国家:
     用途: 不使用 GeoIP，所有来源都应用所选协议屏蔽规则。
     参数: --rules 支持多个规则，用英文逗号分隔，不要加空格。
     命令:
       sudo bash Incubal-Firewall.sh --iface eth0 --rules http,socks5,wireguard --log-port-access --yes

二、部署参数说明
  --iface <IFACE>
     指定 XDP 绑定网卡，例如 eth0、ens18、ens33。
     不填写时脚本会优先根据默认路由自动选择网卡。

  --rules <LIST>
     指定协议屏蔽规则。可选值:
       default       = email,http,socks5,fet-strict,wireguard
       all-protocols = email,http,socks5,fet-strict,wireguard,quic
       all           = 阻止所有入站流量
       none          = 不启用协议屏蔽，可配合 --log-port-access 只做统计
       自定义        = email,http,socks5,fet-strict,fet-loose,wireguard,quic
     示例:
       sudo bash Incubal-Firewall.sh --iface eth0 --rules http,socks5,wireguard --yes

  --countries <CODES>
     黑名单国家模式，只对指定国家来源应用所选规则。
     示例:
       sudo bash Incubal-Firewall.sh --iface eth0 --countries CN,RU --rules default --yes

  --allow-only-countries <CODES>
     白名单国家模式，只允许指定国家访问。
     示例:
       sudo bash Incubal-Firewall.sh --iface eth0 --allow-only-countries US,JP,KR --rules all --yes

  --block-all-from <CODES>
     快捷阻断模式，阻止指定国家全部入站流量。
     等价于给 RFW 传入 --countries <CODES> --block-all。
     示例:
       sudo bash Incubal-Firewall.sh --iface eth0 --block-all-from CN --yes

  --log-port-access
     开启 eBPF 端口访问统计。开启后才能使用 --stats、--blocked-stats、--watch-stats。
     建议部署时默认带上，方便后续查看来源 IP、端口、允许次数和阻断次数。

  --release-url <URL>
     指定二进制下载根地址。默认使用 GitHub 最新 Release。
     只有在你使用自建下载源、镜像源或测试 Release 时才需要改。
     示例:
       sudo bash Incubal-Firewall.sh --release-url https://example.com/releases --yes

  --yes, -y
     非交互确认。脚本不会再询问确认，适合自动化部署或直接复制执行。

三、快捷命令 incudalrfw
  部署成功后，脚本会创建管理入口:
    /usr/local/bin/incudalrfw -> /opt/incubal-firewall/Incubal-Firewall.sh

  直接进入交互式菜单:
    sudo incudalrfw

  查看部署脚本帮助:
    sudo incudalrfw --help

  直接查看阻断统计:
    sudo incudalrfw --blocked-stats

  调用 RFW 原生命令:
    sudo incudalrfw raw --help
    sudo incudalrfw raw stats --help

  兼容原来的 RFW 统计写法:
    sudo incudalrfw stats --blocked-only

  如果快捷命令不存在，可修复管理入口:
    sudo bash Incubal-Firewall.sh --install-shortcut

四、阻断统计和端口访问统计
  1. 查看全部端口访问统计:
     用途: 显示允许和阻断的累计次数。
     前提: 部署时必须开启 --log-port-access。
     命令:
       sudo bash Incubal-Firewall.sh --stats

  2. 只查看被阻断的访问统计:
     用途: 查看哪些来源 IP 被阻断、访问了哪个协议和目标端口、累计阻断多少次。
     命令:
       sudo bash Incubal-Firewall.sh --blocked-stats

  3. 按目标端口过滤统计:
     用途: 只看某个端口，例如 SSH 22、HTTP 80、HTTPS 443。
     命令:
       sudo bash Incubal-Firewall.sh --blocked-stats --stats-port 22

  4. 按来源 IP 过滤统计:
     用途: 排查某一个来源 IP 是否被阻断或访问过哪些端口。
     命令:
       sudo bash Incubal-Firewall.sh --blocked-stats --stats-ip 1.2.3.4

  5. 按端口分组查看统计:
     用途: 先按端口汇总，再查看每个端口下的来源 IP。
     命令:
       sudo bash Incubal-Firewall.sh --blocked-stats --group-by-port

  6. 实时刷新阻断统计:
     用途: 类似监控面板，每隔几秒刷新一次阻断计数。
     参数: --interval 指定刷新间隔，单位秒，默认 2 秒。
     命令:
       sudo bash Incubal-Firewall.sh --watch-stats --interval 3

五、阻断明细日志和原始日志
  1. 查看最近阻断明细日志:
     用途: 从 systemd 日志中筛选 BLOCKED 行，查看具体命中的规则、来源 IP、源端口和目标端口。
     命令:
       sudo bash Incubal-Firewall.sh --blocked-logs

  2. 实时监控阻断明细:
     用途: 边测试边看实时阻断记录，按 Ctrl-C 退出。
     命令:
       sudo bash Incubal-Firewall.sh --watch-blocked

  3. 查看最近 80 行原始服务日志:
     用途: 排查服务启动失败、GeoIP 下载失败、XDP 加载失败等问题。
     命令:
       sudo bash Incubal-Firewall.sh --logs

  4. 手动查看完整 systemd 日志:
     用途: 不经过脚本，直接跟踪 rfw.service 输出。
     命令:
       journalctl -u rfw -f

六、服务管理
  查看安装路径、快捷命令、服务文件、启动命令和运行状态:
    sudo bash Incubal-Firewall.sh --status

  启动服务:
    sudo bash Incubal-Firewall.sh --start

  停止服务:
    sudo bash Incubal-Firewall.sh --stop

  重启服务:
    sudo bash Incubal-Firewall.sh --restart

七、卸载
  用途: 彻底卸载 RFW，删除 rfw.service、/opt/incubal-firewall、
        /usr/local/bin/incudalrfw、残留 BPF map，并删除当前部署脚本文件。
  命令:
    sudo bash Incubal-Firewall.sh --uninstall

八、注意事项
  1. --stats / --blocked-stats / --watch-stats 依赖 --log-port-access。
  2. --blocked-logs / --watch-blocked 依赖 rfw.service 的 journalctl 日志。
  3. 如果你手动运行 /opt/incubal-firewall/rfw，而不是 systemd 服务，阻断日志会输出到当前终端。
  4. --countries、--allow-only-countries、--block-all-from 不要同时混用。
EOF
}

show_banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  ║                                                  ║${NC}"
    echo -e "${CYAN}  ║              ${BOLD}Incubal-Firewall${NC}${CYAN}                    ║${NC}"
    echo -e "${CYAN}  ║              ${DIM}RFW XDP Firewall Setup${NC}${CYAN}              ║${NC}"
    echo -e "${CYAN}  ║                                                  ║${NC}"
    echo -e "${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}版本: ${SCRIPT_VERSION}${NC}"
    echo ""
}

pause_screen() {
    if [[ -t 0 ]]; then
        echo ""
        echo -ne "  ${DIM}按 Enter 返回主菜单...${NC}"
        read -r _ || true
    fi
}

show_main_menu() {
    show_runtime_overview

    echo -e "  ${BOLD}请选择操作：${NC}"
    echo ""
    echo -e "    ${CYAN}1)${NC}  部署 / 重新部署 RFW"
    echo -e "    ${CYAN}2)${NC}  查看 RFW 状态"
    echo -e "    ${CYAN}3)${NC}  启动 RFW 服务"
    echo -e "    ${CYAN}4)${NC}  停止 RFW 服务"
    echo -e "    ${CYAN}5)${NC}  重启 RFW 服务"
    echo -e "    ${CYAN}6)${NC}  查看阻断统计"
    echo -e "    ${CYAN}7)${NC}  查看阻断明细日志"
    echo -e "    ${CYAN}8)${NC}  实时监控阻断日志"
    echo -e "    ${CYAN}9)${NC}  查看最近原始日志"
    echo ""
    echo -e "    ${RED}10)${NC} 卸载 RFW"
    echo -e "    ${CYAN}11)${NC} 使用帮助"
    echo -e "    ${CYAN}0)${NC}  退出"
    echo ""
    echo -ne "  ${BOLD}请输入选项 [0-11]: ${NC}"
}

reset_install_options() {
    IFACE=""
    RULES=""
    COUNTRIES=""
    ALLOW_ONLY_COUNTRIES=""
    BLOCK_ALL_FROM=""
    LOG_PORT_ACCESS="false"
    RFW_ARGS=()
    SUMMARY_RULES=""
    SUMMARY_GEO=""
    SUMMARY_LOG="关闭"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请以 root 权限运行此脚本"
        echo -e "  ${DIM}示例: sudo bash Incubal-Firewall.sh${NC}"
        exit 1
    fi
}

require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "RFW 依赖 Linux eBPF/XDP，只能部署在 Linux 系统"
        exit 1
    fi
}

require_command() {
    local name="$1"
    local package_hint="$2"
    if ! command -v "$name" >/dev/null 2>&1; then
        error "缺少命令: ${name}"
        error "请先安装依赖: ${package_hint}"
        exit 1
    fi
}

ensure_dependencies() {
    require_command curl "apt-get install -y curl"
    require_command ip "apt-get install -y iproute2"
    require_command systemctl "安装并启用 systemd"
}

ensure_systemctl() {
    require_linux
    require_command systemctl "安装并启用 systemd"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iface)
                require_value "$1" "${2:-}"
                IFACE="${2:-}"; shift 2 ;;
            --rules)
                require_value "$1" "${2:-}"
                RULES="${2:-}"; shift 2 ;;
            --countries)
                require_value "$1" "${2:-}"
                COUNTRIES="${2:-}"; shift 2 ;;
            --allow-only-countries)
                require_value "$1" "${2:-}"
                ALLOW_ONLY_COUNTRIES="${2:-}"; shift 2 ;;
            --block-all-from)
                require_value "$1" "${2:-}"
                BLOCK_ALL_FROM="${2:-}"; shift 2 ;;
            --log-port-access)
                LOG_PORT_ACCESS="true"; shift ;;
            --release-url)
                require_value "$1" "${2:-}"
                RELEASE_URL="${2:-}"; shift 2 ;;
            --yes|-y)
                YES="true"; shift ;;
            --status)
                ACTION="status"; shift ;;
            --start)
                ACTION="start"; shift ;;
            --stop)
                ACTION="stop"; shift ;;
            --restart)
                ACTION="restart"; shift ;;
            --stats)
                ACTION="stats"; shift ;;
            --blocked-stats)
                ACTION="blocked-stats"; shift ;;
            --stats-port)
                require_value "$1" "${2:-}"
                STATS_PORT="${2:-}"; shift 2 ;;
            --stats-ip)
                require_value "$1" "${2:-}"
                STATS_IP="${2:-}"; shift 2 ;;
            --group-by-port)
                STATS_GROUP_BY_PORT="true"; shift ;;
            --watch-stats)
                ACTION="watch-stats"; shift ;;
            --interval)
                require_value "$1" "${2:-}"
                STATS_INTERVAL="${2:-}"; shift 2 ;;
            --blocked-logs)
                ACTION="blocked-logs"; shift ;;
            --watch-blocked)
                ACTION="watch-blocked"; shift ;;
            --logs)
                ACTION="logs"; shift ;;
            --install-shortcut)
                ACTION="install-shortcut"; shift ;;
            --uninstall)
                ACTION="uninstall"; shift ;;
            --help|-h)
                usage
                exit 0 ;;
            *)
                error "未知参数: $1"
                echo -e "  ${DIM}使用 --help 查看帮助${NC}"
                exit 1 ;;
        esac
    done

    RELEASE_URL="${RELEASE_URL%/}"

    if [[ -n "$COUNTRIES" && -n "$ALLOW_ONLY_COUNTRIES" ]]; then
        error "--countries 与 --allow-only-countries 不能同时使用"
        exit 1
    fi

    if [[ -n "$COUNTRIES" && -n "$BLOCK_ALL_FROM" ]]; then
        error "--countries 与 --block-all-from 不能同时使用"
        exit 1
    fi

    if [[ -n "$STATS_PORT" && ! "$STATS_PORT" =~ ^[0-9]+$ ]]; then
        error "--stats-port 必须是端口号"
        exit 1
    fi

    if [[ ! "$STATS_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
        error "--interval 必须是正整数秒数"
        exit 1
    fi
}

require_value() {
    local option="$1"
    local value="$2"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "参数 ${option} 缺少取值"
        exit 1
    fi
}

normalize_countries() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' '
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)
            echo "x86_64" ;;
        aarch64|arm64)
            echo "aarch64" ;;
        *)
            error "不支持的架构: $(uname -m)（仅支持 x86_64 / aarch64）"
            exit 1 ;;
    esac
}

detect_default_iface() {
    local detected=""
    detected=$(ip route get 8.8.8.8 2>/dev/null | awk -F'dev ' '{print $2}' | awk '{print $1}' | head -n1 || true)
    if [[ -z "$detected" ]]; then
        detected=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$' | head -n1 || true)
    fi
    echo "$detected"
}

select_interface() {
    if [[ -n "$IFACE" ]]; then
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            error "网卡不存在: ${IFACE}"
            exit 1
        fi
        return
    fi

    local default_iface
    default_iface=$(detect_default_iface)

    if [[ "$YES" == "true" ]]; then
        if [[ -z "$default_iface" ]]; then
            error "无法自动检测默认网卡，请使用 --iface 指定"
            exit 1
        fi
        IFACE="$default_iface"
        info "自动选择网卡: ${IFACE}"
        return
    fi

    local interfaces=()
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        interfaces+=("$iface")
    done < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -v '^lo$')

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        error "未找到可用网络接口"
        exit 1
    fi

    echo ""
    echo -e "  可用网络接口："
    local i
    for i in "${!interfaces[@]}"; do
        local num=$((i + 1))
        local iface_ip=""
        iface_ip=$(ip -4 addr show "${interfaces[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1 || true)
        if [[ "${interfaces[$i]}" == "$default_iface" ]]; then
            echo -e "    ${CYAN}${num})${NC}  ${interfaces[$i]}  ${DIM}(${iface_ip:-no IPv4}, 默认路由)${NC}"
        else
            echo -e "    ${CYAN}${num})${NC}  ${interfaces[$i]}  ${DIM}(${iface_ip:-no IPv4})${NC}"
        fi
    done
    echo ""

    while true; do
        echo -ne "  ${BOLD}请选择网卡编号 [默认 1]: ${NC}"
        local choice=""
        read -r choice || true
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#interfaces[@]}" ]]; then
            IFACE="${interfaces[$((choice - 1))]}"
            break
        fi
        warn "无效输入，请重新选择"
    done
}

add_rule_arg() {
    case "$1" in
        email) RFW_ARGS+=("--block-email") ;;
        http) RFW_ARGS+=("--block-http") ;;
        socks5) RFW_ARGS+=("--block-socks5") ;;
        fet-strict) RFW_ARGS+=("--block-fet-strict") ;;
        fet-loose) RFW_ARGS+=("--block-fet-loose") ;;
        wireguard) RFW_ARGS+=("--block-wireguard") ;;
        quic) RFW_ARGS+=("--block-quic") ;;
        all) RFW_ARGS+=("--block-all") ;;
        none) ;;
        *)
            error "未知规则: $1"
            error "可用规则: default, all-protocols, none, all, email,http,socks5,fet-strict,fet-loose,wireguard,quic"
            exit 1 ;;
    esac
}

build_rules_from_list() {
    local list="$1"
    list=$(echo "$list" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

    case "$list" in
        ""|"default")
            list="email,http,socks5,fet-strict,wireguard"
            SUMMARY_RULES="Email/HTTP/SOCKS5/FET-Strict/WireGuard" ;;
        "all-protocols")
            list="email,http,socks5,fet-strict,wireguard,quic"
            SUMMARY_RULES="Email/HTTP/SOCKS5/FET-Strict/WireGuard/QUIC" ;;
        "all")
            SUMMARY_RULES="所有入站" ;;
        "none")
            SUMMARY_RULES="无协议屏蔽" ;;
        *)
            SUMMARY_RULES=$(echo "$list" | tr ',' '/') ;;
    esac

    local old_ifs="$IFS"
    IFS=','
    read -ra parts <<< "$list"
    IFS="$old_ifs"

    local has_fet_strict="false"
    local has_fet_loose="false"
    local part
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        [[ "$part" == "fet-strict" ]] && has_fet_strict="true"
        [[ "$part" == "fet-loose" ]] && has_fet_loose="true"
        add_rule_arg "$part"
    done

    if [[ "$has_fet_strict" == "true" && "$has_fet_loose" == "true" ]]; then
        error "fet-strict 与 fet-loose 不能同时启用"
        exit 1
    fi
}

interactive_rules() {
    echo ""
    divider
    echo -e "  ${BOLD}配置 RFW 屏蔽规则${NC}"
    divider
    echo ""

    echo -e "  ┌─ 协议屏蔽（可多选，输入编号用空格分隔）──────────"
    echo -e "  │   1) 屏蔽邮件发送       SMTP 25/587/465/2525"
    echo -e "  │   2) 屏蔽 HTTP 入站     明文 HTTP 协议探测"
    echo -e "  │   3) 屏蔽 SOCKS5 入站   代理协议探测"
    echo -e "  │   4) 屏蔽全加密流量     SS/V2Ray（严格模式）"
    echo -e "  │   5) 屏蔽 WireGuard     VPN 协议探测"
    echo -e "  │   6) 屏蔽 QUIC/HTTP3    QUIC 协议"
    echo -e "  │   7) 屏蔽所有入站       最激进模式"
    echo -e "  │"
    echo -e "  │   A) 全选(1-6)  D) 默认(1-5)  C) 清空"
    echo -e "  └──────────────────────────────────────────────────"
    echo ""
    echo -ne "  ${BOLD}请选择 [默认 D]: ${NC}"

    local choice=""
    read -r choice || true
    choice=$(echo "${choice:-D}" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
        A) RULES="all-protocols" ;;
        D) RULES="default" ;;
        C) RULES="none" ;;
        *)
            local selected=()
            local c
            for c in $choice; do
                case "$c" in
                    1) selected+=("email") ;;
                    2) selected+=("http") ;;
                    3) selected+=("socks5") ;;
                    4) selected+=("fet-strict") ;;
                    5) selected+=("wireguard") ;;
                    6) selected+=("quic") ;;
                    7) selected=("all"); break ;;
                    *) warn "忽略未知选项: $c" ;;
                esac
            done
            RULES=$(IFS=, ; echo "${selected[*]:-none}") ;;
    esac
}

interactive_geoip() {
    echo ""
    echo -e "  ┌─ GeoIP 过滤模式 ──────────────────────────────────"
    echo -e "  │   1) 黑名单模式   屏蔽指定国家（推荐）"
    echo -e "  │   2) 白名单模式   仅允许指定国家"
    echo -e "  │   3) 不使用 GeoIP 全局协议过滤"
    echo -e "  └──────────────────────────────────────────────────"
    echo ""
    echo -ne "  ${BOLD}请选择 [默认 1]: ${NC}"
    local geo_choice=""
    read -r geo_choice || true
    geo_choice="${geo_choice:-1}"

    local countries=""
    case "$geo_choice" in
        1)
            echo -ne "  ${BOLD}请输入国家代码（逗号分隔）[默认 CN]: ${NC}"
            read -r countries || true
            countries=$(normalize_countries "${countries:-CN}")
            if [[ "$RULES" == "all" ]]; then
                BLOCK_ALL_FROM="$countries"
            else
                COUNTRIES="$countries"
            fi ;;
        2)
            echo -ne "  ${BOLD}请输入允许国家代码（逗号分隔）[默认 CN]: ${NC}"
            read -r countries || true
            ALLOW_ONLY_COUNTRIES=$(normalize_countries "${countries:-CN}") ;;
        3)
            ;;
        *)
            warn "无效选项，默认不使用 GeoIP" ;;
    esac
}

configure_firewall_args() {
    RFW_ARGS=()

    if [[ -z "$RULES" && "$YES" != "true" ]]; then
        interactive_rules
    fi

    build_rules_from_list "${RULES:-default}"

    if [[ -z "$COUNTRIES" && -z "$ALLOW_ONLY_COUNTRIES" && -z "$BLOCK_ALL_FROM" && "$YES" != "true" ]]; then
        interactive_geoip
    fi

    COUNTRIES=$(normalize_countries "$COUNTRIES")
    ALLOW_ONLY_COUNTRIES=$(normalize_countries "$ALLOW_ONLY_COUNTRIES")
    BLOCK_ALL_FROM=$(normalize_countries "$BLOCK_ALL_FROM")

    if [[ -n "$BLOCK_ALL_FROM" ]]; then
        RFW_ARGS=()
        RFW_ARGS+=("--countries" "$BLOCK_ALL_FROM" "--block-all")
        SUMMARY_RULES="所有入站"
        SUMMARY_GEO="黑名单 (${BLOCK_ALL_FROM})"
    elif [[ -n "$ALLOW_ONLY_COUNTRIES" ]]; then
        RFW_ARGS+=("--allow-only-countries" "$ALLOW_ONLY_COUNTRIES")
        SUMMARY_GEO="白名单 (${ALLOW_ONLY_COUNTRIES})"
    elif [[ -n "$COUNTRIES" ]]; then
        RFW_ARGS+=("--countries" "$COUNTRIES")
        SUMMARY_GEO="黑名单 (${COUNTRIES})"
    else
        SUMMARY_GEO="不使用 GeoIP"
    fi

    if [[ "$LOG_PORT_ACCESS" != "true" && "$YES" != "true" ]]; then
        echo ""
        echo -ne "  ${BOLD}启用端口访问日志？${NC}[y/N]: "
        local log_choice=""
        read -r log_choice || true
        [[ "${log_choice:-}" =~ ^[yY]$ ]] && LOG_PORT_ACCESS="true"
    fi

    if [[ "$LOG_PORT_ACCESS" == "true" ]]; then
        RFW_ARGS+=("--log-port-access")
        SUMMARY_LOG="开启"
    else
        SUMMARY_LOG="关闭"
    fi
}

shell_quote() {
    local quoted=()
    local arg
    for arg in "$@"; do
        quoted+=("$(printf "%q" "$arg")")
    done
    echo "${quoted[*]}"
}

confirm_install() {
    local cmd_args
    cmd_args=$(shell_quote "${RFW_ARGS[@]}")

    echo ""
    divider
    echo -e "  ${BOLD}部署确认${NC}"
    divider
    echo -e "  安装目录  :  ${GREEN}${INSTALL_DIR}${NC}"
    echo -e "  服务名称  :  ${GREEN}${SERVICE_NAME}.service${NC}"
    echo -e "  监听网卡  :  ${GREEN}${IFACE}${NC}"
    echo -e "  屏蔽规则  :  ${GREEN}${SUMMARY_RULES}${NC}"
    echo -e "  GeoIP     :  ${GREEN}${SUMMARY_GEO}${NC}"
    echo -e "  端口日志  :  ${GREEN}${SUMMARY_LOG}${NC}"
    echo -e "  运行参数  :  ${DIM}${cmd_args}${NC}"
    divider
    echo ""

    if [[ "$YES" == "true" ]]; then
        return
    fi

    echo -ne "  ${YELLOW}确认开始部署？${NC}[Y/n]: "
    local confirm=""
    read -r confirm || true
    if [[ "${confirm:-Y}" =~ ^[nN]$ ]]; then
        info "已取消部署"
        exit 0
    fi
}

stop_existing_service() {
    if service_exists; then
        info "停止现有 ${SERVICE_NAME}.service..."
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
}

service_exists() {
    [[ -f "$SERVICE_FILE" ]] && return 0
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl cat "$SERVICE_NAME" >/dev/null 2>&1
}

show_runtime_overview() {
    local bin_state="${DIM}未安装${NC}"
    local service_state="${DIM}未注册${NC}"
    local enabled_state="${DIM}unknown${NC}"
    local shortcut_state="${DIM}未安装${NC}"
    local manager_state="${DIM}未安装${NC}"
    local iface_state="${DIM}未知${NC}"
    local exec_start=""

    if [[ -x "$BIN_PATH" ]]; then
        bin_state="${GREEN}已安装${NC}"
    elif [[ -f "$BIN_PATH" ]]; then
        bin_state="${YELLOW}存在但不可执行${NC}"
    fi

    if [[ -L "$SHORTCUT_PATH" ]]; then
        local shortcut_target=""
        shortcut_target=$(readlink "$SHORTCUT_PATH" 2>/dev/null || true)
        if [[ "$shortcut_target" == "$BIN_PATH" ]]; then
            shortcut_state="${RED}旧版二进制入口${NC}"
        else
            shortcut_state="${GREEN}已安装${NC}${shortcut_target:+ ${DIM}-> ${shortcut_target}${NC}}"
        fi
    elif [[ -x "$SHORTCUT_PATH" ]]; then
        shortcut_state="${GREEN}已安装${NC}"
    fi

    if [[ -f "$MANAGER_PATH" ]]; then
        manager_state="${GREEN}已安装${NC}"
    fi

    if command -v systemctl >/dev/null 2>&1 && service_exists; then
        local active=""
        active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
        local enabled=""
        enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)
        if [[ "$active" == "active" ]]; then
            service_state="${GREEN}运行中${NC}"
        elif [[ "$active" == "inactive" ]]; then
            service_state="${YELLOW}已停止${NC}"
        elif [[ "$active" == "failed" ]]; then
            service_state="${RED}失败${NC}"
        else
            service_state="${YELLOW}${active:-unknown}${NC}"
        fi
        enabled_state="${enabled:-unknown}"

        if [[ -f "$SERVICE_FILE" ]]; then
            exec_start=$(grep '^ExecStart=' "$SERVICE_FILE" 2>/dev/null || true)
            if [[ "$exec_start" =~ --iface[[:space:]]+([^[:space:]]+) ]]; then
                iface_state="${BASH_REMATCH[1]}"
            fi
        fi
    fi

    divider
    echo -e "  ${BOLD}当前状态${NC}"
    echo -e "  RFW 二进制 : ${bin_state}"
    echo -e "  RFW 服务   : ${service_state} / ${enabled_state}"
    echo -e "  监听网卡   : ${iface_state}"
    echo -e "  管理命令   : ${shortcut_state}"
    echo -e "  管理脚本   : ${manager_state}"
    divider
    echo ""
}

cleanup_bpf_pin() {
    if [[ -e "$BPF_PIN_PATH" ]]; then
        info "清理残留 BPF map: ${BPF_PIN_PATH}"
        rm -f "$BPF_PIN_PATH" 2>/dev/null || true
    fi
}

download_binary() {
    local arch_suffix
    arch_suffix=$(detect_arch)
    local url="${RELEASE_URL}/rfw-${arch_suffix}-unknown-linux-musl"
    local tmp_file="${BIN_PATH}.tmp"

    step "下载 RFW 程序..."
    mkdir -p "$INSTALL_DIR"

    local attempt
    for attempt in 1 2 3; do
        info "下载 ${url}（第 ${attempt} 次）"
        if curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp_file"; then
            mv "$tmp_file" "$BIN_PATH"
            chmod 0755 "$BIN_PATH"
            log "RFW 下载完成: ${BIN_PATH}"
            return
        fi
        rm -f "$tmp_file"
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    error "RFW 下载失败"
    error "下载地址: ${url}"
    exit 1
}

write_service() {
    local service_args
    service_args=$(shell_quote "${RFW_ARGS[@]}")

    step "写入 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Incubal Firewall RFW Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
ExecStartPre=-/bin/rm -f ${BPF_PIN_PATH}
ExecStart=${BIN_PATH} --iface ${IFACE} ${service_args}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "服务文件已写入: ${SERVICE_FILE}"
}

install_shortcut() {
    require_root
    require_linux

    mkdir -p "$INSTALL_DIR"
    if [[ -f "$0" ]]; then
        local source_script=""
        source_script=$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")
        local target_script=""
        target_script=$(readlink -f "$MANAGER_PATH" 2>/dev/null || printf '%s\n' "$MANAGER_PATH")
        if [[ "$source_script" != "$target_script" ]]; then
            cp -f "$source_script" "$MANAGER_PATH"
            printf '%s\n' "$source_script" > "$SOURCE_PATH_FILE"
        elif [[ ! -f "$SOURCE_PATH_FILE" ]]; then
            printf '%s\n' "$source_script" > "$SOURCE_PATH_FILE"
        fi
    elif [[ ! -f "$MANAGER_PATH" ]]; then
        error "未找到部署脚本实体文件，无法创建管理快捷命令"
        error "请使用文件方式运行脚本，例如: sudo bash Incubal-Firewall.sh --install-shortcut"
        exit 1
    fi
    chmod 0755 "$MANAGER_PATH"

    mkdir -p "$(dirname "$SHORTCUT_PATH")"
    # 旧版本把 incudalrfw 做成指向 rfw 二进制的 symlink。
    # 必须先删除路径本身，否则重定向会跟随 symlink 写坏目标二进制。
    rm -f "$SHORTCUT_PATH"
    cat > "$SHORTCUT_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

MANAGER="${MANAGER_PATH}"
RFW_BIN="${BIN_PATH}"

if [[ "\${1:-}" == "raw" ]]; then
    shift
    if [[ ! -x "\$RFW_BIN" ]]; then
        echo "RFW 二进制不存在或不可执行: \$RFW_BIN" >&2
        exit 1
    fi
    exec "\$RFW_BIN" "\$@"
fi

case "\${1:-}" in
    stats|run|help)
        if [[ ! -x "\$RFW_BIN" ]]; then
            echo "RFW 二进制不存在或不可执行: \$RFW_BIN" >&2
            exit 1
        fi
        exec "\$RFW_BIN" "\$@"
        ;;
esac

if [[ ! -f "\$MANAGER" ]]; then
    echo "Incubal-Firewall 管理脚本不存在: \$MANAGER" >&2
    exit 1
fi
exec bash "\$MANAGER" "\$@"
EOF
    chmod 0755 "$SHORTCUT_PATH"
    if [[ -x "$BIN_PATH" ]]; then
        chmod 0755 "$BIN_PATH"
    else
        warn "未找到 RFW 二进制: ${BIN_PATH}，快捷菜单仍可使用，部署完成后 raw/stats 命令才可用"
    fi
    log "快捷命令已安装: ${SHORTCUT_PATH} -> ${MANAGER_PATH}"
}

start_service() {
    step "启动 RFW 服务..."
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    cleanup_bpf_pin
    systemctl restart "$SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "RFW 服务已启动"
    else
        error "RFW 服务启动失败"
        error "请查看日志: journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        exit 1
    fi
}

install_firewall() {
    require_root
    require_linux
    ensure_dependencies

    step "检测部署环境..."
    select_interface
    log "使用网卡: ${IFACE}"

    configure_firewall_args
    confirm_install
    stop_existing_service
    cleanup_bpf_pin
    download_binary
    write_service
    install_shortcut
    start_service

    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}  ║                                                  ║${NC}"
    echo -e "${GREEN}  ║        ✓  Incubal-Firewall 部署完成              ║${NC}"
    echo -e "${GREEN}  ║                                                  ║${NC}"
    echo -e "${GREEN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  查看状态: ${DIM}systemctl status ${SERVICE_NAME}${NC}"
    echo -e "  查看日志: ${DIM}journalctl -u ${SERVICE_NAME} -f${NC}"
    echo -e "  进入菜单: ${DIM}sudo incudalrfw${NC}"
    if [[ "$LOG_PORT_ACCESS" == "true" ]]; then
        echo -e "  查看统计: ${DIM}sudo incudalrfw --blocked-stats${NC}"
    fi
    echo ""
}

status_firewall() {
    require_linux

    divider
    echo -e "  ${BOLD}${PROJECT_NAME} 状态${NC}"
    divider

    if [[ -x "$BIN_PATH" ]]; then
        echo -e "  二进制    :  ${GREEN}${BIN_PATH}${NC}"
    else
        echo -e "  二进制    :  ${DIM}未安装${NC}"
    fi

    if [[ -L "$SHORTCUT_PATH" || -x "$SHORTCUT_PATH" ]]; then
        local shortcut_target=""
        shortcut_target=$(readlink "$SHORTCUT_PATH" 2>/dev/null || true)
        echo -e "  管理命令  :  ${GREEN}${SHORTCUT_PATH}${NC}${shortcut_target:+ -> ${shortcut_target}}"
    else
        echo -e "  管理命令  :  ${DIM}未安装，可执行 sudo bash Incubal-Firewall.sh --install-shortcut${NC}"
    fi

    if [[ -f "$MANAGER_PATH" ]]; then
        echo -e "  管理脚本  :  ${GREEN}${MANAGER_PATH}${NC}"
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "  服务文件  :  ${GREEN}${SERVICE_FILE}${NC}"
        local exec_start=""
        exec_start=$(grep '^ExecStart=' "$SERVICE_FILE" 2>/dev/null || true)
        [[ -n "$exec_start" ]] && echo -e "  启动命令  :  ${DIM}${exec_start#ExecStart=}${NC}"
    else
        echo -e "  服务文件  :  ${DIM}未安装${NC}"
    fi

    if command -v systemctl >/dev/null 2>&1 && service_exists; then
        local active=""
        active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)
        local enabled=""
        enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)
        echo -e "  服务状态  :  ${GREEN}${active:-unknown}${NC} / ${enabled:-unknown}"
    else
        echo -e "  服务状态  :  ${DIM}未注册${NC}"
    fi

    divider
}

require_rfw_binary() {
    require_linux

    if [[ -x "$BIN_PATH" ]]; then
        echo "$BIN_PATH"
        return
    fi

    error "未找到 RFW 二进制"
    error "请先执行部署，或确认 ${BIN_PATH} 存在"
    exit 1
}

build_stats_args() {
    local mode="$1"
    local args=("stats")

    if [[ "$mode" == "blocked" ]]; then
        args+=("--blocked-only")
    fi

    if [[ -n "$STATS_PORT" ]]; then
        args+=("--port" "$STATS_PORT")
    fi

    if [[ -n "$STATS_IP" ]]; then
        args+=("--ip" "$STATS_IP")
    fi

    if [[ "$STATS_GROUP_BY_PORT" == "true" ]]; then
        args+=("--group-by-port")
    fi

    printf '%s\n' "${args[@]}"
}

show_port_stats() {
    local mode="${1:-all}"
    local rfw_bin
    rfw_bin=$(require_rfw_binary)
    local args=()
    mapfile -t args < <(build_stats_args "$mode")

    divider
    if [[ "$mode" == "blocked" ]]; then
        echo -e "  ${BOLD}阻断统计（来源 IP / 协议 / 目标端口 / 次数）${NC}"
    else
        echo -e "  ${BOLD}端口访问统计（允许 / 阻断累计）${NC}"
    fi
    divider
    "$rfw_bin" "${args[@]}"
    divider
}

watch_port_stats() {
    local rfw_bin
    rfw_bin=$(require_rfw_binary)
    local args=()
    mapfile -t args < <(build_stats_args "blocked")

    info "每 ${STATS_INTERVAL} 秒刷新阻断统计，按 Ctrl-C 退出"
    while true; do
        clear 2>/dev/null || true
        echo -e "${BOLD}${PROJECT_NAME} 阻断统计监控$(date '+%F %T')${NC}"
        divider
        "$rfw_bin" "${args[@]}" || true
        sleep "$STATS_INTERVAL"
    done
}

service_control() {
    local command="$1"
    local label="$2"

    require_root
    ensure_systemctl

    if ! service_exists; then
        warn "RFW 服务未安装"
        return 0
    fi

    step "${label} RFW 服务..."
    if [[ "$command" == "start" || "$command" == "restart" ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        cleanup_bpf_pin
    fi
    systemctl "$command" "$SERVICE_NAME"
    sleep 1
    status_firewall
}

show_recent_logs() {
    ensure_systemctl

    if ! service_exists; then
        warn "RFW 服务未安装"
        return 0
    fi

    divider
    echo -e "  ${BOLD}最近 80 行日志${NC}"
    divider
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager
    divider
}

show_blocked_logs() {
    ensure_systemctl

    local log_file=""
    log_file=$(mktemp)
    trap 'rm -f "$log_file"' RETURN

    if ! service_exists; then
        warn "RFW 服务未安装"
        warn "确认服务是否正在运行: systemctl status ${SERVICE_NAME} --no-pager"
        warn "查看原始日志: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
    else
        journalctl -u "$SERVICE_NAME" -n 300 --no-pager > "$log_file" 2>/dev/null || true
    fi

    divider
    echo -e "  ${BOLD}最近阻断明细日志${NC}"
    divider
    if ! grep --color=never -E "BLOCKED|被阻止|阻止|阻断" "$log_file"; then
        warn "最近 300 行 systemd 日志里没有匹配到阻断明细"
        warn "确认服务是否正在运行: systemctl status ${SERVICE_NAME} --no-pager"
        warn "查看原始日志: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
        warn "如果你是手动运行 /opt/incubal-firewall/rfw，阻断明细会输出在当前终端，而不是 journalctl"
    fi
    divider
}

watch_blocked_logs() {
    ensure_systemctl

    if ! service_exists; then
        warn "RFW 服务未安装"
        warn "如果你是手动运行 /opt/incubal-firewall/rfw，阻断明细会输出在当前终端，而不是 journalctl"
        return 0
    fi

    info "实时跟踪阻断明细日志，按 Ctrl-C 退出"
    journalctl -u "$SERVICE_NAME" -f --no-pager | grep --line-buffered -E "BLOCKED|被阻止|阻止|阻断"
}

uninstall_firewall() {
    require_root
    require_linux
    require_command systemctl "安装并启用 systemd"

    local script_path=""
    script_path=$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")
    local script_dir=""
    script_dir=$(dirname "$script_path")
    local legacy_script_path="${script_dir}/Incubal-Firewall"
    local source_script_path=""
    if [[ -f "$SOURCE_PATH_FILE" ]]; then
        source_script_path=$(head -n 1 "$SOURCE_PATH_FILE" 2>/dev/null || true)
    fi
    local source_script_candidates=()
    local candidate=""
    local resolved_candidate=""
    for candidate in \
        "$source_script_path" \
        "${PWD}/Incubal-Firewall.sh" \
        "${HOME:-}/Incubal-Firewall.sh" \
        "/root/Incubal-Firewall.sh"; do
        [[ -n "$candidate" && -f "$candidate" ]] || continue
        resolved_candidate=$(readlink -f "$candidate" 2>/dev/null || printf '%s\n' "$candidate")
        [[ "$resolved_candidate" != "$script_path" && "$resolved_candidate" != "$MANAGER_PATH" ]] || continue
        local exists="false"
        local existing_candidate=""
        for existing_candidate in "${source_script_candidates[@]}"; do
            if [[ "$existing_candidate" == "$resolved_candidate" ]]; then
                exists="true"
                break
            fi
        done
        [[ "$exists" == "true" ]] || source_script_candidates+=("$resolved_candidate")
    done

    echo ""
    divider
    echo -e "  ${RED}${BOLD}彻底卸载 Incubal-Firewall${NC}"
    divider
    echo -e "  将删除:"
    echo -e "    ${RED}•${NC} ${SERVICE_FILE}"
    echo -e "    ${RED}•${NC} ${INSTALL_DIR}"
    echo -e "    ${RED}•${NC} ${SHORTCUT_PATH}"
    echo -e "    ${RED}•${NC} ${BPF_PIN_PATH}"
    if [[ -f "$MANAGER_PATH" ]]; then
        echo -e "    ${RED}•${NC} ${MANAGER_PATH}"
    fi
    for candidate in "${source_script_candidates[@]}"; do
        echo -e "    ${RED}•${NC} ${candidate}"
    done
    if [[ -f "$script_path" ]]; then
        echo -e "    ${RED}•${NC} ${script_path}"
    else
        echo -e "    ${DIM}• 当前部署脚本未找到实体文件，跳过脚本自删除${NC}"
    fi
    if [[ "$legacy_script_path" != "$script_path" && -f "$legacy_script_path" ]]; then
        echo -e "    ${RED}•${NC} ${legacy_script_path}"
    fi
    echo ""

    if [[ "$YES" != "true" ]]; then
        echo -ne "  ${BOLD}确认彻底卸载？${NC}[y/N]: "
        local confirm=""
        read -r confirm || true
        if [[ ! "${confirm:-}" =~ ^[yY]$ ]]; then
            info "已取消卸载"
            exit 0
        fi
    fi

    info "停止 RFW 服务..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE" 2>/dev/null || true
    rm -f "$SHORTCUT_PATH" 2>/dev/null || true
    cleanup_bpf_pin
    for candidate in "${source_script_candidates[@]}"; do
        info "删除原始部署脚本: ${candidate}"
        rm -f "$candidate" 2>/dev/null || warn "原始部署脚本删除失败，请手动删除: ${candidate}"
    done
    rm -f "$MANAGER_PATH" 2>/dev/null || true
    rm -rf "$INSTALL_DIR" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if [[ -f "$script_path" ]]; then
        info "删除部署脚本: ${script_path}"
        rm -f "$script_path" 2>/dev/null || warn "部署脚本删除失败，请手动删除: ${script_path}"
    fi
    if [[ "$legacy_script_path" != "$script_path" && -f "$legacy_script_path" ]]; then
        info "删除兼容入口: ${legacy_script_path}"
        rm -f "$legacy_script_path" 2>/dev/null || warn "兼容入口删除失败，请手动删除: ${legacy_script_path}"
    fi

    log "Incubal-Firewall 已彻底卸载"
    exit 0
}

run_interactive_menu() {
    while true; do
        show_banner
        show_main_menu

        local choice=""
        read -r choice || true
        echo ""

        case "$choice" in
            1)
                reset_install_options
                install_firewall
                pause_screen ;;
            2)
                status_firewall
                pause_screen ;;
            3)
                service_control start "启动"
                pause_screen ;;
            4)
                service_control stop "停止"
                pause_screen ;;
            5)
                service_control restart "重启"
                pause_screen ;;
            6)
                STATS_PORT=""
                STATS_IP=""
                STATS_GROUP_BY_PORT="false"
                show_port_stats "blocked"
                pause_screen ;;
            7)
                show_blocked_logs
                pause_screen ;;
            8)
                watch_blocked_logs
                pause_screen ;;
            9)
                show_recent_logs
                pause_screen ;;
            10)
                uninstall_firewall
                pause_screen ;;
            11)
                usage
                pause_screen ;;
            0)
                info "已退出"
                exit 0 ;;
            *)
                warn "无效选项，请重新选择"
                pause_screen ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 && -t 0 ]]; then
        run_interactive_menu
        exit 0
    fi

    parse_args "$@"

    if [[ "$ACTION" == "install" ]]; then
        show_banner
    fi

    case "$ACTION" in
        install) install_firewall ;;
        status) status_firewall ;;
        start) service_control start "启动" ;;
        stop) service_control stop "停止" ;;
        restart) service_control restart "重启" ;;
        stats) show_port_stats "all" ;;
        blocked-stats) show_port_stats "blocked" ;;
        watch-stats) watch_port_stats ;;
        blocked-logs) show_blocked_logs ;;
        watch-blocked) watch_blocked_logs ;;
        logs) show_recent_logs ;;
        install-shortcut) install_shortcut ;;
        uninstall) uninstall_firewall ;;
        *)
            error "未知动作: ${ACTION}"
            exit 1 ;;
    esac
}

main "$@"

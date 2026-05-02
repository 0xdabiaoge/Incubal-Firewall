#!/usr/bin/env bash
# Incudal-RFW deployment and firewall backend manager.
# UTF-8 script. Supports Debian/Ubuntu with nftables, iptables/ipset, and XDP.

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly DEFAULT_RELEASE_URL="https://github.com/0xdabiaoge/incudal-rfw/releases/latest/download"
readonly RFW_SERVICE_NAME="rfw"
readonly RFW_INSTALL_DIR="/root/rfw"
readonly RFW_BIN_PATH="${RFW_INSTALL_DIR}/rfw"
readonly RFW_ETC_DIR="/etc/rfw"
readonly RFW_STATE_DIR="/var/lib/rfw"
readonly RFW_LIB_DIR="/usr/local/lib/rfw"
readonly RFW_SERVICE_FILE="/etc/systemd/system/${RFW_SERVICE_NAME}.service"
readonly RFW_CONFIG_FILE="${RFW_ETC_DIR}/config.env"
readonly RFW_NFT_FILE="${RFW_ETC_DIR}/rfw.nft"
readonly RFW_GEO_FILE="${RFW_STATE_DIR}/geo4.cidr"
readonly RFW_APPLY_IPTABLES="${RFW_LIB_DIR}/apply-iptables.sh"
readonly RFW_CLEAR_IPTABLES="${RFW_LIB_DIR}/clear-iptables.sh"
readonly RFW_IPSET_NAME="rfw_geo4"
readonly RFW_IPTABLES_CHAIN="RFW_INPUT"

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

ACTION="menu"
BACKEND="auto"
IFACE=""
XDP_MODE="auto"
GEO_MODE="blacklist"
COUNTRIES="CN"
SELECTED_RULES=""
RFW_ARGS=""
CUSTOM_RFW_ARGS="false"
LOG_PORT_ACCESS="false"
BINARY_URL=""
RELEASE_URL="$DEFAULT_RELEASE_URL"
NON_INTERACTIVE="false"
FORCE="false"
KEEP_SCRIPT="true"

RULE_FLAGS=(
    "--block-email"
    "--block-http"
    "--block-socks5"
    "--block-fet-strict"
    "--block-fet-loose"
    "--block-wireguard"
    "--block-quic"
    "--block-hysteria2"
    "--block-tuic"
    "--block-udp-fet"
    "--block-vless-tcp"
    "--block-vmess-tcp"
    "--block-all"
)

RULE_NAMES=(
    "邮件端口"
    "明文 HTTP 端口"
    "SOCKS 常见端口"
    "FET 严格识别"
    "FET 宽松识别"
    "WireGuard 常见端口"
    "QUIC 常见端口"
    "Hysteria2 常见端口"
    "TUIC 常见端口"
    "UDP-FET 识别"
    "VLESS TCP 识别"
    "VMess TCP 识别"
    "全部入站"
)

RULE_NOTES_FIREWALL=(
    "tcp 25,465,587,110,995,143,993"
    "tcp 80,8000,8080,8880,8888"
    "tcp 1080,1086,10808,7890,7891"
    "仅 XDP 支持 payload 识别"
    "仅 XDP 支持 payload 识别"
    "udp 51820"
    "udp 443,8443"
    "udp 443,8443,36712"
    "udp 443,8443"
    "仅 XDP 支持 payload 识别"
    "仅 XDP 支持 payload 识别"
    "仅 XDP 支持 payload 识别"
    "直接 drop 匹配来源的全部入站"
)

readonly DEFAULT_RULES="--block-email --block-http --block-socks5 --block-wireguard --block-quic --block-hysteria2 --block-tuic"

log() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; }
step() { echo -e "\n${CYAN}[>]${NC} ${BOLD}$1${NC}"; }
divider() { echo -e "${DIM}------------------------------------------------------------${NC}"; }
wide_divider() { echo -e "${DIM}============================================================${NC}"; }

usage() {
    cat <<EOF
Incudal-RFW 部署脚本 v${SCRIPT_VERSION}

用法:
  sudo bash rfw-test-deploy.sh
  sudo bash rfw-test-deploy.sh --install --backend nft --countries CN --yes
  sudo bash rfw-test-deploy.sh --install --backend iptables --geo-mode none --yes
  sudo bash rfw-test-deploy.sh --install --backend xdp --iface eth0 --xdp-mode skb --yes
  sudo bash rfw-test-deploy.sh --status
  sudo bash rfw-test-deploy.sh --logs
  sudo bash rfw-test-deploy.sh --restart
  sudo bash rfw-test-deploy.sh --uninstall

后端:
  auto       默认。优先 nft，缺失时用 iptables。
  nft        推荐。使用 systemd oneshot + nftables，资源占用低，启动稳定。
  iptables   兼容。使用 iptables + ipset，适合老系统或 nft 不可用环境。
  xdp        高级。使用原 rfw eBPF 程序，支持深度协议识别，但依赖内核和网卡。

常用参数:
  --backend <auto|nft|iptables|xdp>
  --iface <网卡>                       nft/iptables 可选；xdp 必填
  --geo-mode <blacklist|whitelist|none> 默认 blacklist
  --countries <国家代码>                默认 CN，支持 CN,US 或 "CN US"
  --rules "<规则参数>"                  覆盖脚本生成规则
  --log-port-access                    仅 xdp 支持端口统计
  --xdp-mode <auto|skb|drv|hw>          仅 xdp 使用
  --binary-url <URL>                    仅 xdp 需要下载 rfw 二进制
  --release-url <URL>
  --yes                                非交互执行
  --force                              跳过确认
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 权限运行：sudo bash $0"
        exit 1
    fi
}

require_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "${flag} 缺少参数值"
        exit 1
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

is_http_url() {
    [[ "${1:-}" =~ ^https?://[^[:space:]]+$ ]]
}

is_yes() {
    [[ "${1:-}" =~ ^([yY]|[yY][eE][sS]|1|是|确认|好)$ ]]
}

confirm() {
    local prompt="$1"
    if [[ "$NON_INTERACTIVE" == "true" || "$FORCE" == "true" ]]; then
        return 0
    fi
    echo -ne "${YELLOW}${prompt}${NC} [y/N]: "
    local answer=""
    read -r answer || true
    is_yes "$answer"
}

prompt_input() {
    local prompt="$1"
    local default_value="$2"
    local answer=""
    if [[ -n "$default_value" ]]; then
        echo -ne "${BOLD}${prompt}${NC} ${DIM}[默认: ${default_value}]${NC}: " >&2
    else
        echo -ne "${BOLD}${prompt}${NC}: " >&2
    fi
    read -r answer || true
    printf '%s\n' "${answer:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local hint="[y/N]"
    [[ "$default_answer" == "yes" ]] && hint="[Y/n]"
    echo -ne "${BOLD}${prompt}${NC} ${hint}: "
    local answer=""
    read -r answer || true
    if [[ -z "$answer" ]]; then
        [[ "$default_answer" == "yes" ]]
        return
    fi
    is_yes "$answer"
}

pause_enter() {
    [[ "$NON_INTERACTIVE" == "true" ]] && return 0
    echo ""
    echo -ne "${DIM}按回车继续...${NC}"
    read -r _ || true
}

normalize_spaces() {
    local token=""
    local out=""
    for token in ${1:-}; do
        out="${out} ${token}"
    done
    printf '%s\n' "${out# }"
}

shell_quote() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

systemd_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

has_word() {
    [[ " ${1:-} " == *" $2 "* ]]
}

add_word() {
    local list="${1:-}"
    local word="$2"
    if has_word "$list" "$word"; then
        normalize_spaces "$list"
    else
        normalize_spaces "${list} ${word}"
    fi
}

remove_word() {
    local list="${1:-}"
    local word="$2"
    local token=""
    local out=""
    for token in $list; do
        [[ "$token" == "$word" ]] && continue
        out="${out} ${token}"
    done
    normalize_spaces "$out"
}

rule_count() {
    echo "${#RULE_FLAGS[@]}"
}

rule_index_for_flag() {
    local flag="$1"
    local i=""
    for i in "${!RULE_FLAGS[@]}"; do
        if [[ "${RULE_FLAGS[$i]}" == "$flag" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

rule_name_by_flag() {
    local flag="$1"
    local i=""
    if i=$(rule_index_for_flag "$flag"); then
        echo "${RULE_NAMES[$i]}"
    else
        echo "$flag"
    fi
}

rules_to_names() {
    local flag=""
    local out=""
    for flag in ${1:-}; do
        out="${out}$(rule_name_by_flag "$flag")、"
    done
    out="${out%、}"
    printf '%s\n' "${out:-无}"
}

expand_selection_tokens() {
    local input="$1"
    local token=""
    local start=""
    local end=""
    local i=""
    input=${input//,/ }
    input=${input//，/ }
    for token in $input; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( start <= end )); then
                for ((i = start; i <= end; i++)); do echo "$i"; done
            else
                for ((i = start; i >= end; i--)); do echo "$i"; done
            fi
        else
            echo "$token"
        fi
    done
}

flag_from_rule_token() {
    local token="$1"
    token=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
    if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= $(rule_count) )); then
        echo "${RULE_FLAGS[$((token - 1))]}"
        return 0
    fi
    case "$token" in
        mail|email|smtp) echo "--block-email" ;;
        http|web) echo "--block-http" ;;
        socks|socks5) echo "--block-socks5" ;;
        fet|fet-strict|strict) echo "--block-fet-strict" ;;
        fet-loose|loose) echo "--block-fet-loose" ;;
        wg|wireguard) echo "--block-wireguard" ;;
        quic) echo "--block-quic" ;;
        hy2|hysteria2) echo "--block-hysteria2" ;;
        tuic) echo "--block-tuic" ;;
        udp-fet|udpfet) echo "--block-udp-fet" ;;
        vless|vless-tcp) echo "--block-vless-tcp" ;;
        vmess|vmess-tcp) echo "--block-vmess-tcp" ;;
        all|block-all|danger) echo "--block-all" ;;
        *) return 1 ;;
    esac
}

sanitize_rule_conflicts() {
    if has_word "$SELECTED_RULES" "--block-fet-strict" && has_word "$SELECTED_RULES" "--block-fet-loose"; then
        SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-loose")
        warn "FET 严格和宽松不能同时启用，已保留严格模式。"
    fi
}

sync_selected_rules_from_text() {
    local text="${1:-}"
    local flag=""
    local out=""
    for flag in "${RULE_FLAGS[@]}"; do
        if has_word "$text" "$flag"; then
            out=$(add_word "$out" "$flag")
        fi
    done
    SELECTED_RULES="${out:-$DEFAULT_RULES}"
}

toggle_rule() {
    local flag="$1"
    if has_word "$SELECTED_RULES" "$flag"; then
        SELECTED_RULES=$(remove_word "$SELECTED_RULES" "$flag")
    else
        [[ "$flag" == "--block-fet-strict" ]] && SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-loose")
        [[ "$flag" == "--block-fet-loose" ]] && SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-strict")
        SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag")
    fi
    sanitize_rule_conflicts
}

tcp_ports_for_firewall() {
    local flag=""
    local ports=""
    for flag in $SELECTED_RULES; do
        case "$flag" in
            --block-email) ports="${ports} 25 465 587 110 995 143 993" ;;
            --block-http) ports="${ports} 80 8000 8080 8880 8888" ;;
            --block-socks5) ports="${ports} 1080 1086 10808 7890 7891" ;;
        esac
    done
    normalize_port_list "$ports"
}

udp_ports_for_firewall() {
    local flag=""
    local ports=""
    for flag in $SELECTED_RULES; do
        case "$flag" in
            --block-wireguard) ports="${ports} 51820" ;;
            --block-quic) ports="${ports} 443 8443" ;;
            --block-hysteria2) ports="${ports} 443 8443 36712" ;;
            --block-tuic) ports="${ports} 443 8443" ;;
        esac
    done
    normalize_port_list "$ports"
}

normalize_port_list() {
    local ports="${1:-}"
    local p=""
    local out=""
    local seen=" "
    for p in $ports; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        if [[ "$seen" != *" $p "* ]]; then
            out="${out} ${p}"
            seen="${seen}${p} "
        fi
    done
    printf '%s\n' "${out# }"
}

unsupported_firewall_rules() {
    local flag=""
    local out=""
    for flag in $SELECTED_RULES; do
        case "$flag" in
            --block-fet-strict|--block-fet-loose|--block-udp-fet|--block-vless-tcp|--block-vmess-tcp)
                out="${out} $(rule_name_by_flag "$flag")"
                ;;
        esac
    done
    normalize_spaces "$out"
}

country_tokens() {
    printf '%s\n' "${COUNTRIES:-}" | sed 's/[，,;]/ /g' | tr '[:lower:]' '[:upper:]'
}

validate_common_options() {
    case "$BACKEND" in
        auto|nft|iptables|xdp) ;;
        *) error "--backend 无效：${BACKEND}"; exit 1 ;;
    esac
    case "$GEO_MODE" in
        blacklist|whitelist|none) ;;
        *) error "--geo-mode 无效：${GEO_MODE}"; exit 1 ;;
    esac
    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *) error "--xdp-mode 无效：${XDP_MODE}"; exit 1 ;;
    esac
    [[ "$XDP_MODE" == "driver" ]] && XDP_MODE="drv"
    [[ "$XDP_MODE" == "hardware" ]] && XDP_MODE="hw"
    if [[ -n "$IFACE" && ! "$IFACE" =~ ^[A-Za-z0-9_.:@-]+$ ]]; then
        error "网卡名包含不支持的字符：${IFACE}"
        exit 1
    fi
}

select_backend() {
    validate_common_options
    if [[ "$BACKEND" != "auto" ]]; then
        return 0
    fi
    if have nft; then
        BACKEND="nft"
    elif have iptables && have ipset; then
        BACKEND="iptables"
    else
        BACKEND="nft"
    fi
}

detect_arch_suffix() {
    case "$(uname -m)" in
        x86_64) echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *) error "不支持当前架构：$(uname -m)。目前支持 x86_64、aarch64。"; exit 1 ;;
    esac
}

install_packages_if_needed() {
    local missing=()
    local cmd=""
    for cmd in "$@"; do
        have "$cmd" || missing+=("$cmd")
    done
    [[ "${#missing[@]}" -eq 0 ]] && return 0
    if ! have apt-get; then
        error "缺少命令：${missing[*]}。当前脚本自动安装仅支持 Debian/Ubuntu 的 apt-get。"
        exit 1
    fi
    step "安装依赖：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    local packages=(curl ca-certificates iproute2)
    case "$BACKEND" in
        nft) packages+=(nftables) ;;
        iptables) packages+=(iptables ipset) ;;
        xdp) packages+=(curl iproute2) ;;
    esac
    apt-get install -y "${packages[@]}"
}

ensure_dependencies() {
    require_root
    have systemctl || { error "缺少 systemctl，本脚本需要 systemd。"; exit 1; }
    case "$BACKEND" in
        nft) install_packages_if_needed curl ip nft ;;
        iptables) install_packages_if_needed curl ip iptables ipset ;;
        xdp) install_packages_if_needed curl ip ;;
    esac
}

choose_iface_for_xdp() {
    if [[ -n "$IFACE" ]]; then
        ip link show "$IFACE" >/dev/null 2>&1 || { error "网卡不存在：${IFACE}"; exit 1; }
        return 0
    fi
    local default_iface=""
    default_iface=$(ip route show default 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1 || true)
    if [[ -n "$default_iface" ]]; then
        IFACE="$default_iface"
        info "XDP 使用默认路由网卡：${IFACE}"
        return 0
    fi
    error "XDP 后端必须指定 --iface。"
    exit 1
}

prepare_dirs() {
    mkdir -p "$RFW_INSTALL_DIR" "$RFW_ETC_DIR" "$RFW_STATE_DIR" "$RFW_LIB_DIR"
}

save_config() {
    prepare_dirs
    cat > "$RFW_CONFIG_FILE" <<EOF
BACKEND=$(shell_quote "$BACKEND")
IFACE=$(shell_quote "$IFACE")
XDP_MODE=$(shell_quote "$XDP_MODE")
GEO_MODE=$(shell_quote "$GEO_MODE")
COUNTRIES=$(shell_quote "$COUNTRIES")
SELECTED_RULES=$(shell_quote "$SELECTED_RULES")
RFW_ARGS=$(shell_quote "$RFW_ARGS")
CUSTOM_RFW_ARGS=$(shell_quote "$CUSTOM_RFW_ARGS")
LOG_PORT_ACCESS=$(shell_quote "$LOG_PORT_ACCESS")
RELEASE_URL=$(shell_quote "$RELEASE_URL")
BINARY_URL=$(shell_quote "$BINARY_URL")
EOF
}

load_config() {
    if [[ -f "$RFW_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RFW_CONFIG_FILE"
    else
        SELECTED_RULES="$DEFAULT_RULES"
    fi
    SELECTED_RULES="${SELECTED_RULES:-$DEFAULT_RULES}"
    BACKEND="${BACKEND:-auto}"
    GEO_MODE="${GEO_MODE:-blacklist}"
    COUNTRIES="${COUNTRIES:-CN}"
    XDP_MODE="${XDP_MODE:-auto}"
}

build_generated_args() {
    if [[ "$CUSTOM_RFW_ARGS" == "true" ]]; then
        RFW_ARGS=$(normalize_spaces "$RFW_ARGS")
        sync_selected_rules_from_text "$RFW_ARGS"
        return 0
    fi
    SELECTED_RULES=$(normalize_spaces "$SELECTED_RULES")
    RFW_ARGS="$SELECTED_RULES"
    case "$GEO_MODE" in
        blacklist)
            COUNTRIES=$(country_tokens | xargs echo)
            [[ -z "$COUNTRIES" ]] && COUNTRIES="CN"
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --countries ${COUNTRIES// /,}")
            ;;
        whitelist)
            COUNTRIES=$(country_tokens | xargs echo)
            [[ -z "$COUNTRIES" ]] && { error "whitelist 模式必须指定 --countries。"; exit 1; }
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --allow-only-countries ${COUNTRIES// /,}")
            ;;
        none)
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --all-sources")
            ;;
    esac
    if [[ "$LOG_PORT_ACCESS" == "true" ]]; then
        RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --log-port-access")
    fi
}

resolve_binary_url() {
    if [[ -n "$BINARY_URL" ]]; then
        is_http_url "$BINARY_URL" || { error "--binary-url 无效：${BINARY_URL}"; exit 1; }
        echo "$BINARY_URL"
        return 0
    fi
    is_http_url "$RELEASE_URL" || { error "--release-url 无效：${RELEASE_URL}"; exit 1; }
    echo "${RELEASE_URL%/}/rfw-$(detect_arch_suffix)-unknown-linux-musl"
}

download_binary() {
    local url="$1"
    local tmp="${RFW_BIN_PATH}.download"
    prepare_dirs
    rm -f "$tmp"
    local attempt=""
    for attempt in 1 2 3; do
        info "下载 rfw 二进制，第 ${attempt} 次：${url}"
        if curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp"; then
            mv "$tmp" "$RFW_BIN_PATH"
            chmod +x "$RFW_BIN_PATH"
            log "rfw 二进制已安装：${RFW_BIN_PATH}"
            return 0
        fi
        sleep 2
    done
    rm -f "$tmp"
    error "rfw 二进制下载失败。"
    exit 1
}

download_geo_data() {
    : > "$RFW_GEO_FILE"
    [[ "$GEO_MODE" == "none" ]] && return 0

    local code=""
    local lower=""
    local url=""
    local tmp=""
    for code in $(country_tokens); do
        [[ "$code" =~ ^[A-Z]{2}$ ]] || { error "国家代码无效：${code}"; exit 1; }
        lower=$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]')
        url="https://www.ipdeny.com/ipblocks/data/aggregated/${lower}-aggregated.zone"
        tmp="${RFW_STATE_DIR}/${lower}.zone.download"
        info "下载 ${code} IPv4 CIDR：${url}"
        if ! curl -fsSL --connect-timeout 10 --max-time 90 "$url" -o "$tmp"; then
            rm -f "$tmp"
            error "下载 ${code} CIDR 失败。可改用 --geo-mode none，或检查服务器网络。"
            exit 1
        fi
        awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print}' "$tmp" >> "$RFW_GEO_FILE"
        rm -f "$tmp"
    done
    sort -u "$RFW_GEO_FILE" -o "$RFW_GEO_FILE"
    if [[ ! -s "$RFW_GEO_FILE" ]]; then
        error "Geo CIDR 数据为空。"
        exit 1
    fi
}

nft_elements_from_geo() {
    if [[ ! -s "$RFW_GEO_FILE" ]]; then
        echo "127.0.0.2/32"
        return 0
    fi
    paste -sd, "$RFW_GEO_FILE" | sed 's/,/, /g'
}

nft_port_elements() {
    local ports="$1"
    if [[ -z "$ports" ]]; then
        echo "0"
    else
        printf '%s\n' "$ports" | tr ' ' ',' | sed 's/,/, /g'
    fi
}

nft_scope_prefix() {
    case "$GEO_MODE" in
        blacklist) printf 'ip saddr @rfw_geo4 ' ;;
        whitelist) printf 'ip saddr != @rfw_geo4 ' ;;
        none) printf '' ;;
    esac
}

nft_iface_prefix() {
    [[ -n "$IFACE" ]] && printf 'iifname "%s" ' "$IFACE"
}

write_nft_rules() {
    local tcp_ports=""
    local udp_ports=""
    local geo_elements=""
    local scope=""
    local iface=""
    tcp_ports=$(tcp_ports_for_firewall)
    udp_ports=$(udp_ports_for_firewall)
    geo_elements=$(nft_elements_from_geo)
    scope=$(nft_scope_prefix)
    iface=$(nft_iface_prefix)

    cat > "$RFW_NFT_FILE" <<EOF
table inet rfw {
    set rfw_geo4 {
        type ipv4_addr
        flags interval
        elements = { ${geo_elements} }
    }

    set rfw_tcp_ports {
        type inet_service
        elements = { $(nft_port_elements "$tcp_ports") }
    }

    set rfw_udp_ports {
        type inet_service
        elements = { $(nft_port_elements "$udp_ports") }
    }

    chain input {
        type filter hook input priority 0; policy accept;
        ct state established,related accept
        iifname "lo" accept
EOF

    if has_word "$SELECTED_RULES" "--block-all"; then
        echo "        ${iface}${scope}drop comment \"rfw block all\"" >> "$RFW_NFT_FILE"
    fi
    if [[ -n "$tcp_ports" ]]; then
        echo "        ${iface}${scope}tcp dport @rfw_tcp_ports drop comment \"rfw tcp rules\"" >> "$RFW_NFT_FILE"
    fi
    if [[ -n "$udp_ports" ]]; then
        echo "        ${iface}${scope}udp dport @rfw_udp_ports drop comment \"rfw udp rules\"" >> "$RFW_NFT_FILE"
    fi

    cat >> "$RFW_NFT_FILE" <<EOF
    }
}
EOF

    nft -c -f "$RFW_NFT_FILE"
}

write_nft_service() {
    local nft_bin=""
    nft_bin=$(command -v nft)
    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=Incudal-RFW nftables blocking rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${nft_bin} -f ${RFW_NFT_FILE}
ExecStartPre=-/bin/sh -c '${nft_bin} delete table inet rfw 2>/dev/null || true'
ExecStop=/bin/sh -c '${nft_bin} delete table inet rfw 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

iptables_scope_args() {
    case "$GEO_MODE" in
        blacklist) printf '%s' "-m set --match-set ${RFW_IPSET_NAME} src" ;;
        whitelist) printf '%s' "-m set ! --match-set ${RFW_IPSET_NAME} src" ;;
        none) printf '%s' "" ;;
    esac
}

write_iptables_helpers() {
    local tcp_ports=""
    local udp_ports=""
    local iface_args=""
    local scope_args=""
    tcp_ports=$(tcp_ports_for_firewall)
    udp_ports=$(udp_ports_for_firewall)
    [[ -n "$IFACE" ]] && iface_args="-i ${IFACE}"
    scope_args=$(iptables_scope_args)

    cat > "$RFW_CLEAR_IPTABLES" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IPTABLES=\$(command -v iptables)
IPSET=\$(command -v ipset || true)
\$IPTABLES -D INPUT -j ${RFW_IPTABLES_CHAIN} 2>/dev/null || true
\$IPTABLES -F ${RFW_IPTABLES_CHAIN} 2>/dev/null || true
\$IPTABLES -X ${RFW_IPTABLES_CHAIN} 2>/dev/null || true
if [[ -n "\$IPSET" ]]; then
    \$IPSET destroy ${RFW_IPSET_NAME} 2>/dev/null || true
fi
EOF

    cat > "$RFW_APPLY_IPTABLES" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IPTABLES=\$(command -v iptables)
IPSET=\$(command -v ipset)
"${RFW_CLEAR_IPTABLES}"
if [[ "${GEO_MODE}" != "none" ]]; then
    \$IPSET create ${RFW_IPSET_NAME} hash:net family inet hashsize 4096 maxelem 262144 -exist
    while IFS= read -r cidr; do
        [[ -z "\$cidr" ]] && continue
        \$IPSET add ${RFW_IPSET_NAME} "\$cidr" -exist
    done < "${RFW_GEO_FILE}"
fi
\$IPTABLES -N ${RFW_IPTABLES_CHAIN}
\$IPTABLES -I INPUT 1 -j ${RFW_IPTABLES_CHAIN}
\$IPTABLES -A ${RFW_IPTABLES_CHAIN} -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
\$IPTABLES -A ${RFW_IPTABLES_CHAIN} -i lo -j RETURN
EOF

    if has_word "$SELECTED_RULES" "--block-all"; then
        echo "\$IPTABLES -A ${RFW_IPTABLES_CHAIN} ${iface_args} ${scope_args} -j DROP" >> "$RFW_APPLY_IPTABLES"
    fi
    local p=""
    for p in $tcp_ports; do
        echo "\$IPTABLES -A ${RFW_IPTABLES_CHAIN} ${iface_args} -p tcp --dport ${p} ${scope_args} -j DROP" >> "$RFW_APPLY_IPTABLES"
    done
    for p in $udp_ports; do
        echo "\$IPTABLES -A ${RFW_IPTABLES_CHAIN} ${iface_args} -p udp --dport ${p} ${scope_args} -j DROP" >> "$RFW_APPLY_IPTABLES"
    done
    echo "\$IPTABLES -A ${RFW_IPTABLES_CHAIN} -j RETURN" >> "$RFW_APPLY_IPTABLES"
    chmod +x "$RFW_APPLY_IPTABLES" "$RFW_CLEAR_IPTABLES"
}

write_iptables_service() {
    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=Incudal-RFW iptables blocking rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${RFW_APPLY_IPTABLES}
ExecStop=${RFW_CLEAR_IPTABLES}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

detach_xdp_from_iface() {
    local iface="${1:-}"
    [[ -n "$iface" ]] || return 0
    have ip || return 0
    ip link show "$iface" >/dev/null 2>&1 || return 0
    ip link set dev "$iface" xdp off 2>/dev/null || true
    ip link set dev "$iface" xdpgeneric off 2>/dev/null || true
    ip link set dev "$iface" xdpdrv off 2>/dev/null || true
    ip link set dev "$iface" xdpoffload off 2>/dev/null || true
}

cleanup_xdp_state() {
    detach_xdp_from_iface "$IFACE"
    rm -f /sys/fs/bpf/rfw_port_access_log 2>/dev/null || true
}

build_xdp_exec_start() {
    local command=""
    command="$(systemd_quote "$RFW_BIN_PATH")"
    command+=" --iface $(systemd_quote "$IFACE")"
    command+=" --xdp-mode $(systemd_quote "$XDP_MODE")"
    [[ -n "$RFW_ARGS" ]] && command+=" ${RFW_ARGS}"
    printf '%s\n' "$command"
}

write_xdp_service() {
    local exec_start=""
    exec_start=$(build_xdp_exec_start)
    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=Incudal-RFW XDP protocol blocking service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
Environment=RFW_IFACE=$(systemd_quote "$IFACE")
ExecStartPre=-/bin/sh -c 'ip link set dev "\$RFW_IFACE" xdp off 2>/dev/null || true; ip link set dev "\$RFW_IFACE" xdpgeneric off 2>/dev/null || true; ip link set dev "\$RFW_IFACE" xdpdrv off 2>/dev/null || true; ip link set dev "\$RFW_IFACE" xdpoffload off 2>/dev/null || true; rm -f /sys/fs/bpf/rfw_port_access_log 2>/dev/null || true'
ExecStart=${exec_start}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

stop_existing_service() {
    if systemctl list-unit-files "${RFW_SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${RFW_SERVICE_NAME}.service"; then
        systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
        systemctl reset-failed "$RFW_SERVICE_NAME" 2>/dev/null || true
    fi
    nft delete table inet rfw 2>/dev/null || true
    [[ -x "$RFW_CLEAR_IPTABLES" ]] && "$RFW_CLEAR_IPTABLES" 2>/dev/null || true
    cleanup_xdp_state
}

show_capability_warning() {
    local unsupported=""
    unsupported=$(unsupported_firewall_rules)
    if [[ "$BACKEND" != "xdp" && -n "$unsupported" ]]; then
        warn "${BACKEND} 后端无法做 payload 深度识别，以下规则不会生成内核防火墙规则：${unsupported}"
        warn "需要 VLESS/VMess/FET/UDP-FET 精细识别时，请使用 --backend xdp。"
    fi
    if [[ "$BACKEND" != "xdp" && "$LOG_PORT_ACCESS" == "true" ]]; then
        warn "端口访问统计仅 XDP 后端支持，${BACKEND} 后端会忽略 --log-port-access。"
    fi
}

show_summary() {
    divider
    echo -e "${BOLD}部署配置${NC}"
    echo "  后端        : ${BACKEND}"
    echo "  网卡        : ${IFACE:-全部入站接口}"
    echo "  Geo 模式    : ${GEO_MODE}"
    echo "  国家        : ${COUNTRIES:-无}"
    echo "  规则        : $(rules_to_names "$SELECTED_RULES")"
    [[ "$BACKEND" == "xdp" ]] && echo "  XDP 模式    : ${XDP_MODE}"
    [[ "$BACKEND" == "xdp" ]] && echo "  rfw 参数    : ${RFW_ARGS}"
    [[ "$BACKEND" == "nft" ]] && echo "  nft 文件    : ${RFW_NFT_FILE}"
    [[ "$BACKEND" == "iptables" ]] && echo "  iptables    : ${RFW_IPTABLES_CHAIN} + ${RFW_IPSET_NAME}"
    divider
}

start_and_verify_service() {
    systemctl enable "$RFW_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$RFW_SERVICE_NAME"
    sleep 1
    local state=""
    state=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
    if [[ "$state" != "active" ]]; then
        error "服务未进入 active 状态。"
        journalctl -u "$RFW_SERVICE_NAME" -n 120 --no-pager 2>/dev/null || true
        exit 1
    fi
    case "$BACKEND" in
        nft)
            nft list table inet rfw >/dev/null
            ;;
        iptables)
            iptables -S "$RFW_IPTABLES_CHAIN" >/dev/null
            ;;
        xdp)
            ip -details link show "$IFACE" 2>/dev/null | grep -qi 'xdp' || {
                error "XDP 服务 active，但网卡未显示 XDP 挂载。"
                journalctl -u "$RFW_SERVICE_NAME" -n 120 --no-pager 2>/dev/null || true
                exit 1
            }
            ;;
    esac
}

install_or_update() {
    select_backend
    ensure_dependencies
    prepare_dirs
    build_generated_args
    [[ "$BACKEND" == "xdp" ]] && choose_iface_for_xdp

    show_capability_warning
    if [[ "$GEO_MODE" != "none" ]]; then
        download_geo_data
    else
        : > "$RFW_GEO_FILE"
    fi

    if [[ "$NON_INTERACTIVE" != "true" && "$FORCE" != "true" ]]; then
        show_summary
        confirm "确认部署以上配置？" || { info "已取消。"; return 0; }
    fi

    case "$BACKEND" in
        nft)
            step "生成 nftables 规则"
            stop_existing_service
            write_nft_rules
            write_nft_service
            ;;
        iptables)
            step "生成 iptables/ipset 规则"
            stop_existing_service
            write_iptables_helpers
            write_iptables_service
            ;;
        xdp)
            step "安装 XDP 二进制"
            stop_existing_service
            download_binary "$(resolve_binary_url)"
            write_xdp_service
            ;;
    esac
    save_config

    step "启动并验证服务"
    start_and_verify_service
    log "RFW 已启动并生效。"
    show_summary
}

show_rule_table() {
    local i=""
    echo ""
    for i in "${!RULE_FLAGS[@]}"; do
        local num=$((i + 1))
        local flag="${RULE_FLAGS[$i]}"
        local state="${RED}OFF${NC}"
        has_word "$SELECTED_RULES" "$flag" && state="${GREEN}ON ${NC}"
        printf "  %b%2d)%b [%b] %-18s %b%s%b\n" "$CYAN" "$num" "$NC" "$state" "${RULE_NAMES[$i]}" "$DIM" "${RULE_NOTES_FIREWALL[$i]}" "$NC"
    done
}

select_rules_menu() {
    load_config
    while true; do
        clear 2>/dev/null || true
        wide_divider
        echo -e "${BOLD}${CYAN} Incudal-RFW 规则选择${NC}"
        echo -e " ${DIM}输入编号切换，支持 1 2、1-4、mail hy2。a=全开，n=全关，d=推荐，s=保存，0=返回。${NC}"
        wide_divider
        show_rule_table
        wide_divider
        echo -e " 当前启用：${GREEN}$(rules_to_names "$SELECTED_RULES")${NC}"
        echo -ne "${BOLD}操作: ${NC}"
        local choice=""
        local token=""
        local flag=""
        read -r choice || true
        case "${choice:-}" in
            0) return 1 ;;
            a|A|all)
                SELECTED_RULES=""
                for flag in "${RULE_FLAGS[@]}"; do SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag"); done
                sanitize_rule_conflicts
                ;;
            n|N|none) SELECTED_RULES="" ;;
            d|D|default) SELECTED_RULES="$DEFAULT_RULES" ;;
            s|S|save)
                sanitize_rule_conflicts
                save_config
                return 0
                ;;
            *)
                for token in $(expand_selection_tokens "$choice"); do
                    if flag=$(flag_from_rule_token "$token"); then
                        toggle_rule "$flag"
                    else
                        warn "无效输入：${token}"
                        sleep 1
                    fi
                done
                ;;
        esac
    done
}

configure_install_interactive() {
    load_config
    echo ""
    echo -e "${BOLD}选择部署后端${NC}"
    echo "  1) nft       推荐，资源占用低，启动稳定"
    echo "  2) iptables  兼容，适合老系统"
    echo "  3) xdp       深度协议识别，依赖内核/网卡"
    echo -ne "${BOLD}请选择 [默认 1]: ${NC}"
    local choice=""
    read -r choice || true
    case "${choice:-1}" in
        1) BACKEND="nft" ;;
        2) BACKEND="iptables" ;;
        3) BACKEND="xdp" ;;
        *) BACKEND="nft" ;;
    esac

    IFACE=$(prompt_input "限制到指定入站网卡，留空表示全部接口" "${IFACE:-}")
    GEO_MODE=$(prompt_input "Geo 模式 blacklist/whitelist/none" "${GEO_MODE:-blacklist}")
    if [[ "$GEO_MODE" != "none" ]]; then
        COUNTRIES=$(prompt_input "国家代码，例如 CN 或 CN,US" "${COUNTRIES:-CN}")
    else
        COUNTRIES=""
    fi
    if prompt_yes_no "是否调整阻断规则？" "no"; then
        select_rules_menu || true
    fi
    if [[ "$BACKEND" == "xdp" ]]; then
        XDP_MODE=$(prompt_input "XDP 模式 auto/skb/drv/hw" "${XDP_MODE:-auto}")
        if prompt_yes_no "启用端口访问统计？" "yes"; then
            LOG_PORT_ACCESS="true"
        else
            LOG_PORT_ACCESS="false"
        fi
    fi
}

show_status() {
    load_config
    divider
    echo -e "${BOLD}RFW 状态${NC}"
    echo "  配置文件    : ${RFW_CONFIG_FILE}"
    echo "  后端        : ${BACKEND}"
    echo "  服务状态    : $(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || echo inactive)"
    echo "  服务文件    : ${RFW_SERVICE_FILE}"
    echo "  规则        : $(rules_to_names "$SELECTED_RULES")"
    divider
    case "$BACKEND" in
        nft)
            nft list table inet rfw 2>/dev/null || warn "未找到 nft table inet rfw。"
            ;;
        iptables)
            iptables -S "$RFW_IPTABLES_CHAIN" 2>/dev/null || warn "未找到 iptables 链 ${RFW_IPTABLES_CHAIN}。"
            ;;
        xdp)
            [[ -n "$IFACE" ]] && ip -details link show "$IFACE" 2>/dev/null | sed -n '1,8p'
            ;;
    esac
}

show_logs() {
    journalctl -u "$RFW_SERVICE_NAME" -n 160 --no-pager
}

restart_rfw() {
    require_root
    load_config
    systemctl restart "$RFW_SERVICE_NAME"
    start_and_verify_service
    log "服务已重启并验证。"
}

uninstall_rfw() {
    require_root
    load_config
    if ! confirm "确认卸载 RFW 服务并清理 nft/iptables/XDP 状态？"; then
        info "已取消。"
        return 0
    fi
    systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    nft delete table inet rfw 2>/dev/null || true
    [[ -x "$RFW_CLEAR_IPTABLES" ]] && "$RFW_CLEAR_IPTABLES" 2>/dev/null || true
    cleanup_xdp_state
    rm -f "$RFW_SERVICE_FILE"
    rm -rf "$RFW_ETC_DIR" "$RFW_STATE_DIR" "$RFW_LIB_DIR" "$RFW_INSTALL_DIR"
    systemctl daemon-reload
    systemctl reset-failed "$RFW_SERVICE_NAME" 2>/dev/null || true
    log "RFW 已卸载。"
}

main_menu() {
    while true; do
        load_config
        clear 2>/dev/null || true
        wide_divider
        echo -e "${BOLD}${CYAN} Incudal-RFW 部署控制台 v${SCRIPT_VERSION}${NC}"
        echo -e " 状态: ${BOLD}$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || echo inactive)${NC}   后端: ${BOLD}${BACKEND}${NC}   规则: ${BOLD}$(rules_to_names "$SELECTED_RULES")${NC}"
        wide_divider
        echo "  1) 安装 / 重新部署"
        echo "  2) 规则开关管理并应用"
        echo "  3) 查看状态"
        echo "  4) 查看日志"
        echo "  5) 重启服务"
        echo "  6) 卸载"
        echo "  0) 退出"
        echo -ne "${BOLD}请选择: ${NC}"
        local choice=""
        read -r choice || true
        case "${choice:-}" in
            1)
                configure_install_interactive
                install_or_update
                pause_enter
                ;;
            2)
                if select_rules_menu; then
                    install_or_update
                fi
                pause_enter
                ;;
            3) show_status; pause_enter ;;
            4) show_logs; pause_enter ;;
            5) restart_rfw; pause_enter ;;
            6) uninstall_rfw; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选择。"; sleep 1 ;;
        esac
    done
}

parse_args() {
    [[ "$#" -eq 0 ]] && return 0
    ACTION="install"
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --menu) ACTION="menu"; shift ;;
            --install) ACTION="install"; shift ;;
            --status) ACTION="status"; shift ;;
            --logs|--block-logs) ACTION="logs"; shift ;;
            --restart) ACTION="restart"; shift ;;
            --uninstall) ACTION="uninstall"; shift ;;
            --backend) require_value "$1" "${2:-}"; BACKEND="$2"; shift 2 ;;
            --iface) require_value "$1" "${2:-}"; IFACE="$2"; shift 2 ;;
            --xdp-mode) require_value "$1" "${2:-}"; XDP_MODE="$2"; shift 2 ;;
            --geo-mode) require_value "$1" "${2:-}"; GEO_MODE="$2"; shift 2 ;;
            --countries) require_value "$1" "${2:-}"; COUNTRIES="$2"; shift 2 ;;
            --rules) require_value "$1" "${2:-}"; RFW_ARGS="$2"; SELECTED_RULES="$2"; CUSTOM_RFW_ARGS="true"; shift 2 ;;
            --log-port-access) LOG_PORT_ACCESS="true"; shift ;;
            --no-log-port-access) LOG_PORT_ACCESS="false"; shift ;;
            --binary-url) require_value "$1" "${2:-}"; BINARY_URL="$2"; shift 2 ;;
            --release-url) require_value "$1" "${2:-}"; RELEASE_URL="$2"; shift 2 ;;
            --yes|-y) NON_INTERACTIVE="true"; FORCE="true"; shift ;;
            --force) FORCE="true"; shift ;;
            --keep-script) KEEP_SCRIPT="true"; shift ;;
            --help|-h) usage; exit 0 ;;
            --block-*)
                SELECTED_RULES=$(add_word "$SELECTED_RULES" "$1")
                shift
                ;;
            *)
                error "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done
    [[ -z "$SELECTED_RULES" ]] && SELECTED_RULES="$DEFAULT_RULES"
    validate_common_options
}

main() {
    load_config
    parse_args "$@"
    case "$ACTION" in
        menu) main_menu ;;
        install) install_or_update ;;
        status) show_status ;;
        logs) show_logs ;;
        restart) restart_rfw ;;
        uninstall) uninstall_rfw ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"

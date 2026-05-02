#!/usr/bin/env bash
# ============================================================================
# Incudal-RFW 正式部署脚本
#
# 从 GitHub Release 下载 Incudal-RFW 预编译二进制，安装到 /root/rfw，
# 写入 systemd 服务，并提供中文交互控制台管理规则、日志、统计和卸载。
# ============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_RELEASE_URL="https://github.com/0xdabiaoge/incudal-rfw/releases/latest/download"
readonly RFW_INSTALL_DIR="/root/rfw"
readonly RFW_BIN_PATH="${RFW_INSTALL_DIR}/rfw"
readonly RFW_SERVICE_NAME="rfw"
readonly RFW_SERVICE_FILE="/etc/systemd/system/${RFW_SERVICE_NAME}.service"

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly MAGENTA='\033[1;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

ACTION="menu"
IFACE=""
RFW_ARGS=""
BINARY_URL=""
RELEASE_URL="$DEFAULT_RELEASE_URL"
XDP_MODE="auto"
GEO_MODE="blacklist"
COUNTRIES="CN"
LOG_PORT_ACCESS="true"
FORCE="false"
NON_INTERACTIVE="false"
SHOW_LOGS_ON_FAILURE="true"
DELETE_SELF_ON_UNINSTALL="true"
MENU_BACK="false"
SELECTED_RULES=""
CUSTOM_RFW_ARGS="false"

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
    "邮件防滥用"
    "明文 HTTP"
    "SOCKS 代理"
    "SS/TCP-FET 严格"
    "SS/TCP-FET 宽松"
    "WireGuard"
    "QUIC 总开关"
    "Hysteria2 / HY2"
    "TUIC"
    "SS UDP/UDP-FET"
    "VLESS TCP"
    "VMess TCP"
    "全入站阻断"
)

RULE_DESCS=(
    "阻断 SMTP 常用端口，防止发信滥用"
    "阻断明文 HTTP 入站请求"
    "阻断 SOCKS4 / SOCKS4a / SOCKS5"
    "覆盖 Shadowsocks/SS、VMess/raw TCP 等高熵 TCP 加密流量"
    "宽松检测 Shadowsocks/SS 等高熵 TCP 流量，误伤更低"
    "阻断 WireGuard UDP 握手"
    "粗暴阻断可识别 QUIC，HY2/TUIC/HTTP3 会一起受影响"
    "尽力阻断 HY2、混淆 HY2 和明显 UDP 滥用"
    "尽力阻断 TUIC 和非 Web 端口 QUIC 代理"
    "覆盖 Shadowsocks/SS UDP、混淆 UDP 等高熵加密 payload"
    "阻断裸 VLESS over TCP"
    "阻断裸 VMess over TCP"
    "危险规则：阻断匹配来源的全部入站流量"
)

DEFAULT_RULES="--block-email --block-http --block-socks5 --block-fet-strict --block-wireguard --block-hysteria2 --block-tuic --block-udp-fet --block-vless-tcp --block-vmess-tcp"

log() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
step() { echo -e "\n${CYAN}[>]${NC} ${BOLD}$1${NC}"; }

divider() {
    echo -e "${DIM}------------------------------------------------------------${NC}"
}

wide_divider() {
    echo -e "${DIM}============================================================${NC}"
}

section_title() {
    echo ""
    echo -e "${BOLD}${CYAN}$1${NC}"
    divider
}

menu_line() {
    local key="$1"
    local title="$2"
    local desc="${3:-}"
    if [[ -n "$desc" ]]; then
        echo -e "  ${CYAN}${key})${NC} ${BOLD}${title}${NC} ${DIM}${desc}${NC}"
    else
        echo -e "  ${CYAN}${key})${NC} ${BOLD}${title}${NC}"
    fi
}

usage() {
    cat <<EOF
Incudal-RFW 正式部署脚本 v${SCRIPT_VERSION}

用法：
  sudo bash rfw-test-deploy.sh                 # 打开中文控制台
  sudo bash rfw-test-deploy.sh --install       # 使用默认规则部署
  sudo bash rfw-test-deploy.sh --status
  sudo bash rfw-test-deploy.sh --logs
  sudo bash rfw-test-deploy.sh --block-logs
  sudo bash rfw-test-deploy.sh --stats
  sudo bash rfw-test-deploy.sh --restart
  sudo bash rfw-test-deploy.sh --uninstall

默认策略：
  默认只对中国来源 CN 生效，并启用端口访问/拦截统计。
  默认规则：邮件、HTTP、SOCKS、SS/TCP-FET 严格、WG、HY2、TUIC、SS UDP/UDP-FET、VLESS TCP、VMess TCP。

部署参数：
  --iface <网卡名>             指定挂载 XDP 的网卡
  --rules "<RFW参数>"          直接传入完整 RFW 参数，会覆盖脚本生成规则
  --countries <国家代码>       默认 CN
  --geo-mode <blacklist|whitelist|none>
                               blacklist=只阻断指定国家来源；none=所有来源生效
  --log-port-access            启用端口访问/拦截统计
  --no-log-port-access         关闭端口访问/拦截统计
  --xdp-mode <auto|skb|drv|hw> XDP 挂载模式
  --binary-url <URL>           指定完整二进制下载地址
  --release-url <URL>          指定 Release 下载基础地址
  --force                      跳过确认
  --yes                        非交互执行
  --keep-script                卸载时保留脚本文件

规则开关：
  可在控制台中随时启用/关闭单条规则并应用到 systemd 服务。
  也可用 --rules 手动传入，例如：
    sudo bash rfw-test-deploy.sh --iface eth0 --rules "--block-socks5 --block-hysteria2 --countries CN --log-port-access" --yes
EOF
}

pause_enter() {
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi
    MENU_BACK="false"
    echo ""
    echo -ne "${DIM}按回车继续...${NC}"
    read -r _ || true
}

request_menu_back() {
    MENU_BACK="true"
    info "已返回主菜单。"
}

is_menu_back() {
    [[ "$MENU_BACK" == "true" ]]
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 权限运行：sudo bash $0"
        exit 1
    fi
}

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        error "缺少必要命令：${name}"
        exit 1
    fi
}

require_arg_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "${flag} 缺少参数值"
        exit 1
    fi
}

is_http_url() {
    local value="${1:-}"
    [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
}

is_yes() {
    local value="${1:-}"
    [[ "$value" =~ ^([yY]|[yY][eE][sS]|是|确认|好|1)$ ]]
}

confirm() {
    local prompt="$1"
    if [[ "$FORCE" == "true" || "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi

    echo -ne "${YELLOW}${prompt}${NC} [y/N]: "
    local answer=""
    read -r answer || true
    is_yes "$answer"
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local hint="[y/N]"
    if [[ "$default_answer" == "yes" ]]; then
        hint="[Y/n]"
    fi

    echo -ne "${BOLD}${prompt}${NC} ${hint}: "
    local answer=""
    read -r answer || true
    if [[ -z "${answer:-}" ]]; then
        [[ "$default_answer" == "yes" ]]
        return
    fi
    is_yes "$answer"
}

prompt_input() {
    local prompt="$1"
    local default_value="$2"
    local answer=""

    if [[ -n "$default_value" ]]; then
        echo -ne "${BOLD}${prompt}${NC} ${DIM}[默认：${default_value}]${NC}: " >&2
    else
        echo -ne "${BOLD}${prompt}${NC}: " >&2
    fi

    read -r answer || true
    if [[ -z "${answer:-}" ]]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$answer"
    fi
}

detect_arch_suffix() {
    case "$(uname -m)" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            error "不支持当前架构：$(uname -m)。目前支持：x86_64、aarch64。"
            exit 1
            ;;
    esac
}

expand_selection_tokens() {
    local input="$1"
    local token=""
    local start=""
    local end=""
    local i=""

    input=${input//,/ }
    input=${input//，/ }
    input=${input//、/ }

    for token in $input; do
        if [[ "$token" =~ ^[0-9]+(-[0-9]+){2,}$ ]]; then
            printf '%s\n' "$token" | tr '-' '\n'
        elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( start <= end )); then
                for ((i = start; i <= end; i++)); do
                    echo "$i"
                done
            else
                for ((i = start; i >= end; i--)); do
                    echo "$i"
                done
            fi
        else
            echo "$token"
        fi
    done
}

normalize_spaces() {
    local value="${1:-}"
    local token=""
    local result=""
    for token in $value; do
        result="${result} ${token}"
    done
    printf '%s\n' "${result# }"
}

has_word() {
    local haystack=" $1 "
    local needle="$2"
    [[ "$haystack" == *" ${needle} "* ]]
}

add_word() {
    local haystack="$1"
    local needle="$2"
    if has_word "$haystack" "$needle"; then
        printf '%s\n' "$(normalize_spaces "$haystack")"
    else
        printf '%s\n' "$(normalize_spaces "${haystack} ${needle}")"
    fi
}

remove_word() {
    local haystack="$1"
    local needle="$2"
    local token=""
    local result=""
    for token in $haystack; do
        [[ "$token" == "$needle" ]] && continue
        result="${result} ${token}"
    done
    printf '%s\n' "$(normalize_spaces "$result")"
}

rule_count() {
    echo "${#RULE_FLAGS[@]}"
}

rule_flag_by_index() {
    local index="$1"
    echo "${RULE_FLAGS[$((index - 1))]}"
}

rule_name_by_index() {
    local index="$1"
    echo "${RULE_NAMES[$((index - 1))]}"
}

rule_desc_by_index() {
    local index="$1"
    echo "${RULE_DESCS[$((index - 1))]}"
}

rule_name_by_flag() {
    local flag="$1"
    local i=""
    for i in "${!RULE_FLAGS[@]}"; do
        if [[ "${RULE_FLAGS[$i]}" == "$flag" ]]; then
            echo "${RULE_NAMES[$i]}"
            return 0
        fi
    done
    echo "$flag"
}

flag_from_rule_token() {
    local token="$1"
    token=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')

    if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= $(rule_count) )); then
        rule_flag_by_index "$token"
        return 0
    fi

    case "$token" in
        mail|email|smtp) echo "--block-email" ;;
        http|web) echo "--block-http" ;;
        socks|socks5) echo "--block-socks5" ;;
        fet|fet-strict|tcp-fet|strict) echo "--block-fet-strict" ;;
        fet-loose|loose|tcp-fet-loose) echo "--block-fet-loose" ;;
        wg|wireguard) echo "--block-wireguard" ;;
        quic) echo "--block-quic" ;;
        hy2|hysteria2) echo "--block-hysteria2" ;;
        tuic) echo "--block-tuic" ;;
        udp-fet|udpfet) echo "--block-udp-fet" ;;
        vless|vless-tcp) echo "--block-vless-tcp" ;;
        vmess|vmess-tcp) echo "--block-vmess-tcp" ;;
        block-all|all-inbound|danger) echo "--block-all" ;;
        *) return 1 ;;
    esac
}

sanitize_rule_conflicts() {
    if has_word "$SELECTED_RULES" "--block-fet-strict" && has_word "$SELECTED_RULES" "--block-fet-loose"; then
        SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-loose")
        warn "SS/TCP-FET 严格和宽松不能同时开启，已保留严格模式。"
    fi
}

toggle_rule() {
    local flag="$1"
    if has_word "$SELECTED_RULES" "$flag"; then
        SELECTED_RULES=$(remove_word "$SELECTED_RULES" "$flag")
    else
        if [[ "$flag" == "--block-fet-strict" ]]; then
            SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-loose")
        elif [[ "$flag" == "--block-fet-loose" ]]; then
            SELECTED_RULES=$(remove_word "$SELECTED_RULES" "--block-fet-strict")
        fi
        SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag")
    fi
    sanitize_rule_conflicts
}

rules_to_names() {
    local rules="${1:-}"
    local flag=""
    local result=""
    for flag in $rules; do
        result="${result}$(rule_name_by_flag "$flag")、"
    done
    result="${result%、}"
    printf '%s\n' "${result:-无}"
}

sync_selected_rules_from_args() {
    local exec_text="${1:-$RFW_ARGS}"
    local flag=""
    SELECTED_RULES=""
    for flag in "${RULE_FLAGS[@]}"; do
        if [[ " $exec_text " == *" ${flag} "* ]]; then
            SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag")
        fi
    done
}

extract_exec_start() {
    local service_file=""
    for service_file in "$RFW_SERVICE_FILE" "/usr/lib/systemd/system/${RFW_SERVICE_NAME}.service" "/lib/systemd/system/${RFW_SERVICE_NAME}.service"; do
        [[ -f "$service_file" ]] || continue
        grep '^ExecStart=' "$service_file" 2>/dev/null | sed 's/^ExecStart=//' || true
        return 0
    done
}

extract_arg_after() {
    local arg_name="$1"
    local exec_start=""
    exec_start=$(extract_exec_start || true)
    [[ -n "$exec_start" ]] || return 1
    printf '%s\n' "$exec_start" | awk -v key="$arg_name" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == key) {
                    value = $(i + 1);
                    gsub(/^"/, "", value);
                    gsub(/"$/, "", value);
                    print value;
                    exit;
                }
            }
        }'
}

load_current_config() {
    local exec_start=""
    local flag=""

    exec_start=$(extract_exec_start || true)
    if [[ -z "$exec_start" ]]; then
        SELECTED_RULES="$DEFAULT_RULES"
        GEO_MODE="blacklist"
        COUNTRIES="CN"
        LOG_PORT_ACCESS="true"
        return 0
    fi

    SELECTED_RULES=""
    for flag in "${RULE_FLAGS[@]}"; do
        if [[ " $exec_start " == *" ${flag} "* ]]; then
            SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag")
        fi
    done
    [[ -z "$SELECTED_RULES" ]] && SELECTED_RULES="$DEFAULT_RULES"

    IFACE=$(extract_arg_after "--iface" || true)
    XDP_MODE=$(extract_arg_after "--xdp-mode" || true)
    [[ -z "$XDP_MODE" ]] && XDP_MODE="auto"

    if [[ " $exec_start " == *" --all-sources "* ]]; then
        GEO_MODE="none"
        COUNTRIES=""
    elif [[ " $exec_start " == *" --allow-only-countries "* ]]; then
        GEO_MODE="whitelist"
        COUNTRIES=$(extract_arg_after "--allow-only-countries" || true)
        [[ -z "$COUNTRIES" ]] && COUNTRIES="CN"
    elif [[ " $exec_start " == *" --countries "* ]]; then
        GEO_MODE="blacklist"
        COUNTRIES=$(extract_arg_after "--countries" || true)
        [[ -z "$COUNTRIES" ]] && COUNTRIES="CN"
    else
        GEO_MODE="blacklist"
        COUNTRIES="CN"
    fi

    if [[ " $exec_start " == *" --log-port-access "* ]]; then
        LOG_PORT_ACCESS="true"
    else
        LOG_PORT_ACCESS="false"
    fi
}

choose_iface() {
    if [[ -n "$IFACE" ]]; then
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            error "网卡不存在：${IFACE}"
            exit 1
        fi
        return 0
    fi

    local default_iface=""
    default_iface=$(ip route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}' | head -n1 || true)
    if [[ -n "$default_iface" && "$NON_INTERACTIVE" == "true" ]]; then
        IFACE="$default_iface"
        info "使用默认路由网卡：${IFACE}"
        return 0
    fi

    local interfaces=()
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        interfaces+=("$iface")
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$')

    if [[ "${#interfaces[@]}" -eq 0 ]]; then
        error "没有找到可用网卡。"
        exit 1
    fi

    if [[ "${#interfaces[@]}" -eq 1 ]]; then
        IFACE="${interfaces[0]}"
        info "只找到一个可用网卡，自动使用：${IFACE}"
        return 0
    fi

    section_title "选择网卡"
    [[ -n "$default_iface" ]] && echo -e "  ${DIM}默认路由网卡：${default_iface}${NC}"
    local i=""
    for i in "${!interfaces[@]}"; do
        local num=$((i + 1))
        local iface_ip=""
        iface_ip=$(ip -4 addr show "${interfaces[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1 || true)
        if [[ -n "$iface_ip" ]]; then
            echo -e "  ${CYAN}${num})${NC} ${interfaces[$i]} ${DIM}(${iface_ip})${NC}"
        else
            echo -e "  ${CYAN}${num})${NC} ${interfaces[$i]}"
        fi
    done
    menu_line "0" "返回主菜单"
    echo ""

    while true; do
        echo -ne "${BOLD}请选择网卡 [1-${#interfaces[@]}；0 返回]：${NC}"
        local choice=""
        read -r choice || true
        if [[ "${choice:-}" == "0" ]]; then
            request_menu_back
            return 0
        fi
        if [[ "${choice:-}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
            IFACE="${interfaces[$((choice - 1))]}"
            return 0
        fi
        warn "选择无效，请重新输入。"
    done
}

configure_scope_menu() {
    section_title "作用范围"
    echo -e "${DIM}正式默认策略：只对中国来源 CN 生效。除非你明确测试全来源，否则建议保持默认。${NC}"
    menu_line "1" "只阻断指定国家来源" "默认 CN"
    menu_line "2" "只允许指定国家，其余来源按规则阻断"
    menu_line "3" "不区分国家，对所有来源生效"
    menu_line "0" "返回主菜单"
    echo ""
    echo -ne "${BOLD}请选择作用范围 [默认 1；0 返回]：${NC}"

    local choice=""
    read -r choice || true
    case "${choice:-1}" in
        0)
            request_menu_back
            return 0
            ;;
        1)
            GEO_MODE="blacklist"
            COUNTRIES=$(prompt_input "请输入国家代码列表" "${COUNTRIES:-CN}")
            if [[ "$COUNTRIES" == "0" ]]; then
                request_menu_back
                return 0
            fi
            ;;
        2)
            GEO_MODE="whitelist"
            COUNTRIES=$(prompt_input "请输入允许的国家代码列表" "${COUNTRIES:-CN}")
            if [[ "$COUNTRIES" == "0" ]]; then
                request_menu_back
                return 0
            fi
            ;;
        3)
            GEO_MODE="none"
            COUNTRIES=""
            ;;
        *)
            warn "选择无效，已保持默认：只阻断中国来源 CN。"
            GEO_MODE="blacklist"
            COUNTRIES="CN"
            ;;
    esac
    return 0
}

configure_runtime_menu() {
    section_title "运行选项"
    echo -e "${DIM}输入 0 可返回主菜单。${NC}"

    XDP_MODE=$(prompt_input "XDP 挂载模式 auto/skb/drv/hw" "${XDP_MODE:-auto}")
    if [[ "$XDP_MODE" == "0" ]]; then
        request_menu_back
        return 0
    fi
    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *)
            warn "XDP 模式无效，自动改为 auto。"
            XDP_MODE="auto"
            ;;
    esac

    if prompt_yes_no "启用端口访问/拦截统计？" "$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo yes || echo no)"; then
        LOG_PORT_ACCESS="true"
    else
        LOG_PORT_ACCESS="false"
    fi

    if prompt_yes_no "自定义二进制或 Release 下载地址？" "no"; then
        echo -ne "${BOLD}下载方式：1) 最新 Release  2) 自定义 Release 基础地址  3) 完整二进制 URL  0) 返回 [默认 1]：${NC}"
        local answer=""
        read -r answer || true
        case "${answer:-1}" in
            0)
                request_menu_back
                return 0
                ;;
            2) RELEASE_URL=$(prompt_input "请输入 Release 基础地址" "$DEFAULT_RELEASE_URL") ;;
            3) BINARY_URL=$(prompt_input "请输入完整二进制 URL" "") ;;
            *) RELEASE_URL="$DEFAULT_RELEASE_URL" ;;
        esac
        if [[ "$RELEASE_URL" == "0" || "$BINARY_URL" == "0" ]]; then
            request_menu_back
            return 0
        fi
    fi
}

show_rule_table() {
    local i=""
    echo ""
    for i in "${!RULE_FLAGS[@]}"; do
        local num=$((i + 1))
        local flag="${RULE_FLAGS[$i]}"
        local state="${RED}OFF${NC}"
        if has_word "$SELECTED_RULES" "$flag"; then
            state="${GREEN}ON ${NC}"
        fi
        printf "  %b%2d)%b [%b] %-16s %b%s%b\n" "$CYAN" "$num" "$NC" "$state" "${RULE_NAMES[$i]}" "$DIM" "${RULE_DESCS[$i]}" "$NC"
    done
}

select_rules_menu() {
    load_current_config

    while true; do
        clear 2>/dev/null || true
        wide_divider
        echo -e "${BOLD}${CYAN} Incudal-RFW 规则开关管理${NC}"
        echo -e " ${DIM}输入编号可批量切换，例如：3 7 8、1-4、mail hy2 tuic。${NC}"
        echo -e " ${DIM}a=全部开启，n=全部关闭，d=恢复推荐，s=保存应用，0=返回主菜单。${NC}"
        wide_divider
        show_rule_table
        wide_divider
        echo -e " 当前启用：${GREEN}$(rules_to_names "$SELECTED_RULES")${NC}"
        echo -ne "${BOLD}请输入操作：${NC}"

        local choice=""
        local token=""
        local flag=""
        local invalid="false"
        read -r choice || true
        choice="${choice:-}"

        case "$choice" in
            0)
                request_menu_back
                return 0
                ;;
            a|A|all|全部)
                SELECTED_RULES=""
                for flag in "${RULE_FLAGS[@]}"; do
                    SELECTED_RULES=$(add_word "$SELECTED_RULES" "$flag")
                done
                sanitize_rule_conflicts
                ;;
            n|N|none|无)
                SELECTED_RULES=""
                ;;
            d|D|default|推荐)
                SELECTED_RULES="$DEFAULT_RULES"
                ;;
            s|S|save|保存)
                sanitize_rule_conflicts
                if has_word "$SELECTED_RULES" "--block-all"; then
                    if ! confirm "你启用了“全入站阻断”，这会阻断匹配来源的全部入站流量，确认继续？"; then
                        continue
                    fi
                fi
                log "已保存规则选择：$(rules_to_names "$SELECTED_RULES")"
                return 0
                ;;
            "")
                warn "请输入编号或操作。"
                sleep 1
                ;;
            *)
                for token in $(expand_selection_tokens "$choice"); do
                    if flag=$(flag_from_rule_token "$token"); then
                        toggle_rule "$flag"
                    else
                        invalid="true"
                    fi
                done
                if [[ "$invalid" == "true" ]]; then
                    warn "存在无效输入，请重新检查。"
                    sleep 1
                fi
                ;;
        esac
    done
}

reset_install_options() {
    IFACE=""
    RFW_ARGS=""
    BINARY_URL=""
    RELEASE_URL="$DEFAULT_RELEASE_URL"
    XDP_MODE="auto"
    GEO_MODE="blacklist"
    COUNTRIES="CN"
    LOG_PORT_ACCESS="true"
    SELECTED_RULES="$DEFAULT_RULES"
    CUSTOM_RFW_ARGS="false"
}

build_generated_args() {
    if [[ "$CUSTOM_RFW_ARGS" == "true" ]]; then
        RFW_ARGS="$(normalize_spaces "$RFW_ARGS")"
        sync_selected_rules_from_args "$RFW_ARGS"
        return 0
    fi

    COUNTRIES=$(printf '%s' "$COUNTRIES" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    RFW_ARGS="$(normalize_spaces "$SELECTED_RULES")"

    case "$GEO_MODE" in
        blacklist)
            [[ -z "$COUNTRIES" ]] && COUNTRIES="CN"
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --countries ${COUNTRIES}")
            ;;
        whitelist)
            if [[ -z "$COUNTRIES" ]]; then
                error "白名单模式必须指定国家代码。"
                exit 1
            fi
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --allow-only-countries ${COUNTRIES}")
            ;;
        none)
            RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --all-sources")
            ;;
        *)
            error "GeoIP 模式无效：${GEO_MODE}"
            exit 1
            ;;
    esac

    if [[ "$LOG_PORT_ACCESS" == "true" && "$RFW_ARGS" != *"--log-port-access"* ]]; then
        RFW_ARGS=$(normalize_spaces "${RFW_ARGS} --log-port-access")
    fi
}

systemd_escape_arg() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

build_exec_start() {
    local command=""
    command="$(systemd_escape_arg "$RFW_BIN_PATH")"
    command+=" --iface $(systemd_escape_arg "$IFACE")"
    command+=" --xdp-mode $(systemd_escape_arg "$XDP_MODE")"
    if [[ -n "$RFW_ARGS" ]]; then
        command+=" ${RFW_ARGS}"
    fi
    printf '%s\n' "$command"
}

resolve_binary_url() {
    if [[ -n "$BINARY_URL" ]]; then
        if ! is_http_url "$BINARY_URL"; then
            error "--binary-url 无效：${BINARY_URL}"
            exit 1
        fi
        echo "$BINARY_URL"
        return 0
    fi

    if ! is_http_url "$RELEASE_URL"; then
        error "--release-url 无效：${RELEASE_URL}"
        exit 1
    fi

    local arch_suffix=""
    arch_suffix=$(detect_arch_suffix)
    echo "${RELEASE_URL%/}/rfw-${arch_suffix}-unknown-linux-musl"
}

stop_existing_service() {
    if systemctl list-unit-files "${RFW_SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${RFW_SERVICE_NAME}.service"; then
        info "正在停止已有 ${RFW_SERVICE_NAME} 服务..."
        systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    fi
}

download_binary() {
    local url="$1"

    mkdir -p "$RFW_INSTALL_DIR"
    local tmp_file="${RFW_BIN_PATH}.download"
    rm -f "$tmp_file" 2>/dev/null || true

    local attempt=""
    for attempt in 1 2 3; do
        info "正在下载 RFW 二进制，第 ${attempt} 次尝试：${url}"
        if curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp_file"; then
            mv "$tmp_file" "$RFW_BIN_PATH"
            chmod +x "$RFW_BIN_PATH"
            log "RFW 二进制已安装到：${RFW_BIN_PATH}"
            return 0
        fi
        warn "第 ${attempt} 次下载失败。"
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    rm -f "$tmp_file" 2>/dev/null || true
    error "连续 3 次下载 RFW 二进制失败。"
    exit 1
}

write_service() {
    local exec_start=""
    exec_start=$(build_exec_start)

    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=Incudal-RFW 入站协议阻断服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
ExecStart=${exec_start}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "systemd 服务已写入：${RFW_SERVICE_FILE}"
}

show_summary() {
    divider
    echo -e "${BOLD}Incudal-RFW 当前部署配置${NC}"
    echo "  二进制文件  ：${RFW_BIN_PATH}"
    echo "  服务文件    ：${RFW_SERVICE_FILE}"
    echo "  网卡        ：${IFACE:-未设置}"
    echo "  XDP 模式    ：${XDP_MODE}"
    case "$GEO_MODE" in
        blacklist) echo "  作用范围    ：只阻断 ${COUNTRIES:-CN} 来源" ;;
        whitelist) echo "  作用范围    ：只允许 ${COUNTRIES:-CN}，其余来源按规则阻断" ;;
        none) echo "  作用范围    ：所有来源" ;;
    esac
    echo "  端口统计    ：$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo 已启用 || echo 未启用)"
    echo "  启用规则    ：$(rules_to_names "$SELECTED_RULES")"
    echo "  启动参数    ：${RFW_ARGS:-<无>}"
    divider
}

install_or_update_rfw() {
    require_root
    require_command curl
    require_command ip
    require_command systemctl

    step "准备 Incudal-RFW 部署"
    choose_iface
    is_menu_back && return 0
    build_generated_args

    if [[ "$NON_INTERACTIVE" != "true" && "$FORCE" != "true" ]]; then
        show_summary
        if ! confirm "确认使用以上配置部署/更新 RFW？"; then
            info "已取消。"
            return 0
        fi
    fi

    stop_existing_service

    if [[ ! -x "$RFW_BIN_PATH" || -n "$BINARY_URL" || "$RELEASE_URL" != "$DEFAULT_RELEASE_URL" ]]; then
        local url=""
        url=$(resolve_binary_url)
        step "下载二进制文件"
        download_binary "$url"
    else
        info "检测到已安装二进制，继续复用：${RFW_BIN_PATH}"
    fi

    step "写入 systemd 服务"
    write_service

    step "启动服务"
    systemctl start "$RFW_SERVICE_NAME"
    systemctl enable "$RFW_SERVICE_NAME" >/dev/null 2>&1 || true

    sleep 2
    if systemctl is-active --quiet "$RFW_SERVICE_NAME"; then
        log "Incudal-RFW 服务正在运行。"
        show_summary
        echo -e "${DIM}实时日志：sudo journalctl -u ${RFW_SERVICE_NAME} -f${NC}"
        [[ "$LOG_PORT_ACCESS" == "true" ]] && echo -e "${DIM}端口统计：sudo ${RFW_BIN_PATH} stats${NC}"
    else
        error "Incudal-RFW 服务启动失败。"
        if [[ "$SHOW_LOGS_ON_FAILURE" == "true" ]]; then
            journalctl -u "$RFW_SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
        fi
        exit 1
    fi
}

deploy_flow() {
    reset_install_options
    echo ""
    echo -e "${BOLD}将使用推荐规则安装：${NC}${GREEN}$(rules_to_names "$SELECTED_RULES")${NC}"
    echo -e "${DIM}需要改规则的话，可以这里先调整；也可以安装完成后回主菜单选“规则开关管理”。${NC}"
    if prompt_yes_no "安装前是否调整阻断规则？" "no"; then
        select_rules_menu
        if is_menu_back; then MENU_BACK="false"; return 0; fi
    fi
    configure_scope_menu
    if is_menu_back; then MENU_BACK="false"; return 0; fi
    configure_runtime_menu
    if is_menu_back; then MENU_BACK="false"; return 0; fi
    install_or_update_rfw
}

apply_rules_flow() {
    require_root
    require_command systemctl
    require_command ip

    load_current_config
    select_rules_menu
    if is_menu_back; then MENU_BACK="false"; return 0; fi

    if [[ ! -x "$RFW_BIN_PATH" || -z "$(extract_exec_start || true)" ]]; then
        warn "当前还没有完整安装 RFW，将按当前规则执行部署。"
        choose_iface
        is_menu_back && return 0
        build_generated_args
        install_or_update_rfw
        return 0
    fi

    build_generated_args
    show_summary
    if ! confirm "确认应用这些规则并重启 RFW？"; then
        info "已取消。"
        return 0
    fi

    step "应用规则并重启服务"
    write_service
    systemctl restart "$RFW_SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$RFW_SERVICE_NAME"; then
        log "规则已生效。"
    else
        error "服务重启失败。"
        journalctl -u "$RFW_SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
        exit 1
    fi
}

extract_service_iface() {
    extract_arg_after "--iface" || true
}

detach_xdp_if_possible() {
    local iface=""
    iface=$(extract_service_iface || true)
    if [[ -n "$iface" ]] && command -v ip >/dev/null 2>&1 && ip link show "$iface" >/dev/null 2>&1; then
        ip link set dev "$iface" xdp off 2>/dev/null || true
    fi
}

resolve_self_path() {
    local self="${BASH_SOURCE[0]:-$0}"
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$self" 2>/dev/null && return 0
    fi
    if command -v realpath >/dev/null 2>&1; then
        realpath "$self" 2>/dev/null && return 0
    fi
    printf '%s\n' "$self"
}

delete_script_copies() {
    if [[ "$DELETE_SELF_ON_UNINSTALL" != "true" ]]; then
        return 0
    fi

    step "搜索并删除部署脚本"

    local self_path=""
    local self_dir=""
    local root=""
    local file=""
    local deleted=0
    self_path=$(resolve_self_path || true)
    self_dir=$(dirname "$self_path" 2>/dev/null || printf '.')

    local roots=("$self_dir" "/root" "/tmp" "/usr/local/bin" "/opt" "/home")
    local seen="|"

    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        case "$seen" in
            *"|$root|"*) continue ;;
        esac
        seen="${seen}${root}|"

        while IFS= read -r -d '' file; do
            if rm -f -- "$file" 2>/dev/null; then
                log "已删除脚本：${file}"
                deleted=$((deleted + 1))
            else
                warn "脚本删除失败：${file}"
            fi
        done < <(find "$root" -maxdepth 4 -type f \( -name 'rfw-test-deploy.sh' -o -name 'incudal-rfw-deploy.sh' -o -name 'incudal-rfw-test-deploy.sh' \) -print0 2>/dev/null)
    done

    if [[ "$deleted" -eq 0 ]]; then
        warn "没有搜索到需要删除的脚本副本。"
    fi
}

uninstall_rfw() {
    require_root
    require_command systemctl

    if [[ ! -f "$RFW_BIN_PATH" && ! -f "$RFW_SERVICE_FILE" ]]; then
        warn "当前没有安装 Incudal-RFW。"
        if confirm "是否仍然搜索并删除部署脚本？"; then
            delete_script_copies
        fi
        return 0
    fi

    if ! confirm "确认完整卸载 Incudal-RFW，并删除服务、二进制、BPF pin 和部署脚本？"; then
        info "已取消。"
        return 0
    fi

    step "停止并禁用 RFW 服务"
    systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    detach_xdp_if_possible

    step "删除 RFW 文件"
    rm -f "$RFW_SERVICE_FILE" 2>/dev/null || true
    rm -f "/usr/lib/systemd/system/${RFW_SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/lib/systemd/system/${RFW_SERVICE_NAME}.service" 2>/dev/null || true
    rm -rf "$RFW_INSTALL_DIR" 2>/dev/null || true
    rm -f /sys/fs/bpf/rfw_port_access_log 2>/dev/null || true
    rm -f /run/rfw.pid /var/run/rfw.pid 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$RFW_SERVICE_NAME" 2>/dev/null || true
    log "Incudal-RFW 服务和文件已清理。"

    delete_script_copies
    log "完整卸载流程已完成。"
}

show_status() {
    require_command systemctl
    load_current_config

    divider
    echo -e "${BOLD}Incudal-RFW 状态${NC}"
    if [[ -x "$RFW_BIN_PATH" ]]; then
        echo "  二进制文件  ：${RFW_BIN_PATH}"
    else
        echo "  二进制文件  ：未安装"
    fi

    if [[ -f "$RFW_SERVICE_FILE" ]]; then
        echo "  服务文件    ：${RFW_SERVICE_FILE}"
        local exec_start=""
        exec_start=$(extract_exec_start || true)
        echo "  启动命令    ：${exec_start:-未找到}"
    else
        echo "  服务文件    ：未安装"
    fi

    local status="unknown"
    status=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
    [[ -z "${status:-}" || "$status" == "unknown" ]] && status="未知"
    echo "  运行状态    ：${status}"
    echo "  当前网卡    ：${IFACE:-未识别}"
    echo "  XDP 模式    ：${XDP_MODE:-auto}"
    case "$GEO_MODE" in
        blacklist) echo "  作用范围    ：只阻断 ${COUNTRIES:-CN} 来源" ;;
        whitelist) echo "  作用范围    ：只允许 ${COUNTRIES:-CN}，其余来源按规则阻断" ;;
        none) echo "  作用范围    ：所有来源" ;;
    esac
    echo "  端口统计    ：$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo 已启用 || echo 未启用)"
    echo "  启用规则    ：$(rules_to_names "$SELECTED_RULES")"
    divider
}

show_logs() {
    require_command journalctl
    local mode="${1:-recent}"
    if [[ "$mode" == "follow" ]]; then
        journalctl -u "$RFW_SERVICE_NAME" -f
    else
        journalctl -u "$RFW_SERVICE_NAME" -n 160 --no-pager
    fi
}

show_block_logs() {
    require_command journalctl
    step "最近的拦截/丢弃日志"
    if ! journalctl -u "$RFW_SERVICE_NAME" -n 500 --no-pager 2>/dev/null | grep -Ei 'block|blocked|drop|deny|reject|阻断|拦截|丢弃|DROP'; then
        warn "最近日志中没有匹配到明显的拦截记录。可以打开实时日志继续观察。"
    fi
}

show_stats_menu() {
    require_root
    if [[ ! -x "$RFW_BIN_PATH" ]]; then
        error "未找到 RFW 二进制：${RFW_BIN_PATH}"
        return 1
    fi

    while true; do
        section_title "端口访问/拦截统计"
        menu_line "1" "查看全部统计"
        menu_line "2" "只看被阻断记录"
        menu_line "3" "按端口分组"
        menu_line "4" "查询指定端口"
        menu_line "5" "查询指定来源 IPv4"
        menu_line "0" "返回主菜单"
        echo ""
        echo -ne "${BOLD}请选择：${NC}"

        local choice=""
        local port=""
        local ip=""
        read -r choice || true

        case "${choice:-1}" in
            1) "$RFW_BIN_PATH" stats ;;
            2) "$RFW_BIN_PATH" stats --blocked-only ;;
            3) "$RFW_BIN_PATH" stats --group-by-port ;;
            4)
                port=$(prompt_input "请输入端口号" "")
                [[ "$port" == "0" ]] && continue
                [[ -n "$port" ]] && "$RFW_BIN_PATH" stats --port "$port"
                ;;
            5)
                ip=$(prompt_input "请输入来源 IPv4" "")
                [[ "$ip" == "0" ]] && continue
                [[ -n "$ip" ]] && "$RFW_BIN_PATH" stats --ip "$ip"
                ;;
            0) return 0 ;;
            *) warn "选择无效。" ;;
        esac
        pause_enter
        clear 2>/dev/null || true
    done
}

restart_rfw() {
    require_root
    require_command systemctl
    step "重启 RFW 服务"
    systemctl restart "$RFW_SERVICE_NAME"
    sleep 1
    show_status
}

status_badge() {
    local state="$1"
    case "$state" in
        active) echo -e "${GREEN}运行中${NC}" ;;
        inactive|failed) echo -e "${RED}${state}${NC}" ;;
        *) echo -e "${YELLOW}${state:-未知}${NC}" ;;
    esac
}

main_menu() {
    require_root

    while true; do
        clear 2>/dev/null || true
        load_current_config

        local service_state="未知"
        if command -v systemctl >/dev/null 2>&1; then
            service_state=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
            [[ -z "$service_state" ]] && service_state="未知"
        fi

        wide_divider
        echo -e "${BOLD}${CYAN}                 Incudal-RFW${NC}"
        echo -e "${MAGENTA}          宿主机入站协议阻断控制台${NC} ${DIM}v${SCRIPT_VERSION}${NC}"
        wide_divider
        echo -e " 服务状态：$(status_badge "$service_state")   网卡：${BOLD}${IFACE:-未设置}${NC}   安装目录：${RFW_INSTALL_DIR}"
        case "$GEO_MODE" in
            blacklist) echo -e " 作用范围：${BOLD}只阻断 ${COUNTRIES:-CN} 来源${NC}   端口统计：${BOLD}$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo 已启用 || echo 未启用)${NC}" ;;
            whitelist) echo -e " 作用范围：${BOLD}只允许 ${COUNTRIES:-CN}${NC}   端口统计：${BOLD}$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo 已启用 || echo 未启用)${NC}" ;;
            none) echo -e " 作用范围：${BOLD}所有来源${NC}   端口统计：${BOLD}$([[ "$LOG_PORT_ACCESS" == "true" ]] && echo 已启用 || echo 未启用)${NC}" ;;
        esac
        echo -e " 启用规则：${GREEN}$(rules_to_names "$SELECTED_RULES")${NC}"
        wide_divider
        menu_line "1" "安装 / 重新部署" "下载正式 Release，并按自选规则启动"
        menu_line "2" "规则开关管理" "随时启用/关闭规则，保存后自动重启生效"
        menu_line "3" "查看当前配置"
        menu_line "4" "查看最近运行日志"
        menu_line "5" "查看最近拦截日志"
        menu_line "6" "实时跟踪日志"
        menu_line "7" "查看端口访问/拦截统计"
        menu_line "8" "重启 RFW 服务"
        menu_line "9" "完整卸载并删除脚本"
        menu_line "0" "退出"
        wide_divider
        echo -ne "${BOLD}请选择操作：${NC}"

        local choice=""
        read -r choice || true
        case "${choice:-}" in
            1)
                deploy_flow
                if is_menu_back; then MENU_BACK="false"; continue; fi
                pause_enter
                ;;
            2)
                apply_rules_flow
                if is_menu_back; then MENU_BACK="false"; continue; fi
                pause_enter
                ;;
            3)
                show_status
                pause_enter
                ;;
            4)
                show_logs "recent"
                pause_enter
                ;;
            5)
                show_block_logs
                pause_enter
                ;;
            6)
                show_logs "follow"
                ;;
            7)
                show_stats_menu || true
                ;;
            8)
                restart_rfw
                pause_enter
                ;;
            9)
                uninstall_rfw
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                warn "选择无效，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

rules_from_profile_compat() {
    local profile="$1"
    local token=""
    local result=""
    local flag=""
    profile=${profile//,/ }
    for token in $profile; do
        case "$token" in
            strong|all)
                for flag in --block-email --block-http --block-socks5 --block-fet-strict --block-wireguard --block-quic --block-hysteria2 --block-tuic --block-udp-fet --block-vless-tcp --block-vmess-tcp; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            hy2)
                for flag in --block-email --block-socks5 --block-fet-strict --block-wireguard --block-hysteria2 --block-udp-fet; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            tuic)
                for flag in --block-email --block-socks5 --block-wireguard --block-tuic; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            tcp-node|tcp)
                for flag in --block-email --block-http --block-socks5 --block-fet-strict --block-vless-tcp --block-vmess-tcp; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            baseline)
                for flag in --block-email --block-http --block-socks5 --block-fet-strict --block-wireguard; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            manual)
                for flag in $DEFAULT_RULES; do
                    result=$(add_word "$result" "$flag")
                done
                ;;
            *)
                error "--profile 兼容参数无效：${token}"
                exit 1
                ;;
        esac
    done
    printf '%s\n' "$(normalize_spaces "$result")"
}

parse_args() {
    if [[ $# -gt 0 ]]; then
        ACTION="install"
    fi

    SELECTED_RULES="$DEFAULT_RULES"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --menu)
                ACTION="menu"; shift ;;
            --install)
                ACTION="install"; shift ;;
            --apply-rules)
                ACTION="apply-rules"; shift ;;
            --iface)
                require_arg_value "$1" "${2:-}"
                IFACE="$2"; shift 2 ;;
            --binary-url)
                require_arg_value "$1" "${2:-}"
                BINARY_URL="$2"; shift 2 ;;
            --release-url)
                require_arg_value "$1" "${2:-}"
                RELEASE_URL="$2"; shift 2 ;;
            --rules)
                if [[ $# -lt 2 || -z "${2:-}" ]]; then
                    error "--rules 缺少参数值"
                    exit 1
                fi
                RFW_ARGS="$2"; CUSTOM_RFW_ARGS="true"; shift 2 ;;
            --profile)
                require_arg_value "$1" "${2:-}"
                SELECTED_RULES=$(rules_from_profile_compat "$2"); shift 2 ;;
            --countries)
                require_arg_value "$1" "${2:-}"
                COUNTRIES="$2"; shift 2 ;;
            --geo-mode)
                require_arg_value "$1" "${2:-}"
                GEO_MODE="$2"; shift 2 ;;
            --log-port-access)
                LOG_PORT_ACCESS="true"; shift ;;
            --no-log-port-access)
                LOG_PORT_ACCESS="false"; shift ;;
            --xdp-mode)
                require_arg_value "$1" "${2:-}"
                XDP_MODE="$2"; shift 2 ;;
            --force)
                FORCE="true"; shift ;;
            --yes|-y)
                NON_INTERACTIVE="true"; FORCE="true"; shift ;;
            --keep-script)
                DELETE_SELF_ON_UNINSTALL="false"; shift ;;
            --uninstall)
                ACTION="uninstall"; shift ;;
            --status)
                ACTION="status"; shift ;;
            --logs)
                ACTION="logs"; shift ;;
            --follow-logs)
                ACTION="follow-logs"; shift ;;
            --block-logs)
                ACTION="block-logs"; shift ;;
            --stats)
                ACTION="stats"; shift ;;
            --restart)
                ACTION="restart"; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                error "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done

    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *)
            error "--xdp-mode 无效：${XDP_MODE}"
            exit 1
            ;;
    esac

    case "$GEO_MODE" in
        blacklist|whitelist|none) ;;
        *)
            error "--geo-mode 无效：${GEO_MODE}"
            exit 1
            ;;
    esac
}

main() {
    parse_args "$@"

    case "$ACTION" in
        menu)
            main_menu ;;
        install)
            require_root
            require_command ip
            install_or_update_rfw
            ;;
        apply-rules)
            apply_rules_flow ;;
        uninstall)
            uninstall_rfw ;;
        status)
            show_status ;;
        logs)
            show_logs "recent" ;;
        follow-logs)
            show_logs "follow" ;;
        block-logs)
            show_block_logs ;;
        stats)
            show_stats_menu ;;
        restart)
            restart_rfw ;;
        *)
            error "未知操作：${ACTION}"
            exit 1
            ;;
    esac
}

main "$@"

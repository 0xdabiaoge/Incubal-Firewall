#!/usr/bin/env bash
# ============================================================================
# RFW 测试部署脚本
#
# 本脚本用于复刻 Incudal 宿主机安装器的 RFW 部署路径：
# 从 GitHub Release 下载预编译二进制，安装到 /root/rfw，写入 systemd
# 服务，并在选定网卡上启动 RFW。
# ============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="0.2.0"
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
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

ACTION="menu"
IFACE=""
RFW_ARGS=""
BINARY_URL=""
RELEASE_URL="$DEFAULT_RELEASE_URL"
XDP_MODE="auto"
ENABLE_DEFAULT_RULES="true"
COUNTRIES="CN"
GEO_MODE="blacklist"
LOG_PORT_ACCESS="false"
FORCE="false"
NON_INTERACTIVE="false"
SHOW_LOGS_ON_FAILURE="true"
RULE_PROFILE=""
DELETE_SELF_ON_UNINSTALL="true"

log() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
step() { echo -e "\n${CYAN}[>]${NC} ${BOLD}$1${NC}"; }

divider() {
    echo -e "${DIM}------------------------------------------------------------${NC}"
}

usage() {
    cat <<EOF
RFW 测试部署脚本 v${SCRIPT_VERSION}

用法：
  sudo bash rfw-test-deploy.sh                 # 打开交互式中文菜单
  sudo bash rfw-test-deploy.sh [参数]          # 直接部署
  sudo bash rfw-test-deploy.sh --status
  sudo bash rfw-test-deploy.sh --logs
  sudo bash rfw-test-deploy.sh --block-logs
  sudo bash rfw-test-deploy.sh --stats
  sudo bash rfw-test-deploy.sh --restart
  sudo bash rfw-test-deploy.sh --uninstall

安装参数：
  --iface <网卡名>            指定要挂载 XDP 的网卡。
  --binary-url <URL>          指定完整的 RFW 二进制下载地址。
  --release-url <URL>         指定 Release 下载基础地址。
                              默认：${DEFAULT_RELEASE_URL}
  --rules "<参数>"            直接传入原始 RFW 规则参数，会覆盖默认规则。
                              示例：--rules "--countries CN --block-http"
  --no-default-rules          不生成默认规则；除非同时指定 --rules。
  --profile <配置>            规则配置：strong、hy2、tuic、tcp-node、baseline、manual。
  --countries <列表>          默认规则使用的国家代码列表，默认：CN。
  --geo-mode <blacklist|whitelist|none>
                              默认规则的 GeoIP 模式，默认：blacklist。
  --log-port-access           在生成规则中加入 --log-port-access。
  --xdp-mode <auto|skb|drv|hw>
                              XDP 挂载模式，默认：auto。
  --force                     不再确认，直接执行。
  --yes                       非交互模式。
  --keep-script               卸载时保留 rfw-test-deploy.sh 脚本文件。

规则配置：
  strong      强力阻断：QUIC、HY2、TUIC、VLESS、VMess、UDP-FET、SOCKS、WG、HTTP、Email 全开
  hy2         重点测试 HY2 / 混淆 HY2 / UDP 滥用
  tuic        重点测试 TUIC / 非 Web 端口 QUIC 代理
  tcp-node    重点测试 VLESS、VMess、SOCKS、FET 这类 TCP 弱节点协议
  baseline    基础节点阻断组合
  manual      逐条规则手动选择

示例：
  sudo bash rfw-test-deploy.sh --iface eth0 --profile strong --geo-mode none --yes
  sudo bash rfw-test-deploy.sh --iface eth0 --profile hy2 --geo-mode none
  sudo bash rfw-test-deploy.sh --iface eth0 --xdp-mode skb --log-port-access
  sudo bash rfw-test-deploy.sh --iface eth0 --rules "--block-all-from CN --log-port-access"
EOF
}

pause_enter() {
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi
    echo ""
    echo -ne "${DIM}按回车继续...${NC}"
    read -r _ || true
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
        echo -ne "${BOLD}${prompt}${NC} ${DIM}[默认：${default_value}]${NC}: "
    else
        echo -ne "${BOLD}${prompt}${NC}: "
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

    if [[ -n "$default_iface" ]]; then
        echo -e "  ${DIM}默认路由网卡：${default_iface}${NC}"
    fi

    echo ""
    echo "可用网卡："
    local i
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
    echo ""

    while true; do
        echo -ne "${BOLD}请选择网卡 [1-${#interfaces[@]}]：${NC}"
        local choice=""
        read -r choice || true
        if [[ "${choice:-}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
            IFACE="${interfaces[$((choice - 1))]}"
            return 0
        fi
        warn "选择无效，请重新输入。"
    done
}

select_rule_profile() {
    if [[ -n "$RULE_PROFILE" || "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}规则配置：${NC}"
    echo -e "  ${CYAN}1)${NC} strong   ${DIM}强力阻断：QUIC、HY2、TUIC、VLESS、VMess、UDP-FET、SOCKS、WG、HTTP、Email 全开${NC}"
    echo -e "  ${CYAN}2)${NC} hy2      ${DIM}重点测试 HY2 / 混淆 HY2 / UDP 滥用，比 --block-quic 更克制${NC}"
    echo -e "  ${CYAN}3)${NC} tuic     ${DIM}重点测试 TUIC / 非 Web 端口 QUIC 代理${NC}"
    echo -e "  ${CYAN}4)${NC} tcp-node ${DIM}重点测试 VLESS、VMess、SOCKS、FET 这类 TCP 弱节点协议${NC}"
    echo -e "  ${CYAN}5)${NC} baseline ${DIM}基础节点阻断组合，不启用 HY2/TUIC 拆分规则${NC}"
    echo -e "  ${CYAN}6)${NC} manual   ${DIM}逐条规则手动选择${NC}"
    echo ""

    while true; do
        echo -ne "${BOLD}请选择规则配置 [1-6，默认 1]：${NC}"
        local choice=""
        read -r choice || true
        case "${choice:-1}" in
            1) RULE_PROFILE="strong"; return 0 ;;
            2) RULE_PROFILE="hy2"; return 0 ;;
            3) RULE_PROFILE="tuic"; return 0 ;;
            4) RULE_PROFILE="tcp-node"; return 0 ;;
            5) RULE_PROFILE="baseline"; return 0 ;;
            6) RULE_PROFILE="manual"; return 0 ;;
            *) warn "选择无效，请重新输入。" ;;
        esac
    done
}

build_manual_rules() {
    RFW_ARGS=""

    prompt_yes_no "是否阻断 Email/SMTP 发信滥用？" "yes" && RFW_ARGS="${RFW_ARGS} --block-email"
    prompt_yes_no "是否阻断明文 HTTP 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-http"
    prompt_yes_no "是否阻断 SOCKS4/SOCKS5 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-socks5"
    prompt_yes_no "是否阻断 TCP 全加密高熵流量（严格 FET）？" "yes" && RFW_ARGS="${RFW_ARGS} --block-fet-strict"
    prompt_yes_no "是否阻断 WireGuard 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-wireguard"
    prompt_yes_no "是否阻断所有可识别 QUIC？" "yes" && RFW_ARGS="${RFW_ARGS} --block-quic"
    prompt_yes_no "是否尽力阻断 Hysteria2/HY2？" "yes" && RFW_ARGS="${RFW_ARGS} --block-hysteria2"
    prompt_yes_no "是否尽力阻断 TUIC？" "yes" && RFW_ARGS="${RFW_ARGS} --block-tuic"
    prompt_yes_no "是否阻断 UDP 高熵加密流量？" "yes" && RFW_ARGS="${RFW_ARGS} --block-udp-fet"
    prompt_yes_no "是否阻断裸 VLESS over TCP？" "yes" && RFW_ARGS="${RFW_ARGS} --block-vless-tcp"
    prompt_yes_no "是否阻断裸 VMess over TCP？" "yes" && RFW_ARGS="${RFW_ARGS} --block-vmess-tcp"

    RFW_ARGS="${RFW_ARGS# }"
}

build_default_rules() {
    if [[ -n "$RFW_ARGS" ]]; then
        if [[ "$LOG_PORT_ACCESS" == "true" && "$RFW_ARGS" != *"--log-port-access"* ]]; then
            RFW_ARGS="${RFW_ARGS} --log-port-access"
        fi
        return 0
    fi

    COUNTRIES=$(printf '%s' "$COUNTRIES" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

    if [[ "$ENABLE_DEFAULT_RULES" != "true" ]]; then
        RFW_ARGS=""
    else
        select_rule_profile
        RULE_PROFILE="${RULE_PROFILE:-strong}"

        case "$RULE_PROFILE" in
            strong)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-wireguard --block-quic --block-hysteria2 --block-tuic --block-udp-fet --block-vless-tcp --block-vmess-tcp"
                ;;
            hy2)
                RFW_ARGS="--block-email --block-socks5 --block-fet-strict --block-wireguard --block-hysteria2 --block-udp-fet"
                ;;
            tuic)
                RFW_ARGS="--block-email --block-socks5 --block-wireguard --block-tuic"
                ;;
            tcp-node)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-vless-tcp --block-vmess-tcp"
                ;;
            baseline)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-wireguard"
                ;;
            manual)
                build_manual_rules
                ;;
            *)
                error "--profile 无效：${RULE_PROFILE}。可选值：strong、hy2、tuic、tcp-node、baseline、manual。"
                exit 1
                ;;
        esac

        case "$GEO_MODE" in
            blacklist)
                if [[ -n "$COUNTRIES" ]]; then
                    RFW_ARGS="${RFW_ARGS} --countries ${COUNTRIES}"
                fi
                ;;
            whitelist)
                if [[ -z "$COUNTRIES" ]]; then
                    error "--geo-mode whitelist 必须同时指定 --countries。"
                    exit 1
                fi
                RFW_ARGS="${RFW_ARGS} --allow-only-countries ${COUNTRIES}"
                ;;
            none)
                ;;
            *)
                error "--geo-mode 无效：${GEO_MODE}。可选值：blacklist、whitelist、none。"
                exit 1
                ;;
        esac
    fi

    if [[ "$LOG_PORT_ACCESS" == "true" && "$RFW_ARGS" != *"--log-port-access"* ]]; then
        RFW_ARGS="${RFW_ARGS} --log-port-access"
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

    local attempt
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
Description=RFW 测试防火墙服务
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
    echo -e "${BOLD}RFW 测试部署配置${NC}"
    echo "  二进制文件：${RFW_BIN_PATH}"
    echo "  服务文件  ：${RFW_SERVICE_FILE}"
    echo "  网卡      ：${IFACE}"
    echo "  XDP 模式  ：${XDP_MODE}"
    echo "  规则参数  ：${RFW_ARGS:-<无>}"
    divider
}

install_rfw() {
    require_root
    require_command curl
    require_command ip
    require_command systemctl

    step "准备 RFW 测试部署"

    if [[ -f "$RFW_BIN_PATH" || -f "$RFW_SERVICE_FILE" ]]; then
        if ! confirm "检测到 RFW 似乎已经安装，是否重新安装？"; then
            info "已取消。"
            return 0
        fi
    fi

    choose_iface
    build_default_rules

    if [[ "$NON_INTERACTIVE" != "true" && "$FORCE" != "true" ]]; then
        show_summary
        if ! confirm "确认使用以上配置进行安装？"; then
            info "已取消。"
            return 0
        fi
    fi

    stop_existing_service

    local url=""
    url=$(resolve_binary_url)
    step "下载二进制文件"
    download_binary "$url"

    step "安装 systemd 服务"
    write_service

    step "启动服务"
    systemctl start "$RFW_SERVICE_NAME"
    systemctl enable "$RFW_SERVICE_NAME" >/dev/null 2>&1 || true

    sleep 2
    if systemctl is-active --quiet "$RFW_SERVICE_NAME"; then
        log "RFW 服务正在运行。"
        show_summary
        echo -e "${DIM}查看实时日志：sudo journalctl -u ${RFW_SERVICE_NAME} -f${NC}"
        if [[ "$RFW_ARGS" == *"--log-port-access"* ]]; then
            echo -e "${DIM}查看统计：sudo ${RFW_BIN_PATH} stats${NC}"
        fi
    else
        error "RFW 服务启动失败。"
        if [[ "$SHOW_LOGS_ON_FAILURE" == "true" ]]; then
            journalctl -u "$RFW_SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
        fi
        exit 1
    fi
}

extract_service_iface() {
    local service_file=""
    local exec_start=""
    local token=""

    for service_file in "$RFW_SERVICE_FILE" "/usr/lib/systemd/system/${RFW_SERVICE_NAME}.service" "/lib/systemd/system/${RFW_SERVICE_NAME}.service"; do
        [[ -f "$service_file" ]] || continue
        exec_start=$(grep '^ExecStart=' "$service_file" 2>/dev/null | sed 's/^ExecStart=//' || true)
        [[ -n "$exec_start" ]] || continue
        token=$(printf '%s\n' "$exec_start" | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "--iface") {
                        gsub(/^"/, "", $(i + 1));
                        gsub(/"$/, "", $(i + 1));
                        print $(i + 1);
                        exit
                    }
                }
            }')
        if [[ -n "$token" ]]; then
            printf '%s\n' "$token"
            return 0
        fi
    done
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

    step "搜索并删除测试部署脚本"

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
        done < <(find "$root" -maxdepth 4 -type f \( -name 'rfw-test-deploy.sh' -o -name 'incudal-rfw-test-deploy.sh' \) -print0 2>/dev/null)
    done

    if [[ "$deleted" -eq 0 ]]; then
        warn "没有搜索到需要删除的脚本副本。"
    fi
}

uninstall_rfw() {
    require_root
    require_command systemctl

    if [[ ! -f "$RFW_BIN_PATH" && ! -f "$RFW_SERVICE_FILE" ]]; then
        warn "当前没有安装 RFW 测试部署。"
        if confirm "是否仍然搜索并删除测试部署脚本？"; then
            delete_script_copies
        fi
        return 0
    fi

    if ! confirm "确认完整卸载 RFW，并删除服务、二进制、BPF pin 和测试脚本？"; then
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
    log "RFW 服务和文件已清理。"

    delete_script_copies
    log "完整卸载流程已完成。"
}

show_status() {
    require_command systemctl

    divider
    echo -e "${BOLD}RFW 状态${NC}"
    if [[ -x "$RFW_BIN_PATH" ]]; then
        echo "  二进制文件：${RFW_BIN_PATH}"
    else
        echo "  二进制文件：未安装"
    fi

    if [[ -f "$RFW_SERVICE_FILE" ]]; then
        echo "  服务文件  ：${RFW_SERVICE_FILE}"
        local exec_start=""
        exec_start=$(grep '^ExecStart=' "$RFW_SERVICE_FILE" 2>/dev/null || true)
        echo "  启动命令  ：${exec_start#ExecStart=}"
    else
        echo "  服务文件  ：未安装"
    fi

    local status="unknown"
    status=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
    if [[ -z "${status:-}" || "$status" == "unknown" ]]; then
        status="未知"
    fi
    echo "  运行状态  ：${status}"
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
        warn "最近日志中没有匹配到明显的拦截记录。可用菜单开启实时日志继续观察。"
    fi
}

show_stats_menu() {
    require_root
    if [[ ! -x "$RFW_BIN_PATH" ]]; then
        error "未找到 RFW 二进制：${RFW_BIN_PATH}"
        return 1
    fi

    echo ""
    echo -e "${BOLD}端口访问/拦截统计：${NC}"
    echo -e "  ${CYAN}1)${NC} 查看全部统计"
    echo -e "  ${CYAN}2)${NC} 只看被阻断的记录"
    echo -e "  ${CYAN}3)${NC} 按端口分组查看"
    echo -e "  ${CYAN}4)${NC} 查询指定端口"
    echo -e "  ${CYAN}5)${NC} 查询指定来源 IP"
    echo -e "  ${CYAN}0)${NC} 返回"
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
            [[ -n "$port" ]] && "$RFW_BIN_PATH" stats --port "$port"
            ;;
        5)
            ip=$(prompt_input "请输入来源 IPv4" "")
            [[ -n "$ip" ]] && "$RFW_BIN_PATH" stats --ip "$ip"
            ;;
        0) return 0 ;;
        *) warn "选择无效。" ;;
    esac
}

restart_rfw() {
    require_root
    require_command systemctl
    step "重启 RFW 服务"
    systemctl restart "$RFW_SERVICE_NAME"
    sleep 1
    show_status
}

reset_install_options() {
    IFACE=""
    RFW_ARGS=""
    BINARY_URL=""
    RELEASE_URL="$DEFAULT_RELEASE_URL"
    XDP_MODE="auto"
    ENABLE_DEFAULT_RULES="true"
    COUNTRIES="CN"
    GEO_MODE="blacklist"
    LOG_PORT_ACCESS="false"
    RULE_PROFILE=""
}

configure_geo_mode_menu() {
    echo ""
    echo -e "${BOLD}GeoIP 作用范围：${NC}"
    echo -e "  ${CYAN}1)${NC} 只阻断指定国家来源 ${DIM}(默认 CN)${NC}"
    echo -e "  ${CYAN}2)${NC} 只允许指定国家，其余来源按规则阻断"
    echo -e "  ${CYAN}3)${NC} 不区分国家，对所有来源生效"
    echo ""
    echo -ne "${BOLD}请选择 GeoIP 模式 [1-3，默认 3]：${NC}"

    local choice=""
    read -r choice || true
    case "${choice:-3}" in
        1)
            GEO_MODE="blacklist"
            COUNTRIES=$(prompt_input "请输入国家代码列表" "CN")
            ;;
        2)
            GEO_MODE="whitelist"
            COUNTRIES=$(prompt_input "请输入允许的国家代码列表" "CN")
            ;;
        3)
            GEO_MODE="none"
            COUNTRIES=""
            ;;
        *)
            warn "选择无效，默认使用所有来源。"
            GEO_MODE="none"
            COUNTRIES=""
            ;;
    esac
}

configure_advanced_menu() {
    local answer=""

    XDP_MODE=$(prompt_input "XDP 挂载模式 auto/skb/drv/hw" "auto")
    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *)
            warn "XDP 模式无效，自动改为 auto。"
            XDP_MODE="auto"
            ;;
    esac

    if prompt_yes_no "是否启用端口访问/拦截统计？" "yes"; then
        LOG_PORT_ACCESS="true"
    else
        LOG_PORT_ACCESS="false"
    fi

    if prompt_yes_no "是否自定义二进制或 Release 下载地址？" "no"; then
        echo -ne "${BOLD}选择下载方式：1) 最新 Release  2) 自定义 Release 基础地址  3) 完整二进制 URL [默认 1]：${NC}"
        read -r answer || true
        case "${answer:-1}" in
            2) RELEASE_URL=$(prompt_input "请输入 Release 基础地址" "$DEFAULT_RELEASE_URL") ;;
            3) BINARY_URL=$(prompt_input "请输入完整二进制 URL" "") ;;
            *) RELEASE_URL="$DEFAULT_RELEASE_URL" ;;
        esac
    fi
}

configure_menu_install() {
    local mode="$1"
    reset_install_options

    choose_iface
    configure_geo_mode_menu
    configure_advanced_menu

    case "$mode" in
        strong|hy2|tuic|tcp-node|baseline)
            RULE_PROFILE="$mode"
            ;;
        profile)
            select_rule_profile
            ;;
        manual)
            RULE_PROFILE="manual"
            ;;
        raw)
            ENABLE_DEFAULT_RULES="false"
            RFW_ARGS=$(prompt_input "请输入完整 RFW 参数" "--block-socks5 --block-fet-strict --block-wireguard --log-port-access")
            ;;
        *)
            RULE_PROFILE="strong"
            ;;
    esac
}

main_menu() {
    require_root

    while true; do
        clear 2>/dev/null || true
        echo -e "${BOLD}Incudal RFW 测试部署菜单${NC} ${DIM}v${SCRIPT_VERSION}${NC}"
        divider
        echo -e "  ${CYAN}1)${NC} 快速强力部署 ${DIM}(所有节点阻断规则，默认所有来源生效)${NC}"
        echo -e "  ${CYAN}2)${NC} 选择规则模板部署"
        echo -e "  ${CYAN}3)${NC} 自定义选择阻断规则部署"
        echo -e "  ${CYAN}4)${NC} 手动输入完整 RFW 参数部署"
        echo -e "  ${CYAN}5)${NC} 查看服务状态和启动命令"
        echo -e "  ${CYAN}6)${NC} 查看最近运行日志"
        echo -e "  ${CYAN}7)${NC} 查看最近拦截日志"
        echo -e "  ${CYAN}8)${NC} 实时跟踪日志"
        echo -e "  ${CYAN}9)${NC} 查看端口访问/拦截统计"
        echo -e "  ${CYAN}10)${NC} 重启 RFW 服务"
        echo -e "  ${CYAN}11)${NC} 完整卸载并删除脚本"
        echo -e "  ${CYAN}0)${NC} 退出"
        divider
        echo -ne "${BOLD}请选择操作：${NC}"

        local choice=""
        read -r choice || true
        case "${choice:-}" in
            1)
                reset_install_options
                RULE_PROFILE="strong"
                GEO_MODE="none"
                LOG_PORT_ACCESS="true"
                choose_iface
                configure_advanced_menu
                install_rfw
                pause_enter
                ;;
            2)
                configure_menu_install "profile"
                install_rfw
                pause_enter
                ;;
            3)
                configure_menu_install "manual"
                install_rfw
                pause_enter
                ;;
            4)
                configure_menu_install "raw"
                install_rfw
                pause_enter
                ;;
            5)
                show_status
                pause_enter
                ;;
            6)
                show_logs "recent"
                pause_enter
                ;;
            7)
                show_block_logs
                pause_enter
                ;;
            8)
                show_logs "follow"
                ;;
            9)
                show_stats_menu || true
                pause_enter
                ;;
            10)
                restart_rfw
                pause_enter
                ;;
            11)
                uninstall_rfw
                pause_enter
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

parse_args() {
    if [[ $# -gt 0 ]]; then
        ACTION="install"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --menu)
                ACTION="menu"; shift ;;
            --install)
                ACTION="install"; shift ;;
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
                require_arg_value "$1" "${2:-}"
                RFW_ARGS="$2"; ENABLE_DEFAULT_RULES="false"; shift 2 ;;
            --no-default-rules)
                ENABLE_DEFAULT_RULES="false"; shift ;;
            --profile)
                require_arg_value "$1" "${2:-}"
                RULE_PROFILE="$2"; shift 2 ;;
            --countries)
                require_arg_value "$1" "${2:-}"
                COUNTRIES="$2"; shift 2 ;;
            --geo-mode)
                require_arg_value "$1" "${2:-}"
                GEO_MODE="$2"; shift 2 ;;
            --log-port-access)
                LOG_PORT_ACCESS="true"; shift ;;
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

    case "$RULE_PROFILE" in
        ""|strong|hy2|tuic|tcp-node|baseline|manual) ;;
        *)
            error "--profile 无效：${RULE_PROFILE}"
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
            install_rfw ;;
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

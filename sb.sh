#!/bin/bash

# ==========================================
# Sing-box 5-in-1 工业级稳定版
# 核心架构：Sing-box 原生 + wgcf (WireGuard) + Argo HTTP2
# ==========================================

# --- 终端视觉设计 ---
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'

msg_info() { echo -e "${CYAN}[ INFO ]${NC} $1"; }
msg_success() { echo -e "${GREEN}[  OK  ]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[ WARN ]${NC} $1"; }
msg_error() { echo -e "${RED}[ FAIL ]${NC} $1"; }
reading() { echo -ne "${CYAN}➤ $1${NC}" >&2; read -r "$2"; }

print_logo() {
    clear
    echo -e "${CYAN}┌───────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}           Sing-box 5-in-1                 ${CYAN}│${NC}"
    echo -e "${CYAN}└───────────────────────────────────────────────┘${NC}"
    echo ""
}

# --- 全局变量 ---
SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
SB_INFO="${SB_DIR}/install.info"
SB_BIN="/usr/local/bin/sing-box"
ARGO_BIN="/usr/local/bin/cloudflared"
WGCF_BIN="/usr/local/bin/wgcf"
ARGO_LOG="${SB_DIR}/argo.log"
USED_PORTS=()

[[ $EUID -ne 0 ]] && msg_error "必须以 root 用户运行此脚本！" && exit 1

# --- 快捷指令就绪 ---
if [[ "$0" != "/usr/bin/sb" ]]; then
    rm -f /usr/bin/sb 2>/dev/null
    cp -f "$0" /usr/bin/sb
    chmod +x /usr/bin/sb
    msg_success "快捷指令 'sb' 已就绪，后续可直接输入 sb 唤出面板。"
    sleep 1
fi

load_config() { [ -f "$SB_INFO" ] && source "$SB_INFO"; }
save_config() {
    cat > "$SB_INFO" << EOF
UUID=$UUID
PW_HY=$PW_HY
PW_TC=$PW_TC
S5_U=$S5_U
S5_P=$S5_P
PORT_VD=$PORT_VD
PORT_HY=$PORT_HY
PORT_TC=$PORT_TC
PORT_S5=$PORT_S5
WARP_MODE=$WARP_MODE
WARP_DOMAINS=$WARP_DOMAINS
CUSTOM_IP=$CUSTOM_IP
ARGO_MODE=$ARGO_MODE
ARGO_TOKEN=$ARGO_TOKEN
ARGO_DOMAIN=$ARGO_DOMAIN
WG_PRIV=$WG_PRIV
WG_IP4=$WG_IP4
WG_IP6=$WG_IP6
EOF
}

# --- 核心网络与依赖调优 ---
get_random_port() {
    local port
    while true; do
        port=$((RANDOM % 50000 + 10000))
        if ! ss -tuln | grep -q ":$port " && [[ ! " ${USED_PORTS[@]} " =~ " ${port} " ]]; then
            USED_PORTS+=($port)
            echo "$port"
            break
        fi
    done
}

get_outbound_ip() {
    local ip=$(curl -s4 --max-time 3 https://api.ipify.org)
    [ -z "$ip" ] && ip=$(curl -s6 --max-time 3 ipv6.ip.sb)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

optimize_network() {
    msg_info "正在进行底层网络防断流调优..."
    modprobe tcp_bbr >/dev/null 2>&1 || true
    cat > /etc/sysctl.d/99-singbox-optimize.conf << EOF
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.core.rmem_max=8388608
net.core.wmem_max=8388608
EOF
    sysctl -p /etc/sysctl.d/99-singbox-optimize.conf >/dev/null 2>&1
}

install_deps() {
    msg_info "正在检查基础环境依赖..."
    local pkgs=("curl" "wget" "jq" "openssl" "iproute2")
    local need_install=0
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then need_install=1; break; fi
    done
    if [ "$need_install" -eq 1 ]; then
        apt-get update -y >/dev/null 2>&1 || yum makecache -y >/dev/null 2>&1
        apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || yum install -y "${pkgs[@]}" >/dev/null 2>&1
    fi
    optimize_network
}

# --- 架构识别与组件拉取 ---
get_architecture() {
    ARCH=$(uname -m)
    case "${ARCH}" in 
        x86_64) S_ARCH="amd64"; A_ARCH="amd64" ;; 
        aarch64|arm64) S_ARCH="arm64"; A_ARCH="arm64" ;; 
        *) msg_error "不支持的 CPU 架构: ${ARCH}"; exit 1 ;; 
    esac
}

install_singbox() {
    if [ ! -f "$SB_BIN" ]; then
        msg_info "正在拉取 Sing-box 内核 ($S_ARCH)..."
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
        curl -sLo sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${S_ARCH}.tar.gz"
        tar -xzf sb.tar.gz
        mv sing-box-*/sing-box "$SB_BIN"
        rm -rf sb.tar.gz sing-box-*
        chmod +x "$SB_BIN"
    fi
}

install_argo() {
    if [ ! -f "$ARGO_BIN" ]; then
        msg_info "正在拉取 Cloudflared Argo 隧道 ($A_ARCH)..."
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A_ARCH}" -o "$ARGO_BIN"
        chmod +x "$ARGO_BIN"
    fi
}

install_wgcf_warp() {
    if [ -z "$WG_PRIV" ]; then
        msg_info "正在原生接管 WARP (生成 WireGuard 密钥)..."
        mkdir -p "${SB_DIR}/wgcf" && cd "${SB_DIR}/wgcf"
        curl -sL "https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_$(uname -s | tr '[:upper:]' '[:lower:]')_${S_ARCH}" -o "$WGCF_BIN"
        chmod +x "$WGCF_BIN"
        
        yes | "$WGCF_BIN" register >/dev/null 2>&1
        "$WGCF_BIN" generate >/dev/null 2>&1
        
        if [ -f "wgcf-profile.conf" ]; then
            WG_PRIV=$(grep "PrivateKey" wgcf-profile.conf | awk '{print $3}')
            WG_IP4=$(grep "Address" wgcf-profile.conf | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+" | head -n 1)
            WG_IP6=$(grep "Address" wgcf-profile.conf | grep -oE "([a-fA-F0-9:]+)/[0-9]+" | head -n 1)
            msg_success "WARP 原生密钥生成成功！"
        else
            msg_warn "WARP 注册失败，将默认走直连出站。"
            WG_PRIV="none"; WG_IP4="172.16.0.2/32"; WG_IP6="2606:4700:110:8f81::2/128"
        fi
        cd - >/dev/null
    fi
}

# --- 配置构建引擎 ---
generate_config() {
    mkdir -p "$SB_DIR"
    if [ ! -f "${SB_DIR}/server.crt" ]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "${SB_DIR}/server.key" -out "${SB_DIR}/server.crt" -subj "/CN=bing.com" -days 3650 >/dev/null 2>&1
    fi

    local rules_json='{"outbound": "direct-out"}'
    if [ "$WARP_MODE" == "2" ] && [ "$WG_PRIV" != "none" ]; then 
        rules_json='{"outbound": "warp-out"}'
    elif [ "$WARP_MODE" == "3" ] && [ -n "$WARP_DOMAINS" ] && [ "$WG_PRIV" != "none" ]; then
        IFS=',' read -ra DOMAINS <<< "$WARP_DOMAINS"; local domain_array=""
        for d in "${DOMAINS[@]}"; do [ -n "$d" ] && domain_array+="\"$d\","; done
        domain_array=${domain_array%,}
        if [ -n "$domain_array" ]; then
            rules_json="{ \"domain_suffix\": [${domain_array}], \"outbound\": \"warp-out\" }, { \"outbound\": \"direct-out\" }"
        fi
    fi

    local warp_outbound_json='{ "type": "block", "tag": "warp-out" }'
    if [ "$WG_PRIV" != "none" ]; then
        warp_outbound_json="{
            \"type\": \"wireguard\", \"tag\": \"warp-out\",
            \"server\": \"engage.cloudflareclient.com\", \"server_port\": 2408,
            \"local_address\": [\"$WG_IP4\", \"$WG_IP6\"],
            \"private_key\": \"$WG_PRIV\",
            \"peer_public_key\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\",
            \"mtu\": 1280
        }"
    fi

    cat > "$SB_CONF" << EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": $PORT_VD, "tcp_fast_open": true, "users": [ { "uuid": "$UUID", "flow": "" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "transport": { "type": "ws", "path": "/ws" } },
    { "type": "vless", "tag": "in-argo", "listen": "127.0.0.1", "listen_port": 10086, "tcp_fast_open": true, "users": [ { "uuid": "$UUID", "flow": "" } ], "transport": { "type": "ws", "path": "/argo" } },
    { "type": "hysteria2", "tag": "in-hy2", "listen": "::", "listen_port": $PORT_HY, "users": [ { "password": "$PW_HY" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" } },
    { "type": "tuic", "tag": "in-tuic", "listen": "::", "listen_port": $PORT_TC, "users": [ { "uuid": "$UUID", "password": "$PW_TC" } ], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "congestion_control": "bbr", "udp_relay_mode": "quic" },
    { "type": "socks", "tag": "in-socks", "listen": "::", "listen_port": $PORT_S5, "users": [ { "username": "$S5_U", "password": "$S5_P" } ] }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    $warp_outbound_json,
    { "type": "block", "tag": "block-out" }
  ],
  "route": { "rules": [ $rules_json ], "auto_detect_interface": true, "final": "direct-out" }
}
EOF
    save_config
}

setup_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Core Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN run -c $SB_CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    local ARGO_CMD="$ARGO_BIN tunnel --url http://127.0.0.1:10086 --protocol http2 --edge-ip-version 4 --retries 5 --no-autoupdate"
    [ "$ARGO_MODE" == "fixed" ] && ARGO_CMD="$ARGO_BIN tunnel run --protocol http2 --edge-ip-version 4 --token ${ARGO_TOKEN}"
    
    cat > /etc/systemd/system/sb-argo.service << EOF
[Unit]
Description=Cloudflared Argo Tunnel
After=network.target sing-box.service

[Service]
ExecStart=/bin/bash -c '$ARGO_CMD > $ARGO_LOG 2>&1'
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box sb-argo >/dev/null 2>&1
    systemctl restart sing-box sb-argo
}

# --- 菜单功能实现 ---
install_all() {
    print_logo
    if [ -f "$SB_INFO" ]; then
        msg_warn "检测到系统已存在部署配置。"
        reading "是否清除并强制重装？(y/n): " confirm
        [[ "$confirm" != "y" ]] && return
    fi
    
    get_architecture
    install_deps
    install_singbox
    install_argo
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PORT_VD=$(get_random_port); PORT_HY=$(get_random_port)
    PORT_TC=$(get_random_port); PORT_S5=$(get_random_port)
    
    PW_HY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    PW_TC=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    S5_U="user"; S5_P=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)
    
    ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
    WARP_MODE="1"; WARP_DOMAINS=""; WG_PRIV=""
    
    install_wgcf_warp

    msg_info "正在生成底层架构配置并拉起系统服务..."
    generate_config; setup_services
    msg_success "部署完成！底层防护已生效。"
    sleep 2
}

manage_protocols() {
    [ ! -f "$SB_INFO" ] && msg_error "请先部署系统！" && sleep 1 && return
    load_config
    while true; do
        print_logo
        echo -e "${CYAN}┌── 独立协议配置管理 ───────────────┐${NC}"
        echo -e "${CYAN}│${NC}  [1] 修改 VLESS    (端口: $PORT_VD)"
        echo -e "${CYAN}│${NC}  [2] 修改 Hy2      (端口: $PORT_HY)"
        echo -e "${CYAN}│${NC}  [3] 修改 TUIC v5  (端口: $PORT_TC)"
        echo -e "${CYAN}│${NC}  [4] 修改 SOCKS5   (端口: $PORT_S5)"
        echo -e "${CYAN}│${NC}  [5] 配置 Argo隧道 (模式: $ARGO_MODE)"
        echo -e "${CYAN}│${NC}  [0] 返回主菜单"
        echo -e "${CYAN}└───────────────────────────────────┘${NC}"
        reading "选择 [0-5]: " choice
        case $choice in
            1) reading "➤ 新 VLESS 端口 (回车不变): " p; [ -n "$p" ] && PORT_VD=$p; reading "➤ 新 UUID (回车不变): " u; [ -n "$u" ] && UUID=$u ;;
            2) reading "➤ 新 Hy2 端口 (回车不变): " p; [ -n "$p" ] && PORT_HY=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && PW_HY=$pw ;;
            3) reading "➤ 新 TUIC 端口 (回车不变): " p; [ -n "$p" ] && PORT_TC=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && PW_TC=$pw ;;
            4) reading "➤ 新 Socks5 端口 (回车不变): " p; [ -n "$p" ] && PORT_S5=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && S5_P=$pw ;;
            5)
                reading "➤ [1] 临时隧道(随机域名)  [2] 固定隧道: " am
                if [ "$am" == "2" ]; then
                    ARGO_MODE="fixed"
                    reading "➤ 固定域名 (如 v.domain.com): " d; [ -n "$d" ] && ARGO_DOMAIN=$d
                    reading "➤ Cloudflare Token: " t; [ -n "$t" ] && ARGO_TOKEN=$t
                else
                    ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
                fi
                ;;
            0) break ;;
            *) continue ;;
        esac
        generate_config; setup_services
        msg_success "配置已热重载！"; sleep 1
    done
}

manage_warp() {
    [ ! -f "$SB_INFO" ] && msg_error "请先部署系统！" && sleep 1 && return
    load_config
    while true; do
        print_logo
        local mode_str="原生直连"
        [ "$WARP_MODE" == "2" ] && mode_str="全局 WARP (WireGuard)"
        [ "$WARP_MODE" == "3" ] && mode_str="路由分流 (WireGuard)"
        
        echo -e "${CYAN}┌── WARP 原生分流配置 ──────────────┐${NC}"
        echo -e "${CYAN}│${NC} 当前模式: ${GREEN}$mode_str${NC}"
        [ "$WARP_MODE" == "3" ] && echo -e "${CYAN}│${NC} 分流名单: ${YELLOW}${WARP_DOMAINS:-无}${NC}"
        echo -e "${CYAN}├───────────────────────────────────┤${NC}"
        echo -e "${CYAN}│${NC}  [1] 切换工作模式"
        echo -e "${CYAN}│${NC}  [2] 追加分流域名"
        echo -e "${CYAN}│${NC}  [3] 移除分流域名"
        echo -e "${CYAN}│${NC}  [4] 重置分流名单"
        echo -e "${CYAN}│${NC}  [0] 返回主菜单"
        echo -e "${CYAN}└───────────────────────────────────┘${NC}"
        
        reading "选择 [0-4]: " choice
        case $choice in
            1)
                echo -e "  ➤ [1]=关闭  [2]=全局WARP  [3]=指定分流"
                reading "➤ 选择模式: " wm; [ -n "$wm" ] && WARP_MODE=$wm
                [[ "$WARP_MODE" == "2" || "$WARP_MODE" == "3" ]] && install_wgcf_warp
                ;;
            2) reading "➤ 追加域名 (如 netflix.com): " nd; [ -n "$nd" ] && { [ -z "$WARP_DOMAINS" ] && WARP_DOMAINS="$nd" || WARP_DOMAINS="$WARP_DOMAINS,$nd"; } ;;
            3) reading "➤ 移除域名: " rm_d; [ -n "$rm_d" ] && WARP_DOMAINS=$(echo "$WARP_DOMAINS" | sed -e "s/$rm_d//g" -e 's/,,/,/g' -e 's/^,//' -e 's/,$//') ;;
            4) WARP_DOMAINS="" ;;
            0) break ;;
        esac
        generate_config; systemctl restart sing-box
        msg_success "WARP 策略已生效！"; sleep 1
    done
}

show_nodes() {
    print_logo; [ ! -f "$SB_INFO" ] && msg_error "请先部署系统！" && sleep 1 && return
    load_config
    out_ip=$(get_outbound_ip)
    
    if [ -z "$CUSTOM_IP" ]; then
        echo -e "${YELLOW}检测出站IP为: ${GREEN}$out_ip${NC}"
        reading "➤ 若需指定入站IP/域名请在此输入 (一致请直接回车): " in_ip
        [ -n "$in_ip" ] && CUSTOM_IP=$in_ip || CUSTOM_IP=$out_ip
        save_config
    fi

    local ip=$CUSTOM_IP; [[ "$ip" =~ .*:.* ]] && ip="[${ip}]" 
    local all_links=""
    
    echo -e "\n${CYAN}┌── 节点信息汇总 ─────────────────────────────────┐${NC}"
    # 1. VLESS
    echo -e "${CYAN}│${NC} [1] VLESS WS: 伪装直连"
    link1="vless://${UUID}@${ip}:${PORT_VD}?encryption=none&security=tls&sni=bing.com&alpn=http%2F1.1&type=ws&host=bing.com&path=%2Fws&allowInsecure=1#SB-VLESS"
    echo -e "${CYAN}│${NC}     ${link1}"; all_links+="$link1\n"
    
    # 2. Argo
    local argo_domain=""
    if [ "$ARGO_MODE" == "temp" ]; then
        for i in {1..8}; do
            argo_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
            [ -n "$argo_domain" ] && break; sleep 1
        done
    elif [ "$ARGO_MODE" == "fixed" ]; then
        argo_domain="$ARGO_DOMAIN"
    fi
    
    echo -e "${CYAN}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} [2] VLESS Argo: 穿透隧道"
    if [ -n "$argo_domain" ]; then
        link2="vless://${UUID}@www.visa.com.sg:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2Fargo#SB-Argo"
        echo -e "${CYAN}│${NC}     ${link2}"; all_links+="$link2\n"
    else 
        echo -e "${CYAN}│${NC}     ${RED}(隧道建立延迟，请稍后再次查看或检查日志)${NC}"
    fi

    # 3. Hysteria 2
    echo -e "${CYAN}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} [3] Hysteria2: 暴力加速"
    link3="hysteria2://${PW_HY}@${ip}:${PORT_HY}?insecure=1&sni=bing.com#SB-Hy2"
    echo -e "${CYAN}│${NC}     ${link3}"; all_links+="$link3\n"
    
    # 4. TUIC v5
    echo -e "${CYAN}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} [4] TUIC v5: QUIC 协议"
    link4="tuic://${UUID}:${PW_TC}@${ip}:${PORT_TC}?sni=bing.com&alpn=h3&congestion_control=bbr&allow_insecure=1#SB-TUIC"
    echo -e "${CYAN}│${NC}     ${link4}"; all_links+="$link4\n"
    
    # 5. SOCKS5
    echo -e "${CYAN}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} [5] SOCKS5: 基础代理"
    link5="socks://$(echo -n "${S5_U}:${S5_P}" | base64 | tr -d '\n')@${ip}:${PORT_S5}#SB-Socks5"
    echo -e "${CYAN}│${NC}     ${link5}"; all_links+="$link5\n"
    echo -e "${CYAN}└─────────────────────────────────────────────────┘${NC}"

    echo -e "\n${YELLOW}Base64 订阅链接 (已自动备份至 /root/sub.txt):${NC}"
    local final_b64=$(echo -e "$all_links" | sed '/^$/d' | base64 | tr -d '\n')
    echo -e "$final_b64"
    echo -e "$final_b64" > /root/sub.txt
    
    echo -e "\n"
    reading "按回车键返回..." dummy
}

uninstall_script() {
    print_logo
    reading "➤ 确定要彻底卸载系统并删除程序配置吗? (y/n): " c
    [[ "$c" != "y" ]] && return

    msg_info "正在清理底层服务与程序数据 (保留 sub.txt)..."
    systemctl stop sing-box sb-argo >/dev/null 2>&1
    systemctl disable sing-box sb-argo >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb-argo.service
    rm -rf "$SB_DIR" "$SB_BIN" "$ARGO_BIN" "$WGCF_BIN" "/usr/bin/sb"
    systemctl daemon-reload
    msg_success "程序和配置已完全卸载，订阅链接留存至 /root/sub.txt。"; exit 0
}

main_menu() {
    while true; do
        print_logo
        local status="${RED}未安装 (停机)${NC}"
        [ -f "$SB_INFO" ] && status="${GREEN}已安装 (运行中)${NC}"
        
        echo -e "   状态: $status"
        echo -e "   ────────────────────────────────"
        echo -e "   ${GREEN}[1]${NC} 部署 / 重置核心架构"
        echo -e "   ${GREEN}[2]${NC} 协议与端口参数管理"
        echo -e "   ${GREEN}[3]${NC} WARP 原生分流管理"
        echo -e "   ${GREEN}[4]${NC} 获取节点订阅信息"
        echo -e "   ────────────────────────────────"
        echo -e "   ${RED}[9]${NC} 彻底卸载清理"
        echo -e "   ${RED}[0]${NC} 退出"
        echo ""
        reading "输入指令: " choice
        case $choice in
            1) install_all ;;
            2) manage_protocols ;;
            3) manage_warp ;;
            4) show_nodes ;;
            9) uninstall_script ;;
            0) clear; exit 0 ;;
            *) ;;
        esac
    done
}

main_menu

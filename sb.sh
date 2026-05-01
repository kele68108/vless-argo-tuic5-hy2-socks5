#!/bin/bash

# ==========================================
# Sing-box 5-in-1 全能架构版 (v3.0 终极纯血版)
# 核心：Sing-box 统一管理 5 大协议入站与路由
# 优势：彻底解决断流，统一配置文件，性能拉满
# ==========================================

red() { echo -e "\033[1;91m$1\033[0m"; }
green() { echo -e "\033[1;32m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
purple() { echo -e "\033[1;35m$1\033[0m"; }
reading() { echo -ne "$(green "$1")" >&2; read -r "$2"; }

SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
SB_INFO="${SB_DIR}/install.info"
SB_BIN="/usr/local/bin/sing-box"

[[ $EUID -ne 0 ]] && red "错误：必须以 root 用户运行此脚本！" && exit 1

# --- 快捷指令 ---
if [[ -f "$0" ]] && [[ "$0" != "/usr/bin/sb" ]]; then
    cp -f "$0" /usr/bin/sb
    chmod +x /usr/bin/sb
    green "[提示] 快捷指令 'sb' 已创建，以后在终端直接输入 sb 即可唤出本菜单！"
    sleep 1
fi

# --- 1. 基础工具与防断流优化 ---
check_port_usage() {
    local port=$1; [ -z "$port" ] && return 0
    if lsof -i :$port >/dev/null 2>&1 || netstat -tuln | grep -q ":$port "; then return 1; fi
    return 0
}

get_outbound_ip() {
    local ip=$(curl -s4 --max-time 3 https://api.ipify.org)
    [ -z "$ip" ] && ip=$(curl -s6 --max-time 3 ipv6.ip.sb)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

optimize_network() {
    cat > /etc/sysctl.d/99-singbox-optimize.conf << EOF
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-singbox-optimize.conf >/dev/null 2>&1
}

install_deps() {
    yellow ">> 正在检查并安装基础依赖..."
    apt-get update -y >/dev/null 2>&1 || yum makecache -y >/dev/null 2>&1
    local pkgs=("curl" "wget" "jq" "openssl" "gpg" "lsb-release" "lsof" "net-tools")
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            apt-get install -y "$pkg" >/dev/null 2>&1 || yum install -y "$pkg" >/dev/null 2>&1
        fi
    done
    optimize_network
}

# --- 2. 核心组件安装 ---
install_singbox() {
    if [ ! -f "$SB_BIN" ]; then
        yellow ">> 正在下载并部署 Sing-box 核心..."
        ARCH=$(uname -m)
        case "${ARCH}" in x86_64) S_ARCH="amd64" ;; aarch64|arm64) S_ARCH="armv8" ;; *) red "不支持的架构: $ARCH"; exit 1 ;; esac
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
        curl -sLo sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${S_ARCH}.tar.gz"
        tar -xzf sb.tar.gz; mv sing-box-*/sing-box "$SB_BIN"; rm -rf sb.tar.gz sing-box-*
        chmod +x "$SB_BIN"
    fi
}

install_warp() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        yellow ">> 正在安装 Cloudflare WARP 客户端..."
        curl -fsSl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
        apt-get update -y >/dev/null 2>&1 && apt-get install -y cloudflare-warp >/dev/null 2>&1
    fi
    
    yellow ">> 正在初始化 WARP 动态引擎 (代理模式 40000 端口)..."
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
}

# --- 3. 配置文件生成 ---
generate_config() {
    local uuid=$1; local pw_hy=$2; local pw_tc=$3; local s5_u=$4; local s5_p=$5
    local port_vd=$6; local port_hy=$7; local port_tc=$8; local port_s5=$9
    local argo_port=10086; local warp_mode=${10}; local warp_domains=${11}

    mkdir -p "$SB_DIR"
    if [ ! -f "${SB_DIR}/server.crt" ]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "${SB_DIR}/server.key" -out "${SB_DIR}/server.crt" -subj "/CN=bing.com" -days 3650 >/dev/null 2>&1
    fi

    local rules_json=""
    if [ "$warp_mode" == "2" ]; then rules_json='{"outbound": "warp-out"}'
    elif [ "$warp_mode" == "3" ]; then
        IFS=',' read -ra DOMAINS <<< "$warp_domains"; local domain_array=""
        for d in "${DOMAINS[@]}"; do domain_array+="\"$d\","; done
        domain_array=${domain_array%,}
        rules_json="{ \"domain_suffix\": [${domain_array}], \"outbound\": \"warp-out\" }, { \"outbound\": \"direct-out\" }"
    else rules_json='{"outbound": "direct-out"}'; fi

    cat > "$SB_CONF" << EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": $port_vd, "users": [ { "uuid": "$uuid", "flow": "" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "transport": { "type": "ws", "path": "/ws" } },
    { "type": "vless", "tag": "in-argo", "listen": "127.0.0.1", "listen_port": $argo_port, "users": [ { "uuid": "$uuid", "flow": "" } ], "transport": { "type": "ws", "path": "/argo" } },
    { "type": "hysteria2", "tag": "in-hy2", "listen": "::", "listen_port": $port_hy, "users": [ { "password": "$pw_hy" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" } },
    { "type": "tuic", "tag": "in-tuic", "listen": "::", "listen_port": $port_tc, "users": [ { "uuid": "$uuid", "password": "$pw_tc" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "congestion_control": "bbr" },
    { "type": "socks", "tag": "in-socks", "listen": "::", "listen_port": $port_s5, "users": [ { "username": "$s5_u", "password": "$s5_p" } ] }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    { "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40000 },
    { "type": "block", "tag": "block-out" }
  ],
  "route": { "rules": [ $rules_json ], "auto_detect_interface": true, "final": "direct-out" }
}
EOF

    # 保存配置信息供随时查看
    cat > "$SB_INFO" << EOF
UUID=$uuid
PW_HY=$pw_hy
PW_TC=$pw_tc
S5_U=$s5_u
S5_P=$s5_p
PORT_VD=$port_vd
PORT_HY=$port_hy
PORT_TC=$port_tc
PORT_S5=$port_s5
WARP_MODE=$warp_mode
WARP_DOMAINS=$warp_domains
EOF
}

setup_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Core Service
After=network.target
[Service]
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sing-box >/dev/null 2>&1
    systemctl restart sing-box
}

# --- 4. 交互与菜单功能 ---
install_all() {
    clear; purple "====== Sing-box 5-in-1 全能版安装 ======"
    install_deps; install_singbox
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    reading "1. 分配全局 UUID [回车默认: $uuid]: " in_uuid; [ -n "$in_uuid" ] && uuid=$in_uuid
    
    yellow "\n--- 端口分配 (自动避开冲突) ---"
    while true; do port_vd=$((RANDOM % 50000 + 10000)); check_port_usage $port_vd && break; done
    while true; do port_hy=$((RANDOM % 50000 + 10000)); check_port_usage $port_hy && break; done
    while true; do port_tc=$((RANDOM % 50000 + 10000)); check_port_usage $port_tc && break; done
    while true; do port_s5=$((RANDOM % 50000 + 10000)); check_port_usage $port_s5 && break; done
    
    pw_hy=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    pw_tc=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    s5_u="user"; s5_p=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)

    echo "VLESS WS 端口: $port_vd | Hysteria 2 端口: $port_hy"
    echo "TUIC v5 端口: $port_tc | SOCKS5 端口: $port_s5"

    yellow "\n--- WARP 分流配置 ---"
    green "1. 关闭 WARP (原生 IP 直连)"
    green "2. 全局 WARP (所有流量走 CF)"
    green "3. 指定网址 WARP (建议: chatgpt.com,netflix.com,openai.com)"
    reading "请选择 WARP 模式 (1/2/3): " warp_mode
    
    local warp_domains=""
    if [[ "$warp_mode" == "2" || "$warp_mode" == "3" ]]; then install_warp; fi
    if [ "$warp_mode" == "3" ]; then
        reading "请输入走 WARP 的域名后缀 (英文逗号隔开): " warp_domains
    fi

    yellow "\n>> 正在生成节点并启动服务..."
    generate_config "$uuid" "$pw_hy" "$pw_tc" "$s5_u" "$s5_p" "$port_vd" "$port_hy" "$port_tc" "$port_s5" "$warp_mode" "$warp_domains"
    setup_services
    green "✅ 部署完成！"
    sleep 2; show_nodes
}

show_nodes() {
    clear; if [ ! -f "$SB_INFO" ]; then red "未检测到安装信息！"; sleep 2; return; fi
    source "$SB_INFO"
    
    yellow "正在分析 IP 环境..."
    out_ip=$(get_outbound_ip); raw_ip=$out_ip
    reading "您的出站 IP 是 $out_ip。如果处于 NAT 环境需强行指定 IP 请输入 (回车默认使用出站IP): " in_ip
    [ -n "$in_ip" ] && raw_ip=$in_ip
    if [[ "$raw_ip" =~ .*:.* ]]; then ip="[${raw_ip}]"; else ip="${raw_ip}"; fi

    purple "\n================== 节点信息汇总 ==================\n"
    local all_links=""
    
    green "1. [VLESS + WS + TLS] (伪装 TLS)"
    link1="vless://${UUID}@${ip}:${PORT_VD}?encryption=none&security=tls&sni=bing.com&alpn=http%2F1.1&type=ws&host=bing.com&path=%2Fws&allowInsecure=1#SB-VLESS"
    echo "   $link1"; all_links+="$link1\n"; echo "--------------------------------------------------"
    
    green "2. [Hysteria 2]"
    link2="hysteria2://${PW_HY}@${ip}:${PORT_HY}?insecure=1&sni=bing.com#SB-Hy2"
    echo "   $link2"; all_links+="$link2\n"; echo "--------------------------------------------------"
    
    green "3. [TUIC v5]"
    link3="tuic://${UUID}:${PW_TC}@${ip}:${PORT_TC}?sni=bing.com&alpn=h3&congestion_control=bbr&allow_insecure=1#SB-TUIC"
    echo "   $link3"; all_links+="$link3\n"; echo "--------------------------------------------------"
    
    green "4. [SOCKS5]"
    b64_cred=$(echo -n "${S5_U}:${S5_P}" | base64 | tr -d '\n')
    link4="socks://${b64_cred}@${ip}:${PORT_S5}#SB-Socks5"
    echo "   $link4"; all_links+="$link4\n"; echo "--------------------------------------------------"

    yellow "\n=== Base64 订阅码 (复制到软件) ==="
    echo -e "$all_links" | sed '/^$/d' | base64 | tr -d '\n'
    
    if [ "$WARP_MODE" == "3" ]; then
        purple "\n[WARP 分流已开启] 当前走 CF 的域名: $WARP_DOMAINS"
    elif [ "$WARP_MODE" == "2" ]; then
        purple "\n[WARP 全局已开启] 所有流量均走 Cloudflare 出口"
    fi
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..."
}

modify_warp() {
    clear; if [ ! -f "$SB_INFO" ]; then red "未检测到安装信息！"; sleep 2; return; fi
    source "$SB_INFO"
    
    purple "====== 修改 WARP 分流规则 ======"
    echo "当前模式: $WARP_MODE"
    [ "$WARP_MODE" == "3" ] && echo "当前分流域名: $WARP_DOMAINS"
    
    green "\n1. 关闭 WARP"
    green "2. 全局 WARP"
    green "3. 指定网址 WARP (修改域名)"
    reading "请选择新模式 (1/2/3): " new_mode
    
    local new_domains=""
    if [[ "$new_mode" == "2" || "$new_mode" == "3" ]]; then install_warp; fi
    if [ "$new_mode" == "3" ]; then
        reading "请输入走 WARP 的域名后缀 (如 chatgpt.com,netflix.com): " new_domains
    fi
    
    generate_config "$UUID" "$PW_HY" "$PW_TC" "$S5_U" "$S5_P" "$PORT_VD" "$PORT_HY" "$PORT_TC" "$PORT_S5" "$new_mode" "$new_domains"
    systemctl restart sing-box
    green "WARP 规则已热重载生效！"; sleep 2
}

uninstall_script() {
    clear; red "!!! 危险操作 !!!"
    reading "确定要彻底删除 Sing-box, WARP 及所有配置吗? (y/n): " c
    [[ "$c" != "y" ]] && return

    yellow "正在停止服务并清理系统..."
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service
    
    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli disconnect >/dev/null 2>&1
        apt-get remove -y cloudflare-warp >/dev/null 2>&1
    fi

    rm -rf "$SB_DIR" "$SB_BIN" "/usr/bin/sb"
    systemctl daemon-reload
    green "所有内容已彻底卸载。"; rm -f "$0"; exit 0
}

main_menu() {
    while true; do
        clear; purple "====== Sing-box 5-in-1 (WARP 分流) ======"
        green "1. 一键部署 / 重置安装"
        green "2. 查看节点信息与订阅链接"
        green "3. 修改 WARP 分流规则 (热重载)"
        echo "-----------------------------------------"
        red "9. 彻底卸载脚本与服务"
        red "0. 退出"
        reading "请选择: " choice
        case $choice in
            1) install_all ;;
            2) show_nodes ;;
            3) modify_warp ;;
            9) uninstall_script ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

main_menu

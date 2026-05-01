#!/bin/bash

# ==========================================
# Sing-box 5-in-1 全能架构版 (v4.1 完美体验版)
# 修复：Argo 隧道固定模式缺少域名、Token 无防呆校验的问题
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
ARGO_BIN="/usr/local/bin/cloudflared"
ARGO_LOG="${SB_DIR}/argo.log"

[[ $EUID -ne 0 ]] && red "错误：必须以 root 用户运行此脚本！" && exit 1

# --- 强制覆盖修复快捷指令 ---
if [[ "$0" != "/usr/bin/sb" ]]; then
    rm -f /usr/bin/sb 2>/dev/null
    cp -f "$0" /usr/bin/sb
    chmod +x /usr/bin/sb
    green "[提示] 快捷指令 'sb' 已创建/修复，以后直接输入 sb 即可唤出菜单！"
    sleep 1
fi

# --- 核心数据读写 ---
load_config() {
    [ -f "$SB_INFO" ] && source "$SB_INFO"
}
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
EOF
}

# --- 基础工具 ---
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
        if ! command -v "$pkg" >/dev/null 2>&1; then apt-get install -y "$pkg" >/dev/null 2>&1 || yum install -y "$pkg" >/dev/null 2>&1; fi
    done
    optimize_network
}

# --- 核心组件部署 ---
install_singbox() {
    if [ ! -f "$SB_BIN" ]; then
        yellow ">> 正在部署 Sing-box 核心..."
        ARCH=$(uname -m); case "${ARCH}" in x86_64) S_ARCH="amd64" ;; aarch64|arm64) S_ARCH="armv8" ;; *) red "不支持的架构"; exit 1 ;; esac
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
        curl -sLo sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${S_ARCH}.tar.gz"
        tar -xzf sb.tar.gz; mv sing-box-*/sing-box "$SB_BIN"; rm -rf sb.tar.gz sing-box-*
        chmod +x "$SB_BIN"
    fi
}

install_argo() {
    if [ ! -f "$ARGO_BIN" ]; then
        yellow ">> 正在部署 Cloudflared (Argo) 核心..."
        ARCH=$(uname -m); case "${ARCH}" in x86_64) A_ARCH="amd64" ;; aarch64|arm64) A_ARCH="arm64" ;; esac
        curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A_ARCH}" -o "$ARGO_BIN"
        chmod +x "$ARGO_BIN"
    fi
}

install_warp() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        yellow ">> 正在安装 Cloudflare WARP 客户端..."
        curl -fsSl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
        apt-get update -y >/dev/null 2>&1 && apt-get install -y cloudflare-warp >/dev/null 2>&1
    fi
    warp-cli --accept-tos registration new >/dev/null 2>&1
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
    warp-cli --accept-tos connect >/dev/null 2>&1
}

# --- 配置引擎 ---
generate_config() {
    mkdir -p "$SB_DIR"
    if [ ! -f "${SB_DIR}/server.crt" ]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "${SB_DIR}/server.key" -out "${SB_DIR}/server.crt" -subj "/CN=bing.com" -days 3650 >/dev/null 2>&1
    fi

    local rules_json='{"outbound": "direct-out"}'
    if [ "$WARP_MODE" == "2" ]; then rules_json='{"outbound": "warp-out"}'
    elif [ "$WARP_MODE" == "3" ] && [ -n "$WARP_DOMAINS" ]; then
        IFS=',' read -ra DOMAINS <<< "$WARP_DOMAINS"; local domain_array=""
        for d in "${DOMAINS[@]}"; do [ -n "$d" ] && domain_array+="\"$d\","; done
        domain_array=${domain_array%,}
        if [ -n "$domain_array" ]; then
            rules_json="{ \"domain_suffix\": [${domain_array}], \"outbound\": \"warp-out\" }, { \"outbound\": \"direct-out\" }"
        fi
    fi

    cat > "$SB_CONF" << EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": $PORT_VD, "users": [ { "uuid": "$UUID", "flow": "" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "transport": { "type": "ws", "path": "/ws" } },
    { "type": "vless", "tag": "in-argo", "listen": "127.0.0.1", "listen_port": 10086, "users": [ { "uuid": "$UUID", "flow": "" } ], "transport": { "type": "ws", "path": "/argo" } },
    { "type": "hysteria2", "tag": "in-hy2", "listen": "::", "listen_port": $PORT_HY, "users": [ { "password": "$PW_HY" } ], "tls": { "enabled": true, "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" } },
    { "type": "tuic", "tag": "in-tuic", "listen": "::", "listen_port": $PORT_TC, "users": [ { "uuid": "$UUID", "password": "$PW_TC" } ], "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "${SB_DIR}/server.crt", "key_path": "${SB_DIR}/server.key" }, "congestion_control": "bbr" },
    { "type": "socks", "tag": "in-socks", "listen": "::", "listen_port": $PORT_S5, "users": [ { "username": "$S5_U", "password": "$S5_P" } ] }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct-out" },
    { "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40000 },
    { "type": "block", "tag": "block-out" }
  ],
  "route": { "rules": [ $rules_json ], "auto_detect_interface": true, "final": "direct-out" }
}
EOF
    save_config
}

setup_services() {
    # Sing-box 服务
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
    # Argo 隧道服务
    local ARGO_CMD="$ARGO_BIN tunnel --url http://localhost:10086 --no-autoupdate --edge-ip-version auto"
    [ "$ARGO_MODE" == "fixed" ] && ARGO_CMD="$ARGO_BIN tunnel run --token ${ARGO_TOKEN}"
    cat > /etc/systemd/system/sb-argo.service << EOF
[Unit]
Description=Argo Tunnel for Sing-box
After=network.target
[Service]
ExecStart=/bin/bash -c '$ARGO_CMD > $ARGO_LOG 2>&1'
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box sb-argo >/dev/null 2>&1
    systemctl restart sing-box sb-argo
}

# --- 菜单功能实现 ---
install_all() {
    clear; purple "====== 极速一键部署 ======"
    if [ -f "$SB_INFO" ]; then
        yellow "检测到已部署过节点！"
        reading "是否确定要清除旧配置并重新安装？(y/n): " confirm
        [[ "$confirm" != "y" ]] && return
    fi
    
    install_deps; install_singbox; install_argo
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    while true; do PORT_VD=$((RANDOM % 50000 + 10000)); check_port_usage $PORT_VD && break; done
    while true; do PORT_HY=$((RANDOM % 50000 + 10000)); check_port_usage $PORT_HY && break; done
    while true; do PORT_TC=$((RANDOM % 50000 + 10000)); check_port_usage $PORT_TC && break; done
    while true; do PORT_S5=$((RANDOM % 50000 + 10000)); check_port_usage $PORT_S5 && break; done
    PW_HY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    PW_TC=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 10)
    S5_U="user"; S5_P=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)
    
    ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
    WARP_MODE="1"; WARP_DOMAINS=""

    yellow "\n>> 正在生成配置并拉起服务..."
    generate_config; setup_services
    green "✅ 部署成功！快去查看节点信息吧。"; sleep 2
}

manage_protocols() {
    [ ! -f "$SB_INFO" ] && red "请先进行一键部署！" && sleep 1 && return
    load_config
    while true; do
        clear; purple "=== 单独协议管理 ==="
        echo "1. 修改 VLESS (端口: $PORT_VD | UUID: $UUID)"
        echo "2. 修改 Hysteria 2 (端口: $PORT_HY | 密码: $PW_HY)"
        echo "3. 修改 TUIC v5 (端口: $PORT_TC | 密码: $PW_TC)"
        echo "4. 修改 SOCKS5 (端口: $PORT_S5 | 用户: $S5_U)"
        echo "5. 配置 Argo 隧道 (当前模式: $ARGO_MODE)"
        echo "0. 返回上级菜单"
        reading "请选择: " choice
        case $choice in
            1) reading "新 VLESS 端口 (回车不变): " p; [ -n "$p" ] && PORT_VD=$p; reading "新 UUID (回车不变): " u; [ -n "$u" ] && UUID=$u ;;
            2) reading "新 Hy2 端口 (回车不变): " p; [ -n "$p" ] && PORT_HY=$p; reading "新密码 (回车不变): " pw; [ -n "$pw" ] && PW_HY=$pw ;;
            3) reading "新 TUIC 端口 (回车不变): " p; [ -n "$p" ] && PORT_TC=$p; reading "新密码 (回车不变): " pw; [ -n "$pw" ] && PW_TC=$pw ;;
            4) reading "新 Socks5 端口 (回车不变): " p; [ -n "$p" ] && PORT_S5=$p; reading "新密码 (回车不变): " pw; [ -n "$pw" ] && S5_P=$pw ;;
            5)
                reading "1=临时隧道(随机域名), 2=固定隧道(填Token/域名): " am
                if [ "$am" == "2" ]; then
                    ARGO_MODE="fixed"
                    
                    # 强校验 1：输入并验证域名
                    while true; do
                        reading "请输入 Cloudflare 绑定的固定域名 (如 v.yourdomain.com): " d
                        if [ -n "$d" ]; then
                            ARGO_DOMAIN=$d
                            break
                        else
                            red "❌ 域名不能为空，请重新输入！"
                        fi
                    done
                    
                    # 强校验 2：输入并严格验证 Token 长度 (防乱敲回车或错误输入)
                    while true; do
                        reading "请输入 Cloudflare Token (极长字符串): " t
                        if [ ${#t} -gt 50 ]; then
                            ARGO_TOKEN=$t
                            break
                        else
                            red "❌ 错误：Token 格式不正确(过短或为空)！Argo Token 通常极长，请检查复制是否完整！"
                        fi
                    done
                else
                    ARGO_MODE="temp"
                    ARGO_TOKEN=""
                    ARGO_DOMAIN=""
                fi
                ;;
            0) break ;;
            *) continue ;;
        esac
        generate_config; setup_services
        green "✅ 配置已更新并热重载！"; sleep 1
    done
}

manage_warp() {
    [ ! -f "$SB_INFO" ] && red "请先进行一键部署！" && sleep 1 && return
    load_config
    while true; do
        clear; purple "====== WARP 智能分流管理 ======"
        local mode_str="原生直连"
        [ "$WARP_MODE" == "2" ] && mode_str="全局 WARP"
        [ "$WARP_MODE" == "3" ] && mode_str="路由分流"
        echo -e "当前模式: \033[1;36m$mode_str\033[0m"
        [ "$WARP_MODE" == "3" ] && echo -e "当前分流域名: \033[1;33m${WARP_DOMAINS:-无}\033[0m"
        echo "--------------------------------"
        green "1. 切换 WARP 模式"
        green "2. 追加分流域名 (仅在路由分流模式下生效)"
        green "3. 清空所有分流域名"
        purple "0. 返回上级菜单"
        reading "请选择: " choice
        case $choice in
            1)
                echo " 1=关闭, 2=全局走WARP, 3=指定网址走WARP"
                reading "选择模式: " wm; [ -n "$wm" ] && WARP_MODE=$wm
                [[ "$WARP_MODE" == "2" || "$WARP_MODE" == "3" ]] && install_warp
                ;;
            2)
                reading "输入要追加的域名 (如 netflix.com): " nd
                if [ -n "$nd" ]; then
                    if [ -z "$WARP_DOMAINS" ]; then WARP_DOMAINS="$nd"
                    else WARP_DOMAINS="$WARP_DOMAINS,$nd"; fi
                fi
                ;;
            3) WARP_DOMAINS="" ;;
            0) break ;;
        esac
        generate_config; systemctl restart sing-box
        green "✅ WARP 规则已热重载生效！"; sleep 1
    done
}

show_nodes() {
    clear; [ ! -f "$SB_INFO" ] && red "请先部署节点！" && sleep 1 && return
    load_config
    
    yellow "正在获取网络环境..."
    out_ip=$(get_outbound_ip)
    
    # IP 记忆功能逻辑
    if [ -z "$CUSTOM_IP" ]; then
        reading "检测出站IP为 $out_ip。请输入您的真实入站IP/域名 (如果一致直接回车): " in_ip
        [ -n "$in_ip" ] && CUSTOM_IP=$in_ip || CUSTOM_IP=$out_ip
        save_config # 记录下来，以后不用再输了
    fi

    local ip=$CUSTOM_IP
    [[ "$ip" =~ .*:.* ]] && ip="[${ip}]" # IPv6 格式化

    purple "\n================== 节点信息汇总 ==================\n"
    local all_links=""
    
    green "1. [VLESS + WS] (端口: $PORT_VD)"
    link1="vless://${UUID}@${ip}:${PORT_VD}?encryption=none&security=tls&sni=bing.com&alpn=http%2F1.1&type=ws&host=bing.com&path=%2Fws&allowInsecure=1#SB-VLESS"
    echo "   $link1"; all_links+="$link1\n"; echo "--------------------------------------------------"
    
    green "2. [VLESS + Argo隧道]"
    local argo_domain=""
    if [ "$ARGO_MODE" == "temp" ]; then
        for i in {1..5}; do
            argo_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
            [ -n "$argo_domain" ] && break; sleep 1
        done
        [ -n "$argo_domain" ] && echo "   类型: 临时隧道 (已成功抓取)"
    elif [ "$ARGO_MODE" == "fixed" ]; then
        argo_domain="$ARGO_DOMAIN"
        echo "   类型: 固定隧道"
    fi
    
    if [ -n "$argo_domain" ]; then
        link2="vless://${UUID}@www.visa.com.sg:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2Fargo#SB-Argo"
        echo "   域名: $argo_domain"
        echo "   $link2"; all_links+="$link2\n"
    else red "   (获取 Argo 域名失败，请检查服务日志 /var/log/messages)"; fi
    echo "--------------------------------------------------"
    
    green "3. [Hysteria 2] (端口: $PORT_HY)"
    link3="hysteria2://${PW_HY}@${ip}:${PORT_HY}?insecure=1&sni=bing.com#SB-Hy2"
    echo "   $link3"; all_links+="$link3\n"; echo "--------------------------------------------------"
    
    green "4. [TUIC v5] (端口: $PORT_TC)"
    link4="tuic://${UUID}:${PW_TC}@${ip}:${PORT_TC}?sni=bing.com&alpn=h3&congestion_control=bbr&allow_insecure=1#SB-TUIC"
    echo "   $link4"; all_links+="$link4\n"; echo "--------------------------------------------------"
    
    green "5. [SOCKS5] (端口: $PORT_S5)"
    b64_cred=$(echo -n "${S5_U}:${S5_P}" | base64 | tr -d '\n')
    link5="socks://${b64_cred}@${ip}:${PORT_S5}#SB-Socks5"
    echo "   $link5"; all_links+="$link5\n"; echo "--------------------------------------------------"

    yellow "\n=== Base64 订阅码 (复制到软件) ==="
    echo -e "$all_links" | sed '/^$/d' | base64 | tr -d '\n'
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..."
}

uninstall_script() {
    clear; red "!!! 危险操作 !!!"
    reading "确定要彻底删除节点及所有配置吗? (y/n): " c
    [[ "$c" != "y" ]] && return

    yellow "正在清理系统..."
    systemctl stop sing-box sb-argo >/dev/null 2>&1
    systemctl disable sing-box sb-argo >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb-argo.service
    
    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli disconnect >/dev/null 2>&1
        apt-get remove -y cloudflare-warp >/dev/null 2>&1
    fi

    rm -rf "$SB_DIR" "$SB_BIN" "$ARGO_BIN" "/usr/bin/sb"
    systemctl daemon-reload
    green "所有内容已彻底卸载。"; rm -f "$0"; exit 0
}

main_menu() {
    while true; do
        clear; purple "====== Sing-box 全能版 (v4.1 完美体验版) ======"
        local status="未安装"
        [ -f "$SB_INFO" ] && status="已安装"
        echo -e "当前系统状态: \033[1;32m$status\033[0m"
        echo "-------------------------------------------"
        green "1. 一键部署 / 重置安装"
        green "2. 独立管理代理协议 (修改端口/密码等)"
        green "3. 管理 WARP 智能分流 (追加/清空)"
        green "4. 查看节点信息与订阅链接"
        echo "-------------------------------------------"
        red "9. 彻底卸载脚本与服务"
        red "0. 退出"
        reading "请选择: " choice
        case $choice in
            1) install_all ;;
            2) manage_protocols ;;
            3) manage_warp ;;
            4) show_nodes ;;
            9) uninstall_script ;;
            0) exit 0 ;;
        esac
    done
}

main_menu

#!/bin/bash

# ==========================================
# Sing-box 5-in-1 全能架构版 (一键极速部署)
# 特性：极致终端 UI，新版 DNS 路由引擎，ACME 真实证书，I/O 强校验
# ==========================================

# --- 视觉与色彩引擎 ---
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; PURPLE='\033[1;35m'; CYAN='\033[1;36m'; NC='\033[0m'

msg_info() { echo -e "${CYAN}[ℹ️ INFO]${NC} $1"; }
msg_success() { echo -e "${GREEN}[✅ OK]${NC} $1"; }
msg_warn() { echo -e "${YELLOW}[⚠️ WARN]${NC} $1"; }
msg_error() { echo -e "${RED}[❌ ERR]${NC} $1"; }
reading() { echo -ne "${CYAN}➤ $1${NC}" >&2; read -r "$2"; }

print_logo() {
    clear
    echo -e "${PURPLE}╭━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╮${NC}"
    echo -e "${PURPLE}┃${NC}   🚀 ${CYAN}Sing-box 5-in-1全能引擎 ${YELLOW}(一键极速部署)${NC}   ${PURPLE}┃${NC}"
    echo -e "${PURPLE}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}"
    echo ""
}

# --- 全局变量 ---
SB_DIR="/etc/sing-box"
SB_CONF="${SB_DIR}/config.json"
SB_INFO="${SB_DIR}/install.info"
SB_BIN="/usr/local/bin/sing-box"
ARGO_BIN="/usr/local/bin/cloudflared"
ARGO_LOG="${SB_DIR}/argo.log"

[[ $EUID -ne 0 ]] && msg_error "必须以 root 用户运行此脚本！" && exit 1

# --- 强制覆盖修复快捷指令 ---
if [[ "$0" != "/usr/bin/sb" ]]; then
    rm -f /usr/bin/sb 2>/dev/null
    cp -f "$0" /usr/bin/sb
    chmod +x /usr/bin/sb
    msg_success "快捷指令 'sb' 已就绪，以后直接输入 sb 即可唤出面板！"
    sleep 1
fi

# --- 核心数据读写 ---
load_config() { 
    [ -f "$SB_INFO" ] && source "$SB_INFO"
    # 兼容老版本默认值
    [ -z "$VD_MODE" ] && VD_MODE="2"
    [ -z "$VD_DOMAIN" ] && VD_DOMAIN=""
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
VD_MODE=$VD_MODE
VD_DOMAIN=$VD_DOMAIN
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
    msg_info "正在检查并安装基础依赖环境..."
    apt-get update -y >/dev/null 2>&1 || yum makecache -y >/dev/null 2>&1
    local pkgs=("curl" "wget" "jq" "openssl" "gpg" "lsb-release" "lsof" "net-tools" "socat")
    for pkg in "${pkgs[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then apt-get install -y "$pkg" >/dev/null 2>&1 || yum install -y "$pkg" >/dev/null 2>&1; fi
    done
    optimize_network
}

# --- 健壮性下载引擎 ---
safe_download() {
    local url=$1
    local dest=$2
    msg_info "正在获取: $url"
    local http_code=$(curl -sL -w "%{http_code}" -o "$dest" "$url")
    if [ "$http_code" != "200" ]; then
        msg_error "文件拉取失败！(HTTP 状态码: $http_code)"
        rm -f "$dest"
        return 1
    fi
    if [ ! -s "$dest" ]; then
        msg_error "下载失败！文件为空。"
        rm -f "$dest"
        return 1
    fi
    return 0
}

# --- ACME 证书申请模块 ---
apply_cert() {
    local domain=$1
    if [ ! -d ~/.acme.sh ]; then msg_warn "正在安装 acme.sh 证书工具..."; curl https://get.acme.sh | sh >/dev/null 2>&1; fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    
    echo ""; msg_info "================ 证书申请 ================"
    msg_info "开始为 $domain 申请 TLS 证书"
    msg_info ">>> 尝试第一阶段：Standalone 模式 (自动验证)"
    
    local standalone_success=false
    if check_port_usage 80; then
        ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --force
        if [ $? -eq 0 ]; then standalone_success=true; fi
    else msg_warn "检测到 80 端口被占用，跳过 Standalone 模式。"; fi
    
    if [ "$standalone_success" = false ]; then
        echo ""; msg_error "Standalone 模式申请失败 (可能是 NAT 环境导致 80 端口不可达)。"
        msg_info ">>> 触发第二阶段：Cloudflare API (DNS-01) 模式"
        reading "是否启用 Cloudflare API 继续申请证书？(y/n，默认 y): " use_dns
        [ -z "$use_dns" ] && use_dns="y"
        
        if [[ "$use_dns" != "y" ]]; then msg_error "已取消证书申请。"; return 1; fi
        
        echo ""; msg_warn "请登录 Cloudflare 获取以下凭据："
        reading "1. 请输入 Cloudflare API Token: " cf_token
        while [ -z "$cf_token" ]; do reading "Token 不能为空，请重新输入: " cf_token; done
        
        reading "2. 请输入域名的 区域 ID (Zone ID): " cf_zone_id
        while [ -z "$cf_zone_id" ]; do reading "区域 ID 不能为空，请重新输入: " cf_zone_id; done
        
        export CF_Token="$cf_token"
        export CF_Zone_ID="$cf_zone_id"
        
        msg_info "正在通过 Cloudflare DNS API 申请证书，这可能需要 1-2 分钟..."
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" -k ec-256 --force
        
        if [ $? -ne 0 ]; then
            echo ""; msg_error "证书申请彻底失败！请检查 API 权限及 区域 ID 是否正确。"; return 1
        fi
    fi
    
    msg_info "正在安装证书到 Sing-box 环境..."
    mkdir -p "${SB_DIR}"
    ~/.acme.sh/acme.sh --installcert -d "$domain" --fullchain-file "${SB_DIR}/server.crt" --key-file "${SB_DIR}/server.key" --ecc >/dev/null 2>&1
    msg_success "真实域名证书申请并部署成功！"
    return 0
}

# --- 核心组件部署 ---
install_singbox() {
    if [ ! -f "$SB_BIN" ]; then
        msg_info "正在下载部署 Sing-box 核心大脑..."
        ARCH=$(uname -m); case "${ARCH}" in x86_64) S_ARCH="amd64" ;; aarch64|arm64) S_ARCH="arm64" ;; *) msg_error "不支持的架构"; exit 1 ;; esac
        TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r .tag_name)
        
        if safe_download "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${S_ARCH}.tar.gz" "sb.tar.gz"; then
            tar -xzf sb.tar.gz || { msg_error "解压失败"; rm -f sb.tar.gz; exit 1; }
            mv sing-box-*/sing-box "$SB_BIN"; rm -rf sb.tar.gz sing-box-*
            chmod +x "$SB_BIN"
        else
            msg_error "Sing-box 核心获取失败，请检查网络！"
            exit 1
        fi
    fi
}

install_argo() {
    if [ ! -f "$ARGO_BIN" ]; then
        msg_info "正在下载部署 Cloudflared (Argo) 隧道组件..."
        ARCH=$(uname -m); case "${ARCH}" in x86_64) A_ARCH="amd64" ;; aarch64|arm64) A_ARCH="arm64" ;; esac
        if safe_download "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${A_ARCH}" "$ARGO_BIN"; then
            chmod +x "$ARGO_BIN"
        else
            msg_error "Argo 核心获取失败，跳过安装！"
        fi
    fi
}

install_warp() {
    if ! command -v warp-cli >/dev/null 2>&1; then
        msg_info "正在安装 Cloudflare WARP 官方客户端..."
        curl -fsSl https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        echo "deb [arch=${DPKG_ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
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
    
    # 根据 VD_MODE 决定是否生成自签证书
    if [[ "$VD_MODE" != "3" ]] && [[ ! -f "${SB_DIR}/server.crt" ]]; then
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "${SB_DIR}/server.key" -out "${SB_DIR}/server.crt" -subj "/CN=bing.com" -days 3650 >/dev/null 2>&1
    fi

    # 动态构建 VLESS Inbound
    local vless_inbound
    if [ "$VD_MODE" == "1" ]; then
        vless_inbound='{ "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": '$PORT_VD', "users": [ { "uuid": "'$UUID'", "flow": "" } ], "transport": { "type": "ws", "path": "/ws" } }'
    elif [ "$VD_MODE" == "3" ] && [ -n "$VD_DOMAIN" ]; then
        vless_inbound='{ "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": '$PORT_VD', "users": [ { "uuid": "'$UUID'", "flow": "" } ], "tls": { "enabled": true, "server_name": "'$VD_DOMAIN'", "certificate_path": "'${SB_DIR}'/server.crt", "key_path": "'${SB_DIR}'/server.key" }, "transport": { "type": "ws", "path": "/ws" } }'
    else
        vless_inbound='{ "type": "vless", "tag": "in-vless", "listen": "::", "listen_port": '$PORT_VD', "users": [ { "uuid": "'$UUID'", "flow": "" } ], "tls": { "enabled": true, "certificate_path": "'${SB_DIR}'/server.crt", "key_path": "'${SB_DIR}'/server.key" }, "transport": { "type": "ws", "path": "/ws" } }'
    fi

    # 构建 WARP 路由规则
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

    # 核心：修复无意义 direct 路由冲突的精简 DNS 引擎
    cat > "$SB_CONF" << EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": {
    "servers": [
      { "tag": "dns-remote", "type": "udp", "server": "1.1.1.1" }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [
    $vless_inbound,
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
    print_logo
    echo -e "${YELLOW}▶ 开始极速一键部署流程...${NC}\n"
    if [ -f "$SB_INFO" ]; then
        msg_warn "检测到系统已部署过节点！"
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
    VD_MODE="2"; VD_DOMAIN=""

    echo ""
    msg_info "正在生成底层架构配置并拉起系统服务..."
    generate_config; setup_services
    echo ""
    msg_success "部署大功告成！全协议矩阵已在后台运行。"
    sleep 2
}

manage_protocols() {
    [ ! -f "$SB_INFO" ] && msg_error "请先进行一键部署！" && sleep 1 && return
    load_config
    while true; do
        print_logo
        echo -e "${CYAN}╭━━━ ⚙️ 独立协议参数管理 ━━━━━━━━━━━━╮${NC}"
        echo -e "${CYAN}┃${NC}  [1] ⚡ 修改 VLESS     ${YELLOW}(端口: $PORT_VD)${NC}"
        echo -e "${CYAN}┃${NC}  [2] 🚀 修改 Hy2       ${YELLOW}(端口: $PORT_HY)${NC}"
        echo -e "${CYAN}┃${NC}  [3] 🏎️  修改 TUIC v5  ${YELLOW}(端口: $PORT_TC)${NC}"
        echo -e "${CYAN}┃${NC}  [4] 🛡️  修改 SOCKS5   ${YELLOW}(端口: $PORT_S5)${NC}"
        echo -e "${CYAN}┃${NC}  [5] ☁️  配置 Argo 隧道 ${YELLOW}(模式: $ARGO_MODE)${NC}"
        echo -e "${CYAN}┃${NC}  [0] ↩️  返回主菜单"
        echo -e "${CYAN}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}"
        reading "请选择操作 [0-5]: " choice
        case $choice in
            1) 
                reading "➤ 新 VLESS 端口 (回车不变): " p; [ -n "$p" ] && PORT_VD=$p
                reading "➤ 新 UUID (回车不变): " u; [ -n "$u" ] && UUID=$u
                echo -e "\n  ${YELLOW}请选择 VLESS 模式：${NC}"
                echo -e "  [1] 关闭 TLS (纯普通直连)"
                echo -e "  [2] 开启 TLS (自签伪装证书)"
                echo -e "  [3] 开启 TLS (申请真实域名证书)"
                reading "➤ 模式选择 [1-3]: " vm
                if [ "$vm" == "3" ]; then
                    reading "➤ 请输入已解析到此VPS的真实域名: " vd
                    if [ -n "$vd" ]; then
                        apply_cert "$vd"
                        if [ $? -eq 0 ]; then
                            VD_MODE="3"; VD_DOMAIN="$vd"
                        else
                            msg_error "证书获取失败，放弃修改模式。"
                        fi
                    else
                        msg_warn "域名为空，操作取消。"
                    fi
                elif [[ "$vm" == "1" || "$vm" == "2" ]]; then
                    VD_MODE=$vm; VD_DOMAIN=""
                fi
                ;;
            2) reading "➤ 新 Hy2 端口 (回车不变): " p; [ -n "$p" ] && PORT_HY=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && PW_HY=$pw ;;
            3) reading "➤ 新 TUIC 端口 (回车不变): " p; [ -n "$p" ] && PORT_TC=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && PW_TC=$pw ;;
            4) reading "➤ 新 Socks5 端口 (回车不变): " p; [ -n "$p" ] && PORT_S5=$p; reading "➤ 新密码 (回车不变): " pw; [ -n "$pw" ] && S5_P=$pw ;;
            5)
                reading "➤ [1]=临时隧道(随机域名)  [2]=固定隧道: " am
                if [ "$am" == "2" ]; then
                    ARGO_MODE="fixed"
                    while true; do
                        reading "➤ 请输入绑定的固定域名 (如 v.domain.com): " d
                        if [ -n "$d" ]; then ARGO_DOMAIN=$d; break; else msg_error "域名不能为空！"; fi
                    done
                    while true; do
                        reading "➤ 请输入 Cloudflare Token: " t
                        if [ ${#t} -gt 50 ]; then ARGO_TOKEN=$t; break; else msg_error "Token 过短，请检查复制是否完整！"; fi
                    done
                else
                    ARGO_MODE="temp"; ARGO_TOKEN=""; ARGO_DOMAIN=""
                fi
                ;;
            0) break ;;
            *) continue ;;
        esac
        generate_config; setup_services
        msg_success "配置已更新并实现热重载！"; sleep 1
    done
}

manage_warp() {
    [ ! -f "$SB_INFO" ] && msg_error "请先进行一键部署！" && sleep 1 && return
    load_config
    while true; do
        print_logo
        local mode_str="原生直连"
        [ "$WARP_MODE" == "2" ] && mode_str="全局 WARP"
        [ "$WARP_MODE" == "3" ] && mode_str="路由分流"
        
        echo -e "${PURPLE}╭━━━ 🌐 WARP 智能分流大脑 ━━━━━━━━━━╮${NC}"
        echo -e "${PURPLE}┃${NC} 当前模式: ${GREEN}$mode_str${NC}"
        [ "$WARP_MODE" == "3" ] && echo -e "${PURPLE}┃${NC} 分流名单: ${YELLOW}${WARP_DOMAINS:-无}${NC}"
        echo -e "${PURPLE}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
        echo -e "${PURPLE}┃${NC}  [1] 🔄 切换 WARP 工作模式"
        echo -e "${PURPLE}┃${NC}  [2] ➕ 追加目标分流域名"
        echo -e "${PURPLE}┃${NC}  [3] ➖ 移除指定分流域名"
        echo -e "${PURPLE}┃${NC}  [4] 🗑️  清空所有分流名单"
        echo -e "${PURPLE}┃${NC}  [0] ↩️  返回主菜单"
        echo -e "${PURPLE}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}"
        
        reading "请选择操作 [0-4]: " choice
        case $choice in
            1)
                echo -e "  ➤ [1]=关闭  [2]=全局WARP  [3]=指定分流"
                reading "➤ 选择模式: " wm; [ -n "$wm" ] && WARP_MODE=$wm
                [[ "$WARP_MODE" == "2" || "$WARP_MODE" == "3" ]] && install_warp
                ;;
            2)
                reading "➤ 输入要追加的域名 (如 netflix.com): " nd
                if [ -n "$nd" ]; then
                    if [ -z "$WARP_DOMAINS" ]; then WARP_DOMAINS="$nd"
                    else WARP_DOMAINS="$WARP_DOMAINS,$nd"; fi
                fi
                ;;
            3)
                if [ -z "$WARP_DOMAINS" ]; then msg_warn "当前没有可删除的域名！"; sleep 1; continue; fi
                reading "➤ 输入要移除的域名 (如 ip.sb): " rm_d
                if [ -n "$rm_d" ]; then
                    IFS=',' read -ra DOMAINS <<< "$WARP_DOMAINS"
                    local new_arr=""
                    for d in "${DOMAINS[@]}"; do
                        if [ "$d" != "$rm_d" ] && [ -n "$d" ]; then new_arr+="$d,"; fi
                    done
                    WARP_DOMAINS=${new_arr%,}
                    msg_success "分流名单已更新！"
                fi
                ;;
            4) WARP_DOMAINS="" ;;
            0) break ;;
        esac
        generate_config; systemctl restart sing-box
        msg_success "WARP 路由规则已热更新！"; sleep 1
    done
}

show_nodes() {
    print_logo; [ ! -f "$SB_INFO" ] && msg_error "请先部署节点！" && sleep 1 && return
    load_config
    
    msg_info "正在探测网络环境出口..."
    out_ip=$(get_outbound_ip)
    
    if [ -z "$CUSTOM_IP" ]; then
        echo -e "${YELLOW}检测出站IP为: ${GREEN}$out_ip${NC}"
        reading "➤ 若需指定入站IP/域名请在此输入 (一致请直接回车): " in_ip
        [ -n "$in_ip" ] && CUSTOM_IP=$in_ip || CUSTOM_IP=$out_ip
        save_config
    fi

    local ip=$CUSTOM_IP
    [[ "$ip" =~ .*:.* ]] && ip="[${ip}]" 

    echo -e "\n${CYAN}╭━━━━━━━━━━━━ 🔗 节点信息汇总 ━━━━━━━━━━━━╮${NC}"
    local all_links=""
    
    # 1. VLESS (根据不同模式生成订阅)
    if [ "$VD_MODE" == "1" ]; then
        echo -e "${CYAN}┃${NC} ⚡ ${GREEN}[1. VLESS + WS]${NC} (关闭 TLS 纯直连)"
        link1="vless://${UUID}@${ip}:${PORT_VD}?encryption=none&security=none&type=ws&path=%2Fws#SB-VLESS-NoTLS"
    elif [ "$VD_MODE" == "3" ] && [ -n "$VD_DOMAIN" ]; then
        echo -e "${CYAN}┃${NC} ⚡ ${GREEN}[1. VLESS + WS + TLS]${NC} (真实证书: ${VD_DOMAIN})"
        link1="vless://${UUID}@${VD_DOMAIN}:${PORT_VD}?encryption=none&security=tls&sni=${VD_DOMAIN}&type=ws&host=${VD_DOMAIN}&path=%2Fws#SB-VLESS-TLS"
    else
        echo -e "${CYAN}┃${NC} ⚡ ${GREEN}[1. VLESS + WS + TLS]${NC} (自签伪装证书)"
        link1="vless://${UUID}@${ip}:${PORT_VD}?encryption=none&security=tls&sni=bing.com&alpn=http%2F1.1&type=ws&host=bing.com&path=%2Fws&allowInsecure=1#SB-VLESS-FakeTLS"
    fi
    echo -e "${CYAN}┃${NC}    ${link1}"
    all_links+="$link1\n"
    
    # 2. Argo
    local argo_domain=""
    if [ "$ARGO_MODE" == "temp" ]; then
        for i in {1..5}; do
            argo_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "$ARGO_LOG" | head -n 1 | sed 's/https:\/\///')
            [ -n "$argo_domain" ] && break; sleep 1
        done
        [ -n "$argo_domain" ] && argo_type="临时随机隧道"
    elif [ "$ARGO_MODE" == "fixed" ]; then
        argo_domain="$ARGO_DOMAIN"; argo_type="固定专线隧道"
    fi
    
    echo -e "${CYAN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    echo -e "${CYAN}┃${NC} ☁️  ${GREEN}[2. VLESS + Argo]${NC} (${argo_type:-未就绪})"
    if [ -n "$argo_domain" ]; then
        link2="vless://${UUID}@www.visa.com.sg:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2Fargo#SB-Argo"
        echo -e "${CYAN}┃${NC}    ${link2}"
        all_links+="$link2\n"
    else 
        echo -e "${CYAN}┃${NC}    ${RED}(未能成功获取隧道域名，请检查日志)${NC}"
    fi

    # 3. Hysteria 2
    echo -e "${CYAN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    echo -e "${CYAN}┃${NC} 🚀 ${GREEN}[3. Hysteria 2]${NC} (暴力加速)"
    link3="hysteria2://${PW_HY}@${ip}:${PORT_HY}?insecure=1&sni=bing.com#SB-Hy2"
    echo -e "${CYAN}┃${NC}    ${link3}"
    all_links+="$link3\n"
    
    # 4. TUIC v5
    echo -e "${CYAN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    echo -e "${CYAN}┃${NC} 🏎️  ${GREEN}[4. TUIC v5]${NC} (QUIC 协议)"
    link4="tuic://${UUID}:${PW_TC}@${ip}:${PORT_TC}?sni=bing.com&alpn=h3&congestion_control=bbr&allow_insecure=1#SB-TUIC"
    echo -e "${CYAN}┃${NC}    ${link4}"
    all_links+="$link4\n"
    
    # 5. SOCKS5
    echo -e "${CYAN}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    echo -e "${CYAN}┃${NC} 🛡️  ${GREEN}[5. SOCKS5]${NC} (基础代理)"
    b64_cred=$(echo -n "${S5_U}:${S5_P}" | base64 | tr -d '\n')
    link5="socks://${b64_cred}@${ip}:${PORT_S5}#SB-Socks5"
    echo -e "${CYAN}┃${NC}    ${link5}"
    all_links+="$link5\n"
    echo -e "${CYAN}╰━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╯${NC}"

    echo -e "\n${YELLOW}📦 Base64 通用订阅码 (请一键复制以下内容):${NC}"
    echo -e "$all_links" | sed '/^$/d' | base64 | tr -d '\n'
    
    echo -e "\n"
    reading "按回车键 (Enter) 返回主菜单..." dummy
}

uninstall_script() {
    print_logo; msg_error "!!! 危险操作: 准备物理超度所有服务 !!!"
    reading "➤ 确定要彻底清空本脚本、核心引擎及所有配置吗? (y/n): " c
    [[ "$c" != "y" ]] && return

    msg_info "正在屠宰后台进程与残留文件..."
    systemctl stop sing-box sb-argo >/dev/null 2>&1
    systemctl disable sing-box sb-argo >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb-argo.service
    
    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli disconnect >/dev/null 2>&1
        apt-get remove -y cloudflare-warp >/dev/null 2>&1
    fi

    rm -rf "$SB_DIR" "$SB_BIN" "$ARGO_BIN" "/usr/bin/sb"
    systemctl daemon-reload
    msg_success "系统已恢复纯净状态。江湖再见！"; rm -f "$0"; exit 0
}

main_menu() {
    while true; do
        print_logo
        local status="${RED}未安装 (休眠中)${NC}"
        [ -f "$SB_INFO" ] && status="${GREEN}已安装 (运行中)${NC}"
        
        echo -e "   系统状态: $status"
        echo -e "   ─────────────────────────────────────────"
        echo -e "   ${GREEN}[1]${NC} 🚀 一键部署 / 重置安装引擎"
        echo -e "   ${GREEN}[2]${NC} ⚙️  单独协议配置管理 (端口/密码/证书)"
        echo -e "   ${GREEN}[3]${NC} 🌐 调教 WARP 智能分流规则"
        echo -e "   ${GREEN}[4]${NC} 🔗 查看提取节点订阅链接"
        echo -e "   ─────────────────────────────────────────"
        echo -e "   ${RED}[9]${NC} 🗑️  彻底超度 (卸载脚本与服务)"
        echo -e "   ${RED}[0]${NC} 🚪 安全退出面板"
        echo ""
        reading "请输入指令代码: " choice
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

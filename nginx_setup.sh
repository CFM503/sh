#!/bin/bash

#====================================================
# Nginx 管理与反向代理配置脚本
# 版本: 1.6.1
# 功能: 自动安装/卸载Nginx、安全配置反向代理(WebSocket)、
#       查看状态、删除代理、一键修复/恢复出厂默认配置、
#       网站首页模板与伪装(小游戏/个人博客/隐形跳转)
# 适配: Debian / Ubuntu / CentOS / RHEL / Fedora / Arch / Alpine
#====================================================

SCRIPT_VERSION="1.6.1"
VERSION="1.6.1"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# 全局变量
OS=""
OS_VERSION=""
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
PKG_REMOVE=""
PKG_PURGE=""
CONF_STYLE=""       # "sites" 或 "confd"
PROXY_CONF_DIR=""
ENABLED_CONF_DIR=""
MAIN_CONF="/etc/nginx/nginx.conf"

#====================================================
# 系统环境与依赖检测
#====================================================

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 root 权限运行此脚本${NC}"
        echo -e "请使用: ${GREEN}sudo bash $0${NC}"
        exit 1
    fi
}

# 检测系统版本
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        OS_VERSION=$(cat /etc/debian_version)
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
        OS_VERSION=$(cat /etc/redhat-release)
    else
        OS="unknown"
        OS_VERSION="unknown"
    fi
}

# 检测包管理器
detect_package_manager() {
    detect_os
    
    if command -v apt &> /dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt install -y"
        PKG_UPDATE="apt update -y"
        PKG_REMOVE="apt remove -y"
        PKG_PURGE="apt purge -y"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache"
        PKG_REMOVE="dnf remove -y"
        PKG_PURGE="dnf remove -y"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
        PKG_REMOVE="yum remove -y"
        PKG_PURGE="yum remove -y"
    elif command -v pacman &> /dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
        PKG_REMOVE="pacman -R --noconfirm"
        PKG_PURGE="pacman -Rns --noconfirm"
    elif command -v apk &> /dev/null; then
        PKG_MGR="apk"
        PKG_INSTALL="apk add"
        PKG_UPDATE="apk update"
        PKG_REMOVE="apk del"
        PKG_PURGE="apk del"
    elif command -v zypper &> /dev/null; then
        PKG_MGR="zypper"
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
        PKG_REMOVE="zypper remove -y"
        PKG_PURGE="zypper remove -y --clean-deps"
    else
        PKG_MGR="unknown"
    fi
}

# 检测 Nginx 配置目录结构
detect_nginx_dirs() {
    mkdir -p /etc/nginx/conf.d 2>/dev/null
    
    if [ -d "/etc/nginx/sites-available" ] && [ -d "/etc/nginx/sites-enabled" ]; then
        CONF_STYLE="sites"
        PROXY_CONF_DIR="/etc/nginx/sites-available"
        ENABLED_CONF_DIR="/etc/nginx/sites-enabled"
    else
        CONF_STYLE="confd"
        PROXY_CONF_DIR="/etc/nginx/conf.d"
        ENABLED_CONF_DIR="/etc/nginx/conf.d"
    fi
}

# 自动清理历史残留的损坏/乱码配置文件与死链接
clean_corrupted_configs() {
    for dir in /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d; do
        if [ -d "$dir" ]; then
            for f in "$dir"/proxy_*.conf; do
                if [ -e "$f" ] || [ -L "$f" ]; then
                    # 1. 清理死链接
                    if [ -L "$f" ] && [ ! -e "$f" ]; then
                        rm -f "$f" 2>/dev/null
                        continue
                    fi
                    # 2. 清理文件名包含非法/乱码字符的文件
                    local base_name
                    base_name=$(basename "$f")
                    if [[ "$base_name" =~ [^a-zA-Z0-9_\.\-] ]]; then
                        rm -f "$f" 2>/dev/null
                        continue
                    fi
                    # 3. 清理包含二进制/非UTF-8损坏字节的文件
                    if [ -f "$f" ] && ! grep -I -q . "$f" 2>/dev/null; then
                        rm -f "$f" 2>/dev/null
                        continue
                    fi
                fi
            done
        fi
    done
}

# 初始化环境
init_env() {
    detect_package_manager
    detect_nginx_dirs
    clean_corrupted_configs
}

# 确保 Nginx 已安装
ensure_nginx_installed() {
    if command -v nginx &> /dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}Nginx 未安装，正在自动安装...${NC}"
    install_nginx
    return $?
}

# 确保 WebSocket 升级映射配置存在（避免破坏 HTTP 与 WebSocket 兼容性）
ensure_websocket_map() {
    local map_conf="/etc/nginx/conf.d/00_websocket_map.conf"
    if [ ! -f "$map_conf" ]; then
        mkdir -p /etc/nginx/conf.d 2>/dev/null
        cat > "$map_conf" << 'EOF'
# 全局 WebSocket Upgrade Header 映射配置
# 由 Nginx 自动化脚本生成
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF
    fi
}

#====================================================
# Nginx 服务安装与卸载
#====================================================

# 安装 Nginx
install_nginx() {
    echo -e "${YELLOW}正在准备安装 Nginx...${NC}"
    init_env
    
    if command -v nginx &> /dev/null; then
        echo -e "${GREEN}✓ Nginx 已安装:${NC}"
        nginx -v
        return 0
    fi
    
    if [ "$PKG_MGR" = "unknown" ]; then
        echo -e "${RED}错误: 未检测到支持的包管理器，请手动安装 Nginx${NC}"
        return 1
    fi
    
    echo -e "${BLUE}系统: $OS $OS_VERSION | 包管理器: $PKG_MGR${NC}"
    echo -e "${YELLOW}更新软件包索引...${NC}"
    $PKG_UPDATE
    
    # 部分 CentOS/RHEL 需要 EPEL 源
    if [ "$PKG_MGR" = "yum" ] || [ "$PKG_MGR" = "dnf" ]; then
        if ! $PKG_INSTALL nginx 2>/dev/null; then
            echo -e "${YELLOW}尝试安装 epel-release 后重试...${NC}"
            $PKG_INSTALL epel-release
            $PKG_UPDATE
            $PKG_INSTALL nginx
        fi
    else
        $PKG_INSTALL nginx
    fi
    
    if command -v nginx &> /dev/null; then
        echo -e "${GREEN}✓ Nginx 安装成功!${NC}"
        nginx -v
        ensure_websocket_map
        start_service
        return 0
    else
        echo -e "${RED}✗ Nginx 安装失败，请检查网络或软件源配置${NC}"
        return 1
    fi
}

# 卸载 Nginx
uninstall_nginx() {
    init_env
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}           警告: 即将卸载 Nginx!${NC}"
    echo -e "${RED}========================================${NC}"
    echo -e "1. 仅卸载 Nginx 程序 (保留配置文件与日志)"
    echo -e "2. 完全卸载 Nginx 并彻底清除残留 (Purge 推荐)"
    echo -e "0. 取消"
    echo -e "${RED}========================================${NC}"
    echo -n "请选择卸载方式 [0-2]: "
    read -r un_choice
    
    case "$un_choice" in
        1)
            echo -e "${YELLOW}停止并禁用 Nginx 服务...${NC}"
            stop_service 2>/dev/null
            if command -v systemctl &> /dev/null; then
                systemctl disable nginx 2>/dev/null
                systemctl reset-failed nginx 2>/dev/null
            fi
            killall -9 nginx 2>/dev/null || pkill -9 nginx 2>/dev/null
            echo -e "${YELLOW}正在卸载 Nginx 主程序...${NC}"
            $PKG_REMOVE nginx
            echo -e "${GREEN}✓ Nginx 程序已卸载 (配置文件已完整保留在 /etc/nginx/)${NC}"
            ;;
        2)
            echo -e "${RED}确认彻底清除所有 Nginx 程序、配置、模块与缓存日志? (y/N): ${NC}"
            read -r confirm_purge
            if [ "$confirm_purge" = "y" ] || [ "$confirm_purge" = "Y" ]; then
                echo -e "${YELLOW}正在停止并清理 Nginx 进程...${NC}"
                stop_service 2>/dev/null
                if command -v systemctl &> /dev/null; then
                    systemctl disable nginx 2>/dev/null
                fi
                killall -9 nginx 2>/dev/null || pkill -9 nginx 2>/dev/null
                
                # 自动安全备份
                local purge_bak="/root/nginx_backup_before_purge_$(date +%Y%m%d_%H%M%S)"
                if [ -d "/etc/nginx" ]; then
                    echo -e "${BLUE}安全备份原配置到: ${purge_bak}...${NC}"
                    mkdir -p "$purge_bak"
                    cp -r /etc/nginx "$purge_bak/" 2>/dev/null
                    echo -e "${GREEN}✓ 备份完成${NC}"
                fi
                
                echo -e "${YELLOW}通过包管理器深度清除 Nginx 及其依赖模块...${NC}"
                if [ "$PKG_MGR" = "apt" ]; then
                    apt-get purge -y nginx nginx-common nginx-core nginx-full "libnginx-mod-*" 2>/dev/null || $PKG_PURGE nginx nginx-common nginx-core
                    apt-get autoremove --purge -y 2>/dev/null
                elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
                    if command -v dnf &>/dev/null; then
                        dnf remove -y nginx nginx-filesystem nginx-core 2>/dev/null || dnf remove -y nginx
                        dnf autoremove -y 2>/dev/null
                    else
                        yum remove -y nginx nginx-filesystem 2>/dev/null || yum remove -y nginx
                    fi
                elif [ "$PKG_MGR" = "pacman" ]; then
                    pacman -Rns --noconfirm nginx 2>/dev/null
                elif [ "$PKG_MGR" = "apk" ]; then
                    apk del nginx 2>/dev/null
                else
                    $PKG_REMOVE nginx 2>/dev/null
                fi
                
                echo -e "${YELLOW}清理残留配置目录、日志与缓存文件...${NC}"
                rm -rf /etc/nginx 2>/dev/null
                rm -rf /var/log/nginx 2>/dev/null
                rm -rf /var/cache/nginx 2>/dev/null
                rm -rf /usr/share/nginx 2>/dev/null
                rm -rf /run/nginx.pid 2>/dev/null
                
                # 刷新 systemd 状态
                if command -v systemctl &> /dev/null; then
                    systemctl daemon-reload 2>/dev/null
                    systemctl reset-failed 2>/dev/null
                fi
                
                echo ""
                echo -e "${GREEN}======================================================${NC}"
                echo -e "${GREEN}  ✓ Nginx 已完全卸载，所有残留文件与系统服务已清理干净!${NC}"
                echo -e "${GREEN}======================================================${NC}"
                [ -d "$purge_bak" ] && echo -e "${BLUE}卸载前的历史配置备份保存在: ${purge_bak}${NC}"
            else
                echo -e "${YELLOW}已取消清除操作${NC}"
            fi
            ;;
        *)
            echo -e "${YELLOW}已取消卸载${NC}"
            ;;
    esac
}

#====================================================
# Nginx 服务生命周期控制
#====================================================

start_service() {
    echo -e "${YELLOW}正在启动 Nginx...${NC}"
    if command -v systemctl &> /dev/null; then
        systemctl enable nginx 2>/dev/null
        systemctl start nginx
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}✓ Nginx 启动成功并已设为开机自启${NC}"
            return 0
        fi
    elif command -v service &> /dev/null; then
        service nginx start
        return $?
    else
        nginx
        return $?
    fi
    echo -e "${RED}✗ Nginx 启动失败，请使用菜单选项 6 检查配置语法${NC}"
    return 1
}

stop_service() {
    echo -e "${YELLOW}正在停止 Nginx...${NC}"
    if command -v systemctl &> /dev/null; then
        systemctl stop nginx
    elif command -v service &> /dev/null; then
        service nginx stop
    else
        nginx -s stop 2>/dev/null || killall nginx 2>/dev/null
    fi
    echo -e "${GREEN}✓ Nginx 服务已停止${NC}"
}

restart_service() {
    echo -e "${YELLOW}正在重启 Nginx...${NC}"
    if ! test_config_silent; then
        echo -e "${RED}✗ 配置存在错误，中止重启:${NC}"
        nginx -t
        return 1
    fi
    
    if command -v systemctl &> /dev/null; then
        systemctl restart nginx
    elif command -v service &> /dev/null; then
        service nginx restart
    else
        nginx -s reload 2>/dev/null || (killall nginx 2>/dev/null && nginx)
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Nginx 重启成功${NC}"
    else
        echo -e "${RED}✗ Nginx 重启失败${NC}"
    fi
}

reload_nginx() {
    echo -e "${YELLOW}正在重载 Nginx 配置...${NC}"
    if ! test_config; then
        echo -e "${RED}✗ 配置语法错误，无法重载!${NC}"
        return 1
    fi
    
    # 检查 Nginx 当前是否在运行，若未运行则直接启动
    if ! pgrep nginx &>/dev/null; then
        echo -e "${YELLOW}检测到 Nginx 服务未运行，正在启动服务...${NC}"
        start_service
        return $?
    fi
    
    if command -v systemctl &> /dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null
    elif command -v service &> /dev/null; then
        service nginx reload 2>/dev/null || service nginx restart 2>/dev/null
    else
        nginx -s reload 2>/dev/null || nginx
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Nginx 配置重载成功${NC}"
        return 0
    else
        echo -e "${YELLOW}重载失败，尝试直接重启服务...${NC}"
        restart_service
    fi
}

# 检查配置语法
test_config() {
    echo -e "${YELLOW}检查 Nginx 配置语法 (nginx -t)...${NC}"
    local output
    output=$(nginx -t 2>&1)
    local ret=$?
    echo "$output"
    if [ $ret -eq 0 ]; then
        echo -e "${GREEN}✓ Nginx 配置语法正确${NC}"
        return 0
    else
        echo -e "${RED}✗ Nginx 配置语法错误${NC}"
        return 1
    fi
}

test_config_silent() {
    nginx -t &> /dev/null
    return $?
}

# 获取公网 IP (用于生成可直接访问的测试 URL)
get_public_ip() {
    local ip
    ip=$(curl -s -m 2 http://ip.sb 2>/dev/null || curl -s -m 2 https://api.ipify.org 2>/dev/null || curl -s -m 2 http://ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip="127.0.0.1"
    echo "$ip"
}

# 验证单个反向代理规则并输出直观的成功/失败连通性检测报告
verify_proxy_rule() {
    local listen_port="${1:-80}"
    local proxy_path="${2:-/}"
    local upstream_host="${3:-127.0.0.1}"
    local upstream_port="$4"
    local server_name="${5:-_}"
    
    [[ "$proxy_path" != /* ]] && proxy_path="/$proxy_path"
    local pub_ip
    pub_ip=$(get_public_ip)
    
    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}             反向代理设置与连通性检测报告${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    # 1. 检测 Nginx 自身是否在运行并监听端口
    local nginx_listen="no"
    if ss -tulpn 2>/dev/null | grep ":${listen_port}[[:space:]]" | grep -q "nginx"; then
        nginx_listen="yes"
    elif pgrep nginx &>/dev/null && [ "$listen_port" = "80" ]; then
        nginx_listen="yes"
    fi
    
    # 2. 检测后端目标程序端口监听状态
    local backend_listen="no"
    local backend_proc=""
    if [ "$upstream_host" = "127.0.0.1" ] || [ "$upstream_host" = "localhost" ]; then
        if command -v ss &>/dev/null; then
            local ss_out
            ss_out=$(ss -tulpn 2>/dev/null | grep ":${upstream_port} ")
            if [ -n "$ss_out" ]; then
                backend_listen="yes"
                backend_proc=$(echo "$ss_out" | awk -F'users:' '{print $2}' | tr -d '()' | xargs)
            fi
        fi
    fi
    
    # 3. 本地发包模拟 HTTP 探测
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "http://127.0.0.1:${listen_port}${proxy_path}" 2>/dev/null)
    
    echo -e " [1] 配置语法测试:   ${GREEN}✓ 语法检测通过，已成功加载${NC}"
    
    if [ "$nginx_listen" = "yes" ]; then
        echo -e " [2] Nginx 监听端口: ${GREEN}● 端口 ${listen_port} 正常监听${NC}"
    else
        echo -e " [2] Nginx 监听端口: ${RED}○ 端口 ${listen_port} 未检测到监听${NC}"
    fi
    
    if [ "$backend_listen" = "yes" ]; then
        echo -e " [3] 后端服务状态:   ${GREEN}● 目标 ${upstream_host}:${upstream_port} 正常运行${NC} ${CYAN}(${backend_proc})${NC}"
    elif [ "$upstream_host" = "127.0.0.1" ] || [ "$upstream_host" = "localhost" ]; then
        echo -e " [3] 后端服务状态:   ${YELLOW}○ 端口 ${upstream_port} 暂无进程监听 (请确保后端程序已启动)${NC}"
    else
        echo -e " [3] 后端服务状态:   ${BLUE}○ 远程目标主机: ${upstream_host}:${upstream_port}${NC}"
    fi
    
    if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
        if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ] || [ "$http_code" = "400" ] || [ "$http_code" = "404" ]; then
            echo -e " [4] HTTP 探测响应:  ${GREEN}✓ HTTP 状态码 ${http_code} (反代链路正常打通)${NC}"
        elif [ "$http_code" = "502" ] || [ "$http_code" = "504" ]; then
            echo -e " [4] HTTP 探测响应:  ${YELLOW}▲ HTTP 状态码 ${http_code} (Nginx正常，但后端未开启或无响应)${NC}"
        else
            echo -e " [4] HTTP 探测响应:  ${BLUE}HTTP 状态码 ${http_code}${NC}"
        fi
    else
        echo -e " [4] HTTP 探测响应:  ${YELLOW}○ 暂无 HTTP 响应 (连接超时或未响应)${NC}"
    fi
    
    local show_url="http://${pub_ip}"
    [ "$listen_port" != "80" ] && show_url="${show_url}:${listen_port}"
    show_url="${show_url}${proxy_path}"
    
    echo -e " [5] 外部访问测试URL: ${GREEN}${show_url}${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    if [ "$nginx_listen" = "yes" ] && ([ "$backend_listen" = "yes" ] || [ "$upstream_host" != "127.0.0.1" ]); then
        echo -e "${GREEN}  ✓ 反向代理设置【成功生效】！${NC}"
    elif [ "$nginx_listen" = "yes" ]; then
        echo -e "${YELLOW}  ✓ Nginx 代理配置已就绪！(待后端在端口 ${upstream_port} 启动后即可正常使用)${NC}"
    else
        echo -e "${RED}  ✗ 配置建立完成但 Nginx 服务未运行，请检查服务状态${NC}"
    fi
    echo -e "${CYAN}======================================================${NC}"
    echo ""
}

#====================================================
# 反向代理配置管理 (模块化设计，永不破坏原有默认配置)
#====================================================

# 查找默认站点配置文件
find_default_server_conf() {
    detect_nginx_dirs
    if [ "$CONF_STYLE" = "sites" ]; then
        if [ -f "/etc/nginx/sites-available/default" ]; then
            echo "/etc/nginx/sites-available/default"
            return 0
        fi
        local first_conf
        first_conf=$(ls /etc/nginx/sites-available/*.conf 2>/dev/null | head -1)
        if [ -n "$first_conf" ] && [ -f "$first_conf" ]; then
            echo "$first_conf"
            return 0
        fi
    fi
    
    if [ -f "/etc/nginx/conf.d/default.conf" ]; then
        echo "/etc/nginx/conf.d/default.conf"
        return 0
    fi
    
    return 1
}

# 模式 1: 创建独立站点反向代理配置文件 (最推荐，完全隔离安全)
create_standalone_proxy() {
    local proxy_name="$1"
    local listen_port="$2"
    local server_name="$3"
    local proxy_path="$4"
    local upstream_host="$5"
    local upstream_port="$6"
    local enable_ws="$7"
    
    init_env
    ensure_websocket_map
    
    local conf_file="${PROXY_CONF_DIR}/proxy_${proxy_name}.conf"
    local tmp_file=$(mktemp)
    
    # 处理路径斜杠
    [[ "$proxy_path" != /* ]] && proxy_path="/$proxy_path"
    
    cat > "$tmp_file" << EOF
#====================================================
# 独立反向代理站点配置
# 标识: proxy_${proxy_name}
# 创建时间: $(date '+%Y-%m-%d %H:%M:%S')
#====================================================

server {
    listen ${listen_port};
    server_name ${server_name};

    # 客户端上传与缓冲区优化
    client_max_body_size 100m;
    client_body_buffer_size 128k;

    location ${proxy_path} {
        proxy_pass http://${upstream_host}:${upstream_port};
        proxy_redirect off;
        proxy_http_version 1.1;
        
        # 请求头转发
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # 超时时间 (长连接支持)
        proxy_connect_timeout 60s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;

        # 禁用缓冲保证实时性
        proxy_buffering off;
        proxy_cache off;
    }
}
EOF

    # 移动到目标目录
    cp "$tmp_file" "$conf_file"
    rm -f "$tmp_file"
    
    # 如果是 Debian/Ubuntu sites 模式，建立软链接
    if [ "$CONF_STYLE" = "sites" ]; then
        ln -sf "$conf_file" "${ENABLED_CONF_DIR}/proxy_${proxy_name}.conf"
    fi
    
    # 语法测试
    if test_config_silent; then
        echo -e "${GREEN}✓ 独立代理配置创建成功: ${conf_file}${NC}"
        reload_nginx
        verify_proxy_rule "$listen_port" "$proxy_path" "$upstream_host" "$upstream_port" "$server_name"
        return 0
    else
        echo -e "${RED}✗ 新建配置导致语法错误，正在自动撤销...${NC}"
        rm -f "$conf_file"
        [ "$CONF_STYLE" = "sites" ] && rm -f "${ENABLED_CONF_DIR}/proxy_${proxy_name}.conf"
        nginx -t
        return 1
    fi
}

# 模式 2: 在现有默认站点中安全注入 location 路径反代 (带自动语法检测与瞬间回滚保护)
inject_location_to_default() {
    local proxy_path="$1"
    local upstream_host="$2"
    local upstream_port="$3"
    
    init_env
    ensure_websocket_map
    
    # 处理路径
    [[ "$proxy_path" != /* ]] && proxy_path="/$proxy_path"
    
    # 查找默认配置文件
    local def_conf
    def_conf=$(find_default_server_conf)
    
    if [ -z "$def_conf" ] || [ ! -f "$def_conf" ]; then
        echo -e "${YELLOW}未找到现有的默认站点配置文件，将自动为您创建独立默认代理站点...${NC}"
        local safe_name
        safe_name=$(echo "$proxy_path" | tr -cd 'a-zA-Z0-9_')
        [ -z "$safe_name" ] && safe_name="root"
        create_standalone_proxy "default_${safe_name}" "80" "_" "$proxy_path" "$upstream_host" "$upstream_port" "yes"
        return $?
    fi
    
    echo -e "${BLUE}目标默认配置文件: ${def_conf}${NC}"
    
    # 检查是否已存在相同的 location 块
    if grep -q "location[[:space:]]*${proxy_path}[[:space:]]*{" "$def_conf" 2>/dev/null; then
        echo -e "${YELLOW}检测到 ${def_conf} 中已存在 location ${proxy_path} 配置块${NC}"
        echo -n "是否覆盖更新此路径配置? (y/N): "
        read -r confirm_replace
        if [ "$confirm_replace" != "y" ] && [ "$confirm_replace" != "Y" ]; then
            echo -e "${YELLOW}已取消添加${NC}"
            return 0
        fi
    fi
    
    # 生成安全的备份文件
    local backup_file="${def_conf}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$def_conf" "$backup_file"
    
    # 如果已存在，先安全清理旧的 location 块 (基于标记或范围)
    local clean_tmp=$(mktemp)
    awk -v target_loc="location ${proxy_path} " -v target_loc2="location ${proxy_path}{" '
        BEGIN { skip = 0; brace_level = 0; }
        $0 ~ target_loc || $0 ~ target_loc2 || $0 ~ "# BEGIN_PROXY_" {
            if ($0 ~ target_loc || $0 ~ target_loc2) {
                skip = 1;
                brace_level = 0;
            }
        }
        skip == 1 {
            # 统计大括号
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1);
                if (c == "{") brace_level++;
                if (c == "}") brace_level--;
            }
            if (brace_level <= 0 && $0 ~ "}") {
                skip = 0;
            }
            next;
        }
        { print }
    ' "$def_conf" > "$clean_tmp"
    cp "$clean_tmp" "$def_conf"
    rm -f "$clean_tmp"
    
    # 生成 location 片段
    local snippet_tmp=$(mktemp)
    local tag_id=$(echo "$proxy_path" | tr -cd 'a-zA-Z0-9_')
    cat > "$snippet_tmp" << EOF

    # BEGIN_PROXY_${tag_id}
    # 反向代理: ${proxy_path} -> http://${upstream_host}:${upstream_port} ($(date '+%Y-%m-%d %H:%M:%S'))
    location ${proxy_path} {
        proxy_pass http://${upstream_host}:${upstream_port};
        proxy_redirect off;
        proxy_http_version 1.1;
        
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 86400s;
        proxy_read_timeout 86400s;
        proxy_buffering off;
        proxy_cache off;
    }
    # END_PROXY_${tag_id}
EOF

    # 寻找最后一个闭合的花括号行号 (即 server 块的结尾)
    local last_brace_line
    last_brace_line=$(grep -n '^[[:space:]]*}[[:space:]]*$' "$def_conf" | tail -1 | cut -d: -f1)
    if [ -z "$last_brace_line" ]; then
        last_brace_line=$(grep -n '}' "$def_conf" | tail -1 | cut -d: -f1)
    fi
    
    if [ -z "$last_brace_line" ]; then
        echo -e "${RED}错误: 无法在 ${def_conf} 中定位合法的 server 闭合花括号${NC}"
        cp "$backup_file" "$def_conf"
        rm -f "$backup_file" "$snippet_tmp"
        return 1
    fi
    
    # 借助 awk 安全注入，绝对不会破坏换行和特殊字符
    local out_tmp=$(mktemp)
    awk -v target_line="$last_brace_line" -v snippet_file="$snippet_tmp" '
        NR == target_line {
            while ((getline line < snippet_file) > 0) {
                print line
            }
            close(snippet_file)
        }
        { print }
    ' "$def_conf" > "$out_tmp"
    
    cp "$out_tmp" "$def_conf"
    rm -f "$out_tmp" "$snippet_tmp"
    
    # 验证语法并决定是否回滚
    if test_config_silent; then
        echo -e "${GREEN}✓ 路径反代配置成功注入到 ${def_conf}${NC}"
        echo -e "${BLUE}备份文件保存在: ${backup_file}${NC}"
        reload_nginx
        verify_proxy_rule "80" "$proxy_path" "$upstream_host" "$upstream_port"
        return 0
    else
        echo -e "${RED}✗ 配置注入后语法测试失败，正在启动紧急安全回滚...${NC}"
        cp "$backup_file" "$def_conf"
        rm -f "$backup_file"
        echo -e "${GREEN}✓ 已成功回滚至修改前状态，原配置未受任何损坏${NC}"
        nginx -t
        return 1
    fi
}

# 交互式添加反向代理菜单
add_proxy_interactive() {
    check_root
    ensure_nginx_installed || return 1
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}         添加 Nginx 反向代理${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}1.${NC} 在默认站点添加路径反代 (如: http://IP/pyway -> 127.0.0.1:2052)"
    echo -e "${GREEN}2.${NC} 创建独立站点/域名反代 (如: http://example.com 或自定义端口)"
    echo -e "${GREEN}3.${NC} 快捷预设: /pyway -> 127.0.0.1:2052 (WebSocket)"
    echo -e "${RED}0.${NC} 返回"
    echo -e "${CYAN}========================================${NC}"
    echo -n "请选择代理模式 [0-3]: "
    read -r mode_choice
    
    case "$mode_choice" in
        1)
            echo ""
            echo -e "${YELLOW}--- 配置默认站点路径反代 ---${NC}"
            read -p "请输入访问路径 (例如 /pyway 或 /v2ray): " proxy_path
            [ -z "$proxy_path" ] && { echo -e "${RED}路径不能为空${NC}"; return 1; }
            
            read -p "请输入后端目标主机 (默认 127.0.0.1): " upstream_host
            upstream_host=${upstream_host:-127.0.0.1}
            
            read -p "请输入后端目标端口 (例如 2052): " upstream_port
            [ -z "$upstream_port" ] && { echo -e "${RED}端口不能为空${NC}"; return 1; }
            
            inject_location_to_default "$proxy_path" "$upstream_host" "$upstream_port"
            ;;
        2)
            echo ""
            echo -e "${YELLOW}--- 配置独立站点/域名反代 ---${NC}"
            read -p "请输入配置标识名称 (仅字母数字，如 myapp): " proxy_name
            proxy_name=$(echo "$proxy_name" | tr -cd 'a-zA-Z0-9_')
            [ -z "$proxy_name" ] && { echo -e "${RED}标识名称不能为空${NC}"; return 1; }
            
            read -p "请输入 Nginx 监听端口 (默认 80): " listen_port
            listen_port=${listen_port:-80}
            
            read -p "请输入绑定域名 (默认 _ 匹配所有): " server_name
            server_name=${server_name:-_}
            
            read -p "请输入匹配路径 (默认 /): " proxy_path
            proxy_path=${proxy_path:-/}
            
            read -p "请输入后端目标主机 (默认 127.0.0.1): " upstream_host
            upstream_host=${upstream_host:-127.0.0.1}
            
            read -p "请输入后端目标端口: " upstream_port
            [ -z "$upstream_port" ] && { echo -e "${RED}端口不能为空${NC}"; return 1; }
            
            create_standalone_proxy "$proxy_name" "$listen_port" "$server_name" "$proxy_path" "$upstream_host" "$upstream_port" "yes"
            ;;
        3)
            echo -e "${YELLOW}应用预设: /pyway -> 127.0.0.1:2052${NC}"
            inject_location_to_default "/pyway" "127.0.0.1" "2052"
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# 预设 pyway 快捷调用
preset_pyway() {
    check_root
    ensure_nginx_installed || return 1
    echo -e "${YELLOW}正在配置预设: /pyway -> 127.0.0.1:2052 (支持 WebSocket)${NC}"
    inject_location_to_default "/pyway" "127.0.0.1" "2052"
}

#====================================================
# 查看与删除代理配置
#====================================================

# 查看当前 Nginx 配置概览与代理规则
show_config() {
    init_env
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}       Nginx 状态与配置概览${NC}"
    echo -e "${CYAN}========================================${NC}"
    
    # 运行状态
    echo -e "${BLUE}1. 服务运行状态:${NC}"
    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "   状态: ${GREEN}● 正在运行 (Active)${NC}"
        else
            echo -e "   状态: ${RED}○ 未运行 (Inactive)${NC}"
        fi
    elif pgrep nginx &> /dev/null; then
        echo -e "   状态: ${GREEN}● 正在运行 (进程存在)${NC}"
    else
        echo -e "   状态: ${RED}○ 未运行${NC}"
    fi
    
    if command -v nginx &> /dev/null; then
        echo -n "   版本: "
        nginx -v 2>&1
    fi
    
    # 端口监听
    echo ""
    echo -e "${BLUE}2. 端口监听情况:${NC}"
    if command -v ss &> /dev/null; then
        ss -tulpn | grep nginx | awk '{printf "   %-8s %-22s (PID: %s)\n", $1, $5, $7}' 2>/dev/null
    elif command -v netstat &> /dev/null; then
        netstat -tulpn | grep nginx | awk '{printf "   %-8s %-22s\n", $1, $4}' 2>/dev/null
    fi
    
    # 独立代理配置文件
    echo ""
    echo -e "${BLUE}3. 独立代理配置文件列表:${NC}"
    local count=0
    for f in "${ENABLED_CONF_DIR}"/proxy_*.conf; do
        if [ -f "$f" ]; then
            if ! grep -I -q . "$f" 2>/dev/null; then
                continue
            fi
            count=$((count + 1))
            local l_port=$(grep -I -E '^[[:space:]]*listen' "$f" | head -1 | tr -s ' ' | xargs)
            local s_name=$(grep -I -E '^[[:space:]]*server_name' "$f" | head -1 | tr -s ' ' | xargs)
            local p_pass=$(grep -I -E '^[[:space:]]*proxy_pass' "$f" | head -1 | tr -s ' ' | xargs)
            echo -e "   ${GREEN}[$count]${NC} $f"
            [ -n "$l_port" ] && echo -e "       $l_port | $s_name"
            [ -n "$p_pass" ] && echo -e "       $p_pass"
        fi
    done
    [ $count -eq 0 ] && echo -e "   ${YELLOW}(暂无已启用的独立代理配置文件)${NC}"
    
    # 默认站点中的路径反代
    echo ""
    echo -e "${BLUE}4. 默认站点中检测到的反向代理 (proxy_pass):${NC}"
    local loc_count=0
    for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf; do
        if [ -f "$conf" ] && [[ "$conf" != *"00_websocket_map.conf"* ]]; then
            if ! grep -I -q . "$conf" 2>/dev/null; then
                continue
            fi
            local matches
            matches=$(grep -I -n -C 2 "proxy_pass" "$conf" 2>/dev/null)
            if [ -n "$matches" ]; then
                loc_count=$((loc_count + 1))
                echo -e "   ${CYAN}--- 来自文件: ${conf} ---${NC}"
                grep -I -E "location|proxy_pass" "$conf" 2>/dev/null | sed 's/^[[:space:]]*/     /'
            fi
        fi
    done
    [ $loc_count -eq 0 ] && echo -e "   ${YELLOW}(未检测到其他反向代理指令)${NC}"
    
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

# 全量检测所有已配置代理的连通性与 HTTP 响应
test_all_proxies_connectivity() {
    init_env
    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}          全量检测 Nginx 反向代理连通性${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    local found=0
    
    # 1. 扫描已启用的独立配置文件 (过滤非文本文件)
    for f in "${ENABLED_CONF_DIR}"/proxy_*.conf; do
        if [ -f "$f" ]; then
            if ! grep -I -q . "$f" 2>/dev/null; then
                continue
            fi
            found=$((found + 1))
            local l_port=$(grep -I -E '^[[:space:]]*listen' "$f" | head -1 | awk '{print $2}' | tr -d ';')
            local p_path=$(grep -I -E '^[[:space:]]*location' "$f" | head -1 | awk '{print $2}' | tr -d '{')
            local p_pass=$(grep -I -E '^[[:space:]]*proxy_pass' "$f" | head -1 | awk '{print $2}' | tr -d ';')
            local s_name=$(grep -I -E '^[[:space:]]*server_name' "$f" | head -1 | awk '{print $2}' | tr -d ';')
            
            l_port=${l_port:-80}
            p_path=${p_path:-/}
            
            local up_host="127.0.0.1"
            local up_port="80"
            if [[ "$p_pass" =~ http://([^:]+):([0-9]+) ]]; then
                up_host="${BASH_REMATCH[1]}"
                up_port="${BASH_REMATCH[2]}"
            fi
            
            echo -e "${BLUE}>>> 独立站点代理: $(basename "$f")${NC}"
            verify_proxy_rule "$l_port" "$p_path" "$up_host" "$up_port" "$s_name"
        fi
    done
    
    # 2. 扫描默认站点中的路径反代
    local def_conf
    def_conf=$(find_default_server_conf)
    if [ -n "$def_conf" ] && [ -f "$def_conf" ]; then
        local loc_lines
        loc_lines=$(grep -nE '^[[:space:]]*location[[:space:]]+/[^[:space:]]*' "$def_conf" 2>/dev/null | grep -vE 'location[[:space:]]*/[[:space:]]*\{')
        if [ -n "$loc_lines" ]; then
            while IFS= read -r item; do
                [ -z "$item" ] && continue
                local line_no=$(echo "$item" | cut -d: -f1)
                local content_part=$(echo "$item" | cut -d: -f2-)
                local loc_path=$(echo "$content_part" | awk '{print $2}' | tr -d '{')
                [ -z "$loc_path" ] && continue
                
                local p_pass
                p_pass=$(tail -n +"$line_no" "$def_conf" | head -15 | grep -E '^[[:space:]]*proxy_pass' | head -1 | awk '{print $2}' | tr -d ';')
                if [ -n "$p_pass" ]; then
                    found=$((found + 1))
                    local up_host="127.0.0.1"
                    local up_port="80"
                    if [[ "$p_pass" =~ http://([^:]+):([0-9]+) ]]; then
                        up_host="${BASH_REMATCH[1]}"
                        up_port="${BASH_REMATCH[2]}"
                    fi
                    echo -e "${BLUE}>>> 默认站点路径代理: ${loc_path} (位于 $(basename "$def_conf"))${NC}"
                    verify_proxy_rule "80" "$loc_path" "$up_host" "$up_port" "_"
                fi
            done <<< "$loc_lines"
        fi
    fi
    
    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}未检测到任何反向代理规则配置${NC}"
        echo -e "${CYAN}======================================================${NC}"
    fi
}

# 删除代理配置 (支持选择序号删除)
delete_proxy_config() {
    check_root
    init_env
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}         删除 Nginx 反向代理${NC}"
    echo -e "${CYAN}========================================${NC}"
    
    local items=()
    local item_types=() # "file" 或 "tag"
    local item_targets=() # 文件路径 或 配置文件:tag_id
    local idx=0
    
    # 1. 扫描独立配置文件
    for f in /etc/nginx/conf.d/proxy_*.conf /etc/nginx/sites-available/proxy_*.conf; do
        if [ -f "$f" ]; then
            idx=$((idx + 1))
            items+=("[独立文件] $(basename "$f") - $f")
            item_types+=("file")
            item_targets+=("$f")
        fi
    done
    
    # 2. 扫描注入在 default 站点中的代理标记
    local def_conf
    def_conf=$(find_default_server_conf)
    if [ -n "$def_conf" ] && [ -f "$def_conf" ]; then
        local tags
        tags=$(grep -oE '# BEGIN_PROXY_[a-zA-Z0-9_]+' "$def_conf" | sed 's/# BEGIN_PROXY_//' | sort -u)
        for tag in $tags; do
            idx=$((idx + 1))
            items+=("[默认站点路径] /${tag} (位于 ${def_conf})")
            item_types+=("tag")
            item_targets+=("${def_conf}:${tag}")
        done
    fi
    
    if [ ${#items[@]} -eq 0 ]; then
        echo -e "${YELLOW}未检测到任何可供删除的代理配置${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}检测到以下代理配置:${NC}"
    for i in "${!items[@]}"; do
        echo -e "${GREEN}$((i+1)).${NC} ${items[$i]}"
    done
    echo -e "${RED}0.${NC} 返回"
    echo -e "${CYAN}========================================${NC}"
    echo -n "请输入要删除的配置序号 [0-$idx]: "
    read -r del_num
    
    if [ "$del_num" = "0" ] || [ -z "$del_num" ]; then
        echo -e "${YELLOW}已取消删除${NC}"
        return 0
    fi
    
    if ! [[ "$del_num" =~ ^[0-9]+$ ]] || [ "$del_num" -lt 1 ] || [ "$del_num" -gt "$idx" ]; then
        echo -e "${RED}输入无效${NC}"
        return 1
    fi
    
    local target_idx=$((del_num - 1))
    local type="${item_types[$target_idx]}"
    local target="${item_targets[$target_idx]}"
    
    if [ "$type" = "file" ]; then
        echo -e "${YELLOW}正在删除配置文件: ${target}...${NC}"
        local base_name
        base_name=$(basename "$target")
        rm -f "$target"
        rm -f "/etc/nginx/sites-available/${base_name}" "/etc/nginx/sites-enabled/${base_name}" "/etc/nginx/conf.d/${base_name}" 2>/dev/null
        
        if test_config_silent; then
            echo -e "${GREEN}✓ 代理配置文件已删除${NC}"
            reload_nginx
        else
            echo -e "${RED}✗ 删除后配置测试失败，请检查配置${NC}"
        fi
    elif [ "$type" = "tag" ]; then
        local conf_file="${target%%:*}"
        local tag_id="${target##*:}"
        echo -e "${YELLOW}正在从 ${conf_file} 中移除代理标记 /${tag_id}...${NC}"
        
        local backup_file="${conf_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$conf_file" "$backup_file"
        
        local tmp_clean=$(mktemp)
        sed "/# BEGIN_PROXY_${tag_id}/,/# END_PROXY_${tag_id}/d" "$conf_file" > "$tmp_clean"
        cp "$tmp_clean" "$conf_file"
        rm -f "$tmp_clean"
        
        if test_config_silent; then
            echo -e "${GREEN}✓ 已成功移除路径代理配置${NC}"
            rm -f "$backup_file"
            reload_nginx
        else
            echo -e "${RED}✗ 移除后配置语法错误，正在自动回滚...${NC}"
            cp "$backup_file" "$conf_file"
            rm -f "$backup_file"
        fi
    fi
}

#====================================================
# 一键修复 / 恢复 Nginx 初始出厂配置
#====================================================

# 1. 官方包出厂原生重置 (100% 还原刚安装时的官方纯净初始配置)
factory_reset_from_pkg() {
    echo -e "${YELLOW}正在通过官方包管理器 ($PKG_MGR) 强制重新提取官方初始配置文件...${NC}"
    
    if [ "$PKG_MGR" = "apt" ]; then
        echo -e "${BLUE}执行 apt 官方配置强制覆盖还原 (force-confmiss / force-confnew)...${NC}"
        apt-get update -y
        # 清理异常链接与临时代理
        rm -rf /etc/nginx/sites-enabled/* 2>/dev/null
        rm -rf /etc/nginx/conf.d/proxy_*.conf 2>/dev/null
        
        # 强制释放官方包中的所有初始配置文件
        apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" -o Dpkg::Options::="--force-confnew" -y nginx nginx-common nginx-core 2>/dev/null || \
        apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" -o Dpkg::Options::="--force-confnew" -y nginx
        
        # 建立默认软链
        if [ -f /etc/nginx/sites-available/default ] && [ -d /etc/nginx/sites-enabled ]; then
            ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        fi
        
    elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
        echo -e "${BLUE}执行 rpm 官方配置强制覆盖还原...${NC}"
        rm -rf /etc/nginx/conf.d/proxy_*.conf 2>/dev/null
        if command -v dnf &>/dev/null; then
            dnf reinstall -y nginx
        else
            yum reinstall -y nginx
        fi
        
        # 将 rpm 生成的 .rpmnew 文件覆盖回原配置
        find /etc/nginx -name "*.rpmnew" 2>/dev/null | while read -r rpmnew; do
            orig="${rpmnew%.rpmnew}"
            mv -f "$rpmnew" "$orig"
        done
        
    elif [ "$PKG_MGR" = "pacman" ]; then
        echo -e "${BLUE}执行 pacman 官方配置还原...${NC}"
        pacman -S --noconfirm nginx
        find /etc/nginx -name "*.pacnew" 2>/dev/null | while read -r pacnew; do
            orig="${pacnew%.pacnew}"
            mv -f "$pacnew" "$orig"
        done
    elif [ "$PKG_MGR" = "apk" ]; then
        apk fix nginx
    fi
}

# 2. 本地快速重置默认站点 (无需联网下载)
local_reset_default_site() {
    echo -e "${BLUE}正在本地重建标准默认站点配置...${NC}"
    
    # 清理失效代理与临时文件
    rm -rf /etc/nginx/conf.d/proxy_*.conf 2>/dev/null
    find /etc/nginx -name "*.bak.*" -delete 2>/dev/null
    find /etc/nginx -name "*.tmp*" -delete 2>/dev/null
    
    mkdir -p /var/www/html
    if [ ! -f /var/www/html/index.html ]; then
        cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to Nginx</title>
<style>
    body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; padding-top: 50px; }
</style>
</head>
<body>
<h1>Welcome to Nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and working.</p>
</body>
</html>
EOF
    fi

    if [ "$CONF_STYLE" = "sites" ]; then
        # Debian / Ubuntu 环境
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        rm -rf /etc/nginx/sites-enabled/* 2>/dev/null
        cat > /etc/nginx/sites-available/default << 'EOF'
# Nginx 标准默认站点配置 (Debian/Ubuntu)
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    else
        # RHEL / CentOS / Fedora / Arch 环境
        mkdir -p /etc/nginx/conf.d
        if grep -q "server[[:space:]]*{" /etc/nginx/nginx.conf 2>/dev/null; then
            cat > /etc/nginx/conf.d/default.conf << 'EOF'
# Nginx 默认站点扩展配置
EOF
        else
            cat > /etc/nginx/conf.d/default.conf << 'EOF'
# Nginx 标准默认站点配置 (RHEL/CentOS)
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF
        fi
    fi
}

# 恢复默认配置交互入口
restore_default_config() {
    check_root
    init_env
    
    echo ""
    echo -e "${RED}======================================================${NC}"
    echo -e "${RED}            恢复 Nginx 初始/默认配置${NC}"
    echo -e "${RED}======================================================${NC}"
    echo -e "${GREEN}1.${NC} 【官方出厂原生重置】(强烈推荐)"
    echo -e "   通过系统包管理器 ($PKG_MGR) 强制重新提取官方初始配置文件"
    echo -e "   100% 还原为刚刚全新安装 Nginx 时的纯净状态 (含 nginx.conf、default 等全部文件)"
    echo ""
    echo -e "${GREEN}2.${NC} 【本地快速修复重置】"
    echo -e "   无需联网下载，在本地清理代理并重新生成标准合法 default 站点"
    echo ""
    echo -e "${RED}0.${NC} 返回"
    echo -e "${RED}======================================================${NC}"
    echo -n "请选择恢复模式 [0-2]: "
    read -r r_choice
    
    case "$r_choice" in
        1|2)
            # 1. 无论选哪种，先执行全盘安全备份
            local backup_dir="/root/nginx_backup_$(date +%Y%m%d_%H%M%S)"
            echo -e "${BLUE}正在备份当前所有配置到: ${backup_dir}...${NC}"
            mkdir -p "$backup_dir"
            cp -r /etc/nginx/* "$backup_dir/" 2>/dev/null
            echo -e "${GREEN}✓ 备份完成${NC}"
            
            if [ "$r_choice" = "1" ]; then
                factory_reset_from_pkg
            else
                local_reset_default_site
            fi
            
            ensure_websocket_map
            
            # 2. 测试配置语法并重启服务
            echo -e "${BLUE}正在测试恢复后的配置并重启服务...${NC}"
            if test_config; then
                restart_service
                echo ""
                echo -e "${GREEN}======================================================${NC}"
                echo -e "${GREEN}  ✓ Nginx 初始配置已成功恢复，服务正常运行!${NC}"
                echo -e "${GREEN}======================================================${NC}"
                echo -e "${BLUE}修改前历史配置已安全保存在: ${backup_dir}${NC}"
            else
                echo -e "${RED}✗ 配置测试仍有错误，请查看上方提示${NC}"
            fi
            ;;
        0)
            echo -e "${YELLOW}操作已取消${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

#====================================================
# 网站首页模板与伪装发布管理
#====================================================

# 探测 Nginx Web 根目录
get_nginx_web_root() {
    local root_path=""
    # 1. 尝试从活动配置文件中解析
    for conf in /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf /etc/nginx/nginx.conf; do
        if [ -f "$conf" ]; then
            root_path=$(grep -E '^[ \t]*root[ \t]+' "$conf" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -n 1)
            [ -n "$root_path" ] && break
        fi
    done
    # 2. 检查系统常见默认目录
    if [ -z "$root_path" ] || [ ! -d "$root_path" ]; then
        for p in /var/www/html /usr/share/nginx/html /var/www /var/www/localhost/htdocs; do
            if [ -d "$p" ]; then
                root_path="$p"
                break
            fi
        done
    fi
    [ -z "$root_path" ] && root_path="/var/www/html"
    mkdir -p "$root_path" 2>/dev/null
    echo "$root_path"
}

# 备份现有 index.html
backup_index_html() {
    local root_dir="$1"
    if [ -f "$root_dir/index.html" ]; then
        local bak="$root_dir/index.html.bak_$(date +%Y%m%d_%H%M%S)"
        cp "$root_dir/index.html" "$bak"
        echo -e "${GREEN}✓ 已备份原主页至: ${bak}${NC}"
    fi
}

# 1. 部署 2048 小游戏
deploy_game_2048() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    cat > "$target_file" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<title>2048 - 经典益智数字拼图</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; user-select: none; -webkit-user-select: none; }
body {
    background: #faf8ef; color: #776e65; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 15px;
}
.header { width: 100%; max-width: 400px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; }
.title { font-size: 46px; font-weight: bold; color: #776e65; line-height: 1; }
.scores { display: flex; gap: 8px; }
.score-box { background: #bbada0; color: #fff; border-radius: 6px; padding: 6px 12px; text-align: center; min-width: 70px; }
.score-title { font-size: 11px; text-transform: uppercase; font-weight: 600; opacity: 0.8; }
.score-val { font-size: 18px; font-weight: bold; }
.toolbar { width: 100%; max-width: 400px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; }
.intro { font-size: 13px; color: #8f7a66; }
.btn-restart { background: #8f7a66; color: #f9f6f2; border: none; border-radius: 6px; padding: 8px 16px; font-weight: bold; cursor: pointer; transition: 0.2s; }
.btn-restart:hover { background: #9f8b77; }
.game-container {
    width: 100%; max-width: 400px; height: 400px; background: #bbada0; border-radius: 8px; padding: 12px; position: relative;
    touch-action: none;
}
.grid { display: grid; grid-template-columns: repeat(4, 1fr); grid-template-rows: repeat(4, 1fr); gap: 12px; width: 100%; height: 100%; }
.cell { background: rgba(238, 228, 218, 0.35); border-radius: 6px; }
.tile-container { position: absolute; top: 12px; left: 12px; right: 12px; bottom: 12px; }
.tile {
    position: absolute; width: calc((100% - 36px) / 4); height: calc((100% - 36px) / 4);
    border-radius: 6px; display: flex; align-items: center; justify-content: center; font-weight: bold; font-size: 28px;
    transition: transform 100ms ease-in-out;
}
.tile-2 { background: #eee4da; color: #776e65; }
.tile-4 { background: #ede0c8; color: #776e65; }
.tile-8 { background: #f2b179; color: #f9f6f2; }
.tile-16 { background: #f59563; color: #f9f6f2; }
.tile-32 { background: #f67c5f; color: #f9f6f2; }
.tile-64 { background: #f65e3b; color: #f9f6f2; }
.tile-128 { background: #edcf72; color: #f9f6f2; font-size: 24px; box-shadow: 0 0 10px rgba(243, 215, 116, 0.4); }
.tile-256 { background: #edcc61; color: #f9f6f2; font-size: 24px; box-shadow: 0 0 12px rgba(243, 215, 116, 0.5); }
.tile-512 { background: #edc850; color: #f9f6f2; font-size: 24px; box-shadow: 0 0 15px rgba(243, 215, 116, 0.6); }
.tile-1024 { background: #edc53f; color: #f9f6f2; font-size: 20px; box-shadow: 0 0 18px rgba(243, 215, 116, 0.7); }
.tile-2048 { background: #edc22e; color: #f9f6f2; font-size: 20px; box-shadow: 0 0 22px rgba(243, 215, 116, 0.8); }
.overlay {
    position: absolute; top: 0; left: 0; right: 0; bottom: 0; background: rgba(238, 228, 218, 0.78);
    display: none; flex-direction: column; align-items: center; justify-content: center; border-radius: 8px; z-index: 10;
}
.overlay.active { display: flex; animation: fadeIn 0.4s ease forwards; }
.overlay-msg { font-size: 32px; font-weight: bold; color: #776e65; margin-bottom: 16px; }
@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
</style>
</head>
<body>
<div class="header">
    <div class="title">2048</div>
    <div class="scores">
        <div class="score-box"><div class="score-title">得分</div><div id="score" class="score-val">0</div></div>
        <div class="score-box"><div class="score-title">最高分</div><div id="best" class="score-val">0</div></div>
    </div>
</div>
<div class="toolbar">
    <div class="intro">滑动或按方向键合并数字至 <strong>2048</strong>！</div>
    <button class="btn-restart" onclick="game.init()">新游戏</button>
</div>
<div class="game-container" id="board">
    <div class="grid">
        <div class="cell"></div><div class="cell"></div><div class="cell"></div><div class="cell"></div>
        <div class="cell"></div><div class="cell"></div><div class="cell"></div><div class="cell"></div>
        <div class="cell"></div><div class="cell"></div><div class="cell"></div><div class="cell"></div>
        <div class="cell"></div><div class="cell"></div><div class="cell"></div><div class="cell"></div>
    </div>
    <div class="tile-container" id="tileContainer"></div>
    <div class="overlay" id="overlay">
        <div class="overlay-msg" id="overlayMsg">游戏结束</div>
        <button class="btn-restart" onclick="game.init()">再玩一次</button>
    </div>
</div>

<script>
class Game2048 {
    constructor() {
        this.size = 4;
        this.board = [];
        this.score = 0;
        this.best = parseInt(localStorage.getItem('2048_best') || '0', 10);
        document.getElementById('best').innerText = this.best;
        this.init();
        this.setupInputs();
    }
    init() {
        this.board = Array(this.size).fill(0).map(() => Array(this.size).fill(0));
        this.score = 0;
        document.getElementById('score').innerText = 0;
        document.getElementById('overlay').classList.remove('active');
        this.addTile();
        this.addTile();
        this.render();
    }
    addTile() {
        let empty = [];
        for (let r = 0; r < this.size; r++) {
            for (let c = 0; c < this.size; c++) {
                if (this.board[r][c] === 0) empty.push({ r, c });
            }
        }
        if (empty.length > 0) {
            let { r, c } = empty[Math.floor(Math.random() * empty.length)];
            this.board[r][c] = Math.random() < 0.9 ? 2 : 4;
        }
    }
    render() {
        const container = document.getElementById('tileContainer');
        container.innerHTML = '';
        for (let r = 0; r < this.size; r++) {
            for (let c = 0; c < this.size; c++) {
                const val = this.board[r][c];
                if (val !== 0) {
                    const tile = document.createElement('div');
                    tile.className = `tile tile-${val > 2048 ? 2048 : val}`;
                    tile.style.transform = `translate(${c * 100}%, ${r * 100}%)`;
                    tile.innerText = val;
                    container.appendChild(tile);
                }
            }
        }
    }
    move(dir) {
        let moved = false;
        let prev = JSON.stringify(this.board);
        if (dir === 'left') {
            for (let r = 0; r < this.size; r++) this.board[r] = this.slide(this.board[r]);
        } else if (dir === 'right') {
            for (let r = 0; r < this.size; r++) this.board[r] = this.slide(this.board[r].reverse()).reverse();
        } else if (dir === 'up') {
            for (let c = 0; c < this.size; c++) {
                let col = [this.board[0][c], this.board[1][c], this.board[2][c], this.board[3][c]];
                col = this.slide(col);
                for (let r = 0; r < this.size; r++) this.board[r][c] = col[r];
            }
        } else if (dir === 'down') {
            for (let c = 0; c < this.size; c++) {
                let col = [this.board[3][c], this.board[2][c], this.board[1][c], this.board[0][c]];
                col = this.slide(col);
                for (let r = 0; r < this.size; r++) this.board[r][c] = col[3 - r];
            }
        }
        if (JSON.stringify(this.board) !== prev) {
            this.addTile();
            this.render();
            this.checkGameOver();
        }
    }
    slide(row) {
        let arr = row.filter(v => v !== 0);
        for (let i = 0; i < arr.length - 1; i++) {
            if (arr[i] === arr[i + 1]) {
                arr[i] *= 2;
                this.score += arr[i];
                arr.splice(i + 1, 1);
                if (this.score > this.best) {
                    this.best = this.score;
                    localStorage.setItem('2048_best', this.best);
                    document.getElementById('best').innerText = this.best;
                }
                document.getElementById('score').innerText = this.score;
            }
        }
        while (arr.length < this.size) arr.push(0);
        return arr;
    }
    checkGameOver() {
        for (let r = 0; r < this.size; r++) {
            for (let c = 0; c < this.size; c++) {
                if (this.board[r][c] === 0) return;
                if (c < this.size - 1 && this.board[r][c] === this.board[r][c + 1]) return;
                if (r < this.size - 1 && this.board[r][c] === this.board[r + 1][c]) return;
            }
        }
        document.getElementById('overlayMsg').innerText = "游戏结束";
        document.getElementById('overlay').classList.add('active');
    }
    setupInputs() {
        window.addEventListener('keydown', e => {
            if (['ArrowLeft', 'KeyA'].includes(e.code)) this.move('left');
            else if (['ArrowRight', 'KeyD'].includes(e.code)) this.move('right');
            else if (['ArrowUp', 'KeyW'].includes(e.code)) this.move('up');
            else if (['ArrowDown', 'KeyS'].includes(e.code)) this.move('down');
        });
        let startX, startY;
        const el = document.getElementById('board');
        el.addEventListener('touchstart', e => {
            startX = e.touches[0].clientX;
            startY = e.touches[0].clientY;
        }, { passive: true });
        el.addEventListener('touchend', e => {
            if (!startX || !startY) return;
            let dx = e.changedTouches[0].clientX - startX;
            let dy = e.changedTouches[0].clientY - startY;
            if (Math.max(Math.abs(dx), Math.abs(dy)) > 25) {
                if (Math.abs(dx) > Math.abs(dy)) {
                    this.move(dx > 0 ? 'right' : 'left');
                } else {
                    this.move(dy > 0 ? 'down' : 'up');
                }
            }
            startX = startY = null;
        }, { passive: true });
    }
}
const game = new Game2048();
</script>
</body>
</html>
EOF
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 经典 2048 小游戏已成功部署至站点首页！${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 2. 部署霓虹赛博贪吃蛇小游戏
deploy_game_snake() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    cat > "$target_file" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<title>霓虹赛博贪吃蛇</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; user-select: none; }
body {
    background: #0d1117; color: #00ffcc; font-family: 'Segoe UI', system-ui, sans-serif;
    display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 10px;
}
.header { width: 100%; max-width: 360px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
.title { font-size: 24px; font-weight: 800; text-shadow: 0 0 10px #00ffcc; }
.stats { display: flex; gap: 10px; }
.stat-box { background: rgba(0,255,204,0.1); border: 1px solid #00ffcc; border-radius: 6px; padding: 4px 10px; text-align: center; }
.stat-lbl { font-size: 10px; opacity: 0.8; }
.stat-val { font-size: 16px; font-weight: bold; }
#gameCanvas {
    background: #080a0f; border: 2px solid #00ffcc; border-radius: 8px; box-shadow: 0 0 16px rgba(0,255,204,0.25);
    max-width: 100%; display: block;
}
.d-pad { margin-top: 15px; display: grid; grid-template-columns: repeat(3, 60px); grid-template-rows: repeat(2, 50px); gap: 6px; }
.d-btn {
    background: rgba(0,255,204,0.15); border: 1px solid #00ffcc; color: #00ffcc; border-radius: 8px;
    font-size: 20px; display: flex; align-items: center; justify-content: center; cursor: pointer;
    touch-action: manipulation;
}
.d-btn:active { background: #00ffcc; color: #080a0f; }
.btn-up { grid-column: 2; grid-row: 1; }
.btn-left { grid-column: 1; grid-row: 2; }
.btn-down { grid-column: 2; grid-row: 2; }
.btn-right { grid-column: 3; grid-row: 2; }
.tip { font-size: 12px; color: #8b949e; margin-top: 10px; text-align: center; }
.overlay {
    position: absolute; top: 0; left: 0; width: 100%; height: 100%; background: rgba(8,10,15,0.85);
    display: none; flex-direction: column; align-items: center; justify-content: center; z-index: 20; border-radius: 8px;
}
.overlay.active { display: flex; }
.btn-restart {
    background: #00ffcc; color: #080a0f; font-weight: bold; border: none; padding: 10px 24px; border-radius: 6px;
    cursor: pointer; font-size: 16px; box-shadow: 0 0 12px #00ffcc; margin-top: 12px;
}
</style>
</head>
<body>
<div class="header">
    <div class="title">NEON SNAKE</div>
    <div class="stats">
        <div class="stat-box"><div class="stat-lbl">得分</div><div id="score" class="stat-val">0</div></div>
        <div class="stat-box"><div class="stat-lbl">最高分</div><div id="best" class="stat-val">0</div></div>
    </div>
</div>
<div style="position: relative;">
    <canvas id="gameCanvas" width="340" height="340"></canvas>
    <div class="overlay" id="overlay">
        <h2 style="color: #ff007f; text-shadow: 0 0 12px #ff007f; font-size: 28px;">GAME OVER</h2>
        <p style="margin-top: 8px; color: #8b949e;">最终得分: <span id="finalScore" style="color: #00ffcc; font-weight: bold;">0</span></p>
        <button class="btn-restart" onclick="game.start()">重新开始</button>
    </div>
</div>
<div class="d-pad">
    <div class="d-btn btn-up" onclick="game.setDir(0,-1)">▲</div>
    <div class="d-btn btn-left" onclick="game.setDir(-1,0)">◀</div>
    <div class="d-btn btn-down" onclick="game.setDir(0,1)">▼</div>
    <div class="d-btn btn-right" onclick="game.setDir(1,0)">▶</div>
</div>
<div class="tip">电脑键盘按 W A S D 或方向键控制</div>

<script>
class NeonSnake {
    constructor() {
        this.canvas = document.getElementById('gameCanvas');
        this.ctx = this.canvas.getContext('2d');
        this.grid = 17;
        this.count = this.canvas.width / this.grid;
        this.best = parseInt(localStorage.getItem('neon_snake_best') || '0', 10);
        document.getElementById('best').innerText = this.best;
        this.start();
        this.setupKeys();
    }
    start() {
        this.snake = [{ x: 8, y: 8 }, { x: 7, y: 8 }, { x: 6, y: 8 }];
        this.dir = { x: 1, y: 0 };
        this.nextDir = { x: 1, y: 0 };
        this.score = 0;
        this.food = this.spawnFood();
        this.over = false;
        document.getElementById('score').innerText = 0;
        document.getElementById('overlay').classList.remove('active');
        if (this.timer) clearInterval(this.timer);
        this.timer = setInterval(() => this.update(), 110);
    }
    setDir(x, y) {
        if (this.dir.x + x !== 0 || this.dir.y + y !== 0) {
            this.nextDir = { x, y };
        }
    }
    spawnFood() {
        let f;
        while (!f || this.snake.some(s => s.x === f.x && s.y === f.y)) {
            f = { x: Math.floor(Math.random() * this.count), y: Math.floor(Math.random() * this.count) };
        }
        return f;
    }
    update() {
        if (this.over) return;
        this.dir = { ...this.nextDir };
        const head = { x: this.snake[0].x + this.dir.x, y: this.snake[0].y + this.dir.y };
        if (head.x < 0 || head.x >= this.count || head.y < 0 || head.y >= this.count ||
            this.snake.some(s => s.x === head.x && s.y === head.y)) {
            this.gameOver();
            return;
        }
        this.snake.unshift(head);
        if (head.x === this.food.x && head.y === this.food.y) {
            this.score += 10;
            document.getElementById('score').innerText = this.score;
            if (this.score > this.best) {
                this.best = this.score;
                localStorage.setItem('neon_snake_best', this.best);
                document.getElementById('best').innerText = this.best;
            }
            this.food = this.spawnFood();
        } else {
            this.snake.pop();
        }
        this.draw();
    }
    draw() {
        this.ctx.fillStyle = '#080a0f';
        this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
        this.ctx.strokeStyle = 'rgba(0, 255, 204, 0.05)';
        for (let i = 0; i < this.count; i++) {
            this.ctx.beginPath(); this.ctx.moveTo(i * this.grid, 0); this.ctx.lineTo(i * this.grid, this.canvas.height); this.ctx.stroke();
            this.ctx.beginPath(); this.ctx.moveTo(0, i * this.grid); this.ctx.lineTo(this.canvas.width, i * this.grid); this.ctx.stroke();
        }
        this.ctx.shadowBlur = 10;
        this.ctx.shadowColor = '#ff007f';
        this.ctx.fillStyle = '#ff007f';
        this.ctx.fillRect(this.food.x * this.grid + 2, this.food.y * this.grid + 2, this.grid - 4, this.grid - 4);
        this.ctx.shadowColor = '#00ffcc';
        this.snake.forEach((seg, i) => {
            this.ctx.fillStyle = i === 0 ? '#ffffff' : '#00ffcc';
            this.ctx.fillRect(seg.x * this.grid + 1, seg.y * this.grid + 1, this.grid - 2, this.grid - 2);
        });
        this.ctx.shadowBlur = 0;
    }
    gameOver() {
        this.over = true;
        clearInterval(this.timer);
        document.getElementById('finalScore').innerText = this.score;
        document.getElementById('overlay').classList.add('active');
    }
    setupKeys() {
        window.addEventListener('keydown', e => {
            if (e.key === 'ArrowUp' || e.key === 'w') this.setDir(0, -1);
            else if (e.key === 'ArrowDown' || e.key === 's') this.setDir(0, 1);
            else if (e.key === 'ArrowLeft' || e.key === 'a') this.setDir(-1, 0);
            else if (e.key === 'ArrowRight' || e.key === 'd') this.setDir(1, 0);
        });
    }
}
const game = new NeonSnake();
</script>
</body>
</html>
EOF
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 霓虹赛博贪吃蛇小游戏已成功部署至站点首页！${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 3. 部署经典俄罗斯方块
deploy_game_tetris() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    cat > "$target_file" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<title>经典俄罗斯方块</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; user-select: none; }
body {
    background: #11141d; color: #fff; font-family: 'Segoe UI', system-ui, sans-serif;
    display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; padding: 10px;
}
.game-wrap { display: flex; gap: 15px; background: #1a1f2c; padding: 15px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
canvas { background: #0c0e14; border: 2px solid #2f384f; border-radius: 6px; display: block; }
.side-panel { display: flex; flex-direction: column; justify-content: space-between; min-width: 100px; }
.panel-box { background: #0c0e14; border: 1px solid #2f384f; border-radius: 6px; padding: 10px; text-align: center; margin-bottom: 10px; }
.panel-lbl { font-size: 11px; color: #8b9bb4; text-transform: uppercase; margin-bottom: 4px; }
.panel-val { font-size: 20px; font-weight: bold; color: #4deeea; }
.btn {
    background: #4deeea; color: #11141d; font-weight: bold; border: none; padding: 8px 12px;
    border-radius: 6px; cursor: pointer; margin-top: 5px; width: 100%;
}
.btn:hover { background: #74f0ee; }
.controls {
    margin-top: 15px; display: flex; flex-direction: column; align-items: center; gap: 6px; width: 100%; max-width: 320px;
}
.c-row { display: flex; gap: 10px; }
.c-btn {
    background: #252c3f; border: 1px solid #3c4866; color: #4deeea; border-radius: 8px;
    width: 54px; height: 44px; font-size: 18px; display: flex; align-items: center; justify-content: center;
    cursor: pointer; touch-action: manipulation;
}
.c-btn:active { background: #4deeea; color: #11141d; }
.tip { font-size: 12px; color: #6f7f98; margin-top: 10px; }
</style>
</head>
<body>
<div class="game-wrap">
    <canvas id="tetris" width="200" height="400"></canvas>
    <div class="side-panel">
        <div>
            <div class="panel-box"><div class="panel-lbl">得分</div><div id="score" class="panel-val">0</div></div>
            <div class="panel-box"><div class="panel-lbl">行数</div><div id="lines" class="panel-val">0</div></div>
            <div class="panel-box"><div class="panel-lbl">级别</div><div id="level" class="panel-val">1</div></div>
            <div class="panel-box">
                <div class="panel-lbl">下一个</div>
                <canvas id="next" width="80" height="80"></canvas>
            </div>
        </div>
        <button class="btn" onclick="game.start()">重新开始</button>
    </div>
</div>
<div class="controls">
    <div class="c-row">
        <div class="c-btn" onclick="game.rotate()">↻</div>
    </div>
    <div class="c-row">
        <div class="c-btn" onclick="game.move(-1)">◀</div>
        <div class="c-btn" onclick="game.drop()">▼</div>
        <div class="c-btn" onclick="game.move(1)">▶</div>
        <div class="c-btn" onclick="game.hardDrop()">⏬</div>
    </div>
</div>
<div class="tip">电脑按键: ← → 移动，↑ 旋转，↓ 软降，空格 硬降</div>

<script>
const COLS = 10, ROWS = 20, BLOCK = 20;
const SHAPES = [
    [],
    [[1,1,1,1]],
    [[1,1,1],[0,1,0]],
    [[1,1,1],[1,0,0]],
    [[1,1,1],[0,0,1]],
    [[1,1],[1,1]],
    [[0,1,1],[1,1,0]],
    [[1,1,0],[0,1,1]]
];
const COLORS = [null, '#4deeea', '#b00b69', '#f9a602', '#2f52e0', '#ffe600', '#00ff66', '#ff2e00'];

class TetrisGame {
    constructor() {
        this.canvas = document.getElementById('tetris');
        this.ctx = this.canvas.getContext('2d');
        this.nextCanvas = document.getElementById('next');
        this.nextCtx = this.nextCanvas.getContext('2d');
        this.start();
        this.setupKeys();
    }
    start() {
        this.board = Array(ROWS).fill(0).map(() => Array(COLS).fill(0));
        this.score = 0; this.lines = 0; this.level = 1;
        this.gameOver = false;
        this.nextType = Math.floor(Math.random() * 7) + 1;
        this.spawn();
        this.updateStats();
        if (this.timer) clearInterval(this.timer);
        this.speed = 800;
        this.timer = setInterval(() => this.drop(), this.speed);
    }
    spawn() {
        this.type = this.nextType;
        this.nextType = Math.floor(Math.random() * 7) + 1;
        this.matrix = SHAPES[this.type];
        this.pos = { x: Math.floor((COLS - this.matrix[0].length) / 2), y: 0 };
        if (this.collide(this.pos.x, this.pos.y, this.matrix)) {
            this.gameOver = true;
            clearInterval(this.timer);
            alert("游戏结束！最终得分: " + this.score);
        }
        this.drawNext();
    }
    collide(x, y, mat) {
        for (let r = 0; r < mat.length; r++) {
            for (let c = 0; c < mat[r].length; c++) {
                if (mat[r][c]) {
                    let nx = x + c, ny = y + r;
                    if (nx < 0 || nx >= COLS || ny >= ROWS || (ny >= 0 && this.board[ny][nx])) return true;
                }
            }
        }
        return false;
    }
    move(dir) {
        if (this.gameOver) return;
        if (!this.collide(this.pos.x + dir, this.pos.y, this.matrix)) {
            this.pos.x += dir;
            this.draw();
        }
    }
    rotate() {
        if (this.gameOver) return;
        const rotated = this.matrix[0].map((_, i) => this.matrix.map(row => row[i]).reverse());
        if (!this.collide(this.pos.x, this.pos.y, rotated)) {
            this.matrix = rotated;
            this.draw();
        }
    }
    drop() {
        if (this.gameOver) return;
        if (!this.collide(this.pos.x, this.pos.y + 1, this.matrix)) {
            this.pos.y++;
        } else {
            this.lock();
        }
        this.draw();
    }
    hardDrop() {
        if (this.gameOver) return;
        while (!this.collide(this.pos.x, this.pos.y + 1, this.matrix)) {
            this.pos.y++;
            this.score += 2;
        }
        this.lock();
        this.draw();
    }
    lock() {
        this.matrix.forEach((row, r) => {
            row.forEach((val, c) => {
                if (val) this.board[this.pos.y + r][this.pos.x + c] = this.type;
            });
        });
        this.clearLines();
        this.spawn();
    }
    clearLines() {
        let cleared = 0;
        for (let r = ROWS - 1; r >= 0; r--) {
            if (this.board[r].every(v => v !== 0)) {
                this.board.splice(r, 1);
                this.board.unshift(Array(COLS).fill(0));
                cleared++;
                r++;
            }
        }
        if (cleared > 0) {
            const points = [0, 100, 300, 500, 800];
            this.score += (points[cleared] || 1000) * this.level;
            this.lines += cleared;
            this.level = Math.floor(this.lines / 10) + 1;
            this.updateStats();
        }
    }
    updateStats() {
        document.getElementById('score').innerText = this.score;
        document.getElementById('lines').innerText = this.lines;
        document.getElementById('level').innerText = this.level;
    }
    draw() {
        this.ctx.fillStyle = '#0c0e14';
        this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
        this.board.forEach((row, r) => {
            row.forEach((val, c) => {
                if (val) this.drawBlock(this.ctx, c * BLOCK, r * BLOCK, COLORS[val]);
            });
        });
        if (this.matrix) {
            this.matrix.forEach((row, r) => {
                row.forEach((val, c) => {
                    if (val) this.drawBlock(this.ctx, (this.pos.x + c) * BLOCK, (this.pos.y + r) * BLOCK, COLORS[this.type]);
                });
            });
        }
    }
    drawBlock(ctx, x, y, color) {
        ctx.fillStyle = color;
        ctx.fillRect(x + 1, y + 1, BLOCK - 2, BLOCK - 2);
        ctx.strokeStyle = 'rgba(255,255,255,0.2)';
        ctx.strokeRect(x + 1, y + 1, BLOCK - 2, BLOCK - 2);
    }
    drawNext() {
        this.nextCtx.fillStyle = '#0c0e14';
        this.nextCtx.fillRect(0, 0, this.nextCanvas.width, this.nextCanvas.height);
        const mat = SHAPES[this.nextType];
        const offX = (this.nextCanvas.width - mat[0].length * 16) / 2;
        const offY = (this.nextCanvas.height - mat.length * 16) / 2;
        mat.forEach((row, r) => {
            row.forEach((val, c) => {
                if (val) {
                    this.nextCtx.fillStyle = COLORS[this.nextType];
                    this.nextCtx.fillRect(offX + c * 16, offY + r * 16, 14, 14);
                }
            });
        });
    }
    setupKeys() {
        window.addEventListener('keydown', e => {
            if (e.code === 'ArrowLeft' || e.code === 'KeyA') this.move(-1);
            else if (e.code === 'ArrowRight' || e.code === 'KeyD') this.move(1);
            else if (e.code === 'ArrowUp' || e.code === 'KeyW') this.rotate();
            else if (e.code === 'ArrowDown' || e.code === 'KeyS') this.drop();
            else if (e.code === 'Space') this.hardDrop();
        });
    }
}
const game = new TetrisGame();
</script>
</body>
</html>
EOF
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 经典俄罗斯方块小游戏已成功部署至站点首页！${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 4. 部署现代极客个人博客/导航主页
deploy_geek_blog() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    cat > "$target_file" << 'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Geek's Space - 探索技术与思考</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    background: #0d1117; color: #c9d1d9; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    line-height: 1.6; padding: 20px;
}
.container { max-width: 800px; margin: 0 auto; }
header { display: flex; justify-content: space-between; align-items: center; padding: 20px 0; border-bottom: 1px solid #30363d; margin-bottom: 30px; }
.logo { font-size: 22px; font-weight: bold; color: #58a6ff; text-decoration: none; display: flex; align-items: center; gap: 8px; }
nav a { color: #8b949e; text-decoration: none; margin-left: 20px; font-size: 14px; transition: color 0.2s; }
nav a:hover { color: #58a6ff; }
.hero-card {
    background: #161b22; border: 1px solid #30363d; border-radius: 12px; padding: 24px; margin-bottom: 30px;
    display: flex; gap: 20px; align-items: center; box-shadow: 0 4px 20px rgba(0,0,0,0.3);
}
.avatar {
    width: 72px; height: 72px; border-radius: 50%; background: linear-gradient(135deg, #238636, #58a6ff);
    display: flex; align-items: center; justify-content: center; font-size: 32px; flex-shrink: 0; box-shadow: 0 0 15px rgba(88,166,255,0.4);
}
.bio h1 { font-size: 20px; color: #f0f6fc; margin-bottom: 4px; display: flex; align-items: center; gap: 10px; }
.status-pill { font-size: 12px; background: rgba(35,134,54,0.2); color: #3fb950; border: 1px solid rgba(59,185,80,0.3); border-radius: 20px; padding: 2px 10px; font-weight: normal; }
.bio p { font-size: 14px; color: #8b949e; margin-bottom: 10px; }
.tags { display: flex; flex-wrap: wrap; gap: 6px; }
.tag { font-size: 12px; background: #21262d; color: #79c0ff; border: 1px solid #30363d; border-radius: 6px; padding: 2px 8px; }
.section-title { font-size: 18px; color: #f0f6fc; margin-bottom: 16px; border-left: 4px solid #58a6ff; padding-left: 10px; }
.posts { display: flex; flex-direction: column; gap: 16px; margin-bottom: 30px; }
.post-card {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 18px; transition: transform 0.2s, border-color 0.2s;
    cursor: pointer; text-decoration: none; display: block;
}
.post-card:hover { transform: translateY(-2px); border-color: #58a6ff; }
.post-title { font-size: 16px; font-weight: bold; color: #58a6ff; margin-bottom: 6px; }
.post-desc { font-size: 13px; color: #8b949e; margin-bottom: 10px; }
.post-meta { font-size: 12px; color: #6e7681; display: flex; gap: 15px; }
.links-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 40px; }
.link-card {
    background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 14px; text-decoration: none; color: #c9d1d9;
    display: flex; align-items: center; gap: 10px; font-size: 14px; transition: background 0.2s;
}
.link-card:hover { background: #21262d; color: #58a6ff; }
footer { text-align: center; font-size: 13px; color: #6e7681; padding: 20px 0; border-top: 1px solid #30363d; }
@media (max-width: 600px) {
    .hero-card { flex-direction: column; text-align: center; }
    .tags { justify-content: center; }
    header { flex-direction: column; gap: 10px; }
    nav a { margin: 0 10px; }
}
</style>
</head>
<body>
<div class="container">
    <header>
        <a href="#" class="logo">⚡ GEEK_SPACE</a>
        <nav>
            <a href="#">文章</a>
            <a href="#">项目</a>
            <a href="#">关于</a>
        </nav>
    </header>

    <div class="hero-card">
        <div class="avatar">🚀</div>
        <div class="bio">
            <h1>Geek Explorer <span class="status-pill">● Online</span></h1>
            <p>探索底层系统、高性能网络与云原生架构 · 追求极致效率与简洁优雅</p>
            <div class="tags">
                <span class="tag">Linux</span>
                <span class="tag">Nginx</span>
                <span class="tag">Docker</span>
                <span class="tag">BBR/TCP</span>
                <span class="tag">Go</span>
                <span class="tag">Python</span>
            </div>
        </div>
    </div>

    <div class="section-title">精选博文</div>
    <div class="posts">
        <div class="post-card">
            <div class="post-title">2026 现代 Linux VPS 极限网络调优与物理网卡 FQ 持久化实战</div>
            <div class="post-desc">深度剖析为什么常规 sysctl default_qdisc 会产生“假生效”，以及如何通过 hardware qdisc replace 和 64MB 巨型 BDP 读写缓冲区突破跨国千兆单流吞吐限制。</div>
            <div class="post-meta"><span>📅 2026-09-16</span><span>⏱ 8 min read</span><span>🏷 架构与网络</span></div>
        </div>
        <div class="post-card">
            <div class="post-title">从零搭建生产级 Nginx 安全反向代理与 WebSocket 动态映射</div>
            <div class="post-desc">解密 HTTP 与 WebSocket 混合流量在 Nginx 层的无损转发策略，实现精准状态探测与自动回滚高可用机制。</div>
            <div class="post-meta"><span>📅 2026-09-10</span><span>⏱ 12 min read</span><span>🏷 Nginx 实战</span></div>
        </div>
        <div class="post-card">
            <div class="post-title">如何保护 VPS 免受全网端口扫描与 SSH 暴力破解侵害</div>
            <div class="post-desc">修改自定义高位端口，联动 UFW / Firewalld / SELinux 策略，在确保业务安全的同时杜绝失联风险。</div>
            <div class="post-meta"><span>📅 2026-09-02</span><span>⏱ 6 min read</span><span>🏷 服务器运维</span></div>
        </div>
    </div>

    <div class="section-title">常用导航</div>
    <div class="links-grid">
        <a href="https://github.com" target="_blank" class="link-card">🐙 GitHub 开源项目</a>
        <a href="https://kernel.org" target="_blank" class="link-card">🐧 Linux Kernel 文档</a>
        <a href="https://nginx.org" target="_blank" class="link-card">🌐 Nginx 官方手册</a>
        <a href="https://speedtest.net" target="_blank" class="link-card">⚡ 国际网络测速</a>
    </div>

    <footer>
        <p>© 2026 Powered by Nginx on Linux VPS · All Rights Reserved.</p>
    </footer>
</div>
</body>
</html>
EOF
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 现代极客个人博客/导航主页已成功部署至站点首页！${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 5. 部署自定义地址栏不变的隐形跳转与伪装
deploy_cloaked_redirect() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    
    echo ""
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}         自定义地址栏不变的网站跳转/伪装${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${YELLOW}提示: 访客访问您的 VPS IP 或域名时，将以全屏无缝呈现目标网站，${NC}"
    echo -e "${YELLOW}      而浏览器的地址栏将始终保持为您当前 VPS 的地址！${NC}"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    
    local target_url=""
    read -p "请输入目标跳转网站 URL (如 https://www.bing.com): " target_url
    [ -z "$target_url" ] && echo -e "${YELLOW}已取消${NC}" && wait_for_user && return
    
    if [[ ! "$target_url" =~ ^https?:// ]]; then
        target_url="https://$target_url"
    fi
    
    local site_title="Welcome"
    read -p "请输入网页标签页标题 (默认: Welcome): " input_title
    [ -n "$input_title" ] && site_title="$input_title"
    
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    local template='<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>__SITE_TITLE__</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
#frame {
    position: fixed; top: 0; left: 0; width: 100vw; height: 100vh;
    border: none; margin: 0; padding: 0; display: block; z-index: 1;
}
#loader {
    position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: #12141a;
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    color: #8b949e; font-family: system-ui, sans-serif; z-index: 2; transition: opacity 0.5s ease;
}
.spinner {
    width: 44px; height: 44px; border: 4px solid rgba(255,255,255,0.1);
    border-top-color: #58a6ff; border-radius: 50%; animation: spin 0.8s linear infinite; margin-bottom: 16px;
}
@keyframes spin { to { transform: rotate(360deg); } }
</style>
</head>
<body>
<div id="loader">
    <div class="spinner"></div>
    <div style="font-size: 14px; letter-spacing: 1px;">正在加载内容...</div>
</div>
<iframe id="frame" src="__TARGET_URL__" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen onload="document.getElementById(\x27loader\x27).style.opacity=\x270\x27;setTimeout(()=>document.getElementById(\x27loader\x27).style.display=\x27none\x27,500)"></iframe>
</body>
</html>'

    local safe_url="${target_url//&/\\&}"
    local safe_title="${site_title//&/\\&}"
    local content="${template//__SITE_TITLE__/$safe_title}"
    content="${content//__TARGET_URL__/$safe_url}"
    
    echo "$content" > "$target_file"
    
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 隐形穿透跳转页面已成功部署至站点首页！${NC}"
    echo -e "${GREEN}  目标网站: ${CYAN}${target_url}${NC}"
    echo -e "${GREEN}  网页标题: ${CYAN}${site_title}${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 6. 还原官方原生 Nginx 欢迎页
restore_default_index() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    backup_index_html "$root_dir"
    local target_file="$root_dir/index.html"
    
    cat > "$target_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
html { color-scheme: light dark; }
body { width: 35em; margin: 0 auto;
font-family: Tahoma, Verdana, Arial, sans-serif; }
</style>
</head>
<body>
<h1>Welcome to nginx!</h1>
<p>If you see this page, the nginx web server is successfully installed and
working. Further configuration is required.</p>

<p>For online documentation and support please refer to
<a href="http://nginx.org/">nginx.org</a>.<br/>
Commercial support is available at
<a href="http://nginx.com/">nginx.com</a>.</p>

<p><em>Thank you for using nginx.</em></p>
</body>
</html>
EOF
    echo -e "${GREEN}======================================================${NC}"
    echo -e "${GREEN}  ✓ 已成功还原为官方原生 Nginx 欢迎页！${NC}"
    echo -e "${GREEN}  文件路径: ${target_file}${NC}"
    echo -e "${GREEN}======================================================${NC}"
    wait_for_user
}

# 二级菜单：网站首页与伪装发布管理
web_homepage_management() {
    local root_dir
    root_dir=$(get_nginx_web_root)
    
    while true; do
        clear_screen
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${CYAN}          Nginx 网站主页与伪装发布管理${NC}"
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "当前站点根目录: ${GREEN}${root_dir}${NC}"
        echo -e "主页文件路径:   ${GREEN}${root_dir}/index.html${NC}"
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e "${GREEN}1.${NC} 一键部署：经典 2048 数字拼图 (现代炫彩版)"
        echo -e "${GREEN}2.${NC} 一键部署：霓虹赛博贪吃蛇 (炫彩 Canvas + 触屏)"
        echo -e "${GREEN}3.${NC} 一键部署：经典俄罗斯方块 (复古街机风)"
        echo -e "${GREEN}4.${NC} 一键部署：现代极客个人博客 / 导航主页 (暗黑极简)"
        echo -e "${GREEN}5.${NC} 一键部署：自定义地址栏不变隐形跳转 (全屏穿透)"
        echo -e "${GREEN}6.${NC} 还原为官方原生欢迎页 (Welcome to nginx)"
        echo -e "${RED}0.${NC} 返回上级菜单"
        echo -e "${CYAN}==============================================================${NC}"
        echo -n "请选择操作 [0-6]: "
        
        read -r choice || break
        case "$choice" in
            1) deploy_game_2048 ;;
            2) deploy_game_snake ;;
            3) deploy_game_tetris ;;
            4) deploy_geek_blog ;;
            5) deploy_cloaked_redirect ;;
            6) restore_default_index ;;
            0) break ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

#====================================================
# 主菜单交互
#====================================================

main_menu() {
    init_env
    while true; do
        echo ""
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${CYAN}       Nginx 管理与反向代理工具 v${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${GREEN}1.${NC} 安装 Nginx"
        echo -e "${GREEN}2.${NC} 启动 / 重启 / 重载 Nginx"
        echo -e "${GREEN}3.${NC} 查看状态与当前代理配置"
        echo -e "${GREEN}4.${NC} 添加反向代理 (支持路径/独立站点/WS)"
        echo -e "${GREEN}5.${NC} 快捷添加预设代理 (/pyway -> 2052)"
        echo -e "${GREEN}6.${NC} 测试代理连通性 (实时探测 HTTP 与后端状态)"
        echo -e "${GREEN}7.${NC} 检查配置语法 (nginx -t)"
        echo -e "${GREEN}8.${NC} 删除代理配置 (支持编号选择)"
        echo -e "${GREEN}9.${NC} 恢复初始配置 (官方出厂还原 / 默认重置)"
        echo -e "${GREEN}10.${NC} 卸载 Nginx"
        echo -e "${GREEN}11.${NC} 网站首页与伪装发布 (小游戏 / 个人博客 / 隐形跳转)"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}==============================================================${NC}"
        echo -n "请选择操作 [0-11]: "
        
        read -r choice || break
        case "$choice" in
            1)
                check_root
                install_nginx
                ;;
            2)
                check_root
                echo ""
                echo -e "1. 重载配置 (平滑生效 reload)"
                echo -e "2. 重启服务 (restart)"
                echo -e "3. 启动服务 (start)"
                echo -e "4. 停止服务 (stop)"
                echo -n "请选择 [1-4]: "
                read -r s_choice
                case "$s_choice" in
                    1) reload_nginx ;;
                    2) restart_service ;;
                    3) start_service ;;
                    4) stop_service ;;
                    *) echo -e "${RED}无效选择${NC}" ;;
                esac
                ;;
            3)
                show_config
                ;;
            4)
                add_proxy_interactive
                ;;
            5)
                preset_pyway
                ;;
            6)
                test_all_proxies_connectivity
                ;;
            7)
                test_config
                ;;
            8)
                delete_proxy_config
                ;;
            9)
                restore_default_config
                ;;
            10)
                check_root
                uninstall_nginx
                ;;
            11)
                check_root
                web_homepage_management
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-11${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行入口
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main_menu
fi
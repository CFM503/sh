#!/bin/bash

#====================================================
# Nginx 管理与反向代理配置脚本
# 功能: 自动安装/卸载Nginx、安全配置反向代理(WebSocket)、
#       查看状态、删除代理、一键修复/恢复出厂默认配置
# 适配: Debian / Ubuntu / CentOS / RHEL / Fedora / Arch / Alpine
#====================================================

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

# 初始化环境
init_env() {
    detect_package_manager
    detect_nginx_dirs
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
    
    if command -v systemctl &> /dev/null; then
        systemctl reload nginx
    elif command -v service &> /dev/null; then
        service nginx reload
    else
        nginx -s reload
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
    for f in /etc/nginx/conf.d/proxy_*.conf /etc/nginx/sites-available/proxy_*.conf; do
        if [ -f "$f" ]; then
            count=$((count + 1))
            local l_port=$(grep -E '^[[:space:]]*listen' "$f" | head -1 | tr -s ' ' | xargs)
            local s_name=$(grep -E '^[[:space:]]*server_name' "$f" | head -1 | tr -s ' ' | xargs)
            local p_pass=$(grep -E '^[[:space:]]*proxy_pass' "$f" | head -1 | tr -s ' ' | xargs)
            echo -e "   ${GREEN}[$count]${NC} $f"
            [ -n "$l_port" ] && echo -e "       $l_port | $s_name"
            [ -n "$p_pass" ] && echo -e "       $p_pass"
        fi
    done
    [ $count -eq 0 ] && echo -e "   ${YELLOW}(暂无独立代理配置文件)${NC}"
    
    # 默认站点中的路径反代
    echo ""
    echo -e "${BLUE}4. 默认站点中检测到的反向代理 (proxy_pass):${NC}"
    local loc_count=0
    for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf; do
        if [ -f "$conf" ] && [[ "$conf" != *"00_websocket_map.conf"* ]]; then
            local matches
            matches=$(grep -n -C 2 "proxy_pass" "$conf" 2>/dev/null)
            if [ -n "$matches" ]; then
                loc_count=$((loc_count + 1))
                echo -e "   ${CYAN}--- 来自文件: ${conf} ---${NC}"
                grep -E "location|proxy_pass" "$conf" 2>/dev/null | sed 's/^[[:space:]]*/     /'
            fi
        fi
    done
    [ $loc_count -eq 0 ] && echo -e "   ${YELLOW}(未检测到其他反向代理指令)${NC}"
    
    echo -e "${CYAN}========================================${NC}"
    echo ""
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
        rm -f "/etc/nginx/sites-enabled/${base_name}" 2>/dev/null
        
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
# 主菜单交互
#====================================================

main_menu() {
    init_env
    while true; do
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}       Nginx 管理与反向代理工具${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo -e "${GREEN}1.${NC} 安装 Nginx"
        echo -e "${GREEN}2.${NC} 启动 / 重启 / 重载 Nginx"
        echo -e "${GREEN}3.${NC} 查看状态与当前代理配置"
        echo -e "${GREEN}4.${NC} 添加反向代理 (支持路径/独立站点/WS)"
        echo -e "${GREEN}5.${NC} 快捷添加预设代理 (/pyway -> 2052)"
        echo -e "${GREEN}6.${NC} 检查配置语法 (nginx -t)"
        echo -e "${GREEN}7.${NC} 删除代理配置 (支持编号选择)"
        echo -e "${GREEN}8.${NC} 恢复初始配置 (官方出厂还原 / 默认重置)"
        echo -e "${GREEN}9.${NC} 卸载 Nginx"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}========================================${NC}"
        echo -n "请选择操作 [0-9]: "
        
        read -r choice
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
                test_config
                ;;
            7)
                delete_proxy_config
                ;;
            8)
                restore_default_config
                ;;
            9)
                check_root
                uninstall_nginx
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 0-9${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行入口
main_menu
#!/bin/bash

#==============================================
# Nginx 安装与反向代理配置脚本
# 自动安装Nginx并配置WebSocket反向代理
# 适配: Debian/Ubuntu/CentOS/RHEL
#==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIGS=()

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用root权限运行${NC}"
        echo "使用: sudo bash $0"
        exit 1
    fi
}

# 确保Nginx已安装
ensure_nginx_installed() {
    if command -v nginx &> /dev/null; then
        return 0
    fi
    
    echo -e "${YELLOW}Nginx未安装，正在自动安装...${NC}"
    
    # 检测包管理器
    if command -v apt &> /dev/null; then
        apt update
        apt install -y nginx
    elif command -v yum &> /dev/null; then
        yum install -y nginx
    elif command -v dnf &> /dev/null; then
        dnf install -y nginx
    elif command -v pacman &> /dev/null; then
        pacman -S --noconfirm nginx
    else
        echo -e "${RED}错误: 未检测到支持的包管理器${NC}"
        echo -e "${YELLOW}请手动安装 Nginx${NC}"
        return 1
    fi
    
    if command -v nginx &> /dev/null; then
        echo -e "${GREEN}Nginx安装成功${NC}"
        
        # 启动Nginx
        if command -v systemctl &> /dev/null; then
            systemctl enable nginx
            systemctl start nginx
        else
            service nginx start
        fi
        
        return 0
    else
        echo -e "${RED}Nginx安装失败${NC}"
        return 1
    fi
}

# 检测包管理器
detect_package_manager() {
    if command -v apt &> /dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt install -y"
        PKG_UPDATE="apt update"
        SYSCTL_CONF="/etc/sysctl.conf"
    elif command -v yum &> /dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum makecache"
        SYSCTL_CONF="/etc/sysctl.conf"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf makecache"
        SYSCTL_CONF="/etc/sysctl.conf"
    elif command -v pacman &> /dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="pacman -S --noconfirm"
        PKG_UPDATE="pacman -Sy"
        SYSCTL_CONF="/etc/sysctl.conf"
    else
        echo -e "${RED}错误: 未检测到支持的包管理器${NC}"
        exit 1
    fi
    echo -e "${GREEN}检测到包管理器: $PKG_MGR${NC}"
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
    else
        OS="unknown"
        OS_VERSION="unknown"
    fi
    echo -e "${GREEN}系统: $OS $OS_VERSION${NC}"
}

# 安装Nginx
install_nginx() {
    echo -e "${YELLOW}安装Nginx...${NC}"
    
    # 检查是否已安装
    if command -v nginx &> /dev/null; then
        echo -e "${GREEN}Nginx已安装${NC}"
        nginx -v
        return
    fi
    
    $PKG_UPDATE
    $PKG_INSTALL nginx
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Nginx安装成功${NC}"
        nginx -v
    else
        echo -e "${RED}Nginx安装失败${NC}"
        exit 1
    fi
}

# 启动Nginx
start_nginx() {
    echo -e "${YELLOW}启动Nginx...${NC}"
    
    if command -v systemctl &> /dev/null; then
        systemctl enable nginx
        systemctl start nginx
        systemctl status nginx --no-pager
    else
        service nginx start
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Nginx启动成功${NC}"
    else
        echo -e "${YELLOW}Nginx可能已在运行${NC}"
    fi
}

# 备份配置
backup_config() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        backup="${config_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup"
        echo -e "${GREEN}已备份: $backup${NC}"
    fi
}

# 添加反向代理配置
add_proxy_config() {
    local path="$1"
    local upstream_host="$2"
    local upstream_port="$3"
    
    echo -e "${YELLOW}添加反向代理配置...${NC}"
    
    # 确定配置文件路径
    if [ -d "/etc/nginx/sites-available" ]; then
        CONFIG_FILE="/etc/nginx/sites-available/default"
        SITES_ENABLED="/etc/nginx/sites-enabled"
    else
        CONFIG_FILE="/etc/nginx/conf.d/default.conf"
        SITES_ENABLED=""
    fi
    
    # 备份配置
    backup_config "$CONFIG_FILE"
    
    # 检查是否已有相同配置
    if grep -q "location $path" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}检测到已有 $path 配置${NC}"
        read -p "是否覆盖? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "跳过"
            return
        fi
        # 删除旧配置
        sed -i "/location $path/,/}/d" "$CONFIG_FILE"
    fi
    
    # 生成配置
    cat > /tmp/proxy_config << EOF

    # 反向代理配置 - $(date)
    location $path {
        proxy_pass http://$upstream_host:$upstream_port;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 缓冲设置
        proxy_buffering off;
        proxy_cache off;
    }
EOF

    # 插入配置到server块
    if [ -f "$CONFIG_FILE" ]; then
        # 在最后一个}之前插入配置
        sed -i '/}/i\    # 反向代理配置' "$CONFIG_FILE"
        cat /tmp/proxy_config >> "$CONFIG_FILE"
    else
        # 创建新配置文件
        cat > "$CONFIG_FILE" << EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    
    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;
    
    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
        cat /tmp/proxy_config >> "$CONFIG_FILE"
        echo "}" >> "$CONFIG_FILE"
    fi
    
    rm -f /tmp/proxy_config
    
    echo -e "${GREEN}配置已添加: $path -> $upstream_host:$upstream_port${NC}"
}

# 检测Nginx配置目录
detect_nginx_config_dir() {
    if [ -d "/etc/nginx/sites-available" ]; then
        echo "debian"
    elif [ -d "/etc/nginx/conf.d" ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# 创建独立的配置文件
create_proxy_conf() {
    local path="$1"
    local upstream_host="$2"
    local upstream_port="$3"
    
    # 确保Nginx已安装
    if ! ensure_nginx_installed; then
        return 1
    fi
    
    echo -e "${YELLOW}添加反向代理配置...${NC}"
    
    local nginx_type=$(detect_nginx_config_dir)
    local CONF_FILE
    
    # 找到主配置文件 (default 或第一个配置)
    if [ "$nginx_type" = "debian" ]; then
        if [ -f /etc/nginx/sites-available/default ]; then
            CONF_FILE="/etc/nginx/sites-available/default"
        else
            CONF_FILE=$(ls /etc/nginx/sites-available/*.conf 2>/dev/null | head -1)
        fi
    else
        CONF_FILE="/etc/nginx/conf.d/default.conf"
    fi
    
    if [ -z "$CONF_FILE" ] || [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}未找到Nginx配置文件${NC}"
        return 1
    fi
    
    echo -e "${BLUE}配置文件: ${CONF_FILE}${NC}"
    
    # 备份
    backup_config "$CONF_FILE"
    
    # 检查是否已有相同的 location
    if grep -q "location $path" "$CONF_FILE" 2>/dev/null; then
        echo -e "${YELLOW}已存在 location $path，跳过${NC}"
        return 0
    fi
    
    # 生成 location 配置块到临时文件
    local tmpfile=$(mktemp)
    cat > "$tmpfile" << EOF

# 反向代理配置 - $(date)
location $path {
    proxy_pass http://$upstream_host:$upstream_port;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffering off;
    proxy_cache off;
}
EOF
    
    # 在最后一个 } 之前插入配置
    sed -i "/^}/r $tmpfile" "$CONF_FILE"
    rm -f "$tmpfile"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}配置已添加: $path -> $upstream_host:$upstream_port${NC}"
    else
        echo -e "${RED}配置添加失败${NC}"
        return 1
    fi
    
    # 确保 sites-enabled 有链接
    if [ "$nginx_type" = "debian" ] && [ -d /etc/nginx/sites-enabled ]; then
        ln -sf "$CONF_FILE" /etc/nginx/sites-enabled/
    fi
    
    echo ""
    echo -e "${YELLOW}下一步:${NC}"
    echo -e "1. 检查配置: ${GREEN}nginx -t${NC}"
    echo -e "2. 重载Nginx: ${GREEN}systemctl reload nginx${NC}"
}

# 检查配置语法
test_config() {
    echo -e "${YELLOW}检查Nginx配置语法...${NC}"
    nginx -t 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}配置语法正确${NC}"
        return 0
    else
        echo -e "${RED}配置语法错误${NC}"
        return 1
    fi
}

# 重载Nginx
reload_nginx() {
    echo -e "${YELLOW}重载Nginx配置...${NC}"
    
    if test_config; then
        if command -v systemctl &> /dev/null; then
            systemctl reload nginx
        else
            service nginx reload
        fi
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Nginx重载成功${NC}"
        else
            echo -e "${RED}Nginx重载失败${NC}"
        fi
    fi
}

# 查看当前配置
show_config() {
    echo -e "${YELLOW}=== Nginx 配置信息 ===${NC}"
    echo ""
    
    # 检查Nginx主配置
    echo -e "${BLUE}Nginx 主配置文件:${NC}"
    if [ -f /etc/nginx/nginx.conf ]; then
        echo "  /etc/nginx/nginx.conf"
        echo ""
        echo -e "${BLUE}Include 配置:${NC}"
        grep -E "include|sites-enabled|conf.d" /etc/nginx/nginx.conf 2>/dev/null | head -10
    fi
    
    echo ""
    local nginx_type=$(detect_nginx_config_dir)
    
    if [ "$nginx_type" = "debian" ]; then
        echo -e "${BLUE}=== /etc/nginx/sites-available/ ===${NC}"
        ls -la /etc/nginx/sites-available/ 2>/dev/null
        echo ""
        echo -e "${BLUE}=== /etc/nginx/sites-enabled/ ===${NC}"
        ls -la /etc/nginx/sites-enabled/ 2>/dev/null
    else
        echo -e "${BLUE}=== /etc/nginx/conf.d/ ===${NC}"
        ls -la /etc/nginx/conf.d/ 2>/dev/null
    fi
    
    echo ""
    echo -e "${YELLOW}已配置的 location:${NC}"
    if [ -d /etc/nginx/sites-enabled ]; then
        grep -rn "location\|proxy_pass" /etc/nginx/sites-enabled/ 2>/dev/null
    elif [ -d /etc/nginx/conf.d ]; then
        grep -rn "location\|proxy_pass" /etc/nginx/conf.d/ 2>/dev/null
    fi
}

# 添加自定义代理
add_custom_proxy() {
    echo -e "${YELLOW}添加自定义反向代理${NC}"
    echo ""
    echo "示例: /pyway -> 127.0.0.1:2052"
    echo ""
    
    read -p "代理路径 (如 /pyway): " proxy_path
    read -p "上游地址 (默认: 127.0.0.1): " upstream_host
    upstream_host=${upstream_host:-127.0.0.1}
    read -p "上游端口 (如 2052): " upstream_port
    
    if [ -z "$proxy_path" ] || [ -z "$upstream_port" ]; then
        echo -e "${RED}错误: 路径和端口不能为空${NC}"
        return
    fi
    
    create_proxy_conf "$proxy_path" "$upstream_host" "$upstream_port"
    reload_nginx
}

# 预设配置
preset_pyway() {
    echo -e "${YELLOW}预设: /pyway -> 127.0.0.1:2052${NC}"
    create_proxy_conf "/pyway" "127.0.0.1" "2052"
    reload_nginx
}

preset_all() {
    echo -e "${YELLOW}一键添加所有预设配置${NC}"
    create_proxy_conf "/pyway" "127.0.0.1" "2052"
    reload_nginx
}

# 删除配置
delete_proxy_config() {
    echo -e "${YELLOW}删除代理配置${NC}"
    echo ""
    
    local nginx_type=$(detect_nginx_config_dir)
    
    if [ "$nginx_type" = "debian" ]; then
        echo "已配置的代理:"
        ls /etc/nginx/sites-available/proxy_*.conf 2>/dev/null
    else
        echo "已配置的代理:"
        ls /etc/nginx/conf.d/proxy_*.conf 2>/dev/null
    fi
    
    echo ""
    read -p "输入要删除的配置文件名: " filename
    
    if [ -f "$filename" ]; then
        rm -f "$filename"
        # 同时删除sites-enabled中的链接
        rm -f "/etc/nginx/sites-enabled/$(basename $filename)" 2>/dev/null
        echo -e "${GREEN}配置已删除${NC}"
        reload_nginx
    else
        echo -e "${RED}文件不存在${NC}"
    fi
}

# 卸载Nginx
uninstall_nginx() {
    echo -e "${RED}警告: 即将卸载Nginx!${NC}"
    read -p "确认卸载? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        if command -v systemctl &> /dev/null; then
            systemctl stop nginx
            systemctl disable nginx
        fi
        $PKG_INSTALL nginx
        echo -e "${GREEN}Nginx已卸载${NC}"
    else
        echo "已取消"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}       Nginx 安装与配置工具${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo -e "${GREEN}1.${NC} 安装Nginx"
        echo -e "${GREEN}2.${NC} 启动Nginx"
        echo -e "${GREEN}3.${NC} 查看当前配置"
        echo -e "${GREEN}4.${NC} 添加反向代理"
        echo -e "${GREEN}5.${NC} 检查配置语法"
        echo -e "${GREEN}6.${NC} 重载Nginx"
        echo -e "${GREEN}7.${NC} 删除代理配置"
        echo -e "${GREEN}8.${NC} 卸载Nginx"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}========================================${NC}"
        echo -n "请选择: "
        
        read choice
        case $choice in
            1) 
                check_root
                detect_os
                detect_package_manager
                install_nginx
                start_nginx
                ;;
            2) start_nginx ;;
            3) show_config ;;
            4) 
                check_root
                add_custom_proxy
                ;;
            5) test_config ;;
            6) reload_nginx ;;
            7) 
                check_root
                delete_proxy_config
                ;;
            8)
                check_root
                uninstall_nginx
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# 运行
main_menu
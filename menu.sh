#!/bin/bash

#==============================================
# 通用菜单框架 - 兼容所有Linux发行版
# 适配: Debian, Ubuntu, CentOS, RHEL, Fedora,
#       Arch, openSUSE, Alpine 等
# 版本: 1.1.0
#==============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 清屏
clear_screen() {
    clear
}

# 等待用户输入
wait_for_user() {
    echo ""
    read -p "按回车继续..."
}

# 显示主菜单
show_main_menu() {
    clear_screen
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}         主  菜  单${NC}"
    echo -e "${CYAN}==============================${NC}"
    echo -e "${GREEN}1.${NC} 系统管理"
    echo -e "${GREEN}2.${NC} 网络管理"
    echo -e "${GREEN}3.${NC} 文件管理"
    echo -e "${GREEN}4.${NC} 服务管理"
    echo -e "${GREEN}5.${NC} 用户管理"
    echo -e "${GREEN}6.${NC} 软件管理"
    echo -e "${GREEN}7.${NC} 备份恢复"
    echo -e "${GREEN}8.${NC} 系统监控"
    echo -e "${GREEN}9.${NC} 安全管理"
    echo -e "${GREEN}10.${NC} 网络优化(BBR/TCP)"
    echo -e "${GREEN}11.${NC} Nginx配置"
    echo -e "${GREEN}12.${NC} 自定义功能"
    echo -e "${GREEN}13.${NC} 更新/检查依赖"
    echo -e "${RED}0.${NC} 退出"
    echo -e "${CYAN}==============================${NC}"
    echo -n "请选择: "
}

# 显示子菜单通用函数
show_submenu() {
    local title="$1"
    shift
    local options=("$@")
    
    clear_screen
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}         ${title}${NC}"
    echo -e "${CYAN}==============================${NC}"
    
    for i in "${!options[@]}"; do
        echo -e "${GREEN}$((i+1)).${NC} ${options[$i]}"
    done
    echo -e "${GREEN}0.${NC} 返回上级"
    echo -e "${CYAN}==============================${NC}"
    echo -n "请选择: "
}

#==============================================
# 系统管理
#==============================================
system_management() {
    while true; do
        show_submenu "系统管理" \
            "查看系统信息" \
            "查看内核版本" \
            "查看系统运行时间" \
            "查看CPU信息" \
            "查看内存信息" \
            "查看磁盘信息" \
            "重启系统" \
            "关机"
        
        read choice
        case $choice in
            1) system_info ;;
            2) kernel_version ;;
            3) uptime_info ;;
            4) cpu_info ;;
            5) memory_info ;;
            6) disk_info ;;
            7) reboot_system ;;
            8) shutdown_system ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

system_info() {
    echo -e "\n${YELLOW}=== 系统信息 ===${NC}"
    uname -a
    echo ""
    cat /etc/os-release 2>/dev/null || cat /etc/issue 2>/dev/null
    wait_for_user
}

kernel_version() {
    echo -e "\n${YELLOW}=== 内核版本 ===${NC}"
    uname -r
    uname -v
    wait_for_user
}

uptime_info() {
    echo -e "\n${YELLOW}=== 系统运行时间 ===${NC}"
    uptime
    wait_for_user
}

cpu_info() {
    echo -e "\n${YELLOW}=== CPU信息 ===${NC}"
    if [ -f /proc/cpuinfo ]; then
        grep -E "^(model name|cpu MHz|processor)" /proc/cpuinfo
    else
        sysctl -n hw.model 2>/dev/null || echo "无法获取CPU信息"
    fi
    echo -e "\nCPU核心数: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "未知")"
    wait_for_user
}

memory_info() {
    echo -e "\n${YELLOW}=== 内存信息 ===${NC}"
    if command -v free &> /dev/null; then
        free -h
    else
        cat /proc/meminfo | head -20
    fi
    wait_for_user
}

disk_info() {
    echo -e "\n${YELLOW}=== 磁盘信息 ===${NC}"
    df -h 2>/dev/null || df -k
    wait_for_user
}

reboot_system() {
    echo -e "\n${RED}警告: 即将重启系统!${NC}"
    read -p "确认重启? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        sudo reboot
    else
        echo "已取消"
        sleep 1
    fi
}

shutdown_system() {
    echo -e "\n${RED}警告: 即将关闭系统!${NC}"
    read -p "确认关机? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        sudo shutdown -h now
    else
        echo "已取消"
        sleep 1
    fi
}

#==============================================
# 网络管理
#==============================================
network_management() {
    while true; do
        show_submenu "网络管理" \
            "查看IP地址" \
            "查看网络连接" \
            "查看路由表" \
            "测试网络连通性" \
            "查看DNS信息" \
            "查看监听端口" \
            "重启网络服务"
        
        read choice
        case $choice in
            1) show_ip ;;
            2) show_connections ;;
            3) show_routing ;;
            4) test_network ;;
            5) show_dns ;;
            6) show_ports ;;
            7) restart_network ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

show_ip() {
    echo -e "\n${YELLOW}=== IP地址信息 ===${NC}"
    if command -v ip &> /dev/null; then
        ip addr show
    elif command -v ifconfig &> /dev/null; then
        ifconfig
    else
        hostname -I 2>/dev/null
    fi
    wait_for_user
}

show_connections() {
    echo -e "\n${YELLOW}=== 网络连接 ===${NC}"
    if command -v ss &> /dev/null; then
        ss -tuln
    elif command -v netstat &> /dev/null; then
        netstat -tuln
    else
        echo "需要安装 net-tools 或 iproute2"
    fi
    wait_for_user
}

show_routing() {
    echo -e "\n${YELLOW}=== 路由表 ===${NC}"
    if command -v ip &> /dev/null; then
        ip route show
    elif command -v route &> /dev/null; then
        route -n
    fi
    wait_for_user
}

test_network() {
    echo -e "\n${YELLOW}=== 网络连通性测试 ===${NC}"
    read -p "请输入目标地址 (默认: 8.8.8.8): " target
    target=${target:-8.8.8.8}
    ping -c 4 "$target"
    wait_for_user
}

show_dns() {
    echo -e "\n${YELLOW}=== DNS信息 ===${NC}"
    cat /etc/resolv.conf 2>/dev/null
    wait_for_user
}

show_ports() {
    echo -e "\n${YELLOW}=== 监听端口 ===${NC}"
    if command -v ss &> /dev/null; then
        ss -tlnp
    elif command -v netstat &> /dev/null; then
        netstat -tlnp
    fi
    wait_for_user
}

restart_network() {
    echo -e "\n${YELLOW}=== 重启网络服务 ===${NC}"
    if command -v systemctl &> /dev/null; then
        sudo systemctl restart networking 2>/dev/null || sudo systemctl restart NetworkManager 2>/dev/null
    elif command -v service &> /dev/null; then
        sudo service networking restart
    fi
    wait_for_user
}

#==============================================
# 文件管理
#==============================================
file_management() {
    while true; do
        show_submenu "文件管理" \
            "浏览目录" \
            "查找文件" \
            "查看文件内容" \
            "复制文件" \
            "移动文件" \
            "删除文件" \
            "修改权限" \
            "搜索文件内容"
        
        read choice
        case $choice in
            1) browse_directory ;;
            2) find_file ;;
            3) view_file ;;
            4) copy_file ;;
            5) move_file ;;
            6) delete_file ;;
            7) change_permissions ;;
            8) search_content ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

browse_directory() {
    read -p "请输入目录路径 (默认: 当前目录): " dir
    dir=${dir:-.}
    echo -e "\n${YELLOW}=== ${dir} ===${NC}"
    ls -lah "$dir"
    wait_for_user
}

find_file() {
    read -p "请输入要查找的文件名: " filename
    read -p "搜索路径 (默认: /): " path
    path=${path:-/}
    echo -e "\n${YELLOW}=== 搜索结果 ===${NC}"
    find "$path" -name "*$filename*" 2>/dev/null | head -50
    wait_for_user
}

view_file() {
    read -p "请输入文件路径: " filepath
    if [ -f "$filepath" ]; then
        echo -e "\n${YELLOW}=== ${filepath} ===${NC}"
        if command -v bat &> /dev/null; then
            bat "$filepath"
        else
            cat "$filepath"
        fi
    else
        echo "文件不存在"
    fi
    wait_for_user
}

copy_file() {
    read -p "源文件: " src
    read -p "目标位置: " dest
    cp -i "$src" "$dest"
    wait_for_user
}

move_file() {
    read -p "源文件: " src
    read -p "目标位置: " dest
    mv -i "$src" "$dest"
    wait_for_user
}

delete_file() {
    read -p "要删除的文件: " filepath
    echo -e "${RED}警告: 将删除 ${filepath}${NC}"
    read -p "确认删除? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rm -i "$filepath"
    else
        echo "已取消"
    fi
    wait_for_user
}

change_permissions() {
    read -p "文件路径: " filepath
    read -p "权限 (如 755, 644): " perms
    chmod "$perms" "$filepath"
    wait_for_user
}

search_content() {
    read -p "搜索关键词: " keyword
    read -p "搜索路径: " path
    echo -e "\n${YELLOW}=== 搜索结果 ===${NC}"
    grep -rn "$keyword" "$path" 2>/dev/null | head -50
    wait_for_user
}

#==============================================
# 服务管理
#==============================================
service_management() {
    while true; do
        show_submenu "服务管理" \
            "查看所有服务" \
            "查看服务状态" \
            "启动服务" \
            "停止服务" \
            "重启服务" \
            "开机自启" \
            "禁用服务"
        
        read choice
        case $choice in
            1) list_services ;;
            2) check_service ;;
            3) start_service ;;
            4) stop_service ;;
            5) restart_service ;;
            6) enable_service ;;
            7) disable_service ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

list_services() {
    echo -e "\n${YELLOW}=== 运行中的服务 ===${NC}"
    systemctl list-units --type=service --state=running 2>/dev/null || service --status-all 2>/dev/null
    wait_for_user
}

check_service() {
    read -p "服务名称: " service_name
    echo -e "\n${YELLOW}=== ${service_name} 状态 ===${NC}"
    systemctl status "$service_name" 2>/dev/null || service "$service_name" status 2>/dev/null
    wait_for_user
}

start_service() {
    read -p "服务名称: " service_name
    sudo systemctl start "$service_name" 2>/dev/null || sudo service "$service_name" start 2>/dev/null
    wait_for_user
}

stop_service() {
    read -p "服务名称: " service_name
    sudo systemctl stop "$service_name" 2>/dev/null || sudo service "$service_name" stop 2>/dev/null
    wait_for_user
}

restart_service() {
    read -p "服务名称: " service_name
    sudo systemctl restart "$service_name" 2>/dev/null || sudo service "$service_name" restart 2>/dev/null
    wait_for_user
}

enable_service() {
    read -p "服务名称: " service_name
    sudo systemctl enable "$service_name" 2>/dev/null
    wait_for_user
}

disable_service() {
    read -p "服务名称: " service_name
    sudo systemctl disable "$service_name" 2>/dev/null
    wait_for_user
}

#==============================================
# 用户管理
#==============================================
user_management() {
    while true; do
        show_submenu "用户管理" \
            "查看所有用户" \
            "添加用户" \
            "删除用户" \
            "修改密码" \
            "查看用户组" \
            "添加用户组" \
            "切换用户"
        
        read choice
        case $choice in
            1) list_users ;;
            2) add_user ;;
            3) delete_user ;;
            4) change_password ;;
            5) list_groups ;;
            6) add_group ;;
            7) switch_user ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

list_users() {
    echo -e "\n${YELLOW}=== 用户列表 ===${NC}"
    cat /etc/passwd | grep -v "nologin\|false" | cut -d: -f1,3,6
    wait_for_user
}

add_user() {
    read -p "新用户名: " username
    sudo useradd -m "$username"
    echo "用户 $username 已创建"
    wait_for_user
}

delete_user() {
    read -p "要删除的用户名: " username
    sudo userdel -r "$username"
    wait_for_user
}

change_password() {
    read -p "用户名: " username
    sudo passwd "$username"
    wait_for_user
}

list_groups() {
    echo -e "\n${YELLOW}=== 用户组 ===${NC}"
    cat /etc/group | cut -d: -f1
    wait_for_user
}

add_group() {
    read -p "新组名: " groupname
    sudo groupadd "$groupname"
    wait_for_user
}

switch_user() {
    read -p "切换到用户: " username
    sudo su - "$username"
}

#==============================================
# 软件管理
#==============================================
software_management() {
    # 检测包管理器
    if command -v apt &> /dev/null; then
        pkg_manager="apt"
    elif command -v yum &> /dev/null; then
        pkg_manager="yum"
    elif command -v dnf &> /dev/null; then
        pkg_manager="dnf"
    elif command -v pacman &> /dev/null; then
        pkg_manager="pacman"
    elif command -v zypper &> /dev/null; then
        pkg_manager="zypper"
    else
        pkg_manager="unknown"
    fi
    
    while true; do
        show_submenu "软件管理 (${pkg_manager})" \
            "更新软件源" \
            "升级所有软件" \
            "安装软件" \
            "卸载软件" \
            "搜索软件" \
            "查看已安装软件"
        
        read choice
        case $choice in
            1) update_sources ;;
            2) upgrade_all ;;
            3) install_package ;;
            4) remove_package ;;
            5) search_package ;;
            6) list_installed ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

update_sources() {
    echo -e "\n${YELLOW}=== 更新软件源 ===${NC}"
    case $pkg_manager in
        apt) sudo apt update ;;
        yum) sudo yum makecache ;;
        dnf) sudo dnf makecache ;;
        pacman) sudo pacman -Sy ;;
        zypper) sudo zypper refresh ;;
    esac
    wait_for_user
}

upgrade_all() {
    echo -e "\n${YELLOW}=== 升级所有软件 ===${NC}"
    case $pkg_manager in
        apt) sudo apt upgrade -y ;;
        yum) sudo yum update -y ;;
        dnf) sudo dnf upgrade -y ;;
        pacman) sudo pacman -Syu ;;
        zypper) sudo zypper update -y ;;
    esac
    wait_for_user
}

install_package() {
    read -p "软件包名称: " package
    case $pkg_manager in
        apt) sudo apt install -y "$package" ;;
        yum) sudo yum install -y "$package" ;;
        dnf) sudo dnf install -y "$package" ;;
        pacman) sudo pacman -S --noconfirm "$package" ;;
        zypper) sudo zypper install -y "$package" ;;
    esac
    wait_for_user
}

remove_package() {
    read -p "软件包名称: " package
    case $pkg_manager in
        apt) sudo apt remove -y "$package" ;;
        yum) sudo yum remove -y "$package" ;;
        dnf) sudo dnf remove -y "$package" ;;
        pacman) sudo pacman -R --noconfirm "$package" ;;
        zypper) sudo zypper remove -y "$package" ;;
    esac
    wait_for_user
}

search_package() {
    read -p "搜索关键词: " keyword
    case $pkg_manager in
        apt) apt search "$keyword" ;;
        yum) yum search "$keyword" ;;
        dnf) dnf search "$keyword" ;;
        pacman) pacman -Ss "$keyword" ;;
        zypper) zypper search "$keyword" ;;
    esac
    wait_for_user
}

list_installed() {
    echo -e "\n${YELLOW}=== 已安装软件 ===${NC}"
    case $pkg_manager in
        apt) dpkg -l | grep "^ii" | awk '{print $2}' ;;
        yum) yum list installed ;;
        dnf) dnf list installed ;;
        pacman) pacman -Q ;;
        zypper) zypper packages --installed ;;
    esac | head -50
    wait_for_user
}

#==============================================
# 备份恢复
#==============================================
backup_restore() {
    while true; do
        show_submenu "备份恢复" \
            "备份文件" \
            "备份目录" \
            "恢复文件" \
            "创建快照"
        
        read choice
        case $choice in
            1) backup_file ;;
            2) backup_directory ;;
            3) restore_file ;;
            4) create_snapshot ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

backup_file() {
    read -p "要备份的文件: " src
    read -p "备份到: " dest
    cp -v "$src" "$dest.bak.$(date +%Y%m%d_%H%M%S)"
    wait_for_user
}

backup_directory() {
    read -p "要备份的目录: " src
    read -p "备份文件名: " dest
    tar -czf "$dest.tar.gz" "$src"
    wait_for_user
}

restore_file() {
    read -p "备份文件: " src
    read -p "恢复到: " dest
    tar -xzf "$src" -C "$dest"
    wait_for_user
}

create_snapshot() {
    read -p "快照名称: " name
    echo "创建快照: $name $(date)"
    wait_for_user
}

#==============================================
# 系统监控
#==============================================
system_monitor() {
    while true; do
        show_submenu "系统监控" \
            "实时监控进程" \
            "查看CPU使用率" \
            "查看内存使用" \
            "查看磁盘IO" \
            "查看网络流量" \
            "查看系统日志"
        
        read choice
        case $choice in
            1) watch_processes ;;
            2) watch_cpu ;;
            3) watch_memory ;;
            4) watch_disk_io ;;
            5) watch_network ;;
            6) view_logs ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

watch_processes() {
    echo -e "\n${YELLOW}=== 实时进程监控 (按Ctrl+C退出) ===${NC}"
    top
    wait_for_user
}

watch_cpu() {
    echo -e "\n${YELLOW}=== CPU使用率 ===${NC}"
    mpstat 2>/dev/null || (echo "每2秒采样一次:"; for i in {1..5}; do echo "采样$i:"; top -bn1 | head -5; sleep 2; done)
    wait_for_user
}

watch_memory() {
    echo -e "\n${YELLOW}=== 内存使用 ===${NC}"
    free -h
    echo ""
    vmstat 2>/dev/null || echo "vmstat不可用"
    wait_for_user
}

watch_disk_io() {
    echo -e "\n${YELLOW}=== 磁盘IO ===${NC}"
    iostat 2>/dev/null || (echo "磁盘使用:"; df -h)
    wait_for_user
}

watch_network() {
    echo -e "\n${YELLOW}=== 网络流量 ===${NC}"
    if command -v ifstat &> /dev/null; then
        ifstat
    else
        cat /proc/net/dev
    fi
    wait_for_user
}

view_logs() {
    echo -e "\n${YELLOW}=== 系统日志 ===${NC}"
    if command -v journalctl &> /dev/null; then
        journalctl -n 50
    else
        tail -50 /var/log/syslog 2>/dev/null || tail -50 /var/log/messages 2>/dev/null
    fi
    wait_for_user
}

#==============================================
# 安全管理
#==============================================
security_management() {
    while true; do
        show_submenu "安全管理" \
            "查看防火墙规则" \
            "开放端口" \
            "关闭端口" \
            "查看登录记录" \
            "查看SSH配置" \
            "检查系统更新"
        
        read choice
        case $choice in
            1) view_firewall ;;
            2) open_port ;;
            3) close_port ;;
            4) view_login_records ;;
            5) view_ssh_config ;;
            6) check_updates ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

view_firewall() {
    echo -e "\n${YELLOW}=== 防火墙规则 ===${NC}"
    if command -v ufw &> /dev/null; then
        sudo ufw status verbose
    elif command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --list-all
    elif command -v iptables &> /dev/null; then
        sudo iptables -L -n
    else
        echo "未检测到防火墙工具"
    fi
    wait_for_user
}

open_port() {
    read -p "端口号: " port
    if command -v ufw &> /dev/null; then
        sudo ufw allow "$port"
    elif command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --add-port="$port/tcp"
    fi
    wait_for_user
}

close_port() {
    read -p "端口号: " port
    if command -v ufw &> /dev/null; then
        sudo ufw deny "$port"
    elif command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --remove-port="$port/tcp"
    fi
    wait_for_user
}

view_login_records() {
    echo -e "\n${YELLOW}=== 最近登录记录 ===${NC}"
    last -20
    wait_for_user
}

view_ssh_config() {
    echo -e "\n${YELLOW}=== SSH配置 ===${NC}"
    cat /etc/ssh/sshd_config 2>/dev/null | grep -v "^#" | grep -v "^$"
    wait_for_user
}

check_updates() {
    echo -e "\n${YELLOW}=== 检查系统更新 ===${NC}"
    if command -v apt &> /dev/null; then
        sudo apt list --upgradable 2>/dev/null
    elif command -v yum &> /dev/null; then
        sudo yum check-update
    elif command -v dnf &> /dev/null; then
        sudo dnf check-update
    fi
    wait_for_user
}

#==============================================
# 自动下载功能
#==============================================
GITHUB_RAW="https://raw.githubusercontent.com/CFM503/sh/master"

# 下载文件
download_file() {
    local filename="$1"
    local url="${GITHUB_RAW}/${filename}"
    local dest="${BASH_SOURCE[0]%/*}/${filename}"
    
    echo -e "${YELLOW}正在下载 ${filename}...${NC}"
    echo -e "${BLUE}URL: ${url}${NC}"
    echo -e "${BLUE}目标: ${dest}${NC}"
    
    local download_success=false
    
    # 尝试使用curl
    if command -v curl &> /dev/null; then
        echo -e "${BLUE}使用 curl 下载...${NC}"
        curl -L --connect-timeout 10 --max-time 30 -o "$dest" "$url"
        if [ $? -eq 0 ] && [ -f "$dest" ] && [ -s "$dest" ]; then
            download_success=true
        fi
    fi
    
    # 如果curl失败，尝试wget
    if [ "$download_success" = false ] && command -v wget &> /dev/null; then
        echo -e "${BLUE}使用 wget 下载...${NC}"
        wget --timeout=10 -O "$dest" "$url"
        if [ $? -eq 0 ] && [ -f "$dest" ] && [ -s "$dest" ]; then
            download_success=true
        fi
    fi
    
    # 如果还是失败，尝试git clone
    if [ "$download_success" = false ] && command -v git &> /dev/null; then
        echo -e "${BLUE}使用 git 下载...${NC}"
        local temp_dir="/tmp/sh_download_$$"
        rm -rf "$temp_dir"
        git clone --depth 1 https://github.com/CFM503/sh.git "$temp_dir" 2>/dev/null
        if [ -f "$temp_dir/$filename" ]; then
            cp "$temp_dir/$filename" "$dest"
            rm -rf "$temp_dir"
            if [ -f "$dest" ] && [ -s "$dest" ]; then
                download_success=true
            fi
        else
            rm -rf "$temp_dir"
        fi
    fi
    
    if [ "$download_success" = true ]; then
        echo -e "${GREEN}下载成功: ${filename}${NC}"
        chmod +x "$dest" 2>/dev/null
        return 0
    else
        echo -e "${RED}下载失败: ${filename}${NC}"
        echo -e "${YELLOW}请手动下载: ${url}${NC}"
        echo -e "${YELLOW}保存到: ${dest}${NC}"
        return 1
    fi
}

# 检查并下载依赖
check_and_download() {
    local filename="$1"
    local filepath="${BASH_SOURCE[0]%/*}/${filename}"
    
    if [ ! -f "$filepath" ]; then
        echo -e "${YELLOW}未找到 ${filename}，正在自动下载...${NC}"
        download_file "$filename"
    fi
    
    if [ -f "$filepath" ]; then
        return 0
    else
        return 1
    fi
}

#==============================================
# 网络优化
#==============================================
network_optimize() {
    if check_and_download "network_optimize.sh"; then
        bash "${BASH_SOURCE[0]%/*}/network_optimize.sh"
    else
        echo -e "${RED}错误: 无法下载 network_optimize.sh${NC}"
        echo -e "${YELLOW}请手动下载: ${GITHUB_RAW}/network_optimize.sh${NC}"
    fi
}

#==============================================
# Nginx配置
#==============================================
nginx_setup() {
    if check_and_download "nginx_setup.sh"; then
        bash "${BASH_SOURCE[0]%/*}/nginx_setup.sh"
    else
        echo -e "${RED}错误: 无法下载 nginx_setup.sh${NC}"
        echo -e "${YELLOW}请手动下载: ${GITHUB_RAW}/nginx_setup.sh${NC}"
    fi
}

#==============================================
# 自定义功能 (您可以在这里添加)
#==============================================
custom_functions() {
    while true; do
        show_submenu "自定义功能" \
            "功能1" \
            "功能2" \
            "功能3"
        
        read choice
        case $choice in
            1) custom_func1 ;;
            2) custom_func2 ;;
            3) custom_func3 ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

custom_func1() {
    echo "功能1 - 在这里添加您的代码"
    wait_for_user
}

custom_func2() {
    echo "功能2 - 在这里添加您的代码"
    wait_for_user
}

custom_func3() {
    echo "功能3 - 在这里添加您的代码"
    wait_for_user
}

#==============================================
# 更新/检查依赖
#==============================================
update_dependencies() {
    while true; do
        show_submenu "更新/检查依赖" \
            "检查所有依赖" \
            "更新 network_optimize.sh" \
            "更新 nginx_setup.sh" \
            "更新所有依赖" \
            "删除所有依赖"
        
        read choice
        case $choice in
            1) check_all_dependencies ;;
            2) 
                download_file "network_optimize.sh"
                wait_for_user
                ;;
            3) 
                download_file "nginx_setup.sh"
                wait_for_user
                ;;
            4) update_all_dependencies ;;
            5) delete_all_dependencies ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

check_all_dependencies() {
    echo -e "\n${YELLOW}=== 依赖检查 ===${NC}"
    
    local files=("network_optimize.sh" "nginx_setup.sh")
    local all_ok=true
    
    for file in "${files[@]}"; do
        local filepath="${BASH_SOURCE[0]%/*}/${file}"
        if [ -f "$filepath" ]; then
            echo -e "${GREEN}✓ ${file} - 已存在${NC}"
        else
            echo -e "${RED}✗ ${file} - 缺少${NC}"
            all_ok=false
        fi
    done
    
    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}所有依赖文件已就绪${NC}"
    else
        echo -e "${YELLOW}发现缺少的依赖文件${NC}"
        read -p "是否立即下载? (Y/n): " download_now
        if [ "$download_now" != "n" ] && [ "$download_now" != "N" ]; then
            update_all_dependencies
        fi
    fi
    wait_for_user
}

update_all_dependencies() {
    echo -e "\n${YELLOW}=== 更新所有依赖 ===${NC}"
    
    download_file "network_optimize.sh"
    download_file "nginx_setup.sh"
    
    echo -e "\n${GREEN}更新完成!${NC}"
    wait_for_user
}

delete_all_dependencies() {
    echo -e "\n${RED}=== 删除所有依赖 ===${NC}"
    echo -e "${RED}警告: 将删除所有子菜单文件!${NC}"
    
    read -p "确认删除? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        local files=("network_optimize.sh" "nginx_setup.sh")
        for file in "${files[@]}"; do
            local filepath="${BASH_SOURCE[0]%/*}/${file}"
            if [ -f "$filepath" ]; then
                rm -f "$filepath"
                echo -e "${GREEN}已删除: ${file}${NC}"
            fi
        done
        echo -e "${GREEN}删除完成!${NC}"
    else
        echo "已取消"
    fi
    wait_for_user
}

#==============================================
# 主程序入口
#==============================================
main() {
    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then
        echo "注意: 部分功能需要root权限"
        sleep 1
    fi
    
    # 检查依赖文件
    echo -e "${BLUE}检查依赖文件...${NC}"
    local missing=()
    [ ! -f "${BASH_SOURCE[0]%/*}/network_optimize.sh" ] && missing+=("network_optimize.sh")
    [ ! -f "${BASH_SOURCE[0]%/*}/nginx_setup.sh" ] && missing+=("nginx_setup.sh")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}发现缺少 ${#missing[@]} 个文件: ${missing[*]}${NC}"
        read -p "是否自动下载? (Y/n): " auto_download
        if [ "$auto_download" != "n" ] && [ "$auto_download" != "N" ]; then
            for file in "${missing[@]}"; do
                download_file "$file"
            done
            echo -e "${GREEN}下载完成!${NC}"
            sleep 1
        fi
    else
        echo -e "${GREEN}所有依赖文件已就绪${NC}"
        sleep 1
    fi
    
    # 主循环
    while true; do
        show_main_menu
        read choice
        case $choice in
            1) system_management ;;
            2) network_management ;;
            3) file_management ;;
            4) service_management ;;
            5) user_management ;;
            6) software_management ;;
            7) backup_restore ;;
            8) system_monitor ;;
            9) security_management ;;
            10) network_optimize ;;
            11) nginx_setup ;;
            12) custom_functions ;;
            13) update_dependencies ;;
            0) 
                echo -e "\n${GREEN}再见!${NC}"
                exit 0
                ;;
            *) 
                echo "无效选择，请重试"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
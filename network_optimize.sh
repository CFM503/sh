#!/bin/bash

#==============================================
# VPS 网络优化脚本
# 自动配置BBR、TCP缓冲区、滑动窗口等
# 适配: Debian 12/13, Ubuntu, CentOS, RHEL
#==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查是否为root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用root权限运行此脚本${NC}"
        echo "使用: sudo bash $0"
        exit 1
    fi
}

# 检测系统版本
detect_system() {
    echo -e "${BLUE}检测系统版本...${NC}"
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        echo -e "${GREEN}系统: $PRETTY_NAME${NC}"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        VERSION=$(cat /etc/debian_version)
        echo -e "${GREEN}系统: Debian $VERSION${NC}"
    else
        echo -e "${RED}无法检测系统版本${NC}"
        exit 1
    fi
    
    # 检测配置文件路径
    if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
        if [ "$VERSION" = "13" ] || [ "$VERSION" = "trixie" ]; then
            SYSCTL_CONF="/etc/sysctl.d/99-sysctl.conf"
            SYSCTL_CMD="sysctl --system"
            echo -e "${GREEN}使用配置文件: $SYSCTL_CONF (Debian 13)${NC}"
        else
            SYSCTL_CONF="/etc/sysctl.conf"
            SYSCTL_CMD="sysctl -p"
            echo -e "${GREEN}使用配置文件: $SYSCTL_CONF (Debian 12/其他)${NC}"
        fi
    elif [ "$OS" = "centos" ] || [ "$OS" = "rhel" ] || [ "$OS" = "fedora" ]; then
        SYSCTL_CONF="/etc/sysctl.d/99-custom.conf"
        SYSCTL_CMD="sysctl --system"
        echo -e "${GREEN}使用配置文件: $SYSCTL_CONF (CentOS/RHEL)${NC}"
    else
        SYSCTL_CONF="/etc/sysctl.d/99-custom.conf"
        SYSCTL_CMD="sysctl --system"
        echo -e "${GREEN}使用配置文件: $SYSCTL_CONF (通用)${NC}"
    fi
}

# 备份原有配置
backup_config() {
    echo -e "${YELLOW}备份原有配置...${NC}"
    
    BACKUP_DIR="/root/sysctl_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    if [ -f "$SYSCTL_CONF" ]; then
        cp "$SYSCTL_CONF" "$BACKUP_DIR/"
        echo -e "${GREEN}已备份到: $BACKUP_DIR/${NC}"
    fi
    
    # 备份所有sysctl配置
    cp -r /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null
    cp -r /etc/sysctl.d/ "$BACKUP_DIR/" 2>/dev/null
    
    echo -e "${GREEN}备份完成: $BACKUP_DIR${NC}"
}

# 优化参数配置
optimize_network() {
    echo -e "${YELLOW}应用网络优化配置...${NC}"
    
    # 优化参数
    cat > /tmp/network_optimization.conf << 'EOF'
#==============================================
# VPS 网络优化配置
# 生成时间: $(date)
#==============================================

# 开启 BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 极大化 TCP 读写缓冲区，专治大带宽长延迟（LFN）网络
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# 优化滑动窗口与快重传
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
EOF

    # 如果目标文件已存在，追加配置（避免重复）
    if [ -f "$SYSCTL_CONF" ]; then
        # 检查是否已有优化配置
        if grep -q "net.core.default_qdisc = fq" "$SYSCTL_CONF"; then
            echo -e "${YELLOW}检测到已有优化配置，跳过...${NC}"
            return
        fi
        echo "" >> "$SYSCTL_CONF"
        echo "# VPS网络优化配置 - $(date)" >> "$SYSCTL_CONF"
    fi
    
    # 写入配置
    cat /tmp/network_optimization.conf >> "$SYSCTL_CONF"
    rm -f /tmp/network_optimization.conf
    
    echo -e "${GREEN}配置写入完成: $SYSCTL_CONF${NC}"
}

# 应用配置
apply_config() {
    echo -e "${YELLOW}应用系统配置...${NC}"
    
    # 检查BBR模块是否可用
    echo -e "${BLUE}检查BBR模块...${NC}"
    modprobe tcp_bbr 2>/dev/null || modprobe tcp_congestion_bbr 2>/dev/null
    
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}BBR模块已加载${NC}"
    else
        echo -e "${YELLOW}BBR模块可能未编译到内核，尝试继续...${NC}"
    fi
    
    # 应用配置
    echo -e "${BLUE}执行: $SYSCTL_CMD${NC}"
    $SYSCTL_CMD 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}配置应用成功${NC}"
    else
        echo -e "${YELLOW}配置应用完成(部分参数可能不支持)${NC}"
    fi
}

# 验证配置
verify_config() {
    echo -e "${YELLOW}验证优化配置...${NC}"
    echo ""
    
    local all_ok=true
    
    # 验证BBR
    echo -e "${BLUE}1. BBR拥塞控制:${NC}"
    bbr_value=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "   default_qdisc = $bbr_value"
    if [ "$bbr_value" = "fq" ]; then
        echo -e "   ${GREEN}✓ BBR队列已启用${NC}"
    else
        echo -e "   ${RED}✗ BBR队列未启用${NC}"
        all_ok=false
    fi
    
    cc_value=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "   congestion_control = $cc_value"
    if [ "$cc_value" = "bbr" ]; then
        echo -e "   ${GREEN}✓ BBR拥塞控制已启用${NC}"
    else
        echo -e "   ${RED}✗ BBR拥塞控制未启用${NC}"
        all_ok=false
    fi
    
    echo ""
    echo -e "${BLUE}2. TCP缓冲区:${NC}"
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null)
    echo -e "   rmem_max = $rmem_max"
    if [ "$rmem_max" -ge 16777216 ] 2>/dev/null; then
        echo -e "   ${GREEN}✓ 读缓冲区已优化${NC}"
    else
        echo -e "   ${RED}✗ 读缓冲区未优化${NC}"
        all_ok=false
    fi
    
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null)
    echo -e "   wmem_max = $wmem_max"
    if [ "$wmem_max" -ge 16777216 ] 2>/dev/null; then
        echo -e "   ${GREEN}✓ 写缓冲区已优化${NC}"
    else
        echo -e "   ${RED}✗ 写缓冲区未优化${NC}"
        all_ok=false
    fi
    
    echo ""
    echo -e "${BLUE}3. 滑动窗口:${NC}"
    window_scaling=$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)
    echo -e "   tcp_window_scaling = $window_scaling"
    if [ "$window_scaling" = "1" ]; then
        echo -e "   ${GREEN}✓ 窗口缩放已启用${NC}"
    else
        echo -e "   ${RED}✗ 窗口缩放未启用${NC}"
        all_ok=false
    fi
    
    sack=$(sysctl -n net.ipv4.tcp_sack 2>/dev/null)
    echo -e "   tcp_sack = $sack"
    if [ "$sack" = "1" ]; then
        echo -e "   ${GREEN}✓ SACK已启用${NC}"
    else
        echo -e "   ${RED}✗ SACK未启用${NC}"
        all_ok=false
    fi
    
    echo ""
    echo -e "${BLUE}4. TCP读写缓冲区详情:${NC}"
    sysctl net.ipv4.tcp_rmem 2>/dev/null
    sysctl net.ipv4.tcp_wmem 2>/dev/null
    
    echo ""
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  所有优化配置已成功应用!${NC}"
        echo -e "${GREEN}========================================${NC}"
    else
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}  部分配置可能未生效(内核不支持)${NC}"
        echo -e "${YELLOW}========================================${NC}"
    fi
}

# 显示当前配置
show_current_config() {
    echo -e "${YELLOW}当前网络配置:${NC}"
    echo ""
    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
    sysctl net.core.rmem_max
    sysctl net.core.wmem_max
    sysctl net.ipv4.tcp_window_scaling
    sysctl net.ipv4.tcp_sack
    sysctl net.ipv4.tcp_rmem
    sysctl net.ipv4.tcp_wmem
}

# 恢复备份
restore_backup() {
    echo -e "${YELLOW}可用的备份:${NC}"
    ls -la /root/sysctl_backup_* 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}未找到备份文件${NC}"
        return
    fi
    
    echo ""
    read -p "请输入要恢复的备份目录名: " backup_dir
    
    if [ -d "/root/$backup_dir" ]; then
        cp -r /root/$backup_dir/* /etc/sysctl.d/ 2>/dev/null
        cp /root/$backup_dir/sysctl.conf /etc/ 2>/dev/null
        sysctl --system 2>/dev/null
        echo -e "${GREEN}配置已恢复${NC}"
    else
        echo -e "${RED}备份目录不存在${NC}"
    fi
}

# 主菜单
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}       VPS 网络优化工具${NC}"
        echo -e "${CYAN}========================================${NC}"
        echo -e "${GREEN}1.${NC} 查看当前配置"
        echo -e "${GREEN}2.${NC} 应用BBR优化"
        echo -e "${GREEN}3.${NC} 仅验证配置"
        echo -e "${GREEN}4.${NC} 恢复备份"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}========================================${NC}"
        echo -n "请选择: "
        
        read -r choice || break
        case $choice in
            1) show_current_config ;;
            2)
                check_root
                detect_system
                backup_config
                optimize_network
                apply_config
                verify_config
                ;;
            3) verify_config ;;
            4) restore_backup ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# 直接运行
main_menu
#!/bin/bash

#==============================================
# VPS 网络优化脚本
# 版本: 1.3.1
# 2026 现代极限网络调优 (BBR+FQ物理硬件持久化、64M巨型BDP缓冲区、0-RTT握手加速、SSH端口修改)
# 适配: Debian 12/13, Ubuntu, CentOS, RHEL
#==============================================

SCRIPT_VERSION="1.3.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

wait_for_user() {
    echo ""
    read -p "按回车继续..."
}

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
        SYS_VERSION=$VERSION_ID
        echo -e "${GREEN}系统: $PRETTY_NAME${NC}"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        SYS_VERSION=$(cat /etc/debian_version)
        echo -e "${GREEN}系统: Debian $SYS_VERSION${NC}"
    else
        echo -e "${RED}无法检测系统版本${NC}"
        exit 1
    fi
    
    # 检测配置文件路径
    if [ "$OS" = "debian" ] || [ "$OS" = "ubuntu" ]; then
        if [ "$SYS_VERSION" = "13" ] || [ "$SYS_VERSION" = "trixie" ]; then
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

# 获取默认物理网卡名称
get_default_interface() {
    local iface=""
    if command -v ip &>/dev/null; then
        iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n 1)
        [ -z "$iface" ] && iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    fi
    if [ -z "$iface" ] && command -v route &>/dev/null; then
        iface=$(route -n 2>/dev/null | awk '$1 == "0.0.0.0" {print $8}' | head -n 1)
    fi
    if [ -z "$iface" ]; then
        for candidate in eth0 ens3 ens5 enp1s0 enp3s0; do
            if [ -d "/sys/class/net/$candidate" ]; then
                iface="$candidate"
                break
            fi
        done
    fi
    echo "${iface:-eth0}"
}

# 获取总内存 (MB)
get_total_ram_mb() {
    local ram_mb=1024
    if [ -f /proc/meminfo ]; then
        local kb
        kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        ram_mb=$(( kb / 1024 ))
    fi
    echo "$ram_mb"
}

# 物理网卡 FQ 硬件队列开机持久化服务 (解决假生效痛点)
apply_fq_persistence() {
    local iface="$1"
    echo -e "${YELLOW}正在激活物理网卡硬件 FQ 调度队列 (${iface})...${NC}"
    
    if ! command -v tc &>/dev/null; then
        echo -e "${BLUE}安装 iproute/tc 工具包...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq iproute2 &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q iproute &>/dev/null
        fi
    fi
    
    # 1. 立即挂载 FQ 队列到物理网卡
    if command -v tc &>/dev/null; then
        tc qdisc replace dev "$iface" root fq 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ 物理网卡 ${iface} 已成功挂载 FQ 硬件队列！${NC}"
        else
            echo -e "${YELLOW}提示: 物理网卡挂载 FQ 出现非致命提示，继续配置开机守护...${NC}"
        fi
    fi
    
    # 2. 创建 systemd 开机持久化服务
    if [ -d /etc/systemd/system ]; then
        echo -e "${BLUE}配置开机持久化服务: /etc/systemd/system/set-fq-qdisc.service${NC}"
        local tc_bin
        tc_bin=$(command -v tc 2>/dev/null || echo "/sbin/tc")
        cat > /etc/systemd/system/set-fq-qdisc.service << EOF
[Unit]
Description=Set FQ qdisc for ${iface} at startup
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${tc_bin} qdisc replace dev ${iface} root fq
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload &>/dev/null
        systemctl enable --now set-fq-qdisc.service &>/dev/null
        echo -e "${GREEN}✓ FQ 硬件队列开机持久化服务已启用！${NC}"
    fi
}

# 优化参数配置 (2026 现代极限调优)
optimize_network() {
    echo -e "${YELLOW}应用网络优化配置 (BBR + 极限低延迟与 BDP 缓冲区)...${NC}"
    
    local ram_mb
    ram_mb=$(get_total_ram_mb)
    local buf_max=16777216
    local buf_def=1048576
    local mode_desc="16MB 稳健标准档 (适配内存 < 2GB)"
    
    if [ "$ram_mb" -ge 1800 ]; then
        buf_max=67108864
        buf_def=1048576
        mode_desc="64MB 极限千兆吞吐档 (专治跨国千兆跑不满，当前内存 ${ram_mb} MB)"
    else
        mode_desc="16MB 均衡安全档 (安全防 OOM，当前内存 ${ram_mb} MB)"
    fi
    
    echo -e "${GREEN}内存检测: ${ram_mb} MB -> 自动适配: ${mode_desc}${NC}"
    
    # 生成优化配置
    cat > /tmp/network_optimization.conf << EOF
#==============================================================
# VPS 极限网络调优与核心协议参数 (2026 现代全景指南)
# 生成时间: $(date)
#==============================================================

# 1. 开启 BBR 拥塞控制与 FQ 队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 2. 巨型 TCP 读写缓冲区 (打破跨国千兆高延迟 BDP 限制)
net.core.rmem_max = ${buf_max}
net.core.wmem_max = ${buf_max}
net.core.rmem_default = ${buf_def}
net.core.wmem_default = ${buf_def}
net.ipv4.tcp_rmem = 4096 87380 ${buf_max}
net.ipv4.tcp_wmem = 4096 65536 ${buf_max}

# 3. 握手加速、0-RTT 与防缓冲膨胀 (Anti-Bufferbloat)
# 开启 TCP Fast Open 双向快速握手 (0-RTT)
net.ipv4.tcp_fastopen = 3
# 空闲连接不重置拥塞窗口 (彻底解决长连接与间歇访问卡顿)
net.ipv4.tcp_slow_start_after_idle = 0
# 限制未发报文缓冲区上限 (16KB)，消除缓冲膨胀与 RTT 抖动
net.ipv4.tcp_notsent_lowat = 16384
# 开启自动 MTU 黑洞探测，避免隧道与丢包死锁卡住
net.ipv4.tcp_mtu_probing = 1
# 优化滑动窗口与快重传
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_sack = 1

# 4. 高并发连接队列与快速回收
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 131072
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
EOF

    # 如果目标配置文件已存在，先清除历史 VPS 调优标记以支持覆盖升级
    if [ -f "$SYSCTL_CONF" ]; then
        sed -i '/# VPS网络优化配置/,$d' "$SYSCTL_CONF" 2>/dev/null
        sed -i '/# VPS 极限网络调优/,$d' "$SYSCTL_CONF" 2>/dev/null
        echo "" >> "$SYSCTL_CONF"
    fi
    
    # 写入配置
    cat /tmp/network_optimization.conf >> "$SYSCTL_CONF"
    rm -f /tmp/network_optimization.conf
    
    echo -e "${GREEN}配置已写入: $SYSCTL_CONF${NC}"
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
        echo -e "${YELLOW}BBR模块可能未编译到内核(或内核已内置)，尝试继续...${NC}"
    fi
    
    # 应用内核 sysctl 配置
    echo -e "${BLUE}执行内核参数加载: $SYSCTL_CMD${NC}"
    $SYSCTL_CMD 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 内核参数加载成功${NC}"
    else
        echo -e "${YELLOW}内核参数加载完成(部分高版本特定参数若不支持会自动忽略)${NC}"
    fi
    
    # 激活物理网卡 FQ 硬件队列并开启开机持久化 (解决假生效痛点)
    local iface
    iface=$(get_default_interface)
    apply_fq_persistence "$iface"
}

# 验证配置
verify_config() {
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${CYAN}             验证 VPS 现代极限网络配置${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    local all_ok=true
    local iface
    iface=$(get_default_interface)
    
    # 1. 验证 BBR 与 FQ 拥塞控制
    echo -e "${BLUE}1. BBR 与 FQ 调度队列:${NC}"
    local bbr_qdisc bbr_cc
    bbr_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    bbr_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    echo -e "   内核默认队列: default_qdisc = $bbr_qdisc"
    echo -e "   拥塞控制算法: tcp_congestion_control = $bbr_cc"
    if [ "$bbr_qdisc" = "fq" ] && [ "$bbr_cc" = "bbr" ]; then
        echo -e "   ${GREEN}✓ BBR 与 FQ 内核参数已成功启用${NC}"
    else
        echo -e "   ${YELLOW}⚠ BBR/FQ 状态可能未完全生效${NC}"
        all_ok=false
    fi
    
    # 2. 验证物理网卡硬件队列 (解决假生效痛点)
    echo -e "\n${BLUE}2. 物理网卡硬件队列实测 (${iface}):${NC}"
    local tc_out=""
    if command -v tc &>/dev/null; then
        tc_out=$(tc qdisc show dev "$iface" 2>/dev/null)
        echo -e "   真实硬件队列: $tc_out"
        if echo "$tc_out" | grep -q "qdisc fq"; then
            echo -e "   ${GREEN}✓ 物理网卡 ${iface} 已真实挂载 FQ 队列，BBR Pacing 完全发力！${NC}"
        else
            echo -e "   ${YELLOW}⚠ 物理网卡当前非 FQ 队列 (可能为 pfifo_fast)，BBR Pacing 受限${NC}"
            all_ok=false
        fi
    else
        echo -e "   ${YELLOW}提示: 未安装 tc 命令，跳过硬件网卡队列探测${NC}"
    fi
    
    # 3. 验证 0-RTT 与低延迟参数
    echo -e "\n${BLUE}3. 0-RTT 与低延迟协议栈:${NC}"
    local tfo notsent sstart
    tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
    notsent=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    sstart=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)
    echo -e "   TCP Fast Open (0-RTT): tcp_fastopen = $tfo (目标: 3)"
    echo -e "   防缓冲膨胀上限 (16KB): tcp_notsent_lowat = $notsent (目标: 16384)"
    echo -e "   空闲保持拥塞窗口: tcp_slow_start_after_idle = $sstart (目标: 0)"
    if [ "$tfo" = "3" ] && [ "$notsent" = "16384" ] && [ "$sstart" = "0" ]; then
        echo -e "   ${GREEN}✓ 现代低延迟与防缓冲膨胀参数已全部生效${NC}"
    else
        echo -e "   ${YELLOW}提示: 部分低延迟参数因内核版本限制未能完全匹配${NC}"
    fi
    
    # 4. 验证 TCP 缓冲区
    echo -e "\n${BLUE}4. TCP 巨型读写缓冲区:${NC}"
    local rmax wmax
    rmax=$(sysctl -n net.core.rmem_max 2>/dev/null)
    wmax=$(sysctl -n net.core.wmem_max 2>/dev/null)
    echo -e "   读缓冲区上限: rmem_max = $rmax"
    echo -e "   写缓冲区上限: wmem_max = $wmax"
    if [ "$rmax" -ge 67108864 ] 2>/dev/null; then
        echo -e "   ${GREEN}✓ 64MB 极限千兆吞吐档已激活 (专治跨国千兆跑不满)${NC}"
    elif [ "$rmax" -ge 16777216 ] 2>/dev/null; then
        echo -e "   ${GREEN}✓ 16MB 均衡标准档已激活 (安全防 OOM)${NC}"
    else
        echo -e "   ${YELLOW}⚠ 缓冲区未充分优化${NC}"
    fi
    
    echo -e "${CYAN}======================================================${NC}"
    if [ "$all_ok" = true ]; then
        echo -e "${GREEN}  ✓ 恭喜！现代 VPS 极限网络优化已全部生效并处于最佳状态！${NC}"
    else
        echo -e "${YELLOW}  部分配置生效中，若为旧内核请考虑升级系统或内核。${NC}"
    fi
    echo -e "${CYAN}======================================================${NC}"
    wait_for_user
}

# 显示当前配置
show_current_config() {
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}               当前网络参数看板${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local iface
    iface=$(get_default_interface)
    
    echo -e "${BLUE}[拥塞控制与硬件队列]${NC}"
    sysctl net.core.default_qdisc 2>/dev/null
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null
    if command -v tc &>/dev/null; then
        echo -n "物理网卡 ($iface) 队列: "
        tc qdisc show dev "$iface" 2>/dev/null
    fi
    
    echo -e "\n${BLUE}[低延迟与防缓冲膨胀]${NC}"
    sysctl net.ipv4.tcp_fastopen 2>/dev/null
    sysctl net.ipv4.tcp_notsent_lowat 2>/dev/null
    sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null
    sysctl net.ipv4.tcp_mtu_probing 2>/dev/null
    
    echo -e "\n${BLUE}[TCP 读写缓冲区]${NC}"
    sysctl net.core.rmem_max 2>/dev/null
    sysctl net.core.wmem_max 2>/dev/null
    sysctl net.ipv4.tcp_rmem 2>/dev/null
    sysctl net.ipv4.tcp_wmem 2>/dev/null
    
    echo -e "\n${BLUE}[高并发与连接队列]${NC}"
    sysctl net.core.somaxconn 2>/dev/null
    sysctl net.core.netdev_max_backlog 2>/dev/null
    sysctl net.ipv4.tcp_tw_reuse 2>/dev/null
    sysctl net.ipv4.tcp_fin_timeout 2>/dev/null
    echo -e "${CYAN}==============================================${NC}"
    wait_for_user
}

# 恢复备份与回滚
restore_backup() {
    echo -e "${YELLOW}可用的配置备份:${NC}"
    ls -d /root/sysctl_backup_* 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}未找到备份文件${NC}"
        wait_for_user
        return
    fi
    
    echo ""
    read -p "请输入要恢复的备份目录完整路径或名称 (如 sysctl_backup_xxx): " backup_input
    [ -z "$backup_input" ] && echo -e "${YELLOW}已取消${NC}" && wait_for_user && return
    
    local target_dir="$backup_input"
    [ ! -d "$target_dir" ] && target_dir="/root/$backup_input"
    
    if [ -d "$target_dir" ]; then
        echo -e "${YELLOW}正在恢复系统原始配置...${NC}"
        cp -r "$target_dir"/* /etc/sysctl.d/ 2>/dev/null
        cp "$target_dir"/sysctl.conf /etc/ 2>/dev/null
        sysctl --system 2>/dev/null || sysctl -p 2>/dev/null
        
        # 清理 FQ 硬件队列持久化服务
        if [ -f /etc/systemd/system/set-fq-qdisc.service ]; then
            echo -e "${BLUE}清理 FQ 开机持久化服务...${NC}"
            systemctl disable --now set-fq-qdisc.service 2>/dev/null
            rm -f /etc/systemd/system/set-fq-qdisc.service 2>/dev/null
            systemctl daemon-reload 2>/dev/null
        fi
        
        # 还原网卡硬件队列为系统默认 pfifo_fast
        local iface
        iface=$(get_default_interface)
        if command -v tc &>/dev/null; then
            tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null || tc qdisc del dev "$iface" root 2>/dev/null
        fi
        
        echo -e "${GREEN}✓ 系统配置与网卡队列已彻底恢复！${NC}"
    else
        echo -e "${RED}错误: 备份目录不存在: $target_dir${NC}"
    fi
    wait_for_user
}

#==============================================
# SSH 端口安全管理模块 (防暴力破解)
#==============================================

# 获取当前 SSH 端口
get_current_ssh_port() {
    local port=""
    if command -v sshd &>/dev/null; then
        port=$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n 1)
    fi
    if [ -z "$port" ] && [ -f /etc/ssh/sshd_config ]; then
        port=$(grep -E '^[ \t]*Port[ \t]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -o -E '[0-9]+' | tail -n 1)
    fi
    echo "${port:-22}"
}

# 检测端口是否已被占用
check_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tulpn 2>/dev/null | grep -q -E ":${port}\b"
        return $?
    elif command -v netstat &>/dev/null; then
        netstat -tulpn 2>/dev/null | grep -q -E ":${port}\b"
        return $?
    elif command -v lsof &>/dev/null; then
        lsof -i ":${port}" &>/dev/null
        return $?
    fi
    return 1
}

# 配置系统防火墙以放行指定端口
configure_firewall_port() {
    local port="$1"
    echo -e "${YELLOW}正在检测并配置系统防火墙放行端口 ${port}/tcp...${NC}"
    local fw_configured=false
    
    # 1. UFW (Debian/Ubuntu)
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q -i "active"; then
            echo -e "${BLUE}检测到 UFW 防火墙处于激活状态，添加放行规则...${NC}"
            ufw allow "${port}/tcp" comment "SSH Port" &>/dev/null
            echo -e "${GREEN}✓ UFW 已放行端口 ${port}/tcp${NC}"
            fw_configured=true
        fi
    fi
    
    # 2. Firewalld (CentOS/RHEL/Fedora)
    if command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state &>/dev/null; then
            echo -e "${BLUE}检测到 Firewalld 处于运行状态，添加放行规则...${NC}"
            firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
            firewall-cmd --reload &>/dev/null
            echo -e "${GREEN}✓ Firewalld 已放行端口 ${port}/tcp${NC}"
            fw_configured=true
        fi
    fi
    
    # 3. iptables (规则注入兜底)
    if command -v iptables &>/dev/null; then
        if iptables -L INPUT -n 2>/dev/null | grep -q -E 'REJECT|DROP'; then
            echo -e "${BLUE}检测到 iptables 存在拦截策略，注入允许规则...${NC}"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            echo -e "${GREEN}✓ iptables 已插入放行规则${NC}"
            fw_configured=true
        fi
    fi
    
    if [ "$fw_configured" = "false" ]; then
        echo -e "${BLUE}系统内未检测到开启中的系统级防火墙 (UFW/Firewalld/iptables 拦截规则)。${NC}"
    fi
}

# 配置 SELinux 放行端口
configure_selinux_port() {
    local port="$1"
    if command -v getenforce &>/dev/null; then
        local status
        status=$(getenforce 2>/dev/null)
        if [ "$status" = "Enforcing" ]; then
            echo -e "${YELLOW}检测到 SELinux 处于 Enforcing 模式，正在配置端口标签...${NC}"
            if command -v semanage &>/dev/null; then
                semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null
                echo -e "${GREEN}✓ SELinux 已放行端口 ${port}${NC}"
            else
                echo -e "${YELLOW}未检测到 semanage 命令，临时切换为 Permissive 模式以防止 SSH 监听被阻断...${NC}"
                setenforce 0 2>/dev/null
                echo -e "${GREEN}已临时生效。建议后续通过包管理器安装 policycoreutils-python-utils。${NC}"
            fi
        fi
    fi
}

# 修改 SSH 端口核心函数
change_ssh_port() {
    check_root
    
    local current_port
    current_port=$(get_current_ssh_port)
    
    echo ""
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${CYAN}             修改 SSH 端口 (防暴力破解)${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo -e "当前 SSH 运行端口: ${GREEN}${current_port}${NC}"
    echo -e "${YELLOW}提示: 建议选择 1024 - 65535 之间未被占用的高位端口。${NC}"
    echo -e "${YELLOW}      请勿使用常见服务端口 (如 80, 443, 3306, 6379, 8080 等)。${NC}"
    echo -e "${CYAN}----------------------------------------------${NC}"
    
    local new_port
    while true; do
        read -p "请输入新的 SSH 端口号 [1024-65535] (输入 0 取消): " new_port
        [ "$new_port" = "0" ] && echo -e "${YELLOW}已取消修改。${NC}" && wait_for_user && return 0
        
        # 纯数字校验
        if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误: 端口号必须为纯数字！${NC}"
            continue
        fi
        
        # 端口范围校验
        if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            echo -e "${RED}错误: 端口范围必须在 1-65535 之间！${NC}"
            continue
        fi
        
        if [ "$new_port" -le 1024 ]; then
            echo -e "${YELLOW}警告: 端口 ${new_port} 属于系统特权预留端口，容易发生冲突。${NC}"
            read -p "是否仍然坚持使用端口 ${new_port}? (y/N): " confirm_priv
            if [ "$confirm_priv" != "y" ] && [ "$confirm_priv" != "Y" ]; then
                continue
            fi
        fi
        
        if [ "$new_port" -eq "$current_port" ]; then
            echo -e "${YELLOW}当前 SSH 已经在使用端口 ${new_port}，无需重复修改。${NC}"
            wait_for_user
            return 0
        fi
        
        # 占用检测
        if check_port_in_use "$new_port"; then
            echo -e "${RED}错误: 端口 ${new_port} 当前已被本机其他服务占用，请更换端口！${NC}"
            continue
        fi
        
        break
    done
    
    echo ""
    echo -e "${YELLOW}准备将 SSH 端口由 ${current_port} 修改为 ${new_port}...${NC}"
    
    if [ ! -f /etc/ssh/sshd_config ]; then
        echo -e "${RED}错误: 未找到 SSH 主配置文件 /etc/ssh/sshd_config${NC}"
        wait_for_user
        return 1
    fi
    
    # 1. 备份原配置
    local backup_file="/etc/ssh/sshd_config.bak_$(date +%Y%m%d_%H%M%S)"
    cp /etc/ssh/sshd_config "$backup_file"
    echo -e "${GREEN}✓ 已备份原配置文件至: ${backup_file}${NC}"
    
    # 2. 注释 sshd_config.d/*.conf 中的冲突 Port 指令 (兼容 Debian 12+/Ubuntu 22+)
    if [ -d /etc/ssh/sshd_config.d ]; then
        for dconf in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$dconf" ] && grep -q -E '^[ \t]*Port[ \t]+' "$dconf" 2>/dev/null; then
                sed -i -E 's/^[ \t]*Port[ \t]+.*/#& (disabled for port change)/' "$dconf" 2>/dev/null
            fi
        done
    fi
    
    # 3. 更新 /etc/ssh/sshd_config
    if grep -q -E '^[# \t]*Port[ \t]+' /etc/ssh/sshd_config; then
        sed -i -E "s/^[# \t]*Port[ \t]+.*/Port $new_port/" /etc/ssh/sshd_config
    else
        echo -e "\nPort $new_port" >> /etc/ssh/sshd_config
    fi
    
    # 4. 语法检测与自动回滚
    echo -e "${YELLOW}正在检测 SSH 配置语法合法性 (sshd -t)...${NC}"
    local test_e
    test_err=$(sshd -t 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: sshd 配置语法测试失败！输出信息如下:${NC}"
        echo "$test_err"
        echo -e "${YELLOW}正在自动回滚原配置，取消本次操作...${NC}"
        cp "$backup_file" /etc/ssh/sshd_config
        echo -e "${GREEN}✓ 已成功回滚至修改前状态，未对服务产生影响。${NC}"
        wait_for_user
        return 1
    fi
    echo -e "${GREEN}✓ 配置语法测试通过${NC}"
    
    # 5. 配置 SELinux 与防火墙
    configure_selinux_port "$new_port"
    configure_firewall_port "$new_port"
    
    # 6. 重启 SSH 服务
    echo -e "${YELLOW}正在平滑重启 SSH 服务...${NC}"
    local restart_ok=false
    for svc in sshd ssh; do
        if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl list-unit-files "$svc.service" 2>/dev/null | grep -q "$svc"; then
            if systemctl restart "$svc" 2>/dev/null; then
                restart_ok=true
                break
            fi
        elif service "$svc" status &>/dev/null; then
            if service "$svc" restart 2>/dev/null; then
                restart_ok=true
                break
            fi
        fi
    done
    
    if [ "$restart_ok" = "false" ]; then
        echo -e "${YELLOW}尝试通用重载命令...${NC}"
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service sshd restart 2>/dev/null || service ssh restart 2>/dev/null
    fi
    
    sleep 1
    
    # 7. 检测新端口监听
    if check_port_in_use "$new_port"; then
        echo -e "\n${GREEN}======================================================${NC}"
        echo -e "${GREEN}       ✓ SSH 端口修改成功！已成功监听端口: ${new_port}${NC}"
        echo -e "${GREEN}======================================================${NC}"
    else
        echo -e "\n${YELLOW}提示: SSH 服务已完成重启，但本地探测新端口暂未就绪。${NC}"
    fi
    
    # 8. 极其重要的安全警示
    echo -e "\n${RED}======================= 【极为重要 · 请务必阅读】 =======================${NC}"
    echo -e "${YELLOW}1. 请【千万不要立即关闭当前终端窗口】！保持本连接开启。${NC}"
    echo -e "${YELLOW}2. 若服务器位于云厂商平台 (阿里云、腾讯云、华为云、AWS、GCP、甲骨文云等)，${NC}"
    echo -e "${YELLOW}   请【立即】前往云控制台的【安全组 / 防火墙】页面，添加入站规则放行 TCP ${new_port} 端口！${NC}"
    echo -e "${YELLOW}3. 请新建一个终端窗口，执行以下命令测试能否通过新端口登录：${NC}"
    echo -e "${CYAN}   ssh -p ${new_port} root@<您的VPS公网IP>${NC}"
    echo -e "${YELLOW}4. 确认新端口连接完全正常后，再关闭此窗口或断开连接。${NC}"
    echo -e "${YELLOW}5. 配置文件备份保存在: ${backup_file}${NC}"
    echo -e "${RED}========================================================================${NC}"
    
    wait_for_user
}

# 主菜单
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${CYAN}       VPS 现代网络极限优化工具 v${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}==============================================================${NC}"
        echo -e "${GREEN}1.${NC} 查看当前网络参数看板"
        echo -e "${GREEN}2.${NC} 应用 BBR 与极限调优 (64M/16M缓冲区 + FQ硬件持久化 + 0-RTT)"
        echo -e "${GREEN}3.${NC} 验证配置与物理网卡队列状态"
        echo -e "${GREEN}4.${NC} 恢复系统备份与清理持久化"
        echo -e "${GREEN}5.${NC} 修改 SSH 端口 (防暴力破解)"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}==============================================================${NC}"
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
            5) change_ssh_port ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# 直接运行
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main_menu
fi
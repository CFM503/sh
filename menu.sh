#!/bin/bash

#==============================================
# VPS 管理工具 - 主菜单
# 版本: 1.5.0
# 支持主菜单与子菜单自动更新与版本检测
#==============================================

SCRIPT_VERSION="1.5.0"
VERSION="$SCRIPT_VERSION"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_RAW="https://raw.githubusercontent.com/CFM503/sh/master"

clear_screen() {
    clea
}

wait_for_user() {
    echo ""
    read -p "按回车继续..."
}

#==============================================
# 版本检测与比较算法 (纯 Bash 实现)
#==============================================

# 提取文本行中的版本号
extract_ver() {
    local line="$1"
    echo "$line" | sed -E 's/.*(版本:[ ]*|[A-Za-z_]*VERSION=["'"'"']?)([0-9]+(\.[0-9]+)+).*/\2/'
}

# 判断 $1 是否大于 $2 (语义化版本号比较)
# 返回 0 表示 $1 > $2，返回 1 表示 $1 <= $2
version_gt() {
    local v_remote="$1"
    local v_local="$2"
    if [ -z "$v_remote" ] || [ -z "$v_local" ] || [ "$v_remote" = "$v_local" ]; then
        return 1
    fi
    local s1="${v_remote#v}"
    local s2="${v_local#v}"
    local IFS=.
    local v1=($s1)
    local v2=($s2)
    local max_len=${#v1[@]}
    [ ${#v2[@]} -gt $max_len ] && max_len=${#v2[@]}
    for ((i=0; i<max_len; i++)); do
        local n1="${v1[i]:-0}"
        local n2="${v2[i]:-0}"
        n1="${n1//[^0-9]/}"
        n2="${n2//[^0-9]/}"
        n1=${n1:-0}
        n2=${n2:-0}
        if (( 10#$n1 > 10#$n2 )); then
            return 0
        elif (( 10#$n1 < 10#$n2 )); then
            return 1
        fi
    done
    return 1
}

# 获取本地脚本版本
get_local_version() {
    local filepath="${SCRIPT_DIR}/$1"
    if [ ! -f "$filepath" ]; then
        echo ""
        return
    fi
    local line
    line=$(head -n 35 "$filepath" 2>/dev/null | grep -m1 -E '^SCRIPT_VERSION=|^VERSION=|^# 版本:')
    extract_ver "$line"
}

# 获取远程脚本版本 (低超时 3~6 秒，支持 HTTP Range 优先加速)
get_remote_version() {
    local filename="$1"
    local url="${GITHUB_RAW}/${filename}"
    local line=""
    
    if command -v curl &> /dev/null; then
        line=$(curl -fsSL --connect-timeout 3 --max-time 6 -r 0-1024 "$url" 2>/dev/null | grep -m1 -E '^SCRIPT_VERSION=|^VERSION=|^# 版本:')
        if [ -z "$line" ]; then
            line=$(curl -fsSL --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | head -n 35 | grep -m1 -E '^SCRIPT_VERSION=|^VERSION=|^# 版本:')
        fi
    elif command -v wget &> /dev/null; then
        line=$(wget -qO- --timeout=6 "$url" 2>/dev/null | head -n 35 | grep -m1 -E '^SCRIPT_VERSION=|^VERSION=|^# 版本:')
    fi
    extract_ver "$line"
}

#==============================================
# 安全下载与原子覆盖
#==============================================
download_file() {
    local filename="$1"
    local dest="${SCRIPT_DIR}/${filename}"
    local tmp_file="${SCRIPT_DIR}/.${filename}.tmp"
    local url="${GITHUB_RAW}/${filename}"
    
    echo -e "${YELLOW}正在下载: ${filename}...${NC}"
    local downloaded=false
    
    # curl 优先
    if command -v curl &> /dev/null; then
        if curl -fsSL --connect-timeout 10 --max-time 60 -o "$tmp_file" "$url" 2>/dev/null; then
            downloaded=true
        fi
    fi
    
    # wget 兜底
    if [ "$downloaded" != "true" ] && command -v wget &> /dev/null; then
        if wget -q --timeout=15 -O "$tmp_file" "$url" 2>/dev/null; then
            downloaded=true
        fi
    fi
    
    # 校验合法性与非空
    if [ "$downloaded" = "true" ] && [ -s "$tmp_file" ] && grep -q '^#!/bin/bash' "$tmp_file" 2>/dev/null; then
        chmod +x "$tmp_file" 2>/dev/null
        mv -f "$tmp_file" "$dest"
        echo -e "${GREEN}✓ 成功 (${filename})${NC}"
        return 0
    fi
    
    rm -f "$tmp_file"
    echo -e "${RED}✗ 失败: ${filename}${NC}"
    echo -e "${YELLOW}手动下载地址: ${url}${NC}"
    echo -e "${YELLOW}保存路径: ${dest}${NC}"
    return 1
}

# 确保基础依赖存在
ensure_deps() {
    local files=("network_optimize.sh" "nginx_setup.sh")
    local need_download=()
    
    for file in "${files[@]}"; do
        if [ ! -f "${SCRIPT_DIR}/${file}" ] || [ ! -s "${SCRIPT_DIR}/${file}" ]; then
            need_download+=("$file")
        fi
    done
    
    if [ ${#need_download[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少 ${#need_download[@]} 个子菜单文件，正在初始化下载...${NC}"
        for file in "${need_download[@]}"; do
            download_file "$file"
        done
        echo ""
    fi
}

#==============================================
# 自动更新模块
#==============================================

# 主菜单自动更新与热重启
auto_update_self() {
    local silent="${1:-false}"
    if [ "$silent" != "true" ]; then
        echo -e "${CYAN}正在检查主菜单更新...${NC}"
    fi
    
    local remote_ve
    remote_ver=$(get_remote_version "menu.sh")
    
    if [ -z "$remote_ver" ]; then
        if [ "$silent" != "true" ]; then
            echo -e "${YELLOW}未能获取主菜单远程版本（可能网络超时），跳过检查。${NC}"
        fi
        return 0
    fi
    
    if version_gt "$remote_ver" "$SCRIPT_VERSION"; then
        echo -e "${YELLOW}========================================${NC}"
        echo -e "${YELLOW}发现主菜单新版本: v${remote_ver} (当前: v${SCRIPT_VERSION})${NC}"
        echo -e "${YELLOW}正在自动更新主菜单...${NC}"
        echo -e "${YELLOW}========================================${NC}"
        if download_file "menu.sh"; then
            echo -e "${GREEN}主菜单更新完成，正在重新加载...${NC}"
            sleep 1
            exec bash "${SCRIPT_DIR}/menu.sh" "$@"
        else
            echo -e "${RED}主菜单更新失败，继续使用当前版本。${NC}"
        fi
    else
        if [ "$silent" != "true" ]; then
            echo -e "${GREEN}当前主菜单已是最新版本 (v${SCRIPT_VERSION})。${NC}"
        fi
    fi
}

# 子菜单自动更新
auto_update_submenu() {
    local script="$1"
    local silent="${2:-false}"
    local filepath="${SCRIPT_DIR}/${script}"
    
    if [ ! -f "$filepath" ] || [ ! -s "$filepath" ]; then
        download_file "$script"
        return $?
    fi
    
    local local_ve
    local_ver=$(get_local_version "$script")
    local remote_ve
    remote_ver=$(get_remote_version "$script")
    
    if [ -n "$remote_ver" ]; then
        [ -z "$local_ver" ] && local_ver="1.0.0"
        if version_gt "$remote_ver" "$local_ver"; then
            echo -e "${YELLOW}发现 ${script} 新版本: v${remote_ver} (当前: v${local_ver})，正在自动更新...${NC}"
            if download_file "$script"; then
                echo -e "${GREEN}${script} 已自动更新至最新版 (v${remote_ver})${NC}"
                return 0
            else
                echo -e "${YELLOW}更新失败，继续使用本地版本。${NC}"
                return 1
            fi
        else
            if [ "$silent" != "true" ]; then
                echo -e "${GREEN}${script} 已是最新版本 (v${local_ver})。${NC}"
            fi
        fi
    else
        if [ "$silent" != "true" ]; then
            echo -e "${YELLOW}未能获取 ${script} 远程版本，跳过自动更新。${NC}"
        fi
    fi
    return 0
}

# 检查所有组件状态与更新
check_all_updates() {
    clear_screen
    echo -e "${CYAN}==================================================${NC}"
    echo -e "${CYAN}               检查组件版本与更新状态${NC}"
    echo -e "${CYAN}==================================================${NC}"
    printf "%-22s %-12s %-12s %s\n" "组件名称" "本地版本" "远程版本" "状态"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    
    local all_files=("menu.sh" "network_optimize.sh" "nginx_setup.sh")
    local has_update=false
    
    for file in "${all_files[@]}"; do
        local l_ver r_ver status
        if [ "$file" = "menu.sh" ]; then
            l_ver="$SCRIPT_VERSION"
        else
            l_ver=$(get_local_version "$file")
        fi
        [ -z "$l_ver" ] && l_ver="未安装"
        
        r_ver=$(get_remote_version "$file")
        
        if [ -z "$r_ver" ]; then
            r_ver="检测超时"
            status="${YELLOW}网络超时${NC}"
        elif [ "$l_ver" = "未安装" ]; then
            status="${RED}缺少依赖${NC}"
            has_update=true
        elif version_gt "$r_ver" "$l_ver"; then
            status="${YELLOW}可更新 -> v${r_ver}${NC}"
            has_update=true
        else
            status="${GREEN}已是最新${NC}"
        fi
        
        printf "%-22s %-12s %-12s %b\n" "$file" "$l_ver" "$r_ver" "$status"
    done
    echo -e "${CYAN}==================================================${NC}"
    
    if [ "$has_update" = "true" ]; then
        echo ""
        read -p "检测到有组件可更新，是否立即全部更新? (y/N): " do_up
        if [ "$do_up" = "y" ] || [ "$do_up" = "Y" ]; then
            update_all_components
        fi
    else
        echo -e "\n${GREEN}所有已安装组件均为最新版本！${NC}"
        wait_for_use
    fi
}

# 更新所有组件
update_all_components() {
    echo -e "\n${CYAN}>>> 正在更新子菜单依赖...${NC}"
    download_file "network_optimize.sh"
    download_file "nginx_setup.sh"
    
    echo -e "\n${CYAN}>>> 正在检查并更新主菜单...${NC}"
    auto_update_self "false"
    wait_for_use
}

#==============================================
# 子菜单入口
#==============================================
run_submenu() {
    local script="$1"
    local filepath="${SCRIPT_DIR}/${script}"
    
    if [ ! -f "$filepath" ] || [ ! -s "$filepath" ]; then
        echo -e "${YELLOW}未找到 ${script}，正在下载...${NC}"
        if ! download_file "$script"; then
            echo -e "${RED}无法获取 ${script}${NC}"
            wait_for_use
            return 1
        fi
    else
        # 运行前自动检查子菜单更新 (静默模式：有新版本才更新提示)
        auto_update_submenu "$script" "true"
    fi
    
    bash "$filepath"
}

#==============================================
# 依赖与更新管理
#==============================================
dep_management() {
    while true; do
        clear_screen
        echo -e "${CYAN}==============================${NC}"
        echo -e "${CYAN}       依赖与更新管理${NC}"
        echo -e "${CYAN}==============================${NC}"
        echo -e "${GREEN}1.${NC} 检查所有组件状态与更新"
        echo -e "${GREEN}2.${NC} 一键更新全部脚本 (主菜单+子菜单)"
        echo -e "${GREEN}3.${NC} 一键更新所有依赖 (仅子菜单)"
        echo -e "${GREEN}4.${NC} 单独更新主菜单 (menu.sh)"
        echo -e "${GREEN}5.${NC} 单独更新 network_optimize.sh"
        echo -e "${GREEN}6.${NC} 单独更新 nginx_setup.sh"
        echo -e "${GREEN}7.${NC} 删除所有子菜单依赖"
        echo -e "${RED}0.${NC} 返回主菜单"
        echo -e "${CYAN}==============================${NC}"
        echo -n "请选择: "
        
        read choice || break
        case $choice in
            1) check_all_updates ;;
            2) update_all_components ;;
            3)
                download_file "network_optimize.sh"
                download_file "nginx_setup.sh"
                wait_for_use
                ;;
            4)
                auto_update_self "false"
                wait_for_use
                ;;
            5)
                auto_update_submenu "network_optimize.sh" "false"
                wait_for_use
                ;;
            6)
                auto_update_submenu "nginx_setup.sh" "false"
                wait_for_use
                ;;
            7)
                echo -e "${RED}确认删除所有子菜单依赖? (y/N)${NC}"
                read confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    rm -f "${SCRIPT_DIR}/network_optimize.sh"
                    rm -f "${SCRIPT_DIR}/nginx_setup.sh"
                    echo -e "${GREEN}已删除所有子菜单依赖文件${NC}"
                fi
                wait_for_use
                ;;
            0) break ;;
            *) sleep 1 ;;
        esac
    done
}

#==============================================
# 主菜单
#==============================================
show_main_menu() {
    clear_screen
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}       VPS 管理工具 v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}==============================${NC}"
    echo -e "${GREEN}1.${NC} 网络优化 (BBR/TCP)"
    echo -e "${GREEN}2.${NC} Nginx 配置"
    echo -e "${GREEN}3.${NC} 依赖与更新管理"
    echo -e "${GREEN}4.${NC} 检查并更新全部脚本"
    echo -e "${RED}0.${NC} 退出"
    echo -e "${CYAN}==============================${NC}"
    echo -n "请选择: "
}

main() {
    # 启动时自动检查主菜单更新 (发现新版本则自动下载并热重启)
    auto_update_self "true"
    
    # 启动时检查依赖完整性
    ensure_deps
    
    while true; do
        show_main_menu
        read choice || break
        case $choice in
            1) run_submenu "network_optimize.sh" ;;
            2) run_submenu "nginx_setup.sh" ;;
            3) dep_management ;;
            4) check_all_updates ;;
            0)
                echo -e "\n${GREEN}再见!${NC}"
                exit 0
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
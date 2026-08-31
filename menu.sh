#!/bin/bash

#==============================================
# VPS 管理工具 - 主菜单
# 版本: 1.4.1
# 自动下载子菜单功能
#==============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_RAW="https://raw.githubusercontent.com/CFM503/sh/master"

clear_screen() {
    clear
}

wait_for_user() {
    echo ""
    read -p "按回车继续..."
}

#==============================================
# 下载功能
#==============================================
download_file() {
    local filename="$1"
    local dest="${SCRIPT_DIR}/${filename}"
    local url="${GITHUB_RAW}/${filename}"
    
    echo -e "${YELLOW}下载: ${filename}${NC}"
    
    # curl
    if command -v curl &> /dev/null; then
        curl -fsSL --connect-timeout 15 --max-time 60 -o "$dest" "$url" 2>/dev/null
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            chmod +x "$dest" 2>/dev/null
            echo -e "${GREEN}OK (${filename})${NC}"
            return 0
        fi
    fi
    
    # wget
    if command -v wget &> /dev/null; then
        wget -q --timeout=15 -O "$dest" "$url" 2>/dev/null
        if [ -f "$dest" ] && [ -s "$dest" ]; then
            chmod +x "$dest" 2>/dev/null
            echo -e "${GREEN}OK (${filename})${NC}"
            return 0
        fi
    fi
    
    echo -e "${RED}失败: ${filename}${NC}"
    echo -e "${YELLOW}手动下载: ${url}${NC}"
    echo -e "${YELLOW}保存到: ${dest}${NC}"
    return 1
}

ensure_deps() {
    local files=("network_optimize.sh" "nginx_setup.sh")
    local need_download=()
    
    for file in "${files[@]}"; do
        if [ ! -f "${SCRIPT_DIR}/${file}" ] || [ ! -s "${SCRIPT_DIR}/${file}" ]; then
            need_download+=("$file")
        fi
    done
    
    if [ ${#need_download[@]} -gt 0 ]; then
        echo -e "${YELLOW}缺少 ${#need_download[@]} 个文件，正在下载...${NC}"
        for file in "${need_download[@]}"; do
            download_file "$file"
        done
        echo ""
    fi
}

#==============================================
# 子菜单入口
#==============================================
run_submenu() {
    local script="$1"
    local filepath="${SCRIPT_DIR}/${script}"
    
    if [ -f "$filepath" ] && [ -s "$filepath" ]; then
        bash "$filepath"
    else
        echo -e "${YELLOW}未找到 ${script}，正在下载...${NC}"
        if download_file "$script"; then
            bash "${SCRIPT_DIR}/${script}"
        else
            echo -e "${RED}无法获取 ${script}${NC}"
        fi
    fi
}

#==============================================
# 依赖管理
#==============================================
dep_management() {
    while true; do
        clear_screen
        echo -e "${CYAN}==============================${NC}"
        echo -e "${CYAN}       依赖管理${NC}"
        echo -e "${CYAN}==============================${NC}"
        echo -e "${GREEN}1.${NC} 检查所有依赖"
        echo -e "${GREEN}2.${NC} 更新 network_optimize.sh"
        echo -e "${GREEN}3.${NC} 更新 nginx_setup.sh"
        echo -e "${GREEN}4.${NC} 更新所有依赖"
        echo -e "${GREEN}5.${NC} 删除所有依赖"
        echo -e "${RED}0.${NC} 返回"
        echo -e "${CYAN}==============================${NC}"
        echo -n "请选择: "
        
        read choice || break
        case $choice in
            1) 
                echo ""
                for file in network_optimize.sh nginx_setup.sh; do
                    if [ -f "${SCRIPT_DIR}/${file}" ] && [ -s "${SCRIPT_DIR}/${file}" ]; then
                        echo -e "${GREEN}✓ ${file} - OK${NC}"
                    else
                        echo -e "${RED}✗ ${file} - 缺少${NC}"
                    fi
                done
                wait_for_user
                ;;
            2) download_file "network_optimize.sh"; wait_for_user ;;
            3) download_file "nginx_setup.sh"; wait_for_user ;;
            4) 
                download_file "network_optimize.sh"
                download_file "nginx_setup.sh"
                wait_for_user
                ;;
            5)
                echo -e "${RED}确认删除所有依赖? (y/N)${NC}"
                read confirm
                if [ "$confirm" = "y" ]; then
                    rm -f "${SCRIPT_DIR}/network_optimize.sh"
                    rm -f "${SCRIPT_DIR}/nginx_setup.sh"
                    echo -e "${GREEN}已删除${NC}"
                fi
                wait_for_user
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
    echo -e "${CYAN}       VPS 管理工具 v1.4.1${NC}"
    echo -e "${CYAN}==============================${NC}"
    echo -e "${GREEN}1.${NC} 网络优化 (BBR/TCP)"
    echo -e "${GREEN}2.${NC} Nginx 配置"
    echo -e "${GREEN}3.${NC} 依赖管理"
    echo -e "${RED}0.${NC} 退出"
    echo -e "${CYAN}==============================${NC}"
    echo -n "请选择: "
}

main() {
    # 启动时检查依赖
    ensure_deps
    
    while true; do
        show_main_menu
        read choice || break
        case $choice in
            1) run_submenu "network_optimize.sh" ;;
            2) run_submenu "nginx_setup.sh" ;;
            3) dep_management ;;
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

main
# VPS 管理工具集

一套通用的VPS管理脚本，支持所有Linux发行版。

## 功能模块

### 1. 系统管理
- 查看系统信息、内核版本、运行时间
- 查看CPU、内存、磁盘信息
- 重启/关机系统

### 2. 网络管理
- 查看IP地址、网络连接、路由表
- 测试网络连通性
- 查看DNS、监听端口
- 重启网络服务

### 3. 文件管理
- 浏览目录、查找文件
- 查看/复制/移动/删除文件
- 修改权限、搜索内容

### 4. 服务管理
- 查看/启动/停止/重启服务
- 开机自启/禁用服务

### 5. 用户管理
- 查看/添加/删除用户
- 修改密码、管理用户组

### 6. 软件管理
- 自动检测包管理器(apt/yum/dnf/pacman等)
- 更新/升级/安装/卸载软件

### 7. 备份恢复
- 文件/目录备份
- 快照创建

### 8. 系统监控
- 实时进程监控
- CPU/内存/磁盘IO/网络流量监控
- 查看系统日志

### 9. 安全管理
- 防火墙规则管理
- 端口管理
- 查看登录记录/SSH配置

### 10. 网络优化
- 自动配置BBR拥塞控制
- TCP缓冲区优化
- 滑动窗口和SACK优化
- 支持Debian 12/13及所有主流发行版

### 11. Nginx配置
- 自动安装Nginx
- 配置反向代理(支持WebSocket)
- 预设: /pyway -> 127.0.0.1:2052
- 配置验证和重载

## 文件结构

```
├── menu.sh              # 主菜单入口
├── network_optimize.sh  # 网络优化脚本
├── nginx_setup.sh       # Nginx配置脚本
├── CHANGELOG.md         # 更新日志
└── README.md            # 说明文档
```

## 使用方法

```bash
# 给脚本执行权限
chmod +x *.sh

# 运行主菜单
bash menu.sh

# 或单独运行某个脚本
sudo bash network_optimize.sh
sudo bash nginx_setup.sh
```

## 系统要求

- 操作系统: Linux (Debian/Ubuntu/CentOS/RHEL/Fedora/Arch等)
- Shell: Bash 4.0+
- 权限: 部分功能需要root权限

## 更新日志

详见 [CHANGELOG.md](CHANGELOG.md)

## 许可证

MIT License
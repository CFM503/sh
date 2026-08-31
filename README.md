# VPS 管理工具

一套通用的VPS管理脚本，支持所有Linux发行版。

## 快速安装

```bash
wget https://raw.githubusercontent.com/CFM503/sh/master/menu.sh && chmod +x menu.sh && bash menu.sh
```

> 首次运行会自动下载所需的子菜单文件。
> 如需更新，重新运行上面的命令即可覆盖旧版本。

## 功能模块

| 功能 | 说明 |
|------|------|
| 网络优化 | BBR拥塞控制、TCP缓冲区优化、滑动窗口和SACK |
| Nginx配置 | 自动安装Nginx、配置反向代理(支持WebSocket) |

## 使用方法

```bash
# 下载运行
wget https://raw.githubusercontent.com/CFM503/sh/master/menu.sh && chmod +x menu.sh && bash menu.sh

# 更新版本（覆盖本地文件）
wget -O menu.sh https://raw.githubusercontent.com/CFM503/sh/master/menu.sh && bash menu.sh
```

## 系统要求

- 操作系统: Linux (Debian/Ubuntu/CentOS/RHEL/Fedora/Arch等)
- 权限: 部分功能需要root权限

## 版本

当前版本: v1.4.2

## 许可证

MIT License
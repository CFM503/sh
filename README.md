# VPS 管理工具

一套通用的VPS管理脚本，支持所有Linux发行版。

## 快速安装

```bash
wget https://raw.githubusercontent.com/CFM503/sh/master/menu.sh && chmod +x menu.sh && bash menu.sh
```

> 首次运行会自动下载所需的子菜单文件。
> 支持主菜单与子菜单在线自动检测与更新，启动或进入子菜单时自动同步最新版本。
> 也可在菜单中选择「依赖与更新管理」或「检查并更新全部脚本」随时手动检测更新。

## 功能模块

| 功能 | 说明 |
|------|------|
| 网络优化 | BBR+FQ硬件队列开机持久化、64M/16M内存自适应BDP缓冲区、0-RTT握手加速、修改SSH端口(防暴力破解) |
| Nginx配置 | 自动安装Nginx、配置反向代理(支持WebSocket) |
| 自动更新 | 支持主菜单与子脚本自动检测更新、版本比对与原子热重启 |

## 使用方法

```bash
# 下载运行（后续启动将自动检测并提示更新）
wget https://raw.githubusercontent.com/CFM503/sh/master/menu.sh && chmod +x menu.sh && bash menu.sh
```

## 系统要求

- 操作系统: Linux (Debian/Ubuntu/CentOS/RHEL/Fedora/Arch等)
- 权限: 部分功能需要root权限

## 版本

当前版本: v1.5.0

## 许可证

MIT License
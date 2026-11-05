# service-change-address

开机时在本机控制台提示修改本机 IP 的 systemd 服务。可下载到任意 Ubuntu/Debian（netplan）服务器一键安装。

## 一键安装（每台服务器）

```bash
git clone https://github.com/supremeluojunyu/service-change-address.git
cd service-change-address
sudo ./install.sh
```

或下载 zip 后解压安装：

```bash
curl -fsSL -o service-change-address.zip \
  https://github.com/supremeluojunyu/service-change-address/archive/refs/heads/main.zip
unzip service-change-address.zip
cd service-change-address-main
sudo ./install.sh
```

## 开机行为

1. 自动启动 `ip-change-prompt.service`（挂了会按 `Restart=on-failure` 拉起）
2. **输入密码**（初始 `123456789`，30 秒超时或错误 → 直接继续开机）
3. **首次开机**（`FORCE_CHANGE_PASSWORD=1`）可改密，需确认一遍；也可跳过
4. **改 IP**（60 秒）：写入 `/etc/netplan/50-cloud-init.yaml` 后立刻重启；超时则按原配置开机

控制台：`tty1`（虚拟机控制台或 Ctrl+Alt+F1）。纯 SSH 看不到提示。

## 用 nano 改密码

```bash
sudo nano /etc/ip-change-prompt.conf
```

```
PASSWORD=你的新密码
FORCE_CHANGE_PASSWORD=0
```

## 卸载

```bash
sudo ./uninstall.sh
```

不会删除已修改的 netplan 与密码配置文件。

## 文件说明

| 文件 | 作用 |
|------|------|
| `install.sh` | 安装并启用服务 |
| `uninstall.sh` | 卸载服务 |
| `ip-change-prompt.sh` | 控制台交互脚本 |
| `ip-change-prompt.service` | systemd 单元 |
| `ip-change-prompt.conf` | 初始密码模板 |

## 要求

- root / sudo
- systemd
- netplan（默认 `/etc/netplan/50-cloud-init.yaml`）
- python3 + PyYAML（Ubuntu 一般已带 `python3-yaml`）

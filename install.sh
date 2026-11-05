#!/bin/bash
# 在目标服务器上一键安装开机改 IP 服务
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 sudo 运行: sudo $0"
  exit 1
fi

if [[ ! -f /etc/netplan/50-cloud-init.yaml ]]; then
  echo "警告: 未找到 /etc/netplan/50-cloud-init.yaml，服务 Condition 可能不会启动。"
  echo "若网卡配置文件名不同，请安装后编辑 Environment=NETPLAN_FILE=..."
fi

install -d -m 755 /usr/local/sbin
install -d -m 755 /usr/local/share/ip-change-prompt
install -m 755 "$ROOT/ip-change-prompt.sh" /usr/local/sbin/ip-change-prompt.sh
install -m 644 "$ROOT/ip-change-prompt.service" /etc/systemd/system/ip-change-prompt.service
install -m 644 "$ROOT/README.md" /usr/local/share/ip-change-prompt/README.md

CONF=/etc/ip-change-prompt.conf
if [[ ! -f "$CONF" ]]; then
  install -m 600 "$ROOT/ip-change-prompt.conf" "$CONF"
else
  # 仍是旧默认 changeip 时，迁移到新初始密码；用户已改过的密码不覆盖
  if grep -qE '^[[:space:]]*PASSWORD=changeip[[:space:]]*$' "$CONF"; then
    install -m 600 "$ROOT/ip-change-prompt.conf" "$CONF"
  else
    if ! grep -qE '^[[:space:]]*FORCE_CHANGE_PASSWORD=' "$CONF"; then
      printf '\nFORCE_CHANGE_PASSWORD=0\n' >>"$CONF"
    fi
    chmod 600 "$CONF"
  fi
fi

touch /var/log/ip-change-prompt.log
chmod 644 /var/log/ip-change-prompt.log

systemctl daemon-reload
systemctl enable ip-change-prompt.service

echo
echo "========================================"
echo " 安装完成: ip-change-prompt.service"
echo "========================================"
echo "密码文件: $CONF"
echo "初始密码: 123456789"
echo "开机流程: 输密码(30s) → 首次可改密 → 改 IP(60s) → 改完立刻重启"
echo "控制台:   tty1（虚拟机控制台 / Ctrl+Alt+F1）"
echo
echo "卸载: sudo $ROOT/uninstall.sh"
echo
systemctl status ip-change-prompt.service --no-pager -l || true

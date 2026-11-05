#!/bin/bash
# 从本机卸载 ip-change-prompt 服务（不删除已改过的 netplan）
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "请使用 sudo 运行: sudo $0"
  exit 1
fi

systemctl disable --now ip-change-prompt.service 2>/dev/null || true
rm -f /etc/systemd/system/ip-change-prompt.service
rm -f /etc/systemd/system/multi-user.target.wants/ip-change-prompt.service
rm -f /etc/systemd/system/graphical.target.wants/ip-change-prompt.service
rm -f /usr/local/sbin/ip-change-prompt.sh
rm -rf /usr/local/share/ip-change-prompt
systemctl daemon-reload

echo "服务已卸载。"
echo "说明: /etc/ip-change-prompt.conf 与 /etc/netplan/50-cloud-init.yaml 未删除，如需清理请手动删除。"

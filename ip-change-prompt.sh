#!/bin/bash
# 开机时在控制台提示修改本机 IP（写入 netplan 50-cloud-init.yaml）
# 先校验密码：错误或超时则直接继续开机；密码正确后再进入改 IP 阶段
# 首次（FORCE_CHANGE_PASSWORD=1）可通过提示行改密，需确认一遍；配置文件仍可用 nano 编辑

set -euo pipefail

NETPLAN_FILE="${NETPLAN_FILE:-/etc/netplan/50-cloud-init.yaml}"
CONFIG_FILE="${IP_CHANGE_CONFIG:-/etc/ip-change-prompt.conf}"
AUTH_TIMEOUT="${IP_CHANGE_AUTH_TIMEOUT:-30}"
TIMEOUT="${IP_CHANGE_TIMEOUT:-60}"
TTY="${IP_CHANGE_TTY:-/dev/tty1}"
# 默认密码，可被配置文件或环境变量 IP_CHANGE_PASSWORD 覆盖
DEFAULT_PASSWORD="123456789"

# 尽量让早期控制台能显示提示
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

log() {
  echo "[ip-change-prompt] $*" | tee -a /var/log/ip-change-prompt.log >/dev/null 2>&1 || true
}

die() {
  log "ERROR: $*"
  echo
  echo "[ERROR] $*"
  echo "[错误] $*"
  sleep 2
  exit 1
}

# 强制打到当前控制台并刷新
say() {
  printf '%s\n' "$*"
}

say_n() {
  printf '%s' "$*"
}

prepare_console() {
  stty sane 2>/dev/null || true
  stty echo 2>/dev/null || true
  clear 2>/dev/null || true
  # 给 plymouth/切换终端一点时间，避免提示被盖住
  sleep 0.5
}

conf_get() {
  local key="$1"
  local default="${2:-}"
  local val=""
  if [[ -r "$CONFIG_FILE" ]]; then
    val="$(
      grep -E "^[[:space:]]*${key}=" "$CONFIG_FILE" | head -1 \
        | sed "s/^[[:space:]]*${key}=//" \
        | sed 's/^"//;s/"$//;s/^'\''//;s/'\''$//'
    )" || true
  fi
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# 就地更新/追加键值，保持 nano 可编辑的纯文本格式
conf_set() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$CONFIG_FILE" ]]; then
    if grep -qE "^[[:space:]]*${key}=" "$CONFIG_FILE"; then
      sed -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$CONFIG_FILE" >"$tmp"
    else
      cat "$CONFIG_FILE" >"$tmp"
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
  else
    cat >"$tmp" <<EOF
# ip-change-prompt 密码配置（权限应为 600）
# 可用 nano 编辑本文件：sudo nano /etc/ip-change-prompt.conf
PASSWORD=${DEFAULT_PASSWORD}
FORCE_CHANGE_PASSWORD=1
EOF
    if [[ "$key" != "PASSWORD" && "$key" != "FORCE_CHANGE_PASSWORD" ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
    else
      sed -E "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$tmp" >"${tmp}.2"
      mv "${tmp}.2" "$tmp"
    fi
  fi
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

load_password() {
  local pw="${IP_CHANGE_PASSWORD:-}"
  if [[ -z "$pw" ]]; then
    pw="$(conf_get PASSWORD "$DEFAULT_PASSWORD")"
  fi
  if [[ -z "$pw" ]]; then
    pw="$DEFAULT_PASSWORD"
  fi
  printf '%s' "$pw"
}

need_force_change_password() {
  local flag
  flag="$(conf_get FORCE_CHANGE_PASSWORD 0 | tr '[:upper:]' '[:lower:]')"
  case "$flag" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  read -r a b c d <<<"$ip"
  for oct in "$a" "$b" "$c" "$d"; do
    [[ "$oct" =~ ^[0-9]+$ ]] || return 1
    (( oct >= 0 && oct <= 255 )) || return 1
  done
  return 0
}

is_cidr() {
  local prefix="$1"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 1 && prefix <= 32 ))
}

extract_current_address() {
  python3 - "$NETPLAN_FILE" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    import yaml
    data = yaml.safe_load(text) or {}
    ethernets = (data.get("network") or {}).get("ethernets") or {}
    for iface, conf in ethernets.items():
        addrs = conf.get("addresses") or []
        if addrs:
            print(str(addrs[0]).strip())
            sys.exit(0)
except Exception:
    pass

import re
m = re.search(r"-\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?:/[0-9]+)?)", text)
if not m:
    sys.exit(1)
print(m.group(1))
PY
}

write_new_address() {
  local new_addr="$1"
  python3 - "$NETPLAN_FILE" "$new_addr" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
new_addr = sys.argv[2]
text = path.read_text(encoding="utf-8")

try:
    import yaml

    class FlowList(list):
        pass

    def represent_flow_list(dumper, data):
        return dumper.represent_sequence("tag:yaml.org,2002:seq", data, flow_style=True)

    yaml.add_representer(FlowList, represent_flow_list)

    data = yaml.safe_load(text) or {}
    network = data.setdefault("network", {})
    network.setdefault("version", 2)
    ethernets = network.setdefault("ethernets", {})
    if not ethernets:
        raise RuntimeError("netplan 中未找到 ethernets 网卡配置")

    # 只改第一块网卡的第一个地址，保留网关/DNS
    iface = next(iter(ethernets))
    conf = ethernets[iface]
    addrs = conf.get("addresses") or []
    if addrs:
        addrs[0] = new_addr
    else:
        addrs = [new_addr]
    conf["addresses"] = addrs

    ns = conf.get("nameservers")
    if isinstance(ns, dict) and isinstance(ns.get("addresses"), list):
        ns["addresses"] = FlowList(ns["addresses"])

    out = yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False)
    path.write_text(out, encoding="utf-8")
    path.chmod(0o600)
except Exception:
    import re

    pattern = re.compile(r"(-\s*)([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?:/[0-9]+)?)")
    if not pattern.search(text):
        raise SystemExit("无法在 netplan 文件中定位地址行")
    new_text, n = pattern.subn(rf"\g<1>{new_addr}", text, count=1)
    if n != 1:
        raise SystemExit("替换地址失败")
    path.write_text(new_text, encoding="utf-8")
    path.chmod(0o600)
PY
}

prompt_password() {
  local expected="$1"

  prepare_console
  cat <<EOF

############################################################
#  IP Change Service / 本机 IP 修改服务
############################################################
#  STEP 1/2: Enter password / 第1步：请输入登录密码
############################################################
#
#  EN: Enter the password to change IP.
#      - No input within ${AUTH_TIMEOUT}s  -> continue boot
#      - Wrong password                   -> continue boot
#      - Correct password                 -> next step
#
#  中文: 请输入密码以进入 IP 修改。
#      - ${AUTH_TIMEOUT} 秒内不输入        -> 直接继续开机
#      - 密码错误                         -> 直接继续开机
#      - 密码正确                         -> 进入下一步
#
############################################################

EOF

  say_n "Password / 密码 > "
  local input=""
  # -s 不回显密码；超时则继续开机
  if ! read -r -s -t "$AUTH_TIMEOUT" input; then
    echo
    say "[Timeout] No password in ${AUTH_TIMEOUT}s. Continue boot with current IP."
    say "[超时] ${AUTH_TIMEOUT} 秒未输入密码，按原配置继续开机。"
    log "auth timeout, continue boot"
    sleep 1
    return 1
  fi
  echo

  if [[ -z "$input" ]]; then
    say "[Skip] Empty password. Continue boot with current IP."
    say "[跳过] 未输入密码，按原配置继续开机。"
    log "auth empty, continue boot"
    sleep 1
    return 1
  fi

  if [[ "$input" != "$expected" ]]; then
    say "[Failed] Wrong password. Continue boot with current IP."
    say "[失败] 密码错误，按原配置继续开机。"
    log "auth failed, continue boot"
    sleep 2
    return 1
  fi

  say "[OK] Password accepted."
  say "[成功] 密码正确。"
  log "auth ok"
  sleep 1
  return 0
}

# 首次开机：提示改密，输入两遍确认；回车/超时可跳过
prompt_change_password_first_boot() {
  need_force_change_password || return 0

  prepare_console
  cat <<EOF

############################################################
#  First boot: change password / 首次开机：修改密码
############################################################
#
#  EN: Set a new password (optional).
#      - Enter new password, then confirm once
#      - Empty / timeout ${AUTH_TIMEOUT}s -> keep current password
#      - Later you can also: sudo nano ${CONFIG_FILE}
#
#  中文: 建议设置新密码（可跳过）。
#      - 输入新密码后需再确认一遍
#      - 直接回车 / ${AUTH_TIMEOUT} 秒超时 -> 保留当前密码
#      - 也可稍后: sudo nano ${CONFIG_FILE}
#
############################################################

EOF

  local new_pw confirm
  say_n "New password / 新密码 > "
  if ! read -r -s -t "$AUTH_TIMEOUT" new_pw; then
    echo
    say "[Timeout] Keep current password."
    say "[超时] 保留当前密码。"
    conf_set FORCE_CHANGE_PASSWORD 0
    log "password change skipped (timeout)"
    sleep 1
    return 0
  fi
  echo

  if [[ -z "$new_pw" ]]; then
    say "[Skip] Keep current password."
    say "[跳过] 保留当前密码。"
    conf_set FORCE_CHANGE_PASSWORD 0
    log "password change skipped (empty)"
    sleep 1
    return 0
  fi

  say_n "Confirm password / 确认新密码 > "
  if ! read -r -s -t "$AUTH_TIMEOUT" confirm; then
    echo
    say "[Timeout] Password not changed."
    say "[超时] 未修改密码。"
    conf_set FORCE_CHANGE_PASSWORD 0
    log "password confirm timeout, keep old"
    sleep 1
    return 0
  fi
  echo

  if [[ "$new_pw" != "$confirm" ]]; then
    say "[Mismatch] Two inputs differ. Password not changed."
    say "[不一致] 两次输入不同，未修改密码。"
    conf_set FORCE_CHANGE_PASSWORD 0
    log "password confirm mismatch, keep old"
    sleep 2
    return 0
  fi

  conf_set PASSWORD "$new_pw"
  conf_set FORCE_CHANGE_PASSWORD 0
  say "[OK] New password saved to ${CONFIG_FILE}"
  say "[成功] 新密码已保存到 ${CONFIG_FILE}"
  log "password changed via first-boot prompt"
  sleep 1
  return 0
}

prompt_ip_change() {
  local current current_prefix="24"
  current="$(extract_current_address)" || die "Cannot read current IP / 无法读取当前 IP"
  if [[ "$current" == */* ]]; then
    current_prefix="${current##*/}"
  fi

  prepare_console
  cat <<EOF

############################################################
#  STEP 2/2: Change IP address / 第2步：输入要修改的 IP
############################################################
#
#  Config / 配置文件 : ${NETPLAN_FILE}
#  Current IP / 当前地址 : ${current}
#
#  EN: Enter the new IP address to apply.
#      - Example: 192.168.3.100
#      - Or CIDR: 192.168.3.100/24
#      - Empty / no input within ${TIMEOUT}s -> continue boot
#      - If changed, system will reboot immediately
#
#  中文: 请输入需要修改的 IP 地址。
#      - 例如: 192.168.3.100
#      - 或带掩码: 192.168.3.100/24
#      - 直接回车 / ${TIMEOUT} 秒不输入 -> 直接继续开机
#      - 若已修改，将立刻重启生效
#
############################################################

EOF

  say_n "New IP / 新 IP > "
  local input=""
  if ! read -r -t "$TIMEOUT" input; then
    echo
    say "[Timeout] No IP in ${TIMEOUT}s. Continue boot with ${current}."
    say "[超时] ${TIMEOUT} 秒未输入 IP，按原配置继续开机。"
    log "ip timeout, keep $current"
    sleep 1
    return 0
  fi

  input="$(echo "$input" | tr -d '[:space:]')"
  if [[ -z "$input" ]]; then
    say "[Skip] Empty IP. Continue boot with ${current}."
    say "[跳过] 未输入 IP，按原配置继续开机。"
    log "empty ip input, keep $current"
    sleep 1
    return 0
  fi

  local new_ip new_prefix="$current_prefix"
  if [[ "$input" == */* ]]; then
    new_ip="${input%%/*}"
    new_prefix="${input##*/}"
  else
    new_ip="$input"
  fi

  is_ipv4 "$new_ip" || die "Invalid IPv4: $new_ip / 非法 IPv4 地址: $new_ip"
  is_cidr "$new_prefix" || die "Invalid prefix: $new_prefix / 非法掩码前缀: $new_prefix"

  local new_addr="${new_ip}/${new_prefix}"
  if [[ "$new_addr" == "$current" ]]; then
    say "[OK] Same as current IP. Continue boot."
    say "[提示] 与当前地址相同，无需修改，继续开机。"
    log "unchanged $current"
    sleep 1
    return 0
  fi

  echo
  say "[Apply] Change IP: ${current} -> ${new_addr}"
  say "[应用] 正在把地址从 ${current} 改为 ${new_addr}"
  say "Writing ${NETPLAN_FILE} ..."
  write_new_address "$new_addr" || die "Failed to write netplan / 写入 netplan 失败"

  if command -v netplan >/dev/null 2>&1; then
    netplan generate || die "netplan generate failed / netplan 校验失败"
  fi

  log "changed $current -> $new_addr, rebooting"
  say "[OK] Config updated. Rebooting now..."
  say "[成功] 配置已更新，系统将立即重启..."
  sync
  sleep 2
  systemctl reboot --no-block || /sbin/reboot
  return 0
}

main() {
  [[ -r "$NETPLAN_FILE" ]] || die "Missing $NETPLAN_FILE / 找不到配置文件"
  [[ "$(id -u)" -eq 0 ]] || die "Root required / 需要 root 权限"

  # 绑定到控制台（虚拟机请看控制台或 Ctrl+Alt+F1）
  if [[ -e "$TTY" ]]; then
    exec <>"$TTY" >&0 2>&0
  fi

  prepare_console
  say "IP Change Service starting on ${TTY} ..."
  say "本机 IP 修改服务正在启动（控制台 ${TTY}）..."
  sleep 1

  # 配置文件不存在时写入初始模板（与 nano 编辑格式一致）
  if [[ ! -f "$CONFIG_FILE" ]]; then
    conf_set PASSWORD "$DEFAULT_PASSWORD"
    conf_set FORCE_CHANGE_PASSWORD 1
  fi

  local expected
  expected="$(load_password)"

  if ! prompt_password "$expected"; then
    exit 0
  fi

  prompt_change_password_first_boot
  prompt_ip_change
  exit 0
}

main "$@"

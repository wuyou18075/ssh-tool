#!/bin/bash

# 定义终端颜色变量（仅用红/绿/黄/橙，避免深蓝/亮白看不清）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[38;5;208m'   # 256色橙
# 原蓝/青标题统一改为橙色（兼容旧 ${BLUE}/${CYAN}）
BLUE="${ORANGE}"
CYAN="${ORANGE}"
NC='\033[0m'
BOLD='\033[1m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "${ORANGE}[INFO]${NC} $*"; }
title(){ echo -e "\n${BOLD}${ORANGE}==== $* ====${NC}\n"; }
pause(){ read -r -p "按回车返回菜单..." _ || true; }
ask_yn_default_yes() {
  local a; printf '%s [Y/n]: ' "$1"; read -r a || true; a="${a:-y}"
  case "${a,,}" in y|yes|"") return 0 ;; *) return 1 ;; esac
}
ask_yn_default_no() {
  local a; printf '%s [y/N]: ' "$1"; read -r a || true; a="${a:-n}"
  case "${a,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}
validate_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "用户名不合法: $u"; return 1; }
}


CF_TOKEN_FILE="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
CF_DIR="${CF_DIR:-/etc/cloudflared}"
S6_SCAN_DIR="${S6_SCAN_DIR:-/run/service}"
LAST_USER=""
LAST_PASS=""
QUICK_SSH_USER="${QUICK_SSH_USER:-kkb}"
QUICK_SSH_PID="${QUICK_SSH_PID:-/run/sys-mgr-quick-ssh.pid}"
QUICK_SSH_LOG="${QUICK_SSH_LOG:-/var/log/sys-mgr-quick-ssh.log}"
QUICK_SSH_URL="${QUICK_SSH_URL:-/run/sys-mgr-quick-ssh.url}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"

# 确保以 root 用户运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
  exit 1
fi

# ==============================================================================
# 服务管理器探测：以 PID 1 为准（关键修复点）
# 说明：本环境装了 systemctl 二进制，但 PID 1 是 supervisord，
#       真正的服务由 supervisord 管理，故不能仅凭 systemctl 是否存在判定。
# ==============================================================================
get_manager() {
  local pid1
  pid1=$(cat /proc/1/comm 2>/dev/null)
  # 1) 真 systemd
  if [ "$pid1" = "systemd" ] && command -v systemctl &>/dev/null; then
    echo "systemd"; return
  fi
  # 2) CloudStudio：仅当 PID1 就是 supervisord（已验证有效，勿改 conf 探测）
  if [ "$pid1" = "supervisord" ]; then
    echo "supervisord"; return
  fi
  # 3) s6（勿被 supervisorctl 二进制误吸）
  case "$pid1" in
    s6-svscan|s6-supervise) echo "s6"; return ;;
  esac
  # 4) runit
  case "$pid1" in
    runit|runsvdir) echo "runit"; return ;;
  esac
  if command -v rc-update &>/dev/null || command -v rc-service &>/dev/null; then
    echo "openrc"; return
  fi
  if [ -f /etc/init.d/rc ] || command -v service &>/dev/null; then
    echo "sysvinit"; return
  fi
  # 禁止「仅有 systemctl/supervisorctl 就认定」
  echo "unknown"
}

# 动态探测 supervisord 真正 include 的配置目录（关键修复点）
# 不再写死 /etc/supervisor/conf.d（本环境根本不读它）
# 从 supervisord 主 conf 解析 [include] files= 得到目录列表（每行一个目录）
# 权威来源：进程 -c 指定的 conf，而不是「磁盘上哪个目录有垃圾 .conf」
_supervisor_dirs_from_main_conf() {
  local cfg="$1"
  [ -f "$cfg" ] || return 1
  local files_line
  files_line=$(awk '/^\[include\]/{f=1;next} f&&/^[[:space:]]*files/{sub(/.*=/,"");print;f=0}' "$cfg")
  [ -n "$files_line" ] || return 1
  echo "$files_line" | tr ' ' '\n' | while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    local d="${pat%/*}"
    d=$(printf '%s' "$d" | sed -E 's/%\(ENV_([A-Za-z_]+)\)s/${\1}/g')
    d=$(eval echo "$d" 2>/dev/null)
    [ -n "$d" ] && [ -d "$d" ] && echo "$d"
  done
}

# 在目录列表中按 CloudStudio 优先规则选一个：pref > 含 conf 的 > 第一个
_supervisor_pick_from_dirs() {
  local all_found="$1"
  local pref="/usr/local/share/supervisor"
  [ -z "$all_found" ] && return 1
  if echo "$all_found" | grep -qx "$pref"; then
    echo "$pref"; return 0
  fi
  # 优先：include 列表里且已有 *.conf 的（减少空目录）
  local d
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    # 排除明显临时名（弱规则，不碰 pref 成功路径）
    case "$d" in
      *_run*|*/tmp/*|*/temp/*) continue ;;
    esac
    if ls "$d"/*.conf >/dev/null 2>&1; then
      echo "$d"; return 0
    fi
  done <<EOF
$all_found
EOF
  local first
  first=$(echo "$all_found" | head -n1)
  [ -n "$first" ] && { echo "$first"; return 0; }
  return 1
}

# 动态探测 supervisord 真正 include 的配置目录（关键修复点）
# 权威：/proc/1/cmdline 的 -c 主 conf → [include] files=
# CloudStudio：pref=/usr/local/share/supervisor 优先（已验证）
# 其它厂商：主 conf 解析失败时，再扫常见主 conf 的 include，最后才目录兜底
get_supervisor_conf_dir() {
  local cfg all_found picked
  local pref="/usr/local/share/supervisor"

  # ---------- ① 进程 cmdline -c（最权威）----------
  cfg=$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | grep -oE '\-c [^ ]+' | awk '{print $2}')
  [ -z "$cfg" ] && cfg="/etc/supervisord.conf"

  if [ -f "$cfg" ]; then
    all_found=$(_supervisor_dirs_from_main_conf "$cfg")
    if picked=$(_supervisor_pick_from_dirs "$all_found"); then
      # 来源：进程主 conf 的 include（CloudStudio 标准路径仍优先）
      echo "$picked"
      return 0
    fi
    # 有 -c 主 conf，但无 [include] 或 include 目录均不存在：
    # 用主 conf 同级 conf.d / 主 conf 目录（兼容 /.随机串/.../supervisord-conf/）
    # 不影响上面 include→pref 成功路径
    local cfg_dir conf_d
    cfg_dir=$(dirname "$cfg")
    conf_d="${cfg_dir}/conf.d"
    if mkdir -p "$conf_d" 2>/dev/null && [ -w "$conf_d" ]; then
      echo "$conf_d"
      return 0
    fi
    if [ -n "$cfg_dir" ] && [ "$cfg_dir" != "." ] && mkdir -p "$cfg_dir" 2>/dev/null && [ -w "$cfg_dir" ]; then
      echo "$cfg_dir"
      return 0
    fi
  fi

  # ---------- ② 其它常见主 conf：仍读 include；失败则 conf 旁 conf.d ----------
  local try_cfg
  for try_cfg in \
    /etc/supervisord.conf \
    /etc/supervisor/supervisord.conf \
    /usr/local/etc/supervisord.conf \
    /usr/local/etc/supervisor/supervisord.conf \
    /etc/supervisor.conf
  do
    [ -f "$try_cfg" ] || continue
    [ "$try_cfg" = "$cfg" ] && continue
    all_found=$(_supervisor_dirs_from_main_conf "$try_cfg")
    if picked=$(_supervisor_pick_from_dirs "$all_found"); then
      echo "$picked"
      return 0
    fi
    # 无 include：主 conf 旁 conf.d
    local td tdd
    td=$(dirname "$try_cfg")
    tdd="${td}/conf.d"
    if mkdir -p "$tdd" 2>/dev/null && [ -w "$tdd" ]; then
      echo "$tdd"
      return 0
    fi
  done

  # ---------- ③ 最后兜底：固定目录（仅当完全解析不到时）----------
  local cand
  for cand in \
    "$pref" \
    /etc/supervisor/conf.d \
    /etc/supervisord.d \
    /etc/supervisor.d \
    /usr/local/etc/supervisor/conf.d \
    /usr/local/etc/supervisord.d \
    /var/lib/supervisor/conf.d \
    /etc/supervisor/conf \
    /opt/supervisor/conf.d
  do
    if [ -d "$cand" ] && [ -w "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  for cand in "$pref" /etc/supervisor/conf.d /etc/supervisord.d; do
    if [ -d "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

# 辅助函数：寻找 supervisorctl 真实路径
find_supervisorctl() {
  if command -v supervisorctl &>/dev/null; then
    command -v supervisorctl
  else
    find /usr /local /opt -name supervisorctl 2>/dev/null | head -n 1
  fi
}

cron_daemon_running() {
  pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 \
    || pgrep -f '[c]ron(d)? ' >/dev/null 2>&1
}

# ---------- SSH 一键准备：hostkey / 密码登录 / root登录 / :22 ----------
SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/99-sys-manager-password.conf}"

port_22_listening() {
  ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' \
    || netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' \
    || (echo >/dev/tcp/127.0.0.1/22) &>/dev/null
}

sshd_bin() {
  if [[ -x /usr/sbin/sshd ]]; then echo /usr/sbin/sshd
  elif command -v sshd &>/dev/null; then command -v sshd
  else echo ""; fi
}

ensure_ssh_host_keys() {
  mkdir -p /etc/ssh /run/sshd /var/run/sshd 2>/dev/null || true
  if [[ -f /etc/ssh/ssh_host_rsa_key || -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_ecdsa_key ]]; then
    echo -e "  ${GREEN}[hostkey]${NC} 已有主机密钥，跳过生成。"
    return 0
  fi
  echo -e "  ${YELLOW}[hostkey]${NC} 未检测到 host key，正在 ssh-keygen -A ..."
  ssh-keygen -A 2>/dev/null || true
  if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" 2>/dev/null || true
  fi
  if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
    ssh-keygen -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N "" 2>/dev/null || true
  fi
  if [[ -f /etc/ssh/ssh_host_rsa_key || -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_ecdsa_key ]]; then
    echo -e "  ${GREEN}[hostkey]${NC} 主机密钥已就绪。"
    return 0
  fi
  echo -e "  ${RED}[hostkey]${NC} 仍无 host key，sshd 无法启动。"
  ls -la /etc/ssh/ssh_host_* 2>/dev/null || true
  return 1
}

# 兼容旧名
warn_if_password_auth_disabled() {
  ensure_ssh_password_login
}

# 开启密码登录 + 允许 root 密码登录
ensure_ssh_password_login() {
  local bin pa pr need=0
  bin="$(sshd_bin)"
  mkdir -p /etc/ssh/sshd_config.d 2>/dev/null || true

  pa=$("$bin" -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
  pr=$("$bin" -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
  if [ "$pa" != "yes" ]; then need=1; fi
  if [ "$pr" != "yes" ]; then need=1; fi

  if [ "$need" -eq 0 ]; then
    echo -e "  ${GREEN}[auth]${NC} PasswordAuthentication=${pa:-yes}  PermitRootLogin=${pr:-yes}"
    return 0
  fi

  echo -e "  ${YELLOW}[auth]${NC} 写入 $SSHD_DROPIN ..."
  cat >"$SSHD_DROPIN" <<'EOF'
# managed by sys_manager.sh — 隧道/密码登录
PasswordAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
  if [ -n "$bin" ] && ! "$bin" -t 2>/dev/null; then
    echo -e "  ${RED}[auth]${NC} sshd -t 失败，已删除 drop-in。"
    rm -f "$SSHD_DROPIN"
    return 1
  fi
  if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
      || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  fi
  local pid
  pid=$(pgrep -xo sshd 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -HUP "$pid" 2>/dev/null || true
  fi
  if [ -e /run/service/svc-sshd ] && command -v s6-svc &>/dev/null; then
    s6-svc -h /run/service/svc-sshd 2>/dev/null || s6-svc -u /run/service/svc-sshd 2>/dev/null || true
  fi
  sleep 1
  pa=$("$bin" -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
  pr=$("$bin" -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
  if [ "$pa" = "yes" ] && [ "$pr" = "yes" ]; then
    echo -e "  ${GREEN}[auth]${NC} 已生效: PasswordAuthentication=yes  PermitRootLogin=yes"
    return 0
  fi
  echo -e "  ${YELLOW}[auth]${NC} 已写 drop-in，sshd -T: password=${pa:-?} rootlogin=${pr:-?}"
  return 0
}

reload_or_start_sshd() {
  local bin
  bin="$(sshd_bin)"
  [ -n "$bin" ] || return 1
  if port_22_listening; then
    local pid
    pid=$(pgrep -xo sshd 2>/dev/null || true)
    [ -n "$pid" ] && kill -HUP "$pid" 2>/dev/null || true
    return 0
  fi
  if [ -e /run/service/svc-sshd ] && command -v s6-svc &>/dev/null; then
    s6-svc -u /run/service/svc-sshd 2>/dev/null || true
    sleep 1
    port_22_listening && return 0
  fi
  if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    sleep 1
    port_22_listening && return 0
  fi
  service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
  sleep 1
  port_22_listening && return 0
  "$bin" 2>/dev/null || true
  sleep 1
  port_22_listening
}

ensure_sshd_running() {
  echo -e "${CYAN}[SSH] 检查 host key / 密码登录 / root 登录 / :22 ...${NC}"
  ensure_ssh_host_keys || return 1
  ensure_ssh_password_login || true
  local bin
  bin="$(sshd_bin)"
  if [ -z "$bin" ]; then
    echo -e "  ${RED}未找到 sshd，请安装 openssh-server。${NC}"
    return 1
  fi
  if ! "$bin" -t 2>/dev/null; then
    echo -e "  ${RED}sshd -t 失败，请检查配置。${NC}"
    "$bin" -t 2>&1 | tail -5
    return 1
  fi
  if port_22_listening; then
    echo -e "  ${GREEN}[:22]${NC} 已在监听。"
  else
    echo -e "  ${YELLOW}[:22]${NC} 未监听，正在启动 sshd ..."
    reload_or_start_sshd || true
    sleep 1
  fi
  if port_22_listening; then
    echo -e "  ${GREEN}[:22]${NC} 监听正常。"
    return 0
  fi
  echo -e "  ${RED}[:22]${NC} 仍未监听。可: $bin -D -e 看报错"
  return 1
}

prepare_ssh_for_tunnel() {
  echo -e "${CYAN}${BOLD}▶ SSH 一键准备（hostkey / root密码 / 密码登录 / :22）${NC}"
  ensure_root_access || true
  ensure_sshd_running || true
  print_ssh_ready_summary
}

print_ssh_ready_summary() {
  local bin pa pr
  bin="$(sshd_bin)"
  echo -e "${CYAN}---------- SSH 验收清单 ----------${NC}"
  if [[ -f /etc/ssh/ssh_host_rsa_key || -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_ecdsa_key ]]; then
    echo -e "  host key       : ${GREEN}OK${NC}"
  else
    echo -e "  host key       : ${RED}缺失${NC}"
  fi
  local h
  h=$(getent shadow root 2>/dev/null | cut -d: -f2)
  if [[ "$h" == "!"* || "$h" == "*" || -z "$h" ]]; then
    echo -e "  root 密码      : ${RED}未设置${NC}"
  else
    echo -e "  root 密码      : ${GREEN}已设置${NC}"
  fi
  pa=$("$bin" -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')
  pr=$("$bin" -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')
  if [ "$pa" = "yes" ]; then
    echo -e "  密码登录       : ${GREEN}yes${NC}"
  else
    echo -e "  密码登录       : ${RED}${pa:-?}${NC}"
  fi
  if [ "$pr" = "yes" ]; then
    echo -e "  PermitRootLogin: ${GREEN}yes${NC}"
  else
    echo -e "  PermitRootLogin: ${YELLOW}${pr:-?}${NC}"
  fi
  if port_22_listening; then
    echo -e "  :22 监听       : ${GREEN}OK${NC}"
  else
    echo -e "  :22 监听       : ${RED}未监听${NC}"
  fi
  if pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
    echo -e "  cloudflared    : ${GREEN}运行中${NC}"
  else
    echo -e "  cloudflared    : ${YELLOW}未运行（菜单 3 配置隧道）${NC}"
  fi
  echo -e "${CYAN}----------------------------------${NC}"
  echo -e " 客户端示例（固定域名 Access）:"
  echo -e "  ${BOLD}cloudflared access tcp --hostname <你的ssh域名> --url 127.0.0.1:2222${NC}"
  echo -e "  ${BOLD}ssh -p 2222 root@127.0.0.1${NC}"
}

# 确保 root 有可用密码（否则无法 SSH 登录）
ensure_root_access() {
  local h
  h=$(getent shadow root | cut -d: -f2)
  if [[ "$h" == "!"* || "$h" == "*" || -z "$h" ]]; then
    echo -e "${YELLOW}检测到 root 未设置密码，无法 SSH 登录。${NC}"
    local pw=""
    while true; do
      printf '请设置 root 密码: '
      stty -echo
      read -r pw
      stty echo
      echo
      if [ -z "$pw" ]; then
        echo -e "${RED}密码不能为空，请重试。${NC}"
        continue
      fi
      break
    done
    if echo "root:$pw" | chpasswd; then
      echo -e "  ${GREEN}root 密码已设置。${NC}"
    else
      echo -e "  ${RED}chpasswd 失败。${NC}"
      return 1
    fi
  else
    echo -e "  root 密码已存在，跳过。"
  fi
}

# 下载并安装 bore 客户端
install_bore() {
  local ver="0.6.0" url tmp="/tmp/bore.tgz" asset
  case "$(uname -m)" in
    x86_64|amd64) asset="bore-v${ver}-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64|arm64) asset="bore-v${ver}-aarch64-unknown-linux-musl.tar.gz" ;;
    *)
      echo -e "${RED}不支持的架构: $(uname -m)，无法自动安装 bore。${NC}"
      return 1
      ;;
  esac
  url="https://github.com/ekzhang/bore/releases/download/v${ver}/${asset}"
  echo -e "${CYAN}正在下载 bore v${ver} (${asset}) ...${NC}"
  if command -v curl &>/dev/null; then
    curl -sSL -A "Mozilla/5.0" -o "$tmp" "$url" || { echo -e "${RED}下载失败${NC}"; return 1; }
  elif command -v wget &>/dev/null; then
    wget -q -O "$tmp" "$url" || { echo -e "${RED}下载失败${NC}"; return 1; }
  else
    echo -e "${RED}需要 curl 或 wget${NC}"; return 1
  fi
  tar xzf "$tmp" -C /tmp bore 2>/dev/null || tar xzf "$tmp" -C /tmp || { echo -e "${RED}解压失败${NC}"; return 1; }
  [ -f /tmp/bore ] || { echo -e "${RED}包内无 bore 二进制${NC}"; return 1; }
  install -m 755 /tmp/bore /usr/local/bin/bore
  echo -e "${GREEN}✅ bore 安装完成: $(/usr/local/bin/bore --version 2>&1 | head -1)${NC}"
}

# 等待 bore 在日志中输出公网端口
wait_bore_port() {
  local log="/tmp/bore.log" i PORT
  for i in $(seq 1 15); do
    PORT=$(grep -oE 'bore.pub:[0-9]+' "$log" 2>/dev/null | head -1 | cut -d: -f2)
    [ -n "$PORT" ] && { echo "$PORT"; return; }
    sleep 1
  done
}

# 立即（手动）启动某服务，先杀掉已有同名进程避免重复
# 使用 setsid 完全脱离父进程会话，防止启动脚本退出后被连带终止
restart_now() {
  local name="$1" cmd="$2" log="$3"
  # sshd：禁止 pkill -x，避免踢掉当前会话
  if [ "$name" = "sshd" ]; then
    if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' \
       || netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
      echo -e "  ${GREEN}:22 已在监听，跳过重启 sshd（保护当前会话）。${NC}"
      return 0
    fi
    ensure_sshd_running
    return $?
  fi
  pkill -x "$name" 2>/dev/null || true
  sleep 1
  if command -v setsid &>/dev/null; then
    # shellcheck disable=SC2086
    setsid nohup $cmd > "$log" 2>&1 &
  else
    # shellcheck disable=SC2086
    nohup $cmd > "$log" 2>&1 &
  fi
  local pid=$!
  sleep 0.3
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "  ${GREEN}已启动 $name (pid $pid)${NC}"
    return 0
  fi
  echo -e "  ${YELLOW}已尝试启动 $name，请检查 $log${NC}"
  return 1
}

# ==============================================================================
# 通用：把任意服务注册为开机自启（按管理器自适应）
#   $1 = 服务名(程序名)  $2 = 完整启动命令  $3 = 日志文件
# ==============================================================================


# ==============================================================================
# s6 方案1：持久定义在磁盘 + 开机 Hook 补 /run/service 软链
# 不依赖 svc-nginx 等是否存在；只看 PID1=s6 与 hook 目录是否可写
# ==============================================================================
S6_OPT_ROOT="${S6_OPT_ROOT:-/opt/svc}"
S6_RELINK_BIN="${S6_RELINK_BIN:-/opt/svc/s6-relink-sys-manager.sh}"
S6_HOOK_NAME="99-sys-manager-s6-relink"

# 探测「每次容器启动会执行」的目录（有哪个用哪个，不要求有 nginx）
find_s6_boot_hook_dirs() {
  local d
  for d in \
    /etc/cont-init.d \
    /custom-cont-init.d \
    /config/custom-cont-init.d \
    /etc/s6-overlay/s6-rc.d/user/contents.d \
    /etc/cont-init.d.d
  do
    # contents.d 是文件列表不是脚本目录，单独处理
    if [ "$d" = "/etc/s6-overlay/s6-rc.d/user/contents.d" ]; then
      continue
    fi
    if [ -d "$d" ] && [ -w "$d" ]; then
      echo "$d"
    fi
  done
}

# 写统一 relink 脚本（磁盘持久）；开机 hook 与手动修复都调它
install_s6_relink_script() {
  mkdir -p "$(dirname "$S6_RELINK_BIN")" "$S6_OPT_ROOT" 2>/dev/null || true
  local scan="${S6_SCAN_DIR:-/run/service}"
  local opt="${S6_OPT_ROOT:-/opt/svc}"
  cat >"$S6_RELINK_BIN" <<RELINK
#!/bin/sh
# sys_manager: 重启后把磁盘上的服务定义重新链到 /run/service（tmpfs）
# 不依赖 svc-nginx 是否存在
SCAN="${scan}"
OPT="${opt}"
LOG="/var/log/s6-relink-sys-manager.log"
mkdir -p "\$SCAN" "\$(dirname "\$LOG")" 2>/dev/null || true
echo "\$(date -Iseconds 2>/dev/null || date): s6-relink start" >>"\$LOG"

i=0
while [ "\$i" -lt 30 ]; do
  if [ -d "\$SCAN" ]; then
    break
  fi
  i=\$((i + 1))
  sleep 1
done

for def in "\$OPT"/*/s6; do
  [ -d "\$def" ] || continue
  [ -x "\$def/run" ] || continue
  name=\$(basename "\$(dirname "\$def")")
  link="svc-\${name}"
  ln -sfn "\$def" "\$SCAN/\$link" 2>>"\$LOG" || true
  echo "linked \$SCAN/\$link -> \$def" >>"\$LOG"
done

if command -v s6-svscanctl >/dev/null 2>&1; then
  s6-svscanctl -a "\$SCAN" >>"\$LOG" 2>&1 || true
fi
sleep 1
for def in "\$OPT"/*/s6; do
  [ -d "\$def" ] || continue
  name=\$(basename "\$(dirname "\$def")")
  link="svc-\${name}"
  if command -v s6-svc >/dev/null 2>&1 && [ -e "\$SCAN/\$link" ]; then
    s6-svc -u "\$SCAN/\$link" >>"\$LOG" 2>&1 || true
  fi
done
echo "\$(date -Iseconds 2>/dev/null || date): s6-relink done" >>"\$LOG"
RELINK
  chmod +x "$S6_RELINK_BIN"
}

install_s6_boot_hook() {
  install_s6_relink_script
  local dirs d hook path n=0
  dirs=$(find_s6_boot_hook_dirs)
  if [ -z "$dirs" ]; then
    echo -e "  ${YELLOW}未找到可写 cont-init 目录 → 无法安装开机补链 hook${NC}"
    echo -e "  ${YELLOW}已写持久定义与 relink 脚本: $S6_RELINK_BIN${NC}"
    echo -e "  ${YELLOW}重启后 /run 会丢链接；请手动: $S6_RELINK_BIN 或菜单「修复 s6 链接」${NC}"
    return 1
  fi
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    path="$d/${S6_HOOK_NAME}"
    # cont-init 脚本通常无扩展名、可执行
    cat >"$path" <<EOF
#!/usr/bin/with-contenv sh
# 由 sys_manager 安装：每次启动补 s6 服务软链（不依赖 svc-nginx）
# 若 with-contenv 不存在，下面 shebang 失败时用 /bin/sh 再装一份
exec ${S6_RELINK_BIN}
EOF
    # 无 with-contenv 的镜像：纯 sh
    if [ ! -x /usr/bin/with-contenv ] && [ ! -x /command/with-contenv ]; then
      cat >"$path" <<EOF
#!/bin/sh
exec ${S6_RELINK_BIN}
EOF
    fi
    chmod +x "$path"
    echo -e "  ${GREEN}开机 hook: $path${NC}"
    n=$((n + 1))
  done <<EOF
$dirs
EOF
  [ "$n" -gt 0 ]
}

# 当前会话立刻 relink（菜单修复 / enable 后调用）
s6_relink_now() {
  install_s6_relink_script
  if [ -x "$S6_RELINK_BIN" ]; then
    "$S6_RELINK_BIN"
    return $?
  fi
  return 1
}

# s6：创建 longrun 并链入 /run/service（适配 workbuddy 的 svc-* 风格）
enable_service_s6() {
  local name="$1" cmd="$2" log="${3:-/var/log/$1.log}"
  local scan="${S6_SCAN_DIR:-/run/service}"
  local defdir="/opt/svc/${name}/s6"
  local linkname="svc-${name}"

  mkdir -p "$scan" "$defdir" /opt/svc/"$name" 2>/dev/null || true
  mkdir -p "$(dirname "$log")" 2>/dev/null || true

  if [ "$name" = "sshd" ]; then
    local bin="/usr/sbin/sshd"
    [ -x "$bin" ] || bin="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
    # -D 前台；-e 日志走 stderr。缺 host key 时 exit 255 是常见原因
    cat >"$defdir/run" <<EOF
#!/bin/sh
exec 2>&1
mkdir -p /run/sshd /var/run/sshd /etc/ssh

# 必须有 host key，否则 sshd 直接: no hostkeys available -- exiting (255)
if [ ! -f /etc/ssh/ssh_host_rsa_key ] && [ ! -f /etc/ssh/ssh_host_ed25519_key ] && [ ! -f /etc/ssh/ssh_host_ecdsa_key ]; then
  echo "no host keys, running ssh-keygen -A"
  ssh-keygen -A 2>&1 || true
fi
# 仍没有则逐个生成
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" 2>&1 || true
fi
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -b 3072 -f /etc/ssh/ssh_host_rsa_key -N "" 2>&1 || true
fi
if [ ! -f /etc/ssh/ssh_host_rsa_key ] && [ ! -f /etc/ssh/ssh_host_ed25519_key ] && [ ! -f /etc/ssh/ssh_host_ecdsa_key ]; then
  echo "FATAL: still no host keys under /etc/ssh after ssh-keygen"
  ls -la /etc/ssh/ 2>&1 || true
  sleep 15
  exit 1
fi

if ! $bin -t 2>&1; then
  echo "sshd -t failed, sleep 10"
  sleep 10
  exit 1
fi

# :22 被散养 sshd 占用时先清掉，否则 -D bind 失败 → 255
if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' || netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
  echo "port 22 busy, stopping orphan sshd for s6 -D takeover"
  pkill -x sshd 2>/dev/null || true
  sleep 1
fi

exec $bin -D -e
EOF
  elif [ "$name" = "cloudflared" ]; then
    cat >"$defdir/run" <<EOF
#!/bin/sh
exec 2>&1
TOKEN_FILE="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
CFBIN="\$(command -v cloudflared 2>/dev/null || true)"
[ -z "\$CFBIN" ] && [ -x /usr/local/bin/cloudflared ] && CFBIN=/usr/local/bin/cloudflared
[ -z "\$CFBIN" ] && [ -x /root/cloudflared ] && CFBIN=/root/cloudflared
if [ -z "\$CFBIN" ] || [ ! -x "\$CFBIN" ]; then
  echo "cloudflared missing"; sleep 30; exit 1
fi
if [ -s "\$TOKEN_FILE" ]; then
  TOK=\$(tr -d '\\r\\n' < "\$TOKEN_FILE")
  exec "\$CFBIN" --no-autoupdate tunnel run --token "\$TOK"
fi
exec $cmd
EOF
  else
    cat >"$defdir/run" <<EOF
#!/bin/sh
exec 2>&1
exec $cmd
EOF
  fi
  chmod +x "$defdir/run"
  cat >"$defdir/finish" <<EOF
#!/bin/sh
echo "\$(date -Iseconds 2>/dev/null || date): $name exited \$1" >> "$log"
exec sleep 2
EOF
  chmod +x "$defdir/finish"

  ln -sfn "$defdir" "$scan/$linkname"
  echo -e "${GREEN}✅ s6 已链接 ${scan}/${linkname} -> ${defdir}${NC}"

  command -v s6-svscanctl >/dev/null 2>&1 && s6-svscanctl -a "$scan" 2>/dev/null || true

  # sshd：交给 s6 独占 -D，不要再 ensure_sshd_running（会起守护进程抢 :22 → s6 里 exit 255）
  if [ "$name" = "sshd" ]; then
    if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' \
       || netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
      echo -e "  ${YELLOW}:22 已被占用，结束散养 sshd 后由 s6 前台接管（可能短暂断 SSH）${NC}"
      pkill -x sshd 2>/dev/null || true
      sleep 1
    fi
    command -v s6-svc >/dev/null 2>&1 && s6-svc -u "$scan/$linkname" 2>/dev/null || true
    sleep 2
    if command -v s6-svc >/dev/null 2>&1; then
      # 若仍 down，再 up 一次
      s6-svstat "$scan/$linkname" 2>/dev/null | grep -q '^up' || s6-svc -u "$scan/$linkname" 2>/dev/null || true
      sleep 1
    fi
  elif [ "$name" = "cloudflared" ]; then
    command -v s6-svc >/dev/null 2>&1 && s6-svc -u "$scan/$linkname" 2>/dev/null || true
    if ! pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
      restart_now "$name" "$cmd" "$log"
    else
      echo -e "  ${GREEN}cloudflared 已在运行。${NC}"
    fi
  else
    command -v s6-svc >/dev/null 2>&1 && s6-svc -u "$scan/$linkname" 2>/dev/null || true
    restart_now "$name" "$cmd" "$log"
  fi
  sleep 1
  if command -v s6-svstat >/dev/null 2>&1; then
    echo -e "  s6-svstat: $(s6-svstat "$scan/$linkname" 2>/dev/null || echo n/a)"
  fi
  if [ "$name" = "sshd" ]; then
    if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
      echo -e "  ${GREEN}验收: :22 在监听${NC}"
    else
      echo -e "  ${YELLOW}验收: :22 仍未监听。请在机器上执行:${NC}"
      echo -e "    cat /opt/svc/sshd/s6/run"
      echo -e "    s6-svstat /run/service/svc-sshd"
      echo -e "    /usr/sbin/sshd -t; /usr/sbin/sshd -D -e   # 前台看报错"
    fi
  fi
  # 方案1：安装开机 hook（不依赖是否已有 svc-nginx）
  local hook_ok=0
  if install_s6_boot_hook; then
    hook_ok=1
  fi
  # 再跑一次 relink 确保当前完整
  s6_relink_now >/dev/null 2>&1 || true

  echo -e "${CYAN}---------- s6 持久化验收 ----------${NC}"
  if [ -x "$defdir/run" ]; then
    echo -e "  持久定义: ${GREEN}OK${NC} $defdir/run"
  else
    echo -e "  持久定义: ${RED}缺失${NC}"
  fi
  if [ -e "$scan/$linkname" ]; then
    echo -e "  当前链接: ${GREEN}OK${NC} $scan/$linkname  (位于 tmpfs，重启会丢，靠 hook 补)"
  else
    echo -e "  当前链接: ${YELLOW}无${NC} $scan/$linkname"
  fi
  if [ "$hook_ok" -eq 1 ]; then
    echo -e "  开机 hook: ${GREEN}已安装${NC} → 容器重启后应自动补链"
    echo -e "${GREEN}✅ 当前已注册；并已安装开机补链（方案1）${NC}"
  else
    echo -e "  开机 hook: ${RED}未安装${NC} → ${YELLOW}仅当前会话有效，重启后需重跑菜单或手动 $S6_RELINK_BIN${NC}"
    echo -e "${YELLOW}⚠️ 未宣称「永久开机自启」：本镜像无可用 cont-init 类目录${NC}"
  fi
  echo -e "${CYAN}----------------------------------${NC}"
}

enable_service() {
  local name="$1" cmd="$2" log="${3:-/var/log/$1.log}"
  local mgr; mgr=$(get_manager)
  case "$mgr" in
    systemd)
      local sf="/etc/systemd/system/$name.service"
      cat > "$sf" <<EOF
[Unit]
Description=$name service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$cmd
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable "$name"
      systemctl restart "$name"
      echo -e "${GREEN}✅ 已通过 Systemd 启用 $name 并启动。${NC}"
      ;;
    supervisord)
      local dir; dir=$(get_supervisor_conf_dir)
      if [ -z "$dir" ]; then
        echo -e "${YELLOW}⚠️ 无法定位 supervisord 配置目录，回退为手动后台启动（无开机自启）。${NC}"
        restart_now "$name" "$cmd" "$log"
        return
      fi
      mkdir -p "$dir"
      cat > "$dir/$name.conf" <<EOF
[program:$name]
command=$cmd
autostart=true
autorestart=true
startsecs=5
user=root
redirect_stderr=true
stdout_logfile=$log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=5
EOF
      echo -e "${GREEN}✅ 已将 $name 配置写入 $dir/$name.conf${NC}"
      echo -e "  ${CYAN}（CloudStudio：完整重启后由 PID1=supervisord 读 conf；当前见下方启动结果）${NC}"
      # 立即启动（手动），避免 HUP 重启所有服务造成中断
      if [ "$name" = "sshd" ] && pgrep -x sshd >/dev/null; then
        echo -e "  sshd 已在运行，保留当前实例（不 pkill；重启沙箱后由 supervisord 读 conf）。"
      else
        restart_now "$name" "$cmd" "$log"
      fi
      # 可选：立即交给 supervisord 托管（会短暂重启所有服务）
      printf '%s' "是否立即重载 supervisord 使【当前会话】也由其托管？(会短暂重启所有服务) [y/N]: "
      read -r hup
      if [[ "$hup" =~ ^[Yy] ]]; then
        echo -e "${YELLOW}正在向 PID1 发送 HUP 重载 supervisord ...${NC}"
        kill -HUP 1 2>/dev/null || true
        echo -e "${GREEN}已完成。若终端断开，重连即可。${NC}"
      else
        echo -e "  已跳过 HUP。当前为手动/setsid 运行；沙箱完整重启后由 supervisord 读 conf。"
      fi
      ;;
    s6)
      enable_service_s6 "$name" "$cmd" "$log"
      ;;
    openrc)
      cat > "/etc/init.d/$name" <<EOF
#!/sbin/openrc-run
command="$cmd"
pidfile="/run/$name.pid"
EOF
      chmod +x "/etc/init.d/$name"
      rc-update add "$name" default
      "/etc/init.d/$name" restart
      echo -e "${GREEN}✅ 已通过 OpenRC 启用 $name。${NC}"
      ;;
    sysvinit)
      cat > "/etc/init.d/$name" <<EOF
#!/bin/bash
NAME="$name"
LOG="$log"
CMD='$cmd'
case "\$1" in
  start)
    mkdir -p /run
    if [ "\$NAME" = "sshd" ]; then
      mkdir -p /run/sshd
      /usr/sbin/sshd 2>/dev/null || true
    else
      nohup \$CMD > "\$LOG" 2>&1 &
      echo \$! > /run/\${NAME}.pid
    fi
    ;;
  stop)
    if [ "\$NAME" = "sshd" ]; then
      [ -f /var/run/sshd.pid ] && kill "\$(cat /var/run/sshd.pid)" 2>/dev/null || true
    else
      [ -f /run/\${NAME}.pid ] && kill "\$(cat /run/\${NAME}.pid)" 2>/dev/null || true
    fi
    ;;
  restart) "\$0" stop; sleep 1; "\$0" start ;;
esac
EOF
      chmod +x "/etc/init.d/$name"
      if command -v update-rc.d &>/dev/null; then update-rc.d "$name" defaults; fi
      "/etc/init.d/$name" restart
      echo -e "${GREEN}✅ 已通过 SysVinit 启用 $name。${NC}"
      ;;
    *)
      if ! command -v crontab &>/dev/null; then
        echo -e "${YELLOW}无 crontab，仅手动启动 $name。${NC}"
        restart_now "$name" "$cmd" "$log"
        return
      fi
      local line="@reboot nohup $cmd > $log 2>&1 &"
      # 去重：去掉含服务名的旧行
      (crontab -l 2>/dev/null | grep -vF "$name" || true; echo "$line") | crontab - 2>/dev/null \
        || { echo -e "${RED}crontab 写入失败${NC}"; restart_now "$name" "$cmd" "$log"; return; }
      restart_now "$name" "$cmd" "$log"
      if cron_daemon_running; then
        echo -e "${GREEN}✅ 已写 crontab @reboot 且 cron 在跑；$name 当前已尝试启动。${NC}"
      else
        echo -e "${YELLOW}⚠️ crontab 已写入，但未检测到 cron/crond → @reboot 在本环境【基本无效】。${NC}"
        echo -e "  $name 已尝试手动启动；容器/沙箱重启后请重新执行本菜单。"
      fi
      ;;
  esac
}

# ==============================================================================
# 功能 1：查看系统详情
# ==============================================================================
show_system_info() {
  clear
  echo -e "${CYAN}${BOLD}▶ [系统详情概览]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"

  OS_NAME=$(grep -oP '(?<=^PRETTY_NAME=")[^"]*' /etc/os-release 2>/dev/null || cat /etc/issue | tr -d '\n')
  KERNEL=$(uname -r)
  ARCH=$(uname -m)
  UPTIME=$(uptime -p 2>/dev/null || uptime | awk -F'(, ?)+' '{print $2}')
  CPU_MODEL=$(lscpu 2>/dev/null | grep "Model name" | awk -F: '{print $2}' | xargs || cat /proc/cpuinfo | grep 'model name' | head -n1 | awk -F: '{print $2}' | xargs)
  CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)

  if command -v free &>/dev/null; then
    MEM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -h | awk '/Mem:/ {print $3}')
    MEM_FREE=$(free -h | awk '/Mem:/ {print $4}')
  else
    MEM_TOTAL="N/A"; MEM_USED="N/A"; MEM_FREE="N/A"
  fi

  DISK_USAGE=$(df -h / | awk 'NR==2 {print "总计: " $2 "  |  已用: " $3 "  |  可用: " $4 "  (使用率: " $5 ")"}')

  printf " ${BOLD}%-14s${NC} : %s\n" "操作系统" "${OS_NAME:-未知系统}"
  printf " ${BOLD}%-14s${NC} : %s (%s)\n" "内核与架构" "$KERNEL" "$ARCH"
  printf " ${BOLD}%-14s${NC} : %s (%s 核)\n" "CPU 型号" "${CPU_MODEL:-通用虚拟处理器}" "$CPU_CORES"
  printf " ${BOLD}%-14s${NC} : 总计 ${BLUE}%s${NC} | 已用 ${YELLOW}%s${NC} | 剩余 ${GREEN}%s${NC}\n" "内存状态" "$MEM_TOTAL" "$MEM_USED" "$MEM_FREE"
  printf " ${BOLD}%-14s${NC} : %s\n" "根目录磁盘" "$DISK_USAGE"
  printf " ${BOLD}%-14s${NC} : %s\n" "运行时间" "${UPTIME:-未知}"
  echo -e "${CYAN}--------------------------------------------------${NC}"
}

# ==============================================================================
# 功能 2：查看系统 Init 与服务
# ==============================================================================
show_init_and_services() {
  clear
  echo -e "${CYAN}${BOLD}▶ [系统 Init 与开机自启项目]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"

  PID1_CMD=$(cat /proc/1/comm 2>/dev/null)
  MANAGER=$(get_manager)

  echo -e " 当前 PID 1 进程 : ${BOLD}$PID1_CMD${NC}"
  if command -v ps &>/dev/null; then
    echo -e " ${BOLD}ps -p 1:${NC}"
    ps -p 1 -o pid,ppid,user,comm,args 2>/dev/null || ps -p 1 2>/dev/null || true
  fi
  echo -e " 可用服务管理器 : ${GREEN}${BOLD}$MANAGER${NC}"
  if [ "$MANAGER" = "supervisord" ]; then
    DIR=$(get_supervisor_conf_dir)
    echo -e " supervisord 配置目录 : ${BLUE}${DIR:-未定位}${NC}"
    echo -e "  ${CYAN}(优先: PID1 cmdline -c 主conf 的 [include]；非「有垃圾.conf就选」)${NC}"
    echo -e " 已托管程序:"
    if [ -n "$DIR" ] && [ -d "$DIR" ]; then
      local _any=0
      for f in "$DIR"/*.conf; do
        [ -f "$f" ] || continue
        echo "   - $(basename "$f")"
        _any=1
      done
      [ "$_any" -eq 0 ] && echo "   (目录为空)"
    else
      echo "   (未定位目录，跳过列举)"
    fi
  fi
  echo -e "${CYAN}--------------------------------------------------${NC}"

  case "$MANAGER" in
    systemd)
      echo -e "${BLUE}【Systemd 已启用服务预览】${NC}"
      systemctl list-unit-files --type=service --state=enabled --no-pager 2>/dev/null | head -n 15
      ;;
    supervisord)
      echo -e "${BLUE}【当前运行的相关进程】${NC}"
      local _found=0
      for pat in sshd cloudflared bore; do
        if pgrep -af "$pat" 2>/dev/null | grep -v 'pgrep' | head -3; then
          _found=1
        fi
      done
      [ "$_found" -eq 0 ] && echo "  (无 sshd/cloudflared/bore 在运行)"
      ;;
    s6)
      echo -e "${BLUE}【s6 服务目录 /run/service】${NC}"
      ls -la /run/service 2>/dev/null || ls -la /var/run/s6/services 2>/dev/null || echo "  (无 /run/service)"
      echo -e "${BLUE}【本脚本 CF/SSH】${NC}"
      for n in svc-cloudflared svc-sshd; do
        if [ -e /run/service/$n ]; then
          echo -n "  $n: "
          s6-svstat /run/service/$n 2>/dev/null || ls -la /run/service/$n
        else
          echo "  $n: (未注册，菜单3/4 可装)"
        fi
      done
      ;;
    openrc)
      echo -e "${BLUE}【OpenRC 默认级别服务】${NC}"
      rc-update show
      ;;
    sysvinit)
      echo -e "${BLUE}【SysVinit 服务列表状态】${NC}"
      service --status-all 2>/dev/null || ls /etc/init.d/
      ;;
    *)
      echo "未识别到主流服务管理器，正在检查 rc.local 或 crontab..."
      [ -f /etc/rc.local ] && cat /etc/rc.local
      crontab -l 2>/dev/null || echo "  (无 crontab)"
      if ! cron_daemon_running; then
        echo -e "  ${YELLOW}未检测到 cron/crond，@reboot 可能无效。${NC}"
      fi
      ;;
  esac
  echo -e "${CYAN}--------------------------------------------------${NC}"
}

# ==============================================================================
# 功能 3：配置 Cloudflare 隧道（连接 + 开机自启）
# ==============================================================================
setup_cf_tunnel() {
  clear
  echo -e "${CYAN}${BOLD}▶ [Cloudflare 隧道管理]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"
  local _tf="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  echo -e "  Token 文件: $_tf"
  if [ -s "$_tf" ]; then
    echo -e "  状态: ${GREEN}已有保存的 Token${NC}（可直接选 2 重启，或 1 回车复用）"
  else
    echo -e "  状态: ${YELLOW}尚无 Token${NC}（请选 1 粘贴）"
  fi
  echo -e "  ${GREEN}1.${NC} 粘贴 / 更新 Token 并启动（回车=用已保存 Token）"
  echo -e "  ${GREEN}2.${NC} 用已保存 Token 重启隧道（不改文件）"
  echo -e "  ${GREEN}3.${NC} 查看已保存 Token"
  echo -e "  ${GREEN}4.${NC} 查看所有隧道相关状态"
  echo -e "  ${GREEN}5.${NC} 删除 Token 并停止隧道"
  echo -e "  ${RED}0.${NC} 返回"
  echo -e "${CYAN}--------------------------------------------------${NC}"
  printf '%s' "请选择 [0-5]: "
  read -r cfs
  case "$cfs" in
    1) cf_paste_token_and_start ;;
    2) cf_restart_saved_token ;;
    3) cf_view_token ;;
    4) cf_list_tunnels ;;
    5) cf_delete_token ;;
    0) return ;;
    *) echo -e "${RED}无效选项${NC}" ;;
  esac
}

cf_ensure_bin() {
  if command -v cloudflared &>/dev/null || [ -x /usr/local/bin/cloudflared ] || [ -x /root/cloudflared ]; then
    return 0
  fi
  echo -e "${RED}未找到 cloudflared${NC}"
  return 1
}

# 用磁盘上已有 Token 启动/注册服务（不读 stdin）
cf_start_with_token_file() {
  local f="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  local TOKEN FULL_CMD
  cf_ensure_bin || return 1
  if [ ! -s "$f" ]; then
    echo -e "${RED}无已保存 Token: $f${NC}"
    echo -e "  请先选 1 粘贴 Token。"
    return 1
  fi
  TOKEN=$(tr -d '\r\n' <"$f")
  if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 20 ]; then
    echo -e "${RED}Token 文件无效或过短: $f${NC}"
    return 1
  fi
  FULL_CMD="cloudflared tunnel --no-autoupdate run --token $TOKEN"
  echo -e "${GREEN}使用已保存 Token 启动（$f，长度 ${#TOKEN}）${NC}"
  prepare_ssh_for_tunnel
  enable_service "cloudflared" "$FULL_CMD" "/var/log/cloudflared.log"
  sleep 2
  if pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
    echo -e "${GREEN}✅ cloudflared 进程在运行。${NC}"
  else
    echo -e "${YELLOW}⚠️ 进程未检测到: tail -30 /var/log/cloudflared.log${NC}"
  fi
}

cf_restart_saved_token() {
  echo -e "${CYAN}--- 用已保存 Token 重启 ---${NC}"
  cf_start_with_token_file
}

cf_paste_token_and_start() {
  echo -e "${CYAN}--- 粘贴 / 更新 Token ---${NC}"
  cf_ensure_bin || return 1
  local f="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  if [ -s "$f" ]; then
    echo -e "  已有 Token 文件。${GREEN}直接回车${NC}=沿用并启动；输入新内容=覆盖后启动。"
  else
    echo -e "  尚无保存的 Token，请粘贴 Token 或完整 cloudflared 命令。"
  fi
  printf '%s' "Token/命令（回车=用已保存）: "
  read -r CF_INPUT
  if [ -z "$CF_INPUT" ]; then
    if [ -s "$f" ]; then
      echo -e "${CYAN}未输入新内容 → 使用已保存 Token${NC}"
      cf_start_with_token_file
      return
    fi
    echo -e "${RED}输入为空且无已保存 Token，取消。${NC}"
    return 1
  fi
  local TOKEN FULL_CMD
  if [[ "$CF_INPUT" == *"cloudflared"* ]]; then
    FULL_CMD="$CF_INPUT"
    TOKEN=$(echo "$CF_INPUT" | sed -n 's/.*--token[ =]*//p' | awk '{print $1}')
  else
    TOKEN=$(echo "$CF_INPUT" | tr -d '[:space:]')
    FULL_CMD="cloudflared tunnel --no-autoupdate run --token $TOKEN"
  fi
  mkdir -p "${CF_DIR:-/etc/cloudflared}"
  umask 077
  if [ -n "$TOKEN" ]; then
    printf '%s\n' "$TOKEN" >"$f"
    chmod 600 "$f" 2>/dev/null || true
    echo -e "${GREEN}✅ Token 已写入 $f（覆盖旧值）${NC}"
  fi
  prepare_ssh_for_tunnel
  enable_service "cloudflared" "$FULL_CMD" "/var/log/cloudflared.log"
  sleep 2
  if pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
    echo -e "${GREEN}✅ cloudflared 进程在运行。${NC}"
  else
    echo -e "${YELLOW}⚠️ 进程未检测到: tail -30 /var/log/cloudflared.log${NC}"
  fi
}

cf_view_token() {
  echo -e "${CYAN}--- 查看 Token ---${NC}"
  local f="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  if [ ! -s "$f" ]; then
    echo -e "${YELLOW}无 Token: $f${NC}"
    return
  fi
  local tok
  tok=$(tr -d '\r\n' <"$f")
  echo "  路径: $f"
  echo "  长度: ${#tok}"
  if [ "${#tok}" -gt 24 ]; then
    echo "  脱敏: ${tok:0:12}...${tok: -8}"
  else
    echo "  脱敏: ${tok:0:6}..."
  fi
  printf '%s' "显示完整 Token？[y/N]: "
  read -r show
  if [[ "$show" =~ ^[Yy] ]]; then
    echo "$tok"
  fi
}

cf_list_tunnels() {
  echo -e "${CYAN}--- 隧道状态一览 ---${NC}"
  local f="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  echo " Token: $([ -s "$f" ] && echo "有 $f" || echo "无")"
  echo " 二进制: $(command -v cloudflared 2>/dev/null || ls /usr/local/bin/cloudflared /root/cloudflared 2>/dev/null | head -1 || echo 未安装)"
  echo " 进程:"
  pgrep -af cloudflared 2>/dev/null || echo "  (无)"
  echo " s6:"
  if [ -e /run/service/svc-cloudflared ]; then
    ls -la /run/service/svc-cloudflared
    s6-svstat /run/service/svc-cloudflared 2>/dev/null || true
  else
    echo "  (未注册 svc-cloudflared，菜单3→1 粘贴或 3→2 用已保存重启)"
  fi
  echo " supervisord conf:"
  local dir
  dir=$(get_supervisor_conf_dir 2>/dev/null || true)
  if [ -n "$dir" ] && [ -f "$dir/cloudflared.conf" ]; then
    ls -la "$dir/cloudflared.conf"
  else
    echo "  (无)"
  fi
  echo " 日志尾:"
  tail -12 /var/log/cloudflared.log 2>/dev/null || echo "  (无日志)"
}

cf_delete_token() {
  echo -e "${CYAN}--- 删除 Token / 停隧道 ---${NC}"
  local f="${CF_TOKEN_FILE:-/etc/cloudflared/tunnel.token}"
  printf '%s' "确认删除 $f 并停止 cloudflared？[y/N]: "
  read -r conf
  if [[ ! "$conf" =~ ^[Yy] ]]; then
    echo "已取消。"
    return
  fi
  pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
  if command -v s6-svc >/dev/null 2>&1 && [ -e /run/service/svc-cloudflared ]; then
    s6-svc -d /run/service/svc-cloudflared 2>/dev/null || true
    s6-svc -x /run/service/svc-cloudflared 2>/dev/null || true
    rm -f /run/service/svc-cloudflared
  fi
  local dir
  dir=$(get_supervisor_conf_dir 2>/dev/null || true)
  [ -n "$dir" ] && rm -f "$dir/cloudflared.conf"
  rm -f "$f"
  echo -e "${GREEN}✅ 已删除 Token 并尝试停止隧道。${NC}"
}

setup_ssh() {
  clear
  echo -e "${CYAN}${BOLD}▶ [配置 SSH 自启 + 认证一键处理]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"

  # 自动: root密码 / hostkey / PasswordAuthentication / PermitRootLogin / :22
  prepare_ssh_for_tunnel
  echo
  mkdir -p /run/sshd /var/run/sshd 2>/dev/null || true
  MANAGER=$(get_manager)

  case "$MANAGER" in
    systemd)
      local svc=sshd
      systemctl list-unit-files 2>/dev/null | grep -q "^ssh\.service" && svc=ssh
      systemctl enable "$svc"
      systemctl restart "$svc"
      echo -e "${GREEN}✅ 已通过 Systemd 启用 $svc。${NC}"
      ;;
    supervisord)
      # 用 shell 包装：先确保 /run/sshd 存在（/run 为 tmpfs，重启后可能不存在）
      enable_service "sshd" "/bin/bash -c 'mkdir -p /run/sshd && exec /usr/sbin/sshd -D'" "/var/log/sshd.log"
      ;;
    s6)
      enable_service "sshd" "/bin/bash -c 'mkdir -p /run/sshd && exec /usr/sbin/sshd -D'" "/var/log/sshd.log"
      ;;
    openrc)
      rc-update add sshd default 2>/dev/null || rc-update add ssh default 2>/dev/null || true
      rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null || true
      echo -e "${GREEN}✅ 已通过 OpenRC 启用 sshd。${NC}"
      ;;
    sysvinit)
      update-rc.d ssh defaults 2>/dev/null || update-rc.d sshd defaults 2>/dev/null
      /etc/init.d/ssh restart 2>/dev/null || /etc/init.d/sshd restart 2>/dev/null
      echo -e "${GREEN}✅ 已通过 SysVinit 启用 ssh。${NC}"
      ;;
    *)
      ensure_sshd_running || true
      echo -e "${YELLOW}未识别标准服务管理器，已尝试手动启动 sshd。${NC}"
      if command -v crontab &>/dev/null; then
        local line="@reboot /bin/bash -c 'mkdir -p /run/sshd && /usr/sbin/sshd'"
        (crontab -l 2>/dev/null | grep -vF 'sshd' || true; echo "$line") | crontab - 2>/dev/null || true
        if cron_daemon_running; then
          echo -e "${GREEN}已写 crontab @reboot 且 cron 在跑。${NC}"
        else
          echo -e "${YELLOW}crontab 已写但无 cron 进程，@reboot 可能无效。${NC}"
        fi
      fi
      ;;
  esac
  ensure_ssh_password_login || true
  ensure_sshd_running || true
  echo
  print_ssh_ready_summary
}

# ==============================================================================
# 功能 5：Bore 隧道（bore.pub）：安装 / 连接 / 开机自启
# ==============================================================================
setup_bore() {
  clear
  echo -e "${CYAN}${BOLD}▶ [Bore 隧道 (bore.pub)：安装 / 连接 / 开机自启]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"

  local BORE_BIN="/usr/local/bin/bore"
  if [ ! -x "$BORE_BIN" ]; then
    install_bore || { echo -e "${RED}bore 安装失败，取消。${NC}"; return 1; }
  fi

  prepare_ssh_for_tunnel

  echo -e "${CYAN}正在建立 bore 隧道 (bore local 22 --to bore.pub) ...${NC}"
  enable_service "bore" "$BORE_BIN local 22 --to bore.pub" "/tmp/bore.log"

  local PORT
  PORT=$(wait_bore_port)
  if [ -n "$PORT" ]; then
    echo -e "${GREEN}✅ Bore 隧道已建立${NC}"
    echo -e "   连接命令: ${BOLD}ssh -p $PORT root@bore.pub${NC}"
  else
    echo -e "${YELLOW}⚠️ 未能获取端口，请查看 /tmp/bore.log${NC}"
  fi
}

# ==============================================================================
# 功能 6：修改 Root 用户密码
# ==============================================================================
change_root_passwd() {
  clear
  echo -e "${CYAN}${BOLD}▶ [修改 Root 用户密码]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"
  echo -e "  直接回车 = ${GREEN}不修改${NC}，保持原密码。"
  printf '%s' "新 root 密码（回车跳过）: "
  stty -echo
  read -r p1
  stty echo
  echo
  if [ -z "$p1" ]; then
    echo -e "${GREEN}已跳过，未修改密码。${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    return 0
  fi
  printf '%s' "再输入一次确认: "
  stty -echo
  read -r p2
  stty echo
  echo
  if [ "$p1" != "$p2" ]; then
    echo -e "${RED}两次不一致，已取消。${NC}"
    return 1
  fi
  if echo "root:$p1" | chpasswd; then
    echo -e "${GREEN}✅ root 密码已更新。${NC}"
  else
    echo -e "${RED}chpasswd 失败。${NC}"
  fi
  echo -e "${CYAN}--------------------------------------------------${NC}"
}

# ==============================================================================
# 主菜单循环（仅在执行脚本时启动，source 时只定义函数便于测试）
# ==============================================================================

menu_s6_relink() {
  clear
  echo -e "${CYAN}${BOLD}▶ [s6 修复：重新挂载 CF/SSH 服务链接]${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"
  echo -e "  说明: /run/service 在 Docker 中多为内存；重启后链接会丢。"
  echo -e "  本操作根据磁盘上 ${S6_OPT_ROOT:-/opt/svc}/*/s6 重新 ln 并 up。"
  echo -e "  ${YELLOW}不依赖系统是否已有 svc-nginx。${NC}"
  echo -e "${CYAN}--------------------------------------------------${NC}"
  if [ "$(get_manager)" != "s6" ]; then
    echo -e "${YELLOW}当前管理器不是 s6 ($(get_manager))，仍尝试 relink。${NC}"
  fi
  install_s6_boot_hook || true
  s6_relink_now
  echo
  echo -e "${BLUE}当前 /run/service 中本脚本服务:${NC}"
  for n in svc-cloudflared svc-sshd; do
    if [ -e /run/service/$n ]; then
      echo -n "  $n: "
      s6-svstat /run/service/$n 2>/dev/null || ls -la /run/service/$n
    else
      echo "  $n: (无链接 — 请先菜单 3/4 安装以生成 /opt/svc 定义)"
    fi
  done
  echo -e "  relink 脚本: $S6_RELINK_BIN"
  echo -e "  hook 探测:"
  find_s6_boot_hook_dirs | sed 's/^/    /' || echo "    (无)"
}


# ==============================================================================
# auto_ssh 扩展菜单（追加，不改动 1-5/7 核心）
# ==============================================================================
create_user_with_password() {
  local user="$1" pass="$2" shell="${3:-/bin/bash}" create_home="${4:-1}"
  validate_username "$user" || return 1
  if id "$user" &>/dev/null; then
    warn "用户已存在: $user"
    if ask_yn_default_yes "是否只更新密码?"; then
      echo "${user}:${pass}" | chpasswd && ok "已更新密码: $user"
    else info "跳过"; fi
  else
    if [ "$create_home" = "1" ]; then useradd -m -s "$shell" "$user"
    else useradd -M -s "$shell" "$user"; fi
    echo "${user}:${pass}" | chpasswd
    ok "已创建用户: $user"
  fi
  local g=""
  getent group sudo &>/dev/null && g=sudo
  [ -z "$g" ] && getent group wheel &>/dev/null && g=wheel
  if [ -n "$g" ] && ask_yn_default_yes "是否将 ${user} 加入 ${g} 组?"; then
    usermod -aG "$g" "$user" 2>/dev/null || true
    ok "已加入 $g"
    if command -v sudo &>/dev/null && [ -d /etc/sudoers.d ] && ask_yn_default_yes "是否配置 sudo 免密?"; then
      echo "${user} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/${user}"
      chmod 440 "/etc/sudoers.d/${user}"
      ok "已写 /etc/sudoers.d/${user}"
    fi
  fi
  LAST_USER="$user"; LAST_PASS="$pass"
}

sm_create_user() {
  clear; title "新建用户名和密码"
  local user p1 p2
  printf '%s' "用户名: "; read -r user
  validate_username "$user" || { pause; return; }
  while true; do
    printf '%s' "密码: "; stty -echo; read -r p1; stty echo; echo
    printf '%s' "再输一次: "; stty -echo; read -r p2; stty echo; echo
    [ -z "$p1" ] && { err "密码不能为空"; continue; }
    [ "$p1" != "$p2" ] && { err "两次不一致"; continue; }
    break
  done
  create_user_with_password "$user" "$p1" "/bin/bash" 1 || true
  pause
}

sm_ssh_password_policy() {
  clear; title "检查 SSH + 密码登录"
  prepare_ssh_for_tunnel
  echo
  local bin; bin="$(sshd_bin)"
  echo "配置: ${SSHD_CONFIG:-/etc/ssh/sshd_config}"
  if [ -n "$bin" ]; then
    echo "sshd -T 摘要:"
    "$bin" -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin|usepam) ' | sed 's/^/  /' || true
  fi
  port_22_listening && ok ":22 在监听" || warn ":22 未监听"
  pause
}

sm_local_ssh_test() {
  clear; title "本机验证 SSH"
  local user
  printf '%s' "用户名 [${LAST_USER:-root}]: "; read -r user
  user="${user:-${LAST_USER:-root}}"
  if ! id "$user" &>/dev/null; then err "用户不存在: $user"; pause; return; fi
  prepare_ssh_for_tunnel
  if ! port_22_listening; then err ":22 未监听"; pause; return; fi
  info "ssh ${user}@127.0.0.1"
  if [ -n "${LAST_PASS:-}" ] && [ "$user" = "$LAST_USER" ] && command -v sshpass &>/dev/null; then
    if ask_yn_default_yes "用 sshpass 自动验证?"; then
      sshpass -p "$LAST_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o ConnectTimeout=8 "${user}@127.0.0.1" "echo OK && id" && ok "验证成功" || err "验证失败"
      pause; return
    fi
  fi
  set +e
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 "${user}@127.0.0.1"
  local rc=$?; set -e
  [ $rc -eq 0 ] && ok "会话正常结束" || warn "退出码 $rc"
  pause
}

sm_cf_status() {
  clear; title "查看 CF 状态"
  cf_list_tunnels
  pause
}

sm_cf_logs() {
  clear; title "查看 CF 日志"
  local f="/var/log/cloudflared.log"
  if [ -f "$f" ]; then
    echo "--- tail -50 $f ---"
    tail -50 "$f"
    echo
    if ask_yn_default_no "跟随日志 tail -f?"; then tail -f "$f"; fi
  else
    warn "无 $f"
    journalctl -u cloudflared -n 40 --no-pager 2>/dev/null || true
  fi
  pause
}

sm_uninstall_cf() {
  clear; title "卸载 CF 隧道"
  ask_yn_default_no "确认卸载本地 cloudflared 注册与进程?" || { info "取消"; pause; return; }
  pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
  if command -v s6-svc >/dev/null 2>&1 && [ -e /run/service/svc-cloudflared ]; then
    s6-svc -d /run/service/svc-cloudflared 2>/dev/null || true
    s6-svc -x /run/service/svc-cloudflared 2>/dev/null || true
    rm -f /run/service/svc-cloudflared
  fi
  rm -rf /opt/svc/cloudflared/s6 2>/dev/null || true
  rm -f /opt/svc/cloudflared/supervisor.sh /opt/svc/cloudflared/.pid 2>/dev/null || true
  systemctl stop cloudflared 2>/dev/null || true
  systemctl disable cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload 2>/dev/null || true
  local dir; dir=$(get_supervisor_conf_dir 2>/dev/null || true)
  [ -n "$dir" ] && rm -f "$dir/cloudflared.conf"
  if command -v crontab &>/dev/null; then
    (crontab -l 2>/dev/null | grep -v cloudflared || true) | crontab - 2>/dev/null || true
  fi
  ask_yn_default_yes "删除 Token ${CF_TOKEN_FILE}?" && rm -f "${CF_TOKEN_FILE}"
  ask_yn_default_no "删除目录 ${CF_DIR}?" && rm -rf "${CF_DIR}"
  ask_yn_default_no "卸载 cloudflared 二进制?" && rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared /root/cloudflared
  ok "本地 CF 清理完成"
  pause
}

sm_change_user_password() {
  clear; title "修改普通用户密码"
  local user p1 p2
  printf '%s' "用户名 [${LAST_USER:-}]: "; read -r user
  user="${user:-$LAST_USER}"
  validate_username "$user" || { pause; return; }
  id "$user" &>/dev/null || { err "用户不存在"; pause; return; }
  while true; do
    printf '%s' "新密码: "; stty -echo; read -r p1; stty echo; echo
    printf '%s' "再输一次: "; stty -echo; read -r p2; stty echo; echo
    [ -z "$p1" ] && { err "不能为空"; continue; }
    [ "$p1" != "$p2" ] && { err "不一致"; continue; }
    break
  done
  echo "${user}:${p1}" | chpasswd
  ok "已更新: $user"
  LAST_USER="$user"; LAST_PASS="$p1"
  pause
}

_sm_cf_bin() {
  command -v cloudflared 2>/dev/null \
    || { [ -x /usr/local/bin/cloudflared ] && echo /usr/local/bin/cloudflared; } \
    || { [ -x /root/cloudflared ] && echo /root/cloudflared; } || true
}

parse_quick_tunnel_host() {
  grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "${1:-$QUICK_SSH_LOG}" 2>/dev/null | head -1 | sed 's|https://||'
}

stop_quick_temp_ssh_tunnel() {
  local pid=""
  [ -f "$QUICK_SSH_PID" ] && pid=$(cat "$QUICK_SSH_PID" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true
  fi
  pkill -f "cloudflared.*--url tcp://127.0.0.1:22" 2>/dev/null || true
  rm -f "$QUICK_SSH_PID" "$QUICK_SSH_URL"
}

sm_stop_quick_temp_ssh() {
  clear; title "关闭临时 SSH 隧道"
  stop_quick_temp_ssh_tunnel
  ok "已停止临时 trycloudflare 隧道"
  pause
}

sm_quick_temp_ssh() {
  clear; title "一键临时 SSH（trycloudflare）"
  echo "cloudflared tunnel --url tcp://127.0.0.1:22"
  prepare_ssh_for_tunnel
  local CFB; CFB=$(_sm_cf_bin)
  [ -n "$CFB" ] || { err "未找到 cloudflared"; pause; return 1; }
  port_22_listening || { err ":22 未监听"; pause; return 1; }
  stop_quick_temp_ssh_tunnel
  mkdir -p /var/log /run
  : >"$QUICK_SSH_LOG"
  info "启动临时隧道..."
  nohup env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
    "$CFB" tunnel --no-autoupdate --url "tcp://127.0.0.1:22" >>"$QUICK_SSH_LOG" 2>&1 &
  echo $! >"$QUICK_SSH_PID"
  ok "PID=$(cat "$QUICK_SSH_PID") 日志=$QUICK_SSH_LOG"
  local i host=""
  for i in $(seq 1 30); do
    host=$(parse_quick_tunnel_host)
    [ -n "$host" ] && { echo "$host" >"$QUICK_SSH_URL"; break; }
    if ! kill -0 "$(cat "$QUICK_SSH_PID" 2>/dev/null)" 2>/dev/null; then
      err "进程已退出"; tail -15 "$QUICK_SSH_LOG"; pause; return 1
    fi
    printf '.'; sleep 1
  done
  echo
  [ -n "$host" ] || { err "未拿到 trycloudflare 域名"; tail -20 "$QUICK_SSH_LOG"; pause; return 1; }
  ok "就绪: https://${host}"
  echo "  cloudflared access tcp --hostname ${host} --url 127.0.0.1:2222"
  echo "  ssh -p 2222 ${QUICK_SSH_USER:-kkb}@127.0.0.1"
  echo "关闭: 菜单 16"
  pause
}


if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  while true; do
    clear
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║        全能自适应系统服务与详情管理脚本          ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e " PID1=$(cat /proc/1/comm 2>/dev/null)  管理器=$(get_manager)"
    echo -e " ${ORANGE}—— 核心（已调试）——${NC}"
    echo -e " ${GREEN}1.${NC} 查看系统详情概览"
    echo -e " ${GREEN}2.${NC} 查看 Init / 开机自启（含 ps -p 1）"
    echo -e " ${GREEN}3.${NC} Cloudflare 隧道（Token 粘贴/重启/查看/状态/删除）"
    echo -e " ${GREEN}4.${NC} 配置 SSH 自启（hostkey/密码登录/:22）"
    echo -e " ${GREEN}5.${NC} Bore 隧道"
    echo -e " ${GREEN}7.${NC} s6 修复/重挂 CF·SSH 链接"
    echo -e " ${ORANGE}—— SSH/用户/CF 扩展 ——${NC}"
    echo -e " ${GREEN}8.${NC} 新建用户名和密码"
    echo -e " ${GREEN}9.${NC} 检查 SSH + 密码登录"
    echo -e " ${GREEN}10.${NC} 本机验证 SSH"
    echo -e " ${GREEN}11.${NC} 查看 CF 状态"
    echo -e " ${GREEN}12.${NC} 修改 Root 密码（回车=不改）"
    echo -e " ${GREEN}13.${NC} 查看 CF 日志"
    echo -e " ${GREEN}14.${NC} 卸载 CF 隧道"
    echo -e " ${GREEN}15.${NC} 一键临时 SSH（trycloudflare）"
    echo -e " ${GREEN}16.${NC} 关闭临时 SSH 隧道"
    echo -e " ${GREEN}17.${NC} 修改普通用户密码"
    echo -e " ${RED}0.${NC} 退出脚本"
    echo -e " ${YELLOW}提示: 自启请用 3/4/7；Init 查看用 2${NC}"
    echo -e "${CYAN}--------------------------------------------------${NC}"
    printf '%s' "请输入选项 [0-17]: "
    read -r choice

    case "$choice" in
      1) show_system_info ;;
      2) show_init_and_services ;;
      3) setup_cf_tunnel ;;
      4) setup_ssh ;;
      5) setup_bore ;;
      6) echo -e "${YELLOW}原 6 已迁到 12${NC}"; change_root_passwd ;;
      7) menu_s6_relink ;;
      8) sm_create_user ;;
      9) sm_ssh_password_policy ;;
      10) sm_local_ssh_test ;;
      11) sm_cf_status ;;
      12) change_root_passwd ;;
      13) sm_cf_logs ;;
      14) sm_uninstall_cf ;;
      15) sm_quick_temp_ssh ;;
      16) sm_stop_quick_temp_ssh ;;
      17) sm_change_user_password ;;
      0) echo -e "\n感谢使用，再见！"; exit 0 ;;
      *) echo -e "${RED}无效的输入，请重新选择！${NC}" ;;
    esac

    echo -e "\n"
    read -r _dummy
  done
fi

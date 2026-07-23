#!/usr/bin/env bash
# ssh-aotu.sh - SSH 用户 + Cloudflare Tunnel (Token) 管理台
# 用法（权限自适应）:
#   bash ssh-aotu.sh                               # 已是 root 直接跑（不必套 sudo）
#   sudo bash ssh-aotu.sh                          # 普通用户有 sudo 时（会自动提权）
#   bash ssh-aotu.sh --user alice -p 'xxx'         # CLI 建用户（默认加 sudo 组）
#   bash ssh-aotu.sh --check-only
# 兼容: root/sudo；服务后端 systemd|openrc|s6|runit|supervisor（探测后选型，不锁死一种系统）
# 注意: LF 换行；Windows 拷贝后: sed -i 's/\r$//' ssh-aotu.sh
set -euo pipefail

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_BACKUP_DIR="/etc/ssh/backup"
CF_DIR="/etc/cloudflared"
CF_CONFIG="${CF_DIR}/config.yml"
CF_TOKEN_FILE="${CF_DIR}/tunnel.token"
CF_BIN=""
LAST_USER=""
LAST_PASS=""
LAST_HOSTNAME=""

# CLI（原 manage-ssh-user.sh 能力）
CLI_MODE=0
CLI_USER=""
CLI_PASS=""
CLI_SHELL="/bin/bash"
CLI_CREATE_HOME=1
CLI_CHECK_ONLY=0
CLI_ENABLE_PASSWORD=0
CLI_SKIP_USER=0

if [[ -t 1 ]]; then
  C0=$'\033[0m'; C1=$'\033[1m'
  CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CB=$'\033[34m'; CM=$'\033[35m'
else
  C0=""; C1=""; CR=""; CG=""; CY=""; CB=""; CM=""
fi

info()  { echo -e "${CB}[INFO]${C0} $*"; }
ok()    { echo -e "${CG}[OK]${C0} $*"; }
warn()  { echo -e "${CY}[WARN]${C0} $*"; }
err()   { echo -e "${CR}[ERR]${C0} $*" >&2; }
title() { echo -e "\n${C1}${CM}==== $* ====${C0}\n"; }
pause() { read -r -p "按回车返回菜单..." _ || true; }

usage() {
  cat <<'EOF'
用法: bash ssh-aotu.sh [选项]   # root 直接跑；非 root 用 sudo bash ssh-aotu.sh

无参数时进入交互菜单（SSH 用户 + Cloudflare 隧道）。

CLI 选项（原 manage-ssh-user 能力）:
  -u, --user NAME          创建/改密的用户名
  -p, --password PASS      密码（可省略后交互输入）
      --shell PATH         登录 shell，默认 /bin/bash
      --no-create-home     不创建家目录
      --check-only         只检查 sshd 密码登录状态
      --enable-password    不询问，直接允许密码登录并重载 sshd
      --skip-user          跳过建用户，只处理 ssh 配置
  -h, --help               显示帮助

示例:
  sudo bash ssh-aotu.sh
  sudo bash ssh-aotu.sh --user alice --password 'Secret123!'
  sudo bash ssh-aotu.sh --check-only
  sudo bash ssh-aotu.sh --enable-password --skip-user
EOF
}

# =============================================================================
# 权限兼容（三脚本统一原则）
# - 已是 root：命令直接执行，绝不强制再套 sudo
# - 非 root 且有 sudo：提权时用 sudo
# - 非 root 且无 sudo：尝试提示/装包失败则降级，不把脚本写死成「只能某一种系统」
# =============================================================================
IS_ROOT=0
HAS_SUDO_BIN=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1
command -v sudo >/dev/null 2>&1 && HAS_SUDO_BIN=1

is_root() { [[ "$(id -u)" -eq 0 ]]; }

as_root() {
  if is_root; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 127
  fi
}

try_install_sudo_once() {
  is_root || return 1
  command -v sudo >/dev/null 2>&1 && return 0
  info "root 环境未装 sudo，尝试安装（仅一次，失败不影响继续）..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo 2>/dev/null || apt-get install -y sudo 2>/dev/null || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y sudo 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then yum install -y sudo 2>/dev/null || true
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache sudo 2>/dev/null || true
  fi
  if command -v sudo >/dev/null 2>&1; then
    HAS_SUDO_BIN=1
    ok "sudo 已安装"
    return 0
  fi
  warn "sudo 安装失败，继续以 root 直接执行（无需 sudo）"
  return 1
}

require_root() {
  # 已是 root：直接过；可选装 sudo 给别人用（失败不阻断）
  if is_root; then
    IS_ROOT=1
    try_install_sudo_once || true
    info "权限: root（直接执行，不强制 sudo）"
    return 0
  fi
  # 非 root：有 sudo 则提权重跑（透传原始参数，勿用 printf %q 空参会产生 ''）
  if command -v sudo >/dev/null 2>&1; then
    HAS_SUDO_BIN=1
    info "权限: 非 root，使用 sudo 提权重跑..."
    if [[ $# -gt 0 ]]; then
      exec sudo -E bash "$0" "$@"
    else
      exec sudo -E bash "$0"
    fi
  fi
  # 无 root 且无 sudo：
  # - CLI 模式必须 root → 退出
  # - 交互菜单 → 受限模式继续（可查看/部分操作；写系统配置会失败）
  if [[ "${REQUIRE_ROOT_STRICT:-0}" == "1" ]] || [[ "${CLI_MODE:-0}" -eq 1 ]]; then
    err "此操作需要 root 权限。"
    echo "  当前用户: $(id -un) (uid=$(id -u))"
    echo "  请任选："
    echo "    1) 用 root 执行: bash $0"
    echo "    2) 安装 sudo 后: sudo bash $0"
    echo "    3) 控制台 root: apt-get install -y sudo 后配置 NOPASSWD"
    exit 1
  fi
  IS_ROOT=0
  HAS_SUDO_BIN=0
  warn "权限: 普通用户且无 sudo → 【受限模式】"
  warn "  可用: 查看状态、本机端口/环境探测、部分本机检查"
  warn "  不可用: 装包/改 sshd/写 /etc/cloudflared/注册系统服务"
  warn "  需要完整功能时请: root 或 sudo bash $0"
  return 0
}

# 交互菜单里需要写系统时的软拦截（不退出脚本）
need_root_or_skip() {
  local what="${1:-此操作}"
  if is_root; then return 0; fi
  if command -v sudo >/dev/null 2>&1; then
    # 有 sudo 但主流程没 reexec 时，提示用户
    err "${what} 需要 root。请用: sudo bash $0"
    return 1
  fi
  err "${what} 需要 root/sudo，当前为受限模式，已跳过"
  echo "  获取权限后重试: bash $0 （以 root）或 sudo bash $0"
  return 1
}

ask_yn_default_yes() {
  local prompt="$1" ans
  read -r -p "${prompt} [Y/n]: " ans || true
  ans="${ans:-y}"
  case "${ans,,}" in y|yes|"") return 0 ;; *) return 1 ;; esac
}

ask_yn_default_no() {
  local prompt="$1" ans
  read -r -p "${prompt} [y/N]: " ans || true
  ans="${ans:-n}"
  case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

validate_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "用户名不合法: $u"; return 1; }
}

# $1 user  $2 pass  [$3 shell]  [$4 create_home 0|1]
create_user_with_password() {
  local user="$1" pass="$2" shell="${3:-/bin/bash}" create_home="${4:-1}"
  validate_username "$user" || return 1
  if id "$user" &>/dev/null; then
    warn "用户已存在: $user"
    # 非交互（CLI）时默认只改密码，避免 read 挂起
    if [[ "${CLI_MODE:-0}" -eq 1 ]] || [[ ! -t 0 ]]; then
      echo "${user}:${pass}" | chpasswd
      ok "已更新密码: $user (非交互)"
    elif ask_yn_default_yes "是否只更新密码?"; then
      echo "${user}:${pass}" | chpasswd
      ok "已更新密码: $user"
    else
      info "跳过"
    fi
  else
    if [[ "$create_home" -eq 1 ]]; then
      useradd -m -s "$shell" "$user"
    else
      useradd -M -s "$shell" "$user"
    fi
    echo "${user}:${pass}" | chpasswd
    ok "已创建用户: $user (shell=$shell home=$([[ $create_home -eq 1 ]] && echo yes || echo no))"
  fi
  local g=""
  if getent group sudo &>/dev/null; then g=sudo
  elif getent group wheel &>/dev/null; then g=wheel
  fi
  if [[ -n "$g" ]]; then
    # 默认加入 sudo/wheel（回车=是）；CLI 也默认给予，可用 CREATE_USER_NO_SUDO=1 关闭
    if [[ "${CREATE_USER_NO_SUDO:-0}" == "1" ]]; then
      info "CREATE_USER_NO_SUDO=1，不加入 ${g} 组"
    elif [[ "${CLI_MODE:-0}" -eq 1 ]] || [[ ! -t 0 ]]; then
      usermod -aG "$g" "$user" 2>/dev/null || true
      ok "已加入 ${g} 组（CLI 默认，等同管理员权限）"
    elif ask_yn_default_yes "是否将 ${user} 加入 ${g} 组（管理员/sudo 权限）?"; then
      usermod -aG "$g" "$user"
      ok "已加入 $g"
      # 若已装 sudo，再写一条免密（可选，默认是）
      if command -v sudo &>/dev/null && [[ -d /etc/sudoers.d ]]; then
        if ask_yn_default_yes "是否为 ${user} 配置 sudo 免密 (NOPASSWD)?"; then
          echo "${user} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/${user}"
          chmod 440 "/etc/sudoers.d/${user}"
          ok "已写入 /etc/sudoers.d/${user}"
        fi
      fi
    else
      info "未加入 ${g} 组"
    fi
  fi
  LAST_USER="$user"
  LAST_PASS="$pass"
  info "已记住最近用户: $LAST_USER"
}

menu_create_user() {
  title "2. 新建用户名和密码"
  local user pass p1 p2
  read -r -p "用户名: " user
  validate_username "$user" || { pause; return; }
  while true; do
    read -r -s -p "密码: " p1; echo
    read -r -s -p "再输一次: " p2; echo
    [[ -z "$p1" ]] && { err "密码不能为空"; continue; }
    [[ "$p1" != "$p2" ]] && { err "两次不一致"; continue; }
    pass="$p1"; break
  done
  create_user_with_password "$user" "$pass" "/bin/bash" 1 || true
  pause
}

# 缓存 sshd -T 全量输出（一次）
SSHD_T_CACHE=""
load_sshd_T() {
  if [[ -n "${SSHD_T_CACHE:-}" ]]; then return 0; fi
  if command -v sshd &>/dev/null; then
    SSHD_T_CACHE="$(sshd -T 2>/dev/null || true)"
  fi
}

get_sshd_val() {
  local key="$1" val=""
  load_sshd_T
  if [[ -n "$SSHD_T_CACHE" ]]; then
    val="$(printf '%s\n' "$SSHD_T_CACHE" | awk -v k="${key,,}" 'tolower($1)==k{print $2;exit}')" || true
  fi
  if [[ -z "$val" && -f "$SSHD_CONFIG" ]]; then
    val="$(awk -v k="$key" '
      BEGIN { IGNORECASE=1 }
      $1 ~ "^"k"$" && $1 !~ /^#/ { v=$2 }
      END { if (v!="") print v }
    ' "$SSHD_CONFIG" 2>/dev/null || true)"
  fi
  echo "$val"
}

password_auth_allowed() {
  local pa
  pa="$(get_sshd_val PasswordAuthentication)"
  [[ -z "$pa" ]] && pa="yes"
  [[ "${pa,,}" == "yes" ]]
}

print_ssh_status() {
  echo "配置文件: $SSHD_CONFIG"
  load_sshd_T
  local keys=(
    PasswordAuthentication
    KbdInteractiveAuthentication
    ChallengeResponseAuthentication
    PubkeyAuthentication
    PermitRootLogin
    UsePAM
  )
  local k v
  for k in "${keys[@]}"; do
    v="$(get_sshd_val "$k")"
    [[ -z "$v" ]] && v="(未显式配置/未知)"
    printf "  %-32s %s\n" "$k" "$v"
  done
  if password_auth_allowed; then ok "判定: 允许密码登录"
  else warn "判定: 不允许密码登录"; fi
}

enable_password_auth() {
  mkdir -p "$SSHD_BACKUP_DIR"
  local bak="${SSHD_BACKUP_DIR}/sshd_config.$(date +%Y%m%d_%H%M%S).bak"
  cp -a "$SSHD_CONFIG" "$bak"
  ok "备份: $bak"
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    cat >/etc/ssh/sshd_config.d/99-allow-password.conf <<'EOF'
# managed by ssh-aotu.sh
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
    ok "写入 /etc/ssh/sshd_config.d/99-allow-password.conf"
  else
    sed -i -E \
      -e 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' \
      -e 's/^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*/KbdInteractiveAuthentication yes/' \
      -e 's/^[#[:space:]]*ChallengeResponseAuthentication[[:space:]].*/ChallengeResponseAuthentication yes/' \
      "$SSHD_CONFIG"
    grep -qE '^PasswordAuthentication[[:space:]]+yes' "$SSHD_CONFIG" \
      || echo "PasswordAuthentication yes" >>"$SSHD_CONFIG"
    grep -qE '^KbdInteractiveAuthentication[[:space:]]+yes' "$SSHD_CONFIG" \
      || echo "KbdInteractiveAuthentication yes" >>"$SSHD_CONFIG"
    ok "已修改 $SSHD_CONFIG"
  fi
  if ! sshd -t; then err "sshd -t 失败"; return 1; fi
  ok "语法检查通过"
  if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null \
    || service sshd reload 2>/dev/null || service ssh reload 2>/dev/null; then
    ok "sshd 已重载"
  else
    # 兼容 s6/no-systemd：向主 sshd 发 HUP
    local pid=""
    pid="$(pgrep -xo sshd 2>/dev/null || true)"
    if [[ -z "$pid" ]]; then
      pid="$(pgrep -f '/sshd\b|sshd: /' 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$pid" ]]; then
      kill -HUP "$pid" 2>/dev/null || true
      ok "已向 sshd(PID=$pid) 发送 HUP"
    else
      warn "请手动 reload ssh"
    fi
  fi
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      "" )
        # sudo/引号残留空参数，忽略
        shift ;;
      -u|--user)
        CLI_USER="${2:-}"; CLI_MODE=1; shift 2 ;;
      -p|--password)
        CLI_PASS="${2:-}"; CLI_MODE=1; shift 2 ;;
      --shell)
        CLI_SHELL="${2:-/bin/bash}"; CLI_MODE=1; shift 2 ;;
      --no-create-home)
        CLI_CREATE_HOME=0; CLI_MODE=1; shift ;;
      --check-only)
        CLI_CHECK_ONLY=1; CLI_SKIP_USER=1; CLI_MODE=1; shift ;;
      --enable-password)
        CLI_ENABLE_PASSWORD=1; CLI_MODE=1; shift ;;
      --skip-user)
        CLI_SKIP_USER=1; CLI_MODE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        err "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

cli_prompt_user_pass() {
  if [[ -z "$CLI_USER" ]]; then
    read -r -p "请输入新用户名: " CLI_USER
  fi
  if [[ -z "$CLI_USER" ]]; then
    err "用户名为空"; exit 1
  fi
  if [[ -z "$CLI_PASS" ]]; then
    local p1 p2
    while true; do
      read -r -s -p "请输入密码: " p1; echo
      read -r -s -p "请再次输入密码: " p2; echo
      [[ -z "$p1" ]] && { err "密码不能为空"; continue; }
      [[ "$p1" != "$p2" ]] && { err "两次密码不一致"; continue; }
      CLI_PASS="$p1"
      break
    done
  fi
}

cli_handle_password_policy() {
  print_ssh_status
  echo
  if password_auth_allowed; then
    ok "已允许密码登录，无需修改"
    return 0
  fi
  if [[ "$CLI_ENABLE_PASSWORD" -eq 1 ]]; then
    info "已指定 --enable-password，正在改为允许..."
    enable_password_auth
    print_ssh_status
    return 0
  fi
  if ask_yn_default_yes "当前不允许密码登录，是否改为允许并重载 sshd?"; then
    enable_password_auth
    print_ssh_status
  else
    warn "保持当前 ssh 配置不变"
  fi
}

cli_run() {
  require_root
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    err "找不到 sshd 配置: $SSHD_CONFIG"
    exit 1
  fi
  echo "${C1}=== SSH 用户与密码登录（CLI）===${C0}"
  if [[ "$CLI_CHECK_ONLY" -eq 1 ]]; then
    print_ssh_status
    exit 0
  fi
  if [[ "$CLI_SKIP_USER" -eq 0 ]]; then
    cli_prompt_user_pass
    create_user_with_password "$CLI_USER" "$CLI_PASS" "$CLI_SHELL" "$CLI_CREATE_HOME" || exit 1
  else
    info "已跳过创建用户"
  fi
  cli_handle_password_policy
  echo
  ok "CLI 完成"
  if [[ "$CLI_SKIP_USER" -eq 0 && -n "$CLI_USER" ]]; then
    info "测试: ssh ${CLI_USER}@127.0.0.1"
    info "若走 CF 隧道: cloudflared access tcp --hostname <域名> --url 127.0.0.1:2222"
  fi
}

menu_ssh_password_policy() {
  title "3. SSH 状态（服务 + 密码登录）"
  # 先确认 sshd 可用并监听 22
  if ! ensure_sshd_running; then
    err "SSH 服务异常，先解决 22 端口监听问题"
    pause
    return
  fi
  echo
  if [[ ! -f "$SSHD_CONFIG" ]]; then
    err "找不到 $SSHD_CONFIG"
    pause
    return
  fi
  print_ssh_status
  echo
  if password_auth_allowed; then
    ok "当前已允许密码登录，无需修改"
  else
    if ask_yn_default_yes "不允许密码登录，是否改为允许并刷新?"; then
      enable_password_auth || true
      echo
      print_ssh_status
    else
      warn "保持不变"
    fi
  fi
  echo
  info "本机快速探测: nc/ssh 到 127.0.0.1:22"
  if command -v nc &>/dev/null; then
    if nc -z -w 2 127.0.0.1 22 2>/dev/null; then
      ok "127.0.0.1:22 可连通"
    else
      warn "nc 探测 22 失败"
    fi
  else
    if (echo >/dev/tcp/127.0.0.1/22) &>/dev/null; then
      ok "127.0.0.1:22 可连通"
    else
      warn "TCP 探测 22 失败"
    fi
  fi
  pause
}

port_22_listening() {
  # 快照优先
  if [[ -n "${SNAP_TS:-}" && "${SNAP_TS:-0}" != "0" && $(( $(date +%s) - SNAP_TS )) -lt 3 ]]; then
    [[ "${SNAP_PORT22:-0}" -eq 1 ]]
    return $?
  fi
  if command -v ss &>/dev/null; then
    ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'
    return $?
  fi
  if command -v netstat &>/dev/null; then
    netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'
    return $?
  fi
  (echo >/dev/tcp/127.0.0.1/22) &>/dev/null
}

ensure_sshd_running() {
  if port_22_listening; then
    ok "本机 22 端口已在监听"
    return 0
  fi
  warn "本机 22 端口未监听，尝试安装/启动 sshd..."

  # 安装 openssh-server（按包管理器 / 通用探测）
  if ! command -v sshd &>/dev/null; then
    info "未找到 sshd，尝试安装 openssh-server..."
    [[ -n "$ENV_PKG" ]] || PROBE_SKIP_NET=1 probe_environment
    case "${ENV_PKG}" in
      apt) pkg_install openssh-server || true ;;
      dnf|yum) pkg_install openssh-server || true ;;
      apk) pkg_install openssh || true ;;
      pacman) pkg_install openssh || true ;;
      zypper) pkg_install openssh || true ;;
      *)
        if command -v apt-get &>/dev/null; then
          DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null 2>&1 || true
        elif command -v dnf &>/dev/null; then dnf install -y openssh-server >/dev/null 2>&1 || true
        elif command -v yum &>/dev/null; then yum install -y openssh-server >/dev/null 2>&1 || true
        elif command -v apk &>/dev/null; then apk add --no-cache openssh >/dev/null 2>&1 || true
        else err "无法自动安装 openssh-server，请手动安装"; return 1
        fi
        ;;
    esac
  fi

  if ! command -v sshd &>/dev/null; then
    err "sshd 仍不可用"
    return 1
  fi

  # 生成 host key（部分镜像缺）
  if [[ ! -f /etc/ssh/ssh_host_rsa_key && ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    info "生成 SSH host key..."
    ssh-keygen -A 2>/dev/null || true
  fi

  # 确保 PermitListen / 监听 22（默认即可）
  mkdir -p /var/run/sshd 2>/dev/null || true

  # 启动服务
  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  fi
  if ! port_22_listening; then
    service ssh start 2>/dev/null || service sshd start 2>/dev/null || true
  fi
  if ! port_22_listening; then
    # 无 systemd 时前台/后台直接起
    info "尝试直接启动 /usr/sbin/sshd..."
    /usr/sbin/sshd 2>/dev/null || sshd 2>/dev/null || true
  fi

  local i
  for i in 1 2 3 4 5; do
    if port_22_listening; then
      ok "sshd 已启动，22 端口监听中"
      # 非 systemd 环境挂保活，防止过几天进程消失
      if ! systemd_usable 2>/dev/null; then
        try_register_sshd_supervisor 2>/dev/null || true
      fi
      return 0
    fi
    sleep 1
  done

  err "仍无法监听 22。诊断:"
  echo "--- sshd 进程 ---"
  ps aux | grep -E '[s]shd' || true
  echo "--- 监听端口 ---"
  ss -lntp 2>/dev/null | head -20 || true
  # 即使当前失败也部署 supervisor，便于后续自动重试
  if is_root && ! systemd_usable 2>/dev/null; then
    try_register_sshd_supervisor 2>/dev/null || true
  fi
  return 1
}

menu_local_ssh_test() {
  title "4. 本机验证 SSH"
  local user
  if [[ -n "$LAST_USER" ]]; then
    read -r -p "用户名 [${LAST_USER}]: " user; user="${user:-$LAST_USER}"
  else
    read -r -p "用户名: " user
  fi
  if [[ -z "$user" ]]; then err "用户名为空"; pause; return; fi
  if ! id "$user" &>/dev/null; then err "用户不存在: $user"; pause; return; fi
  if ! password_auth_allowed; then
    if ask_yn_default_yes "当前可能不允许密码登录，是否先开启?"; then
      enable_password_auth || true
    fi
  fi
  if ! ensure_sshd_running; then
    err "本机 SSH 服务不可用，无法验证（Connection refused 即此原因）"
    pause
    return
  fi
  info "ssh ${user}@127.0.0.1"
  if [[ -n "${LAST_PASS:-}" && "$user" == "$LAST_USER" ]] && command -v sshpass &>/dev/null; then
    if ask_yn_default_yes "用 sshpass 自动验证?"; then
      if sshpass -p "$LAST_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o PreferredAuthentications=password -o PubkeyAuthentication=no \
          -o ConnectTimeout=8 "${user}@127.0.0.1" "echo OK && id"; then
        ok "验证成功"
      else
        err "验证失败"
      fi
      pause; return
    fi
  fi
  set +e
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=10 "${user}@127.0.0.1"
  local rc=$?; set -e
  if [[ $rc -eq 0 ]]; then ok "会话正常结束"; else warn "退出码 $rc"; fi
  pause
}

refresh_cf_bin() {
  CF_BIN="$(command -v cloudflared 2>/dev/null || true)"
  if [[ -z "$CF_BIN" && -x /usr/local/bin/cloudflared ]]; then
    CF_BIN=/usr/local/bin/cloudflared
  fi
  if [[ -z "$CF_BIN" && -x /usr/bin/cloudflared ]]; then
    CF_BIN=/usr/bin/cloudflared
  fi
  if [[ -z "$CF_BIN" && -x "${HOME}/.ssh-aotu/cloudflared" ]]; then
    CF_BIN="${HOME}/.ssh-aotu/cloudflared"
  fi
  if [[ -z "$CF_BIN" && -x "${HOME}/cloudflared" ]]; then
    CF_BIN="${HOME}/cloudflared"
  fi
  if [[ -z "$CF_BIN" && -x ./cloudflared ]]; then
    CF_BIN=./cloudflared
  fi
  return 0
}

# =============================================================================
# GitHub 下载：不测速，固定顺序试镜像（失败换下一个）
# =============================================================================
GH_MIRROR_ORDER="DIRECT ghproxy.net ghfast ghproxy.com"
GH_MIRROR_BEST="DIRECT"

# 将 github.com 原始 URL 套上指定镜像前缀
mirror_github_url() {
  local origin="$1" name="$2"
  case "$name" in
    DIRECT|"") echo "$origin" ;;
    ghfast) echo "https://ghfast.top/${origin}" ;;
    ghproxy.net) echo "https://ghproxy.net/${origin}" ;;
    mirror.ghproxy) echo "https://mirror.ghproxy.com/${origin}" ;;
    ghproxy.com) echo "https://ghproxy.com/${origin}" ;;
    gitclone)
      echo "https://gitclone.com/github.com/${origin#https://github.com/}"
      ;;
    *) echo "$origin" ;;
  esac
}

# 展开固定镜像列表（不探测）
github_download_urls() {
  local origin="$1" name
  for name in ${GH_MIRROR_ORDER}; do
    mirror_github_url "$origin" "$name"
  done
}

# 按固定顺序下载 github 文件
download_from_github() {
  local origin="$1" dest="$2" min_bytes="${3:-1000}"
  local url tmp sz ok_dl=0
  if [[ "$origin" != https://github.com/* && "$origin" != http://github.com/* ]]; then
    err "非 GitHub URL: $origin"
    return 1
  fi
  tmp="${dest}.dl.$$"
  info "下载: $(basename "$origin")"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    info "  → ${url:0:76}..."
    rm -f "$tmp"
    if curl -fL --connect-timeout 12 --max-time 180 --retry 1 \
        --progress-bar -o "$tmp" "$url"; then
      sz="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)"
      if [[ "${sz:-0}" -ge "$min_bytes" ]]; then
        mv -f "$tmp" "$dest"
        ok_dl=1
        ok "下载成功 ($sz bytes)"
        break
      fi
      warn "文件过小 (${sz})，换源"
      rm -f "$tmp"
    else
      warn "失败，换源"
      rm -f "$tmp"
    fi
  done < <(github_download_urls "$origin")
  [[ "$ok_dl" -eq 1 ]]
}

install_cloudflared_if_needed() {
  refresh_cf_bin
  if [[ -n "$CF_BIN" ]] && "$CF_BIN" --version &>/dev/null; then
    ok "已安装: $CF_BIN ($("$CF_BIN" --version 2>/dev/null | head -1))"
    return 0
  fi
  local p
  for p in /usr/local/bin/cloudflared /usr/bin/cloudflared \
           "${HOME}/.ssh-aotu/cloudflared" "${HOME}/cloudflared" \
           ./cloudflared /opt/cloudflared/cloudflared; do
    if [[ -x "$p" ]] && "$p" --version &>/dev/null; then
      CF_BIN="$p"
      ok "发现已有二进制: $CF_BIN"
      return 0
    fi
  done

  [[ -n "$ENV_ARCH" ]] || PROBE_SKIP_NET=1 probe_environment

  local arch="${ENV_ARCH:-}"
  case "$arch" in
    amd64|arm64|arm) ;;
    *)
      case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armhf) arch=arm ;;
        *) err "不支持架构: $(uname -m)"; return 1 ;;
      esac
      ;;
  esac
  local asset="cloudflared-linux-${arch}"
  local origin="https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}"
  local tmp="/tmp/${asset}.$$"
  local dest=""

  # 安装目标：root → /usr/local/bin；普通用户 → ~/.ssh-aotu/
  if is_root; then
    dest="/usr/local/bin/cloudflared"
  else
    mkdir -p "${HOME}/.ssh-aotu" 2>/dev/null || true
    dest="${HOME}/.ssh-aotu/cloudflared"
    info "无 root：cloudflared 将安装到 ${dest}（用户态，不影响系统）"
  fi

  info "安装 cloudflared (arch=${arch}) → ${dest}"
  if ! download_from_github "$origin" "$tmp" 5000000; then
    err "cloudflared 自动下载失败"
    echo "  ① 手动放到: ${dest}"
    echo "     ${origin}"
    echo "  ② 有 root 时: install -m 755 ${asset} /usr/local/bin/cloudflared"
    echo "  ③ 固定隧道(须root): 菜单 5 Token"
    rm -f "$tmp"
    return 1
  fi
  chmod +x "$tmp"
  if ! "$tmp" --version &>/dev/null; then
    err "下载的文件无法执行"
    rm -f "$tmp"
    return 1
  fi
  if is_root; then
    install -m 755 "$tmp" /usr/local/bin/cloudflared || mv -f "$tmp" /usr/local/bin/cloudflared
  else
    mv -f "$tmp" "$dest"
    chmod +x "$dest"
  fi
  rm -f "$tmp" 2>/dev/null || true
  refresh_cf_bin
  if [[ -n "$CF_BIN" ]] && "$CF_BIN" --version &>/dev/null; then
    ok "安装完成: $CF_BIN ($("$CF_BIN" --version 2>/dev/null | head -1))"
    return 0
  fi
  err "安装后仍不可用"
  return 1
}

save_tunnel_token() {
  local token="$1"
  mkdir -p "$CF_DIR"
  umask 077
  printf '%s\n' "$token" >"$CF_TOKEN_FILE"
  chmod 600 "$CF_TOKEN_FILE"
  ok "Token 已保存: $CF_TOKEN_FILE"
}

load_tunnel_token() {
  if [[ -f "$CF_TOKEN_FILE" ]]; then
    tr -d '\015\012' <"$CF_TOKEN_FILE"
  fi
  return 0
}

# 菜单 5 共用：保存 token 后走万能注册
install_token_service() {
  local token="$1"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装"; return 1; }
  [[ -n "$token" ]] || { err "token 为空"; return 1; }
  save_tunnel_token "$token"
  try_register_cloudflared
}


menu_create_cf_tunnel() {
  title "5. CF 固定隧道（Token；自动探测环境并注册）"
  install_cloudflared_if_needed || { pause; return; }
  echo "1) 粘贴 Token 安装启动（默认）"
  echo "2) 已保存 Token 重启"
  echo "3) 查看 Token 状态"
  local mode token hostname service_url
  read -r -p "请选择 [1]: " mode
  mode="${mode:-1}"
  case "$mode" in
    1)
      read -r -p "Token: " token
      token="$(echo "$token" | tr -d '[:space:]')"
      if [[ "$token" == *"--token"* ]]; then
        token="$(echo "$token" | sed -n 's/.*--token[ =]*//p' | awk '{print $1}')"
      fi
      if [[ -z "$token" || ${#token} -lt 20 ]]; then err "Token 无效"; pause; return; fi
      if [[ "$token" != eyJ* ]]; then
        warn "Token 通常以 eyJ 开头"
        ask_yn_default_yes "仍继续?" || { pause; return; }
      fi
      read -r -p "公网域名（仅写进 README 提示，可留空）: " hostname
      hostname="${hostname:-${LAST_HOSTNAME:-your-hostname.example.com}}"
      LAST_HOSTNAME="$hostname"
      read -r -p "本地服务 [ssh://localhost:22]: " service_url
      service_url="${service_url:-ssh://localhost:22}"
      mkdir -p "$CF_DIR"
      cat >"${CF_DIR}/README.token-mode.txt" <<EOF
# Token 模式（由 ssh-aotu.sh 生成，仅备忘）
# Token 文件: ${CF_TOKEN_FILE}
# 控制台建议: ${hostname} -> ${service_url}
# 本机访问示例:
#   cloudflared access tcp --hostname ${hostname} --url 127.0.0.1:2222
#   然后: ssh -p 2222 user@127.0.0.1
EOF
      install_token_service "$token" || { pause; return; }
      ok "已运行，请到 Cloudflare Zero Trust 控制台确认连接器在线"
      echo "访问示例: cloudflared access tcp --hostname ${hostname} --url 127.0.0.1:2222"
      ;;
    2)
      token="$(load_tunnel_token)"
      [[ -n "$token" ]] || { err "无已保存 Token"; pause; return; }
      install_token_service "$token" || { pause; return; }
      ;;
    3)
      if [[ -f "$CF_TOKEN_FILE" ]]; then
        token="$(load_tunnel_token)"
        ok "长度=${#token} 前缀=${token:0:8}..."
      else
        warn "未配置 Token"
      fi
      ;;
    *) err "无效选项" ;;
  esac
  pause
}



menu_cf_status() {
  title "6. CF 状态"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "未安装"; pause; return; }
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment

  local token_mode=0
  [[ -f "$CF_TOKEN_FILE" ]] && token_mode=1
  # 兼容 config.yml / config.yaml
  local cfg=""
  if [[ -f "$CF_CONFIG" ]]; then cfg="$CF_CONFIG"
  elif [[ -f "${CF_DIR}/config.yaml" ]]; then cfg="${CF_DIR}/config.yaml"
  fi

  local proc_line=""
  proc_line="$(ps aux 2>/dev/null | grep -E '[c]loudflared' | sed -E 's/(--token[ =])[^ ]+/\1***/g' || true)"
  if [[ -n "$proc_line" ]] && echo "$proc_line" | grep -q -- '--token'; then
    token_mode=1
  fi

  echo "--- 版本 ---"
  "$CF_BIN" --version 2>&1 || true
  echo
  echo "--- 运行模式 / 后端 ---"
  local backend; backend="$(prefer_service_backend)"
  info "环境 Init=$ENV_INIT 推荐后端=$backend"
  if [[ "$token_mode" -eq 1 ]]; then
    ok "Token 模式（固定隧道 connector）"
  elif [[ -n "$cfg" ]]; then
    ok "cert/config 模式: $cfg"
  else
    warn "未检测到 Token 或 config"
  fi
  echo
  echo "--- 进程 ---"
  if [[ -n "$proc_line" ]]; then
    echo "$proc_line"
    ok "cloudflared 进程在运行"
  else
    warn "无 cloudflared 进程"
  fi
  echo
  if [[ -f "$CF_TOKEN_FILE" ]]; then
    local t; t="$(load_tunnel_token)"
    ok "Token 文件: $CF_TOKEN_FILE 长度=${#t} 前缀=${t:0:8}..."
  else
    warn "无 Token 文件: $CF_TOKEN_FILE"
  fi
  echo
  echo "--- 服务注册 ---"
  local shown=0
  if systemd_usable && systemctl cat cloudflared.service &>/dev/null 2>&1; then
    systemctl --no-pager --full status cloudflared 2>/dev/null | head -15 || true
    shown=1
  fi
  if [[ -e /run/service/svc-cloudflared ]]; then
    ok "s6: /run/service/svc-cloudflared"
    s6-svstat /run/service/svc-cloudflared 2>/dev/null || true
    shown=1
  fi
  if [[ -f /etc/init.d/cloudflared ]]; then
    ok "OpenRC: /etc/init.d/cloudflared"
    rc-service cloudflared status 2>/dev/null || true
    shown=1
  fi
  if command -v sv &>/dev/null; then
    for d in /etc/service /var/service /service; do
      if [[ -d "$d/cloudflared" ]]; then
        ok "runit: $d/cloudflared"
        sv status cloudflared 2>/dev/null || true
        shown=1
      fi
    done
  fi
  if [[ -x /opt/svc/cloudflared/supervisor.sh ]]; then
    ok "supervisor: /opt/svc/cloudflared/supervisor.sh"
    [[ -f /opt/svc/cloudflared/.pid ]] && echo "  pidfile=$(cat /opt/svc/cloudflared/.pid 2>/dev/null)"
    shown=1
  fi
  if [[ "$shown" -eq 0 ]]; then
    if [[ -n "$proc_line" ]]; then
      info "进程在跑但未检测到标准服务注册（可能是散养 nohup）→ 可用菜单 1 规范注册"
    else
      warn "无服务注册且无进程"
    fi
  fi
  echo
  if [[ -f "${CF_DIR}/README.token-mode.txt" ]]; then
    echo "--- README ---"
    cat "${CF_DIR}/README.token-mode.txt"
    echo
  fi
  if [[ -n "$cfg" ]]; then
    echo "--- $(basename "$cfg") ---"
    cat "$cfg"
    echo
  fi

  if [[ "$token_mode" -eq 1 ]]; then
    info "跳过 cloudflared tunnel list（Token 模式不需要）"
  else
    echo "--- tunnel list ---"
    "$CF_BIN" tunnel list 2>&1 || warn "tunnel list 失败（未 login 时正常）"
  fi
  echo
  echo "--- 本机 22 ---"
  if port_22_listening; then ok "sshd 已监听 22"
  else warn "未监听 22"; fi
  pause
}

menu_cf_logs() {
  title "7. CF 日志"
  local lines=80
  read -r -p "行数 [80]: " lines; lines="${lines:-80}"
  local got=0
  if systemd_usable && systemctl cat cloudflared.service &>/dev/null 2>&1; then
    journalctl -u cloudflared -n "$lines" --no-pager 2>&1 | sed -E 's/(eyJ[A-Za-z0-9_-]{10,})/***TOKEN***/g' || true
    got=1
    ask_yn_default_no "跟随实时 journal 日志?" && journalctl -u cloudflared -f
  fi
  if [[ -f /var/log/cloudflared.log ]]; then
    [[ "$got" -eq 1 ]] && echo "--- /var/log/cloudflared.log ---"
    tail -n "$lines" /var/log/cloudflared.log | sed -E 's/(eyJ[A-Za-z0-9_-]{10,})/***TOKEN***/g'
    got=1
    ask_yn_default_no "跟随实时文件日志?" && tail -f /var/log/cloudflared.log
  fi
  if [[ -e /run/service/svc-cloudflared ]] && command -v s6-svstat &>/dev/null; then
    echo "--- s6 status ---"
    s6-svstat /run/service/svc-cloudflared 2>/dev/null || true
    got=1
  fi
  if [[ "$got" -eq 0 ]]; then
    warn "无日志（无 journal / 无 /var/log/cloudflared.log）"
  fi
  pause
}

menu_uninstall_cf() {
  title "8. 卸载 CF"
  ask_yn_default_no "确认卸载本地隧道?" || { info "取消"; pause; return; }
  refresh_cf_bin
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment

  # systemd
  systemctl stop cloudflared 2>/dev/null || true
  systemctl disable cloudflared 2>/dev/null || true
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload 2>/dev/null || true

  # s6
  if [[ -e /run/service/svc-cloudflared ]]; then
    s6-svc -d /run/service/svc-cloudflared 2>/dev/null || true
    s6-svc -x /run/service/svc-cloudflared 2>/dev/null || true
    rm -f /run/service/svc-cloudflared
  fi
  rm -rf /opt/svc/cloudflared/s6 2>/dev/null || true
  rm -f /opt/svc/cloudflared/relink-s6.sh 2>/dev/null || true

  # openrc
  if [[ -f /etc/init.d/cloudflared ]]; then
    rc-service cloudflared stop 2>/dev/null || true
    rc-update del cloudflared default 2>/dev/null || true
    rm -f /etc/init.d/cloudflared
  fi

  # runit
  for d in /etc/service /var/service /service; do
    if [[ -d "$d/cloudflared" ]]; then
      sv down cloudflared 2>/dev/null || true
      rm -rf "$d/cloudflared"
    fi
  done

  # supervisor
  if [[ -f /opt/svc/cloudflared/.pid ]]; then
    kill "$(cat /opt/svc/cloudflared/.pid 2>/dev/null)" 2>/dev/null || true
    rm -f /opt/svc/cloudflared/.pid
  fi
  rm -f /opt/svc/cloudflared/supervisor.sh 2>/dev/null || true
  # crontab 清理
  if command -v crontab &>/dev/null; then
    (crontab -l 2>/dev/null | grep -v 'cloudflared' || true) | crontab - 2>/dev/null || true
  fi

  pkill -f "cloudflared.*tunnel run" 2>/dev/null || true
  ok "已停止本地 cloudflared 并清理各后端注册"

  info "云端隧道请在 Cloudflare Zero Trust 控制台删除（Token 模式无本地 cert 操作）"
  if ask_yn_default_yes "删除 $CF_DIR?"; then rm -rf "$CF_DIR"; fi
  if ask_yn_default_no "卸载 cloudflared 二进制?"; then
    rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared
  fi
  rm -f /var/log/cloudflared.log 2>/dev/null || true
  ok "完成"
  pause
}



# =============================================================================
# 环境探测（万能适配：先识别再选型）
# ENV_INIT: systemd|openrc|s6|runit|sysv|manual
# ENV_PKG:  apt|dnf|yum|apk|pacman|zypper|unknown
# ENV_ARCH: amd64|arm64|arm|...
# ENV_PRIV: root|sudo|user
# ENV_CT:   docker|podman|lxc|openvz|wsl|nspawn|native
# ENV_NET:  ok|limited|offline
# =============================================================================
ENV_INIT="" ENV_PKG="" ENV_ARCH="" ENV_PRIV="" ENV_CT="" ENV_NET="" ENV_OS=""
ENV_PROBED=0
ENV_BACKEND=""
ENV_PUBLIC_IP=""
# 运行时快照（每轮菜单采一次）
SNAP_CF_RUN=0
SNAP_SSH_RUN=0
SNAP_PORT22=0
SNAP_TS=0

detect_init() {
  local pid1
  pid1="$(cat /proc/1/comm 2>/dev/null || echo unknown)"
  case "$pid1" in
    systemd) echo "systemd"; return ;;
    s6-svscan|s6-supervise) echo "s6"; return ;;
    runit|runsvdir) echo "runit"; return ;;
    init)
      if [[ -d /run/openrc || -e /sbin/openrc-run ]] || command -v rc-service &>/dev/null; then
        echo "openrc"; return
      fi
      if [[ -d /etc/init.d ]]; then echo "sysv"; return; fi
      echo "sysv"; return
      ;;
  esac
  # 非 systemd PID1：禁止调用 systemctl（broken systemd 上极慢）
  if command -v rc-service &>/dev/null || [[ -d /run/openrc ]]; then echo "openrc"; return; fi
  if [[ -d /run/service ]] || command -v s6-svc &>/dev/null; then echo "s6"; return; fi
  if command -v sv &>/dev/null || [[ -d /etc/service || -d /var/service ]]; then echo "runit"; return; fi
  if [[ -d /etc/init.d ]]; then echo "sysv"; return; fi
  echo "manual"
}

detect_pkg() {
  if command -v apt-get &>/dev/null || command -v apt &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v yum &>/dev/null; then echo "yum"
  elif command -v apk &>/dev/null; then echo "apk"
  elif command -v pacman &>/dev/null; then echo "pacman"
  elif command -v zypper &>/dev/null; then echo "zypper"
  else echo "unknown"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "arm" ;;
    *) uname -m ;;
  esac
}

detect_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then echo "root"
  elif command -v sudo &>/dev/null; then echo "sudo"
  else echo "user"
  fi
}

detect_container() {
  if [[ -f /.dockerenv ]]; then echo "docker"; return; fi
  if [[ -f /run/.containerenv ]]; then echo "podman"; return; fi
  if grep -qaE 'docker|lxc|containerd|kubepods|podman' /proc/1/cgroup 2>/dev/null; then
    if grep -qa docker /proc/1/cgroup 2>/dev/null; then echo "docker"; return; fi
    if grep -qa lxc /proc/1/cgroup 2>/dev/null; then echo "lxc"; return; fi
    echo "container"; return
  fi
  if grep -qa microsoft /proc/version 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    echo "wsl"; return
  fi
  # 不调用 systemd-detect-virt（慢且可能卡 D-Bus）
  echo "native"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-linux}-${VERSION_ID:-?}"
  else
    uname -s
  fi
}

detect_net() {
  # 轻量：一次请求同时拿公网 IP + 证明出网（失败再试 1 次备用）
  local ip=""
  ip="$(curl -4 -fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ENV_PUBLIC_IP="$ip"
    echo "ok"
    return
  fi
  ip="$(curl -4 -fsS --connect-timeout 2 --max-time 4 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ENV_PUBLIC_IP="$ip"
    echo "ok"
    return
  fi
  if curl -4 -fsS --connect-timeout 2 --max-time 3 -o /dev/null https://1.1.1.1 2>/dev/null \
    || curl -4 -fsS --connect-timeout 2 --max-time 3 -o /dev/null https://www.cloudflare.com 2>/dev/null; then
    ENV_PUBLIC_IP=""
    echo "limited"
    return
  fi
  if ping -c1 -W2 1.1.1.1 &>/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
    ENV_PUBLIC_IP=""
    echo "limited"
    return
  fi
  ENV_PUBLIC_IP=""
  echo "offline"
}

# 汇总探测，写入全局 ENV_*（同进程默认只跑一次，FORCE_PROBE=1 强制）
probe_environment() {
  if [[ "${ENV_PROBED:-0}" -eq 1 && "${FORCE_PROBE:-0}" != "1" ]]; then
    return 0
  fi
  ENV_INIT="$(detect_init)"
  ENV_PKG="$(detect_pkg)"
  ENV_ARCH="$(detect_arch)"
  ENV_PRIV="$(detect_priv)"
  ENV_CT="$(detect_container)"
  ENV_OS="$(detect_os)"
  if [[ "${PROBE_SKIP_NET:-0}" == "2" ]]; then
    ENV_NET="skipped"
    ENV_PUBLIC_IP=""
  else
    ENV_NET="$(detect_net)"
  fi
  ENV_BACKEND=""
  ENV_BACKEND="$(_prefer_service_backend_calc)"
  ENV_PROBED=1
}

# 采集运行时快照（轻量，每轮菜单一次）
snapshot_runtime() {
  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then SNAP_CF_RUN=1; else SNAP_CF_RUN=0; fi
  if pgrep -x sshd &>/dev/null || pgrep -f "[s]shd:" &>/dev/null || pgrep -f "/sshd\b" &>/dev/null; then
    SNAP_SSH_RUN=1
  else
    SNAP_SSH_RUN=0
  fi
  # 直接测端口，避免与 port_22_listening 快照递归
  if command -v ss &>/dev/null; then
    if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then SNAP_PORT22=1; else SNAP_PORT22=0; fi
  elif (echo >/dev/tcp/127.0.0.1/22) &>/dev/null; then
    SNAP_PORT22=1
  else
    SNAP_PORT22=0
  fi
  SNAP_TS="$(date +%s)"
}

print_env_fingerprint() {
  [[ -n "$ENV_INIT" ]] || probe_environment
  local host tstr
  host="$(hostname 2>/dev/null || echo unknown)"
  tstr="$(date '+%F %T')"
  refresh_cf_bin 2>/dev/null || true
  echo "── 环境指纹 ────────────────────────────────"
  _kv "主机" "$(_dot_dim)" "$host"
  _kv "时间" "$(_dot_dim)" "$tstr"
  _kv "OS" "$(_dot_dim)" "${ENV_OS} $(uname -r | cut -d- -f1)"
  _kv "Arch" "$(_dot_dim)" "$ENV_ARCH"
  local pid1_comm pid1_args
  pid1_comm="$(cat /proc/1/comm 2>/dev/null || echo ?)"
  pid1_args="$(ps -p 1 -o args= 2>/dev/null | head -c 120 || true)"
  [[ -z "$pid1_args" ]] && pid1_args="?"
  _kv "Init" "$(_dot_dim)" "${ENV_INIT}  (ps -p 1: ${pid1_comm})"
  _kv "PID1" "$(_dot_dim)" "${pid1_args}"
  _kv "包管理" "$(_dot_dim)" "$ENV_PKG"
  case "$ENV_PRIV" in
    root) _kv "权限" "$(_dot_ok)" "root" ;;
    sudo|sudo-ask) _kv "权限" "$(_dot_todo)" "$ENV_PRIV" ;;
    *) _kv "权限" "$(_dot_bad)" "普通用户" ;;
  esac
  case "$ENV_CT" in
    native) _kv "运行时" "$(_dot_ok)" "物理/虚拟机" ;;
    *) _kv "运行时" "$(_dot_todo)" "$ENV_CT" ;;
  esac
  case "$ENV_NET" in
    ok) _kv "出网" "$(_dot_ok)" "可访问外网" ;;
    limited) _kv "出网" "$(_dot_todo)" "部分可达（ICMP/HTTPS 异常）" ;;
    skipped) _kv "出网" "$(_dot_dim)" "未探测" ;;
    *) _kv "出网" "$(_dot_bad)" "不可达/受限" ;;
  esac
  if [[ -n "${ENV_PUBLIC_IP:-}" ]]; then
    _kv "公网IP" "$(_dot_ok)" "$ENV_PUBLIC_IP （仅显示，入站端口不通时不能直连 SSH）"
  else
    _kv "公网IP" "$(_dot_todo)" "未获取"
  fi
  if [[ -n "${CF_BIN:-}" ]]; then
    _kv "cf" "$(_dot_ok)" "$CF_BIN"
  else
    _kv "cf" "$(_dot_todo)" "未安装"
  fi
  # 推荐服务后端
  local backend
  backend="$(prefer_service_backend)"
  _kv "服务后端" "$(_dot_ok)" "$backend (自动)"
}

# 推荐后端计算（无缓存）
_prefer_service_backend_calc() {
  # 注意：依赖 ENV_INIT 已设置；不在此递归 probe
  local init="${ENV_INIT:-}"
  [[ -n "$init" ]] || init="$(detect_init)"
  # 先信 PID1，再验证可用性（避免误进 systemd）
  case "$init" in
    systemd)
      if systemd_usable; then echo "systemd"; return; fi
      ;;
    openrc)
      if openrc_usable; then echo "openrc"; return; fi
      ;;
    s6)
      if [[ "$kind" == "cf" ]]; then
        local sd="/run/service"
        [[ -e "$sd/svc-cloudflared" || -e "$sd/cloudflared" || -e "$(s6_dir 2>/dev/null)/svc-cloudflared" ]] && {
          d_reg="$(_dot_ok)"; reg_txt="s6已登记"
        } || { d_reg="$(_dot_todo)"; reg_txt="未登记"; }
        if pgrep -f "$bin_pat" &>/dev/null; then
          d_en="$(_dot_ok)"; en_txt="进程在跑"
        else
          d_en="$(_dot_bad)"; en_txt="登记≠在跑"
        fi
      else
        local sd="/run/service"
        if [[ -e "$sd/svc-sshd" || -e "$sd/sshd" || -x /opt/svc/sshd/s6/run ]]; then
          d_reg="$(_dot_ok)"; reg_txt="s6已登记"
        elif [[ -x /opt/svc/sshd/supervisor.sh ]]; then
          d_reg="$(_dot_ok)"; reg_txt="supervisor"
        else
          d_reg="$(_dot_todo)"; reg_txt="未登记"
        fi
        if port_22_listening 2>/dev/null; then
          d_en="$(_dot_ok)"; en_txt=":22在听"
        else
          d_en="$(_dot_bad)"; en_txt=":22未听"
        fi
      fi
      ;;
    runit)
      if runit_usable; then echo "runit"; return; fi
      ;;
  esac
  # 回退顺序
  if systemd_usable; then echo "systemd"; return; fi
  if openrc_usable; then echo "openrc"; return; fi
  if s6_usable; then echo "s6"; return; fi
  if runit_usable; then echo "runit"; return; fi
  echo "supervisor"
}

prefer_service_backend() {
  if [[ -n "${ENV_BACKEND:-}" ]]; then
    echo "$ENV_BACKEND"
    return
  fi
  [[ "${ENV_PROBED:-0}" -eq 1 ]] || PROBE_SKIP_NET=1 probe_environment
  if [[ -n "${ENV_BACKEND:-}" ]]; then
    echo "$ENV_BACKEND"
    return
  fi
  ENV_BACKEND="$(_prefer_service_backend_calc)"
  echo "$ENV_BACKEND"
}

s6_dir() {
  local d
  for d in /run/service /var/run/s6/services /etc/s6/services /etc/services.d /etc/s6-overlay/s6-rc/source; do
    [[ -d "$d" ]] && { echo "$d"; return 0; }
  done
  if [[ -d /etc/s6-overlay/s6-rc.d ]]; then echo "/etc/s6-overlay/s6-rc.d"; return 0; fi
  echo "/run/service"
}

# 严格 systemd：避免容器残留 /run/systemd 误判
systemd_usable() {
  command -v systemctl &>/dev/null || return 1
  local pid1
  pid1="$(cat /proc/1/comm 2>/dev/null || true)"
  # 非 systemd 为 PID1 时直接否，绝不调用 systemctl（防卡死）
  [[ "$pid1" == "systemd" ]] || return 1
  [[ -d /run/systemd/system ]] || return 1
  local st
  st="$(timeout 1 systemctl is-system-running 2>/dev/null || true)"
  case "$st" in running|degraded) return 0 ;; esac
  return 1
}
systemd_try_available() { command -v systemctl &>/dev/null; }

openrc_usable() {
  command -v rc-service &>/dev/null || command -v rc-update &>/dev/null || [[ -d /run/openrc ]]
}

s6_usable() {
  local init="${ENV_INIT:-}"
  [[ -n "$init" ]] || init="$(detect_init)"
  [[ "$init" == "s6" ]] || [[ -d /run/service ]] || return 1
  command -v s6-svc &>/dev/null || command -v s6-svscan &>/dev/null || [[ -d /run/service ]]
}

runit_usable() {
  command -v sv &>/dev/null || [[ -d /etc/service || -d /var/service || -d /service ]]
}

# 通用包安装（按 ENV_PKG）
pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  [[ -n "$ENV_PKG" ]] || probe_environment
  info "安装软件包 (${ENV_PKG}): ${pkgs[*]}"
  case "$ENV_PKG" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
      ;;
    dnf) dnf install -y "${pkgs[@]}" >/dev/null 2>&1 ;;
    yum) yum install -y "${pkgs[@]}" >/dev/null 2>&1 ;;
    apk) apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm "${pkgs[@]}" >/dev/null 2>&1 ;;
    zypper) zypper -n install "${pkgs[@]}" >/dev/null 2>&1 ;;
    *) err "未知包管理器，无法安装: ${pkgs[*]}"; return 1 ;;
  esac
}

# 状态灯（printf %b，避免 ANSI 打乱对齐）
_dot_ok()   { printf '%b' "${CG}●${C0}"; }
_dot_bad()  { printf '%b' "${CR}×${C0}"; }
_dot_todo() { printf '%b' "${CY}○${C0}"; }
_dot_dim()  { printf '%b' "${CB}·${C0}"; }

# 按终端显示宽度左对齐标签（中文算 2 列）
_label() {
  local s="$1" width="${2:-8}"
  local i c code w=0 out="$s"
  local -i n=${#s}
  for ((i=0; i<n; i++)); do
    c="${s:i:1}"
    # 粗略：非 ASCII 多字节字符按 2 列
    if [[ $(printf '%s' "$c" | wc -c) -gt 1 ]]; then
      w=$((w+2))
    else
      w=$((w+1))
    fi
  done
  while (( w < width )); do
    out+=" "
    w=$((w+1))
  done
  printf '%s' "$out"
}

_kv() {
  # _kv LABEL DOT TEXT
  printf "  "; _label "$1" 8; printf " %b %s\n" "$2" "$3"
}

_norm_active() {
  case "${1:-}" in
    active|running) echo "运行中" ;;
    inactive|dead) echo "已停止" ;;
    failed) echo "失败" ;;
    activating|reloading) echo "启动中" ;;
    ""|unknown) echo "异常" ;;
    *) echo "$1" ;;
  esac
}
_norm_enabled() {
  case "${1:-}" in
    enabled|enabled-runtime) echo "已自启" ;;
    disabled|disabled-runtime) echo "未自启" ;;
    static|indirect|generated|alias|transient) echo "$1" ;;
    ""|unknown|not-found) echo "-" ;;
    *) echo "$1" ;;
  esac
}

_unit_exists() {
  local name="$1"
  systemctl cat "${name}.service" &>/dev/null || systemctl status "${name}" &>/dev/null
}

# 左列固定 8 字符宽
_row() {
  local label="$1"
  shift
  printf "  %-8s " "$label"
  local part
  for part in "$@"; do
    printf '%b' "$part"
  done
  printf '\n'
}

# 按真实服务后端显示状态（非 systemd 时不再显示 unit异常）
# $1 显示名  $2 类型 cf|ssh  $3 进程匹配
_print_svc_line() {
  local label="$1" kind="$2" bin_pat="$3"
  local backend="${4:-}"
  local d_proc d_reg d_en
  local proc_txt reg_txt en_txt
  [[ -n "$backend" ]] || backend="$(prefer_service_backend 2>/dev/null || echo manual)"

  # 优先用快照，避免重复 pgrep
  local running=0
  if [[ "$kind" == "cf" && -n "${SNAP_TS:-}" && "${SNAP_TS:-0}" != "0" ]]; then
    running="${SNAP_CF_RUN:-0}"
  elif [[ "$kind" == "ssh" && -n "${SNAP_TS:-}" && "${SNAP_TS:-0}" != "0" ]]; then
    running="${SNAP_SSH_RUN:-0}"
  elif [[ -n "$bin_pat" ]] && pgrep -f "$bin_pat" &>/dev/null; then
    running=1
  fi
  if [[ "$running" -eq 1 ]]; then
    d_proc="$(_dot_ok)"; proc_txt="进程运行"
  else
    d_proc="$(_dot_bad)"; proc_txt="进程未运行"
  fi

  d_reg="$(_dot_todo)"; reg_txt="未注册"
  d_en="$(_dot_todo)"; en_txt="-"

  case "$backend" in
    systemd)
      local unit="" active="" enabled=""
      if [[ "$kind" == "cf" ]]; then unit="cloudflared"
      else
        if _unit_exists ssh; then unit=ssh
        elif _unit_exists sshd; then unit=sshd
        else unit=sshd
        fi
      fi
      if _unit_exists "$unit"; then
        active="$(systemctl is-active "$unit" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        if [[ "$active" == "active" ]]; then
          d_reg="$(_dot_ok)"; reg_txt="unit运行"
        else
          d_reg="$(_dot_todo)"; reg_txt="unit$(_norm_active "$active")"
        fi
        if [[ "$enabled" == "enabled" || "$enabled" == "enabled-runtime" ]]; then
          d_en="$(_dot_ok)"; en_txt="已自启"
        else
          d_en="$(_dot_todo)"; en_txt="$(_norm_enabled "$enabled")"
        fi
      else
        d_reg="$(_dot_todo)"; reg_txt="未装unit"
        d_en="$(_dot_todo)"; en_txt="未自启"
      fi
      ;;
    s6)
      if [[ "$kind" == "cf" ]]; then
        if [[ -e /run/service/svc-cloudflared || -d /opt/svc/cloudflared/s6 ]]; then
          d_reg="$(_dot_ok)"; reg_txt="s6已注册"
          # relink + s6 扫描 ≈ 开机可恢复
          if [[ -x /opt/svc/cloudflared/relink-s6.sh ]]; then
            d_en="$(_dot_ok)"; en_txt="已挂自启"
          else
            d_en="$(_dot_todo)"; en_txt="注册在/run"
          fi
          local st=""
          st="$(s6-svstat /run/service/svc-cloudflared 2>/dev/null || true)"
          if echo "$st" | grep -q '^up'; then
            reg_txt="s6监督中"
          elif pgrep -f "$bin_pat" &>/dev/null; then
            reg_txt="s6已注册"
          fi
        else
          d_reg="$(_dot_todo)"; reg_txt="s6未注册"
          d_en="$(_dot_todo)"; en_txt="-"
        fi
      else
        # ssh：容器镜像常自带，进程+22 即可
        if port_22_listening 2>/dev/null || pgrep -f "$bin_pat" &>/dev/null; then
          d_reg="$(_dot_ok)"; reg_txt="服务可用"
          d_en="$(_dot_ok)"; en_txt="随容器"
        else
          d_reg="$(_dot_todo)"; reg_txt="未就绪"
          d_en="$(_dot_dim)"; en_txt="-"
        fi
      fi
      ;;
    openrc)
      if [[ "$kind" == "cf" ]]; then
        if [[ -f /etc/init.d/cloudflared ]]; then
          d_reg="$(_dot_ok)"; reg_txt="openrc脚本"
          if rc-update show default 2>/dev/null | grep -q cloudflared; then
            d_en="$(_dot_ok)"; en_txt="已自启"
          else
            d_en="$(_dot_todo)"; en_txt="未加入default"
          fi
        else
          d_reg="$(_dot_todo)"; reg_txt="未装脚本"
        fi
      else
        if port_22_listening 2>/dev/null; then
          d_reg="$(_dot_ok)"; reg_txt="服务可用"
          d_en="$(_dot_ok)"; en_txt="随系统"
        else
          d_reg="$(_dot_todo)"; reg_txt="未就绪"
        fi
      fi
      ;;
    runit)
      if [[ "$kind" == "cf" ]]; then
        local found=0 d
        for d in /etc/service /var/service /service; do
          [[ -d "$d/cloudflared" ]] && found=1
        done
        if [[ "$found" -eq 1 ]]; then
          d_reg="$(_dot_ok)"; reg_txt="runit服务"
          d_en="$(_dot_ok)"; en_txt="已链接"
        else
          d_reg="$(_dot_todo)"; reg_txt="未注册"
        fi
      else
        if port_22_listening 2>/dev/null; then
          d_reg="$(_dot_ok)"; reg_txt="服务可用"
          d_en="$(_dot_ok)"; en_txt="随系统"
        else
          d_reg="$(_dot_todo)"; reg_txt="未就绪"
        fi
      fi
      ;;
    supervisor|*)
      if [[ "$kind" == "cf" ]]; then
        if [[ -x /opt/svc/cloudflared/supervisor.sh ]]; then
          d_reg="$(_dot_ok)"; reg_txt="supervisor"
          if pgrep -f 'cloudflared.*tunnel' &>/dev/null; then
            d_en="$(_dot_ok)"; en_txt="进程在跑"
          else
            d_en="$(_dot_bad)"; en_txt="脚本在进程无"
          fi
          if crontab -l 2>/dev/null | grep -q cloudflared; then
            if cron_daemon_running 2>/dev/null; then
              en_txt="${en_txt}+cron"
            else
              en_txt="${en_txt}+无cron"
            fi
          fi
        elif pgrep -f "$bin_pat" &>/dev/null; then
          d_reg="$(_dot_todo)"; reg_txt="散养进程"
          d_en="$(_dot_todo)"; en_txt="无自启"
        else
          d_reg="$(_dot_todo)"; reg_txt="未注册"
        fi
      else
        if [[ -x /opt/svc/sshd/supervisor.sh || -x /opt/svc/sshd/s6/run ]]; then
          d_reg="$(_dot_ok)"; reg_txt="已部署保活"
        else
          d_reg="$(_dot_todo)"; reg_txt="未部署保活"
        fi
        if port_22_listening 2>/dev/null; then
          d_en="$(_dot_ok)"; en_txt=":22在听"
        else
          d_en="$(_dot_bad)"; en_txt=":22未听"
        fi
      fi
      ;;
  esac

  printf "  "; _label "$label" 8; printf " "
  printf "%b %-8s  " "$d_proc" "$proc_txt"
  printf "%b %-10s  " "$d_reg" "$reg_txt"
  printf "%b %s\n" "$d_en" "$en_txt"
}

print_panel_service_monitor() {
  local backend
  [[ "${ENV_PROBED:-0}" -eq 1 ]] || PROBE_SKIP_NET=1 probe_environment
  backend="$(prefer_service_backend)"
  snapshot_runtime
  echo "── 服务监测 ────────────────────────────────"
  _kv "Init" "$(_dot_dim)" "$ENV_INIT (PID1=$(cat /proc/1/comm 2>/dev/null || echo ?))"
  _kv "后端" "$(_dot_ok)" "$backend (自动选型)"

  # 严格分情况：只展示当前正在用的后端，不用的一字不提
  case "$backend" in
    systemd)
      _kv "systemd" "$(_dot_ok)" "当前使用"
      echo "  （列: 进程 | unit状态 | 开机自启）"
      ;;
    openrc)
      _kv "openrc" "$(_dot_ok)" "当前使用"
      echo "  （列: 进程 | openrc脚本 | 开机自启）"
      ;;
    s6)
      _kv "s6" "$(_dot_ok)" "当前使用"
      echo "  （列: 进程 | s6注册 | 自启/恢复）"
      ;;
    runit)
      _kv "runit" "$(_dot_ok)" "当前使用"
      echo "  （列: 进程 | runit服务 | 链接自启）"
      ;;
    *)
      _kv "管理" "$(_dot_todo)" "supervisor/nohup"
      echo "  （列: 进程 | 注册方式 | 自启）"
      ;;
  esac

  _print_svc_line "cf" "cf" "cloudflared.*tunnel" "$backend"
  _print_svc_line "ssh" "ssh" "[s]shd" "$backend"

  if port_22_listening 2>/dev/null; then
    _kv ":22" "$(_dot_ok)" "监听中"
  else
    _kv ":22" "$(_dot_bad)" "未监听"
  fi

  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    case "$backend" in
      systemd)
        if systemctl is-active cloudflared &>/dev/null; then
          _kv "提示" "$(_dot_ok)" "cf 已由 systemd 管理"
        else
          _kv "提示" "$(_dot_todo)" "cf 进程在跑但未进 systemd → 选 1"
        fi
        ;;
      s6)
        if [[ -e /run/service/svc-cloudflared ]]; then
          _kv "提示" "$(_dot_ok)" "cf 已由 s6 管理"
        else
          _kv "提示" "$(_dot_todo)" "cf 进程在跑但未进 s6 → 选 1"
        fi
        ;;
      openrc)
        if [[ -f /etc/init.d/cloudflared ]]; then
          _kv "提示" "$(_dot_ok)" "cf 已由 OpenRC 管理"
        else
          _kv "提示" "$(_dot_todo)" "进程在跑未装 openrc 脚本 → 选 1"
        fi
        ;;
      runit)
        _kv "提示" "$(_dot_ok)" "cf 进程运行中 (runit)"
        ;;
      *)
        _kv "提示" "$(_dot_ok)" "cf 进程运行中 (supervisor/nohup)"
        ;;
    esac
  elif [[ -f "$CF_TOKEN_FILE" ]]; then
    _kv "提示" "$(_dot_todo)" "有 Token 未运行 → 选 1 或 5（自动 $backend）"
  else
    _kv "提示" "$(_dot_dim)" "无 Token → 菜单 5 配置"
  fi
  echo "  说明: 登记/脚本 ≠ 进程在跑；容器重启后请看进程列，不要只看「已挂自启」"
  echo "────────────────────────────────────────────"
}

# 管理台标题已并入环境指纹；保留空函数兼容旧调用
print_panel_header() {
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment
  refresh_cf_bin 2>/dev/null || true
}






# 停掉可能冲突的 cloudflared 实例
# 注意: 会中断隧道；若当前 SSH 走 CF，请在网页控制台执行，不要在隧道 SSH 里强杀
stop_cloudflared_instances() {
  local force="${1:-0}"
  systemctl stop cloudflared 2>/dev/null || true
  if [[ -e /run/service/svc-cloudflared ]]; then
    s6-svc -d /run/service/svc-cloudflared 2>/dev/null || true
  fi
  local sd
  sd="$(s6_dir 2>/dev/null || true)"
  if [[ -n "$sd" && -d "$sd/cloudflared" ]]; then
    s6-svc -d "$sd/cloudflared" 2>/dev/null || true
  fi
  if [[ -f /etc/init.d/cloudflared ]]; then
    rc-service cloudflared stop 2>/dev/null || true
  fi
  if [[ -f /opt/svc/cloudflared/.pid ]]; then
    kill "$(cat /opt/svc/cloudflared/.pid 2>/dev/null)" 2>/dev/null || true
    rm -f /opt/svc/cloudflared/.pid
  fi
  sleep 1
  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    pkill -TERM -f "cloudflared.*tunnel run" 2>/dev/null || true
    sleep 2
  fi
  if [[ "$force" == "1" ]] && pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    warn "强制结束 cloudflared（可能导致依赖隧道的 SSH 断开）"
    pkill -9 -f "cloudflared.*tunnel" 2>/dev/null || true
    sleep 1
  fi
}

# s6 注册：默认不杀已运行进程（防止 SSH 经隧道时把自己踢下线）
try_register_cloudflared_s6() {
  title "注册 cloudflared 为 s6 服务"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装，请先菜单 5 安装"; return 1; }
  local token
  token="$(load_tunnel_token)"
  if [[ -z "$token" ]]; then
    err "无 Token 文件: $CF_TOKEN_FILE"
    info "请先菜单 5 粘贴 Token"
    return 1
  fi

  local defdir="/opt/svc/cloudflared/s6"
  local scan="/run/service"
  local linkname="svc-cloudflared"
  mkdir -p "$defdir" /var/log /opt/svc/cloudflared

  if [[ ! -d "$scan" ]]; then
    warn "/run/service 不存在，改用 supervisor"
    return 1
  fi

  cat >"$defdir/run" <<EOF
#!/usr/bin/with-contenv bash
exec ${CF_BIN} --no-autoupdate tunnel run --token "\$(tr -d '\\015\\012' < ${CF_TOKEN_FILE})"
EOF
  if [[ ! -x /usr/bin/with-contenv ]]; then
    cat >"$defdir/run" <<EOF
#!/bin/sh
exec ${CF_BIN} --no-autoupdate tunnel run --token "\$(tr -d '\\015\\012' < ${CF_TOKEN_FILE})"
EOF
  fi
  chmod +x "$defdir/run"
  cat >"$defdir/finish" <<'EOF'
#!/bin/sh
echo "$(date): cloudflared exited ($?), restart in 5s" >> /var/log/cloudflared.log
sleep 5
exit 1
EOF
  chmod +x "$defdir/finish"

  ln -sfn "$defdir" "$scan/$linkname"
  ok "已链接 $scan/$linkname -> $defdir"

  cat >/opt/svc/cloudflared/relink-s6.sh <<EOF
#!/bin/sh
mkdir -p /run/service
ln -sfn $defdir /run/service/$linkname
command -v s6-svscanctl >/dev/null 2>&1 && s6-svscanctl -a /run/service
command -v s6-svc >/dev/null 2>&1 && s6-svc -u /run/service/$linkname
EOF
  chmod +x /opt/svc/cloudflared/relink-s6.sh
  install_crontab_reboot \
    "@reboot /opt/svc/cloudflared/relink-s6.sh >> /var/log/cloudflared.log 2>&1" \
    "relink-s6" || true
  _note_keepalive_scope

  if command -v s6-svscanctl &>/dev/null; then
    s6-svscanctl -a "$scan" 2>/dev/null || true
  fi

  # 已有进程：不杀，只保证配置落盘
  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    local st=""
    st="$(s6-svstat "$scan/$linkname" 2>/dev/null || true)"
    if echo "$st" | grep -q '^up'; then
      ok "s6 监督中且进程 up（容器整实例重启后需再验收进程）"
      echo "  $st"
      return 0
    fi
    ok "s6 配置已写入；进程当前在跑（登记≠容器重启后必起）"
    warn "未强制重启进程（防止隧道 SSH 断连）。进程退出后将由 s6 自动拉起。"
    info "若必须热切换到 s6 监督，请在【网页控制台】执行: s6-svc -t $scan/$linkname"
    return 0
  fi

  # 未运行：启动
  if command -v s6-svc &>/dev/null; then
    s6-svc -u "$scan/$linkname" 2>/dev/null || true
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
      ok "s6 注册成功: $scan/$linkname"
      s6-svstat "$scan/$linkname" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  warn "s6 未拉起进程"
  s6-svstat "$scan/$linkname" 2>/dev/null || true
  return 1
}


try_register_cloudflared_supervisor() {
  title "注册 cloudflared supervisor（崩溃自启）"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装"; return 1; }
  local token
  token="$(load_tunnel_token)"
  [[ -n "$token" ]] || { err "无 Token: $CF_TOKEN_FILE"; return 1; }

  mkdir -p /opt/svc/cloudflared /var/log
  local already_run=0
  pgrep -f "cloudflared.*tunnel" &>/dev/null && already_run=1

  cat >/opt/svc/cloudflared/supervisor.sh <<EOF
#!/bin/bash
BIN="${CF_BIN}"
TOKEN_FILE="${CF_TOKEN_FILE}"
LOG="/var/log/cloudflared.log"
PIDF="/opt/svc/cloudflared/.pid"
echo \$\$ > "\$PIDF"
echo "\$(date): supervisor start PID=\$\$" >> "\$LOG"
while true; do
  if [[ ! -x "\$BIN" ]]; then
    echo "\$(date): binary missing, sleep 30" >> "\$LOG"
    sleep 30
    continue
  fi
  if [[ ! -s "\$TOKEN_FILE" ]]; then
    echo "\$(date): token missing, sleep 30" >> "\$LOG"
    sleep 30
    continue
  fi
  TOK=\$(tr -d '\\015\\012' < "\$TOKEN_FILE")
  echo "\$(date): starting cloudflared" >> "\$LOG"
  "\$BIN" --no-autoupdate tunnel run --token "\$TOK" >> "\$LOG" 2>&1
  rc=\$?
  case \$rc in
    130|143|137)
      echo "\$(date): stopped by signal \$rc" >> "\$LOG"
      rm -f "\$PIDF"
      exit 0
      ;;
    *)
      echo "\$(date): exited \$rc, restart in 5s" >> "\$LOG"
      sleep 5
      ;;
  esac
done
EOF
  chmod +x /opt/svc/cloudflared/supervisor.sh

  install_crontab_reboot \
    "@reboot /opt/svc/cloudflared/supervisor.sh >> /var/log/cloudflared.log 2>&1 &" \
    "cloudflared/supervisor" || true
  _note_keepalive_scope
  if [[ -f /etc/rc.local ]]; then
    if ! grep -q cloudflared/supervisor /etc/rc.local 2>/dev/null; then
      sed -i '/^exit 0/i\/opt\/svc\/cloudflared\/supervisor.sh >> \/var\/log\/cloudflared.log 2>\&1 \&' /etc/rc.local 2>/dev/null || true
    fi
  fi

  if [[ "${already_run:-0}" -eq 1 ]]; then
    ok "supervisor 脚本已写入；进程当前在跑（未强杀；容器重启后不保证）"
    return 0
  fi
  nohup /opt/svc/cloudflared/supervisor.sh >>/var/log/cloudflared.log 2>&1 &
  echo $! >/opt/svc/cloudflared/.pid
  sleep 2
  if pgrep -f "cloudflared.*tunnel" &>/dev/null || kill -0 "$(cat /opt/svc/cloudflared/.pid 2>/dev/null)" 2>/dev/null; then
    ok "supervisor 已启动 PID=$(cat /opt/svc/cloudflared/.pid 2>/dev/null) 日志 /var/log/cloudflared.log"
    return 0
  fi
  err "supervisor 启动失败"
  return 1
}

# systemd 注册（仅真正可用时）
try_install_cloudflared_systemd() {
  title "尝试注册 cloudflared 为 systemd 服务"
  if ! systemd_usable; then
    err "systemd 不可用（Init=$(detect_init), is-system-running=$(systemctl is-system-running 2>/dev/null || echo n/a)）"
    return 1
  fi

  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装，请先菜单 5 安装"; return 1; }
  local token
  token="$(load_tunnel_token)"
  if [[ -z "$token" ]]; then
    err "无 Token 文件: $CF_TOKEN_FILE"
    info "请先菜单 5 粘贴 Token"
    return 1
  fi

  mkdir -p "$CF_DIR"
  local already_run=0
  pgrep -f "cloudflared.*tunnel" &>/dev/null && already_run=1

  cat >/etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel (token mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c 'exec ${CF_BIN} --no-autoupdate tunnel run --token "\$(tr -d "\\015\\012" < ${CF_TOKEN_FILE})"'
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  ok "已写入 /etc/systemd/system/cloudflared.service"

  set +e
  systemctl daemon-reload
  local rc_reload=$?
  systemctl enable cloudflared
  local rc_en=$?
  local rc_rs=0 st=""
  if [[ "${already_run:-0}" -eq 1 ]]; then
    info "进程已在运行：跳过 systemctl restart（防断 SSH）"
    st="$(systemctl is-active cloudflared 2>/dev/null || true)"
    set -e
    echo "  daemon-reload=$rc_reload  enable=$rc_en  restart=skipped  is-active=${st:-unknown}"
    ok "systemd unit 已写入并 enable；进程保持原样运行"
    return 0
  fi
  systemctl restart cloudflared
  rc_rs=$?
  sleep 2
  st="$(systemctl is-active cloudflared 2>/dev/null)"
  set -e

  echo "  daemon-reload=$rc_reload  enable=$rc_en  restart=$rc_rs  is-active=${st:-unknown}"
  if [[ "$st" == "active" ]]; then
    ok "cloudflared systemd 已 active（systemd 下开机自启以 enable 为准）"
    systemctl --no-pager --full status cloudflared 2>/dev/null | head -20 || true
    return 0
  fi

  err "systemd 注册失败或未 active"
  systemctl --no-pager --full status cloudflared 2>&1 | head -30 || true
  return 1
}

# OpenRC 注册 cloudflared
try_register_cloudflared_openrc() {
  title "注册 cloudflared 为 OpenRC 服务"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装"; return 1; }
  local token; token="$(load_tunnel_token)"
  [[ -n "$token" ]] || { err "无 Token: $CF_TOKEN_FILE"; return 1; }
  local already_run=0
  pgrep -f "cloudflared.*tunnel" &>/dev/null && already_run=1
  cat >/etc/init.d/cloudflared <<EOF
#!/sbin/openrc-run
name="cloudflared"
command="${CF_BIN}"
command_args="--no-autoupdate tunnel run --token \$(tr -d '\\015\\012' < ${CF_TOKEN_FILE})"
command_background=true
pidfile="/run/cloudflared.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.log"
depend() { need net; }
EOF
  chmod +x /etc/init.d/cloudflared
  rc-update add cloudflared default 2>/dev/null || true
  if [[ "${already_run:-0}" -eq 1 ]]; then
    ok "OpenRC 脚本已安装；进程已在运行（未 restart，防断 SSH）"
    return 0
  fi
  rc-service cloudflared restart 2>/dev/null || rc-service cloudflared start 2>/dev/null || true
  sleep 2
  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    ok "OpenRC 注册成功"
    return 0
  fi
  err "OpenRC 启动失败"
  return 1
}

# runit 注册
try_register_cloudflared_runit() {
  title "注册 cloudflared 为 runit 服务"
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装"; return 1; }
  local token; token="$(load_tunnel_token)"
  [[ -n "$token" ]] || { err "无 Token"; return 1; }
  local svdir=""
  for d in /etc/service /var/service /service; do
    [[ -d "$d" ]] && { svdir="$d"; break; }
  done
  [[ -n "$svdir" ]] || { err "无 runit service 目录"; return 1; }
  stop_cloudflared_instances
  mkdir -p "$svdir/cloudflared"
  cat >"$svdir/cloudflared/run" <<EOF
#!/bin/sh
exec ${CF_BIN} --no-autoupdate tunnel run --token "\$(tr -d '\\015\\012' < ${CF_TOKEN_FILE})"
EOF
  chmod +x "$svdir/cloudflared/run"
  if command -v sv &>/dev/null; then
    sv up cloudflared 2>/dev/null || sv start cloudflared 2>/dev/null || true
  fi
  sleep 2
  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    ok "runit 注册成功: $svdir/cloudflared"
    return 0
  fi
  err "runit 启动失败"
  return 1
}

# 统一入口：按探测结果自动选型（systemd→openrc→s6→runit→supervisor）
# 若已在运行：只补注册、默认不杀进程，避免隧道 SSH 自杀
try_register_cloudflared() {
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment
  local backend
  backend="$(prefer_service_backend)"
  info "环境: Init=$ENV_INIT CT=$ENV_CT PKG=$ENV_PKG ARCH=$ENV_ARCH → 后端=$backend"

  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 未安装，请先菜单 5"; return 1; }
  local token; token="$(load_tunnel_token)"
  [[ -n "$token" ]] || { err "无 Token: $CF_TOKEN_FILE（请菜单 5 配置）"; return 1; }

  if pgrep -f "cloudflared.*tunnel" &>/dev/null; then
    info "检测到 cloudflared 已在运行 → 安全模式：补注册、不强制杀进程"
  fi

  if systemd_usable; then
    try_install_cloudflared_systemd && return 0
    warn "systemd 失败，尝试下一档"
  fi
  if openrc_usable; then
    try_register_cloudflared_openrc && return 0
    warn "openrc 失败，尝试下一档"
  fi
  if s6_usable || [[ "$ENV_INIT" == "s6" ]]; then
    try_register_cloudflared_s6 && return 0
    warn "s6 失败，尝试下一档"
  fi
  if runit_usable; then
    try_register_cloudflared_runit && return 0
    warn "runit 失败，尝试 supervisor"
  fi
  try_register_cloudflared_supervisor
}



try_install_sshd_systemd() {
  title "注册/确保 SSH 服务可用"
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment

  if port_22_listening; then
    ok "本机 22 已在监听（Init=$ENV_INIT）"
    pgrep -af '[s]shd' | head -3 || true
    try_register_sshd_supervisor || true
    return 0
  fi

  ensure_sshd_running || true
  if port_22_listening; then
    ok "sshd 已拉起，22 监听中"
    return 0
  fi

  if systemd_usable; then
    info "尝试 systemd enable/restart ssh|sshd"
    set +e
    systemctl daemon-reload
    local unit=""
    if systemctl cat ssh.service &>/dev/null; then unit=ssh
    elif systemctl cat sshd.service &>/dev/null; then unit=sshd
    else unit=ssh
    fi
    systemctl enable "$unit" 2>/dev/null || systemctl enable sshd 2>/dev/null
    systemctl restart "$unit" 2>/dev/null || systemctl restart sshd 2>/dev/null
    sleep 1
    set -e
    if port_22_listening; then ok "SSH systemd 启动成功 unit=${unit}"; return 0; fi
  fi

  if openrc_usable; then
    info "尝试 OpenRC 启动 sshd"
    rc-service sshd restart 2>/dev/null || rc-service ssh restart 2>/dev/null || true
    rc-update add sshd default 2>/dev/null || true
    sleep 1
    if port_22_listening; then ok "SSH OpenRC 可用"; return 0; fi
  fi

  if [[ "$ENV_INIT" == "s6" ]] || s6_usable; then
    info "s6 环境：查找已有 ssh 并统一注册 svc-sshd"
    local sd name
    sd="$(s6_dir)"
    for name in sshd ssh openssh openssh-server svc-sshd svc-ssh; do
      if [[ -d "$sd/$name" || -e "$sd/$name" ]]; then
        s6-svc -u "$sd/$name" 2>/dev/null || s6-svc -a "$sd/$name" 2>/dev/null || true
      fi
    done
    sleep 1
    if port_22_listening; then
      ok "s6 下 SSH 已可用"
      try_register_sshd_s6 || true
      return 0
    fi
    info "创建 svc-sshd（与 CF 同模式）"
    if try_register_sshd_s6; then return 0; fi
  fi

  if runit_usable; then
    sv up ssh 2>/dev/null || sv up sshd 2>/dev/null || true
    sleep 1
    if port_22_listening; then ok "runit 下 SSH 已可用"; return 0; fi
  fi

  info "直接启动 sshd 二进制（通用回退）"
  # 尽量用包管理器装 openssh-server
  if ! command -v sshd &>/dev/null; then
    case "${ENV_PKG}" in
      apt) pkg_install openssh-server || true ;;
      dnf|yum) pkg_install openssh-server || true ;;
      apk) pkg_install openssh || true ;;
    esac
  fi
  mkdir -p /var/run/sshd 2>/dev/null || true
  [[ -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_rsa_key ]] || ssh-keygen -A 2>/dev/null || true
  /usr/sbin/sshd 2>/dev/null || sshd 2>/dev/null || true
  sleep 1
  if port_22_listening; then
    ok "sshd 已直接启动"
    # 容器/无 systemd：必须挂保活，否则过几天进程没了 22 就不监听
    try_register_sshd_supervisor || true
    return 0
  fi
  err "SSH 仍无法监听 22（环境=$ENV_INIT/$ENV_CT）"
  ps aux | grep -E '[s]shd' || true
  # 仍尝试挂保活脚本，便于下次拉起
  try_register_sshd_supervisor || true
  return 1
}

# 容器/supervisord 环境：sshd 与 cloudflared 一样需要「崩溃/消失后自动再起」
# 注意：必须用 sshd -D（前台），否则守护进程化后 while 循环会狂刷新进程

# ----- 自启/保活诚实校验（避免假阳性） -----
cron_daemon_running() {
  pgrep -x cron &>/dev/null || pgrep -x crond &>/dev/null || pgrep -f '[c]ron(d)? ' &>/dev/null
}

# 写入 @reboot；0=写入且cron在跑 1=写入但无cron 2=失败
install_crontab_reboot() {
  local line="$1" tag="$2"
  if ! command -v crontab &>/dev/null; then
    warn "无 crontab 命令 → 无法写 @reboot（${tag}）"
    return 2
  fi
  if (crontab -l 2>/dev/null | grep -vF "$tag"; echo "$line") | crontab - 2>/dev/null; then
    if cron_daemon_running; then
      ok "已写 crontab @reboot（${tag}），且 cron 守护进程在跑"
      return 0
    fi
    warn "crontab 已写入（${tag}），但未检测到 cron/crond → @reboot 在本环境【基本无效】"
    warn "  容器/沙箱重启后不会靠 cron 拉起；需 s6/平台启动命令或手动恢复"
    return 1
  fi
  warn "crontab 写入失败（${tag}）"
  return 2
}

_note_keepalive_scope() {
  info "保活范围: 进程崩溃可自动再起；【容器/沙箱整实例重启或休眠】不保证自动恢复"
}

try_register_sshd_supervisor() {
  title "注册 sshd 进程保活"
  if ! is_root; then
    err "注册 sshd 保活需要 root"
    return 1
  fi
  if [[ "${ENV_INIT:-}" == "s6" ]] || s6_usable 2>/dev/null; then
    info "检测到 s6，优先 s6 注册 sshd（与 CF 同后端）"
    if try_register_sshd_s6; then
      return 0
    fi
    warn "s6 注册 sshd 未完全成功，回退 nohup supervisor"
  fi
  if ! command -v sshd &>/dev/null && [[ ! -x /usr/sbin/sshd ]]; then
    err "未找到 sshd"
    return 1
  fi
  local bin="/usr/sbin/sshd"
  [[ -x "$bin" ]] || bin="$(command -v sshd)"
  mkdir -p /opt/svc/sshd /var/log /var/run/sshd
  [[ -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_rsa_key ]] || ssh-keygen -A 2>/dev/null || true

  cat >/opt/svc/sshd/supervisor.sh <<EOF
#!/bin/bash
BIN="${bin}"
LOG="/var/log/sshd-supervisor.log"
PIDF="/opt/svc/sshd/.pid"
mkdir -p /var/run/sshd /opt/svc/sshd
echo \$\$ > "\$PIDF"
echo "\$(date -Iseconds): sshd supervisor start PID=\$\$" >> "\$LOG"
while true; do
  if ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]' \\
     || netstat -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
    sleep 15
    continue
  fi
  if [[ ! -x "\$BIN" ]]; then
    echo "\$(date -Iseconds): sshd missing, sleep 30" >> "\$LOG"
    sleep 30
    continue
  fi
  if [[ ! -f /etc/ssh/ssh_host_rsa_key && ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -A >>"\$LOG" 2>&1 || true
  fi
  echo "\$(date -Iseconds): starting \$BIN -D" >> "\$LOG"
  "\$BIN" -D >>"\$LOG" 2>&1
  rc=\$?
  echo "\$(date -Iseconds): sshd -D exit \$rc, restart 3s" >> "\$LOG"
  sleep 3
done
EOF
  chmod +x /opt/svc/sshd/supervisor.sh

  local sup_ok=0
  if pgrep -f '/opt/svc/sshd/supervisor\.sh' &>/dev/null; then
    ok "sshd supervisor 进程在跑"
    sup_ok=1
  else
    if ! port_22_listening; then
      "$bin" 2>/dev/null || true
      sleep 1
    fi
    nohup /opt/svc/sshd/supervisor.sh >>/var/log/sshd-supervisor.log 2>&1 &
    echo $! >/opt/svc/sshd/.pid
    sleep 1
    if pgrep -f '/opt/svc/sshd/supervisor\.sh' &>/dev/null; then
      ok "已启动 sshd supervisor 进程"
      sup_ok=1
    else
      err "sshd supervisor 未保持运行，见 /var/log/sshd-supervisor.log"
      tail -15 /var/log/sshd-supervisor.log 2>/dev/null || true
    fi
  fi

  install_crontab_reboot \
    "@reboot /opt/svc/sshd/supervisor.sh >> /var/log/sshd-supervisor.log 2>&1" \
    "/opt/svc/sshd/supervisor" || true
  _note_keepalive_scope

  if port_22_listening && [[ "$sup_ok" -eq 1 ]]; then
    ok "验收: :22 监听 且 supervisor 进程在跑（仅进程级保活）"
    return 0
  fi
  if port_22_listening; then
    warn "验收: :22 在听，但 supervisor 未确认 → 崩溃后可能不会自动再起"
    return 0
  fi
  warn "验收失败: :22 仍未监听"
  return 1
}

try_register_sshd_s6() {
  title "注册 sshd 为 s6 服务（与 CF 统一）"
  if ! is_root; then err "需要 root"; return 1; fi
  if ! command -v sshd &>/dev/null && [[ ! -x /usr/sbin/sshd ]]; then
    err "未找到 sshd"; return 1
  fi
  local bin="/usr/sbin/sshd"
  [[ -x "$bin" ]] || bin="$(command -v sshd)"
  local scan defdir linkname="svc-sshd"
  scan="$(s6_dir 2>/dev/null || echo /run/service)"
  mkdir -p "$scan" /opt/svc/sshd /var/run/sshd /var/log
  [[ -f /etc/ssh/ssh_host_ed25519_key || -f /etc/ssh/ssh_host_rsa_key ]] || ssh-keygen -A 2>/dev/null || true
  defdir="/opt/svc/sshd/s6"
  mkdir -p "$defdir"
  cat >"$defdir/run" <<EOF
#!/bin/sh
exec 2>&1
mkdir -p /var/run/sshd
exec ${bin} -D
EOF
  chmod +x "$defdir/run"
  cat >"$defdir/finish" <<'EOF'
#!/bin/sh
echo "sshd exited ($1), s6 restart" >> /var/log/sshd-supervisor.log
exec sleep 2
EOF
  chmod +x "$defdir/finish"
  ln -sfn "$defdir" "$scan/$linkname"
  ok "s6 已链接 $scan/$linkname"

  cat >/opt/svc/sshd/relink-s6.sh <<EOF
#!/bin/sh
mkdir -p /run/service
ln -sfn $defdir /run/service/$linkname
command -v s6-svscanctl >/dev/null 2>&1 && s6-svscanctl -a /run/service
command -v s6-svc >/dev/null 2>&1 && s6-svc -u /run/service/$linkname
if ! ss -ltn 2>/dev/null | grep -qE ':(22)[[:space:]]'; then
  ${bin} 2>/dev/null || true
fi
EOF
  chmod +x /opt/svc/sshd/relink-s6.sh
  install_crontab_reboot \
    "@reboot /opt/svc/sshd/relink-s6.sh >> /var/log/sshd-supervisor.log 2>&1" \
    "/opt/svc/sshd/relink-s6" || true

  if command -v s6-svscanctl &>/dev/null; then
    s6-svscanctl -a "$scan" 2>/dev/null || true
  fi
  if ! port_22_listening; then
    command -v s6-svc &>/dev/null && s6-svc -u "$scan/$linkname" 2>/dev/null || true
    sleep 1
    if ! port_22_listening; then
      "$bin" 2>/dev/null || true
      sleep 1
    fi
  fi
  _note_keepalive_scope
  if port_22_listening; then
    ok "验收: :22 在监听；s6=$(s6-svstat "$scan/$linkname" 2>/dev/null || echo n/a)"
    return 0
  fi
  err "s6 注册后 :22 仍未监听"
  return 1
}

menu_try_systemd_services() {
  title "1. 查看 Init(ps -p 1) + 注册自启服务"
  [[ "${ENV_PROBED:-0}" -eq 1 ]] || PROBE_SKIP_NET=1 probe_environment
  echo "── 系统 Init 类型（ps -p 1）────────────────"
  if command -v ps &>/dev/null; then
    ps -p 1 -o pid,ppid,user,comm,args 2>/dev/null \
      || ps -p 1 -o pid,user,comm,args 2>/dev/null \
      || ps -p 1 2>/dev/null \
      || echo "  (ps 不可用)"
  else
    echo "  /proc/1/comm: $(cat /proc/1/comm 2>/dev/null || echo ?)"
    echo "  /proc/1/cmdline: $(tr '\0' ' ' </proc/1/cmdline 2>/dev/null || echo ?)"
  fi
  echo "  /proc/1/comm = $(cat /proc/1/comm 2>/dev/null || echo ?)"
  echo "  探测归类 ENV_INIT = ${ENV_INIT:-?} （detect_init）"
  echo "  推荐后端         = $(prefer_service_backend)"
  echo "  包管理/架构/运行时 = ${ENV_PKG:-?} / ${ENV_ARCH:-?} / ${ENV_CT:-?}"
  echo "────────────────────────────────────────────"
  echo
  echo "探测结果: Init=$ENV_INIT | 包=$ENV_PKG | Arch=$ENV_ARCH | 运行时=$ENV_CT | 权限=$ENV_PRIV"
  echo "策略: systemd → openrc → s6 → runit → supervisor（成功即停）"
  echo
  warn "若 SSH 走 Cloudflare 隧道：注册时默认不杀已运行 cloudflared，避免把自己踢下线。"
  info "必须热切换时请用网页控制台/物理终端，不要在隧道 SSH 里强杀进程。"
  echo
  print_compact_summary
  echo
  echo "1) 注册 cloudflared（需已有 Token）"
  echo "2) 注册/确保 sshd + 保活（防过几天 22 没了）"
  echo "3) 两项都试（推荐）"
  echo "i) 仅再显示一次 Init（ps -p 1）"
  echo "0) 返回"
  local c
  read -r -p "请选择 [3]: " c
  c="${c:-3}"
  case "$c" in
    1)
      if need_root_or_skip "注册 cloudflared"; then try_register_cloudflared || true; fi
      ;;
    2)
      if need_root_or_skip "注册/保活 sshd"; then
        try_install_sshd_systemd || true
        try_register_sshd_supervisor || true
      fi
      ;;
    3)
      if need_root_or_skip "注册 sshd+cloudflared"; then
        try_install_sshd_systemd || true
        try_register_sshd_supervisor || true
        echo
        try_register_cloudflared || true
      fi
      ;;
    i|I)
      echo
      ps -p 1 -o pid,ppid,user,comm,args 2>/dev/null || ps -p 1 2>/dev/null || true
      echo "  ENV_INIT=$(detect_init)  backend=$(prefer_service_backend)"
      ;;
    0) return ;;
    *) warn "无效选项" ;;
  esac
  echo
  print_compact_summary
  pause
}




# =============================================================================
# 96/97/98 快速临时 SSH（不碰固定隧道自启）
# =============================================================================
QUICK_SSH_USER="${QUICK_SSH_USER:-kkb}"
QUICK_SSH_PASS="${QUICK_SSH_PASS:-1q2w3e4r}"
QUICK_SSH_LOCAL_PORT="${QUICK_SSH_LOCAL_PORT:-2222}"
# 路径：root 用 /run+/var/log；普通用户用 ~/.ssh-aotu（穿透不依赖 root）
_init_quick_ssh_paths() {
  if is_root; then
    QUICK_SSH_PID="${QUICK_SSH_PID:-/run/vps-quick-ssh.pid}"
    QUICK_SSH_LOG="${QUICK_SSH_LOG:-/var/log/vps-quick-ssh.log}"
    QUICK_SSH_URL="${QUICK_SSH_URL:-/run/vps-quick-ssh.url}"
    USER_CF_DIR="${USER_CF_DIR:-/usr/local/bin}"
  else
    local d="${HOME}/.ssh-aotu"
    mkdir -p "$d" 2>/dev/null || d="/tmp/ssh-aotu-${USER:-u}"
    mkdir -p "$d" 2>/dev/null || true
    QUICK_SSH_PID="${QUICK_SSH_PID:-$d/quick-ssh.pid}"
    QUICK_SSH_LOG="${QUICK_SSH_LOG:-$d/quick-ssh.log}"
    QUICK_SSH_URL="${QUICK_SSH_URL:-$d/quick-ssh.url}"
    USER_CF_DIR="${USER_CF_DIR:-$d}"
  fi
}
_init_quick_ssh_paths
# 兼容旧变量名
QUICK_SSH_PID="${QUICK_SSH_PID}"
QUICK_SSH_LOG="${QUICK_SSH_LOG}"
QUICK_SSH_URL="${QUICK_SSH_URL}"

# 最近一次临时隧道失败原因: rate_limit | dead | timeout | none
QUICK_TUNNEL_ERR=""

# 非交互创建/改密（96 专用）
ensure_user_password_force() {
  local user="$1" pass="$2" shell="${3:-/bin/bash}"
  validate_username "$user" || return 1
  [[ -n "$pass" ]] || { err "密码为空"; return 1; }
  if id "$user" &>/dev/null; then
    echo "${user}:${pass}" | chpasswd
    ok "用户已存在，已重置密码: $user"
  else
    useradd -m -s "$shell" "$user"
    echo "${user}:${pass}" | chpasswd
    ok "已创建用户: $user"
  fi
  LAST_USER="$user"
  LAST_PASS="$pass"
}

stop_quick_temp_ssh_tunnel() {
  local pid=""
  if [[ -f "$QUICK_SSH_PID" ]]; then
    pid="$(cat "$QUICK_SSH_PID" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  # 只杀「临时 tcp 隧道」，不动固定 token 隧道
  pkill -f "cloudflared.*tunnel --url tcp://127.0.0.1:22" 2>/dev/null || true
  pkill -f "cloudflared.*tunnel --url ssh://localhost:22" 2>/dev/null || true
  pkill -f "cloudflared.*tunnel --url tcp://localhost:22" 2>/dev/null || true
  rm -f "$QUICK_SSH_PID" "$QUICK_SSH_URL"
}

# 从日志解析 trycloudflare 主机名
parse_quick_tunnel_host() {
  local logf="${1:-$QUICK_SSH_LOG}"
  local host=""
  host="$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' "$logf" 2>/dev/null | tail -1 || true)"
  echo "$host"
}

# 日志是否 trycloudflare 限流
is_quick_tunnel_rate_limited() {
  local logf="${1:-$QUICK_SSH_LOG}"
  [[ -f "$logf" ]] || return 1
  grep -qE '429|Too Many Requests|error code: 1015|status_code="429"' "$logf" 2>/dev/null
}

# =============================================================================
# 96 临时隧道：直连失败后，仅走 SOCKS5 重试
# - 已有 SOCKS：问是否用（回车=Y）
# - 没有：问是否抓取 SOCKS5 再试（回车=Y）→ 拉 50 条新节点
#   · 延迟 <100ms 立刻用来开隧道
#   · 延迟 >1000ms 跳过
#   · 100–1000ms 作为候选依次试
#   · 本批全失败再问是否换一批（不复用上一批）
# =============================================================================

# 读当前已配置的 SOCKS5（只认 SOCKS，不认 WARP/HTTP）
load_current_socks5() {
  local f ep url
  for f in /etc/proxy-mgr/socks5.env "${HOME}/.proxy-mgr/socks5.env" /home/cj/.proxy-mgr/socks5.env; do
    [[ -f "$f" ]] || continue
    ep="$(grep '^SOCKS5_ENDPOINT=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    url="$(grep '^SOCKS5_URL=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    if [[ "$ep" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
      if [[ -z "$url" || "$url" != socks* ]]; then
        url="socks5h://${ep}"
      fi
      [[ "$url" == socks5://* ]] && url="socks5h://${url#socks5://}"
      # 只接受 socks 协议
      [[ "$url" =~ ^socks5h?:// ]] || continue
      echo "$url"
      return 0
    fi
  done
  # 环境变量里若是 socks
  local u
  for u in "${ALL_PROXY:-}" "${all_proxy:-}" "${SOCKS_PROXY:-}" "${socks_proxy:-}"; do
    [[ -z "$u" ]] && continue
    if [[ "$u" =~ ^socks5h?:// ]] || [[ "$u" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
      [[ "$u" =~ ^[0-9] ]] && u="socks5h://${u}"
      [[ "$u" == socks5://* ]] && u="socks5h://${u#socks5://}"
      echo "$u"
      return 0
    fi
  done
  return 1
}

# 测单个 SOCKS5 延迟(ms)；失败返回非0。stdout 仅数字毫秒
_quick_socks5_latency_ms() {
  local ep="$1"  # host:port 或 socks5h://host:port
  local host port start end ms out
  ep="${ep#socks5h://}"
  ep="${ep#socks5://}"
  host="${ep%:*}"
  port="${ep##*:}"
  [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null || return 1
  fi
  start=$(date +%s%3N 2>/dev/null || date +%s)
  out="$(curl -4 -fsS --connect-timeout 2 --max-time 2 \
    --socks5-hostname "${host}:${port}" \
    https://api.ipify.org 2>/dev/null | tr -d '[:space:]' | head -c 64 || true)"
  end=$(date +%s%3N 2>/dev/null || date +%s)
  [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  if [[ ${#start} -ge 12 ]]; then ms=$((end - start)); else ms=$(( (end - start) * 1000 )); fi
  [[ $ms -lt 1 ]] && ms=1
  # >1000 视为不合格
  [[ $ms -gt 1000 ]] && return 1
  echo "$ms"
  return 0
}

# 从 proxy.sh 同源列表抓一批 SOCKS5 地址（stdout 每行 host:port），尽量避开 used 文件
# $1=数量  $2=已用文件(可选)
_fetch_socks5_batch() {
  local need="${1:-50}"
  local usedf="${2:-}"
  local urls=(
    "https://cdn.jsdelivr.net/gh/proxyscrape/free-proxy-list@main/proxies/protocols/socks5/data.txt"
    "https://raw.githubusercontent.com/proxygenerator1/ProxyGenerator/main/MostStable/socks5.txt"
    "https://raw.githubusercontent.com/VPSLabCloud/VPSLab-Free-Proxy-List/main/socks5_all.txt"
    "https://raw.githubusercontent.com/iplocate/free-proxy-list/main/protocols/socks5.txt"
  )
  local tmp raw u mirrors m
  tmp="$(mktemp 2>/dev/null || echo /tmp/vps-socks-batch.$$)"
  : >"$tmp"
  for u in "${urls[@]}"; do
    raw="$(mktemp 2>/dev/null || echo /tmp/vps-socks-raw.$$)"
    mirrors=("$u")
    if [[ "$u" == https://raw.githubusercontent.com/* ]]; then
      mirrors+=("https://ghfast.top/${u}" "https://ghproxy.net/${u}")
    fi
    for m in "${mirrors[@]}"; do
      if curl -fsSL --connect-timeout 6 --max-time 25 -o "$raw" "$m" 2>/dev/null && [[ -s "$raw" ]]; then
        break
      fi
    done
    if [[ -s "$raw" ]]; then
      awk '
        {
          gsub(/\r/,"");
          if (match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+/))
            print substr($0, RSTART, RLENGTH);
        }
      ' "$raw" >>"$tmp"
    fi
    rm -f "$raw"
  done
  # 去重、打乱、排除已用
  if [[ -n "$usedf" && -f "$usedf" ]]; then
    sort -u "$tmp" | grep -v -F -f "$usedf" 2>/dev/null | shuf 2>/dev/null | head -n "$need" \
      || sort -u "$tmp" | grep -v -F -f "$usedf" 2>/dev/null | head -n "$need"
  else
    sort -u "$tmp" | shuf 2>/dev/null | head -n "$need" \
      || sort -u "$tmp" | head -n "$need"
  fi
  rm -f "$tmp"
}

# 用一批 SOCKS 测延迟并尝试开隧道；成功 return 0
# 规则：ms<100 立刻开隧道；ms>1000 跳过；其余先收集再按延迟升序试
_try_tunnel_with_socks_batch() {
  local -a batch=("$@")
  local -a mid=()  # "ms|host:port"
  local ep ms url
  local i=0 n=${#batch[@]}
  info "本批 ${n} 条 SOCKS5：<100ms 立刻用，>1000ms 跳过，其余稍后按延迟试..."
  for ep in "${batch[@]}"; do
    i=$((i + 1))
    ms="$(_quick_socks5_latency_ms "$ep" 2>/dev/null || true)"
    if [[ -z "$ms" ]]; then
      printf '  [%d/%d] %s  跳过(不通或>1000ms)\n' "$i" "$n" "$ep"
      continue
    fi
    if [[ "$ms" -lt 100 ]]; then
      ok "  [${i}/${n}] ${ep}  ${ms}ms <100 → 立刻开隧道"
      url="socks5h://${ep}"
      if _start_quick_tunnel_once "$url" "SOCKS5 ${ep} ${ms}ms"; then
        return 0
      fi
      warn "  该节点开隧道失败，继续..."
      continue
    fi
    # 100–1000
    printf '  [%d/%d] %s  %sms (候选)\n' "$i" "$n" "$ep" "$ms"
    mid+=("${ms}|${ep}")
  done
  if [[ ${#mid[@]} -eq 0 ]]; then
    warn "本批无合格候选（无 <1000ms 可用节点）"
    return 1
  fi
  # 按延迟升序再试
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ms="${line%%|*}"
    ep="${line#*|}"
    info "试用候选 ${ep} (${ms}ms) 开隧道..."
    url="socks5h://${ep}"
    if _start_quick_tunnel_once "$url" "SOCKS5 ${ep} ${ms}ms"; then
      return 0
    fi
  done < <(printf '%s\n' "${mid[@]}" | sort -t'|' -k1,1n)
  return 1
}

# 抓取+测活+开隧道循环（每批不重复上一批）
_retry_tunnel_via_fresh_socks5() {
  local usedf batch_file
  usedf="$(mktemp 2>/dev/null || echo /tmp/vps-socks-used.$$)"
  : >"$usedf"
  while true; do
    info "抓取 50 条新 SOCKS5（proxy.sh 同源列表，排除本会话已试过的）..."
    local -a batch=()
    mapfile -t batch < <(_fetch_socks5_batch 50 "$usedf")
    if [[ ${#batch[@]} -eq 0 ]]; then
      err "抓不到新节点（列表空或全被排除）"
      rm -f "$usedf"
      return 1
    fi
    # 记入已用
    printf '%s\n' "${batch[@]}" >>"$usedf"
    ok "本批拿到 ${#batch[@]} 条，开始测延迟/开隧道..."
    if _try_tunnel_with_socks_batch "${batch[@]}"; then
      rm -f "$usedf"
      return 0
    fi
    warn "本批 50 条均未能开出临时隧道"
    if ask_yn_default_yes "是否换一批 SOCKS5 再试（不会用上一批）?"; then
      continue
    fi
    rm -f "$usedf"
    return 1
  done
}

# $1=DIRECT 或 socks5h://host:port  $2=标签
_start_quick_tunnel_once() {
  local mode="${1:-DIRECT}"
  local label="${2:-}"
  local proxy_url=""

  case "$mode" in
    ""|DIRECT)
      label="${label:-直连}"
      proxy_url=""
      ;;
    *)
      proxy_url="$mode"
      label="${label:-经 ${proxy_url}}"
      ;;
  esac

  stop_quick_temp_ssh_tunnel
  mkdir -p /var/log /run
  : >"$QUICK_SSH_LOG"
  info "启动 CF 临时隧道 tcp://127.0.0.1:22 （${label}）..."

  if [[ -n "$proxy_url" ]]; then
    nohup env \
      ALL_PROXY="$proxy_url" HTTPS_PROXY="$proxy_url" HTTP_PROXY="$proxy_url" \
      all_proxy="$proxy_url" https_proxy="$proxy_url" http_proxy="$proxy_url" \
      NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1" \
      "$CF_BIN" tunnel --no-autoupdate --url "tcp://127.0.0.1:22" \
      >>"$QUICK_SSH_LOG" 2>&1 &
  else
    nohup env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY \
      -u all_proxy -u https_proxy -u http_proxy \
      -u SOCKS_PROXY -u socks_proxy -u SOCKS5_PROXY \
      "$CF_BIN" tunnel --no-autoupdate --url "tcp://127.0.0.1:22" \
      >>"$QUICK_SSH_LOG" 2>&1 &
  fi
  echo $! >"$QUICK_SSH_PID"
  ok "临时隧道 PID=$(cat "$QUICK_SSH_PID") 日志=$QUICK_SSH_LOG"

  local i host=""
  for i in $(seq 1 28); do
    host="$(parse_quick_tunnel_host)"
    if [[ -n "$host" ]]; then
      echo "$host" >"$QUICK_SSH_URL"
      ok "临时隧道已就绪: https://${host} （${label}）"
      QUICK_TUNNEL_ERR=""
      return 0
    fi
    if ! kill -0 "$(cat "$QUICK_SSH_PID" 2>/dev/null)" 2>/dev/null; then
      if is_quick_tunnel_rate_limited; then
        QUICK_TUNNEL_ERR="rate_limit"
        warn "trycloudflare 限流 (429/1015) — ${label}"
      else
        QUICK_TUNNEL_ERR="dead"
        warn "临时隧道进程已退出 — ${label}"
        tail -8 "$QUICK_SSH_LOG" 2>/dev/null || true
      fi
      return 1
    fi
    sleep 1
    printf '.'
  done
  echo
  QUICK_TUNNEL_ERR="timeout"
  warn "等待 trycloudflare 域名超时 — ${label}"
  return 1
}

start_quick_temp_ssh_tunnel() {
  QUICK_TUNNEL_ERR=""
  install_cloudflared_if_needed || { QUICK_TUNNEL_ERR="install"; return 1; }
  refresh_cf_bin
  [[ -n "$CF_BIN" ]] || { err "cloudflared 不可用"; QUICK_TUNNEL_ERR="install"; return 1; }

  if [[ -f "$QUICK_SSH_PID" ]] && kill -0 "$(cat "$QUICK_SSH_PID" 2>/dev/null)" 2>/dev/null; then
    local h
    h="$(parse_quick_tunnel_host)"
    [[ -z "$h" && -f "$QUICK_SSH_URL" ]] && h="$(cat "$QUICK_SSH_URL" 2>/dev/null || true)"
    if [[ -n "$h" ]]; then
      ok "临时隧道已在运行: $h"
      echo "$h" >"$QUICK_SSH_URL"
      QUICK_TUNNEL_ERR=""
      return 0
    fi
  fi

  # ① 直连
  info "① 优先直连 Cloudflare trycloudflare ..."
  if _start_quick_tunnel_once "DIRECT" "直连"; then
    return 0
  fi

  # ② 仅 SOCKS5 回退
  local cur_socks=""
  cur_socks="$(load_current_socks5 2>/dev/null || true)"
  if [[ -n "$cur_socks" ]]; then
    warn "直连失败。检测到当前 SOCKS5: ${cur_socks}"
    if ask_yn_default_yes "是否用该 SOCKS5 重试临时隧道?"; then
      info "② 经已有 SOCKS5 重试..."
      if _start_quick_tunnel_once "$cur_socks" "已有SOCKS5"; then
        return 0
      fi
      warn "已有 SOCKS5 未能开出隧道"
      if ask_yn_default_yes "是否抓取新 SOCKS5 节点再试?"; then
        if _retry_tunnel_via_fresh_socks5; then
          return 0
        fi
      fi
    elif ask_yn_default_yes "是否改抓新 SOCKS5 节点再试?"; then
      if _retry_tunnel_via_fresh_socks5; then
        return 0
      fi
    fi
  else
    info "未检测到已配置的 SOCKS5"
    if ask_yn_default_yes "是否开启 SOCKS5 抓取并重试临时隧道?"; then
      if _retry_tunnel_via_fresh_socks5; then
        return 0
      fi
    fi
  fi

  if is_quick_tunnel_rate_limited; then
    QUICK_TUNNEL_ERR="rate_limit"
  fi
  warn "临时隧道仍失败，日志: $QUICK_SSH_LOG"
  tail -15 "$QUICK_SSH_LOG" 2>/dev/null || true
  return 1
}

print_quick_ssh_client_commands() {
  local host="${1:-}"
  local user="${2:-$QUICK_SSH_USER}"
  local pass="${3:-$QUICK_SSH_PASS}"
  local lport="${QUICK_SSH_LOCAL_PORT}"
  echo
  echo "============================================================"
  echo " 本机（你的电脑）连接步骤"
  echo "============================================================"
  if [[ -z "$host" ]]; then
    warn "未拿到隧道域名，请打开服务器日志: $QUICK_SSH_LOG"
    echo "  找到类似 xxxx.trycloudflare.com 后替换下面 HOST"
    host="<xxxx.trycloudflare.com>"
  fi
  echo
  echo "【步骤 A】本机需已安装 cloudflared，另开终端执行："
  echo
  echo "  cloudflared access tcp --hostname ${host} --url 127.0.0.1:${lport}"
  echo
  echo "【步骤 B】再开一个终端登录："
  echo
  echo "  ssh ${user}@127.0.0.1 -p ${lport}"
  echo "  密码: ${pass}"
  echo
  echo "（可选）Windows PowerShell 一条测试："
  echo "  ssh -o StrictHostKeyChecking=no -p ${lport} ${user}@127.0.0.1"
  echo
  echo "关闭临时隧道：在服务器再跑 ssh-aotu.sh 选 97"
  echo "============================================================"
}

# 确认 sshd 进程在跑且 22 可连
ensure_sshd_process_alive() {
  if ! port_22_listening; then
    return 1
  fi
  if pgrep -x sshd &>/dev/null || pgrep -f '[s]shd:' &>/dev/null || pgrep -f '/sshd\b' &>/dev/null; then
    ok "sshd 进程运行中"
    return 0
  fi
  warn "22 在听但未见 sshd 进程，尝试再起 sshd..."
  /usr/sbin/sshd 2>/dev/null || sshd 2>/dev/null || true
  sleep 1
  if pgrep -x sshd &>/dev/null || pgrep -f '[s]shd' &>/dev/null; then
    ok "sshd 已重新拉起"
    return 0
  fi
  err "sshd 进程未运行"
  return 1
}

# 本机验证 user/pass 能否密码登录 127.0.0.1:22（隧道回源必须能过）
verify_local_password_login() {
  local user="$1" pass="$2"
  local rc=1
  info "本机验证: ssh ${user}@127.0.0.1 （密码登录）..."

  # 优先 sshpass
  if ! command -v sshpass &>/dev/null; then
    info "安装 sshpass 用于自动验密..."
    [[ -n "$ENV_PKG" ]] || PROBE_SKIP_NET=1 probe_environment
    case "${ENV_PKG}" in
      apt) pkg_install sshpass || true ;;
      dnf|yum) pkg_install sshpass || true ;;
      apk) pkg_install sshpass || true ;;
      *)
        command -v apt-get &>/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sshpass 2>/dev/null || true
        command -v apk &>/dev/null && apk add --no-cache sshpass 2>/dev/null || true
        ;;
    esac
  fi

  if command -v sshpass &>/dev/null; then
    set +e
    sshpass -p "$pass" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout=8 \
      "${user}@127.0.0.1" "echo SSH_LOGIN_OK && id -un && whoami" 2>/tmp/vps-ssh-verify.err
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      ok "验证成功: ${user} 密码登录 127.0.0.1:22 可用"
      return 0
    fi
    err "验证失败 (exit=$rc)"
    [[ -s /tmp/vps-ssh-verify.err ]] && sed 's/^/  /' /tmp/vps-ssh-verify.err | tail -8
    return 1
  fi

  # 无 sshpass：用 expect（若有）
  if command -v expect &>/dev/null; then
    set +e
    expect <<EOF >/tmp/vps-ssh-verify.out 2>/tmp/vps-ssh-verify.err
set timeout 10
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no ${user}@127.0.0.1 "echo SSH_LOGIN_OK"
expect {
  -re "(?i)password:" { send "${pass}\r"; exp_continue }
  "SSH_LOGIN_OK" { exit 0 }
  timeout { exit 1 }
  eof { exit 1 }
}
EOF
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] || grep -q SSH_LOGIN_OK /tmp/vps-ssh-verify.out 2>/dev/null; then
      ok "验证成功 (expect): ${user} 密码登录可用"
      return 0
    fi
    err "expect 验证失败"
    return 1
  fi

  err "无法自动验密：请安装 sshpass 后重试 (apt install sshpass)"
  echo "  手动自测: ssh ${user}@127.0.0.1"
  return 1
}

menu_quick_temp_ssh() {
  title "96. 一键临时 SSH（无端口权限 / 仅 CF 穿透）"
  echo "本脚本场景: 入站端口全不通，【不提供】ssh user@公网IP 直连方案"
  echo "默认: 用户=${QUICK_SSH_USER} 密码=${QUICK_SSH_PASS}"
  if is_root; then
    echo "流程: sshd → 密码登录 → 建/改用户 → 本机验密 → CF临时隧道"
  else
    echo "流程【无root用户态】: 检测:22 → 现有用户验密 → 用户目录 cloudflared → 临时隧道"
    echo "  （不改 sshd/不建用户；二进制与日志在 ~/.ssh-aotu/）"
  fi
  echo
  _init_quick_ssh_paths
  [[ -n "$ENV_INIT" ]] || PROBE_SKIP_NET=1 probe_environment
  SNAP_TS=0

  info "[1/5] 检查本机 sshd / :22 ..."
  if is_root; then
    if ! ensure_sshd_running; then
      err "本机 SSH 起不来，中止"; pause; return
    fi
    if ! ensure_sshd_process_alive; then
      err "sshd 进程异常，中止"; pause; return
    fi
  else
    if ! port_22_listening; then
      err "当前无 root，且 :22 未监听 — 无法自动启动 sshd"
      echo "  请用控制台/root 先启动 SSH，或: sudo bash $0 再选 96"
      pause
      return
    fi
    ok "检测到 :22 已在监听（用户态不强制改 sshd）"
  fi
  SNAP_TS=0
  if ! port_22_listening; then
    err "22 端口未监听，中止"; pause; return
  fi
  ok "sshd 侧就绪: :22 监听"

  info "[2/5] 检查密码登录..."
  if password_auth_allowed; then
    ok "已允许密码登录"
  else
    if is_root; then
      warn "不允许密码登录 → 自动修复"
      enable_password_auth || { err "无法开启密码登录"; pause; return; }
      SSHD_T_CACHE=""
      if password_auth_allowed; then
        ok "密码登录已开启"
      else
        err "密码登录仍未开启，中止"; pause; return
      fi
    else
      warn "sshd 可能禁止密码登录，且无 root 无法修改配置"
      warn "若下一步验密失败，请用 root 执行本脚本或手动改 PasswordAuthentication yes"
    fi
  fi

  info "[3/5] 用户 ${QUICK_SSH_USER} ..."
  if is_root; then
    ensure_user_password_force "$QUICK_SSH_USER" "$QUICK_SSH_PASS" "/bin/bash" || {
      err "用户处理失败"; pause; return
    }
  else
    if ! id "$QUICK_SSH_USER" &>/dev/null; then
      err "用户 ${QUICK_SSH_USER} 不存在，无 root 无法创建"
      echo "  请: sudo bash $0 选 96，或 root 先: useradd -m ${QUICK_SSH_USER}"
      pause
      return
    fi
    ok "用户已存在: ${QUICK_SSH_USER}（无 root 不改密码；请确认密码为 ${QUICK_SSH_PASS}）"
  fi

  info "[4/5] 验证 ${QUICK_SSH_USER} 本机密码登录..."
  if ! verify_local_password_login "$QUICK_SSH_USER" "$QUICK_SSH_PASS"; then
    err "===== 本机密码登录验证失败，不启动隧道 ====="
    echo "  请检查: PasswordAuthentication / 用户 shell / 密码是否正确"
    echo "  手动: ssh ${QUICK_SSH_USER}@127.0.0.1"
    if ! is_root; then
      echo "  无 root 时无法自动建用户/改密，请提权后重试 96"
    fi
    pause
    return
  fi

  info "[5/5] 启动 CF 临时隧道（唯一外网入口）..."
  local host="" tunnel_ok=0
  if start_quick_temp_ssh_tunnel; then
    tunnel_ok=1
    host="$(cat "$QUICK_SSH_URL" 2>/dev/null || true)"
    [[ -z "$host" ]] && host="$(parse_quick_tunnel_host)"
  fi

  if [[ "$tunnel_ok" -ne 1 || -z "$host" ]]; then
    err "===== 临时隧道失败：无法穿透 ====="
    echo
    if is_quick_tunnel_rate_limited || [[ "${QUICK_TUNNEL_ERR:-}" == "rate_limit" ]]; then
      warn "原因: Cloudflare trycloudflare 限流 (429/1015)"
      echo "  【推荐】菜单 5：Zero Trust 固定 Token（须root）"
      echo "  【可选】proxy.sh 设 SOCKS5 后重试 96（直连失败会问是否走 SOCKS）"
    else
      echo "  常见原因: cloudflared 异常 / 出网拦截 / trycloudflare 不可用"
      echo "  ① 确认 cloudflared 可用后重试 96"
      echo "  ② 菜单 5：固定 Token 隧道（须root，长期推荐）"
    fi
    echo
    echo "  本机已验证: 用户 ${QUICK_SSH_USER} 可登录 127.0.0.1"
    pause
    return
  fi

  ok "===== 本机验密 OK + 隧道就绪 ====="
  print_quick_ssh_client_commands "$host" "$QUICK_SSH_USER" "$QUICK_SSH_PASS"
  pause
}

menu_stop_quick_temp_ssh() {
  title "97. 关闭临时 SSH 隧道"
  stop_quick_temp_ssh_tunnel
  ok "临时隧道已关闭（固定 Token 隧道未动）"
  if pgrep -f "cloudflared.*tunnel run --token" &>/dev/null; then
    info "检测到固定隧道仍在运行"
  fi
  pause
}

menu_change_user_password() {
  title "98. 修改用户密码"
  local user p1 p2
  read -r -p "用户名 [${QUICK_SSH_USER}]: " user
  user="${user:-$QUICK_SSH_USER}"
  validate_username "$user" || { pause; return; }
  if ! id "$user" &>/dev/null; then
    err "用户不存在: $user"
    pause
    return
  fi
  while true; do
    read -r -s -p "新密码: " p1; echo
    read -r -s -p "再输一次: " p2; echo
    [[ -z "$p1" ]] && { err "密码不能为空"; continue; }
    [[ "$p1" != "$p2" ]] && { err "两次不一致"; continue; }
    break
  done
  echo "${user}:${p1}" | chpasswd
  ok "已更新密码: $user"
  if [[ "$user" == "$LAST_USER" || "$user" == "$QUICK_SSH_USER" ]]; then
    LAST_USER="$user"
    LAST_PASS="$p1"
  fi
  pause
}

print_compact_summary() {
  [[ "${ENV_PROBED:-0}" -eq 1 ]] || PROBE_SKIP_NET=0 probe_environment
  refresh_cf_bin 2>/dev/null || true
  snapshot_runtime
  local be cf_s ssh_s net_s
  be="$(prefer_service_backend)"
  if [[ "${SNAP_CF_RUN:-0}" -eq 1 ]]; then cf_s="cf●"; else cf_s="cf×"; fi
  if [[ "${SNAP_PORT22:-0}" -eq 1 ]]; then ssh_s=":22●"; else ssh_s=":22×"; fi
  case "${ENV_NET:-}" in
    ok) net_s="出网●" ;;
    limited) net_s="出网○" ;;
    offline|"") net_s="出网×" ;;
    *) net_s="出网?" ;;
  esac
  echo "  环境: ${ENV_INIT}|${ENV_CT}|${ENV_ARCH}|${ENV_PKG} 后端=${be}  ${cf_s}  ${ssh_s}  ${net_s}"
  if [[ -n "${ENV_PUBLIC_IP:-}" ]]; then
    echo "  公网IP: ${ENV_PUBLIC_IP} （无入站端口时勿直连，仅作标识）"
  else
    echo "  公网IP: 未获取"
  fi
  if [[ -n "${CF_BIN:-}" ]]; then
    echo "  cfbin: ${CF_BIN}"
  else
    echo "  cfbin: 未安装"
  fi
}

show_menu() {
  # 不用 clear：部分 web 终端/容器里清屏后看起来像“没输出”
  echo ""
  # 探测只做一次（r 可强制刷新）
  if [[ "${ENV_PROBED:-0}" -ne 1 ]]; then
    PROBE_SKIP_NET=0 probe_environment
  fi
  refresh_cf_bin 2>/dev/null || true
  snapshot_runtime 2>/dev/null || true
  if ! is_root && ! command -v sudo &>/dev/null; then
    warn "【受限模式】当前无 root/sudo — 诊断可用，写系统/装包/注册服务请提权"
  fi

  # 默认完整状态面板（环境指纹 + 服务监测）
  # 只要紧凑一行: VPS_COMPACT=1 bash ssh-aotu.sh
  if [[ "${VPS_COMPACT:-0}" == "1" ]]; then
    echo "── ssh-aotu.sh ──────────────────────────────"
    print_compact_summary
  else
    print_panel_header
    print_env_fingerprint
    print_panel_service_monitor
  fi
  echo ""
  echo "  1) 查看 Init(ps -p 1) + 注册自启服务                    [须root]"
  echo "  2) 新建用户名和密码                                     [须root]"
  echo "  3) 检查 SSH + 密码登录                                  [无需root*]"
  echo "  4) 本机验证 SSH                                         [无需root]"
  echo "  5) CF 固定隧道（Token）                                 [须root]"
  echo "  6) 查看 CF 状态                                         [无需root*]"
  echo "  7) 查看 CF 日志                                         [无需root*]"
  echo "  8) 卸载 CF 隧道                                         [须root]"
  echo "  9) 环境详情（完整面板）                                 [无需root]"
  echo " ------------------------------------------------"
  echo "  96) 一键临时 SSH（穿透）                                 [无需root*]"
  echo "  97) 关闭临时 SSH 隧道                                   [无需root*]"
  echo "  98) 修改用户密码                                        [须root]"
  echo "  r) 刷新环境探测                                         [无需root]"
  echo "  0) 退出"
  echo "  标注: [须root]=无权限会提示；[无需root*]=用户态优先(sshd/用户需已就绪)"
  echo ""
  printf "请选择: "
  read -r choice || true
  echo
  case "${choice:-}" in
    1) menu_try_systemd_services ;;
    2) if need_root_or_skip "新建用户"; then menu_create_user; else pause; fi ;;
    3) menu_ssh_password_policy ;;
    4) menu_local_ssh_test ;;
    5) if need_root_or_skip "配置 CF 固定隧道"; then menu_create_cf_tunnel; else pause; fi ;;
    6) menu_cf_status ;;
    7) menu_cf_logs ;;
    8) if need_root_or_skip "卸载 CF 隧道"; then menu_uninstall_cf; else pause; fi ;;
    9)
      print_panel_header
      print_env_fingerprint
      print_panel_service_monitor
      pause
      ;;
    r|R)
      FORCE_PROBE=1 PROBE_SKIP_NET=0 probe_environment
      FORCE_PROBE=0
      snapshot_runtime
      ok "已刷新环境 Init=$ENV_INIT 后端=$ENV_BACKEND"
      sleep 1
      ;;
    96) menu_quick_temp_ssh ;;
    97) menu_stop_quick_temp_ssh ;;
    98) if need_root_or_skip "修改用户密码"; then menu_change_user_password; else pause; fi ;;
    0) echo "再见"; exit 0 ;;
    *) warn "无效选项: ${choice:-空}"; sleep 1 ;;
  esac
}


main() {
  # 保留原始参数（数组），sudo 重跑时原样透传；禁止 printf %q 空参生成 ''
  local -a ORIG_ARGS=("$@")
  parse_cli_args "$@"
  if [[ "$CLI_MODE" -eq 1 ]]; then
    # CLI 改用户/sshd 必须 root
    REQUIRE_ROOT_STRICT=1 require_root "${ORIG_ARGS[@]}"
    cli_run
    exit 0
  fi
  # 交互菜单：无 root 也进受限模式，不整脚本退出
  REQUIRE_ROOT_STRICT=0 require_root "${ORIG_ARGS[@]}"
  refresh_cf_bin 2>/dev/null || true
  PROBE_SKIP_NET=0 probe_environment 2>/dev/null || PROBE_SKIP_NET=1 probe_environment 2>/dev/null || true
  snapshot_runtime 2>/dev/null || true
  while true; do show_menu; done
}

main "$@"

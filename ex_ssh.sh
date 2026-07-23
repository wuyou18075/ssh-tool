#!/bin/bash
# 自动兼容 Windows 换行(CRLF)：从 Windows 拷到 Linux 也不会出现 $'\r' 报错，无需手动 sed/dos2unix
# 注意：必须是单行；通过临时文件 re-exec，避免 bash -s 占用 stdin 导致菜单 read 失效
[ -n "${__SCRIPT_LF_OK:-}" ] || { export __SCRIPT_LF_OK=1; _t=$(mktemp 2>/dev/null || echo "/tmp/.1sh_lf_$$.sh"); tr -d '\015' <"$0" >"$_t"; chmod +x "$_t" 2>/dev/null; exec bash "$_t" "$@"; }

# 定义颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# CF 隧道相关路径
CF_BIN="/usr/local/bin/cloudflared"
CF_DIR="/etc/cloudflared"
CF_TOKEN_FILE="${CF_DIR}/tunnel-token.json"
CF_TOKEN_RAW="${CF_DIR}/tunnel.token"          # Zero Trust 一串 token
CF_CONFIG="${CF_DIR}/config.yaml"
CF_SVC_DIR="/opt/svc/cloudflared"
CF_LOG_DIR="/var/log/sys-svc"
CF_LOG="${CF_LOG_DIR}/cloudflared.log"
CF_PID="${CF_SVC_DIR}/.pid"
CF_SUPERVISOR="${CF_SVC_DIR}/supervisor.sh"

# ==========================================
# 通用：提权执行（root 直接跑，非 root 才 sudo）
# 兼容：真 VPS / 容器 / 有无 sudo 包
# ==========================================
is_root() { [ "$(id -u)" -eq 0 ]; }

need_root() {
    if is_root; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        # 不自动 sudo 每一条命令；as_root 会处理
        return 0
    fi
    echo -e "${YELLOW}[!] ${1:-此操作} 需要 root/sudo（当前受限模式）${NC}"
    return 1
}

# 带提权的命令：root 不套 sudo；非 root 用 sudo；无 sudo 则失败
as_root() {
    if is_root; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "${RED}[x] 无 root/sudo，无法执行: $*${NC}" >&2
        return 127
    fi
}

# 脚本入口：有 sudo 可提权；无 root/sudo 进入受限菜单（诊断仍可用）
ensure_priv_or_reexec() {
    if is_root; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo -e "${YELLOW}[!] root 环境未装 sudo，尝试安装...${NC}"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq 2>/dev/null; apt-get install -y -qq sudo 2>/dev/null || true
            elif command -v yum >/dev/null 2>&1; then yum install -y sudo 2>/dev/null || true
            elif command -v dnf >/dev/null 2>&1; then dnf install -y sudo 2>/dev/null || true
            elif command -v apk >/dev/null 2>&1; then apk add --no-cache sudo 2>/dev/null || true
            fi
        fi
        return 0
    fi
    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            echo -e "${YELLOW}[!] 非 root，使用 sudo 重跑本脚本...${NC}"
            exec sudo -E bash "$0" "$@"
        fi
        # 有 sudo 但要密码：不强制 reexec，进入受限菜单
        echo -e "${YELLOW}[!] 检测到 sudo 但需密码；进入【受限模式】（诊断可用，写系统需 sudo）${NC}"
        echo -e "  完整权限: ${CYAN}sudo bash $0${NC}"
        return 0
    fi
    echo -e "${YELLOW}[!] 普通用户且无 sudo → 【受限模式】仍可进菜单${NC}"
    echo -e "  ${GREEN}无需 root:${NC} 2/3 端口诊断、5 sshx、6 ttyd+临时CF、8 FRP、9 tmate"
    echo -e "  ${RED}需要 root:${NC} 4 固定CF隧道、系统装包（7 Tailscale 可用户态）"
    echo -e "  完整功能: 控制台 root 执行 ${CYAN}bash $0${NC} 或 ${CYAN}sudo bash $0${NC}"
    return 0
}

# 菜单项需要写系统时软拦截
need_root_action() {
    local what="${1:-此操作}"
    if is_root; then return 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        return 0
    fi
    echo -e "${RED}[x] ${what} 需要 root/sudo，当前受限模式已跳过${NC}"
    echo -e "  请: sudo bash $0  或  控制台 root 再执行"
    return 1
}

# 排序数字端口列表（空格分隔 -> 排序后空格分隔）
sort_ports() {
    echo "$1" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# ==========================================
# 功能 1：权限检测与尝试安装 sudo
# ==========================================
check_and_install_sudo() {
    echo -e "\n${CYAN}>>> 权限检测与环境修复 <<<${NC}"
    if [ "$EUID" -eq 0 ]; then
        echo -e "${GREEN}[√] 当前已经是 Root 权限（无需 sudo 提权）。${NC}"
        if command -v sudo >/dev/null 2>&1; then
            echo -e "${GREEN}[√] sudo 已安装: $(command -v sudo)${NC}"
        else
            echo -e "${YELLOW}[!] 未安装 sudo，正在尝试自动安装...${NC}"
            if command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y sudo curl
            elif command -v dnf >/dev/null 2>&1; then dnf install -y sudo curl
            elif command -v yum >/dev/null 2>&1; then yum install -y sudo curl
            elif command -v apk >/dev/null 2>&1; then apk add --no-cache sudo curl
            else echo -e "${RED}[x] 无法识别包管理器。${NC}"; fi
            command -v sudo >/dev/null 2>&1 && echo -e "${GREEN}[√] sudo 安装成功。${NC}" \
              || echo -e "${RED}[x] sudo 安装失败。${NC}"
        fi
        # 可选：给指定用户免密 sudo（回车默认当前非 root 会话用户或 cj）
        if command -v sudo >/dev/null 2>&1 && [ -d /etc/sudoers.d ]; then
            local u_default=""
            # 若通过 sudo 进来，SUDO_USER 为原用户
            u_default="${SUDO_USER:-}"
            [ -z "$u_default" ] || [ "$u_default" = "root" ] && u_default="cj"
            echo -e "${YELLOW}可为普通用户配置 sudo 免密（沙箱常用）。${NC}"
            read -p "授权用户名 [回车=${u_default}，输入 n 跳过]: " u_grant
            if [ "$u_grant" = "n" ] || [ "$u_grant" = "N" ]; then
                echo -e "${YELLOW}[i] 跳过免密配置${NC}"
            else
                u_grant="${u_grant:-$u_default}"
                if id "$u_grant" >/dev/null 2>&1; then
                    getent group sudo >/dev/null 2>&1 && usermod -aG sudo "$u_grant" 2>/dev/null || true
                    getent group wheel >/dev/null 2>&1 && usermod -aG wheel "$u_grant" 2>/dev/null || true
                    echo "${u_grant} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/${u_grant}"
                    chmod 440 "/etc/sudoers.d/${u_grant}"
                    echo -e "${GREEN}[√] 已加入 sudo/wheel 并写入 /etc/sudoers.d/${u_grant}${NC}"
                    echo -e "  该用户执行: ${CYAN}sudo -i${NC} 或 ${CYAN}sudo bash 脚本.sh${NC}"
                else
                    echo -e "${RED}[x] 用户不存在: $u_grant${NC}"
                fi
            fi
        fi
    else
        echo -e "${RED}[x] 当前为普通用户 (uid=$EUID)。${NC}"
        if command -v sudo >/dev/null 2>&1; then
            echo -e "${GREEN}[√] 已安装 sudo，请用: sudo bash $0${NC}"
            if sudo -n true 2>/dev/null; then
                echo -e "${GREEN}[√] 当前免密 sudo 可用${NC}"
            else
                echo -e "${YELLOW}[!] sudo 需要密码；若无密码请用网页控制台 root 配置 NOPASSWD${NC}"
            fi
        else
            echo -e "${RED}[x] 未安装 sudo。请在网页控制台用 root 执行:${NC}"
            echo -e "  ${CYAN}apt-get update && apt-get install -y sudo${NC}"
            echo -e "  ${CYAN}echo '$(id -un) ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$(id -un)${NC}"
            echo -e "  ${CYAN}chmod 440 /etc/sudoers.d/$(id -un)${NC}"
            if id -nG 2>/dev/null | grep -qw sudo; then
                echo -e "${YELLOW}[i] 你已在 sudo 组，但系统缺少 sudo 软件包，装上即可。${NC}"
            fi
        fi
    fi
}

# ==========================================
# 功能 2：内部端口检查
# ==========================================
check_internal_ports() {
    echo -e "\n${CYAN}>>> 内部端口检查 (监听中的服务) <<<${NC}"
    if [ "$EUID" -ne 0 ]; then echo -e "${YELLOW}提示：非 Root 身份，输出结果中最右侧的进程名称将被隐藏。${NC}"; fi
    echo "----------------------------------------------------"
    if command -v ss >/dev/null 2>&1; then ss -tulnp | grep LISTEN
    elif command -v netstat >/dev/null 2>&1; then netstat -tulnp | grep LISTEN
    else echo -e "${RED}未找到 ss 或 netstat 命令。${NC}"; fi
}

# ==========================================
# 功能 3：本机端口诊断（ss 为准 + nmap 辅助，防 NAT 误报）
# ==========================================

get_public_ip() {
    local ip=""
    for url in \
        "https://ifconfig.me" \
        "https://api.ipify.org" \
        "https://icanhazip.com" \
        "https://ipinfo.io/ip"; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

ensure_nmap() {
    if command -v nmap >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}[!] 本机未安装 nmap，正在尝试安装...${NC}"
    if [ "$EUID" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo -e "${RED}[x] 无 root/sudo，无法自动安装 nmap。${NC}"
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update -y && as_root apt-get install -y nmap
    elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y nmap
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y nmap
    elif command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache nmap
    else
        echo -e "${RED}[x] 无法识别包管理器，请手动安装 nmap。${NC}"
        return 1
    fi
    command -v nmap >/dev/null 2>&1
}

# 解析本机 LISTEN → 全局变量
collect_local_listen() {
    LOCAL_LISTEN_ALL=""
    LOCAL_LISTEN_EXT=""
    LOCAL_LISTEN_LO=""
    LOCAL_LISTEN_RAW=""

    local raw=""
    if command -v ss >/dev/null 2>&1; then
        raw=$(ss -tuln 2>/dev/null | grep LISTEN || true)
    elif command -v netstat >/dev/null 2>&1; then
        raw=$(netstat -tuln 2>/dev/null | grep LISTEN || true)
    else
        return 1
    fi
    LOCAL_LISTEN_RAW="$raw"

    local line addr port ip
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        addr=$(echo "$line" | awk '{
            for (i=1;i<=NF;i++) {
                if ($i ~ /:[0-9]+$/) { print $i; exit }
            }
        }')
        [ -z "$addr" ] && continue
        port="${addr##*:}"
        port="${port%%[^0-9]*}"
        [[ "$port" =~ ^[0-9]+$ ]] || continue

        case " $LOCAL_LISTEN_ALL " in
            *" $port "*) ;;
            *) LOCAL_LISTEN_ALL="$LOCAL_LISTEN_ALL $port" ;;
        esac

        ip="${addr%:$port}"
        ip="${ip#[}"
        ip="${ip%]}"
        # 127.0.0.0/8（含 Docker 127.0.0.11）与 ::1 视为仅本机
        if [ "$ip" = "::1" ] || [[ "$ip" == 127.* ]]; then
            case " $LOCAL_LISTEN_LO " in
                *" $port "*) ;;
                *) LOCAL_LISTEN_LO="$LOCAL_LISTEN_LO $port" ;;
            esac
        else
            case " $LOCAL_LISTEN_EXT " in
                *" $port "*) ;;
                *) LOCAL_LISTEN_EXT="$LOCAL_LISTEN_EXT $port" ;;
            esac
        fi
    done <<< "$raw"

    LOCAL_LISTEN_ALL=$(sort_ports "$LOCAL_LISTEN_ALL")
    LOCAL_LISTEN_EXT=$(sort_ports "$LOCAL_LISTEN_EXT")
    LOCAL_LISTEN_LO=$(sort_ports "$LOCAL_LISTEN_LO")
    return 0
}

show_local_listen() {
    echo -e "\n${CYAN}>>> 本机真实监听 (ss/netstat，权威) <<<${NC}"
    if ! collect_local_listen; then
        echo -e "${RED}[x] 未找到 ss 或 netstat，无法获取本机监听。${NC}"
        return 1
    fi
    if [ -z "$LOCAL_LISTEN_ALL" ]; then
        echo -e "${YELLOW}[!] 未发现 LISTEN 端口。${NC}"
        return 0
    fi

    if [ -n "$LOCAL_LISTEN_EXT" ]; then
        echo -e "${GREEN}对外可能可达 (绑定 0.0.0.0/*/[::] 等):${NC}"
        for p in $LOCAL_LISTEN_EXT; do
            echo -e "  ${GREEN}$p/tcp${NC}"
        done
    else
        echo -e "${YELLOW}对外可能可达: (无)${NC}"
    fi

    if [ -n "$LOCAL_LISTEN_LO" ]; then
        echo -e "${YELLOW}仅本机 (127.x / ::1):${NC}"
        for p in $LOCAL_LISTEN_LO; do
            case " $LOCAL_LISTEN_EXT " in
                *" $p "*) continue ;;
            esac
            echo -e "  ${YELLOW}$p/tcp${NC}"
        done
    fi

    echo -e "${CYAN}原始 LISTEN 行:${NC}"
    echo "$LOCAL_LISTEN_RAW"
}

parse_nmap_open_ports() {
    local grepable="$1"
    local ports=""
    local field item port state
    field=$(echo "$grepable" | tr '\n' ' ' | sed -n 's/.*Ports: //p' | sed 's/Ignored.*//')
    IFS=',' read -ra items <<< "$field"
    for item in "${items[@]}"; do
        item=$(echo "$item" | tr -d ' ')
        [ -z "$item" ] && continue
        port="${item%%/*}"
        state=$(echo "$item" | cut -d'/' -f2)
        if [ "$state" = "open" ] && [[ "$port" =~ ^[0-9]+$ ]]; then
            case " $ports " in
                *" $port "*) ;;
                *) ports="$ports $port" ;;
            esac
        fi
    done
    sort_ports "$ports"
}

port_in_list() {
    case " $2 " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

count_ports() {
    local n=0 p
    for p in $1; do n=$((n + 1)); done
    echo "$n"
}

cross_check_nmap() {
    local nmap_open="$1"
    local scanning_self="$2"
    local trusted="" suspect="" not_in_scan=""
    local p
    local open_count listen_count
    open_count=$(count_ports "$nmap_open")
    listen_count=$(count_ports "$LOCAL_LISTEN_ALL")

    echo -e "\n${CYAN}>>> 交叉核对 (nmap open ∩ 本机 LISTEN) <<<${NC}"
    echo -e "nmap 报 open: ${open_count} 个 | 本机 LISTEN: ${listen_count} 个"

    local untrusted=0
    if [ "$scanning_self" -eq 1 ] && [ "$open_count" -ge 30 ] && [ "$open_count" -gt $((listen_count * 3 + 5)) ]; then
        untrusted=1
        echo -e "${RED}[!] 判定：本次 nmap 结果不可信（疑似 NAT/回环 hairpin 假开放）。${NC}"
        echo -e "${YELLOW}    本机诊断请以上方 ss 监听为准；下方仅展示与 ss 交叉后的可信端口。${NC}"
    fi

    for p in $nmap_open; do
        if port_in_list "$p" "$LOCAL_LISTEN_ALL"; then
            trusted="$trusted $p"
        else
            suspect="$suspect $p"
        fi
    done
    trusted=$(sort_ports "$trusted")
    suspect=$(sort_ports "$suspect")

    for p in $LOCAL_LISTEN_ALL; do
        if ! port_in_list "$p" "$nmap_open"; then
            not_in_scan="$not_in_scan $p"
        fi
    done
    not_in_scan=$(sort_ports "$not_in_scan")

    echo -e "\n${GREEN}[√] 可信开放 (nmap 与 ss 均确认):${NC}"
    if [ -n "$trusted" ]; then
        for p in $trusted; do
            if port_in_list "$p" "$LOCAL_LISTEN_EXT"; then
                echo -e "  ${GREEN}$p/tcp${NC}  (对外绑定)"
            else
                echo -e "  ${GREEN}$p/tcp${NC}  (仅本机绑定)"
            fi
        done
    else
        echo -e "  ${YELLOW}(无)${NC}"
    fi

    if [ "$scanning_self" -eq 1 ]; then
        if [ -n "$suspect" ]; then
            local sc
            sc=$(count_ports "$suspect")
            echo -e "\n${RED}[!] 疑似误报 (nmap 报 open，但 ss 无 LISTEN): ${sc} 个${NC}"
            if [ "$untrusted" -eq 1 ]; then
                echo -e "${YELLOW}    数量过多，已折叠明细。常见原因：从容器/NAT 内扫本机公网 IP 会假通。${NC}"
            else
                local shown=0
                for p in $suspect; do
                    echo -e "  ${RED}$p/tcp${NC}"
                    shown=$((shown + 1))
                    [ "$shown" -ge 20 ] && { echo -e "  ${YELLOW}... 其余省略${NC}"; break; }
                done
            fi
        fi

        if [ -n "$not_in_scan" ]; then
            echo -e "\n${YELLOW}[i] 本机有监听，但本次 nmap 未覆盖/未报 open:${NC}"
            for p in $not_in_scan; do
                echo -e "  ${YELLOW}$p/tcp${NC}"
            done
            echo -e "${YELLOW}    可用「指定端口」再扫这些端口。${NC}"
        fi
    else
        echo -e "\n${YELLOW}[i] 目标非本机；外网真实情况请在你自己电脑扫描。${NC}"
        if [ -n "$suspect" ]; then
            local sc
            sc=$(count_ports "$suspect")
            echo -e "${CYAN}nmap 在目标上报 open: ${sc} 个${NC}"
            if [ "$sc" -le 30 ]; then
                for p in $suspect; do echo -e "  $p/tcp"; done
            else
                echo -e "${YELLOW}    数量较多，见上方 nmap 输出。${NC}"
            fi
        fi
    fi

    # 返回 untrusted 标记供调用方决定是否隐藏原文
    return "$untrusted"
}

check_external_ports() {
    echo -e "\n${CYAN}>>> 本机端口诊断 (ss 为准 + nmap 辅助) <<<${NC}"
    echo -e "${YELLOW}说明：本机诊断以 ss 真实监听为准。${NC}"
    echo -e "${YELLOW}      从本机扫自己的公网 IP 可能出现 NAT 假 open，脚本会自动交叉核对。${NC}"
    echo -e "${YELLOW}      云厂商安全组是否放行，请在你自己电脑上扫公网 IP。${NC}"

    show_local_listen

    PUBLIC_IP=$(get_public_ip || true)
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "\n检测到公网 IP: ${GREEN}$PUBLIC_IP${NC} (仅供参考，外网复核请在自己电脑扫描)"
    else
        echo -e "\n${YELLOW}[!] 无法自动获取公网 IP（外网受限时正常）。${NC}"
    fi

    DEFAULT_IP="127.0.0.1"
    read -p "扫描目标 IP [回车= $DEFAULT_IP]: " TARGET_IP
    TARGET_IP=${TARGET_IP:-$DEFAULT_IP}

    local scanning_self=0
    case "$TARGET_IP" in
        127.0.0.1|localhost|::1) scanning_self=1 ;;
    esac
    if [ -n "$PUBLIC_IP" ] && [ "$TARGET_IP" = "$PUBLIC_IP" ]; then
        scanning_self=1
        echo -e "${YELLOW}[!] 目标是本机公网 IP：从容器/NAT 内扫描极易误报，将启用交叉核对。${NC}"
    fi
    if [ "$scanning_self" -eq 1 ] && [ "$TARGET_IP" = "127.0.0.1" ]; then
        echo -e "${GREEN}[i] 默认扫 127.0.0.1，结果与 ss 最接近。${NC}"
    fi

    echo -e "扫描范围:"
    echo -e "  ${GREEN}1.${NC} 常见端口快速扫描 (-F)  [默认]"
    echo -e "  ${GREEN}2.${NC} 指定端口 (例如 22,80,443,8080)"
    echo -e "  ${GREEN}3.${NC} 全端口 1-65535 (较慢)"
    read -p "请选择 [1-3，回车=1]: " scan_mode
    scan_mode=${scan_mode:-1}

    local nmap_args=(-Pn --open)
    case $scan_mode in
        2)
            read -p "请输入端口列表: " port_list
            if [ -z "$port_list" ]; then
                echo -e "${RED}端口不能为空。${NC}"
                return 1
            fi
            nmap_args+=(-p "$port_list")
            ;;
        3)
            nmap_args+=(-p-)
            echo -e "${YELLOW}全端口扫描可能需要数分钟，请耐心等待...${NC}"
            ;;
        *)
            nmap_args+=(-F)
            ;;
    esac

    if ! ensure_nmap; then
        echo -e "${RED}本机 nmap 不可用。已展示上方 ss 监听，可据此判断。${NC}"
        echo -e "安装: apt install nmap / yum install nmap"
        if [ -n "$PUBLIC_IP" ]; then
            echo -e "外网复核（在自己电脑执行）: ${CYAN}nmap -Pn $PUBLIC_IP${NC}"
        fi
        return 1
    fi

    echo -e "\n正在 nmap 扫描 ${GREEN}$TARGET_IP${NC} ... (${YELLOW}约需 10-60 秒${NC})"
    echo "----------------------------------------------------"

    local gnmap_file nmap_out_file
    gnmap_file=$(mktemp 2>/dev/null || echo "/tmp/.1sh_nmap_$$.gnmap")
    nmap_out_file=$(mktemp 2>/dev/null || echo "/tmp/.1sh_nmap_$$.out")

    # 人类可读 + greppable 同时产出
    nmap "${nmap_args[@]}" -oN "$nmap_out_file" -oG "$gnmap_file" "$TARGET_IP" >/dev/null 2>&1
    local rc=$?

    local nmap_open=""
    if [ -f "$gnmap_file" ]; then
        nmap_open=$(parse_nmap_open_ports "$(cat "$gnmap_file")")
    fi
    local open_count
    open_count=$(count_ports "$nmap_open")

    # 预判是否不可信：扫自己 + open 过多 → 折叠原始明细
    local will_untrust=0
    local listen_count
    listen_count=$(count_ports "$LOCAL_LISTEN_ALL")
    if [ "$scanning_self" -eq 1 ] && [ "$open_count" -ge 30 ] && [ "$open_count" -gt $((listen_count * 3 + 5)) ]; then
        will_untrust=1
    fi

    if [ "$will_untrust" -eq 1 ]; then
        echo -e "${RED}nmap 原始结果不可信：报 open ${open_count} 个（明细已折叠，避免刷屏）${NC}"
        echo -e "${YELLOW}Host is up. 详见下方交叉核对。${NC}"
    else
        if [ -f "$nmap_out_file" ]; then
            # 去掉 # Nmap 注释头的噪音，保留报告主体
            grep -v '^#' "$nmap_out_file" | sed '/^$/N;/^\n$/d'
        fi
    fi
    echo "----------------------------------------------------"

    rm -f "$gnmap_file" "$nmap_out_file"

    cross_check_nmap "$nmap_open" "$scanning_self" || true

    echo "----------------------------------------------------"
    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}[√] 诊断完成。本机以 ss 为准；外网放行请在自己电脑验证。${NC}"
    else
        echo -e "${RED}[x] nmap 退出码: $rc（ss 监听结果仍有效）${NC}"
    fi
    if [ -n "$PUBLIC_IP" ]; then
        echo -e "外网复核（在自己电脑执行）: ${CYAN}nmap -Pn $PUBLIC_IP${NC}"
    else
        echo -e "外网复核（在自己电脑执行）: ${CYAN}nmap -Pn <公网IP>${NC}"
    fi
    return $rc
}

# ==========================================
# 功能 4：CF 隧道管理（合并自 cf-suidao.sh）
# ==========================================

detect_init() {
    case "$(cat /proc/1/comm 2>/dev/null)" in
        systemd) echo "systemd" ;;
        s6-svscan) echo "s6" ;;
        *) echo "manual" ;;
    esac
}

detect_container() {
    [ -f "/.dockerenv" ] && echo "docker" && return
    grep -qE 'docker|lxc|containerd' /proc/1/cgroup 2>/dev/null && echo "docker" && return
    echo "native"
}

systemd_ok() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] && systemctl is-system-running &>/dev/null
}

svc_type() {
    systemd_ok && echo "systemd" && return
    [ "$(detect_init)" = "s6" ] && echo "s6" && return
    echo "manual"
}

s6_dir() {
    for d in /etc/s6/services /etc/services.d /run/s6/services; do
        [ -d "$d" ] && echo "$d" && return
    done
    echo "/etc/s6/services"
}

cf_arch() {
    uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'
}

# 是否有可用 token（JSON 凭据 或 纯 token 字符串）
cf_has_token() {
    if [ -f "$CF_TOKEN_RAW" ] && [ -s "$CF_TOKEN_RAW" ]; then
        return 0
    fi
    if [ -f "$CF_TOKEN_FILE" ] && [ -s "$CF_TOKEN_FILE" ]; then
        return 0
    fi
    return 1
}

cf_is_installed() {
    [ -x "$CF_BIN" ] && "$CF_BIN" version &>/dev/null
}

cf_is_running() {
    local st
    st=$(svc_type)
    case "$st" in
        systemd)
            systemctl is-active --quiet cloudflared 2>/dev/null
            ;;
        s6)
            local sd
            sd=$(s6_dir)
            s6-svstat "$sd/cloudflared" 2>/dev/null | grep -q '^up' \
                || s6-svc -s "$sd/cloudflared" 2>/dev/null
            ;;
        manual)
            local pid=""
            [ -f "$CF_PID" ] && pid=$(cat "$CF_PID" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
            # 兜底：进程名
            pgrep -f 'cloudflared.*(tunnel|supervisor)' >/dev/null 2>&1
            ;;
    esac
}

write_cf_supervisor() {
    as_root mkdir -p "$CF_SVC_DIR" "$CF_LOG_DIR"
    # 用 as_root tee 写文件
    as_root tee "$CF_SUPERVISOR" >/dev/null << 'CFEOF'
#!/bin/bash
# cloudflared supervisor - 崩溃自启 + 退避重试
NAME="cloudflared"
BIN="/usr/local/bin/cloudflared"
DIR="/etc/cloudflared"
LOG="/var/log/sys-svc/cloudflared.log"
PIDF="/opt/svc/cloudflared/.pid"
TOKEN_RAW="/etc/cloudflared/tunnel.token"
TOKEN_JSON="/etc/cloudflared/tunnel-token.json"
CONFIG="/etc/cloudflared/config.yaml"
NET_BACKOFF=5
MAX_BACKOFF=300

# 清理旧 supervisor
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != "$$" ]; then
    kill "$old" 2>/dev/null || true
  fi
fi
echo $$ > "$PIDF"
echo "$(date): supervisor started (PID: $$)" >> "$LOG"

while true; do
  if [ ! -x "$BIN" ] || ! "$BIN" version &>/dev/null; then
    echo "$(date): binary issue, re-downloading..." >> "$LOG"
    rm -f "$BIN"
    arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -fsSL --connect-timeout 10 --max-time 120 \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
      -o "$BIN" && chmod +x "$BIN" && echo "$(date): download ok" >> "$LOG" || {
      echo "$(date): download failed, retry in 60s" >> "$LOG"; sleep 60; continue; }
  fi

  # 优先：Zero Trust 纯 token
  if [ -f "$TOKEN_RAW" ] && [ -s "$TOKEN_RAW" ]; then
    tok=$(tr -d '\r\n' < "$TOKEN_RAW")
    echo "$(date): starting cloudflared (token mode)..." >> "$LOG"
    "$BIN" tunnel run --token "$tok" >> "$LOG" 2>&1
    rc=$?
  elif [ -f "$TOKEN_JSON" ] && [ -s "$TOKEN_JSON" ] && [ -f "$CONFIG" ]; then
    cd "$DIR" || exit 1
    echo "$(date): starting cloudflared (config mode)..." >> "$LOG"
    "$BIN" tunnel --config "$CONFIG" run >> "$LOG" 2>&1
    rc=$?
  else
    echo "$(date): TOKEN MISSING. 在面板中安装/编辑 Token。" >> "$LOG"
    sleep 30
    continue
  fi

  case $rc in
    130|143|137)
      echo "$(date): stopped by signal ($rc), not restarting" >> "$LOG"
      rm -f "$PIDF"; exit 0 ;;
    1|2|127)
      echo "$(date): FATAL ($rc), retry in 30s" >> "$LOG"; sleep 30 ;;
    7|8|9|35|60|64|110|111|112|113)
      echo "$(date): NETWORK ERROR ($rc), backoff ${NET_BACKOFF}s" >> "$LOG"
      sleep $NET_BACKOFF
      NET_BACKOFF=$((NET_BACKOFF * 2))
      [ $NET_BACKOFF -gt $MAX_BACKOFF ] && NET_BACKOFF=$MAX_BACKOFF ;;
    *)
      echo "$(date): exited ($rc), restart in 5s" >> "$LOG"
      NET_BACKOFF=5; sleep 5 ;;
  esac
done
CFEOF
    as_root chmod +x "$CF_SUPERVISOR"
}

# 交互读取 token（支持纯字符串 或 JSON）
cf_read_token_interactive() {
    echo -e "  支持两种格式:"
    echo -e "  ${GREEN}1)${NC} Zero Trust 面板复制的一长串 Token（推荐，单行回车结束）"
    echo -e "  ${GREEN}2)${NC} credentials JSON（以 { 开头，粘贴完按 Ctrl+D）"
    echo ""
    echo -n "  请粘贴 Token: "
    local first_line=""
    # 不使用 -t 超时，避免慢粘贴被截断
    IFS= read -r first_line || true
    if [ -z "$first_line" ]; then
        echo -e "${YELLOW}[!] 未输入。${NC}"
        return 1
    fi

    as_root mkdir -p "$CF_DIR" "$CF_LOG_DIR"

    if echo "$first_line" | grep -q '^{'; then
        local token_content="$first_line" line
        while IFS= read -r line; do
            token_content="${token_content}
${line}"
        done
        printf '%s\n' "$token_content" | as_root tee "$CF_TOKEN_FILE" >/dev/null
        as_root rm -f "$CF_TOKEN_RAW"
        echo -e "${GREEN}[√] token 已保存 (JSON → $CF_TOKEN_FILE)${NC}"
    else
        # 纯 token 字符串
        printf '%s\n' "$(echo "$first_line" | tr -d '\r\n ')" | as_root tee "$CF_TOKEN_RAW" >/dev/null
        as_root chmod 600 "$CF_TOKEN_RAW" 2>/dev/null || true
        echo -e "${GREEN}[√] token 已保存 (纯字符串 → $CF_TOKEN_RAW)${NC}"
    fi
    return 0
}

cf_ensure_config_template() {
    if [ -f "$CF_CONFIG" ]; then
        return 0
    fi
    as_root tee "$CF_CONFIG" >/dev/null << 'EOF'
# 仅在使用 JSON 凭据文件时需要；纯 Token 模式可忽略本文件
tunnel: <tunnel-name>
credentials-file: /etc/cloudflared/tunnel-token.json
ingress:
  - hostname: example.com
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
    echo -e "${GREEN}[√] 已写入 config 模板: $CF_CONFIG${NC}"
}

cf_install_service_unit() {
    local st
    st=$(svc_type)
    echo -e "  安装服务方式: ${CYAN}${st}${NC}"

    case "$st" in
        systemd)
            # token 模式与 config 模式不同 ExecStart
            local exec_line
            if [ -f "$CF_TOKEN_RAW" ] && [ -s "$CF_TOKEN_RAW" ]; then
                exec_line="$CF_BIN tunnel run --token \$(tr -d '\\r\\n' < $CF_TOKEN_RAW)"
                # systemd 不支持 $() 在 ExecStart 里随意用，改为 EnvironmentFile/脚本
                as_root tee /usr/local/bin/cloudflared-run.sh >/dev/null << EOF
#!/bin/bash
exec $CF_BIN tunnel run --token "\$(tr -d '\\r\\n' < $CF_TOKEN_RAW)"
EOF
                as_root chmod +x /usr/local/bin/cloudflared-run.sh
                exec_line="/usr/local/bin/cloudflared-run.sh"
            else
                exec_line="$CF_BIN tunnel --config $CF_CONFIG run"
            fi
            as_root tee /etc/systemd/system/cloudflared.service >/dev/null << SVD
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$CF_DIR
ExecStart=$exec_line
Restart=always
RestartSec=5
StandardOutput=append:$CF_LOG
StandardError=append:$CF_LOG

[Install]
WantedBy=multi-user.target
SVD
            as_root systemctl daemon-reload
            as_root systemctl enable cloudflared 2>/dev/null \
                && echo -e "${GREEN}[√] systemd 已 enable${NC}" \
                || echo -e "${YELLOW}[!] systemctl enable 失败${NC}"
            as_root systemctl restart cloudflared 2>/dev/null \
                && echo -e "${GREEN}[√] 已启动${NC}" \
                || echo -e "${YELLOW}[!] 启动失败，请看日志${NC}"
            ;;
        s6)
            local sd
            sd=$(s6_dir)
            as_root mkdir -p "$sd/cloudflared"
            if [ -f "$CF_TOKEN_RAW" ] && [ -s "$CF_TOKEN_RAW" ]; then
                as_root tee "$sd/cloudflared/run" >/dev/null << S6EOF
#!/bin/sh
exec $CF_BIN tunnel run --token "\$(tr -d '\r\n' < $CF_TOKEN_RAW)"
S6EOF
            else
                as_root tee "$sd/cloudflared/run" >/dev/null << S6EOF
#!/bin/sh
cd $CF_DIR
exec $CF_BIN tunnel --config $CF_CONFIG run
S6EOF
            fi
            as_root chmod +x "$sd/cloudflared/run"
            as_root tee "$sd/cloudflared/finish" >/dev/null << 'S6FIN'
#!/bin/sh
echo "cloudflared exited ($?), restart in 5s" >> /var/log/sys-svc/cloudflared.log
sleep 5
exit 1
S6FIN
            as_root chmod +x "$sd/cloudflared/finish"
            s6-svc -u "$sd/cloudflared" 2>/dev/null \
                || s6-svc -a "$sd/cloudflared" 2>/dev/null \
                && echo -e "${GREEN}[√] s6 已安装 ($sd)${NC}" \
                || echo -e "${YELLOW}[!] s6 启动失败，路径: $sd${NC}"
            ;;
        manual)
            write_cf_supervisor
            cf_register_boot
            # 停掉旧进程再启
            if [ -f "$CF_PID" ]; then
                as_root kill "$(cat "$CF_PID" 2>/dev/null)" 2>/dev/null || true
            fi
            as_root pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
            as_root mkdir -p "$CF_LOG_DIR"
            as_root bash -c "nohup $CF_SUPERVISOR >> $CF_LOG 2>&1 & echo \$! > $CF_PID"
            echo -e "${GREEN}[√] supervisor 已启动${NC}"
            ;;
    esac
}

cf_register_boot() {
    local boot="$CF_SUPERVISOR"
    [ ! -f "$boot" ] && write_cf_supervisor
    local ok=false
    if [ -f /etc/rc.local ]; then
        if as_root grep -q "cloudflared" /etc/rc.local 2>/dev/null; then
            ok=true
        else
            as_root sed -i "/^exit 0/i\\${boot} >> ${CF_LOG} 2>&1 &" /etc/rc.local 2>/dev/null && ok=true
        fi
    fi
    if ! $ok && command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v cloudflared; echo "@reboot ${boot} >> ${CF_LOG} 2>&1 &") | crontab - 2>/dev/null && ok=true
    fi
    if ! $ok; then
        if ! grep -q cloudflared /etc/profile 2>/dev/null; then
            echo "${boot} >> ${CF_LOG} 2>&1 &" | as_root tee -a /etc/profile >/dev/null && ok=true
        else
            ok=true
        fi
    fi
    if $ok; then
        echo -e "${GREEN}[√] 开机自启已注册${NC}"
    else
        echo -e "${YELLOW}[!] 注册失败，请手动添加${NC}"
    fi
}

install_cloudflared() {
    echo -e "\n${CYAN}>>> 安装 Cloudflare Tunnel <<<${NC}"
    if ! need_root; then return 1; fi

    local arch
    arch=$(cf_arch)
    as_root mkdir -p "$CF_DIR" "$CF_SVC_DIR" "$CF_LOG_DIR"

    if cf_is_installed; then
        echo -e "${GREEN}[√] cloudflared 已存在: $($CF_BIN version 2>/dev/null | head -1)${NC}"
    else
        echo -n "  下载 cloudflared (${arch})..."
        local ok=false i
        for i in 1 2 3; do
            if as_root curl -fsSL --connect-timeout 10 --max-time 120 \
                "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
                -o "$CF_BIN" 2>/dev/null; then
                as_root chmod +x "$CF_BIN"
                if "$CF_BIN" version &>/dev/null; then
                    ok=true
                    break
                fi
            fi
            echo -e " ${YELLOW}失败(第${i}次)${NC}"
            sleep 3
        done
        if ! $ok; then
            echo -e " ${RED}下载失败${NC}"
            return 1
        fi
        echo -e " ${GREEN}OK${NC}"
    fi

    if ! cf_has_token; then
        echo -e "\n${YELLOW}[!] 尚未配置 Token${NC}"
        cf_read_token_interactive || echo -e "${YELLOW}[!] 可稍后在「编辑 Token」中补配${NC}"
    else
        echo -e "${GREEN}[√] 已检测到 Token${NC}"
    fi

    # 仅 JSON 模式需要 config 模板
    if [ -f "$CF_TOKEN_FILE" ] && [ ! -f "$CF_TOKEN_RAW" ]; then
        cf_ensure_config_template
    fi

    cf_install_service_unit
    echo -e "\n${GREEN}[√] 安装流程结束${NC}"
    cf_status
}

cf_start() {
    if ! need_root; then return 1; fi
    if ! cf_is_installed; then
        echo -e "${RED}[x] 未安装 cloudflared，请先安装。${NC}"
        return 1
    fi
    if ! cf_has_token; then
        echo -e "${RED}[x] 缺少 Token，请先编辑 Token。${NC}"
        return 1
    fi
    local st
    st=$(svc_type)
    case "$st" in
        systemd) as_root systemctl start cloudflared ;;
        s6)
            local sd; sd=$(s6_dir)
            s6-svc -u "$sd/cloudflared" 2>/dev/null || s6-svc -a "$sd/cloudflared" 2>/dev/null
            ;;
        manual)
            if cf_is_running; then
                echo -e "${GREEN}[√] 已在运行${NC}"
                return 0
            fi
            [ -f "$CF_SUPERVISOR" ] || write_cf_supervisor
            as_root bash -c "nohup $CF_SUPERVISOR >> $CF_LOG 2>&1 & echo \$! > $CF_PID"
            ;;
    esac
    sleep 1
    if cf_is_running; then
        echo -e "${GREEN}[√] 已启动${NC}"
    else
        echo -e "${YELLOW}[!] 启动命令已发，但进程未检测到，请看日志${NC}"
    fi
}

cf_stop() {
    if ! need_root; then return 1; fi
    local st
    st=$(svc_type)
    case "$st" in
        systemd) as_root systemctl stop cloudflared ;;
        s6)
            local sd; sd=$(s6_dir)
            s6-svc -d "$sd/cloudflared" 2>/dev/null
            ;;
        manual)
            if [ -f "$CF_PID" ]; then
                as_root kill "$(cat "$CF_PID" 2>/dev/null)" 2>/dev/null || true
                as_root rm -f "$CF_PID"
            fi
            as_root pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
            as_root pkill -f 'cloudflared/supervisor' 2>/dev/null || true
            ;;
    esac
    echo -e "${GREEN}[√] 已停止${NC}"
}

cf_restart() {
    cf_stop
    sleep 2
    cf_start
}

cf_status() {
    local st inst run
    st=$(svc_type)
    if cf_is_installed; then
        inst="${GREEN}已安装${NC}"
    else
        inst="${RED}未安装${NC}"
    fi
    if cf_is_running; then
        run="${GREEN}运行中${NC}"
    else
        run="${RED}已停止${NC}"
    fi
    echo -e "\n${CYAN}>>> CF Tunnel 状态 <<<${NC}"
    echo -e "  Init: $(detect_init) | 管理: ${st} | 环境: $(detect_container)"
    echo -e "  二进制: ${inst}"
    if cf_is_installed; then
        echo -e "  版本: $($CF_BIN version 2>/dev/null | head -1)"
    fi
    echo -e "  状态: ${run}"
    if [ -f "$CF_TOKEN_RAW" ]; then
        echo -e "  Token: ${GREEN}纯字符串${NC} ($CF_TOKEN_RAW)"
    elif [ -f "$CF_TOKEN_FILE" ]; then
        echo -e "  Token: ${GREEN}JSON 凭据${NC} ($CF_TOKEN_FILE)"
    else
        echo -e "  Token: ${RED}未配置${NC}"
    fi
    [ -f "$CF_CONFIG" ] && echo -e "  Config: $CF_CONFIG"
    echo -e "  日志: $CF_LOG"

    case "$st" in
        systemd)
            systemctl status cloudflared --no-pager 2>/dev/null | head -15 || true
            ;;
        s6)
            local sd; sd=$(s6_dir)
            s6-svstat "$sd/cloudflared" 2>/dev/null || echo "  s6 未注册"
            ;;
        manual)
            local pid=""
            [ -f "$CF_PID" ] && pid=$(cat "$CF_PID" 2>/dev/null)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo -e "  supervisor PID: $pid"
            fi
            pgrep -af 'cloudflared' 2>/dev/null | head -5 || true
            ;;
    esac
}

cf_logs() {
    echo -e "\n${CYAN}>>> CF 日志 (最近 40 行) <<<${NC}"
    if [ -f "$CF_LOG" ]; then
        tail -40 "$CF_LOG"
    else
        # systemd journal 兜底
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -u cloudflared -n 40 --no-pager 2>/dev/null || echo "  无日志"
        else
            echo "  无日志文件: $CF_LOG"
        fi
    fi
}

cf_edit_token() {
    echo -e "\n${CYAN}>>> 编辑 CF Token <<<${NC}"
    if ! need_root; then return 1; fi
    if [ -f "$CF_TOKEN_RAW" ]; then
        echo -e "${YELLOW}当前 (纯字符串，仅显示前后):${NC}"
        local t; t=$(tr -d '\r\n' < "$CF_TOKEN_RAW")
        echo "  ${t:0:12}...${t: -8}"
    elif [ -f "$CF_TOKEN_FILE" ]; then
        echo -e "${YELLOW}当前 JSON:${NC}"
        cat "$CF_TOKEN_FILE"
    else
        echo -e "${YELLOW}当前无 Token${NC}"
    fi
    echo ""
    cf_read_token_interactive || return 1
    # token 变更后若用 systemd，重写 unit
    if [ "$(svc_type)" = "systemd" ] && [ -f /etc/systemd/system/cloudflared.service ]; then
        cf_install_service_unit
    fi
    echo -e "${YELLOW}建议执行「重启」使新 Token 生效。${NC}"
}

cf_enable_boot() {
    if ! need_root; then return 1; fi
    local init
    init=$(detect_init)
    if [ "$init" = "systemd" ]; then
        as_root systemctl enable cloudflared 2>/dev/null \
            && echo -e "${GREEN}[√] systemd 开机自启已启用${NC}" \
            || echo -e "${YELLOW}[!] enable 失败（服务可能未安装）${NC}"
    elif [ "$init" = "s6" ]; then
        echo -e "${GREEN}[√] s6 默认随服务目录启动${NC}"
    else
        write_cf_supervisor
        cf_register_boot
    fi
}

# SSH 本地转发（原功能4的一部分，保留）
ssh_port_forward_hint() {
    echo -e "\n${CYAN}>>> SSH 本地端口转发 <<<${NC}"
    echo -e "把服务器本地端口安全拉到你自己电脑浏览器访问。"
    read -p "服务器上要访问的端口 (例如 3000): " r_port
    read -p "SSH 登录用户名 (如 cj): " s_user
    local p_ip
    p_ip=$(get_public_ip || true)
    [ -z "$p_ip" ] && p_ip="<服务器公网IP>"
    local s_port=""
    read -p "SSH 端口 [回车=22]: " s_port
    s_port=${s_port:-22}
    echo -e "\n${CYAN}>>> 请在你的个人电脑终端运行： <<<${NC}"
    if [ "$s_port" = "22" ]; then
        echo -e "${GREEN}ssh -L 8080:127.0.0.1:${r_port} ${s_user}@${p_ip}${NC}"
    else
        echo -e "${GREEN}ssh -L 8080:127.0.0.1:${r_port} -p ${s_port} ${s_user}@${p_ip}${NC}"
    fi
    echo -e "登录成功后，电脑浏览器打开 ${YELLOW}http://127.0.0.1:8080${NC}"
}

cf_tunnel_menu() {
    while true; do
        local st inst run
        st=$(svc_type)
        if cf_is_installed; then inst="${GREEN}已安装${NC}"; else inst="${RED}未安装${NC}"; fi
        if cf_is_running; then run="${GREEN}运行中${NC}"; else run="${RED}已停止${NC}"; fi

        echo -e "\n${CYAN}====================================================${NC}"
        echo -e "${CYAN}              CF 隧道管理${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e "  Init: $(detect_init) | 管理: ${st} | 环境: $(detect_container)"
        echo -e "  CF Tunnel: ${inst}  ${run}"
        echo -e "----------------------------------------------------"
        echo -e "  ${GREEN}1.${NC} 安装 / 修复 CF Tunnel"
        echo -e "  ${GREEN}2.${NC} 启动"
        echo -e "  ${GREEN}3.${NC} 停止"
        echo -e "  ${GREEN}4.${NC} 重启"
        echo -e "  ${GREEN}5.${NC} 查看状态"
        echo -e "  ${GREEN}6.${NC} 查看日志"
        echo -e "  ${GREEN}7.${NC} 编辑 Token"
        echo -e "  ${GREEN}8.${NC} 注册开机自启"
        echo -e "  ${GREEN}9.${NC} SSH 本地端口转发 (生成电脑端命令)"
        echo -e "  ${RED}0.${NC} 返回主菜单"
        echo -e "${CYAN}====================================================${NC}"
        read -p "请选择 [0-9]: " cf_opt
        case "$cf_opt" in
            1) install_cloudflared ;;
            2) cf_start ;;
            3) cf_stop ;;
            4) cf_restart ;;
            5) cf_status ;;
            6) cf_logs ;;
            7) cf_edit_token ;;
            8) cf_enable_boot ;;
            9) ssh_port_forward_hint ;;
            0) return ;;
            *) echo -e "${RED}无效选项。${NC}" ;;
        esac
        echo -e "\n${YELLOW}----------------------------------------------------${NC}"
        read -p "按 【回车键】 继续..."
    done
}

# ==========================================
# 功能 5：连接穿透（合并自 cf.sh）
# 运行时文件统一放 CONN_DIR；快速隧道不杀固定隧道进程
# ==========================================

CONN_DIR="${HOME}/.1sh-conn"
mkdir -p "$CONN_DIR" 2>/dev/null || CONN_DIR="/tmp/1sh-conn-$$"
mkdir -p "$CONN_DIR" 2>/dev/null || true

refresh_env_flags() {
    HAS_SUDO=false
    HAS_PKG_MANAGER=false
    HAS_SYSTEMD=false
    if [ "$EUID" -eq 0 ]; then
        HAS_SUDO=true
    elif command -v sudo >/dev/null 2>&1; then
        HAS_SUDO=true
    fi
    if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1 \
        || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 \
        || command -v apk >/dev/null 2>&1; then
        HAS_PKG_MANAGER=true
    fi
    if command -v systemctl >/dev/null 2>&1 && [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        HAS_SYSTEMD=true
    fi
}

check_tools() {
    local MISSING="" tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            MISSING="$MISSING $tool"
        fi
    done
    [ -z "$MISSING" ] && return 0
    refresh_env_flags
    echo -e "${YELLOW}[*] 缺失工具:${MISSING}，尝试自动安装...${NC}"
    if [ "$HAS_SUDO" != true ] && [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[!] 无 root/sudo，无法自动安装${MISSING}${NC}"
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
        as_root apt-get update -qq 2>/dev/null
        as_root apt-get install -y -qq $MISSING 2>/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y -q $MISSING 2>/dev/null
    elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y $MISSING 2>/dev/null
    elif command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache $MISSING 2>/dev/null
    else
        echo -e "${RED}[!] 无法识别包管理器${NC}"
        return 1
    fi
    return 0
}

find_available_port() {
    local base=${1:-7681}
    local max=$((base + 50))
    local port=$base
    while [ "$port" -le "$max" ]; do
        if command -v ss >/dev/null 2>&1; then
            if ! ss -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
                echo "$port"; return 0
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if ! netstat -tln 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
                echo "$port"; return 0
            fi
        else
            echo "$port"; return 0
        fi
        port=$((port + 1))
    done
    echo "$base"
    return 1
}

get_cf_cmd() {
    if [ -x "$CF_BIN" ]; then echo "$CF_BIN"; return; fi
    if command -v cloudflared >/dev/null 2>&1; then command -v cloudflared; return; fi
    if [ -x "$CONN_DIR/cloudflared" ]; then echo "$CONN_DIR/cloudflared"; return; fi
    if [ -x "./cloudflared" ]; then echo "./cloudflared"; return; fi
    echo ""
}

install_cf_local() {
    local cmd
    cmd=$(get_cf_cmd)
    if [ -n "$cmd" ] && "$cmd" version >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}[*] 下载 cloudflared 到 $CONN_DIR ...${NC}"
    mkdir -p "$CONN_DIR"
    local arch
    arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    if curl -fsSL --connect-timeout 10 --max-time 120 \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
        -o "$CONN_DIR/cloudflared"; then
        chmod +x "$CONN_DIR/cloudflared"
        return 0
    fi
    echo -e "${RED}[x] cloudflared 下载失败${NC}"
    return 1
}

install_sshx() {
    if command -v sshx >/dev/null 2>&1; then return 0; fi
    if [ -x "$HOME/.sshx/bin/sshx" ]; then return 0; fi
    if [ -x "$CONN_DIR/sshx" ]; then return 0; fi

    check_tools curl tar || return 1
    local arch suffix
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64"; suffix="-unknown-linux-musl" ;;
        aarch64|arm64) arch="aarch64"; suffix="-unknown-linux-musl" ;;
        *) echo -e "${RED}[x] 不支持的架构${NC}"; return 1 ;;
    esac

    echo -e "${YELLOW}[*] 下载 sshx...${NC}"
    mkdir -p "$CONN_DIR"
    (
        cd "$CONN_DIR" || exit 1
        if curl -sSf https://sshx.io/get | sh -s download >/dev/null 2>&1 && [ -x "./sshx" ]; then
            exit 0
        fi
        local URL="https://s3.amazonaws.com/sshx/sshx-${arch}${suffix}.tar.gz"
        local TGZ="sshx.tgz.$$"
        if curl -L --connect-timeout 15 --max-time 90 -o "$TGZ" "$URL" && tar -xzf "$TGZ" 2>/dev/null; then
            rm -f "$TGZ"
            [ -f ./sshx ] && chmod +x ./sshx && exit 0
        fi
        rm -f "$TGZ"
        exit 1
    ) && return 0
    echo -e "${RED}[x] sshx 安装失败（网络或源不可用）${NC}"
    return 1
}

get_sshx_cmd() {
    if command -v sshx >/dev/null 2>&1; then command -v sshx
    elif [ -x "$HOME/.sshx/bin/sshx" ]; then echo "$HOME/.sshx/bin/sshx"
    elif [ -x "$CONN_DIR/sshx" ]; then echo "$CONN_DIR/sshx"
    else echo ""; fi
}

install_ttyd() {
    if command -v ttyd >/dev/null 2>&1; then return 0; fi
    if [ -x "$CONN_DIR/ttyd" ] && "$CONN_DIR/ttyd" --version >/dev/null 2>&1; then return 0; fi

    check_tools curl || true
    if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
        echo -e "${YELLOW}[*] 尝试 apt 安装 ttyd...${NC}"
        as_root apt-get update -qq 2>/dev/null
        as_root apt-get install -y -qq ttyd 2>/dev/null && command -v ttyd >/dev/null 2>&1 && return 0
    fi
    if command -v apk >/dev/null 2>&1; then
        as_root apk add --no-cache ttyd 2>/dev/null && command -v ttyd >/dev/null 2>&1 && return 0
    fi

    echo -e "${YELLOW}[*] 从 GitHub 下载 ttyd...${NC}"
    mkdir -p "$CONN_DIR"
    local ARCH T_VERSION BIN_URL
    ARCH=$(uname -m)
    T_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/tsl0922/ttyd/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$T_VERSION" ] && T_VERSION="1.7.7"
    case "$ARCH" in
        x86_64|amd64) BIN_URL="https://github.com/tsl0922/ttyd/releases/download/${T_VERSION}/ttyd.x86_64" ;;
        aarch64|arm64) BIN_URL="https://github.com/tsl0922/ttyd/releases/download/${T_VERSION}/ttyd.aarch64" ;;
        *) echo -e "${RED}[x] 不支持的架构${NC}"; return 1 ;;
    esac
    if curl -L --connect-timeout 15 --max-time 90 -o "$CONN_DIR/ttyd" "$BIN_URL" && chmod +x "$CONN_DIR/ttyd"; then
        if "$CONN_DIR/ttyd" --version >/dev/null 2>&1; then
            echo -e "${GREEN}[√] ttyd 就绪${NC}"
            return 0
        fi
    fi
    rm -f "$CONN_DIR/ttyd"
    echo -e "${RED}[x] ttyd 安装失败${NC}"
    return 1
}

get_ttyd_cmd() {
    if command -v ttyd >/dev/null 2>&1; then command -v ttyd
    elif [ -x "$CONN_DIR/ttyd" ]; then echo "$CONN_DIR/ttyd"
    else echo ""; fi
}

install_frpc() {
    if command -v frpc >/dev/null 2>&1; then return 0; fi
    if [ -x "$CONN_DIR/frpc" ]; then return 0; fi
    echo -e "${YELLOW}[*] 下载 frpc...${NC}"
    mkdir -p "$CONN_DIR"
    local ARCH FRP_ARCH FRP_URL
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) FRP_ARCH="amd64" ;;
        aarch64|arm64) FRP_ARCH="arm64" ;;
        *) echo -e "${RED}[x] 不支持的架构${NC}"; return 1 ;;
    esac
    FRP_URL=$(curl -s --max-time 15 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep "browser_download_url.*linux_${FRP_ARCH}.tar.gz" | head -1 | cut -d '"' -f 4)
    if [ -z "$FRP_URL" ]; then
        echo -e "${RED}[x] 无法获取 frp 下载地址${NC}"
        return 1
    fi
    local TGZ="$CONN_DIR/frp.tar.gz"
    if curl -L --connect-timeout 15 --max-time 120 -o "$TGZ" "$FRP_URL"; then
        tar -xzf "$TGZ" -C "$CONN_DIR" 2>/dev/null
        local bin
        bin=$(find "$CONN_DIR" -maxdepth 2 -type f -name frpc 2>/dev/null | head -1)
        if [ -n "$bin" ]; then
            cp -f "$bin" "$CONN_DIR/frpc"
            chmod +x "$CONN_DIR/frpc"
            rm -f "$TGZ"
            find "$CONN_DIR" -maxdepth 1 -type d -name 'frp_*' -exec rm -rf {} + 2>/dev/null || true
            return 0
        fi
    fi
    echo -e "${RED}[x] frpc 安装失败${NC}"
    return 1
}

get_frpc_cmd() {
    if command -v frpc >/dev/null 2>&1; then command -v frpc
    elif [ -x "$CONN_DIR/frpc" ]; then echo "$CONN_DIR/frpc"
    else echo ""; fi
}

run_sshx() {
    install_sshx || return 1
    local CMD
    CMD=$(get_sshx_cmd)
    [ -z "$CMD" ] && { echo -e "${RED}[x] sshx 未就绪${NC}"; return 1; }

    stop_sshx
    echo -e "${YELLOW}[*] 后台启动 sshx.io...${NC}"
    nohup "$CMD" > "$CONN_DIR/sshx.log" 2>&1 &
    echo $! > "$CONN_DIR/sshx.pid"
    local SSHX_PID=$! SSHX_URL="" i
    for i in $(seq 1 12); do
        sleep 1; echo -n "."
        SSHX_URL=$(grep -oE 'https://sshx\.io/s/[a-zA-Z0-9#_-]+' "$CONN_DIR/sshx.log" 2>/dev/null | head -1)
        [ -n "$SSHX_URL" ] && break
        if ! kill -0 "$SSHX_PID" 2>/dev/null; then
            echo -e "\n${RED}[x] sshx 进程退出${NC}"
            tail -5 "$CONN_DIR/sshx.log" 2>/dev/null
            return 1
        fi
    done
    if [ -z "$SSHX_URL" ]; then
        echo -e "\n${RED}[x] 获取 sshx URL 超时${NC}"
        tail -5 "$CONN_DIR/sshx.log" 2>/dev/null
        return 1
    fi
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e " sshx 已后台运行"
    echo -e " 网页终端: ${YELLOW}$SSHX_URL${NC}"
    echo -e "${GREEN}==================================================${NC}"
}

stop_sshx() {
    local pid
    [ -f "$CONN_DIR/sshx.pid" ] && pid=$(cat "$CONN_DIR/sshx.pid" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    pkill -f '[s]shx' 2>/dev/null || true
    rm -f "$CONN_DIR/sshx.pid"
}

check_sshx_status() {
    local pid=""
    [ -f "$CONN_DIR/sshx.pid" ] && pid=$(cat "$CONN_DIR/sshx.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        local url
        url=$(grep -oE 'https://sshx\.io/s/[a-zA-Z0-9#_-]+' "$CONN_DIR/sshx.log" 2>/dev/null | head -1)
        echo "running|$pid|$url"
    elif pgrep -f '[s]shx' >/dev/null 2>&1; then
        pid=$(pgrep -f '[s]shx' | head -1)
        echo "running|$pid|"
    else
        echo "stopped|"
    fi
}

uninstall_sshx() {
    stop_sshx
    rm -f "$CONN_DIR/sshx" "$CONN_DIR/sshx.log" "$CONN_DIR/sshx.pid"
    rm -rf "$HOME/.sshx"
    echo -e "${GREEN}[√] sshx 已清理${NC}"
}

# ---------- tmate 终端共享（SSH 会话 / 零端口） ----------
TMATE_SOCK="${CONN_DIR}/tmate.sock"
TMATE_LOG="${CONN_DIR}/tmate.log"
TMATE_INFO="${CONN_DIR}/tmate.info"
TMATE_PID="${CONN_DIR}/tmate.pid"

get_tmate_cmd() {
    if command -v tmate >/dev/null 2>&1; then command -v tmate
    elif [ -x "$CONN_DIR/tmate" ]; then echo "$CONN_DIR/tmate"
    else echo ""; fi
}

install_tmate() {
    local cmd
    cmd=$(get_tmate_cmd)
    if [ -n "$cmd" ] && "$cmd" -V >/dev/null 2>&1; then
        return 0
    fi
    refresh_env_flags 2>/dev/null || true
    echo -e "${YELLOW}[*] 安装 tmate...${NC}"
    if is_root || command -v sudo >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            as_root apt-get update -qq 2>/dev/null || true
            as_root apt-get install -y -qq tmate 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
            as_root dnf install -y -q tmate 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            as_root yum install -y tmate 2>/dev/null || true
        elif command -v apk >/dev/null 2>&1; then
            as_root apk add --no-cache tmate 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}[!] 无 root/sudo，跳过 apt 安装 tmate${NC}"
        echo -e "  若 PATH 已有 tmate 可继续；否则请: apt install tmate（须root）"
    fi
    cmd=$(get_tmate_cmd)
    if [ -n "$cmd" ] && "$cmd" -V >/dev/null 2>&1; then
        echo -e "${GREEN}[√] tmate 可用: $cmd${NC}"
        return 0
    fi
    echo -e "${RED}[x] tmate 不可用。有 root 时: apt install tmate${NC}"
    return 1
}

fetch_tmate_creds() {
    local cmd sock
    cmd=$(get_tmate_cmd)
    sock="${TMATE_SOCK}"
    [ -n "$cmd" ] && [ -S "$sock" ] || return 1
    local ssh_rw ssh_ro web
    ssh_rw=$("$cmd" -S "$sock" display -p '#{tmate_ssh}' 2>/dev/null || true)
    ssh_ro=$("$cmd" -S "$sock" display -p '#{tmate_ssh_ro}' 2>/dev/null || true)
    web=$("$cmd" -S "$sock" display -p '#{tmate_web}' 2>/dev/null || true)
    # 部分版本 web 键名不同
    [ -z "$web" ] && web=$("$cmd" -S "$sock" display -p '#{tmate_web_ro}' 2>/dev/null || true)
    if [ -z "$ssh_rw" ] && [ -z "$ssh_ro" ]; then
        return 1
    fi
    {
        echo "ssh_rw=${ssh_rw}"
        echo "ssh_ro=${ssh_ro}"
        echo "web=${web}"
        echo "updated=$(date '+%F %T' 2>/dev/null || true)"
    } > "$TMATE_INFO"
    return 0
}

print_tmate_creds() {
    local ssh_rw ssh_ro web
    if [ -f "$TMATE_INFO" ]; then
        # shellcheck disable=SC1090
        ssh_rw=$(grep '^ssh_rw=' "$TMATE_INFO" 2>/dev/null | cut -d= -f2-)
        ssh_ro=$(grep '^ssh_ro=' "$TMATE_INFO" 2>/dev/null | cut -d= -f2-)
        web=$(grep '^web=' "$TMATE_INFO" 2>/dev/null | cut -d= -f2-)
    fi
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e " tmate 终端共享已就绪（零端口，依赖出站 tmate.io）"
    echo -e "${YELLOW}【读写】在你的电脑执行（完整 shell 权限，勿泄露）:${NC}"
    if [ -n "$ssh_rw" ]; then
        echo -e "  ${GREEN}${ssh_rw}${NC}"
    else
        echo -e "  ${RED}(未获取到 rw 连接串)${NC}"
    fi
    if [ -n "$ssh_ro" ]; then
        echo -e "${CYAN}【只读】观摩用:${NC}"
        echo -e "  ${CYAN}${ssh_ro}${NC}"
    fi
    if [ -n "$web" ]; then
        echo -e " Web: ${YELLOW}${web}${NC}"
    fi
    echo -e " 控制端一般只需系统自带 ssh，${YELLOW}不必${NC}安装 tmate"
    echo -e " 结束会话: 本菜单「关闭连接」"
    echo -e "${GREEN}==================================================${NC}"
}

run_tmate() {
    install_tmate || return 1
    local CMD
    CMD=$(get_tmate_cmd)
    [ -z "$CMD" ] && { echo -e "${RED}[x] tmate 未就绪${NC}"; return 1; }

    mkdir -p "$CONN_DIR"
    stop_tmate

    echo -e "${YELLOW}[*] 后台启动 tmate 会话...${NC}"
    echo -e "${YELLOW}    需服务器能访问 *.tmate.io（出站）; rw 链接等同交出终端权限${NC}"
    # 后台 session，不占用菜单 tty
    rm -f "$TMATE_SOCK" "$TMATE_LOG" "$TMATE_INFO"
    nohup "$CMD" -S "$TMATE_SOCK" new-session -d >/dev/null 2>>"$TMATE_LOG" &
    echo $! > "$TMATE_PID"

    # 等待 tmate 连上中继（优先 display 取凭证，避免 wait 卡死）
    local i ready=0
    for i in $(seq 1 35); do
        if [ -S "$TMATE_SOCK" ] && fetch_tmate_creds 2>/dev/null; then
            ready=1
            break
        fi
        # 非阻塞：带超时的 wait（有 timeout 命令时）
        if command -v timeout >/dev/null 2>&1; then
            timeout 2 "$CMD" -S "$TMATE_SOCK" wait tmate-ready >>"$TMATE_LOG" 2>&1 && {
                fetch_tmate_creds 2>/dev/null && ready=1 && break
            }
        fi
        sleep 1
        echo -n "."
    done
    echo ""

    if [ "$ready" -ne 1 ] && ! fetch_tmate_creds; then
        echo -e "${RED}[x] tmate 就绪超时（检查出网/DNS 到 tmate.io）${NC}"
        [ -f "$TMATE_LOG" ] && tail -15 "$TMATE_LOG"
        stop_tmate
        return 1
    fi

    fetch_tmate_creds || true
    print_tmate_creds
    # 凭证写入 info 供 status 展示
    if [ -f "$TMATE_INFO" ]; then
        local rw
        rw=$(grep '^ssh_rw=' "$TMATE_INFO" | cut -d= -f2-)
        [ -n "$rw" ] && echo -e "${GREEN}[√] 凭证已缓存: $TMATE_INFO${NC}"
    fi
}

stop_tmate() {
    local CMD
    CMD=$(get_tmate_cmd)
    if [ -n "$CMD" ] && [ -S "$TMATE_SOCK" ]; then
        "$CMD" -S "$TMATE_SOCK" kill-server 2>/dev/null || true
    fi
    local pid=""
    [ -f "$TMATE_PID" ] && pid=$(cat "$TMATE_PID" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    # 仅杀本 sock 相关，避免误杀系统其他 tmate
    pkill -f "tmate -S ${TMATE_SOCK}" 2>/dev/null || true
    rm -f "$TMATE_SOCK" "$TMATE_PID"
}

check_tmate_status() {
    local CMD pid=""
    CMD=$(get_tmate_cmd)
    if [ -n "$CMD" ] && [ -S "$TMATE_SOCK" ]; then
        if fetch_tmate_creds 2>/dev/null; then
            local rw
            rw=$(grep '^ssh_rw=' "$TMATE_INFO" 2>/dev/null | cut -d= -f2-)
            [ -f "$TMATE_PID" ] && pid=$(cat "$TMATE_PID" 2>/dev/null)
            [ -z "$pid" ] && pid="tmate"
            echo "running|${pid}|${rw}"
            return 0
        fi
    fi
    # sock 残留但不可用
    if [ -f "$TMATE_INFO" ] && [ -S "$TMATE_SOCK" ]; then
        local rw
        rw=$(grep '^ssh_rw=' "$TMATE_INFO" 2>/dev/null | cut -d= -f2-)
        echo "running|?|${rw}"
        return 0
    fi
    echo "stopped|"
}

uninstall_tmate() {
    stop_tmate
    rm -f "$TMATE_LOG" "$TMATE_INFO" "$CONN_DIR/tmate"
    echo -e "${GREEN}[√] tmate 会话与缓存已清理（系统包未自动卸载）${NC}"
    echo -e "  如需卸包: apt remove tmate / yum remove tmate"
}

run_ttyd_cf() {
    install_ttyd || return 1
    install_cf_local || return 1
    local ttyd_user ttyd_pass ttyd_port TARGET_PORT TTYD_CMD CF_CMD TTYD_PID i URL
    read -p "网页登录账号 [回车=admin]: " ttyd_user
    ttyd_user=${ttyd_user:-admin}
    read -p "网页登录密码 [回车=123456]: " ttyd_pass
    ttyd_pass=${ttyd_pass:-123456}
    read -p "监听端口 [回车=自动从7681找空闲]: " ttyd_port
    ttyd_port=${ttyd_port:-7681}

    stop_ttyd_cf
    TARGET_PORT=$(find_available_port "$ttyd_port")
    if [ "$TARGET_PORT" != "$ttyd_port" ]; then
        echo -e "${YELLOW}[!] 端口 $ttyd_port 占用，改用 $TARGET_PORT${NC}"
    fi
    echo "$TARGET_PORT" > "$CONN_DIR/ttyd.port"

    TTYD_CMD=$(get_ttyd_cmd)
    CF_CMD=$(get_cf_cmd)
    echo -e "${YELLOW}[*] 启动 ttyd :$TARGET_PORT ...${NC}"
    nohup "$TTYD_CMD" -p "$TARGET_PORT" -c "${ttyd_user}:${ttyd_pass}" -W \
        bash -c 'unset PROMPT_COMMAND VSCODE_IPC_HOOK_CLI; exec /bin/bash -i' \
        > "$CONN_DIR/ttyd.log" 2>&1 &
    TTYD_PID=$!
    echo $TTYD_PID > "$CONN_DIR/ttyd.pid"

    local ok=false
    for i in $(seq 1 12); do
        sleep 1; echo -n "."
        kill -0 $TTYD_PID 2>/dev/null || { echo -e "\n${RED}[x] ttyd 退出${NC}"; tail -5 "$CONN_DIR/ttyd.log"; return 1; }
        if ss -tln 2>/dev/null | grep -qE ":${TARGET_PORT}[[:space:]]"; then ok=true; break; fi
    done
    $ok || { echo -e "\n${RED}[x] 端口未监听${NC}"; return 1; }
    echo -e " ${GREEN}ttyd OK${NC}"

    echo -e "${YELLOW}[*] 启动 Cloudflare 快速隧道 (http2)...${NC}"
    nohup "$CF_CMD" tunnel --protocol http2 --url "http://127.0.0.1:${TARGET_PORT}" \
        </dev/null > "$CONN_DIR/cf_ttyd.log" 2>&1 &
    echo $! > "$CONN_DIR/cf_ttyd.pid"

    URL=""
    for i in $(seq 1 20); do
        sleep 1; echo -n "."
        URL=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CONN_DIR/cf_ttyd.log" 2>/dev/null | head -1)
        [ -n "$URL" ] && break
    done
    if [ -z "$URL" ]; then
        echo -e "\n${RED}[x] 快速隧道 URL 获取超时${NC}"
        tail -8 "$CONN_DIR/cf_ttyd.log" 2>/dev/null
        return 1
    fi
    echo -e "\n${GREEN}==================================================${NC}"
    echo -e " ttyd 网页终端已穿透"
    echo -e " 网址: ${YELLOW}$URL${NC}"
    echo -e " 账号: ${CYAN}$ttyd_user${NC}  密码: ${CYAN}$ttyd_pass${NC}  端口: ${CYAN}$TARGET_PORT${NC}"
    echo -e "${GREEN}==================================================${NC}"
}

stop_ttyd_cf() {
    local pid
    for f in ttyd.pid cf_ttyd.pid; do
        if [ -f "$CONN_DIR/$f" ]; then
            pid=$(cat "$CONN_DIR/$f" 2>/dev/null)
            [ -n "$pid" ] && kill "$pid" 2>/dev/null
            [ -n "$pid" ] && pkill -P "$pid" 2>/dev/null || true
            rm -f "$CONN_DIR/$f"
        fi
    done
    # 只杀 quick tunnel，不杀固定隧道
    pkill -f "tunnel --protocol http2 --url http://127.0.0.1:" 2>/dev/null || true
    pkill -f "[t]tyd -p" 2>/dev/null || true
    rm -f "$CONN_DIR/ttyd.port"
}

check_ttyd_status() {
    local port="7681" pid="" cf_pid="" url=""
    [ -f "$CONN_DIR/ttyd.port" ] && port=$(cat "$CONN_DIR/ttyd.port")
    [ -f "$CONN_DIR/ttyd.pid" ] && pid=$(cat "$CONN_DIR/ttyd.pid" 2>/dev/null)
    [ -f "$CONN_DIR/cf_ttyd.pid" ] && cf_pid=$(cat "$CONN_DIR/cf_ttyd.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CONN_DIR/cf_ttyd.log" 2>/dev/null | head -1)
        echo "running|$pid|cf:$cf_pid 端口:$port $url"
    else
        echo "stopped|"
    fi
}

uninstall_ttyd_cf() {
    stop_ttyd_cf
    rm -f "$CONN_DIR/ttyd" "$CONN_DIR/ttyd.log" "$CONN_DIR/cf_ttyd.log" "$CONN_DIR/ttyd.port"
    echo -e "${GREEN}[√] ttyd+CF 快速隧道已清理（不影响固定隧道）${NC}"
}

run_frp() {
    # 先收集参数并校验，再下载/启动（避免网络失败时进不了交互校验）
    local frp_server frp_port local_port remote_port CMD
    echo -e "${CYAN}提示: 需自备 FRP 服务端${NC}"
    read -p "serverAddr: " frp_server
    [ -z "$frp_server" ] && { echo -e "${RED}[x] serverAddr 不能为空${NC}"; return 1; }
    read -p "serverPort [7000]: " frp_port
    frp_port=${frp_port:-7000}
    read -p "本地端口 [22]: " local_port
    local_port=${local_port:-22}
    read -p "远端 remotePort: " remote_port
    [ -z "$remote_port" ] && { echo -e "${RED}[x] remotePort 必填${NC}"; return 1; }

    install_frpc || return 1

    cat > "$CONN_DIR/frpc.toml" <<INNER
serverAddr = "$frp_server"
serverPort = $frp_port

[[proxies]]
name = "tunnel_$(date +%s)"
type = "tcp"
localIP = "127.0.0.1"
localPort = $local_port
remotePort = $remote_port
INNER
    stop_frp
    CMD=$(get_frpc_cmd)
    [ -z "$CMD" ] && { echo -e "${RED}[x] frpc 未就绪${NC}"; return 1; }
    nohup "$CMD" -c "$CONN_DIR/frpc.toml" > "$CONN_DIR/frpc.log" 2>&1 &
    echo $! > "$CONN_DIR/frpc.pid"
    echo -e "${GREEN}==================================================${NC}"
    echo -e " frpc 已后台启动"
    echo -e " 连接: ${CYAN}${frp_server}:${remote_port}${NC} → 本地 ${local_port}"
    echo -e "${GREEN}==================================================${NC}"
}

stop_frp() {
    local pid
    [ -f "$CONN_DIR/frpc.pid" ] && pid=$(cat "$CONN_DIR/frpc.pid" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    pkill -f "[f]rpc -c $CONN_DIR/frpc.toml" 2>/dev/null || true
    rm -f "$CONN_DIR/frpc.pid"
}

check_frp_status() {
    local pid=""
    [ -f "$CONN_DIR/frpc.pid" ] && pid=$(cat "$CONN_DIR/frpc.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "running|$pid|"
    else
        echo "stopped|"
    fi
}

uninstall_frp() {
    stop_frp
    rm -f "$CONN_DIR/frpc" "$CONN_DIR/frpc.toml" "$CONN_DIR/frpc.log" "$CONN_DIR/frp.tar.gz"
    echo -e "${GREEN}[√] FRP 已清理${NC}"
}

# ---------- Tailscale（systemd 正式安装 / s6·容器用户态模式）----------
# 注意：二进制与状态目录不能同名！曾误用 $CONN_DIR/tailscale 既当文件又当目录
TS_BIN_DIR="${TS_BIN_DIR:-$CONN_DIR/bin}"
TS_STATE_DIR="${TS_STATE_DIR:-$CONN_DIR/ts-state}"
TS_SOCK="${TS_SOCK:-$TS_STATE_DIR/tailscaled.sock}"
TS_STATE="${TS_STATE:-$TS_STATE_DIR/tailscaled.state}"
TS_LOG="${TS_LOG:-$TS_STATE_DIR/tailscaled.log}"
TS_PID="${TS_PID:-$TS_STATE_DIR/tailscaled.pid}"
TS_CLI="${TS_BIN_DIR}/tailscale"
TS_DAEMON="${TS_BIN_DIR}/tailscaled"

get_tailscale_cmd() {
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
    elif [ -f "$TS_CLI" ] && [ -x "$TS_CLI" ]; then
        echo "$TS_CLI"
    elif [ -f "$CONN_DIR/bin/tailscale" ] && [ -x "$CONN_DIR/bin/tailscale" ]; then
        echo "$CONN_DIR/bin/tailscale"
    else
        echo ""
    fi
}

get_tailscaled_cmd() {
    if command -v tailscaled >/dev/null 2>&1; then
        command -v tailscaled
    elif [ -f "$TS_DAEMON" ] && [ -x "$TS_DAEMON" ]; then
        echo "$TS_DAEMON"
    elif [ -f "$CONN_DIR/bin/tailscaled" ] && [ -x "$CONN_DIR/bin/tailscaled" ]; then
        echo "$CONN_DIR/bin/tailscaled"
    else
        echo ""
    fi
}

# 无包管理/无 systemd 时下载官方静态包到 CONN_DIR/bin
install_tailscale_static() {
    local arch ver="1.80.3" url tgz d
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armhf) arch="arm" ;;
        *) echo -e "${RED}[x] 不支持架构: $(uname -m)${NC}"; return 1 ;;
    esac
    mkdir -p "$CONN_DIR" "$TS_BIN_DIR" "$TS_STATE_DIR"
    # 若旧版误把状态目录建在 $CONN_DIR/tailscale，且它是目录，不要往那里 cp 二进制
    if [ -d "$CONN_DIR/tailscale" ] && [ ! -f "$CONN_DIR/tailscale" ]; then
        echo -e "${YELLOW}[i] 发现旧目录 $CONN_DIR/tailscale（状态残留），二进制将装到 $TS_BIN_DIR/${NC}"
    fi
    tgz="$CONN_DIR/tailscale_${ver}_${arch}.tgz"
    url="https://pkgs.tailscale.com/stable/tailscale_${ver}_${arch}.tgz"
    echo -e "${YELLOW}[*] 下载 Tailscale 静态包 ${ver} (${arch})...${NC}"
    if ! curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$tgz"; then
        echo -e "${RED}[x] 下载失败: $url${NC}"
        return 1
    fi
    tar -xzf "$tgz" -C "$CONN_DIR" 2>/dev/null || { echo -e "${RED}[x] 解压失败${NC}"; return 1; }
    d=$(find "$CONN_DIR" -maxdepth 1 -type d -name "tailscale_*_${arch}" 2>/dev/null | head -1)
    if [ -z "$d" ]; then
        d=$(find "$CONN_DIR" -maxdepth 2 -type f -name tailscaled 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    fi
    if [ -n "$d" ] && [ -f "$d/tailscaled" ]; then
        cp -f "$d/tailscale" "$TS_CLI"
        cp -f "$d/tailscaled" "$TS_DAEMON"
        chmod +x "$TS_CLI" "$TS_DAEMON"
        echo -e "${GREEN}[√] 已安装: $TS_CLI 与 $TS_DAEMON${NC}"
        return 0
    fi
    echo -e "${RED}[x] 包内未找到 tailscaled${NC}"
    return 1
}

ensure_tailscale_bins() {
    if [ -n "$(get_tailscale_cmd)" ] && [ -n "$(get_tailscaled_cmd)" ]; then
        return 0
    fi
    echo -e "${YELLOW}[*] 安装 Tailscale...${NC}"
    if [ "${HAS_SYSTEMD:-false}" = true ] || [ "$(detect_init 2>/dev/null)" = "systemd" ]; then
        if curl -fsSL https://tailscale.com/install.sh | as_root sh; then
            [ -n "$(get_tailscale_cmd)" ] && [ -n "$(get_tailscaled_cmd)" ] && return 0
        fi
    fi
    install_tailscale_static || return 1
    [ -n "$(get_tailscale_cmd)" ] && [ -n "$(get_tailscaled_cmd)" ]
}

# 用户态网络：无需 /dev/net/tun、无需 systemd
start_tailscaled_userspace() {
    local daemon ts
    daemon=$(get_tailscaled_cmd)
    ts=$(get_tailscale_cmd)
    if [ -z "$daemon" ] || [ -z "$ts" ]; then
        echo -e "${RED}[x] 未找到 tailscale/tailscaled 可执行文件${NC}"
        echo -e "  期望: $TS_CLI 与 $TS_DAEMON"
        return 1
    fi
    if [ -d "$daemon" ] || [ -d "$ts" ]; then
        echo -e "${RED}[x] 路径是目录而非二进制: ts=$ts daemon=$daemon${NC}"
        echo -e "  请: rm -rf $CONN_DIR/tailscale 后菜单 7→4 清理再 7→1 重装"
        return 1
    fi
    mkdir -p "$TS_STATE_DIR"
    if [ -f "$TS_PID" ] && kill -0 "$(cat "$TS_PID" 2>/dev/null)" 2>/dev/null; then
        echo -e "${GREEN}[√] tailscaled 已在运行 (userspace) PID=$(cat "$TS_PID")${NC}"
        return 0
    fi
    pkill -f "tailscaled.*${TS_STATE}" 2>/dev/null || true
    pkill -f 'tailscaled.*userspace-networking' 2>/dev/null || true
    sleep 0.5
    echo -e "${YELLOW}[*] 启动 tailscaled（userspace-networking，适配 s6/容器）${NC}"
    echo -e "  daemon=$daemon"
    nohup "$daemon" \
        --state="$TS_STATE" \
        --socket="$TS_SOCK" \
        --tun=userspace-networking \
        >>"$TS_LOG" 2>&1 &
    echo $! >"$TS_PID"
    sleep 2
    if kill -0 "$(cat "$TS_PID" 2>/dev/null)" 2>/dev/null; then
        echo -e "${GREEN}[√] tailscaled PID=$(cat "$TS_PID") 日志 $TS_LOG${NC}"
        return 0
    fi
    echo -e "${RED}[x] tailscaled 启动失败，见 $TS_LOG${NC}"
    tail -20 "$TS_LOG" 2>/dev/null || true
    return 1
}

run_tailscale() {
    refresh_env_flags
    if [ "$HAS_SUDO" != true ] && [ "$EUID" -ne 0 ] && [ ! -w "$CONN_DIR" ]; then
        echo -e "${RED}[x] 需要 root/sudo，或可写目录 $CONN_DIR${NC}"
        return 1
    fi

    ensure_tailscale_bins || {
        echo -e "${RED}[x] Tailscale 安装失败${NC}"
        return 1
    }

    local ts daemon use_userspace=0 up_log auth_url authkey
    ts=$(get_tailscale_cmd)
    daemon=$(get_tailscaled_cmd)
    up_log="${TS_STATE_DIR}/tailscale-up.log"
    mkdir -p "$TS_STATE_DIR"

    # 有 systemd 且能 systemctl：走官方服务
    if [ "${HAS_SYSTEMD:-false}" = true ] && command -v systemctl >/dev/null 2>&1 \
       && [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        echo -e "${CYAN}[*] 检测到 systemd，使用系统 tailscaled 服务${NC}"
        as_root systemctl enable --now tailscaled 2>/dev/null || as_root systemctl start tailscaled 2>/dev/null || true
        sleep 1
        if ! pgrep -x tailscaled >/dev/null 2>&1; then
            echo -e "${YELLOW}[!] systemctl 未拉起 tailscaled，改用用户态模式${NC}"
            use_userspace=1
        fi
    else
        echo -e "${CYAN}[*] 当前 init=$(detect_init 2>/dev/null || echo ?)（非 systemd），使用用户态 Tailscale${NC}"
        use_userspace=1
    fi

    # 无图形浏览器：编号菜单 1/2/0（不要用 A/B 或把字母当 Auth Key）
    authkey="${TS_AUTHKEY:-}"
    auth_mode=""
    if [ -n "$authkey" ]; then
        auth_mode="key"
        echo -e "${CYAN}[*] 检测到环境变量 TS_AUTHKEY，将用 Auth Key 登录${NC}"
    else
        echo -e "${CYAN}--------------------------------------------------${NC}"
        echo -e " 服务器/容器 ${YELLOW}无法自动打开浏览器${NC}，请选择："
        echo -e "  ${GREEN}1.${NC} 网页链接登录（生成 https://login.tailscale.com/... 用手机/电脑打开）"
        echo -e "  ${GREEN}2.${NC} Auth Key 登录（控制台创建: login.tailscale.com/admin/settings/keys）"
        echo -e "  ${RED}0.${NC} 返回"
        echo -e "${CYAN}--------------------------------------------------${NC}"
        printf '%s' "请选择 [0-2]: "
        read -r ts_choice || true
        case "${ts_choice:-}" in
            1)
                auth_mode="url"
                ;;
            2)
                auth_mode="key"
                printf '%s' "请粘贴 Auth Key (tskey-auth-...): "
                read -r authkey || true
                authkey=$(echo "$authkey" | tr -d '[:space:]')
                if [ -z "$authkey" ]; then
                    echo -e "${RED}[x] Auth Key 为空，已取消${NC}"
                    return 1
                fi
                if [[ ! "$authkey" =~ ^tskey- ]]; then
                    echo -e "${YELLOW}[!] 密钥通常以 tskey- 开头，仍将尝试...${NC}"
                fi
                ;;
            0|"")
                echo -e "${GREEN}已返回${NC}"
                return 0
                ;;
            *)
                echo -e "${RED}无效选项，请输入 0 / 1 / 2${NC}"
                return 1
                ;;
        esac
    fi

    : >"$up_log"
    if [ "$use_userspace" -eq 1 ]; then
        start_tailscaled_userspace || return 1
        echo -e "${YELLOW}[*] tailscale up（socket=$TS_SOCK）...${NC}"
        if [ "$auth_mode" = "key" ]; then
            echo -e "${CYAN}[*] 使用 Auth Key 登录（无需浏览器）${NC}"
            "$ts" --socket="$TS_SOCK" up --authkey="$authkey" --accept-dns=false >>"$up_log" 2>&1 || true
        else
            # 网页链接模式：后台跑 up，提取 login URL
            echo -e "${CYAN}[*] 正在申请登录链接（约数秒）...${NC}"
            "$ts" --socket="$TS_SOCK" up --accept-dns=false --timeout=60s >>"$up_log" 2>&1 &
            local up_pid=$!
            local i=0
            auth_url=""
            while [ $i -lt 25 ]; do
                sleep 1
                i=$((i + 1))
                auth_url=$(grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9/_\-?=&%]+' "$up_log" 2>/dev/null | tail -1)
                [ -n "$auth_url" ] && break
                if "$ts" --socket="$TS_SOCK" status 2>/dev/null | grep -qiE 'Running|idle'; then
                    break
                fi
            done
            if [ -n "$auth_url" ]; then
                echo ""
                echo -e "${GREEN}==================================================${NC}"
                echo -e " ${BOLD}请用手机或电脑浏览器打开下面链接登录：${NC}"
                echo -e " ${YELLOW}${auth_url}${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo -e " 登录完成后回到本窗口等待（最多约 2 分钟）..."
                echo "$auth_url" >"${TS_STATE_DIR}/login.url"
                echo -e " 链接已保存: ${TS_STATE_DIR}/login.url"
                echo -e " 查看: ${BOLD}cat ${TS_STATE_DIR}/login.url${NC}"
            else
                echo -e "${YELLOW}[!] 未解析到登录 URL，完整输出:${NC}"
                cat "$up_log" 2>/dev/null | tail -30
                echo -e " 也可手动: ${BOLD}$ts --socket=$TS_SOCK up${NC}"
            fi
            i=0
            while [ $i -lt 90 ]; do
                sleep 2
                i=$((i + 1))
                if [ -n "$("$ts" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1)" ]; then
                    break
                fi
                if ! kill -0 "$up_pid" 2>/dev/null; then
                    auth_url=$(grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9/_\-?=&%]+' "$up_log" 2>/dev/null | tail -1)
                    if [ -n "$auth_url" ]; then
                        echo -e " 登录链接: ${YELLOW}${auth_url}${NC}"
                        echo "$auth_url" >"${TS_STATE_DIR}/login.url"
                    fi
                    break
                fi
                printf '.'
            done
            echo
            kill "$up_pid" 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}[*] tailscale up ...${NC}"
        if [ "$auth_mode" = "key" ]; then
            echo -e "${CYAN}[*] 使用 Auth Key 登录（无需浏览器）${NC}"
            as_root tailscale up --authkey="$authkey" >>"$up_log" 2>&1 \
              || as_root "$ts" up --authkey="$authkey" >>"$up_log" 2>&1 || true
        else
            echo -e "${CYAN}[*] 正在申请登录链接（约数秒）...${NC}"
            if [ -t 0 ]; then
                as_root tailscale up 2>&1 | tee -a "$up_log" || as_root "$ts" up 2>&1 | tee -a "$up_log" || true
            else
                as_root tailscale up >>"$up_log" 2>&1 || as_root "$ts" up >>"$up_log" 2>&1 || true
            fi
            auth_url=$(grep -oE 'https://login\.tailscale\.com/[a-zA-Z0-9/_\-?=&%]+' "$up_log" 2>/dev/null | tail -1)
            if [ -n "$auth_url" ]; then
                echo ""
                echo -e "${GREEN}==================================================${NC}"
                echo -e " ${BOLD}请用手机或电脑浏览器打开：${NC}"
                echo -e " ${YELLOW}${auth_url}${NC}"
                echo -e "${GREEN}==================================================${NC}"
                echo "$auth_url" >"${TS_STATE_DIR}/login.url"
                echo -e " 链接已保存: ${TS_STATE_DIR}/login.url"
            else
                echo -e "${YELLOW}[!] 若未登录成功，请看: cat $up_log${NC}"
            fi
        fi
    fi

    local IP="" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if [ "$use_userspace" -eq 1 ]; then
            IP=$("$ts" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1)
        else
            IP=$(tailscale ip -4 2>/dev/null | head -1)
            [ -z "$IP" ] && IP=$("$ts" ip -4 2>/dev/null | head -1)
        fi
        [ -n "$IP" ] && break
        sleep 2
    done

    echo -e "${GREEN}==================================================${NC}"
    if [ -n "$IP" ]; then
        echo -e " Tailscale 已上线"
        echo -e " 内网 IP: ${YELLOW}${IP}${NC}"
        [ "$use_userspace" -eq 1 ] && echo -e " 模式: ${CYAN}userspace-networking${NC}（适合 s6/容器）"
        echo -e " 电脑装 Tailscale 后: ${BOLD}ssh 用户@${IP}${NC}"
    else
        echo -e " ${YELLOW}尚未拿到 Tailscale IP（多半还没在浏览器完成登录）${NC}"
        if [ -f "${TS_STATE_DIR}/login.url" ]; then
            echo -e " 登录链接: ${YELLOW}$(cat "${TS_STATE_DIR}/login.url")${NC}"
        fi
        if [ "$use_userspace" -eq 1 ]; then
            echo -e " 登录后检查: ${BOLD}$ts --socket=$TS_SOCK status${NC}"
            echo -e "            ${BOLD}$ts --socket=$TS_SOCK ip -4${NC}"
        else
            echo -e " 登录后检查: ${BOLD}tailscale status${NC} / ${BOLD}tailscale ip -4${NC}"
        fi
        echo -e " 免浏览器: 控制台创建 Auth Key 后:"
        echo -e "   ${BOLD}export TS_AUTHKEY='tskey-auth-xxxx'${NC}"
        echo -e "   再菜单 7→1 重试"
    fi
    echo -e "${GREEN}==================================================${NC}"
}

stop_tailscale() {
    local ts
    ts=$(get_tailscale_cmd)
    if [ -n "$ts" ] && [ -S "$TS_SOCK" ]; then
        "$ts" --socket="$TS_SOCK" down 2>/dev/null || true
    fi
    if command -v tailscale >/dev/null 2>&1; then
        as_root tailscale down 2>/dev/null || true
    fi
    if [ -f "$TS_PID" ]; then
        kill "$(cat "$TS_PID" 2>/dev/null)" 2>/dev/null || true
        rm -f "$TS_PID"
    fi
    pkill -f 'tailscaled.*userspace-networking' 2>/dev/null || true
    echo -e "${GREEN}[√] 已尝试关闭 Tailscale${NC}"
}

check_tailscale_status() {
    local ip="" pid="" ts
    ts=$(get_tailscale_cmd)
    if [ -n "$ts" ] && [ -S "$TS_SOCK" ]; then
        ip=$("$ts" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1)
        pid=$(cat "$TS_PID" 2>/dev/null || pgrep -f 'tailscaled.*userspace' | head -1)
    fi
    if [ -z "$ip" ]; then
        ip=$(tailscale ip -4 2>/dev/null | head -1)
        pid=$(pgrep -x tailscaled | head -1)
    fi
    if [ -n "$ip" ]; then
        echo "running|${pid:-?}|Tailscale IP: $ip"
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "running|$pid|已启动未拿 IP（请完成登录）"
    else
        echo "stopped|"
    fi
}

uninstall_tailscale() {
    stop_tailscale
    if command -v systemctl >/dev/null 2>&1 && [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        as_root systemctl stop tailscaled 2>/dev/null || true
        as_root systemctl disable tailscaled 2>/dev/null || true
    fi
    # 清理二进制（新路径）与旧错误路径（曾把二进制/状态都叫 tailscale）
    rm -f "$TS_CLI" "$TS_DAEMON" "$CONN_DIR/tailscaled" "$TS_PID"
    # 若 $CONN_DIR/tailscale 是文件则删；若是目录则整目录删（旧 bug 残留）
    if [ -f "$CONN_DIR/tailscale" ]; then
        rm -f "$CONN_DIR/tailscale"
    elif [ -d "$CONN_DIR/tailscale" ]; then
        rm -rf "$CONN_DIR/tailscale"
    fi
    rm -rf "$TS_STATE_DIR"
    echo -e "${GREEN}[√] 已清理用户态 Tailscale 文件${NC}"
    echo -e "  二进制: $TS_BIN_DIR/"
    echo -e "  状态:   $TS_STATE_DIR/"
    echo -e "${YELLOW}[i] 系统包安装的请用: apt remove tailscale${NC}"
}


manage_connection() {
    local name="$1" status_fn="$2" start_fn="$3" stop_fn="$4" uninstall_fn="$5"
    while true; do
        local status_line state pid extra
        status_line=$($status_fn)
        state=$(echo "$status_line" | cut -d'|' -f1)
        echo -e "\n${CYAN}====================================================${NC}"
        echo -e "${CYAN}  $name${NC}"
        echo -e "${CYAN}====================================================${NC}"
        if [ "$state" = "running" ]; then
            pid=$(echo "$status_line" | cut -d'|' -f2)
            extra=$(echo "$status_line" | cut -d'|' -f3-)
            echo -e " ${GREEN}[●] 已连接  PID: $pid${NC}"
            [ -n "$extra" ] && [ "$extra" != "|" ] && echo -e " ${CYAN}$extra${NC}"
        else
            echo -e " ${YELLOW}[○] 未连接${NC}"
        fi
        echo -e "  ${GREEN}1.${NC} 新建连接"
        echo -e "  ${GREEN}2.${NC} 关闭连接"
        echo -e "  ${GREEN}3.${NC} 查看详情"
        echo -e "  ${GREEN}4.${NC} 清理卸载"
        echo -e "  ${RED}0.${NC} 返回"
        echo -e "${CYAN}====================================================${NC}"
        read -p "请选择 [0-4]: " sub_choice
        case $sub_choice in
            1) $start_fn ;;
            2)
                if [ "$state" = "running" ]; then
                    $stop_fn
                    echo -e "${GREEN}[√] 已关闭${NC}"
                else
                    echo -e "${YELLOW}[!] 当前未连接${NC}"
                fi ;;
            3)
                if [ "$state" = "running" ]; then
                    pid=$(echo "$status_line" | cut -d'|' -f2)
                    echo -e " 状态: ${GREEN}运行中${NC}  PID: $pid"
                    ps -p "$pid" -o cmd= 2>/dev/null | sed 's/^/  进程: /'
                    extra=$(echo "$status_line" | cut -d'|' -f3-)
                    [ -n "$extra" ] && [ "$extra" != "|" ] && echo -e "  附加: $extra"
                    for lf in "$CONN_DIR/sshx.log" "$CONN_DIR/ttyd.log" "$CONN_DIR/cf_ttyd.log" \
                              "$CONN_DIR/frpc.log"; do
                        if [ -f "$lf" ]; then
                            echo -e "  日志 $(basename "$lf") 末5行:"
                            tail -5 "$lf" | sed 's/^/    /'
                            break
                        fi
                    done
                else
                    echo -e "${YELLOW}[!] 当前未连接${NC}"
                fi
                read -p "回车继续..." ;;
            4)
                echo -e "${YELLOW}[*] 清理 $name ...${NC}"
                $uninstall_fn
                read -p "回车返回上级..."
                break ;;
            0) break ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# ==========================================
# 主菜单循环（诊断 + 固定隧道 + 连接穿透 平铺）
# ==========================================
# 权限兼容：root 直接跑；非 root 有 sudo 则自动提权重跑；无 sudo 仍可做只读诊断
ensure_priv_or_reexec "$@"
refresh_env_flags 2>/dev/null || true

while true; do
    refresh_env_flags 2>/dev/null || true
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${CYAN}      Linux 服务器端口与穿透诊断工具箱${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -n "  权限: "
    if is_root; then
        echo -ne "${GREEN}root（直接执行）${NC}"
    elif command -v sudo >/dev/null 2>&1; then
        echo -ne "${YELLOW}用户+sudo${NC}"
    else
        echo -ne "${RED}普通用户（无 sudo）${NC}"
    fi
    echo -n "  | 环境: "
    if [ "${HAS_SYSTEMD:-false}" = true ] && [ "${HAS_SUDO:-false}" = true ]; then
        echo -e "${GREEN}标准 VPS (全功能)${NC}"
    else
        echo -e "${YELLOW}轻量/容器 (init=$(detect_init 2>/dev/null || echo ?))${NC}"
    fi
    echo -e "----------------------------------------------------"
    echo -e "  ${GREEN}1.${NC} 检查 Root 权限与 sudo 环境"
    echo -e "  ${GREEN}2.${NC} 检查内部端口 (本机监听)     ${CYAN}[无需root]${NC}"
    echo -e "  ${GREEN}3.${NC} 本机端口诊断 (ss+nmap)      ${CYAN}[无需root*]${NC}"
    echo -e "----------------------------------------------------"
    echo -e "  ${YELLOW}4.${NC} CF 固定隧道管理             ${RED}[须root]${NC}"
    echo -e "  ${YELLOW}5.${NC} 网页 sshx.io 零配置终端     ${CYAN}[无需root]${NC}"
    echo -e "  ${YELLOW}6.${NC} 网页 ttyd + CF 快速隧道     ${CYAN}[无需root*]${NC}"
    echo -e "  ${YELLOW}7.${NC} Tailscale 组网              ${CYAN}[s6可用·用户态]${NC}"
    echo -e "  ${YELLOW}8.${NC} FRP 端口转发                ${CYAN}[无需root*]${NC}"
    echo -e "  ${YELLOW}9.${NC} tmate 终端共享              ${CYAN}[无需root]${NC}"
    echo -e "  ${RED}0.${NC} 退出工具"
    echo -e "${CYAN}====================================================${NC}"
    echo -e "  ${CYAN}* 用户态: 二进制在 ~/.1sh-conn；[须root] 写系统/装服务${NC}"

    read -p "请输入选项数字 [0-9]: " choice

    case $choice in
        1) check_and_install_sudo ;;
        2) check_internal_ports ;;
        3) check_external_ports ;;
        4) if need_root_action "CF 固定隧道管理"; then cf_tunnel_menu; fi ;;
        5) manage_connection "sshx.io" check_sshx_status run_sshx stop_sshx uninstall_sshx ;;
        6) manage_connection "ttyd + CF 快速隧道" check_ttyd_status run_ttyd_cf stop_ttyd_cf uninstall_ttyd_cf ;;
        7) if need_root_action "Tailscale"; then manage_connection "Tailscale" check_tailscale_status run_tailscale stop_tailscale uninstall_tailscale; fi ;;
        8) manage_connection "FRP" check_frp_status run_frp stop_frp uninstall_frp ;;
        9) manage_connection "tmate 终端共享" check_tmate_status run_tmate stop_tmate uninstall_tmate ;;
        0) echo -e "${GREEN}感谢使用，已退出！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0 到 9 之间的数字。${NC}" ;;
    esac

    # 带内部循环的管理面板自己有回车等待
    case $choice in
        4|5|6|7|8|9) ;;
        *)
            echo -e "\n${YELLOW}----------------------------------------------------${NC}"
            read -p "按 【回车键】 返回主菜单..."
            ;;
    esac
done

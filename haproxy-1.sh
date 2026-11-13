#!/bin/bash
#
# HAProxy Manager - Advanced TCP Forwarding Manager
# Supports IPv4 / IPv6 / Dual-Stack, per-rule management, validation, backup
#

# ============================================================
#  COLORS & GLOBALS
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/haproxy/haproxy.cfg"
BACKUP_DIR="/etc/haproxy/backups"
LOG_FILE="/var/log/haproxy.log"

# متغیر سراسری برای ذخیره حالت انتخاب شده (رفع باگ)
SELECTED_BIND_MODE=""

# ============================================================
#  HELPERS
# ============================================================
require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}This script must be run as root.${NC}" 1>&2
        exit 1
    fi
}

ensure_deps() {
    if ! command -v haproxy &>/dev/null; then
        echo -e "${YELLOW}HAProxy not found. Installing...${NC}"
        apt-get update -qq && apt-get install -y haproxy || {
            echo -e "${RED}Failed to install HAProxy.${NC}"; exit 1; }
    fi
    if ! command -v jq &>/dev/null; then
        apt-get update -qq && apt-get install -y jq >/dev/null 2>&1
    fi
    mkdir -p "$BACKUP_DIR"
}

pause() { read -p "Press Enter to continue..." _; }

confirm() {
    local msg="$1"
    read -p "$msg (yes/no): " ans
    [[ "$ans" == "yes" || "$ans" == "Yes" || "$ans" == "YES" ]]
}

# ============================================================
#  HEADER / STATUS
# ============================================================
show_logo() {
    echo -e "${BLUE}"
cat << "EOF"
    __  _____    ____
   / / / /   |  / __ \_________  _  ____  __
  / /_/ / /| | / /_/ / ___/ __ \| |/_/ / / /
 / __  / ___ |/ ____/ /  / /_/ />  </ /_/ /
/_/ /_/_/  |_/_/   /_/   \____/_/|_|\__, /
                                   /____/
        HAProxy Manager  |  v2.5
EOF
    echo -e "${NC}"
}

show_status() {
    if systemctl is-active --quiet haproxy; then
        echo -e "Service : ${GREEN}ACTIVE${NC}"
    else
        echo -e "Service : ${RED}INACTIVE${NC}"
    fi
    if command -v haproxy &>/dev/null; then
        local ver
        ver=$(haproxy -v 2>/dev/null | head -n1)
        echo -e "Version : ${CYAN}${ver}${NC}"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        local n
        n=$(grep -c '^frontend ' "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo -e "Rules   : ${MAGENTA}${n}${NC}"
    else
        echo -e "Rules   : ${YELLOW}no config${NC}"
    fi
}

# ============================================================
#  CONFIG FILE MANAGEMENT
# ============================================================
backup_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp "$CONFIG_FILE" "$BACKUP_DIR/haproxy.cfg.$ts"
    ls -1t "$BACKUP_DIR"/haproxy.cfg.* 2>/dev/null | tail -n +21 | xargs -r rm -f
}

write_base_config() {
    backup_config
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" << 'EOF'
# HAProxy configuration - managed by haproxy-manager.sh
global
    log /dev/log    local0
    log /dev/log    local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms
EOF
}

ensure_base_config() {
    if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^global' "$CONFIG_FILE"; then
        write_base_config
    fi
}

# ============================================================
#  VALIDATION
# ============================================================
validate_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file not found.${NC}"
        return 1
    fi
    if haproxy -c -f "$CONFIG_FILE" >/tmp/haproxy-check.log 2>&1; then
        echo -e "${GREEN}Config is valid.${NC}"
        return 0
    else
        echo -e "${RED}Config is INVALID:${NC}"
        grep -E 'ALERT|ERROR|Fatal' /tmp/haproxy-check.log
        return 1
    fi
}

apply_and_restart() {
    local old
    old=$(mktemp)
    cp "$CONFIG_FILE" "$old" 2>/dev/null

    if ! validate_config; then
        echo -e "${YELLOW}Restoring previous config...${NC}"
        [ -s "$old" ] && cp "$old" "$CONFIG_FILE"
        rm -f "$old"
        pause
        return 1
    fi
    rm -f "$old"

    if systemctl restart haproxy; then
        echo -e "${GREEN}HAProxy restarted successfully.${NC}"
        return 0
    else
        echo -e "${RED}Failed to restart HAProxy. Check logs with option 7.${NC}"
        return 1
    fi
}

# ============================================================
#  BIND ADDRESS RESOLUTION
# ============================================================
build_bind_line() {
    local mode="$1" port="$2"
    case "$mode" in
        ipv6) echo "    bind [::]:$port v6only" ;;
        dual) echo "    bind [::]:$port" ;;
        *)    echo "    bind *:$port" ;;
    esac
}

# $1 = port
# این تابع مستقیماً متغیر سراسری SELECTED_BIND_MODE را تنظیم می‌کند
prompt_bind_mode() {
    local port="$1"
    SELECTED_BIND_MODE="" # ریست کردن

    local v4_busy=0 v6_busy=0
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q '0.0.0.0:'"$port" && v4_busy=1
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q '\[::\]:'"$port" && v6_busy=1

    echo ""
    echo -e "${BOLD}--- Select listen mode for port :$port ---${NC}"
    echo -e "${GREEN}1) IPv4 only${NC}   (bind *:$port)"
    echo -e "${BLUE}2) IPv6 only${NC}   (bind [::]:$port v6only)"
    echo -e "${MAGENTA}3) Dual-Stack${NC}  (bind [::]:$port)"
    echo ""

    echo -e "${BOLD}Current status:${NC}"
    [ "$v4_busy" -eq 1 ] && echo -e "  IPv4: ${RED}IN USE${NC}" || echo -e "  IPv4: ${GREEN}free${NC}"
    [ "$v6_busy" -eq 1 ] && echo -e "  IPv6: ${RED}IN USE${NC}" || echo -e "  IPv6: ${GREEN}free${NC}"
    echo ""

    local recommend=1 reason=""
    if [ "$v4_busy" -eq 1 ] && [ "$v6_busy" -eq 0 ]; then
        recommend=2; reason="IPv4 busy, IPv6 free -> Option 2 is recommended."
    elif [ "$v4_busy" -eq 0 ] && [ "$v6_busy" -eq 0 ]; then
        recommend=1; reason="Port free -> Option 1 is simplest."
    elif [ "$v4_busy" -eq 1 ] && [ "$v6_busy" -eq 1 ]; then
        echo -e "${RED}Both IPv4 and IPv6 are in use.${NC}"
        echo -e "${YELLOW}You should choose a different bind port.${NC}\n"
        recommend=0
    fi
    [ -n "$reason" ] && echo -e "${GREEN}Recommendation:${NC} $reason\n"

    local m
    read -p "Choice [1-3, default ${recommend:-1}]: " m
    m="${m:-${recommend:-1}}"

    case "$m" in
        2)
            if [ "$v6_busy" -eq 1 ]; then
                echo -e "${RED}IPv6 port $port is already in use. Choose another port.${NC}"
                pause; return 1
            fi
            SELECTED_BIND_MODE="ipv6"
            return 0
            ;;
        3)
            if [ "$v4_busy" -eq 1 ] || [ "$v6_busy" -eq 1 ]; then
                echo -e "${RED}Dual-Stack requires the port to be completely free.${NC}"
                echo -e "${YELLOW}IPv4 busy=$v4_busy  IPv6 busy=$v6_busy${NC}"
                confirm "Continue anyway? (HAProxy will likely fail)" || { pause; return 1; }
            fi
            SELECTED_BIND_MODE="dual"
            return 0
            ;;
        *)
            if [ "$v4_busy" -eq 1 ]; then
                echo -e "${RED}IPv4 port $port is already in use.${NC}"
                echo -e "${YELLOW}Tip: choose mode 2 (IPv6 only) or another port.${NC}"
                pause; return 1
            fi
            SELECTED_BIND_MODE="ipv4"
            return 0
            ;;
    esac
}

# ============================================================
#  ADD RULE
# ============================================================
add_rule() {
    clear
    ensure_base_config
    echo -e "${BOLD}=== Add new forwarding rule ===${NC}\n"
    
    echo -e "${YELLOW}Note - Listen Modes Explained:${NC}"
    echo -e "  ${GREEN}1) IPv4 only${NC}  (bind *:PORT)"
    echo -e "     Only IPv4 clients. Fails if an IPv4 service uses PORT."
    echo -e "  ${BLUE}2) IPv6 only${NC}  (bind [::]:PORT v6only)"
    echo -e "     Only IPv6 clients. Use if PORT is used by IPv4 (e.g. kariz)."
    echo -e "  ${MAGENTA}3) Dual-Stack${NC} (bind [::]:PORT)"
    echo -e "     Both IPv4 & IPv6. Fails if PORT is used on either stack."
    echo ""

    local bport
    read -p "Bind port (HAProxy listens here): " bport
    [[ "$bport" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid port.${NC}"; pause; return 1; }

    if [ -f "$CONFIG_FILE" ] && grep -q "frontend frontend_$bport" "$CONFIG_FILE"; then
        echo -e "${RED}A rule with bind port $bport already exists.${NC}"; pause; return 1
    fi

    # فراخوانی تابع (دیگر از $(...) استفاده نمی‌کنیم)
    prompt_bind_mode "$bport" || return 1

    local bmode="$SELECTED_BIND_MODE"
    
    # چک ایمنی: اگر به هر دلیلی حالت خالی بود، به ipv4 برمی‌گردیم
    if [ -z "$bmode" ]; then
        echo -e "${RED}Error: bind mode was not selected. Defaulting to IPv4.${NC}"
        bmode="ipv4"
    fi

    local dip dport
    read -p "Destination IP (backend): " dip
    read -p "Destination port (backend): " dport
    [[ "$dport" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid destination port.${NC}"; pause; return 1; }

    {
        echo ""
        echo "frontend frontend_$bport"
        build_bind_line "$bmode" "$bport"
        echo "    mode tcp"
        echo "    default_backend backend_$bport"
        echo ""
        echo "backend backend_$bport"
        echo "    mode tcp"
        echo "    server server_$bport $dip:$dport"
    } >> "$CONFIG_FILE"

    echo ""
    apply_and_restart
    echo ""
    echo -e "${GREEN}Rule added:${NC} [$bmode] :$bport  ->  $dip:$dport"
    pause
}

# ============================================================
#  LIST RULES
# ============================================================
list_rules() {
    clear
    echo -e "${BOLD}=== Current forwarding rules ===${NC}\n"
    if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^frontend ' "$CONFIG_FILE"; then
        echo -e "${YELLOW}No rules defined.${NC}"
        pause; return
    fi

    local -a names binds backends
    local fname bindline backend
    while IFS= read -r line; do
        if [[ "$line" =~ ^frontend[[:space:]]+([^[:space:]]+) ]]; then
            fname="${BASH_REMATCH[1]}"
            bindline="?"
            backend="?"
        elif [[ "$line" =~ ^[[:space:]]+bind[[:space:]]+(.+) ]]; then
            bindline="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+default_backend[[:space:]]+([^[:space:]]+) ]]; then
            backend="${BASH_REMATCH[1]}"
            names+=("$fname"); binds+=("$bindline"); backends+=("$backend")
        fi
    done < "$CONFIG_FILE"

    local i
    printf "%-4s %-18s %-25s %-15s %s\n" "#" "FRONTEND" "BIND" "BACKEND" "DESTINATION"
    echo "--------------------------------------------------------------------------------"
    for i in "${!names[@]}"; do
        local be="${backends[$i]}"
        local dest
        dest=$(awk -v be="$be" '
            $1=="backend" && $2==be {inb=1; next}
            inb && $1=="server" {print $3; exit}
            inb && $1=="backend" {exit}
        ' "$CONFIG_FILE")
        printf "%-4s %-18s %-25s %-15s %s\n" \
            "$((i+1))" "${names[$i]}" "${binds[$i]}" "$be" "$dest"
    done
    echo ""
    pause
}

# ============================================================
#  DELETE ONE RULE
# ============================================================
delete_rule() {
    clear
    echo -e "${BOLD}=== Delete a rule ===${NC}\n"
    if [ ! -f "$CONFIG_FILE" ] || ! grep -q '^frontend ' "$CONFIG_FILE"; then
        echo -e "${YELLOW}No rules to delete.${NC}"; pause; return
    fi

    local -a names
    mapfile -t names < <(grep '^frontend ' "$CONFIG_FILE" | awk '{print $2}')
    local i
    for i in "${!names[@]}"; do
        echo "  $((i+1))) ${names[$i]}"
    done
    echo "  0) Cancel"
    local sel
    read -p "Select number to delete: " sel
    [[ "$sel" == "0" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#names[@]}" ]; then
        echo -e "${RED}Invalid selection.${NC}"; pause; return
    fi

    local fname="${names[$((sel-1))]}"
    local be
    be=$(awk -v f="$fname" '
        $1=="frontend" && $2==f {inf=1; next}
        inf && $1=="default_backend" {print $2; exit}
        inf && $1=="frontend" {exit}
    ' "$CONFIG_FILE")

    echo -e "Will delete: ${YELLOW}$fname${NC} and backend ${YELLOW}$be${NC}"
    confirm "Are you sure?" || return

    awk -v f="$fname" -v b="$be" '
        BEGIN {skip=0}
        /^frontend / { if ($2==f) {skip=1; next} else skip=0 }
        /^backend /  { if ($2==b) {skip=1; next} else skip=0 }
        /^[^[:space:]]/ { if (skip && $1!="frontend" && $1!="backend") skip=0 }
        skip==0 {print}
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    echo ""
    apply_and_restart
    echo -e "${GREEN}Deleted $fname.${NC}"
    pause
}

# ============================================================
#  FULL RESET
# ============================================================
destroy_all() {
    clear
    echo -e "${RED}${BOLD}=== Stop HAProxy and remove ALL configs ===${NC}\n"
    confirm "This will stop HAProxy and delete the entire config. Continue?" || return
    backup_config
    systemctl stop haproxy 2>/dev/null
    rm -f "$CONFIG_FILE"
    echo -e "${GREEN}Stopped and removed.${NC}"
    pause
}

# ============================================================
#  RESTART
# ============================================================
restart_service() {
    clear
    echo -e "${YELLOW}Restarting HAProxy...${NC}\n"
    if [ -f "$CONFIG_FILE" ]; then
        validate_config || { pause; return; }
    fi
    if systemctl restart haproxy; then
        echo -e "${GREEN}Restarted successfully.${NC}"
    else
        echo -e "${RED}Restart failed. Use option 7 for logs.${NC}"
    fi
    pause
}

# ============================================================
#  LOGS
# ============================================================
view_logs() {
    clear
    echo -e "${BOLD}=== HAProxy logs (Ctrl+C to exit) ===${NC}\n"
    if [ -f "$LOG_FILE" ]; then
        tail -n 100 -f "$LOG_FILE"
    else
        journalctl -u haproxy -n 100 -f
    fi
}

# ============================================================
#  SHOW LISTENING PORTS
# ============================================================
show_ports() {
    clear
    echo -e "${BOLD}=== Ports currently listened by HAProxy ===${NC}\n"
    ss -tlnp 2>/dev/null | grep -E 'haproxy' || echo -e "${YELLOW}None.${NC}"
    echo ""
    pause
}

# ============================================================
#  HELP / GUIDE
# ============================================================
show_help() {
    clear
    echo -e "${BOLD}=== Quick Guide ===${NC}\n"

    echo -e "${CYAN}What does this script do?${NC}"
    echo "  It manages HAProxy as a TCP port-forwarder."
    echo "  Each rule forwards a 'bind port' on this server to a"
    echo "  'destination IP:port' (backend).\n"

    echo -e "${CYAN}Listen modes explained:${NC}"
    echo -e "  ${GREEN}1) IPv4 only${NC}   bind *:PORT"
    echo "     Only IPv4 clients can connect."
    echo "     Cannot be used if another IPv4 service already uses PORT.\n"

    echo -e "  ${BLUE}2) IPv6 only${NC}   bind [::]:PORT v6only"
    echo "     Only IPv6 clients can connect (v6only prevents IPv4 clash)."
    echo "     Best when the same PORT is already used by an IPv4 service"
    echo "     (e.g. kariz on 0.0.0.0:PORT).\n"

    echo -e "  ${MAGENTA}3) Dual-Stack${NC}   bind [::]:PORT"
    echo "     Both IPv4 and IPv6 clients can connect."
    echo "     Requires PORT to be completely free on both stacks.\n"

    echo -e "${CYAN}Typical scenario (kariz on IPv4, want IPv6 too):${NC}"
    echo "  - Bind port      : 4628 (a free port)"
    echo "  - Listen mode    : 2 (IPv6 only)"
    echo "  - Destination IP : 127.0.0.1"
    echo "  - Destination port: 4627 (where kariz listens on IPv4)"
    echo "  Result: [::]:4628 v6only  ->  127.0.0.1:4627\n"

    echo -e "${CYAN}Useful options:${NC}"
    echo "  2) List rules        - show all current forwards"
    echo "  3) Delete a rule     - remove one forward, keep the rest"
    echo "  4) Show listening ports - verify HAProxy is bound correctly"
    echo "  7) View logs         - debug connection issues"
    echo "  6) Stop & remove ALL - full reset (backup is kept)\n"

    echo -e "${YELLOW}Backups:${NC} $BACKUP_DIR (last 20 kept)"
    echo -e "${YELLOW}Config :${NC} $CONFIG_FILE\n"
    pause
}

# ============================================================
#  MAIN MENU
# ============================================================
main_menu() {
    while true; do
        clear
        show_logo
        echo "---------------------------------------"
        show_status
        echo "---------------------------------------"
        echo -e "${GREEN}1.${NC} Add new forwarding rule"
        echo -e "${BLUE}2.${NC} List existing rules"
        echo -e "${YELLOW}3.${NC} Delete a rule"
        echo -e "${CYAN}4.${NC} Show listening ports"
        echo -e "${YELLOW}5.${NC} Restart HAProxy"
        echo -e "${RED}6.${NC} Stop & remove ALL configs"
        echo -e "${MAGENTA}7.${NC} View real-time logs"
        echo -e "${BOLD}8.${NC} Help / Guide"
        echo -e "${BOLD}9.${NC} Exit"
        echo "---------------------------------------"
        read -p "Enter your choice: " c
        case "$c" in
            1) add_rule ;;
            2) list_rules ;;
            3) delete_rule ;;
            4) show_ports ;;
            5) restart_service ;;
            6) destroy_all ;;
            7) view_logs ;;
            8) show_help ;;
            9) echo "Bye."; exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  ENTRY
# ============================================================
require_root
ensure_deps
main_menu
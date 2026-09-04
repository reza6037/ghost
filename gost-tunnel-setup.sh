#!/usr/bin/env bash
#
# GOST Tunnel Manager - Multi-Instance (Visual Edition) - FIXED
#
set -uo pipefail

BIN_PATH="/usr/local/bin/gost"
RESOLV_CONF="/etc/resolv.conf"

# --- Colors & Styling ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[ℹ]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[✔]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_err()   { echo -e "${RED}[✖]${NC} $1"; }

print_banner() {
    clear
    echo -e "${MAGENTA}"
    echo " ╔════════════════════════════════════════════════════╗"
    echo " ║             GOST TUNNEL MANAGER v2.1               ║"
    echo " ║          Multi-Instance Support (Iran Server)      ║"
    echo " ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_header() {
    echo -e "${CYAN}╭────────── $1 ───────────${NC}"
}

print_footer() {
    echo -e "${CYAN}╰────────────────────────────────────────${NC}"
    echo ""
}

ask() {
    echo -e -n "${YELLOW}➜ ${WHITE}$1 ${NC}"
}

# --- Core Functions ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "In script bayad ba root ejra beshe (sudo bash gost-tunnel.sh)."
        exit 1
    fi
}

detect_os_arch() {
    OS_TYPE="$(uname -s)"
    if [[ "$OS_TYPE" != "Linux" ]]; then
        log_err "Faghat baraye Linux poshtibani mishavad."
        exit 1
    fi

    ARCH_RAW="$(uname -m)"
    case "$ARCH_RAW" in
        x86_64|amd64) GOST_ARCH="amd64" ;;
        aarch64|arm64) GOST_ARCH="arm64" ;;
        armv7l|armv7) GOST_ARCH="armv7" ;;
        i386|i686) GOST_ARCH="386" ;;
        *) log_err "Memari '$ARCH_RAW' shenasayi nashod."; exit 1 ;;
    esac
}

install_gost_binary_if_needed() {
    if [[ -f "$BIN_PATH" ]]; then
        return 0
    fi
    detect_os_arch
    log_info "Dar hale daryaft-e akharin version-e GOST..."
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    if [[ -z "${LATEST_TAG:-}" ]]; then log_err "Daryaft version jadid khata dad."; exit 1; fi

    VERSION_NO_V="${LATEST_TAG#v}"
    FILE_NAME="gost_${VERSION_NO_V}_linux_${GOST_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${LATEST_TAG}/${FILE_NAME}"

    TMP_DIR=$(mktemp -d)
    curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/gost.tar.gz"
    tar -xzf "${TMP_DIR}/gost.tar.gz" -C "$TMP_DIR"
    mv "${TMP_DIR}/gost" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$TMP_DIR"
    log_ok "GOST ba movafaghiat nasb shod."
}

setup_internal_dns() {
    if command -v dnsmasq >/dev/null 2>&1 && systemctl is-active --quiet dnsmasq; then return 0; fi
    log_info "Tanzim-e DNS caching mahalli baraye sor'at behtar..."
    if ! command -v dig >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y dnsutils dnsmasq >/dev/null 2>&1 || true
    fi
    systemctl stop systemd-resolved >/dev/null 2>&1 || true
    systemctl disable systemd-resolved >/dev/null 2>&1 || true
    cat > /etc/dnsmasq.conf <<EOF
no-resolv
server=8.8.8.8
server=1.1.1.1
cache-size=2000
listen-address=127.0.0.1
bind-interfaces
EOF
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq >/dev/null 2>&1 || true
    echo "nameserver 127.0.0.1" > "$RESOLV_CONF"
}

rebuild_gost_args() {
    local ip="$1"
    local ports_csv="$2"
    IFS=',' read -ra PORT_ARRAY <<< "$ports_csv"
    GOST_ARGS=""
    for p in "${PORT_ARRAY[@]}"; do
        p_trimmed=$(echo "$p" | xargs)
        GOST_ARGS="${GOST_ARGS} -L=tcp://:${p_trimmed}/${ip}:${p_trimmed}"
    done
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
TUNNEL_NAME="${TUNNEL_NAME}"
FOREIGN_IP="${FOREIGN_IP}"
PORTS="${PORTS}"
GOST_ARGS="${GOST_ARGS}"
EOF
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return 0; fi
    source "$CONFIG_FILE"
}

set_tunnel_variables() {
    local tname="$1"
    TUNNEL_NAME="$tname"
    SERVICE_NAME="gost-tunnel-${TUNNEL_NAME}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG_FILE="/etc/gost-tunnel-${TUNNEL_NAME}.conf"
    CRON_FILE="/etc/cron.d/gost-tunnel-${TUNNEL_NAME}-restart"
}

# --- Menu Actions ---
do_configure() {
    print_banner
    print_header "Sakht-e Tanl Jadid"
    check_root
    install_gost_binary_if_needed
    setup_internal_dns

    ask "Name ya Shenase tanl (mesal: panel1): "
    read -r TNAME
    if [[ -z "$TNAME" ]]; then log_err "Name khali ast!"; sleep 2; return 0; fi
    TNAME=$(echo "$TNAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-_')
    set_tunnel_variables "$TNAME"

    ask "IP Server Kharej: "
    read -r FOREIGN_IP
    if [[ -z "$FOREIGN_IP" ]]; then log_err "IP khali ast!"; sleep 2; return 0; fi

    ask "Port(haye) Kharej (joda ba comma): "
    read -r PORTS_INPUT
    if [[ -z "$PORTS_INPUT" ]]; then log_err "Port khali ast!"; sleep 2; return 0; fi

    rebuild_gost_args "$FOREIGN_IP" "$PORTS_INPUT"
    PORTS="$PORTS_INPUT"
    save_config

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Tunnel - ${TUNNEL_NAME}
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH}${GOST_ARGS}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    echo ""
    log_ok "Tanl '${TUNNEL_NAME}' ba movafaghiat roshan shod."
    sleep 2
}

select_tunnel_menu() {
    check_root
    while true; do
        print_banner
        shopt -s nullglob
        local configs=( /etc/gost-tunnel-*.conf )
        shopt -u nullglob

        if [[ ${#configs[@]} -eq 0 ]]; then
            log_warn "Hich tanli peida nashod. Aval gozine 1 ro bezanid."
            sleep 2
            return 0
        fi

        print_header "List-e Tanl-haye Mojood"
        local i=1
        declare -A tunnel_map
        for cfg in "${configs[@]}"; do
            source "$cfg"
            echo -e "  ${WHITE}$i)${NC} ${CYAN}[${TUNNEL_NAME}]${NC} ➔ IP: ${YELLOW}${FOREIGN_IP}${NC} | Ports: ${GREEN}${PORTS}${NC}"
            tunnel_map[$i]="${TUNNEL_NAME}"
            ((i++))
        done
        echo -e "  ${WHITE}0)${NC} Bazgasht"
        print_footer

        local CHOICE
        ask "Shomare tanl ro entekhab konid: "
        read -r CHOICE
        
        if [[ "$CHOICE" == "0" || -z "$CHOICE" ]]; then return 0; fi

        if [[ -n "${tunnel_map[$CHOICE]:-}" ]]; then
            set_tunnel_variables "${tunnel_map[$CHOICE]}"
            load_config
            manage_single_tunnel
        else
            log_err "Entekhab nadorost."
            sleep 1
        fi
    done
}

manage_single_tunnel() {
    while true; do
        print_banner
        print_header "Modiriat Tanl: ${MAGENTA}[ ${TUNNEL_NAME} ]${NC}"
        echo -e "  IP Kharej: ${YELLOW}${FOREIGN_IP}${NC}  |  Port(ha): ${GREEN}${PORTS}${NC}"
        echo " ────────────────────────────────────────"
        echo -e "  ${WHITE}1)${NC} Taghir-e IP-e khareji"
        echo -e "  ${WHITE}2)${NC} Taghir-e Port-ha"
        echo -e "  ${WHITE}3)${NC} Restart-e dasti service"
        echo -e "  ${WHITE}4)${NC} Vaziate Service (Status)"
        echo -e "  ${WHITE}5)${NC} Live Log (zende)"
        echo -e "  ${WHITE}6)${NC} Tanzim CronJob Restart"
        echo -e "  ${RED}7) Hazf-e in Tanl${NC}"
        echo -e "  ${WHITE}0)${NC} Bazgasht"
        print_footer

        local SUBCHOICE
        ask "Entekhab konid: "
        read -r SUBCHOICE

        case "$SUBCHOICE" in
            1)
                ask "IP jadid kharej: "
                read -r NEW_IP
                [[ -z "$NEW_IP" ]] && continue
                rebuild_gost_args "$NEW_IP" "$PORTS"
                FOREIGN_IP="$NEW_IP"
                save_config; systemctl restart "$SERVICE_NAME"
                log_ok "IP taghir kard."; sleep 2
                ;;
            2)
                ask "Port-haye jadid (ba comma): "
                read -r NEW_PORTS
                [[ -z "$NEW_PORTS" ]] && continue
                rebuild_gost_args "$FOREIGN_IP" "$NEW_PORTS"
                PORTS="$NEW_PORTS"
                save_config; systemctl restart "$SERVICE_NAME"
                log_ok "Port-ha taghir kard."; sleep 2
                ;;
            3)
                systemctl restart "$SERVICE_NAME"
                log_ok "Service restart shod."; sleep 2
                ;;
            4)
                systemctl status "$SERVICE_NAME" --no-pager -l || true
                read -n 1 -s -r -p "Baraye edame kelidi ra feshar dahid..."
                ;;
            5)
                log_info "Baraye khoruj Ctrl+C ra bezanid..."
                journalctl -u "$SERVICE_NAME" -f --no-hostname -o short-iso
                ;;
            6)
                ask "Har chand saat yekbar restart beshe? (mesal: 4): "
                read -r CHOURS
                if [[ "$CHOURS" =~ ^[0-9]+$ ]]; then
                    echo "0 */${CHOURS} * * * root systemctl restart ${SERVICE_NAME}.service >/dev/null 2>&1" > "$CRON_FILE"
                    chmod 644 "$CRON_FILE"
                    log_ok "Cronjob baraye har $CHOURS saat tanzim shod."; sleep 2
                else
                    log_err "Adad namotabar!"; sleep 2
                fi
                ;;
            7)
                ask "Motmaeni in tanl pak beshe? (y/n): "
                read -r CONFIRM
                if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
                    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
                    rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$CRON_FILE"
                    systemctl daemon-reload
                    log_ok "Tanl '${TUNNEL_NAME}' pak shod."; sleep 2
                    return 0
                fi
                ;;
            0) return 0 ;;
            *) log_err "Nadorost."; sleep 1 ;;
        esac
    done
}

# --- Main Entry ---
show_menu() {
    while true; do
        print_banner
        echo -e "  ${WHITE}1)${NC} Sakht va Pikarbandi-e Tanl-e Jadid"
        echo -e "  ${WHITE}2)${NC} List-e Tanl-ha va Modiriat (Taghirat/Hazf)"
        echo -e "  ${WHITE}0)${NC} Khorooj"
        print_footer
        
        local CHOICE
        ask "Entekhab konid [0-2]: "
        read -r CHOICE

        case "$CHOICE" in
            1) do_configure ;;
            2) select_tunnel_menu ;;
            0) clear; exit 0 ;;
            *) log_err "Entekhab nadorost."; sleep 1 ;;
        esac
    done
}

if [[ $# -gt 0 ]]; then
    log_err "Faghat 'sudo bash gost-tunnel.sh' ro ejra konid."
    exit 1
else
    show_menu
fi

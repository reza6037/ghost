#!/usr/bin/env bash
#
# GOST Tunnel Manager - baraye server Iran
# Kar: yek TCP tunnel sadeh be samte server khareji (Pasargad panel) mizanad
# (Nyazi be nasb-e jodagane ru server-e khareji nist - faghat portesh bayad baz bashe)
#
set -euo pipefail

SERVICE_NAME="gost-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/gost"
CONFIG_FILE="/etc/gost-tunnel.conf"
CRON_FILE="/etc/cron.d/gost-tunnel-restart"
RESOLV_CONF="/etc/resolv.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "In script bayad ba root ejra beshe. az 'sudo bash gost-tunnel.sh' estefade kon."
        exit 1
    fi
}

detect_os_arch() {
    OS_TYPE="$(uname -s)"
    if [[ "$OS_TYPE" != "Linux" ]]; then
        log_err "In script faghat baraye Linux server neveshte shode. OS shoma: $OS_TYPE"
        exit 1
    fi

    ARCH_RAW="$(uname -m)"
    case "$ARCH_RAW" in
        x86_64|amd64)
            GOST_ARCH="amd64"
            ;;
        aarch64|arm64)
            GOST_ARCH="arm64"
            ;;
        armv7l|armv7)
            GOST_ARCH="armv7"
            ;;
        i386|i686)
            GOST_ARCH="386"
            ;;
        *)
            log_err "Memari '$ARCH_RAW' shenasayi nashod. Nemitunam GOST-e monaseb ro dade konam."
            exit 1
            ;;
    esac

    log_info "OS: Linux | Memari shenasayi shode: $GOST_ARCH"
}

get_latest_gost_version() {
    log_info "Dar hale peida kardan-e akharin version-e GOST..."
    LATEST_TAG=$(curl -fsSL https://api.github.com/repos/go-gost/gost/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

    if [[ -z "${LATEST_TAG:-}" ]]; then
        log_err "Nashod version-e jadid ro az GitHub begiram. Internet-e server-e Iran ro check kon."
        exit 1
    fi
    log_ok "Akharin version: $LATEST_TAG"
}

install_gost() {
    detect_os_arch
    get_latest_gost_version

    VERSION_NO_V="${LATEST_TAG#v}"
    FILE_NAME="gost_${VERSION_NO_V}_linux_${GOST_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${LATEST_TAG}/${FILE_NAME}"

    log_info "Dar hale dade kardan-e GOST az:"
    echo "  $DOWNLOAD_URL"

    TMP_DIR=$(mktemp -d)
    if ! curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/gost.tar.gz"; then
        log_err "Dade kardan-e GOST fail shod. Link ro check kon ya version-e digeh ro emtehan kon:"
        echo "  https://github.com/go-gost/gost/releases"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    tar -xzf "${TMP_DIR}/gost.tar.gz" -C "$TMP_DIR"

    if [[ ! -f "${TMP_DIR}/gost" ]]; then
        log_err "Faile ejrayi-e gost dakhele package peida nashod."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    mv "${TMP_DIR}/gost" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    rm -rf "$TMP_DIR"

    log_ok "GOST ba movafaghiat nasb shod: $($BIN_PATH -V 2>&1 || true)"
}

# ---------------------------------------------
# DNS-e dakheli: test-e latency + local caching (dnsmasq)
#
# Tavajoh: DNS faghat sor'at-e resolve-e domain-ha ro kam mikone
# (masalan load-e site/launcher), ru ping-e vaghei-e dakhele-e bazi
# (ke ba'ad az resolve mostaghiman ru IP mire) tasiri nadare.
# In DNS caching baraye sor'at-e kolli va connection setup mofide.
# ---------------------------------------------
measure_dns_latency() {
    local ip="$1"
    local qtime
    qtime=$(dig +time=1 +tries=1 @"$ip" google.com 2>/dev/null | awk '/Query time:/ {print $4}')
    if [[ -z "$qtime" ]]; then
        echo 9999
    else
        echo "$qtime"
    fi
}

setup_internal_dns() {
    log_info "Dar hale test-e latency-e chandta DNS provider baraye entekhab-e sari-tarin..."

    if ! command -v dig >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y dnsutils >/dev/null 2>&1 || \
        yum install -y bind-utils >/dev/null 2>&1 || true
    fi

    local names=("Google-1" "Google-2" "Cloudflare-1" "Cloudflare-2" "Quad9")
    local ips=("8.8.8.8" "8.8.4.4" "1.1.1.1" "1.0.0.1" "9.9.9.9")

    BEST_NAME=""
    BEST_IP=""
    BEST_TIME=999999
    SECOND_IP="8.8.8.8"
    SECOND_TIME=999999

    for i in "${!ips[@]}"; do
        local ip="${ips[$i]}"
        local name="${names[$i]}"
        local t
        t=$(measure_dns_latency "$ip")
        echo "  ${name} (${ip}): ${t} ms"
        if [[ "$t" -lt "$BEST_TIME" ]]; then
            SECOND_IP="$BEST_IP"
            SECOND_TIME="$BEST_TIME"
            BEST_TIME="$t"
            BEST_NAME="$name"
            BEST_IP="$ip"
        elif [[ "$t" -lt "$SECOND_TIME" ]]; then
            SECOND_TIME="$t"
            SECOND_IP="$ip"
        fi
    done

    if [[ -z "$BEST_IP" || "$BEST_TIME" -eq 9999 ]]; then
        log_warn "Hich DNS-i javab-e motabar nadad, fallback be Google DNS."
        BEST_IP="8.8.8.8"
        SECOND_IP="8.8.4.4"
    else
        log_ok "Sari-tarin DNS: ${BEST_NAME} (${BEST_IP}) ~ ${BEST_TIME}ms | fallback: ${SECOND_IP}"
    fi

    # nasb-e dnsmasq baraye local caching (query-haye tekrari taghriban 0ms mishan)
    if ! command -v dnsmasq >/dev/null 2>&1; then
        log_info "Dar hale nasb-e dnsmasq baraye DNS caching-e mahalli..."
        apt-get update -y >/dev/null 2>&1 && apt-get install -y dnsmasq >/dev/null 2>&1 || \
        yum install -y dnsmasq >/dev/null 2>&1 || true
    fi

    if command -v dnsmasq >/dev/null 2>&1; then
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
        systemctl disable systemd-resolved >/dev/null 2>&1 || true

        cat > /etc/dnsmasq.conf <<EOF
no-resolv
server=${BEST_IP}
server=${SECOND_IP}
cache-size=2000
listen-address=127.0.0.1
bind-interfaces
EOF
        systemctl enable dnsmasq >/dev/null 2>&1 || true
        systemctl restart dnsmasq

        rm -f "$RESOLV_CONF"
        cat > "$RESOLV_CONF" <<EOF
nameserver 127.0.0.1
EOF
        log_ok "dnsmasq (local cache) fa'al shod, forward be ${BEST_IP} / ${SECOND_IP}"
    else
        log_warn "Nashod dnsmasq nasb beshe. Faghat DNS-e sari be sorat-e mostaghim tanzim shod (bedun-e cache)."
        [[ -L "$RESOLV_CONF" ]] && rm -f "$RESOLV_CONF" || cp "$RESOLV_CONF" "${RESOLV_CONF}.bak.$(date +%s)" 2>/dev/null || true
        cat > "$RESOLV_CONF" <<EOF
nameserver ${BEST_IP}
nameserver ${SECOND_IP}
EOF
    fi

    log_info "Yad-avari: in tanzimat sor'at-e resolve-e domain-ha ro behtar mikone; ping-e dakhele-e bazi be masir-e tunnel bastegi dare."
}

rebuild_gost_args() {
    local ip="$1"
    local ports_csv="$2"

    IFS=',' read -ra PORT_ARRAY <<< "$ports_csv"

    GOST_ARGS=""
    for p in "${PORT_ARRAY[@]}"; do
        p_trimmed=$(echo "$p" | xargs)
        if ! [[ "$p_trimmed" =~ ^[0-9]+$ ]]; then
            log_err "Port '$p_trimmed' adad nist."
            exit 1
        fi
        GOST_ARGS="${GOST_ARGS} -L=tcp://:${p_trimmed}/${ip}:${p_trimmed}"
    done

    FOREIGN_IP="$ip"
    PORTS="$ports_csv"
}

save_config() {
    {
        echo "FOREIGN_IP=${FOREIGN_IP}"
        echo "PORTS=${PORTS}"
    } > "$CONFIG_FILE"
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "Hanooz tunnel pikarbandi nashode. Aval gozine 1 (Pikarbandi) ro bezan."
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

ask_tunnel_config() {
    echo ""
    log_info "Hala tanzimat-e tunnel ro vared kon:"
    echo ""

    read -rp "IP server-e khareji (jayi ke Pasargad panel roshe): " FOREIGN_IP
    if [[ -z "$FOREIGN_IP" ]]; then
        log_err "IP nemitune khali bashe."
        exit 1
    fi

    echo ""
    echo "Halla port-haye caraberha ro vared kon."
    echo "Age chandta port darim, ba comma joda kon. Masalan: 8080,8443,2053"
    read -rp "Port(ha)-ye server-e khareji: " PORTS_INPUT

    if [[ -z "$PORTS_INPUT" ]]; then
        log_err "Hich porti vared nashod."
        exit 1
    fi

    rebuild_gost_args "$FOREIGN_IP" "$PORTS_INPUT"

    echo ""
    log_info "Khalase tanzimat:"
    echo "  Foreign server : $FOREIGN_IP"
    echo "  Port-ha        : $PORTS_INPUT"
    echo ""

    save_config
}

create_systemd_service() {
    log_info "Dar hale sakht-e systemd service..."

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST TCP Tunnel Service
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

    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_ok "Service ba movafaghiat run shod va rooshane."
    else
        log_err "Service run nashod! Baraye jozyat: journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
}

# ---------------------------------------------
# Cron Job Restart - hala hour-e delkhah az karbar porsideh mishe
# ---------------------------------------------
ensure_cron_installed() {
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        log_warn "Sarvis-e cron peida nashod. Dar hale nasb-e cron..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y cron >/dev/null 2>&1
            systemctl enable cron >/dev/null 2>&1 || true
            systemctl start cron >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y cronie >/dev/null 2>&1
            systemctl enable crond >/dev/null 2>&1 || true
            systemctl start crond >/dev/null 2>&1 || true
        else
            log_warn "Nashod cron ro automatic nasb konam. Khodet cron ro nasb kon."
        fi
    fi
}

setup_cron_restart() {
    check_root
    if [[ ! -f "$BIN_PATH" ]]; then
        log_err "Aval GOST ro pikarbandi kon (gozine 1)."
        return 1
    fi

    echo ""
    read -rp "Har chand saat yekbar service restart beshe? (masalan 4): " CRON_HOURS

    if ! [[ "$CRON_HOURS" =~ ^[0-9]+$ ]] || [[ "$CRON_HOURS" -lt 1 ]] || [[ "$CRON_HOURS" -gt 23 ]]; then
        log_err "Adad-e vared shode motabar nist. Bayad adad-e beine 1 ta 23 bashe."
        return 1
    fi

    log_info "Dar hale tanzim-e cronjob baraye restart-e automatic (har ${CRON_HOURS} saat yekbar)..."
    ensure_cron_installed

    cat > "$CRON_FILE" <<EOF
# Automatic restart-e gost-tunnel har ${CRON_HOURS} saat yekbar
0 */${CRON_HOURS} * * * root systemctl restart ${SERVICE_NAME}.service >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"

    log_ok "Cronjob tanzim shod: har ${CRON_HOURS} saat yekbar service restart mishe (fayl: $CRON_FILE)"
}

remove_cron_restart() {
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        log_ok "Cronjob-e restart pak shod."
    fi
}

toggle_cron() {
    check_root
    if [[ -f "$CRON_FILE" ]]; then
        remove_cron_restart
        log_info "Automatic restart (cron) gheyr-e fa'al shod."
    else
        setup_cron_restart
    fi
}

# ---------------------------------------------
# Pikarbandi-e Tunnel (Nasb agar lazem bashe + Configure + DNS)
# ---------------------------------------------
do_configure() {
    check_root

    if [[ ! -f "$BIN_PATH" ]]; then
        install_gost
    else
        log_info "GOST ghablan nasb shode. Az dade kardan-e mojadad sarfenazar mishe."
    fi

    ask_tunnel_config
    setup_internal_dns
    create_systemd_service
    show_status

    echo ""
    log_ok "Pikarbandi tamam shod! Caraberha mitunan az tarigh-e port-haye vared shode vasl beshan."
    log_info "Yadet nare az gozine 3 baraye tanzim-e automatic restart (cron) estefade koni."
}

show_logs() {
    check_root
    if ! systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        log_err "Service hanooz nasb nashode. Aval gozine 1 (Pikarbandi) ro bezan."
        exit 1
    fi
    log_info "Live log (baraye khoruj: Ctrl+C)..."
    journalctl -u "$SERVICE_NAME" -f --no-hostname -o short-iso
}

show_status() {
    echo ""
    log_info "Status-e service:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
}

do_restart() {
    check_root
    systemctl restart "$SERVICE_NAME"
    log_ok "Service restart shod."
    show_status
}

do_uninstall() {
    check_root
    log_warn "In kar service ro pak mikone va GOST ro hazf mikone."
    read -rp "Motmaeni? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log_info "Uninstall cancel shod."
        exit 0
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "$BIN_PATH"
    rm -f "$CONFIG_FILE"
    remove_cron_restart
    systemctl daemon-reload

    log_ok "Hame chi pak shod."
}

# ---------------------------------------------
# Modiriat-e Service: taghir-e IP / port / hazf-e service+cron
# ---------------------------------------------
change_ip() {
    check_root
    load_config || return 1

    echo ""
    log_info "IP-e feli: ${FOREIGN_IP}"
    read -rp "IP-e jadid-e server-e khareji: " NEW_IP
    if [[ -z "$NEW_IP" ]]; then
        log_err "IP nemitune khali bashe."
        return 1
    fi

    rebuild_gost_args "$NEW_IP" "$PORTS"
    save_config
    create_systemd_service
    log_ok "IP be ${FOREIGN_IP} taghir kard va service update shod."
}

change_ports() {
    check_root
    load_config || return 1

    echo ""
    log_info "Port-haye feli: ${PORTS}"
    echo "Port-haye jadid ro ba comma vared kon. Masalan: 8080,8443,2053"
    read -rp "Port(ha)-ye jadid: " NEW_PORTS
    if [[ -z "$NEW_PORTS" ]]; then
        log_err "Hich porti vared nashod."
        return 1
    fi

    rebuild_gost_args "$FOREIGN_IP" "$NEW_PORTS"
    save_config
    create_systemd_service
    log_ok "Port-ha be-roz shod: ${PORTS}"
}

delete_service_and_cron() {
    check_root
    log_warn "In kar service-e GOST va cronjob-e restart ro hazf mikone (khode barnameh-ye GOST hazf nemishe)."
    read -rp "Motmaeni? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log_info "Cancel shod."
        return 0
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    remove_cron_restart
    systemctl daemon-reload

    log_ok "Service va cronjob hazf shodan. (GOST hanooz nasbe, baraye pikarbandi-e mojadad gozine 1 ro bezan)"
}

service_management_menu() {
    while true; do
        echo ""
        echo "======================================"
        echo "        Modiriat-e Service"
        echo "======================================"
        echo "1) Taghir-e IP-e khareji"
        echo "2) Taghir-e Port-ha"
        echo "3) Restart-e dasti"
        echo "4) Status-e service"
        echo "5) Roshan/khamush-e automatic restart (cron)"
        echo "6) Hazf-e Service + Cronjob (bedun-e hazf-e GOST)"
        echo "7) Hazf-e kamel (Uninstall-e GOST + service + cron)"
        echo "0) Bazgasht be manu-e asli"
        echo "======================================"
        read -rp "Entekhab kon [0-7]: " SUBCHOICE

        case "$SUBCHOICE" in
            1) change_ip ;;
            2) change_ports ;;
            3) do_restart ;;
            4) show_status ;;
            5) toggle_cron ;;
            6) delete_service_and_cron ;;
            7) do_uninstall ;;
            0) return 0 ;;
            *) log_err "Entekhab-e nadorost." ;;
        esac
    done
}

show_menu() {
    echo ""
    echo "======================================"
    echo "   GOST Tunnel Manager - Server Iran"
    echo "======================================"
    echo "1) Pikarbandi-e Tunnel (Nasb + Configure + DNS)"
    echo "2) Modiriat-e Service (IP / Port / Hazf / ...)"
    echo "3) Didan-e Log (be soorat-e zende)"
    echo "4) Cron Job Restart (har chand saat)"
    echo "0) Khorooj"
    echo "======================================"
    read -rp "Entekhab kon [0-4]: " CHOICE

    case "$CHOICE" in
        1) do_configure ;;
        2) service_management_menu ;;
        3) show_logs ;;
        4) setup_cron_restart ;;
        0) exit 0 ;;
        *) log_err "Entekhab-e nadorost." ;;
    esac
}

# --- Ejra ---
if [[ $# -gt 0 ]]; then
    case "$1" in
        configure|install) check_root; do_configure ;;
        manage) service_management_menu ;;
        changeip) change_ip ;;
        changeports) change_ports ;;
        log|logs) show_logs ;;
        cron) setup_cron_restart ;;
        status) show_status ;;
        restart) do_restart ;;
        deleteservice) delete_service_and_cron ;;
        togglecron) toggle_cron ;;
        uninstall) do_uninstall ;;
        *)
            log_err "Dastoor-e nashenakhte: $1"
            echo "Estefade: bash gost-tunnel.sh [configure|manage|changeip|changeports|log|cron|status|restart|deleteservice|togglecron|uninstall]"
            exit 1
            ;;
    esac
else
    show_menu
fi

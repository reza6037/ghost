#!/usr/bin/env bash
#
# GOST Tunnel Manager - baraye server Iran
# Kar: yek TCP tunnel sadeh be samte server khareji (Pasargad panel) mizanad
#
set -euo pipefail

SERVICE_NAME="gost-tunnel"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/gost"
CONFIG_FILE="/etc/gost-tunnel.conf"
CRON_FILE="/etc/cron.d/gost-tunnel-restart"

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

    # tabdil comma be array
    IFS=',' read -ra PORT_ARRAY <<< "$PORTS_INPUT"

    # sakhtan-e argument haye -L baraye har port (ham local ham remote port yeki mishe)
    GOST_ARGS=""
    for p in "${PORT_ARRAY[@]}"; do
        p_trimmed=$(echo "$p" | xargs)
        if ! [[ "$p_trimmed" =~ ^[0-9]+$ ]]; then
            log_err "Port '$p_trimmed' adad nist."
            exit 1
        fi
        GOST_ARGS="${GOST_ARGS} -L=tcp://:${p_trimmed}/${FOREIGN_IP}:${p_trimmed}"
    done

    echo ""
    log_info "Khalase tanzimat:"
    echo "  Foreign server : $FOREIGN_IP"
    echo "  Port-ha        : $PORTS_INPUT"
    echo ""

    # zakhire baraye estefade badi (uninstall/status/reconfigure)
    {
        echo "FOREIGN_IP=${FOREIGN_IP}"
        echo "PORTS=${PORTS_INPUT}"
    } > "$CONFIG_FILE"
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

setup_cron_restart() {
    log_info "Dar hale tanzim-e cronjob baraye restart-e automatic (har 4 saat yekbar)..."

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

    cat > "$CRON_FILE" <<EOF
# Automatic restart-e gost-tunnel har 4 saat yekbar
0 */4 * * * root systemctl restart ${SERVICE_NAME}.service >/dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"

    log_ok "Cronjob tanzim shod: har 4 saat yekbar service restart mishe (fayl: $CRON_FILE)"
}

remove_cron_restart() {
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        log_ok "Cronjob-e restart pak shod."
    fi
}

do_install() {
    check_root
    install_gost
    ask_tunnel_config
    create_systemd_service
    setup_cron_restart
    show_status
    echo ""
    log_ok "Tamam shod! Alan caraberha mitunan az tarigh-e port-haye vared shode be internet-e beinolmelali vasl beshan."
    log_info "Service har 4 saat yekbar be soorat-e automatic restart mishe (cronjob)."
}

show_logs() {
    check_root
    if ! systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        log_err "Service hanooz nasb nashode. Aval install ro bezan."
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

toggle_cron() {
    check_root
    if [[ -f "$CRON_FILE" ]]; then
        remove_cron_restart
        log_info "Automatic restart (cron) gheyr-e fa'al shod."
    else
        setup_cron_restart
    fi
}

do_reconfigure() {
    check_root
    if [[ ! -f "$BIN_PATH" ]]; then
        log_err "Aval GOST ro nasb kon (gozine 1)."
        exit 1
    fi
    ask_tunnel_config
    create_systemd_service
    log_ok "Port-ha update shodan."
}

show_menu() {
    echo ""
    echo "======================================"
    echo "   GOST Tunnel Manager - Server Iran"
    echo "======================================"
    echo "1) Nasb va rah andazi-e tunnel (Install)"
    echo "2) Didan-e log-ha (be soorat-e zende)"
    echo "3) Didan-e status-e service"
    echo "4) Restart kardan-e service"
    echo "5) Taghir-e port-ha (Reconfigure)"
    echo "6) Roshan/khamush kardan-e automatic restart (cron - har 4 saat)"
    echo "7) Hazf-e kamel (Uninstall)"
    echo "0) Khorooj"
    echo "======================================"
    read -rp "Entekhab kon [0-7]: " CHOICE

    case "$CHOICE" in
        1) do_install ;;
        2) show_logs ;;
        3) show_status ;;
        4) do_restart ;;
        5) do_reconfigure ;;
        6) toggle_cron ;;
        7) do_uninstall ;;
        0) exit 0 ;;
        *) log_err "Entekhab-e nadorost." ;;
    esac
}

# --- Ejra ---
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) check_root; do_install ;;
        log|logs) show_logs ;;
        status) show_status ;;
        restart) do_restart ;;
        reconfigure) do_reconfigure ;;
        cron) toggle_cron ;;
        uninstall) do_uninstall ;;
        *)
            log_err "Dastoor-e nashenakhte: $1"
            echo "Estefade: bash gost-tunnel.sh [install|log|status|restart|reconfigure|cron|uninstall]"
            exit 1
            ;;
    esac
else
    show_menu
fi

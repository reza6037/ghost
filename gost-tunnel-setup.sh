#!/bin/bash
#===============================================================================
#  GOST Tunnel Setup Script
#  Baraye setup kardan tunnel GOST beyn Server IRAN va Server KHAREJ
#  (Server khareji jaii ke Pasargad Panel roosh run mishe)
#
#  In script ro roo SERVER IRAN run kon (root laazeme)
#===============================================================================

set -e

# ---------------- Rangha baraye khoroji ghashang ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GOST_BIN="/usr/local/bin/gost"
CONFIG_DIR="/etc/gost-tunnel"
CONFIG_FILE="${CONFIG_DIR}/tunnel.conf"
SERVICE_FILE="/etc/systemd/system/gost-tunnel.service"
SERVICE_NAME="gost-tunnel"
MANAGE_CMD="/usr/local/bin/gost-manage"

msg()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------- Check root ----------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        err "In script ro ba root run kon. (sudo -i baad script ro dobare run kon)"
        exit 1
    fi
}

# ---------------- Tashkhis OS va Architecture ----------------
detect_os_arch() {
    OS_TYPE=$(uname -s)
    case "$OS_TYPE" in
        Linux)  GOST_OS="linux" ;;
        Darwin) GOST_OS="darwin" ;;
        *) err "In sistem amel poshtibani nemishe: $OS_TYPE"; exit 1 ;;
    esac

    ARCH_TYPE=$(uname -m)
    case "$ARCH_TYPE" in
        x86_64|amd64)  GOST_ARCH="amd64" ;;
        aarch64|arm64) GOST_ARCH="arm64" ;;
        armv7l)        GOST_ARCH="armv7" ;;
        armv6l)        GOST_ARCH="armv6" ;;
        i386|i686)     GOST_ARCH="386" ;;
        *) err "In memari poshtibani nemishe: $ARCH_TYPE"; exit 1 ;;
    esac

    ok "OS tashkhis dade shod: ${GOST_OS} / ${GOST_ARCH}"
}

# ---------------- Package manager check (baraye tar/curl) ----------------
ensure_deps() {
    for cmd in curl tar systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "$cmd nasb nist, dare nasb mishe..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y >/dev/null 2>&1
                apt-get install -y curl tar >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y curl tar >/dev/null 2>&1
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y curl tar >/dev/null 2>&1
            else
                err "Package manager peida nashod, khodet $cmd ro nasb kon."
                exit 1
            fi
        fi
    done
}

# ---------------- Download va Nasb GOST ----------------
install_gost() {
    msg "In hale peida kardan akharin version GOST..."

    LATEST_TAG=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_TAG" ]; then
        err "Nashod version akhar ro peida kard. Internet ya dastresi be GitHub ro check kon."
        exit 1
    fi

    VERSION_NUM="${LATEST_TAG#v}"
    ASSET_NAME="gost_${VERSION_NUM}_${GOST_OS}_${GOST_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/${LATEST_TAG}/${ASSET_NAME}"

    msg "Version peida shod: ${LATEST_TAG} -- dare download mishe..."

    TMP_DIR=$(mktemp -d)
    if ! curl -L -s -o "${TMP_DIR}/gost.tar.gz" "$DOWNLOAD_URL"; then
        err "Download fail shod. URL: $DOWNLOAD_URL"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    tar -xzf "${TMP_DIR}/gost.tar.gz" -C "$TMP_DIR"

    if [ ! -f "${TMP_DIR}/gost" ]; then
        err "Faile gost dakhele package peida nashod."
        rm -rf "$TMP_DIR"
        exit 1
    fi

    mv "${TMP_DIR}/gost" "$GOST_BIN"
    chmod +x "$GOST_BIN"
    rm -rf "$TMP_DIR"

    ok "GOST nasb shod: $($GOST_BIN -V 2>/dev/null || echo $LATEST_TAG)"
}

# ---------------- Gereftan Ettelaat az User ----------------
ask_config() {
    echo ""
    echo -e "${BOLD}=== Tanzimate Tunnel ===${NC}"
    echo ""

    read -rp "$(echo -e ${CYAN}IP ya domain server KHAREJI: ${NC})" REMOTE_HOST
    while [ -z "$REMOTE_HOST" ]; do
        read -rp "IP/domain khali nemishe, dobare vared kon: " REMOTE_HOST
    done

    echo ""
    echo -e "${YELLOW}--- Port mahsuse Tunnel VPN (masalan port service Xray/V2ray) ---${NC}"
    read -rp "$(echo -e ${CYAN}Port GOST roo server IRAN [masalan 8443]: ${NC})" LOCAL_TUNNEL_PORT
    read -rp "$(echo -e ${CYAN}Port motenazer roo server KHAREJ ke bayad forward beshe be un: ${NC})" REMOTE_TUNNEL_PORT

    echo ""
    echo -e "${YELLOW}--- Chon nemishe hamzaman az yek port ham baraye GOST ham Pasargad panel estefade kard ---${NC}"
    echo -e "${YELLOW}--- pas port panel Pasargad ham jodagane forward mishe ---${NC}"
    read -rp "$(echo -e ${CYAN}Aya mikhay port Panel Pasargad ham az tarigh in tunnel dastresi dashte bashe? [y/n]: ${NC})" WANT_PANEL

    if [[ "$WANT_PANEL" =~ ^[Yy]$ ]]; then
        read -rp "$(echo -e ${CYAN}Port dar server IRAN baraye dastresi be Panel Pasargad [masalan 2096]: ${NC})" LOCAL_PANEL_PORT
        read -rp "$(echo -e ${CYAN}Port vaghei Panel Pasargad roo server KHAREJ: ${NC})" REMOTE_PANEL_PORT
        HAS_PANEL="yes"
    else
        HAS_PANEL="no"
    fi

    echo ""
    read -rp "$(echo -e "${CYAN}Protocol tunnel [1=tcp default | 2=tcp+tls]: ${NC}")" PROTO_CHOICE
    if [ "$PROTO_CHOICE" == "2" ]; then
        TUNNEL_PROTO="tls"
    else
        TUNNEL_PROTO="tcp"
    fi
}

# ---------------- Sakhte Config File ----------------
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
REMOTE_HOST=${REMOTE_HOST}
LOCAL_TUNNEL_PORT=${LOCAL_TUNNEL_PORT}
REMOTE_TUNNEL_PORT=${REMOTE_TUNNEL_PORT}
HAS_PANEL=${HAS_PANEL}
LOCAL_PANEL_PORT=${LOCAL_PANEL_PORT:-}
REMOTE_PANEL_PORT=${REMOTE_PANEL_PORT:-}
TUNNEL_PROTO=${TUNNEL_PROTO}
EOF
    ok "Config zakhire shod dar $CONFIG_FILE"
}

# ---------------- Sakhte systemd service ----------------
build_exec_args() {
    source "$CONFIG_FILE"

    ARGS="-L=${TUNNEL_PROTO}://:${LOCAL_TUNNEL_PORT}/${REMOTE_HOST}:${REMOTE_TUNNEL_PORT}"

    if [ "$HAS_PANEL" == "yes" ] && [ -n "$LOCAL_PANEL_PORT" ]; then
        ARGS="${ARGS} -L=${TUNNEL_PROTO}://:${LOCAL_PANEL_PORT}/${REMOTE_HOST}:${REMOTE_PANEL_PORT}"
    fi

    echo "$ARGS"
}

create_service() {
    EXEC_ARGS=$(build_exec_args)

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST Tunnel Service (Iran -> Kharej)
After=network.target

[Service]
Type=simple
ExecStart=${GOST_BIN} ${EXEC_ARGS}
Restart=always
RestartSec=3
StandardOutput=append:/var/log/gost-tunnel.log
StandardError=append:/var/log/gost-tunnel.log

[Install]
WantedBy=multi-user.target
EOF

    touch /var/log/gost-tunnel.log
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service GOST ba movafaghiat run shod."
    else
        err "Service run nashod, ba 'gost-manage logs' error ro check kon."
    fi
}

# ---------------- Sakhte Dastoore Modiriati gost-manage ----------------
create_manage_cmd() {
    cat > "$MANAGE_CMD" <<'EOFCMD'
#!/bin/bash
SERVICE_NAME="gost-tunnel"
CONFIG_FILE="/etc/gost-tunnel/tunnel.conf"
LOG_FILE="/var/log/gost-tunnel.log"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

show_status() {
    echo -e "${CYAN}--- Vaziate Tunnel ---${NC}"
    systemctl status "$SERVICE_NAME" --no-pager -l | head -n 12
    echo ""
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${CYAN}--- Tanzimat Fael ---${NC}"
        cat "$CONFIG_FILE"
    fi
}

case "$1" in
    start)
        systemctl start "$SERVICE_NAME"
        echo -e "${GREEN}Tunnel start shod.${NC}"
        ;;
    stop)
        systemctl stop "$SERVICE_NAME"
        echo -e "${RED}Tunnel stop shod.${NC}"
        ;;
    restart)
        systemctl restart "$SERVICE_NAME"
        echo -e "${GREEN}Tunnel restart shod.${NC}"
        ;;
    status)
        show_status
        ;;
    logs)
        echo -e "${CYAN}Log zende (Ctrl+C baraye khorooj):${NC}"
        journalctl -u "$SERVICE_NAME" -f -n 100 --no-pager 2>/dev/null || tail -f "$LOG_FILE"
        ;;
    logs-file)
        tail -n 100 -f "$LOG_FILE"
        ;;
    uninstall)
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f /etc/systemd/system/gost-tunnel.service
        rm -rf /etc/gost-tunnel
        rm -f /usr/local/bin/gost
        systemctl daemon-reload
        echo -e "${RED}Tunnel be tor kamel hazf shod.${NC}"
        echo "Ageh mikhay dobare nasb koni, script asli ro dobare run kon."
        rm -- "$0"
        ;;
    *)
        echo "Estefade: gost-manage {start|stop|restart|status|logs|logs-file|uninstall}"
        ;;
esac
EOFCMD

    chmod +x "$MANAGE_CMD"
    ok "Dastoore modiriati sakhte shod: gost-manage"
}

# ---------------- Khorooji Nahaii ----------------
print_summary() {
    source "$CONFIG_FILE"
    echo ""
    echo -e "${BOLD}=================================================${NC}"
    echo -e "${GREEN}Tunnel GOST ba movafaghiat setup shod!${NC}"
    echo -e "${BOLD}=================================================${NC}"
    echo -e "Server Khareji     : ${REMOTE_HOST}"
    echo -e "Port Tunnel (IRAN) : ${LOCAL_TUNNEL_PORT}  --> Khareje ${REMOTE_TUNNEL_PORT}"
    if [ "$HAS_PANEL" == "yes" ]; then
        echo -e "Port Panel (IRAN)  : ${LOCAL_PANEL_PORT}  --> Khareje ${REMOTE_PANEL_PORT}"
    fi
    echo -e "Protocol           : ${TUNNEL_PROTO}"
    echo ""
    echo -e "${CYAN}Dastoore Modiriat:${NC}"
    echo "  gost-manage status      -> didan vaziat"
    echo "  gost-manage logs        -> didan log zende"
    echo "  gost-manage restart     -> restart kardan tunnel"
    echo "  gost-manage stop        -> stop kardan tunnel"
    echo "  gost-manage uninstall   -> hazf kamel"
    echo ""
    warn "Yadet nare firewall port haaye bala ro roo har do server BAZ koni (masalan ufw allow port)"
}

# ---------------- Main ----------------
main() {
    check_root
    echo -e "${BOLD}${CYAN}"
    echo "==========================================="
    echo "   GOST Tunnel Setup - Iran <-> Kharej"
    echo "==========================================="
    echo -e "${NC}"

    detect_os_arch
    ensure_deps
    install_gost
    ask_config
    save_config
    create_service
    create_manage_cmd
    print_summary
}

main

#!/bin/bash

# Terminal colors and log helpers
readonly _C_RESET='\033[0m'
readonly _C_BLUE='\033[0;34m'
readonly _C_YELLOW='\033[0;33m'
readonly _C_RED='\033[0;31m'

info() { echo -e "${_C_BLUE}$*${_C_RESET}"; }
warning() { echo -e "${_C_YELLOW}$*${_C_RESET}" >&2; }
error() { echo -e "${_C_RED}$*${_C_RESET}" >&2; }

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  error "Please run as root (use sudo)"
  exit 1
fi

usage() {
    echo "Usage: $0 -s <server> -n <name> -p <password> -psk <psk> [-k|--keepalive] [-r|--retries <number>] [-w|--retry-sleep <seconds>]"
    echo "Options:"
    echo "  -s,    --server       IP address or domain of the VPN server"
    echo "  -n,    --name         Username for VPN"
    echo "  -p,    --password     Password for VPN"
    echo "  -psk,  --psk          Pre-shared key (PSK) for VPN"
    echo "  -k,    --keepalive    Install and start a systemd background service for auto-reconnect"
    echo "  -r,    --retries      Maximum number of retries for IP assignment (default: 15)"
    echo "  -w,    --retry-sleep  Seconds to wait between IP assignment retries (default: 10)"
    echo "  -h,    --help         Display this help message and exit"
    exit 1
}

SERVER=""
NAME=""
PASSWORD=""
PSK=""
KEEPALIVE=false
MAX_RETRIES=15
IP_RETRY_SLEEP=10

# Define the responsible config file
CONFIG_FILE="/etc/l2tp-connect.conf"

# Source the file if it exists to load default values
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi


# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--server) SERVER="$2"; shift ;;
        -n|--name) NAME="$2"; shift ;;
        -p|--password) PASSWORD="$2"; shift ;;
        -psk|--psk) PSK="$2"; shift ;;
        -k|--keepalive) KEEPALIVE=true ;;
        -r|--retries) MAX_RETRIES="$2"; shift ;;
        -w|--retry-sleep) IP_RETRY_SLEEP="$2"; shift ;;
        -h|--help) usage ;;
        *) error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if ! [[ "$IP_RETRY_SLEEP" =~ ^[0-9]+$ ]]; then
    error "Invalid --retry-sleep value: must be a non-negative integer."
    usage
fi

if [ -z "$SERVER" ] || [ -z "$NAME" ] || [ -z "$PASSWORD" ] || [ -z "$PSK" ]; then
    error "Missing required parameters in $CONFIG_FILE or CLI arguments."
    usage
fi


# Define configuration files
IPSEC_CONF_DIR="/etc/ipsec.d"
IPSEC_CONF_FILE="$IPSEC_CONF_DIR/l2tp-connect-tool.conf"
SECRETS_FILE="$IPSEC_CONF_DIR/l2tp-connect-tool.secrets"
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
PPP_FILE="/etc/ppp/options.l2tp-connect-tool"
CONTROL_FILE="/var/run/xl2tpd/l2tp-control"
CONNECTION_NAME="auto-vpn-connect"
INTERFACE="ppp0"

# True when $INTERFACE has an IPv4 address (tunnel considered up).
interface_has_vpn_ip() {
    ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -q "inet "
}

info "Configuring VPN settings..."

# 0. Ensure drop-in directories exist and main files include them
mkdir -p "$IPSEC_CONF_DIR"

if ! grep -q "include /etc/ipsec.d/\*.conf" /etc/ipsec.conf 2>/dev/null; then
    echo "include /etc/ipsec.d/*.conf" >> /etc/ipsec.conf
fi
if ! grep -q "include /etc/ipsec.d/\*.secrets" /etc/ipsec.secrets 2>/dev/null; then
    echo "include /etc/ipsec.d/*.secrets" >> /etc/ipsec.secrets
fi


# 1. Generate /etc/ipsec.conf
cat > "$IPSEC_CONF_FILE" <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0" 

conn $CONNECTION_NAME
    keyexchange=ikev1
    authby=psk
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER
    rightid=%any
    rightprotoport=17/1701
    ike=aes128-sha1-modp1024!
    esp=aes128-sha1!
    forceencaps=yes
    auto=add
EOF

# 2. Generate Drop-in /etc/ipsec.d/l2tp-connect-tool.secrets
echo "%any $SERVER : PSK \"$PSK\"" > "$SECRETS_FILE"

# 3. Write /etc/xl2tpd/xl2tpd.conf (xl2tpd rejects lines before any [section]; use [global] first)
cat > "$XL2TPD_CONF" <<EOF
[global]
port = 1701

[lac $CONNECTION_NAME]
lns = $SERVER
pppoptfile = $PPP_FILE
length bit = yes
EOF


# 4. Generate /etc/ppp/options.l2tp-connect-tool
cat > "$PPP_FILE" <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
refuse-pap
require-mschap-v2
noccp
noauth
mtu 1350
mru 1350
noipdefault
usepeerdns
connect-delay 5000
name "$NAME"
password "$PASSWORD"
EOF

# 5. Apply core configurations and ensure base services are running
if interface_has_vpn_ip; then
    info "$INTERFACE already has an IPv4 address; leaving the existing tunnel up (not restarting xl2tpd or IPsec)."
else
    info "Restarting core services to apply configurations..."
    systemctl restart xl2tpd.service
    ipsec restart 2>/dev/null || systemctl restart strongswan-ipsec
    sleep 2
fi

# ==========================================
# BACKGROUND KEEPALIVE MODE (Systemd Daemon)
# ==========================================
if [ "$KEEPALIVE" = true ]; then
    info "Setting up auto-reconnect systemd service..."

    KEEPALIVE_SCRIPT="/usr/local/bin/l2tp-keepalive"
    SERVICE_FILE="/etc/systemd/system/vpn-keepalive.service"

    # Create the keepalive script (${CONNECTION_NAME} expanded here; \$ escapes inner-script vars)
    cat > "$KEEPALIVE_SCRIPT" <<KEOF
#!/bin/bash
# If ppp0 already has an IP, do not tear down the tunnel; just monitor.
if ip -4 addr show dev ppp0 2>/dev/null | grep -q "inet "; then
    while ip -4 addr show dev ppp0 2>/dev/null | grep -q "inet "; do
        sleep 15
    done
    echo "VPN interface lost. Exiting for restart..."
    exit 1
fi

# 1. Clean up any stale sessions
ipsec down ${CONNECTION_NAME} 2>/dev/null
sleep 2

# 2. Start the connection
ipsec up ${CONNECTION_NAME}
sleep 2
echo "c ${CONNECTION_NAME}" > /var/run/xl2tpd/l2tp-control

# 3. Wait for the interface to appear (e.g., ppp0)
MAX_RETRIES=$MAX_RETRIES
COUNT=0
while [ \$COUNT -lt \$MAX_RETRIES ]; do
    if ip -4 addr show dev ppp0 2>/dev/null | grep -q "inet "; then
        echo "VPN connected successfully."
        break
    fi
    systemctl restart xl2tpd
    
    # 2. Wait for the daemon to fully initialize
    sleep 2
    
    # 3. Trigger the connection
    if [ -p "$CONTROL_FILE" ]; then
        echo "c $CONNECTION_NAME" > "$CONTROL_FILE"
    else
        exit 1
    fi

    sleep "$IP_RETRY_SLEEP"

    ((COUNT++))
done

# 4. The Stay Alive Loop
while ip -4 addr show dev ppp0 2>/dev/null | grep -q "inet "; do
    sleep 15
done

echo "VPN interface lost. Exiting for restart..."
exit 1
KEOF

    chmod +x "$KEEPALIVE_SCRIPT"

    # Create the systemd service file
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=L2TP VPN Keep-Alive
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$KEEPALIVE_SCRIPT
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and start the service
    systemctl daemon-reload
    systemctl enable --now vpn-keepalive.service
    
    info "--------------------------------------------------------"
    info "VPN keepalive service installed and started in the background."
    info "To check status: sudo systemctl status vpn-keepalive"
    info "To view logs:    sudo journalctl -u vpn-keepalive -f"
    info "To stop VPN:     sudo systemctl stop vpn-keepalive"
    info "--------------------------------------------------------"
    exit 0
fi

# ==========================================
# FOREGROUND MODE (Manual Run)
# ==========================================

cleanup() {
    echo ""
    info "Disconnecting VPN and cleaning up..."
    if [ -p "$CONTROL_FILE" ]; then
        echo "d $CONNECTION_NAME" > "$CONTROL_FILE"
    fi
    ipsec down "$CONNECTION_NAME" 2>/dev/null
    exit 0
}

# Trap Ctrl+C (SIGINT) and termination signals to run cleanup
trap cleanup SIGINT SIGTERM

if interface_has_vpn_ip; then
    ASSIGNED_IP=$(ip -4 addr show dev "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    info "VPN already active on $INTERFACE (IP: $ASSIGNED_IP). Press Ctrl+C to disconnect gracefully."
else
    info "Initializing IPsec (Phase 1)..."
    ipsec down "$CONNECTION_NAME" 2>/dev/null
    systemctl restart strongswan-starter
    sleep 1
    ipsec up "$CONNECTION_NAME"
    sleep 2

    info "Initializing L2TP/PPP (Phase 2)..."
    if [ -p "$CONTROL_FILE" ]; then
        echo "c $CONNECTION_NAME" > "$CONTROL_FILE"
    else
        error "Control file $CONTROL_FILE does not exist. Is xl2tpd running?"
        cleanup
    fi

    # Wait Loop for IP address assignment
    COUNT=0

    info "Waiting for IP assignment on $INTERFACE..."
    while [ $COUNT -lt $MAX_RETRIES ]; do
        if ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -q "inet "; then
            ASSIGNED_IP=$(ip -4 addr show dev "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
            info "Success: VPN connected! IP assigned is $ASSIGNED_IP"
            ip link set dev "$INTERFACE" up
            break
        fi
        warning "Retrying for IP assignment on $INTERFACE... ($COUNT/$MAX_RETRIES)"

        # 1. Clean up dead states
        systemctl restart xl2tpd
        
        # 2. Wait for the daemon to fully initialize
        sleep 2
        
        # 3. Trigger the connection
        if [ -p "$CONTROL_FILE" ]; then
            echo "c $CONNECTION_NAME" > "$CONTROL_FILE"
        else
            error "Error occured: $CONTROL_FILE doesn't exist"
        fi

        sleep "$IP_RETRY_SLEEP"
        ((COUNT++))

    done

    if [ $COUNT -eq $MAX_RETRIES ]; then
        error "VPN failed to establish the $INTERFACE interface or receive an IP."
        cleanup
    fi

    info "VPN is active. Press Ctrl+C to disconnect gracefully."
fi

# The Stay Alive Loop
while ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -q "inet "; do
    sleep 5
done

info "VPN interface lost from the server side. Exiting..."
cleanup
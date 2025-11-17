#!/bin/bash
#
# Non-Interactive Auto Installer for OV-Node (White-Label System)
# This script bypasses all interactive prompts and auto-configures the node
#

set -e

# Color codes
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m"

# Configuration variables (will be injected by SSH installer)
NODE_SERVICE_PORT="${NODE_SERVICE_PORT:-9090}"
NODE_API_KEY="${NODE_API_KEY}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
R2_BUCKET_NAME="${R2_BUCKET_NAME}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID}"
R2_PUBLIC_BASE_URL="${R2_PUBLIC_BASE_URL}"
R2_DOWNLOAD_TOKEN="${R2_DOWNLOAD_TOKEN:-8638b5a1-77df-4d24-8253-58977fa508a4}"
OPENVPN_PORT="${OPENVPN_PORT:-1194}"
OPENVPN_PROTOCOL="${OPENVPN_PROTOCOL:-udp}"

# Installation directories
APP_NAME="ov-node"
INSTALL_DIR="/opt/$APP_NAME"
REPO_URL="https://github.com/TinyActive/OpenVpn-Panel-Node"
PYTHON="/usr/bin/python3"
VENV_DIR="$INSTALL_DIR/venv"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Validation
validate_config() {
    log_info "Validating configuration..."
    
    if [ -z "$NODE_API_KEY" ]; then
        log_error "NODE_API_KEY is required"
        exit 1
    fi
    
    if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_BUCKET_NAME" ]; then
        log_error "R2 configuration is incomplete (ACCESS_KEY_ID, SECRET_ACCESS_KEY, BUCKET_NAME required)"
        exit 1
    fi
    
    if [ -z "$R2_ACCOUNT_ID" ]; then
        log_error "R2_ACCOUNT_ID is required"
        exit 1
    fi
    
    if [ -z "$R2_PUBLIC_BASE_URL" ]; then
        log_error "R2_PUBLIC_BASE_URL is required"
        exit 1
    fi
    
    log_success "Configuration validated"
}

# Install system dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -y
    apt-get install -y python3 python3-pip python3-venv wget curl git iptables openssl ca-certificates gnupg
    
    log_success "System dependencies installed"
}

# Auto-configure OpenVPN (non-interactive)
install_openvpn() {
    log_info "Installing OpenVPN in non-interactive mode..."
    
    # Check if OpenVPN is already installed
    if [ -f "/etc/openvpn/server/server.conf" ]; then
        log_warning "OpenVPN is already installed, skipping installation"
        return 0
    fi
    
    # Get the primary IP address
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
    fi
    
    if [ -z "$SERVER_IP" ]; then
        log_error "Could not detect server IP address"
        exit 1
    fi
    
    log_info "Server IP: $SERVER_IP"
    log_info "OpenVPN Port: $OPENVPN_PORT"
    log_info "OpenVPN Protocol: $OPENVPN_PROTOCOL"
    
    # Copy our custom openvpn-install.sh from repo
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    if [ -f "$SCRIPT_DIR/openvpn-install.sh" ]; then
        log_info "Using openvpn-install.sh from repository..."
        cp "$SCRIPT_DIR/openvpn-install.sh" /root/openvpn-install.sh
        chmod +x /root/openvpn-install.sh
    elif [ ! -f "/root/openvpn-install.sh" ]; then
        log_info "Downloading OpenVPN installer..."
        wget https://git.io/vpn -O /root/openvpn-install.sh
        chmod +x /root/openvpn-install.sh
    fi
    
    # Use printf to pipe all inputs to the installer script
    # This bypasses all interactive prompts
    log_info "Running OpenVPN installer with automated responses..."
    
    # Prepare automated responses:
    # 1. IP selection (just press enter for first IP)
    # 2. Port (will be auto-selected in the script)
    # 3. Protocol (will be auto-selected in the script)
    # 4. DNS (will be auto-selected in the script)
    # 5. Client name (will be auto-selected in the script)
    
    # The openvpn-install.sh we have already auto-selects everything,
    # but it might still show prompts. We just send newlines.
    export DEBIAN_FRONTEND=noninteractive
    export APPROVE_INSTALL=y
    export APPROVE_IP=$SERVER_IP
    export MENU_OPTION=1
    
    # Pipe empty responses (just press enter repeatedly)
    printf '\n\n\n\n\n\n\n\n\n\n' | bash /root/openvpn-install.sh > /tmp/openvpn_install.log 2>&1
    
    local exit_code=$?
    
    # Check if OpenVPN was installed successfully
    if [ -f "/etc/openvpn/server/server.conf" ]; then
        log_success "OpenVPN installed successfully"
        
        # Ensure OpenVPN service is running
        systemctl enable openvpn-server@server || true
        systemctl start openvpn-server@server || true
        sleep 2
        
        if systemctl is-active --quiet openvpn-server@server; then
            log_success "OpenVPN service is running"
        else
            log_warning "OpenVPN installed but service not running, will retry..."
            systemctl restart openvpn-server@server || true
        fi
        
        return 0
    else
        log_error "OpenVPN installation failed (exit code: $exit_code)"
        log_error "Installation log:"
        cat /tmp/openvpn_install.log
        exit 1
    fi
}

# Clone repository
clone_repository() {
    log_info "Setting up OV-Node repository..."
    
    if [ -d "$INSTALL_DIR" ]; then
        log_warning "Directory exists, removing..."
        rm -rf "$INSTALL_DIR"
    fi
    
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    log_success "Repository cloned to $INSTALL_DIR"
}

# Setup Python virtual environment
setup_virtualenv() {
    log_info "Creating Python virtual environment..."
    
    if [ ! -d "$VENV_DIR" ]; then
        $PYTHON -m venv "$VENV_DIR"
    fi
    
    log_info "Installing Python dependencies..."
    "$VENV_DIR/bin/pip" install --upgrade pip
    
    if [ -f "$INSTALL_DIR/requirements.txt" ]; then
        "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
    else
        log_warning "requirements.txt not found, installing basic dependencies..."
        "$VENV_DIR/bin/pip" install fastapi uvicorn psutil pydantic_settings python-dotenv colorama pexpect requests
    fi
    
    log_success "Virtual environment configured"
}

# Configure .env file
configure_env() {
    log_info "Configuring environment variables..."
    
    ENV_FILE="$INSTALL_DIR/.env"
    
    # Create .env from .env.example
    if [ -f "$INSTALL_DIR/.env.example" ]; then
        cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
    else
        log_error ".env.example not found"
        exit 1
    fi
    
    # Replace all configuration values
    sed -i "s/^SERVICE_PORT = .*/SERVICE_PORT = $NODE_SERVICE_PORT/" "$ENV_FILE"
    sed -i "s/^API_KEY = .*/API_KEY = $NODE_API_KEY/" "$ENV_FILE"
    sed -i "s/^R2_ACCESS_KEY_ID = .*/R2_ACCESS_KEY_ID = $R2_ACCESS_KEY_ID/" "$ENV_FILE"
    sed -i "s/^R2_SECRET_ACCESS_KEY = .*/R2_SECRET_ACCESS_KEY = $R2_SECRET_ACCESS_KEY/" "$ENV_FILE"
    sed -i "s/^R2_BUCKET_NAME = .*/R2_BUCKET_NAME = $R2_BUCKET_NAME/" "$ENV_FILE"
    sed -i "s/^R2_ACCOUNT_ID = .*/R2_ACCOUNT_ID = $R2_ACCOUNT_ID/" "$ENV_FILE"
    sed -i "s|^R2_PUBLIC_BASE_URL = .*|R2_PUBLIC_BASE_URL = $R2_PUBLIC_BASE_URL|" "$ENV_FILE"
    sed -i "s/^R2_DOWNLOAD_TOKEN = .*/R2_DOWNLOAD_TOKEN = $R2_DOWNLOAD_TOKEN/" "$ENV_FILE"
    
    log_success "Environment configuration complete"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service..."
    
    cat > /etc/systemd/system/ov-node.service << EOF
[Unit]
Description=OV-Node App (White-Label)
After=network.target openvpn-server@server.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/core
ExecStart=$VENV_DIR/bin/python app.py
Restart=always
RestartSec=5
Environment="PATH=$VENV_DIR/bin:/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ov-node
    
    log_success "Systemd service created"
}

# Start service
start_service() {
    log_info "Starting OV-Node service..."
    
    systemctl start ov-node
    sleep 3
    
    if systemctl is-active --quiet ov-node; then
        log_success "OV-Node service is running"
    else
        log_error "OV-Node service failed to start"
        systemctl status ov-node --no-pager
        exit 1
    fi
}

# Display summary
display_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   OV-Node Installation Completed Successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Configuration Summary:${NC}"
    echo -e "  • Node Address: ${GREEN}$SERVER_IP${NC}"
    echo -e "  • Node Port: ${GREEN}$NODE_SERVICE_PORT${NC}"
    echo -e "  • OpenVPN Port: ${GREEN}$OPENVPN_PORT${NC}"
    echo -e "  • OpenVPN Protocol: ${GREEN}$OPENVPN_PROTOCOL${NC}"
    echo -e "  • R2 Bucket: ${GREEN}$R2_BUCKET_NAME${NC}"
    echo -e "  • Service Status: ${GREEN}$(systemctl is-active ov-node)${NC}"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Check service: ${BLUE}systemctl status ov-node${NC}"
    echo -e "  2. View logs: ${BLUE}journalctl -u ov-node -f${NC}"
    echo -e "  3. The node will be automatically synced with the panel"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
}

# Main installation flow
main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}   OV-Node Auto Installer (Non-Interactive)${NC}"
    echo -e "${BLUE}   White-Label System - TinyActive${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo ""
    
    validate_config
    install_dependencies
    install_openvpn
    clone_repository
    setup_virtualenv
    configure_env
    create_systemd_service
    start_service
    display_summary
    
    exit 0
}

# Run main installation
main

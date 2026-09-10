#!/usr/bin/env bash
# WhisperTunnel installer
# Usage: bash <(curl -Ls https://raw.githubusercontent.com/freeb5d/whispertunnel/main/install.sh)
# Subcommands: install (default) | uninstall | update | reconfigure | cert | panel-creds | panel-reset

set -e

REPO="https://github.com/freeb5d/whispertunnel"
RAW="https://raw.githubusercontent.com/freeb5d/whispertunnel/main"
INSTALL_DIR="/usr/local/whispertunnel"
BIN_PATH="${INSTALL_DIR}/whispertunnel-bin"
CONFIG_PATH="${INSTALL_DIR}/config.json"
PANEL_CONFIG_PATH="${INSTALL_DIR}/panel.json"
SERVICE_PATH="/etc/systemd/system/whispertunnel.service"
MENU_PATH="/usr/local/bin/whispertunnel"

red()   { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    red "This script must be run as root (sudo)."
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) red "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

rand_str() {
  local len="${1:-16}"
  head -c 64 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

rand_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

install_binary() {
  mkdir -p "$INSTALL_DIR"
  green "Downloading WhisperTunnel binary (${ARCH})..."
  LATEST_URL="${REPO}/releases/latest/download/whispertunnel-linux-${ARCH}"
  if ! curl -Lso "$BIN_PATH" "$LATEST_URL"; then
    red "Binary download failed. Make sure a release has been published."
    exit 1
  fi
  chmod +x "$BIN_PATH"
}

install_menu() {
  green "Installing the whispertunnel management command..."
  curl -Lso "$MENU_PATH" "${RAW}/menu.sh"
  chmod +x "$MENU_PATH"
}

ask_role() {
  echo ""
  echo "Select the role for this machine:"
  echo "  1) Server  (the exit box / final destination, e.g. next to SSH)"
  echo "  2) Client  (the entry box / next to the service you want tunneled)"
  read -rp "Choice [1-2]: " ROLE_CHOICE
  case "$ROLE_CHOICE" in
    1) ROLE="server" ;;
    2) ROLE="client" ;;
    *) red "Invalid choice"; exit 1 ;;
  esac
}

ask_common() {
  read -rp "Tunnel key (secret) [enter to generate randomly]: " TKEY
  if [[ -z "$TKEY" ]]; then
    TKEY=$(rand_str 32)
    yellow "Generated random key: $TKEY"
  fi
}

issue_cert_certbot() {
  local domain="$1"
  yellow "Installing Certbot (if not already installed)..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y certbot >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y certbot >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y certbot >/dev/null 2>&1
  else
    red "Unknown package manager; install certbot manually."
    return 1
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    red "Certbot installation failed."
    return 1
  fi

  yellow "Requesting a certificate for ${domain} (port 80 must be free)..."
  systemctl stop whispertunnel 2>/dev/null || true

  if certbot certonly --standalone --non-interactive --agree-tos \
      -m "admin@${domain}" -d "${domain}"; then
    CERT_PATH="/etc/letsencrypt/live/${domain}/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/${domain}/privkey.pem"
    green "Certificate obtained successfully."
    return 0
  else
    red "Failed to obtain certificate. Make sure the domain points to this server's IP and port 80 is open."
    return 1
  fi
}

configure_server() {
  read -rp "Domain with SSL set up for it (e.g. example.com): " DOMAIN
  read -rp "Hidden WebSocket path (e.g. /assets/app.js) [default: /assets/app.js]: " WSPATH
  WSPATH=${WSPATH:-/assets/app.js}
  read -rp "Target service address:port (e.g. 127.0.0.1:22) [default: 127.0.0.1:22]: " TARGET
  TARGET=${TARGET:-127.0.0.1:22}
  read -rp "TLS listen port [default: 443]: " LISTEN_PORT
  LISTEN_PORT=${LISTEN_PORT:-443}

  echo ""
  echo "SSL certificate:"
  echo "  1) Get automatically via Certbot (recommended — needs a valid domain and open port 80)"
  echo "  2) Enter path to an existing certificate manually"
  read -rp "Choice [1-2]: " CERT_CHOICE

  if [[ "$CERT_CHOICE" == "1" ]]; then
    if ! issue_cert_certbot "$DOMAIN"; then
      yellow "Falling back to manual entry."
      read -rp "Path to fullchain.pem: " CERT_PATH
      read -rp "Path to privkey.pem: " KEY_PATH
    fi
  else
    read -rp "Path to fullchain.pem: " CERT_PATH
    read -rp "Path to privkey.pem: " KEY_PATH
  fi

  cat > "$CONFIG_PATH" <<EOF
{
  "role": "server",
  "domain": "$DOMAIN",
  "ws_path": "$WSPATH",
  "target": "$TARGET",
  "listen_port": $LISTEN_PORT,
  "tunnel_key": "$TKEY",
  "cert_path": "$CERT_PATH",
  "key_path": "$KEY_PATH"
}
EOF
}

configure_client() {
  read -rp "Server address (wss://example.com/assets/app.js): " REMOTE_URL
  read -rp "Local port that apps/services will connect to [default: 2222]: " LOCAL_PORT
  LOCAL_PORT=${LOCAL_PORT:-2222}

  cat > "$CONFIG_PATH" <<EOF
{
  "role": "client",
  "remote_url": "$REMOTE_URL",
  "local_addr": "127.0.0.1:$LOCAL_PORT",
  "tunnel_key": "$TKEY"
}
EOF
}

ask_panel_exposure() {
  echo ""
  echo "Web panel access:"
  echo "  1) Localhost only (recommended — reach it via 'ssh -L 8080:127.0.0.1:<port> user@server')"
  echo "  2) All interfaces (reachable directly at http://<server-ip>:<port>/, protected only by the panel login)"
  read -rp "Choice [1-2, default: 1]: " PANEL_EXPOSURE_CHOICE
  case "$PANEL_EXPOSURE_CHOICE" in
    2) PANEL_LISTEN_ADDR="0.0.0.0" ;;
    *) PANEL_LISTEN_ADDR="127.0.0.1" ;;
  esac
}

configure_panel() {
  ask_panel_exposure
  PANEL_PORT=$(rand_port)
  PANEL_USER="admin_$(rand_str 6)"
  PANEL_PASS=$(rand_str 20)

  cat > "$PANEL_CONFIG_PATH" <<EOF
{
  "listen_addr": "$PANEL_LISTEN_ADDR",
  "listen_port": $PANEL_PORT,
  "username": "$PANEL_USER",
  "password": "$PANEL_PASS"
}
EOF
  chmod 600 "$PANEL_CONFIG_PATH"
}

install_service() {
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=WhisperTunnel Service (tunnel + panel)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -config ${CONFIG_PATH} -panel-config ${PANEL_CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable whispertunnel
  systemctl restart whispertunnel
}

server_ip() {
  curl -s -4 --max-time 3 ifconfig.me 2>/dev/null || curl -s -4 --max-time 3 icanhazip.com 2>/dev/null || echo "<your-server-ip>"
}

# panel_url prints how to reach the panel given its configured listen_addr:
# a direct URL when bound to all interfaces, or an ssh -L hint when
# restricted to localhost (the panel isn't reachable from outside in that case).
panel_url() {
  local addr port
  addr=$(grep -o '"listen_addr"[^,}]*' "$PANEL_CONFIG_PATH" 2>/dev/null | sed 's/.*: *"//;s/"//')
  port=$(grep -o '"listen_port"[^,}]*' "$PANEL_CONFIG_PATH" 2>/dev/null | grep -o '[0-9]*')
  if [[ "$addr" == "127.0.0.1" || "$addr" == "localhost" ]]; then
    echo "Localhost only — from your machine, run:"
    echo "   ssh -L 8080:127.0.0.1:${port} <user>@$(server_ip)"
    echo "then open: http://127.0.0.1:8080/"
  else
    echo "URL:      http://$(server_ip):${port}/"
  fi
}

status_check() {
  sleep 1
  if systemctl is-active --quiet whispertunnel; then
    green "WhisperTunnel installed and running successfully (tunnel + panel in one service)."
  else
    red "Service did not come up. Check logs: journalctl -u whispertunnel -e"
  fi

  echo ""
  echo "=================================================="
  echo " Web panel:"
  panel_url | sed 's/^/   /'
  echo "   Username: ${PANEL_USER}"
  echo "   Password: ${PANEL_PASS}"
  echo "=================================================="
  yellow "Save these credentials now — the password is not shown again."
  echo ""
  echo "To manage from the terminal instead, run:"
  green "    whispertunnel"
  echo ""
}

do_install() {
  require_root
  detect_arch

  echo "=============================================="
  echo "        WhisperTunnel Installer"
  echo "=============================================="

  install_binary
  install_menu
  ask_role
  ask_common

  if [[ "$ROLE" == "server" ]]; then
    configure_server
  else
    configure_client
  fi

  configure_panel
  install_service
  status_check
}

do_uninstall() {
  require_root
  systemctl stop whispertunnel 2>/dev/null || true
  systemctl disable whispertunnel 2>/dev/null || true
  rm -f "$SERVICE_PATH"
  rm -rf "$INSTALL_DIR"
  rm -f "$MENU_PATH"
  systemctl daemon-reload
  green "WhisperTunnel has been removed."
}

do_update() {
  require_root
  detect_arch
  install_binary
  install_menu
  systemctl restart whispertunnel
  green "WhisperTunnel updated."
}

do_reconfigure() {
  require_root
  ask_role
  ask_common
  if [[ "$ROLE" == "server" ]]; then
    configure_server
  else
    configure_client
  fi
  systemctl restart whispertunnel
  green "Config rewritten and service restarted."
}

do_cert() {
  require_root
  if [[ ! -f "$CONFIG_PATH" ]]; then
    red "Config not found; run the installer first."
    exit 1
  fi
  DOMAIN=$(grep -o '"domain"[^,}]*' "$CONFIG_PATH" | sed 's/.*: *"//;s/"//')
  if [[ -z "$DOMAIN" ]]; then
    read -rp "Domain: " DOMAIN
  fi
  if issue_cert_certbot "$DOMAIN"; then
    sed -i "s#\"cert_path\": *\"[^\"]*\"#\"cert_path\": \"$CERT_PATH\"#" "$CONFIG_PATH"
    sed -i "s#\"key_path\": *\"[^\"]*\"#\"key_path\": \"$KEY_PATH\"#" "$CONFIG_PATH"
    systemctl restart whispertunnel
    green "Certificate updated and service restarted."
  fi
}

do_panel_creds() {
  require_root
  if [[ ! -f "$PANEL_CONFIG_PATH" ]]; then
    red "Panel config not found."
    exit 1
  fi
  PANEL_USER=$(grep -o '"username"[^,}]*' "$PANEL_CONFIG_PATH" | sed 's/.*: *"//;s/"//')
  PANEL_PASS=$(grep -o '"password"[^,}]*' "$PANEL_CONFIG_PATH" | sed 's/.*: *"//;s/"//')
  panel_url
  echo "Username: ${PANEL_USER}"
  echo "Password: ${PANEL_PASS}"
}

do_panel_reset() {
  require_root
  configure_panel
  systemctl restart whispertunnel
  do_panel_creds
}

case "$1" in
  uninstall) do_uninstall ;;
  update) do_update ;;
  reconfigure) do_reconfigure ;;
  cert) do_cert ;;
  panel-creds) do_panel_creds ;;
  panel-reset) do_panel_reset ;;
  *) do_install ;;
esac

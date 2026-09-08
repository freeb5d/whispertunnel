#!/usr/bin/env bash
# WhisperTunnel management menu — invoked by typing: whispertunnel
# Installed to /usr/local/bin/whispertunnel by install.sh

INSTALL_DIR="/usr/local/whispertunnel"
BIN_PATH="${INSTALL_DIR}/whispertunnel-bin"
CONFIG_PATH="${INSTALL_DIR}/config.json"
SERVICE_NAME="whispertunnel"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALLER_URL="https://raw.githubusercontent.com/freeb5d/whispertunnel/main/install.sh"

red()   { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
cyan()  { echo -e "\033[36m$1\033[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    red "This command must be run as root (sudo whispertunnel)."
    exit 1
  fi
}

press_enter() {
  echo ""
  read -rp "Press Enter to return to the menu..." _
}

show_status_line() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "Service status: \033[32m* running\033[0m"
  else
    echo -e "Service status: \033[31m* stopped\033[0m"
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    ROLE=$(grep -o '"role"[^,}]*' "$CONFIG_PATH" | sed 's/.*: *"//;s/"//')
    echo "Role: ${ROLE:-unknown}"
  fi
}

do_start()    { systemctl start "$SERVICE_NAME"    && green "Service started."    || red "Failed to start."; }
do_stop()     { systemctl stop "$SERVICE_NAME"     && green "Service stopped."   || red "Failed to stop."; }
do_restart()  { systemctl restart "$SERVICE_NAME"  && green "Service restarted." || red "Failed to restart."; }
do_enable()   { systemctl enable "$SERVICE_NAME"   && green "Start on boot enabled."; }
do_disable()  { systemctl disable "$SERVICE_NAME"  && yellow "Start on boot disabled."; }

do_status_full() {
  echo ""
  systemctl status "$SERVICE_NAME" --no-pager -l
  press_enter
}

do_logs() {
  echo ""
  yellow "Press Ctrl+C to exit the log view."
  echo ""
  journalctl -u "$SERVICE_NAME" -f
}

do_show_config() {
  echo ""
  if [[ -f "$CONFIG_PATH" ]]; then
    cyan "Config file ($CONFIG_PATH):"
    echo ""
    cat "$CONFIG_PATH"
  else
    red "Config file not found."
  fi
  press_enter
}

do_edit_config() {
  ${EDITOR:-nano} "$CONFIG_PATH"
  echo ""
  read -rp "Restart the service to apply changes? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    do_restart
  fi
  press_enter
}

do_change_key() {
  echo ""
  read -rp "New tunnel key [enter to generate randomly]: " NEWKEY
  if [[ -z "$NEWKEY" ]]; then
    NEWKEY=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    sed -i "s/\"tunnel_key\": *\"[^\"]*\"/\"tunnel_key\": \"$NEWKEY\"/" "$CONFIG_PATH"
    green "New key: $NEWKEY"
    yellow "Note: set this same key on the other side (server/client) too."
    do_restart
  else
    red "Config file not found."
  fi
  press_enter
}

do_reconfigure() {
  echo ""
  yellow "This will overwrite the current config."
  read -rp "Continue? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    bash <(curl -Ls "$INSTALLER_URL") reconfigure
  fi
  press_enter
}

do_update() {
  echo ""
  yellow "Fetching the latest release from GitHub..."
  bash <(curl -Ls "$INSTALLER_URL") update
  press_enter
}

do_uninstall() {
  echo ""
  red "This will completely remove the WhisperTunnel service, binary, and config."
  read -rp "Are you sure? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    bash <(curl -Ls "$INSTALLER_URL") uninstall
    exit 0
  fi
  press_enter
}

do_cert() {
  echo ""
  bash <(curl -Ls "$INSTALLER_URL") cert
  press_enter
}

do_version() {
  echo ""
  if [[ -x "$BIN_PATH" ]]; then
    "$BIN_PATH" -version 2>/dev/null || echo "Version not available."
  else
    red "Binary not found."
  fi
  press_enter
}

main_menu() {
  clear
  echo "=================================================="
  echo "              WhisperTunnel Manager"
  echo "=================================================="
  show_status_line
  echo "--------------------------------------------------"
  echo " 1) Start"
  echo " 2) Stop"
  echo " 3) Restart"
  echo " 4) Full status"
  echo " 5) View live logs"
  echo " 6) Show config"
  echo " 7) Edit config"
  echo " 8) Change tunnel key"
  echo " 9) Reconfigure (role/domain/port...)"
  echo "10) Enable start on boot"
  echo "11) Disable start on boot"
  echo "12) Update to latest release"
  echo "13) Uninstall"
  echo "14) Get/renew SSL certificate (Certbot)"
  echo " 0) Exit"
  echo "=================================================="
  read -rp "Choose an option: " choice

  case "$choice" in
    1) do_start ;;
    2) do_stop ;;
    3) do_restart ;;
    4) do_status_full ;;
    5) do_logs ;;
    6) do_show_config ;;
    7) do_edit_config ;;
    8) do_change_key ;;
    9) do_reconfigure ;;
    10) do_enable ;;
    11) do_disable ;;
    12) do_update ;;
    13) do_uninstall ;;
    14) do_cert ;;
    0) exit 0 ;;
    *) red "Invalid choice" ;;
  esac
}

require_root

if [[ -n "$1" ]]; then
  case "$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    status) systemctl status "$SERVICE_NAME" --no-pager -l ;;
    logs) journalctl -u "$SERVICE_NAME" -f ;;
    uninstall) bash <(curl -Ls "$INSTALLER_URL") uninstall ;;
    *) red "Invalid command: $1" ;;
  esac
  exit 0
fi

while true; do
  main_menu
  echo ""
  read -rp "Press Enter to return to the menu..." _
done

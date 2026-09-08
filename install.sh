#!/usr/bin/env bash
# WhisperTunnel installer
# Usage: bash <(curl -Ls https://raw.githubusercontent.com/<you>/whispertunnel/main/install.sh)

set -e

REPO="https://github.com/freeb5d/whispertunnel"          # <-- change to your repo
RAW="https://raw.githubusercontent.com/freeb5d/whispertunnel/main" # <-- change to your repo
INSTALL_DIR="/usr/local/whispertunnel"
BIN_PATH="${INSTALL_DIR}/whispertunnel"
CONFIG_PATH="${INSTALL_DIR}/config.json"
SERVICE_PATH="/etc/systemd/system/whispertunnel.service"

red()   { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    red "این اسکریپت باید با دسترسی root اجرا شود (sudo)."
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) red "معماری پشتیبانی نمی‌شود: $(uname -m)"; exit 1 ;;
  esac
}

install_binary() {
  mkdir -p "$INSTALL_DIR"
  green "در حال دریافت باینری WhisperTunnel (${ARCH})..."
  # از GitHub Releases باینری از پیش build شده را می‌گیرد
  LATEST_URL="${REPO}/releases/latest/download/whispertunnel-linux-${ARCH}"
  if ! curl -Lso "$BIN_PATH" "$LATEST_URL"; then
    red "دانلود باینری ناموفق بود. مطمئن شوید ریلیز منتشر شده است."
    exit 1
  fi
  chmod +x "$BIN_PATH"
}

ask_role() {
  echo ""
  echo "نقش این سرور را انتخاب کنید:"
  echo "  1) Server  (روی سرور خارج / مقصد نهایی، مثلا کنار SSH)"
  echo "  2) Client  (روی سرور داخل / کنار سرویسی که میخوای تونل شه)"
  read -rp "انتخاب [1-2]: " ROLE_CHOICE
  case "$ROLE_CHOICE" in
    1) ROLE="server" ;;
    2) ROLE="client" ;;
    *) red "انتخاب نامعتبر"; exit 1 ;;
  esac
}

ask_common() {
  read -rp "کلید مخفی تونل (Tunnel Key) [enter برای تولید تصادفی]: " TKEY
  if [[ -z "$TKEY" ]]; then
    TKEY=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
    yellow "کلید تصادفی تولید شد: $TKEY"
  fi
}

configure_server() {
  read -rp "دامنه‌ای که SSL روش ست شده (مثلا example.com): " DOMAIN
  read -rp "مسیر پنهان وب‌سوکت (مثلا /assets/app.js) [پیش‌فرض: /assets/app.js]: " WSPATH
  WSPATH=${WSPATH:-/assets/app.js}
  read -rp "آدرس و پورت سرویس مقصد (مثلا 127.0.0.1:22) [پیش‌فرض: 127.0.0.1:22]: " TARGET
  TARGET=${TARGET:-127.0.0.1:22}
  read -rp "پورت لیسن TLS [پیش‌فرض: 443]: " LISTEN_PORT
  LISTEN_PORT=${LISTEN_PORT:-443}
  read -rp "مسیر fullchain.pem: " CERT_PATH
  read -rp "مسیر privkey.pem: " KEY_PATH

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
  read -rp "آدرس سرور (wss://example.com/assets/app.js): " REMOTE_URL
  read -rp "پورت لوکال که کاربران/سرویس‌ها بهش وصل می‌شن [پیش‌فرض: 2222]: " LOCAL_PORT
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

install_service() {
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=WhisperTunnel Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -config ${CONFIG_PATH}
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

status_check() {
  sleep 1
  if systemctl is-active --quiet whispertunnel; then
    green "WhisperTunnel با موفقیت نصب و اجرا شد."
    echo "برای بررسی وضعیت:   systemctl status whispertunnel"
    echo "برای مشاهده لاگ:    journalctl -u whispertunnel -f"
    echo "فایل کانفیگ:        $CONFIG_PATH"
  else
    red "سرویس بالا نیامد. لاگ را بررسی کنید: journalctl -u whispertunnel -e"
  fi
}

uninstall() {
  systemctl stop whispertunnel 2>/dev/null || true
  systemctl disable whispertunnel 2>/dev/null || true
  rm -f "$SERVICE_PATH"
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload
  green "WhisperTunnel حذف شد."
  exit 0
}

main() {
  require_root
  detect_arch

  if [[ "$1" == "uninstall" ]]; then
    uninstall
  fi

  echo "=============================================="
  echo "        WhisperTunnel Installer"
  echo "=============================================="

  install_binary
  ask_role
  ask_common

  if [[ "$ROLE" == "server" ]]; then
    configure_server
  else
    configure_client
  fi

  install_service
  status_check
}

main "$@"

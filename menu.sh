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
    red "این دستور باید با دسترسی root اجرا شود (sudo whispertunnel)."
    exit 1
  fi
}

press_enter() {
  echo ""
  read -rp "برای بازگشت به منو Enter را بزنید..." _
}

show_status_line() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "وضعیت سرویس: \033[32m● در حال اجرا\033[0m"
  else
    echo -e "وضعیت سرویس: \033[31m● متوقف\033[0m"
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    ROLE=$(grep -o '"role"[^,}]*' "$CONFIG_PATH" | sed 's/.*: *"//;s/"//')
    echo "نقش: ${ROLE:-نامشخص}"
  fi
}

do_start()    { systemctl start "$SERVICE_NAME"    && green "سرویس استارت شد." || red "خطا در استارت."; }
do_stop()     { systemctl stop "$SERVICE_NAME"     && green "سرویس متوقف شد."  || red "خطا در توقف."; }
do_restart()  { systemctl restart "$SERVICE_NAME"  && green "سرویس ری‌استارت شد." || red "خطا در ری‌استارت."; }
do_enable()   { systemctl enable "$SERVICE_NAME"   && green "استارت خودکار فعال شد."; }
do_disable()  { systemctl disable "$SERVICE_NAME"  && yellow "استارت خودکار غیرفعال شد."; }

do_status_full() {
  echo ""
  systemctl status "$SERVICE_NAME" --no-pager -l
  press_enter
}

do_logs() {
  echo ""
  yellow "برای خروج از لاگ، Ctrl+C را بزنید."
  echo ""
  journalctl -u "$SERVICE_NAME" -f
}

do_show_config() {
  echo ""
  if [[ -f "$CONFIG_PATH" ]]; then
    cyan "محتوای فایل کانفیگ ($CONFIG_PATH):"
    echo ""
    cat "$CONFIG_PATH"
  else
    red "فایل کانفیگ پیدا نشد."
  fi
  press_enter
}

do_edit_config() {
  ${EDITOR:-nano} "$CONFIG_PATH"
  echo ""
  read -rp "سرویس ری‌استارت شود تا تغییرات اعمال شود؟ [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    do_restart
  fi
  press_enter
}

do_change_key() {
  echo ""
  read -rp "کلید تونل جدید [enter برای تولید تصادفی]: " NEWKEY
  if [[ -z "$NEWKEY" ]]; then
    NEWKEY=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    sed -i "s/\"tunnel_key\": *\"[^\"]*\"/\"tunnel_key\": \"$NEWKEY\"/" "$CONFIG_PATH"
    green "کلید جدید: $NEWKEY"
    yellow "توجه: باید همین کلید را در کانفیگ سرور/کلاینت طرف مقابل هم تنظیم کنید."
    do_restart
  else
    red "فایل کانفیگ پیدا نشد."
  fi
  press_enter
}

do_reconfigure() {
  echo ""
  yellow "این کار کانفیگ فعلی را بازنویسی می‌کند."
  read -rp "ادامه می‌دهید؟ [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    bash <(curl -Ls "$INSTALLER_URL") reconfigure
  fi
  press_enter
}

do_update() {
  echo ""
  yellow "دریافت آخرین نسخه از GitHub..."
  bash <(curl -Ls "$INSTALLER_URL") update
  press_enter
}

do_uninstall() {
  echo ""
  red "این کار سرویس، باینری و کانفیگ WhisperTunnel را کامل حذف می‌کند."
  read -rp "مطمئن هستید؟ [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    bash <(curl -Ls "$INSTALLER_URL") uninstall
    exit 0
  fi
  press_enter
}

do_version() {
  echo ""
  if [[ -x "$BIN_PATH" ]]; then
    "$BIN_PATH" -version 2>/dev/null || echo "نسخه در دسترس نیست."
  else
    red "باینری پیدا نشد."
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
  echo " 1) Start                 استارت سرویس"
  echo " 2) Stop                  توقف سرویس"
  echo " 3) Restart               ری‌استارت سرویس"
  echo " 4) Status (کامل)"
  echo " 5) نمایش لاگ (زنده)"
  echo " 6) نمایش کانفیگ"
  echo " 7) ویرایش کانفیگ"
  echo " 8) تغییر کلید تونل"
  echo " 9) بازپیکربندی کامل (نقش/دامنه/پورت...)"
  echo "10) فعال کردن استارت خودکار (boot)"
  echo "11) غیرفعال کردن استارت خودکار"
  echo "12) بروزرسانی به آخرین نسخه"
  echo "13) حذف کامل"
  echo " 0) خروج"
  echo "=================================================="
  read -rp "انتخاب خود را وارد کنید: " choice

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
    0) exit 0 ;;
    *) red "انتخاب نامعتبر" ;;
  esac
}

require_root

if [[ -n "$1" ]]; then
  # non-interactive shortcuts: whispertunnel start|stop|restart|status|logs|uninstall
  case "$1" in
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    status) systemctl status "$SERVICE_NAME" --no-pager -l ;;
    logs) journalctl -u "$SERVICE_NAME" -f ;;
    uninstall) bash <(curl -Ls "$INSTALLER_URL") uninstall ;;
    *) red "دستور نامعتبر: $1" ;;
  esac
  exit 0
fi

while true; do
  main_menu
  echo ""
  read -rp "برای بازگشت به منو Enter را بزنید..." _
done

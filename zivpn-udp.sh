#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0"
CONFIG_DIR="/etc/zivpn-udp"
CONFIG_FILE="${CONFIG_DIR}/config.json"
OVPN_FILE="${CONFIG_DIR}/zivpn_udp.ovpn"
AUTH_FILE="${CONFIG_DIR}/auth.txt"
LOG_FILE="/var/log/zivpn-udp.log"
SERVICE_FILE="/etc/systemd/system/zivpn-udp.service"
BOT_SERVICE_FILE="/etc/systemd/system/zivpn-bot.service"
API_SERVICE_FILE="/etc/systemd/system/zivpn-api.service"
BOT_TARGET_DIR="/opt/zivpn-udp"

# -------- Helper --------
log() { echo -e "[INFO] $*"; }
ok() { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }
err() { echo -e "\e[31m[ERR]\e[0m $*"; }
die() { err "$*"; exit 1; }
pause() { read -rp "Tekan ENTER untuk lanjut..." _; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Jalankan script ini sebagai root (sudo)."
    exit 1
  fi
}

json_get() {
  local key=$1
  ensure_config_object || return 1
  jq -r ".$key" "$CONFIG_FILE"
}

json_set() {
  local key=$1 value=$2
  ensure_config_object
  tmp=$(mktemp)
  jq --arg k "$key" --arg v "$value" 'try (.[$k] = ($v | fromjson)) catch (.[$k] = $v)' "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

ensure_config_object() {
  if [[ -f "$CONFIG_FILE" ]] && jq -e 'type=="object"' "$CONFIG_FILE" >/dev/null 2>&1; then
    return 0
  fi

  warn "config.json tidak ditemukan atau tidak valid. Membuat kerangka baru di $CONFIG_FILE"
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<'EOF_JSON'
{
  "domain": "",
  "port": 0,
  "license": "",
  "expiry": "",
  "api_url": "",
  "api_token": "",
  "telegram_bot_token": "",
  "telegram_admin_id": "",
  "created_at": "",
  "ovpn_username": "",
  "ovpn_password": ""
}
EOF_JSON
}

# -------- Dependencies --------
install_deps() {
  if command -v apt >/dev/null 2>&1; then
    log "Memperbarui dan memasang dependensi..."
    apt update -y
    apt install -y openvpn curl jq lsb-release net-tools python3 python3-pip openssl
  else
    warn "apt tidak tersedia, instalasi paket dilewati. Pasang openvpn, curl, jq, python3 secara manual."
  fi
}

# -------- OVPN handling --------
check_udp_only() {
  if [[ -f "$OVPN_FILE" ]]; then
    if ! grep -q "^proto udp" "$OVPN_FILE"; then
      warn "proto bukan udp, memperbaiki..."
      sed -i 's/^proto .*/proto udp/g' "$OVPN_FILE"
    fi
    if ! grep -q "remote .* udp$" "$OVPN_FILE"; then
      warn "Baris remote tidak memiliki suffix udp. Pastikan server mendukung UDP."
    fi
  fi
}

create_ovpn() {
  local domain=$1 port=$2
  cat >"$OVPN_FILE" <<EOF_OVPN
client
dev tun
proto udp
remote ${domain} ${port} udp
ca ${CONFIG_DIR}/ca.crt
auth-user-pass ${AUTH_FILE}
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-CBC
auth SHA256
redirect-gateway def1
verb 3

# Sertifikat / kunci harus disisipkan sesuai kebutuhan:
# <ca> ... </ca>
# <cert> ... </cert>
# <key> ... </key>
# <tls-auth> ... </tls-auth>
EOF_OVPN
  check_udp_only
}

generate_ca_certificate() {
  local ca_key="${CONFIG_DIR}/ca.key"
  local ca_crt="${CONFIG_DIR}/ca.crt"

  if [[ -s "$ca_crt" && -s "$ca_key" ]]; then
    ok "Sertifikat CA sudah ada di $ca_crt"
    return
  fi

  log "Membuat sertifikat CA self-signed untuk OpenVPN..."
  mkdir -p "$CONFIG_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$ca_key" -out "$ca_crt" \
    -days 3650 -subj "/CN=ZIVPN-UDP-CA" >/dev/null 2>&1
  chmod 600 "$ca_key"
  ok "Sertifikat CA otomatis dibuat di $ca_crt"
}

create_auth_file() {
  local username=$1 password=$2
  mkdir -p "$CONFIG_DIR"
  cat >"$AUTH_FILE" <<EOF_AUTH
${username}
${password}
EOF_AUTH
  chmod 600 "$AUTH_FILE"
}

refresh_auth_from_config() {
  ensure_config_object
  local username=$(json_get ovpn_username)
  local password=$(json_get ovpn_password)
  if [[ -z "$username" || "$username" == "null" || -z "$password" || "$password" == "null" ]]; then
    warn "Username/password OpenVPN belum dikonfigurasi di config.json"
    return
  fi
  create_auth_file "$username" "$password"
}

create_config_json() {
  local domain=$1 port=$2 license=$3 expiry=$4 api_url=$5 api_token=$6 bot_token=$7 admin_id=$8 ovpn_user=$9 ovpn_pass=${10}
  mkdir -p "$CONFIG_DIR"
  cat >"$CONFIG_FILE" <<EOF_JSON
{
  "domain": "${domain}",
  "port": ${port},
  "license": "${license}",
  "expiry": "${expiry}",
  "api_url": "${api_url}",
  "api_token": "${api_token}",
  "telegram_bot_token": "${bot_token}",
  "telegram_admin_id": "${admin_id}",
  "created_at": "$(date '+%Y-%m-%d %H:%M:%S')",
  "ovpn_username": "${ovpn_user}",
  "ovpn_password": "${ovpn_pass}"
}
EOF_JSON
}

create_tunnel_service() {
  cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=ZIVPN UDP Auto Tunnel (OpenVPN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/sbin/openvpn --config ${OVPN_FILE} --log-append ${LOG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable zivpn-udp
  systemctl start zivpn-udp
}

create_bot_service() {
  mkdir -p "$BOT_TARGET_DIR"
  cp "$(pwd)/telegram_bot.py" "${BOT_TARGET_DIR}/telegram_bot.py"
  cat >"$BOT_SERVICE_FILE" <<EOF_BOT
[Unit]
Description=ZIVPN Telegram Bot Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${BOT_TARGET_DIR}
ExecStart=/usr/bin/python3 ${BOT_TARGET_DIR}/telegram_bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_BOT
  systemctl daemon-reload
  systemctl enable zivpn-bot
  systemctl start zivpn-bot
}

create_local_api_service() {
  local token=$1 port=${2:-8686}
  mkdir -p "$BOT_TARGET_DIR"
  cp "$(pwd)/local_api.py" "${BOT_TARGET_DIR}/local_api.py"
  cat >"$API_SERVICE_FILE" <<EOF_API
[Unit]
Description=ZIVPN Local API Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${BOT_TARGET_DIR}
ExecStart=/usr/bin/python3 ${BOT_TARGET_DIR}/local_api.py --host 127.0.0.1 --port ${port} --db ${CONFIG_DIR}/local_api_db.json --token ${token}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_API
  systemctl daemon-reload
  systemctl enable zivpn-api
  systemctl start zivpn-api
}

# -------- API helpers --------
load_api_env() {
  ensure_config_object
  API_URL=$(json_get api_url)
  API_TOKEN=$(json_get api_token)
  [[ "$API_URL" == "null" || -z "$API_URL" ]] && die "api_url belum dikonfigurasi."
}

curl_api() {
  local path=$1
  local url="${API_URL%/}/${path}"
  local resp
  if [[ -n "$API_TOKEN" && "$API_TOKEN" != "null" ]]; then
    if ! resp=$(curl -fsS -H "Authorization: Bearer ${API_TOKEN}" "$url"); then
      die "Gagal memanggil API ${url}. Periksa koneksi atau token."
    fi
  else
    if ! resp=$(curl -fsS "$url"); then
      die "Gagal memanggil API ${url}. Periksa koneksi atau endpoint."
    fi
  fi
  echo "$resp"
}

api_ping() { load_api_env; curl_api "ping"; }
api_users() { load_api_env; curl_api "users"; }
api_info() { load_api_env; curl_api "info"; }
api_add_user() { load_api_env; curl_api "add?user=$1&pass=$2&days=$3"; }
api_trial() { load_api_env; curl_api "trial?minutes=$1"; }
api_delete() { load_api_env; curl_api "delete?user=$1"; }
api_renew() { load_api_env; curl_api "renew?user=$1&days=$2"; }
api_changepass() { load_api_env; curl_api "changepass?user=$1&pass=$2"; }
api_backup() { load_api_env; curl_api "backup"; }
api_restore() { load_api_env; curl_api "restore?id=$1"; }

# -------- Menu actions --------
install_all() {
  install_deps
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"

  read -rp "DOMAIN/HOST ZIVPN: " domain
  while true; do
    read -rp "PORT UDP ZIVPN (1-65535): " port
    if [[ $port =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)); then
      break
    else
      err "Port tidak valid."
    fi
  done
  read -rp "LICENSE KEY: " license
  read -rp "EXPIRY DATE (YYYY-MM-DD): " expiry
  read -rp "USERNAME OpenVPN (sesuai dari panel): " ovpn_user
  read -rsp "PASSWORD OpenVPN: " ovpn_pass; echo
  read -rp "Gunakan API lokal tanpa panel? [y/N]: " use_local_api
  api_url=""
  api_token=""
  if [[ "$use_local_api" =~ ^[Yy]$ ]]; then
    read -rp "Port API lokal (default 8686): " api_port
    api_port=${api_port:-8686}
    if ! [[ $api_port =~ ^[0-9]+$ ]] || ((api_port < 1 || api_port > 65535)); then
      die "Port API lokal tidak valid."
    fi
    read -rp "Token API lokal (opsional, biarkan kosong jika tidak ingin): " api_token
    api_url="http://127.0.0.1:${api_port}"
  else
    read -rp "API URL (contoh https://domain/api): " api_url
    read -rp "API TOKEN (boleh kosong): " api_token
  fi
  read -rp "TELEGRAM BOT TOKEN (boleh kosong): " bot_token
  read -rp "TELEGRAM ADMIN CHAT ID (boleh kosong): " admin_id

  create_auth_file "$ovpn_user" "$ovpn_pass"
  create_ovpn "$domain" "$port"
  generate_ca_certificate
  create_config_json "$domain" "$port" "$license" "$expiry" "$api_url" "$api_token" "$bot_token" "$admin_id" "$ovpn_user" "$ovpn_pass"
  if [[ "$use_local_api" =~ ^[Yy]$ ]]; then
    create_local_api_service "$api_token" "$api_port"
    ok "API lokal dijalankan di ${api_url}"
  fi
  create_tunnel_service
  ok "Instalasi selesai. Tunnel berjalan dengan service zivpn-udp."
}

service_start() {
  refresh_auth_from_config
  if systemctl start zivpn-udp; then
    ok "Service dimulai."
  else
    err "Gagal memulai service zivpn-udp."
  fi
}

service_stop() {
  if systemctl stop zivpn-udp; then
    ok "Service dihentikan."
  else
    err "Gagal menghentikan service zivpn-udp."
  fi
}

service_restart() {
  refresh_auth_from_config
  if systemctl restart zivpn-udp; then
    ok "Service direstart."
  else
    err "Gagal merestart service zivpn-udp."
  fi
}

service_status() { systemctl status zivpn-udp || true; }
service_logs() { tail -n 50 "$LOG_FILE"; }

local_api_start() { systemctl start zivpn-api && ok "API lokal dimulai." || warn "Gagal memulai API lokal."; }
local_api_stop() { systemctl stop zivpn-api && ok "API lokal dihentikan." || warn "Gagal menghentikan API lokal."; }
local_api_status() { systemctl status zivpn-api || true; }

show_vps_info() {
  echo "OS       : $(lsb_release -ds 2>/dev/null || echo \"Unknown\")"
  echo "Kernel   : $(uname -r)"
  echo "CPU      : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
  echo "Cores    : $(nproc)"
  echo "RAM      : $(free -m | awk '/Mem:/ {print $2" MB"}')"
  echo "Disk     : $(df -h / | awk 'NR==2 {print $2" total, "$4" free"}')"
}

edit_ovpn() { ${EDITOR:-nano} "$OVPN_FILE"; service_restart; }
edit_json() { ${EDITOR:-nano} "$CONFIG_FILE"; }

api_menu() {
  ensure_config_object
  local current_api_url=$(json_get api_url)
  local api_mode=""
  if [[ "$current_api_url" == http://127.0.0.1:* || "$current_api_url" == http://localhost:* ]]; then
    api_mode="(API lokal)"
  fi
  while true; do
    echo "\n[API MANAGER]"
    echo "API URL: ${current_api_url:-belum diset} ${api_mode}"
    echo "[1] List Akun"
    echo "[2] Tambah User"
    echo "[3] Trial User"
    echo "[4] Hapus User"
    echo "[5] Perpanjang User"
    echo "[6] Ubah Password User"
    echo "[7] Backup Akun"
    echo "[8] Restore Akun"
    echo "[9] Start API Lokal"
    echo "[10] Stop API Lokal"
    echo "[11] Status API Lokal"
    echo "[0] Kembali"
    read -rp "Pilih: " choice
    case $choice in
      1) api_users | jq .; pause ;;
      2) read -rp "Username: " u; read -rp "Password: " p; read -rp "Hari: " d; api_add_user "$u" "$p" "$d"; pause ;;
      3) read -rp "Menit trial: " m; api_trial "$m"; pause ;;
      4) read -rp "Username: " u; api_delete "$u"; pause ;;
      5) read -rp "Username: " u; read -rp "Hari: " d; api_renew "$u" "$d"; pause ;;
      6) read -rp "Username: " u; read -rp "Password baru: " p; api_changepass "$u" "$p"; pause ;;
      7) api_backup; pause ;;
      8) read -rp "Backup ID: " bid; api_restore "$bid"; pause ;;
      9) local_api_start; pause ;;
      10) local_api_stop; pause ;;
      11) local_api_status; pause ;;
      0) break ;;
      *) warn "Pilihan tidak dikenal" ;;
    esac
  done
}

bot_menu() {
  while true; do
    echo "\n[TELEGRAM BOT MANAGER]"
    echo "[1] Setup Bot"
    echo "[2] Start Bot Service"
    echo "[3] Stop Bot Service"
    echo "[4] Status Bot Service"
    echo "[0] Kembali"
    read -rp "Pilih: " choice
    case $choice in
      1)
        read -rp "Telegram Bot Token: " bot_token
        read -rp "Telegram Admin Chat ID: " admin_id
        json_set telegram_bot_token "$bot_token"
        json_set telegram_admin_id "$admin_id"
        create_bot_service
        ok "Bot disiapkan dan dijalankan."
        pause
        ;;
      2) systemctl start zivpn-bot; ok "Bot service dimulai."; pause ;;
      3) systemctl stop zivpn-bot; ok "Bot service dihentikan."; pause ;;
      4) systemctl status zivpn-bot; pause ;;
      0) break ;;
      *) warn "Pilihan tidak dikenal" ;;
    esac
  done
}

print_banner() {
  local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  local domain=$(json_get domain 2>/dev/null || echo '-')
  local license=$(json_get license 2>/dev/null || echo '-')
  local expiry=$(json_get expiry 2>/dev/null || echo '-')
cat <<'BANNER'
  ███████╗██╗██╗   ██╗██████╗ ███╗   ██╗
  ██╔════╝██║██║   ██║██╔══██╗████╗  ██║
  ███████╗██║██║   ██║██████╔╝██╔██╗ ██║
  ╚════██║██║██║   ██║██╔═══╝ ██║╚██╗██║
  ███████║██║╚██████╔╝██║     ██║ ╚████║
  ╚══════╝╚═╝ ╚═════╝ ╚═╝     ╚═╝  ╚═══╝
        ZIVPN UDP MANAGER v1.0
BANNER
  echo "IP Server : ${ip:--}"
  echo "Domain    : ${domain:--}"
  echo "---------------------------------------"
  echo "License   : ${license:--}"
  echo "Expiry    : ${expiry:--}"
  echo "---------------------------------------"
}

main_menu() {
  while true; do
    print_banner
    echo "[1] Install / Setup Awal"
    echo "[2] Start Tunnel"
    echo "[3] Stop Tunnel"
    echo "[4] Restart Tunnel"
    echo "[5] VPS Information"
    echo "[6] Tunnel Logs"
    echo "[7] Edit Config OVPN"
    echo "[8] Edit Config JSON"
    echo "[9] API Manager"
    echo "[10] Telegram Bot Manager"
    echo "[0] Exit"
    read -rp "Pilih menu: " choice
    case $choice in
      1) install_all ;;
      2) service_start; pause ;;
      3) service_stop; pause ;;
      4) service_restart; pause ;;
      5) show_vps_info; pause ;;
      6) service_logs; pause ;;
      7) edit_ovpn; pause ;;
      8) edit_json; pause ;;
      9) api_menu ;;
      10) bot_menu ;;
      0) exit 0 ;;
      *) warn "Pilihan tidak dikenal." ;;
    esac
  done
}

handle_args() {
  case ${1:-menu} in
    install) install_all ;;
    start) service_start ;;
    stop) service_stop ;;
    restart) service_restart ;;
    status) service_status ;;
    logs) service_logs ;;
    menu) main_menu ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
}

require_root
handle_args "$@"

#!/usr/bin/env bash
set -euo pipefail

APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-1200}"
LOG_FILE="/root/azmov-panel-$(date +%F-%H%M%S).log"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
  fi
}

ask() {
  local var="$1"
  local prompt="$2"
  local def="${3:-}"
  local val
  if [ -n "$def" ]; then
    read -rp "$prompt [$def]: " val
    val="${val:-$def}"
  else
    read -rp "$prompt: " val
  fi
  printf -v "$var" '%s' "$val"
}

ask_yes_no() {
  local var="$1"
  local prompt="$2"
  local def="${3:-y}"
  local val
  read -rp "$prompt [$def]: " val
  val="${val:-$def}"
  case "$val" in
    y|Y|yes|YES|Yes) printf -v "$var" '%s' "y" ;;
    *) printf -v "$var" '%s' "n" ;;
  esac
}

start_log() {
  mkdir -p /root
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "=== AZMOV PANEL LOG: $LOG_FILE ==="
}

wait_for_apt_locks() {
  local waited=0
  local holders

  while true; do
    holders="$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true)"
    if [ -z "$holders" ]; then
      return 0
    fi

    if [ "$waited" -ge "$APT_LOCK_TIMEOUT" ]; then
      echo "apt/dpkg lock is still held after ${APT_LOCK_TIMEOUT}s."
      echo "Lock holders:$holders"
      echo "Check: ps -fp $holders"
      exit 1
    fi

    echo "Waiting for apt/dpkg lock holders:$holders (${waited}s/${APT_LOCK_TIMEOUT}s)"
    sleep 10
    waited=$((waited + 10))
  done
}

install_base_packages() {
  wait_for_apt_locks
  apt update
  wait_for_apt_locks
  apt install -y curl dnsutils ca-certificates
}

optimize_node_profile() {
  local profile="$1"
  local mtu="$2"
  local rmem="67108864"
  local wmem="67108864"
  local syn_backlog="65536"
  local somaxconn="65535"
  local tw_buckets="6000"
  local txqueue="5000"

  case "$profile" in
    default)
      rmem="67108864"; wmem="67108864"; syn_backlog="65536"; somaxconn="65535"; tw_buckets="6000"; txqueue="5000"
      ;;
    latency)
      rmem="33554432"; wmem="33554432"; syn_backlog="65536"; somaxconn="65535"; tw_buckets="12000"; txqueue="3000"
      ;;
    throughput)
      rmem="134217728"; wmem="134217728"; syn_backlog="131072"; somaxconn="131072"; tw_buckets="24000"; txqueue="10000"
      ;;
  esac

  cat >/etc/sysctl.d/99-remnawave-grpc-optimization.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $rmem
net.core.wmem_max = $wmem
net.ipv4.tcp_rmem = 4096 87380 $rmem
net.ipv4.tcp_wmem = 4096 65536 $wmem
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.somaxconn = $somaxconn
net.ipv4.tcp_max_tw_buckets = $tw_buckets
net.ipv4.tcp_tw_reuse = 1
EOF

  sysctl --system >/dev/null || true

  if [ -n "$mtu" ]; then
    ip link set dev ens3 mtu "$mtu" || true
    cat >/etc/systemd/system/remnawave-network-optimize.service <<EOF
[Unit]
Description=Apply Remnawave network optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set dev ens3 mtu $mtu
ExecStart=/usr/sbin/tc qdisc replace dev ens3 root fq
ExecStart=/usr/sbin/ip link set dev ens3 txqueuelen $txqueue
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnawave-network-optimize.service || true
  fi

  tc qdisc replace dev ens3 root fq || true
  ip link set dev ens3 txqueuelen "$txqueue" || true
}

optimization_menu() {
  local choice mtu
  install_base_packages
  apt install -y iproute2
  while true; do
    clear || true
    echo "========================"
    echo "       AZMOV PANEL"
    echo "========================"
    echo "Optimization profiles"
    echo
    echo "1. Default balanced (recommended, MTU 1476)"
    echo "2. Low latency (lighter buffers, MTU 1476)"
    echo "3. High throughput (larger buffers, MTU 1476)"
    echo "4. Custom MTU only"
    echo "5. Disable persistent MTU service"
    echo "0. Back"
    echo
    read -rp "Select: " choice
    case "$choice" in
      1) optimize_node_profile "default" "1476"; read -rp "Applied. Press Enter..." _ ;;
      2) optimize_node_profile "latency" "1476"; read -rp "Applied. Press Enter..." _ ;;
      3) optimize_node_profile "throughput" "1476"; read -rp "Applied. Press Enter..." _ ;;
      4) ask mtu "MTU value, empty to keep current" "1476"; optimize_node_profile "default" "$mtu"; read -rp "Applied. Press Enter..." _ ;;
      5) systemctl disable --now remnawave-network-optimize.service || true; ip link set dev ens3 mtu 1500 || true; read -rp "Disabled and MTU set to 1500. Press Enter..." _ ;;
      0) return 0 ;;
      *) read -rp "Unknown option. Press Enter..." _ ;;
    esac
  done
}

write_decoy_site() {
  local concept="$1"
  mkdir -p /var/www/decoy/assets

  case "$concept" in
    2)
      cat >/var/www/decoy/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Northstar Observatory</title><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"></head><body><main class="astro"><nav>Northstar Observatory<span>Telemetry Live</span></nav><section><p class="kicker">Deep sky relay</p><h1>Orbital visibility window confirmed</h1><p>Atmospheric readings, telescope alignment, and archive sync are nominal across the northern observation grid.</p><div class="metrics"><b>98.7%</b><b>12 ms</b><b>Clear</b></div></section></main></body></html>
EOF
      cat >/var/www/decoy/assets/app.css <<'EOF'
*{box-sizing:border-box}body{margin:0;min-height:100vh;background:#050814;color:#ecf4ff;font-family:Inter,system-ui,sans-serif}.astro{min-height:100vh;padding:42px;background:linear-gradient(135deg,#050814,#111f3d 55%,#1c2b4a)}nav{display:flex;justify-content:space-between;color:#9db7e8;font-weight:700}section{max-width:760px;margin:14vh 0 0}h1{font-size:clamp(42px,8vw,92px);line-height:.95;margin:12px 0;letter-spacing:0}.kicker{color:#78ffe0;text-transform:uppercase;font-weight:800}section>p{font-size:20px;line-height:1.6;color:#c6d3ea}.metrics{display:flex;gap:12px;flex-wrap:wrap;margin-top:28px}.metrics b{border:1px solid #4f6fa6;padding:14px 18px;border-radius:6px;background:#101a31}
EOF
      ;;
    3)
      cat >/var/www/decoy/index.html <<'EOF'
<!doctype html><html lang="it"><head><meta charset="utf-8"><title>Casa Verde</title><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"></head><body><main class="cafe"><section><span>Casa Verde</span><h1>Cucina locale, tavoli disponibili</h1><p>Il calendario delle prenotazioni e il menu stagionale sono aggiornati per il servizio serale.</p><a href="/health">Stato servizio</a></section><aside><b>18:00</b><b>21:30</b><b>Aperto</b></aside></main></body></html>
EOF
      cat >/var/www/decoy/assets/app.css <<'EOF'
*{box-sizing:border-box}body{margin:0;background:#f5efe6;color:#17382d;font-family:Georgia,serif}.cafe{min-height:100vh;display:grid;grid-template-columns:1fr 340px;gap:34px;align-items:center;padding:7vw;background:linear-gradient(90deg,#f5efe6,#d8ead5)}span{color:#8a2d16;font:800 18px system-ui,sans-serif;text-transform:uppercase}h1{font-size:clamp(40px,7vw,86px);line-height:1;margin:14px 0;letter-spacing:0}p{font-size:22px;line-height:1.55;max-width:720px}a{display:inline-block;margin-top:18px;color:#fff;background:#17382d;padding:14px 18px;border-radius:4px;text-decoration:none;font-family:system-ui,sans-serif}aside{display:grid;gap:16px}aside b{background:#fff;border:1px solid #c4d8bf;padding:26px;border-radius:4px;font:700 30px system-ui,sans-serif}@media(max-width:760px){.cafe{grid-template-columns:1fr}}
EOF
      ;;
    4)
      cat >/var/www/decoy/index.html <<'EOF'
<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Sakura Dispatch</title><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"></head><body><main class="sakura"><header>桜配送センター</header><section><h1>配送状況は正常です</h1><p>地域ルート、倉庫同期、到着予定時刻の更新が完了しました。</p><div><span>Tokyo</span><span>Osaka</span><span>Fukuoka</span></div></section></main></body></html>
EOF
      cat >/var/www/decoy/assets/app.css <<'EOF'
*{box-sizing:border-box}body{margin:0;min-height:100vh;background:#fff7fb;color:#251b2b;font-family:"Segoe UI",system-ui,sans-serif}.sakura{min-height:100vh;padding:34px;background:linear-gradient(160deg,#fff7fb,#ffd6e8 45%,#eaf7ff)}header{font-weight:900;color:#a12258;border-bottom:2px solid #f1a6c7;padding-bottom:18px}section{margin:12vh auto 0;max-width:860px;text-align:center}h1{font-size:clamp(42px,8vw,88px);letter-spacing:0;line-height:1.03;margin:0 0 18px}p{font-size:21px;color:#5e5364}div{display:flex;justify-content:center;gap:12px;flex-wrap:wrap;margin-top:32px}span{background:#fff;border:1px solid #ee9fc1;padding:14px 18px;border-radius:999px;font-weight:800}
EOF
      ;;
    5)
      cat >/var/www/decoy/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Nordic Weather Grid</title><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"></head><body><main class="weather"><section><p>Nordic Weather Grid</p><h1>Regional forecast node online</h1></section><table><tr><td>Wind</td><td>12 km/h</td></tr><tr><td>Pressure</td><td>1018 hPa</td></tr><tr><td>Status</td><td>Stable</td></tr></table></main></body></html>
EOF
      cat >/var/www/decoy/assets/app.css <<'EOF'
*{box-sizing:border-box}body{margin:0;background:#e8f1f4;color:#0f2930;font-family:Arial,system-ui,sans-serif}.weather{min-height:100vh;display:grid;grid-template-columns:1.2fr .8fr;align-items:end;gap:40px;padding:6vw}p{text-transform:uppercase;font-weight:800;color:#496a73}h1{font-size:clamp(42px,8vw,96px);letter-spacing:0;line-height:.98;margin:0 0 6vh}table{width:100%;border-collapse:collapse;background:#f8fbfc;border:1px solid #b9cbd1}td{padding:22px;border-bottom:1px solid #cbd9dd;font-size:22px}td:last-child{text-align:right;font-weight:800}@media(max-width:800px){.weather{grid-template-columns:1fr}}
EOF
      ;;
    *)
      cat >/var/www/decoy/index.html <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Edge Media Monitor</title><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/assets/app.css"></head><body><main class="shell"><section class="hero"><div><span class="eyebrow">Edge Media Monitor</span><h1>Realtime delivery status</h1><p>Media session routing, regional availability checks, and playback synchronization are operating normally.</p></div><div class="status"><span class="dot"></span><strong>Operational</strong></div></section></main></body></html>
EOF
      cat >/var/www/decoy/assets/app.css <<'EOF'
:root{--bg:#eef3f8;--panel:#fff;--ink:#172033;--muted:#657389;--line:#d8e1eb;--blue:#2364aa;--green:#1c9b72}*{box-sizing:border-box}body{margin:0;min-height:100vh;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:linear-gradient(135deg,#eef3f8,#dfeaf4);color:var(--ink)}.shell{width:min(980px,calc(100% - 32px));margin:9vh auto}.hero{display:flex;align-items:flex-start;justify-content:space-between;gap:28px;padding:38px;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 18px 45px rgba(23,32,51,.08)}.eyebrow{display:inline-flex;margin-bottom:18px;color:var(--blue);font-size:13px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}h1{margin:0;font-size:clamp(34px,5vw,58px);line-height:1.02;letter-spacing:0}p{max-width:620px;margin:18px 0 0;color:var(--muted);font-size:18px;line-height:1.6}.status{display:inline-flex;align-items:center;gap:10px;flex:0 0 auto;padding:12px 14px;border:1px solid rgba(28,155,114,.24);border-radius:8px;background:rgba(28,155,114,.08);color:#12664d}.dot{width:10px;height:10px;border-radius:50%;background:var(--green);box-shadow:0 0 0 5px rgba(28,155,114,.15)}@media(max-width:720px){.shell{margin:24px auto}.hero{flex-direction:column;padding:26px}}
EOF
      ;;
  esac

  chown -R www-data:www-data /var/www/decoy 2>/dev/null || true
}

decoy_menu() {
  local choice
  clear || true
  echo "========================"
  echo "       AZMOV PANEL"
  echo "========================"
  echo "Index HTML concept"
  echo
  echo "1. Edge Media Monitor - light SaaS status"
  echo "2. Northstar Observatory - dark space telemetry"
  echo "3. Casa Verde - Italian cafe"
  echo "4. Sakura Dispatch - Japanese logistics"
  echo "5. Nordic Weather Grid - minimal weather"
  echo
  ask choice "Select concept" "1"
  write_decoy_site "$choice"
  systemctl reload nginx 2>/dev/null || true
  echo "Decoy concept applied to /var/www/decoy"
  read -rp "Press Enter..." _
}

write_nginx_config() {
  local domain="$1"
  local grpc_service="$2"

  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%F-%H%M%S) || true
  cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;

    client_max_body_size 0;
    client_header_buffer_size 16k;
    large_client_header_buffers 8 32k;

    log_format grpc_min '$remote_addr $time_local host="$host" proto="$server_protocol" '
                        '"$request_method $request_uri" st=$status bytes=$body_bytes_sent '
                        'rt=$request_time grt="$upstream_response_time" '
                        'ua="$http_user_agent"';

    include /etc/nginx/sites-enabled/*;
}
EOF

  cat >/etc/nginx/sites-available/$domain <<EOF
upstream xray_grpc {
    server 127.0.0.1:11443;
    keepalive 256;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/decoy;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    root /var/www/decoy;
    index index.html;

    location = /health {
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 200 '{"status":"ok"}';
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location ^~ /$grpc_service/Tun {
        access_log /var/log/nginx/grpc_access.log grpc_min;

        grpc_pass grpc://xray_grpc;
        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;

        grpc_read_timeout 900s;
        grpc_send_timeout 900s;
        grpc_connect_timeout 30s;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/$domain
}

write_remnawave_profile() {
  local grpc_service="$1"
  cat >/root/remnawave-grpc-config-profile.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "skipFallback": false
      }
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "grpc-inbound",
      "port": 11443,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "$grpc_service",
          "multiMode": false
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOF
}

print_install_summary() {
  local domain="$1"
  local grpc_service="$2"
  local node_api_port="$3"
  local public_ip dns_1 dns_8 site_code health_body ports
  public_ip="$(curl -4fsS ifconfig.me || true)"
  dns_1="$(dig +short "$domain" @1.1.1.1 | tail -n1 || true)"
  dns_8="$(dig +short "$domain" @8.8.8.8 | tail -n1 || true)"
  site_code="$(curl -k -sS -o /dev/null -w '%{http_code}' "https://$domain/" || true)"
  health_body="$(curl -k -fsS "https://$domain/health" || true)"
  if [ -n "$node_api_port" ]; then
    ports="$(ss -lntp | grep -E ":(11443|443|$node_api_port)\b" || true)"
  else
    ports="$(ss -lntp | grep -E ":(11443|443)\b" || true)"
  fi

  echo
  echo "=============================="
  echo "       INSTALL SUCCESS"
  echo "=============================="
  echo "Log file: $LOG_FILE"
  echo "Public IP: $public_ip"
  echo "DNS 1.1.1.1: $dns_1"
  echo "DNS 8.8.8.8: $dns_8"
  echo "Site: https://$domain/ HTTP $site_code"
  echo "Health: $health_body"
  echo "gRPC path: /$grpc_service/Tun"
  echo
  echo "Listening ports:"
  echo "$ports"
  echo
  echo "Remnawave Host:"
  echo "Inbound: grpc-inbound"
  echo "Address/SNI/Host: $domain"
  echo "Port: 443"
  echo "Security: TLS"
  echo "Network: gRPC"
  echo "Service Name: $grpc_service"
  echo "Multi Mode: false"
  echo "ALPN: h2,http/1.1"
  echo "Fingerprint: chrome, firefox, safari or randomized variants can be tested"
}

grpc_setup() {
  local optimize_node mtu_value origin_domain email panel_ip node_api_port grpc_service decoy_choice public_ip dns_1 dns_8 cont
  start_log
  echo "=== gRPC SETUP ==="
  ask_yes_no optimize_node "Optimize node network settings? BBR, buffers, fq, optional MTU" "y"
  mtu_value=""
  if [ "$optimize_node" = "y" ]; then
    ask mtu_value "Interface MTU, empty to keep current" "1476"
  fi
  ask origin_domain "Domain pointed to this server, e.g. gb1.azmov.ru"
  ask email "Email for Let's Encrypt" "admin@azmov.ru"
  ask panel_ip "Remnawave Panel public IP allowed to Node API, empty to skip" ""
  ask node_api_port "Remnawave Node API port, empty to skip" "2222"
  ask grpc_service "gRPC serviceName" "media.session.poll"
  ask decoy_choice "Index HTML concept 1-5" "1"

  install_base_packages
  public_ip="$(curl -4fsS ifconfig.me || true)"
  dns_1="$(dig +short "$origin_domain" @1.1.1.1 | tail -n1 || true)"
  dns_8="$(dig +short "$origin_domain" @8.8.8.8 | tail -n1 || true)"

  echo
  echo "Public IP: $public_ip"
  echo "DNS 1.1.1.1: $dns_1"
  echo "DNS 8.8.8.8: $dns_8"
  echo

  if [ -n "$public_ip" ] && { [ "$dns_1" != "$public_ip" ] || [ "$dns_8" != "$public_ip" ]; }; then
    echo "WARNING: DNS does not fully match this server IP yet."
    echo "Expected A record: $origin_domain -> $public_ip"
    read -rp "Continue anyway? [y/N]: " cont
    if [ "$cont" != "y" ] && [ "$cont" != "Y" ]; then
      exit 1
    fi
  fi

  wait_for_apt_locks
  DEBIAN_FRONTEND=noninteractive apt -y upgrade
  wait_for_apt_locks
  apt install -y nginx certbot curl wget git unzip nano htop jq ufw openssl ca-certificates dnsutils iproute2

  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable --now docker

  cat >/etc/sysctl.d/99-vpn-connection-limits.conf <<'EOF'
fs.file-max = 2097152
fs.nr_open = 2097152
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.netfilter.nf_conntrack_max = 262144
EOF

  modprobe nf_conntrack || true
  echo nf_conntrack >/etc/modules-load.d/nf_conntrack.conf
  sysctl --system >/dev/null || true
  if [ "$optimize_node" = "y" ]; then
    optimize_node_profile "default" "$mtu_value"
  fi

  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  if [ -n "$panel_ip" ] && [ -n "$node_api_port" ]; then
    ufw allow from "$panel_ip" to any port "$node_api_port" proto tcp
  fi
  ufw --force enable

  systemctl stop nginx || true
  certbot certonly --standalone \
    -d "$origin_domain" \
    --non-interactive \
    --agree-tos \
    -m "$email"

  write_decoy_site "$decoy_choice"
  write_nginx_config "$origin_domain" "$grpc_service"
  nginx -t && systemctl restart nginx
  write_remnawave_profile "$grpc_service"
  print_install_summary "$origin_domain" "$grpc_service" "$node_api_port"
  read -rp "Press Enter to return to menu..." _
}

main_menu() {
  need_root
  while true; do
    clear || true
    echo "========================"
    echo "       AZMOV PANEL"
    echo "========================"
    echo "1. GRPC SETUP"
    echo "2. INDEX HTML CONCEPT"
    echo "3. OPTIMIZATION"
    echo "0. EXIT"
    echo
    read -rp "Select: " choice
    case "$choice" in
      1) grpc_setup ;;
      2) decoy_menu ;;
      3) optimization_menu ;;
      0) exit 0 ;;
      *) read -rp "Unknown option. Press Enter..." _ ;;
    esac
  done
}

main_menu

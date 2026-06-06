#!/usr/bin/env bash
set -euo pipefail

APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-1200}"

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

optimize_node() {
  local mtu="$1"

  cat >/etc/sysctl.d/99-remnawave-grpc-optimization.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 65536
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.tcp_tw_reuse = 1
EOF

  sysctl --system >/dev/null || true

  if [ -n "$mtu" ]; then
    ip link set dev ens3 mtu "$mtu" || true
    mkdir -p /etc/systemd/system/remnawave-network-optimize.service.d
    cat >/etc/systemd/system/remnawave-network-optimize.service <<EOF
[Unit]
Description=Apply Remnawave network optimization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link set dev ens3 mtu $mtu
ExecStart=/usr/sbin/tc qdisc replace dev ens3 root fq
ExecStart=/usr/sbin/ip link set dev ens3 txqueuelen 5000
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnawave-network-optimize.service || true
  fi

  tc qdisc replace dev ens3 root fq || true
  ip link set dev ens3 txqueuelen 5000 || true
}

need_root

echo "=== Remnawave gRPC direct installer ==="
ask_yes_no OPTIMIZE_NODE "Optimize node network settings? BBR, buffers, fq, optional MTU" "y"
MTU_VALUE=""
if [ "$OPTIMIZE_NODE" = "y" ]; then
  ask MTU_VALUE "Interface MTU, empty to keep current" "1476"
fi
ask ORIGIN_DOMAIN "Domain pointed to this server, e.g. gb1.azmov.ru"
ask EMAIL "Email for Let's Encrypt" "admin@azmov.ru"
ask PANEL_IP "Remnawave Panel public IP allowed to Node API, empty to skip" ""
ask NODE_API_PORT "Remnawave Node API port, empty to skip" "2222"
ask GRPC_SERVICE "gRPC serviceName" "media.session.poll"

wait_for_apt_locks
apt update
wait_for_apt_locks
apt install -y curl dnsutils ca-certificates

PUBLIC_IP="$(curl -4fsS ifconfig.me || true)"
DNS_1="$(dig +short "$ORIGIN_DOMAIN" @1.1.1.1 | tail -n1 || true)"
DNS_8="$(dig +short "$ORIGIN_DOMAIN" @8.8.8.8 | tail -n1 || true)"

echo
echo "Public IP: $PUBLIC_IP"
echo "DNS 1.1.1.1: $DNS_1"
echo "DNS 8.8.8.8: $DNS_8"
echo

if [ -n "$PUBLIC_IP" ] && { [ "$DNS_1" != "$PUBLIC_IP" ] || [ "$DNS_8" != "$PUBLIC_IP" ]; }; then
  echo "WARNING: DNS does not fully match this server IP yet."
  echo "Expected A record: $ORIGIN_DOMAIN -> $PUBLIC_IP"
  read -rp "Continue anyway? [y/N]: " CONT
  if [ "$CONT" != "y" ] && [ "$CONT" != "Y" ]; then
    exit 1
  fi
fi

wait_for_apt_locks
DEBIAN_FRONTEND=noninteractive apt -y upgrade
wait_for_apt_locks
apt install -y nginx certbot curl wget git unzip nano htop jq ufw openssl ca-certificates dnsutils

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
if [ "$OPTIMIZE_NODE" = "y" ]; then
  optimize_node "$MTU_VALUE"
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
if [ -n "$PANEL_IP" ] && [ -n "$NODE_API_PORT" ]; then
  ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp
fi
ufw --force enable

systemctl stop nginx || true

certbot certonly --standalone \
  -d "$ORIGIN_DOMAIN" \
  --non-interactive \
  --agree-tos \
  -m "$EMAIL"

systemctl start nginx || true

mkdir -p /var/www/decoy/assets

cat >/var/www/decoy/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Edge Media Monitor</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div>
        <span class="eyebrow">Edge Media Monitor</span>
        <h1>Realtime delivery status</h1>
        <p>Media session routing, regional availability checks, and playback synchronization are operating normally.</p>
      </div>
      <div class="status"><span class="dot"></span><strong>Operational</strong></div>
    </section>
  </main>
</body>
</html>
EOF

cat >/var/www/decoy/assets/app.css <<'EOF'
:root { --bg:#eef3f8; --panel:#fff; --ink:#172033; --muted:#657389; --line:#d8e1eb; --blue:#2364aa; --green:#1c9b72; }
* { box-sizing:border-box; }
body { margin:0; min-height:100vh; font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:radial-gradient(circle at 20% 0%,rgba(35,100,170,.16),transparent 32%),var(--bg); color:var(--ink); }
.shell { width:min(980px,calc(100% - 32px)); margin:9vh auto; }
.hero { display:flex; align-items:flex-start; justify-content:space-between; gap:28px; padding:38px; background:var(--panel); border:1px solid var(--line); border-radius:12px; box-shadow:0 18px 45px rgba(23,32,51,.08); }
.eyebrow { display:inline-flex; margin-bottom:18px; color:var(--blue); font-size:13px; font-weight:700; letter-spacing:.08em; text-transform:uppercase; }
h1 { margin:0; font-size:clamp(34px,5vw,58px); line-height:1.02; letter-spacing:0; }
p { max-width:620px; margin:18px 0 0; color:var(--muted); font-size:18px; line-height:1.6; }
.status { display:inline-flex; align-items:center; gap:10px; flex:0 0 auto; padding:12px 14px; border:1px solid rgba(28,155,114,.24); border-radius:8px; background:rgba(28,155,114,.08); color:#12664d; }
.dot { width:10px; height:10px; border-radius:50%; background:var(--green); box-shadow:0 0 0 5px rgba(28,155,114,.15); }
@media (max-width:720px) { .shell{margin:24px auto;} .hero{flex-direction:column;padding:26px;} }
EOF

chown -R www-data:www-data /var/www/decoy

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

cat >/etc/nginx/sites-available/$ORIGIN_DOMAIN <<EOF
upstream xray_grpc {
    server 127.0.0.1:11443;
    keepalive 256;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $ORIGIN_DOMAIN;

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
    server_name $ORIGIN_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$ORIGIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ORIGIN_DOMAIN/privkey.pem;

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

    location ^~ /$GRPC_SERVICE/Tun {
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
ln -sf /etc/nginx/sites-available/$ORIGIN_DOMAIN /etc/nginx/sites-enabled/$ORIGIN_DOMAIN

nginx -t && systemctl restart nginx

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
          "serviceName": "$GRPC_SERVICE",
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

echo
echo "=== DONE ==="
echo "Site: https://$ORIGIN_DOMAIN/"
echo "Health: https://$ORIGIN_DOMAIN/health"
echo "gRPC path: /$GRPC_SERVICE/Tun"
echo
echo "Remnawave Config Profile saved to:"
echo "/root/remnawave-grpc-config-profile.json"
echo
echo "Remnawave Host:"
echo "Inbound: grpc-inbound"
echo "Address/SNI/Host: $ORIGIN_DOMAIN"
echo "Port: 443"
echo "Security: TLS"
echo "Network: gRPC"
echo "Service Name: $GRPC_SERVICE"
echo "Multi Mode: false"
echo "ALPN: h2,http/1.1"
echo "Fingerprint: chrome"
if [ "$OPTIMIZE_NODE" = "y" ]; then
  echo
  echo "Network optimization:"
  echo "BBR/fq/buffers: enabled"
  if [ -n "$MTU_VALUE" ]; then
    echo "MTU: $MTU_VALUE"
  else
    echo "MTU: unchanged"
  fi
fi
if [ -n "$PANEL_IP" ] && [ -n "$NODE_API_PORT" ]; then
  echo
  echo "Node API firewall:"
  echo "Allowed Panel IP: $PANEL_IP"
  echo "Allowed Node API port: $NODE_API_PORT/tcp"
fi
echo
echo "After assigning profile to node, run:"
if [ -n "$NODE_API_PORT" ]; then
  echo "docker restart remnanode && sleep 10 && ss -lntp | grep -E ':(11443|443|$NODE_API_PORT)\\b'"
else
  echo "docker restart remnanode && sleep 10 && ss -lntp | grep -E ':(11443|443)\\b'"
fi

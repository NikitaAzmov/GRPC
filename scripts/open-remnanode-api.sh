#!/usr/bin/env bash
set -euo pipefail

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

need_root

echo "=== Open Remnawave Node API for Panel only ==="
ask PANEL_IP "Remnawave Panel public IP allowed to Node API"
ask NODE_API_PORT "Remnawave Node API port from docker-compose.yml" "2222"

ufw allow from "$PANEL_IP" to any port "$NODE_API_PORT" proto tcp
ufw reload

echo
echo "=== DONE ==="
echo "Allowed Panel IP: $PANEL_IP"
echo "Allowed Node API port: $NODE_API_PORT/tcp"
echo
echo "Check on node:"
echo "ss -lntp | grep ':$NODE_API_PORT'"
echo "ufw status verbose"
echo
echo "Check from panel server:"
echo "nc -vz NODE_PUBLIC_IP $NODE_API_PORT"

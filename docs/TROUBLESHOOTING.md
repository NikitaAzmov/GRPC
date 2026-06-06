# Troubleshooting

## `Could not get lock /var/lib/dpkg/lock-frontend`

Причина: на сервере работает автоматическое обновление `unattended-upgrades`.

Что делать:

```bash
ps -fp PROCESS_ID
```

Обычно нужно просто подождать. Скрипт уже умеет ждать до 20 минут. Если процесс завис и точно ничего не ставит:

```bash
systemctl status unattended-upgrades
journalctl -u unattended-upgrades -n 100 --no-pager
```

Не удаляй lock-файлы, пока жив процесс `apt`, `dpkg` или `unattended-upgr`.

## DNS не совпадает с IP сервера

Симптом:

```text
WARNING: DNS does not fully match this server IP yet.
```

Проверь:

```bash
dig +short your-domain.example @1.1.1.1
dig +short your-domain.example @8.8.8.8
curl -4 ifconfig.me
```

Решение: обнови A-запись домена на публичный IPv4 сервера и дождись распространения DNS.

## Certbot не выдал сертификат

Частые причины:

- домен не указывает на сервер;
- порт `80` закрыт firewall-провайдером;
- порт `80` занят другим сервисом;
- превышен лимит Let's Encrypt.

Проверки:

```bash
ss -lntp | grep ':80'
ufw status verbose
dig +short your-domain.example @1.1.1.1
```

Повторный запуск:

```bash
certbot certonly --standalone -d your-domain.example --agree-tos -m admin@example.com
```

## Nginx не стартует

Проверка конфига:

```bash
nginx -t
journalctl -u nginx -n 100 --no-pager
```

Частые причины:

- ошибка в домене или имени файла в `/etc/nginx/sites-enabled/`;
- нет сертификата в `/etc/letsencrypt/live/DOMAIN/`;
- порт `443` занят другим процессом.

Проверить порт:

```bash
ss -lntp | grep ':443'
```

## `/health` работает, но gRPC не подключается

Это значит, что TLS/Nginx жив, но upstream на `127.0.0.1:11443` не отвечает или serviceName не совпадает.

Проверки:

```bash
ss -lntp | grep ':11443'
docker logs remnanode --tail 100
tail -n 100 /var/log/nginx/error.log
tail -n 100 /var/log/nginx/grpc_access.log
```

Решения:

- назначь Remnawave Config Profile на node;
- перезапусти node:

```bash
docker restart remnanode
```

- проверь, что `serviceName` одинаковый в Nginx, Xray config profile и клиенте;
- проверь, что inbound tag в Remnawave: `grpc-inbound`.

## Ошибка `connect() failed (111: Connection refused) while connecting to upstream`

Причина: Nginx пытается проксировать на `127.0.0.1:11443`, но там никто не слушает.

Решение:

```bash
ss -lntp | grep ':11443'
docker restart remnanode
docker logs remnanode --tail 100
```

Если inbound не появился, проверь Remnawave profile.

## Remnawave Panel не видит remnanode

Причина: Panel подключается к remnanode по отдельному `NODE_PORT`, например `2222`. Этот порт не относится к клиентскому gRPC на `443`, но нужен для config push, статистики и статуса node.

Проверь на node:

```bash
cd /opt/remnanode
grep -E 'NODE_PORT|SECRET_KEY' docker-compose.yml
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
ss -lntp | grep ':2222'
ufw status verbose
docker logs remnanode --tail 100
```

Если `NODE_PORT=2222`, открой его только для IP панели:

```bash
ufw allow from PANEL_IP to any port 2222 proto tcp
ufw reload
```

Проверь с сервера панели:

```bash
nc -vz NODE_PUBLIC_IP 2222
```

Если `nc` не подключается:

- проверь firewall провайдера на node;
- проверь, что в Remnawave Panel указан публичный IP node и правильный port;
- проверь, что remnanode container запущен;
- проверь, что `NODE_PORT` в `docker-compose.yml` совпадает с портом в панели.

## Клиент подключается, но трафик не идет

Проверь:

- `Security: TLS`;
- `Network: gRPC`;
- `Port: 443`;
- `SNI/Host` равен домену;
- `Service Name` совпадает полностью;
- `Multi Mode: false`;
- `ALPN: h2,http/1.1`.

Также проверь, что в Xray routing не блокируется нужный трафик.

## Высокая задержка или packet loss

Проверь базовую сеть:

```bash
ping -c 30 1.1.1.1
ping -c 30 8.8.8.8
ip -s link show ens3
tc qdisc show dev ens3
```

Проверь MTU:

```bash
ping -M do -s 1472 -c 5 1.1.1.1 || true
ping -M do -s 1448 -c 5 1.1.1.1 || true
ping -M do -s 1400 -c 5 1.1.1.1 || true
```

Если видишь `Frag needed ... mtu = 1476`, попробуй:

```bash
ip link set dev ens3 mtu 1476
tc qdisc replace dev ens3 root fq
ip link set dev ens3 txqueuelen 5000
systemctl restart nginx
docker restart remnanode
```

Чтобы сделать MTU постоянным, включи оптимизацию через установщик или создай systemd service:

```bash
systemctl status remnawave-network-optimize.service
```

Откат:

```bash
ip link set dev ens3 mtu 1500
systemctl disable --now remnawave-network-optimize.service
```

## Нужно открыть Node API порт

Основной установщик спрашивает IP панели и Node API port. Если ты оставил IP панели пустым или менял порт позже, открой доступ отдельно.

Открывай Node API только для IP панели:

```bash
ufw allow from PANEL_IP to any port NODE_API_PORT proto tcp
ufw status numbered
```

Не открывай Node API порт на весь интернет.

Небезопасный вариант, который проще, но не рекомендуется:

```bash
ufw allow 2222/tcp
```

Такой вариант позволит подключаться к Node API с любых IP.

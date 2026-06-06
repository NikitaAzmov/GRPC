# Remnawave gRPC Direct Kit

Готовый набор для установки gRPC inbound за Nginx TLS reverse proxy.

Схема:

```text
client -> domain:443 TLS/h2 -> nginx -> 127.0.0.1:11443 -> remnanode/xray grpc-inbound
```

## Что внутри

```text
remnawave-grpc-kit/
  configs/
    remnawave-xray-config-profile.json
  docs/
    TROUBLESHOOTING.md
  scripts/
    install-remna-grpc.sh
  README.md
```

## Требования

- Ubuntu 24.04 или близкая версия Ubuntu/Debian.
- Root-доступ.
- Домен с A-записью на IP сервера.
- Свободные порты `80` и `443`.
- Remnawave/remnanode уже должен быть установлен отдельно, если ты будешь сразу назначать профиль на node.

## Быстрый старт

1. Скопируй папку `remnawave-grpc-kit` на сервер.

2. Перейди в папку:

```bash
cd remnawave-grpc-kit
```

3. Запусти установку:

```bash
chmod +x scripts/install-remna-grpc.sh
sudo ./scripts/install-remna-grpc.sh
```

4. Скрипт спросит только:

```text
Domain pointed to this server
Email for Let's Encrypt
gRPC serviceName
```

Рекомендуемый `gRPC serviceName`:

```text
media.session.poll
```

5. После завершения проверь сайт:

```bash
curl -I https://your-domain.example/
curl https://your-domain.example/health
```

Ожидаемый health-ответ:

```json
{"status":"ok"}
```

## Настройка Remnawave

В Remnawave добавь/импортируй Config Profile из файла:

```text
configs/remnawave-xray-config-profile.json
```

Главные параметры:

```text
Inbound: grpc-inbound
Listen: 127.0.0.1
Port: 11443
Protocol: vless
Network: gRPC
Security: none
Service Name: media.session.poll
Multi Mode: false
```

Для клиента/host в Remnawave:

```text
Address/SNI/Host: твой домен
Port: 443
Security: TLS
Network: gRPC
Service Name: media.session.poll
Multi Mode: false
ALPN: h2,http/1.1
Fingerprint: chrome
```

Если меняешь `serviceName` при установке, обязательно поменяй его и в `configs/remnawave-xray-config-profile.json`.

## Что делает скрипт

- Проверяет, что запуск идет от root.
- Проверяет публичный IP и DNS A-запись домена через `1.1.1.1` и `8.8.8.8`.
- Ждет освобождения `apt`/`dpkg` lock, если работает `unattended-upgrades`.
- Устанавливает `nginx`, `certbot`, `ufw`, `dnsutils` и базовые утилиты.
- Устанавливает Docker, если его нет.
- Настраивает системные лимиты и TCP-параметры.
- Открывает в UFW только `22`, `80`, `443`.
- Получает Let's Encrypt сертификат через standalone certbot.
- Создает decoy-сайт и `/health`.
- Настраивает Nginx с TLS HTTP/2 и gRPC proxy на `127.0.0.1:11443`.
- Сохраняет итоговый Remnawave/Xray profile в `/root/remnawave-grpc-config-profile.json`.

## Проверка после назначения профиля

После назначения profile на node:

```bash
docker restart remnanode
sleep 10
ss -lntp | grep -E ':(11443|443)\b'
```

Должно быть:

- `nginx` слушает `443`;
- inbound слушает `127.0.0.1:11443`.

Логи Nginx:

```bash
journalctl -u nginx -n 100 --no-pager
tail -n 100 /var/log/nginx/error.log
tail -n 100 /var/log/nginx/grpc_access.log
```

Логи remnanode:

```bash
docker logs remnanode --tail 100
```

## Важно

Скрипт не открывает порт Remnawave Node API. Если твоей установке Remnawave нужен отдельный Node API порт, открой его вручную только для IP панели:

```bash
ufw allow from PANEL_IP to any port NODE_API_PORT proto tcp
```

Например:

```bash
ufw allow from 81.29.146.164 to any port 2222 proto tcp
```

Если Node API у тебя уже настроен отдельно, этот kit его не трогает.

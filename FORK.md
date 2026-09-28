# RemnaSetup — сборка gko11

[English](FORK.en.md) | Русский

Форк [Capybara-z/RemnaSetup](https://github.com/Capybara-z/RemnaSetup) с заменёнными
компонентами selfsteal и WARP. Всё остальное (панель, subscription page, nginx,
BBR, IPv6, бэкапы) осталось от оригинала.

## Установка

```bash
bash <(curl -fsSL raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh)
```

## Что заменено

### Selfsteal: Docker + Caddy вместо системного пакета

`scripts/remnanode/install-caddy.sh` переписан полностью.

Оригинал ставил Caddy через apt и правил `/etc/caddy/Caddyfile`. Здесь всё
живёт в контейнере `/opt/selfsteal`, конфиг и сертификаты — рядом.

Что учтено:

- **Health-check ходит по домену, а не по `127.0.0.1`.** При обращении по голому
  IP wget не отправляет SNI, Caddy не находит site-блок и рвёт хендшейк с
  `tlsv1 alert internal error`. Контейнер при этом работает, но вечно висит
  `unhealthy`. Добавлен `extra_hosts`, чтобы контейнер резолвил свой домен на себя.
- **`init: true`** — tini как PID 1. Без него `ssl_client`, который порождает
  busybox wget на каждой проверке, остаётся зомби-процессом и за сутки набивает
  тысячи PID'ов.
- **HTTP/3 отключён** (`protocols h1 h2`). Для статической заглушки бесполезен,
  а QUIC-буферы заметно едят память на нодах с 1–2 ГБ.
- **Порт 443 публикуется только когда он свободен.** Если Xray слушает 443,
  Reality сам отдаёт заглушку через `target`, и проброс не нужен. Хуже того —
  Docker займёт порт первым, и Xray после рестарта на него не забиндится, нода
  отвалится. Скрипт смотрит, кто фактически держит 443, и при виде `rw-core`
  отказывается публиковать.
  Если же Xray на другом порту (1443 и т.п.), 443 отдаётся Caddy: иначе домен из
  `serverNames` снаружи не отвечает вообще, что для маскировки хуже, чем
  обычный сайт.
- **Детект существующей установки** с предложением полной переустановки.
  Volume `caddy_data` при этом **сохраняется**: Let's Encrypt выдаёт лишь
  5 одинаковых сертификатов в неделю, и на переустановках в лимит легко упереться.
- **Самопроверка после старта** — `openssl s_client` с правильным SNI.
- Инбаунд не генерируется. Скрипт печатает `target` и `serverNames` для ручной
  настройки в панели.

### WARP: Docker SOCKS5 вместо WARP-NATIVE

`scripts/remnanode/install-warp.sh`. Нативный WARP (wgcf + `wg-quick@warp`) убран,
вместо него контейнер [`ghcr.io/kingcc/warproxy`](https://github.com/kingcc/warproxy)
(wireproxy) с SOCKS5. Xray подключает его как outbound:

```json
{"tag":"WARP","protocol":"socks","settings":{"servers":[{"address":"172.17.0.1","port":1080}]}}
```

#### Почему регистрация перестала работать

Cloudflare проверяет TLS-отпечаток клиента на `api.cloudflareclient.com`.
Образ `kingcc/warproxy` собран в 2025 г. со старым `wgcf`, его отпечаток больше не
проходит, и регистрация получает `429 Too Many Requests` — это **не** лимит по IP,
ждать бесполезно. Исправлено в wgcf 2.3.0 (API `v0a5641` + новый отпечаток),
см. [ViRb3/wgcf#626](https://github.com/ViRb3/wgcf/issues/626).

#### Как теперь устроено

- Скрипт качает **wgcf ≥ 2.3.0** в `/opt/warproxy/bin` и регистрирует аккаунт
  **сам, на хосте, до запуска контейнера**. Без валидного аккаунта и профиля
  контейнер не запускается — иначе он пошёл бы регистрироваться сам.
- Этот же wgcf монтируется в контейнер (`./bin/wgcf:/usr/local/bin/wgcf:ro`),
  старый бинарник образа в API больше не ходит.
- `wireproxy.conf` собирается скриптом заново при каждой установке. Раньше
  битый файл от неудачного старта (`one and only one [Interface] is expected`)
  переживал любые переустановки: образ создаёт его, только если файла нет.
- Проверка туннеля — `cloudflare.com/cdn-cgi/trace` через SOCKS5 (`warp=on`).
  Старая проверка через `wg show` никогда не срабатывала: в контейнере userspace
  wireproxy, интерфейса `wg` там нет.
- Проверяется и доступность TikTok через WARP.

#### Без перерегистраций

При существующей установке скрипт спрашивает:

1. **Переустановить с сохранением аккаунта** (по умолчанию, и всегда — без терминала);
2. **Полная переустановка с новой регистрацией** — старый аккаунт уходит в бэкап.
   Если новая регистрация не удалась, **прежний аккаунт возвращается автоматически**.

Аккаунт хранится в `/opt/warproxy/config`, перед пересозданием контейнера он
вытаскивается из живого контейнера (`docker cp`). Бэкапы — `/opt/warproxy/backup/`.
Если профиль не соответствует ключу аккаунта (например, после импорта), он
генерируется заново.

Если хостинг всё же упёрся в реальный лимит — аккаунт можно зарегистрировать
дома (`wgcf.exe register`, wgcf ≥ 2.3.0) и импортировать: путём к файлу,
вставкой содержимого (`p`) или `WARP_ACCOUNT_FILE=...`.

#### TikTok через WARP

После установки печатается и сохраняется в `/opt/warproxy/xray-warp-tiktok.json`
готовый блок для Remnawave (Config profiles):

- outbound `WARP` (socks) и `BLOCK` (blackhole, если его ещё нет);
- правила **в начало** `routing.rules`: UDP 443 к доменам TikTok → `BLOCK`,
  остальной трафик TikTok → `WARP`. QUIC блокируется намеренно — SOCKS5 у
  wireproxy несёт только TCP, приложение откатывается на TCP и идёт через WARP;
- в инбаундах нужен `sniffing` с `destOverride: ["http","tls","quic"]`, иначе
  доменные правила не сработают.

Домены перечислены явно, без `geosite:tiktok`: если в geosite.dat ноды нет этой
категории, Xray не стартует вообще.

## Что важно не делать

- Не удалять `/opt/warproxy/config` — там аккаунт WARP; без него понадобится новая регистрация.
- Не запускать `docker compose down -v` в `/opt/selfsteal` — снесёт сертификаты.
- Не пробрасывать 443 на Caddy, если на нём сидит Xray.

## Переменные для неинтерактивного режима

Selfsteal:

```
DOMAIN, ACME_EMAIL, LOCAL_PORT, XRAY_PORT, SITE_NAME, REINSTALL_CONFIRM
```

WARP:

```
WARP_MODE=keep|reregister|cancel, WARP_ACCOUNT_FILE, WARP_ENDPOINT,
BIND_ADDR, SOCKS_PORT, TZ_VAL, WGCF_VERSION, WARP_REG_ATTEMPTS
```

`REINSTALL_CONFIRM=y` для WARP оставлен для совместимости и означает `WARP_MODE=keep`.

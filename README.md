# RemnaSetup

<div align="center">

[English](README.en.md) | [Русский](README.md)

![RemnaSetup](https://img.shields.io/badge/RemnaSetup-2.5-blue)
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-orange)

Скрипт для установки и управления инфраструктурой **Remnawave** и **Remnanode**

[![Stars](https://img.shields.io/github/stars/gko11/RemnaSetup?style=social)](https://github.com/gko11/RemnaSetup)

</div>

---

## Установка

```bash
bash <(curl -fsSL raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh)
```

или

```bash
curl -fsSL https://raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh -o install.sh && chmod +x install.sh && sudo bash ./install.sh
```

---

## Возможности

### Remnawave (панель)
- Полная установка (Remnawave + Caddy)
- Установка панели / страницы подписок / Caddy по отдельности
- Обновление всех компонентов
- Бэкап и восстановление (ручной, автоматический, с отправкой в Telegram или S3-хранилище)

### Remnanode (нода)
- Полная установка (Remnanode + Selfsteal на Docker + Caddy + BBR + WARP)
- Управление IPv6
- WARP SOCKS5 прокси (Docker) — регистрация через wgcf ≥ 2.3.0, без перерегистраций, готовый роутинг TikTok → WARP
- **Обновление ноды без лишнего перезапуска**: нет новой версии — контейнер не трогается; новая не запустилась — автоматический откат
- **Расписание обслуживания**: свой день обновления для каждого сервера и плановая перезагрузка, время по Москве (таймеры systemd)
- **Hysteria2**: сертификат берётся у Caddy (или Caddy получает его сам), проброс в контейнер ноды, ежедневная синхронизация, UDP 443
- BBR оптимизация (через /etc/sysctl.d, без дублей)
- BBR оптимизация

---

## Non-interactive режим

Можно передать параметры через переменные окружения и команду — скрипт выполнится без вопросов.

### Полная установка ноды с Caddy

```bash
DOMAIN=node.example.com \
MONITOR_PORT=8443 \
NODE_PORT=3001 \
SECRET_KEY='ваш_ключ' \
WEBSERVER=caddy \
INSTALL_WARP=y \
BBR_ANSWER=y \
sudo -E bash /opt/remnasetup/remnasetup.sh install-node
```

### Пропуск компонентов

```bash
DOMAIN=node.example.com \
WEBSERVER=caddy \
MONITOR_PORT=8443 \
SKIP_REMNANODE=true \
SKIP_WARP=true \
SKIP_BBR=true \
sudo -E bash /opt/remnasetup/remnasetup.sh install-node
```

### Доступные команды

| Команда | Описание |
|---|---|
| `install-node` | Полная установка ноды |
| `install-node-only` | Только Remnanode |
| `install-caddy-node` | Только Caddy |
| `install-bbr` | Только BBR |
| `install-warp` | Только WARP SOCKS5 (Docker) |
| `update-node` | Обновить Remnanode (без перезапуска, если новой версии нет; откат, если новая не поднялась) |
| `maintenance` | Расписание: день обновления + перезагрузка |
| `install-hy2` | Hysteria2: сертификат из Caddy + подготовка ноды |

### Переменные окружения

| Переменная | Описание | По умолчанию |
|---|---|---|
| `DOMAIN` | Домен ноды | — |
| `MONITOR_PORT` | Порт веб-сервера | `8443` |
| `NODE_PORT` | Порт ноды | `3001` |
| `SECRET_KEY` | Ключ подключения к панели | — |
| `INSTALL_WARP` | `y` / `n` | — |
| `BBR_ANSWER` | `y` / `n` | — |
| `SKIP_WEBSERVER` | `true` — пропустить веб-сервер | — |
| `SKIP_REMNANODE` | `true` — пропустить ноду | — |
| `SKIP_WARP` | `true` — пропустить WARP | — |
| `WARP_MODE` | `keep` — переустановить с сохранением аккаунта / `reregister` — новая регистрация / `cancel` | `keep` |
| `WARP_ACCOUNT_FILE` | путь к готовому `wgcf-account.toml` для импорта | — |
| `WARP_ENDPOINT` | свой endpoint WARP, напр. `162.159.192.1:2408` | — |
| `WARP_BIND_ADDR` / `BIND_ADDR` | адрес SOCKS5 на хосте | `172.17.0.1` |
| `WARP_SOCKS_PORT` / `SOCKS_PORT` | порт SOCKS5 | `1080` |
| `SKIP_BBR` | `true` — пропустить BBR | — |
| `UPDATE_REMNANODE` | `true` — переустановить ноду | — |
| `UPDATE_CADDY` | `true` — переустановить Caddy | — |
| `UPDATE_DAY` | день обновления ноды `1`–`7` (Пн–Вс) или `off` | из старого crontab / `3` |
| `UPDATE_TIME` | время обновления, ЧЧ:ММ по `MAINT_TZ` | `01:00` |
| `REBOOT_MODE` | `daily` / `weekly` / `off` | `daily` |
| `REBOOT_DAY` / `REBOOT_TIME` | день (для `weekly`) и время перезагрузки | `03:00` |
| `MAINT_TZ` | часовой пояс расписания | `Europe/Moscow` |
| `TG_TOKEN` / `TG_CHAT` / `NODE_NAME` | алерт в Telegram, если нода не поднялась после обновления | — |
| `REMOVE_OLD_CRON` | `y` / `n` — убрать старые строки crontab с обновлением/перезагрузкой | `y` |
| `SETUP_MAINTENANCE` | `y` / `n` — настроить расписание в конце полной установки | `y` |
| `HY2_DOMAIN` | домен для Hysteria2 | домен selfsteal |
| `HY2_ISSUE` / `HY2_RECREATE` / `HY2_UFW` | `y`/`n`: выпуск через Caddy, пересоздание контейнера, открыть 443/udp | `y` |
| `LANGUAGE` | `ru` / `en` | `ru` |

Без аргументов скрипт работает в обычном интерактивном режиме через меню.

---

## Автоматические бэкапы

Расписание: ежедневно в заданное время или каждые N часов (настраивается через cron).

При настройке доступны три варианта хранения:

1. **Telegram** — отправка архива в Telegram-чат через бота
2. **S3-хранилище** — загрузка в любое S3-совместимое хранилище
3. **Локально** — только на сервере

### S3-хранилище

Поддерживается любое S3-совместимое хранилище (Yandex Object Storage, Selectel, Timeweb, MinIO и др.).

При настройке запрашиваются:

| Параметр | Описание | По умолчанию |
|---|---|---|
| Endpoint | URL S3-сервиса | — |
| Access Key | Ключ доступа | — |
| Secret Key | Секретный ключ | — |
| Bucket | Имя бакета | — |
| Region | Регион | — |
| Path | Путь (префикс) внутри бакета | — |
| Keep | Количество хранимых бэкапов в S3 (`0` — хранить все) | — |

При ручном бэкапе, если ранее настроен S3, скрипт предложит загрузить архив в то же хранилище.

---

## Контакты

Telegram: [@KaTTuBaRa](https://t.me/KaTTuBaRa)

## Поддержка проекта

Сделано при поддержке [SoloBot](https://github.com/Vladless/Solo_bot) ([@solonet_sup](https://t.me/solonet_sup))

## Лицензия

MIT

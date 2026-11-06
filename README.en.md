# RemnaSetup

<div align="center">

[English](README.en.md) | [Русский](README.md)

![RemnaSetup](https://img.shields.io/badge/RemnaSetup-2.5-blue)
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-orange)

Script for installing and managing **Remnawave** and **Remnanode** infrastructure

[![Stars](https://img.shields.io/github/stars/gko11/RemnaSetup?style=social)](https://github.com/gko11/RemnaSetup)

</div>

---

## Installation

```bash
bash <(curl -fsSL raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh)
```

or

```bash
curl -fsSL https://raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh -o install.sh && chmod +x install.sh && sudo bash ./install.sh
```

---

## Features

### Remnawave (panel)
- Full installation (Remnawave + Caddy)
- Install panel / subscription page / Caddy separately
- Update all components
- Backup and restore (manual, automatic, with Telegram or S3-compatible storage)

### Remnanode (node)
- Full installation (Remnanode + Selfsteal on Docker + Caddy + BBR + WARP)
- IPv6 management
- WARP SOCKS5 proxy (Docker) — registration via wgcf ≥ 2.3.0, no re-registrations, ready TikTok → WARP routing
- **Node update without needless restarts**: no new version — the container is untouched; a new one fails to start — automatic rollback
- **Maintenance schedule**: own update day per server and a scheduled reboot, Moscow time (systemd timers)
- **Hysteria2**: certificate taken from Caddy (or Caddy obtains it), mounted into the node container, daily sync, UDP 443
- BBR optimization (via /etc/sysctl.d, no duplicates)
- BBR optimization

---

## Non-interactive mode

Pass parameters via environment variables and a command — the script will run without prompts.

### Full node installation with Caddy

```bash
DOMAIN=node.example.com \
MONITOR_PORT=8443 \
NODE_PORT=3001 \
SECRET_KEY='your_key' \
WEBSERVER=caddy \
INSTALL_WARP=y \
BBR_ANSWER=y \
sudo -E bash /opt/remnasetup/remnasetup.sh install-node
```

### Skip components

```bash
DOMAIN=node.example.com \
WEBSERVER=caddy \
MONITOR_PORT=8443 \
SKIP_REMNANODE=true \
SKIP_WARP=true \
SKIP_BBR=true \
sudo -E bash /opt/remnasetup/remnasetup.sh install-node
```

### Available commands

| Command | Description |
|---|---|
| `install-node` | Full node installation |
| `install-node-only` | Remnanode only |
| `install-caddy-node` | Caddy only |
| `install-bbr` | BBR only |
| `install-warp` | WARP SOCKS5 (Docker) only |
| `update-node` | Update Remnanode (no restart if no new version; rollback if the new one fails) |
| `maintenance` | Schedule: update day + reboot |
| `install-hy2` | Hysteria2: certificate from Caddy + node preparation |

### Environment variables

| Variable | Description | Default |
|---|---|---|
| `DOMAIN` | Node domain | — |
| `MONITOR_PORT` | Web server port | `8443` |
| `NODE_PORT` | Node port | `3001` |
| `SECRET_KEY` | Panel connection key | — |
| `INSTALL_WARP` | `y` / `n` | — |
| `BBR_ANSWER` | `y` / `n` | — |
| `SKIP_WEBSERVER` | `true` — skip web server | — |
| `SKIP_REMNANODE` | `true` — skip node | — |
| `SKIP_WARP` | `true` — skip WARP | — |
| `WARP_MODE` | `keep` — reinstall keeping the account / `reregister` — new registration / `cancel` | `keep` |
| `WARP_ACCOUNT_FILE` | path to an existing `wgcf-account.toml` to import | — |
| `WARP_ENDPOINT` | custom WARP endpoint, e.g. `162.159.192.1:2408` | — |
| `WARP_BIND_ADDR` / `BIND_ADDR` | SOCKS5 address on the host | `172.17.0.1` |
| `WARP_SOCKS_PORT` / `SOCKS_PORT` | SOCKS5 port | `1080` |
| `SKIP_BBR` | `true` — skip BBR | — |
| `UPDATE_REMNANODE` | `true` — reinstall node | — |
| `UPDATE_CADDY` | `true` — reinstall Caddy | — |
| `UPDATE_DAY` | node update day `1`–`7` (Mon–Sun) or `off` | from old crontab / `3` |
| `UPDATE_TIME` | update time, HH:MM in `MAINT_TZ` | `01:00` |
| `REBOOT_MODE` | `daily` / `weekly` / `off` | `daily` |
| `REBOOT_DAY` / `REBOOT_TIME` | reboot day (for `weekly`) and time | `03:00` |
| `MAINT_TZ` | schedule time zone | `Europe/Moscow` |
| `TG_TOKEN` / `TG_CHAT` / `NODE_NAME` | Telegram alert if the node fails after an update | — |
| `REMOVE_OLD_CRON` | `y` / `n` — remove old crontab update/reboot lines | `y` |
| `SETUP_MAINTENANCE` | `y` / `n` — set up the schedule at the end of full install | `y` |
| `HY2_DOMAIN` | Hysteria2 domain | selfsteal domain |
| `HY2_ISSUE` / `HY2_RECREATE` / `HY2_UFW` | `y`/`n`: issue via Caddy, recreate container, open 443/udp | `y` |
| `LANGUAGE` | `ru` / `en` | `ru` |

Without arguments the script runs in interactive menu mode.

---

## Automatic backups

Schedule: daily at a specific time or every N hours (configured via cron).

Three storage options are available:

1. **Telegram** — send archive to a Telegram chat via bot
2. **S3 storage** — upload to any S3-compatible storage
3. **Local** — server only

### S3 storage

Any S3-compatible storage is supported (Yandex Object Storage, Selectel, Timeweb, MinIO, etc.).

Configuration parameters:

| Parameter | Description | Default |
|---|---|---|
| Endpoint | S3 service URL | — |
| Access Key | Access key | — |
| Secret Key | Secret key | — |
| Bucket | Bucket name | — |
| Region | Region | — |
| Path | Path (prefix) inside the bucket | — |
| Keep | Number of backups to keep in S3 (`0` — keep all) | — |

When creating a manual backup, if S3 was previously configured, the script will offer to upload the archive to the same storage.

---

## Contacts

Telegram: [@KaTTuBaRa](https://t.me/KaTTuBaRa)

## Support

Made with support from [SoloBot](https://github.com/Vladless/Solo_bot) ([@solonet_sup](https://t.me/solonet_sup))

## License

MIT

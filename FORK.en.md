# RemnaSetup — gko11 build

English | [Русский](FORK.md)

A fork of [Capybara-z/RemnaSetup](https://github.com/Capybara-z/RemnaSetup) with the
selfsteal and WARP components replaced. Everything else (panel, subscription page,
nginx, BBR, IPv6, backups) comes from the original.

## Installation

```bash
bash <(curl -fsSL raw.githubusercontent.com/gko11/RemnaSetup/refs/heads/main/install.sh)
```

## What was replaced

### Selfsteal: Docker + Caddy instead of the system package

`scripts/remnanode/install-caddy.sh` is rewritten from scratch.

The original installed Caddy via apt and edited `/etc/caddy/Caddyfile`. Here everything
lives in a container in `/opt/selfsteal`, with the config and certificates next to it.

What is taken care of:

- **The health-check goes to the domain, not to `127.0.0.1`.** When hitting a bare IP,
  wget sends no SNI, Caddy finds no site block and drops the handshake with
  `tlsv1 alert internal error`. The container keeps working but stays `unhealthy`
  forever. `extra_hosts` makes the container resolve its own domain to itself.
- **`init: true`** — tini as PID 1. Without it the `ssl_client` spawned by busybox wget
  on every check stays a zombie and piles up thousands of PIDs a day.
- **HTTP/3 is disabled** (`protocols h1 h2`). Useless for a static decoy, and QUIC
  buffers eat noticeable memory on 1–2 GB nodes.
- **Port 443 is published only when it is free.** If Xray listens on 443, Reality serves
  the decoy itself via `target` and no publish is needed. Worse, Docker would grab the
  port first, Xray would fail to bind after a restart and the node would drop. The
  script checks who actually holds 443 and refuses to publish when it sees `rw-core`.
  If Xray is on another port (1443 etc.), 443 goes to Caddy: otherwise the domain from
  `serverNames` does not answer from outside at all, which is worse for masking than
  an ordinary site.
- **Detection of an existing installation** with an offer to fully reinstall. The
  `caddy_data` volume is **kept**: Let's Encrypt issues only 5 identical certificates
  per week, and reinstalls hit that limit easily.
- **Self-check after start** — `openssl s_client` with the correct SNI.
- The inbound is not generated. The script prints `target` and `serverNames` for manual
  setup in the panel.

### WARP: Docker SOCKS5 instead of WARP-NATIVE

`scripts/remnanode/install-warp.sh`. Native WARP (wgcf + `wg-quick@warp`) is removed,
replaced by the [`ghcr.io/kingcc/warproxy`](https://github.com/kingcc/warproxy)
container (wireproxy) with SOCKS5. Xray uses it as an outbound:

```json
{"tag":"WARP","protocol":"socks","settings":{"servers":[{"address":"172.17.0.1","port":1080}]}}
```

#### Why registration stopped working

Cloudflare checks the client's TLS fingerprint on `api.cloudflareclient.com`.
The `kingcc/warproxy` image was built in 2025 with an old `wgcf`; its fingerprint no
longer passes and registration gets `429 Too Many Requests` — this is **not** a per-IP
limit, waiting does not help. Fixed in wgcf 2.3.0 (API `v0a5641` + new fingerprint),
see [ViRb3/wgcf#626](https://github.com/ViRb3/wgcf/issues/626).

#### How it works now

- The script downloads **wgcf ≥ 2.3.0** to `/opt/warproxy/bin` and registers the account
  **itself, on the host, before the container starts**. Without a valid account and
  profile the container is not started — otherwise it would go and register by itself.
- The same wgcf is mounted into the container (`./bin/wgcf:/usr/local/bin/wgcf:ro`),
  so the image's old binary no longer talks to the API.
- `wireproxy.conf` is rebuilt by the script on every install. Previously a broken file
  from a failed start (`one and only one [Interface] is expected`) survived every
  reinstall: the image only creates it when the file is missing.
- The tunnel is checked via `cloudflare.com/cdn-cgi/trace` through SOCKS5 (`warp=on`).
  The old `wg show` check never fired: the container runs userspace wireproxy, there is
  no `wg` interface in it.
- TikTok reachability through WARP is checked as well.

#### No re-registrations

With an existing installation the script asks:

1. **Reinstall keeping the account** (default, and always when there is no terminal);
2. **Full reinstall with a new registration** — the old account goes to backup.
   If the new registration fails, **the previous account is restored automatically**.

The account is stored in `/opt/warproxy/config`; before the container is recreated it
is pulled out of the running container (`docker cp`). Backups: `/opt/warproxy/backup/`.
If the profile does not match the account key (e.g. after an import), it is regenerated.

If the hosting did hit a real limit, register the account at home
(`wgcf.exe register`, wgcf ≥ 2.3.0) and import it: by file path, by pasting the
content (`p`), or with `WARP_ACCOUNT_FILE=...`.

#### TikTok via WARP

After installation a ready block for Remnawave (Config profiles) is printed and saved to
`/opt/warproxy/xray-warp-tiktok.json`:

- outbounds `WARP` (socks) and `BLOCK` (blackhole, if you do not have it yet);
- rules at the **top** of `routing.rules`: UDP 443 to TikTok domains → `BLOCK`, all other
  TikTok traffic → `WARP`. QUIC is blocked on purpose — wireproxy SOCKS5 carries TCP only,
  the app falls back to TCP and goes through WARP;
- inbounds need `sniffing` with `destOverride: ["http","tls","quic"]`, otherwise domain
  rules do not match.

Domains are listed explicitly, without `geosite:tiktok`: if the node's geosite.dat lacks
that category, Xray does not start at all.

## What not to do

- Do not delete `/opt/warproxy/config` — it holds the WARP account; without it a new
  registration is needed.
- Do not run `docker compose down -v` in `/opt/selfsteal` — it wipes the certificates.
- Do not publish 443 to Caddy if Xray sits on it.

## Variables for non-interactive mode

Selfsteal:

```
DOMAIN, ACME_EMAIL, LOCAL_PORT, XRAY_PORT, SITE_NAME, REINSTALL_CONFIRM
```

WARP:

```
WARP_MODE=keep|reregister|cancel, WARP_ACCOUNT_FILE, WARP_ENDPOINT,
BIND_ADDR, SOCKS_PORT, TZ_VAL, WGCF_VERSION, WARP_REG_ATTEMPTS
```

`REINSTALL_CONFIRM=y` for WARP is kept for compatibility and means `WARP_MODE=keep`.

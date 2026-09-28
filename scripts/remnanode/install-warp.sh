#!/bin/bash
#
# WARP SOCKS5 proxy (Docker) — Xray использует его как outbound:
#   {"protocol":"socks","settings":{"servers":[{"address":"172.17.0.1","port":1080}]}}
#
# ПОЧЕМУ WARP ПЕРЕСТАЛ РЕГИСТРИРОВАТЬСЯ
#   Cloudflare проверяет TLS-отпечаток клиента на api.cloudflareclient.com.
#   Образ ghcr.io/kingcc/warproxy собран в 2025 г. со старым wgcf, его отпечаток
#   больше не проходит, и любая регистрация получает "429 Too Many Requests"
#   (это не лимит по IP, ждать бесполезно). Исправлено в wgcf 2.3.0
#   (API v0a5641 + новый отпечаток): https://github.com/ViRb3/wgcf/issues/626
#
# ЧТО ДЕЛАЕТ СКРИПТ
#   1. Качает wgcf >= 2.3.0 в /opt/warproxy/bin и регистрирует аккаунт САМ,
#      на хосте, до запуска контейнера. Без валидного аккаунта и профиля
#      контейнер не запускается — иначе он полезет регистрироваться сам.
#   2. Подкладывает этот же wgcf в контейнер (read-only mount), чтобы старый
#      бинарник образа не ходил в API.
#   3. Сам собирает wireproxy.conf — битый файл от прошлых неудачных запусков
#      ("one and only one [Interface] is expected") больше не переживает
#      переустановку.
#   4. При существующей установке спрашивает: переустановить с сохранением
#      аккаунта или с новой регистрацией. По умолчанию — без перерегистрации.
#      Если новая регистрация не удалась — возвращает прежний аккаунт.
#   5. Проверяет туннель через cloudflare.com/cdn-cgi/trace (warp=on), а не
#      через `wg show` — в контейнере userspace wireproxy, интерфейса wg нет.
#   6. Печатает и сохраняет готовый блок Xray для TikTok через WARP.
#
# Неинтерактивные переменные:
#   WARP_MODE=keep|reregister|cancel   что делать с существующей установкой (default: keep)
#   WARP_ACCOUNT_FILE=/path/wgcf-account.toml   импорт готового аккаунта
#   WARP_ENDPOINT=162.159.192.1:2408   свой endpoint (если UDP к engage.* режется)
#   BIND_ADDR, SOCKS_PORT, TZ_VAL, WGCF_VERSION, WARP_REG_ATTEMPTS
#   REINSTALL_CONFIRM=y — устаревший флаг, трактуется как WARP_MODE=keep
#

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

INSTALL_DIR="${WARP_INSTALL_DIR:-/opt/warproxy}"
CONFIG_DIR="${INSTALL_DIR}/config"
BACKUP_DIR="${INSTALL_DIR}/backup"
BIN_DIR="${INSTALL_DIR}/bin"
WGCF_BIN="${BIN_DIR}/wgcf"
ACCOUNT="${CONFIG_DIR}/wgcf-account.toml"
PROFILE="${CONFIG_DIR}/wgcf-profile.conf"
WPCONF="${CONFIG_DIR}/wireproxy.conf"
SNIPPET="${INSTALL_DIR}/xray-warp-tiktok.json"
IMAGE="ghcr.io/kingcc/warproxy:latest"
CONTAINER="warproxy"
WGCF_MIN_VERSION="2.3.0"
STAMP=$(date +%Y%m%d-%H%M%S)
TMP_WORK=""
LINE="────────────────────────────────────────────────────────────"

TIKTOK_DOMAINS='"domain:tiktok.com", "domain:tiktokv.com", "domain:tiktokcdn.com", "domain:tiktokcdn-us.com",
          "domain:tiktokcdn-eu.com", "domain:tiktokv.us", "domain:tiktokv.eu", "domain:tiktokw.us",
          "domain:tiktokw.eu", "domain:tiktokd.net", "domain:tiktokd.org", "domain:tik-tokapi.com",
          "domain:ttwstatic.com", "domain:ttlivecdn.com", "domain:byteoversea.com", "domain:byteoversea.net",
          "domain:ibytedtos.com", "domain:ibyteimg.com", "domain:ipstatp.com", "domain:muscdn.com",
          "domain:musical.ly", "domain:bytedapm.com", "domain:isnssdk.com", "domain:sgpstatp.com"'

t() {
    local key="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$key" in
            hdr)             echo "WARP SOCKS5 proxy (Docker) — installation" ;;
            found)           echo "Existing installation detected" ;;
            acc_state_ok)    echo "WARP account: present" ;;
            acc_state_none)  echo "WARP account: none" ;;
            mode_title)      echo "What should be done?" ;;
            mode_keep)       echo "Reinstall and KEEP the current WARP account (no re-registration) — recommended" ;;
            mode_rereg)      echo "Full reinstall with a NEW WARP registration (old account goes to backup)" ;;
            mode_cancel)     echo "Cancel" ;;
            mode_ask)        echo "Choose [1/2/0] (default 1):" ;;
            mode_bad)        echo "Enter 1, 2 or 0" ;;
            mode_selected)   echo "Mode" ;;
            rereg_confirm)   echo "A new account will be registered, the current one is moved to backup. Continue? [y/N]:" ;;
            cancelled)       echo "Cancelled, nothing changed." ;;
            rescuing)        echo "Pulling the account out of the existing container..." ;;
            rescued)         echo "Account rescued from the container" ;;
            rescue_fail)     echo "The container has no valid account." ;;
            backup_made)     echo "Backup" ;;
            keep_no_account) echo "Keep mode chosen, but there is no saved account — a registration is required (this is the first one, not a re-registration)." ;;
            wgcf_get)        echo "Downloading wgcf" ;;
            wgcf_ok)         echo "wgcf ready" ;;
            wgcf_fail)       echo "Could not download wgcf. Check access to github.com." ;;
            wgcf_too_old)    echo "is older than the minimum, using" ;;
            src_title)       echo "Where to get the WARP account from?" ;;
            src_hint)        echo "Enter — register automatically; a path — import wgcf-account.toml; p — paste the file content" ;;
            src_ask)         echo "Choice:" ;;
            retry_ask)       echo "Try another way? [y/N]:" ;;
            paste_hint)      echo "Paste wgcf-account.toml content and finish with an empty line:" ;;
            imported)        echo "Account imported." ;;
            import_bad)      echo "This is not a valid wgcf-account.toml (device_id / access_token / private_key required)" ;;
            not_found)       echo "File not found or empty" ;;
            registering)     echo "Registering a WARP account" ;;
            attempt)         echo "attempt" ;;
            reg_ok)          echo "Account registered." ;;
            reg_fail)        echo "Registration failed." ;;
            reg_429)         echo "Cloudflare answers 429. With wgcf >= 2.3.0 this is usually a real per-IP limit of this hosting." ;;
            reg_what_now)    echo "The container is NOT started without an account (otherwise it would try to register by itself). Options:" ;;
            reg_opt_home)    echo "register at home (Windows: wgcf.exe register) and import the file:" ;;
            reg_opt_node)    echo "copy the account from a node where WARP works:" ;;
            reg_opt_wait)    echo "or retry later (the limit clears within hours)." ;;
            restoring_old)   echo "New registration failed — restoring the previous account, WARP keeps working on it." ;;
            gen_profile)     echo "Generating WireGuard profile" ;;
            gen_ok)          echo "Profile ready." ;;
            gen_fail)        echo "Could not generate the profile." ;;
            profile_mismatch) echo "The profile does not match the account key — regenerating." ;;
            profile_reuse)   echo "Profile matches the account, reusing it." ;;
            wp_built)        echo "wireproxy.conf rebuilt from the profile" ;;
            ask_bind)        echo "Bind address (Xray connects here)" ;;
            ask_port)        echo "SOCKS5 port" ;;
            ask_tz)          echo "Timezone" ;;
            bind_missing)    echo "this address does not exist on the host. For remnanode (network_mode: host) 127.0.0.1 works; 172.17.0.1 requires the docker0 bridge." ;;
            bind_public)     echo "0.0.0.0 publishes an open SOCKS5 proxy to the whole internet." ;;
            bind_public_ask) echo "Really bind to 0.0.0.0? [y/N]:" ;;
            port_bad)        echo "Port must be a number 1-65535" ;;
            port_busy)       echo "port is already taken by another process" ;;
            removing)        echo "Removing the old container (account is kept)..." ;;
            pulling)         echo "Updating image..." ;;
            starting)        echo "Starting..." ;;
            start_fail)      echo "docker compose up failed" ;;
            waiting)         echo "Waiting for the tunnel (up to ~90s)..." ;;
            up)              echo "WARP tunnel is up" ;;
            exit_ip)         echo "Exit IP via WARP" ;;
            server_ip)       echo "server" ;;
            same_ip)         echo "SOCKS answers but the IP equals the server IP — traffic bypasses WARP." ;;
            tiktok_ok)       echo "TikTok via WARP answers, HTTP" ;;
            tiktok_fail)     echo "TikTok did not answer via WARP (HTTP" ;;
            badconf)         echo "wireproxy rejected the config (one and only one [Interface])." ;;
            rate)            echo "The container tried to register by itself and got 429." ;;
            no_tunnel)       echo "Tunnel did not come up in time." ;;
            udp_hint)        echo "WARP uses UDP 2408. If the host blocks it, set another endpoint and rerun in keep mode:" ;;
            xray_title)      echo "Remnawave → Config profiles → your profile:" ;;
            xray_step1)      echo "1) add to \"outbounds\" (BLOCK — only if you do not have it yet):" ;;
            xray_step2)      echo "2) put these rules at the TOP of \"routing.rules\":" ;;
            xray_step3)      echo "3) inbounds must have sniffing on: \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"]}" ;;
            xray_quic)       echo "QUIC to TikTok is blocked on purpose: wireproxy SOCKS5 carries TCP only, the app falls back to TCP and goes through WARP." ;;
            xray_saved)      echo "Full snippet (all TikTok domains) saved to" ;;
            keep_dir)        echo "Do not delete this directory by hand — it holds the WARP account." ;;
            check_any)       echo "Check at any time:" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            hdr)             echo "WARP SOCKS5 прокси (Docker) — установка" ;;
            found)           echo "Обнаружена существующая установка" ;;
            acc_state_ok)    echo "Аккаунт WARP: есть" ;;
            acc_state_none)  echo "Аккаунт WARP: нет" ;;
            mode_title)      echo "Что делаем?" ;;
            mode_keep)       echo "Переустановить и СОХРАНИТЬ текущий аккаунт WARP (без перерегистрации) — рекомендуется" ;;
            mode_rereg)      echo "Полностью переустановить с НОВОЙ регистрацией WARP (старый аккаунт уйдёт в бэкап)" ;;
            mode_cancel)     echo "Отмена" ;;
            mode_ask)        echo "Выберите [1/2/0] (по умолчанию 1):" ;;
            mode_bad)        echo "Введите 1, 2 или 0" ;;
            mode_selected)   echo "Режим" ;;
            rereg_confirm)   echo "Будет зарегистрирован новый аккаунт, текущий уйдёт в бэкап. Продолжить? [y/N]:" ;;
            cancelled)       echo "Отменено, ничего не изменено." ;;
            rescuing)        echo "Забираю аккаунт из существующего контейнера..." ;;
            rescued)         echo "Аккаунт спасён из контейнера" ;;
            rescue_fail)     echo "В контейнере нет валидного аккаунта." ;;
            backup_made)     echo "Бэкап" ;;
            keep_no_account) echo "Выбран режим с сохранением, но сохранённого аккаунта нет — нужна регистрация (это первая регистрация, а не повторная)." ;;
            wgcf_get)        echo "Скачиваю wgcf" ;;
            wgcf_ok)         echo "wgcf готов" ;;
            wgcf_fail)       echo "Не удалось скачать wgcf. Проверьте доступ к github.com." ;;
            wgcf_too_old)    echo "старше минимальной, беру" ;;
            src_title)       echo "Откуда взять аккаунт WARP?" ;;
            src_hint)        echo "Enter — зарегистрировать автоматически; путь — импорт wgcf-account.toml; p — вставить содержимое файла" ;;
            src_ask)         echo "Выбор:" ;;
            retry_ask)       echo "Попробовать другим способом? [y/N]:" ;;
            paste_hint)      echo "Вставьте содержимое wgcf-account.toml и завершите пустой строкой:" ;;
            imported)        echo "Аккаунт импортирован." ;;
            import_bad)      echo "Это не валидный wgcf-account.toml (нужны device_id / access_token / private_key)" ;;
            not_found)       echo "Файл не найден или пуст" ;;
            registering)     echo "Регистрирую аккаунт WARP" ;;
            attempt)         echo "попытка" ;;
            reg_ok)          echo "Аккаунт зарегистрирован." ;;
            reg_fail)        echo "Регистрация не удалась." ;;
            reg_429)         echo "Cloudflare отвечает 429. С wgcf >= 2.3.0 это обычно уже реальный лимит по IP этого хостинга." ;;
            reg_what_now)    echo "Без аккаунта контейнер НЕ запускается (иначе он пойдёт регистрироваться сам). Варианты:" ;;
            reg_opt_home)    echo "зарегистрировать дома (Windows: wgcf.exe register) и импортировать файл:" ;;
            reg_opt_node)    echo "перенести аккаунт с ноды, где WARP работает:" ;;
            reg_opt_wait)    echo "либо повторить позже (лимит спадает за несколько часов)." ;;
            restoring_old)   echo "Новая регистрация не удалась — возвращаю прежний аккаунт, WARP продолжит работать на нём." ;;
            gen_profile)     echo "Генерирую WireGuard-профиль" ;;
            gen_ok)          echo "Профиль готов." ;;
            gen_fail)        echo "Не удалось сгенерировать профиль." ;;
            profile_mismatch) echo "Профиль не соответствует ключу аккаунта — генерирую заново." ;;
            profile_reuse)   echo "Профиль соответствует аккаунту, использую его." ;;
            wp_built)        echo "wireproxy.conf пересобран из профиля" ;;
            ask_bind)        echo "Адрес привязки (Xray ходит сюда)" ;;
            ask_port)        echo "SOCKS5 порт" ;;
            ask_tz)          echo "Таймзона" ;;
            bind_missing)    echo "такого адреса на хосте нет. Для remnanode (network_mode: host) подходит 127.0.0.1; 172.17.0.1 требует мост docker0." ;;
            bind_public)     echo "0.0.0.0 публикует открытый SOCKS5-прокси на весь интернет." ;;
            bind_public_ask) echo "Точно привязать к 0.0.0.0? [y/N]:" ;;
            port_bad)        echo "Порт должен быть числом 1-65535" ;;
            port_busy)       echo "порт уже занят другим процессом" ;;
            removing)        echo "Удаляю старый контейнер (аккаунт сохраняется)..." ;;
            pulling)         echo "Обновляю образ..." ;;
            starting)        echo "Запускаю..." ;;
            start_fail)      echo "docker compose up завершился с ошибкой" ;;
            waiting)         echo "Жду подъёма туннеля (до ~90с)..." ;;
            up)              echo "Туннель WARP поднят" ;;
            exit_ip)         echo "Выходной IP через WARP" ;;
            server_ip)       echo "сервер" ;;
            same_ip)         echo "SOCKS отвечает, но IP совпадает с серверным — трафик идёт мимо WARP." ;;
            tiktok_ok)       echo "TikTok через WARP отвечает, HTTP" ;;
            tiktok_fail)     echo "TikTok через WARP не ответил (HTTP" ;;
            badconf)         echo "wireproxy отверг конфиг (one and only one [Interface])." ;;
            rate)            echo "Контейнер пытался регистрироваться сам и получил 429." ;;
            no_tunnel)       echo "Туннель за отведённое время не поднялся." ;;
            udp_hint)        echo "WARP ходит по UDP 2408. Если хостер его режет — задайте другой endpoint и перезапустите в режиме keep:" ;;
            xray_title)      echo "Remnawave → Config profiles → ваш профиль:" ;;
            xray_step1)      echo "1) добавить в \"outbounds\" (BLOCK — только если его ещё нет):" ;;
            xray_step2)      echo "2) эти правила поставить В НАЧАЛО \"routing.rules\":" ;;
            xray_step3)      echo "3) в инбаундах должен быть включён sniffing: \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"]}" ;;
            xray_quic)       echo "QUIC к TikTok блокируется намеренно: SOCKS5 у wireproxy несёт только TCP, приложение откатывается на TCP и идёт через WARP." ;;
            xray_saved)      echo "Полный сниппет (все домены TikTok) сохранён в" ;;
            keep_dir)        echo "Каталог руками не удалять — в нём аккаунт WARP." ;;
            check_any)       echo "Проверка в любой момент:" ;;
            *) echo "$key" ;;
        esac
    fi
}

cleanup() {
    [ -n "$TMP_WORK" ] && rm -rf "$TMP_WORK"
}
trap cleanup EXIT

ask() {
    local prompt="$1" default="$2" varname="$3"
    local current="${!varname}"
    if [ -n "$current" ]; then
        info "${varname}=${current}"
        return
    fi
    if is_non_interactive; then
        printf -v "$varname" '%s' "$default"
        info "${varname}=${default}"
        return
    fi
    question "${prompt}${default:+ [$default]}:"
    printf -v "$varname" '%s' "${REPLY:-$default}"
}

check_docker() {
    if ! command_exists docker; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
    fi
    if ! docker info >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
    fi
    if ! docker compose version &>/dev/null; then
        error "docker compose plugin missing"
        exit 1
    fi
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"
}

# ---------- валидация файлов ----------

toml_value() {
    # toml_value <file> <key>  →  значение из  key = '...'  /  key = "..."
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" "$1" 2>/dev/null | head -1
}

account_valid() {
    local f="$1"
    [ -s "$f" ] || return 1
    [ -n "$(toml_value "$f" device_id)" ] || return 1
    [ -n "$(toml_value "$f" access_token)" ] || return 1
    [ -n "$(toml_value "$f" private_key)" ] || return 1
    return 0
}

profile_valid() {
    local f="$1"
    [ -s "$f" ] || return 1
    [ "$(grep -c '^\[Interface\]' "$f")" = "1" ] || return 1
    [ "$(grep -c '^\[Peer\]' "$f")" = "1" ] || return 1
    grep -qE '^PrivateKey[[:space:]]*=' "$f" || return 1
    grep -qE '^Address[[:space:]]*=' "$f" || return 1
    grep -qE '^PublicKey[[:space:]]*=' "$f" || return 1
    grep -qE '^Endpoint[[:space:]]*=' "$f" || return 1
    return 0
}

profile_matches_account() {
    local acc_key prof_key
    acc_key=$(toml_value "$ACCOUNT" private_key)
    prof_key=$(sed -nE 's/^PrivateKey[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$PROFILE" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -n "$acc_key" ] && [ "$acc_key" = "$prof_key" ]
}

backup_file_stamped() {
    # backup_file_stamped <src> [suffix]
    [ -s "$1" ] || return 0
    local dst
    dst="${BACKUP_DIR}/$(basename "$1").${STAMP}${2:+.$2}"
    cp -p "$1" "$dst" && chmod 600 "$dst"
    info "$(t backup_made): $dst"
}

# ---------- wgcf ----------

version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

wgcf_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armv7)   echo "armv7" ;;
        armv6l)         echo "armv6" ;;
        armv5*)         echo "armv5" ;;
        i386|i686)      echo "386" ;;
        s390x)          echo "s390x" ;;
        *)              echo "" ;;
    esac
}

install_wgcf() {
    local have=""
    [ -f "${BIN_DIR}/wgcf.version" ] && have=$(cat "${BIN_DIR}/wgcf.version")
    if [ -x "$WGCF_BIN" ] && [ -n "$have" ] && version_ge "$have" "$WGCF_MIN_VERSION" \
        && { [ -z "$WGCF_VERSION" ] || [ "$have" = "${WGCF_VERSION#v}" ]; }; then
        info "$(t wgcf_ok): v${have}"
        return 0
    fi

    local ver="${WGCF_VERSION#v}"
    if [ -z "$ver" ]; then
        # /releases/latest редиректит на /releases/tag/vX.Y.Z — без GitHub API и его лимитов
        ver=$(curl -fsSL -o /dev/null -w '%{url_effective}' --max-time 15 \
              https://github.com/ViRb3/wgcf/releases/latest 2>/dev/null | sed -nE 's#.*/tag/v?([0-9][0-9.]*)$#\1#p')
    fi
    if [ -z "$ver" ] || ! version_ge "$ver" "$WGCF_MIN_VERSION"; then
        [ -n "$ver" ] && warn "wgcf v${ver} $(t wgcf_too_old) v${WGCF_MIN_VERSION}"
        ver="$WGCF_MIN_VERSION"
    fi

    local arch
    arch=$(wgcf_arch)
    if [ -z "$arch" ]; then
        error "Unsupported architecture: $(uname -m)"
        return 1
    fi

    local url="https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    info "$(t wgcf_get) v${ver} (${arch})..."
    create_directory "$BIN_DIR"
    if curl -fsSL --retry 3 --max-time 120 -o "${WGCF_BIN}.new" "$url" \
        && chmod 755 "${WGCF_BIN}.new" \
        && "${WGCF_BIN}.new" --help >/dev/null 2>&1; then
        mv -f "${WGCF_BIN}.new" "$WGCF_BIN"
        echo "$ver" > "${BIN_DIR}/wgcf.version"
        success "$(t wgcf_ok): v${ver}"
        return 0
    fi
    rm -f "${WGCF_BIN}.new"
    error "$(t wgcf_fail)"
    echo "  $url"
    return 1
}

REG_RATE_LIMITED="no"

register_account() {
    local attempts="${WARP_REG_ATTEMPTS:-3}" i out rc
    local tmp="${TMP_WORK}/reg"
    REG_RATE_LIMITED="no"
    for i in $(seq 1 "$attempts"); do
        rm -rf "$tmp" && mkdir -p "$tmp"
        info "$(t registering) ($(t attempt) ${i}/${attempts})..."
        out=$(cd "$tmp" && timeout 90 "$WGCF_BIN" register --accept-tos --config "${tmp}/wgcf-account.toml" 2>&1)
        rc=$?
        if [ $rc -eq 0 ] && account_valid "${tmp}/wgcf-account.toml"; then
            install -m 600 "${tmp}/wgcf-account.toml" "$ACCOUNT"
            backup_file_stamped "$ACCOUNT" "registered"
            success "$(t reg_ok)"
            return 0
        fi
        echo "$out" | tail -n 4 | sed 's/^/    /'
        if echo "$out" | grep -qiE '429|too many requests'; then
            REG_RATE_LIMITED="yes"
        fi
        [ "$i" -lt "$attempts" ] && sleep $((i * 15))
    done
    error "$(t reg_fail)"
    return 1
}

generate_profile() {
    local attempts=3 i out
    local tmp="${TMP_WORK}/gen"
    info "$(t gen_profile)..."
    for i in $(seq 1 "$attempts"); do
        rm -rf "$tmp" && mkdir -p "$tmp"
        out=$(cd "$tmp" && timeout 90 "$WGCF_BIN" generate --config "$ACCOUNT" --profile "${tmp}/wgcf-profile.conf" 2>&1)
        if profile_valid "${tmp}/wgcf-profile.conf"; then
            install -m 600 "${tmp}/wgcf-profile.conf" "$PROFILE"
            success "$(t gen_ok)"
            return 0
        fi
        echo "$out" | tail -n 4 | sed 's/^/    /'
        [ "$i" -lt "$attempts" ] && sleep $((i * 10))
    done
    error "$(t gen_fail)"
    return 1
}

import_account_from() {
    local src="$1"
    if [ ! -s "$src" ]; then
        error "$(t not_found): $src"
        return 1
    fi
    if ! account_valid "$src"; then
        error "$(t import_bad)"
        return 1
    fi
    install -m 600 "$src" "$ACCOUNT"
    backup_file_stamped "$ACCOUNT" "imported"
    success "$(t imported)"
    return 0
}

paste_account() {
    local f="${TMP_WORK}/pasted.toml" line
    : > "$f"
    info "$(t paste_hint)"
    while IFS= read -r line; do
        [ -z "$line" ] && break
        printf '%s\n' "$line" >> "$f"
    done
    import_account_from "$f"
}

print_reg_help() {
    [ "$REG_RATE_LIMITED" = "yes" ] && warn "$(t reg_429)"
    warn "$(t reg_what_now)"
    echo -e "${BOLD_YELLOW}  •${RESET} $(t reg_opt_home)"
    echo "      https://github.com/ViRb3/wgcf/releases  (wgcf >= ${WGCF_MIN_VERSION})"
    echo "      WARP_ACCOUNT_FILE=/root/wgcf-account.toml bash /opt/remnasetup/remnasetup.sh install-warp"
    echo -e "${BOLD_YELLOW}  •${RESET} $(t reg_opt_node)"
    echo "      docker exec ${CONTAINER} cat /config/wgcf-account.toml"
    echo -e "${BOLD_YELLOW}  •${RESET} $(t reg_opt_wait)"
}

# Аккаунт: импорт из WARP_ACCOUNT_FILE → интерактивный выбор → автоматическая регистрация.
obtain_account() {
    if [ -n "$WARP_ACCOUNT_FILE" ]; then
        import_account_from "$WARP_ACCOUNT_FILE"
        return $?
    fi

    if ! is_non_interactive; then
        while true; do
            echo
            info "$(t src_title)"
            echo "  $(t src_hint)"
            question "$(t src_ask)"
            case "$REPLY" in
                "")
                    if [ -x "$WGCF_BIN" ] || install_wgcf; then
                        register_account && return 0
                        print_reg_help
                    fi
                    ;;
                p|P)
                    paste_account && return 0
                    ;;
                *)
                    import_account_from "$REPLY" && return 0
                    ;;
            esac
            question "$(t retry_ask)"
            [[ "$REPLY" =~ ^[Yy]$ ]] || return 1
        done
    fi

    { [ -x "$WGCF_BIN" ] || install_wgcf; } || return 1
    register_account && return 0
    print_reg_help
    return 1
}

# Пока старый контейнер жив, аккаунт ещё можно достать; после docker rm — нет.
rescue_from_container() {
    container_exists || return 0
    account_valid "$ACCOUNT" && return 0
    info "$(t rescuing)"
    local tmp="${TMP_WORK}/rescue"
    mkdir -p "$tmp"
    if docker cp "${CONTAINER}:/config/wgcf-account.toml" "${tmp}/wgcf-account.toml" >/dev/null 2>&1 \
        && account_valid "${tmp}/wgcf-account.toml"; then
        install -m 600 "${tmp}/wgcf-account.toml" "$ACCOUNT"
        success "$(t rescued): $ACCOUNT"
        if docker cp "${CONTAINER}:/config/wgcf-profile.conf" "${tmp}/wgcf-profile.conf" >/dev/null 2>&1 \
            && profile_valid "${tmp}/wgcf-profile.conf" && [ ! -s "$PROFILE" ]; then
            install -m 600 "${tmp}/wgcf-profile.conf" "$PROFILE"
        fi
    else
        warn "$(t rescue_fail)"
    fi
}

# wireproxy.conf собираем сами и всегда заново: образ создаёт его только если
# файла нет, поэтому битый файл от неудачного старта жил бы вечно.
build_wireproxy_conf() {
    local tmp="${TMP_WORK}/wireproxy.conf"
    awk -v ep="$WARP_ENDPOINT" '
        /^[[:space:]]*$/ { next }
        /^PersistentKeepalive/ { ka=1 }
        /^Endpoint[[:space:]]*=/ && ep != "" { print "Endpoint = " ep; next }
        { print }
        END { if (!ka) print "PersistentKeepalive = 25" }
    ' "$PROFILE" > "$tmp"
    {
        echo
        echo "[Socks5]"
        echo "BindAddress = 0.0.0.0:1080"
    } >> "$tmp"
    install -m 600 "$tmp" "$WPCONF"
    info "$(t wp_built): $WPCONF"
}

addr_on_host() {
    local a="$1"
    if [ "$a" = "0.0.0.0" ] || [ "$a" = "127.0.0.1" ]; then
        return 0
    fi
    ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$a"
}

port_taken() {
    local addr="$1" port="$2"
    command -v ss >/dev/null 2>&1 || return 1
    ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE "^(\*|0\.0\.0\.0|\[::\]|${addr//./\\.}):${port}$"
}

remove_container() {
    info "$(t removing)"
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        (cd "$INSTALL_DIR" && docker compose down --remove-orphans >/dev/null 2>&1) || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

write_compose() {
    local vol_wgcf=""
    if [ -x "$WGCF_BIN" ]; then
        # свежий wgcf внутрь контейнера: старый из образа не проходит проверку Cloudflare
        vol_wgcf=$'\n      - ./bin/wgcf:/usr/local/bin/wgcf:ro'
    fi
    cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  warproxy:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    restart: always
    ports:
      - "${BIND_ADDR}:${SOCKS_PORT}:1080"
    environment:
      - WARP_ENABLED=true
      - WARP_PLUS=false
      - SOCKS5_PORT=1080
      - TZ=${TZ_VAL}
    # Аккаунт WARP живёт здесь. Без этого volume он теряется при каждом
    # пересоздании контейнера и начинается повторная регистрация.
    volumes:
      - ./config:/config${vol_wgcf}
    healthcheck:
      # у образа свой healthcheck с retries=1 — даём WARP время подняться
      start_period: 90s
      interval: 30s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

write_xray_snippet() {
    local addr="$1" port="$2"
    cat > "$SNIPPET" <<EOF
{
  "outbounds": [
    { "tag": "WARP", "protocol": "socks", "settings": { "servers": [ { "address": "${addr}", "port": ${port} } ] } },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "network": "udp",
        "port": "443",
        "domain": [
          ${TIKTOK_DOMAINS}
        ],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "domain": [
          ${TIKTOK_DOMAINS}
        ],
        "outboundTag": "WARP"
      }
    ]
  }
}
EOF
    chmod 644 "$SNIPPET"
}

choose_mode() {
    # → WARP_MODE = keep | reregister | cancel
    local m="${WARP_MODE,,}"
    case "$m" in
        keep|reregister|cancel) WARP_MODE="$m"; info "WARP_MODE=${WARP_MODE}"; return ;;
        "") ;;
        *) warn "WARP_MODE=${WARP_MODE}: keep|reregister|cancel → keep"; WARP_MODE="keep"; return ;;
    esac

    if [[ "$REINSTALL_CONFIRM" =~ ^(y|Y|yes|true)$ ]] || is_non_interactive; then
        # автоматика никогда не перерегистрирует сама
        WARP_MODE="keep"
        info "WARP_MODE=keep"
        return
    fi

    echo
    info "$(t mode_title)"
    echo -e "${BLUE}  1) $(t mode_keep)${RESET}"
    echo -e "${BLUE}  2) $(t mode_rereg)${RESET}"
    echo -e "${RED}  0) $(t mode_cancel)${RESET}"
    while true; do
        question "$(t mode_ask)"
        case "${REPLY:-1}" in
            1) WARP_MODE="keep"; break ;;
            2)
                question "$(t rereg_confirm)"
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then WARP_MODE="reregister"; else WARP_MODE="keep"; fi
                break
                ;;
            0) WARP_MODE="cancel"; break ;;
            *) warn "$(t mode_bad)" ;;
        esac
    done
    info "$(t mode_selected): ${WARP_MODE}"
}

restore_old_account() {
    warn "$(t restoring_old)"
    install -m 600 "${TMP_WORK}/old-account.toml" "$ACCOUNT"
    rm -f "$PROFILE"
    [ -f "${TMP_WORK}/old-profile.conf" ] && install -m 600 "${TMP_WORK}/old-profile.conf" "$PROFILE"
    OLD_SAVED="restored"
}

main() {
    check_root

    echo -e "${MAGENTA}${LINE}${RESET}"
    echo -e "${BOLD_MAGENTA}$(t hdr)${RESET}"
    echo -e "${MAGENTA}${LINE}${RESET}"

    check_docker

    TMP_WORK=$(mktemp -d)
    create_directory "$CONFIG_DIR"
    create_directory "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    # ---------- существующая установка ----------
    local existing=""
    container_exists && existing="container ${CONTAINER}"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && existing="${existing}${existing:+, }${INSTALL_DIR}"
    account_valid "$ACCOUNT" && existing="${existing}${existing:+, }wgcf-account.toml"

    if [ -n "$existing" ]; then
        warn "$(t found): ${existing}"
        docker ps -a --filter "name=^${CONTAINER}$" --format '      {{.Status}}   {{.Ports}}' 2>/dev/null || true
        rescue_from_container
        if account_valid "$ACCOUNT"; then info "$(t acc_state_ok)"; else info "$(t acc_state_none)"; fi
        choose_mode
    else
        WARP_MODE="fresh"
    fi

    if [ "$WARP_MODE" = "cancel" ]; then
        info "$(t cancelled)"
        exit 0
    fi

    # wgcf нужен для регистрации/генерации и для подмены старого wgcf в контейнере.
    # В режиме keep с живым аккаунтом и профилем без него можно обойтись.
    install_wgcf || true

    # ---------- аккаунт ----------
    OLD_SAVED="no"
    if [ -n "$WARP_ACCOUNT_FILE" ]; then
        # явный импорт важнее режима: текущий аккаунт — в бэкап, файл валидируется до замены
        if ! account_valid "$WARP_ACCOUNT_FILE"; then
            import_account_from "$WARP_ACCOUNT_FILE"
            exit 1
        fi
        if ! cmp -s "$WARP_ACCOUNT_FILE" "$ACCOUNT"; then
            backup_file_stamped "$ACCOUNT" "replaced"
            import_account_from "$WARP_ACCOUNT_FILE" || exit 1
        fi
    elif [ "$WARP_MODE" = "reregister" ] && account_valid "$ACCOUNT"; then
        backup_file_stamped "$ACCOUNT" "replaced"
        backup_file_stamped "$PROFILE" "replaced"
        mv -f "$ACCOUNT" "${TMP_WORK}/old-account.toml"
        [ -f "$PROFILE" ] && mv -f "$PROFILE" "${TMP_WORK}/old-profile.conf"
        OLD_SAVED="yes"
    elif account_valid "$ACCOUNT"; then
        # бэкап только если такого аккаунта в бэкапах ещё нет — без мусора на каждом запуске
        local last_bak
        last_bak=$(ls -t "${BACKUP_DIR}"/wgcf-account.toml.* 2>/dev/null | head -1)
        if [ -z "$last_bak" ] || ! cmp -s "$ACCOUNT" "$last_bak"; then
            backup_file_stamped "$ACCOUNT"
        fi
    fi

    if ! account_valid "$ACCOUNT"; then
        [ "$WARP_MODE" = "keep" ] && warn "$(t keep_no_account)"
        if ! obtain_account; then
            if [ "$OLD_SAVED" = "yes" ]; then
                restore_old_account
            else
                exit 1
            fi
        fi
    fi

    # ---------- профиль ----------
    if profile_valid "$PROFILE" && profile_matches_account; then
        info "$(t profile_reuse)"
    else
        profile_valid "$PROFILE" && warn "$(t profile_mismatch)"
        if [ ! -x "$WGCF_BIN" ] || ! generate_profile; then
            if [ "$OLD_SAVED" = "yes" ]; then
                restore_old_account
                if ! { profile_valid "$PROFILE" && profile_matches_account; }; then
                    exit 1
                fi
            else
                exit 1
            fi
        fi
    fi
    build_wireproxy_conf

    # ---------- параметры ----------
    local old_bind="" old_port="" old_line
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        old_line=$(grep -oE '"[0-9.]+:[0-9]+:1080"' "${INSTALL_DIR}/docker-compose.yml" 2>/dev/null | head -1 | tr -d '"')
        old_bind="${old_line%%:*}"
        old_port=$(echo "$old_line" | cut -d: -f2)
    fi

    ask "$(t ask_bind)" "${old_bind:-172.17.0.1}" BIND_ADDR
    while ! addr_on_host "$BIND_ADDR"; do
        error "${BIND_ADDR}: $(t bind_missing)"
        is_non_interactive && exit 1
        BIND_ADDR=""
        ask "$(t ask_bind)" "127.0.0.1" BIND_ADDR
    done
    if [ "$BIND_ADDR" = "0.0.0.0" ]; then
        warn "$(t bind_public)"
        is_non_interactive && exit 1
        question "$(t bind_public_ask)"
        [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
    fi

    ask "$(t ask_port)" "${old_port:-1080}" SOCKS_PORT
    while ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS_PORT" -lt 1 ] || [ "$SOCKS_PORT" -gt 65535 ]; do
        error "$(t port_bad)"
        is_non_interactive && exit 1
        SOCKS_PORT=""
        ask "$(t ask_port)" "1080" SOCKS_PORT
    done
    ask "$(t ask_tz)" "Europe/Moscow" TZ_VAL

    # ---------- (пере)запуск ----------
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && \
        cp "${INSTALL_DIR}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml.${STAMP}"
    remove_container

    if port_taken "$BIND_ADDR" "$SOCKS_PORT"; then
        error "${BIND_ADDR}:${SOCKS_PORT} — $(t port_busy)"
        ss -Htlnp 2>/dev/null | grep -E ":${SOCKS_PORT}\b" | sed 's/^/    /'
        exit 1
    fi

    info "$(t pulling)"
    docker pull "$IMAGE" >/dev/null || true

    write_compose
    info "$(t starting)"
    if ! (cd "$INSTALL_DIR" && docker compose up -d); then
        error "$(t start_fail)"
        exit 1
    fi

    # ---------- проверка ----------
    local test_addr="$BIND_ADDR"
    [ "$test_addr" = "0.0.0.0" ] && test_addr="127.0.0.1"
    local proxy="socks5h://${test_addr}:${SOCKS_PORT}"
    local state="unknown" trace="" logs

    info "$(t waiting)"
    for _ in $(seq 1 30); do
        sleep 3
        trace=$(curl -s --max-time 6 -x "$proxy" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
        if echo "$trace" | grep -qE '^warp=(on|plus)'; then state="up"; break; fi
        logs=$(docker logs "$CONTAINER" 2>&1 | tail -40 || true)
        if echo "$logs" | grep -q "one and only one \[Interface\]"; then state="badconf"; break; fi
        if echo "$logs" | grep -q "429 Too Many Requests"; then state="ratelimited"; break; fi
    done

    echo
    echo -e "${MAGENTA}${LINE}${RESET}"
    case "$state" in
        up)
            local warp_ip warp_loc host_ip tt_code
            warp_ip=$(echo "$trace" | sed -n 's/^ip=//p')
            warp_loc=$(echo "$trace" | sed -n 's/^loc=//p')
            host_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)
            success "$(t up) (warp=$(echo "$trace" | sed -n 's/^warp=//p'))"
            if [ -n "$warp_ip" ] && [ "$warp_ip" != "$host_ip" ]; then
                success "$(t exit_ip): ${warp_ip}${warp_loc:+ [$warp_loc]} ($(t server_ip) ${host_ip:-?})"
            else
                warn "$(t same_ip)"
            fi
            tt_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$proxy" https://www.tiktok.com/ 2>/dev/null || true)
            if [[ "$tt_code" =~ ^[23] ]]; then
                success "$(t tiktok_ok) ${tt_code}"
            else
                warn "$(t tiktok_fail) ${tt_code:-000})"
            fi
            cp -p "$ACCOUNT" "${BACKUP_DIR}/wgcf-account.toml.ok" 2>/dev/null || true
            ;;
        badconf)
            error "$(t badconf)"
            echo "  docker logs ${CONTAINER} --tail 60"
            echo "  cat ${WPCONF}"
            ;;
        ratelimited)
            error "$(t rate)"
            print_reg_help
            ;;
        *)
            warn "$(t no_tunnel)"
            echo "  docker logs ${CONTAINER} --tail 60"
            echo "  $(t udp_hint)"
            echo "    WARP_ENDPOINT=162.159.192.1:2408 WARP_MODE=keep bash /opt/remnasetup/remnasetup.sh install-warp"
            echo "    WARP_ENDPOINT=162.159.192.1:500  WARP_MODE=keep bash /opt/remnasetup/remnasetup.sh install-warp"
            ;;
    esac
    echo -e "${MAGENTA}${LINE}${RESET}"

    # ---------- Xray / Remnawave ----------
    write_xray_snippet "$test_addr" "$SOCKS_PORT"
    echo
    echo -e "${BOLD_CYAN}$(t xray_title)${RESET}"
    echo -e "${BOLD_CYAN}$(t xray_step1)${RESET}"
    echo -e "${BLUE}  {\"tag\":\"WARP\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"${test_addr}\",\"port\":${SOCKS_PORT}}]}}${RESET}"
    echo -e "${BLUE}  {\"tag\":\"BLOCK\",\"protocol\":\"blackhole\"}${RESET}"
    echo -e "${BOLD_CYAN}$(t xray_step2)${RESET}"
    echo -e "${BLUE}  {\"type\":\"field\",\"network\":\"udp\",\"port\":\"443\",\"domain\":[\"domain:tiktok.com\",\"domain:tiktokv.com\",\"domain:tiktokcdn.com\",…],\"outboundTag\":\"BLOCK\"}${RESET}"
    echo -e "${BLUE}  {\"type\":\"field\",\"domain\":[\"domain:tiktok.com\",\"domain:tiktokv.com\",\"domain:tiktokcdn.com\",…],\"outboundTag\":\"WARP\"}${RESET}"
    echo -e "${BOLD_CYAN}$(t xray_step3)${RESET}"
    info "$(t xray_quic)"
    info "$(t xray_saved): ${SNIPPET}"
    echo

    info "Account: ${ACCOUNT}"
    info "Backups: ${BACKUP_DIR}/"
    warn "$(t keep_dir)"
    echo
    info "$(t check_any)"
    echo "  curl -s -x ${proxy} https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)='"

    if [ "$state" = "up" ]; then
        [ "$SKIP_PAUSE" = "true" ] || pause_press_key "$(get_string "warp_native_press_key")"
        exit 0
    fi
    exit 1
}

main

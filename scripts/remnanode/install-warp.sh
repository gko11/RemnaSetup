#!/bin/bash
#
# WARP SOCKS5 proxy (Docker) — вместо нативного WARP на wgcf + wg-quick.
# Xray использует его как outbound: {"protocol":"socks","address":"172.17.0.1","port":1080}
#
# КЛЮЧЕВОЙ МОМЕНТ: аккаунт Cloudflare WARP лежит в /config. Если каталог не
# вынесен наружу, он умирает вместе с контейнером, при старте wgcf идёт
# регистрировать новый, а Cloudflare лимитирует регистрации по IP и на адресах
# хостингов быстро отдаёт 429 Too Many Requests. После этого туннель не
# поднимается вообще, а в логах видно лишь невнятное
# "one and only one [Interface] is expected" — это следствие, а не причина.
#

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

INSTALL_DIR="/opt/warproxy"
CONFIG_DIR="${INSTALL_DIR}/config"
BACKUP_DIR="${INSTALL_DIR}/backup"
STAMP=$(date +%Y%m%d-%H%M%S)

t() {
    local key="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$key" in
            hdr)           echo "WARP SOCKS5 proxy (Docker) — installation" ;;
            warn_account)  echo "The WARP account lives in /config. Without an external volume it dies with the container, and Cloudflare answers 429 to re-registration. This script keeps it outside." ;;
            found)         echo "Existing installation detected" ;;
            reinstall_note) echo "Full reinstall removes the container and compose file." ;;
            account_kept)  echo "The WARP account (wgcf-account.toml) is kept on purpose — without it a new registration hits 429." ;;
            ask_reinstall) echo "Perform a full reinstall? [y/N]:" ;;
            cancelled)     echo "Cancelled, nothing changed." ;;
            rescuing)      echo "Trying to rescue the account from the existing container..." ;;
            rescued)       echo "Account rescued" ;;
            rescue_fail)   echo "Could not pull the account out of the container." ;;
            have_account)  echo "Account already present, reusing it." ;;
            backup_made)   echo "Account backup" ;;
            no_account)    echo "No working WARP account." ;;
            import_hint)   echo "Bring wgcf-account.toml from a node where WARP is alive (docker exec warproxy cat /config/wgcf-account.toml), or register at home: wgcf register" ;;
            ask_import)    echo "Path to an existing wgcf-account.toml (Enter — try registration):" ;;
            imported)      echo "Account imported." ;;
            not_found)     echo "File not found or empty" ;;
            ask_bind)      echo "Bind address (Xray connects here)" ;;
            ask_port)      echo "SOCKS5 port" ;;
            ask_tz)        echo "Timezone" ;;
            removing)      echo "Removing container (account kept)..." ;;
            pulling)       echo "Updating image..." ;;
            starting)      echo "Starting..." ;;
            waiting)       echo "Waiting for the tunnel (up to ~90s)..." ;;
            up)            echo "WireGuard tunnel is up." ;;
            works)         echo "Proxy works: exiting via" ;;
            same_ip)       echo "SOCKS answers but the IP equals the server IP — traffic bypasses WARP." ;;
            no_exit)       echo "No exit through SOCKS5 — check: docker logs warproxy" ;;
            rate)          echo "Cloudflare refused registration: 429 Too Many Requests." ;;
            rate_expl)     echo "The limit is per IP. Hosting addresses are worn out by other people's registrations, and every container recreate spends another attempt." ;;
            no_tunnel)     echo "Tunnel did not come up in time." ;;
            udp_hint)      echo "WARP uses UDP 2408 — make sure the host does not block it:" ;;
            keep_dir)      echo "Do not delete this directory by hand — that is exactly what leads to 429." ;;
            check_any)     echo "Check at any time:" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            hdr)           echo "WARP SOCKS5 прокси (Docker) — установка" ;;
            warn_account)  echo "Аккаунт WARP лежит в /config. Без внешнего volume он умирает вместе с контейнером, а на повторную регистрацию Cloudflare отвечает 429. Скрипт выносит его наружу." ;;
            found)         echo "Обнаружена существующая установка" ;;
            reinstall_note) echo "Полная переустановка удалит контейнер и compose-файл." ;;
            account_kept)  echo "Аккаунт WARP (wgcf-account.toml) сохраняется намеренно — без него новая регистрация упрётся в 429." ;;
            ask_reinstall) echo "Выполнить полную переустановку? [y/N]:" ;;
            cancelled)     echo "Отменено, ничего не изменено." ;;
            rescuing)      echo "Пробую забрать аккаунт из существующего контейнера..." ;;
            rescued)       echo "Аккаунт спасён" ;;
            rescue_fail)   echo "Достать аккаунт из контейнера не удалось." ;;
            have_account)  echo "Аккаунт уже на месте, использую его." ;;
            backup_made)   echo "Бэкап аккаунта" ;;
            no_account)    echo "Рабочего аккаунта WARP нет." ;;
            import_hint)   echo "Принесите wgcf-account.toml с ноды, где WARP живой (docker exec warproxy cat /config/wgcf-account.toml), либо зарегистрируйте дома: wgcf register" ;;
            ask_import)    echo "Путь к готовому wgcf-account.toml (Enter — пробовать регистрацию):" ;;
            imported)      echo "Аккаунт импортирован." ;;
            not_found)     echo "Файл не найден или пуст" ;;
            ask_bind)      echo "Адрес привязки (Xray ходит сюда)" ;;
            ask_port)      echo "SOCKS5 порт" ;;
            ask_tz)        echo "Таймзона" ;;
            removing)      echo "Удаляю контейнер (аккаунт сохраняется)..." ;;
            pulling)       echo "Обновляю образ..." ;;
            starting)      echo "Запускаю..." ;;
            waiting)       echo "Жду подъёма туннеля (до ~90с)..." ;;
            up)            echo "WireGuard-туннель поднят." ;;
            works)         echo "Прокси работает: выходим через" ;;
            same_ip)       echo "SOCKS отвечает, но IP совпадает с серверным — трафик идёт мимо WARP." ;;
            no_exit)       echo "Через SOCKS5 наружу не вышли — проверьте: docker logs warproxy" ;;
            rate)          echo "Cloudflare отказал в регистрации: 429 Too Many Requests." ;;
            rate_expl)     echo "Лимит вешается на IP. Адреса хостингов заезжены чужими регистрациями, и каждое пересоздание контейнера тратит очередную попытку." ;;
            no_tunnel)     echo "Туннель за отведённое время не поднялся." ;;
            udp_hint)      echo "WARP ходит по UDP 2408 — проверьте, что хостер его не режет:" ;;
            keep_dir)      echo "Каталог руками не удалять — именно это приводит к 429." ;;
            check_any)     echo "Проверка в любой момент:" ;;
            *) echo "$key" ;;
        esac
    fi
}

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
    if ! docker compose version &>/dev/null; then
        error "docker compose plugin missing"
        exit 1
    fi
}

main() {
    check_root
    check_docker

    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD_MAGENTA}$(t hdr)${RESET}"
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    warn "$(t warn_account)"
    echo

    create_directory "$CONFIG_DIR"
    create_directory "$BACKUP_DIR"

    REINSTALL="no"
    EXISTING=""
    docker ps -a --format '{{.Names}}' | grep -qx warproxy && EXISTING="container warproxy"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && EXISTING="${EXISTING}${EXISTING:+, }${INSTALL_DIR}"

    if [ -n "$EXISTING" ]; then
        warn "$(t found): ${EXISTING}"
        docker ps -a --filter name=warproxy --format '      {{.Status}}   {{.Ports}}' 2>/dev/null || true
        info "$(t reinstall_note)"
        info "$(t account_kept)"
        if [[ "$REINSTALL_CONFIRM" =~ ^(y|Y|yes|true)$ ]] || is_non_interactive; then
            REINSTALL="yes"
        else
            question "$(t ask_reinstall)"
            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                REINSTALL="yes"
            else
                info "$(t cancelled)"
                exit 0
            fi
        fi
    fi

    # Спасаем аккаунт из старого контейнера, пока он ещё жив.
    # После docker rm файл исчезнет безвозвратно.
    if docker ps -a --format '{{.Names}}' | grep -qx warproxy; then
        if [ ! -s "${CONFIG_DIR}/wgcf-account.toml" ]; then
            info "$(t rescuing)"
            if docker cp warproxy:/config/wgcf-account.toml "${CONFIG_DIR}/wgcf-account.toml" 2>/dev/null; then
                success "$(t rescued): ${CONFIG_DIR}/wgcf-account.toml"
                docker cp warproxy:/config/wgcf-profile.conf "${CONFIG_DIR}/wgcf-profile.conf" 2>/dev/null || true
            else
                warn "$(t rescue_fail)"
            fi
        else
            info "$(t have_account)"
        fi
    fi

    if [ -s "${CONFIG_DIR}/wgcf-account.toml" ]; then
        cp "${CONFIG_DIR}/wgcf-account.toml" "${BACKUP_DIR}/wgcf-account.toml.${STAMP}"
        info "$(t backup_made): ${BACKUP_DIR}/wgcf-account.toml.${STAMP}"
    fi

    if [ ! -s "${CONFIG_DIR}/wgcf-account.toml" ]; then
        warn "$(t no_account)"
        info "$(t import_hint)"
        if ! is_non_interactive; then
            question "$(t ask_import)"
            IMPORT_PATH="$REPLY"
            if [ -n "$IMPORT_PATH" ]; then
                if [ -s "$IMPORT_PATH" ]; then
                    cp "$IMPORT_PATH" "${CONFIG_DIR}/wgcf-account.toml"
                    cp "$IMPORT_PATH" "${BACKUP_DIR}/wgcf-account.toml.imported.${STAMP}"
                    success "$(t imported)"
                else
                    error "$(t not_found): $IMPORT_PATH"
                    exit 1
                fi
            fi
        fi
    fi

    OLD_BIND=""; OLD_PORT=""
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        OLD_LINE=$(grep -oE '"[0-9.]+:[0-9]+:1080"' "${INSTALL_DIR}/docker-compose.yml" 2>/dev/null | tr -d '"')
        OLD_BIND="${OLD_LINE%%:*}"
        OLD_PORT=$(echo "$OLD_LINE" | cut -d: -f2)
    fi

    ask "$(t ask_bind)" "${OLD_BIND:-172.17.0.1}" BIND_ADDR
    ask "$(t ask_port)" "${OLD_PORT:-1080}"       SOCKS_PORT
    ask "$(t ask_tz)"   "Europe/Moscow"           TZ_VAL

    if [ "$REINSTALL" = "yes" ]; then
        [ -f "${INSTALL_DIR}/docker-compose.yml" ] && \
            cp "${INSTALL_DIR}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml.${STAMP}"
        info "$(t removing)"
        # без -v: именованные volume не трогаем, аккаунт уже в ./config
        if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
            (cd "$INSTALL_DIR" && docker compose down) || true
        fi
        docker rm -f warproxy 2>/dev/null || true
        rm -f "${INSTALL_DIR}/docker-compose.yml"
        info "$(t pulling)"
        docker pull ghcr.io/kingcc/warproxy:latest || true
    fi

    cd "$INSTALL_DIR" || exit 1

    cat > docker-compose.yml <<EOF
services:
  warproxy:
    image: ghcr.io/kingcc/warproxy:latest
    container_name: warproxy
    restart: always
    ports:
      - "${BIND_ADDR}:${SOCKS_PORT}:1080"
    environment:
      - SOCKS5_PORT=1080
      - TZ=${TZ_VAL}
    # БЕЗ ЭТОГО VOLUME аккаунт WARP теряется при каждом пересоздании контейнера,
    # после чего Cloudflare начинает отдавать 429 и прокси уже не поднимается.
    volumes:
      - ./config:/config
    healthcheck:
      # у образа свой healthcheck с retries=1 — он загорается unhealthy раньше,
      # чем WARP успевает подняться; даём время на старте
      start_period: 90s
      interval: 30s
      retries: 3
EOF

    info "$(t starting)"
    docker compose up -d

    info "$(t waiting)"
    STATE="unknown"
    for i in $(seq 1 30); do
        sleep 3
        LOGS=$(docker logs warproxy 2>&1 | tail -40 || true)
        if echo "$LOGS" | grep -q "429 Too Many Requests"; then STATE="ratelimited"; break; fi
        if docker exec warproxy sh -c 'wg show 2>/dev/null | grep -q interface' 2>/dev/null; then STATE="up"; break; fi
    done

    echo
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    case "$STATE" in
        up)
            success "$(t up)"
            WARP_IP=$(curl -s --max-time 10 --socks5 "${BIND_ADDR}:${SOCKS_PORT}" https://api.ipify.org || echo "")
            HOST_IP=$(curl -s --max-time 10 https://api.ipify.org || echo "")
            if [ -n "$WARP_IP" ] && [ "$WARP_IP" != "$HOST_IP" ]; then
                success "$(t works) ${WARP_IP} (server ${HOST_IP})"
            elif [ -n "$WARP_IP" ]; then
                warn "$(t same_ip)"
            else
                warn "$(t no_exit)"
            fi
            docker cp warproxy:/config/wgcf-account.toml "${BACKUP_DIR}/wgcf-account.toml.ok.${STAMP}" 2>/dev/null || true
            echo
            echo -e "${BOLD_CYAN}Xray outbound:${RESET}"
            echo -e "${BLUE}  {\"tag\":\"WARP\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"${BIND_ADDR}\",\"port\":${SOCKS_PORT}}]}}${RESET}"
            ;;
        ratelimited)
            error "$(t rate)"
            echo "  $(t rate_expl)"
            echo
            echo -e "${BOLD_YELLOW}  1.${RESET} cd ${INSTALL_DIR} && docker compose stop"
            echo -e "${BOLD_YELLOW}  2.${RESET} docker exec warproxy cat /config/wgcf-account.toml   # на рабочей ноде"
            echo -e "     → ${CONFIG_DIR}/wgcf-account.toml"
            echo -e "${BOLD_YELLOW}  3.${RESET} wgcf register  # с домашней машины"
            echo -e "${BOLD_YELLOW}  4.${RESET} подождать несколько часов"
            ;;
        *)
            warn "$(t no_tunnel)"
            echo "  docker logs warproxy --tail 60"
            echo "  $(t udp_hint)"
            echo "    nc -zvu engage.cloudflareclient.com 2408"
            ;;
    esac
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo
    info "Account: ${CONFIG_DIR}/wgcf-account.toml"
    info "Backups: ${BACKUP_DIR}/"
    warn "$(t keep_dir)"
    echo
    info "$(t check_any)"
    echo "  curl -s --socks5 ${BIND_ADDR}:${SOCKS_PORT} https://api.ipify.org"

    pause_press_key "$(get_string "warp_native_press_key")"
    exit 0
}

main

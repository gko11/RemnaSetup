#!/bin/bash
#
# Selfsteal (Docker + Caddy) — маскировочный сайт для Xray Reality.
# Отличия от нативной установки: всё в контейнере, сертификаты в volume,
# health-check ходит по домену (по голому IP Caddy рвёт хендшейк без SNI).
#

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

INSTALL_DIR="/opt/selfsteal"
BACKUP_DIR="${INSTALL_DIR}/backup"
STAMP=$(date +%Y%m%d-%H%M%S)

t() {
    local key="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$key" in
            hdr)            echo "Selfsteal (Docker + Caddy) — installation" ;;
            found)          echo "Existing installation detected" ;;
            reinstall_note) echo "Full reinstall removes the container, Caddyfile, compose and site files." ;;
            certs_kept)     echo "Volume caddy_data with certificates is kept on purpose: Let's Encrypt allows only 5 identical certificates per week." ;;
            ask_reinstall)  echo "Perform a full reinstall? [y/N]:" ;;
            cancelled)      echo "Cancelled, nothing changed." ;;
            ask_domain)     echo "Selfsteal domain" ;;
            ask_email)      echo "Email for Let's Encrypt" ;;
            ask_port)       echo "Local decoy port (xray target)" ;;
            ask_xray)       echo "Port the Xray inbound listens on" ;;
            ask_site)       echo "Decoy site name" ;;
            domain_req)     echo "Domain is required" ;;
            dns_ok_local)   echo "resolves to an address owned by this machine" ;;
            dns_ok_ext)     echo "matches the external IP" ;;
            dns_mismatch)   echo "resolves elsewhere; Let's Encrypt will not issue a certificate" ;;
            dns_none)       echo "does not resolve at all. Check the A record." ;;
            proceed)        echo "Continue anyway? [y/N]:" ;;
            xray_on_443)    echo "Xray is on 443 — Reality serves the decoy through target. No 443 publish needed." ;;
            xray_conflict)  echo "Port 443 is held by Xray. Publishing 443 to Caddy would steal it and the node would drop after restart. Skipping — safeguard." ;;
            port_busy)      echo "Port 443 is busy" ;;
            publish443)     echo "Xray is elsewhere, so 443 goes straight to Caddy — otherwise the serverNames domain is dead." ;;
            removing)       echo "Removing old installation (certificates kept)..." ;;
            starting)       echo "Starting container..." ;;
            cert_issued)    echo "Certificate issued." ;;
            cert_reused)    echo "Reused stored certificate from volume." ;;
            cert_unknown)   echo "No confirmation in logs — check: docker compose logs -f" ;;
            tls_ok)         echo "TLS answers with a valid certificate for" ;;
            tls_fail)       echo "TLS did not return a certificate — check: docker compose logs" ;;
            done_)          echo "Done." ;;
            for_inbound)    echo "For the inbound in the panel:" ;;
            check_outside)  echo "Check the decoy from OUTSIDE (not from this server):" ;;
            dead_domain)    echo "443 is not published and Xray is not on 443 — the domain does not answer from outside, although it is in serverNames." ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            hdr)            echo "Selfsteal (Docker + Caddy) — установка" ;;
            found)          echo "Обнаружена существующая установка" ;;
            reinstall_note) echo "Полная переустановка удалит контейнер, Caddyfile, compose и файлы сайта." ;;
            certs_kept)     echo "Volume caddy_data с сертификатами сохраняется намеренно: Let's Encrypt выдаёт лишь 5 одинаковых сертификатов в неделю." ;;
            ask_reinstall)  echo "Выполнить полную переустановку? [y/N]:" ;;
            cancelled)      echo "Отменено, ничего не изменено." ;;
            ask_domain)     echo "Домен для selfsteal" ;;
            ask_email)      echo "Email для Let's Encrypt" ;;
            ask_port)       echo "Локальный порт decoy-сайта (xray target)" ;;
            ask_xray)       echo "Порт, на котором слушает Xray-инбаунд" ;;
            ask_site)       echo "Название сайта-заглушки" ;;
            domain_req)     echo "Домен обязателен" ;;
            dns_ok_local)   echo "резолвится в адрес этой машины" ;;
            dns_ok_ext)     echo "совпадает с внешним IP" ;;
            dns_mismatch)   echo "резолвится не сюда; Let's Encrypt не выпустит сертификат" ;;
            dns_none)       echo "не резолвится вообще. Проверьте A-запись." ;;
            proceed)        echo "Продолжить всё равно? [y/N]:" ;;
            xray_on_443)    echo "Xray на 443 — заглушку отдаст сам Reality через target. Проброс 443 не нужен." ;;
            xray_conflict)  echo "Порт 443 занят Xray. Проброс 443 на Caddy отнимет его, и после рестарта нода отвалится. Пропускаю — это защита." ;;
            port_busy)      echo "Порт 443 занят" ;;
            publish443)     echo "Xray не на 443, значит 443 отдаём Caddy — иначе домен из serverNames будет мёртвым." ;;
            removing)       echo "Удаляю старую установку (сертификаты сохраняются)..." ;;
            starting)       echo "Запускаю контейнер..." ;;
            cert_issued)    echo "Сертификат выпущен." ;;
            cert_reused)    echo "Использован сохранённый сертификат из volume." ;;
            cert_unknown)   echo "Подтверждения в логах нет — проверьте: docker compose logs -f" ;;
            tls_ok)         echo "TLS отвечает валидным сертификатом для" ;;
            tls_fail)       echo "TLS не отдал сертификат — смотрите: docker compose logs" ;;
            done_)          echo "Готово." ;;
            for_inbound)    echo "Для инбаунда в панели:" ;;
            check_outside)  echo "Проверка decoy СНАРУЖИ (не с этого сервера):" ;;
            dead_domain)    echo "443 не опубликован и Xray не на 443 — домен снаружи не отвечает, хотя стоит в serverNames." ;;
            *) echo "$key" ;;
        esac
    fi
}

port_busy() {
    local p="$1"
    command -v ss &>/dev/null || return 1
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
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

    REINSTALL="no"
    EXISTING=""
    docker ps -a --format '{{.Names}}' | grep -qx selfsteal && EXISTING="container selfsteal"
    [ -f "${INSTALL_DIR}/docker-compose.yml" ] && EXISTING="${EXISTING}${EXISTING:+, }${INSTALL_DIR}"

    if [ -n "$EXISTING" ]; then
        warn "$(t found): ${EXISTING}"
        docker ps -a --filter name=selfsteal --format '      {{.Status}}   {{.Ports}}' 2>/dev/null || true
        info "$(t reinstall_note)"
        info "$(t certs_kept)"
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

    OLD_DOMAIN=""; OLD_EMAIL=""; OLD_PORT=""
    if [ -f "${INSTALL_DIR}/.env" ]; then
        OLD_DOMAIN=$(grep -E '^DOMAIN=' "${INSTALL_DIR}/.env" | cut -d= -f2-)
        OLD_EMAIL=$(grep -E '^ACME_EMAIL=' "${INSTALL_DIR}/.env" | cut -d= -f2-)
        OLD_PORT=$(grep -E '^LOCAL_PORT=' "${INSTALL_DIR}/.env" | cut -d= -f2-)
    fi

    ask "$(t ask_domain)" "$OLD_DOMAIN" DOMAIN
    if [ -z "$DOMAIN" ]; then
        error "$(t domain_req)"
        exit 1
    fi
    ask "$(t ask_email)" "${OLD_EMAIL:-admin@${DOMAIN}}" ACME_EMAIL
    ask "$(t ask_port)"  "${OLD_PORT:-8443}"             LOCAL_PORT
    ask "$(t ask_xray)"  "443"                           XRAY_PORT
    ask "$(t ask_site)"  "Northwind Systems"             SITE_NAME

    PUBLISH_443="no"
    OWNER=""
    if port_busy 443; then
        OWNER=$(ss -tlnp 2>/dev/null | awk '$4 ~ /[:.]443$/{print $NF}' | head -1)
    fi

    if [ "$XRAY_PORT" = "443" ]; then
        info "$(t xray_on_443)"
    elif echo "$OWNER" | grep -qiE 'rw-core|xray'; then
        warn "$(t xray_conflict)"
        echo "      $OWNER"
    elif [ -n "$OWNER" ]; then
        warn "$(t port_busy): $OWNER"
        if ! is_non_interactive; then
            question "$(t proceed)"
            [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
        fi
    else
        PUBLISH_443="yes"
        info "$(t publish443)"
    fi

    SERVER_IP=$(curl -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || echo "")
    DOMAIN_IP=$( (getent ahostsv4 "$DOMAIN" 2>/dev/null || true) | awk '{print $1}' | head -1)
    if [ -n "$DOMAIN_IP" ]; then
        if ip -4 addr show 2>/dev/null | grep -qw "$DOMAIN_IP"; then
            success "${DOMAIN} → ${DOMAIN_IP}: $(t dns_ok_local)"
        elif [ "$SERVER_IP" = "$DOMAIN_IP" ]; then
            success "${DOMAIN} → ${DOMAIN_IP}: $(t dns_ok_ext)"
        else
            warn "${DOMAIN} → ${DOMAIN_IP}: $(t dns_mismatch)"
            ip -4 addr show | awk '/inet /{print "      " $2}'
            if ! is_non_interactive; then
                question "$(t proceed)"
                [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
            fi
        fi
    else
        warn "${DOMAIN}: $(t dns_none)"
        if ! is_non_interactive; then
            question "$(t proceed)"
            [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
        fi
    fi

    create_directory "$BACKUP_DIR"
    if [ "$REINSTALL" = "yes" ]; then
        for f in Caddyfile docker-compose.yml .env; do
            [ -f "${INSTALL_DIR}/${f}" ] && cp "${INSTALL_DIR}/${f}" "${BACKUP_DIR}/${f}.${STAMP}"
        done
        info "$(t removing)"
        # без -v: флаг снёс бы caddy_data вместе с сертификатами
        if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
            (cd "$INSTALL_DIR" && docker compose down) || true
        fi
        docker rm -f selfsteal 2>/dev/null || true
        rm -f "${INSTALL_DIR}/Caddyfile" "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/.env"
        rm -rf "${INSTALL_DIR}/html"
    fi

    create_directory "${INSTALL_DIR}/html"
    cd "$INSTALL_DIR" || exit 1

    cat > .env <<EOF
DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
LOCAL_PORT=${LOCAL_PORT}
EOF

    # HTTP/3 выключен: для статики бесполезен, QUIC-буферы едят память на нодах с 1-2 ГБ
    cat > Caddyfile <<'CADDY'
{
    email {$ACME_EMAIL}
    servers {
        protocols h1 h2
    }
}

{$DOMAIN}:__LOCAL_PORT__ {
    root * /srv/decoy
    file_server
    encode zstd gzip

    header {
        -Server
        Strict-Transport-Security "max-age=31536000"
    }

    log {
        output file /data/access.log
        format json
    }
}
CADDY
    sed -i "s/__LOCAL_PORT__/${LOCAL_PORT}/" Caddyfile

    PORTS_443=""
    [ "$PUBLISH_443" = "yes" ] && PORTS_443="      - \"443:${LOCAL_PORT}\""

    cat > docker-compose.yml <<EOF
services:
  selfsteal:
    image: caddy:2-alpine
    container_name: selfsteal
    restart: unless-stopped
    # tini как PID 1 — иначе ssl_client от health-check копится зомби-процессами
    init: true
    env_file: .env
    ports:
      - "80:80"
${PORTS_443}
      - "127.0.0.1:${LOCAL_PORT}:${LOCAL_PORT}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/srv/decoy:ro
      - caddy_data:/data
      - caddy_config:/config
    extra_hosts:
      - "${DOMAIN}:127.0.0.1"
    healthcheck:
      # по домену, а не по 127.0.0.1: по голому IP wget не шлёт SNI,
      # Caddy не находит site-блок и рвёт хендшейк → вечный unhealthy
      test: ["CMD", "wget", "-qO-", "--no-check-certificate", "https://${DOMAIN}:${LOCAL_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  caddy_data:
  caddy_config:
EOF
    sed -i '/^$/d' docker-compose.yml

    cp -r /opt/remnasetup/data/site/* html/ 2>/dev/null || true
    if [ -f html/index.html ]; then
        RANDOM_META_ID=$(openssl rand -hex 16)
        RANDOM_CLASS=$(openssl rand -hex 8)
        RANDOM_COMMENT=$(openssl rand -hex 12)
        META_NAMES=("render-id" "view-id" "page-id" "config-id")
        RANDOM_META_NAME=${META_NAMES[$RANDOM % ${#META_NAMES[@]}]}
        sed -i "/<meta name=\"viewport\"/a \    <meta name=\"$RANDOM_META_NAME\" content=\"$RANDOM_META_ID\">\n    <!-- $RANDOM_COMMENT -->" html/index.html
        sed -i "s/<body/<body class=\"$RANDOM_CLASS\"/" html/index.html
        [ -f html/assets/style.css ] && sed -i "1i /* $RANDOM_COMMENT */" html/assets/style.css
        [ -f html/assets/main.js ] && sed -i "1i // $RANDOM_COMMENT" html/assets/main.js
    fi

    info "$(t starting)"
    docker compose up -d

    OK=""
    for i in $(seq 1 30); do
        if docker compose logs 2>&1 | grep -qi "certificate obtained successfully\|obtained certificate"; then OK=1; break; fi
        if docker compose logs 2>&1 | grep -qi "loading managed certificate"; then OK=2; break; fi
        sleep 2
    done
    case "$OK" in
        1) success "$(t cert_issued)" ;;
        2) success "$(t cert_reused)" ;;
        *) warn "$(t cert_unknown)" ;;
    esac

    if command_exists openssl; then
        if openssl s_client -connect "127.0.0.1:${LOCAL_PORT}" -servername "$DOMAIN" \
             -alpn h2,http/1.1 </dev/null 2>&1 | grep -q "CN *= *${DOMAIN}"; then
            success "$(t tls_ok) ${DOMAIN}"
        else
            warn "$(t tls_fail)"
        fi
    fi

    echo
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    success "$(t done_)"
    echo -e "${BOLD_CYAN}$(t for_inbound)${RESET}"
    echo -e "${BLUE}  target / dest : 127.0.0.1:${LOCAL_PORT}${RESET}"
    echo -e "${BLUE}  serverNames   : ${DOMAIN}${RESET}"
    echo
    echo -e "${BOLD_CYAN}$(t check_outside)${RESET}"
    if [ "$XRAY_PORT" = "443" ] || [ "$PUBLISH_443" = "yes" ]; then
        echo -e "${BLUE}  curl -sI --max-time 10 https://${DOMAIN}/${RESET}"
    else
        warn "$(t dead_domain)"
    fi
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"

    pause_press_key "$(get_string "install_caddy_node_press_key")"
    exit 0
}

main

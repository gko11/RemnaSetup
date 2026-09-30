#!/bin/bash

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

# --- локальные строки этой сборки (не трогаем общий languages.sh) ---
get_string_local() {
    local key="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$key" in
            delegating_selfsteal) echo "Installing selfsteal (Docker + Caddy)..." ;;
            delegating_warproxy)  echo "Installing WARP SOCKS5 proxy (Docker)..." ;;
            removing_native_warp) echo "Removing leftover native WARP (wg-quick@warp)..." ;;
            selfsteal_found)      echo "Selfsteal (Docker + Caddy) is already installed" ;;
            warp_found)           echo "WARP SOCKS5 (Docker) is already installed — the installer will ask whether to keep the account or re-register" ;;
            native_warp_found)    echo "Native WARP (wg-quick@warp) found — it will be replaced by WARP SOCKS5 (Docker)" ;;
            warp_failed)          echo "WARP was not set up — see the messages above. The rest of the installation continues." ;;
            sum_status)           echo "Status:" ;;
            sum_logs)             echo "Logs:" ;;
            sum_check)            echo "Exit check:" ;;
            sum_restart)          echo "Restart:" ;;
            sum_account)          echo "WARP account:" ;;
            sum_dont_delete)      echo "DO NOT delete!" ;;
            sum_tiktok)           echo "Xray snippet for TikTok:" ;;
            *) echo "$key" ;;
        esac
    else
        case "$key" in
            delegating_selfsteal) echo "Устанавливаю selfsteal (Docker + Caddy)..." ;;
            delegating_warproxy)  echo "Устанавливаю WARP SOCKS5 прокси (Docker)..." ;;
            removing_native_warp) echo "Удаляю остатки нативного WARP (wg-quick@warp)..." ;;
            selfsteal_found)      echo "Selfsteal (Docker + Caddy) уже установлен" ;;
            warp_found)           echo "WARP SOCKS5 (Docker) уже установлен — установщик спросит, сохранить аккаунт или перерегистрировать" ;;
            native_warp_found)    echo "Найден нативный WARP (wg-quick@warp) — он будет заменён на WARP SOCKS5 (Docker)" ;;
            warp_failed)          echo "WARP не настроен — см. сообщения выше. Остальная установка продолжается." ;;
            sum_status)           echo "Статус:" ;;
            sum_logs)             echo "Логи:" ;;
            sum_check)            echo "Проверка выхода:" ;;
            sum_restart)          echo "Перезапуск:" ;;
            sum_account)          echo "Аккаунт WARP:" ;;
            sum_dont_delete)      echo "НЕ удалять!" ;;
            sum_tiktok)           echo "Сниппет Xray для TikTok:" ;;
            *) echo "$key" ;;
        esac
    fi
}

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

selfsteal_installed() {
    [ -f /opt/selfsteal/docker-compose.yml ] || \
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx selfsteal
}

warproxy_installed() {
    [ -f /opt/warproxy/docker-compose.yml ] || [ -s /opt/warproxy/config/wgcf-account.toml ] || \
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx warproxy
}

native_warp_installed() {
    [ -f /etc/wireguard/warp.conf ] || \
        systemctl is-enabled wg-quick@warp >/dev/null 2>&1 || \
        systemctl is-active wg-quick@warp >/dev/null 2>&1
}

stop_caddy_if_running() {
    # системный Caddy (старые версии скрипта)
    if command -v caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy 2>/dev/null; then
        warn "$(get_string "install_nginx_node_caddy_detected")"
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy 2>/dev/null || true
        success "$(get_string "install_nginx_node_caddy_stopped")"
    fi
    # Docker-selfsteal этой сборки: останавливаем без down -v, сертификаты в volume остаются
    if [ -f /opt/selfsteal/docker-compose.yml ] || docker ps --format '{{.Names}}' 2>/dev/null | grep -qx selfsteal; then
        warn "$(get_string "install_nginx_node_caddy_detected")"
        if [ -f /opt/selfsteal/docker-compose.yml ]; then
            (cd /opt/selfsteal && docker compose stop) >/dev/null 2>&1 || true
            (cd /opt/selfsteal && docker compose rm -f) >/dev/null 2>&1 || true
        fi
        docker rm -f selfsteal >/dev/null 2>&1 || true
        success "$(get_string "install_nginx_node_caddy_stopped")"
    fi
}

install_docker() {
    info "$(get_string "install_full_node_installing_docker")"
    curl -fsSL https://get.docker.com | sh || {
        error "$(get_string "install_full_node_docker_error")"
        exit 1
    }
    success "$(get_string "install_full_node_docker_installed_success")"
}

check_components() {
    if command -v docker >/dev/null 2>&1; then
        info "$(get_string "install_full_node_docker_installed")"
    else
        info "$(get_string "install_full_node_docker_not_installed")"
    fi

    if [ -f "/opt/remnanode/docker-compose.yml" ]; then
        info "$(get_string "install_full_node_remnanode_installed")"
        if [[ "$SKIP_REMNANODE" == "true" ]]; then
            info "SKIP_REMNANODE=true, skipping..."
        elif [[ "$UPDATE_REMNANODE" == "true" ]]; then
            info "UPDATE_REMNANODE=true, will update..."
        else
            while true; do
                question "$(get_string "install_full_node_update_remnanode")"
                UPDATE_NODE="$REPLY"
                if [[ "$UPDATE_NODE" == "y" || "$UPDATE_NODE" == "Y" ]]; then
                    UPDATE_REMNANODE=true
                    break
                elif [[ "$UPDATE_NODE" == "n" || "$UPDATE_NODE" == "N" ]]; then
                    SKIP_REMNANODE=true
                    break
                else
                    warn "$(get_string "install_full_node_please_enter_yn")"
                fi
            done
        fi
    fi

    if selfsteal_installed || command -v caddy >/dev/null 2>&1; then
        if selfsteal_installed; then
            info "$(get_string_local "selfsteal_found")"
        else
            info "$(get_string "install_full_node_caddy_installed")"
        fi
        DETECTED_WEBSERVER="caddy"
        if [[ "$SKIP_WEBSERVER" == "true" ]]; then
            info "SKIP_WEBSERVER=true, skipping..."
        elif [[ -n "$WEBSERVER" ]]; then
            if [[ "$WEBSERVER" == "caddy" ]]; then
                UPDATE_CADDY=true
                info "WEBSERVER=caddy, will update..."
            fi
        elif [[ "$UPDATE_CADDY" == "true" ]]; then
            info "UPDATE_CADDY=true, will update..."
        else
            while true; do
                question "$(get_string "install_full_node_update_caddy")"
                UPDATE_CADDY="$REPLY"
                if [[ "$UPDATE_CADDY" == "y" || "$UPDATE_CADDY" == "Y" ]]; then
                    UPDATE_CADDY=true
                    break
                elif [[ "$UPDATE_CADDY" == "n" || "$UPDATE_CADDY" == "N" ]]; then
                    SKIP_CADDY=true
                    break
                else
                    warn "$(get_string "install_full_node_please_enter_yn")"
                fi
            done
        fi
    fi

    if command -v nginx >/dev/null 2>&1; then
        info "$(get_string "install_full_node_nginx_installed")"
        if [[ -z "$DETECTED_WEBSERVER" ]]; then
            DETECTED_WEBSERVER="nginx"
        fi
        if [[ "$SKIP_WEBSERVER" == "true" ]]; then
            info "SKIP_WEBSERVER=true, skipping..."
        elif [[ -n "$WEBSERVER" ]]; then
            if [[ "$WEBSERVER" == "nginx" ]]; then
                UPDATE_NGINX=true
                info "WEBSERVER=nginx, will update..."
            fi
        elif [[ "$UPDATE_NGINX" == "true" ]]; then
            info "UPDATE_NGINX=true, will update..."
        else
            while true; do
                question "$(get_string "install_full_node_update_nginx")"
                UPDATE_NGINX="$REPLY"
                if [[ "$UPDATE_NGINX" == "y" || "$UPDATE_NGINX" == "Y" ]]; then
                    UPDATE_NGINX=true
                    break
                elif [[ "$UPDATE_NGINX" == "n" || "$UPDATE_NGINX" == "N" ]]; then
                    SKIP_NGINX=true
                    break
                else
                    warn "$(get_string "install_full_node_please_enter_yn")"
                fi
            done
        fi
    fi

    # WARP: режим (сохранить аккаунт / перерегистрировать) спрашивает сам install-warp.sh
    if native_warp_installed; then
        info "$(get_string_local "native_warp_found")"
    fi
    if warproxy_installed; then
        info "$(get_string_local "warp_found")"
    fi
    if [[ -z "$SKIP_WARP" ]]; then
        SKIP_WARP=false
    fi

    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        info "$(get_string "install_full_node_bbr_configured")"
        SKIP_BBR=true
    fi
}

request_data() {
    if [[ "$SKIP_WEBSERVER" != "true" ]]; then
        if [[ -n "$DOMAIN" ]]; then
            info "DOMAIN=$DOMAIN"
        else
            while true; do
                question "$(get_string "install_full_node_enter_domain")"
                DOMAIN="$REPLY"
                if [[ "$DOMAIN" == "n" || "$DOMAIN" == "N" ]]; then
                    SKIP_WEBSERVER=true
                    break
                elif [[ -n "$DOMAIN" ]]; then
                    break
                fi
                warn "$(get_string "install_full_node_domain_empty")"
            done
        fi
    fi

    if [[ "$SKIP_WEBSERVER" != "true" ]]; then
        if [[ -n "$MONITOR_PORT" ]]; then
            info "MONITOR_PORT=$MONITOR_PORT"
        else
            while true; do
                question "$(get_string "install_full_node_enter_port")"
                MONITOR_PORT="$REPLY"
                MONITOR_PORT=${MONITOR_PORT:-8443}
                if [[ "$MONITOR_PORT" =~ ^[0-9]+$ ]]; then
                    break
                fi
                warn "$(get_string "install_full_node_port_must_be_number")"
            done
        fi

        if [[ -n "$WEBSERVER" ]]; then
            info "WEBSERVER=$WEBSERVER"
        else
            echo ""
            info "$(get_string "install_full_node_webserver_choice")"
            echo -e "${BLUE}1. $(get_string "install_full_node_webserver_caddy")${RESET}"
            echo -e "${BLUE}2. $(get_string "install_full_node_webserver_nginx")${RESET}"
            echo ""
            while true; do
                question "$(get_string "install_full_node_webserver_choose")"
                WEBSERVER_CHOICE="$REPLY"
                if [[ "$WEBSERVER_CHOICE" == "1" ]]; then
                    WEBSERVER="caddy"
                    break
                elif [[ "$WEBSERVER_CHOICE" == "2" ]]; then
                    WEBSERVER="nginx"
                    break
                fi
                warn "$(get_string "install_full_node_webserver_invalid")"
            done
        fi

        if [[ "$WEBSERVER" == "nginx" ]]; then
            if [[ -n "$USE_PROXY_PROTOCOL" ]]; then
                info "USE_PROXY_PROTOCOL=$USE_PROXY_PROTOCOL"
            else
                while true; do
                    question "$(get_string "install_nginx_node_use_proxy_protocol")"
                    USE_PROXY_PROTOCOL="$REPLY"
                    if [[ "$USE_PROXY_PROTOCOL" == "y" || "$USE_PROXY_PROTOCOL" == "Y" || "$USE_PROXY_PROTOCOL" == "n" || "$USE_PROXY_PROTOCOL" == "N" ]]; then
                        break
                    fi
                    warn "$(get_string "install_full_node_please_enter_yn")"
                done
            fi

            if [[ -n "$CERT_METHOD" ]]; then
                info "CERT_METHOD=$CERT_METHOD"
            else
                echo ""
                info "$(get_string "install_nginx_node_cert_method_prompt")"
                echo -e "${BLUE}1. Cloudflare DNS-01 (wildcard)${RESET}"
                echo -e "${BLUE}2. HTTP-01 / standalone${RESET}"
                echo -e "${BLUE}3. Gcore DNS-01 (wildcard)${RESET}"
                echo ""
                while true; do
                    question "$(get_string "install_nginx_node_cert_method_choose")"
                    CERT_METHOD="$REPLY"
                    if [[ "$CERT_METHOD" =~ ^[1-3]$ ]]; then
                        break
                    fi
                    warn "$(get_string "install_nginx_node_cert_method_invalid")"
                done
            fi
        fi
    fi

    if [[ "$SKIP_REMNANODE" != "true" ]]; then
        if [[ -n "$NODE_PORT" ]]; then
            info "NODE_PORT=$NODE_PORT"
        else
            while true; do
                question "$(get_string "install_full_node_enter_app_port")"
                NODE_PORT="$REPLY"
                if [[ "$NODE_PORT" == "n" || "$NODE_PORT" == "N" ]]; then
                    while true; do
                        question "$(get_string "install_full_node_confirm_skip_remnanode")"
                        CONFIRM="$REPLY"
                        if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                            SKIP_REMNANODE=true
                            break
                        elif [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
                            break
                        else
                            warn "$(get_string "install_full_node_please_enter_yn")"
                        fi
                    done
                    if [[ "$SKIP_REMNANODE" == "true" ]]; then
                        break
                    fi
                fi
                NODE_PORT=${NODE_PORT:-3001}
                if [[ "$NODE_PORT" =~ ^[0-9]+$ ]]; then
                    break
                fi
                warn "$(get_string "install_full_node_port_must_be_number")"
            done
        fi

        if [[ "$SKIP_REMNANODE" != "true" ]]; then
            if [[ -n "$SECRET_KEY" ]]; then
                info "SECRET_KEY=***"
            else
                while true; do
                    question "$(get_string "install_full_node_enter_ssl_cert")"
                    SECRET_KEY="$REPLY"
                    if [[ "$SECRET_KEY" == "n" || "$SECRET_KEY" == "N" ]]; then
                        while true; do
                            question "$(get_string "install_full_node_confirm_skip_remnanode")"
                            CONFIRM="$REPLY"
                            if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                                SKIP_REMNANODE=true
                                break
                            elif [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
                                break
                            else
                                warn "$(get_string "install_full_node_please_enter_yn")"
                            fi
                        done
                        if [[ "$SKIP_REMNANODE" == "true" ]]; then
                            break
                        fi
                    elif [[ -n "$SECRET_KEY" ]]; then
                        break
                    fi
                    warn "$(get_string "install_full_node_ssl_cert_empty")"
                done
            fi
        fi
    fi

    if [[ "$SKIP_WARP" != "true" ]]; then
        if [[ "$INSTALL_WARP" == "y" || "$INSTALL_WARP" == "Y" ]]; then
            info "INSTALL_WARP=$INSTALL_WARP"
        elif [[ "$INSTALL_WARP" == "n" || "$INSTALL_WARP" == "N" ]]; then
            SKIP_WARP=true
            info "INSTALL_WARP=$INSTALL_WARP, skipping..."
        else
            while true; do
                question "$(get_string "install_full_node_install_warp_native")"
                INSTALL_WARP="$REPLY"
                if [[ "$INSTALL_WARP" == "n" || "$INSTALL_WARP" == "N" ]]; then
                    while true; do
                        question "$(get_string "install_full_node_confirm_skip_warp")"
                        CONFIRM="$REPLY"
                        if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
                            SKIP_WARP=true
                            break
                        elif [[ "$CONFIRM" == "n" || "$CONFIRM" == "N" ]]; then
                            break
                        else
                            warn "$(get_string "install_full_node_please_enter_yn")"
                        fi
                    done
                    if [[ "$SKIP_WARP" == "true" ]]; then
                        break
                    fi
                elif [[ "$INSTALL_WARP" == "y" || "$INSTALL_WARP" == "Y" ]]; then
                    break
                else
                    warn "$(get_string "install_full_node_please_enter_yn")"
                fi
            done
        fi
    fi

    if [[ "$SKIP_BBR" != "true" ]]; then
        if [[ "$BBR_ANSWER" == "y" || "$BBR_ANSWER" == "Y" ]]; then
            SKIP_BBR=false
            info "BBR_ANSWER=$BBR_ANSWER"
        elif [[ "$BBR_ANSWER" == "n" || "$BBR_ANSWER" == "N" ]]; then
            SKIP_BBR=true
            info "BBR_ANSWER=$BBR_ANSWER, skipping..."
        else
            while true; do
                question "$(get_string "install_full_node_need_bbr")"
                BBR_ANSWER="$REPLY"
                if [[ "$BBR_ANSWER" == "n" || "$BBR_ANSWER" == "N" ]]; then
                    SKIP_BBR=true
                    break
                elif [[ "$BBR_ANSWER" == "y" || "$BBR_ANSWER" == "Y" ]]; then
                    SKIP_BBR=false
                    break
                else
                    warn "$(get_string "install_full_node_please_enter_yn")"
                fi
            done
        fi
    fi
}

RESTORE_DNS_REQUIRED=false

restore_dns() {
    if [[ "$RESTORE_DNS_REQUIRED" == true && -f /etc/resolv.conf.backup ]]; then
        cp /etc/resolv.conf.backup /etc/resolv.conf
        success "$(get_string "warp_native_dns_restored")"
        RESTORE_DNS_REQUIRED=false
    fi
}

uninstall_warp_native() {
    # Нативный WARP (wgcf + wg-quick@warp) в этой сборке не ставится.
    # Если он остался от прежней установки — аккуратно убираем, чтобы не
    # конфликтовал с контейнерным WARP по маршрутам и DNS.
    # (проверка через list-unit-files не работала: там виден только шаблон wg-quick@.service)
    if native_warp_installed; then
        warn "$(get_string_local "removing_native_warp")"
        systemctl stop wg-quick@warp 2>/dev/null || true
        systemctl disable wg-quick@warp 2>/dev/null || true
        [ -f /etc/wireguard/warp.conf ] && mv -f /etc/wireguard/warp.conf "/etc/wireguard/warp.conf.bak.$(date +%s)"
        # watchdog от WARP-NATIVE иначе поднимет интерфейс обратно
        rm -f /etc/cron.d/warp-native
        rm -rf /opt/warp-native
    fi
}

install_warp() {
    # WARP-NATIVE вырезан. Вместо него — WARP через Docker-контейнер с SOCKS5,
    # который Xray использует как outbound (socks 172.17.0.1:1080).
    # Не форсируем NON_INTERACTIVE и адрес/порт: при повторной установке скрипт
    # сам возьмёт прежние значения из compose и спросит режим (keep/reregister).
    # Без терминала режим всегда keep — автоматика не перерегистрирует аккаунт.
    info "$(get_string_local "delegating_warproxy")"
    BIND_ADDR="${WARP_BIND_ADDR:-}" \
    SOCKS_PORT="${WARP_SOCKS_PORT:-}" \
    TZ_VAL="${TZ_VAL:-Europe/Moscow}" \
    NON_INTERACTIVE="${NON_INTERACTIVE:-}" \
    WARP_MODE="${WARP_MODE:-}" \
    WARP_ACCOUNT_FILE="${WARP_ACCOUNT_FILE:-}" \
    WARP_ENDPOINT="${WARP_ENDPOINT:-}" \
    SKIP_PAUSE=true \
    bash /opt/remnasetup/scripts/remnanode/install-warp.sh
    WARP_RESULT=$?
    if [ "$WARP_RESULT" -ne 0 ]; then
        warn "$(get_string_local "warp_failed")"
    fi
}

install_bbr() {
    info "$(get_string "install_full_node_installing_bbr")"
    modprobe tcp_bbr
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
    sysctl -p
    success "$(get_string "install_full_node_bbr_installed_success")"
}

setup_logs_and_logrotate() {
    info "$(get_string "install_full_node_setup_logs")"

    if [ ! -d "/var/log/remnanode" ]; then
        mkdir -p /var/log/remnanode
        info "$(get_string "install_full_node_logs_dir_created")"
    else
        info "$(get_string "install_full_node_logs_dir_exists")"
    fi

    if ! command -v logrotate >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y logrotate
    fi

    if [ ! -f "/etc/logrotate.d/remnanode" ] || ! grep -q "copytruncate" /etc/logrotate.d/remnanode; then
        tee /etc/logrotate.d/remnanode > /dev/null <<EOF
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        success "$(get_string "install_full_node_logs_configured")"
    else
        info "$(get_string "install_full_node_logs_already_configured")"
    fi
}

install_caddy() {
    # Делегируем установку отдельному скрипту: selfsteal живёт в Docker,
    # а не системным пакетом. Переменные прокидываются окружением.
    info "$(get_string_local "delegating_selfsteal")"
    DOMAIN="$DOMAIN" \
    LOCAL_PORT="${MONITOR_PORT:-8443}" \
    XRAY_PORT="${XRAY_PORT:-443}" \
    SITE_NAME="${SITE_NAME:-Northwind Systems}" \
    NON_INTERACTIVE="${NON_INTERACTIVE:-true}" \
    REINSTALL_CONFIRM="${UPDATE_CADDY:-yes}" \
    bash /opt/remnasetup/scripts/remnanode/install-caddy.sh
}

install_nginx_selfsteal() {
    info "$(get_string "install_full_node_installing_nginx")"

    stop_caddy_if_running

    apt-get install -y nginx certbot

    info "$(get_string "install_full_node_setup_site")"

    if [ -d "/var/www/site" ]; then
        rm -rf /var/www/site/*
    else
        mkdir -p /var/www/site
    fi
    mkdir -p /var/www/html

    RANDOM_META_ID=$(openssl rand -hex 16)
    RANDOM_CLASS=$(openssl rand -hex 8)
    RANDOM_COMMENT=$(openssl rand -hex 12)

    META_NAMES=("render-id" "view-id" "page-id" "config-id")
    RANDOM_META_NAME=${META_NAMES[$RANDOM % ${#META_NAMES[@]}]}

    cp -r "/opt/remnasetup/data/site/"* /var/www/site/

    sed -i "/<meta name=\"viewport\"/a \    <meta name=\"$RANDOM_META_NAME\" content=\"$RANDOM_META_ID\">\n    <!-- $RANDOM_COMMENT -->" /var/www/site/index.html
    sed -i "s/<body/<body class=\"$RANDOM_CLASS\"/" /var/www/site/index.html

    sed -i "1i /* $RANDOM_COMMENT */" /var/www/site/assets/style.css
    sed -i "1i // $RANDOM_COMMENT" /var/www/site/assets/main.js

    local base_domain
    base_domain=$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')
    local wildcard_domain="*.$base_domain"

    case $CERT_METHOD in
        1)
            if [[ -n "$CF_API_KEY" ]]; then
                info "CF_API_KEY=***"
            else
                while true; do
                    question "$(get_string "install_nginx_node_enter_cf_token")"
                    CF_API_KEY="$REPLY"
                    if [[ -n "$CF_API_KEY" ]]; then break; fi
                    warn "$(get_string "install_nginx_node_token_empty")"
                done
            fi
            if [[ -n "$CF_EMAIL" ]]; then
                info "CF_EMAIL=$CF_EMAIL"
            else
                while true; do
                    question "$(get_string "install_nginx_node_enter_cf_email")"
                    CF_EMAIL="$REPLY"
                    if [[ -n "$CF_EMAIL" ]]; then break; fi
                    warn "$(get_string "install_nginx_node_email_empty")"
                done
            fi

            apt-get install -y python3-certbot-dns-cloudflare

            mkdir -p ~/.secrets/certbot
            if [[ $CF_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CF_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CF_EMAIL
dns_cloudflare_api_key = $CF_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$CF_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 || {
                error "$(get_string "install_nginx_node_cert_failed")"
                exit 1
            }
            CERT_DOMAIN="$base_domain"
            ;;
        2)
            if [[ -n "$LE_EMAIL" ]]; then
                info "LE_EMAIL=$LE_EMAIL"
            else
                while true; do
                    question "$(get_string "install_nginx_node_enter_email")"
                    LE_EMAIL="$REPLY"
                    if [[ -n "$LE_EMAIL" ]]; then break; fi
                    warn "$(get_string "install_nginx_node_email_empty")"
                done
            fi

            systemctl stop nginx 2>/dev/null || true

            certbot certonly \
                --standalone \
                -d "$DOMAIN" \
                --email "$LE_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 || {
                error "$(get_string "install_nginx_node_cert_failed")"
                exit 1
            }
            CERT_DOMAIN="$DOMAIN"
            ;;
        3)
            if [[ -n "$GCORE_API_KEY" ]]; then
                info "GCORE_API_KEY=***"
            else
                while true; do
                    question "$(get_string "install_nginx_node_enter_gcore_token")"
                    GCORE_API_KEY="$REPLY"
                    if [[ -n "$GCORE_API_KEY" ]]; then break; fi
                    warn "$(get_string "install_nginx_node_token_empty")"
                done
            fi
            if [[ -n "$LE_EMAIL" ]]; then
                info "LE_EMAIL=$LE_EMAIL"
            else
                while true; do
                    question "$(get_string "install_nginx_node_enter_email")"
                    LE_EMAIL="$REPLY"
                    if [[ -n "$LE_EMAIL" ]]; then break; fi
                    warn "$(get_string "install_nginx_node_email_empty")"
                done
            fi

            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                info "$(get_string "install_nginx_node_installing_gcore_plugin")"
                apt-get install -y python3-pip >/dev/null 2>&1
                if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
                    python3 -m pip install --break-system-packages certbot-dns-gcore
                else
                    python3 -m pip install certbot-dns-gcore
                fi

                if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                    error "$(get_string "install_nginx_node_gcore_plugin_failed")"
                    exit 1
                fi
                success "$(get_string "install_nginx_node_gcore_plugin_installed")"
            else
                info "$(get_string "install_nginx_node_gcore_plugin_exists")"
            fi

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$LE_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 || {
                error "$(get_string "install_nginx_node_cert_failed")"
                exit 1
            }
            CERT_DOMAIN="$base_domain"
            ;;
    esac

    success "$(get_string "install_nginx_node_cert_obtained")"

    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        local cron_command
        if [ "$CERT_METHOD" == "2" ]; then
            cron_command="systemctl stop nginx && /usr/bin/certbot renew --quiet && systemctl start nginx"
        else
            cron_command="/usr/bin/certbot renew --quiet && systemctl reload nginx"
        fi
        (crontab -u root -l 2>/dev/null; echo "0 5 * * 0 $cron_command") | crontab -u root -
    fi

    cp "/opt/remnasetup/data/nginx/nginx-node.conf" /etc/nginx/nginx.conf

    rm -f /etc/nginx/conf.d/default.conf
    rm -f /etc/nginx/sites-enabled/default

    if [[ "$USE_PROXY_PROTOCOL" == "y" || "$USE_PROXY_PROTOCOL" == "Y" ]]; then
        cp "/opt/remnasetup/data/nginx/selfsteal-proxy-protocol.conf" /etc/nginx/conf.d/selfsteal.conf
    else
        cp "/opt/remnasetup/data/nginx/selfsteal.conf" /etc/nginx/conf.d/selfsteal.conf
    fi

    sed -i "s|\$DOMAIN|$DOMAIN|g" /etc/nginx/conf.d/selfsteal.conf
    sed -i "s|\$MONITOR_PORT|$MONITOR_PORT|g" /etc/nginx/conf.d/selfsteal.conf

    if [[ -n "$CERT_DOMAIN" && "$CERT_DOMAIN" != "$DOMAIN" ]]; then
        sed -i "s|/etc/letsencrypt/live/$DOMAIN|/etc/letsencrypt/live/$CERT_DOMAIN|g" /etc/nginx/conf.d/selfsteal.conf
    fi

    nginx -t || {
        error "$(get_string "install_nginx_node_config_test_failed")"
        exit 1
    }

    systemctl restart nginx
    systemctl enable nginx
    success "$(get_string "install_full_node_nginx_installed_success")"
}

install_remnanode() {
    info "$(get_string "install_full_node_installing_remnanode")"
    mkdir -p /opt/remnanode

    if [ -n "$SUDO_USER" ]; then
        REAL_USER="$SUDO_USER"
    elif [ -n "$USER" ] && [ "$USER" != "root" ]; then
        REAL_USER="$USER"
    else
        REAL_USER=$(getent passwd 2>/dev/null | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "nobody" {print $1; exit}')
        if [ -z "$REAL_USER" ]; then
            REAL_USER="root"
        fi
    fi
    
    chown "$REAL_USER:$REAL_USER" /opt/remnanode
    cd /opt/remnanode || exit 1

    info "$(get_string "install_full_node_using_standard_compose")"
    cp "/opt/remnasetup/data/docker/node-compose.yml" docker-compose.yml

    sed -i "s|\$NODE_PORT|$NODE_PORT|g" docker-compose.yml
    sed -i "s|\$SECRET_KEY|$SECRET_KEY|g" docker-compose.yml

    # Половина RAM хоста, но не меньше 512 МБ и не больше 4 ГБ.
    info "$(get_string "mem_limits_header" "$(host_ram_mb)")"
    set_container_limits docker-compose.yml NODE 50 512 4096

    docker compose up -d || {
        error "$(get_string "install_full_node_remnanode_error")"
        exit 1
    }
    success "$(get_string "install_full_node_remnanode_installed_success")"
}

main() {
    trap restore_dns EXIT
    
    info "$(get_string "install_full_node_start")"

    check_components
    request_data

    info "$(get_string "install_full_node_updating_packages")"
    while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        warn "apt is locked by another process, waiting..."
        sleep 3
    done
    apt-get update -y

    if ! check_docker; then
        install_docker
    fi

    if [[ "$SKIP_WARP" != "true" ]]; then
        if native_warp_installed; then
            uninstall_warp_native
            echo ""
        fi
        install_warp
    fi
    
    if [[ "$SKIP_BBR" != "true" ]]; then
        install_bbr
    fi
    
    if [[ "$SKIP_WEBSERVER" != "true" ]]; then
        if [[ "$WEBSERVER" == "caddy" && "$SKIP_CADDY" != "true" ]]; then
            # системный Caddy от старых версий держал бы те же порты, что и Docker-Caddy
            if systemctl list-unit-files caddy.service >/dev/null 2>&1 && systemctl is-active --quiet caddy 2>/dev/null; then
                systemctl stop caddy 2>/dev/null || true
                systemctl disable caddy 2>/dev/null || true
            fi
            # nginx-selfsteal на тех же портах мешал бы контейнеру
            if systemctl is-active --quiet nginx 2>/dev/null && [ -f /etc/nginx/conf.d/selfsteal.conf ]; then
                systemctl stop nginx 2>/dev/null || true
                systemctl disable nginx 2>/dev/null || true
            fi
            install_caddy
        elif [[ "$WEBSERVER" == "nginx" && "$SKIP_NGINX" != "true" ]]; then
            if [[ "$UPDATE_NGINX" == "true" ]]; then
                systemctl stop nginx 2>/dev/null || true
                rm -f /etc/nginx/conf.d/selfsteal.conf
            fi
            install_nginx_selfsteal
        fi
    fi

    setup_logs_and_logrotate
    
    if [[ "$SKIP_REMNANODE" != "true" ]]; then
        if [[ "$UPDATE_REMNANODE" == "true" ]]; then
            cd /opt/remnanode || exit 1
            docker compose down
            rm -f docker-compose.yml
            rm -f .env
        fi
        install_remnanode
    fi
    
    success "$(get_string "install_full_node_complete")"

    if [[ "$WEBSERVER" == "nginx" && "$SKIP_WEBSERVER" != "true" ]]; then
        echo ""
        if [[ "$USE_PROXY_PROTOCOL" == "y" || "$USE_PROXY_PROTOCOL" == "Y" ]]; then
            echo -e "${BOLD_CYAN}Xray Reality config:${RESET}"
            echo -e "${BLUE}  \"target\": \"127.0.0.1:$MONITOR_PORT\",${RESET}"
            echo -e "${BLUE}  \"xver\": 1${RESET}"
        else
            echo -e "${BOLD_CYAN}Xray Reality config:${RESET}"
            echo -e "${BLUE}  \"target\": \"127.0.0.1:$MONITOR_PORT\",${RESET}"
            echo -e "${BLUE}  \"xver\": 0${RESET}"
        fi
    fi

    if [[ "$SKIP_WARP" != "true" && -f /opt/warproxy/docker-compose.yml ]]; then
        local warp_line warp_addr warp_port
        warp_line=$(grep -oE '"[0-9.]+:[0-9]+:1080"' /opt/warproxy/docker-compose.yml 2>/dev/null | head -1 | tr -d '"')
        warp_addr="${warp_line%%:*}"
        warp_port=$(echo "$warp_line" | cut -d: -f2)
        [ "$warp_addr" = "0.0.0.0" ] && warp_addr="127.0.0.1"
        echo ""
        echo -e "${BOLD_CYAN}➤ $(get_string_local "sum_status")${RESET}  docker ps --filter name=warproxy"
        echo -e "${BOLD_CYAN}➤ $(get_string_local "sum_logs")${RESET}  docker logs warproxy --tail 60"
        echo -e "${BOLD_CYAN}➤ $(get_string_local "sum_check")${RESET}  curl -s -x socks5h://${warp_addr:-172.17.0.1}:${warp_port:-1080} https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp)='"
        echo -e "${BOLD_CYAN}➤ $(get_string_local "sum_restart")${RESET}  cd /opt/warproxy && docker compose restart"
        echo -e "${BOLD_CYAN}➤ $(get_string_local "sum_tiktok")${RESET}  /opt/warproxy/xray-warp-tiktok.json"
        echo -e "${BOLD_YELLOW}➤ $(get_string_local "sum_account")${RESET}  /opt/warproxy/config/wgcf-account.toml — $(get_string_local "sum_dont_delete")"
        echo ""
    fi

    pause_press_key "$(get_string "install_full_node_press_key")"
    exit 0
}

main

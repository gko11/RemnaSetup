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
            ask_maint)            echo "Set up the maintenance schedule (update day + reboot)? [Y/n]:" ;;
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
            ask_maint)            echo "Настроить расписание обслуживания (день обновления + перезагрузка)? [Y/n]:" ;;
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

        # selfsteal в этой сборке — только Docker + Caddy
        WEBSERVER="caddy"
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
    # sysctl.d вместо дописывания в sysctl.conf: повторный запуск не плодит дубли
    info "$(get_string "install_full_node_installing_bbr")"
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr > /etc/modules-load.d/bbr.conf
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/60-bbr.conf
    sysctl -q -p /etc/sysctl.d/60-bbr.conf
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
    install -d -m 700 /opt/remnanode/hy2-certs

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

    # Расписание обслуживания: обновление ноды по своему дню + плановая перезагрузка
    if [[ "$SKIP_REMNANODE" != "true" ]]; then
        if [[ -n "$UPDATE_DAY" || -n "$REBOOT_MODE" ]] || ! is_non_interactive; then
            local ans="${SETUP_MAINTENANCE:-}"
            if [[ -z "$ans" ]]; then
                if is_non_interactive; then ans=y; else question "$(get_string_local "ask_maint")"; ans="${REPLY:-y}"; fi
            fi
            [[ "$ans" =~ ^[Yy] ]] && bash /opt/remnasetup/scripts/remnanode/maintenance.sh
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

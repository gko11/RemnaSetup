#!/bin/bash
#
# Hysteria2: подготовка ноды — сертификат, проброс в контейнер, автообновление, UDP 443.
#
# Новый сертификат НЕ выпускается, если Caddy (selfsteal) уже держит действующий
# для этого домена. Если нет — Caddy выпустит его сам (добавляется site-блок,
# HTTP-01 через порт 80, который selfsteal уже публикует).
#
# Шаги:
#   1. найти сертификат домена (Docker-том caddy_data, системный Caddy, certbot);
#   2. если не найден и есть selfsteal — попросить Caddy выпустить;
#   3. скопировать в /opt/remnanode/hy2-certs (fullchain.pem, privkey.pem);
#   4. добавить в docker-compose ноды том /opt/remnanode/hy2-certs:/hy2-certs:ro;
#   5. таймер ежедневной синхронизации (Caddy продлевает — копия обновляется,
#      Xray перечитывает файл сам раз в час, перезапуск не нужен);
#   6. открыть 443/udp в ufw;
#   7. напечатать, что вписать в профиль и хост в панели.
#
# Неинтерактивно: HY2_DOMAIN, HY2_ISSUE=y|n, HY2_RECREATE=y|n, HY2_UFW=y|n

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

BIN_SRC=/opt/remnasetup/scripts/remnanode/bin
NODE_DIR=/opt/remnanode
DST=${NODE_DIR}/hy2-certs
MOUNT_LINE="      - ${DST}:/hy2-certs:ro"
SELFSTEAL=/opt/selfsteal
STAMP=$(date +%Y%m%d-%H%M%S)

t() {
    local k="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$k" in
            hdr)        echo "Hysteria2 — certificate and node preparation" ;;
            no_node)    echo "Remnanode is not installed (/opt/remnanode/docker-compose.yml)" ;;
            ask_domain) echo "Node domain for Hysteria2 (address/SNI of the host in the panel)" ;;
            found)      echo "Certificate found:" ;;
            not_found)  echo "No valid certificate found for" ;;
            can_issue)  echo "Caddy (selfsteal) can obtain it now. Needs: A record of the domain → this server, port 80 open." ;;
            ask_issue)  echo "Ask Caddy to obtain the certificate? [Y/n]:" ;;
            dns_bad)    echo "The domain does not point to this server — Let's Encrypt will refuse:" ;;
            issuing)    echo "Adding the domain to Caddy and waiting for the certificate (up to 2 min)..." ;;
            issued)     echo "Caddy obtained the certificate." ;;
            issue_fail) echo "Caddy did not obtain the certificate. Logs: docker logs selfsteal --tail 50. Caddyfile restored." ;;
            no_caddy)   echo "Selfsteal (Caddy) is not installed — install it first (menu: Selfsteal) or put fullchain.pem/privkey.pem into" ;;
            same_dom)   echo "This is the selfsteal domain itself, yet Caddy has no valid certificate. Check: docker logs selfsteal --tail 50" ;;
            copied)     echo "Copy is in" ;;
            mount_ok)   echo "Node container already mounts /hy2-certs" ;;
            mount_add)  echo "Adding volume to /opt/remnanode/docker-compose.yml:" ;;
            mount_bad)  echo "docker-compose.yml became invalid — restored from backup" ;;
            recreate)   echo "The node container must be recreated to see the folder: users reconnect in ~5 s. Do it now? [Y/n]:" ;;
            later)      echo "Postponed. Run later: cd /opt/remnanode && docker compose up -d" ;;
            visible)    echo "Container sees /hy2-certs/fullchain.pem" ;;
            invisible)  echo "Container does NOT see /hy2-certs — do not enable the HY2 inbound on this node yet" ;;
            timer)      echo "Daily certificate sync: 04:17 Moscow" ;;
            ufw_ask)    echo "Open 443/udp in ufw? [Y/n]:" ;;
            ufw_ok)     echo "443/udp is open in ufw" ;;
            udp_busy)   echo "UDP 443 is already used by another process — Hysteria2 will not start:" ;;
            hoster_fw)  echo "If the hoster has its own firewall (panel), open UDP 443 there too." ;;
            ready)      echo "READY — the HY2 inbound can be enabled on this node." ;;
            panel)      echo "In the panel:" ;;
            p_inb)      echo "Profile → hysteria inbound, tlsSettings.certificates:" ;;
            p_node)     echo "Nodes → this node: tick the HY2 inbound (on nodes without a certificate — keep it unticked)" ;;
            p_host)     echo "Hosts → new: inbound HY2-*, address/SNI" ;;
            p_host2)    echo "port 443, ALPN h3, hidden, same squads as the main host of the country" ;;
            *) echo "$k" ;;
        esac
    else
        case "$k" in
            hdr)        echo "Hysteria2 — сертификат и подготовка ноды" ;;
            no_node)    echo "Remnanode не установлен (/opt/remnanode/docker-compose.yml)" ;;
            ask_domain) echo "Домен ноды для Hysteria2 (адрес/SNI хоста в панели)" ;;
            found)      echo "Найден сертификат:" ;;
            not_found)  echo "Не найден действующий сертификат для" ;;
            can_issue)  echo "Caddy (selfsteal) может получить его сейчас. Нужно: A-запись домена → этот сервер, открыт порт 80." ;;
            ask_issue)  echo "Попросить Caddy получить сертификат? [Y/n]:" ;;
            dns_bad)    echo "Домен указывает не на этот сервер — Let's Encrypt откажет:" ;;
            issuing)    echo "Добавляю домен в Caddy и жду сертификат (до 2 минут)..." ;;
            issued)     echo "Caddy получил сертификат." ;;
            issue_fail) echo "Caddy не получил сертификат. Логи: docker logs selfsteal --tail 50. Caddyfile возвращён как был." ;;
            no_caddy)   echo "Selfsteal (Caddy) не установлен — поставьте его (меню: Selfsteal) или положите fullchain.pem/privkey.pem в" ;;
            same_dom)   echo "Это домен самого selfsteal, но действующего сертификата у Caddy нет. Смотрите: docker logs selfsteal --tail 50" ;;
            copied)     echo "Копия лежит в" ;;
            mount_ok)   echo "Контейнер ноды уже видит /hy2-certs" ;;
            mount_add)  echo "Добавляю том в /opt/remnanode/docker-compose.yml:" ;;
            mount_bad)  echo "docker-compose.yml стал некорректным — восстановлен из копии" ;;
            recreate)   echo "Чтобы контейнер увидел папку, его нужно пересоздать: пользователи переподключатся за ~5 с. Сделать сейчас? [Y/n]:" ;;
            later)      echo "Отложено. Выполните позже: cd /opt/remnanode && docker compose up -d" ;;
            visible)    echo "Контейнер видит /hy2-certs/fullchain.pem" ;;
            invisible)  echo "Контейнер НЕ видит /hy2-certs — inbound HY2 на этой ноде пока не включайте" ;;
            timer)      echo "Ежедневная синхронизация сертификата: 04:17 по Москве" ;;
            ufw_ask)    echo "Открыть 443/udp в ufw? [Y/n]:" ;;
            ufw_ok)     echo "443/udp открыт в ufw" ;;
            udp_busy)   echo "UDP 443 уже занят другим процессом — Hysteria2 не запустится:" ;;
            hoster_fw)  echo "Если у хостера есть свой файрвол (в панели хостера) — откройте UDP 443 и там." ;;
            ready)      echo "ГОТОВО — inbound HY2 на этой ноде можно включать." ;;
            panel)      echo "В панели:" ;;
            p_inb)      echo "Профиль → inbound hysteria, tlsSettings.certificates:" ;;
            p_node)     echo "Ноды → эта нода: галка на inbound HY2 (на нодах без сертификата — не ставить)" ;;
            p_host)     echo "Хосты → новый: inbound HY2-*, адрес/SNI" ;;
            p_host2)    echo "порт 443, ALPN h3, скрытый, те же сквады, что у основного хоста страны" ;;
            *) echo "$k" ;;
        esac
    fi
}

yes_default() { # yes_default ПЕРЕМЕННАЯ "вопрос"  → 0 если да (по умолчанию да)
    local v="${!1}"
    if [ -z "$v" ]; then
        if is_non_interactive; then v=y; else question "$2"; v="${REPLY:-y}"; fi
    fi
    [[ "$v" =~ ^[Yy] ]]
}

find_cert() { /usr/local/sbin/remnasetup-hy2-cert --find --domain "$HY2_DOMAIN"; }

caddy_issue() {
    local cf="${SELFSTEAL}/Caddyfile" port ip dip
    port=$(grep -E '^LOCAL_PORT=' "${SELFSTEAL}/.env" 2>/dev/null | cut -d= -f2-); port=${port:-8443}
    ip=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null)
    dip=$( (getent ahostsv4 "$HY2_DOMAIN" 2>/dev/null || true) | awk '{print $1}' | head -1)
    if [ -z "$dip" ] || { [ "$dip" != "$ip" ] && ! ip -4 addr show | grep -qw "$dip"; }; then
        warn "$(t dns_bad) ${HY2_DOMAIN} → ${dip:-—}, $(hostname -s) = ${ip:-?}"
        return 1
    fi
    info "$(t issuing)"
    cp "$cf" "${cf}.bak.${STAMP}"
    # тот же сайт-заглушка, тот же локальный порт: Reality этот блок не задевает
    cat >> "$cf" <<EOF

${HY2_DOMAIN}:${port} {
    root * /srv/decoy
    file_server
    header -Server
}
EOF
    if ! docker exec selfsteal caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
        cp "${cf}.bak.${STAMP}" "$cf"; docker exec selfsteal caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
        error "$(t issue_fail)"; return 1
    fi
    local i
    for i in $(seq 1 24); do
        sleep 5
        if find_cert >/dev/null 2>&1; then success "$(t issued)"; return 0; fi
    done
    cp "${cf}.bak.${STAMP}" "$cf"; docker exec selfsteal caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
    error "$(t issue_fail)"
    return 1
}

ensure_mount() {
    local f="${NODE_DIR}/docker-compose.yml"
    if grep -qF ":/hy2-certs" "$f"; then info "$(t mount_ok)"; return 0; fi
    info "$(t mount_add)"; echo "$MOUNT_LINE"
    cp "$f" "${f}.bak.${STAMP}"
    if grep -qE '^    volumes:' "$f"; then
        awk -v line="$MOUNT_LINE" '{print} /^    volumes:/ && !d {print line; d=1}' "${f}.bak.${STAMP}" > "$f"
    elif grep -qE '^    logging:' "$f"; then
        awk -v line="$MOUNT_LINE" '/^    logging:/ && !d {print "    volumes:"; print line; d=1} {print}' "${f}.bak.${STAMP}" > "$f"
    else
        printf '    volumes:\n%s\n' "$MOUNT_LINE" >> "$f"
    fi
    if ! (cd "$NODE_DIR" && docker compose config -q 2>/dev/null); then
        cp "${f}.bak.${STAMP}" "$f"; error "$(t mount_bad)"; return 1
    fi
    if yes_default HY2_RECREATE "$(t recreate)"; then
        (cd "$NODE_DIR" && docker compose up -d) || return 1
        sleep 3
    else
        warn "$(t later)"; return 2
    fi
}

main() {
    check_root
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD_MAGENTA}$(t hdr)${RESET}"
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    [ -f "${NODE_DIR}/docker-compose.yml" ] || { error "$(t no_node)"; exit 1; }
    command_exists openssl || install_packages openssl

    install -m 755 "$BIN_SRC/remnasetup-hy2-cert" /usr/local/sbin/remnasetup-hy2-cert

    local def_dom=""
    [ -f /etc/remnasetup/hy2.env ] && def_dom=$(grep -E '^DOMAIN=' /etc/remnasetup/hy2.env | cut -d= -f2- | tr -d '"')
    [ -z "$def_dom" ] && [ -f "${SELFSTEAL}/.env" ] && def_dom=$(grep -E '^DOMAIN=' "${SELFSTEAL}/.env" | cut -d= -f2-)
    if [ -n "${HY2_DOMAIN:-}" ]; then info "HY2_DOMAIN=${HY2_DOMAIN}"
    elif is_non_interactive; then HY2_DOMAIN="$def_dom"
    else question "$(t ask_domain)${def_dom:+ [$def_dom]}:"; HY2_DOMAIN="${REPLY:-$def_dom}"; fi
    [ -n "$HY2_DOMAIN" ] || { error "domain?"; exit 1; }

    # 1-2. найти или выпустить
    local list
    if list=$(find_cert); then
        success "$(t found)"; echo "$list" | sed 's/^/      /'
    else
        warn "$(t not_found) ${HY2_DOMAIN}"
        [ -n "$list" ] && echo "$list" | sed 's/^/      /'
        local ss_dom=""
        [ -f "${SELFSTEAL}/.env" ] && ss_dom=$(grep -E '^DOMAIN=' "${SELFSTEAL}/.env" | cut -d= -f2-)
        if ! docker ps --format '{{.Names}}' | grep -qx selfsteal; then
            error "$(t no_caddy) ${DST}"; exit 1
        fi
        if [ "$ss_dom" = "$HY2_DOMAIN" ]; then error "$(t same_dom)"; exit 1; fi
        info "$(t can_issue)"
        yes_default HY2_ISSUE "$(t ask_issue)" || exit 1
        caddy_issue || exit 1
    fi

    # 3. копия
    mkdir -p /etc/remnasetup
    echo "DOMAIN=\"${HY2_DOMAIN}\"" > /etc/remnasetup/hy2.env
    /usr/local/sbin/remnasetup-hy2-cert --domain "$HY2_DOMAIN" || exit 1
    info "$(t copied) ${DST}: $(openssl x509 -in "${DST}/fullchain.pem" -noout -enddate | cut -d= -f2)"

    # 4. том в контейнер
    ensure_mount; local mrc=$?
    local ready=1
    if [ $mrc -eq 0 ] && docker exec remnanode test -r /hy2-certs/fullchain.pem 2>/dev/null; then
        success "$(t visible)"
    else
        warn "$(t invisible)"; ready=0
    fi

    # 5. таймер синхронизации
    cat > /etc/systemd/system/remnasetup-hy2-cert.service <<'EOF'
[Unit]
Description=Hysteria2 certificate sync from Caddy (RemnaSetup)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remnasetup-hy2-cert
EOF
    cat > /etc/systemd/system/remnasetup-hy2-cert.timer <<'EOF'
[Unit]
Description=Hysteria2 certificate sync — daily (RemnaSetup)

[Timer]
OnCalendar=*-*-* 04:17:00 Europe/Moscow
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnasetup-hy2-cert.timer >/dev/null 2>&1 && info "$(t timer)"

    # 6. UDP 443
    local owner
    owner=$(ss -ulnp 2>/dev/null | awk '$4 ~ /[:.]443$/ {print $NF}' | grep -viE 'rw-core|xray' | head -1)
    [ -n "$owner" ] && { warn "$(t udp_busy) $owner"; ready=0; }
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status | grep -qE '^443(/udp)?[[:space:]]+ALLOW'; then
            info "$(t ufw_ok)"
        elif yes_default HY2_UFW "$(t ufw_ask)"; then
            ufw allow 443/udp >/dev/null && success "$(t ufw_ok)"
        fi
    fi
    info "$(t hoster_fw)"

    echo
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    [ $ready -eq 1 ] && success "$(t ready)"
    echo -e "${BOLD_CYAN}$(t panel)${RESET}"
    echo -e "${BLUE}  1. $(t p_inb)${RESET}"
    echo -e "${BLUE}       {\"certificateFile\": \"/hy2-certs/fullchain.pem\", \"keyFile\": \"/hy2-certs/privkey.pem\"}${RESET}"
    echo -e "${BLUE}  2. $(t p_node)${RESET}"
    echo -e "${BLUE}  3. $(t p_host) ${HY2_DOMAIN}, $(t p_host2)${RESET}"
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    pause_press_key "$(get_string "press_any_key")"
}

main "$@"

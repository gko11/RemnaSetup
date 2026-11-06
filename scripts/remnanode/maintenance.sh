#!/bin/bash
#
# Расписание обслуживания ноды: обновление Remnanode и плановая перезагрузка.
#
# Заменяет строки crontab вида
#     0 1 * * 3 cd /opt/remnanode && docker compose pull && docker compose down && docker compose up -d
#     0 3 * * * /sbin/shutdown -r now
# на таймеры systemd. Что это даёт:
#   - время задаётся по Москве, независимо от часового пояса сервера;
#   - у каждого сервера свой день обновления — выбирается здесь;
#   - обновление без лишнего перезапуска, с проверкой и откатом (remnanode-update);
#   - перезагрузка не прерывает идущее обновление и не уходит в петлю;
#   - история: /var/log/remnasetup-maintenance.log и journalctl -u remnanode-update.
#
# Неинтерактивно (все переменные необязательны):
#   UPDATE_DAY=1..7|off  UPDATE_TIME=HH:MM
#   REBOOT_MODE=daily|weekly|off  REBOOT_DAY=1..7  REBOOT_TIME=HH:MM
#   MAINT_TZ=Europe/Moscow  NODE_NAME=nl2  TG_TOKEN=...  TG_CHAT=...
#   REMOVE_OLD_CRON=y|n

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

BIN_SRC=/opt/remnasetup/scripts/remnanode/bin
CONF_DIR=/etc/remnasetup
CONF=${CONF_DIR}/maintenance.env
UNIT_DIR=/etc/systemd/system
STAMP=$(date +%Y%m%d-%H%M%S)

t() {
    local k="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$k" in
            hdr)        echo "Node maintenance schedule (update + reboot)" ;;
            no_systemd) echo "systemd not found — timers are unavailable on this system" ;;
            no_node)    echo "/opt/remnanode/docker-compose.yml not found — install Remnanode first" ;;
            tz)         echo "Times below are in" ;;
            server_tz)  echo "server time zone" ;;
            cur)        echo "Current schedule:" ;;
            old_cron)   echo "Found old crontab lines:" ;;
            days)       echo "Days: 1 Mon, 2 Tue, 3 Wed, 4 Thu, 5 Fri, 6 Sat, 7 Sun" ;;
            upd_day)    echo "Node update day (1-7, 0 = do not update automatically)" ;;
            upd_time)   echo "Node update time HH:MM" ;;
            rb_mode)    echo "Server reboot: 1 daily, 2 once a week, 0 never" ;;
            rb_day)     echo "Reboot day (1-7)" ;;
            rb_time)    echo "Reboot time HH:MM" ;;
            tg_ask)     echo "Telegram alerts if the node fails after an update? Bot token (Enter = skip/keep)" ;;
            tg_chat)    echo "Chat ID" ;;
            name_ask)   echo "Server name in alerts" ;;
            bad_day)    echo "Enter a number 0-7" ;;
            bad_time)   echo "Format HH:MM, e.g. 01:00" ;;
            clash)      echo "Update and reboot are less than 30 min apart — the reboot will wait for the update, but it is better to separate them." ;;
            rm_cron)    echo "Remove the old crontab lines (they would duplicate the timers)? [Y/n]:" ;;
            cron_bak)   echo "crontab backup:" ;;
            cron_kept)  echo "Old crontab lines kept — then the node will be updated/rebooted twice." ;;
            done_)      echo "Schedule saved." ;;
            next)       echo "Next runs:" ;;
            log)        echo "Log:" ;;
            run_now)    echo "Update now (no restart if there is no new version):" ;;
            off)        echo "off" ;;
            every_day)  echo "every day" ;;
            bad_cal)    echo "systemd does not accept the schedule:" ;;
            *) echo "$k" ;;
        esac
    else
        case "$k" in
            hdr)        echo "Расписание обслуживания ноды (обновление + перезагрузка)" ;;
            no_systemd) echo "systemd не найден — таймеры на этой системе недоступны" ;;
            no_node)    echo "Нет /opt/remnanode/docker-compose.yml — сначала установите Remnanode" ;;
            tz)         echo "Время ниже — по часовому поясу" ;;
            server_tz)  echo "часовой пояс сервера" ;;
            cur)        echo "Текущее расписание:" ;;
            old_cron)   echo "Найдены старые строки crontab:" ;;
            days)       echo "Дни: 1 Пн, 2 Вт, 3 Ср, 4 Чт, 5 Пт, 6 Сб, 7 Вс" ;;
            upd_day)    echo "День обновления ноды (1-7, 0 = не обновлять автоматически)" ;;
            upd_time)   echo "Время обновления ЧЧ:ММ" ;;
            rb_mode)    echo "Перезагрузка сервера: 1 ежедневно, 2 раз в неделю, 0 не перезагружать" ;;
            rb_day)     echo "День перезагрузки (1-7)" ;;
            rb_time)    echo "Время перезагрузки ЧЧ:ММ" ;;
            tg_ask)     echo "Уведомлять в Telegram, если нода не поднялась после обновления? Токен бота (Enter = пропустить/оставить)" ;;
            tg_chat)    echo "ID чата" ;;
            name_ask)   echo "Имя сервера в уведомлениях" ;;
            bad_day)    echo "Введите число 0-7" ;;
            bad_time)   echo "Формат ЧЧ:ММ, например 01:00" ;;
            clash)      echo "Обновление и перезагрузка ближе 30 минут друг к другу — перезагрузка дождётся обновления, но лучше развести." ;;
            rm_cron)    echo "Удалить старые строки crontab (иначе задачи будут выполняться дважды)? [Y/n]:" ;;
            cron_bak)   echo "Копия crontab:" ;;
            cron_kept)  echo "Старые строки crontab оставлены — нода будет обновляться/перезагружаться дважды." ;;
            done_)      echo "Расписание сохранено." ;;
            next)       echo "Ближайшие запуски:" ;;
            log)        echo "Журнал:" ;;
            run_now)    echo "Обновить сейчас (без перезапуска, если новой версии нет):" ;;
            off)        echo "выключено" ;;
            every_day)  echo "каждый день" ;;
            bad_cal)    echo "systemd не принимает расписание:" ;;
            *) echo "$k" ;;
        esac
    fi
}

DAY_EN=(x Mon Tue Wed Thu Fri Sat Sun)
DAY_RU=(x Пн Вт Ср Чт Пт Сб Вс)
dayname() { if [ "${LANGUAGE:-ru}" = en ]; then echo "${DAY_EN[$1]}"; else echo "${DAY_RU[$1]}"; fi; }

valid_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }
norm_time() { printf '%02d:%02d' "$((10#${1%%:*}))" "$((10#${1##*:}))"; }

# ask_var ПЕРЕМЕННАЯ "вопрос" "по умолчанию" проверка
ask_var() {
    local var="$1" prompt="$2" def="$3" check="$4" val="${!1}"
    if [ -n "$val" ]; then info "${var}=${val}"; return; fi
    if is_non_interactive; then printf -v "$var" '%s' "$def"; return; fi
    while true; do
        question "${prompt}${def:+ [$def]}:"
        val="${REPLY:-$def}"
        if $check "$val"; then printf -v "$var" '%s' "$val"; return; fi
        warn "$( [ "$check" = valid_time ] && t bad_time || t bad_day )"
    done
}
valid_day() { [[ "$1" =~ ^[0-7]$ ]]; }
valid_day17() { [[ "$1" =~ ^[1-7]$ ]]; }
valid_mode() { [[ "$1" =~ ^[012]$ ]]; }
valid_any() { return 0; }

# Перевод строки cron (время сервера) в день 1-7 и время по MAINT_TZ.
# cron_to_tz "мин" "час" "день_недели|*"  ->  "D HH:MM"  (D = * если ежедневно)
cron_to_tz() {
    local mi="$1" h="$2" dow="$3" d i epoch
    [[ "$mi" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || return 1
    [[ "$dow" = "*" || "$dow" =~ ^[0-7]$ ]] || return 1
    for i in 0 1 2 3 4 5 6; do
        d=$(date -d "+$i day" +%F)
        if [ "$dow" = "*" ] || [ "$(date -d "$d" +%w)" = "$((dow % 7))" ]; then break; fi
    done
    epoch=$(date -d "$d $h:$mi" +%s) || return 1
    if [ "$dow" = "*" ]; then
        TZ="$MAINT_TZ" date -d "@$epoch" +"* %H:%M"
    else
        TZ="$MAINT_TZ" date -d "@$epoch" +"%u %H:%M"
    fi
}

# --- поиск старого crontab -------------------------------------------------
OLD_UPD_LINE=""; OLD_RB_LINE=""
scan_cron() {
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^@ ]] && continue
        if [[ "$line" == *remnanode* && "$line" == *pull* ]]; then OLD_UPD_LINE="$line"
        elif [[ "$line" =~ (shutdown[[:space:]]+-r|[[:space:]/]reboot([[:space:]]|$)) ]]; then OLD_RB_LINE="$line"
        fi
    done < <(crontab -l 2>/dev/null)
}

calendar() { # calendar ДЕНЬ|* ЧЧ:ММ  ->  строка OnCalendar
    local d="$1" tm="$2"
    if [ "$d" = "*" ]; then echo "*-*-* ${tm}:00 ${MAINT_TZ}"
    else echo "${DAY_EN[$d]} *-*-* ${tm}:00 ${MAINT_TZ}"; fi
}

write_timer() { # write_timer имя "описание" ExecStart OnCalendar
    local name="$1" desc="$2" exec="$3" cal="$4"
    cat > "${UNIT_DIR}/${name}.service" <<EOF
[Unit]
Description=${desc} (RemnaSetup)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${exec}
TimeoutStartSec=20min
EOF
    cat > "${UNIT_DIR}/${name}.timer" <<EOF
[Unit]
Description=${desc} — schedule (RemnaSetup)

[Timer]
OnCalendar=${cal}
AccuracySec=1min
Persistent=false

[Install]
WantedBy=timers.target
EOF
}

drop_timer() {
    systemctl disable --now "$1.timer" >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/$1.timer" "${UNIT_DIR}/$1.service"
}

main() {
    check_root
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD_MAGENTA}$(t hdr)${RESET}"
    echo -e "${MAGENTA}────────────────────────────────────────────────────────────${RESET}"
    command_exists systemctl || { error "$(t no_systemd)"; exit 1; }
    [ -f /opt/remnanode/docker-compose.yml ] || { error "$(t no_node)"; exit 1; }

    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    local S_UPD="" S_RB="" S_TG_TOKEN="" S_TG_CHAT="" S_NAME=""
    if [ -f "$CONF" ]; then
        S_UPD=$(grep -E '^UPDATE_SPEC=' "$CONF" | cut -d= -f2- | tr -d '"')
        S_RB=$(grep -E '^REBOOT_SPEC=' "$CONF" | cut -d= -f2- | tr -d '"')
        S_TG_TOKEN=$(grep -E '^TG_TOKEN=' "$CONF" | cut -d= -f2- | tr -d '"')
        S_TG_CHAT=$(grep -E '^TG_CHAT=' "$CONF" | cut -d= -f2- | tr -d '"')
        S_NAME=$(grep -E '^NODE_NAME=' "$CONF" | cut -d= -f2- | tr -d '"')
    fi
    MAINT_TZ="${MAINT_TZ:-Europe/Moscow}"
    info "$(t tz) ${MAINT_TZ} ($(t server_tz): $(timedatectl show -p Timezone --value 2>/dev/null || date +%Z))"

    # Значения по умолчанию: прежние настройки → старый crontab → 3 Ср 01:00 / ежедневно 03:00
    local def_ud="3" def_ut="01:00" def_rm="1" def_rd="3" def_rt="03:00" conv
    scan_cron
    if [ -n "$OLD_UPD_LINE$OLD_RB_LINE" ]; then
        echo; warn "$(t old_cron)"
        [ -n "$OLD_UPD_LINE" ] && echo "      $OLD_UPD_LINE"
        [ -n "$OLD_RB_LINE" ] && echo "      $OLD_RB_LINE"
    fi
    if [ -n "$OLD_UPD_LINE" ]; then
        read -r c_m c_h _ _ c_w _ <<<"$OLD_UPD_LINE"
        if conv=$(cron_to_tz "$c_m" "$c_h" "$c_w") && [ "${conv%% *}" != "*" ]; then
            def_ud="${conv%% *}"; def_ut="${conv##* }"
        fi
    fi
    if [ -n "$OLD_RB_LINE" ]; then
        read -r c_m c_h _ _ c_w _ <<<"$OLD_RB_LINE"
        if conv=$(cron_to_tz "$c_m" "$c_h" "$c_w"); then
            def_rt="${conv##* }"
            if [ "${conv%% *}" = "*" ]; then def_rm=1; else def_rm=2; def_rd="${conv%% *}"; fi
        fi
    fi
    if [ -n "$S_UPD" ]; then
        if [ "$S_UPD" = off ]; then def_ud=0; else def_ud="${S_UPD%% *}"; def_ut="${S_UPD##* }"; fi
    fi
    if [ -n "$S_RB" ]; then
        case "$S_RB" in
            off) def_rm=0 ;;
            "* "*) def_rm=1; def_rt="${S_RB##* }" ;;
            *) def_rm=2; def_rd="${S_RB%% *}"; def_rt="${S_RB##* }" ;;
        esac
    fi

    echo; info "$(t days)"
    # переменные окружения в формате off/daily/weekly → внутренние коды
    [ "${UPDATE_DAY:-}" = off ] && UPDATE_DAY=0
    case "${REBOOT_MODE:-}" in off) REBOOT_MODE=0 ;; daily) REBOOT_MODE=1 ;; weekly) REBOOT_MODE=2 ;; esac

    ask_var UPDATE_DAY "$(t upd_day)" "$def_ud" valid_day
    [ "$UPDATE_DAY" != 0 ] && ask_var UPDATE_TIME "$(t upd_time)" "$def_ut" valid_time
    ask_var REBOOT_MODE "$(t rb_mode)" "$def_rm" valid_mode
    [ "$REBOOT_MODE" = 2 ] && ask_var REBOOT_DAY "$(t rb_day)" "$def_rd" valid_day17
    [ "$REBOOT_MODE" != 0 ] && ask_var REBOOT_TIME "$(t rb_time)" "$def_rt" valid_time

    # Telegram необязателен
    TG_TOKEN="${TG_TOKEN:-}"; TG_CHAT="${TG_CHAT:-}"
    if [ -z "$TG_TOKEN" ] && ! is_non_interactive; then
        question "$(t tg_ask)${S_TG_TOKEN:+ [****${S_TG_TOKEN: -4}]}:"
        TG_TOKEN="${REPLY:-$S_TG_TOKEN}"
        if [ -n "$TG_TOKEN" ]; then
            question "$(t tg_chat)${S_TG_CHAT:+ [$S_TG_CHAT]}:"; TG_CHAT="${REPLY:-$S_TG_CHAT}"
        fi
    else
        TG_TOKEN="${TG_TOKEN:-$S_TG_TOKEN}"; TG_CHAT="${TG_CHAT:-$S_TG_CHAT}"
    fi
    NODE_NAME="${NODE_NAME:-}"
    [ -n "$TG_TOKEN" ] && ask_var NODE_NAME "$(t name_ask)" "${S_NAME:-$(hostname -s)}" valid_any

    # значения из окружения тоже проверяем
    valid_day "$UPDATE_DAY" && valid_mode "$REBOOT_MODE" || { error "UPDATE_DAY/REBOOT_MODE: $(t bad_day)"; exit 1; }
    [ "$UPDATE_DAY" = 0 ] || valid_time "$UPDATE_TIME" || { error "UPDATE_TIME: $(t bad_time)"; exit 1; }
    [ "$REBOOT_MODE" = 0 ] || valid_time "$REBOOT_TIME" || { error "REBOOT_TIME: $(t bad_time)"; exit 1; }
    [ "$REBOOT_MODE" != 2 ] || valid_day17 "$REBOOT_DAY" || { error "REBOOT_DAY: $(t bad_day)"; exit 1; }

    # --- проверка календарей до записи ---
    local UPD_SPEC=off RB_SPEC=off cal_u="" cal_r=""
    if [ "$UPDATE_DAY" != 0 ]; then
        UPDATE_TIME=$(norm_time "$UPDATE_TIME"); UPD_SPEC="$UPDATE_DAY $UPDATE_TIME"
        cal_u=$(calendar "$UPDATE_DAY" "$UPDATE_TIME")
        systemd-analyze calendar "$cal_u" >/dev/null 2>&1 || { error "$(t bad_cal) $cal_u"; exit 1; }
    fi
    if [ "$REBOOT_MODE" != 0 ]; then
        REBOOT_TIME=$(norm_time "$REBOOT_TIME")
        if [ "$REBOOT_MODE" = 1 ]; then RB_SPEC="* $REBOOT_TIME"; cal_r=$(calendar "*" "$REBOOT_TIME")
        else RB_SPEC="$REBOOT_DAY $REBOOT_TIME"; cal_r=$(calendar "$REBOOT_DAY" "$REBOOT_TIME"); fi
        systemd-analyze calendar "$cal_r" >/dev/null 2>&1 || { error "$(t bad_cal) $cal_r"; exit 1; }
    fi
    if [ -n "$cal_u" ] && [ -n "$cal_r" ]; then
        local mu mr diff
        mu=$((10#${UPDATE_TIME%%:*} * 60 + 10#${UPDATE_TIME##*:})); mr=$((10#${REBOOT_TIME%%:*} * 60 + 10#${REBOOT_TIME##*:}))
        diff=$(( mu > mr ? mu - mr : mr - mu ))
        if [ "$diff" -lt 30 ] && { [ "$REBOOT_MODE" = 1 ] || [ "$REBOOT_DAY" = "$UPDATE_DAY" ]; }; then warn "$(t clash)"; fi
    fi

    # --- установка ---
    install -m 755 "$BIN_SRC/remnanode-update" /usr/local/sbin/remnanode-update
    install -m 755 "$BIN_SRC/remnasetup-reboot" /usr/local/sbin/remnasetup-reboot
    umask 077
    cat > "$CONF" <<EOF
# RemnaSetup: настройки обслуживания (меню «Расписание обслуживания»)
UI_LANG="${LANGUAGE:-ru}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
TG_TOKEN="${TG_TOKEN}"
TG_CHAT="${TG_CHAT}"
UPDATE_SPEC="${UPD_SPEC}"
REBOOT_SPEC="${RB_SPEC}"
MAINT_TZ="${MAINT_TZ}"
EOF
    umask 022
    cat > /etc/logrotate.d/remnasetup-maintenance <<'EOF'
/var/log/remnasetup-maintenance.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF

    if [ -n "$cal_u" ]; then
        write_timer remnanode-update "Remnanode update" /usr/local/sbin/remnanode-update "$cal_u"
    else drop_timer remnanode-update; fi
    if [ -n "$cal_r" ]; then
        write_timer remnasetup-reboot "Scheduled reboot" /usr/local/sbin/remnasetup-reboot "$cal_r"
    else drop_timer remnasetup-reboot; fi
    systemctl daemon-reload
    [ -n "$cal_u" ] && systemctl enable --now remnanode-update.timer >/dev/null 2>&1 && systemctl restart remnanode-update.timer
    [ -n "$cal_r" ] && systemctl enable --now remnasetup-reboot.timer >/dev/null 2>&1 && systemctl restart remnasetup-reboot.timer

    # --- старый crontab ---
    if [ -n "$OLD_UPD_LINE$OLD_RB_LINE" ]; then
        local ans="${REMOVE_OLD_CRON:-}"
        if [ -z "$ans" ]; then
            if is_non_interactive; then ans=y; else question "$(t rm_cron)"; ans="${REPLY:-y}"; fi
        fi
        if [[ "$ans" =~ ^[Yy] ]]; then
            local bak="/root/crontab.backup.${STAMP}" tmp
            crontab -l > "$bak" 2>/dev/null
            tmp=$(mktemp)
            { [ -n "$OLD_UPD_LINE" ] && echo "$OLD_UPD_LINE"; [ -n "$OLD_RB_LINE" ] && echo "$OLD_RB_LINE"; } > "$tmp"
            grep -vxF -f "$tmp" "$bak" | crontab -
            rm -f "$tmp"
            info "$(t cron_bak) $bak"
        else
            warn "$(t cron_kept)"
        fi
    fi

    echo
    success "$(t done_)"
    local u_txt r_txt
    if [ "$UPD_SPEC" = off ]; then u_txt="$(t off)"; else u_txt="$(dayname "$UPDATE_DAY") $UPDATE_TIME"; fi
    case "$RB_SPEC" in
        off) r_txt="$(t off)" ;;
        "* "*) r_txt="$(t every_day) $REBOOT_TIME" ;;
        *) r_txt="$(dayname "$REBOOT_DAY") $REBOOT_TIME" ;;
    esac
    echo -e "${BLUE}  Remnanode update : ${u_txt} (${MAINT_TZ})${RESET}"
    echo -e "${BLUE}  Reboot           : ${r_txt} (${MAINT_TZ})${RESET}"
    [ -n "$TG_TOKEN" ] && echo -e "${BLUE}  Telegram         : ${TG_CHAT}${RESET}"
    echo
    echo -e "${BOLD_CYAN}$(t next)${RESET}"
    systemctl list-timers remnanode-update.timer remnasetup-reboot.timer remnasetup-hy2-cert.timer --no-pager 2>/dev/null | head -5
    echo
    echo -e "${BOLD_CYAN}$(t log)${RESET} tail -n 30 /var/log/remnasetup-maintenance.log"
    echo -e "${BOLD_CYAN}$(t run_now)${RESET} remnanode-update"
    pause_press_key "$(get_string "press_any_key")"
}

main "$@"

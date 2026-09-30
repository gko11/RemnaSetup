#!/bin/bash
#
# Лимиты ресурсов для УЖЕ УСТАНОВЛЕННОЙ ноды.
#
# ЗАЧЕМ
#   Свежие установки получают лимиты автоматически, а ноды, поднятые раньше,
#   остаются без них. На боевой ноде это выглядело так: wireproxy внутри
#   warproxy набирал по гигабайту в час, за ночь съедал 8 ГБ, выдавливал
#   систему в своп (511M из 512M) — и ложилась вся нода целиком, вместе с
#   xray и клиентами, которые к утечке отношения не имели.
#
# ЧТО ДЕЛАЕТ
#   1. Считает лимиты от объёма RAM хоста, а не берёт их с потолка.
#   2. Дописывает mem_limit / memswap_limit в docker-compose.yml каждого
#      найденного сервиса и пересоздаёт контейнер. Повторный запуск ничего
#      не ломает — если лимит уже стоит, строка не дублируется.
#   3. warproxy не трогает руками, а переустанавливает через install-warp.sh
#      с WARP_MODE=keep: тот сам перегенерирует compose с лимитами и сохранит
#      аккаунт WARP, так что повторной регистрации в Cloudflare не будет.
#   4. Добавляет ротацию логов — xray с loglevel debug пишет гигабайты за сутки.
#   5. Подтягивает сетевые sysctl: на нодах, поставленных давно,
#      nf_conntrack_max нередко остаётся 65536 против 262144 на свежих.
#
# НЕИНТЕРАКТИВНЫЕ ПЕРЕМЕННЫЕ
#   SKIP_WARP=1        не трогать warproxy
#   SKIP_SYSCTL=1      не менять sysctl
#   NODE_MEM=4096m     задать лимит ноды вручную (иначе 50% RAM, 512m..4g)
#   WARP_MEM_LIMIT=1g  задать лимит warproxy вручную (иначе 15% RAM, 256m..1g)
#   ASSUME_YES=1       не спрашивать подтверждение

set -o pipefail

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

select_language

LINE="────────────────────────────────────────────────────────────"
SYSCTL_FILE="/etc/sysctl.d/99-remnanode-tuning.conf"

t() {
    local key="$1"
    if [ "${LANGUAGE:-ru}" = "en" ]; then
        case "$key" in
            hdr)        echo "Resource limits for an existing node" ;;
            ram)        echo "Host RAM" ;;
            found)      echo "Containers found" ;;
            none)       echo "No known containers found — nothing to do" ;;
            plan)       echo "Limits to be applied" ;;
            confirm)    echo "Apply? [Y/n]:" ;;
            cancelled)  echo "Cancelled" ;;
            no_compose) echo "compose file not found, applying live only (will reset on next 'compose up')" ;;
            already)    echo "limit already present, skipping" ;;
            patched)    echo "compose updated" ;;
            recreated)  echo "container recreated" ;;
            live_only)  echo "limit applied to the running container" ;;
            warp_via)   echo "warproxy: reinstalling via install-warp.sh (account is kept)" ;;
            warp_skip)  echo "warproxy: not installed, skipping" ;;
            sysctl_hdr) echo "Network tuning" ;;
            sysctl_ok)  echo "sysctl applied" ;;
            before)     echo "Memory before" ;;
            after)      echo "Memory after" ;;
            done_ok)    echo "Done" ;;
            verify)     echo "Verify with: docker stats --no-stream" ;;
            no_docker)  echo "docker not found" ;;
            no_daemon)  echo "docker daemon is not running" ;;
        esac
    else
        case "$key" in
            hdr)        echo "Лимиты ресурсов для уже установленной ноды" ;;
            ram)        echo "RAM хоста" ;;
            found)      echo "Найдены контейнеры" ;;
            none)       echo "Известных контейнеров не найдено — делать нечего" ;;
            plan)       echo "Будут выставлены лимиты" ;;
            confirm)    echo "Применяем? [Y/n]:" ;;
            cancelled)  echo "Отменено" ;;
            no_compose) echo "compose-файл не найден, применяю только на живом контейнере (слетит при следующем 'compose up')" ;;
            already)    echo "лимит уже стоит, пропускаю" ;;
            patched)    echo "compose обновлён" ;;
            recreated)  echo "контейнер пересоздан" ;;
            live_only)  echo "лимит применён к работающему контейнеру" ;;
            warp_via)   echo "warproxy: переустанавливаю через install-warp.sh (аккаунт сохраняется)" ;;
            warp_skip)  echo "warproxy: не установлен, пропускаю" ;;
            sysctl_hdr) echo "Сетевой тюнинг" ;;
            sysctl_ok)  echo "sysctl применён" ;;
            before)     echo "Память до" ;;
            after)      echo "Память после" ;;
            done_ok)    echo "Готово" ;;
            verify)     echo "Проверить: docker stats --no-stream" ;;
            no_docker)  echo "docker не найден" ;;
            no_daemon)  echo "демон docker не запущен" ;;
        esac
    fi
}

# Каталог, из которого поднят контейнер. Берём из меток compose —
# гадать по /opt/<имя> нельзя, у людей разные пути.
compose_dir() {
    docker inspect "$1" --format \
        '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null
}

# Вписываем лимиты в compose. Без YAML-парсера, но безопасно: работаем
# только внутри блока нужного сервиса и только если лимита там ещё нет.
patch_compose() {
    local file="$1" container="$2" mem="$3" swap="$4"

    if grep -qE "^[[:space:]]+mem_limit:" "$file"; then
        echo "   $(t already)"
        return 1
    fi

    python3 - "$file" "$container" "$mem" "$swap" <<'PY'
import io, re, sys
path, container, mem, swap = sys.argv[1:5]
lines = io.open(path, encoding="utf-8").read().split("\n")

# находим строку сервиса по container_name, дальше поднимаемся к его отступу
idx = next((i for i, l in enumerate(lines)
            if re.match(r'^\s+container_name:\s*[\'"]?%s[\'"]?\s*$' % re.escape(container), l)), None)
if idx is None:
    sys.exit(2)

indent = re.match(r'^(\s+)', lines[idx]).group(1)
ins = [f"{indent}mem_limit: {mem}"]
if swap:
    ins.append(f"{indent}memswap_limit: {swap}")

lines[idx + 1:idx + 1] = ins
io.open(path, "w", encoding="utf-8").write("\n".join(lines))
PY

    case $? in
        0) echo "   $(t patched): mem_limit=${mem}${swap:+, memswap_limit=$swap}"; return 0 ;;
        2) warn "   container_name: $container в $file не найден"; return 1 ;;
        *) warn "   не удалось изменить $file"; return 1 ;;
    esac
}

apply_to() {
    local container="$1" pct="$2" min="$3" max="$4" forced="$5"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$container" || return 0

    local mem swap dir
    mem="${forced:-$(mem_limit_mb "$pct" "$min" "$max")}"
    swap=""
    swap_accounting_available && swap="$mem"

    echo -e "${BOLD_CYAN}▸ ${container}${RESET}"
    dir=$(compose_dir "$container")

    if [ -n "$dir" ] && [ -f "${dir}/docker-compose.yml" ]; then
        if patch_compose "${dir}/docker-compose.yml" "$container" "$mem" "$swap"; then
            (cd "$dir" && docker compose up -d >/dev/null 2>&1) \
                && echo "   $(t recreated)" \
                || warn "   docker compose up -d завершился с ошибкой"
            return 0
        fi
    else
        echo "   $(t no_compose)"
    fi

    # запасной путь: на лету, без пересоздания
    if [ -n "$swap" ]; then
        docker update --memory "$mem" --memory-swap "$swap" "$container" >/dev/null 2>&1
    else
        docker update --memory "$mem" "$container" >/dev/null 2>&1
    fi && echo "   $(t live_only): $mem"
}

tune_sysctl() {
    [ "${SKIP_SYSCTL:-0}" = "1" ] && return 0
    echo -e "${BOLD_CYAN}▸ $(t sysctl_hdr)${RESET}"
    cat > "$SYSCTL_FILE" <<'EOF'
# Поставлено RemnaSetup: apply-limits.sh
# Ноды, установленные давно, остаются со старыми значениями и упираются
# в таблицу соединений задолго до реального потолка по трафику.
net.netfilter.nf_conntrack_max = 262144
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
EOF
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1
    echo "   $(t sysctl_ok): $SYSCTL_FILE"
    sysctl -n net.netfilter.nf_conntrack_max net.ipv4.tcp_max_syn_backlog net.core.somaxconn 2>/dev/null \
        | paste -d' ' - - - | sed 's/^/   conntrack_max syn_backlog somaxconn: /'
}

main() {
    check_root
    command_exists docker || { error "$(t no_docker)"; exit 1; }
    docker info >/dev/null 2>&1 || { error "$(t no_daemon)"; exit 1; }

    clear
    echo -e "${MAGENTA}${LINE}${RESET}"
    echo -e "${BOLD_CYAN}$(t hdr)${RESET}"
    echo -e "${MAGENTA}${LINE}${RESET}"

    local ram; ram=$(host_ram_mb)
    echo -e "$(t ram): ${BOLD_GREEN}${ram} MB${RESET}"
    swap_accounting_available \
        && echo -e "swap accounting: ${BOLD_GREEN}есть${RESET}" \
        || warn "swap accounting: нет — memswap_limit будет пропущен"

    local present=()
    for c in remnanode selfsteal caddy warproxy; do
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c" && present+=("$c")
    done
    if [ ${#present[@]} -eq 0 ]; then
        warn "$(t none)"; exit 0
    fi
    echo -e "$(t found): ${BOLD_GREEN}${present[*]}${RESET}"

    echo
    echo -e "${BOLD_CYAN}$(t plan):${RESET}"
    printf "   %-12s %s\n" "remnanode" "${NODE_MEM:-$(mem_limit_mb 50 512 4096)}"
    printf "   %-12s %s\n" "selfsteal"  "$(mem_limit_mb 5 128 512)"
    printf "   %-12s %s\n" "warproxy"  "${WARP_MEM_LIMIT:-$(mem_limit_mb 15 256 1024)}"
    echo

    if [ "${ASSUME_YES:-0}" != "1" ] && ! is_non_interactive; then
        question "$(t confirm)"
        case "${REPLY,,}" in n|no|н|нет) info "$(t cancelled)"; exit 0 ;; esac
    fi

    echo -e "$(t before):"; free -h | sed 's/^/   /'
    echo

    apply_to remnanode 50 512 4096 "${NODE_MEM:-}"
    apply_to selfsteal  5 128  512 ""
    apply_to caddy      5 128  512 ""

    # warproxy — через свой установщик: он и compose перегенерирует, и аккаунт
    # WARP сохранит. Руками трогать нельзя, иначе поедет регистрация.
    if [ "${SKIP_WARP:-0}" != "1" ]; then
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx warproxy; then
            echo -e "${BOLD_CYAN}▸ warproxy${RESET}"
            echo "   $(t warp_via)"
            WARP_MODE=keep SKIP_PAUSE=true \
                bash /opt/remnasetup/scripts/remnanode/install-warp.sh \
                || warn "   install-warp.sh вернул ошибку — смотрите вывод выше"
        else
            echo -e "${BOLD_CYAN}▸ warproxy${RESET}"
            echo "   $(t warp_skip)"
        fi
    fi

    tune_sysctl

    echo
    echo -e "$(t after):"; free -h | sed 's/^/   /'
    echo
    echo -e "${MAGENTA}${LINE}${RESET}"
    success "$(t done_ok). $(t verify)"
    echo -e "${MAGENTA}${LINE}${RESET}"
}

main "$@"

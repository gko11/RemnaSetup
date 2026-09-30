#!/bin/bash

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

info() {
    echo -e "${BOLD_CYAN}[INFO]${RESET} $1"
}

warn() {
    echo -e "${BOLD_YELLOW}[WARN]${RESET} $1"
}

error() {
    echo -e "${BOLD_RED}[ERROR]${RESET} $1"
}

success() {
    echo -e "${BOLD_GREEN}[SUCCESS]${RESET} $1"
}

menu() {
    echo -e "${BOLD_MAGENTA}$1${RESET}"
    read -p "$(echo -e "${BOLD_CYAN}$(get_string "select_menu_option"):${RESET}") " choice
    echo "$choice"
}

question() {
    read -p "$(echo -e "${BOLD_CYAN}$1${RESET}") " REPLY
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "$(get_string "root_required")"
        exit 1
    fi
}

check_directory() {
    if [ ! -d "$1" ]; then
        error "$(get_string "directory_not_exist" "$1")"
        exit 1
    fi
}

check_file() {
    if [ ! -f "$1" ]; then
        error "$(get_string "file_not_exist" "$1")"
        exit 1
    fi
}

create_directory() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}

backup_file() {
    if [ -f "$1" ]; then
        cp "$1" "$1.bak"
    fi
}

restore_file() {
    if [ -f "$1.bak" ]; then
        mv "$1.bak" "$1"
    fi
}

detect_package_manager() {
    if command -v apt-get &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v apk &> /dev/null; then
        echo "apk"
    else
        echo "unknown"
    fi
}

update_package_list() {
    local pm=$(detect_package_manager)
    case "$pm" in
        apt)
            apt-get update -y
            ;;
        yum)
            yum check-update -y || true
            ;;
        dnf)
            dnf check-update -y || true
            ;;
        apk)
            apk update
            ;;
        *)
            error "Unsupported package manager"
            return 1
            ;;
    esac
}

install_packages() {
    local pm=$(detect_package_manager)
    local packages="$*"
    
    case "$pm" in
        apt)
            apt-get install -y $packages
            ;;
        yum)
            yum install -y $packages
            ;;
        dnf)
            dnf install -y $packages
            ;;
        apk)
            apk add --no-cache $packages
            ;;
        *)
            error "Unsupported package manager"
            return 1
            ;;
    esac
}

ensure_package() {
    local package="$1"
    if command_exists "$package"; then
        return 0
    fi

    local install_name="$package"
    case "$package" in
        7z)
            local pm=$(detect_package_manager)
            if [ "$pm" = "apt" ]; then
                install_name="p7zip-full"
            else
                install_name="p7zip"
            fi
            ;;
    esac
    
    info "Installing $install_name..."
    update_package_list
    install_packages "$install_name"
}

is_non_interactive() {
    if [[ "$NON_INTERACTIVE" == "true" || "$NON_INTERACTIVE" == "1" ]]; then
        return 0
    fi
    if [[ "$CI" == "true" || "$CI" == "1" ]]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        return 0
    fi
    return 1
}

pause_press_key() {
    local prompt="$1"
    if is_non_interactive; then
        return 0
    fi
    read -n 1 -s -r -p "$prompt"
    echo
}

export -f info
export -f warn
export -f error
export -f success
export -f menu
export -f question
export -f command_exists
export -f check_root
export -f check_directory
export -f check_file
export -f create_directory
export -f backup_file
export -f restore_file
export -f detect_package_manager
export -f update_package_list
export -f install_packages
export -f ensure_package
export -f is_non_interactive
export -f pause_press_key

# ---------------------------------------------------------------------------
# Лимиты памяти для контейнеров
#
# Зачем это нужно. Утечка в одном контейнере способна съесть всю RAM хоста,
# выдавить систему в своп и положить ноду целиком — вместе с теми сервисами,
# которые ни в чём не виноваты. Показательный случай: wireproxy внутри
# warproxy набирает по гигабайту в час и за ночь забивает 8 ГБ.
#
# С лимитом ядро убивает только виновника, "restart: always" поднимает его
# обратно за пару секунд, остальные контейнеры ничего не замечают.
# ---------------------------------------------------------------------------

host_ram_mb() {
    local kb
    kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$kb" ]; then
        echo 2048
        return
    fi
    echo $(( kb / 1024 ))
}

# mem_limit_mb <процент_от_RAM> <минимум_МБ> <максимум_МБ> -> "512m"
mem_limit_mb() {
    local pct="$1" min="$2" max="$3" total value
    total=$(host_ram_mb)
    value=$(( total * pct / 100 ))
    [ "$value" -lt "$min" ] && value="$min"
    [ "$value" -gt "$max" ] && value="$max"
    # на совсем маленьких VPS минимум может оказаться больше самой памяти
    [ "$value" -gt "$total" ] && value="$total"
    echo "${value}m"
}

# Ограничение свопа поддерживается не везде: на cgroup v1 без swapaccount=1
# Docker молча игнорирует memswap_limit и печатает предупреждение при старте.
swap_accounting_available() {
    [ -f /sys/fs/cgroup/memory.swap.max ] && return 0
    [ -f /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes ]
}

# set_container_limits <compose-файл> <ИМЯ_ПЛЕЙСХОЛДЕРА> <процент> <мин_МБ> <макс_МБ>
#
# Подставляет $MEM_<ИМЯ> и $MEMSWAP_<ИМЯ>. Если ядро не умеет считать своп,
# строка memswap_limit из файла удаляется — иначе Docker ругается на каждый
# запуск. memswap_limit, равный mem_limit, запрещает контейнеру уползать
# в своп: лучше быстрый OOM с перезапуском, чем часы свопинга.
set_container_limits() {
    local file="$1" name="$2" pct="$3" min="$4" max="$5"
    local mem swap

    [ -f "$file" ] || return 0

    mem=$(mem_limit_mb "$pct" "$min" "$max")
    sed -i "s|[\$]MEM_${name}|${mem}|g" "$file"

    if swap_accounting_available; then
        sed -i "s|[\$]MEMSWAP_${name}|${mem}|g" "$file"
        swap="$mem"
    else
        sed -i "/[\$]MEMSWAP_${name}/d" "$file"
        swap="-"
    fi

    info "$(get_string "mem_limit_applied" "$name" "$mem" "$swap")"
}

#!/bin/bash

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

# Отдельный файл в sysctl.d вместо дописывания в /etc/sysctl.conf:
# повторный запуск не плодит дубли, удалить настройку — удалить один файл.
install_bbr() {
    info "$(get_string "install_bbr_installing")"
    modprobe tcp_bbr 2>/dev/null || true
    echo tcp_bbr > /etc/modules-load.d/bbr.conf
    sed -i '/^net.core.default_qdisc=fq$/d; /^net.ipv4.tcp_congestion_control=bbr$/d' /etc/sysctl.conf 2>/dev/null
    cat > /etc/sysctl.d/60-bbr.conf <<'CONF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
CONF
    sysctl -q -p /etc/sysctl.d/60-bbr.conf
    success "$(get_string "install_bbr_installed")"
}

main() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && [ -f /etc/sysctl.d/60-bbr.conf ]; then
        info "$(get_string "install_bbr_already_configured")"
    else
        install_bbr
    fi
    pause_press_key "$(get_string "install_bbr_press_key")"
    exit 0
}

main

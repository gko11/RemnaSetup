#!/bin/bash
#
# Обновление Remnanode вручную — тем же механизмом, что и по расписанию:
# без перезапуска, если новой версии нет; с проверкой и откатом, если есть.

source "/opt/remnasetup/scripts/common/colors.sh"
source "/opt/remnasetup/scripts/common/functions.sh"
source "/opt/remnasetup/scripts/common/languages.sh"

main() {
    check_root
    install -m 755 /opt/remnasetup/scripts/remnanode/bin/remnanode-update /usr/local/sbin/remnanode-update
    info "$(get_string "update_node_updating")"
    if [ -f /etc/remnasetup/maintenance.env ]; then
        sed -i "s/^UI_LANG=.*/UI_LANG=\"${LANGUAGE:-ru}\"/" /etc/remnasetup/maintenance.env
    else
        mkdir -p /etc/remnasetup && echo "UI_LANG=\"${LANGUAGE:-ru}\"" > /etc/remnasetup/maintenance.env
    fi
    /usr/local/sbin/remnanode-update "$@"
    case $? in
        0) success "$(get_string "update_node_complete")" ;;
        2) warn "rollback / откат: tail -n 30 /var/log/remnasetup-maintenance.log" ;;
        *) error "tail -n 30 /var/log/remnasetup-maintenance.log" ;;
    esac
    pause_press_key "$(get_string "update_node_press_key")"
    exit 0
}

main "$@"

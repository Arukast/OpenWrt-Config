#!/bin/sh
# File: /etc/profile.d/99-ssh-notify.sh

if [ -n "$SSH_CLIENT" ]; then
    IP_CLIENT=$(echo "$SSH_CLIENT" | awk '{print $1}')
    # Gunakan variabel lingkungan $USER, jika kosong paksa tulis 'root'
    USER_LOGIN=${USER:-"root"}

    # Load config
    CONF="/etc/telegram.conf"
    [ -f "$CONF" ] || CONF="$(dirname "$0")/telegram.conf"
    
    if [ -f "$CONF" ]; then
        . "$CONF"
    fi

    # Load language
    LANG_DIR=${LANG_DIR:-"/etc/telegram_lang"}
    [ -d "$(dirname "$0")/lang" ] && LANG_DIR="$(dirname "$0")/lang"
    LANG_FILE="${LANG_DIR}/${LANG:-en}.sh"

    if [ -f "$LANG_FILE" ]; then
        . "$LANG_FILE"
    elif [ -f "${LANG_DIR}/en.sh" ]; then
        . "${LANG_DIR}/en.sh"
    fi

    safe_format() {
        local template="$1"
        shift
        local escaped_template
        escaped_template=$(echo "$template" | sed 's/%/%%/g; s/%%s/%s/g')
        printf "$escaped_template" "$@"
    }

    if [ -n "$MSG_LOGIN_SSH" ]; then
        PESAN=$(safe_format "$MSG_LOGIN_SSH" "$USER_LOGIN" "$IP_CLIENT")
    else
        PESAN="Successful SSH Login %0AUser: $USER_LOGIN%0AFrom IP: $IP_CLIENT"
    fi

    /usr/bin/telegram_notify.sh "SECURITY" "$PESAN"
fi



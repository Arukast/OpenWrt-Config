# Backup module

backup_uci() {
    if [ "$DRY_RUN" = "0" ]; then
        BACKUP_DIR="/tmp/uci-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        for ns in network wireless sqm system dhcp https-dns-proxy firewall; do
            uci export "$ns" > "$BACKUP_DIR/${ns}.uci" 2>/dev/null || true
        done
        log_ok "UCI backup saved to: $BACKUP_DIR"
    fi
}

#!/usr/bin/env bash
# Root-only local backup with consistent SQLite snapshot and integrity checks.
set -Eeuo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || exit 1
DIR=/root/xui-autodeploy-backups
install -d -m 700 "$DIR"
test -s /etc/x-ui/x-ui.db
SNAP=$(mktemp "$DIR/sqlite.XXXXXX.db")
cleanup() { rm -f -- "$SNAP"; }
trap cleanup EXIT
python3 - "$SNAP" <<'PYSQL'
import sqlite3, sys
target = sys.argv[1]
with sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro', uri=True) as source:
    with sqlite3.connect(target) as destination:
        source.backup(destination)
        assert destination.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
PYSQL
ARCHIVE="$DIR/backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
PART="${ARCHIVE}.partial"
items=(etc/x-ui)
[[ -d /etc/letsencrypt ]] && items+=(etc/letsencrypt)
[[ -d /etc/iptables ]] && items+=(etc/iptables)
# Keep the consistent snapshot separately, never copy live SQLite files into tar.
tar --exclude='etc/x-ui/x-ui.db' --exclude='etc/x-ui/x-ui.db-wal' \
  --exclude='etc/x-ui/x-ui.db-shm' -czf "$PART" -C / "${items[@]}" \
  -C "$DIR" "$(basename "$SNAP")"
tar -tzf "$PART" >/dev/null
mv -f -- "$PART" "$ARCHIVE"
chmod 600 "$ARCHIVE"
# Keep at most approximately two weeks of successful local snapshots.
# Prune only after validating a newly written backup.
find "$DIR" -maxdepth 1 -type f -name 'backup-*.tar.gz' -mtime +13 -delete
printf 'Backup verified: %s\n' "$ARCHIVE"
echo 'Contains sensitive keys and panel credentials. Store an encrypted copy off-server.'

#!/usr/bin/env bash
# Root-only local backup with consistent SQLite snapshot and integrity checks.
set -Eeuo pipefail
umask 077
[[ $(id -u) -eq 0 ]] || exit 1
DIR=/root/xui-autodeploy-backups
install -d -m 700 "$DIR"
DB_TYPE=sqlite
if [[ -f /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  DB_TYPE="${XUI_DB_TYPE:-sqlite}"
fi
[[ "$DB_TYPE" == sqlite || "$DB_TYPE" == postgres ]] || { echo 'Unsupported 3X-UI DB type' >&2; exit 1; }
SNAP=$(mktemp "$DIR/snapshot.XXXXXX")
cleanup() { rm -f -- "$SNAP"; }
trap cleanup EXIT
if [[ "$DB_TYPE" == sqlite ]]; then
  test -s /etc/x-ui/x-ui.db
  python3 - "$SNAP" <<'PYSQL'
import sqlite3, sys
target = sys.argv[1]
with sqlite3.connect('file:/etc/x-ui/x-ui.db?mode=ro', uri=True) as source:
    with sqlite3.connect(target) as destination:
        source.backup(destination)
        assert destination.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
PYSQL
else
  [[ -f /etc/default/x-ui ]] || { echo 'Missing PostgreSQL connection configuration' >&2; exit 1; }
  # Official 3X-UI installer writes XUI_DB_DSN into this root-managed env file.
  # shellcheck disable=SC1091
  source /etc/default/x-ui
  [[ -n "${XUI_DB_DSN:-}" ]] || { echo 'PostgreSQL DSN missing' >&2; exit 1; }
  command -v pg_dump >/dev/null || { echo 'pg_dump missing' >&2; exit 1; }
  command -v pg_restore >/dev/null || { echo 'pg_restore missing' >&2; exit 1; }
  pg_dump --format=custom --file="$SNAP" --dbname="$XUI_DB_DSN"
  pg_restore --list "$SNAP" >/dev/null
  unset XUI_DB_DSN
fi
ARCHIVE="$DIR/backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
PART="${ARCHIVE}.partial"
items=(etc/x-ui)
[[ -d /etc/letsencrypt ]] && items+=(etc/letsencrypt)
[[ -d /etc/iptables ]] && items+=(etc/iptables)
[[ "$DB_TYPE" == postgres && -f /etc/default/x-ui ]] && items+=(etc/default/x-ui)
# Exclude live SQLite: the consistent snapshot or pg_dump is archived separately.
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

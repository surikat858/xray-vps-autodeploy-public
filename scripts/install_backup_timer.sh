#!/usr/bin/env bash
# Explicit, opt-in installation of daily encrypted-storage-ready local backups.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run as root'; exit 1; }
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$BASE/scripts/backup.sh" ]] || exit 1
install -o root -g root -m 700 "$BASE/scripts/backup.sh" /usr/local/sbin/xui-autodeploy-backup
cat > /etc/systemd/system/xui-autodeploy-backup.service <<'UNIT'
[Unit]
Description=Consistent 3X-UI snapshot backup
ConditionPathExists=/etc/x-ui/x-ui.db
[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=/usr/local/sbin/xui-autodeploy-backup
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT
cat > /etc/systemd/system/xui-autodeploy-backup.timer <<'UNIT'
[Unit]
Description=Daily 3X-UI backup schedule
[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true
Unit=xui-autodeploy-backup.service
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now xui-autodeploy-backup.timer
systemctl list-timers --no-pager xui-autodeploy-backup.timer
echo 'Backups remain on this VPS until you configure encrypted OFF-SERVER copy.'

#!/usr/bin/env bash
# Manual, narrowly scoped rollback: restores only prior Xray binary.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || exit 1
OLD=/root/xray-autodeploy-upgrade/xray-previous
BIN=/usr/local/x-ui/bin/xray-linux-amd64
[[ -s "$OLD" ]] || { echo 'Previous Xray not found; nothing changed'; exit 1; }
read -r -p 'Restore previous Xray and restart 3X-UI (disconnect VPN sessions)? Type ROLLBACK: ' response
[[ "$response" == ROLLBACK ]] || exit 1
install -o root -g root -m 755 "$OLD" "${BIN}.revert"
mv -f "${BIN}.revert" "$BIN"
systemctl restart x-ui
systemctl is-active --quiet x-ui
"$BIN" version | head -1

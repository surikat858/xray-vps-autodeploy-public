#!/usr/bin/env bash
# Read-only server summary for interactive root SSH logins.
# No passwords, API tokens, client UUIDs or private keys.
set -euo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exit 0
[[ -f /etc/x-ui/autodeploy-public.env ]] || exit 0
# Root-owned simple variables, written by the installer.
# shellcheck disable=SC1091
source /etc/x-ui/autodeploy-public.env
[[ ${DOMAIN:-} =~ ^[a-z0-9-]+[.]duckdns[.]org$ ]] || exit 0
[[ ${SSH_PORT:-} =~ ^[0-9]{1,5}$ ]] || exit 0
[[ ${VPN_PORT:-} =~ ^[0-9]{1,5}$ ]] || exit 0

printf '\n========= Xray VPS / 3X-UI =========\n'
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  printf 'OS:              %s\n' "${PRETTY_NAME:-unknown}"
fi
printf 'Kernel:          %s\n' "$(uname -r)"
printf 'Domain:          %s\n' "$DOMAIN"
printf 'VPN port:        %s\n' "$VPN_PORT"
printf 'Database:        %s\n' "${XUI_DB_TYPE:-sqlite}"
printf '3X-UI service:   %s\n' "$(systemctl is-active x-ui 2>/dev/null || true)"
printf 'Fail2ban:        %s\n' "$(systemctl is-active fail2ban 2>/dev/null || true)"
printf 'Certbot timer:   %s\n' "$(systemctl is-active certbot.timer 2>/dev/null || true)"
if [[ -x /usr/local/x-ui/x-ui ]]; then
  printf '3X-UI version:   %s\n' "$(/usr/local/x-ui/x-ui version 2>/dev/null | head -n 1 || true)"
fi
if [[ -x /usr/local/x-ui/bin/xray-linux-amd64 ]]; then
  printf 'Xray-core:       %s\n' "$(/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -n 1 || true)"
fi
for package in certbot openssl python3 curl; do
  printf '%-17s %s\n' "$package:" "$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || echo unavailable)"
done

if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  if [[ ${XUI_PANEL_PORT:-} =~ ^[0-9]{1,5}$ &&
        ${XUI_WEB_BASE_PATH:-} =~ ^[A-Za-z0-9/_-]+$ ]]; then
    panel_path="/${XUI_WEB_BASE_PATH#/}"
    panel_path="${panel_path%/}/"
    scheme=http
    if [[ "${PANEL_TLS_MODE:-ssh}" == domain ]]; then scheme=https; fi
    printf 'SSH tunnel:     ssh -N -p %s -L 127.0.0.1:8443:127.0.0.1:%s root@%s\n' \
      "$SSH_PORT" "$XUI_PANEL_PORT" "$DOMAIN"
    printf 'Access URL:     %s://127.0.0.1:8443%s\n' "$scheme" "$panel_path"
  fi
fi
printf 'Server details:  sudo /usr/local/sbin/xui-server-info\n'
printf '3X-UI menu:      sudo x-ui\n'
printf 'Private panel:   sudo bash /root/xray-vps-autodeploy-public/scripts/panel_access.sh --show-credentials\n'
printf '=====================================\n\n'

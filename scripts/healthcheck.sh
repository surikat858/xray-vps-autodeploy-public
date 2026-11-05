#!/usr/bin/env bash
# Read-only local health audit. No credentials or UUIDs printed.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run as root'; exit 1; }
DOMAIN="${DOMAIN:-}"
VPN_PORT="${VPN_PORT:-443}"
if [[ -f /etc/x-ui/autodeploy-public.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/autodeploy-public.env
elif [[ -f "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config.env" ]]; then
  # shellcheck disable=SC1091
  source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config.env"
fi
: "${DOMAIN:?Missing DOMAIN}"
[[ $VPN_PORT =~ ^[0-9]{1,5}$ ]] || exit 1
failures=0
check() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '[OK] %s\n' "$name"
  else
    printf '[FAIL] %s\n' "$name"
    failures=$((failures+1))
  fi
}
check '3X-UI active' systemctl is-active --quiet x-ui
check "VPN TCP ${VPN_PORT} listening" bash -c 'ss -H -ltn "( sport = :$1 )" | grep -q LISTEN' _ "$VPN_PORT"
check 'Panel bound to localhost' bash -c "ss -H -ltnp | grep x-ui | grep -Eq '127[.]0[.]0[.]1:[0-9]+'"
check 'Certificate valid >=7 days' openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkend 604800
check 'Certbot timer enabled' systemctl is-enabled --quiet certbot.timer
check 'Certbot timer active' systemctl is-active --quiet certbot.timer
if [[ "${XUI_DB_TYPE:-sqlite}" == postgres ]]; then
  check 'PostgreSQL panel config exists' test -s /etc/default/x-ui
else
  check '3X-UI SQLite database exists' test -s /etc/x-ui/x-ui.db
fi
check 'Subscription port block service' systemctl is-active --quiet xui-block-subscription.service
check 'IPv4 subscription block' iptables -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT
check 'IPv6 subscription block' ip6tables -C INPUT ! -i lo -p tcp --dport 2096 -j REJECT
check 'DNS resolves' getent ahostsv4 "$DOMAIN"
# Firewall is tested independently because INPUT chains may have jump rules.
echo '[INFO] IPv4 firewall INPUT:'
iptables -S INPUT 2>/dev/null | head -12 || true
echo '[INFO] IPv6 firewall INPUT:'
ip6tables -S INPUT 2>/dev/null | head -12 || true
echo "Xray: $(/usr/local/x-ui/bin/xray-linux-amd64 version | head -1)"
echo "Free disk space: $(df -h / | awk 'NR==2{print $4}')"
printf 'Healthcheck failures: %d\n' "$failures"
(( failures == 0 ))

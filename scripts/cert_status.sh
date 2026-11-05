#!/usr/bin/env bash
# Read-only certificate/DNS audit; does not renew or restart.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || { echo 'Run as root'; exit 1; }
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG_FILE:-$BASE/config.env}"
[[ -f /etc/x-ui/autodeploy-public.env ]] && CONFIG=/etc/x-ui/autodeploy-public.env
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
: "${DOMAIN:?}"
[[ $DOMAIN =~ ^[a-z0-9-]+[.]duckdns[.]org$ ]] || exit 1
cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
renew="/etc/letsencrypt/renewal/$DOMAIN.conf"
[[ -s "$cert" && -s "$renew" ]] || { echo 'Missing certificate/renewal config'; exit 1; }
echo "DOMAIN: $DOMAIN"
openssl x509 -in "$cert" -noout -subject -dates
if openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null; then
  echo 'CERT_VALID_MORE_THAN_30_DAYS: YES'
else
  echo 'CERT_VALID_MORE_THAN_30_DAYS: NO (renewal check recommended)'
fi
echo "CERTBOT_TIMER_ENABLED: $(systemctl is-enabled certbot.timer 2>/dev/null || true)"
echo "CERTBOT_TIMER_ACTIVE: $(systemctl is-active certbot.timer 2>/dev/null || true)"
echo "RENEWAL_METHOD: $(sed -n 's/^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*//p' "$renew" | head -1)"
printf 'DNS_IPV4: '; getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}'
printf 'PUBLIC_IPV4: '; curl -4fsS --max-time 10 https://api.ipify.org || true
echo
echo 'PORT80_LOCAL_LISTENER:'
ss -H -ltn '( sport = :80 )'
echo 'DEPLOY_HOOK:'
test -x /etc/letsencrypt/renewal-hooks/deploy/30-xui-restart.sh && echo INSTALLED || echo NOT_INSTALLED
echo 'No changes made.'
